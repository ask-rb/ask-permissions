# frozen_string_literal: true

module Ask
  module Permissions
    # In-memory whole-tool grants scoped to the current session.
    #
    # A grant bypasses ordinary ask rules, approval_required metadata,
    # high-risk gates, and ask_before_changes side-effect prompts when
    # consulted through ApprovalPolicy#before_tool_call via the optional
    # session_grants: collaborator. Grants never override an explicit deny
    # rule, a tool's always_ask? requirement, or read_only mode.
    #
    # Grants live in memory only, are isolated per instance (sharing an
    # instance shares grants; separate instances do not), and never touch
    # project rules. Use #snapshot / #restore_snapshot (or .from_snapshot)
    # to persist grants alongside durable session state.
    class SessionPermissionGrants
      SNAPSHOT_VERSION = 1

      def initialize(granted_tools: [])
        @mutex = Mutex.new
        @granted = Set.new
        Array(granted_tools).each { |name| grant(name) }
      end

      def grant(tool_name)
        normalized = normalize_tool_name!(tool_name)
        @mutex.synchronize { @granted.add(normalized) }
        self
      end

      def revoke(tool_name)
        normalized = normalize_tool_name!(tool_name)
        @mutex.synchronize { @granted.delete(normalized) }
        self
      end

      def granted?(tool_name)
        normalized = normalize_tool_name(tool_name)
        return false if normalized.nil?

        @mutex.synchronize { @granted.include?(normalized) }
      end

      def granted_tools
        @mutex.synchronize { @granted.to_a.sort }
      end

      def size
        @mutex.synchronize { @granted.size }
      end

      def empty?
        @mutex.synchronize { @granted.empty? }
      end

      def clear
        @mutex.synchronize { @granted.clear }
        self
      end

      # JSON-safe snapshot for a durable session store.
      def snapshot
        @mutex.synchronize do
          { version: SNAPSHOT_VERSION, granted_tools: @granted.to_a.sort }
        end
      end

      # Replaces current grants with validated snapshot contents.
      def restore_snapshot(snapshot)
        tools = validated_snapshot_tools!(snapshot)
        @mutex.synchronize do
          @granted.clear
          tools.each { |name| @granted.add(name) }
        end
        self
      end

      def self.from_snapshot(snapshot)
        new.restore_snapshot(snapshot)
      end

      private

      def normalize_tool_name(tool_name)
        return nil if tool_name.nil?
        return nil unless tool_name.is_a?(String) || tool_name.is_a?(Symbol)

        normalized = tool_name.to_s
        normalized.empty? ? nil : normalized
      end

      def normalize_tool_name!(tool_name)
        normalized = normalize_tool_name(tool_name)
        raise ArgumentError, 'Tool name must be a non-empty String or Symbol' if normalized.nil?

        normalized
      end

      def snapshot_value(hash, key)
        raise ArgumentError, 'Session grants snapshot must be a Hash' unless hash.is_a?(Hash)

        hash.key?(key) ? hash[key] : hash[key.to_s]
      end

      def validated_snapshot_tools!(snapshot)
        version = snapshot_value(snapshot, :version)
        unless version == SNAPSHOT_VERSION
          raise ArgumentError, "Unsupported session grants version: #{version.inspect}"
        end

        entries = snapshot_value(snapshot, :granted_tools)
        raise ArgumentError, 'Session grants snapshot granted_tools must be an Array' unless entries.is_a?(Array)

        entries.map do |entry|
          normalized = normalize_tool_name(entry)
          raise ArgumentError, 'Session grants snapshot tool names must be non-empty Strings' if normalized.nil?

          normalized
        end.uniq
      end
    end
  end
end
