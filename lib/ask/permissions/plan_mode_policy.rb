# frozen_string_literal: true

module Ask
  module Permissions
    # Blocks non-read-only tool calls while a session is preparing a plan.
    # Install this hook only while plan mode is active.
    class PlanModePolicy
      DEFAULT_EXIT_TOOL = 'exit_plan_mode'
      DEFAULT_REASON = 'Plan mode: only read-only tools until the plan is approved'

      def initialize(allowed_tools:, exit_tool: DEFAULT_EXIT_TOOL, reason: DEFAULT_REASON)
        @allowed_tools = Array(allowed_tools).map(&:to_s).freeze
        @exit_tool = exit_tool.to_s
        @reason = reason
      end

      def before_tool_call(tool_call, _context = nil)
        name = tool_call.name.to_s
        return { action: :proceed } if name == @exit_tool || @allowed_tools.include?(name)

        { action: :block, reason: @reason }
      end
    end
  end
end
