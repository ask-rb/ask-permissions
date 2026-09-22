# Contributing — ask-permissions

## Setup

```sh
bundle install
```

Requires Ruby >= 3.2 (see `ask-permissions.gemspec`).

### Local sibling path overrides

When testing against an unreleased sibling Ask gem, temporarily point the dependency at a local checkout instead of the published version — e.g. add a `path:` override in the `Gemfile` (or an equivalent Bundler local override) targeting the sibling directory. Revert the override before opening a PR; never commit path-specific local overrides.

## Tests

```sh
bundle exec rake test                       # full suite
bundle exec rake test TEST=test/permissions_test.rb   # single file
```

## Style

- Every Ruby file starts with `# frozen_string_literal: true`.
- RuboCop is the single style authority (global Ask RuboCop config via `.rubocop.yml`); run `rubocop` (globally installed — it is deliberately not a Gemfile dependency) and keep it clean alongside the tests.

## Pull requests

- Keep PRs focused: one change, one purpose.
- Update `CHANGELOG.md` under the current `[X.Y.Z] - Unreleased` section for anything user-visible.
- Tests are required for behavior changes; the suite and RuboCop must pass.

## Scope

This gem is single-purpose: framework-independent permission rules, policies, and approval queues for ask-rb. Features that belong to other Ask gems (agent loops, LLM providers, transport, etc.) stay out — contribute those to the owning repository instead.
