# frozen_string_literal: true

require_relative "organizations/version"
require_relative "organizations/engine" if defined?(Rails::Engine)

module Organizations
  # Base error class
  class Error < StandardError; end

  # Configuration errors
  class ConfigurationError < Error; end

  # Authorization errors
  class NotAuthorized < Error
    attr_reader :permission, :organization, :user

    def initialize(message = nil, permission: nil, organization: nil, user: nil)
      super(message)
      @permission = permission
      @organization = organization
      @user = user
    end
  end

  # Membership errors
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

  # Autoload components (lazy loading)
  autoload :Configuration, "organizations/configuration"
  autoload :ControllerHelpers, "organizations/controller_helpers"
  autoload :ViewHelpers, "organizations/view_helpers"
  autoload :Roles, "organizations/roles"
  autoload :Callbacks, "organizations/callbacks"
  autoload :CallbackContext, "organizations/callback_context"

  # Models
  module Models
    autoload :Organization, "organizations/models/organization"
    autoload :Membership, "organizations/models/membership"
    autoload :Invitation, "organizations/models/invitation"

    module Concerns
      autoload :HasOrganizations, "organizations/models/concerns/has_organizations"
    end
  end

  class << self
    attr_writer :configuration

    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration)
      configuration.validate!
    end

    def reset_configuration!
      @configuration = nil
    end

    # Built-in roles with their permissions
    # Apps can override via configuration
    def roles
      @roles ||= Roles.default
    end
  end
end
