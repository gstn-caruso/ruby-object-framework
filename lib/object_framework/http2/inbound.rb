# frozen_string_literal: true

module ObjectFramework
  module HTTP2
    class Inbound
      def initialize(cancellation:, on_consume: ->(_) {}, buffer_limit: 65_535)
        @cancellation, @on_consume, @limit = cancellation, on_consume, buffer_limit
        @mutex, @changed, @queue = Mutex.new, ConditionVariable.new, []
        @bytes, @finished, @discard = 0, false, false
      end

      def push(bytes)
        discarded = @mutex.synchronize do
          if @discard
            bytes.bytesize
          else
            raise ProtocolError.new("Inbound stream exceeds flow control", code: 3) if @bytes + bytes.bytesize > @limit
            @queue << bytes.b.freeze unless bytes.empty?
            @bytes += bytes.bytesize
            @changed.broadcast
            0
          end
        end
        @on_consume.call(discarded) if discarded.positive?
      end

      def finish
        @mutex.synchronize { @finished = true; @changed.broadcast }
      end

      def discard
        bytes = @mutex.synchronize do
          @discard, @finished = true, true
          discarded, @bytes = @bytes, 0
          @queue.clear
          @changed.broadcast
          discarded
        end
        @on_consume.call(bytes) if bytes.positive?
      end

      def cancel
        @cancellation.cancel
        @mutex.synchronize { @changed.broadcast }
      end

      def read_exact(count, allow_eof: false)
        result = +"".b
        while result.bytesize < count
          part = @mutex.synchronize do
            loop do
              @cancellation.check!
              unless @queue.empty?
                first = @queue.shift
                length = [count - result.bytesize, first.bytesize].min
                @queue.unshift(first.byteslice(length..)) if length < first.bytesize
                @bytes -= length
                break first.byteslice(0, length)
              end
              if @finished
                return nil if allow_eof && result.empty?
                raise InvalidInput, "Truncated gRPC message"
              end
              remaining = @cancellation.deadline ? @cancellation.deadline - HTTP::Timing.now : 0.1
              @changed.wait(@mutex, [[remaining, 0].max, 0.1].min)
            end
          end
          result << part
          @on_consume.call(part.bytesize)
        end
        result
      end
    end
  end
end
