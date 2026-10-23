This guide starts with a single Ruby object and ends with an application that
owns its collaborators and returns an independent result. You will run the same
intention directly and through ObjectFramework, then inspect what the framework
adds around it.

You need basic Ruby classes, keyword arguments, and blocks. You do not need a
web server, a database, or a generated application directory.

## Install the required Ruby

The project uses Ruby **4.0.8**, including for its test runner. Check the actual
interpreter before proceeding:

```sh
ruby --version
```

The output must begin with `ruby 4.0.8`. The repository contains
`.ruby-version` and `.tool-versions` for Ruby version managers. With asdf, for
example, install the version and select it for this directory:

```sh
asdf install ruby 4.0.8
asdf set ruby 4.0.8
```

## Install ObjectFramework

Install the framework as a gem:

```sh
gem install ruby-object-framework
```

For an application managed with Bundler, add this to its Gemfile and run
`bundle install`:

```ruby
gem "ruby-object-framework", require: "object_framework"
```

Your application can then use `require "object_framework"` without `-Ilib`.
The SQLite adapter is optional and requires an additional
`gem "sqlite3", "~> 2.10", ">= 2.10.1"` declaration when used.

To follow the supplied examples and develop the framework, clone the source
and enter the repository:

```sh
git clone https://github.com/gstn-caruso/ruby-object-framework.git
cd ruby-object-framework
```

The examples run from the repository root. `-Ilib` adds the framework's library
directory to Ruby's load path; it does not install a global application or
change the classes your use cases inherit from.

## Write an ordinary use case

Create `examples/guides/01_plain_use_case.rb`, or run the supplied file:

<!-- example: examples/guides/01_plain_use_case.rb -->

```sh
ruby examples/guides/01_plain_use_case.rb
```

Expected output:

```text
Hello, Ada
```

`Greet` receives a collaborator, the greeting text, in its constructor. The
`name` is an argument to one intention. This distinction matters: construction
describes what an object needs to do its work; `call` describes the business
input for this execution.

A caller can create and exercise this class without starting ObjectFramework.
That makes its behavior easy to test and gives other transports the same
application operation to invoke. The framework will arrange its lifetime; the
use case's job remains the greeting.

## Compose the application

[`ObjectFramework::Application`](api/ObjectFramework/Application.html) composes
the next version. It keeps the same constructor and `call` protocol, and returns
a hash so that the boundary has an explicit public value:

<!-- example: examples/guides/02_composed_application.rb -->

Run it:

```sh
ruby -Ilib examples/guides/02_composed_application.rb
```

Expected output:

```text
Hello, Ada
Result is frozen: true
```

There are three new declarations.
[`factory`](api/ObjectFramework/Application.html#method-i-factory) describes how
to build a named collaborator.
[`operation`](api/ObjectFramework/Application.html#method-i-operation) binds an
intention to its use-case class, dependencies, and transaction policy.
[`start`](api/ObjectFramework/Application.html#method-i-start) validates and
finalizes those registrations.
[`invoke`](api/ObjectFramework/Application.html#method-i-invoke) then constructs
an execution scope and a fresh use-case instance.

The factory block runs when the invocation needs `greeting`. It is not a global
service locator. Inside the use case, the collaborator is already present as
`@greeting`; the class does not reach back into the application to find it.

The declaration `policy: :none` is required because this operation does not
use storage. Later operations will declare `:read` or `:write`. An explicit
policy makes a reviewer's transaction question answerable from composition
code rather than from an implicit callback or naming convention.

## Understand the returned value

The invocation makes an independent copy of strings, arrays, hashes, and
supported value objects, and freezes that public graph. A `Data` object can
contain the same kinds of values. This gives callers a result whose components
do not belong to a closed persistence session.

Try assigning `result[:message] = "Changed"` inside the example. Ruby raises
`FrozenError`. If you need a mutable presentation model, build a new object
from the returned values in the caller.

Returning an arbitrary domain object, an IO object, or a cyclic array raises
[`ObjectFramework::UnsafeResult`](api/ObjectFramework/UnsafeResult.html) before
commit. This is a programming error in the operation's public boundary. It
prevents an apparent success from leaking
managed state whose transaction or resources are about to close.

## Inspect startup and cleanup failures

Change `dependencies: [:greeting]` to `dependencies: [:missing]`. Startup
raises `ConfigurationError` before an invocation can run. A dependency cycle,
duplicate registration, non-callable use-case class, or controller bound to an
unknown operation also fails during startup.

Registering another factory after `start` raises `ConfigurationError` too. The
stable registry lets concurrent requests construct scopes without competing
with configuration changes. The tradeoff is that applications must finish
configuration before they open listeners.

The `ensure` block calls
[`stop`](api/ObjectFramework/Application.html#method-i-stop) on the started
application because cleanup must also happen when the invocation fails. Scoped
resources opt into their own cleanup with `close: true`; you will use that in
the composition guide.

## Run the framework's verification suite

The full suite includes the optional SQLite adapter and independent Python
protocol clients. Prepare those development dependencies:

```sh
bundle install
python3 -m venv .venv
.venv/bin/python -m pip install -r test/interop/requirements.txt
ruby -Ilib:test test/run.rb
```

The runner checks Ruby 4.0.8 first. It uses a small Ruby test harness rather
than an external test gem. For focused work, pass filenames:

```sh
ruby -Ilib:test test/run.rb test/core_test.rb test/invocation_test.rb
```

The [core scenarios](https://github.com/gstn-caruso/ruby-object-framework/blob/main/test/core_test.rb)
exercise application independence, scoped factories, startup validation, and
detached values. The runnable programs in this guide are also checked against
their documented output by `test/guides_test.rb`.

## Next step

Replace the greeting with a real decision. In
[Objects and responsibilities](objects_and_responsibilities.md), an order
decides whether it can be confirmed, a use case coordinates that intention,
and a repository supplies the order. Before continuing, explain which parts of
the greeting example would change if its input arrived over HTTP.
