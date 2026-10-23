This guide follows state ownership through concurrent requests, then introduces
the optional Ruby features used for definition isolation, isolated computation,
and execution-mode measurements. You will run a Ractor task and two independent
Ruby Boxes, and reproduce a three-mode benchmark.

Read [Composition and execution](composition_and_execution.md) and
[gRPC and streaming](grpc_and_streaming.md). The ordinary application does not
need these optional capabilities to serve requests or persist data.

## Separate connection progress from application ownership

[`HTTP::Server`](api/ObjectFramework/HTTP/Server.html) has a dispatcher that
progresses HTTP/1.1 connections through IO readiness and
header parsing. An admitted request gets a fresh thread, which owns body
decoding, controller execution, the use-case invocation, and response sending.
Keep-alive returns the connection for another sequential request; it does not
reuse that request's session.

HTTP/2 has connection-level frame processing and independently admitted RPC
threads. A bidirectional stream is one call with several messages. Connection
state such as HPACK tables and flow-control windows is distinct from the
session created by an application intention.

The thread-per-admitted-request decision makes ownership explicit and supports
ordinary blocking Ruby application code. It incurs thread creation and scheduling
costs. A worker pool would have a different reuse model, while an all-Fiber
application would need stronger expectations about nonblocking collaborators.
The framework follows the chosen request-thread model and measures it rather
than hiding those costs.

## Use admission as a resource boundary

Admission limits active application work. HTTP returns 503 and gRPC returns
RESOURCE_EXHAUSTED when capacity is unavailable. Both reject before creating
another application request thread. A connection cap limits another resource:
clients that hold sockets but have not produced an admitted intention.

For streaming, flow control limits bytes rather than intentions. A client may
own one RPC slot while producing or consuming data slowly. Connection and stream
windows stop that interaction from accumulating an unbounded transport queue.
Use message limits, execution deadlines, and application batch sizes alongside
the count of active requests.

The [HTTP tests](https://github.com/gstn-caruso/ruby-object-framework/blob/main/test/http_server_test.rb)
verify different threads on one keep-alive connection. The
[gRPC tests](https://github.com/gstn-caruso/ruby-object-framework/blob/main/test/grpc_server_test.rb)
verify global admission across connections and large messages crossing several
flow-control windows.

## Keep sessions on their request thread

An execution scope is a useful ownership boundary even when other Ruby
concurrency tools are available. A session contains an identity map, mutable
domain objects, and a unit of work. Moving that graph to another executor would
move responsibility for its transaction and cleanup too.

Instead, materialize independent input values for an isolated computation and
bring independent results back to the owner. The request can then decide what
those values mean for its domain operation.

## Run an isolated Ractor task

[`Capabilities::IsolatedTask`](api/ObjectFramework/Capabilities/IsolatedTask.html)
executes a class or module implementing `self.call(input)`:

<!-- example: examples/guides/11_ractor.rb -->

```sh
ruby -Ilib examples/guides/11_ractor.rb
```

Expected output, apart from Ruby's experimental-feature warning:

```text
Total: 6
Request thread preserved: true
```

The adapter copies input into the framework's independent value representation
and creates a Ractor with the task class and payload. It waits for the result
and returns independent values on the original calling thread. A session or an
arbitrary managed object is rejected before crossing that boundary.

The task should be a bounded computation over its input. Class-level mutable
state and captured outer variables are subject to Ruby's Ractor restrictions.
Task failures return as `Capabilities::TaskFailure`, with `remote_class` and a
backtrace available for diagnostics; the ordinary public boundary can still
present a generic failure.

You may pass `context:` to check cancellation before and after the task. This
does not forcibly interrupt a Ractor already computing. Splitting work into
bounded tasks is therefore part of choosing this executor. Starting a Ractor
for tiny work can cost more than doing that work on the request thread.

## Isolate definitions with Ruby Box

Ruby Box isolates application definitions and monkey patches inside one Ruby
process. Enable it when starting Ruby; changing the environment variable after
the process starts cannot enable the VM feature:

```sh
RUBY_BOX=1 ruby -Ilib examples/guides/12_box.rb
```

The executable example is:

<!-- example: examples/guides/12_box.rb -->

Expected output:

```text
first application
second application
Definitions leaked: false
```

[`Definitions#load`](api/ObjectFramework/Capabilities/Definitions.html#method-i-load)
loads a trusted application file into that box;
[`constant(:YourUseCase)`](api/ObjectFramework/Capabilities/Definitions.html#method-i-constant)
obtains the class to compose into an application.
[`evaluate`](api/ObjectFramework/Capabilities/Definitions.html#method-i-evaluate)
is useful for small definition experiments such as this example.
Two ordinary `Application` objects already have separate registries. Ruby Box
adds isolation for Ruby definitions that would otherwise share a constant
namespace.

This is definition isolation within a process, not an OS process or a security
sandbox for untrusted programs. Ruby Box remains experimental and has known
interactions with native extensions. The default framework path therefore
keeps it optional. See [Ruby's Box documentation](https://docs.ruby-lang.org/en/4.0/Ruby/Box.html)
for the VM's exact isolation behavior.

## Measure interpreter, YJIT, and ZJIT

A JIT changes execution of Ruby code; it does not change which object owns a
session or which thread owns an interaction. Build Ruby 4.0.8 with both JITs
available, then run:

```sh
ruby benchmark/compare.rb 20000 3 > benchmark/results.json
```

The script starts separate interpreter, YJIT, and ZJIT processes. Each performs
2,000 warmup invocations followed by the requested measured iterations. It
checks that the requested engine is actually enabled and that each sample
produces the same checksum.

The workload constructs scoped collaborators, calculates an integer result,
and detaches a public value. The output records the Ruby build, measurement
date, raw durations, allocations, and medians. The checked-in run measured
approximately 0.091 seconds for the interpreter, 0.050 for YJIT, and 0.061 for
ZJIT across 20,000 calls.

Those results describe one small workload on one development machine. Network
waiting, SQLite locks, JIT warmup, memory use, and larger domain computations
can change the comparison. Use the script's explicit workload and raw samples
as a starting point for a representative application measurement rather than
as a deployment-wide speed claim.

## Make cancellation cooperative

Call [`Cancellation#check!`](api/ObjectFramework/Cancellation.html#method-i-check-21)
through `context.cancellation` between pieces of application work. The
invocation also checks before work and before commit. HTTP body and header
deadlines govern transport reading; gRPC deadlines also govern waiting for
messages and flow-control capacity.

A deadline tells collaborators when work should stop. It does not make a
committed transaction disappear, and it cannot safely kill arbitrary Ruby code
while that code mutates an object. Explicit checks and bounded tasks give the
application a point where it can stop consistently.

## Next step

[Testing and extending](testing_and_extending.md) shows how to verify a new
behavior and preserve these protocols. As an exercise, compare a batch of
small computations on the request thread with one larger Ractor task, while
checking that the session never crosses the executor boundary.
