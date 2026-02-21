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
  autoload :CurrentUserResolution, "organizations/current_user_resolution"
  autoload :InvitationAcceptanceResult, "organizations/invitation_acceptance_result"
  autoload :InvitationAcceptanceFailure, "organizations/invitation_acceptance_failure"

  # Alias for README compatibility: `include Organizations::Controller`
  Controller = ControllerHelpers

  # Models module kept for backwards compatibility
  module Models
    module Concerns
      # HasOrganizations is always autoloaded from lib/ because:
      # 1. It's extended onto ActiveRecord::Base at boot time via the engine initializer
      # 2. It doesn't define any associations that point to reloadable classes
      autoload :HasOrganizations, "organizations/models/concerns/has_organizations"
    end
  end

  # In Rails apps, Organization/Membership/Invitation models are loaded from
  # app/models via Zeitwerk (reload-safe). This is critical because these models
  # define associations to other reloadable classes (like Pay::Customer), and we
  # need the association reflections to point to current class objects after reload.
  #
  # In non-Rails environments (plain Ruby, tests without Rails), use lib-based autoloading.
  #
  # NOTE on the guard: Rails::Engine is defined when `railties` has been required.
  # In typical usage, this means a Rails app context where Zeitwerk manages app/models.
  # Edge cases (e.g., requiring railties without a full app) are rare and would need
  # custom setup anyway. For standard Rails apps, this correctly delegates to Zeitwerk.
  #
  # IMPORTANT: The app/models/*.rb entrypoints delegate to lib/ via `load`. This means
  # Zeitwerk watches the entrypoint files, not the lib/ files. Changes to lib/ model
  # files during gem development won't auto-reload; restart the server in that case.
  unless defined?(Rails::Engine)
    autoload :Organization, "organizations/models/organization"
    autoload :Membership, "organizations/models/membership"
    autoload :Invitation, "organizations/models/invitation"
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
