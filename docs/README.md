# Authoring and publishing the documentation

The guides teach the framework progressively, with explicit programs and the
reasoning behind each significant design choice. The editorial acceptance
criteria are in section 6 of [PLAN.md](../PLAN.md). The visual brief is in
[DESIGN.md](DESIGN.md).

## Build and preview

Use Ruby 4.0.8 and install the development dependencies, including RDoc:

```sh
bundle install
bundle exec ruby tools/build_guides.rb
python3 -m http.server 9292 --directory _site
```

Open <http://127.0.0.1:9292>. `_site` is generated and ignored by Git. The site
uses relative URLs so the same output works at a repository Pages path.
The same build generates the searchable RDoc reference at `_site/api/index.html`
and embeds it in the homepage's **API reference** section. Header links make
that section reachable from every guide; the full reference also opens directly.
The header, homepage, and API title read `ObjectFramework::VERSION`.

## Edit the API reference

Write RDoc comments immediately above public classes and methods in `lib/`.
Describe responsibilities, argument requirements, returned values, resource
ownership, and failure behavior. Indented Ruby examples become code blocks;
class names and method references such as `Application#invoke` become links.
The generator parses every library file, including optional SQLite and
capability modules, without loading adapters or starting servers.
For methods created dynamically, use RDoc's `:method:` and `:args:` directives
to document their names and signatures; see `AssociationDSL` in
`lib/object_framework/persistence/mapping.rb` for examples.

In guide prose, link each class or method where its behavior is introduced,
so readers can move from an explanation to the exact API contract. Use relative
Markdown links to the generated RDoc pages:

```markdown
[`ObjectFramework::Application`](api/ObjectFramework/Application.html)
[`Application#invoke`](api/ObjectFramework/Application.html#method-i-invoke)
[`SQLite::Schema.from_mappings`](api/ObjectFramework/SQLite/Schema.html#method-c-from_mappings)
```

RDoc uses `method-i-` anchors for instance methods and `method-c-` for class
methods. Punctuation is encoded in method anchors; for example, `check!` uses
`#method-i-check-21`. Copy the anchor from the generated reference when unsure.
Guide section URLs such as `getting_started.html#compose-the-application`
remain shareable, and the linked API opens at the class or method being discussed.
The build validates these links and method anchors along with the guides.

[`API.md`](../API.md) supplies the reference landing page. Use `rdoc-ref:` links
there to point at API objects, for example
`[Application](rdoc-ref:ObjectFramework::Application)`. The RDoc output is
regenerated on every build so deleted classes do not leave stale pages.

`assets/fonts.css` shares typography between the guides and RDoc. Inter and
IBM Plex Mono are served locally; Calibre loads from the same Rails-hosted
font URLs as Rails Guides. A network connection is needed for Calibre; the
fallback is the browser's sans serif family.

## Edit content and examples

The ordered catalog is `guides/guides.yml`. Guide sources start with level-2
headings; the template supplies the page title. Headings receive stable
lowercase hyphenated IDs. Link to other source guides with relative `.md`
links; the builder converts them to `.html`.

Include a complete Ruby program with an example directive:

```text
<!-- example: examples/guides/02_composed_application.rb -->
```

The build includes the actual source file and links to it on GitHub. Add its
expected stdout to `examples/guides/manifest.yml`; every program runs in a
separate Ruby process during the test suite. Declare needed environment
variables explicitly in that manifest.

Explain the inputs, command, output, failure cases, resource ownership, and
reason for the design. Introduce one idea at a time. Link claims about framework
guarantees to implementation tests and primary protocol sources when relevant.

## Verification and deployment

```sh
bundle install
python3 -m venv .venv
.venv/bin/python -m pip install -r test/interop/requirements.txt
ruby -Ilib:test test/run.rb
bundle exec ruby tools/build_guides.rb
```

The builder rejects missing local files, missing anchors, and duplicate heading
IDs throughout the guides and nested RDoc pages. The guide tests verify the
embedded reference, generated API classes, and broken API links and anchors.
Review desktop and mobile layouts and keyboard access after layout changes.
Run the full suite with plain `ruby`: packaging scenarios deliberately install
the gem in an isolated environment outside Bundler's dependency scope.

`.github/workflows/guides.yml` runs the complete framework and guide suite, then
builds and validates the site. Pull requests receive verification; successful
main-branch runs deploy the generated artifact to GitHub Pages. The deployment
job requires successful verification and uses the `github-pages` environment.
The same verification also gates the automatic gem release; see
[release setup and recovery](RELEASING.md) for its RubyGems registration.

The published site is <https://gstn-caruso.github.io/ruby-object-framework/>.
`GUIDES_REPOSITORY=owner/name` changes source links when building a fork.
