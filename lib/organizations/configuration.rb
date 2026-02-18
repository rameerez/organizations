# frozen_string_literal: true

require "active_support/core_ext/numeric/time"

module Organizations
  class Configuration
    # Personal organization settings
    attr_accessor :create_personal_organization
    attr_accessor :personal_organization_name # Lambda: ->(user) { "#{user.name}'s Organization" }

    # Organization requirements
    attr_accessor :require_organization

    # Invitation settings
    attr_accessor :invitation_expiry
    attr_accessor :default_invitation_role

    # Session/switching
    attr_accessor :session_key

    # Engine configuration
    attr_accessor :parent_controller
    attr_accessor :current_user_method
    attr_accessor :authenticate_user_method

    # Callbacks
    attr_accessor :after_organization_created
    attr_accessor :after_member_added
    attr_accessor :after_member_removed
    attr_accessor :after_invitation_accepted

    def initialize
      # Defaults
      @create_personal_organization = true
      @personal_organization_name = ->(user) { "#{user.name}'s Organization" }
      @require_organization = true
      @invitation_expiry = 7.days
      @default_invitation_role = :member
      @session_key = :current_organization_id
      @parent_controller = "::ApplicationController"
      @current_user_method = :current_user
      @authenticate_user_method = :authenticate_user!

      # Callbacks (no-op by default)
      @after_organization_created = ->(_org, _user) {}
      @after_member_added = ->(_membership) {}
      @after_member_removed = ->(_membership) {}
      @after_invitation_accepted = ->(_invitation, _user) {}
    end

    def validate!
      # TODO: Add validation logic
      # raise ConfigurationError, "..." if invalid
      true
    end
  end
end
