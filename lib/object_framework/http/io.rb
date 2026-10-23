# frozen_string_literal: true

require "time"

module ObjectFramework
  module HTTP
    module Timing
      def self.now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def self.wait(io, mode, deadline)
        remaining = deadline - now
        raise RequestTimeout if remaining <= 0
        readable, writable = mode == :read ? [[io], nil] : [nil, [io]]
        raise RequestTimeout unless IO.select(readable, writable, nil, remaining)
      end
    end

    class Reader
      attr_reader :io, :buffer, :waiter

      def initialize(io:, buffer: +"".b, waiter: nil)
        @io, @buffer = io, buffer
        @waiter = waiter || ->(mode, deadline) { Timing.wait(io, mode, deadline) }
      end

      def read_head(parser, header_timeout:, idle_timeout:, idle: false)
        started = !idle || !buffer.empty?
        deadline = Timing.now + (started ? header_timeout : idle_timeout)
        loop do
          first_line = buffer.index("\r\n")
          raise URITooLong if (first_line || buffer.bytesize) > parser.line_limit
          if (finish = buffer.index("\r\n\r\n"))
            return parser.parse_head(buffer.slice!(0, finish + 4))
          end
          raise HeadersTooLarge if first_line && buffer.bytesize - first_line - 2 > parser.header_limit
          buffer << read_chunk(deadline:)
          unless started
            started, deadline = true, Timing.now + header_timeout
          end
        end
      rescue RequestTimeout
        raise EOFError if idle && !started
        raise
      rescue EOFError
        raise BadRequest unless buffer.empty?
        raise
      end

      def read_exact(count, deadline:)
        buffer << read_chunk(deadline:) while buffer.bytesize < count
        buffer.slice!(0, count)
      end

      def read_line(limit:, deadline:)
        loop do
          if (finish = buffer.index("\r\n"))
            raise HeadersTooLarge if finish > limit
            return buffer.slice!(0, finish + 2).delete_suffix("\r\n")
          end
          raise HeadersTooLarge if buffer.bytesize > limit
          buffer << read_chunk(deadline:)
        end
      end

      def write(bytes, deadline:)
        offset = 0
        while offset < bytes.bytesize
          raise RequestTimeout if Timing.now >= deadline
          result = io.write_nonblock(bytes.byteslice(offset..), exception: false)
          case result
          when :wait_readable then waiter.call(:read, deadline)
          when :wait_writable then waiter.call(:write, deadline)
          else
            offset += result
            yield result if block_given?
          end
        end
      end

      private

      def read_chunk(deadline:)
        loop do
          raise RequestTimeout if Timing.now >= deadline
          result = io.read_nonblock(16_384, exception: false)
          case result
          when :wait_readable then waiter.call(:read, deadline)
          when :wait_writable then waiter.call(:write, deadline)
          when nil then raise EOFError
          else return result
          end
        end
      end
    end

    class Writer
      REASONS = { 200 => "OK", 204 => "No Content", 400 => "Bad Request", 401 => "Unauthorized",
        403 => "Forbidden", 404 => "Not Found", 405 => "Method Not Allowed", 408 => "Request Timeout",
        409 => "Conflict", 413 => "Content Too Large", 414 => "URI Too Long", 415 => "Unsupported Media Type",
        417 => "Expectation Failed", 422 => "Unprocessable Content", 429 => "Too Many Requests",
        431 => "Request Header Fields Too Large", 500 => "Internal Server Error", 501 => "Not Implemented",
        503 => "Service Unavailable", 505 => "HTTP Version Not Supported" }.freeze
      attr_reader :started

      def initialize(reader:)
        @reader, @started = reader, false
      end

      def call(response, head: false, keep_alive: true, deadline:)
        status, body = response.status, response.body
        raise InvalidInput, "Invalid response status" unless status.is_a?(Integer) && status.between?(200, 599)
        headers = response.headers.reject { |name, _| %w[date connection content-length].include?(name.downcase) }
        headers = headers.merge("Date" => Time.now.httpdate, "Connection" => keep_alive ? "keep-alive" : "close")
        headers["Content-Length"] = body.bytesize.to_s unless [204, 304].include?(status)
        headers.each do |name, value|
          raise InvalidInput, "Invalid response header" unless Parser::TOKEN.match?(name) && !value.to_s.match?(/[\x00-\x1f\x7f]/)
          raise InvalidInput, "Response transfer encodings are not supported" if name.downcase == "transfer-encoding"
        end
        prefix = "HTTP/1.1 #{status} #{REASONS.fetch(status, 'Response')}\r\n" + headers.map { |key, value| "#{key}: #{value}\r\n" }.join + "\r\n"
        bytes = head || [204, 304].include?(status) ? prefix : prefix + body
        @reader.write(bytes, deadline:) { @started = true }
      end
    end
  end
end
