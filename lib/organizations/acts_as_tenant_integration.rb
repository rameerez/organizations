# frozen_string_literal: true

require "active_support/concern"

module Organizations
  # Integration concern for acts_as_tenant gem.
  # Automatically sets the current tenant to the current organization.
  #
  # @example Include in ApplicationController
  #   class ApplicationController < ActionController::Base
  #     include Organizations::ControllerHelpers
  #     include Organizations::ActsAsTenantIntegration
  #   end
  #
  # This will automatically call `set_current_tenant(current_organization)`
  # on each request, allowing acts_as_tenant to scope queries.
  #
  module ActsAsTenantIntegration
    extend ActiveSupport::Concern

    included do
      # Ensure this runs after organization is set
      before_action :set_organization_as_tenant

      # Also set tenant when organization is switched
      after_action :sync_tenant_with_organization
    end

    private

    # Set the current tenant to the current organization
    def set_organization_as_tenant
      return unless respond_to?(:current_organization) && current_organization
      return unless acts_as_tenant_available?

      ActsAsTenant.current_tenant = current_organization
    end

    # Sync tenant when organization changes mid-request
    def sync_tenant_with_organization
      return unless acts_as_tenant_available?

      # If organization changed during the request, update tenant
      if respond_to?(:current_organization)
        ActsAsTenant.current_tenant = current_organization
      end
    end

    # Check if acts_as_tenant is available
    def acts_as_tenant_available?
      defined?(ActsAsTenant) && ActsAsTenant.respond_to?(:current_tenant=)
    end
  end
end
