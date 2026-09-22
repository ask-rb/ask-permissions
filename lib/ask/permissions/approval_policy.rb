# frozen_string_literal: true

module Ask
  module Permissions
    # Hook adapter that consults rules, require_approval, and tool metadata, then enqueues through a queue.
    class ApprovalPolicy
      attr_reader :queue, :require_approval, :rules, :tools

      def initialize(queue:, require_approval: nil, rules: nil, tools: nil)
        @queue = queue
        @require_approval = require_approval
        @rules = rules
        @tools = tools
      end

      def before_tool_call(tool_call, _context = nil)
        name = tool_call.name.to_s
        args = tool_call.arguments

        case rules&.classify(name, args)
        when :deny
          return { action: :block, reason: "Denied by permission rules: '#{name}'" }
        when :allow
          return { action: :proceed }
        when :ask
          return enqueue(tool_call, auto_approvable: false)
        end

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
