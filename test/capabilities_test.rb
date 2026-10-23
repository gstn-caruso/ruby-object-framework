# frozen_string_literal: true

require "object_framework"
require "open3"
require "rbconfig"

module CapabilityTasks
  class Summarize
    def self.call(input)
      { total: input[:numbers].sum, ractor: Ractor.current.object_id,
        thread: Thread.current.object_id, name: input[:name].upcase }
    end
  end

  class Fail
    def self.call(input)
      raise ArgumentError, "Task rejected input"
    end
  end
end

Spec.test "optional Ractor tasks receive independent values and return to the owning request thread" do
  task = ObjectFramework::Capabilities::IsolatedTask.new(task: CapabilityTasks::Summarize)
  context = ObjectFramework::ExecutionContext.new
  owner, input = Thread.current.object_id, { numbers: [1, 2, 3], name: +"Ada" }
  result = task.call(input, context:)
  assert_equal 6, result[:total]
  assert_equal "ADA", result[:name]
  assert result[:ractor] != Ractor.current.object_id
  assert result[:thread] != owner
  assert_equal owner, Thread.current.object_id
  assert_equal "Ada", input[:name]
  assert !input[:name].frozen?
  assert result.frozen?
end

Spec.test "Ractor tasks reject managed objects and expose task failures at the ordinary boundary" do
  task = ObjectFramework::Capabilities::IsolatedTask.new(task: CapabilityTasks::Fail)
  failure = assert_raises(ObjectFramework::Capabilities::TaskFailure) { task.call({}) }
  assert_equal "ArgumentError", failure.remote_class
  assert_raises(ObjectFramework::UnsafeResult) { task.call(Object.new) }
  cancellation = ObjectFramework::Cancellation.new
  cancellation.cancel
  context = ObjectFramework::ExecutionContext.new(cancellation:)
  assert_raises(ObjectFramework::Cancelled) { task.call({}, context:) }
end

Spec.test "Ruby Box is explicitly optional and isolates definitions when enabled at process boot" do
  script = <<~RUBY
    require "object_framework"
    first = ObjectFramework::Capabilities::Definitions.new
    second = ObjectFramework::Capabilities::Definitions.new
    first.evaluate("class Example; def self.call; :first; end; end")
    second.evaluate("class Example; def self.call; :second; end; end")
    abort "Definitions leaked" if Object.const_defined?(:Example)
    abort "Definitions mixed" unless [first.constant(:Example).call, second.constant(:Example).call] == [:first, :second]
    puts "isolated"
  RUBY
  output, error, status = Open3.capture3({ "RUBY_BOX" => "1" }, RbConfig.ruby, "-Ilib", "-e", script)
  assert status.success?, error
  assert_equal "isolated\n", output
  unless Ruby::Box.enabled?
    assert_raises(ObjectFramework::Capabilities::Unsupported) { ObjectFramework::Capabilities::Definitions.new }
  end
end
