# Releasing — ask-permissions

[VERSIONING.md](VERSIONING.md) is the canonical versioning document (exact sequential steps, version agreement rules). Follow it; this file only covers the release procedure.

## Preconditions

All must hold before any release:

- **Clean working tree** — no uncommitted changes.
- **Passing tests** — `bundle exec rake test` (and global `rubocop`) are green.
- **Up-to-date CHANGELOG** — the `[X.Y.Z] - Unreleased` heading in `CHANGELOG.md` names the version being released and matches `lib/ask/permissions/version.rb` (version agreement per VERSIONING.md).
- **Runtime dependencies available** — any runtime dependency of this gem (and of its dependents in the ecosystem) is resolvable from RubyGems at the required versions.
- **Build verification** — the gem builds cleanly (`gem build ask-permissions.gemspec`) and the built artifact reports the expected version.

## Publishing: gemchain only

**ALL Ask ecosystem publishing goes through `gemchain`. Never run `rake release`, `gem push`, or any other manual publish.**

Order matters:

1. **ask-permissions is new** — publish it first, before releasing any dependent gem, so dependents resolve it from RubyGems.
2. Then run gemchain's **cascade checks and dry run** across the affected gems (verify version agreement, changelog state, and dependency ordering without publishing). Use `gemchain guard` for pre-release checks and `gemchain update` where a version bump is needed; consult gemchain itself for exact subcommand syntax.
3. **Actual publish requires explicit authorization** — do not publish until authorization is given, even if all checks pass.
