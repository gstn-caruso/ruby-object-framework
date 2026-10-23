This guide makes a small behavior change with TDD, then follows the protocols
you must preserve when extending the framework. You will run an executable
three-scenario example and learn where unit, storage-contract, transport, and
independent-client tests provide different evidence.

Complete [Your first application](getting_started.md) for environment setup.
The other guides explain the collaborators whose behavior these tests observe.
All test names, public APIs, documentation, and explanatory comments use English.

## Start with an observable scenario

Suppose a price operation adds twenty percent tax. Create
`tmp/price_with_tax.rb` from the repository root (`mkdir -p tmp` if needed).
Begin with a zero-price scenario and the smallest implementation that satisfies
it:

```ruby
require_relative "../test/support/spec"

class PriceWithTax
  def call(cents:)
    0
  end
end

Spec.test "a zero price remains zero" do
  assert_equal 0, PriceWithTax.new.call(cents: 0)
end

exit Spec.run
```

Run `ruby tmp/price_with_tax.rb` and observe the passing zero-price scenario.
That first scenario says what zero means. It does not yet establish the tax
calculation. Insert the next useful distinction above `exit Spec.run`, before
changing the code:

```ruby
Spec.test "a price includes twenty percent tax" do
  assert_equal 1200, PriceWithTax.new.call(cents: 1000)
end
```

With the constant implementation, the runner reports `Expected 1200, got 0`.
Observe that failure before replacing the implementation with
`cents + cents / 5`. Next add a negative-price scenario that expects
`ArgumentError`, observe it fail, and add the input rule.

The sequence makes each change answer a demonstrated requirement. It avoids
writing a large implementation and then designing examples around whatever it
already happens to do.

## Run the complete example

The final file includes the project's small dependency-free harness:

<!-- example: examples/guides/13_testing.rb -->

```sh
ruby examples/guides/13_testing.rb
```

Expected output:

```text
PASS a zero price remains zero
PASS a price includes twenty percent tax
PASS negative prices are rejected
3 tests, 0 failures
```

This example chooses whole integer cents and an integer division rule. A real
money policy should define rounding for values that are not divisible by five;
add that requirement as another scenario before treating the example as a tax
library. TDD exposes the current behavioral scope; a green suite does not
invent requirements that have not been stated.

For framework tests, use the version-gated entry point:

```sh
ruby -Ilib:test test/run.rb
ruby -Ilib:test test/run.rb test/mapper_test.rb test/memory_test.rb
```

The assertions include `assert`, `assert_equal`, `assert_same`, and
`assert_raises`. Exception identity matters when verifying that cleanup did not
replace the primary failure. Object identity matters when verifying a session.

## Match the test boundary to the claim

A use-case test can use a small repository double to prove the domain
collaboration. It cannot prove that an adapter rolls back atomically. A socket
test can prove that HEAD sends no body; calling a controller directly cannot.
An encode/decode round trip can pass while both sides share one codec bug.

The repository therefore uses several kinds of evidence:

| Claim | Evidence |
| --- | --- |
| Ordinary objects own business behavior. | Direct order-confirmation scenarios. |
| One session preserves identity and tracks state. | Mapper and invocation scenarios. |
| Storage changes remain isolated and atomic. | Shared contract plus adapter concurrency tests. |
| HTTP framing and admission behave correctly. | Fragmented and malformed raw-socket requests. |
| Protocols work across implementations. | Net::HTTP, grpcio, Google's generated codec, and hyper-h2. |
| Tutorial code agrees with documented output. | Executed example manifest in `test/guides_test.rb`. |

Tests for commit, presentation, and send failures also inspect transaction
outcomes. A 500 response alone cannot establish whether effects were rolled
back or committed.

## Implement a storage adapter against the contract

Register an adapter factory with the reusable suite:

```ruby
StorageContract.register("Your adapter") { build_your_storage }
```

The contract source is
[`test/support/storage_contract.rb`](https://github.com/gstn-caruso/ruby-object-framework/blob/main/test/support/storage_contract.rb).
Your storage must begin independent `:read` and `:write` transactions, as
[`Memory::Storage`](api/ObjectFramework/Memory/Storage.html) and
[`SQLite::Storage`](api/ObjectFramework/SQLite/Storage.html) do. A transaction
follows the [`Persistence::Transaction`](api/ObjectFramework/Persistence/Transaction.html)
lifecycle and provides:

```ruby
find(table, id)                 # A value row, or nil.
query(query_object)             # Independent value rows.
insert(table, row)
update(table, id, replacement_row)
delete(table, id)
commit
rollback
close
state
```

`state` begins `:active` and preserves a known `:committed`, `:rolled_back`, or
`:indeterminate` outcome. `close` is idempotent and releases active resources.
Operations on an inactive transaction raise `ClosedTransaction`, and write
attempts on a read transaction raise `ReadOnlyTransaction`.

Rows must not hold references to domain objects. Duplicate identities,
unavailable storage, and conflicts use the framework's expected exception
vocabulary or explicit error registrations. Do not classify errors by matching
private English engine messages when numeric engine codes exist.

An adapter needing execution-aware acquisition may implement
`begin_transaction_for(mode:, context:)`. Invocation uses it when available;
SQLite uses it to bound lock waits. This extension keeps cancellation explicit
rather than locating the current request in thread-global state.

## Test the adapter's additional semantics

A shared contract covers common guarantees, not every implementation mechanism.
HashMap permits a reader to keep its snapshot after another writer commits and
rejects stale writers by a conservative revision. SQLite's configured DELETE
journal can hold a writer's commit behind an active reader.

Preserve tests for both mechanisms instead of removing a failing concurrency
assertion merely to make adapters look identical. Add tests for lock deadlines,
engine-code translation, connection cleanup, and migrations when those
capabilities exist. State the specific guarantee each scenario establishes.

## Add a module at the composition boundary

[`Application#install`](api/ObjectFramework/Application.html#method-i-install)
registers a module that declares its name and dependencies, configures explicit
factories or operations, validates before startup, starts its resources, and stops them.
Use that protocol for transport or infrastructure integration. Domain classes
continue to receive collaborators through constructors.

For a new transport, translate its input into business arguments and invoke the
same operations. Give it a distinct presenter over the shared error registry.
Test malformed input, cancellation, admission, late failures, and resource
release through the actual protocol, then add an independent client where
possible.

Explanatory source comments are welcome when they preserve the reason for a
protocol constraint or a non-obvious decision. Prefer a short explanation of
why a response cannot replace bytes already sent over a comment that restates
an assignment.

## Contribute to the guides

Guide sources live in `docs/guides`, and the index lives in `guides.yml`.
Complete tutorial programs live in `examples/guides`. An example directive in a
guide includes the actual Ruby file during the build, and the manifest specifies
its expected output. Keep the explanation, runnable program, and assertion in
one change.

Link class and method names to their pages in the
[API reference](api/index.html) where you introduce their behavior. See the
[documentation authoring instructions](https://github.com/gstn-caruso/ruby-object-framework/blob/main/docs/README.md)
for link syntax and RDoc source comments.

Build and preview locally:

```sh
ruby tools/build_guides.rb
python3 -m http.server 9292 --directory _site
```

Open `http://127.0.0.1:9292`. The builder verifies local links and heading
anchors. The published site uses relative asset and guide URLs so it also works
under the repository's GitHub Pages path. CI runs the framework suite and guide
build before publishing its artifact.

## Next step

Choose one small improvement and write the scenario that would make it
necessary. If the improvement changes public behavior, update the relevant
guide and executable example with it. Use the
[design and delivery plan](https://github.com/gstn-caruso/ruby-object-framework/blob/main/PLAN.md)
to check that a local improvement still advances the framework's intended
architecture.
