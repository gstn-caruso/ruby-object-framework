This guide builds order confirmation from collaborating objects. By the end,
you will be able to locate a business rule, an application intention, a
persistence boundary, and a transport boundary without reading the entire
framework.

Read [Your first application](getting_started.md) first. The complete domain
example lives in `examples/orders/domain.rb` and runs without requiring the
framework.

## Begin with a business decision

An order starts pending, has a nonnegative total, and can be confirmed once if
its total is positive. The object that owns that state also owns the decision:

```ruby
class Order
  attr_reader :state, :total_cents

  def confirm
    raise OrderNotConfirmable unless state == "pending" && total_cents.positive?
    @state = "confirmed"
  end
end
```

The complete class checks constructor invariants too. A negative total or an
unknown initial state is rejected during construction. `confirm` checks the
invariant that depends on the order's current state.

Keeping this decision on `Order` means an HTTP controller, an RPC controller,
and a command-line caller all encounter the same rule. If a controller set
`state = "confirmed"` itself, every transport would have to remember both the
state transition and the conditions that make it legal.

## Name the complete intention

`ConfirmOrder` coordinates the intention using an injected repository:

```ruby
class ConfirmOrder
  def initialize(orders:)
    @orders = orders
  end

  def call(order_id:)
    order = @orders.fetch(order_id)
    order.confirm
    Confirmation.new(id: order.id, state: order.state,
                     total_cents: order.total_cents)
  end
end
```

The use case chooses the collaboration: retrieve this order, ask it to confirm,
and describe the resulting public state. It does not decide whether a cancelled
order can be confirmed. It does not choose a database connection or a response
status. Those decisions belong to collaborators with different reasons to
change.

The result is a `Data` value named `Confirmation`. Its fields are copied by the
invocation before the session closes. A future endpoint can add presentation
fields without giving the caller the managed `Order` itself.

## Exercise the collaboration directly

The following program supplies a tiny repository collaborator and confirms the
order twice:

<!-- example: examples/guides/03_order_domain.rb -->

```sh
ruby examples/guides/03_order_domain.rb
```

Expected output:

```text
confirmed
An order can only be confirmed once
```

The repository double answers exactly the message the use case needs: `fetch`.
It does not imitate a database engine. This test asks whether the collaboration
produces the intended behavior; storage isolation will have its own contract.

Notice that the second call raises an ordinary application exception. Domain
exceptions retain meaning before a transport assigns them a public status.
The HTTP application later registers `OrderNotConfirmable` as a conflict.

## Assign the remaining responsibilities

The running application adds these collaborators:

| Collaborator | Decision it owns |
| --- | --- |
| `Order` | Whether its state transition is legal. |
| `ConfirmOrder` | Which objects collaborate to fulfill confirmation. |
| `Orders` repository | How application code asks for an order. |
| External mapping | How order attributes correspond to stored values. |
| `Session` | Which Ruby object represents an identity during this execution. |
| `Invocation` | Scope creation, materialization, transaction policy, cleanup. |
| HTTP or gRPC controller | How transport input becomes use-case arguments. |
| Presenter | How independent results or public failures become protocol output. |

These are boundaries between decisions, not a requirement to introduce a new
class for every line of code. The greeting used a string as a collaborator.
The repository wrapper is useful here because `fetch(order_id)` expresses an
application need without exposing mapping classes to the use case.

## Follow one execution

<div>
<figure><img src="assets/collaboration.svg" alt="An invocation owns the session and transaction while a use case asks an order to confirm."><figcaption>The invocation owns execution resources; the order owns its invariant.</figcaption></figure>
</div>

For `POST /orders/ready/confirm`, the controller extracts `order_id`. Invocation
opens a write transaction and builds `Orders` with that execution's session.
The repository obtains one `Order` from the session. `ConfirmOrder` sends
`confirm`, builds the confirmation value, and returns. Invocation materializes
that value, flushes changes, commits, and closes resources. Only then does the
presenter construct the response body.

This order has a consequence: failure to send the response can occur after a
successful commit. The client may need to inspect the resource before deciding
whether another command is appropriate. Automatically retrying the intention
would hide that distinction and could repeat effects.

## Compare the tradeoffs

A Data Mapper keeps persistence descriptions outside the domain class. This
allows domain objects to have ordinary constructors and invariant-preserving
methods. It requires explicit mappings, identity tracking, and care when
hydrating an object whose stored state is invalid.

An Active Record design would put more storage behavior on the entity itself.
That can reduce composition code for CRUD applications. This framework chooses
external mapping because the domain object should be able to participate in a
plain Ruby collaboration before storage is present.

Constructor injection makes required collaborators visible. It introduces
factory declarations at the composition root. A hidden container lookup would
save those declarations, but understanding a use case would then require
finding the container's runtime state as well as reading the class.

The same principle applies to transaction ownership. `ConfirmOrder` has one
application intention; `Invocation` applies the declared storage policy around
it. When a streaming controller invokes several intentions, each invocation
can finish its own transaction rather than borrowing the lifetime of a network
stream.

## Inspect the executable evidence

Read the [domain source](https://github.com/gstn-caruso/ruby-object-framework/blob/main/examples/orders/domain.rb),
the [composition root](https://github.com/gstn-caruso/ruby-object-framework/blob/main/examples/orders/application.rb),
and the [order example scenarios](https://github.com/gstn-caruso/ruby-object-framework/blob/main/test/orders_example_test.rb).
The scenarios demonstrate direct invocation, HTTP success, absence, business
rejection, a real concurrent commit conflict, and an unexpected storage error.

## Next step

In [Composition and execution](composition_and_execution.md), give these
collaborators a precise lifetime. As an exercise, add a shipping restriction to
the order: decide whether it depends only on order state or needs another
domain collaborator before choosing where to put the rule.
