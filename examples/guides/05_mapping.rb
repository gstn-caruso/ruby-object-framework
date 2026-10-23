# frozen_string_literal: true

require "object_framework"
require_relative "../orders/domain"

mappings = ObjectFramework::Persistence::Mappings.new
mappings.define(OrdersExample::Order, table: :orders) do
  field :id
  field :state
  field :total_cents, type: :integer
end
mappings.validate!
storage = ObjectFramework::Memory::Storage.new
write = storage.begin_transaction(mode: :write)
session = ObjectFramework::Persistence::Session.new(transaction: write, mappings:)
order = OrdersExample::Order.new(total_cents: 1500)
begin
  session.add(order)
  session.flush
  write.commit
ensure
  session.close
  write.close
end

read = storage.begin_transaction(mode: :read)
session = ObjectFramework::Persistence::Session.new(transaction: read, mappings:)
begin
  first = session.find(OrdersExample::Order, order.id)
  second = session.find(OrdersExample::Order, order.id)
  puts "UUID assigned: #{!order.id.nil?}"
  puts "Same identity: #{first.equal?(second)}"
  puts "Independent session: #{!first.equal?(order)}"
  puts "Stored state: #{first.state}"
ensure
  session.close
  read.close
  storage.close
end
