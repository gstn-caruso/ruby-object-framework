# frozen_string_literal: true

module ObjectFramework
  module GRPC
    class Controller
      def initialize(application:, operation:)
        @application, @operation = application, operation
      end

      def call(input, context:)
        @application.invoke(@operation, context:, **input)
      end

      def validate!
        @application.validate_operation!(@operation)
      end
    end

    class StatusPresenter
      STATUSES = { bad_request: 3, invalid_input: 3, unauthenticated: 16, forbidden: 7,
        not_found: 5, conflict: 9, duplicate: 6, transaction_conflict: 10,
        rate_limited: 8, capacity: 8, unavailable: 14, deadline: 4, cancelled: 1,
        unimplemented: 12, internal: 13 }.freeze

      def initialize(registry:); @registry = registry; end

      def call(error)
        description = @registry.resolve(error)
        [STATUSES.fetch(description.category), description.code, description.title]
      end
    end

    class Call
      def initialize(connection:, stream:, descriptor:, message_limit:)
        @connection, @stream, @descriptor, @limit = connection, stream, descriptor, message_limit
        @started = false
      end

      def send(value)
        @stream.context.cancellation.check!
        payload = @descriptor.encode(value)
        raise CapacityExceeded, "Message exceeds configured limit" if payload.bytesize > @limit
        unless @started
          @connection.send_headers(@stream, initial_headers)
          @started = true
        end
        @connection.send_data(@stream, Messages.frame(payload))
      end

      def finish(status: 0, code: "ok", message: "")
        return if @connection.reset?(@stream)
        trailers = [["grpc-status", status.to_s], ["error-code", code], ["operation-id", @stream.context.operation_id]]
        trailers << ["grpc-message", escape(message)] unless message.empty?
        trailers = initial_headers + trailers unless @started
        @connection.send_headers(@stream, trailers, end_stream: true)
      end

      private

      def initial_headers
        [[":status", "200"], ["content-type", "application/grpc"], ["grpc-accept-encoding", "identity"], ["operation-id", @stream.context.operation_id]]
      end

      def escape(value)
        value.b.bytes.map { |byte| byte.between?(32, 126) && byte != 37 ? byte.chr : format("%%%02X", byte) }.join
      end
    end

    class Server
      attr_reader :name, :port

      def initialize(application:, services:, controllers:, host: "127.0.0.1", port: 0,
                     name: :grpc, max_requests: 128, max_connections: 128,
                     message_limit: 1024 * 1024, header_limit: 32 * 1024,
                     execution_timeout: 30, idle_timeout: 30, shutdown_timeout: 5,
                     tls_context: nil, status_presenter: nil)
        @application, @services, @controllers, @host, @port, @name = application, services.dup, controllers.dup, host, port, name
        @max_requests, @max_connections, @message_limit, @header_limit = max_requests, max_connections, message_limit, header_limit
        @execution_timeout, @idle_timeout, @shutdown_timeout, @tls_context = execution_timeout, idle_timeout, shutdown_timeout, tls_context
        @presenter = status_presenter || StatusPresenter.new(registry: application.errors)
        @mutex, @workers, @connections, @routes = Mutex.new, {}, {}.compare_by_identity, {}
      end

      def requires; []; end

      def configure(application)
        application.errors.register(Unimplemented, category: :unimplemented, code: "rpc_unimplemented", title: "RPC method not implemented")
        application.errors.register(HTTP2::ProtocolError, category: :bad_request, code: "http2_protocol_error", title: "Invalid HTTP/2 request")
        application.errors.register(HTTP2::CompressionError, category: :bad_request, code: "hpack_error", title: "Invalid compressed headers")
      end

      def validate!
        unless [@max_requests, @max_connections, @message_limit, @header_limit].all? { |value| value.is_a?(Integer) && value.positive? }
          raise ConfigurationError, "gRPC limits must be positive integers"
        end
        unless [@execution_timeout, @idle_timeout, @shutdown_timeout].all? { |value| value.is_a?(Numeric) && value.positive? }
          raise ConfigurationError, "gRPC timeouts must be positive"
        end
        @services.each do |service|
          service.methods.each_value do |method|
            controller = @controllers.fetch(method.controller) { raise ConfigurationError, "Missing RPC controller" }
            raise ConfigurationError, "RPC controllers must implement call" unless controller.respond_to?(:call)
            controller.validate! if controller.respond_to?(:validate!)
            path = "/#{service.name}/#{method.name}"
            raise ConfigurationError, "Duplicate RPC route" if @routes.key?(path)
            @routes[path] = method
          end
          service.finalize!
        end
        @routes.freeze
        @controllers.freeze
        @services.freeze
        if @tls_context
          raise ConfigurationError, "TLS requires a certificate and private key" unless @tls_context.cert && @tls_context.key
          @tls_context.alpn_select_cb = ->(protocols) { protocols.include?("h2") ? "h2" : raise(HTTP2::ProtocolError, "h2 required") }
          @tls_context.setup
        end
      end

      def start
        @listener = TCPServer.new(@host, @port)
        @port = @listener.local_address.ip_port
        @wake_reader, @wake_writer = IO.pipe
        @running = true
        @acceptor = Thread.new { accept_connections }
        self
      end

      def active_count; @mutex.synchronize { @workers.size }; end

      def stop
        return unless @acceptor
        @running = false
        @wake_writer.write_nonblock(".", exception: false)
        @acceptor.join
        connections, workers = @mutex.synchronize do
          @workers.each_value { |stream| stream.context.cancellation.cancel }
          [@connections.to_a, @workers.keys]
        end
        connections.each { |connection, _| connection.close }
        deadline = HTTP::Timing.now + @shutdown_timeout
        (workers + connections.map(&:last)).each { |thread| thread.join([deadline - HTTP::Timing.now, 0].max) }
        @listener.close
        @wake_reader.close
        @wake_writer.close
        @acceptor = nil
      end

      private

      def accept_connections
        while @running
          readable = IO.select([@listener, @wake_reader])&.first
          break if !@running || readable.include?(@wake_reader)
          loop do
            socket = @listener.accept_nonblock(exception: false)
            break if socket == :wait_readable
            @mutex.synchronize do
              if @connections.size >= @max_connections
                socket.close
                next
              end
              io = @tls_context ? OpenSSL::SSL::SSLSocket.new(socket, @tls_context) : socket
              io.sync_close = true if @tls_context
              connection = HTTP2::Connection.new(io:, on_stream: method(:admit), reporter: @application.reporter,
                stream_limit: @max_requests, header_limit: @header_limit, idle_timeout: @idle_timeout, tls: !!@tls_context)
              thread = Thread.new do
                begin
                  connection.run
                ensure
                  @mutex.synchronize { @connections.delete(connection) }
                end
              end
              @connections[connection] = thread
            end
          end
        end
      end

      def admit(connection, stream, headers)
        metadata = headers.to_h
        context = stream.context
        set_deadline(context, metadata["grpc-timeout"])
        unless metadata[":method"] == "POST" && metadata.fetch("content-type", "").match?(/\Aapplication\/grpc(?:\+proto)?(?:;.*)?\z/)
          connection.send_headers(stream, [[":status", "415"]], end_stream: true)
          return
        end
        method = @routes[metadata[":path"]]
        unless method
          fail_call(connection, stream, Unimplemented.new)
          return
        end
        admitted = @mutex.synchronize do
          if @workers.size >= @max_requests
            false
          else
            thread = Thread.new { perform(connection, stream, method) }
            @workers[thread] = stream
            true
          end
        end
        fail_call(connection, stream, CapacityExceeded.new) unless admitted
      rescue StandardError => error
        fail_call(connection, stream, error)
      end

      def perform(connection, stream, method)
        call = Call.new(connection:, stream:, descriptor: method.output, message_limit: @message_limit)
        messages = Messages.new(input: stream.input, descriptor: method.input, message_limit: @message_limit)
        begin
          input = method.client_streaming ? messages : single_message(messages)
          result = @controllers.fetch(method.controller).call(input, context: stream.context)
          if method.server_streaming
            result.each { |value| call.send(value) }
          else
            call.send(result)
          end
          call.finish
        rescue StandardError => error
          fail_call(connection, stream, error, call:)
        ensure
          @mutex.synchronize { @workers.delete(Thread.current) }
        end
      end

      def single_message(messages)
        value = nil
        count = 0
        messages.each do |message|
          count += 1
          raise InvalidInput, "Unary RPC requires exactly one message" if count > 1
          value = message
        end
        raise InvalidInput, "Unary RPC requires exactly one message" unless count == 1
        value
      end

      def fail_call(connection, stream, error, call: nil)
        @application.reporter.report(error, context: stream.context)
        begin
          status, code, message = @presenter.call(error)
        rescue StandardError => secondary
          @application.reporter.report(secondary, context: stream.context, secondary: true)
          status, code, message = 13, "internal_error", "Internal server error"
        end
        call ||= Call.new(connection:, stream:, descriptor: nil, message_limit: @message_limit)
        call.finish(status:, code:, message:)
      rescue StandardError => secondary
        @application.reporter.report(secondary, context: stream.context, secondary: true)
      end

      def set_deadline(context, value)
        timeout = @execution_timeout
        if value
          match = /\A([0-9]{1,8})([HMSmun])\z/.match(value)
          raise InvalidInput, "Invalid gRPC timeout" unless match
          units = { "H" => 3600, "M" => 60, "S" => 1, "m" => 0.001, "u" => 0.000001, "n" => 0.000000001 }
          timeout = [timeout, Integer(match[1], 10) * units.fetch(match[2])].min
        end
        context.cancellation.deadline = HTTP::Timing.now + timeout
      end
    end
  end
end
