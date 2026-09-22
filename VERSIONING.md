# Versioning — ask-permissions

This repository follows the ask-rb (Ask gem) versioning convention: exact sequential steps, never skipped numbers.

## Increment rules

- Every release advances the version by **exactly one step**. Never skip a number.
- While pre-1.0 (`0.x`), an incompatible feature (API or behavior change) increments the **minor** digit by one: `0.1.0 -> 0.2.0`.
- Compatible fixes increment the **patch** digit by one: `0.1.0 -> 0.1.1`, `0.2.0 -> 0.2.1`.
- Skipping is never allowed: `0.1.0 -> 0.3.0` or `0.1.0 -> 0.1.2` from a single release are both violations.
- The version source of truth is `lib/ask/permissions/version.rb`; the gemspec reads it from there.

## Changelog

- `CHANGELOG.md` keeps a `[X.Y.Z] - Unreleased` section that is filled in as work lands and dated only when that version ships.
- Before any release, the unreleased changelog heading and `lib/ask/permissions/version.rb` must name the same version (version agreement).

## Releasing

- **All releases go through `gemchain`** from the ask-rb workspace. Never `rake release`, `gem push`, or any other manual publish.
- A release requires a **clean working tree**, **passing tests** (`bundle exec rake test`), and **version agreement** — `lib/ask/permissions/version.rb`, the `CHANGELOG.md` heading, and the built gemspec version must all name the same version.
- No release has been made yet: `0.1.0` stays `Unreleased` until `gemchain` publishes it.
