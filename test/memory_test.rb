# frozen_string_literal: true

require "object_framework"
require_relative "support/storage_contract"

StorageContract.register("HashMap") { ObjectFramework::Memory::Storage.new }

Spec.test "HashMap rejects stale writers without publishing any partial changes" do
  storage = ObjectFramework::Memory::Storage.new
  first = storage.begin_transaction(mode: :write)
  second = storage.begin_transaction(mode: :write)
  first.insert(:records, { id: "first" })
  second.insert(:records, { id: "second" })
  first.commit
  assert_raises(ObjectFramework::Conflict) { second.commit }
  assert_equal :rolled_back, second.state
  read = storage.begin_transaction(mode: :read)
  assert_equal ["first"], read.query(ObjectFramework::Persistence::Query.new(table: :records)).map { |row| row[:id] }
ensure
  [first, second, read].compact.each(&:close)
  storage&.close
end

Spec.test "HashMap publishes a single winner under concurrent commits" do
  storage = ObjectFramework::Memory::Storage.new
  ready, release, results = Queue.new, Queue.new, Queue.new
  threads = 8.times.map do |index|
    Thread.new do
      transaction = storage.begin_transaction(mode: :write)
      transaction.insert(:records, { id: index.to_s })
      ready << true
      release.pop
      begin
        transaction.commit
        results << :committed
      rescue ObjectFramework::Conflict
        results << :conflict
      ensure
        transaction.close
      end
    end
  end
  8.times { ready.pop }
  8.times { release << true }
  threads.each(&:join)
  outcomes = 8.times.map { results.pop }
  assert_equal 1, outcomes.count(:committed)
  assert_equal 7, outcomes.count(:conflict)
ensure
  storage&.close
end
