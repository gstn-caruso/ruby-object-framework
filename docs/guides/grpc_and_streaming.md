This guide gives the order-confirmation use case a Protocol Buffers contract
and a gRPC controller, then explains how the same execution boundary extends to
streaming. You will export a `.proto` file and call the native Ruby server with
an independent generated Python codec.

Read [Building an HTTP API](http_apis.md) and
[Failures and observability](failures_and_observability.md). Prepare the Python
test environment from [Your first application](getting_started.md); those
packages belong to the client and verification tooling, not the Ruby server.

## Describe messages as Ruby objects

`examples/orders/contracts.rb` declares the public request and result:

```ruby
request = ObjectFramework::Protobuf::Message.new("ConfirmOrderRequest") do
  field :order_id, 1, :string
end

confirmation = ObjectFramework::Protobuf::Message.new("OrderConfirmation") do
  field :id, 1, :string
  field :state, 2, :string
  field :total_cents, 3, :int64
end

service = ObjectFramework::GRPC::Service.new("orders.Orders")
service.rpc(:ConfirmOrder, input: request, output: confirmation,
            controller: :confirm_order)
```

The number is the field's wire identity. Renaming a Ruby field while keeping
its number is a different compatibility decision from reusing that number for
another meaning. Descriptors reject duplicate and reserved field numbers and
ambiguous exported type names.

The initial codec supports all proto3 scalar wire types, enums, nested messages,
and repeated fields. Repeated numeric values accept packed and unpacked input.
Unknown fields are skipped, and unknown enum numbers remain numbers so that an
older reader can still receive a newer enum value. Features such as oneof and
map declarations are outside this initial descriptor API.

Proto3 scalars have defaults. A missing `order_id` decodes to an empty string;
the decoder cannot infer an application's requirement that it be nonempty.
Validate that business input explicitly when the operation needs that rule.

## Bind the same intention

```ruby
controller = ObjectFramework::GRPC::Controller.new(
  application: app, operation: :confirm_order
)
server = ObjectFramework::GRPC::Server.new(
  application: app, services: [service],
  controllers: { confirm_order: controller }, port: 50051
)
app.install(server)
```

The gRPC controller passes decoded business arguments to `app.invoke` with the
RPC's explicit context. HTTP had a path-to-argument normalization step. gRPC has
a typed message-to-argument boundary. `ConfirmOrder`, `Order`, the repository,
and the write policy are the same collaborators in both cases.

Run both transports over one application:

```sh
ruby -Ilib examples/orders/grpc_server.rb
```

Export the contract in a second terminal:

```sh
ruby -Ilib examples/orders/export_proto.rb > orders.proto
.venv/bin/python examples/orders/grpc_client.py 50051 orders.proto ready
```

Expected client output:

```text
ready: confirmed
```

The client compiles the exported contract with Google's compiler and uses
grpcio's transport. Agreement therefore tests the public wire format across
implementations. It is stronger evidence than encoding and decoding a message
with the same Ruby code.

## Run the complete example in one process

This executable program starts the application, writes the contract to a
temporary file, invokes the independent client, and cleans up:

<!-- example: examples/guides/10_grpc.rb -->

```sh
ruby -Ilib examples/guides/10_grpc.rb
```

Its output is `ready: confirmed`. The Ruby server does not load grpc, protobuf,
or HTTP/2 gems. It implements the planned HTTP/2, HPACK, message framing, and
codec protocols using Ruby and the standard library. That choice keeps runtime
dependencies small and makes protocol behavior explicit; it also makes
interoperability tests a continuing responsibility of this project.

## Select a streaming shape

`Service#rpc` declares streaming direction with `client_streaming:` and
`server_streaming:`. A controller still implements `call(input, context:)`:

| RPC shape | Input | Return value |
| --- | --- | --- |
| Unary | One decoded message hash. | One message value. |
| Server streaming | One decoded message hash. | An enumerable of message values. |
| Client streaming | An enumerable of decoded messages. | One message value. |
| Bidirectional | An enumerable of decoded messages. | An enumerable of message values. |

A bidirectional transformation can be lazy:

```ruby
chat = ->(messages, context:) do
  messages.lazy.map { |message| { text: message[:text].upcase } }
end

service.rpc(:Chat, input: request, output: reply, controller: :chat,
            client_streaming: true, server_streaming: true)
```

Here `request` and `reply` need matching `text` fields. The complete all-mode
example is exercised in
[the gRPC scenarios](https://github.com/gstn-caruso/ruby-object-framework/blob/main/test/grpc_server_test.rb).
A unary method requires exactly one input message; missing or extra messages
are structural errors.

## Keep transactions shorter than streams

A network stream may be long-lived. Holding a database transaction for that
entire lifetime would retain locks and a managed graph while waiting for
unrelated client activity. Invoke complete intentions per message or batch:

```ruby
controller = ->(messages, context:) do
  messages.lazy.map do |message|
    app.invoke(:append_message, context:, **message)
  end
end
```

Each invocation creates and closes its own session before yielding an
independent result. If the stream fails after two committed messages, those two
effects remain confirmed. The gRPC status describes the stream's failure; it
does not roll back earlier transactions.

The suite verifies this with a bidirectional stream that commits two messages,
then raises. The independent client receives INTERNAL and a fresh transaction
still finds both stored messages.

## Follow deadlines, capacity, and flow control

Each admitted RPC has one new thread. A stream's messages belong to that call;
they do not create a new request thread per message. Admission defaults to 128
active calls across connections. Excess calls receive RESOURCE_EXHAUSTED before
another RPC thread is created.

HTTP/2 connection and stream windows bound transport buffering. Incoming
capacity is returned as the request consumes bytes. Outgoing DATA waits for peer
window capacity. A slow client therefore cannot turn a stream into an unbounded
outgoing queue. Message and header limits default to 1 MiB and 32 KiB, with a
default 128 connections.

`grpc-timeout` sets an interaction deadline bounded by the configured execution
timeout. `RST_STREAM` cancellation reaches the explicit cancellation object.
Controllers and long use cases check it cooperatively. Message compression is
identity in this version. TLS accepts application certificates and negotiates
`h2` through ALPN.

## Read the final status

Responses carry `grpc-status` in trailers, including successful streams.
Failures include a safe percent-encoded `grpc-message`, `error-code`, and the
server-generated `operation-id`. A failure after values have been emitted can
still end the stream with an error status when the connection remains usable.

The independent tests cover grpcio, Google's scalar codec, and hyper-h2. They
exercise large messages, header continuations, TLS verification, admission,
deadlines, cancellation, late failure, and a stream error that leaves other
streams on the connection usable. Protocol references are
[HTTP/2](https://www.rfc-editor.org/rfc/rfc9113.html),
[HPACK](https://www.rfc-editor.org/rfc/rfc7541.html), and
[gRPC over HTTP/2](https://github.com/grpc/grpc/blob/master/doc/PROTOCOL-HTTP2.md).

## Next step

[Concurrency and Ruby capabilities](concurrency_and_ruby.md) explains who owns
state while these protocols run. As an exercise, write a client-streaming
controller that aggregates a batch, then decide whether each message or the
whole batch is the complete transactional intention.
