# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Add `PermissionRuleSet` for composing default and project rules with
  deny-first precedence, plus versioned JSON-safe snapshots for portable
  host-owned rule storage.
- Allow `ApprovalPolicy` to receive optional `project_rules:` while
  preserving the existing `rules:` API.

## [0.2.0] - 2026-09-23

### Added

- Add a reusable plan-mode gate and make tool-declared human approval requirements override ordinary allow rules.
- Add JSON-safe pending approval snapshots for hosts that resume sessions after a restart.
- Add capability-aware approval modes for read-only, ask-before-changes, and full-access sessions.
- Add approval resolution scopes (`once`/`session`/`project`) on explicit approvals and rejection feedback, carried on the resolved `Action` for the host to apply. Auto-approvals report `once`; snapshots stay pending-only.
- Add thread-safe `SessionPermissionGrants` for whole-tool session-scoped grants with versioned JSON-safe snapshot/restore, wired into `ApprovalPolicy` via optional `session_grants:` without touching project rules.
- Add optional host-owned `project_grants:` collaborator (`granted?(tool_name)`) to `ApprovalPolicy`; a matching session or project grant bypasses ordinary ask rules, `require_approval`/metadata, elevated-risk prompts, and `ask_before_changes` side-effect prompts, without bypassing explicit deny, `always_ask?`, or `read_only`. No project store is shipped.
## [0.1.0] - 2026-09-23

### Added

- Initial permission rules, mode policies, approval policy, and generic approval queue for ask-rb.
