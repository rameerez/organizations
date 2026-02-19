# frozen_string_literal: true

require_relative "organizations/version"
require_relative "organizations/engine" if defined?(Rails::Engine)

module Organizations
  # === Error Classes ===

  # Base error class for all Organizations errors
  class Error < StandardError; end

  # Configuration errors
  class ConfigurationError < Error; end

  # Authorization errors - raised when user doesn't have permission
  class NotAuthorized < Error
    attr_reader :permission, :organization, :user

    def initialize(message = nil, permission: nil, organization: nil, user: nil)
      super(message)
      @permission = permission
      @organization = organization
      @user = user
    end
  end

  # Membership errors - raised when user is not a member
  class NotAMember < Error
    attr_reader :organization, :user

    def initialize(message = nil, organization: nil, user: nil)
      super(message)
      @organization = organization
      @user = user
    end
  end

  # Invitation errors
  class InvitationError < Error; end
  class InvitationExpired < InvitationError; end
  class InvitationAlreadyAccepted < InvitationError; end
  class InvitationEmailMismatch < InvitationError; end

  # === Autoload Components (lazy loading) ===

  autoload :Configuration, "organizations/configuration"
  autoload :ControllerHelpers, "organizations/controller_helpers"
  autoload :ViewHelpers, "organizations/view_helpers"
  autoload :Roles, "organizations/roles"
  autoload :Callbacks, "organizations/callbacks"
  autoload :CallbackContext, "organizations/callback_context"
  autoload :ActsAsTenantIntegration, "organizations/acts_as_tenant_integration"
  autoload :TestHelpers, "organizations/test_helpers"

  # Alias for README compatibility: `include Organizations::Controller`
  Controller = ControllerHelpers

  # Models - autoload directly under Organizations namespace
  # Model files define Organizations::Organization, etc.
  autoload :Organization, "organizations/models/organization"
  autoload :Membership, "organizations/models/membership"
  autoload :Invitation, "organizations/models/invitation"

  # Models module kept for backwards compatibility
  module Models
    module Concerns
      autoload :HasOrganizations, "organizations/models/concerns/has_organizations"
    end
  end

  class << self
    attr_writer :configuration

    # Get the configuration instance
    # @return [Configuration]
    def configuration
      @configuration ||= Configuration.new
    end

    # Configure the gem
    # @yield [Configuration] The configuration instance
    #
    # @example
    #   Organizations.configure do |config|
    #     config.always_create_personal_organization_for_each_user = true
    #     config.invitation_expiry = 7.days
    #   end
    #
    def configure
      yield(configuration)
      configuration.validate!
    end

    # Reset configuration to defaults
    # Primarily used in tests
    def reset_configuration!
      @configuration = nil
      Roles.reset!
    end

    # Get the roles module
    # @return [Module]
    def roles
      Roles
    end
  end
end
