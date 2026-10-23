# frozen_string_literal: true

module ObjectFramework
  module Values
    def self.detach(value, visiting = {})
      composite = value.is_a?(Array) || value.is_a?(Hash) || value.is_a?(Data)
      if composite
        raise UnsafeResult, "Public values cannot contain cycles" if visiting.key?(value.object_id)
        visiting[value.object_id] = true
      end
      case value
      when nil, true, false, Symbol, Integer, Float then value
      when String then value.dup.freeze
      when Array then value.map { |item| detach(item, visiting) }.freeze
      when Hash then value.to_h { |key, item| [detach(key, visiting), detach(item, visiting)] }.freeze
      when Data then value.class.new(**detach(value.to_h, visiting))
      else raise UnsafeResult, "Public results must contain independent values (#{value.class})"
      end
    ensure
      visiting.delete(value.object_id) if composite
    end
  end

  class Cancellation
    def initialize(deadline: nil, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @deadline, @clock, @mutex, @cancelled = deadline, clock, Mutex.new, false
    end

    def cancel
      @mutex.synchronize { @cancelled = true }
    end

    def check!
      raise Cancelled, "Operation cancelled" if @mutex.synchronize { @cancelled }
      raise DeadlineExceeded, "Deadline exceeded" if @deadline && @clock.call >= @deadline
    end
  end

  class ExecutionContext
    attr_reader :operation_id, :cancellation
    attr_accessor :transaction_state

    def initialize(cancellation: Cancellation.new)
      @operation_id = SecureRandom.uuid.freeze
      @cancellation, @started_at = cancellation, monotonic
      @transaction_state, @failure_reported = :none, false
      @mutex = Mutex.new
    end

    def elapsed
      monotonic - @started_at
    end

    def claim_failure
      @mutex.synchronize do
        return false if @failure_reported
        @failure_reported = true
      end
    end

    private

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end

  class Scope
    def initialize(factories, context:)
      @factories, @context, @instances, @resources = factories, context, { context: }, []
    end

    def provide(name, instance)
      @instances[name] = instance
    end

    def resolve(name)
      return @instances.fetch(name) if @instances.key?(name)
      factory = @factories.fetch(name)
      arguments = factory.dependencies.to_h { |dependency| [dependency, resolve(dependency)] }
      instance = factory.build.call(**arguments)
      @resources << instance if factory.close
      @instances[name] = instance
    end

    def close(reporter:)
      @resources.reverse_each do |resource|
        resource.close
      rescue StandardError => error
        reporter.report(error, context: @context, secondary: true)
      end
      @resources.clear
      @instances.clear
    end
  end

  class Invocation
    def initialize(operation:, factories:, storage:, reporter:, mappings: nil)
      @operation, @factories, @storage, @reporter, @mappings = operation, factories, storage, reporter, mappings
    end

    def call(context: ExecutionContext.new, **arguments)
      scope = Scope.new(@factories, context:)
      transaction = session = nil
      begin
        context.cancellation.check!
        if @operation.policy != :none
          transaction = @storage.begin_transaction(mode: @operation.policy)
          context.transaction_state = :active
          scope.provide(:transaction, transaction)
          if @mappings
            session = Persistence::Session.new(transaction:, mappings: @mappings)
            scope.provide(:session, session)
          end
        end
        dependencies = @operation.dependencies.to_h { |name| [name, scope.resolve(name)] }
        use_case = @operation.use_case.new(**dependencies)
        result = Values.detach(use_case.call(**arguments))
        context.cancellation.check!
        session&.flush
        if transaction
          context.transaction_state = :committing
          transaction.commit
        end
        context.transaction_state = :committed if transaction
        result
      rescue StandardError => error
        rollback(transaction, context:)
        @reporter.report(error, context:)
        raise
      ensure
        # Also release resources when a non-StandardError unwinds the request thread.
        rollback(transaction, context:) if context.transaction_state == :active
        session&.close
        scope.close(reporter: @reporter)
        close_transaction(transaction, context:)
      end
    end

    private

    def rollback(transaction, context:)
      return unless transaction
      state = transaction.respond_to?(:state) ? transaction.state : context.transaction_state
      context.transaction_state = state == :committing ? :indeterminate : state
      return unless state == :active
      transaction.rollback
      context.transaction_state = :rolled_back
    rescue StandardError => error
      context.transaction_state = :indeterminate
      @reporter.report(error, context:, secondary: true)
    end

    def close_transaction(transaction, context:)
      transaction&.close
    rescue StandardError => error
      @reporter.report(error, context:, secondary: true)
    end
  end
end
