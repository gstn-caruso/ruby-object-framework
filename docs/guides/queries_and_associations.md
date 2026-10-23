This guide retrieves a set of purchases and explicitly loads their customer
objects. You will learn which names a query refers to, how ordering and paging
compose, and how an association uses the session's identity map.

Read [Data Mapper and sessions](data_mapper_and_sessions.md) first. The example
introduces a small `Purchase` projection to focus on relationships without
adding unrelated order-confirmation rules.

## Make a query an object

`Persistence::Query` is an immutable description. Each modifier returns a new
query, leaving the original available for another caller:

```ruby
base = ObjectFramework::Persistence::Query.new
large = base.compare(:total_cents, :gte, 1000)
page = large.order(:total_cents, :desc).offset(0).limit(10)
```

Criteria use stored column names and stored values. If a domain attribute
`total` maps through a converter to `total_cents`, query `total_cents` with an
integer. The query describes work for the adapter, which interprets it against
rows; it does not call methods on every loaded domain object.

Use `where` for equality and `compare` for the supported operators:

```ruby
query = ObjectFramework::Persistence::Query.new
query = query.where(state: "pending")
query = query.compare(:total_cents, :gte, 1000)
query = query.compare(:id, :in, [first_id, second_id])
```

The operators are `:eq`, `:ne`, `:gt`, `:gte`, `:lt`, `:lte`, and `:in`.
Successive criteria are combined with AND. This initial protocol does not
accept arbitrary SQL expressions. A small explicit query language can be
interpreted consistently by HashMap and SQLite and bound safely by SQL adapters.

## Define a relationship

An association says which identity connects two entity mappings. The domain
attributes remain ordinary Ruby references:

<!-- example: examples/guides/06_associations.rb -->

```sh
ruby -Ilib examples/guides/06_associations.rb
```

Expected output:

```text
Customer: Ada
Shared identity: true
```

`belongs_to :customer` stores the customer's UUID in `customer_id`. Both new
objects are registered before flush so that their identities are available.
When the session later loads that association, it asks for the customer by
identity and obtains the same object a direct `find(Customer, id)` would return.

You can declare the inverse collection with `has_many`. Its foreign key must
be mapped on the target entity:

```ruby
# On Customer's mapping:
has_many :purchases, target: Purchase, foreign_key: :customer_id
```

For this collection, the target mapping must expose `customer_id` as a field
or a belongs-to foreign key. Startup verifies the target and foreign key.

## Choose an explicit load plan

A session does not perform hidden association queries when domain code reads
an attribute. Supply a load plan at the retrieval boundary:

```ruby
purchase = session.find(Purchase, purchase_id, load: [:customer])
customers = session.query(Customer, query, load: [:purchases])
```

Nested plans are arrays containing association names or a hash naming the next
level. For a model with order lines and products:

```ruby
order = session.find(Order, order_id, load: [{ lines: [:product] }])
```

The session registers an entity's identity before traversing its associations.
Shared references therefore converge on one managed object. Load only the graph
the intention needs, and build its public result while that session is open.

An unloaded association retains the domain constructor's initial value, often
`nil` or an empty array. That initial value does not prove that storage contains
no relationship. The calling use case must know which plan it requested before
interpreting an empty collection as a business fact.

This explicit approach makes IO visible at an application boundary. Lazy
loading can be convenient, but reading an apparently ordinary attribute can
then issue a query, fail after a session has closed, or produce an unexpected
number of queries in a loop. The tradeoff here is a declared plan and more
deliberate graph construction. The initial loader prioritizes correctness and
identity; it does not promise a batched join for every collection plan.

## Preserve foreign keys you did not load

Suppose a purchase is loaded without its customer and only its total changes.
The mapper preserves the baseline `customer_id`; it does not turn the
constructor's `customer = nil` into an instruction to erase the relationship.

To clear an association intentionally, load it first and then assign `nil`.
To assign another entity, register or load that entity so that it has an
identity. Flush rejects an associated object whose identity is absent.

This distinction prevents a partial graph from destroying rows outside the
intention's scope. It also explains why a load plan participates in change
tracking rather than serving only as a query optimization hint.

## Order and paginate predictably

`order(:total_cents, :desc)` can be followed by additional ordering fields.
When `id` is not already included, the adapter adds it as a final ascending
tie-breaker. UUID order is deterministic within the snapshot; it does not
represent creation time.

`limit` and `offset` require nonnegative integers. Paging separate transactions
while other writers change the dataset can still move records between pages.
The tie-breaker stabilizes equal sort values, while snapshot lifetime determines
which dataset is being paged.

The query runs against the transaction's rows. Newly added or modified managed
objects reach those rows at `flush`. If a use case needs a query to reflect its
pending changes before the final invocation flush, explicitly call
`session.flush` first. Direct `find` by a tracked identity can already return
the managed object from the identity map.

## Check adapter equivalence

HashMap interprets criteria against value rows. SQLite compiles them into
parameterized statements using registered schema identifiers. Their common
tests cover filtering, deterministic ordering, pagination, private writes, and
transaction state. Additional tests compare NULL membership and ordering ties.

Read the [shared storage contract](https://github.com/gstn-caruso/ruby-object-framework/blob/main/test/support/storage_contract.rb)
and [association scenarios](https://github.com/gstn-caruso/ruby-object-framework/blob/main/test/mapper_test.rb)
when extending the language. A new operator needs semantics that both adapters
can implement, including how absent and NULL values behave.

## Next step

[Building an HTTP API](http_apis.md) places these application objects behind a
transport. As an exercise, query purchases above a threshold in two pages and
verify that two purchases sharing a customer still reference the same object
within one session.
