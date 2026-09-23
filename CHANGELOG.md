# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Add a reusable plan-mode gate and make tool-declared human approval requirements override ordinary allow rules.
- Add JSON-safe pending approval snapshots for hosts that resume sessions after a restart.
- Add capability-aware approval modes for read-only, ask-before-changes, and full-access sessions.

## [0.1.0] - 2026-09-23

### Added

- Initial permission rules, mode policies, approval policy, and generic approval queue for ask-rb.
