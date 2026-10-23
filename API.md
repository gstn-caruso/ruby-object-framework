# ObjectFramework API

This reference is generated from the Ruby source in `lib/`. It describes the
objects you compose, their method signatures, and the contracts callers must
honor. For a progressive introduction and complete runnable applications, read
the [ObjectFramework Guides](https://gstn-caruso.github.io/ruby-object-framework/).

## Application composition and execution

Start with [Application](rdoc-ref:ObjectFramework::Application). Register
invocation-scoped collaborators with `factory`, declare use cases with
`operation`, and finalize the configuration with `start`. Always call `stop`
in an `ensure` block.

Each operation declares `policy: :none`, `:read`, or `:write`. Transactional
operations require storage. Dependencies are explicit constructor keywords;
`context`, `session`, and `transaction` are reserved execution dependencies.
The latter two require a transactional operation, and sessions require mappings.

[ExecutionContext](rdoc-ref:ObjectFramework::ExecutionContext) carries a generated
operation identifier and [Cancellation](rdoc-ref:ObjectFramework::Cancellation).
Results must contain independent values: strings, numbers, booleans, symbols,
nil, arrays, hashes, and `Data` objects composed of these. They are copied and
frozen before flush and commit. Cycles and unsupported objects raise
[UnsafeResult](rdoc-ref:ObjectFramework::UnsafeResult).

## Persistence

[Mappings](rdoc-ref:ObjectFramework::Persistence::Mappings) describes ordinary
domain objects through [Mapping](rdoc-ref:ObjectFramework::Persistence::Mapping).
Each mapping needs an `id` field stored in the `id` column. Associations load
only when explicitly requested through a session's `load:` plan.

[Session](rdoc-ref:ObjectFramework::Persistence::Session) owns identity and change
tracking within an invocation. Use `add`, `find`, `query`, and `remove` inside
the use case; return values instead of managed entities. The invocation flushes
the session, commits, and closes its resources. A closed session cannot be reused.

[Query](rdoc-ref:ObjectFramework::Persistence::Query) is immutable. Each filter,
comparison, ordering, limit, or offset returns a new query. Queries run with
[Memory::Storage](rdoc-ref:ObjectFramework::Memory::Storage) or the optional
[SQLite::Storage](rdoc-ref:ObjectFramework::SQLite::Storage). SQLite requires the
`sqlite3` gem; [SQLite::Schema](rdoc-ref:ObjectFramework::SQLite::Schema) derives
tables from mappings and accepts consecutive migrations before storage startup.
Commit failures are never automatically retried.

## HTTP, protobuf, and gRPC

[HTTP::Router](rdoc-ref:ObjectFramework::HTTP::Router) binds method/path patterns
to explicit controllers. Install [HTTP::Server](rdoc-ref:ObjectFramework::HTTP::Server)
in the application to serve HTTP/1.1 with bounded admission and request timeouts.
[HTTP::JSONPresenter](rdoc-ref:ObjectFramework::HTTP::JSONPresenter) formats values;
[HTTP::ProblemPresenter](rdoc-ref:ObjectFramework::HTTP::ProblemPresenter) formats
safe error descriptions as problem details.

[Protobuf::Message](rdoc-ref:ObjectFramework::Protobuf::Message) declares proto3
fields and encodes or decodes ordinary hashes.
[GRPC::Service](rdoc-ref:ObjectFramework::GRPC::Service) declares unary and
streaming methods and exports their `.proto` contract. Install
[GRPC::Server](rdoc-ref:ObjectFramework::GRPC::Server) with service descriptors
and controllers. Streaming controllers invoke operations per message or batch,
then yield independent values after their transactions finish.

## Failures and optional capabilities

Register domain exceptions in [ErrorRegistry](rdoc-ref:ObjectFramework::ErrorRegistry)
before startup. The closest registered ancestor supplies the public category,
code, title, and explicitly safe details. Unexpected exceptions receive a generic
description. [FailureReporter](rdoc-ref:ObjectFramework::FailureReporter) sends
immutable diagnostic records to a callable sink without exception messages or
input values.

[Capabilities::Definitions](rdoc-ref:ObjectFramework::Capabilities::Definitions)
loads definitions into a Ruby Box when Ruby starts with `RUBY_BOX=1`.
[Capabilities::IsolatedTask](rdoc-ref:ObjectFramework::Capabilities::IsolatedTask)
runs bounded computations over independent values in a new Ractor. Cancellation
checks happen before and after that computation; they do not forcibly terminate
the Ractor. These capabilities are optional.
