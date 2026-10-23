# frozen_string_literal: true

module ObjectFramework
  Factory = Data.define(:dependencies, :build, :close)
  Operation = Data.define(:use_case, :policy, :dependencies)

  class Application
    attr_reader :errors, :reporter

    def initialize(storage: nil, errors: ErrorRegistry.new, reporter: nil)
      @storage, @errors = storage, errors
      @reporter = reporter || FailureReporter.new(registry: errors)
      @factories, @operations, @modules, @started_modules = {}, {}, {}, []
      @started, @finalized = false, false
    end

    def factory(name, dependencies: [], close: false, &build)
      mutable!
      raise ConfigurationError, "Factory #{name} already registered" if @factories.key?(name)
      raise ConfigurationError, "Factory requires a block" unless build
      @factories[name] = Factory.new(dependencies: dependencies.dup.freeze, build:, close:)
      self
    end

    def operation(name, use_case:, policy:, dependencies: [])
      mutable!
      raise ConfigurationError, "Operation #{name} already registered" if @operations.key?(name)
      raise ConfigurationError, "Unknown transaction policy" unless %i[none read write].include?(policy)
      @operations[name] = Operation.new(use_case:, policy:, dependencies: dependencies.dup.freeze)
      self
    end

    def install(mod)
      mutable!
      raise ConfigurationError, "Module #{mod.name} already registered" if @modules.key?(mod.name)
      @modules[mod.name] = mod
      self
    end

    def start
      raise ConfigurationError, "Application is already started" if @started
      unless @finalized
        modules = ordered_modules
        modules.each { |mod| mod.configure(self) }
        validate!
        @factories.freeze
        @operations.freeze
        @modules.freeze
        @errors.validate!
        @finalized = true
      end
      ordered_modules.each do |mod|
        mod.start
        @started_modules << mod
      end
      @started = true
      self
    rescue Exception
      stop
      raise
    end

    def stop
      error = nil
      @started_modules.reverse_each do |mod|
        mod.stop
      rescue StandardError => failure
        error ||= failure
      end
      @started_modules.clear
      @started = false
      raise error if error && !$!
      self
    end

    def invoke(name, context: ExecutionContext.new, **arguments)
      raise ConfigurationError, "Application is not started" unless @started
      operation = @operations.fetch(name) { raise ConfigurationError, "Unknown operation: #{name}" }
      Invocation.new(operation:, factories: @factories, storage: @storage, reporter: @reporter,
                     mappings: @mappings).call(context:, **arguments)
    end

    private

    def mutable!
      raise ConfigurationError, "Application registrations are finalized" if @finalized
    end

    def validate!
      @factories.each_key { |name| validate_dependency(name, []) }
      @operations.each_value do |operation|
        if operation.policy != :none && !@storage
          raise ConfigurationError, "Transactional operations require storage"
        end
        operation.dependencies.each do |name|
          if %i[transaction session].include?(name)
            raise ConfigurationError, "Storage dependency requires a transaction" if operation.policy == :none
            raise ConfigurationError, "Session requires mappings" if name == :session && !@mappings
          else
            validate_dependency(name, [])
          end
        end
      end
    end

    def validate_dependency(name, visiting)
      return if name == :context
      raise ConfigurationError, "Dependency cycle: #{(visiting + [name]).join(' -> ')}" if visiting.include?(name)
      factory = @factories.fetch(name) { raise ConfigurationError, "Unknown dependency: #{name}" }
      factory.dependencies.each { |dependency| validate_dependency(dependency, visiting + [name]) }
    end

    def ordered_modules
      result = []
      visit = lambda do |name, path|
        raise ConfigurationError, "Module dependency cycle" if path.include?(name)
        mod = @modules.fetch(name) { raise ConfigurationError, "Missing module: #{name}" }
        return if result.include?(mod)
        mod.requires.each { |dependency| visit.call(dependency, path + [name]) }
        result << mod
      end
      @modules.each_key { |name| visit.call(name, []) }
      result
    end
  end
end
