# frozen_string_literal: true

module Ask
  module Permissions
    # Composes default and project rule layers into a single classifier.
    #
    # Resolution: any matched :deny from either layer wins. Otherwise the
    # project decision wins over the default. If neither layer matches,
    # classify returns nil.
    class PermissionRuleSet
      SNAPSHOT_VERSION = 1

      attr_reader :default_rules, :project_rules

      def initialize(default_rules: nil, project_rules: nil)
        validate_layer!(default_rules, 'default_rules')
        validate_layer!(project_rules, 'project_rules')

        @default_rules = default_rules
        @project_rules = project_rules
      end

      def classify(tool_name, args = nil)
        default_decision = @default_rules&.classify(tool_name, args)
        project_decision = @project_rules&.classify(tool_name, args)

        return :deny if default_decision == :deny || project_decision == :deny

        project_decision || default_decision
      end

      def snapshot
        {
          version: SNAPSHOT_VERSION,
          default_rules: snapshot_layer(@default_rules, 'default_rules'),
          project_rules: snapshot_layer(@project_rules, 'project_rules')
        }
      end

      def self.from_snapshot(snapshot)
        raise ArgumentError, 'Snapshot must be a Hash' unless snapshot.is_a?(Hash)
        validate_snapshot_keys!(snapshot, %i[version default_rules project_rules])

        version = snapshot_value(snapshot, :version)
        raise ArgumentError, "Unsupported snapshot version: #{version.inspect}" unless version == 1

        default_raw = snapshot_value(snapshot, :default_rules)
        project_raw = snapshot_value(snapshot, :project_rules)
        validate_snapshot_layer!(default_raw, 'default_rules')
        validate_snapshot_layer!(project_raw, 'project_rules')

        default_rules = default_raw ? PermissionRules.from_snapshot(default_raw) : nil
        project_rules = project_raw ? PermissionRules.from_snapshot(project_raw) : nil

        new(default_rules: default_rules, project_rules: project_rules)
      end

      private

      def self.snapshot_value(hash, key)
        return hash[key] if hash.key?(key)
        return hash[key.to_s] if hash.key?(key.to_s)

        raise ArgumentError, "Snapshot is missing #{key}"
      end

      def self.validate_snapshot_keys!(hash, allowed)
        keys = hash.keys.map(&:to_s)
        unknown = keys - allowed.map(&:to_s)
        raise ArgumentError, "Snapshot has unknown fields: #{unknown.join(', ')}" unless unknown.empty?
      end

      def self.validate_snapshot_layer!(value, name)
        return if value.nil? || value.is_a?(Hash)

        raise ArgumentError, "Snapshot #{name} must be a Hash or nil"
      end

      def snapshot_layer(layer, name)
        return nil unless layer
        unless layer.respond_to?(:snapshot)
          raise ArgumentError, "#{name} must respond to :snapshot to be serialized"
        end

        snapshot = layer.snapshot
        raise ArgumentError, "#{name} snapshot must be a Hash" unless snapshot.is_a?(Hash)

        snapshot
      end

      def validate_layer!(layer, name)
        return if layer.nil?

        unless layer.respond_to?(:classify)
          raise ArgumentError, "#{name} must respond to :classify"
        end
      end
    end
  end
end
