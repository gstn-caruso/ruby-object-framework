# Implementation record

The complete scope is defined in [PLAN.md](PLAN.md). Implementation, tests,
public APIs, and new documentation use English. Each delivery must pass its
scenarios before work starts on the next delivery.

| Delivery | Scope | State |
| --- | --- | --- |
| 1 | Composition, invocation, errors, cancellation, diagnostics | Passed: 19 scenarios on Ruby 4.0.8 |
| 2 | Data Mapper, queries, associations, snapshot HashMap storage | Passed: 35 cumulative scenarios on Ruby 4.0.8 |
| 3 | HTTP/1.1 server, TLS, JSON, order confirmation example | Passed: 61 cumulative scenarios on Ruby 4.0.8 |
| 4 | SQLite adapter, migrations, shared storage contract | Passed: 75 cumulative scenarios on Ruby 4.0.8 |
| 5 | HTTP/2, HPACK, Protocol Buffers, gRPC and streaming interoperability | Passed: 93 cumulative scenarios on Ruby 4.0.8 |
| 6 | Optional Ruby Box, Ractor, interpreter/YJIT/ZJIT comparison | Passed: 97 cumulative scenarios on Ruby 4.0.8 |

## Development

Run `ruby -Ilib:test test/run.rb` with Ruby **4.0.8**. Tests use a small,
dependency-free runner. Add a failing behavioral scenario, observe it fail,
implement the behavior, and rerun the delivery suite before proceeding.

Runtime dependencies are Ruby core and the standard library. The SQLite
adapter may additionally depend on `sqlite3`; no other runtime gems are planned.

The scope also includes the progressive English guides and published GitHub
Pages site specified in section 6 of `PLAN.md`. Guide sources, executable
examples, local build/preview commands, validation, deployment, and verification
of the live site are required deliverables. This documentation work is pending.

## Verified delivery gates

- Delivery 1: `ruby -Ilib:test test/run.rb` — 19 tests, zero failures.
  Includes indeterminate commit outcomes, fatal unwinding, cyclic result
  rejection, module startup validation, and secondary cleanup failures.
- Delivery 2: `ruby -Ilib:test test/run.rb` — 35 tests, zero failures.
  Includes the shared storage contract, eight concurrent writers, mutable
  domain-field isolation, removed-entity visibility, and immutable identities.
- Delivery 3: `ruby -Ilib:test test/run.rb` — 61 tests, zero failures.
  Includes raw-socket fragmentation and pipelining, chunked framing, admission,
  deadlines, TLS, Net::HTTP interoperability, late failures, and all five order
  confirmation outcomes. Start the example with
  `ruby -Ilib examples/orders/server.rb`.
- Delivery 4: `ruby -Ilib:test test/run.rb` — 75 tests, zero failures, with
  sqlite3 2.10.1 and SQLite 3.54.1. Both adapters run the same storage contract.
  SQLite DELETE journaling holds a writer's commit behind active readers; the
  common contract checks visibility before ending the reader, then commits the
  writer. A separate HashMap scenario preserves the stronger concurrent-commit
  snapshot assertion. Tests also cover deadline-bounded locks, safe SQL binding,
  schema versions and shape validation, foreign keys, and per-invocation cleanup.
- Delivery 5: `ruby -Ilib:test test/run.rb` — 93 tests, zero failures. The
  independent clients are grpcio 1.84.1, Google's protobuf 7.36.2, and hyper-h2
  4.4.1. Includes every streaming mode, all proto3 scalars, TLS with certificate
  verification and h2 ALPN, 200 KiB messages, header continuations, isolated
  stream errors, admission across connections, cancellation, and per-message
  commits surviving a late stream error. RFC HPACK tables and their license are
  documented in `THIRD_PARTY_NOTICES.md`.
- Delivery 6: `ruby -Ilib:test test/run.rb` — 97 tests, zero failures.
  Ruby Box isolation is tested in a process booted with `RUBY_BOX=1`. Ractor
  tasks accept independent values and return to the owning request thread.
  `ruby benchmark/compare.rb 20000 3` verified matching results in interpreter,
  YJIT, and ZJIT processes; raw measurements are in `benchmark/results.json`.
