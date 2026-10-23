# frozen_string_literal: true

require "object_framework"

Spec.test "a use case is an ordinary Ruby object with constructor collaborators" do
  use_case = Class.new do
    def initialize(greeting:)
      @greeting = greeting
    end

    def call(name:)
      "#{@greeting}, #{name}"
    end
  end
  app = ObjectFramework::Application.new
  app.factory(:greeting) { "Hello" }
  app.operation(:greet, use_case:, policy: :none, dependencies: [:greeting])
  app.start
  assert_equal "Hello, Ada", app.invoke(:greet, name: "Ada")
ensure
  app&.stop
end

Spec.test "applications keep independent factories and require explicit policies" do
  echo = Class.new { def initialize(value:); @value = value; end; def call; @value; end }
  apps = ["one", "two"].map do |value|
    ObjectFramework::Application.new.tap do |app|
      app.factory(:value) { value }
      app.operation(:echo, use_case: echo, policy: :none, dependencies: [:value])
      app.start
    end
  end
  assert_equal ["one", "two"], apps.map { |app| app.invoke(:echo) }
  assert_raises(ArgumentError) { ObjectFramework::Application.new.operation(:bad, use_case: echo) }
ensure
  apps&.each(&:stop)
end

Spec.test "startup rejects missing dependencies, dependency cycles, and later registration" do
  app = ObjectFramework::Application.new
  app.factory(:a, dependencies: [:missing]) { |missing:| missing }
  assert_raises(ObjectFramework::ConfigurationError) { app.start }
  app = ObjectFramework::Application.new
  app.factory(:a, dependencies: [:b]) { |b:| b }
  app.factory(:b, dependencies: [:a]) { |a:| a }
  assert_raises(ObjectFramework::ConfigurationError) { app.start }
  app = ObjectFramework::Application.new.start
  assert_raises(ObjectFramework::ConfigurationError) { app.factory(:late) { 1 } }
ensure
  app&.stop
end

Spec.test "a scope builds each collaborator once and releases it after invocation" do
  resources = []
  resource = Class.new do
    attr_reader :closed
    def close; @closed = true; end
  end
  probe = Class.new do
    def initialize(first:, second:); @first, @second = first, second; end
    def call; @first.equal?(@second); end
  end
  app = ObjectFramework::Application.new
  app.factory(:resource, close: true) { resource.new.tap { |item| resources << item } }
  app.factory(:first, dependencies: [:resource]) { |resource:| resource }
  app.factory(:second, dependencies: [:resource]) { |resource:| resource }
  app.operation(:probe, use_case: probe, dependencies: [:first, :second], policy: :none)
  app.start
  2.times { assert_equal true, app.invoke(:probe) }
  assert_equal 2, resources.size
  assert resources.all?(&:closed)
ensure
  app&.stop
end

Spec.test "module startup validates first and unwinds started modules in reverse order" do
  events = []
  mod = Class.new do
    attr_reader :name, :requires
    def initialize(name, events, fail: false, requires: [])
      @name, @events, @fail, @requires = name, events, fail, requires
    end
    def configure(app); end
    def start; raise "startup failed" if @fail; @events << [:start, @name]; end
    def stop; @events << [:stop, @name]; end
  end
  app = ObjectFramework::Application.new
  app.install(mod.new(:one, events))
  app.install(mod.new(:two, events, requires: [:one]))
  app.install(mod.new(:three, events, fail: true, requires: [:two]))
  assert_raises(RuntimeError) { app.start }
  assert_equal [[:start, :one], [:start, :two], [:stop, :two], [:stop, :one]], events
end

Spec.test "error resolution uses the most specific ordinary exception and explicit safe details" do
  parent = Class.new(StandardError)
  child = Class.new(parent)
  registry = ObjectFramework::ErrorRegistry.new
  registry.register(parent, category: :conflict, code: "parent", title: "Conflict")
  registry.register(child, category: :invalid_input, code: "child", title: "Invalid", details: ->(error) { { field: "name" } })
  registry.validate!
  result = registry.resolve(child.new("password=secret"))
  assert_equal "child", result.code
  assert_equal({ field: "name" }, result.details)
  assert_equal "internal_error", registry.resolve(RuntimeError.new("secret")).code
  assert_raises(ObjectFramework::ConfigurationError) do
    ObjectFramework::ErrorRegistry.new.tap do |other|
      2.times { other.register(parent, category: :conflict, code: "same", title: "Conflict") }
    end
  end
end

Spec.test "cancellation and deadlines are cooperative and use monotonic time" do
  now = 10.0
  cancellation = ObjectFramework::Cancellation.new(deadline: 11.0, clock: -> { now })
  cancellation.check!
  now = 11.0
  assert_raises(ObjectFramework::DeadlineExceeded) { cancellation.check! }
  cancellation = ObjectFramework::Cancellation.new
  cancellation.cancel
  assert_raises(ObjectFramework::Cancelled) { cancellation.check! }
end

Spec.test "public values are detached and immutable before resources are closed" do
  source = { "items" => [+"original"] }
  use_case = Class.new do
    def initialize(source:); @source = source; end
    def call; @source; end
  end
  app = ObjectFramework::Application.new
  app.factory(:source) { source }
  app.operation(:read, use_case:, dependencies: [:source], policy: :none)
  app.start
  value = app.invoke(:read)
  source["items"].first.replace("changed")
  assert_equal({ "items" => ["original"] }, value)
  assert value.frozen? && value["items"].frozen? && value["items"].first.frozen?
ensure
  app&.stop
end
