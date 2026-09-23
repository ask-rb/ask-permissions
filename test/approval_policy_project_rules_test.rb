# frozen_string_literal: true

require_relative 'test_helper'
require 'json'

class ApprovalPolicyProjectRulesTest < Minitest::Test
  ToolCall = Struct.new(:id, :name, :arguments, keyword_init: true)

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
      action = { id: @sequence, tool_name: tool_name, auto_approvable: auto_approvable }
      @submissions << action
      @actions[@sequence] = action
      @sequence
    end

    def [](id)
      @actions[id]
    end
  end

  def setup
    @queue = FakeQueue.new
  end

  def tool_call(id: 'tc-1', name: 'bash', arguments: nil)
    ToolCall.new(id: id, name: name, arguments: arguments)
  end

  def build_policy(**kwargs)
    Ask::Permissions::ApprovalPolicy.new(queue: @queue, **kwargs)
  end

  def test_project_rules_reader_defaults_to_nil
    policy = build_policy

    assert_nil policy.project_rules
  end

  def test_project_rules_wraps_in_permission_rule_set
    project_rules = Ask::Permissions::PermissionRules.new { allow 'bash' }
    policy = build_policy(project_rules: project_rules)

    assert_instance_of Ask::Permissions::PermissionRuleSet, policy.rules
  end

  def test_project_rules_composed_with_default_rules
    default_rules = Ask::Permissions::PermissionRules.new { allow 'read_file' }
    project_rules = Ask::Permissions::PermissionRules.new { deny 'write_file' }
    policy = build_policy(rules: default_rules, project_rules: project_rules)

    assert_equal :allow, policy.rules.classify('read_file')
    assert_equal :deny, policy.rules.classify('write_file')
  end

  def test_project_rules_deny_overrides_default_allow
    default_rules = Ask::Permissions::PermissionRules.new { allow 'bash' }
    project_rules = Ask::Permissions::PermissionRules.new { deny 'bash' }
    policy = build_policy(rules: default_rules, project_rules: project_rules)

    result = policy.before_tool_call(tool_call(name: 'bash'), {})

    assert_equal :block, result[:action]
    assert_equal "Denied by permission rules: 'bash'", result[:reason]
  end

  def test_project_rules_ask_queues_for_approval
    default_rules = Ask::Permissions::PermissionRules.new { allow 'bash' }
    project_rules = Ask::Permissions::PermissionRules.new { ask 'bash' }
    policy = build_policy(rules: default_rules, project_rules: project_rules)

    result = policy.before_tool_call(tool_call(name: 'bash'), {})

    assert_equal :pending, result[:action]
    assert_equal 1, @queue.submissions.size
  end

  def test_project_rules_allow_proceeds
    default_rules = Ask::Permissions::PermissionRules.new { ask 'read_file' }
    project_rules = Ask::Permissions::PermissionRules.new { allow 'read_file' }
    policy = build_policy(rules: default_rules, project_rules: project_rules)

    result = policy.before_tool_call(tool_call(name: 'read_file'), {})

    assert_equal({ action: :proceed }, result)
    assert_empty @queue.submissions
  end

  def test_project_rules_only_alone
    project_rules = Ask::Permissions::PermissionRules.new { deny 'delete_user' }
    policy = build_policy(project_rules: project_rules)

    result = policy.before_tool_call(tool_call(name: 'delete_user'), {})

    assert_equal :block, result[:action]
  end

  def test_project_rules_cannot_bypass_always_ask
    project_rules = Ask::Permissions::PermissionRules.new { allow 'bash' }
    tool = CapabilityTool.new(name: 'bash', always_ask: true, side_effect_scope: :none)
    policy = build_policy(project_rules: project_rules, tools: { 'bash' => tool })

    result = policy.before_tool_call(tool_call(name: 'bash'), {})

    assert_equal :pending, result[:action]
    assert_equal 1, @queue.submissions.size
  end

  def test_project_rules_cannot_bypass_read_only_mode
    project_rules = Ask::Permissions::PermissionRules.new { allow 'write_file' }
    tool = CapabilityTool.new(name: 'write_file', side_effect_scope: :workspace)
    policy = build_policy(project_rules: project_rules, mode: :read_only, tools: { 'write_file' => tool })

    result = policy.before_tool_call(tool_call(name: 'write_file'), {})

    assert_equal :block, result[:action]
    assert_empty @queue.submissions
  end

  def test_project_rules_session_grants_interact_correctly
    project_rules = Ask::Permissions::PermissionRules.new { ask 'bash' }
    session_grants = Ask::Permissions::SessionPermissionGrants.new
    session_grants.grant('bash')
    policy = build_policy(project_rules: project_rules, session_grants: session_grants)

    result = policy.before_tool_call(tool_call(name: 'bash'), {})

    assert_equal({ action: :proceed }, result)
    assert_empty @queue.submissions
  end

  def test_project_rules_project_grants_interact_correctly
    project_rules = Ask::Permissions::PermissionRules.new { ask 'bash' }
    project_grants = FakeProjectGrants.new(['bash'])
    policy = build_policy(project_rules: project_rules, project_grants: project_grants)

    result = policy.before_tool_call(tool_call(name: 'bash'), {})

    assert_equal({ action: :proceed }, result)
    assert_empty @queue.submissions
  end

  def test_project_rules_deny_still_blocks_even_with_grants
    project_rules = Ask::Permissions::PermissionRules.new { deny 'delete_user' }
    session_grants = Ask::Permissions::SessionPermissionGrants.new
    session_grants.grant('delete_user')
    policy = build_policy(project_rules: project_rules, session_grants: session_grants)

    result = policy.before_tool_call(tool_call(name: 'delete_user'), {})

    assert_equal :block, result[:action]
    assert_equal "Denied by permission rules: 'delete_user'", result[:reason]
  end

  def test_project_rules_snapshot_round_trip
    default_rules = Ask::Permissions::PermissionRules.new { allow 'read_file' }
    project_rules = Ask::Permissions::PermissionRules.new { deny 'write_file' }
    policy = build_policy(rules: default_rules, project_rules: project_rules)

    snapshot = policy.rules.snapshot
    json = JSON.generate(snapshot)
    restored_rules = Ask::Permissions::PermissionRuleSet.from_snapshot(JSON.parse(json))
    restored_policy = build_policy(rules: restored_rules)

    assert_equal :allow, restored_policy.rules.classify('read_file')
    assert_equal :deny, restored_policy.rules.classify('write_file')
  end

  def test_unmatched_project_rules_fall_through_to_default
    default_rules = Ask::Permissions::PermissionRules.new { allow 'read_file' }
    project_rules = Ask::Permissions::PermissionRules.new
    policy = build_policy(rules: default_rules, project_rules: project_rules)

    result = policy.before_tool_call(tool_call(name: 'read_file'), {})

    assert_equal({ action: :proceed }, result)
  end

  def test_project_rules_unmatched_tool_falls_through
    default_rules = Ask::Permissions::PermissionRules.new { allow 'read_file' }
    project_rules = Ask::Permissions::PermissionRules.new { deny 'write_file' }
    policy = build_policy(rules: default_rules, project_rules: project_rules)

    result = policy.before_tool_call(tool_call(name: 'read_file'), {})

    assert_equal({ action: :proceed }, result)
  end

  def test_project_rules_with_require_approval_interaction
    default_rules = Ask::Permissions::PermissionRules.new { allow 'read_file' }
    project_rules = Ask::Permissions::PermissionRules.new { allow 'read_file' }
    policy = build_policy(rules: default_rules, project_rules: project_rules, require_approval: :all)

    result = policy.before_tool_call(tool_call(name: 'read_file'), {})

    assert_equal({ action: :proceed }, result)
  end

  def test_project_rules_ask_overrides_require_approval
    default_rules = Ask::Permissions::PermissionRules.new
    project_rules = Ask::Permissions::PermissionRules.new { ask 'bash' }
    policy = build_policy(rules: default_rules, project_rules: project_rules, require_approval: :all)

    result = policy.before_tool_call(tool_call(name: 'bash'), {})

    assert_equal :pending, result[:action]
  end

  private

  class FakeProjectGrants
    def initialize(granted = [])
      @granted = granted.map(&:to_s)
    end

    def granted?(tool_name)
      @granted.include?(tool_name.to_s)
    end
  end
end
