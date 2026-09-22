# frozen_string_literal: true

module Ask
  module Permissions
    # Mode gate that blocks change tools until approved, with sticky approvals per tool_call_id.
    class Permissions
      DEFAULT_TOOLS = %i[write edit bash destroy].freeze

      ACCESS_MODES = {
        full_access: { blocked_tools: [].freeze }.freeze,
        ask_before_changes: { blocked_tools: DEFAULT_TOOLS }.freeze,
        read_only: { blocked_tools: DEFAULT_TOOLS }.freeze
      }.freeze

      DEFAULT_BLOCKED_TOOLS = DEFAULT_TOOLS
      MODE_BLOCKED_TOOLS = ACCESS_MODES.transform_values { |config| config[:blocked_tools] }.freeze

      Approval = Data.define(
        :tool_call_id, :tool_name, :arguments, :reason, :status,
        :created_at, :approved_at, :tool_call
      ) do
        def pending?
          status == :pending
        end

        def approved?
          status == :approved
        end

        def [](key)
          to_h.fetch(key.to_sym)
        end
      end

      attr_reader :mode, :blocked_tools, :timeout

      def initialize(mode: nil, blocked_tools: nil, timeout: nil, clock: nil)
        @mode = mode
        @blocked_tools =
          if mode
            mode_tools(mode)
          elsif blocked_tools
            Array(blocked_tools).map { |name| name.to_s.to_sym }.uniq
          else
            DEFAULT_BLOCKED_TOOLS.dup
          end
        @timeout = timeout
        @clock = clock || -> { Time.now }
        @approvals = {}
        @mutex = Mutex.new
      end

      def before_tool_call(tool_call, _context = nil)
        name = tool_call.name.to_s.to_sym
        return { action: :proceed } unless blocked_tools.include?(name)

        id = tool_call.id
        created = false

        result = @mutex.synchronize do
          decision = existing_decision(id)
          if decision
            decision
          else
            created = true
            record_pending(tool_call, name)
          end
        end

        warn_approval(tool_call) if created
        result
      end

      def approve(tool_call_id)
        @mutex.synchronize do
          entry = @approvals[tool_call_id]
          next false unless entry

          @approvals[tool_call_id] = entry.with(status: :approved, approved_at: @clock.call)
          true
        end
      end

      def pending_approvals
        @mutex.synchronize { @approvals.values.select(&:pending?) }
      end

      private

      def approved?(tool_call)
        @mutex.synchronize do
          existing_decision(tool_call.id)&.dig(:action) == :proceed
        end
      end

      def mode_tools(mode)
        config = ACCESS_MODES.fetch(mode) do
          raise ArgumentError,
                "Unknown access mode: #{mode.inspect}. Valid: #{ACCESS_MODES.keys.join(', ')}"
        end
        config[:blocked_tools].dup
      end

      def reason_for(tool_name)
        return "#{tool_name} requires approval" if mode.nil?

        "#{tool_name} requires approval (mode: #{mode})"
      end

      def expired?(entry)
        return false if timeout.nil?

        (@clock.call - entry.created_at) > timeout
      end

      def existing_decision(id)
        entry = @approvals[id]

        if entry && expired?(entry)
          @approvals.delete(id)
          entry = nil
        end

        return nil unless entry
        return { action: :proceed } if entry.approved?

        { action: :block, reason: entry.reason }
      end

      def record_pending(tool_call, name)
        entry = Approval.new(
          tool_call_id: tool_call.id,
          tool_name: name,
          arguments: tool_call.arguments,
          reason: reason_for(name),
          status: :pending,
          created_at: @clock.call,
          approved_at: nil,
          tool_call: tool_call
        )
        @approvals[tool_call.id] = entry
        { action: :block, reason: entry.reason }
      end

      def warn_approval(tool_call)
        warn "[Permissions] Tool '#{tool_call.name}' requires approval. " \
             "Call approve('#{tool_call.id}') to allow."
      end
    end
  end
end
