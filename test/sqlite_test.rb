# frozen_string_literal: true

require "object_framework"
require "tmpdir"
require "fileutils"
require_relative "support/storage_contract"

module SQLiteFixture
  def sqlite_schema
    ObjectFramework::SQLite::Schema.new(tables: { records: { id: :string, name: :string, total: :integer } })
  end

  def sqlite_storage(**options)
    directory = Dir.mktmpdir("object-framework-sqlite")
    storage = ObjectFramework::SQLite::Storage.new(path: File.join(directory, "storage.sqlite3"), schema: sqlite_schema, **options)
    original_close = storage.method(:close)
    storage.define_singleton_method(:close) { original_close.call; FileUtils.remove_entry(directory) if File.directory?(directory) }
    storage
  end
end
Spec::Assertions.include(SQLiteFixture)

StorageContract.register("SQLite") { Object.new.extend(SQLiteFixture).sqlite_storage }

Spec.test "SQLite uses durable pragmas and closes the connection owned by each transaction" do
  storage = sqlite_storage
  assert_equal 0, storage.open_connection_count
  first = storage.begin_transaction(mode: :read)
  second = storage.begin_transaction(mode: :read)
  assert_equal 2, storage.open_connection_count
  assert_equal({ foreign_keys: 1, journal_mode: "delete", synchronous: 2 }, first.configuration)
  first.close
  assert_equal 1, storage.open_connection_count
  second.close
  assert_equal 0, storage.open_connection_count
ensure
  first&.close
  second&.close
  storage&.close
end

Spec.test "SQLite parameterizes values and rejects unregistered SQL identifiers" do
  storage = sqlite_storage
  transaction = storage.begin_transaction(mode: :write)
  attack = "'; DROP TABLE records; --"
  transaction.insert(:records, { id: "one", name: attack, total: 1 })
  transaction.commit
  transaction.close
  reader = storage.begin_transaction(mode: :read)
  query = ObjectFramework::Persistence::Query.new(table: :records).where(name: attack)
  assert_equal ["one"], reader.query(query).map { |row| row[:id] }
  assert_raises(ObjectFramework::ConfigurationError) { reader.query(query.order(:missing)) }
  assert_raises(ObjectFramework::ConfigurationError) { reader.find(:missing, "id") }
ensure
  transaction&.close
  reader&.close
  storage&.close
end

Spec.test "SQLite serializes writers with IMMEDIATE and bounds lock waiting by the execution deadline" do
  storage = sqlite_storage(lock_timeout: 1)
  first = storage.begin_transaction(mode: :write)
  started = ObjectFramework::HTTP::Timing.now
  cancellation = ObjectFramework::Cancellation.new(deadline: started + 0.05)
  context = ObjectFramework::ExecutionContext.new(cancellation:)
  assert_raises(ObjectFramework::DeadlineExceeded) { storage.begin_transaction_for(mode: :write, context:) }
  assert ObjectFramework::HTTP::Timing.now - started < 0.5
  assert_equal 1, storage.open_connection_count
  first.close
  second = storage.begin_transaction(mode: :write)
  second.close
ensure
  first&.close
  second&.close
  storage&.close
end

Spec.test "SQLite schema migrations are versioned, atomic, and persist across restarts" do
  directory = Dir.mktmpdir("object-framework-schema")
  path = File.join(directory, "storage.sqlite3")
  first_schema = sqlite_schema
  first = ObjectFramework::SQLite::Storage.new(path:, schema: first_schema)
  transaction = first.begin_transaction(mode: :write)
  transaction.insert(:records, { id: "one", name: "before", total: 1 })
  transaction.commit
  transaction.close
  first.close
  next_schema = sqlite_schema
  next_schema.migration(2) { add_column :records, :note, type: :string }
  second = ObjectFramework::SQLite::Storage.new(path:, schema: next_schema)
  assert_equal 2, second.schema_version
  reader = second.begin_transaction(mode: :read)
  assert_equal "before", reader.find(:records, "one")[:name]
  assert_equal nil, reader.find(:records, "one")[:note]
  reader.close
  assert_raises(ObjectFramework::ConfigurationError) { ObjectFramework::SQLite::Storage.new(path:, schema: first_schema) }
ensure
  transaction&.close
  reader&.close
  first&.close
  second&.close
  FileUtils.remove_entry(directory) if directory && File.directory?(directory)
end

Spec.test "SQLite derives foreign keys from external mappings and classifies engine codes" do
  customer = Class.new
  order = Class.new
  mappings = ObjectFramework::Persistence::Mappings.new
  mappings.define(customer, table: :customers) { field :id; field :name }
  mappings.define(order, table: :orders) { field :id; belongs_to :customer, target: customer, foreign_key: :customer_id }
  directory = Dir.mktmpdir("object-framework-foreign-keys")
  schema = ObjectFramework::SQLite::Schema.from_mappings(mappings)
  storage = ObjectFramework::SQLite::Storage.new(path: File.join(directory, "storage.sqlite3"), schema:)
  transaction = storage.begin_transaction(mode: :write)
  transaction.insert(:orders, { id: "order", customer_id: "missing" })
  assert_raises(ObjectFramework::InvalidInput) { transaction.commit }
  transaction.rollback
  assert_equal :rolled_back, transaction.state
ensure
  transaction&.close
  storage&.close
  FileUtils.remove_entry(directory) if directory && File.directory?(directory)
end

Spec.test "SQLite validates existing schema shape before accepting application operations" do
  directory = Dir.mktmpdir("object-framework-schema-shape")
  path = File.join(directory, "storage.sqlite3")
  storage = ObjectFramework::SQLite::Storage.new(path:, schema: sqlite_schema)
  storage.close
  different = ObjectFramework::SQLite::Schema.new(tables: { records: { id: :string, missing: :string } })
  assert_raises(ObjectFramework::ConfigurationError) { ObjectFramework::SQLite::Storage.new(path:, schema: different) }
ensure
  storage&.close
  FileUtils.remove_entry(directory) if directory && File.directory?(directory)
end

Spec.test "SQLite supports identity-only mappings and preserves known commit state on repeated commit" do
  directory = Dir.mktmpdir("object-framework-id-only")
  schema = ObjectFramework::SQLite::Schema.new(tables: { records: { id: :string } })
  storage = ObjectFramework::SQLite::Storage.new(path: File.join(directory, "storage.sqlite3"), schema:)
  transaction = storage.begin_transaction(mode: :write)
  transaction.insert(:records, { id: "one" })
  transaction.update(:records, "one", { id: "one" })
  transaction.commit
  assert_raises(ObjectFramework::Persistence::ClosedTransaction) { transaction.commit }
  assert_equal :committed, transaction.state
ensure
  transaction&.close
  storage&.close
  FileUtils.remove_entry(directory) if directory && File.directory?(directory)
end

Spec.test "SQLite and HashMap agree on NULL criteria, IN lists, and ordering ties" do
  sqlite = sqlite_storage
  memory = ObjectFramework::Memory::Storage.new
  outcomes = [sqlite, memory].map do |storage|
    transaction = storage.begin_transaction(mode: :write)
    [{ id: "a", name: nil, total: 1 }, { id: "b", name: "x", total: 1 }, { id: "c", name: "x", total: 2 }].each { |row| transaction.insert(:records, row) }
    query = ObjectFramework::Persistence::Query.new(table: :records).compare(:name, :in, [nil, "x"]).order(:total, :desc)
    rows = transaction.query(query)
    transaction.close
    rows
  end
  assert_equal outcomes.first, outcomes.last
ensure
  sqlite&.close
  memory&.close
end

Spec.test "SQLite executes the same mapped order use case as HashMap" do
  require_relative "../examples/orders/application"
  directory = Dir.mktmpdir("object-framework-sqlite-orders")
  schema = ObjectFramework::SQLite::Schema.new(tables: { orders: { id: :string, state: :string, total_cents: :integer } })
  storage = ObjectFramework::SQLite::Storage.new(path: File.join(directory, "storage.sqlite3"), schema:)
  bundle = OrdersExample.build(storage:)
  bundle.application.start
  result = bundle.application.invoke(:confirm_order, order_id: "ready")
  assert_equal "confirmed", result.state
  read = storage.begin_transaction(mode: :read)
  assert_equal "confirmed", read.find(:orders, "ready")[:state]
  read.close
  assert_equal 0, storage.open_connection_count
ensure
  read&.close
  bundle&.application&.stop
  storage&.close
  FileUtils.remove_entry(directory) if directory && File.directory?(directory)
end
