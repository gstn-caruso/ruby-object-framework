# ObjectFramework

A modular Ruby framework for applications built from collaborating objects.
Use cases are ordinary Ruby classes, dependencies are explicit, and each
invocation owns its resources and transaction.

Read the [ObjectFramework Guides](https://gstn-caruso.github.io/ruby-object-framework/)
for progressive tutorials, executable examples, and the reasoning behind the
framework's design. Start with [Your first application](https://gstn-caruso.github.io/ruby-object-framework/getting_started.html).

Development follows the six deliveries in [PLAN.md](PLAN.md). See the
[implementation record](IMPLEMENTATION.md) for the current delivery status.
The initial implementation includes HTTP/1.1, native gRPC streaming, HashMap and
SQLite persistence, and optional Ruby execution capabilities.

## Installation

Install the gem on Ruby 4.0.8:

```sh
gem install ruby-object-framework
```

Or add it to your application's Gemfile:

```ruby
gem "ruby-object-framework", require: "object_framework"
```

Load the framework with `require "object_framework"`. The gem includes all
framework modules and runnable examples. SQLite remains optional; applications
using that adapter must also declare `gem "sqlite3", "~> 2.10", ">= 2.10.1"`.

## Automatic releases

After verification succeeds on `main`, semantic-release updates the Ruby version
and lockfile, creates a version tag, publishes to RubyGems.org, and attaches the
gem and release notes to a GitHub release. Breaking changes increment major,
`feat` increments minor, and other changes increment patch, including docs-only
merges. The first automated release is `1.0.0`.

See [release setup and recovery](docs/RELEASING.md) for the one-time RubyGems
trusted-publisher registration and local packaging commands.

## Requirements and tests

Ruby **4.0.8** is required. Version files support asdf and other Ruby managers.
The core and test runner use Ruby core and the standard library.

```sh
ruby -Ilib:test test/run.rb
```

For the full interoperability gate, prepare the independent Python clients:

```sh
bundle install
python3 -m venv .venv
.venv/bin/python -m pip install -r test/interop/requirements.txt
ruby -Ilib:test test/run.rb
```

Python dependencies are test clients; the framework does not load them. Set
`OBJECT_FRAMEWORK_INTEROP_PYTHON` to use an existing test environment.

Pass test filenames to run selected scenarios:

```sh
ruby -Ilib:test test/run.rb test/core_test.rb test/invocation_test.rb
```

Release tooling requires Node.js 24.10 or newer and is only used in development
and CI. Verify its version rules and release cycle with:

```sh
npm ci --ignore-scripts
npm test
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

## gRPC

Run the same order use case through HTTP and gRPC:

```sh
ruby -Ilib examples/orders/grpc_server.rb
ruby -Ilib examples/orders/export_proto.rb > orders.proto
```

The gRPC service is `orders.Orders/ConfirmOrder`. The framework implements
HTTP/2, HPACK, proto3 wire encoding, gRPC framing, and trailers in Ruby. Message
and service descriptors are Ruby objects that export `.proto` contracts.
Unary, server streaming, client streaming, and bidirectional calls each receive
one new request thread. Streaming controllers invoke use cases per message or
batch so that sessions and transactions finish before yielding public values.

Requests default to a 1 MiB message limit, a 32 KiB header limit, 128 active RPCs,
and 128 connections. Both connection and stream windows bound inbound buffering
and outgoing DATA. Deadlines and `RST_STREAM` cancellation reach the explicit
context. Responses carry `grpc-status`, a safe `grpc-message` when needed,
`error-code`, and `operation-id`. Message compression currently uses identity.
TLS accepts application certificates and negotiates `h2` through ALPN.

Interop tests use Python grpcio, Google's generated protobuf codec, and
hyper-h2. They cover every RPC mode, every scalar type, large messages, header
continuations, error metadata, TLS, admission, deadlines, cancellation, and
failure after a stream has produced values. Protocol references are
[HTTP/2](https://www.rfc-editor.org/rfc/rfc9113.html),
[HPACK](https://www.rfc-editor.org/rfc/rfc7541.html), and the
[gRPC wire protocol](https://github.com/grpc/grpc/blob/master/doc/PROTOCOL-HTTP2.md).

## Optional Ruby capabilities

`ObjectFramework::Capabilities::Definitions` wraps Ruby Box. Start Ruby with
`RUBY_BOX=1`; enabling the variable later cannot change the running VM.
Separate instances load their own application definitions. Ruby Box remains
experimental, so the ordinary composition path does not require it.

`Capabilities::IsolatedTask.new(task: YourTask)` runs a class/module's
`self.call(input)` in a new Ractor. Inputs and results are independent values;
sessions and execution contexts stay on the owning request thread. Tasks should
be bounded computations over values. Cancellation is checked before and after
the isolated task; it does not forcibly terminate a running Ractor.

`ruby benchmark/compare.rb 20000 3` compares interpreter, YJIT, and ZJIT in
separate processes. See [the benchmark notes](benchmark/README.md) for the
workload, raw results, and limits of the comparison.
