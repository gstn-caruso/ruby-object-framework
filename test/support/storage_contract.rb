# frozen_string_literal: true

module StorageContract
  def self.register(name, &build)
    Spec.test "#{name}: rows are independent values and rollback never leaks" do
      storage = build.call
      source = { id: "one", name: +"original", total: 1 }
      transaction = storage.begin_transaction(mode: :write)
      transaction.insert(:records, source)
      source[:name].replace("mutated")
      assert_equal "original", transaction.find(:records, "one")[:name]
      other = storage.begin_transaction(mode: :read)
      assert_equal nil, other.find(:records, "one")
      transaction.rollback
      transaction.close
      other.close
      check = storage.begin_transaction(mode: :read)
      assert_equal nil, check.find(:records, "one")
      check.close
    ensure
      storage&.close
    end

    Spec.test "#{name}: commits are atomic and readers cannot see private writes" do
      storage = build.call
      reader = storage.begin_transaction(mode: :read)
      assert_equal [], reader.query(ObjectFramework::Persistence::Query.new(table: :records))
      writer = storage.begin_transaction(mode: :write)
      writer.insert(:records, { id: "one", name: "A", total: 1 })
      writer.insert(:records, { id: "two", name: "B", total: 2 })
      assert_equal [], reader.query(ObjectFramework::Persistence::Query.new(table: :records))
      reader.commit
      reader.close
      writer.commit
      writer.close
      fresh = storage.begin_transaction(mode: :read)
      assert_equal 2, fresh.query(ObjectFramework::Persistence::Query.new(table: :records)).size
      fresh.close
    ensure
      storage&.close
    end

    Spec.test "#{name}: queries compose criteria, deterministic ordering, and pagination" do
      storage = build.call
      writer = storage.begin_transaction(mode: :write)
      [["a", "group", 3], ["b", "other", 5], ["c", "group", 7], ["d", "group", 9]].each do |id, label, total|
        writer.insert(:records, { id:, name: label, total: })
      end
      writer.commit
      writer.close
      reader = storage.begin_transaction(mode: :read)
      query = ObjectFramework::Persistence::Query.new(table: :records).where(name: "group").compare(:total, :gte, 3).order(:total, :desc).offset(1).limit(1)
      assert_equal ["c"], reader.query(query).map { |row| row[:id] }
      assert_raises(ObjectFramework::Persistence::ReadOnlyTransaction) { reader.insert(:records, { id: "bad" }) }
      reader.close
      assert_raises(ObjectFramework::Persistence::ClosedTransaction) { reader.find(:records, "a") }
    ensure
      storage&.close
    end

    Spec.test "#{name}: update, delete, duplicates, and transaction state follow the contract" do
      storage = build.call
      writer = storage.begin_transaction(mode: :write)
      writer.insert(:records, { id: "a", name: "old", total: 1 })
      assert_raises(ObjectFramework::Duplicate) { writer.insert(:records, { id: "a", name: "bad", total: 2 }) }
      writer.update(:records, "a", { id: "a", name: "new", total: 3 })
      assert_equal "new", writer.find(:records, "a")[:name]
      assert_raises(ObjectFramework::NotFound) { writer.update(:records, "missing", { id: "missing" }) }
      writer.delete(:records, "a")
      assert_equal nil, writer.find(:records, "a")
      writer.commit
      assert_equal :committed, writer.state
      assert_raises(ObjectFramework::Persistence::ClosedTransaction) { writer.commit }
      writer.close
      writer.close
    ensure
      storage&.close
    end
  end
end
