# frozen_string_literal: true

module Organizations
  module ControllerHelpers
    extend ActiveSupport::Concern

    included do
      helper_method :current_organization if respond_to?(:helper_method)
    end

    # TODO: Implement controller helpers:
    # - current_organization
    # - current_organization=(org)
    # - switch_to_organization!(org)
    # - require_organization!
    # - require_organization_admin!
    # - require_organization_owner!
    # - require_organization_permission!(permission)
  end
end
