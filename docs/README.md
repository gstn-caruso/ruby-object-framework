# Authoring and publishing the guides

The guides teach the framework progressively, with explicit programs and the
reasoning behind each significant design choice. The editorial acceptance
criteria are in section 6 of [PLAN.md](../PLAN.md). The visual brief is in
[DESIGN.md](DESIGN.md).

## Build and preview

Use Ruby 4.0.8, including its bundled RDoc documentation tools:

```sh
ruby tools/build_guides.rb
python3 -m http.server 9292 --directory _site
```

Open <http://127.0.0.1:9292>. `_site` is generated and ignored by Git. The site
uses relative URLs so the same output works at a repository Pages path.

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
ruby tools/build_guides.rb
```

The builder rejects missing local files, missing anchors, and duplicate heading
IDs. Review desktop and mobile layouts and keyboard access after layout changes.

`.github/workflows/guides.yml` runs the complete framework and guide suite, then
builds and validates the site. Pull requests receive verification; successful
main-branch runs deploy the generated artifact to GitHub Pages. The deployment
job requires successful verification and uses the `github-pages` environment.

The published site is <https://gstn-caruso.github.io/ruby-object-framework/>.
`GUIDES_REPOSITORY=owner/name` changes source links when building a fork.
