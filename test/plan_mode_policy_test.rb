# frozen_string_literal: true

require_relative 'test_helper'

class PlanModePolicyTest < Minitest::Test
  ToolCall = Struct.new(:name, keyword_init: true)

  def test_allows_only_declared_read_only_tools_and_plan_exit
    policy = Ask::Permissions::PlanModePolicy.new(allowed_tools: %w[read_file search])

    assert_equal({ action: :proceed }, policy.before_tool_call(ToolCall.new(name: 'read_file')))
    assert_equal({ action: :proceed }, policy.before_tool_call(ToolCall.new(name: 'exit_plan_mode')))

    blocked = policy.before_tool_call(ToolCall.new(name: 'write_file'))
    assert_equal :block, blocked[:action]
    assert_match(/plan mode/i, blocked[:reason])
  end

  def test_custom_exit_tool_and_reason_are_supported
    policy = Ask::Permissions::PlanModePolicy.new(
      allowed_tools: ['inspect'],
      exit_tool: 'submit_plan',
      reason: 'Plan approval is required before execution'
    )

    assert_equal({ action: :proceed }, policy.before_tool_call(ToolCall.new(name: 'submit_plan')))
    assert_equal 'Plan approval is required before execution',
      policy.before_tool_call(ToolCall.new(name: 'write'))[:reason]
  end
end
