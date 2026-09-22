# frozen_string_literal: true

module Ask
  module Permissions
    class Error < StandardError
    end

    class UnknownApprovalError < Error
    end
  end
end
