# frozen_string_literal: true

require_relative 'test_helper'
require 'json'

class PermissionRuleSetTest < Minitest::Test
  def test_classify_returns_nil_when_no_layers
    set = Ask::Permissions::PermissionRuleSet.new

    assert_nil set.classify('read_file')
  end

  def test_classify_uses_default_rules_when_no_project_rules
    default = Ask::Permissions::PermissionRules.new { allow 'read_file' }
    set = Ask::Permissions::PermissionRuleSet.new(default_rules: default)

    assert_equal :allow, set.classify('read_file')
    assert_nil set.classify('write_file')
  end

  def test_classify_uses_project_rules_when_no_default_rules
    project = Ask::Permissions::PermissionRules.new { deny 'delete_user' }
    set = Ask::Permissions::PermissionRuleSet.new(project_rules: project)

    assert_equal :deny, set.classify('delete_user')
    assert_nil set.classify('read_file')
  end

  def test_project_rules_take_precedence_over_default_for_same_decision
    default = Ask::Permissions::PermissionRules.new { allow 'read_file' }
    project = Ask::Permissions::PermissionRules.new { ask 'bash' }
    set = Ask::Permissions::PermissionRuleSet.new(default_rules: default, project_rules: project)

    assert_equal :ask, set.classify('bash')
  end

  def test_project_rules_win_when_both_match_non_deny
    default = Ask::Permissions::PermissionRules.new { allow 'bash' }
    project = Ask::Permissions::PermissionRules.new { ask 'bash' }
    set = Ask::Permissions::PermissionRuleSet.new(default_rules: default, project_rules: project)

    assert_equal :ask, set.classify('bash')
  end

  def test_default_wins_when_project_returns_nil
    default = Ask::Permissions::PermissionRules.new { allow 'read_file' }
    set = Ask::Permissions::PermissionRuleSet.new(default_rules: default, project_rules: nil)

    assert_equal :allow, set.classify('read_file')
  end

  def test_deny_from_default_always_wins
    default = Ask::Permissions::PermissionRules.new { deny 'bash' }
    project = Ask::Permissions::PermissionRules.new { allow 'bash' }
    set = Ask::Permissions::PermissionRuleSet.new(default_rules: default, project_rules: project)

    assert_equal :deny, set.classify('bash')
  end

  def test_deny_from_project_always_wins
    default = Ask::Permissions::PermissionRules.new { allow 'bash' }
    project = Ask::Permissions::PermissionRules.new { deny 'bash' }
    set = Ask::Permissions::PermissionRuleSet.new(default_rules: default, project_rules: project)

    assert_equal :deny, set.classify('bash')
  end

  def test_deny_from_either_layer_wins_over_allow
    default = Ask::Permissions::PermissionRules.new { deny 'bash' }
    project = Ask::Permissions::PermissionRules.new { deny 'bash' }
    set = Ask::Permissions::PermissionRuleSet.new(default_rules: default, project_rules: project)

    assert_equal :deny, set.classify('bash')
  end

  def test_project_result_wins_over_default_when_neither_is_deny
    default = Ask::Permissions::PermissionRules.new { allow 'bash' }
    project = Ask::Permissions::PermissionRules.new { ask 'bash' }
    set = Ask::Permissions::PermissionRuleSet.new(default_rules: default, project_rules: project)

    assert_equal :ask, set.classify('bash')
  end

  def test_project_ask_overrides_default_allow
    default = Ask::Permissions::PermissionRules.new { allow 'bash' }
    project = Ask::Permissions::PermissionRules.new { ask 'bash' }
    set = Ask::Permissions::PermissionRuleSet.new(default_rules: default, project_rules: project)

    assert_equal :ask, set.classify('bash')
  end

  def test_passes_args_through_to_both_layers
    default = Ask::Permissions::PermissionRules.new { allow 'bash', 'ls' }
    project = Ask::Permissions::PermissionRules.new { deny 'bash', 'rm' }
    set = Ask::Permissions::PermissionRuleSet.new(default_rules: default, project_rules: project)

    assert_equal :allow, set.classify('bash', { 'command' => 'ls -la' })
    assert_equal :deny, set.classify('bash', { 'command' => 'rm -rf /' })
  end

  def test_snapshot_returns_version_and_layer_snapshots
    default = Ask::Permissions::PermissionRules.new { allow 'read_file' }
    project = Ask::Permissions::PermissionRules.new { deny 'write_file' }
    set = Ask::Permissions::PermissionRuleSet.new(default_rules: default, project_rules: project)

    snapshot = set.snapshot

    assert_equal 1, snapshot[:version]
    assert_kind_of Hash, snapshot[:default_rules]
    assert_kind_of Hash, snapshot[:project_rules]
    assert_equal 1, snapshot[:default_rules][:version]
    assert_equal 1, snapshot[:project_rules][:version]
  end

  def test_snapshot_with_nil_layers
    set = Ask::Permissions::PermissionRuleSet.new

    snapshot = set.snapshot

    assert_nil snapshot[:default_rules]
    assert_nil snapshot[:project_rules]
  end

  def test_from_snapshot_restores_rule_set
    default = Ask::Permissions::PermissionRules.new { allow 'read_file' }
    project = Ask::Permissions::PermissionRules.new { deny 'write_file' }
    original = Ask::Permissions::PermissionRuleSet.new(default_rules: default, project_rules: project)

    restored = Ask::Permissions::PermissionRuleSet.from_snapshot(original.snapshot)

    assert_equal :allow, restored.classify('read_file')
    assert_equal :deny, restored.classify('write_file')
    assert_nil restored.classify('unknown')
  end

  def test_from_snapshot_restores_nil_layers
    original = Ask::Permissions::PermissionRuleSet.new

    restored = Ask::Permissions::PermissionRuleSet.from_snapshot(original.snapshot)

    assert_nil restored.classify('anything')
  end

  def test_from_snapshot_restores_only_default_layer
    default = Ask::Permissions::PermissionRules.new { allow 'read_file' }
    original = Ask::Permissions::PermissionRuleSet.new(default_rules: default)

    restored = Ask::Permissions::PermissionRuleSet.from_snapshot(original.snapshot)

    assert_equal :allow, restored.classify('read_file')
    assert_instance_of Ask::Permissions::PermissionRules, restored.default_rules
    assert_nil restored.project_rules
  end

  def test_snapshot_round_trip_preserves_precedence_through_json
    default = Ask::Permissions::PermissionRules.new { allow 'bash' }
    project = Ask::Permissions::PermissionRules.new { deny 'bash' }
    original = Ask::Permissions::PermissionRuleSet.new(default_rules: default, project_rules: project)

    json = JSON.generate(original.snapshot)
    restored = Ask::Permissions::PermissionRuleSet.from_snapshot(JSON.parse(json))

    assert_equal :deny, restored.classify('bash')
  end

  def test_snapshot_round_trip_preserves_project_over_default
    default = Ask::Permissions::PermissionRules.new { allow 'bash' }
    project = Ask::Permissions::PermissionRules.new { ask 'bash' }
    original = Ask::Permissions::PermissionRuleSet.new(default_rules: default, project_rules: project)

    json = JSON.generate(original.snapshot)
    restored = Ask::Permissions::PermissionRuleSet.from_snapshot(JSON.parse(json))

    assert_equal :ask, restored.classify('bash')
  end

  def test_from_snapshot_rejects_non_hash
    assert_raises(ArgumentError) { Ask::Permissions::PermissionRuleSet.from_snapshot('not a hash') }
  end

  def test_from_snapshot_rejects_wrong_version
    snapshot = { version: 999, default_rules: nil, project_rules: nil }

    assert_raises(ArgumentError) { Ask::Permissions::PermissionRuleSet.from_snapshot(snapshot) }
  end

  def test_from_snapshot_rejects_unknown_fields
    snapshot = { version: 1, default_rules: nil, project_rules: nil, extra: true }

    assert_raises(ArgumentError) { Ask::Permissions::PermissionRuleSet.from_snapshot(snapshot) }
  end

  def test_from_snapshot_rejects_invalid_default_rules
    snapshot = {
      version: 1,
      default_rules: { version: 1, auto_allow_dangerous: false, rules: 'not an array' },
      project_rules: nil
    }

    assert_raises(ArgumentError) { Ask::Permissions::PermissionRuleSet.from_snapshot(snapshot) }
  end

  def test_from_snapshot_rejects_invalid_project_rules
    snapshot = {
      version: 1,
      default_rules: nil,
      project_rules: { version: 999, auto_allow_dangerous: false, rules: [] }
    }

    assert_raises(ArgumentError) { Ask::Permissions::PermissionRuleSet.from_snapshot(snapshot) }
  end

  def test_initialize_rejects_non_classifying_collaborator
    assert_raises(ArgumentError) {
      Ask::Permissions::PermissionRuleSet.new(default_rules: 'not rules')
    }
  end

  def test_initialize_rejects_non_classifying_project_rules
    assert_raises(ArgumentError) {
      Ask::Permissions::PermissionRuleSet.new(project_rules: 'not rules')
    }
  end

  def test_readers_expose_layers
    default = Ask::Permissions::PermissionRules.new { allow 'bash' }
    project = Ask::Permissions::PermissionRules.new { deny 'bash' }
    set = Ask::Permissions::PermissionRuleSet.new(default_rules: default, project_rules: project)

    assert_same default, set.default_rules
    assert_same project, set.project_rules
  end
end
