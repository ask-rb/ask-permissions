# frozen_string_literal: true

module Ask
  module Permissions
    Error = Class.new(StandardError)

    UnknownApprovalError = Class.new(Error)
  end
end
