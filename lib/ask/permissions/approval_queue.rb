# frozen_string_literal: true

require_relative 'errors'

module Ask
  module Permissions
    # Stores pending approval actions, auto-approves eligible work in order, and fires one-argument callbacks.
    class ApprovalQueue
      RESOLUTION_SCOPES = %i[once session project].freeze

      Action = Data.define(
        :id, :tool_call_id, :tool_name, :args, :auto_approvable, :status, :submitted_at, :message,
        :resolution_scope, :feedback
      ) do
        def auto_approvable?
          !!auto_approvable
        end

        def pending?
          status == :pending
        end

        def applying?
          status == :applying
        end

        def approved?
          status == :approved
        end

        def rejected?
          status == :rejected
        end

        # Alias for hosts that think in terms of approval scope.
        def scope
          resolution_scope
        end
      end

      attr_reader :auto_approve
      attr_accessor :on_approve, :on_reject, :on_submit

      def initialize(on_approve: nil, on_reject: nil, auto_approve: {}, on_submit: nil, clock: nil)
        @on_approve = on_approve
        @on_reject = on_reject
        @auto_approve = auto_approve || {}
        @on_submit = on_submit
        @clock = clock || -> { Time.now }
        @actions = {}
        @next_id = 0
        @mutex = Mutex.new
        @draining = false
      end

      def submit(tool_call_id:, tool_name:, args: {}, auto_approvable: false, message: nil)
        action = @mutex.synchronize do
          @next_id += 1
          created = Action.new(
            id: @next_id,
            tool_call_id: tool_call_id,
            tool_name: tool_name.to_s,
            args: args.nil? ? {} : args,
            auto_approvable: auto_approvable ? true : false,
            status: :pending,
            submitted_at: @clock.call,
            message: message,
            resolution_scope: nil,
            feedback: nil
          )
          @actions[created.id] = created
          created
        end

        @on_submit&.call(action)

        drain

        action.id
      end

      def pending_actions
        @mutex.synchronize { @actions.values.select(&:pending?) }
      end

      # A JSON-safe snapshot of pending approvals for a durable session store.
      # Resolved actions are deliberately omitted so a restored approval can
      # never execute twice after a restart.
      def snapshot
        @mutex.synchronize do
          {
            version: 1,
            next_id: @next_id,
            pending_actions: @actions.values.select(&:pending?).map do |action|
              {
                id: action.id,
                tool_call_id: action.tool_call_id,
                tool_name: action.tool_name,
                args: action.args,
                auto_approvable: action.auto_approvable?,
                message: action.message
              }
            end
          }
        end
      end

      # Reconstitutes pending actions without emitting new submission events
      # or draining auto-approvals. The host owns replaying its durable event
      # log; this restores only the actionable queue state.
      def restore_pending(snapshot)
        version = snapshot_value(snapshot, :version)
        raise ArgumentError, "Unsupported approval snapshot version: #{version.inspect}" unless version == 1

        entries = snapshot_value(snapshot, :pending_actions)
        raise ArgumentError, "Approval snapshot pending_actions must be an Array" unless entries.is_a?(Array)

        restored = entries.map do |entry|
          id = snapshot_value(entry, :id)
          tool_name = snapshot_value(entry, :tool_name)
          raise ArgumentError, "Approval snapshot action id must be a positive Integer" unless id.is_a?(Integer) && id.positive?
          raise ArgumentError, "Approval snapshot tool_name must be a String" unless tool_name.is_a?(String)

          Action.new(
            id: id,
            tool_call_id: snapshot_value(entry, :tool_call_id),
            tool_name: tool_name,
            args: snapshot_value(entry, :args) || {},
            auto_approvable: snapshot_value(entry, :auto_approvable) == true,
            status: :pending,
            submitted_at: @clock.call,
            message: snapshot_value(entry, :message),
            resolution_scope: nil,
            feedback: nil
          )
        end
        ids = restored.map(&:id)
        raise ArgumentError, "Approval snapshot contains duplicate action ids" unless ids.uniq == ids

        @mutex.synchronize do
          raise ArgumentError, "Cannot restore approvals into a non-empty queue" unless @actions.empty?

          restored.each { |action| @actions[action.id] = action }
          requested_next_id = snapshot_value(snapshot, :next_id)
          @next_id = [requested_next_id.to_i, ids.max.to_i].max
        end

        restored.size
      end

      def pending?(id)
        @mutex.synchronize { @actions[id]&.pending? || false }
      end

      def any_pending?
        @mutex.synchronize { @actions.each_value.any?(&:pending?) }
      end

      def [](id)
        @mutex.synchronize { @actions[id] }
      end

      def approve(*ids, scope: :once)
        validated = validate_resolution_scope!(scope)
        resolve_all(ids) { |action| apply(action, scope: validated) }
      end

      def reject(*ids, feedback: nil)
        resolve_all(ids) { |action| reject_action(action, feedback: feedback) }
      end

      def approve_all(scope: :once)
        approve(*pending_actions.map(&:id), scope: scope)
      end

      def reject_all(feedback: nil)
        reject(*pending_actions.map(&:id), feedback: feedback)
      end

      def drain
        return self unless start_draining

        begin
          while (head = next_auto_head)
            begin
              apply(head)
            rescue UnknownApprovalError
              next
            end
          end
        ensure
          stop_draining
        end

        self
      end

      private

      def snapshot_value(hash, key)
        raise ArgumentError, "Approval snapshot values must be Hashes" unless hash.is_a?(Hash)

        hash.key?(key) ? hash[key] : hash[key.to_s]
      end

      def apply(action, scope: :once)
        validated = validate_resolution_scope!(scope)
        resolve(action.id, @on_approve, :approved, resolution_scope: validated)
      end

      def reject_action(action, feedback: nil)
        resolve(action.id, @on_reject, :rejected, feedback: feedback)
      end

      def resolve_all(ids)
        actions = @mutex.synchronize do
          ids.flatten.uniq
             .filter_map { |id| @actions[id] }
             .select(&:pending?)
             .sort_by(&:id)
        end

        actions.filter_map do |action|
          yield action
        rescue UnknownApprovalError
          nil
        end
      end

      def validate_resolution_scope!(scope)
        normalized = scope.respond_to?(:to_sym) ? scope.to_sym : scope
        unless RESOLUTION_SCOPES.include?(normalized)
          raise ArgumentError, "Unknown resolution scope: #{scope.inspect}. Valid: #{RESOLUTION_SCOPES.join(', ')}"
        end

        normalized
      end

      def resolve(id, callback, status, resolution_scope: nil, feedback: nil)
        previous = nil
        applying = nil

        @mutex.synchronize do
          previous = @actions[id]
          raise UnknownApprovalError, "unknown pending approval: #{id.inspect}" unless previous&.pending?

          applying = previous.with(status: :applying, resolution_scope: resolution_scope, feedback: feedback)
          @actions[id] = applying
        end

        begin
          callback&.call(applying)
        rescue StandardError
          @mutex.synchronize { @actions[id] = previous }
          raise
        end

        resolved = applying.with(status: status)
        @mutex.synchronize { @actions[id] = resolved }
        resolved
      end

      def next_auto_head
        @mutex.synchronize do
          head = @actions.each_value.find(&:pending?)
          head if head&.auto_approvable? && @auto_approve[head.tool_name] == true
        end
      end

      def start_draining
        @mutex.synchronize do
          next false if @draining

          @draining = true
        end
      end

      def stop_draining
        @mutex.synchronize { @draining = false }
      end
    end
  end
end
