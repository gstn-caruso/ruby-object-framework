# frozen_string_literal: true

require "object_framework"

module MapperFixture
  Money = Data.define(:cents)
  class MoneyConverter
    def dump(value); value.cents; end
    def load(value); Money.new(cents: value); end
  end

  class Customer
    attr_accessor :id, :name
    def initialize(id: nil, name:)
      @id, @name = id, name
    end
  end

  class Order
    attr_accessor :id, :status, :total, :customer, :lines
    def initialize(id: nil, status:, total:)
      @id, @status, @total, @customer, @lines = id, status, total, nil, []
    end
  end

  class Line
    attr_accessor :id, :order_id, :name
    def initialize(id: nil, order_id:, name:)
      @id, @order_id, @name = id, order_id, name
    end
  end

  def mapper_fixture
    mappings = ObjectFramework::Persistence::Mappings.new
    mappings.define(Customer, table: :customers) do
      field :id
      field :name
    end
    mappings.define(Order, table: :orders) do
      field :id
      field :status
      field :total, column: :total_cents, type: :integer, converter: MoneyConverter.new
      belongs_to :customer, target: Customer, foreign_key: :customer_id
      has_many :lines, target: Line, foreign_key: :order_id
    end
    mappings.define(Line, table: :lines) do
      field :id
      field :order_id
      field :name
    end
    mappings.validate!
    storage = ObjectFramework::Memory::Storage.new
    [storage, mappings]
  end

  def mapper_session(storage, mappings, mode: :write)
    transaction = storage.begin_transaction(mode:)
    ObjectFramework::Persistence::Session.new(transaction:, mappings:)
  end
end
Spec::Assertions.include(MapperFixture)

Spec.test "external mappings persist converted values and generate UUIDs at registration" do
  storage, mappings = mapper_fixture
  session = mapper_session(storage, mappings)
  order = MapperFixture::Order.new(status: "open", total: MapperFixture::Money.new(cents: 1500))
  session.add(order)
  assert /\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/.match?(order.id)
  session.flush
  assert_equal 1500, session.transaction.find(:orders, order.id)[:total_cents]
  session.transaction.commit
  session.close
  other = mapper_session(storage, mappings, mode: :read)
  loaded = other.find(MapperFixture::Order, order.id)
  assert_equal order.total, loaded.total
  assert !loaded.equal?(order)
ensure
  session&.transaction&.close
  other&.close
  other&.transaction&.close
  storage&.close
end

Spec.test "identity maps preserve identity in one session and separate sessions" do
  storage, mappings = mapper_fixture
  session = mapper_session(storage, mappings)
  customer = MapperFixture::Customer.new(name: "Ada")
  session.add(customer)
  session.flush
  session.transaction.commit
  session.close
  first = mapper_session(storage, mappings, mode: :read)
  second = mapper_session(storage, mappings, mode: :read)
  a = first.find(MapperFixture::Customer, customer.id)
  assert_same a, first.find(MapperFixture::Customer, customer.id)
  assert !a.equal?(second.find(MapperFixture::Customer, customer.id))
  first.close
  assert_raises(ObjectFramework::ClosedSession) { first.find(MapperFixture::Customer, customer.id) }
ensure
  [session, first, second].compact.each { |item| item.close; item.transaction.close }
  storage&.close
end

Spec.test "unit of work tracks updates and removals and rollback discards managed objects" do
  storage, mappings = mapper_fixture
  seed = mapper_session(storage, mappings)
  customer = MapperFixture::Customer.new(name: "Original")
  seed.add(customer)
  seed.flush
  seed.transaction.commit
  seed.close
  changed = mapper_session(storage, mappings)
  changed.find(MapperFixture::Customer, customer.id).name = "Rolled back"
  changed.flush
  changed.transaction.rollback
  changed.close
  committed = mapper_session(storage, mappings)
  loaded = committed.find(MapperFixture::Customer, customer.id)
  assert_equal "Original", loaded.name
  loaded.name = "Updated"
  committed.flush
  assert_equal "Updated", committed.transaction.find(:customers, customer.id)[:name]
  committed.remove(loaded)
  committed.flush
  committed.transaction.commit
  check = mapper_session(storage, mappings, mode: :read)
  assert_raises(ObjectFramework::NotFound) { check.find(MapperFixture::Customer, customer.id) }
ensure
  [seed, changed, committed, check].compact.each { |item| item.close; item.transaction.close }
  storage&.close
end

Spec.test "declared association plans load shared entities and collections explicitly" do
  storage, mappings = mapper_fixture
  seed = mapper_session(storage, mappings)
  customer = MapperFixture::Customer.new(name: "Ada")
  order = MapperFixture::Order.new(status: "open", total: MapperFixture::Money.new(cents: 100))
  order.customer = customer
  seed.add(customer)
  seed.add(order)
  line = MapperFixture::Line.new(order_id: order.id, name: "Book")
  seed.add(line)
  seed.flush
  seed.transaction.commit
  seed.close
  read = mapper_session(storage, mappings)
  loaded = read.find(MapperFixture::Order, order.id)
  assert_equal nil, loaded.customer
  assert_equal [], loaded.lines
  assert_same loaded, read.find(MapperFixture::Order, order.id, load: [:customer, :lines])
  assert_same read.find(MapperFixture::Customer, customer.id), loaded.customer
  assert_equal ["Book"], loaded.lines.map(&:name)
  query = ObjectFramework::Persistence::Query.new.where(status: "open").limit(1)
  assert_same loaded, read.query(MapperFixture::Order, query).first
ensure
  [seed, read].compact.each { |item| item.close; item.transaction.close }
  storage&.close
end

Spec.test "unloaded associations retain their stored foreign key when other fields change" do
  storage, mappings = mapper_fixture
  transaction = storage.begin_transaction(mode: :write)
  transaction.insert(:orders, { id: "order", status: "open", total_cents: 100, customer_id: "customer" })
  transaction.commit
  transaction.close
  session = mapper_session(storage, mappings)
  session.find(MapperFixture::Order, "order").status = "confirmed"
  session.flush
  assert_equal "customer", session.transaction.find(:orders, "order")[:customer_id]
ensure
  session&.close
  session&.transaction&.close
  storage&.close
end

Spec.test "mapping validation rejects unresolved associations and duplicate columns" do
  mappings = ObjectFramework::Persistence::Mappings.new
  mappings.define(MapperFixture::Order, table: :orders) do
    field :id
    belongs_to :customer, target: MapperFixture::Customer, foreign_key: :customer_id
  end
  assert_raises(ObjectFramework::ConfigurationError) { mappings.validate! }
  assert_raises(ObjectFramework::ConfigurationError) do
    ObjectFramework::Persistence::Mappings.new.define(MapperFixture::Customer, table: :customers) do
      field :id
      field :name, column: :id
    end
  end
end

Spec.test "invocations inject sessions into repository factories and commit tracked changes" do
  storage, mappings = mapper_fixture
  use_case = Class.new do
    def initialize(repository:); @repository = repository; end
    def call(name:)
      customer = MapperFixture::Customer.new(name:)
      @repository.add(customer)
      { id: customer.id, name: customer.name }
    end
  end
  app = ObjectFramework::Application.new(storage:, mappings:)
  app.factory(:repository, dependencies: [:session]) { |session:| session }
  app.operation(:create, use_case:, dependencies: [:repository], policy: :write)
  app.start
  result = app.invoke(:create, name: "Ada")
  read = mapper_session(storage, mappings, mode: :read)
  assert_equal "Ada", read.find(MapperFixture::Customer, result[:id]).name
ensure
  app&.stop
  read&.close
  read&.transaction&.close
  storage&.close
end

Spec.test "hydration gives domain objects mutable fields without sharing storage values" do
  storage, mappings = mapper_fixture
  transaction = storage.begin_transaction(mode: :write)
  transaction.insert(:customers, { id: "customer", name: "Ada" })
  transaction.commit
  transaction.close
  session = mapper_session(storage, mappings)
  loaded = session.find(MapperFixture::Customer, "customer")
  loaded.name.replace("Grace")
  assert_equal "Ada", session.transaction.find(:customers, "customer")[:name]
  session.flush
  assert_equal "Grace", session.transaction.find(:customers, "customer")[:name]
ensure
  session&.close
  session&.transaction&.close
  storage&.close
end

Spec.test "removed entities cannot reappear through a session identity map or query" do
  storage, mappings = mapper_fixture
  session = mapper_session(storage, mappings)
  customer = MapperFixture::Customer.new(name: "Ada")
  session.add(customer)
  session.flush
  session.remove(customer)
  assert_raises(ObjectFramework::NotFound) { session.find(MapperFixture::Customer, customer.id) }
  assert_equal [], session.query(MapperFixture::Customer)
  session.flush
  assert_raises(ObjectFramework::NotFound) { session.find(MapperFixture::Customer, customer.id) }
ensure
  session&.close
  session&.transaction&.close
  storage&.close
end

Spec.test "managed identities cannot be changed even before their first flush" do
  storage, mappings = mapper_fixture
  session = mapper_session(storage, mappings)
  customer = MapperFixture::Customer.new(name: "Ada")
  session.add(customer)
  customer.id = "replacement"
  assert_raises(ObjectFramework::InvalidInput) { session.flush }
ensure
  session&.close
  session&.transaction&.close
  storage&.close
end
