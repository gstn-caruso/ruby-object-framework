This guide gives failures a public meaning without exposing internal messages.
You will observe missing and rejected orders, register an ordinary exception,
and trace what rollback, commit, presentation, sending, and cleanup mean for the
same interaction.

Start with the endpoint in [Building an HTTP API](http_apis.md). Keep business
exceptions in the domain or application namespace; a transport's status is a
representation of that failure, not the failure's identity.

## Register an exception before startup

The order example defines `OrdersExample::OrderNotConfirmable` as an ordinary
`StandardError` subclass. Its composition root declares the public meaning with
[`ErrorRegistry#register`](api/ObjectFramework/ErrorRegistry.html#method-i-register):

```ruby
app.errors.register(
  OrdersExample::OrderNotConfirmable,
  category: :conflict,
  code: "order_not_confirmable",
  title: "Order cannot be confirmed"
)
```

The domain does not inherit from a framework exception. Registration belongs
to application composition because that is where domain meaning meets the
framework's public error vocabulary.

[`ErrorRegistry#resolve`](api/ObjectFramework/ErrorRegistry.html#method-i-resolve)
selects the closest registered ancestor. A specialized rejection can
therefore have its own code while other errors use a parent registration.
Duplicate classes and ambiguous public codes fail during configuration or
startup. Registrations become stable when the application starts.

An optional `details:` callable explicitly extracts safe values:

```ruby
class InvalidQuantity < StandardError; end

app.errors.register(InvalidQuantity, category: :invalid_input,
  code: "invalid_quantity", title: "Quantity is invalid",
  details: ->(error) { { violations: [{ field: "quantity", rule: "positive" }] } })
```

The extractor owns the decision to make those fields public. Copying an entire
exception, input hash, or SQL message would give internal state a public
contract and could include secrets. Unexpected exceptions receive the generic
`internal_error` description.

## Observe absence and business rejection

Run the self-contained error example:

<!-- example: examples/guides/08_errors.rb -->

```sh
ruby -Ilib examples/guides/08_errors.rb
```

Expected output:

```text
404 not_found
Occurrence ID present: true
409 order_not_confirmable
Occurrence ID present: true
```

Absence means that the requested identity could not be recovered. Rejection
means that an existing order's state makes the intention illegal. A transaction
conflict is different again: the operation could not publish a stale snapshot.
Giving these cases distinct codes lets a caller react without parsing English
exception messages.

## Read a problem response

[`HTTP::ProblemPresenter`](api/ObjectFramework/HTTP/ProblemPresenter.html)
formats errors as `application/problem+json`, following
[RFC 9457](https://www.rfc-editor.org/rfc/rfc9457.html). A rejected order has the
following shape; occurrence identifiers vary on every interaction:

```json
{
  "type": "urn:object-framework:error:order_not_confirmable",
  "title": "Order cannot be confirmed",
  "status": 409,
  "instance": "urn:uuid:SERVER_GENERATED_UUID",
  "code": "order_not_confirmable",
  "operation_id": "SERVER_GENERATED_UUID"
}
```

`code` is a stable application-facing name. `operation_id` identifies this
occurrence and connects it to diagnostics. The server generates that identifier;
an untrusted inbound header does not replace it. Public details and field
violations appear only when an extractor declares them.

HTTP and gRPC use separate presenters over the same registry. For example,
absence becomes HTTP 404 or gRPC `NOT_FOUND`, a business-state conflict becomes
HTTP 409 or `FAILED_PRECONDITION`, and a transaction conflict becomes HTTP 409
or `ABORTED`. Unknown RPC methods have their own `UNIMPLEMENTED` meaning.

## Locate the commit boundary

The most useful diagnostic question is whether effects were committed:

| Failure point | Storage consequence | Transport consequence |
| --- | --- | --- |
| Factory, decoder, use case, or materialization before commit | Roll back an active transaction and discard its session. | Present the classified failure if a response can be sent. |
| Commit | Preserve the adapter's known outcome, or mark it indeterminate. | Return the failure; do not repeat the write automatically. |
| Presentation after commit | Effects remain committed. | Present a failure if the response has not begun. |
| Sending after response bytes | Effects remain committed. | HTTP closes; gRPC finishes with an error status when possible. |
| Rollback or close during another failure | Keep the original failure primary. | Record the cleanup failure separately. |

Materializing public values before commit avoids one preventable late failure:
discovering that a use case returned a managed or cyclic object. Other late
failures remain possible because a durable database and a remote client cannot
be committed atomically by one local transaction.

An indeterminate outcome is not a synonym for rollback. If a connection is lost
while acknowledging a commit and the adapter cannot determine the result,
blindly replaying the operation may repeat its effects. The framework therefore
does not retry writes automatically. Application-level idempotency needs a
business key and a deliberate persistence design.

## Record one primary failure

Supply a diagnostic sink to
[`FailureReporter`](api/ObjectFramework/FailureReporter.html) when constructing
the application:

```ruby
errors = ObjectFramework::ErrorRegistry.new
reporter = ObjectFramework::FailureReporter.new(
  registry: errors,
  sink: ->(record) { warn JSON.generate(record) }
)
app = ObjectFramework::Application.new(errors:, reporter:)
```

Records contain operation ID, public code, exception class, cause class,
backtrace, elapsed duration, transaction state, and a secondary-failure flag.
Exception messages, request bodies, credentials, and SQL values are not copied
into records. Applications choose the sink's retention and access policy.

The context claims one primary diagnostic. A use-case failure reported by
Invocation is not reported again as another primary failure by the controller
boundary. A subsequent rollback, close, error-presenter, or writer failure can
still be recorded as secondary. Failure in the sink does not replace the
exception being reported.

## Cooperate with cancellation

An explicit [`Cancellation`](api/ObjectFramework/Cancellation.html) object
belongs to the interaction. The invocation
checks it before work and before commit; long-running use cases should check it
between bounded steps. Cancellation before commit rolls back. Cancellation
after commit preserves confirmed effects.

If the error presenter itself fails, HTTP has a predefined minimal 500 response
and gRPC has a generic INTERNAL fallback, provided the transport can still send
one. Once response state makes a replacement impossible, cleanup and accurate
diagnostics remain the boundary's responsibility.

The [invocation tests](https://github.com/gstn-caruso/ruby-object-framework/blob/main/test/invocation_test.rb)
and [transport tests](https://github.com/gstn-caruso/ruby-object-framework/blob/main/test/http_server_test.rb)
exercise these distinctions with original-exception identity and transaction
state assertions, rather than checking only a status number.

## Next step

[SQLite and schema evolution](sqlite_and_migrations.md) applies the same
boundary to durable storage. As an exercise, add a specialized order rejection,
register a safe field violation, and confirm that its private exception message
does not appear in the HTTP problem or diagnostic record.
