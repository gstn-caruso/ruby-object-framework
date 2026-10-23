# frozen_string_literal: true

require "object_framework"
require_relative "support/http_client"

Spec.test "beans autowire ordinary constructors and factory blocks by required keyword name" do
  greeting = Class.new do
    def initialize(prefix:, punctuation: "!")
      @prefix, @punctuation = prefix, punctuation
    end

    def call(name:)
      "#{@prefix}, #{name}#{@punctuation}"
    end
  end
  use_case = Class.new do
    def initialize(greeting:); @greeting = greeting; end
    def call(name:); @greeting.call(name:); end
  end
  app = ObjectFramework::Application.new
  app.bean(:settings) { { prefix: "Hello" } }
  app.bean(:prefix) { |settings:| settings.fetch(:prefix) }
  app.bean(:punctuation) { "ignored optional dependency" }
  app.bean(:greeting, greeting)
  app.operation(:greet, use_case:, policy: :none)
  app.start
  assert_equal "Hello, Ada!", app.invoke(:greet, name: "Ada")
ensure
  app&.stop
end

Spec.test "explicit dependency lists can inject optional keywords in beans and operations" do
  greeting = Class.new do
    def initialize(prefix: "class default"); @prefix = prefix; end
    def text; @prefix; end
  end
  use_case = Class.new do
    def initialize(greeting: "operation default"); @greeting = greeting; end
    def call; @greeting.is_a?(String) ? @greeting : @greeting.text; end
  end
  app = ObjectFramework::Application.new
  app.factory(:source) { "configured" }
  app.bean(:prefix, dependencies: [:source]) { |source: "block default"| source }
  app.bean(:greeting, greeting, dependencies: [:prefix])
  app.operation(:default, use_case:, policy: :none)
  app.operation(:configured, use_case:, policy: :none, dependencies: [:greeting])
  app.start
  assert_equal "operation default", app.invoke(:default)
  assert_equal "configured", app.invoke(:configured)
ensure
  app&.stop
end

Spec.test "bean and factory dependencies compose in both directions in independent applications" do
  use_case = Class.new do
    def initialize(message:); @message = message; end
    def call; @message; end
  end
  apps = %w[first second].map do |label|
    ObjectFramework::Application.new.tap do |app|
      app.bean(:label) { label }
      app.factory(:prefix, dependencies: [:label]) { |label:| "#{label} application" }
      app.bean(:message) { |prefix:| prefix.upcase }
      app.operation(:read, use_case:, policy: :none)
      app.start
    end
  end
  assert_equal ["FIRST APPLICATION", "SECOND APPLICATION"], apps.map { |app| app.invoke(:read) }
ensure
  apps&.each(&:stop)
end

Spec.test "autowired dependencies reject missing beans and cycles before construction" do
  built = []
  app = ObjectFramework::Application.new
  app.bean(:service) { |missing:| built << true }
  error = assert_raises(ObjectFramework::ConfigurationError) { app.start }
  assert_equal "Unknown dependency: missing", error.message
  assert_equal [], built

  app = ObjectFramework::Application.new
  first = Class.new { def initialize(second:); end }
  app.bean(:first, first)
  app.bean(:second) { |first:| built << true }
  error = assert_raises(ObjectFramework::ConfigurationError) { app.start }
  assert error.message.include?("first -> second -> first")
  assert_equal [], built

  app = ObjectFramework::Application.new
  use_case = Class.new { def initialize(missing:); end; def call; end }
  app.operation(:read, use_case:, policy: :none)
  error = assert_raises(ObjectFramework::ConfigurationError) { app.start }
  assert_equal "Unknown dependency: missing", error.message
ensure
  app&.stop
end

Spec.test "beans reject ambiguous builders, reserved names, duplicate registrations, and late registration" do
  app = ObjectFramework::Application.new
  assert_raises(ObjectFramework::ConfigurationError) { app.bean(:missing) }
  assert_raises(ObjectFramework::ConfigurationError) { app.bean(:invalid, Object.new) }
  assert_raises(ObjectFramework::ConfigurationError) { app.bean(:ambiguous, Object) { Object.new } }
  %i[context session transaction].each do |name|
    assert_raises(ObjectFramework::ConfigurationError) { app.bean(name, Object) }
  end
  app.bean(:service, Object)
  assert_raises(ObjectFramework::ConfigurationError) { app.bean(:service, Object) }
  assert_raises(ObjectFramework::ConfigurationError) { app.factory(:service) { Object.new } }
  app.factory(:legacy) { Object.new }
  assert_raises(ObjectFramework::ConfigurationError) { app.bean(:legacy, Object) }
  app.start
  assert_raises(ObjectFramework::ConfigurationError) { app.bean(:late, Object) }
ensure
  app&.stop
end

Spec.test "positional constructors require a bean block for automatic dependency injection" do
  positional = Class.new do
    def initialize(prefix); @prefix = prefix; end
    def text; @prefix; end
  end
  app = ObjectFramework::Application.new
  assert_raises(ObjectFramework::ConfigurationError) { app.bean(:invalid, positional) }
  app.bean(:prefix) { "Hello" }
  app.bean(:greeting) { |prefix:| positional.new(prefix) }
  use_case = Class.new do
    def initialize(greeting:); @greeting = greeting; end
    def call; @greeting.text; end
  end
  app.operation(:greet, use_case:, policy: :none)
  app.start
  assert_equal "Hello", app.invoke(:greet)
ensure
  app&.stop
end

Spec.test "beans close in reverse construction order after success and execution or construction failure" do
  app = nil
  resource = Class.new do
    def initialize(name:, events:); @name, @events = name, events; end
    def close; @events << @name; end
  end
  %i[success execution_failure construction_failure].each do |behavior|
    events = []
    failure = RuntimeError.new("original failure")
    app = ObjectFramework::Application.new
    app.bean(:first, close: true) { resource.new(name: :first, events:) }
    app.bean(:second, close: true) { |first:| resource.new(name: :second, events:) }
    app.bean(:result) do |second:|
      raise failure if behavior == :construction_failure
      second
    end
    use_case = Class.new do
      define_method(:initialize) { |result:| }
      define_method(:call) { raise failure if behavior == :execution_failure; "ok" }
    end
    app.operation(:perform, use_case:, policy: :none)
    app.start
    if behavior == :success
      assert_equal "ok", app.invoke(:perform)
    else
      assert_same failure, assert_raises(RuntimeError) { app.invoke(:perform) }
    end
    assert_equal [:second, :first], events
    app.stop
  end
ensure
  app&.stop
end

Spec.test "bean cleanup failures are reported without replacing the use case failure or skipping cleanup" do
  events, records = [], []
  original = RuntimeError.new("primary")
  resource = Class.new do
    def initialize(name:, events:, fail: false); @name, @events, @fail = name, events, fail; end
    def close; @events << @name; raise IOError, "cleanup" if @fail; end
  end
  reporter = ObjectFramework::FailureReporter.new(sink: ->(record) { records << record })
  app = ObjectFramework::Application.new(reporter:)
  app.bean(:first, close: true) { resource.new(name: :first, events:) }
  app.bean(:second, close: true) { |first:| resource.new(name: :second, events:, fail: true) }
  use_case = Class.new do
    def initialize(second:); end
    define_method(:call) { raise original }
  end
  app.operation(:perform, use_case:, policy: :none)
  app.start
  assert_same original, assert_raises(RuntimeError) { app.invoke(:perform) }
  assert_equal [:second, :first], events
  assert_equal [false, true], records.map { |record| record.fetch(:secondary) }
ensure
  app&.stop
end

Spec.test "beans automatically receive the current session, transaction, and execution context" do
  storage = ObjectFramework::Memory::Storage.new
  mappings = ObjectFramework::Persistence::Mappings.new
  received = []
  app = ObjectFramework::Application.new(storage:, mappings:)
  app.bean(:repository) do |session:, transaction:, context:|
    received << [session, transaction, context]
    session
  end
  use_case = Class.new do
    def initialize(repository:, session:); @repository, @session = repository, session; end
    def call; @repository.equal?(@session); end
  end
  app.operation(:read, use_case:, policy: :read)
  app.start
  2.times { assert_equal true, app.invoke(:read) }
  assert received[0][0] != received[1][0]
  assert received[0][1] != received[1][1]
  assert received[0][2].operation_id != received[1][2].operation_id
  received.each do |session, transaction, context|
    assert_same transaction, session.transaction
    assert_equal :committed, context.transaction_state
    assert_raises(ObjectFramework::ClosedSession) { session.flush }
  end
ensure
  app&.stop
  storage&.close
end

Spec.test "autowired storage dependencies still require a transaction and session mappings" do
  use_case = Class.new { def initialize(repository:); end; def call; end }
  app = ObjectFramework::Application.new
  app.bean(:repository) { |transaction:| transaction }
  app.operation(:read, use_case:, policy: :none)
  assert_raises(ObjectFramework::ConfigurationError) { app.start }

  storage = ObjectFramework::Memory::Storage.new
  app = ObjectFramework::Application.new(storage:)
  app.bean(:repository) { |session:| session }
  app.operation(:read, use_case:, policy: :read)
  assert_raises(ObjectFramework::ConfigurationError) { app.start }
ensure
  app&.stop
  storage&.close
end

Spec.test "HTTP keep-alive requests construct fresh beans and close each request's resources" do
  closed = []
  counter = Class.new do
    attr_reader :context
    def initialize(context:); @context, @count = context, 0; end
    def increment; @count += 1; end
    define_method(:close) { closed << object_id }
  end
  use_case = Class.new do
    def initialize(first:, second:, context:); @first, @second, @context = first, second, context; end
    def call
      { counts: [@first.increment, @second.increment], identity: @first.object_id,
        same_context: @first.context.equal?(@context), operation_id: @context.operation_id }
    end
  end
  app = ObjectFramework::Application.new
  app.bean(:counter, counter, close: true)
  app.bean(:first) { |counter:| counter }
  app.bean(:second) { |counter:| counter }
  app.operation(:count, use_case:, policy: :none)
  router = ObjectFramework::HTTP::Router.new
  router.controller(:count, ObjectFramework::HTTP::Controller.new(application: app, operation: :count))
  router.route("GET", "/count", controller: :count)
  server = ObjectFramework::HTTP::Server.new(application: app, router:)
  app.install(server)
  app.start
  assert_equal [], closed
  client = HTTPClient.new(server.port)
  results = 2.times.map do
    response = client.request("GET", "/count")
    assert_equal 200, response[:status]
    result = JSON.parse(response[:body])
    assert_equal [1, 2], result.fetch("counts")
    assert_equal true, result.fetch("same_context")
    assert_equal result.fetch("identity"), closed.last
    result
  end
  assert results[0].fetch("operation_id") != results[1].fetch("operation_id")
  assert_equal 2, closed.size
ensure
  client&.close
  app&.stop
end

Spec.test "beans are lazy and shared only within their invocation across concurrent requests" do
  built = []
  use_case = Class.new do
    def initialize(first:, second:); @first, @second = first, second; end
    def call; { same: @first.equal?(@second), identity: @first.object_id }; end
  end
  app = ObjectFramework::Application.new
  app.bean(:resource) { Object.new.tap { |resource| built << resource } }
  app.bean(:first) { |resource:| resource }
  app.bean(:second) { |resource:| resource }
  app.bean(:unused) { raise "Unused beans must not be constructed" }
  app.operation(:identify, use_case:, policy: :none)
  app.start
  assert_equal [], built
  threads = 8.times.map { Thread.new { app.invoke(:identify) } }
  results = threads.map(&:value)
  assert results.all? { |result| result.fetch(:same) }
  assert_equal 8, results.map { |result| result.fetch(:identity) }.uniq.size
  assert_equal 8, built.size
  app.invoke(:identify)
  assert_equal 9, built.size
ensure
  app&.stop
end
