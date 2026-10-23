# frozen_string_literal: true

require "uri"
require "json"

module ObjectFramework
  module HTTP
    class Error < StandardError
      attr_reader :headers
      def initialize(message = nil, headers: {})
        super(message || self.class::TITLE)
        @headers = headers
      end
    end

    ERROR_TYPES = {
      BadRequest: [400, "Bad request"], MethodNotAllowed: [405, "Method not allowed"],
      RequestTimeout: [408, "Request timeout"], PayloadTooLarge: [413, "Payload too large"],
      URITooLong: [414, "Request target too long"], UnsupportedMediaType: [415, "Unsupported media type"],
      ExpectationFailed: [417, "Expectation failed"], HeadersTooLarge: [431, "Request headers too large"],
      NotImplemented: [501, "Transfer coding not implemented"], VersionNotSupported: [505, "HTTP version not supported"]
    }.freeze
    ERROR_TYPES.each do |name, (status, title)|
      type = Class.new(Error)
      type.const_set(:STATUS, status)
      type.const_set(:TITLE, title.freeze)
      const_set(name, type)
    end

    def self.register_errors(registry)
      ERROR_TYPES.each_key do |name|
        type = const_get(name)
        code = name.to_s.gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2').gsub(/([a-z])([A-Z])/, '\1_\2').downcase
        registry.register(type, category: :bad_request, code: "http_#{code}", title: type::TITLE)
      end
    end

    Head = Data.define(:method, :path, :query, :headers, :length, :chunked, :keep_alive)
    Input = Data.define(:params, :query, :body)

    class Parser
      TOKEN = /\A[!#$%&'*+.^_`|~0-9A-Za-z-]+\z/
      attr_reader :line_limit, :header_limit, :body_limit

      def initialize(line_limit: 8 * 1024, header_limit: 32 * 1024, body_limit: 1024 * 1024)
        @line_limit, @header_limit, @body_limit = line_limit, header_limit, body_limit
        raise ConfigurationError, "HTTP limits must be positive integers" unless [line_limit, header_limit, body_limit].all? { |limit| limit.is_a?(Integer) && limit.positive? }
      end

      def parse_head(raw)
        raise BadRequest unless raw.end_with?("\r\n\r\n")
        lines = raw.b.split("\r\n", -1)
        request_line = lines.shift
        raise URITooLong if request_line.bytesize > line_limit
        raise HeadersTooLarge if raw.bytesize - request_line.bytesize - 2 > header_limit
        method, target, version = request_line.split(" ", -1)
        raise BadRequest unless method && TOKEN.match?(method) && target && version && request_line == "#{method} #{target} #{version}"
        raise VersionNotSupported unless version == "HTTP/1.1"
        raise BadRequest if target.match?(/[\x00-\x20\x7f-\xff#]/n)
        headers = {}
        lines[0...-2].each do |line|
          name, value = parse_field(line)
          if headers.key?(name)
            raise BadRequest if %w[host content-length transfer-encoding].include?(name)
            headers[name] = "#{headers[name]}, #{value}"
          else
            headers[name] = value
          end
        end
        host = headers["host"]
        raise BadRequest unless host && /\A(?:\[[0-9a-fA-F:.]+\]|[A-Za-z0-9.-]+)(?::\d{1,5})?\z/.match?(host)
        raise BadRequest if headers.key?("content-length") && headers.key?("transfer-encoding")
        length = 0
        if headers.key?("content-length")
          raise BadRequest unless /\A[0-9]+\z/.match?(headers["content-length"])
          length = Integer(headers["content-length"], 10)
          raise PayloadTooLarge if length > body_limit
        end
        encoding = headers["transfer-encoding"]&.downcase
        if encoding && encoding != "chunked"
          raise BadRequest if encoding.split(",").map(&:strip).count("chunked") != 1 || !encoding.end_with?("chunked")
          raise NotImplemented
        end
        expect = headers["expect"]
        raise ExpectationFailed if expect && expect.downcase != "100-continue"
        path, query = parse_target(method, target)
        Head.new(method:, path:, query:, headers: Values.detach(headers), length:, chunked: encoding == "chunked",
                 keep_alive: !headers.fetch("connection", "").downcase.split(",").map(&:strip).include?("close"))
      end

      def parse_field(line)
        name, value = line.split(":", 2)
        raise BadRequest unless name && TOKEN.match?(name) && value && !value.match?(/[\x00-\x08\x0a-\x1f\x7f]/)
        [name.downcase, value.strip]
      end

      def read_body(reader, head, deadline:)
        return reader.read_exact(head.length, deadline:) unless head.chunked
        body, trailer_size = +"".b, 0
        loop do
          line = reader.read_line(limit: line_limit, deadline:)
          size, extension = line.split(";", 2)
          raise BadRequest unless /\A[0-9a-fA-F]+\z/.match?(size)
          if extension && !/\A(?:[!#$%&'*+.^_`|~0-9A-Za-z-]+(?:=(?:[!#$%&'*+.^_`|~0-9A-Za-z-]+|"(?:[^"\\\r\n]|\\[\x20-\x7e])*"))?)(?:;[!#$%&'*+.^_`|~0-9A-Za-z-]+(?:=(?:[!#$%&'*+.^_`|~0-9A-Za-z-]+|"(?:[^"\\\r\n]|\\[\x20-\x7e])*"))?)*\z/.match?(extension)
            raise BadRequest
          end
          count = Integer(size, 16)
          raise PayloadTooLarge if body.bytesize + count > body_limit
          if count.zero?
            loop do
              trailer = reader.read_line(limit: header_limit, deadline:)
              trailer_size += trailer.bytesize + 2
              raise HeadersTooLarge if trailer_size > header_limit
              break if trailer.empty?
              name, = parse_field(trailer)
              raise BadRequest if %w[content-length transfer-encoding host connection content-type authorization].include?(name)
            end
            return body
          end
          body << reader.read_exact(count, deadline:)
          raise BadRequest unless reader.read_exact(2, deadline:) == "\r\n"
        end
      end

      private

      def parse_target(method, target)
        return ["*", ""] if method == "OPTIONS" && target == "*"
        uri = URI.parse(target)
        if uri.absolute?
          raise BadRequest unless %w[http https].include?(uri.scheme) && uri.host && !uri.userinfo
          path = uri.path.empty? ? "/" : uri.path
        else
          raise BadRequest unless target.start_with?("/") && !target.start_with?("//")
          path = uri.path
        end
        raise BadRequest if target.match?(/%(?![0-9a-fA-F]{2})/)
        [path, uri.query || ""]
      rescue URI::InvalidURIError
        raise BadRequest
      end
    end

    class JSONDecoder
      def call(body, content_type: nil)
        return {} if body.empty?
        raise UnsupportedMediaType unless content_type&.split(";", 2)&.first&.strip&.downcase == "application/json"
        value = JSON.parse(body.dup.force_encoding(Encoding::UTF_8))
        raise InvalidInput, "Expected a JSON object" unless value.is_a?(Hash)
        value
      rescue JSON::ParserError, EncodingError
        raise BadRequest
      end
    end

    Parameter = Data.define(:name, :source, :key, :type, :required)

    class Parameters
      def initialize(&declaration)
        @fields = []
        instance_eval(&declaration) if declaration
        @fields.freeze
        freeze
      end

      def field(name, source: :body, key: name, type: String, required: true)
        raise ConfigurationError, "Invalid parameter source" unless %i[path query body].include?(source)
        raise ConfigurationError, "Duplicate parameter" if @fields.any? { |field| field.name == name }
        @fields << Parameter.new(name:, source:, key:, type:, required:)
      end

      def normalize(input)
        @fields.each_with_object({}) do |field, result|
          source = input.public_send(field.source == :path ? :params : field.source)
          key = field.source == :path ? field.key.to_sym : field.key.to_s
          unless source.key?(key)
            raise InvalidInput, "Missing required parameter" if field.required
            next
          end
          value = source.fetch(key)
          if field.source != :body
            value = Integer(value, 10) if field.type == Integer
            value = Float(value) if field.type == Float
          end
          raise InvalidInput, "Invalid parameter type" unless value.is_a?(field.type)
          result[field.name] = value
        end
      rescue ArgumentError, TypeError
        raise InvalidInput, "Invalid parameter value"
      end
    end

    class Controller
      def initialize(application:, operation:, parameters: Parameters.new)
        @application, @operation, @parameters = application, operation, parameters
      end

      def call(input, context:)
        @application.invoke(@operation, context:, **@parameters.normalize(input))
      end
    end
  end
end
