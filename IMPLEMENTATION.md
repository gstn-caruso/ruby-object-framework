# Implementation record

The complete scope is defined in [PLAN.md](PLAN.md). Implementation, tests,
public APIs, and new documentation use English. Each delivery must pass its
scenarios before work starts on the next delivery.

| Delivery | Scope | State |
| --- | --- | --- |
| 1 | Composition, invocation, errors, cancellation, diagnostics | In progress |
| 2 | Data Mapper, queries, associations, snapshot HashMap storage | Pending |
| 3 | HTTP/1.1 server, TLS, JSON, order confirmation example | Pending |
| 4 | SQLite adapter, migrations, shared storage contract | Pending |
| 5 | HTTP/2, HPACK, Protocol Buffers, gRPC and streaming interoperability | Pending |
| 6 | Optional Ruby Box, Ractor, interpreter/YJIT/ZJIT comparison | Pending |

## Development

Run `ruby -Ilib:test test/run.rb` with Ruby **4.0.8**. Tests use a small,
dependency-free runner. Add a failing behavioral scenario, observe it fail,
implement the behavior, and rerun the delivery suite before proceeding.

Runtime dependencies are Ruby core and the standard library. The SQLite
adapter may additionally depend on `sqlite3`; no other runtime gems are planned.
