# frozen_string_literal: true

require "object_framework"
require_relative "domain"

module OrdersExample
  class Orders
    def initialize(session:)
      @session = session
    end

    def fetch(id)
      @session.find(Order, id)
    end
  end

  Bundle = Data.define(:application, :server, :storage)

  def self.build(port: 0, storage: ObjectFramework::Memory::Storage.new)
    mappings = ObjectFramework::Persistence::Mappings.new
    mappings.define(Order, table: :orders) do
      field :id
      field :state
      field :total_cents, type: :integer
    end
    app = ObjectFramework::Application.new(storage:, mappings:)
    app.errors.register(OrderNotConfirmable, category: :conflict, code: "order_not_confirmable", title: "Order cannot be confirmed")
    app.factory(:orders, dependencies: [:session]) { |session:| Orders.new(session:) }
    app.operation(:confirm_order, use_case: ConfirmOrder, policy: :write, dependencies: [:orders])
    parameters = ObjectFramework::HTTP::Parameters.new do
      field :order_id, source: :path, key: :id, type: String
    end
    controller = ObjectFramework::HTTP::Controller.new(application: app, operation: :confirm_order, parameters:)
    router = ObjectFramework::HTTP::Router.new
    router.controller(:confirm_order, controller)
    router.route("POST", "/orders/:id/confirm", controller: :confirm_order)
    server = ObjectFramework::HTTP::Server.new(application: app, router:, port:)
    app.install(server)
    seed(storage)
    Bundle.new(application: app, server:, storage:)
  end

  def self.seed(storage)
    transaction = storage.begin_transaction(mode: :write)
    transaction.insert(:orders, { id: "ready", state: "pending", total_cents: 1500 })
    transaction.insert(:orders, { id: "rejected", state: "cancelled", total_cents: 500 })
    transaction.commit
  ensure
    transaction&.close
  end
end
