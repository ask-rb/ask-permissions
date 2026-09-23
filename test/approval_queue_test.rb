# frozen_string_literal: true

require_relative 'test_helper'

class ApprovalQueueTest < Minitest::Test
  class HookedQueue < Ask::Permissions::ApprovalQueue
    attr_reader :applied, :rejected_actions

    def initialize(**options)
      super
      @applied = []
      @rejected_actions = []
    end

    private

    def apply(action, scope: :once)
      resolved = super
      @applied << resolved
      resolved
    end

    def reject_action(action, feedback: nil)
      resolved = super
      @rejected_actions << resolved
      resolved
    end
  end

  def setup
    @approved = []
    @rejected = []
    @submitted = []
  end

  def build_queue(auto_approve: {}, on_submit: nil, on_approve: nil, on_reject: nil)
    Ask::Permissions::ApprovalQueue.new(
      auto_approve: auto_approve,
      on_submit: on_submit || ->(action) { @submitted << action },
      on_approve: on_approve || ->(action) { @approved << action },
      on_reject: on_reject || ->(action) { @rejected << action }
    )
  end

  def test_submit_returns_sequential_integer_ids
    queue = build_queue

    ids = Array.new(5) { |i| queue.submit(tool_call_id: "tc-#{i}", tool_name: 'bash') }

    assert_equal [1, 2, 3, 4, 5], ids
  end

  def test_submit_creates_pending_action_with_exact_fields
    queue = build_queue

    id = queue.submit(
      tool_call_id: 'tc-1',
      tool_name: 'bash',
      args: { 'command' => 'ls' },
      message: 'needs eyes'
    )

    action = queue[id]

    assert_kind_of Data, action
    assert_equal 1, action.id
    assert_equal 'tc-1', action.tool_call_id
    assert_equal 'bash', action.tool_name
    assert_equal({ 'command' => 'ls' }, action.args)
    refute(action.auto_approvable)
    assert_equal :pending, action.status
    assert_instance_of Time, action.submitted_at
    assert_equal 'needs eyes', action.message
    assert_predicate action, :pending?
    refute_predicate action, :approved?
    assert_predicate action, :frozen?
    assert_raises(NoMethodError) { action.status = :approved }
  end

  def test_submit_defaults_args_to_empty_hash
    queue = build_queue

    id = queue.submit(tool_call_id: 'tc-1', tool_name: 'read')
    action = queue[id]

    assert_equal({}, action.args)
    assert_nil action.message
    refute(action.auto_approvable)
  end

  def test_pending_query_methods
    queue = build_queue

    refute_predicate queue, :any_pending?
    assert_empty queue.pending_actions
    refute queue.pending?(1)
    assert_nil queue[1]

    first = queue.submit(tool_call_id: 'tc-1', tool_name: 'read')
    second = queue.submit(tool_call_id: 'tc-2', tool_name: 'write')

    assert_predicate queue, :any_pending?
    assert queue.pending?(first)
    assert queue.pending?(second)
    assert_equal [first, second], queue.pending_actions.map(&:id)
    assert_equal 'read', queue[first].tool_name

    queue.approve(first)

    refute queue.pending?(first)
    assert queue.pending?(second)
    assert_equal [second], queue.pending_actions.map(&:id)
    assert_predicate queue, :any_pending?

    queue.approve(second)

    refute_predicate queue, :any_pending?
    assert_empty queue.pending_actions
  end

  def test_auto_approve_drain_requires_flag_and_exact_hash_entry
    enabled = build_queue(auto_approve: { 'read' => true })
    id = enabled.submit(tool_call_id: 'tc-1', tool_name: 'read', auto_approvable: true)

    assert_equal :approved, enabled[id].status

    missing_entry = build_queue(auto_approve: { 'other' => true })
    id = missing_entry.submit(tool_call_id: 'tc-2', tool_name: 'read', auto_approvable: true)

    assert_equal :pending, missing_entry[id].status

    missing_flag = build_queue(auto_approve: { 'read' => true })
    id = missing_flag.submit(tool_call_id: 'tc-3', tool_name: 'read')

    assert_equal :pending, missing_flag[id].status

    not_exactly_true = build_queue(auto_approve: { 'read' => 1 })
    id = not_exactly_true.submit(tool_call_id: 'tc-4', tool_name: 'read', auto_approvable: true)

    assert_equal :pending, not_exactly_true[id].status
  end

  def test_on_submit_fires_before_drain
    events = []
    queue = nil
    queue = Ask::Permissions::ApprovalQueue.new(
      auto_approve: { 'read' => true },
      on_submit: ->(action) { events << [:submit, action.status, queue.pending_actions.map(&:id)] },
      on_approve: ->(action) { events << [:approve, action.status, queue[action.id].status] }
    )

    id = queue.submit(tool_call_id: 'tc-1', tool_name: 'read', auto_approvable: true, message: 'hi')

    assert_equal [
      [:submit, :pending, [id]],
      %i[approve applying applying]
    ], events
    assert_equal :approved, queue[id].status
  end

  def test_ordered_drain_stops_at_first_manual_gate
    queue = build_queue(auto_approve: { 'a1' => true, 'gate' => true, 'a2' => true })

    a1 = queue.submit(tool_call_id: '1', tool_name: 'a1', auto_approvable: true)
    gate = queue.submit(tool_call_id: '2', tool_name: 'gate')
    a2 = queue.submit(tool_call_id: '3', tool_name: 'a2', auto_approvable: true)

    assert_equal :approved, queue[a1].status
    assert_equal :pending, queue[gate].status
    assert_equal :pending, queue[a2].status
    assert_equal [gate, a2], queue.pending_actions.map(&:id)
    assert_equal [a1], @approved.map(&:id)
  end

  def test_drain_does_not_skip_manual_gate_for_later_auto_items
    queue = build_queue(auto_approve: { 'gate' => true, 'auto' => true })

    gate = queue.submit(tool_call_id: '1', tool_name: 'gate')
    auto = queue.submit(tool_call_id: '2', tool_name: 'auto', auto_approvable: true)

    assert_equal :pending, queue[gate].status
    assert_equal :pending, queue[auto].status
    assert_empty @approved
  end

  def test_manual_approve_does_not_drain_following_auto_actions
    queue = build_queue(auto_approve: { 'gate' => true, 'auto' => true })
    gate = queue.submit(tool_call_id: '1', tool_name: 'gate')
    auto = queue.submit(tool_call_id: '2', tool_name: 'auto', auto_approvable: true)

    resolved = queue.approve(gate)

    assert_equal [gate], resolved.map(&:id)
    assert_equal :approved, resolved.first.status
    assert_equal :pending, queue[auto].status
    assert_equal [auto], queue.pending_actions.map(&:id)
    assert_equal [gate], @approved.map(&:id)

    queue.drain

    assert_equal :approved, queue[auto].status
    assert_empty queue.pending_actions
    refute_predicate queue, :any_pending?
    assert_equal [gate, auto], @approved.map(&:id)
  end

  def test_manual_reject_does_not_drain_following_auto_actions
    queue = build_queue(auto_approve: { 'gate' => true, 'auto' => true })
    gate = queue.submit(tool_call_id: '1', tool_name: 'gate')
    auto = queue.submit(tool_call_id: '2', tool_name: 'auto', auto_approvable: true)

    resolved = queue.reject(gate)

    assert_equal [gate], resolved.map(&:id)
    assert_equal :rejected, resolved.first.status
    assert_equal :pending, queue[auto].status
    assert_equal [auto], queue.pending_actions.map(&:id)
    assert_equal [gate], @rejected.map(&:id)
    assert_empty @approved

    queue.drain

    assert_equal :approved, queue[auto].status
    assert_empty queue.pending_actions
    assert_equal [gate], @rejected.map(&:id)
    assert_equal [auto], @approved.map(&:id)
  end

  def test_next_submit_drains_auto_actions_blocked_behind_manual_gate
    queue = build_queue(auto_approve: { 'gate' => true, 'auto' => true })
    gate = queue.submit(tool_call_id: '1', tool_name: 'gate')
    auto = queue.submit(tool_call_id: '2', tool_name: 'auto', auto_approvable: true)

    queue.approve(gate)

    assert_equal :pending, queue[auto].status

    manual = queue.submit(tool_call_id: '3', tool_name: 'manual')

    assert_equal :approved, queue[auto].status
    assert_equal [manual], queue.pending_actions.map(&:id)
    assert_equal [gate, auto], @approved.map(&:id)
  end

  def test_approve_returns_array_of_actions
    queue = build_queue
    one = queue.submit(tool_call_id: '1', tool_name: 'bash')
    two = queue.submit(tool_call_id: '2', tool_name: 'read')

    resolved = queue.approve(one, two)

    assert_equal [one, two], resolved.map(&:id)
    assert(resolved.all? { |action| action.status == :approved })
    assert_empty queue.pending_actions
    assert_equal [one, two], @approved.map(&:id)
    assert_empty @rejected
  end

  def test_reject_returns_array_of_actions
    queue = build_queue
    one = queue.submit(tool_call_id: '1', tool_name: 'bash')
    two = queue.submit(tool_call_id: '2', tool_name: 'read')

    resolved = queue.reject(one, two)

    assert_equal [one, two], resolved.map(&:id)
    assert(resolved.all? { |action| action.status == :rejected })
    assert_empty queue.pending_actions
    assert_equal [one, two], @rejected.map(&:id)
    assert_empty @approved
  end

  def test_approve_all_and_reject_all
    queue = build_queue

    assert_empty queue.approve_all
    assert_empty queue.reject_all

    ids = Array.new(3) { |i| queue.submit(tool_call_id: "tc-#{i}", tool_name: 'tool') }
    approved = queue.approve_all

    assert_equal ids, approved.map(&:id)
    assert_empty queue.pending_actions
    refute_predicate queue, :any_pending?

    other = queue.submit(tool_call_id: 'tc-3', tool_name: 'tool')
    rejected = queue.reject_all

    assert_equal [other], rejected.map(&:id)
    assert_equal :rejected, queue[other].status
    assert_empty queue.pending_actions
  end

  def test_auto_approve_hash_is_exposed
    assert_equal({ 'bash' => true }, build_queue(auto_approve: { 'bash' => true }).auto_approve)
    assert_equal({}, build_queue.auto_approve)
  end

  def test_unknown_and_resolved_ids_are_ignored_without_exceptions
    queue = build_queue

    assert_empty queue.approve('nope')
    assert_empty queue.reject('nope')
    assert_empty queue.approve(nil)
    refute_predicate queue, :any_pending?

    id = queue.submit(tool_call_id: '1', tool_name: 'bash')
    queue.approve(id)

    assert_empty queue.approve(id, 'nope')
    assert_empty queue.reject(id)
    assert_equal :approved, queue[id].status
  end

  def test_approve_flattens_sorts_and_ignores_unknown_or_resolved_ids
    queue = build_queue
    id_one = queue.submit(tool_call_id: '1', tool_name: 'one')
    id_two = queue.submit(tool_call_id: '2', tool_name: 'two')
    id_three = queue.submit(tool_call_id: '3', tool_name: 'three')
    queue.approve(id_two)

    resolved = queue.approve([id_three, [id_one]], id_two, 'nope')

    assert_equal [id_one, id_three], resolved.map(&:id)
    assert(resolved.all? { |action| action.status == :approved })
    assert_empty queue.pending_actions
    assert_equal [id_two, id_one, id_three], @approved.map(&:id)
  end

  def test_reject_flattens_sorts_and_ignores_unknown_or_resolved_ids
    queue = build_queue
    id_one = queue.submit(tool_call_id: '1', tool_name: 'first')
    id_two = queue.submit(tool_call_id: '2', tool_name: 'second')
    resolved_earlier = queue.submit(tool_call_id: '3', tool_name: 'other')
    queue.approve(resolved_earlier)

    resolved = queue.reject([[id_two]], id_one, resolved_earlier, 'nope')

    assert_equal [id_one, id_two], resolved.map(&:id)
    assert(resolved.all? { |action| action.status == :rejected })
    assert_empty queue.pending_actions
    assert_equal :approved, queue[resolved_earlier].status
  end

  def test_callback_attr_accessors_are_readable_and_assignable
    queue = build_queue

    assert_instance_of Proc, queue.on_submit
    assert_instance_of Proc, queue.on_approve
    assert_instance_of Proc, queue.on_reject

    events = []
    queue.on_submit = ->(action) { events << [:submit, action.tool_name] }
    queue.on_approve = ->(action) { events << [:approve, action.tool_name] }
    queue.on_reject = ->(action) { events << [:reject, action.tool_name] }

    approved_id = queue.submit(tool_call_id: '1', tool_name: 'bash')
    queue.approve(approved_id)
    rejected_id = queue.submit(tool_call_id: '2', tool_name: 'read')
    queue.reject(rejected_id)

    assert_equal [
      [:submit, 'bash'],
      [:approve, 'bash'],
      [:submit, 'read'],
      [:reject, 'read']
    ], events
    assert_equal 1, queue.on_submit.arity
    assert_empty @submitted
    assert_empty @approved
    assert_empty @rejected
  end

  def test_approve_callback_failure_resets_pending_and_reraises
    boom = Class.new(StandardError)
    queue = build_queue(on_approve: ->(_action) { raise boom, 'approve failed' })
    id = queue.submit(tool_call_id: '1', tool_name: 'bash')

    error = assert_raises(boom) { queue.approve(id) }

    assert_equal 'approve failed', error.message
    assert_equal :pending, queue[id].status
    assert_equal [id], queue.pending_actions.map(&:id)
    assert_predicate queue, :any_pending?
  end

  def test_reject_callback_failure_resets_pending_and_reraises
    boom = Class.new(StandardError)
    queue = build_queue(on_reject: ->(_action) { raise boom, 'reject failed' })
    id = queue.submit(tool_call_id: '1', tool_name: 'bash')

    error = assert_raises(boom) { queue.reject(id) }

    assert_equal 'reject failed', error.message
    assert_equal :pending, queue[id].status
    assert_equal [id], queue.pending_actions.map(&:id)
    assert_predicate queue, :any_pending?
  end

  def test_on_submit_failure_reraises_and_leaves_action_pending_without_draining
    boom = Class.new(StandardError)
    queue = Ask::Permissions::ApprovalQueue.new(
      auto_approve: { 'bash' => true },
      on_submit: ->(_action) { raise boom, 'submit failed' },
      on_approve: ->(action) { @approved << action }
    )

    assert_raises(boom) do
      queue.submit(tool_call_id: '1', tool_name: 'bash', auto_approvable: true)
    end

    assert_equal 1, queue.pending_actions.size
    assert_equal :pending, queue.pending_actions.first.status
    assert_empty @approved
  end

  def test_drain_callback_failure_resets_pending_and_reraises
    boom = Class.new(StandardError)
    queue = Ask::Permissions::ApprovalQueue.new(
      auto_approve: { 'bash' => true },
      on_approve: ->(_action) { raise boom, 'drain failed' }
    )

    error = assert_raises(boom) do
      queue.submit(tool_call_id: '1', tool_name: 'bash', auto_approvable: true)
    end

    assert_equal 'drain failed', error.message
    assert_equal 1, queue.pending_actions.size
    assert_equal :pending, queue.pending_actions.first.status
    assert_predicate queue, :any_pending?
  end

  def test_explicit_drain_respects_configuration_and_manual_gates
    unconfigured = build_queue(auto_approve: {})
    unconfigured.submit(tool_call_id: '1', tool_name: 'bash', auto_approvable: true)
    unconfigured.drain

    assert_equal 1, unconfigured.pending_actions.size
    assert_equal :pending, unconfigured.pending_actions.first.status

    configured = build_queue(auto_approve: { 'auto' => true })
    gate = configured.submit(tool_call_id: '1', tool_name: 'gate')
    auto = configured.submit(tool_call_id: '2', tool_name: 'auto', auto_approvable: true)
    configured.drain

    assert_equal [gate, auto], configured.pending_actions.map(&:id)
  end

  def test_thread_safety_under_concurrent_submissions
    queue = build_queue
    threads = Array.new(8) do |i|
      Thread.new do
        25.times { |n| queue.submit(tool_call_id: "tc-#{i}-#{n}", tool_name: "tool-#{i}", args: { 'n' => n }) }
      end
    end
    threads.each(&:join)

    ids = queue.pending_actions.map(&:id)

    assert_equal 200, ids.size
    assert_equal 200, ids.uniq.size
    assert_equal (1..200).to_a, ids.sort
  end

  def test_hooks_are_private_extension_points
    hooked = HookedQueue.new
    plain = build_queue

    assert_respond_to hooked, :apply, include_all: true
    assert_respond_to hooked, :reject_action, include_all: true
    refute_respond_to hooked, :apply
    refute_respond_to hooked, :reject_action
    assert_respond_to plain, :apply, include_all: true
    assert_respond_to plain, :reject_action, include_all: true
    refute_respond_to plain, :apply
    refute_respond_to plain, :reject_action
  end

  def test_manual_approve_routes_through_apply_and_returns_resolved_action
    queue = HookedQueue.new(on_approve: ->(action) { @approved << action })
    id = queue.submit(tool_call_id: 'tc-1', tool_name: 'bash')

    resolved = queue.approve(id)

    assert_equal [id], resolved.map(&:id)
    assert_equal :approved, resolved.first.status
    assert_equal resolved.first, queue.applied.first
    assert_predicate queue.applied.first, :approved?
    assert_empty queue.rejected_actions
    assert_equal [id], @approved.map(&:id)
    assert_equal :approved, queue[id].status
  end

  def test_manual_reject_routes_through_reject_action_and_returns_resolved_action
    queue = HookedQueue.new(on_reject: ->(action) { @rejected << action })
    id = queue.submit(tool_call_id: 'tc-1', tool_name: 'bash')

    resolved = queue.reject(id)

    assert_equal [id], resolved.map(&:id)
    assert_equal :rejected, resolved.first.status
    assert_equal resolved.first, queue.rejected_actions.first
    assert_predicate queue.rejected_actions.first, :rejected?
    assert_empty queue.applied
    assert_equal [id], @rejected.map(&:id)
    assert_equal :rejected, queue[id].status
  end

  def test_auto_drain_routes_through_apply
    queue = HookedQueue.new(auto_approve: { 'read' => true }, on_approve: ->(action) { @approved << action })
    id = queue.submit(tool_call_id: 'tc-1', tool_name: 'read', auto_approvable: true)

    assert_equal :approved, queue[id].status
    assert_equal 1, queue.applied.size
    assert_equal id, queue.applied.first.id
    assert_predicate queue.applied.first, :approved?
    assert_empty queue.rejected_actions
    assert_equal [id], @approved.map(&:id)
  end

  def test_explicit_drain_routes_through_apply
    queue = HookedQueue.new(auto_approve: { 'auto' => true })
    gate = queue.submit(tool_call_id: '1', tool_name: 'gate')
    auto = queue.submit(tool_call_id: '2', tool_name: 'auto', auto_approvable: true)

    assert_empty queue.applied

    queue.approve(gate)
    queue.drain

    assert_equal [gate, auto], queue.applied.map(&:id)
    assert_equal :approved, queue[auto].status
  end

  def test_hook_super_failure_rolls_back_to_pending_and_reraises
    boom = Class.new(StandardError)
    queue = HookedQueue.new(on_approve: ->(_action) { raise boom, 'approve failed' })
    id = queue.submit(tool_call_id: '1', tool_name: 'bash')

    assert_raises(boom) { queue.approve(id) }

    assert_equal :pending, queue[id].status
    assert_empty queue.applied
    assert_equal [id], queue.pending_actions.map(&:id)
  end

  def test_hooks_observe_resolved_action_returned_by_super
    observations = []
    subclass = Class.new(HookedQueue) do
      define_method(:apply) do |action, scope: :once|
        super(action, scope: scope).tap { |resolved| observations << [action.id, resolved.status, resolved.equal?(action)] }
      end
    end
    queue = subclass.new
    id = queue.submit(tool_call_id: 'tc-1', tool_name: 'bash')

    returned = queue.approve(id)

    assert_equal [[id, :approved, false]], observations
    assert_equal returned.first, queue[id]
  end

  def test_pending_actions_can_be_snapshotted_and_restored_without_replaying_submission
    original = build_queue
    original.submit(
      tool_call_id: 'tool-call-9',
      tool_name: 'write',
      args: { 'path' => '/tmp/file' },
      message: 'Confirm write'
    )
    snapshot = original.snapshot
    restored_submissions = []
    restored_approvals = []
    restored = build_queue(
      on_submit: ->(action) { restored_submissions << action },
      on_approve: ->(action) { restored_approvals << action }
    )

    assert_equal 1, restored.restore_pending(snapshot)
    assert_empty restored_submissions
    action = restored.pending_actions.fetch(0)
    assert_equal 1, action.id
    assert_equal 'tool-call-9', action.tool_call_id
    assert_equal({ 'path' => '/tmp/file' }, action.args)
    assert_equal 'Confirm write', action.message

    resolved = restored.approve(action.id)
    assert_equal :applying, restored_approvals.fetch(0).status
    assert_equal :approved, resolved.fetch(0).status
  end

  def test_restore_pending_rejects_unsupported_snapshot_versions
    queue = build_queue

    error = assert_raises(ArgumentError) do
      queue.restore_pending('version' => 2, 'pending_actions' => [])
    end

    assert_match(/version/i, error.message)
  end

  def test_approve_defaults_to_once_scope
    queue = build_queue
    id = queue.submit(tool_call_id: '1', tool_name: 'bash')

    resolved = queue.approve(id)

    assert_equal :once, resolved.first.resolution_scope
    assert_equal :once, resolved.first.scope
    assert_nil resolved.first.feedback
    assert_equal :once, queue[id].resolution_scope
    assert_equal :once, @approved.first.resolution_scope
  end

  def test_approve_carries_explicit_session_and_project_scopes
    queue = build_queue
    session_id = queue.submit(tool_call_id: '1', tool_name: 'bash')
    project_id = queue.submit(tool_call_id: '2', tool_name: 'bash')

    session_resolved = queue.approve(session_id, scope: :session)
    project_resolved = queue.approve(project_id, scope: :project)

    assert_equal :session, session_resolved.first.resolution_scope
    assert_equal :session, @approved[0].resolution_scope
    assert_equal :project, project_resolved.first.resolution_scope
    assert_equal :project, @approved[1].resolution_scope
    assert_equal :approved, queue[session_id].status
    assert_equal :approved, queue[project_id].status
  end

  def test_approve_rejects_unknown_scope_without_resolving
    queue = build_queue
    id = queue.submit(tool_call_id: '1', tool_name: 'bash')

    error = assert_raises(ArgumentError) { queue.approve(id, scope: :forever) }

    assert_match(/scope/i, error.message)
    assert_equal :pending, queue[id].status
    assert_empty @approved
  end

  def test_approve_all_forwards_scope_to_each_action
    queue = build_queue
    ids = Array.new(2) { |i| queue.submit(tool_call_id: "tc-#{i}", tool_name: 'tool') }

    resolved = queue.approve_all(scope: :session)

    assert_equal ids, resolved.map(&:id)
    assert(resolved.all? { |action| action.resolution_scope == :session })
    assert_equal %i[session session], @approved.map(&:resolution_scope)
    assert_empty queue.pending_actions
  end

  def test_auto_approved_actions_report_once_scope
    queue = build_queue(auto_approve: { 'read' => true })
    id = queue.submit(tool_call_id: 'tc-1', tool_name: 'read', auto_approvable: true)

    assert_equal :approved, queue[id].status
    assert_equal :once, queue[id].resolution_scope
    assert_equal :once, @approved.first.resolution_scope
    assert_nil @approved.first.feedback
  end

  def test_reject_carries_optional_feedback
    queue = build_queue
    plain_id = queue.submit(tool_call_id: '1', tool_name: 'bash')
    noted_id = queue.submit(tool_call_id: '2', tool_name: 'bash')

    plain = queue.reject(plain_id)
    noted = queue.reject(noted_id, feedback: 'use read instead')

    assert_nil plain.first.feedback
    assert_nil plain.first.resolution_scope
    assert_equal 'use read instead', noted.first.feedback
    assert_equal 'use read instead', @rejected.last.feedback
    assert_equal :rejected, queue[noted_id].status
  end

  def test_reject_all_forwards_feedback
    queue = build_queue
    ids = Array.new(2) { |i| queue.submit(tool_call_id: "tc-#{i}", tool_name: 'tool') }

    resolved = queue.reject_all(feedback: 'not now')

    assert_equal ids, resolved.map(&:id)
    assert_equal ['not now', 'not now'], resolved.map(&:feedback)
    assert_equal ['not now', 'not now'], @rejected.map(&:feedback)
  end

  def test_pending_actions_have_nil_scope_and_feedback_and_snapshots_stay_pending_only
    queue = build_queue
    pending_id = queue.submit(tool_call_id: '1', tool_name: 'bash')
    decided_id = queue.submit(tool_call_id: '2', tool_name: 'bash')

    assert_nil queue[pending_id].resolution_scope
    assert_nil queue[pending_id].feedback

    queue.approve(decided_id, scope: :project)

    snapshot = queue.snapshot

    assert_equal [pending_id], snapshot[:pending_actions].map { |entry| entry[:id] }
    refute snapshot[:pending_actions].any? { |entry| entry.key?(:resolution_scope) }
    refute snapshot[:pending_actions].any? { |entry| entry.key?(:feedback) }
  end

  def test_on_approve_callback_keeps_one_argument_shape
    queue = build_queue

    assert_equal 1, queue.on_approve.arity
    assert_equal 1, queue.on_reject.arity

    approved_id = queue.submit(tool_call_id: '1', tool_name: 'bash')
    queue.approve(approved_id, scope: :session)
    rejected_id = queue.submit(tool_call_id: '2', tool_name: 'bash')
    queue.reject(rejected_id, feedback: 'nope')

    assert_equal :session, @approved.first.resolution_scope
    assert_equal 'nope', @rejected.first.feedback
  end
end
