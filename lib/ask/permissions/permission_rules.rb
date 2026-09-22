# frozen_string_literal: true

require 'json'
require_relative 'tool_pattern'

module Ask
  module Permissions
    # Evaluates tool-invocation rules and returns allow/ask/deny decisions.
    class PermissionRules
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
    end
  end
end
