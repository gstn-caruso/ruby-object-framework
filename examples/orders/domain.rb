# frozen_string_literal: true

module OrdersExample
  class OrderNotConfirmable < StandardError; end

  class Order
    attr_accessor :id
    attr_reader :state, :total_cents

    def initialize(id: nil, state: "pending", total_cents:)
      raise ArgumentError, "Total must be a nonnegative integer" unless total_cents.is_a?(Integer) && total_cents >= 0
      raise ArgumentError, "Unknown order state" unless %w[pending confirmed cancelled].include?(state)
      @id, @state, @total_cents = id, state, total_cents
    end

    def confirm
      raise OrderNotConfirmable unless state == "pending" && total_cents.positive?
      @state = "confirmed"
    end
  end

  Confirmation = Data.define(:id, :state, :total_cents)

  class ConfirmOrder
    def initialize(orders:)
      @orders = orders
    end

    def call(order_id:)
      order = @orders.fetch(order_id)
      order.confirm
      Confirmation.new(id: order.id, state: order.state, total_cents: order.total_cents)
    end
  end
end
