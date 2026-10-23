# frozen_string_literal: true

require "object_framework"
require_relative "support/http_client"
require_relative "../examples/orders/application"

Spec.test "order confirmation is directly invocable without a transport or framework superclass" do
  order = OrdersExample::Order.new(id: "one", state: "pending", total_cents: 1500)
  repository = Object.new
  repository.define_singleton_method(:fetch) { |id| order }
  use_case = OrdersExample::ConfirmOrder.new(orders: repository)
  result = use_case.call(order_id: "one")
  assert_equal "confirmed", result.state
  assert_equal "one", result.id
  assert_equal Object, OrdersExample::Order.superclass
end

Spec.test "the order HTTP example demonstrates success, not found, and business rejection" do
  bundle = OrdersExample.build
  bundle.application.start
  client = HTTPClient.new(bundle.server.port)
  success = client.request("POST", "/orders/ready/confirm")
  assert_equal 200, success[:status]
  assert_equal "confirmed", JSON.parse(success[:body])["state"]
  missing = client.request("POST", "/orders/missing/confirm")
  assert_equal 404, missing[:status]
  rejection = client.request("POST", "/orders/rejected/confirm")
  assert_equal 409, rejection[:status]
  assert_equal "order_not_confirmable", JSON.parse(rejection[:body])["code"]
ensure
  client&.close
  bundle&.application&.stop
  bundle&.storage&.close
end

Spec.test "JSON presentation supports nested independent Data value objects" do
  value = Data.define(:item).new(item: Data.define(:name).new(name: "Ada"))
  response = ObjectFramework::HTTP::JSONPresenter.new.call(value)
  assert_equal({ "item" => { "name" => "Ada" } }, JSON.parse(response.body))
end

class ControlledOrderStorage
  attr_reader :ready, :release

  def initialize(fail_read: false, synchronize_reads: false)
    @storage = ObjectFramework::Memory::Storage.new
    @fail_read, @synchronize_reads = fail_read, synchronize_reads
    @ready, @release = Queue.new, Queue.new
  end

  def begin_transaction(mode:)
    underlying = @storage.begin_transaction(mode:)
    wrapper = Object.new
    %i[insert update delete query commit rollback close state].each do |message|
      wrapper.define_singleton_method(message) { |*args, **kwargs| underlying.public_send(message, *args, **kwargs) }
    end
    fail_read, synchronize_reads, ready, release = @fail_read, @synchronize_reads, @ready, @release
    wrapper.define_singleton_method(:find) do |table, id|
      raise "password=secret" if fail_read
      row = underlying.find(table, id)
      if synchronize_reads
        ready << true
        raise "Barrier timed out" unless release.pop(timeout: 3)
      end
      row
    end
    wrapper
  end

  def close; @storage.close; end
end

Spec.test "the order example demonstrates a real optimistic transaction conflict over HTTP" do
  storage = ControlledOrderStorage.new(synchronize_reads: true)
  bundle = OrdersExample.build(storage:)
  bundle.application.start
  clients = 2.times.map { HTTPClient.new(bundle.server.port) }
  threads = clients.map { |client| Thread.new { client.request("POST", "/orders/ready/confirm") } }
  2.times { assert storage.ready.pop(timeout: 3) }
  2.times { storage.release << true }
  responses = threads.map(&:value)
  assert_equal [200, 409], responses.map { |response| response[:status] }.sort
  conflict = responses.find { |response| response[:status] == 409 }
  assert_equal "transaction_conflict", JSON.parse(conflict[:body])["code"]
ensure
  2.times { storage.release << true } if storage
  threads&.each { |thread| thread.join(3) }
  clients&.each(&:close)
  bundle&.application&.stop
  storage&.close
end

Spec.test "the order example demonstrates an unexpected storage failure without exposing details" do
  storage = ControlledOrderStorage.new(fail_read: true)
  bundle = OrdersExample.build(storage:)
  bundle.application.start
  client = HTTPClient.new(bundle.server.port)
  response = client.request("POST", "/orders/ready/confirm")
  assert_equal 500, response[:status]
  assert_equal "internal_error", JSON.parse(response[:body])["code"]
  assert !response[:body].include?("secret")
ensure
  client&.close
  bundle&.application&.stop
  storage&.close
end
