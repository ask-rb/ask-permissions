# frozen_string_literal: true

require 'json'
require_relative 'tool_pattern'

module Ask
  module Permissions
    # Evaluates tool-invocation rules and returns allow/ask/deny decisions.
    class PermissionRules
      SNAPSHOT_VERSION = 1
      VALID_DECISIONS = %w[allow ask deny].freeze
      VALID_PATTERN_TYPES = %w[string symbol regexp all].freeze
      DANGEROUS_TOOLS = %i[bash code repl].freeze

      Rule = Data.define(
        :decision, :declared_decision, :effective_decision, :tool_pattern, :argument_pattern, :dangerous
      ) do
        def dangerous?
          dangerous
        end

        def universal?
          argument_pattern.nil?
        end

        def tool_matches?(tool_name)
          ToolPattern.match?(tool_pattern, tool_name)
        end

        def argument_matches?(args)
          return true if argument_pattern.nil?

          haystack = serialize(args)

          case argument_pattern
          when Regexp then argument_pattern.match?(haystack)
          else haystack.include?(argument_pattern.to_s)
          end
        end

        def matches?(tool_name, args = nil)
          tool_matches?(tool_name) && argument_matches?(args)
        end

        private

        def serialize(value)
          value.is_a?(Hash) ? JSON.generate(value) : value.to_s
        end
      end

      def initialize(auto_allow_dangerous: false, &block)
        @auto_allow_dangerous = auto_allow_dangerous ? true : false
        @rules = []
        @dangerous_rules = []
        @mutex = Mutex.new
        instance_eval(&block) if block
      end

      def allow(tool_pattern, argument_pattern = nil)
        register(:allow, tool_pattern, argument_pattern)
      end

      def ask(tool_pattern, argument_pattern = nil)
        register(:ask, tool_pattern, argument_pattern)
      end

      def deny(tool_pattern, argument_pattern = nil)
        register(:deny, tool_pattern, argument_pattern)
      end

      def rules
        @mutex.synchronize { @rules.dup }
      end

      def dangerous_rules
        @mutex.synchronize { @dangerous_rules.dup }
      end

      def snapshot
        entries = rules.map do |rule|
          entry = {
            decision: rule.declared_decision.to_s,
            tool_pattern: serialize_pattern(rule.tool_pattern)
          }
          entry[:argument_pattern] = serialize_pattern(rule.argument_pattern) if rule.argument_pattern
          entry
        end

        { version: SNAPSHOT_VERSION, auto_allow_dangerous: @auto_allow_dangerous, rules: entries }
      end

      def self.from_snapshot(snapshot)
        raise ArgumentError, 'Snapshot must be a Hash' unless snapshot.is_a?(Hash)
        validate_snapshot_keys!(snapshot, %i[version auto_allow_dangerous rules], 'snapshot')

        version = snapshot_value(snapshot, :version)
        raise ArgumentError, "Unsupported snapshot version: #{version.inspect}" unless version == 1

        auto_allow = snapshot_value(snapshot, :auto_allow_dangerous)
        unless [true, false].include?(auto_allow)
          raise ArgumentError, 'Snapshot auto_allow_dangerous must be true or false'
        end

        raw_rules = snapshot_value(snapshot, :rules)
        raise ArgumentError, 'Snapshot rules must be an Array' unless raw_rules.is_a?(Array)

        instance = new(auto_allow_dangerous: !!auto_allow)
        raw_rules.each do |entry|
          raise ArgumentError, 'Snapshot rule entry must be a Hash' unless entry.is_a?(Hash)
          validate_snapshot_keys!(entry, %i[decision tool_pattern argument_pattern], 'rule entry')

          decision_str = snapshot_value(entry, :decision)
          raise ArgumentError, 'Rule entry missing decision' if decision_str.nil?
          unless decision_str.is_a?(String) && VALID_DECISIONS.include?(decision_str)
            raise ArgumentError, "Invalid decision: #{decision_str.inspect}"
          end

          tool_pattern_raw = snapshot_value(entry, :tool_pattern)
          raise ArgumentError, 'Rule entry missing tool_pattern' if tool_pattern_raw.nil?
          tool_pattern = deserialize_pattern(tool_pattern_raw)

          argument_pattern_raw = optional_snapshot_value(entry, :argument_pattern)
          argument_pattern = deserialize_pattern(argument_pattern_raw) unless argument_pattern_raw.nil?

          instance.send(:register, decision_str.to_sym, tool_pattern, argument_pattern)
        end

        instance
      end

      def classify(tool_name, args = nil)
        rule = rules.find { |candidate| candidate.matches?(tool_name, args) }
        rule&.effective_decision
      end

      def allow?(tool_name, args = nil)
        classify(tool_name, args) == :allow
      end

      def ask?(tool_name, args = nil)
        classify(tool_name, args) == :ask
      end

      def deny?(tool_name, args = nil)
        classify(tool_name, args) == :deny
      end

      private

      def self.snapshot_value(hash, key)
        return hash[key] if hash.key?(key)
        return hash[key.to_s] if hash.key?(key.to_s)

        raise ArgumentError, "Snapshot is missing #{key}"
      end

      def self.optional_snapshot_value(hash, key)
        return hash[key] if hash.key?(key)
        return hash[key.to_s] if hash.key?(key.to_s)

        nil
      end

      def self.validate_snapshot_keys!(hash, allowed, name)
        keys = hash.keys.map(&:to_s)
        unknown = keys - allowed.map(&:to_s)
        raise ArgumentError, "Snapshot #{name} has unknown fields: #{unknown.join(', ')}" unless unknown.empty?
      end

      def register(decision, tool_pattern, argument_pattern)
        dangerous = dangerous_allow?(decision, tool_pattern, argument_pattern)
        effective = dangerous && !@auto_allow_dangerous ? :ask : decision

        rule = Rule.new(
          decision: decision,
          declared_decision: decision,
          effective_decision: effective,
          tool_pattern: tool_pattern,
          argument_pattern: argument_pattern,
          dangerous: dangerous
        )

        @mutex.synchronize do
          @rules << rule
          @dangerous_rules << rule if dangerous
        end

        self
      end

      def dangerous_allow?(decision, tool_pattern, argument_pattern)
        decision == :allow && argument_pattern.nil? && dangerous_tool?(tool_pattern)
      end

      def dangerous_tool?(tool_pattern)
        return true if tool_pattern == :all
        return DANGEROUS_TOOLS.any? { |name| tool_pattern.match?(name.to_s) } if tool_pattern.is_a?(Regexp)

        DANGEROUS_TOOLS.include?(tool_pattern.to_s.to_sym)
      end

      REGEXP_FLAG_MAP = {
        'i' => Regexp::IGNORECASE,
        'm' => Regexp::MULTILINE,
        'x' => Regexp::EXTENDED
      }.freeze

      def serialize_pattern(pattern)
        case pattern
        when Regexp
          supported_options = Regexp::IGNORECASE | Regexp::MULTILINE | Regexp::EXTENDED
          if (pattern.options & ~supported_options).nonzero?
            raise ArgumentError, "Unsupported regexp options: #{pattern.options}"
          end

          flags_str = +''
          flags_str << 'i' if (pattern.options & Regexp::IGNORECASE).nonzero?
          flags_str << 'm' if (pattern.options & Regexp::MULTILINE).nonzero?
          flags_str << 'x' if (pattern.options & Regexp::EXTENDED).nonzero?
          { type: 'regexp', source: pattern.source, flags: flags_str }
        when Symbol
          pattern == :all ? { type: 'all' } : { type: 'symbol', value: pattern.to_s }
        when String
          { type: 'string', value: pattern }
        else
          raise ArgumentError, "Unsupported permission pattern type: #{pattern.class}"
        end
      end

      def self.deserialize_pattern(raw)
        raise ArgumentError, 'Pattern must be a Hash' unless raw.is_a?(Hash)

        type = snapshot_value(raw, :type)
        raise ArgumentError, "Invalid pattern type: #{type.inspect}" unless type.is_a?(String) && VALID_PATTERN_TYPES.include?(type)

        allowed_keys = case type
        when 'string', 'symbol' then %i[type value]
        when 'regexp' then %i[type source flags]
        when 'all' then %i[type]
        end
        validate_snapshot_keys!(raw, allowed_keys, 'pattern')

        case type
        when 'string'
          value = snapshot_value(raw, :value)
          raise ArgumentError, 'String pattern value must be a String' unless value.is_a?(String)

          value
        when 'symbol'
          value = snapshot_value(raw, :value)
          raise ArgumentError, 'Symbol pattern value must be a String' unless value.is_a?(String)

          value.to_sym
        when 'regexp'
          source = snapshot_value(raw, :source)
          flags_str = snapshot_value(raw, :flags)
          raise ArgumentError, 'Regexp source must be a String' unless source.is_a?(String)
          unless flags_str.is_a?(String) && flags_str.chars.uniq == flags_str.chars && flags_str.chars.all? { |flag| REGEXP_FLAG_MAP.key?(flag) }
            raise ArgumentError, "Invalid regexp flags: #{flags_str.inspect}"
          end

          flags = flags_str.chars.reduce(0) { |sum, ch| sum | REGEXP_FLAG_MAP.fetch(ch) }
          Regexp.new(source, flags)
        when 'all'
          :all
        end
      rescue RegexpError, TypeError => error
        raise ArgumentError, "Invalid regexp pattern: #{error.message}"
      end

      private_class_method :deserialize_pattern
    end
  end
end
