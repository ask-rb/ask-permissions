# frozen_string_literal: true

require_relative 'test_helper'
require 'json'

class PermissionRulesSnapshotTest < Minitest::Test
  def test_snapshot_returns_version_and_entries
    rules = Ask::Permissions::PermissionRules.new
    rules.allow 'read_file'
    rules.deny 'delete_user'

    snapshot = rules.snapshot

    assert_equal 1, snapshot[:version]
    assert_equal false, snapshot[:auto_allow_dangerous]
    assert_kind_of Array, snapshot[:rules]
    assert_equal 2, snapshot[:rules].size
  end

  def test_snapshot_serializes_string_tool_pattern
    rules = Ask::Permissions::PermissionRules.new
    rules.allow 'read_file'

    entry = rules.snapshot[:rules].first

    assert_equal 'allow', entry[:decision]
    assert_equal({ type: 'string', value: 'read_file' }, entry[:tool_pattern])
    assert_nil entry[:argument_pattern]
  end

  def test_snapshot_serializes_regexp_tool_pattern
    rules = Ask::Permissions::PermissionRules.new
    rules.deny(/\Awrite_/)

    entry = rules.snapshot[:rules].first

    assert_equal 'deny', entry[:decision]
    assert_equal({ type: 'regexp', source: '\\Awrite_', flags: '' }, entry[:tool_pattern])
  end

  def test_snapshot_serializes_regexp_with_flags
    rules = Ask::Permissions::PermissionRules.new
    rules.allow 'bash', /rm\s+-rf/i

    entry = rules.snapshot[:rules].first

    assert_equal 'allow', entry[:decision]
    assert_equal({ type: 'regexp', source: 'rm\\s+-rf', flags: 'i' }, entry[:argument_pattern])
  end

  def test_snapshot_serializes_all_tool_pattern
    rules = Ask::Permissions::PermissionRules.new
    rules.deny :all

    entry = rules.snapshot[:rules].first

    assert_equal({ type: 'all' }, entry[:tool_pattern])
  end

  def test_snapshot_preserves_symbol_pattern_type
    rules = Ask::Permissions::PermissionRules.new
    rules.allow :read_file

    assert_equal({ type: 'symbol', value: 'read_file' }, rules.snapshot[:rules].first[:tool_pattern])
  end

  def test_snapshot_rejects_unsupported_pattern_types
    rules = Ask::Permissions::PermissionRules.new
    rules.allow(Object.new)

    assert_raises(ArgumentError) { rules.snapshot }
  end

  def test_snapshot_rejects_regexp_options_it_cannot_preserve
    rules = Ask::Permissions::PermissionRules.new
    rules.deny('read', Regexp.new('.', Regexp::NOENCODING))

    assert_raises(ArgumentError) { rules.snapshot }
  end

  def test_snapshot_serializes_string_argument_pattern
    rules = Ask::Permissions::PermissionRules.new
    rules.ask 'bash', 'rm -rf'

    entry = rules.snapshot[:rules].first

    assert_equal({ type: 'string', value: 'rm -rf' }, entry[:argument_pattern])
  end

  def test_from_snapshot_restores_rules
    snapshot = {
      version: 1,
      auto_allow_dangerous: false,
      rules: [
        { decision: 'allow', tool_pattern: { type: 'string', value: 'read_file' }, argument_pattern: nil },
        { decision: 'deny', tool_pattern: { type: 'string', value: 'delete_user' }, argument_pattern: nil }
      ]
    }

    restored = Ask::Permissions::PermissionRules.from_snapshot(snapshot)

    assert_equal :allow, restored.classify('read_file')
    assert_equal :deny, restored.classify('delete_user')
    assert_nil restored.classify('unknown')
  end

  def test_from_snapshot_restores_regexp_patterns
    snapshot = {
      version: 1,
      auto_allow_dangerous: false,
      rules: [
        { decision: 'deny', tool_pattern: { type: 'regexp', source: '\\Awrite_', flags: '' }, argument_pattern: nil }
      ]
    }

    restored = Ask::Permissions::PermissionRules.from_snapshot(snapshot)

    assert_equal :deny, restored.classify('write_file')
    assert_nil restored.classify('read_file')
  end

  def test_from_snapshot_restores_all_pattern
    snapshot = {
      version: 1,
      auto_allow_dangerous: false,
      rules: [
        { decision: 'deny', tool_pattern: { type: 'all' }, argument_pattern: nil }
      ]
    }

    restored = Ask::Permissions::PermissionRules.from_snapshot(snapshot)

    assert_equal :deny, restored.classify('literally_anything')
  end

  def test_from_snapshot_restores_symbol_pattern_type
    snapshot = {
      version: 1,
      auto_allow_dangerous: false,
      rules: [{ decision: 'allow', tool_pattern: { type: 'symbol', value: 'read_file' } }]
    }

    assert_equal :allow, Ask::Permissions::PermissionRules.from_snapshot(snapshot).classify('read_file')
    assert_equal :read_file, Ask::Permissions::PermissionRules.from_snapshot(snapshot).rules.first.tool_pattern
  end

  def test_from_snapshot_restores_argument_patterns
    snapshot = {
      version: 1,
      auto_allow_dangerous: false,
      rules: [
        {
          decision: 'ask',
          tool_pattern: { type: 'string', value: 'bash' },
          argument_pattern: { type: 'regexp', source: 'rm', flags: '' }
        }
      ]
    }

    restored = Ask::Permissions::PermissionRules.from_snapshot(snapshot)

    assert_equal :ask, restored.classify('bash', { 'command' => 'rm -rf /' })
    assert_nil restored.classify('bash', { 'command' => 'ls -la' })
  end

  def test_from_snapshot_restores_auto_allow_dangerous
    snapshot = {
      version: 1,
      auto_allow_dangerous: true,
      rules: [
        { decision: 'allow', tool_pattern: { type: 'string', value: 'bash' }, argument_pattern: nil }
      ]
    }

    restored = Ask::Permissions::PermissionRules.from_snapshot(snapshot)

    assert_equal :allow, restored.classify('bash')
  end

  def test_from_snapshot_preserves_declaration_order
    snapshot = {
      version: 1,
      auto_allow_dangerous: false,
      rules: [
        { decision: 'allow', tool_pattern: { type: 'string', value: 'a' }, argument_pattern: nil },
        { decision: 'deny', tool_pattern: { type: 'string', value: 'b' }, argument_pattern: nil },
        { decision: 'ask', tool_pattern: { type: 'string', value: 'c' }, argument_pattern: nil }
      ]
    }

    restored = Ask::Permissions::PermissionRules.from_snapshot(snapshot)

    assert_equal %i[allow deny ask], restored.rules.map(&:decision)
  end

  def test_snapshot_round_trip_preserves_rules_through_json
    original = Ask::Permissions::PermissionRules.new(auto_allow_dangerous: true)
    original.allow 'read_file'
    original.deny 'write_file'
    original.ask 'bash', 'rm -rf'
    original.allow(/^r/)

    json = JSON.generate(original.snapshot)
    restored = Ask::Permissions::PermissionRules.from_snapshot(JSON.parse(json))

    assert_equal original.classify('read_file'), restored.classify('read_file')
    assert_equal original.classify('write_file'), restored.classify('write_file')
    assert_equal original.classify('bash', { 'command' => 'rm -rf /' }), restored.classify('bash', { 'command' => 'rm -rf /' })
    assert_equal original.classify('repl'), restored.classify('repl')
  end

  def test_from_snapshot_rejects_non_hash
    assert_raises(ArgumentError) { Ask::Permissions::PermissionRules.from_snapshot('not a hash') }
  end

  def test_from_snapshot_rejects_wrong_version
    snapshot = { version: 999, auto_allow_dangerous: false, rules: [] }

    assert_raises(ArgumentError) { Ask::Permissions::PermissionRules.from_snapshot(snapshot) }
  end

  def test_from_snapshot_rejects_non_array_rules
    snapshot = { version: 1, auto_allow_dangerous: false, rules: 'not an array' }

    assert_raises(ArgumentError) { Ask::Permissions::PermissionRules.from_snapshot(snapshot) }
  end

  def test_from_snapshot_rejects_non_hash_entry
    snapshot = { version: 1, auto_allow_dangerous: false, rules: ['not a hash'] }

    assert_raises(ArgumentError) { Ask::Permissions::PermissionRules.from_snapshot(snapshot) }
  end

  def test_from_snapshot_rejects_invalid_decision
    snapshot = { version: 1, auto_allow_dangerous: false, rules: [
      { decision: 'invalid', tool_pattern: { type: 'string', value: 'bash' }, argument_pattern: nil }
    ] }

    assert_raises(ArgumentError) { Ask::Permissions::PermissionRules.from_snapshot(snapshot) }
  end

  def test_from_snapshot_rejects_invalid_pattern_type
    snapshot = { version: 1, auto_allow_dangerous: false, rules: [
      { decision: 'allow', tool_pattern: { type: 'invalid' }, argument_pattern: nil }
    ] }

    assert_raises(ArgumentError) { Ask::Permissions::PermissionRules.from_snapshot(snapshot) }
  end

  def test_from_snapshot_rejects_missing_decision
    snapshot = { version: 1, auto_allow_dangerous: false, rules: [
      { tool_pattern: { type: 'string', value: 'bash' }, argument_pattern: nil }
    ] }

    assert_raises(ArgumentError) { Ask::Permissions::PermissionRules.from_snapshot(snapshot) }
  end

  def test_from_snapshot_rejects_missing_tool_pattern
    snapshot = { version: 1, auto_allow_dangerous: false, rules: [
      { decision: 'allow', argument_pattern: nil }
    ] }

    assert_raises(ArgumentError) { Ask::Permissions::PermissionRules.from_snapshot(snapshot) }
  end

  def test_from_snapshot_rejects_non_string_decision
    snapshot = { version: 1, auto_allow_dangerous: false, rules: [
      { decision: 123, tool_pattern: { type: 'string', value: 'bash' }, argument_pattern: nil }
    ] }

    assert_raises(ArgumentError) { Ask::Permissions::PermissionRules.from_snapshot(snapshot) }
  end

  def test_from_snapshot_rejects_symbol_decision
    snapshot = {
      version: 1,
      auto_allow_dangerous: false,
      rules: [{ decision: :deny, tool_pattern: { type: 'string', value: 'bash' } }]
    }

    assert_raises(ArgumentError) { Ask::Permissions::PermissionRules.from_snapshot(snapshot) }
  end

  def test_from_snapshot_rejects_unknown_regexp_flags
    snapshot = {
      version: 1,
      auto_allow_dangerous: false,
      rules: [{ decision: 'deny', tool_pattern: { type: 'regexp', source: 'bash', flags: 'z' } }]
    }

    assert_raises(ArgumentError) { Ask::Permissions::PermissionRules.from_snapshot(snapshot) }
  end

  def test_from_snapshot_rejects_unknown_rule_fields
    snapshot = {
      version: 1,
      auto_allow_dangerous: false,
      rules: [],
      unexpected: true
    }

    assert_raises(ArgumentError) { Ask::Permissions::PermissionRules.from_snapshot(snapshot) }
  end

  def test_from_snapshot_rejects_pattern_fields_for_another_pattern_type
    snapshot = {
      version: 1,
      auto_allow_dangerous: false,
      rules: [{ decision: 'deny', tool_pattern: { type: 'all', value: 'ignored' } }]
    }

    assert_raises(ArgumentError) { Ask::Permissions::PermissionRules.from_snapshot(snapshot) }
  end

  def test_from_snapshot_rejects_non_boolean_auto_allow_dangerous
    snapshot = { version: 1, auto_allow_dangerous: 'yes', rules: [] }

    assert_raises(ArgumentError) { Ask::Permissions::PermissionRules.from_snapshot(snapshot) }
  end

  def test_from_snapshot_rejects_non_hash_tool_pattern
    snapshot = { version: 1, auto_allow_dangerous: false, rules: [
      { decision: 'allow', tool_pattern: 'not a hash', argument_pattern: nil }
    ] }

    assert_raises(ArgumentError) { Ask::Permissions::PermissionRules.from_snapshot(snapshot) }
  end

  def test_from_snapshot_rejects_missing_version
    snapshot = { auto_allow_dangerous: false, rules: [] }

    assert_raises(ArgumentError) { Ask::Permissions::PermissionRules.from_snapshot(snapshot) }
  end

  def test_from_snapshot_rejects_missing_rules_key
    snapshot = { version: 1, auto_allow_dangerous: false }

    assert_raises(ArgumentError) { Ask::Permissions::PermissionRules.from_snapshot(snapshot) }
  end

  def test_snapshot_returns_string_keys_for_json_compatibility
    rules = Ask::Permissions::PermissionRules.new
    rules.allow 'read_file'

    json = JSON.generate(rules.snapshot)
    parsed = JSON.parse(json)

    assert_equal 1, parsed['version']
    assert_equal false, parsed['auto_allow_dangerous']
    assert_kind_of Array, parsed['rules']
  end
end
