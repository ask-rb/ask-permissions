# Ask::Permissions

Shared permission rules and approval workflows for the [ask-rb](https://github.com/ask-rb) ecosystem.

`ask-permissions` decides whether a tool call may proceed (`:allow`), must be refused (`:block`), or needs a human decision (`:ask`). It is framework-independent: **ask-agent owns session execution** — running turns, invoking tools, pausing and resuming calls — while this gem owns the reusable authorization and approval logic you plug into those hooks.

Everything lives under the `Ask::Permissions` namespace:

| Class | Role |
| --- | --- |
| `PermissionRules` | Ordered `allow` / `ask` / `deny` rules over tool names and arguments. |
| `ApprovalPolicy` | Composes rules with `require_approval` and tool metadata into one decision. |
| `ApprovalQueue` | Stores pending approvals, auto-approves eligible work in order, fires callbacks. |
| `Permissions` | Legacy mode gate with sticky per-tool approvals (see [Legacy mode gate](#legacy-mode-gate)). |

## Installation

```ruby
# Gemfile
gem "ask-permissions"
```

```sh
bundle install
```

```ruby
require "ask-permissions"   # or require "ask/permissions"
```

## Policy composition

A tool call is scored in three layers; the first layer that has an opinion wins:

1. **`PermissionRules`** — the first matching rule decides: `:deny` becomes `:block`, `:allow` becomes `:allow`, `:ask` queues the call.
2. **`require_approval` / tool metadata** — if no rule matched, a `require_approval` pattern or a tool whose metadata reports `approval_required?` queues the call as `:ask`.
3. **Default** — otherwise the call is allowed. An unconfigured policy therefore allows everything.

`ApprovalPolicy#call` returns the decision hash your hook consumes:

```ruby
{decision: :allow, tool_name: "read_file", tool_call_id: "call-1"}
{decision: :block, tool_name: "delete_user", tool_call_id: "call-2", message: "…"}
{decision: :ask,   tool_name: "bash", tool_call_id: "call-3", action: #<Action id=4 status=:pending>}
```

```ruby
rules = Ask::Permissions::PermissionRules.new
rules.allow "read_file"
rules.ask   "bash", "rm -rf"
rules.deny  "delete_user"

policy = Ask::Permissions::ApprovalPolicy.new(
  rules: rules,
  require_approval: ["bash", /^write_/]
)

policy.call(tool_name: "read_file", tool_call_id: "call-1")[:decision]  # => :allow
policy.call(tool_name: "write_file", tool_call_id: "call-2")[:decision] # => :ask (queued)
policy.call(tool_name: "delete_user")[:decision]                        # => :block (nothing queued)
```

`require_approval` accepts a String, Symbol, Regexp, an Array of those, or `:all` (queue every tool). An explicit `allow` rule still wins over `require_approval` — rules are the finer-grained layer.

Tool metadata lives in a registry — a Hash, Array, or any object indexable by tool name — whose values respond to `approval_required?` and `auto_approvable?`:

```ruby
policy = Ask::Permissions::ApprovalPolicy.new(
  require_approval: "fetch",
  auto_approve: true,
  tools: {"fetch" => fetch_tool}  # fetch_tool.approval_required? && fetch_tool.auto_approvable?
)
```

Queue management is available straight off the policy: `policy.pending`, `policy.approve(id, message:)`, `policy.reject(id, message:)`, and the underlying `policy.queue`.

## Ordered permission rules

Rules are evaluated in declaration order; the first match wins and later rules never override it:

```ruby
rules = Ask::Permissions::PermissionRules.new
rules.allow "bash"     # matches first — every later bash rule is dead
rules.deny  "bash"

rules.decision_for("bash")   # => :allow
rules.decision_for("nope")   # => nil (no match — the policy falls through to its default)
```

Patterns:

- **Tool pattern** — exact `String`/`Symbol` name, `Regexp`, or `:all` (matches every tool).
- **Argument pattern** (optional) — `String` (substring of the serialized args), `Regexp` (against the JSON form), `Hash` (key/value subset), or `Array` (exact serialized match). Omit it to match any arguments.

```ruby
rules.ask   "bash", "rm -rf"            # only dangerous commands
rules.allow "read_file", %r{/docs/}     # only some paths
rules.deny  "read_file", {"path" => "/etc/passwd"}
rules.allow "search"                    # any arguments
```

Predicates: `allow?`, `ask?`, `deny?`. Introspection: `rules` and `dangerous_rules` (both in declaration order).

### Dangerous allow downgrade

An unrestricted `allow` on a dangerous tool is downgraded to `:ask` at registration time, so a broad allow can never silently permit an execution tool:

```ruby
rules = Ask::Permissions::PermissionRules.new
rules.allow "bash"         # declared :allow, effective :ask
rules.decision_for("bash") # => :ask
```

The dangerous set is `bash`, `code`, `repl`. The `:all` pattern and any Regexp that matches one of those names also counts as dangerous — so `rules.allow :all` downgrades *every* tool to `:ask`. The downgrade only applies when the decision is `:allow` **and** no argument pattern was given:

```ruby
rules.allow "bash", "ls -la"   # restricted allow → stays :allow
rules.deny  "bash"             # deny/ask are never downgraded
```

`PermissionRules.new(allow_dangerous: true)` disables the guard. That is an explicit opt-out — leave it off unless you have a narrowly scoped reason.

## ApprovalQueue lifecycle

Each queued approval is an immutable `Action` carrying an **integer submission id** (`1`, `2`, `3`, …) assigned per submission — that id is what humans and UIs approve or reject. It is distinct from `tool_call_id`, which echoes back to the agent's tool call.

1. **Submit** — `submit(tool_name:, args:, tool_call_id:, auto_approvable:, message:)` stores a `:pending` action and fires `on_submit(action)` while it is still pending, before any auto-approval.
2. **Drain** — a queue built with `auto_approve: true` approves the head of the queue while that head is `auto_approvable`, in submission order. Drain stops at the first manual item and never overtakes it: later auto-approvable items wait behind it.
3. **Resolve** — `approve(id, message:)` sets `:approved` and calls `on_approve(action, message)`; `reject(id, message:)` sets `:rejected` and calls `on_reject(action, message)`. Resolution triggers another drain, so work behind the manual item resumes whether it was approved or rejected.
4. **Failure** — a callback that raises rolls the action back to `:pending` and re-raises. Unknown or already-resolved ids raise `Ask::Permissions::UnknownApprovalError`. Resolved actions stay in `all` but leave `pending`.

Auto-approval needs **both** flags: `auto_approve: true` on the queue *and* `auto_approvable: true` on the submission (the policy sets the latter from matching tool metadata). Queues are mutex-guarded and safe to share across threads.

```ruby
queue = Ask::Permissions::ApprovalQueue.new(
  auto_approve: true,
  on_submit:  ->(action) { puts "queued ##{action.id}: #{action.tool_name}" },
  on_approve: ->(action, message) { puts "approved ##{action.id} (#{message})" },
  on_reject:  ->(action, message) { puts "rejected ##{action.id} (#{message})" }
)

action = queue.submit(tool_name: "bash", args: {"command" => "ls"}, tool_call_id: "call-9")
queue.pending                      # actions still awaiting a human
queue.approve(action.id, message: "reviewed")
queue.lookup(action.id).status     # => :approved
```

`ApprovalPolicy` exposes the same lifecycle via `policy.queue`, `policy.pending`, `policy.approve`, and `policy.reject`.

## Wiring it into an agent

`ApprovalPolicy` is designed to sit in a tool-call hook. ask-agent owns session execution — invoking tools, pausing and resuming turns; ask-permissions only answers "may this call proceed?" and hands you callbacks to do the rest:

```ruby
rules = Ask::Permissions::PermissionRules.new
rules.deny  "delete_user"
rules.ask   "bash", "rm -rf"
rules.allow "read_file"

policy = Ask::Permissions::ApprovalPolicy.new(
  rules: rules,
  require_approval: ["bash", /^write_/],
  on_submit:  ->(action)          { UI.enqueue(action.id, action.tool_name) },
  on_approve: ->(action, message) { Session.resume(action.tool_call_id) },
  on_reject:  ->(action, message) { Session.deny(action.tool_call_id, message) }
)

# inside the agent's tool-call hook — proceed / refuse / pause stand in
# for your agent's own verbs
result = policy.call(tool_name: tool_name, args: args, tool_call_id: tool_call_id)

case result[:decision]
when :allow then proceed(result)
when :block  then refuse(result[:message])
when :ask
  action = result[:action]
  action.approved? ? proceed(result) : pause_until_decided(action.id)
end
```

`Session`, `UI`, and the `proceed`/`refuse`/`pause_until_decided` helpers stand in for your own integration — this gem never executes tools itself. A human (or an automated reviewer) later resolves the submission:

```ruby
policy.approve(action_id, message: "looks good")  # fires on_approve
policy.reject(action_id, message: "too risky")    # fires on_reject
```

Notes for hook authors:

- Check `action.status`: an `:ask` decision can come back already `:approved` when auto-approval drained it during `call`.
- Callbacks are the only side-effect seam; if one raises, the action stays `:pending` and your hook sees the exception.
- Approving does **not** rewrite the rules: the next identical call is evaluated from scratch and queues again if it still matches an `ask` rule. Approve per submission, not per tool.

## Legacy mode gate

`Ask::Permissions::Permissions` is the simpler, mode-based gate that predates rules + queue. It blocks a fixed set of "change" tools and records one sticky approval per tool.

```ruby
gate = Ask::Permissions::Permissions.new   # mode: :ask_before_changes

gate.check("bash", {"command" => "ls"})
# => {decision: :block, tool_name: "bash", pending: true, id: 1, message: "…", approval: …}

gate.approve(1)                 # subsequent "bash" checks now :allow
gate.check("bash")[:decision]   # => :allow
gate.reject(other_id, message: "no")  # re-blocks that tool
```

- **Modes** — `:ask_before_changes` (default) and `:read_only` block the built-in change tools (`bash`, `destroy`, `edit`, `write`); `:full_access` blocks nothing by default. Anything you add to `blocked_tools:` is blocked in **every** mode. A missing or invalid mode (including a String) raises `ArgumentError`.
- **Sticky approvals** — the first blocked call creates one pending approval; repeated calls reuse it (same `id`). Approving unlocks that tool for good; rejecting removes it and the tool blocks again. Approving one tool never unlocks another.
- **Timeouts** — `Permissions.new(timeouts: {default: 300, "bash" => 60})` expires *pending* approvals after that many seconds (per-tool entries beat `default:`). Expired approvals vanish, so the next call creates a fresh one; already-approved grants survive. With no timeouts, approvals stay pending indefinitely.
- `call` is an alias for `check`; symbol tool names are normalized to strings; the gate is thread-safe.

Prefer `ApprovalPolicy` for new integrations — it composes with ordered rules and the shared queue. Reach for the mode gate when you only need coarse "block changes until approved" behavior.

## Defaults and safety caveats

- **Unconfigured means allow.** `ApprovalPolicy.new` with no rules, no `require_approval`, and no tool metadata allows every call; a `PermissionRules` with no matching rule returns `nil`, which the policy treats as allow. Configure before you wire a policy into an agent.
- **Dangerous tools are downgraded, not blocked.** An unrestricted `allow` on `bash`/`code`/`repl` becomes `:ask`, but `allow_dangerous: true` turns the guard off — and `:full_access` in the legacy gate blocks nothing you don't list yourself.
- **Auto-approve is opt-in twice.** The queue must be built with `auto_approve: true` *and* each submission must be `auto_approvable`; `require_approval` items without matching tool metadata always wait for a human.
- **Auto-approval never skips the line.** A manual item halts the drain until a human resolves it; later auto items do not jump ahead.
- **Approval state is in memory.** Queues and gate approvals live in the process — they are not persisted and do not survive a restart.
- **Approvals are per submission.** Approving one action does not create a lasting allow rule (unlike the legacy gate's sticky per-tool grants).
- **Callback failures are visible.** `on_submit` / `on_approve` / `on_reject` exceptions propagate and leave actions `:pending`; keep callbacks idempotent.

## Development

```sh
bundle install
bundle exec rake test
```

CI runs the suite on Ruby 3.2, 3.3, and 3.4.

## Versioning

See [VERSIONING.md](VERSIONING.md). All releases go through `gemchain`; never publish this gem by hand.

## License

MIT. See [LICENSE](LICENSE).
