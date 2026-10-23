# frozen_string_literal: true

module ObjectFramework
  module HTTP
    Response = Data.define(:status, :headers, :body)

    class JSONPresenter
      def call(value)
        Response.new(status: 200, headers: { "Content-Type" => "application/json" }, body: JSON.generate(json_value(value)))
      end

      private

      def json_value(value)
        case value
        when Data then json_value(value.to_h)
        when Hash then value.to_h { |key, item| [key, json_value(item)] }
        when Array then value.map { |item| json_value(item) }
        else value
        end
      end
    end

    class ProblemPresenter
      STATUSES = {
        bad_request: 400, invalid_input: 422, unauthenticated: 401, forbidden: 403,
        not_found: 404, conflict: 409, duplicate: 409, transaction_conflict: 409,
        rate_limited: 429, capacity: 503, unavailable: 503, deadline: 503,
        cancelled: 503, internal: 500
      }.freeze

      def initialize(registry:)
        @registry = registry
      end

      def call(exception, context:)
        description = @registry.resolve(exception)
        status = exception.is_a?(Error) ? exception.class::STATUS : STATUSES.fetch(description.category)
        problem = description.details.transform_keys(&:to_s).merge(
          "type" => "urn:object-framework:error:#{description.code}", "title" => description.title,
          "status" => status, "instance" => "urn:uuid:#{context.operation_id}",
          "code" => description.code, "operation_id" => context.operation_id
        )
        headers = { "Content-Type" => "application/problem+json" }
        headers.merge!(exception.headers) if exception.is_a?(Error)
        Response.new(status:, headers:, body: JSON.generate(problem))
      end

      def self.fallback(context:)
        body = '{"type":"urn:object-framework:error:internal_error","title":"Internal server error","status":500,"code":"internal_error","operation_id":"' + context.operation_id + '","instance":"urn:uuid:' + context.operation_id + '"}'
        Response.new(status: 500, headers: { "Content-Type" => "application/problem+json" }, body:)
      end
    end
  end
end
