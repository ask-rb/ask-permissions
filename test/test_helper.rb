# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require 'ask-permissions'
require 'minitest/autorun'

module PermissionTestHelpers
  FakeTool = Struct.new(:name, :approval_required, :auto_approvable, keyword_init: true) do
    def approval_required?
      !!approval_required
    end

    def auto_approvable?
      !!auto_approvable
    end
  end

  def fake_tool(name, approval_required: false, auto_approvable: false)
    FakeTool.new(name: name, approval_required: approval_required, auto_approvable: auto_approvable)
  end
end
