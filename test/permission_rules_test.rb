# frozen_string_literal: true

require_relative 'test_helper'

class PermissionRulesTest < Minitest::Test
  def setup
    @rules = Ask::Permissions::PermissionRules.new
  end

  def test_allows_exact_tool_name
    @rules.allow 'read_file'

    assert_equal :allow, @rules.classify('read_file')
    assert_equal :allow, @rules.classify(:read_file)
  end

  def test_returns_nil_when_no_rule_matches
    assert_nil @rules.classify('write_file')
    assert_nil @rules.classify('write_file', { 'path' => 'a' })
  end

  def test_first_matching_rule_wins
    @rules.allow 'read_file'
    @rules.deny 'read_file'

    assert_equal :allow, @rules.classify('read_file')
  end

  def test_deny_regexp_tool_pattern
    @rules.deny(/\Awrite_/)

    assert_equal :deny, @rules.classify('write_file')
    assert_equal :deny, @rules.classify('write_blob')
    assert_nil @rules.classify('read_file')
  end

  def test_all_tool_pattern_matches_every_tool
    @rules.deny :all

    assert_equal :deny, @rules.classify('literally_anything')
  end

  def test_nil_argument_pattern_matches_any_arguments
    @rules.allow 'search'

    assert_equal :allow, @rules.classify('search')
    assert_equal :allow, @rules.classify('search', { 'query' => 'x' })
    assert_equal :allow, @rules.classify('search', nil)
  end

  def test_string_argument_pattern_matches_substring_of_serialized_args
    @rules.ask 'bash', 'rm -rf'

    assert_equal :ask, @rules.classify('bash', { 'command' => 'sudo rm -rf /tmp/x' })
    assert_nil @rules.classify('bash', { 'command' => 'ls -la' })
  end

  def test_regexp_argument_pattern_matches_serialized_hash_args
    @rules.allow 'read_file', %r{/etc/passwd}

    assert_equal :allow, @rules.classify('read_file', { 'path' => '/etc/passwd' })
    assert_nil @rules.classify('read_file', { 'path' => '/tmp/notes.txt' })
  end

  def test_hash_args_are_serialized_with_json_generate
    @rules.deny 'read_file', '"path":"/etc/passwd"'

    assert_equal :deny, @rules.classify('read_file', { 'path' => '/etc/passwd', 'mode' => 'r' })
    assert_nil @rules.classify('read_file', { 'path' => '/tmp/notes.txt' })
  end

  def test_non_hash_args_are_serialized_with_to_s
    @rules.ask 'search', 'needle'

    assert_equal :ask, @rules.classify('search', 'haystack needle stack')
    assert_nil @rules.classify('search', 'haystack')
  end

  def test_argument_rules_only_apply_to_their_tool
    @rules.ask 'bash', 'rm -rf'

    assert_nil @rules.classify('shell', { 'command' => 'rm -rf /' })
  end

  def test_unrestricted_allow_on_dangerous_tools_is_downgraded_to_ask
    %w[bash code repl].each do |tool|
      rules = Ask::Permissions::PermissionRules.new
      rules.allow tool

      assert_equal :ask, rules.classify(tool), "expected #{tool} allow to be downgraded"
      assert_equal :ask, rules.classify(tool, { 'anything' => 1 })
    end
  end

  def test_unrestricted_allow_on_all_is_downgraded_to_ask
    @rules.allow :all

    assert_equal :ask, @rules.classify('read_file')
    assert_equal :ask, @rules.classify('bash')
  end

  def test_restricted_allow_on_dangerous_tool_is_not_downgraded
    @rules.allow 'bash', 'ls -la'

    assert_equal :allow, @rules.classify('bash', { 'command' => 'ls -la' })
    assert_empty @rules.dangerous_rules
  end

  def test_deny_and_ask_on_dangerous_tools_are_not_flagged
    @rules.deny 'bash'
    @rules.ask 'repl'

    assert_empty @rules.dangerous_rules
    assert_equal :deny, @rules.classify('bash')
    assert_equal :ask, @rules.classify('repl')
  end

  def test_exposes_rules_and_dangerous_rules
    @rules.allow 'bash'
    @rules.allow 'read_file'
    @rules.deny 'write_file'

    assert_equal 3, @rules.rules.size
    assert_equal 1, @rules.dangerous_rules.size

    dangerous = @rules.dangerous_rules.first

    assert dangerous.dangerous
    assert_equal :allow, dangerous.declared_decision
    assert_equal :allow, dangerous.decision
    assert_equal :ask, dangerous.effective_decision
    assert_equal 'bash', dangerous.tool_pattern
    assert_nil dangerous.argument_pattern

    plain = @rules.rules.find { |rule| rule.tool_pattern == 'read_file' }

    refute_predicate plain, :dangerous
    assert_equal :allow, plain.decision
    assert_equal plain.declared_decision, plain.decision
  end

  def test_rules_are_exposed_in_declaration_order
    @rules.allow 'a'
    @rules.deny 'b'
    @rules.ask 'c'

    assert_equal %i[allow deny ask], @rules.rules.map(&:decision)
  end

  def test_auto_allow_dangerous_override_keeps_unrestricted_allows
    rules = Ask::Permissions::PermissionRules.new(auto_allow_dangerous: true)
    rules.allow 'bash'
    rules.allow :all

    assert_equal :allow, rules.classify('bash')
    assert_equal :allow, rules.classify('anything_else')
    assert_equal 2, rules.dangerous_rules.size
    assert(rules.dangerous_rules.all?(&:dangerous))
    assert(rules.dangerous_rules.none? { |rule| rule.declared_decision != rule.decision })
  end

  def test_predicates
    @rules.allow 'read_file'
    @rules.deny 'write_file'
    @rules.ask 'search', 'secret'

    assert @rules.allow?('read_file')
    assert @rules.deny?('write_file')
    assert @rules.ask?('search', 'secret-query')
    refute @rules.allow?('write_file')
    refute @rules.deny?('unknown')
  end

  def test_regexp_dangerous_tool_pattern_is_flagged
    @rules.allow(/^r/)

    assert_equal 1, @rules.dangerous_rules.size
    assert_equal :ask, @rules.classify('repl')
  end

  def test_regexp_tool_pattern_not_matching_dangerous_tools_is_safe
    @rules.allow(/\Aread_/)

    assert_empty @rules.dangerous_rules
    assert_equal :allow, @rules.classify('read_file')
  end

  def test_initialize_accepts_an_optional_block_evaluated_against_the_ruleset
    rules = Ask::Permissions::PermissionRules.new do
      allow 'read_file'
      deny 'delete_user'
      ask 'bash', 'rm -rf'
    end

    assert_equal :allow, rules.classify('read_file')
    assert_equal :deny, rules.classify('delete_user')
    assert_equal :ask, rules.classify('bash', { 'command' => 'rm -rf /' })
    assert_equal 3, rules.rules.size
  end

  def test_initialize_without_a_block_still_registers_rules_normally
    rules = Ask::Permissions::PermissionRules.new
    rules.allow 'read_file'

    assert_equal :allow, rules.classify('read_file')
  end

  def test_dangerous_tools_constant_is_a_frozen_symbol_list
    assert_equal %i[bash code repl], Ask::Permissions::PermissionRules::DANGEROUS_TOOLS
    assert_predicate Ask::Permissions::PermissionRules::DANGEROUS_TOOLS, :frozen?
  end

  def test_broad_dangerous_allow_keeps_decision_allow_but_classifies_as_ask
    @rules.allow 'bash'
    rule = @rules.rules.first

    assert_equal :allow, rule.declared_decision
    assert_equal :allow, rule.decision
    assert_equal :ask, rule.effective_decision
    assert_equal :ask, @rules.classify('bash')
  end

  def test_effective_decision_matches_decision_for_non_dangerous_rules
    @rules.allow 'read_file'
    @rules.deny 'write_file'
    @rules.ask 'search'

    @rules.rules.each do |rule|
      assert_equal rule.decision, rule.effective_decision
      assert_equal rule.decision, rule.declared_decision
    end
  end

  def test_auto_allow_dangerous_keeps_effective_decision_allow
    rules = Ask::Permissions::PermissionRules.new(auto_allow_dangerous: true)
    rules.allow 'bash'
    rule = rules.rules.first

    assert_equal :allow, rule.decision
    assert_equal :allow, rule.effective_decision
    assert_equal :allow, rules.classify('bash')
  end

  def test_rule_tool_matches_and_matches
    @rules.ask 'bash', 'rm -rf'
    rule = @rules.rules.first

    assert rule.tool_matches?('bash')
    assert rule.tool_matches?(:bash)
    refute rule.tool_matches?('sh')
    assert rule.matches?('bash', { 'command' => 'rm -rf /' })
    refute rule.matches?('sh', { 'command' => 'rm -rf /' })
    refute rule.matches?('bash', { 'command' => 'ls' })
  end

  def test_rule_argument_matches_with_nil_pattern_and_regexp_pattern
    unrestricted = Ask::Permissions::PermissionRules.new
    unrestricted.allow 'search'
    rule = unrestricted.rules.first

    assert_nil rule.argument_pattern
    assert rule.argument_matches?(nil)
    assert rule.argument_matches?({ 'q' => 'x' })
    assert rule.matches?('search', 'anything')

    regexp = Ask::Permissions::PermissionRules.new
    regexp.allow 'read_file', %r{/etc/passwd}
    regexp_rule = regexp.rules.first

    assert regexp_rule.argument_matches?({ 'path' => '/etc/passwd' })
    refute regexp_rule.argument_matches?({ 'path' => '/tmp/notes.txt' })
  end

  def test_rule_universal_predicate_is_true_only_when_argument_pattern_is_nil
    @rules.deny :all
    @rules.allow 'read_file'
    @rules.ask 'bash', 'rm -rf'
    @rules.deny :all, 'rm -rf'

    unrestricted_all, unrestricted_tool, restricted_tool, restricted_all = @rules.rules

    assert_predicate unrestricted_all, :universal?
    assert_predicate unrestricted_tool, :universal?
    refute_predicate restricted_tool, :universal?
    refute_predicate restricted_all, :universal?
    assert unrestricted_all.matches?('literally_anything', { 'a' => 1 })
  end
end
