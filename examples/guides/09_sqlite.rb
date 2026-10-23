# frozen_string_literal: true

require "tmpdir"
require_relative "../orders/application"

class GetOrder
  def initialize(session:); @session = session; end
  def call(order_id:)
    order = @session.find(OrdersExample::Order, order_id)
    { state: order.state }
  end
end

Dir.mktmpdir("orders-guide") do |directory|
  schema = ObjectFramework::SQLite::Schema.new(tables: { orders: { id: :string, state: :string, total_cents: :integer } })
  schema.migration(2) { add_column :orders, :note, type: :string }
  storage = ObjectFramework::SQLite::Storage.new(path: File.join(directory, "orders.sqlite3"), schema:)
  bundle = OrdersExample.build(storage:)
  seed = storage.begin_transaction(mode: :write)
  row = seed.find(:orders, "ready")
  seed.update(:orders, "ready", row.merge(note: "gift"))
  seed.commit
  seed.close
  bundle.application.operation(:get_order, use_case: GetOrder, policy: :read, dependencies: [:session])
  bundle.application.start
  begin
    puts "Schema version: #{storage.schema_version}"
    puts "Read: #{bundle.application.invoke(:get_order, order_id: 'ready')[:state]}"
    puts "Write: #{bundle.application.invoke(:confirm_order, order_id: 'ready').state}"
    check = storage.begin_transaction(mode: :read)
    puts "Unmapped note: #{check.find(:orders, 'ready')[:note]}"
    check.close
    puts "Open connections: #{storage.open_connection_count}"
  ensure
    bundle.application.stop
    storage.close
  end
end
