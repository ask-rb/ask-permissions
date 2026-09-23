# frozen_string_literal: true

require_relative 'test_helper'

class ApprovalPolicyProjectGrantsTest < Minitest::Test
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

  # Host-owned collaborator: ApprovalPolicy only calls granted?(tool_name).
  # No storage/persistence lives in the policy.
  class FakeProjectGrants
    def initialize(granted = [])
      @granted = granted.map(&:to_s)
    end

    def granted?(tool_name)
      @granted.include?(tool_name.to_s)
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

  def test_project_grants_reader_defaults_to_nil
    policy = build_policy

    assert_nil policy.project_grants
    assert_nil policy.session_grants
  end

  def test_both_grants_nil_preserves_ordinary_ask_behavior
    rules = Ask::Permissions::PermissionRules.new { ask 'bash' }
    policy = build_policy(rules: rules, require_approval: 'bash')

    result = policy.before_tool_call(tool_call(name: 'bash'), {})

    assert_equal :pending, result[:action]
    assert_equal 1, @queue.submissions.size
  end

  def test_project_grant_bypasses_ordinary_ask_rule
    project_grants = FakeProjectGrants.new(['bash'])
    rules = Ask::Permissions::PermissionRules.new { ask 'bash' }
    policy = build_policy(rules: rules, project_grants: project_grants)

    result = policy.before_tool_call(tool_call(name: 'bash'), {})

    assert_equal({ action: :proceed }, result)
    assert_empty @queue.submissions
  end

  def test_project_grant_bypasses_require_approval
    project_grants = FakeProjectGrants.new(['bash'])
    policy = build_policy(require_approval: 'bash', project_grants: project_grants)

    assert_equal({ action: :proceed }, policy.before_tool_call(tool_call(name: 'bash'), {}))
    assert_empty @queue.submissions
  end

  def test_project_grant_bypasses_tool_metadata_approval_required
    tool = CapabilityTool.new(name: 'fetch', side_effect_scope: :none)
    tool.define_singleton_method(:approval_required?) { true }
    project_grants = FakeProjectGrants.new(['fetch'])
    policy = build_policy(tools: { 'fetch' => tool }, project_grants: project_grants)

    assert_equal({ action: :proceed }, policy.before_tool_call(tool_call(name: 'fetch'), {}))
    assert_empty @queue.submissions
  end

  def test_project_grant_bypasses_elevated_risk_prompt
    tool = CapabilityTool.new(name: 'deploy', risk_level: :high, side_effect_scope: :external)
    project_grants = FakeProjectGrants.new(['deploy'])
    policy = build_policy(tools: { 'deploy' => tool }, project_grants: project_grants)

    assert_equal({ action: :proceed }, policy.before_tool_call(tool_call(name: 'deploy'), {}))
    assert_empty @queue.submissions
  end

  def test_project_grant_bypasses_ask_before_changes_side_effect_prompt
    tool = CapabilityTool.new(name: 'write_file', risk_level: :low, side_effect_scope: :workspace)
    project_grants = FakeProjectGrants.new(['write_file'])
    policy = build_policy(mode: :ask_before_changes, tools: { 'write_file' => tool }, project_grants: project_grants)

    assert_equal({ action: :proceed }, policy.before_tool_call(tool_call(name: 'write_file'), {}))
    assert_empty @queue.submissions
  end

  def test_project_grant_only_applies_to_granted_tool
    project_grants = FakeProjectGrants.new(['bash'])
    policy = build_policy(require_approval: :all, project_grants: project_grants)

    assert_equal({ action: :proceed }, policy.before_tool_call(tool_call(name: 'bash'), {}))

    result = policy.before_tool_call(tool_call(name: 'read'), {})

    assert_equal :pending, result[:action]
  end

  def test_session_or_project_grant_composition_either_bypasses
    session_grants = Ask::Permissions::SessionPermissionGrants.new
    session_grants.grant('bash')
    policy = build_policy(require_approval: :all, session_grants: session_grants,
      project_grants: FakeProjectGrants.new(['deploy']))

    assert_equal({ action: :proceed }, policy.before_tool_call(tool_call(name: 'bash'), {}))
    assert_equal({ action: :proceed }, policy.before_tool_call(tool_call(name: 'deploy'), {}))
    assert_empty @queue.submissions
  end

  def test_neither_grant_still_queues
    session_grants = Ask::Permissions::SessionPermissionGrants.new
    policy = build_policy(require_approval: :all, session_grants: session_grants,
      project_grants: FakeProjectGrants.new([]))

    result = policy.before_tool_call(tool_call(name: 'bash'), {})

    assert_equal :pending, result[:action]
    assert_equal 1, @queue.submissions.size
  end

  def test_session_grants_stay_isolated_from_project_grants
    session_grants = Ask::Permissions::SessionPermissionGrants.new
    session_grants.grant('bash')
    project_grants = FakeProjectGrants.new(['deploy'])
    policy = build_policy(require_approval: :all, session_grants: session_grants, project_grants: project_grants)

    assert session_grants.granted?('bash')
    refute session_grants.granted?('deploy')
    assert project_grants.granted?('deploy')
    refute project_grants.granted?('bash')

    assert_equal :pending, policy.before_tool_call(tool_call(name: 'other'), {})[:action]
  end

  def test_project_grant_cannot_bypass_explicit_deny
    project_grants = FakeProjectGrants.new(['delete_user'])
    rules = Ask::Permissions::PermissionRules.new { deny 'delete_user' }
    policy = build_policy(rules: rules, project_grants: project_grants)

    result = policy.before_tool_call(tool_call(name: 'delete_user'), {})

    assert_equal :block, result[:action]
    assert_equal "Denied by permission rules: 'delete_user'", result[:reason]
    assert_empty @queue.submissions
  end

  def test_project_grant_cannot_bypass_always_ask
    tool = CapabilityTool.new(name: 'bash', always_ask: true, side_effect_scope: :none)
    project_grants = FakeProjectGrants.new(['bash'])
    policy = build_policy(tools: { 'bash' => tool }, project_grants: project_grants)

    result = policy.before_tool_call(tool_call(name: 'bash'), {})

    assert_equal :pending, result[:action]
    assert_equal 1, @queue.submissions.size
  end

  def test_project_grant_cannot_bypass_read_only
    tool = CapabilityTool.new(name: 'write_file', side_effect_scope: :workspace)
    project_grants = FakeProjectGrants.new(['write_file'])
    policy = build_policy(mode: :read_only, tools: { 'write_file' => tool }, project_grants: project_grants)

    result = policy.before_tool_call(tool_call(name: 'write_file'), {})

    assert_equal :block, result[:action]
    assert_empty @queue.submissions
  end
end
