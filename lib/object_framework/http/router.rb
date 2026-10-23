# frozen_string_literal: true

module ObjectFramework
  module HTTP
    Route = Data.define(:method, :pattern, :controller, :expression, :names)
    Match = Data.define(:controller, :params, :allow)

    class Router
      def initialize
        @controllers, @routes = {}, []
      end

      def controller(name, instance)
        mutable!
        raise ConfigurationError, "Duplicate controller: #{name}" if @controllers.key?(name)
        @controllers[name] = instance
        self
      end

      def route(method, pattern, controller:)
        mutable!
        method = method.to_s.upcase
        raise ConfigurationError, "Invalid route" unless Parser::TOKEN.match?(method) && pattern.start_with?("/") && !pattern.include?("?")
        names = []
        expression = pattern.split("/", -1).map do |part|
          if part.start_with?(":")
            name = Persistence::Query.identifier(part.delete_prefix(":"))
            raise ConfigurationError, "Duplicate route parameter" if names.include?(name)
            names << name
            "([^/]+)"
          else
            Regexp.escape(part)
          end
        end.join("/")
        raise ConfigurationError, "Duplicate route" if @routes.any? { |route| route.method == method && route.expression.source == "\\A#{expression}\\z" }
        @routes << Route.new(method:, pattern: pattern.dup.freeze, controller:, expression: /\A#{expression}\z/, names: names.freeze)
        self
      end

      def validate!
        @routes.each do |route|
          controller = @controllers.fetch(route.controller) { raise ConfigurationError, "Unknown route controller" }
          raise ConfigurationError, "Controller must implement call" unless controller.respond_to?(:call)
        end
        @controllers.freeze
        @routes.sort_by! { |route| route.names.size } unless @routes.frozen?
        @routes.freeze
        self
      end

      def resolve(method, path)
        matching = path == "*" ? @routes : @routes.select { |route| route.expression.match?(path) }
        raise NotFound, "Route not found" if matching.empty?
        allow = (matching.map(&:method) + ["OPTIONS"]).uniq
        allow << "HEAD" if allow.include?("GET")
        allow.sort!
        return Match.new(controller: nil, params: {}, allow:) if method == "OPTIONS"
        route = matching.find { |candidate| candidate.method == method }
        route ||= matching.find { |candidate| candidate.method == "GET" } if method == "HEAD"
        raise MethodNotAllowed.new(headers: { "Allow" => allow.join(", ") }) unless route
        captures = route.expression.match(path).captures
        params = route.names.zip(captures).to_h.transform_values do |value|
          decoded = URI.decode_www_form_component(value.gsub("+", "%2B"))
          raise BadRequest unless decoded.valid_encoding? && !decoded.match?(/[\x00-\x1f\x7f]/)
          decoded
        end
        Match.new(controller: @controllers.fetch(route.controller), params:, allow:)
      rescue ArgumentError
        raise BadRequest
      end

      private

      def mutable!
        raise ConfigurationError, "Router is finalized" if @routes.frozen?
      end
    end
  end
end
