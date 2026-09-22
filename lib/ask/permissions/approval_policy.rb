# frozen_string_literal: true

module Ask
  module Permissions
    class ApprovalPolicy
      attr_reader :queue, :require_approval, :rules, :tools

      def initialize(queue:, require_approval: nil, rules: nil, tools: nil)
        @queue = queue
        @require_approval = require_approval
        @rules = rules
        @tools = tools
        @next_action_id = 0
        @action_index = {}
        @mutex = Mutex.new
      end

      def before_tool_call(tool_call, _context = nil)
        name = tool_call.name.to_s
        args = tool_call.arguments

        case rules&.classify(name, args)
        when :deny
          return { action: :block, reason: "permission rules denied #{name.inspect}" }
        when :allow
          return { action: :proceed }
        when :ask
          return enqueue(tool_call, auto_approvable: false)
        end

        return { action: :proceed } unless approval_required?(name)

        enqueue(tool_call, auto_approvable: auto_approvable?(name))
      end

      def lookup(action_id)
        @mutex.synchronize { @action_index[action_id] }
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
        reason = "approval required for #{name.inspect}"

        action = queue.submit(
          tool_name: name,
          args: tool_call.arguments,
          tool_call_id: tool_call.id,
          auto_approvable: auto_approvable,
          message: reason
        )

        action_id = @mutex.synchronize do
          @next_action_id += 1
          @action_index[@next_action_id] = action
          @next_action_id
        end

        { action: :pending, action_id: action_id, reason: reason }
      end
    end
  end
end
