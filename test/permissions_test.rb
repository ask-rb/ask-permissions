# frozen_string_literal: true

require_relative 'test_helper'

class PermissionsTest < Minitest::Test
  ToolCall = Struct.new(:id, :name, :arguments, keyword_init: true)

  CHANGE_TOOLS = %w[write edit bash destroy].freeze
  DEFAULT_BLOCKED_TOOLS = %i[write edit bash destroy].freeze

  def setup
    @now = Time.at(1_700_000_000)
    @clock = -> { @now }
  end

  def build_gate(mode: nil, **)
    Ask::Permissions::Permissions.new(mode: mode, clock: @clock, **)
  end

  def tool_call(id: 'tc-1', name: 'bash', arguments: nil)
    ToolCall.new(id: id, name: name, arguments: arguments)
  end

  def test_omitted_mode_stays_nil_and_blocks_the_default_change_tools
    gate = build_gate

    assert_nil gate.mode
    assert_equal DEFAULT_BLOCKED_TOOLS, gate.blocked_tools

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
      assert_equal DEFAULT_BLOCKED_TOOLS, gate.blocked_tools

      CHANGE_TOOLS.each_with_index do |name, index|
        result = gate.before_tool_call(tool_call(id: "#{mode}-#{index}", name: name), {})

        assert_equal :block, result[:action], "expected #{mode} to block #{name}"
      end
      assert_equal({ action: :proceed }, gate.before_tool_call(tool_call(id: "#{mode}-r", name: 'read_file'), {}))
    end
  end

  def test_nil_mode_with_custom_blocked_tools_blocks_only_those_tools
    gate = build_gate(blocked_tools: ['upload', :delete_all])

    assert_nil gate.mode
    assert_equal %i[upload delete_all], gate.blocked_tools
    assert_equal :block, gate.before_tool_call(tool_call(id: 'u', name: 'upload'), {})[:action]
    assert_equal :block, gate.before_tool_call(tool_call(id: 'd', name: :delete_all), {})[:action]
    assert_equal({ action: :proceed }, gate.before_tool_call(tool_call(id: 'w', name: 'write'), {}))
    assert_equal({ action: :proceed }, gate.before_tool_call(tool_call(id: 'r', name: 'read_file'), {}))
    assert_equal 2, gate.pending_approvals.size
  end

  def test_explicit_mode_ignores_custom_blocked_tools
    full_access = build_gate(mode: :full_access, blocked_tools: ['upload'])

    assert_empty full_access.blocked_tools
    assert_equal({ action: :proceed }, full_access.before_tool_call(tool_call(id: 'u', name: 'upload'), {}))
    assert_empty full_access.pending_approvals

    guarded = build_gate(mode: :ask_before_changes, blocked_tools: ['upload'])

    assert_equal DEFAULT_BLOCKED_TOOLS, guarded.blocked_tools
    assert_equal :block, guarded.before_tool_call(tool_call(id: 'w', name: 'write'), {})[:action]
    assert_equal({ action: :proceed }, guarded.before_tool_call(tool_call(id: 'u', name: 'upload'), {}))
  end

  def test_unknown_mode_raises_argument_error
    error = assert_raises(ArgumentError) { Ask::Permissions::Permissions.new(mode: :yolo) }

    assert_match(/yolo/, error.message)
    assert_raises(ArgumentError) { Ask::Permissions::Permissions.new(mode: 'ask_before_changes') }
  end

  def test_unknown_mode_error_message_is_exact
    error = assert_raises(ArgumentError) { Ask::Permissions::Permissions.new(mode: :yolo) }

    expected = 'Unknown access mode: :yolo. Valid: full_access, ask_before_changes, read_only'

    assert_equal expected, error.message
  end

  def test_public_default_tools_and_access_modes_constants
    klass = Ask::Permissions::Permissions

    assert_equal %i[write edit bash destroy], klass::DEFAULT_TOOLS
    assert_predicate klass::DEFAULT_TOOLS, :frozen?
    assert_equal klass::DEFAULT_TOOLS, klass::DEFAULT_BLOCKED_TOOLS

    assert_equal %i[full_access ask_before_changes read_only], klass::ACCESS_MODES.keys
    assert_predicate klass::ACCESS_MODES, :frozen?

    klass::ACCESS_MODES.each_value do |config|
      assert_predicate config, :frozen?
      assert_includes config.keys, :blocked_tools
      assert_kind_of Array, config[:blocked_tools]
      assert_predicate config[:blocked_tools], :frozen?
    end

    assert_empty klass::ACCESS_MODES[:full_access][:blocked_tools]
    assert_equal klass::DEFAULT_TOOLS, klass::ACCESS_MODES[:ask_before_changes][:blocked_tools]
    assert_equal klass::DEFAULT_TOOLS, klass::ACCESS_MODES[:read_only][:blocked_tools]

    assert_predicate klass::MODE_BLOCKED_TOOLS, :frozen?
    assert_equal klass::ACCESS_MODES.keys, klass::MODE_BLOCKED_TOOLS.keys
    assert_equal klass::ACCESS_MODES[:full_access][:blocked_tools],
                 klass::MODE_BLOCKED_TOOLS[:full_access]
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
    assert_equal :write, entry.tool_name
    assert_equal({ 'path' => 'a.txt' }, entry.arguments)
    assert_equal :pending, entry.status
    assert_equal result[:reason], entry.reason
    assert_instance_of Time, entry.created_at
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

  def test_first_blocked_call_warns_once_and_repeated_checks_stay_silent
    gate = build_gate
    expected = "[Permissions] Tool 'bash' requires approval. Call approve('tc-1') to allow.\n"

    out, err = capture_io { gate.before_tool_call(tool_call(id: 'tc-1', name: 'bash'), {}) }

    assert_empty out
    assert_equal expected, err

    out, err = capture_io do
      3.times { gate.before_tool_call(tool_call(id: 'tc-1', name: 'bash'), {}) }
    end

    assert_empty out
    assert_empty err
  end

  def test_expired_pending_call_warns_again_when_recreated
    gate = build_gate(timeout: 60)
    expected = "[Permissions] Tool 'write' requires approval. Call approve('tc-1') to allow.\n"

    _out, err = capture_io { gate.before_tool_call(tool_call(id: 'tc-1', name: 'write'), {}) }

    assert_equal expected, err

    @now += 61

    _out, err = capture_io { gate.before_tool_call(tool_call(id: 'tc-1', name: 'write'), {}) }

    assert_equal expected, err
    assert_equal 1, gate.pending_approvals.size
  end

  def test_distinct_tool_calls_record_distinct_pending_entries
    gate = build_gate
    gate.before_tool_call(tool_call(id: 'tc-1', name: 'write'), {})
    gate.before_tool_call(tool_call(id: 'tc-2', name: 'bash'), {})

    assert_equal 2, gate.pending_approvals.size
    assert_equal %i[bash write], gate.pending_approvals.map(&:tool_name).sort
    assert_equal %w[tc-1 tc-2], gate.pending_approvals.map(&:tool_call_id).sort
  end

  def test_unblocked_calls_never_record_entries
    gate = build_gate

    3.times { |index| gate.before_tool_call(tool_call(id: "r-#{index}", name: 'read_file'), {}) }

    assert_empty gate.pending_approvals
  end

  def test_tool_names_are_normalized_to_symbols
    gate = build_gate

    string_result = gate.before_tool_call(tool_call(id: 'tc-1', name: 'write', arguments: {}), {})
    symbol_result = gate.before_tool_call(tool_call(id: 'tc-2', name: :write, arguments: {}), {})

    assert_equal :block, string_result[:action]
    assert_equal :block, symbol_result[:action]
    assert_equal %i[write write], gate.pending_approvals.map(&:tool_name)
    assert_includes string_result[:reason], 'write'
  end

  def test_approve_returns_true_and_unlocks_the_call
    gate = build_gate
    gate.before_tool_call(tool_call(id: 'tc-1', name: 'bash'), {})

    assert_same true, gate.approve('tc-1')
    assert_empty gate.pending_approvals
    assert_equal({ action: :proceed }, gate.before_tool_call(tool_call(id: 'tc-1', name: 'bash'), {}))
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

  def test_approve_unknown_id_returns_false
    gate = build_gate

    assert_same false, gate.approve('missing')
    assert_empty gate.pending_approvals
  end

  def test_approving_twice_returns_true
    gate = build_gate
    gate.before_tool_call(tool_call(id: 'tc-1', name: 'bash'), {})

    assert_same true, gate.approve('tc-1')
    assert_same true, gate.approve('tc-1')
    assert_equal({ action: :proceed }, gate.before_tool_call(tool_call(id: 'tc-1', name: 'bash'), {}))
  end

  def test_timeout_expires_the_pending_entry_and_reblocks_the_next_call
    gate = build_gate(timeout: 60)
    gate.before_tool_call(tool_call(id: 'tc-1', name: 'bash'), {})

    @now += 59

    assert_equal 1, gate.pending_approvals.size
    assert_equal :block, gate.before_tool_call(tool_call(id: 'tc-1', name: 'bash'), {})[:action]
    assert_equal 1, gate.pending_approvals.size

    @now += 1

    assert_equal 1, gate.pending_approvals.size
    assert_equal :block, gate.before_tool_call(tool_call(id: 'tc-1', name: 'bash'), {})[:action]
    assert_equal 1, gate.pending_approvals.size
    assert_same true, gate.approve('tc-1')
    assert_equal({ action: :proceed }, gate.before_tool_call(tool_call(id: 'tc-1', name: 'bash'), {}))

    @now += 1

    result = gate.before_tool_call(tool_call(id: 'tc-1', name: 'bash'), {})

    assert_equal :block, result[:action]
    assert_equal 1, gate.pending_approvals.size

    entry = gate.pending_approvals.first

    assert_equal :pending, entry.status
    assert_nil entry.approved_at
    assert_equal @now, entry.created_at

    assert_same true, gate.approve('tc-1')

    assert_equal({ action: :proceed }, gate.before_tool_call(tool_call(id: 'tc-1', name: 'bash'), {}))
    assert_empty gate.pending_approvals
  end

  def test_exact_timeout_boundary_does_not_expire_a_pending_entry
    gate = build_gate(timeout: 60)
    original = gate.before_tool_call(tool_call(id: 'tc-1', name: 'bash'), {})

    @now += 60

    result = gate.before_tool_call(tool_call(id: 'tc-1', name: 'bash'), {})
    entry = gate.pending_approvals.first

    assert_equal :block, original[:action]
    assert_equal :block, result[:action]
    assert_equal 1, gate.pending_approvals.size
    assert_equal Time.at(1_700_000_000), entry.created_at

    @now += 1

    gate.before_tool_call(tool_call(id: 'tc-1', name: 'bash'), {})

    assert_equal 1, gate.pending_approvals.size
    assert_equal @now, gate.pending_approvals.first.created_at
  end

  def test_exact_timeout_boundary_does_not_expire_an_approved_grant
    gate = build_gate(timeout: 60)
    gate.before_tool_call(tool_call(id: 'tc-1', name: 'bash'), {})
    gate.approve('tc-1')

    @now += 60

    assert_equal({ action: :proceed }, gate.before_tool_call(tool_call(id: 'tc-1', name: 'bash'), {}))

    @now += 1

    assert_equal :block, gate.before_tool_call(tool_call(id: 'tc-1', name: 'bash'), {})[:action]
    assert_equal 1, gate.pending_approvals.size
  end

  def test_approved_grant_expires_from_original_created_at_and_reblocks
    gate = build_gate(timeout: 60)
    gate.before_tool_call(tool_call(id: 'tc-1', name: 'bash'), {})

    @now += 30
    gate.approve('tc-1')

    @now += 29

    assert_equal({ action: :proceed }, gate.before_tool_call(tool_call(id: 'tc-1', name: 'bash'), {}))

    @now += 2

    result = gate.before_tool_call(tool_call(id: 'tc-1', name: 'bash'), {})

    assert_equal :block, result[:action]
    assert_equal 1, gate.pending_approvals.size

    entry = gate.pending_approvals.first

    assert_equal :pending, entry.status
    assert_nil entry.approved_at
    assert_equal @now, entry.created_at

    assert_same true, gate.approve('tc-1')
    assert_equal({ action: :proceed }, gate.before_tool_call(tool_call(id: 'tc-1', name: 'bash'), {}))
  end

  def test_approval_never_expires_without_a_timeout
    gate = build_gate
    gate.before_tool_call(tool_call(id: 'tc-1', name: 'bash'), {})
    gate.approve('tc-1')

    @now += 10_000_000

    assert_equal({ action: :proceed }, gate.before_tool_call(tool_call(id: 'tc-1', name: 'bash'), {}))
  end

  def test_pending_entries_never_expire_without_a_timeout
    gate = build_gate
    gate.before_tool_call(tool_call(id: 'tc-1', name: 'bash'), {})

    @now += 10_000_000

    assert_equal 1, gate.pending_approvals.size
    assert_equal :block, gate.before_tool_call(tool_call(id: 'tc-1', name: 'bash'), {})[:action]
    assert_equal 1, gate.pending_approvals.size
    assert_same true, gate.approve('tc-1')
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
