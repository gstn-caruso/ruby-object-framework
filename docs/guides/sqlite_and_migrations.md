This guide replaces the volatile adapter with SQLite while keeping the order
use case and its domain decisions unchanged. You will create a versioned
schema, add a column, run read and write operations, and verify connection
cleanup.

Read [Data Mapper and sessions](data_mapper_and_sessions.md) and
[Failures and observability](failures_and_observability.md) first. Install the
one optional Ruby runtime gem with `bundle install`.

## Keep the application protocol stable

Both adapters begin a transaction with
[`begin_transaction(mode:)`](api/ObjectFramework/SQLite/Storage.html#method-i-begin_transaction),
then expose row retrieval, query, insert, update, delete, commit, rollback,
close, and state.
The session collaborates with that protocol rather than a database connection
API.

[`SQLite::Schema.from_mappings`](api/ObjectFramework/SQLite/Schema.html#method-c-from_mappings)
derives a schema from existing mappings. Pass it to
[`SQLite::Storage`](api/ObjectFramework/SQLite/Storage.html):

```ruby
schema = ObjectFramework::SQLite::Schema.from_mappings(mappings)
storage = ObjectFramework::SQLite::Storage.new(
  path: "orders.sqlite3", schema:
)
app = ObjectFramework::Application.new(storage:, mappings:)
```

`ObjectFramework::SQLite` loads sqlite3 on demand. Requiring the core framework
does not require that gem. SQLite storage expects a file path; use the memory
adapter for the framework's volatile-storage case.

Schema generation uses mapped column names and types. Belongs-to relationships
produce foreign-key constraints. The supported scalar column types are string,
integer, float, boolean, and blob; domain value objects use converters.

## Evolve a schema deliberately

Schema version 1 creates the declared tables.
[`Schema#migration`](api/ObjectFramework/SQLite/Schema.html#method-i-migration)
adds consecutive versions over that initial definition:

```ruby
schema = ObjectFramework::SQLite::Schema.new(
  tables: { orders: { id: :string, state: :string, total_cents: :integer } }
)
schema.migration(2) { add_column :orders, :note, type: :string }
```

Keep the version-1 definition stable when adding this migration. If the initial
definition already includes `note` and version 2 also adds it, a fresh database
would attempt to add the same column twice. A migration history describes a
sequence, not just the current desired table shape.

The adapter applies pending versions in a transaction and records the result in
SQLite's `user_version`. Startup rejects a database newer than the declared
schema and rejects mismatched column declarations. A failed startup migration
does not justify opening a listener against an uncertain schema.

The initial migration API exposes adding columns. More elaborate transformations
need a deliberate extension and tests for existing and fresh databases; do not
pretend that editing a version number transforms stored data by itself.

## Run the migrated order application

This complete program uses a temporary database, adds a note column, reads an
order through a read-only use case, and confirms it through the original write
operation:

<!-- example: examples/guides/09_sqlite.rb -->

```sh
ruby -Ilib examples/guides/09_sqlite.rb
```

Expected output:

```text
Schema version: 2
Read: pending
Write: confirmed
Unmapped note: gift
Open connections: 0
```

The domain mapping does not yet expose `note`. Preserving that stored value
prevents a partial projection from erasing a newly introduced column during an
unrelated order update. Reading the projection also remains a read; unknown
columns do not create a false dirty change.

The program removes its temporary directory afterward. For persistent data,
use a stable file path and seed only new installations. The order demo's
`OrdersExample.build` intentionally seeds a fresh store; production application
composition should separate initialization data from every restart.

## Understand connection ownership and configuration

Every transactional invocation owns a separate connection. Invocation closes it
after materialization, commit or rollback, and session cleanup. An application
does not lend one mutable SQLite connection to concurrent request threads.

Connections use foreign keys ON and synchronization FULL. The storage is
initialized in DELETE journal mode. Read operations begin DEFERRED transactions;
write operations begin IMMEDIATE transactions. These choices make durability
and writer contention visible rather than dependent on the first query an
application happens to issue.

An IMMEDIATE writer reserves write capability at transaction start. A second
writer can wait for that reservation. A DEFERRED reader establishes its database
snapshot when it reads. With DELETE journaling, an active reader can delay the
writer's commit until the reader finishes.

This differs from HashMap, whose reader can keep a private immutable snapshot
while another transaction publishes a new one. Both adapters isolate private
writes; their locking mechanisms differ. The shared contract tests common
visibility and atomicity, while adapter-specific scenarios test the additional
snapshot and locking behavior.

## Bound lock waits by the interaction

`lock_timeout:` defaults to one second. Invocation passes the explicit context
to adapters implementing `begin_transaction_for(mode:, context:)`; SQLite uses
that context's cancellation and deadline while waiting for locks.

```ruby
cancellation = ObjectFramework::Cancellation.new(
  deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.05
)
context = ObjectFramework::ExecutionContext.new(cancellation:)
app.invoke(:confirm_order, context:, order_id: "ready")
```

If another writer holds the reservation, this operation cannot wait past its
execution deadline merely because the storage's lock timeout is longer. The
failure still follows the ordinary rollback and public translation boundary.
Waiting for a lock is not an application-level replay of the write intention.

## Bind data, register identifiers

The adapter binds field values as statement parameters. Query and modification
identifiers must belong to the declared schema. An input string resembling SQL
remains a value, and an unknown column is rejected as configuration misuse.

Engine failures are classified by numeric result codes, including extended
constraint codes. Duplicate identities become `Duplicate`; foreign-key and
field constraints become `InvalidInput`; temporary lock and IO availability
failures become `Unavailable`. Commit handling preserves known outcomes and
uses an indeterminate state when the result cannot be established safely.

See [SQLite's transaction documentation](https://sqlite.org/lang_transaction.html)
for the engine's locking semantics and the
[adapter scenarios](https://github.com/gstn-caruso/ruby-object-framework/blob/main/test/sqlite_test.rb)
for the framework's contracts and deadline assertions.

## Next step

In [gRPC and streaming](grpc_and_streaming.md), reuse the same operation through
a second transport. As an exercise, run two writer invocations against one
database file, give the second a short deadline, and inspect its public error
and the absence of leaked connections.
