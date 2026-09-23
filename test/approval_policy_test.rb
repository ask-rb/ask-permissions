# frozen_string_literal: true

require_relative 'test_helper'

class ApprovalPolicyTest < Minitest::Test
  include PermissionTestHelpers

  ToolCall = Struct.new(:id, :name, :arguments, keyword_init: true)

  FakeAction = Data.define(:id, :tool_name, :args, :tool_call_id, :auto_approvable, :message, :status) do
    def auto_approvable?
      !!auto_approvable
    end

    def pending?
      status == :pending
    end
  end

  CapabilityTool = Struct.new(:name, :always_ask, :risk_level, :side_effect_scope, :auto_approvable, keyword_init: true) do
    def always_ask? = always_ask
    def auto_approvable? = auto_approvable
  end

  class FakeQueue
    attr_reader :submissions

    def initialize
      @submissions = []
      @actions = {}
      @sequence = 0
    end

    def submit(tool_name:, args: nil, tool_call_id: nil, auto_approvable: false, message: nil)
      @sequence += 1
      action = FakeAction.new(
        id: @sequence,
        tool_name: tool_name,
        args: args,
        tool_call_id: tool_call_id,
        auto_approvable: auto_approvable,
        message: message,
        status: :pending
      )
      @submissions << action
      @actions[action.id] = action
      action.id
    end

    def [](id)
      @actions[id]
    end
  end

  class FakeRules
    attr_reader :calls

    def initialize(mapping = {}, default: nil)
      @mapping = mapping
      @default = default
      @calls = []
    end

    def classify(name, args = nil)
      @calls << [name, args]
      @mapping.fetch(name, @default)
    end
  end

  def setup
    @queue = FakeQueue.new
  end

  def build_policy(**)
    Ask::Permissions::ApprovalPolicy.new(queue: @queue, **)
  end

  def tool_call(id: 'tc-1', name: 'bash', arguments: nil)
    ToolCall.new(id: id, name: name, arguments: arguments)
  end

  def test_queue_keyword_is_required
    error = assert_raises(ArgumentError) { Ask::Permissions::ApprovalPolicy.new }

    assert_match(/queue/, error.message)
  end

  def test_deny_rule_blocks
    rules = FakeRules.new({ 'delete_user' => :deny })
    policy = build_policy(rules: rules)

    result = policy.before_tool_call(
      tool_call(id: 'tc-9', name: 'delete_user', arguments: { 'id' => 1 }),
      {}
    )

    assert_equal %i[action reason], result.keys
    assert_equal :block, result[:action]
    assert_kind_of String, result[:reason]
    assert_equal "Denied by permission rules: 'delete_user'", result[:reason]
    assert_equal [['delete_user', { 'id' => 1 }]], rules.calls
    assert_empty @queue.submissions
  end

  def test_deny_reason_embeds_the_matched_tool_name_exactly_once
    rules = FakeRules.new({ 'delete_user' => :deny })
    policy = build_policy(rules: rules)

    result = policy.before_tool_call(tool_call(name: 'delete_user'), {})

    assert_equal "Denied by permission rules: 'delete_user'", result[:reason]
    refute_includes result[:reason], '"'
  end

  def test_allow_rule_proceeds_even_when_approval_is_required
    rules = FakeRules.new({ 'bash' => :allow })
    policy = build_policy(rules: rules, require_approval: :all)

    result = policy.before_tool_call(tool_call(name: 'bash'), {})

    assert_equal({ action: :proceed }, result)
    assert_empty @queue.submissions
  end

  def test_allow_rule_cannot_bypass_tool_that_always_requires_human_approval
    rules = FakeRules.new({ 'bash' => :allow })
    tool = fake_tool('bash', auto_approvable: true)
    tool.define_singleton_method(:always_ask?) { true }
    policy = build_policy(rules: rules, tools: { 'bash' => tool })

    result = policy.before_tool_call(tool_call(name: 'bash'), {})

    assert_equal :pending, result[:action]
    refute @queue.submissions.first.auto_approvable?
  end

  def test_high_risk_tool_queues_for_human_approval_and_cannot_auto_approve
    tool = CapabilityTool.new(name: 'deploy', risk_level: :high, side_effect_scope: :external, auto_approvable: true)
    policy = build_policy(tools: { 'deploy' => tool })

    result = policy.before_tool_call(tool_call(name: 'deploy'), {})

    assert_equal :pending, result[:action]
    refute_predicate @queue.submissions.first, :auto_approvable?
  end

  def test_read_only_mode_blocks_unknown_or_mutating_capabilities
    tool = CapabilityTool.new(name: 'opaque', side_effect_scope: :unknown)
    policy = build_policy(mode: :read_only, tools: { 'opaque' => tool })

    result = policy.before_tool_call(tool_call(name: 'opaque'), {})

    assert_equal :block, result[:action]
    assert_empty @queue.submissions
  end

  def test_ask_before_changes_mode_queues_declared_side_effects
    tool = CapabilityTool.new(name: 'write_file', risk_level: :low, side_effect_scope: :workspace, auto_approvable: true)
    policy = build_policy(mode: :ask_before_changes, tools: { 'write_file' => tool })

    result = policy.before_tool_call(tool_call(name: 'write_file'), {})

    assert_equal :pending, result[:action]
    refute_predicate @queue.submissions.first, :auto_approvable?
  end

  def test_full_access_mode_bypasses_risk_gate_but_not_hard_human_gate
    risky_tool = CapabilityTool.new(name: 'deploy', risk_level: :critical, side_effect_scope: :external)
    risky_policy = build_policy(mode: :full_access, tools: { 'deploy' => risky_tool })
    assert_equal({ action: :proceed }, risky_policy.before_tool_call(tool_call(name: 'deploy'), {}))

    mandatory_tool = CapabilityTool.new(name: 'deploy', always_ask: true, risk_level: :critical,
      side_effect_scope: :external)
    mandatory_policy = build_policy(mode: :full_access, tools: { 'deploy' => mandatory_tool })
    assert_equal :pending, mandatory_policy.before_tool_call(tool_call(name: 'deploy'), {})[:action]
  end

  def test_read_only_mode_allows_only_explicitly_declared_side_effect_free_tools
    tool = CapabilityTool.new(name: 'read_config', side_effect_scope: :none)
    policy = build_policy(mode: :read_only, tools: { 'read_config' => tool })

    assert_equal({ action: :proceed }, policy.before_tool_call(tool_call(name: 'read_config'), {}))
  end

  def test_ask_rule_queues_with_auto_approvable_false
    rules = FakeRules.new({ 'bash' => :ask })
    tools = { 'bash' => fake_tool('bash', auto_approvable: true) }
    policy = build_policy(rules: rules, tools: tools)

    result = policy.before_tool_call(
      tool_call(id: 'tc-1', name: 'bash', arguments: { 'command' => 'rm -rf /' }),
      {}
    )

    assert_equal %i[action action_id reason], result.keys
    assert_equal :pending, result[:action]
    assert_kind_of Integer, result[:action_id]
    assert_equal "Tool 'bash' requires approval", result[:reason]
    assert_equal 1, @queue.submissions.size

    submission = @queue.submissions.first

    assert_equal 'bash', submission.tool_name
    assert_equal({ 'command' => 'rm -rf /' }, submission.args)
    assert_equal 'tc-1', submission.tool_call_id
    refute_predicate submission, :auto_approvable?
    assert_equal 'Calling "bash" requires approval', submission.message
    assert_predicate submission, :pending?
  end

  def test_unmatched_rules_fall_through_when_nothing_requires_approval
    rules = FakeRules.new({}, default: nil)
    policy = build_policy(rules: rules)

    result = policy.before_tool_call(tool_call(name: 'read_file'), {})

    assert_equal({ action: :proceed }, result)
    assert_empty @queue.submissions
  end

  def test_require_approval_all_queues_every_tool
    policy = build_policy(require_approval: :all)

    first = policy.before_tool_call(tool_call(id: 'a', name: 'anything'), {})
    second = policy.before_tool_call(tool_call(id: 'b', name: 'other'), {})

    assert_equal :pending, first[:action]
    assert_equal :pending, second[:action]
    assert_equal [false, false], @queue.submissions.map(&:auto_approvable)
    assert_equal %w[anything other], @queue.submissions.map(&:tool_name)
  end

  def test_require_approval_matches_exact_name
    policy = build_policy(require_approval: 'bash')

    assert_equal :pending, policy.before_tool_call(tool_call(name: 'bash'), {})[:action]
    assert_equal({ action: :proceed }, policy.before_tool_call(tool_call(name: 'read_file'), {}))
  end

  def test_require_approval_symbol_matches_string_tool_name
    policy = build_policy(require_approval: :write_file)

    assert_equal :pending, policy.before_tool_call(tool_call(name: 'write_file'), {})[:action]
    assert_equal({ action: :proceed }, policy.before_tool_call(tool_call(name: 'read_file'), {}))
  end

  def test_require_approval_regexp_matches_tool_name
    policy = build_policy(require_approval: /\Awrite_/)

    assert_equal :pending, policy.before_tool_call(tool_call(name: 'write_blob'), {})[:action]
    assert_equal({ action: :proceed }, policy.before_tool_call(tool_call(name: 'read_blob'), {}))
  end

  def test_require_approval_accepts_a_list_of_criteria
    policy = build_policy(require_approval: ['bash', /^rm/, :edit])

    assert_equal :pending, policy.before_tool_call(tool_call(name: 'bash'), {})[:action]
    assert_equal :pending, policy.before_tool_call(tool_call(name: 'rm_secrets'), {})[:action]
    assert_equal :pending, policy.before_tool_call(tool_call(name: 'edit'), {})[:action]
    assert_equal({ action: :proceed }, policy.before_tool_call(tool_call(name: 'read'), {}))
  end

  def test_matching_tool_object_approval_required_queues
    tools = { 'fetch' => fake_tool('fetch', approval_required: true) }
    policy = build_policy(tools: tools)

    assert_equal :pending, policy.before_tool_call(tool_call(id: 'tc-3', name: 'fetch'), {})[:action]
    assert_equal({ action: :proceed }, policy.before_tool_call(tool_call(name: 'render'), {}))
  end

  def test_auto_approvable_comes_from_matching_tool_object
    tools = { 'fetch' => fake_tool('fetch', approval_required: true, auto_approvable: true) }
    policy = build_policy(require_approval: :all, tools: tools)

    policy.before_tool_call(tool_call(id: 'a', name: 'fetch'), {})
    policy.before_tool_call(tool_call(id: 'b', name: 'search'), {})

    assert_predicate @queue.submissions.first, :auto_approvable?
    refute_predicate @queue.submissions.last, :auto_approvable?
  end

  def test_auto_approvable_is_false_without_a_matching_tool
    policy = build_policy(require_approval: 'bash')

    result = policy.before_tool_call(tool_call(name: 'bash'), {})

    refute_predicate @queue.submissions.first, :auto_approvable?
    assert_equal :pending, result[:action]
  end

  def test_symbolic_tool_names_are_normalized
    policy = build_policy(require_approval: 'bash')

    result = policy.before_tool_call(tool_call(name: :bash), {})

    assert_equal :pending, result[:action]
    assert_equal 'bash', @queue.submissions.first.tool_name
  end

  def test_action_ids_are_sequential_integers
    policy = build_policy(require_approval: :all)

    first = policy.before_tool_call(tool_call(id: 'a', name: 'one'), {})
    second = policy.before_tool_call(tool_call(id: 'b', name: 'two'), {})

    assert_instance_of Integer, first[:action_id]
    assert_instance_of Integer, second[:action_id]
    assert_equal 1, first[:action_id]
    assert_equal 2, second[:action_id]
  end

  def test_action_id_is_exactly_the_queue_submit_return_value
    policy = build_policy(require_approval: :all)

    result = policy.before_tool_call(tool_call(id: 'tc-1', name: 'bash'), {})

    assert_equal @queue.submissions.first.id, result[:action_id]
  end

  def test_policies_sharing_a_queue_have_no_own_id_counter
    first = Ask::Permissions::ApprovalPolicy.new(queue: @queue, require_approval: :all)
    second = Ask::Permissions::ApprovalPolicy.new(queue: @queue, require_approval: :all)

    a = first.before_tool_call(tool_call(id: 'a', name: 'one'), {})
    b = second.before_tool_call(tool_call(id: 'b', name: 'two'), {})

    assert_equal 1, a[:action_id]
    assert_equal 2, b[:action_id]
  end

  def test_lookup_maps_action_id_to_the_queue_action
    policy = build_policy(require_approval: 'bash')

    result = policy.before_tool_call(tool_call(id: 'tc-7', name: 'bash'), {})
    action = policy.lookup(result[:action_id])

    assert_same @queue.submissions.first, action
    assert_equal 'tc-7', action.tool_call_id
    assert_nil policy.lookup(9_999)
  end

  def test_tools_registry_supports_hash_array_and_indexable
    tool = fake_tool('fetch', approval_required: true)

    assert_equal :pending, build_policy(tools: { 'fetch' => tool })
      .before_tool_call(tool_call(name: 'fetch'), {})[:action]

    @queue = FakeQueue.new

    assert_equal :pending, build_policy(tools: [tool])
      .before_tool_call(tool_call(name: 'fetch'), {})[:action]

    registry = Object.new
    registry.define_singleton_method(:[]) { |name| name == 'fetch' ? tool : nil }
    @queue = FakeQueue.new

    assert_equal :pending, build_policy(tools: registry)
      .before_tool_call(tool_call(name: 'fetch'), {})[:action]
  end

  def test_hash_tools_registry_supports_symbol_keys
    tool = fake_tool('fetch', approval_required: true)

    policy = build_policy(tools: { fetch: tool })

    assert_equal :pending, policy.before_tool_call(tool_call(name: 'fetch'), {})[:action]
  end

  def test_nothing_configured_proceeds_without_submitting
    policy = build_policy

    result = policy.before_tool_call(tool_call(name: 'read_file', arguments: { 'path' => 'x' }), {})

    assert_equal({ action: :proceed }, result)
    assert_empty @queue.submissions
  end

  def test_rules_take_precedence_over_require_approval_and_tools
    rules = FakeRules.new({ 'bash' => :deny })
    tools = { 'bash' => fake_tool('bash', approval_required: true) }
    policy = build_policy(rules: rules, require_approval: :all, tools: tools)

    result = policy.before_tool_call(tool_call(name: 'bash'), {})

    assert_equal :block, result[:action]
    assert_empty @queue.submissions
  end

  def test_context_argument_is_accepted
    policy = build_policy(require_approval: 'bash')

    result = policy.before_tool_call(tool_call(name: 'bash'), { session: 's-1' })

    assert_equal :pending, result[:action]
  end
end
