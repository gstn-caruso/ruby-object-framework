# frozen_string_literal: true

module ObjectFramework
  class ConfigurationError < StandardError; end
  class InvalidInput < StandardError; end
  class NotFound < StandardError; end
  class Conflict < StandardError; end
  class Duplicate < StandardError; end
  class Unavailable < StandardError; end
  class CapacityExceeded < StandardError; end
  class DeadlineExceeded < StandardError; end
  class Cancelled < StandardError; end
  class ClosedSession < StandardError; end
  class UnsafeResult < StandardError; end

  ErrorDescription = Data.define(:category, :code, :title, :details)

  class ErrorRegistry
    CATEGORIES = %i[bad_request invalid_input unauthenticated forbidden not_found conflict
                    duplicate transaction_conflict rate_limited capacity unavailable
                    deadline cancelled unimplemented internal].freeze
    DEFAULTS = {
      InvalidInput => [:invalid_input, "invalid_input", "Invalid input"],
      NotFound => [:not_found, "not_found", "Resource not found"],
      Conflict => [:transaction_conflict, "transaction_conflict", "Transaction conflict"],
      Duplicate => [:duplicate, "duplicate", "Resource already exists"],
      Unavailable => [:unavailable, "unavailable", "Storage unavailable"],
      CapacityExceeded => [:capacity, "capacity_exceeded", "Capacity exhausted"],
      DeadlineExceeded => [:deadline, "deadline_exceeded", "Deadline exceeded"],
      Cancelled => [:cancelled, "cancelled", "Operation cancelled"]
    }.freeze

    def initialize
      @registrations = {}
      DEFAULTS.each { |type, (category, code, title)| register(type, category:, code:, title:) }
    end

    def register(type, category:, code:, title:, details: ->(_) { {} })
      raise ConfigurationError, "Error registry is finalized" if @registrations.frozen?
      raise ConfigurationError, "Expected an exception class" unless type.is_a?(Class) && type <= StandardError
      raise ConfigurationError, "Duplicate error registration: #{type}" if @registrations.key?(type)
      raise ConfigurationError, "Unknown error category: #{category}" unless CATEGORIES.include?(category)
      raise ConfigurationError, "A stable code and title are required" if code.to_s.empty? || title.to_s.empty?
      @registrations[type] = [category, code.to_s.dup.freeze, title.to_s.dup.freeze, details].freeze
      self
    end

    def validate!
      codes = @registrations.values.map { |registration| registration[1] }
      raise ConfigurationError, "Ambiguous public error codes" unless codes.uniq.size == codes.size
      @registrations.freeze
      self
    end

    def resolve(exception)
      type = exception.class.ancestors.find { |ancestor| @registrations.key?(ancestor) }
      return ErrorDescription.new(category: :internal, code: "internal_error", title: "Internal server error", details: {}) unless type

      category, code, title, details = @registrations.fetch(type)
      ErrorDescription.new(category:, code:, title:, details: Values.detach(details.call(exception)))
    end
  end

  class FailureReporter
    def initialize(sink: ->(record) {}, registry: ErrorRegistry.new)
      @sink, @registry = sink, registry
    end

    def report(exception, context:, secondary: false)
      return if !secondary && !context.claim_failure

      # Messages and argument values are deliberately absent: they can contain secrets.
      record = {
        operation_id: context.operation_id, code: @registry.resolve(exception).code,
        exception: exception.class.name, cause: exception.cause&.class&.name,
        backtrace: exception.backtrace&.dup, duration: context.elapsed,
        transaction_state: context.transaction_state, secondary:
      }
      @sink.call(Values.detach(record))
    rescue StandardError
      # Diagnostics must never replace the exception being reported.
      nil
    end
  end
end
