This guide stores the order example without adding persistence methods to its
domain class. You will register an order, receive a UUID, reload it through a
session, and observe identity and change-tracking rules.

Complete [Composition and execution](composition_and_execution.md) first. This
guide uses HashMap storage so that database installation does not obscure the
object collaboration. The data disappears when the process ends.

## Describe storage outside the entity

An external mapping associates a Ruby class with a table and its fields:

```ruby
mappings = ObjectFramework::Persistence::Mappings.new
mappings.define(OrdersExample::Order, table: :orders) do
  field :id
  field :state
  field :total_cents, type: :integer
end
```

`Order` still decides what `confirm` means. The descriptor decides which values
represent an order in storage. `Session` uses both descriptions to construct a
managed object and remember its original row.

Mappings are validated at application startup and then finalized. A missing
identity field, duplicate column, unresolved association, or unknown field type
fails before a listener starts. UUID identities use a string `id` column.

By default, loading calls the entity's keyword constructor with mapped field
names. This keeps construction invariants active. If an existing model needs a
different construction protocol, declare a builder:

```ruby
mappings.define(Customer, table: :customers) do
  field :id
  field :name
  build { |attributes| Customer.new(**attributes) }
end
```

Fields may also declare explicit `read:` and `write:` callables. This is useful
for an identity setter with a domain-specific name. The mapper does not need to
insert persistence methods into the class to gain access to its state.

## Register and reload an order

The complete example exposes the lower-level transaction and session protocol
so that their lifetimes are visible:

<!-- example: examples/guides/05_mapping.rb -->

```sh
ruby -Ilib examples/guides/05_mapping.rb
```

Expected output:

```text
UUID assigned: true
Same identity: true
Independent session: true
Stored state: pending
```

`session.add(order)` assigns a UUID immediately if the order has no identity.
This lets another new object refer to it before rows are inserted. The unit of
work records an insertion; `flush` writes the serialized row into the private
transaction. `commit` publishes the transaction's changes.

Closing a session discards its identity map and tracked objects. Closing a still
active transaction rolls it back. The application-level `Invocation` normally
performs these steps for you; the explicit form is useful for understanding the
protocol and preparing fixture data.

## Preserve identity within one execution

An identity map answers the question: which Ruby object represents this class
and UUID in this session? Repeated `find` calls return the same object.
Associations loaded through the same session also use that identity map.

This matters when two domain objects refer to one customer. A change through
one reference must be visible through the other before persistence happens.
Constructing a new customer for every row would give one transaction several
contradictory in-memory versions of a single identity.

A second session creates a second object. That separation gives rollback a
clear meaning: discard that session and its managed graph. The framework does
not attempt to reverse every mutation on arbitrary Ruby objects after failure.
Such reversal would need knowledge of caches, derived state, and side effects
inside every domain class.

## Track changes without explicit save calls

The unit of work keeps an immutable baseline row for each loaded entity. At
flush, it serializes the current state and compares it with the baseline. New
objects are inserted, changed objects are updated, and removed objects are
deleted.

```ruby
order = session.find(OrdersExample::Order, order_id)
order.confirm
session.flush
```

There is no `order.save`. The entity's job is to change legally; the session's
job is to follow managed changes. Removing an entity uses `session.remove(order)`.
The session then prevents it from reappearing through `find` or a query. A
managed identity cannot change, including before its first flush.

Hydration gives domain fields their own editable copies. Changing a loaded
string cannot mutate the transaction's stored row by alias. Conversely, stored
rows are values rather than references to your domain objects. This separation
is the foundation of both rollback isolation and independent sessions.

## Map a value object through a converter

A value object can have a domain representation different from its column:

```ruby
Money = Data.define(:cents)
converter = ObjectFramework::Persistence::Converter.new(
  dump: ->(money) { money&.cents },
  load: ->(cents) { cents && Money.new(cents:) }
)

# In a mapping for a class whose constructor accepts total:
field :total, column: :total_cents, type: :integer, converter:
```

The converter owns representation, such as cents to `Money`. It should not
decide whether a particular order may have that total. The constructor and
domain methods still own that rule. External conversion also lets storage
types remain small and portable: strings, integers, floats, booleans, and blobs.

The [mapper scenarios](https://github.com/gstn-caruso/ruby-object-framework/blob/main/test/mapper_test.rb)
exercise a money converter, mutable field isolation, immutable identities,
change tracking, removals, and associations.

## Understand snapshot and commit behavior

HashMap transactions start from a snapshot and keep private modifications.
Other transactions cannot observe those private rows. A write commit checks the
storage revision and publishes all its changes under a mutex. If another writer
has advanced that revision, the stale writer receives `Conflict` and publishes
nothing.

The revision check is deliberately conservative: independent writes to
different rows can conflict. It gives the first adapter a simple, reviewable
atomicity rule. A more selective conflict policy would require more metadata
and a stronger contract about which reads and writes must be validated.

A domain exception before commit triggers rollback. Do not return the managed
order as the operation result; construct `Confirmation` while the session is
open. Invocation materializes the value before flushing and committing. If the
caller later changes its own presentation model, storage remains unaffected.

Schema columns not exposed by the mapping are preserved from the baseline
when an entity is updated. They also do not make an unchanged read appear
dirty. This supports an incremental schema change without forcing every
application projection to expose every column immediately.

## Next step

[Queries and associations](queries_and_associations.md) extends a single entity
into an explicit object graph. As an exercise, add two orders to one transaction,
raise before commit, and verify through a fresh session that neither became
visible. Then make two concurrent writers and inspect which one wins.
