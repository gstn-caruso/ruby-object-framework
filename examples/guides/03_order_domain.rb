# frozen_string_literal: true

require_relative "../orders/domain"

order = OrdersExample::Order.new(id: "ready", total_cents: 1500)
repository = Object.new
repository.define_singleton_method(:fetch) { |id| order }
confirm = OrdersExample::ConfirmOrder.new(orders: repository)
puts confirm.call(order_id: "ready").state
begin
  confirm.call(order_id: "ready")
rescue OrdersExample::OrderNotConfirmable
  puts "An order can only be confirmed once"
end
