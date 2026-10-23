# frozen_string_literal: true

require "object_framework"

class RecordingTransaction
  attr_reader :events, :state

  def initialize(commit_error: nil, commit_state: :active, rollback_error: nil, close_error: nil)
    @commit_error, @commit_state, @rollback_error, @close_error = commit_error, commit_state, rollback_error, close_error
    @state, @events = :active, []
  end

  def commit
    @events << :commit
    @state = @commit_error ? @commit_state : :committed
    raise @commit_error if @commit_error
  end

  def rollback
    @events << :rollback
    raise @rollback_error if @rollback_error
    @state = :rolled_back
  end

  def close
    @events << :close
    raise @close_error if @close_error
  end
end

module InvocationFixture
  def invocation_fixture(transaction:, behavior:, records: [], policy: :write)
    storage = Object.new
    storage.define_singleton_method(:begin_transaction) { |mode:| transaction }
    use_case = Class.new do
      define_method(:call) { behavior.call }
    end
    registry = ObjectFramework::ErrorRegistry.new
    reporter = ObjectFramework::FailureReporter.new(registry:, sink: ->(record) { records << record })
    ObjectFramework::Application.new(storage:, errors: registry, reporter:).tap do |app|
      app.operation(:perform, use_case:, policy:)
      app.start
    end
  end
end
Spec::Assertions.include(InvocationFixture)

Spec.test "successful writes materialize before commit and close their transaction" do
  transaction = RecordingTransaction.new
  app = invocation_fixture(transaction:, behavior: -> { { value: "ok" } })
  context = ObjectFramework::ExecutionContext.new
  assert_equal({ value: "ok" }, app.invoke(:perform, context:))
  assert_equal [:commit, :close], transaction.events
  assert_equal :committed, context.transaction_state
ensure
  app&.stop
end

Spec.test "use case and materialization failures roll back and preserve the original exception" do
  [RuntimeError.new("password=secret"), Object.new].each do |result|
    transaction = RecordingTransaction.new
    records = []
    behavior = -> { raise result if result.is_a?(Exception); result }
    app = invocation_fixture(transaction:, behavior:, records:)
    exception = assert_raises(StandardError) { app.invoke(:perform) }
    assert_same result, exception if result.is_a?(Exception)
    assert_equal [:rollback, :close], transaction.events
    assert_equal 1, records.size
    assert !records.inspect.include?("password=secret")
    assert_equal :rolled_back, records.first[:transaction_state]
    app.stop
  end
end

Spec.test "commit failures retain known committed, rolled back, or indeterminate outcomes" do
  %i[active committed rolled_back indeterminate].each do |state|
    failure = RuntimeError.new("commit failed")
    transaction = RecordingTransaction.new(commit_error: failure, commit_state: state)
    app = invocation_fixture(transaction:, behavior: -> { "ok" })
    context = ObjectFramework::ExecutionContext.new
    assert_same failure, assert_raises(RuntimeError) { app.invoke(:perform, context:) }
    assert_equal(state == :active ? :rolled_back : state, context.transaction_state)
    assert_equal(state == :active ? [:commit, :rollback, :close] : [:commit, :close], transaction.events)
    app.stop
  end
end

Spec.test "rollback and close failures are secondary and never replace the primary failure" do
  original = RuntimeError.new("primary")
  transaction = RecordingTransaction.new(rollback_error: IOError.new("rollback"), close_error: IOError.new("close"))
  records = []
  app = invocation_fixture(transaction:, behavior: -> { raise original }, records:)
  assert_same original, assert_raises(RuntimeError) { app.invoke(:perform) }
  assert_equal 1, records.count { |record| !record[:secondary] }
  assert_equal 2, records.count { |record| record[:secondary] }
  assert_equal [:rollback, :close], transaction.events
ensure
  app&.stop
end

Spec.test "fatal unwinding still rolls back and closes without catching the fatal exception" do
  transaction = RecordingTransaction.new
  fatal = Class.new(Exception).new("fatal")
  app = invocation_fixture(transaction:, behavior: -> { raise fatal })
  assert_same fatal, assert_raises(fatal.class) { app.invoke(:perform) }
  assert_equal [:rollback, :close], transaction.events
ensure
  app&.stop
end

Spec.test "cancellation before commit rolls back but cancellation after commit keeps effects" do
  cancellation = ObjectFramework::Cancellation.new
  transaction = RecordingTransaction.new
  app = invocation_fixture(transaction:, behavior: -> { cancellation.cancel; "ok" })
  context = ObjectFramework::ExecutionContext.new(cancellation:)
  assert_raises(ObjectFramework::Cancelled) { app.invoke(:perform, context:) }
  assert_equal [:rollback, :close], transaction.events
  app.stop

  transaction = RecordingTransaction.new
  transaction.define_singleton_method(:commit) { super(); cancellation.cancel }
  cancellation = ObjectFramework::Cancellation.new
  app = invocation_fixture(transaction:, behavior: -> { "ok" })
  context = ObjectFramework::ExecutionContext.new(cancellation:)
  assert_equal "ok", app.invoke(:perform, context:)
  assert_equal :committed, context.transaction_state
ensure
  app&.stop
end

Spec.test "the failure reporter records one primary failure per operation across boundaries" do
  records = []
  reporter = ObjectFramework::FailureReporter.new(sink: ->(record) { records << record })
  first = ObjectFramework::ExecutionContext.new
  second = ObjectFramework::ExecutionContext.new
  2.times { reporter.report(RuntimeError.new("secret"), context: first) }
  reporter.report(RuntimeError.new("secret"), context: second)
  assert_equal 2, records.size
  assert first.operation_id != second.operation_id
  assert records.all? { |record| record[:duration] >= 0 && record[:code] == "internal_error" }
end

Spec.test "a commit failure without an adapter outcome is indeterminate and is never retried" do
  transaction = Object.new
  events = []
  transaction.define_singleton_method(:commit) { events << :commit; raise IOError, "connection lost" }
  transaction.define_singleton_method(:rollback) { events << :rollback }
  transaction.define_singleton_method(:close) { events << :close }
  app = invocation_fixture(transaction:, behavior: -> { "ok" })
  context = ObjectFramework::ExecutionContext.new
  assert_raises(IOError) { app.invoke(:perform, context:) }
  assert_equal :indeterminate, context.transaction_state
  assert_equal [:commit, :close], events
ensure
  app&.stop
end

Spec.test "cyclic public results fail safely and roll back" do
  transaction = RecordingTransaction.new
  cyclic = []
  cyclic << cyclic
  app = invocation_fixture(transaction:, behavior: -> { cyclic })
  assert_raises(ObjectFramework::UnsafeResult) { app.invoke(:perform) }
  assert_equal [:rollback, :close], transaction.events
ensure
  app&.stop
end
