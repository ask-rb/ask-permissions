# frozen_string_literal: true

require_relative 'test_helper'

class ApprovalQueueTest < Minitest::Test
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
    assert_equal false, action.auto_approvable
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
    assert_equal false, action.auto_approvable
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

  def test_drain_resumes_after_gate_is_approved
    queue = build_queue(auto_approve: { 'gate' => true, 'auto' => true })
    gate = queue.submit(tool_call_id: '1', tool_name: 'gate')
    auto = queue.submit(tool_call_id: '2', tool_name: 'auto', auto_approvable: true)

    resolved = queue.approve(gate)

    assert_equal [gate], resolved.map(&:id)
    assert_equal :approved, resolved.first.status
    assert_equal :approved, queue[auto].status
    assert_empty queue.pending_actions
    refute_predicate queue, :any_pending?
    assert_equal [gate, auto], @approved.map(&:id)
  end

  def test_drain_resumes_after_gate_is_rejected
    queue = build_queue(auto_approve: { 'gate' => true, 'auto' => true })
    gate = queue.submit(tool_call_id: '1', tool_name: 'gate')
    auto = queue.submit(tool_call_id: '2', tool_name: 'auto', auto_approvable: true)

    resolved = queue.reject(gate)

    assert_equal [gate], resolved.map(&:id)
    assert_equal :rejected, resolved.first.status
    assert_equal :approved, queue[auto].status
    assert_equal [gate], @rejected.map(&:id)
    assert_equal [auto], @approved.map(&:id)
    assert_empty queue.pending_actions
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

  def test_unknown_and_resolved_ids_raise
    queue = build_queue

    assert_raises(Ask::Permissions::UnknownApprovalError) { queue.approve('nope') }
    assert_raises(Ask::Permissions::UnknownApprovalError) { queue.reject('nope') }

    id = queue.submit(tool_call_id: '1', tool_name: 'bash')
    queue.approve(id)

    assert_raises(Ask::Permissions::UnknownApprovalError) { queue.approve(id) }
    assert_raises(Ask::Permissions::UnknownApprovalError) { queue.reject(id) }
    assert_equal :approved, queue[id].status
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
end
