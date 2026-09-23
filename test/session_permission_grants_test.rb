# frozen_string_literal: true

require_relative 'test_helper'
require 'json'

class SessionPermissionGrantsTest < Minitest::Test
  def build_grants(**kwargs)
    Ask::Permissions::SessionPermissionGrants.new(**kwargs)
  end

  def test_starts_empty
    grants = build_grants

    assert_predicate grants, :empty?
    assert_equal 0, grants.size
    assert_equal [], grants.granted_tools
    refute grants.granted?('bash')
  end

  def test_grant_normalizes_symbol_and_string_names
    grants = build_grants
    grants.grant(:bash)

    assert grants.granted?('bash')
    assert grants.granted?(:bash)
    assert_equal ['bash'], grants.granted_tools
  end

  def test_grant_rejects_blank_and_invalid_names
    grants = build_grants

    assert_raises(ArgumentError) { grants.grant(nil) }
    assert_raises(ArgumentError) { grants.grant('') }
    assert_raises(ArgumentError) { grants.grant(123) }
    assert_raises(ArgumentError) { grants.revoke(nil) }
    assert_raises(ArgumentError) { grants.revoke('') }
  end

  def test_granted_predicate_returns_false_for_invalid_names
    grants = build_grants

    refute grants.granted?(nil)
    refute grants.granted?('')
    refute grants.granted?(123)
  end

  def test_duplicate_grant_is_idempotent
    grants = build_grants
    grants.grant('bash')
    grants.grant(:bash)
    grants.grant('bash')

    assert grants.granted?('bash')
    assert_equal ['bash'], grants.granted_tools
    assert_equal 1, grants.size
  end

  def test_revoke_removes_grant
    grants = build_grants
    grants.grant('bash')
    grants.revoke(:bash)

    refute grants.granted?('bash')
    assert_predicate grants, :empty?
  end

  def test_revoke_unknown_tool_is_a_noop
    grants = build_grants
    grants.grant('bash')
    grants.revoke('read')

    assert grants.granted?('bash')
    refute grants.granted?('read')
    assert_equal ['bash'], grants.granted_tools
  end

  def test_revoke_after_re_grant_cycle
    grants = build_grants
    grants.grant('bash')
    grants.revoke('bash')
    refute grants.granted?('bash')
    grants.grant('bash')
    assert grants.granted?('bash')
  end

  def test_clear_empties_all_grants
    grants = build_grants
    grants.grant('bash')
    grants.grant('read')
    grants.clear

    assert_predicate grants, :empty?
    assert_equal [], grants.granted_tools
  end

  def test_snapshot_is_json_safe_and_versioned
    grants = build_grants
    grants.grant('bash')
    grants.grant(:read)

    snapshot = grants.snapshot

    assert_equal 1, snapshot[:version]
    assert_equal %w[bash read], snapshot[:granted_tools]
    # JSON round-trip must preserve everything restore needs.
    round_tripped = JSON.parse(JSON.generate(snapshot))

    restored = build_grants
    restored.restore_snapshot(round_tripped)

    assert restored.granted?('bash')
    assert restored.granted?('read')
    assert_equal %w[bash read], restored.granted_tools
  end

  def test_snapshot_round_trip_with_symbol_keys
    grants = build_grants
    grants.grant('bash')

    restored = Ask::Permissions::SessionPermissionGrants.from_snapshot(grants.snapshot)

    assert restored.granted?('bash')
    assert_equal ['bash'], restored.granted_tools
  end

  def test_restore_replaces_existing_grants
    grants = build_grants
    grants.grant('bash')

    grants.restore_snapshot({ version: 1, granted_tools: ['read'] })

    refute grants.granted?('bash')
    assert grants.granted?('read')
  end

  def test_restore_dedupes_snapshot_entries
    grants = build_grants
    grants.restore_snapshot({ version: 1, granted_tools: %w[bash bash] })

    assert_equal ['bash'], grants.granted_tools
  end

  def test_restore_rejects_invalid_snapshots
    grants = build_grants

    assert_raises(ArgumentError) { grants.restore_snapshot(nil) }
    assert_raises(ArgumentError) { grants.restore_snapshot({}) }
    assert_raises(ArgumentError) { grants.restore_snapshot({ version: 2, granted_tools: [] }) }
    assert_raises(ArgumentError) { grants.restore_snapshot({ version: 1 }) }
    assert_raises(ArgumentError) { grants.restore_snapshot({ version: 1, granted_tools: 'bash' }) }
    assert_raises(ArgumentError) { grants.restore_snapshot({ version: 1, granted_tools: [nil] }) }
    assert_raises(ArgumentError) { grants.restore_snapshot({ version: 1, granted_tools: [''] }) }
    assert_raises(ArgumentError) { grants.restore_snapshot({ version: 1, granted_tools: [123] }) }
  end

  def test_restore_failure_preserves_existing_grants
    grants = build_grants
    grants.grant('bash')

    assert_raises(ArgumentError) { grants.restore_snapshot({ version: 999, granted_tools: [] }) }

    assert grants.granted?('bash')
  end

  def test_thread_safety_under_concurrent_grants
    grants = build_grants
    threads = 10.times.map do |i|
      Thread.new do
        100.times do
          grants.grant("tool-#{i}")
          grants.granted?("tool-#{i}")
        end
      end
    end
    threads.each(&:join)

    assert_equal 10, grants.size
    10.times { |i| assert grants.granted?("tool-#{i}") }
  end
end
