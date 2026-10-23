# frozen_string_literal: true

require "object_framework"

module OrdersExample
  def self.grpc_contract
    request = ObjectFramework::Protobuf::Message.new("ConfirmOrderRequest") do
      field :order_id, 1, :string
    end
    confirmation = ObjectFramework::Protobuf::Message.new("OrderConfirmation") do
      field :id, 1, :string
      field :state, 2, :string
      field :total_cents, 3, :int64
    end
    ObjectFramework::GRPC::Service.new("orders.Orders").tap do |service|
      service.rpc(:ConfirmOrder, input: request, output: confirmation, controller: :confirm_order)
    end
  end
end
