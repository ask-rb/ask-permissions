# frozen_string_literal: true

require_relative 'test_helper'

class PermissionsTest < Minitest::Test
  ToolCall = Struct.new(:id, :name, :arguments, keyword_init: true)

  CHANGE_TOOLS = %w[write edit bash destroy].freeze

  def setup
    @now = Time.at(1_700_000_000)
    @clock = -> { @now }
  end

  def build_gate(mode: nil, **options)
    Ask::Permissions::Permissions.new(mode: mode, clock: @clock, **options)
  end

  def tool_call(id: 'tc-1', name: 'bash', arguments: nil)
    ToolCall.new(id: id, name: name, arguments: arguments)
  end

  def test_defaults_block_change_tools
    gate = build_gate

    assert_equal :ask_before_changes, gate.mode
    assert_equal %w[write edit bash destroy], gate.blocked_tools

    CHANGE_TOOLS.each_with_index do |name, index|
      result = gate.before_tool_call(tool_call(id: "tc-#{index}", name: name), {})

      assert_equal :block, result[:action], "expected #{name} to be blocked"
      assert_kind_of String, result[:reason]
    end

    assert_equal({ action: :proceed }, gate.before_tool_call(tool_call(id: 'r', name: 'read_file'), {}))
    assert_equal CHANGE_TOOLS.size, gate.pending_approvals.size
  end

  def test_full_access_blocks_nothing
    gate = build_gate(mode: :full_access)

    assert_equal :full_access, gate.mode
    assert_empty gate.blocked_tools

    (CHANGE_TOOLS + %w[read_file]).each_with_index do |name, index|
      call = tool_call(id: "tc-#{index}", name: name, arguments: { 'path' => 'x' })

      assert_equal({ action: :proceed }, gate.before_tool_call(call, {}), "expected #{name} to proceed")
    end
    assert_empty gate.pending_approvals
  end

  def test_ask_before_changes_and_read_only_block_the_same_tools
    %i[ask_before_changes read_only].each do |mode|
      gate = build_gate(mode: mode)

      assert_equal mode, gate.mode
      assert_equal %w[write edit bash destroy], gate.blocked_tools

      CHANGE_TOOLS.each_with_index do |name, index|
        result = gate.before_tool_call(tool_call(id: "#{mode}-#{index}", name: name), {})

        assert_equal :block, result[:action], "expected #{mode} to block #{name}"
      end
      assert_equal({ action: :proceed }, gate.before_tool_call(tool_call(id: "#{mode}-r", name: 'read_file'), {}))
    end
  end

  def test_custom_blocked_tools_extend_the_mode_defaults
    gate = build_gate(blocked_tools: ['upload', :delete_all])

    assert_equal %w[write edit bash destroy upload delete_all], gate.blocked_tools
    assert_equal :block, gate.before_tool_call(tool_call(id: 'u', name: 'upload'), {})[:action]
    assert_equal :block, gate.before_tool_call(tool_call(id: 'd', name: 'delete_all'), {})[:action]
    assert_equal :block, gate.before_tool_call(tool_call(id: 'w', name: 'write'), {})[:action]
    assert_equal({ action: :proceed }, gate.before_tool_call(tool_call(id: 'r', name: 'read_file'), {}))
  end

  def test_custom_blocked_tools_apply_in_full_access_mode
    gate = build_gate(mode: :full_access, blocked_tools: ['upload'])

    assert_equal %w[upload], gate.blocked_tools
    assert_equal :block, gate.before_tool_call(tool_call(id: 'u', name: 'upload'), {})[:action]
    assert_equal({ action: :proceed }, gate.before_tool_call(tool_call(id: 'w', name: 'write'), {}))
  end

  def test_unknown_mode_raises_argument_error
    error = assert_raises(ArgumentError) { Ask::Permissions::Permissions.new(mode: :yolo) }

    assert_match(/yolo/, error.message)
    assert_raises(ArgumentError) { Ask::Permissions::Permissions.new(mode: 'ask_before_changes') }
  end

  def test_first_blocked_call_records_pending_and_blocks
    gate = build_gate
    call = tool_call(id: 'tc-1', name: 'write', arguments: { 'path' => 'a.txt' })

    result = gate.before_tool_call(call, {})

    assert_equal %i[action reason], result.keys
    assert_equal :block, result[:action]
    assert_kind_of String, result[:reason]
    assert_includes result[:reason], 'write'

    assert_equal 1, gate.pending_approvals.size
    entry = gate.pending_approvals.first

    assert_equal 'tc-1', entry.tool_call_id
    assert_equal 'write', entry.tool_name
    assert_equal({ 'path' => 'a.txt' }, entry.arguments)
    assert_equal :pending, entry.status
    assert_equal result[:reason], entry.reason
    assert_instance_of Time, entry.submitted_at
    assert_nil entry.approved_at
    assert_predicate entry, :pending?
  end

  def test_repeated_blocked_call_while_pending_keeps_the_same_entry
    gate = build_gate
    first = gate.before_tool_call(tool_call(id: 'tc-1', name: 'bash'), {})
    second = gate.before_tool_call(tool_call(id: 'tc-1', name: 'bash'), {})

    assert_equal :block, first[:action]
    assert_equal :block, second[:action]
    assert_equal first[:reason], second[:reason]
    assert_equal 1, gate.pending_approvals.size
  end

  def test_distinct_tool_calls_record_distinct_pending_entries
    gate = build_gate
    gate.before_tool_call(tool_call(id: 'tc-1', name: 'write'), {})
    gate.before_tool_call(tool_call(id: 'tc-2', name: 'bash'), {})

    assert_equal 2, gate.pending_approvals.size
    assert_equal %w[bash write], gate.pending_approvals.map(&:tool_name).sort
    assert_equal %w[tc-1 tc-2], gate.pending_approvals.map(&:tool_call_id).sort
  end

  def test_unblocked_calls_never_record_entries
    gate = build_gate

    3.times { |index| gate.before_tool_call(tool_call(id: "r-#{index}", name: 'read_file'), {}) }

    assert_empty gate.pending_approvals
  end

  def test_approve_marks_existing_pending_approved
    gate = build_gate
    gate.before_tool_call(tool_call(id: 'tc-1', name: 'bash'), {})

    entry = gate.approve('tc-1')

    assert_equal :approved, entry.status
    assert_equal 'tc-1', entry.tool_call_id
    assert_instance_of Time, entry.approved_at
    refute_predicate entry, :pending?
    assert_predicate entry, :approved?
    assert_empty gate.pending_approvals
  end

  def test_repeated_calls_proceed_after_approval
    gate = build_gate
    gate.before_tool_call(tool_call(id: 'tc-1', name: 'bash'), {})
    gate.approve('tc-1')

    3.times do
      assert_equal({ action: :proceed }, gate.before_tool_call(tool_call(id: 'tc-1', name: 'bash'), {}))
    end
    assert_empty gate.pending_approvals
  end

  def test_approving_one_tool_call_does_not_unlock_others
    gate = build_gate
    gate.before_tool_call(tool_call(id: 'tc-1', name: 'bash'), {})
    gate.before_tool_call(tool_call(id: 'tc-2', name: 'write'), {})

    gate.approve('tc-1')

    assert_equal({ action: :proceed }, gate.before_tool_call(tool_call(id: 'tc-1', name: 'bash'), {}))
    assert_equal :block, gate.before_tool_call(tool_call(id: 'tc-2', name: 'write'), {})[:action]
    assert_equal 1, gate.pending_approvals.size
  end

  def test_symbol_tool_names_are_normalized
    gate = build_gate

    result = gate.before_tool_call(tool_call(id: 'tc-1', name: :write, arguments: {}), {})

    assert_equal :block, result[:action]
    assert_equal 'write', gate.pending_approvals.first.tool_name
  end

  def test_approve_unknown_id_raises
    gate = build_gate

    error = assert_raises(Ask::Permissions::UnknownApprovalError) { gate.approve('missing') }

    assert_match(/missing/, error.message)
  end

  def test_approve_twice_raises
    gate = build_gate
    gate.before_tool_call(tool_call(id: 'tc-1', name: 'bash'), {})
    gate.approve('tc-1')

    assert_raises(Ask::Permissions::UnknownApprovalError) { gate.approve('tc-1') }
  end

  def test_timeout_expires_approval_and_reblocks
    gate = build_gate(timeout: 60)
    gate.before_tool_call(tool_call(id: 'tc-1', name: 'bash'), {})
    gate.approve('tc-1')

    @now += 59

    assert_equal({ action: :proceed }, gate.before_tool_call(tool_call(id: 'tc-1', name: 'bash'), {}))

    @now += 1
    result = gate.before_tool_call(tool_call(id: 'tc-1', name: 'bash'), {})

    assert_equal :block, result[:action]
    assert_equal 1, gate.pending_approvals.size

    entry = gate.pending_approvals.first

    assert_equal :pending, entry.status
    assert_nil entry.approved_at
    assert_equal @now, entry.submitted_at

    gate.approve('tc-1')

    assert_equal({ action: :proceed }, gate.before_tool_call(tool_call(id: 'tc-1', name: 'bash'), {}))
    assert_empty gate.pending_approvals
  end

  def test_approval_never_expires_without_a_timeout
    gate = build_gate
    gate.before_tool_call(tool_call(id: 'tc-1', name: 'bash'), {})
    gate.approve('tc-1')

    @now += 10_000_000

    assert_equal({ action: :proceed }, gate.before_tool_call(tool_call(id: 'tc-1', name: 'bash'), {}))
  end

  def test_pending_entries_do_not_expire
    gate = build_gate(timeout: 60)
    first = gate.before_tool_call(tool_call(id: 'tc-1', name: 'bash'), {})

    @now += 1000

    assert_equal 1, gate.pending_approvals.size
    second = gate.before_tool_call(tool_call(id: 'tc-1', name: 'bash'), {})

    assert_equal :block, second[:action]
    assert_equal first[:reason], second[:reason]
    assert_equal 1, gate.pending_approvals.size
  end

  def test_before_tool_call_tolerates_a_missing_context_argument
    gate = build_gate(mode: :full_access)

    assert_equal({ action: :proceed }, gate.before_tool_call(tool_call(name: 'read_file')))
  end

  def test_concurrent_blocked_calls_record_a_single_pending_entry
    gate = build_gate

    threads = Array.new(6) do
      Thread.new do
        20.times { gate.before_tool_call(tool_call(id: 'tc-1', name: 'bash'), {}) }
      end
    end
    threads.each(&:join)

    assert_equal 1, gate.pending_approvals.size
  end
end
