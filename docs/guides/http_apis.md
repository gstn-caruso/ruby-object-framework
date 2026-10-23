This guide exposes `ConfirmOrder` as `POST /orders/:id/confirm`. You will build
the route, controller, parameter declaration, and listener, then call the
endpoint with an independent HTTP client.

You should understand the use case from
[Objects and responsibilities](objects_and_responsibilities.md) and the scoped
session from [Data Mapper and sessions](data_mapper_and_sessions.md). The supplied
application uses HashMap storage and starts with `ready` and `rejected` orders.

## Bind transport input to business arguments

The domain operation accepts `order_id:`. HTTP supplies that identity as a path
segment named `id`. Make the translation explicit:

```ruby
parameters = ObjectFramework::HTTP::Parameters.new do
  field :order_id, source: :path, key: :id, type: String
end

controller = ObjectFramework::HTTP::Controller.new(
  application: app, operation: :confirm_order, parameters:
)
```

The controller owns transport interpretation. `ConfirmOrder` continues to
receive business arguments and injected collaborators. It does not need a
request object, a header map, or HTTP-specific exception classes.

Parameter declarations select fields from `:path`, `:query`, or `:body`.
Required fields are required by default; `required: false` omits an absent field
so that the use case can apply its own keyword default. Query and path numbers
can be normalized to `Integer` or `Float`; JSON body values must already have
the declared type.

This is structural validation. The domain still decides whether a correctly
typed order can be confirmed. A string identity can be well formed yet refer to
no order; an existing order can still reject the transition.

## Register a route and start the listener

```ruby
router = ObjectFramework::HTTP::Router.new
router.controller(:confirm_order, controller)
router.route("POST", "/orders/:id/confirm", controller: :confirm_order)

server = ObjectFramework::HTTP::Server.new(
  application: app, router:, host: "127.0.0.1", port: 8080
)
app.install(server)
app.start
```

The router validates registered controller bindings and their operation names
at startup. Named path segments are decoded before parameter normalization.
Static routes take precedence over parameterized routes, and duplicate patterns
for one method are rejected.

Run the complete existing composition root:

```sh
ruby -Ilib examples/orders/server.rb
```

In another terminal:

```sh
curl -X POST http://127.0.0.1:8080/orders/ready/confirm
```

The response is HTTP 200 and its JSON contains:

```json
{"id":"ready","state":"confirmed","total_cents":1500}
```

The example process keeps that confirmed state until it stops. A second
confirmation is rejected with 409. Restarting the process recreates its
in-memory seed data.

## Run a self-contained client example

This program starts on an assigned local port, calls the endpoint with
`Net::HTTP`, and closes the application:

<!-- example: examples/guides/07_http.rb -->

```sh
ruby -Ilib examples/guides/07_http.rb
```

Expected output:

```text
HTTP 200
Order state: confirmed
```

The client is separate from the framework's parser and writer. It verifies
public behavior rather than repeating an internal method call.

## Read the request path

The dispatcher recognizes headers and reserves capacity. Each admitted request
gets a new thread, which completes the body, decodes JSON, resolves the route,
normalizes arguments, and calls the controller. Invocation materializes the
result and commits before the presenter and writer send it.

Keep-alive reuses a connection, but sequential requests on that connection get
different request threads and contexts. This prevents a connection's lifetime
from accidentally becoming a session's lifetime. The dispatcher uses
`IO.select` and Fibers for connection progress; the application work belongs to
the admitted request thread.

The default active-request limit is 128. Excess requests receive 503 before
another request thread is created. There is also a configurable connection
limit, defaulting to 1,024. Holding connections and executing application work
are separate kinds of capacity.

## Know the HTTP behavior

Routes that do not exist produce 404. A path with a different registered method
produces 405 and an `Allow` header. GET routes support HEAD through the same
controller, with the response body suppressed. Keep GET operations safe to read:
HEAD does not make an unsafe GET use case harmless. OPTIONS describes allowed
methods without invoking the route's use case.

Nonempty request bodies require `application/json`. Invalid JSON syntax yields
400; a valid JSON array where an object is required yields 422. Declared
parameter type failures also yield 422. Unsupported content types yield 415.
Errors are public problem documents, explained in the next guide.

The parser supports Content-Length and chunked request bodies. Ambiguous framing,
such as both Content-Length and Transfer-Encoding, is rejected and the
connection closes. A later pipelined request is not executed through the
ambiguous body. This strictness follows the framing responsibilities in
[RFC 9112](https://www.rfc-editor.org/rfc/rfc9112.html).

## Configure limits and TLS

Construct a `Parser` with `line_limit:`, `header_limit:`, and `body_limit:` to
change the defaults of 8 KiB, 32 KiB, and 1 MiB. Pass it as `parser:` to the
server. Timeouts are constructor options: `header_timeout:` defaults to 10
seconds; body, execution, idle, and write timeouts default to 30 seconds.

The execution deadline is cooperative. A use case doing long Ruby work should
check `context.cancellation.check!` between bounded steps. Responses are
materialized in memory, so choose limits appropriate to the application's
public results as well as its input.

For TLS, supply an application-configured `OpenSSL::SSL::SSLContext` containing
`cert` and `key` as `tls_context:`. Startup validates that both are present
before opening the listener. Certificate acquisition and rotation belong to the
application or deployment environment.

The [HTTP scenarios](https://github.com/gstn-caruso/ruby-object-framework/blob/main/test/http_server_test.rb)
cover fragmentation, keep-alive, pipelining, chunking, saturation, deadlines,
TLS, independent clients, and late send failures.

## Next step

[Failures and observability](failures_and_observability.md) follows the error
path through the same objects. Try the `missing` and `rejected` identities and
explain why one is absence while the other is a business-state conflict.
