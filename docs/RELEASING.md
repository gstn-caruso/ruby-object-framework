# Gem releases

The package is `ruby-object-framework`; its Ruby entry point is
`require "object_framework"`. The gem contains every framework module, the
runnable examples, README, and third-party notices. SQLite is an optional
application dependency and is not installed with the core gem.

## One-time RubyGems setup

Register a pending trusted publisher in the RubyGems.org account that will own
the gem, following the [official trusted-publishing guide](https://guides.rubygems.org/trusted-publishing/#pushing-a-new-gem-with-a-trusted-publisher).
Use these exact values:

| Field | Value |
| --- | --- |
| Gem name | `ruby-object-framework` |
| Repository owner | `gstn-caruso` |
| Repository name | `ruby-object-framework` |
| Workflow filename | `guides.yml` |
| GitHub environment | `release` |

Leave the optional workflow repository fields empty: the workflow lives in this
repository. For a gem that already exists, add the same trusted publisher from
the gem's settings instead. A pending publisher supports the first publication
and becomes a regular publisher after it succeeds.

Publishing uses short-lived OIDC credentials through the official
`rubygems/configure-rubygems-credentials` action. No RubyGems API key or npm token
is needed. The `release` job requires `contents: write` to commit the version,
push tags and create GitHub releases, and `id-token: write` to authenticate with
RubyGems. If branch protection is enabled later, the release identity must be
allowed to push the version commit to `main`.

This registration requires access to the owning RubyGems account. Until it is
configured, verification and Pages deployment can succeed, but the release job
will fail at authentication before creating a release tag.

## Release behavior

`.github/workflows/guides.yml` runs on pull requests and pushes to `main`.
Verification checks the Ruby suite, independent protocol clients, isolated gem
installation, semantic version rules, a local release cycle, and guide links.
Only successful main-branch verification enables the separate release and
Pages deployment jobs. A manually dispatched run on `main` can also release
changes that have not been released yet.

semantic-release analyzes all commits since the previous `vMAJOR.MINOR.PATCH`
tag. The highest applicable change determines the next version:

| Commit | Change |
| --- | --- |
| `feat!: ...`, `fix!: ...`, or a `BREAKING CHANGE:` footer | Major |
| `feat: ...` | Minor |
| Other changes, including `fix:`, `docs:`, `chore:`, and ordinary merge messages | Patch |

Use Conventional Commit titles for squash merges so that feature and breaking
changes retain their semantic meaning. With merge commits, the underlying
commits are analyzed too. The first release is `1.0.0`; it does not derive its
version from the initial `0.1.0` development constant. A run with no unreleased
commits does not create another version.

The prepare step writes `lib/object_framework/version.rb`, updates the local
gem entry in `Gemfile.lock`, and strictly builds the gem in `pkg/`.
`@semantic-release/git` commits those two version files with `[skip ci]` so the
release does not cause another release run. The version commit receives the
tag; its source and the packaged Ruby constant agree. Generated artifacts and
Node dependencies are excluded from the gem and Git.

The publish step pushes the gem to RubyGems.org, then creates a GitHub release
with semantic release notes and the same `.gem` attached. The Node package is
private and no npm publishing plugin is enabled. Workflow runs use
[`queue: max`](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency)
so another merge does not cancel an in-progress publication or replace a
pending run. GitHub supports up to 100 pending runs per concurrency group.

## Local verification and packaging

Use Ruby 4.0.8, Git, and Node.js 24.10 or newer:

```sh
bundle install
python3 -m venv .venv
.venv/bin/python -m pip install -r test/interop/requirements.txt
npm ci --ignore-scripts
npm test
ruby -Ilib:test test/run.rb
ruby tools/build_guides.rb
```

The release integration test uses temporary local Git repositories and builds
real gems. It checks the initial release, a docs-only patch, matching version
files and tags, and a repeated run with no new changes. It does not contact
RubyGems or create real GitHub releases.

Build the current checkout without publishing or changing its version:

```sh
mkdir -p pkg
gem build ruby-object-framework.gemspec --strict --output pkg/ruby-object-framework.gem
gem install ./pkg/ruby-object-framework.gem --local --no-document
ruby -robject_framework -e 'puts ObjectFramework::VERSION'
```

## Failed-release recovery

If authentication fails before tagging, complete the trusted-publisher setup
and rerun the failed release job. The workflow preserves any built gem as an
Actions artifact even if a later publication step fails.

If a version tag already exists, semantic-release treats it as released and a
rerun does not repeat its publish step. Download the retained gem artifact,
confirm its version and tag, and finish publishing that exact artifact with
`gem push --host https://rubygems.org PATH_TO_GEM`. If only the GitHub release is
missing, create it for the existing tag and attach the same gem. Do not move
published tags or rebuild different code under an already published version.
