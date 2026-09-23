# frozen_string_literal: true

require_relative 'test_helper'
require 'json'

class ApprovalPolicySessionGrantsTest < Minitest::Test
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

  def test_session_grants_reader_defaults_to_nil
    policy = build_policy

    assert_nil policy.session_grants
    assert_equal({ action: :proceed }, policy.before_tool_call(tool_call(name: 'read'), {}))
  end

  def test_ungranted_tool_still_queues_for_ask_rule
    grants = Ask::Permissions::SessionPermissionGrants.new
    rules = Ask::Permissions::PermissionRules.new { ask 'bash' }
    policy = build_policy(rules: rules, session_grants: grants)

    result = policy.before_tool_call(tool_call(name: 'bash'), {})

    assert_equal :pending, result[:action]
    assert_equal 1, @queue.submissions.size
  end

  def test_grant_bypasses_ordinary_ask_rule
    grants = Ask::Permissions::SessionPermissionGrants.new
    grants.grant('bash')
    rules = Ask::Permissions::PermissionRules.new { ask 'bash' }
    policy = build_policy(rules: rules, session_grants: grants)

    result = policy.before_tool_call(tool_call(name: 'bash'), {})

    assert_equal({ action: :proceed }, result)
    assert_empty @queue.submissions
  end

  def test_grant_bypasses_require_approval
    grants = Ask::Permissions::SessionPermissionGrants.new
    grants.grant(:bash)
    policy = build_policy(require_approval: 'bash', session_grants: grants)

    assert_equal({ action: :proceed }, policy.before_tool_call(tool_call(name: 'bash'), {}))
    assert_empty @queue.submissions
  end

  def test_grant_bypasses_require_approval_only_for_granted_tool
    grants = Ask::Permissions::SessionPermissionGrants.new
    grants.grant('bash')
    policy = build_policy(require_approval: :all, session_grants: grants)

    assert_equal({ action: :proceed }, policy.before_tool_call(tool_call(name: 'bash'), {}))

    result = policy.before_tool_call(tool_call(name: 'read'), {})

    assert_equal :pending, result[:action]
  end

  def test_grant_bypasses_tool_metadata_approval_required
    tool = CapabilityTool.new(name: 'fetch', side_effect_scope: :none)
    tool.define_singleton_method(:approval_required?) { true }
    grants = Ask::Permissions::SessionPermissionGrants.new
    grants.grant('fetch')
    policy = build_policy(tools: { 'fetch' => tool }, session_grants: grants)

    assert_equal({ action: :proceed }, policy.before_tool_call(tool_call(name: 'fetch'), {}))
    assert_empty @queue.submissions
  end

  def test_grant_bypasses_high_risk_gate
    tool = CapabilityTool.new(name: 'deploy', risk_level: :high, side_effect_scope: :external)
    grants = Ask::Permissions::SessionPermissionGrants.new
    grants.grant('deploy')
    policy = build_policy(tools: { 'deploy' => tool }, session_grants: grants)

    assert_equal({ action: :proceed }, policy.before_tool_call(tool_call(name: 'deploy'), {}))
    assert_empty @queue.submissions
  end

  def test_grant_bypasses_ask_before_changes_side_effect_prompt
    tool = CapabilityTool.new(name: 'write_file', risk_level: :low, side_effect_scope: :workspace)
    grants = Ask::Permissions::SessionPermissionGrants.new
    grants.grant('write_file')
    policy = build_policy(mode: :ask_before_changes, tools: { 'write_file' => tool }, session_grants: grants)

    assert_equal({ action: :proceed }, policy.before_tool_call(tool_call(name: 'write_file'), {}))
    assert_empty @queue.submissions
  end

  def test_explicit_deny_always_blocks_granted_tool
    grants = Ask::Permissions::SessionPermissionGrants.new
    grants.grant('delete_user')
    rules = Ask::Permissions::PermissionRules.new { deny 'delete_user' }
    policy = build_policy(rules: rules, session_grants: grants)

    result = policy.before_tool_call(tool_call(name: 'delete_user'), {})

    assert_equal :block, result[:action]
    assert_equal "Denied by permission rules: 'delete_user'", result[:reason]
    assert_empty @queue.submissions
  end

  def test_always_ask_always_queues_and_cannot_be_bypassed
    tool = CapabilityTool.new(name: 'bash', always_ask: true, side_effect_scope: :none)
    grants = Ask::Permissions::SessionPermissionGrants.new
    grants.grant('bash')
    policy = build_policy(tools: { 'bash' => tool }, session_grants: grants)

    result = policy.before_tool_call(tool_call(name: 'bash'), {})

    assert_equal :pending, result[:action]
    assert_equal 1, @queue.submissions.size
  end

  def test_read_only_blocks_granted_side_effecting_tool
    tool = CapabilityTool.new(name: 'write_file', side_effect_scope: :workspace)
    grants = Ask::Permissions::SessionPermissionGrants.new
    grants.grant('write_file')
    policy = build_policy(mode: :read_only, tools: { 'write_file' => tool }, session_grants: grants)

    result = policy.before_tool_call(tool_call(name: 'write_file'), {})

    assert_equal :block, result[:action]
    assert_empty @queue.submissions
  end

  def test_explicit_allow_still_proceeds
    grants = Ask::Permissions::SessionPermissionGrants.new
    rules = Ask::Permissions::PermissionRules.new { allow 'read_file' }
    policy = build_policy(rules: rules, session_grants: grants)

    assert_equal({ action: :proceed }, policy.before_tool_call(tool_call(name: 'read_file'), {}))
  end

  def test_revoked_grant_queues_again
    grants = Ask::Permissions::SessionPermissionGrants.new
    grants.grant('bash')
    policy = build_policy(require_approval: 'bash', session_grants: grants)

    assert_equal({ action: :proceed }, policy.before_tool_call(tool_call(name: 'bash'), {}))

    grants.revoke('bash')
    result = policy.before_tool_call(tool_call(name: 'bash'), {})

    assert_equal :pending, result[:action]
  end

  def test_grants_do_not_affect_other_policy_instances
    grants = Ask::Permissions::SessionPermissionGrants.new
    grants.grant('bash')

    granted_policy = build_policy(require_approval: 'bash', session_grants: grants)
    other_queue = FakeQueue.new
    isolated_policy = Ask::Permissions::ApprovalPolicy.new(queue: other_queue, require_approval: 'bash')

    assert_equal({ action: :proceed }, granted_policy.before_tool_call(tool_call(name: 'bash'), {}))
    assert_equal :pending, isolated_policy.before_tool_call(tool_call(name: 'bash'), {})[:action]
  end

  def test_grants_do_not_mutate_project_rules
    grants = Ask::Permissions::SessionPermissionGrants.new
    grants.grant('bash')
    rules = Ask::Permissions::PermissionRules.new { ask 'bash' }
    policy = build_policy(rules: rules, session_grants: grants)

    assert_equal({ action: :proceed }, policy.before_tool_call(tool_call(name: 'bash'), {}))
    # The persisted rule still classifies as ask; only the session bypasses it.
    assert_equal :ask, rules.classify('bash')
    assert_equal 1, rules.rules.size
  end

  def test_snapshot_round_trip_preserves_grants_across_resume
    grants = Ask::Permissions::SessionPermissionGrants.new
    grants.grant('bash')
    snapshot = JSON.parse(JSON.generate(grants.snapshot))

    resumed = Ask::Permissions::SessionPermissionGrants.from_snapshot(snapshot)
    policy = build_policy(require_approval: 'bash', session_grants: resumed)

    assert_equal({ action: :proceed }, policy.before_tool_call(tool_call(name: 'bash'), {}))
  end

  def test_invalid_snapshot_raises_on_restore
    grants = Ask::Permissions::SessionPermissionGrants.new

    assert_raises(ArgumentError) { grants.restore_snapshot({ version: 999, granted_tools: [] }) }
    assert_raises(ArgumentError) { Ask::Permissions::SessionPermissionGrants.from_snapshot({ version: 1 }) }
  end
end
