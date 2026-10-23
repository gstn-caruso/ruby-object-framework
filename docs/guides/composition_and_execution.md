This guide explains how an application becomes a stable set of descriptions,
then creates independent execution scopes from them. You will observe a scoped
resource being reused within one invocation and closed when that invocation
finishes.

You should understand the roles in
[Objects and responsibilities](objects_and_responsibilities.md). The application
API is intentionally small: beans and factories describe construction,
operations describe intentions and policies, and modules describe startup and
shutdown.

## Declare collaborators before startup

[`Application#factory`](api/ObjectFramework/Application.html#method-i-factory)
registers collaborators with explicit dependencies. Factory blocks receive
those dependencies as keyword arguments:

```ruby
app.factory(:orders, dependencies: [:session]) do |session:|
  Orders.new(session:)
end

app.operation(:confirm_order, use_case: ConfirmOrder,
              dependencies: [:orders], policy: :write)
```

[`Application#operation`](api/ObjectFramework/Application.html#method-i-operation)
binds `ConfirmOrder` to its dependencies and policy.
The `orders` factory belongs to the composition root. `ConfirmOrder` receives
an `Orders` instance; it never needs the factory name. This keeps wiring
decisions visible while leaving the use case independent of the container.

Factories run on demand inside a scope. The scope caches each named result,
so two collaborators depending on `orders` receive the same repository for
that invocation. A later invocation has a new cache and a new use-case object.

The reserved dependencies are `context`, `transaction`, and `session`. Context
is available to every policy. Transaction and session require a storage policy;
session also requires mappings. A factory cannot shadow these names.

## Register request-scoped beans

[`Application#bean`](api/ObjectFramework/Application.html#method-i-bean)
registers an ordinary Ruby class or a builder block. It infers dependencies
from required keyword arguments, so a repository whose constructor is
`initialize(session:)` can be registered directly:

```ruby
app.bean(:orders, Orders)
app.operation(:confirm_order, use_case: ConfirmOrder, policy: :write)
```

`ConfirmOrder#initialize(orders:)` receives the repository, and
`Orders#initialize(session:)` receives this invocation's session. Neither class
needs to inherit from the framework or access the application. Bean names match
constructor keyword names; registration remains explicit rather than scanning
loaded classes.

Beans belong to one invocation. Startup validates their dependency graph without
constructing them. The invocation builds only the beans reached through its
operation's dependencies and caches each named result until that invocation
ends. A second request, including one on the same HTTP connection, builds fresh
instances. Direct calls through `app.invoke` have the same lifetime as requests
entering through HTTP or gRPC operations.

Run a complete example:

<!-- example: examples/guides/14_request_beans.rb -->

```sh
ruby -Ilib examples/guides/14_request_beans.rb
```

Expected output:

```text
Counter closed
Request 1: 1, 2
Counter closed
Request 2: 1, 2
Independent contexts: true
```

The wiring in that example is:

```ruby
app.bean(:counter, RequestCounter, close: true)
app.bean(:first) { |counter:| counter }
app.bean(:second) { |counter:| counter }
app.operation(:count, use_case: CountTwice, policy: :none)
```

Both branches receive the same counter within a request, so its two reads
produce `1, 2`. The next request starts at `1` again. Its counter also receives
a fresh `context`. Only the `counter` registration owns cleanup: the branches
return its instance without registering another `close` call. Cleanup happens
before `app.invoke` returns, including when building a dependent bean or calling
the use case raises.

Only required keywords are inferred. For `initialize(clock: nil)`, Ruby's
default remains in effect even if a `clock` bean exists. Use
`app.bean(:service, Service, dependencies: [:clock])` to inject that optional
keyword explicitly. Operations and builder blocks accept the same override.
For a positional constructor, use a block such as
`app.bean(:client) { |endpoint:| Client.new(endpoint) }`.

Beans and factories use the same registry and scope, so their dependencies can
refer to each other. Missing dependencies, cycles, reserved names, duplicate
registrations, and registration after startup are rejected. Existing
`factory(..., dependencies: [...])` declarations retain their behavior. The
[bean scenarios](https://github.com/gstn-caruso/ruby-object-framework/blob/main/test/beans_test.rb)
exercise concurrent invocations, keep-alive HTTP requests, startup failures,
transaction dependencies, and resource cleanup.

## Observe scope ownership

Run this complete example:

<!-- example: examples/guides/04_scoped_resources.rb -->

```sh
ruby -Ilib examples/guides/04_scoped_resources.rb
```

Expected output:

```text
Same resource: true
opened, closed
```

Both `first` and `second` depend on one named `resource`. `close: true` gives
the scope responsibility for calling its `close` method. Resources close in
reverse construction order. Repeating `app.invoke(:compare)` opens and closes
a second resource; it does not keep the first execution alive.

Use this ownership rule for short-lived collaborators such as a per-execution
client or file handle. Long-lived listener and storage lifecycles belong to
application modules or to explicit outer `ensure` blocks. A factory that closes
a shared singleton would give one request responsibility for another request's
resource.

## Choose an explicit transaction policy

Every operation declares exactly one policy:

| Policy | Behavior |
| --- | --- |
| `:none` | Construct a scope and invoke the use case without storage. |
| `:read` | Open a read transaction and, when mappings exist, a session. |
| `:write` | Open a write transaction, track changes, flush, and commit. |

Read and write operations both close their transactions. The adapter enforces
read-only behavior. Mutating a managed object during a read operation does not
silently upgrade its transaction; flushing the change fails.

The policy is a reviewable part of the operation description. Inferring it
from HTTP methods would make direct callers and other transports behave
differently. Inferring it from the first SQL statement would make resource
ownership depend on a path through application code.

## Follow the invocation boundary

[`Application#invoke`](api/ObjectFramework/Application.html#method-i-invoke)
executes this sequence:

1. Check cancellation and create the scope.
2. Open the declared transaction and session.
3. Build scoped collaborators and the ordinary use-case instance.
4. Call the use case and materialize independent public values.
5. Check cancellation, flush managed changes, and commit.
6. Close the session, scoped resources, and transaction in `ensure`.

Materialization happens before commit so that an unsupported result can still
roll back the operation. Presentation happens afterward so that a formatter's
failure cannot falsely imply that committed effects disappeared.

An exception before commit rolls back and discards the scope. If rollback or
close also fails, the original exception remains primary and secondary failures
are reported. Cleanup also runs while a fatal exception unwinds the thread,
although the normal failure boundary classifies `StandardError`.

## Compose application modules

[`Application#install`](api/ObjectFramework/Application.html#method-i-install)
registers a module supplying `name`, `requires`, `configure(application)`,
`start`, and `stop`. It may also supply `validate!`. For example, HTTP and gRPC
servers act as modules:

```ruby
app.install(http_server)
app.install(grpc_server)
app.start
begin
  # The application owns the running listeners here.
ensure
  app.stop
end
```

Startup orders module dependencies, configures all modules, and validates
dependencies, mappings, routes, use cases, and error registrations before any
module starts. Only after validation succeeds are listeners opened. If a later
module fails to start, already-started modules stop in reverse order.

This is a small protocol rather than an inheritance hierarchy. An adapter can
participate without adopting framework-specific lifecycle state in its domain
objects. The cost is explicit composition and the requirement that module
configuration finish before startup.

## Keep execution state local

Create two `Application` instances to host independent applications in one
process. Each owns its registries, factories, and operations. Request-specific
state belongs in locals or scoped collaborators. A controller is usually
long-lived, so storing `@current_session` or `@current_order` on it would mix
concurrent executions.

Inject [`ExecutionContext`](api/ObjectFramework/ExecutionContext.html) through
`context` when a use case needs cooperative cancellation or its operation
identifier. Call [`Cancellation#check!`](api/ObjectFramework/Cancellation.html#method-i-check-21)
between bounded pieces of long work. The cancellation object communicates intent;
the framework does not kill arbitrary Ruby code in the middle of a state change.

The [invocation scenarios](https://github.com/gstn-caruso/ruby-object-framework/blob/main/test/invocation_test.rb)
cover successful commit, rollback, indeterminate commit outcomes, cleanup
failures, cancellation, and fatal unwinding.

## Next step

Read [Data Mapper and sessions](data_mapper_and_sessions.md) to see what the
storage scope actually manages. Before moving on, change the resource example
so that `CompareResources#call` raises, and verify that the `closed` event is
still recorded in an outer rescue or diagnostic sink.
