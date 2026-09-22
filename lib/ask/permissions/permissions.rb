# frozen_string_literal: true

module Ask
  module Permissions
    class Permissions
      DEFAULT_MODE = :ask_before_changes
      DEFAULT_BLOCKED_TOOLS = %w[write edit bash destroy].freeze
      MODE_BLOCKED_TOOLS = {
        full_access: [].freeze,
        ask_before_changes: DEFAULT_BLOCKED_TOOLS,
        read_only: DEFAULT_BLOCKED_TOOLS
      }.freeze

      Approval = Data.define(
        :tool_call_id, :tool_name, :arguments, :reason, :status, :submitted_at, :approved_at
      ) do
        def pending?
          status == :pending
        end

        def approved?
          status == :approved
        end
      end

      attr_reader :mode, :blocked_tools, :timeout

      def initialize(mode: nil, blocked_tools: nil, timeout: nil, clock: nil)
        @mode = mode.nil? ? DEFAULT_MODE : mode
        unless MODE_BLOCKED_TOOLS.key?(@mode)
          raise ArgumentError, "unknown mode: #{mode.inspect} (valid modes: #{MODE_BLOCKED_TOOLS.keys.join(', ')})"
        end

        @blocked_tools = (MODE_BLOCKED_TOOLS.fetch(@mode) + Array(blocked_tools).map(&:to_s)).uniq
        @timeout = timeout
        @clock = clock || -> { Time.now }
        @approvals = {}
        @mutex = Mutex.new
      end

      def before_tool_call(tool_call, _context = nil)
        name = tool_call.name.to_s
        return { action: :proceed } unless blocked_tools.include?(name)

        id = tool_call.id

        @mutex.synchronize do
          entry = @approvals[id]

          if entry&.approved?
            return { action: :proceed } unless expired?(entry)

            entry = entry.with(status: :pending, submitted_at: @clock.call, approved_at: nil)
            @approvals[id] = entry
          elsif entry
            return { action: :block, reason: entry.reason }
          else
            entry = Approval.new(
              tool_call_id: id,
              tool_name: name,
              arguments: tool_call.arguments,
              reason: reason_for(name),
              status: :pending,
              submitted_at: @clock.call,
              approved_at: nil
            )
            @approvals[id] = entry
          end

          { action: :block, reason: entry.reason }
        end
      end

      def approve(tool_call_id)
        @mutex.synchronize do
          entry = @approvals[tool_call_id]
          raise UnknownApprovalError, "unknown pending approval: #{tool_call_id.inspect}" unless entry&.pending?

          approved = entry.with(status: :approved, approved_at: @clock.call)
          @approvals[tool_call_id] = approved
          approved
        end
      end

      def pending_approvals
        @mutex.synchronize { @approvals.values.select(&:pending?) }
      end

      private

      def reason_for(tool_name)
        "#{tool_name} requires approval (mode: #{mode})"
      end

      def expired?(entry)
        return false if timeout.nil? || entry.approved_at.nil?

        (@clock.call - entry.approved_at) >= timeout
      end
    end
  end
end
