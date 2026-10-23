# frozen_string_literal: true

module ObjectFramework
  Factory = Data.define(:dependencies, :build, :close)
  Operation = Data.define(:use_case, :policy, :dependencies)

  # Composes use cases, scoped collaborators, and lifecycle modules.
  # Registrations belong to this instance and become immutable at #start.
  #
  #   app = ObjectFramework::Application.new
  #   app.factory(:greeting) { "Hello" }
  #   app.operation(:greet, use_case: Greet, policy: :none, dependencies: [:greeting])
  #   app.start
  #   begin
  #     app.invoke(:greet, name: "Ada")
  #   ensure
  #     app.stop
  #   end
  class Application
    attr_reader :errors, :reporter

    # Creates an independent composition root. Transactional operations need
    # +storage+; the reserved +session+ dependency also needs +mappings+.
    def initialize(storage: nil, mappings: nil, errors: ErrorRegistry.new, reporter: nil)
      @storage, @mappings, @errors = storage, mappings, errors
      @reporter = reporter || FailureReporter.new(registry: errors)
      @factories, @operations, @modules, @started_modules = {}, {}, {}, []
      @started, @finalized = false, false
    end

    # Registers an invocation-scoped collaborator, constructed lazily once per
    # invocation. The block receives its declared dependencies as keywords.
    # With <tt>close: true</tt>, cleanup calls the collaborator's +close+ in
    # reverse construction order, including when the operation fails.
    # +context+, +session+, and +transaction+ are reserved names. Returns +self+.
    def factory(name, dependencies: [], close: false, &build)
      mutable!
      raise ConfigurationError, "Reserved execution dependency: #{name}" if %i[context session transaction].include?(name)
      raise ConfigurationError, "Factory #{name} already registered" if @factories.key?(name)
      raise ConfigurationError, "Factory requires a block" unless build
      @factories[name] = Factory.new(dependencies: dependencies.dup.freeze, build:, close:)
      self
    end

    # Registers an invocation-scoped bean from a Ruby class or a block.
    # Required constructor/block keywords name its dependencies unless an
    # explicit +dependencies+ list is supplied. Optional keywords keep their
    # defaults. Beans are lazy, shared only within one invocation, and released
    # with that invocation when <tt>close: true</tt>. Returns +self+.
    #
    #   app.bean(:orders, Orders)
    #   app.bean(:client, close: true) { |context:| Client.new(context:) }
    def bean(name, type = nil, dependencies: nil, close: false, &build)
      raise ConfigurationError, "A bean accepts either a class or a block" if type && build
      unless type.is_a?(Class) || (type.nil? && build)
        raise ConfigurationError, "A bean requires a class or a block"
      end
      dependencies ||= keyword_dependencies(type ? type.instance_method(:initialize) : build)
      build ||= ->(**arguments) { type.new(**arguments) }
      factory(name, dependencies:, close:, &build)
    end

    # Registers a class implementing +call+. Dependencies become constructor
    # keywords; omitting +dependencies+ infers required constructor keywords.
    # #invoke arguments become +call+ keywords. +policy+ must be +:none+,
    # +:read+, or +:write+. Returns +self+.
    def operation(name, use_case:, policy:, dependencies: nil)
      mutable!
      raise ConfigurationError, "Operation #{name} already registered" if @operations.key?(name)
      raise ConfigurationError, "Unknown transaction policy" unless %i[none read write].include?(policy)
      dependencies ||= use_case.is_a?(Class) ? keyword_dependencies(use_case.instance_method(:initialize)) : []
      @operations[name] = Operation.new(use_case:, policy:, dependencies: dependencies.dup.freeze)
      self
    end

    # Registers a lifecycle module implementing +name+, +requires+, +configure+,
    # +start+, and +stop+, and optionally +validate!+. Modules start in dependency
    # order and stop in reverse order. Returns +self+.
    def install(mod)
      mutable!
      raise ConfigurationError, "Module #{mod.name} already registered" if @modules.key?(mod.name)
      @modules[mod.name] = mod
      self
    end

    # Configures modules, validates dependencies and policies, freezes
    # registrations, and starts modules. Raises ConfigurationError for invalid
    # composition. If startup fails, already-started modules are stopped.
    def start
      raise ConfigurationError, "Application is already started" if @started
      unless @finalized
        modules = ordered_modules
        modules.each { |mod| mod.configure(self) }
        validate!
        modules.each { |mod| mod.validate! if mod.respond_to?(:validate!) }
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

    # Stops started modules in reverse order, attempting every stop even if one
    # fails. Preserves an exception already unwinding the caller. Returns +self+.
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

    # Executes a registered use case in a fresh resource and transaction scope.
    # Returns an independent, frozen value graph before resources are closed.
    # Unsupported results raise UnsafeResult before flush or commit. Failures
    # are reported and re-raised; failed commits are never automatically retried.
    # The application must be started. +context+ defaults to a fresh context.
    def invoke(name, context: ExecutionContext.new, **arguments)
      raise ConfigurationError, "Application is not started" unless @started
      operation = @operations.fetch(name) { raise ConfigurationError, "Unknown operation: #{name}" }
      Invocation.new(operation:, factories: @factories, storage: @storage, reporter: @reporter,
                     mappings: @mappings).call(context:, **arguments)
    end

    def validate_operation!(name)
      operation = @operations.fetch(name) { raise ConfigurationError, "Unknown operation: #{name}" }
      unless operation.use_case.is_a?(Class) && operation.use_case.public_instance_methods.include?(:call)
        raise ConfigurationError, "Use cases must be classes implementing call"
      end
      operation
    end

    private

    def keyword_dependencies(callable)
      parameters = callable.parameters
      if parameters.any? { |kind, _| kind == :req }
        raise ConfigurationError, "Automatic injection requires keyword arguments; wrap positional constructors in a bean block"
      end
      parameters.filter_map { |kind, name| name if kind == :keyreq }
    end

    def mutable!
      raise ConfigurationError, "Application registrations are finalized" if @finalized
    end

    def validate!
      @mappings&.validate!
      @factories.each_key { |name| validate_dependency(name, []) }
      @operations.each do |name, operation|
        validate_operation!(name)
        if operation.policy != :none && !@storage
          raise ConfigurationError, "Transactional operations require storage"
        end
        operation.dependencies.each { |name| validate_dependency(name, [], policy: operation.policy) }
      end
    end

    def validate_dependency(name, visiting, policy: nil)
      return if name == :context
      if %i[session transaction].include?(name)
        raise ConfigurationError, "Storage dependency requires a transaction" if policy == :none
        raise ConfigurationError, "Session requires mappings" if name == :session && !@mappings
        return
      end
      raise ConfigurationError, "Dependency cycle: #{(visiting + [name]).join(' -> ')}" if visiting.include?(name)
      factory = @factories.fetch(name) { raise ConfigurationError, "Unknown dependency: #{name}" }
      factory.dependencies.each { |dependency| validate_dependency(dependency, visiting + [name], policy:) }
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
