# ObjectFramework

A modular Ruby framework for applications built from collaborating objects.
Use cases are ordinary Ruby classes, dependencies are explicit, and each
invocation owns its resources and transaction.

Development follows the six deliveries in [PLAN.md](PLAN.md). See the
[implementation record](IMPLEMENTATION.md) for the current delivery status.
The framework is under development; completed delivery gates do not imply that
the remaining transports and storage adapters are available yet.

## Requirements and tests

Ruby **4.0.8** is required. Version files support asdf and other Ruby managers.
The core and test runner use Ruby core and the standard library.

```sh
ruby -Ilib:test test/run.rb
```

Pass test filenames to run selected scenarios:

```sh
ruby -Ilib:test test/run.rb test/core_test.rb test/invocation_test.rb
```

## An ordinary use case

```ruby
require "object_framework"

class Greet
  def initialize(greeting:)
    @greeting = greeting
  end

  def call(name:)
    { message: "#{@greeting}, #{name}" }
  end
end

app = ObjectFramework::Application.new
app.factory(:greeting) { "Hello" }
app.operation(:greet, use_case: Greet, policy: :none, dependencies: [:greeting])
app.start
begin
  app.invoke(:greet, name: "Ada") # => { message: "Hello, Ada" }
ensure
  app.stop
end
```

Every operation declares `:none`, `:read`, or `:write` as its transaction policy.
Transactional operations require a storage adapter. Factories are scoped to an
invocation, may declare their own dependencies, and may opt into cleanup with
`close: true`. The reserved `context` dependency exposes a server-generated
operation identifier and cooperative cancellation. Application registrations
are finalized at startup. Separate application instances have separate registries.

Public results contain independent, immutable values: strings, numbers,
booleans, symbols, nil, arrays, hashes, and `Data` objects composed of these.
Returning an unsupported object or a cycle fails before commit. Managed domain
objects must be converted to values inside the use case.

## Errors and diagnostics

Register ordinary exception classes through `app.errors.register`, supplying a
category, stable public code, title, and an optional explicit safe-details
extractor. The closest registered ancestor wins. Unexpected failures receive a
generic public description.

`FailureReporter` accepts a `sink:` callable. It records one primary failure per
interaction, plus cleanup failures marked as secondary. Records contain the
operation identifier, public code, exception and cause classes, backtrace,
duration, and transaction outcome. Exception messages and input values are
excluded to avoid exposing credentials or payloads. Applications should apply
their own retention and access policy to the sink.

Commit outcomes remain `:committed`, `:rolled_back`, or `:indeterminate` when
the adapter can determine them. A failed commit is never automatically retried.
Cancellation is cooperative; use cases doing long work should call
`context.cancellation.check!` at suitable boundaries.

## Contributing

Keep public APIs, tests, documentation, and explanatory comments in English.
Start a behavior change with a failing scenario in the dependency-free runner,
then implement it and run the current delivery gate. Comments explaining
protocol constraints and non-obvious decisions are welcome.

## HTTP order example

```sh
ruby -Ilib examples/orders/server.rb
curl -X POST http://127.0.0.1:8080/orders/ready/confirm
curl -X POST http://127.0.0.1:8080/orders/missing/confirm
curl -X POST http://127.0.0.1:8080/orders/rejected/confirm
```

`ConfirmOrder` collaborates with an injected repository. `Order` owns its
confirmation invariant. An external mapping describes persistence, and an HTTP
controller normalizes path parameters before invoking the operation. The test
suite also demonstrates a concurrent commit conflict and an unexpected storage
failure. The example uses volatile in-memory storage.

HTTP uses a dispatcher with `IO.select` and Fibers, then one new thread per
admitted request. Admission defaults to 128 active requests. Keep-alive requests
run sequentially on separate threads. Limits default to an 8 KiB request line,
32 KiB header section, and 1 MiB body. Header timeout is 10 seconds; body,
execution, write, and idle timeouts are 30 seconds. Execution cancellation is
cooperative. `Server` accepts an application-configured OpenSSL `tls_context:`
with a certificate and private key.

The parser follows [RFC 9112](https://www.rfc-editor.org/rfc/rfc9112.html).
Ambiguous framing closes the connection. Invalid JSON yields 400, invalid
structure yields 422, missing routes yield 404, and wrong methods yield 405 with
`Allow`. Errors use [RFC 9457](https://www.rfc-editor.org/rfc/rfc9457.html)
problem details; presentation and send failures preserve the transaction outcome.

## SQLite

Install the sole optional runtime gem with `bundle install` (or install `sqlite3`
2.10.1 or newer in the 2.x series). Requiring `object_framework` does not load
sqlite3 until `ObjectFramework::SQLite` is used.

```ruby
schema = ObjectFramework::SQLite::Schema.from_mappings(mappings)
storage = ObjectFramework::SQLite::Storage.new(path: "orders.sqlite3", schema:)
app = ObjectFramework::Application.new(storage:, mappings:)
```

Each invocation owns one SQLite connection. Foreign keys are enabled, journal
mode is DELETE, and synchronization is FULL. Writes use IMMEDIATE transactions;
reads use DEFERRED transactions. Lock waiting respects the execution deadline
and a configurable `lock_timeout:` (one second by default). Writes have no
automatic application-level retries. SQL values are bound parameters; table
and column names must belong to the declared schema.

Schema version 1 creates the declared tables. Add consecutive versions before
constructing the storage:

```ruby
schema.migration(2) { add_column :orders, :note, type: :string }
```

Migrations run in a transaction and use SQLite's `user_version`. Startup rejects
newer database versions and mismatched column declarations. DELETE journaling
can delay a writer's commit while a reader remains active; keep invocations
short. Call `storage.close` after stopping applications that use it.
