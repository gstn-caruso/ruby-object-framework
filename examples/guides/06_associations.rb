# frozen_string_literal: true

require "object_framework"

class Customer
  attr_accessor :id, :name
  def initialize(id: nil, name:); @id, @name = id, name; end
end

class Purchase
  attr_accessor :id, :total_cents, :customer
  def initialize(id: nil, total_cents:)
    @id, @total_cents, @customer = id, total_cents, nil
  end
end

mappings = ObjectFramework::Persistence::Mappings.new
mappings.define(Customer, table: :customers) { field :id; field :name }
mappings.define(Purchase, table: :purchases) do
  field :id
  field :total_cents, type: :integer
  belongs_to :customer, target: Customer, foreign_key: :customer_id
end
mappings.validate!
storage = ObjectFramework::Memory::Storage.new
write = storage.begin_transaction(mode: :write)
seed = ObjectFramework::Persistence::Session.new(transaction: write, mappings:)
customer = Customer.new(name: "Ada")
purchase = Purchase.new(total_cents: 1500)
purchase.customer = customer
seed.add(customer)
seed.add(purchase)
seed.flush
write.commit
seed.close
write.close

read = storage.begin_transaction(mode: :read)
session = ObjectFramework::Persistence::Session.new(transaction: read, mappings:)
begin
  query = ObjectFramework::Persistence::Query.new.compare(:total_cents, :gte, 1000).order(:total_cents, :desc).limit(10)
  loaded = session.query(Purchase, query, load: [:customer]).first
  puts "Customer: #{loaded.customer.name}"
  puts "Shared identity: #{loaded.customer.equal?(session.find(Customer, customer.id))}"
ensure
  session.close
  read.close
  storage.close
end
