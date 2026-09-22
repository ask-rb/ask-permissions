# frozen_string_literal: true

require 'json'
require_relative 'tool_pattern'

module Ask
  module Permissions
    class PermissionRules
      DANGEROUS_TOOLS = %w[bash code repl].freeze

      Rule = Data.define(:decision, :declared_decision, :tool_pattern, :argument_pattern, :dangerous) do
        def dangerous?
          dangerous
        end
      end

      def initialize(auto_allow_dangerous: false)
        @auto_allow_dangerous = auto_allow_dangerous ? true : false
        @rules = []
        @dangerous_rules = []
        @mutex = Mutex.new
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

      def classify(tool_name, args = nil)
        rule = rules.find { |candidate| matches?(candidate, tool_name, args) }
        rule&.decision
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

      def register(decision, tool_pattern, argument_pattern)
        dangerous = dangerous_allow?(decision, tool_pattern, argument_pattern)
        effective = dangerous && !@auto_allow_dangerous ? :ask : decision

        rule = Rule.new(
          decision: effective,
          declared_decision: decision,
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
        return DANGEROUS_TOOLS.any? { |name| tool_pattern.match?(name) } if tool_pattern.is_a?(Regexp)

        DANGEROUS_TOOLS.include?(tool_pattern.to_s)
      end

      def matches?(rule, tool_name, args)
        ToolPattern.match?(rule.tool_pattern, tool_name) &&
          arguments_match?(rule.argument_pattern, args)
      end

      def arguments_match?(pattern, args)
        return true if pattern.nil?

        haystack = serialize(args)

        case pattern
        when Regexp then pattern.match?(haystack)
        else haystack.include?(pattern.to_s)
        end
      end

      def serialize(value)
        value.is_a?(Hash) ? JSON.generate(value) : value.to_s
      end
    end
  end
end
