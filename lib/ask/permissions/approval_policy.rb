# frozen_string_literal: true

module Ask
  module Permissions
    # Hook adapter that consults rules, require_approval, and tool metadata, then enqueues through a queue.
    class ApprovalPolicy
      MODES = %i[full_access ask_before_changes read_only].freeze
      SIDE_EFFECT_SCOPES = %i[none session workspace project system external unknown].freeze

      attr_reader :queue, :require_approval, :rules, :tools, :mode

      def initialize(queue:, require_approval: nil, rules: nil, tools: nil, mode: nil)
        raise ArgumentError, "Unknown permission mode: #{mode.inspect}" if mode && !MODES.include?(mode.to_sym)

        @queue = queue
        @require_approval = require_approval
        @rules = rules
        @tools = tools
        @mode = mode&.to_sym
      end

      def before_tool_call(tool_call, _context = nil)
        name = tool_call.name.to_s
        args = tool_call.arguments

        rule_decision = rules&.classify(name, args)
        case rule_decision
        when :deny
          return { action: :block, reason: "Denied by permission rules: '#{name}'" }
        when :ask
          return enqueue(tool_call, auto_approvable: false)
        end

        # A tool's explicit human-confirmation requirement is a hard safety
        # boundary: an ordinary allow rule must not be able to bypass it.
        if always_ask?(name)
          return enqueue(tool_call, auto_approvable: false)
        end

        if mode == :read_only && side_effect_scope(name) != :none
          return { action: :block, reason: "Read-only mode blocks tools with side effects (#{name})" }
        end

        return { action: :proceed } if rule_decision == :allow

        return { action: :proceed } if mode == :full_access

        if mode == :ask_before_changes && side_effect_scope(name) != :none
          return enqueue(tool_call, auto_approvable: false)
        end

        return enqueue(tool_call, auto_approvable: false) if elevated_risk?(name)

        return { action: :proceed } unless approval_required?(name)

        enqueue(tool_call, auto_approvable: auto_approvable?(name))
      end

      def lookup(action_id)
        queue[action_id]
      end

      private

      def approval_required?(name)
        return true if matches_require_approval?(require_approval, name)

        tool = find_tool(name)
        !!(tool && tool.respond_to?(:approval_required?) && tool.approval_required?)
      end

      def matches_require_approval?(criterion, name)
        case criterion
        when nil then false
        when :all then true
        when Array then criterion.any? { |entry| matches_require_approval?(entry, name) }
        when Regexp then criterion.match?(name)
        else criterion.to_s == name
        end
      end

      def auto_approvable?(name)
        tool = find_tool(name)
        !!(tool && tool.respond_to?(:auto_approvable?) && tool.auto_approvable?)
      end

      def always_ask?(name)
        tool = find_tool(name)
        !!(tool && tool.respond_to?(:always_ask?) && tool.always_ask?)
      end

      def elevated_risk?(name)
        tool = find_tool(name)
        risk = tool.risk_level if tool&.respond_to?(:risk_level)
        risk = risk.to_sym if risk.respond_to?(:to_sym)
        %i[high critical].include?(risk)
      end

      def side_effect_scope(name)
        tool = find_tool(name)
        scope = tool.side_effect_scope if tool&.respond_to?(:side_effect_scope)
        scope = scope.to_sym if scope.respond_to?(:to_sym)
        SIDE_EFFECT_SCOPES.include?(scope) ? scope : :unknown
      end

      def find_tool(name)
        case tools
        when nil then nil
        when Hash then tools[name] || tools[name.to_sym]
        when Array then tools.find { |tool| tool.respond_to?(:name) && tool.name.to_s == name }
        else tools.respond_to?(:[]) ? tools[name] : nil
        end
      end

      def enqueue(tool_call, auto_approvable:)
        name = tool_call.name.to_s
        reason = "Tool '#{name}' requires approval"
        message = "Calling \"#{name}\" requires approval"

        action_id = queue.submit(
          tool_name: name,
          args: tool_call.arguments,
          tool_call_id: tool_call.id,
          auto_approvable: auto_approvable,
          message: message
        )

        { action: :pending, action_id: action_id, reason: reason }
      end
    end
  end
end
