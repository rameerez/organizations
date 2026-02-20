# frozen_string_literal: true

require "active_support/core_ext/numeric/time"

module Organizations
  # Configuration class for the Organizations gem.
  # Provides all customization options for organization behavior.
  #
  # @example Basic configuration
  #   Organizations.configure do |config|
  #     config.always_create_personal_organization_for_each_user = true
  #     config.invitation_expiry = 7.days
  #   end
  #
  # @example Custom roles
  #   Organizations.configure do |config|
  #     config.roles do
  #       role :viewer do
  #         can :view_organization
  #       end
  #       role :member, inherits: :viewer do
  #         can :create_resources
  #       end
  #     end
  #   end
  #
  class Configuration
    # === Authentication ===
    # Method that returns the current user (default: :current_user)
    attr_accessor :current_user_method

    # Method that ensures user is authenticated (default: :authenticate_user!)
    attr_accessor :authenticate_user_method

    # === Auto-creation ===
    # Create personal organization on user signup
    attr_accessor :always_create_personal_organization_for_each_user

    # Name for auto-created organizations
    # Can be a String or a Proc/Lambda: ->(user) { "#{user.name}'s Workspace" }
    attr_accessor :default_organization_name

    # === Invitations ===
    # How long invitations are valid
    attr_accessor :invitation_expiry

    # Default role for invited members
    attr_accessor :default_invitation_role

    # Custom mailer for invitations (class name as string)
    attr_accessor :invitation_mailer

    # === Limits ===
    # Maximum organizations a user can own (nil = unlimited)
    attr_accessor :max_organizations_per_user

    # === Onboarding ===
    # Require users to always belong to at least one organization
    # Set to true to prevent users from leaving their last organization
    attr_accessor :always_require_users_to_belong_to_one_organization

    # === Session/Switching ===
    # Session key for storing current organization ID
    attr_accessor :session_key

    # === Redirects ===
    # Where to redirect when user has no organization
    attr_accessor :redirect_path_when_no_organization

    # Where to redirect after organization is created (nil = default show page)
    # Can be a String ("/dashboard") or Proc (->(org) { "/orgs/#{org.id}" })
    attr_accessor :after_organization_created_redirect_path

    # === Invitation Flow Redirects ===
    # Where to redirect unauthenticated users when they try to accept an invitation
    # Can be nil (use default: new_user_registration_path or root_path),
    # a String ("/users/sign_up"), or a Proc receiving (invitation, user)
    attr_accessor :redirect_path_when_invitation_requires_authentication

    # Where to redirect after invitation is accepted
    # Can be nil (use default: root_path), a String ("/dashboard"),
    # or a Proc receiving (invitation, user)
    attr_accessor :redirect_path_after_invitation_accepted

    # === Organizations Controller ===
    # Additional params to permit when creating/updating organizations
    # @example [:support_email, :billing_email, :logo]
    attr_accessor :additional_organization_params

    # === Engine configuration ===
    # Base controller for authenticated routes (default: ::ApplicationController)
    attr_accessor :parent_controller

    # Base controller for public routes like invitation acceptance (default: ActionController::Base)
    # Use this to avoid inheriting host app filters that enforce authentication
    attr_accessor :public_controller

    # === Handlers (blocks) ===
    # @private - stored handler blocks
    attr_reader :unauthorized_handler, :no_organization_handler

    # === Callbacks ===
    # @private - stored callback blocks
    attr_reader :on_organization_created_callback,
                :on_member_invited_callback,
                :on_member_joined_callback,
                :on_member_removed_callback,
                :on_role_changed_callback,
                :on_ownership_transferred_callback

    # === Custom Roles ===
    # @private - custom roles definition
    attr_reader :custom_roles_definition

    def initialize
      # Authentication defaults
      @current_user_method = :current_user
      @authenticate_user_method = :authenticate_user!

      # Auto-creation defaults
      @always_create_personal_organization_for_each_user = false
      @default_organization_name = "Personal"

      # Invitation defaults
      @invitation_expiry = 7.days
      @default_invitation_role = :member
      @invitation_mailer = "Organizations::InvitationMailer"

      # Limits
      @max_organizations_per_user = nil

      # Onboarding
      @always_require_users_to_belong_to_one_organization = false

      # Session/switching
      @session_key = :current_organization_id

      # Redirects
      @redirect_path_when_no_organization = "/organizations/new"
      @after_organization_created_redirect_path = nil

      # Invitation flow redirects
      @redirect_path_when_invitation_requires_authentication = nil
      @redirect_path_after_invitation_accepted = nil

      # Organizations controller
      @additional_organization_params = []

      # Engine
      @parent_controller = "::ApplicationController"
      @public_controller = "ActionController::Base"

      # Handlers (nil by default - use default behavior)
      @unauthorized_handler = nil
      @no_organization_handler = nil

      # Callbacks (nil by default - no-op)
      @on_organization_created_callback = nil
      @on_member_invited_callback = nil
      @on_member_joined_callback = nil
      @on_member_removed_callback = nil
      @on_role_changed_callback = nil
      @on_ownership_transferred_callback = nil

      # Custom roles
      @custom_roles_definition = nil
    end

    # === Handler Configuration Methods ===

    # Configure unauthorized access handler
    # @yield [context] Block to handle unauthorized access
    # @yieldparam context [CallbackContext] Context with user, organization, permission info
    #
    # @example
    #   config.on_unauthorized do |context|
    #     redirect_to root_path, alert: "You don't have permission."
    #   end
    #
    def on_unauthorized(&block)
      @unauthorized_handler = block if block_given?
    end

    # Configure no organization handler
    # @yield [context] Block to handle when user has no organization
    # @yieldparam context [CallbackContext] Context with user info
    #
    # @example
    #   config.on_no_organization do |context|
    #     redirect_to new_organization_path, notice: "Please create an organization."
    #   end
    #
    def on_no_organization(&block)
      @no_organization_handler = block if block_given?
    end

    # === Callback Configuration Methods ===

    # Called when an organization is created
    # @yield [context] Block to execute
    # @yieldparam context [CallbackContext] Context with organization and user
    def on_organization_created(&block)
      @on_organization_created_callback = block if block_given?
    end

    # Called when a member is invited
    # @yield [context] Block to execute
    # @yieldparam context [CallbackContext] Context with organization, invitation, invited_by
    def on_member_invited(&block)
      @on_member_invited_callback = block if block_given?
    end

    # Called when a member joins (invitation accepted)
    # @yield [context] Block to execute
    # @yieldparam context [CallbackContext] Context with organization, membership, user
    def on_member_joined(&block)
      @on_member_joined_callback = block if block_given?
    end

    # Called when a member is removed
    # @yield [context] Block to execute
    # @yieldparam context [CallbackContext] Context with organization, membership, user, removed_by
    def on_member_removed(&block)
      @on_member_removed_callback = block if block_given?
    end

    # Called when a member's role changes
    # @yield [context] Block to execute
    # @yieldparam context [CallbackContext] Context with organization, membership, old_role, new_role, changed_by
    def on_role_changed(&block)
      @on_role_changed_callback = block if block_given?
    end

    # Called when ownership is transferred
    # @yield [context] Block to execute
    # @yieldparam context [CallbackContext] Context with organization, old_owner, new_owner
    def on_ownership_transferred(&block)
      @on_ownership_transferred_callback = block if block_given?
    end

    # === Roles Configuration ===

    # Define custom roles with permissions
    # @yield DSL block for role definition
    #
    # @example
    #   config.roles do
    #     role :viewer do
    #       can :view_organization
    #       can :view_members
    #     end
    #     role :member, inherits: :viewer do
    #       can :create_resources
    #     end
    #   end
    #
    def roles(&block)
      if block_given?
        @custom_roles_definition = block
        # Reset cached permissions so new roles take effect
        Roles.reset!
      end
    end

    # Resolve the default organization name for a user
    # @param user [Object] The user object
    # @return [String] The organization name
    def resolve_default_organization_name(user)
      case @default_organization_name
      when Proc
        @default_organization_name.call(user)
      when String
        @default_organization_name
      else
        "Personal"
      end
    end

    # Validate the configuration
    # @raise [ConfigurationError] if configuration is invalid
    def validate!
      validate_authentication_methods!
      validate_invitation_settings!
      validate_limits!
      validate_invitation_redirects!
      true
    end

    private

    def validate_authentication_methods!
      unless @current_user_method.is_a?(Symbol)
        raise ConfigurationError, "current_user_method must be a Symbol"
      end

      unless @authenticate_user_method.is_a?(Symbol)
        raise ConfigurationError, "authenticate_user_method must be a Symbol"
      end
    end

    def validate_invitation_settings!
      unless @invitation_expiry.nil? || @invitation_expiry.is_a?(ActiveSupport::Duration) || @invitation_expiry.is_a?(Numeric)
        raise ConfigurationError, "invitation_expiry must be a Duration (e.g., 7.days) or nil"
      end

      unless Roles::HIERARCHY.include?(@default_invitation_role.to_sym)
        raise ConfigurationError, "default_invitation_role must be one of: #{Roles::HIERARCHY.join(', ')}"
      end
    end

    def validate_limits!
      if @max_organizations_per_user && !@max_organizations_per_user.is_a?(Integer)
        raise ConfigurationError, "max_organizations_per_user must be an Integer or nil"
      end

      if @max_organizations_per_user && @max_organizations_per_user < 1
        raise ConfigurationError, "max_organizations_per_user must be at least 1"
      end
    end

    def validate_invitation_redirects!
      validate_redirect_option!(
        @redirect_path_when_invitation_requires_authentication,
        "redirect_path_when_invitation_requires_authentication"
      )
      validate_redirect_option!(
        @redirect_path_after_invitation_accepted,
        "redirect_path_after_invitation_accepted"
      )
    end

    def validate_redirect_option!(value, option_name)
      return if value.nil? || value.is_a?(String) || value.is_a?(Proc)

      raise ConfigurationError,
            "#{option_name} must be nil, a String, or a Proc"
    end
  end
end
