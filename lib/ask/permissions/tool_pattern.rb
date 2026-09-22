# frozen_string_literal: true

module Ask
  module Permissions
    module ToolPattern
      module_function

      def match?(pattern, tool_name)
        name = tool_name.to_s

        case pattern
        when :all then true
        when Regexp then pattern.match?(name)
        else pattern.to_s == name
        end
      end
    end
  end
end
