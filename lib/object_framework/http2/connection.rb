# frozen_string_literal: true

module ObjectFramework
  module HTTP2
    Stream = Struct.new(:id, :context, :input, :send_window, :receive_window,
                        :remote_closed, :local_closed, :reset, :received, :content_length,
                        keyword_init: true)

    class Connection
      PREFACE = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".b.freeze
      MAX_WINDOW = 2**31 - 1
      attr_reader :io

      def initialize(io:, on_stream:, reporter:, header_limit: 32 * 1024,
                     stream_limit: 128, idle_timeout: 30, write_timeout: 30,
                     tls: false)
        @io, @on_stream, @reporter = io, on_stream, reporter
        @header_limit, @stream_limit, @idle_timeout, @write_timeout, @tls = header_limit, stream_limit, idle_timeout, write_timeout, tls
        @reader = HTTP::Reader.new(io:)
        @decoder, @encoder = HPACK::Decoder.new(header_limit:), HPACK::Encoder.new
        @mutex, @write_mutex, @changed = Mutex.new, Mutex.new, ConditionVariable.new
        @streams, @last_stream, @closed, @draining = {}, 0, false, false
        @peer_initial_window, @send_window, @receive_window = 65_535, 65_535, 65_535
        @peer_frame_size, @continuation, @first_frame = 16_384, nil, true
        @context = ExecutionContext.new
      end

      def run
        handshake if @tls
        raise ProtocolError, "Invalid HTTP/2 connection preface" unless @reader.read_exact(PREFACE.bytesize, deadline: deadline) == PREFACE
        send_frame(4, 0, 0, [3, @stream_limit, 6, @header_limit].pack("nNnN"))
        loop do
          frame = Frame.read(@reader, deadline:)
          if @first_frame
            raise ProtocolError unless frame.type == 4 && frame.stream_id.zero? && (frame.flags & 1).zero?
            @first_frame = false
          end
          raise ProtocolError if @continuation && (frame.type != 9 || frame.stream_id != @continuation[:id])
          begin
            process(frame)
          rescue StreamError => error
            reject_stream(error)
          end
        end
      rescue EOFError, IOError, SystemCallError
        nil
      rescue StandardError => error
        @reporter.report(error, context: @context)
        begin
          code = error.is_a?(ProtocolError) ? error.code : 2
          send_frame(7, 0, 0, [@last_stream, code].pack("NN"))
        rescue StandardError
          nil
        end
      ensure
        close
      end

      def close
        streams = @mutex.synchronize do
          @closed = true
          @changed.broadcast
          @streams.values.dup
        end
        streams.each { |stream| stream.input.cancel }
        io.close unless io.closed?
      rescue IOError, SystemCallError
        nil
      end

      def send_headers(stream, headers, end_stream: false)
        stream.context.cancellation.check! unless end_stream
        block = @encoder.encode(headers)
        raise CapacityExceeded, "Outgoing headers exceed configured limit" if headers.sum { |name, value| name.bytesize + value.bytesize + 32 } > @header_limit
        @write_mutex.synchronize do
          offset, first = 0, true
          begin
            chunk = block.byteslice(offset, @peer_frame_size) || "".b
            offset += chunk.bytesize
            flags = offset == block.bytesize ? 4 : 0
            flags |= 1 if first && end_stream
            write_frame(first ? 1 : 9, flags, stream.id, chunk)
            first = false
          end while offset < block.bytesize
        end
        finish_local(stream) if end_stream
      end

      def send_data(stream, bytes)
        offset = 0
        while offset < bytes.bytesize
          count = @mutex.synchronize do
            loop do
              stream.context.cancellation.check!
              raise Cancelled, "HTTP/2 stream is closed" if @closed || stream.reset || stream.local_closed
              available = [@send_window, stream.send_window, @peer_frame_size, bytes.bytesize - offset].min
              if available.positive?
                @send_window -= available
                stream.send_window -= available
                break available
              end
              remaining = stream.context.cancellation.deadline ? stream.context.cancellation.deadline - HTTP::Timing.now : 0.1
              @changed.wait(@mutex, [[remaining, 0].max, 0.1].min)
            end
          end
          send_frame(0, 0, stream.id, bytes.byteslice(offset, count))
          offset += count
        end
      end

      def reset?(stream)
        @mutex.synchronize { @closed || stream.reset }
      end

      private

      def deadline; HTTP::Timing.now + @idle_timeout; end

      def handshake
        limit = deadline
        loop do
          result = io.accept_nonblock(exception: false)
          break unless %i[wait_readable wait_writable].include?(result)
          HTTP::Timing.wait(io, result == :wait_readable ? :read : :write, limit)
        end
        raise ProtocolError, "TLS must negotiate h2" unless io.alpn_protocol == "h2"
      end

      def process(frame)
        case frame.type
        when 0 then receive_data(frame)
        when 1 then receive_headers(frame)
        when 2
          require_stream(frame)
          require_size(frame, 5)
          raise ProtocolError if frame.payload.unpack1("N") & MAX_WINDOW == frame.stream_id
        when 3 then receive_reset(frame)
        when 4 then receive_settings(frame)
        when 5 then raise ProtocolError, "Clients cannot push streams"
        when 6
          require_connection(frame)
          require_size(frame, 8)
          send_frame(6, 1, 0, frame.payload) if (frame.flags & 1).zero?
        when 7
          require_connection(frame)
          raise ProtocolError.new(code: 6) if frame.payload.bytesize < 8
          @draining = true
        when 8 then receive_window(frame)
        when 9 then receive_continuation(frame)
        end
      end

      def receive_settings(frame)
        require_connection(frame)
        if (frame.flags & 1).positive?
          require_size(frame, 0)
          return
        end
        raise ProtocolError.new(code: 6) unless (frame.payload.bytesize % 6).zero?
        frame.payload.unpack("nN" * (frame.payload.bytesize / 6)).each_slice(2) do |id, value|
          case id
          when 2 then raise ProtocolError unless value <= 1
          when 4
            raise ProtocolError.new(code: 3) if value > MAX_WINDOW
            @mutex.synchronize do
              difference = value - @peer_initial_window
              @streams.each_value do |stream|
                raise ProtocolError.new(code: 3) if stream.send_window + difference > MAX_WINDOW
                stream.send_window += difference
              end
              @peer_initial_window = value
              @changed.broadcast
            end
          when 5
            raise ProtocolError unless value.between?(16_384, 16_777_215)
            @peer_frame_size = value
          end
        end
        send_frame(4, 1, 0, "".b)
      end

      def receive_headers(frame)
        require_stream(frame)
        stream = @mutex.synchronize { @streams[frame.stream_id] }
        fresh = !stream
        if fresh
          raise ProtocolError unless frame.stream_id.odd? && frame.stream_id > @last_stream && !@draining
          @last_stream = frame.stream_id
        else
          raise StreamError.new(frame.stream_id, code: 5) if stream.remote_closed
          raise StreamError.new(frame.stream_id) if (frame.flags & 1).zero?
        end
        payload, = unpad(frame)
        if (frame.flags & 32).positive?
          raise ProtocolError.new(code: 6) if payload.bytesize < 5
          raise ProtocolError if payload.unpack1("N") & MAX_WINDOW == frame.stream_id
          payload = payload.byteslice(5..)
        end
        @continuation = { id: frame.stream_id, bytes: payload, end_stream: (frame.flags & 1).positive?, fresh: }
        complete_headers if (frame.flags & 4).positive?
      end

      def receive_continuation(frame)
        raise ProtocolError unless @continuation && @continuation[:id] == frame.stream_id
        @continuation[:bytes] += frame.payload
        raise CompressionError if @continuation[:bytes].bytesize > @header_limit
        complete_headers if (frame.flags & 4).positive?
      end

      def complete_headers
        block, @continuation = @continuation, nil
        headers = @decoder.decode(block[:bytes])
        begin
          validate_headers(headers, request: block[:fresh])
        rescue ProtocolError => error
          raise StreamError.new(block[:id], error.message, code: error.code)
        end
        if block[:fresh]
          context = ExecutionContext.new
          stream = Stream.new(id: block[:id], context:, send_window: @peer_initial_window,
            receive_window: 65_535, remote_closed: block[:end_stream], local_closed: false,
            reset: false, received: 0, content_length: nil)
          stream.input = Inbound.new(cancellation: context.cancellation,
            on_consume: ->(count) { release_capacity(stream, count) })
          lengths = headers.select { |name, _| name == "content-length" }.map(&:last)
          unless lengths.empty?
            raise ProtocolError unless lengths.size == 1 && /\A[0-9]+\z/.match?(lengths.first)
            stream.content_length = Integer(lengths.first, 10)
          end
          @mutex.synchronize do
            raise StreamError.new(stream.id, "Peer exceeded concurrent stream limit", code: 7) if @streams.size >= @stream_limit
            @streams[stream.id] = stream
          end
          finish_remote(stream) if block[:end_stream]
          @on_stream.call(self, stream, headers)
        else
          stream = @mutex.synchronize { @streams.fetch(block[:id]) }
          finish_remote(stream)
        end
      end

      def validate_headers(headers, request:)
        regular, pseudo = false, {}
        headers.each do |name, value|
          raise ProtocolError unless /\A:?[!#$%&'*+.^_`|~0-9a-z-]+\z/.match?(name)
          raise ProtocolError if value.match?(/[\x00\r\n]/) || value.start_with?(" ", "\t") || value.end_with?(" ", "\t")
          if name.start_with?(":")
            raise ProtocolError if regular || !request || pseudo.key?(name) || !%w[:method :path :scheme :authority].include?(name)
            pseudo[name] = value
          else
            regular = true
            raise ProtocolError if %w[connection keep-alive proxy-connection transfer-encoding upgrade].include?(name)
            raise ProtocolError if name == "te" && value != "trailers"
          end
        end
        if request
          raise ProtocolError unless pseudo[":method"] && %w[http https].include?(pseudo[":scheme"]) && pseudo[":path"]&.start_with?("/")
        end
      end

      def receive_data(frame)
        require_stream(frame)
        payload, overhead = unpad(frame)
        stream = @mutex.synchronize do
          @receive_window -= frame.payload.bytesize
          raise ProtocolError.new(code: 3) if @receive_window.negative?
          @streams[frame.stream_id]
        end
        unless stream
          raise ProtocolError if frame.stream_id > @last_stream
          release_capacity(nil, frame.payload.bytesize)
          send_frame(3, 0, frame.stream_id, [5].pack("N"))
          return
        end
        if stream.remote_closed
          release_capacity(nil, frame.payload.bytesize)
          raise StreamError.new(stream.id, "DATA after end of stream", code: 5)
        end
        exceeded = false
        @mutex.synchronize do
          stream.receive_window -= frame.payload.bytesize
          exceeded = stream.receive_window.negative?
          stream.received += payload.bytesize
        end
        if exceeded
          release_capacity(nil, frame.payload.bytesize)
          raise StreamError.new(stream.id, code: 3)
        end
        release_capacity(stream, overhead) if overhead.positive?
        stream.input.push(payload)
        finish_remote(stream) if (frame.flags & 1).positive?
      end

      def receive_reset(frame)
        require_stream(frame)
        require_size(frame, 4)
        stream = @mutex.synchronize do
          raise ProtocolError if frame.stream_id > @last_stream
          found = @streams.delete(frame.stream_id)
          found.reset = true if found
          @changed.broadcast
          found
        end
        stream&.input&.cancel
        stream&.input&.discard
      end

      def receive_window(frame)
        require_size(frame, 4)
        increment = frame.payload.unpack1("N") & MAX_WINDOW
        if increment.zero?
          raise ProtocolError if frame.stream_id.zero?
          raise StreamError.new(frame.stream_id)
        end
        @mutex.synchronize do
          if frame.stream_id.zero?
            raise ProtocolError.new(code: 3) if @send_window + increment > MAX_WINDOW
            @send_window += increment
          elsif (stream = @streams[frame.stream_id])
            raise StreamError.new(stream.id, code: 3) if stream.send_window + increment > MAX_WINDOW
            stream.send_window += increment
          elsif frame.stream_id > @last_stream
            raise ProtocolError
          end
          @changed.broadcast
        end
      end

      def finish_remote(stream)
        if stream.content_length && stream.received != stream.content_length
          raise StreamError.new(stream.id, "Content length does not match DATA")
        end
        @mutex.synchronize do
          stream.remote_closed = true
          @streams.delete(stream.id) if stream.local_closed
        end
        stream.input.finish
      end

      def finish_local(stream)
        @mutex.synchronize do
          stream.local_closed = true
          @streams.delete(stream.id) if stream.remote_closed
          @changed.broadcast
        end
        stream.input.discard
      end

      def release_capacity(stream, count)
        return if count.zero?
        active_stream = @mutex.synchronize do
          return if @closed
          @receive_window += count
          if stream && @streams.key?(stream.id) && !stream.reset
            stream.receive_window += count
            true
          end
        end
        send_frame(8, 0, 0, [count].pack("N"))
        send_frame(8, 0, stream.id, [count].pack("N")) if active_stream
      rescue IOError, SystemCallError
        nil
      end

      def reject_stream(error)
        stream = @mutex.synchronize do
          found = @streams.delete(error.stream_id)
          found.reset = true if found
          @changed.broadcast
          found
        end
        @reporter.report(error, context: stream&.context || ExecutionContext.new)
        stream&.input&.cancel
        stream&.input&.discard
        send_frame(3, 0, error.stream_id, [error.code].pack("N"))
      end

      def unpad(frame)
        return [frame.payload, 0] if (frame.flags & 8).zero?
        padding = frame.payload.getbyte(0)
        raise ProtocolError unless padding && padding < frame.payload.bytesize
        [frame.payload.byteslice(1, frame.payload.bytesize - padding - 1), padding + 1]
      end

      def require_connection(frame); raise ProtocolError unless frame.stream_id.zero?; end
      def require_stream(frame); raise ProtocolError if frame.stream_id.zero?; end
      def require_size(frame, size); raise ProtocolError.new(code: 6) unless frame.payload.bytesize == size; end

      def send_frame(type, flags, stream_id, payload)
        @write_mutex.synchronize { write_frame(type, flags, stream_id, payload) }
      end

      def write_frame(type, flags, stream_id, payload)
        frame = Frame.new(type:, flags:, stream_id:, payload:)
        @reader.write(frame.encode, deadline: HTTP::Timing.now + @write_timeout)
      end
    end
  end
end
