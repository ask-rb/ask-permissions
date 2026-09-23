# Ask::Permissions

Shared permission rules and approval workflows for the [ask-rb](https://github.com/ask-rb) ecosystem.

`ask-permissions` answers one question before a tool runs: may this call proceed? It is framework-independent — **your agent owns session execution** (running turns, invoking tools, pausing and resuming), while this gem owns the reusable classification, queueing, and approval logic you plug into a `before_tool_call` hook.

Everything lives under the `Ask::Permissions` namespace:

| Class | Role |
| --- | --- |
| `PermissionRules` | Ordered `allow` / `ask` / `deny` rules over tool names and arguments; `classify` returns the first match. |
| `ApprovalPolicy` | Hook adapter: consults rules, `require_approval`, and tool metadata, then enqueues through a queue. |
| `ApprovalQueue` | Stores pending `Action`s, auto-approves eligible work in order, fires one-argument callbacks. |
| `Permissions` | Optional mode gate (`nil` by default, or `:ask_before_changes` / `:read_only` / `:full_access`) with sticky approvals per `tool_call_id`. |
| `PlanModePolicy` | Allows only declared read-only tools and the plan-submission tool while plan mode is active. |

Tools that expose `always_ask?` cannot be approved by a matching ordinary
`allow` rule; their calls enter the human approval queue and cannot be
auto-approved.

`ApprovalQueue#snapshot` and `#restore_pending` let a session host persist
pending approvals alongside its durable session state. Restoring does not
re-emit submission events or auto-approve work; the host remains responsible
for replaying its event log and reconnecting the restored queue to its session.

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

Requires Ruby >= 3.2.

## ApprovalQueue

The queue is the source of truth for pending human decisions. Each submission becomes an immutable `Action` (a `Data` object) with a **sequential integer id** (`1`, `2`, `3`, …) assigned at submission time.

```ruby
queue = Ask::Permissions::ApprovalQueue.new(
  auto_approve: {"fetch" => true},   # Hash keyed by tool name; entry must be exactly true
  on_submit:    ->(action) { UI.enqueue(action) },          # one argument: the Action
  on_approve:   ->(action) { Session.resume(action.tool_call_id) },
  on_reject:    ->(action) { Session.deny(action.tool_call_id) }
)

id = queue.submit(
  tool_call_id: "tc-1",
  tool_name: "bash",
  args: {"command" => "ls"},
  auto_approvable: false,
  message: "needs eyes"
)                                    # => 1 (integer id)

queue[id]                            # => the Action (or nil)
queue.pending_actions                # => Actions with status :pending
queue.pending?(id)                   # => true / false
queue.any_pending?                   # => true / false
```

### Resolving

```ruby
queue.approve(id)          # => [action] — fires on_approve(action); does not drain
queue.reject(id)           # => [action] — fires on_reject(action); does not drain
queue.approve(1, 2, 3)     # accepts several ids; returns only the resolved Actions
queue.approve_all          # approves every pending Action (empty array if none)
queue.reject_all
queue.drain                # re-runs the auto-approval pass explicitly
```

Unknown or already-resolved ids are ignored — they never raise. `approve` / `reject` return only the subset that was still pending (in id order), or `[]` when nothing qualified, and they do **not** drain afterward.

### Action

Fields: `id`, `tool_call_id`, `tool_name`, `args`, `auto_approvable`, `status`, `submitted_at`, `message`.
Statuses: `:pending` → `:applying` (transient, inside the callback) → `:approved` or `:rejected`.
Predicates: `pending?`, `applying?`, `approved?`, `rejected?`, `auto_approvable?`. Actions are frozen.

### Callbacks

All three callbacks take **exactly one argument — the `Action`**:

- `on_submit(action)` — fires while the action is still `:pending`, before any auto-approval.
- `on_approve(action)` / `on_reject(action)` — fire during resolution. If they raise, the action rolls back to `:pending` and the exception propagates.

### Auto-approval

Auto-approval needs **both** conditions:

1. the submission carries `auto_approvable: true`, and
2. `auto_approve` contains that tool name with the value exactly `true`.

```ruby
queue = Ask::Permissions::ApprovalQueue.new(auto_approve: {"read" => true})
queue.submit(tool_call_id: "tc-1", tool_name: "read", auto_approvable: true)
# => immediately :approved via on_approve

queue.submit(tool_call_id: "tc-2", tool_name: "read")                  # stays :pending
queue.submit(tool_call_id: "tc-3", tool_name: "other", auto_approvable: true)  # stays :pending
```

Drain is **ordered and never overtakes a manual item**: it approves from the head of the queue while that head is eligible and stops at the first manual entry. Auto-drain runs on every `submit`. `approve` / `reject` do **not** drain, so work behind a manual item waits until the next `submit` or an explicit `queue.drain`.

Queues are mutex-guarded and safe to share across threads. Approval state lives in memory only.

## PermissionRules

Rules are evaluated in declaration order; the first match wins.

```ruby
rules = Ask::Permissions::PermissionRules.new    # auto_allow_dangerous: false (default)

rules.allow "read_file"
rules.ask   "bash", "rm -rf"
rules.deny  "delete_user"

rules.classify("bash", {"command" => "sudo rm -rf /tmp"})  # => :ask
rules.classify("read_file")                               # => :allow
rules.classify("delete_user")                             # => :deny
rules.classify("unknown")                                 # => nil (no match)

rules.allow?("read_file")    # => true
rules.ask?("bash", {"command" => "rm -rf /"})
rules.deny?("delete_user")
```

`allow` / `ask` / `deny` take `(tool_pattern, argument_pattern = nil)` and return `self`, so they chain. `PermissionRules.new` also accepts an optional block, which is `instance_eval`'d against the ruleset:

```ruby
rules = Ask::Permissions::PermissionRules.new do
  allow "read_file"
  deny  "delete_user"
  ask   "bash", "rm -rf"
end
```

### Patterns

- **Tool pattern** — exact `String`/`Symbol` name, `Regexp`, or `:all` (matches every tool).
- **Argument pattern** (optional) — `String` (substring of the serialized args) or `Regexp` (against the serialized form). Hash args are serialized with `JSON.generate`; anything else with `to_s`. Omit it to match any arguments.

```ruby
rules.ask   "bash", "rm -rf"            # substring of the serialized args
rules.allow "read_file", %r{/docs/}     # Regexp against the serialized args
rules.allow "search"                    # any arguments
```

Introspection: `rules` and `dangerous_rules` (both in declaration order). Each entry is a `Rule` with `decision`, `declared_decision`, `effective_decision`, `tool_pattern`, `argument_pattern`, `dangerous`, plus the predicates `dangerous?` and `universal?` (unrestricted argument pattern — `argument_pattern` is `nil`, regardless of tool pattern) and the matchers `tool_matches?(name)`, `argument_matches?(args)`, and `matches?(name, args)`. `decision` and `declared_decision` always keep the decision as written at declaration time; `classify` returns `effective_decision`.

### Dangerous allow downgrade

An unrestricted `allow` on a dangerous tool is downgraded to `:ask` **for classification only**, so a broad allow can never silently permit an execution tool:

```ruby
rules = Ask::Permissions::PermissionRules.new
rules.allow "bash"            # declared :allow, effective :ask
rule = rules.rules.first
rule.decision                 # => :allow (declared decision is preserved)
rule.declared_decision        # => :allow
rule.effective_decision       # => :ask
rules.classify("bash")        # => :ask
```

The dangerous set is the public frozen `DANGEROUS_TOOLS` constant, `%i[bash code repl]`. The `:all` pattern and any `Regexp` that matches one of those names also counts as dangerous — so `rules.allow :all` downgrades *every* tool to `:ask`. The downgrade only applies when the declared decision is `:allow` **and** no argument pattern was given:

```ruby
rules.allow "bash", "ls -la"   # restricted allow → stays :allow
rules.deny  "bash"             # deny/ask are never downgraded
```

`PermissionRules.new(auto_allow_dangerous: true)` disables the guard. That is an explicit opt-out — leave it off unless you have a narrowly scoped reason.

## ApprovalPolicy

`ApprovalPolicy` requires a `queue:`; everything else is optional:

```ruby
rules = Ask::Permissions::PermissionRules.new
rules.deny  "delete_user"
rules.ask   "bash", "rm -rf"
rules.allow "read_file"

queue = Ask::Permissions::ApprovalQueue.new(
  auto_approve: {"fetch" => true},
  on_submit:    ->(action) { UI.enqueue(action) },
  on_approve:   ->(action) { Session.resume(action.tool_call_id) },
  on_reject:    ->(action) { Session.deny(action.tool_call_id) }
)

policy = Ask::Permissions::ApprovalPolicy.new(
  queue: queue,                              # required
  rules: rules,                              # optional
  require_approval: ["bash", /^write_/],     # optional
  tools: {"fetch" => fetch_tool}             # optional registry
)
```

The optional `mode:` applies declared tool capabilities consistently: `:read_only`
blocks side-effecting or undeclared-scope tools, `:ask_before_changes` queues
them for a person, and `:full_access` bypasses ordinary risk gates. Explicit
`ask`/`deny` rules still apply in every mode, and a tool's `always_ask?` remains
non-bypassable. Tools with `:high` or `:critical` risk are queued unless an
explicit allow rule or `:full_access` mode permits them; risk-gated approvals
are never auto-approved.

### The hook: `before_tool_call`

`before_tool_call(tool_call, context = nil)` expects `tool_call` to respond to `name`, `arguments`, and `id`. It returns exactly one of three shapes:

```ruby
{action: :proceed}
{action: :block, reason: "Denied by permission rules: 'delete_user'"}
{action: :pending, action_id: 1, reason: "Tool 'bash' requires approval"}
```

Resolution order — the first layer with an opinion wins:

1. **`rules.classify(name, arguments)`** — `:deny` → block with the exact reason `"Denied by permission rules: '<name>'"`, `:allow` → proceed, `:ask` → enqueue with `auto_approvable: false`. An explicit `allow` rule therefore wins over `require_approval`.
2. **`require_approval` / tool metadata** — if no rule matched, a `require_approval` pattern or a tool whose metadata reports `approval_required?` enqueues as `:pending`; `auto_approvable` comes from the tool's `auto_approvable?`.
3. **Default** — otherwise the call proceeds. An unconfigured policy allows everything.

`require_approval` accepts `nil`, `:all` (queue every tool), a `String`/`Symbol` (exact name), a `Regexp`, or an `Array` of those (any match).

The `tools` registry may be a `Hash` (String or Symbol keys), an `Array` of objects that respond to `name`, or any object indexable with `[]`. Values should respond to `approval_required?` and/or `auto_approvable?`:

```ruby
tools = {"fetch" => fetch_tool}   # fetch_tool.approval_required? && fetch_tool.auto_approvable?
```

### Looking up and resolving

`result[:action_id]` **is** the queue's action id — exactly what `queue.submit` returned (sequential integers assigned in submission order). `policy.lookup(id)` simply delegates to `queue[id]`:

```ruby
result = policy.before_tool_call(tool_call, context)
return proceed if result[:action] == :proceed
return refuse(result[:reason]) if result[:action] == :block

action = policy.lookup(result[:action_id])   # the queue Action, or nil
queue.approve(action.id)                     # fires on_approve
queue.reject(action.id)                      # fires on_reject
```

Readers: `policy.queue`, `policy.rules`, `policy.require_approval`, `policy.tools`.

### Auto-approval through the policy

Only the `require_approval` / tool-metadata path can set `auto_approvable: true` — an `ask` rule always enqueues with `auto_approvable: false`. Even then the queue must also list the tool in its `auto_approve` hash. A `:pending` result can therefore come back with the action already `:approved`; check `action.status` (or `action.approved?`) before pausing.

## Wiring it into an agent

`ApprovalPolicy` sits in your agent's tool-call hook; this gem never executes tools itself:

```ruby
result = policy.before_tool_call(tool_call, context)

case result[:action]
when :proceed then proceed(result)
when :block   then refuse(result[:reason])
when :pending
  action = policy.lookup(result[:action_id])
  action.approved? ? proceed(result) : pause_until_decided(action)
end
```

`proceed` / `refuse` / `pause_until_decided`, `Session`, and `UI` stand in for your own integration. A human (or an automated reviewer) later resolves the submission through the queue — `queue.approve(action.id)` or `queue.reject(action.id)`.

Notes for hook authors:

- Callbacks are the only side-effect seam; if one raises, the action stays `:pending` (or rolls back to `:pending`) and your hook sees the exception.
- Approving does **not** rewrite the rules: the next identical call is classified from scratch and queues again if it still matches an `ask` rule. Approve per submission, not per tool.
- `result[:action_id]` is the queue's own action id; `policy.lookup(action_id)` just delegates to `queue[action_id]`.

## Mode gate: `Permissions`

`Ask::Permissions::Permissions` is the simpler mode-based gate. It blocks a fixed set of change tools and records a sticky approval per `tool_call_id`.

```ruby
gate = Ask::Permissions::Permissions.new   # mode: nil (default)

result = gate.before_tool_call(tool_call, {})
# => {action: :block, reason: "bash requires approval"}

gate.pending_approvals            # => pending Approval entries
gate.approve("tc-1")              # => true

gate.before_tool_call(tool_call, {})
# => {action: :proceed}   (same tool_call id, already approved)
```

- **Modes** — omit `mode:` and `mode` stays `nil`; blocked tools default to the symbols `:write`, `:edit`, `:bash`, `:destroy`. With an explicit mode (`:ask_before_changes`, `:read_only`, or `:full_access`) the blocked set comes from the mode — `:ask_before_changes` and `:read_only` block those same four defaults, `:full_access` blocks nothing — and **`blocked_tools:` is ignored**. Without a mode, a custom `blocked_tools:` list **replaces** the default entirely (entries may be Strings or Symbols; they normalize to Symbols). An unknown mode (including a String) raises `ArgumentError` with the exact message `"Unknown access mode: <mode>. Valid: full_access, ask_before_changes, read_only"`. With an explicit mode the block reason reads `"bash requires approval (mode: ask_before_changes)"`; with `mode` omitted it is just `"bash requires approval"`.
- **Public constants** — `Permissions::DEFAULT_TOOLS` is the frozen default set (`%i[write edit bash destroy]`) and `Permissions::ACCESS_MODES` maps each mode key to a frozen config hash with a `:blocked_tools` key (`full_access` → `[]`, the others → `DEFAULT_TOOLS`). The pre-existing `DEFAULT_BLOCKED_TOOLS` and `MODE_BLOCKED_TOOLS` remain available as aliases derived from them.
- **Sticky approvals** — keyed by `tool_call_id`. The first blocked call records one pending `Approval`; repeated calls with the same `tool_call_id` reuse it. `approve(tool_call_id)` returns `true` for **any existing entry** — pending or already approved — and `false` only when the id is unknown; it never raises. Once approved, later calls with that id proceed. Approving one `tool_call_id` never unlocks another. There is no reject API: an entry you never approve keeps blocking.
- **Approval reminder** — the first blocked request for a `tool_call_id` writes a reminder to stderr (`warn`, i.e. `$stderr`); repeated checks against the same still-pending entry stay silent, and an expired entry that gets recreated on the next call warns again.
- **Timeout** — `Permissions.new(timeout: 60)` expires **both pending and approved** entries once `now - created_at` **exceeds** the timeout (`elapsed > timeout` — an entry exactly at the timeout has *not* expired yet), measured from the entry's **original** `created_at`. Expiry is acted on by `before_tool_call` for that `tool_call_id`: the stale entry is removed, a fresh pending `Approval` is recorded with a new `created_at`, and the call blocks again. `pending_approvals` only lists entries whose current status is `:pending` — it never purges expired ones. Without `timeout:` nothing ever expires.
- Tool names normalize to **Symbols** (so `Approval#tool_name` is a Symbol like `:bash`); the gate is mutex-guarded.

Prefer `ApprovalPolicy` for new integrations — it composes with ordered rules and the shared queue. Reach for the mode gate when you only need coarse "block changes until approved" behavior.

## Defaults and safety caveats

- **Unconfigured means allow.** `ApprovalPolicy.new(queue: queue)` with no rules, no `require_approval`, and no tool metadata proceeds on every call; a `PermissionRules` with no matching rule returns `nil`, which the policy treats as proceed. Configure before wiring a policy into an agent.
- **Dangerous tools are downgraded, not blocked.** An unrestricted `allow` on `bash`/`code`/`repl` classifies as `:ask` (the rule's `decision` stays `:allow`; `effective_decision` is `:ask`), but `auto_allow_dangerous: true` turns the guard off — and `:full_access` in the mode gate blocks nothing (`blocked_tools:` is ignored whenever a mode is set).
- **Auto-approve is opt-in twice.** The queue's `auto_approve` hash must contain the tool name `=> true` *and* the submission must be `auto_approvable`; `require_approval` items without matching tool metadata always wait for a human.
- **Auto-approval never skips the line.** A manual item halts the drain until a human resolves it; later auto items do not jump ahead. `approve` / `reject` do not resume the drain themselves — the next `submit` or an explicit `queue.drain` does.
- **Approval state is in memory.** Queues and gate approvals are not persisted and do not survive a restart.
- **Queue approvals are per submission; gate approvals are sticky per `tool_call_id`.**
- **Callback failures are visible.** `on_submit` / `on_approve` / `on_reject` exceptions propagate and leave actions `:pending`; keep callbacks idempotent.

## Development

```sh
bundle install
bundle exec rake test
```

Requires Ruby >= 3.2 (see `ask-permissions.gemspec`).

## Versioning

See [VERSIONING.md](VERSIONING.md). Every release advances the version by exactly one step, and all releases go through `gemchain` — never publish this gem by hand.

## License

MIT. See [LICENSE](LICENSE).
