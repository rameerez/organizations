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
    #
    # Create personal organization automatically on user signup.
    #
    # This setting controls the user's first-time experience:
    #
    # ┌─────────────────────────────────────────────────────────────────────────┐
    # │  true  → "Instant access" pattern                                       │
    # │                                                                         │
    # │  User signs up → auto-created workspace → lands in app immediately      │
    # │                                                                         │
    # │  Think: Notion, Slack, Trello                                           │
    # │  "Sign up and start using it in seconds"                                │
    # │                                                                         │
    # │  Best for: productivity tools, note apps, simple SaaS                   │
    # └─────────────────────────────────────────────────────────────────────────┘
    #
    # ┌─────────────────────────────────────────────────────────────────────────┐
    # │  false → "Guided onboarding" pattern                                    │
    # │                                                                         │
    # │  User signs up → onboarding wizard → enters company info → dashboard    │
    # │                                                                         │
    # │  Think: Stripe, HubSpot, enterprise B2B tools                           │
    # │  "Tell us about your company before you start"                          │
    # │                                                                         │
    # │  Best for: B2B SaaS needing company details, billing info, etc.         │
    # └─────────────────────────────────────────────────────────────────────────┘
    #
    # Related settings:
    #   - default_organization_name: Name for auto-created orgs (only when true)
    #   - redirect_path_when_no_organization: Where to send users without an org
    #   - always_require_users_to_belong_to_one_organization: Prevent leaving last org
    #
    attr_accessor :always_create_personal_organization_for_each_user

    # Name for auto-created organizations (only used when always_create_personal_organization_for_each_user = true)
    # Can be a String or a Proc/Lambda: ->(user) { "#{user.name}'s Workspace" }
    attr_accessor :default_organization_name

    # === Invitations ===
    # How long invitations are valid
    attr_accessor :invitation_expiry

    # Default role for invited members
    attr_accessor :default_invitation_role

    # Custom mailer for invitations (class name as string)
    attr_accessor :invitation_mailer

    # === Verified Joining ===
    # Custom mailer for email-verification codes (class name as string)
    attr_accessor :verification_mailer

    # How long an emailed verification code stays valid.
    # Must be a Duration/Numeric — codes always expire (OTP hygiene).
    attr_accessor :verification_code_ttl

    # Maximum wrong-code attempts per challenge before it locks
    attr_accessor :verification_max_attempts

    # Minimum time between (re)sends of a verification code for one request
    attr_accessor :verification_resend_interval

    # Maximum number of code sends per join request
    attr_accessor :verification_max_sends

    # Custom email normalizer for the verified_email uniqueness invariant.
    # nil = use Organizations::EmailNormalizer (downcase + strip + drop +tag).
    # Can be a Proc/Lambda: ->(email) { ... } returning the normalized string.
    attr_accessor :verification_email_normalizer

    # Allow Organization#join_with_account_email! to trust a host user's
    # already-confirmed account email (e.g. Devise :confirmable) as proof of
    # inbox control, skipping the emailed code when the domain matches.
    attr_accessor :trust_confirmed_account_email

    # How long join requests stay pending before they read as expired
    # (derived status, like invitations). nil = never expire.
    attr_accessor :join_request_expiry

    # Custom join code generator. nil = built-in 8-char ambiguity-free code.
    # Can be a Proc/Lambda: -> { ... } returning the code string.
    attr_accessor :join_code_generator

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

    # Default flash alert for no-organization redirects when using the built-in handler
    # nil keeps backward-compatible default alert
    attr_accessor :no_organization_alert

    # Default flash notice for no-organization redirects when using the built-in handler
    # nil means no notice
    attr_accessor :no_organization_notice

    # === Invitation Flow Redirects ===
    # Where to redirect unauthenticated users when they try to accept an invitation
    # Can be nil (use default: new_user_registration_path or root_path),
    # a String ("/users/sign_up"), or a Proc receiving (invitation, user)
    attr_accessor :redirect_path_when_invitation_requires_authentication

    # Where to redirect after invitation is accepted
    # Can be nil (use default: root_path), a String ("/dashboard"),
    # or a Proc receiving (invitation, user)
    attr_accessor :redirect_path_after_invitation_accepted

    # Where to redirect after organization switch
    # Can be nil (use default: root_path), a String ("/dashboard"),
    # or a Proc receiving (organization, user)
    attr_accessor :redirect_path_after_organization_switched

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

    # Layout for authenticated engine controllers (OrganizationsController, etc.)
    # Can be nil (use controller default), String, or Symbol
    attr_accessor :authenticated_controller_layout

    # Layout for public engine controllers (PublicInvitationsController, etc.)
    # Can be nil (use controller default), String, or Symbol
    attr_accessor :public_controller_layout

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
                :on_ownership_transferred_callback,
                :on_join_request_created_callback,
                :on_join_request_approved_callback,
                :on_join_request_rejected_callback

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

      # Verified joining defaults
      @verification_mailer = "Organizations::VerificationMailer"
      @verification_code_ttl = 15.minutes
      @verification_max_attempts = 5
      @verification_resend_interval = 60.seconds
      @verification_max_sends = 5
      @verification_email_normalizer = nil
      @trust_confirmed_account_email = true
      @join_request_expiry = 30.days
      @join_code_generator = nil

      # Limits
      @max_organizations_per_user = nil

      # Onboarding
      @always_require_users_to_belong_to_one_organization = false

      # Session/switching
      @session_key = :current_organization_id

      # Redirects
      @redirect_path_when_no_organization = "/organizations/new"
      @after_organization_created_redirect_path = nil
      @no_organization_alert = nil
      @no_organization_notice = nil

      # Invitation flow redirects
      @redirect_path_when_invitation_requires_authentication = nil
      @redirect_path_after_invitation_accepted = nil
      @redirect_path_after_organization_switched = nil

      # Organizations controller
      @additional_organization_params = []

      # Engine
      @parent_controller = "::ApplicationController"
      @public_controller = "ActionController::Base"
      @authenticated_controller_layout = nil
      @public_controller_layout = nil

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
      @on_join_request_created_callback = nil
      @on_join_request_approved_callback = nil
      @on_join_request_rejected_callback = nil

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

    # Called when a join request is created (request-to-join workflow)
    # @yield [context] Block to execute
    # @yieldparam context [CallbackContext] Context with organization, user, join_request
    def on_join_request_created(&block)
      @on_join_request_created_callback = block if block_given?
    end

    # Called when a join request is approved (manually or auto-approved).
    # NOTE: like all after-callbacks, errors here are isolated — hosts must
    # enforce hard caps (e.g. member limits) BEFORE approving, in their own code.
    # @yield [context] Block to execute
    # @yieldparam context [CallbackContext] Context with organization, user, join_request, membership, decided_by (nil for auto-approvals)
    def on_join_request_approved(&block)
      @on_join_request_approved_callback = block if block_given?
    end

    # Called when a join request is rejected
    # @yield [context] Block to execute
    # @yieldparam context [CallbackContext] Context with organization, user, join_request, decided_by
    def on_join_request_rejected(&block)
      @on_join_request_rejected_callback = block if block_given?
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

    # Normalize an email through the configured (or default) normalizer
    # @param email [String, nil]
    # @return [String] normalized email
    def normalize_verification_email(email)
      normalizer = @verification_email_normalizer
      return normalizer.call(email).to_s if normalizer.respond_to?(:call)

      EmailNormalizer.normalize(email)
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
      validate_verification_settings!
      validate_limits!
      validate_invitation_redirects!
      validate_no_organization_messages!
      validate_controller_layouts!
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

    def validate_verification_settings!
      validate_duration_option!(@verification_code_ttl, "verification_code_ttl", "15.minutes")
      validate_duration_option!(@verification_resend_interval, "verification_resend_interval", "60.seconds")
      validate_positive_integer_option!(@verification_max_attempts, "verification_max_attempts")
      validate_positive_integer_option!(@verification_max_sends, "verification_max_sends")
      validate_callable_option!(@verification_email_normalizer, "verification_email_normalizer")
      validate_callable_option!(@join_code_generator, "join_code_generator")

      unless [true, false].include?(@trust_confirmed_account_email)
        raise ConfigurationError, "trust_confirmed_account_email must be true or false"
      end

      return if @join_request_expiry.nil? || duration_like?(@join_request_expiry)

      raise ConfigurationError, "join_request_expiry must be a Duration (e.g., 30.days), Numeric, or nil (never expire)"
    end

    def duration_like?(value)
      value.is_a?(ActiveSupport::Duration) || value.is_a?(Numeric)
    end

    def validate_duration_option!(value, option_name, example)
      return if duration_like?(value)

      raise ConfigurationError, "#{option_name} must be a Duration (e.g., #{example}) or Numeric"
    end

    def validate_positive_integer_option!(value, option_name)
      return if value.is_a?(Integer) && value >= 1

      raise ConfigurationError, "#{option_name} must be an Integer of at least 1"
    end

    def validate_callable_option!(value, option_name)
      return if value.nil? || value.respond_to?(:call)

      raise ConfigurationError, "#{option_name} must be nil or callable (Proc/Lambda)"
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
      validate_redirect_option!(
        @redirect_path_after_organization_switched,
        "redirect_path_after_organization_switched"
      )
    end

    def validate_controller_layouts!
      validate_layout_option!(@authenticated_controller_layout, "authenticated_controller_layout")
      validate_layout_option!(@public_controller_layout, "public_controller_layout")
    end

    def validate_no_organization_messages!
      validate_string_option!(@no_organization_alert, "no_organization_alert")
      validate_string_option!(@no_organization_notice, "no_organization_notice")
    end

    def validate_redirect_option!(value, option_name)
      return if value.nil? || value.is_a?(String) || value.is_a?(Proc)

      raise ConfigurationError,
            "#{option_name} must be nil, a String, or a Proc"
    end

    def validate_layout_option!(value, option_name)
      return if value.nil? || value.is_a?(String) || value.is_a?(Symbol)

      raise ConfigurationError,
            "#{option_name} must be nil, a String, or a Symbol"
    end

    def validate_string_option!(value, option_name)
      return if value.nil? || value.is_a?(String)

      raise ConfigurationError,
            "#{option_name} must be nil or a String"
    end
  end
end
