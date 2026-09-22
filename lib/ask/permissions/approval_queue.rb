# frozen_string_literal: true

require_relative 'errors'

module Ask
  module Permissions
    # Stores pending approval actions, auto-approves eligible work in order, and fires one-argument callbacks.
    class ApprovalQueue
      Action = Data.define(
        :id, :tool_call_id, :tool_name, :args, :auto_approvable, :status, :submitted_at, :message
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
            message: message
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

      def pending?(id)
        @mutex.synchronize { @actions[id]&.pending? || false }
      end

      def any_pending?
        @mutex.synchronize { @actions.each_value.any?(&:pending?) }
      end

      def [](id)
        @mutex.synchronize { @actions[id] }
      end

      def approve(*ids)
        resolve_all(ids, @on_approve, :approved)
      end

      def reject(*ids)
        resolve_all(ids, @on_reject, :rejected)
      end

      def approve_all
        approve(*pending_actions.map(&:id))
      end

      def reject_all
        reject(*pending_actions.map(&:id))
      end

      def drain
        return self unless start_draining

        begin
          while (head = next_auto_head)
            begin
              resolve(head.id, @on_approve, :approved)
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

      def resolve_all(ids, callback, status)
        actions = @mutex.synchronize do
          ids.flatten.uniq
             .filter_map { |id| @actions[id] }
             .select(&:pending?)
             .sort_by(&:id)
        end

        actions.filter_map do |action|
          resolve(action.id, callback, status)
        rescue UnknownApprovalError
          nil
        end
      end

      def resolve(id, callback, status)
        previous = nil
        applying = nil

        @mutex.synchronize do
          previous = @actions[id]
          raise UnknownApprovalError, "unknown pending approval: #{id.inspect}" unless previous&.pending?

          applying = previous.with(status: :applying)
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
