# frozen_string_literal: true

require "socket"
require "openssl"

module ObjectFramework
  module HTTP
    Connection = Struct.new(:io, :buffer, :fiber, :context, keyword_init: true) do
      def close
        io.close unless io.closed?
      rescue IOError, SystemCallError
        nil
      end
    end

    # Application lifecycle module serving HTTP/1.1 on a dispatcher and one new
    # thread per admitted request. Keep-alive requests execute sequentially.
    # Install with Application#install before startup; the application owns
    # listener startup, cooperative shutdown, and controller validation.
    class Server
      attr_reader :port, :name

      # Configures admission limits and timeouts in seconds. +port+ zero lets
      # the OS assign a port, available through #port after startup.
      # +tls_context+ is an optional OpenSSL context with application-provided
      # certificate and private key. Execution cancellation is cooperative.
      def initialize(application:, router:, host: "127.0.0.1", port: 0, name: :http,
                     parser: Parser.new, presenter: JSONPresenter.new, problem_presenter: nil,
                     max_requests: 128, max_connections: 1024, header_timeout: 10,
                     body_timeout: 30, execution_timeout: 30, idle_timeout: 30,
                     write_timeout: 30, shutdown_timeout: 5, tls_context: nil,
                     writer_factory: ->(reader) { Writer.new(reader:) })
        @application, @router, @host, @port, @name = application, router, host, port, name
        @parser, @presenter, @problem_presenter = parser, presenter, problem_presenter
        @max_requests, @max_connections = max_requests, max_connections
        @header_timeout, @body_timeout, @execution_timeout = header_timeout, body_timeout, execution_timeout
        @idle_timeout, @write_timeout, @shutdown_timeout = idle_timeout, write_timeout, shutdown_timeout
        @tls_context, @writer_factory = tls_context, writer_factory
        @mutex, @workers, @admitted_count = Mutex.new, {}, 0
        @completed = Queue.new
        @connections, @waiting = {}.compare_by_identity, {}.compare_by_identity
      end

      def requires; []; end

      def configure(application)
        HTTP.register_errors(application.errors)
        @problem_presenter ||= ProblemPresenter.new(registry: application.errors)
      end

      def validate!
        @router.validate!
        unless [@max_requests, @max_connections].all? { |value| value.is_a?(Integer) && value.positive? }
          raise ConfigurationError, "Admission limits must be positive integers"
        end
        unless [@header_timeout, @body_timeout, @execution_timeout, @idle_timeout, @write_timeout, @shutdown_timeout].all? { |value| value.is_a?(Numeric) && value.positive? }
          raise ConfigurationError, "HTTP timeouts must be positive"
        end
        if @tls_context
          raise ConfigurationError, "TLS requires an application certificate and private key" unless @tls_context.cert && @tls_context.key
          @tls_context.setup
        end
      end

      def start
        @listener = TCPServer.new(@host, @port)
        @port = @listener.local_address.ip_port
        @wake_reader, @wake_writer = IO.pipe
        @running = true
        @dispatcher = Thread.new { dispatch }
        self
      rescue Exception
        @listener&.close
        @wake_reader&.close
        @wake_writer&.close
        raise
      end

      def active_count; @mutex.synchronize { @workers.size }; end
      def admitted_count; @mutex.synchronize { @admitted_count }; end
      def connection_count; @connections.size; end

      def stop
        return unless @dispatcher
        @running = false
        wake
        @dispatcher.join
        workers = @mutex.synchronize do
          @workers.each_value { |context, connection| context.cancellation.cancel; connection.close }
          @workers.keys
        end
        deadline = Timing.now + @shutdown_timeout
        workers.each { |thread| thread.join([deadline - Timing.now, 0].max) }
        @wake_reader.close
        @wake_writer.close
        @dispatcher = nil
      end

      private

      def dispatch
        while @running
          complete_requests
          now = Timing.now
          @waiting.dup.each { |connection, (_, deadline)| resume_connection(connection) if deadline <= now }
          reads = [@listener, @wake_reader] + @waiting.select { |_, (mode, _)| mode == :read }.keys.map(&:io)
          writes = @waiting.select { |_, (mode, _)| mode == :write }.keys.map(&:io)
          deadline = @waiting.values.map(&:last).min
          timeout = deadline ? [[deadline - Timing.now, 0].max, 0.5].min : 0.5
          readable, writable = IO.select(reads, writes, nil, timeout)
          next unless readable
          drain_wake if readable.delete(@wake_reader)
          accept_connections if readable.delete(@listener)
          ready = readable + writable
          @waiting.keys.each { |connection| resume_connection(connection) if ready.include?(connection.io) }
        end
      ensure
        @connections.each_key(&:close)
        @connections.clear
        @waiting.clear
        @listener.close unless @listener.closed?
      end

      def accept_connections
        loop do
          socket = @listener.accept_nonblock(exception: false)
          break if socket == :wait_readable
          if @connections.size >= @max_connections
            socket.close
            next
          end
          io = @tls_context ? OpenSSL::SSL::SSLSocket.new(socket, @tls_context) : socket
          io.sync_close = true if @tls_context
          connection = Connection.new(io:, buffer: +"".b, context: ExecutionContext.new)
          @connections[connection] = true
          connection.fiber = connection_fiber(connection)
          resume_connection(connection)
        end
      end

      def connection_fiber(connection)
        Fiber.new do
          reader = Reader.new(io: connection.io, buffer: connection.buffer,
            waiter: ->(mode, deadline) { Fiber.yield([mode, deadline]) })
          begin
            handshake(connection, reader) if @tls_context
            idle = false
            loop do
              connection.context = ExecutionContext.new
              head = reader.read_head(@parser, header_timeout: @header_timeout, idle_timeout: @idle_timeout, idle:)
              raise CapacityExceeded if Fiber.yield([:request, head]) == :rejected
              idle = true
            end
          rescue EOFError
            nil
          rescue StandardError => error
            @application.reporter.report(error, context: connection.context)
            response = problem(error, context: connection.context)
            Writer.new(reader:).call(response, keep_alive: false, deadline: Timing.now + @write_timeout)
          end
          nil
        end
      end

      def handshake(connection, reader)
        deadline = Timing.now + @header_timeout
        loop do
          raise RequestTimeout if Timing.now >= deadline
          result = connection.io.accept_nonblock(exception: false)
          break unless %i[wait_readable wait_writable].include?(result)
          reader.waiter.call(result == :wait_readable ? :read : :write, deadline)
        end
      end

      def resume_connection(connection, value = nil)
        @waiting.delete(connection)
        result = connection.fiber.resume(value)
        if result && result.first == :request
          resume_connection(connection, :rejected) unless admit(connection, result.last)
        elsif result
          @waiting[connection] = result
        else
          forget(connection)
        end
      rescue StandardError => error
        @application.reporter.report(error, context: connection.context)
        forget(connection)
      end

      def admit(connection, head)
        @mutex.synchronize do
          return false if @workers.size >= @max_requests
          @admitted_count += 1
          thread = Thread.new { serve(connection, head) }
          @workers[thread] = [connection.context, connection]
        end
        true
      end

      def serve(connection, head)
        context = connection.context
        reader = Reader.new(io: connection.io, buffer: connection.buffer)
        writer = nil
        keep_alive, body_read = false, false
        begin
          writer = @writer_factory.call(reader)
          reader.write("HTTP/1.1 100 Continue\r\n\r\n", deadline: Timing.now + @write_timeout) if head.headers["expect"]
          body = @parser.read_body(reader, head, deadline: Timing.now + @body_timeout)
          body_read = true
          context.cancellation.deadline = Timing.now + @execution_timeout
          context.cancellation.check!
          match = @router.resolve(head.method, head.path)
          if head.method == "OPTIONS"
            response = Response.new(status: 204, headers: { "Allow" => match.allow.join(", ") }, body: "")
          else
            input = Input.new(params: match.params, query: query_parameters(head.query),
              body: JSONDecoder.new.call(body, content_type: head.headers["content-type"]))
            result = match.controller.call(input, context:)
            context.cancellation.check!
            response = @presenter.call(result)
          end
          writer.call(response, head: head.method == "HEAD", keep_alive: head.keep_alive, deadline: Timing.now + @write_timeout)
          keep_alive = head.keep_alive
        rescue StandardError => error
          @application.reporter.report(error, context:)
          writer ||= Writer.new(reader:)
          unless writer.started
            begin
              writer.call(problem(error, context:), head: head.method == "HEAD", keep_alive: body_read && head.keep_alive, deadline: Timing.now + @write_timeout)
              keep_alive = body_read && head.keep_alive
            rescue StandardError => secondary
              @application.reporter.report(secondary, context:, secondary: true)
              keep_alive = false
            end
          end
        ensure
          @mutex.synchronize { @workers.delete(Thread.current) }
          reuse = keep_alive && @running
          connection.close unless reuse
          @completed << [reuse ? :reuse : :close, connection]
          wake
        end
      end

      def query_parameters(query)
        URI.decode_www_form(query).each_with_object({}) do |(key, value), result|
          result[key] = result.key?(key) ? Array(result[key]) + [value] : value
        end
      rescue ArgumentError
        raise BadRequest
      end

      def problem(error, context:)
        @problem_presenter.call(error, context:)
      rescue StandardError => secondary
        @application.reporter.report(secondary, context:, secondary: true)
        ProblemPresenter.fallback(context:)
      end

      def complete_requests
        until @completed.empty?
          action, connection = @completed.pop
          action == :reuse && @running ? resume_connection(connection) : forget(connection)
        end
      end

      def forget(connection)
        @waiting.delete(connection)
        @connections.delete(connection)
        connection.close
      end

      def wake
        @wake_writer&.write_nonblock(".", exception: false)
      rescue IOError, SystemCallError
        nil
      end

      def drain_wake
        loop do
          result = @wake_reader.read_nonblock(1024, exception: false)
          break if result == :wait_readable || result.nil?
        end
      end
    end
  end
end
