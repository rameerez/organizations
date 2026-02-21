# frozen_string_literal: true

require "active_support/concern"

module Organizations
  # Controller helpers to be included in host application controllers.
  # Provides current_organization context, session-based switching, and permission guards.
  #
  # @example Include in ApplicationController
  #   class ApplicationController < ActionController::Base
  #     include Organizations::ControllerHelpers
  #   end
  #
  # @example Using guards
  #   class ProjectsController < ApplicationController
  #     before_action :require_organization!
  #     before_action :require_organization_admin!, only: [:create, :destroy]
  #   end
  #
  module ControllerHelpers
    extend ActiveSupport::Concern
    include Organizations::CurrentUserResolution

    included do
      # Make helpers available in views
      if respond_to?(:helper_method)
        helper_method :current_organization
        helper_method :current_membership
        helper_method :organization_signed_in?
        helper_method :pending_organization_invitation
        helper_method :pending_organization_invitation?
        helper_method :pending_organization_invitation_email
      end
    end

    # === Context Helpers ===

    # Returns the current organization from session
    # Validates membership - if user was removed, auto-switches to next available org
    # Falls back to most recently joined org if no session set
    # Memoized within the request
    # @return [Organizations::Organization, nil]
    def current_organization
      return @_current_organization if defined?(@_current_organization)

      user = organizations_current_user
      return @_current_organization = nil unless user

      session_key = Organizations.configuration.session_key
      org_id = session[session_key]

      # Find organization AND verify membership
      # Use is_member_of? which has DB fallback for stale loaded associations
      org = org_id ? Organizations::Organization.find_by(id: org_id) : nil

      if org && user.is_member_of?(org)
        # Valid membership - use this org
        user._current_organization_id = org.id
        @_current_organization = org
      else
        # User was removed from this org OR no session set
        # Auto-switch to next available org (most recently joined)
        clear_organization_session!

        fallback_org = fallback_organization_for(user)
        if fallback_org
          session[session_key] = fallback_org.id
          user._current_organization_id = fallback_org.id
          @_current_organization = fallback_org
        else
          @_current_organization = nil
        end
      end
    end

    # Returns the current user's membership in the current organization
    # @return [Organizations::Membership, nil]
    def current_membership
      return @_current_membership if defined?(@_current_membership)

      user = organizations_current_user
      return @_current_membership = nil unless user && current_organization

      @_current_membership = user.memberships.find_by(organization_id: current_organization.id)
    end

    # Check if there's an active organization
    # @return [Boolean]
    def organization_signed_in?
      current_organization.present?
    end

    # === Pending Invitation Helpers ===

    # Returns the pending invitation token from session
    # @return [String, nil]
    def pending_organization_invitation_token
      session[pending_invitation_session_key]
    end

    # Returns the pending invitation if token is valid and invitation is usable
    # Clears token if invitation is missing, expired, or already accepted
    # @return [Organizations::Invitation, nil]
    def pending_organization_invitation
      token = pending_organization_invitation_token
      return nil unless token

      # Check memoized value (keyed by token to handle mid-request changes)
      if defined?(@_pending_organization_invitation_token) && @_pending_organization_invitation_token == token
        return @_pending_organization_invitation
      end

      invitation = Organizations::Invitation.find_by(token: token)

      unless invitation
        clear_pending_organization_invitation!
        return nil
      end

      if invitation.expired? || invitation.accepted?
        clear_pending_organization_invitation!
        return nil
      end

      @_pending_organization_invitation_token = token
      @_pending_organization_invitation = invitation
    end

    # Check if there's a valid pending invitation
    # @return [Boolean]
    def pending_organization_invitation?
      pending_organization_invitation.present?
    end

    # Returns the email from the pending invitation, if present
    # @return [String, nil]
    def pending_organization_invitation_email
      pending_organization_invitation&.email
    end

    # Clear pending invitation token and memoized values
    # @return [nil]
    def clear_pending_organization_invitation!
      session.delete(pending_invitation_session_key)
      remove_instance_variable(:@_pending_organization_invitation) if defined?(@_pending_organization_invitation)
      remove_instance_variable(:@_pending_organization_invitation_token) if defined?(@_pending_organization_invitation_token)
      nil
    end

    # Accept pending invitation (if present) and return post-accept redirect path.
    # Returns nil when there is no pending/acceptable invitation.
    #
    # @param user [User] The user accepting the invitation
    # @param token [String, nil] Explicit invitation token (optional)
    # @param switch [Boolean] Whether to switch organization context
    # @param skip_email_validation [Boolean] Whether to skip invitation email checks
    # @param notice [Boolean, String, Proc] Flash notice behavior (default: true)
    # @return [String, nil] Redirect path or nil
    def pending_invitation_acceptance_redirect_path_for(
      user,
      token: nil,
      switch: true,
      skip_email_validation: false,
      notice: true
    )
      result = accept_pending_organization_invitation!(
        user,
        token: token,
        switch: switch,
        skip_email_validation: skip_email_validation
      )
      return nil unless result

      set_pending_invitation_acceptance_notice!(result, user: user, notice: notice)
      redirect_path_after_invitation_accepted(result.invitation, user: user)
    end

    # Accept pending invitation and either return redirect path or perform redirect.
    #
    # @param user [User] The user accepting the invitation
    # @param redirect [Boolean] When true, performs redirect_to and returns true/false
    # @param token [String, nil] Explicit invitation token (optional)
    # @param switch [Boolean] Whether to switch organization context
    # @param skip_email_validation [Boolean] Whether to skip invitation email checks
    # @param notice [Boolean, String, Proc] Flash notice behavior (default: true)
    # @return [String, Boolean, nil]
    def handle_pending_invitation_acceptance_for(
      user,
      redirect: false,
      token: nil,
      switch: true,
      skip_email_validation: false,
      notice: true
    )
      path = pending_invitation_acceptance_redirect_path_for(
        user,
        token: token,
        switch: switch,
        skip_email_validation: skip_email_validation,
        notice: notice
      )

      return false if redirect && path.nil?
      return nil unless path
      return path unless redirect

      redirect_to path
      true
    end

    # Accept a pending organization invitation for a user
    # This is the canonical method for handling invitation acceptance after signup/signin.
    #
    # @param user [User] The user accepting the invitation
    # @param token [String, nil] Explicit token (uses session token if not provided)
    # @param switch [Boolean] Whether to switch to the organization after acceptance (default: true)
    # @param skip_email_validation [Boolean] Skip email matching check (default: false)
    # @param return_failure [Boolean] Return a structured failure object instead of nil
    # @return [Organizations::InvitationAcceptanceResult, Organizations::InvitationAcceptanceFailure, nil]
    #
    # @example Basic usage in after_sign_in_path_for
    #   def after_sign_in_path_for(resource)
    #     if (result = accept_pending_organization_invitation!(resource))
    #       return redirect_path_after_invitation_accepted(result.invitation, user: resource)
    #     end
    #     super
    #   end
    #
    def accept_pending_organization_invitation!(
      user,
      token: nil,
      switch: true,
      skip_email_validation: false,
      return_failure: false
    )
      return invitation_acceptance_failure(:missing_user, return_failure: return_failure) unless user

      # Track whether we're using an explicit token that differs from session
      # Only skip session clearing if explicit token fails and differs from session
      explicit_token = token.presence
      session_token = pending_organization_invitation_token
      invitation_token = explicit_token || session_token
      return invitation_acceptance_failure(:missing_token, return_failure: return_failure) unless invitation_token

      # When explicit token differs from session, don't clear session on failure
      using_different_explicit_token = explicit_token && explicit_token != session_token

      invitation = Organizations::Invitation.find_by(token: invitation_token)
      unless invitation
        # Only clear session if we were using the session token (or same token)
        clear_pending_organization_invitation! unless using_different_explicit_token
        return invitation_acceptance_failure(:invitation_not_found, return_failure: return_failure)
      end

      if invitation.expired?
        # Only clear session if we were using the session token (or same token)
        clear_pending_organization_invitation! unless using_different_explicit_token
        return invitation_acceptance_failure(
          :invitation_expired,
          return_failure: return_failure,
          invitation: invitation
        )
      end

      # Check email match (unless skipping validation)
      unless skip_email_validation
        if user.respond_to?(:email) && !invitation.for_email?(user.email)
          # Email mismatch - keep token intact to allow switching accounts
          return invitation_acceptance_failure(
            :email_mismatch,
            return_failure: return_failure,
            invitation: invitation
          )
        end
      end

      status = :accepted
      membership = nil

      begin
        membership = invitation.accept!(user, skip_email_validation: skip_email_validation)
      rescue Organizations::InvitationExpired
        # Race condition: invitation expired between our check and accept!
        clear_pending_organization_invitation! unless using_different_explicit_token
        return invitation_acceptance_failure(
          :invitation_expired,
          return_failure: return_failure,
          invitation: invitation
        )
      rescue Organizations::InvitationAlreadyAccepted
        # Check if user is actually a member
        membership = Organizations::Membership.find_by(
          user_id: user.id,
          organization_id: invitation.organization_id
        )
        unless membership
          # Data integrity anomaly: invitation marked accepted but membership missing
          if defined?(Rails) && Rails.respond_to?(:logger)
            Rails.logger.warn "[Organizations] InvitationAlreadyAccepted raised but no membership found for user=#{user.id} org=#{invitation.organization_id}"
          end
          clear_pending_organization_invitation! unless using_different_explicit_token
          return invitation_acceptance_failure(
            :already_accepted_without_membership,
            return_failure: return_failure,
            invitation: invitation
          )
        end
        status = :already_member
      end

      # Attempt to switch to the organization
      switched = true
      if switch
        begin
          switch_to_organization!(invitation.organization, user: user)
        rescue Organizations::NotAMember
          switched = false
        end
      else
        switched = false
      end

      # Always clear session token on successful acceptance
      clear_pending_organization_invitation!

      Organizations::InvitationAcceptanceResult.new(
        status: status,
        invitation: invitation,
        membership: membership,
        switched: switched
      )
    end

    # Returns the path to redirect to when an invitation requires authentication
    # Uses configured value or falls back to registration/root path
    #
    # @param invitation [Organizations::Invitation, nil] The invitation (optional)
    # @param user [User, nil] The user (optional)
    # @return [String] The redirect path
    def redirect_path_when_invitation_requires_authentication(invitation = nil, user: nil)
      config_value = Organizations.configuration.redirect_path_when_invitation_requires_authentication

      resolve_controller_redirect_path(
        config_value,
        invitation,
        user,
        default: -> { default_auth_required_redirect_path }
      )
    end

    # Returns the path to redirect to after invitation is accepted
    # Uses configured value or falls back to root path
    #
    # @param invitation [Organizations::Invitation] The invitation that was accepted
    # @param user [User, nil] The user who accepted (optional)
    # @return [String] The redirect path
    def redirect_path_after_invitation_accepted(invitation, user: nil)
      config_value = Organizations.configuration.redirect_path_after_invitation_accepted

      resolve_controller_redirect_path(
        config_value,
        invitation,
        user,
        default: -> { default_after_accept_redirect_path }
      )
    end

    # Returns the path to redirect to after organization switch
    # Uses configured value or falls back to root path
    #
    # @param organization [Organizations::Organization] The organization switched to
    # @param user [User, nil] The user who switched (optional)
    # @return [String] The redirect path
    def redirect_path_after_organization_switched(organization, user: nil)
      config_value = Organizations.configuration.redirect_path_after_organization_switched

      resolve_controller_redirect_path(
        config_value,
        organization,
        user,
        default: -> { default_after_switch_redirect_path }
      )
    end

    # Returns the redirect path used when the user has no active organization.
    # Uses configured value or falls back to /organizations/new.
    #
    # @param user [User, nil] Optional user context for Proc redirects
    # @return [String]
    def redirect_path_when_no_organization(user: nil)
      config_value = Organizations.configuration.redirect_path_when_no_organization
      redirect_user = user || organizations_current_user

      resolve_controller_redirect_path(
        config_value,
        redirect_user,
        default: -> { "/organizations/new" }
      )
    end

    # Alias used in many host apps for readability.
    #
    # @param user [User, nil] Optional user context for Proc redirects
    # @return [String]
    def no_organization_redirect_path(user: nil)
      redirect_path_when_no_organization(user: user)
    end

    # Redirect helper for no-organization flows.
    #
    # When both alert and notice are nil, uses the default alert message.
    #
    # @param alert [String, nil] Flash alert message
    # @param notice [String, nil] Flash notice message
    # @return [false]
    def redirect_to_no_organization!(alert: nil, notice: nil)
      flash_options = {}
      flash_options[:alert] = alert unless alert.nil?
      flash_options[:notice] = notice unless notice.nil?

      # Keep current behavior for existing apps when nothing is configured/passed.
      flash_options[:alert] = "Please select or create an organization." if flash_options.empty?

      redirect_to no_organization_redirect_path, **flash_options
      false
    end

    # Creates an organization and switches context in one call.
    #
    # @param user [User] The user who will own the created organization
    # @param attributes [Hash] Attributes passed to create_organization!
    # @return [Organizations::Organization] The created organization
    def create_organization_and_switch!(user, attributes = {})
      organization = user.create_organization!(attributes)
      switch_to_organization!(organization, user: user)
      organization
    end

    # Alias for readability in host apps.
    alias_method :create_organization_with_context!, :create_organization_and_switch!

    # === Switching ===

    # Sets the current organization in session
    # @param org [Organizations::Organization, nil]
    def current_organization=(org)
      session_key = Organizations.configuration.session_key

      if org
        session[session_key] = org.id
        @_current_organization = org
        @_current_membership = nil # Clear cached membership

        # Update user's context
        user = organizations_current_user
        user._current_organization_id = org.id if user
      else
        clear_organization_session!
      end
    end

    # Switches to a different organization
    # @param org [Organizations::Organization]
    # @param user [User, nil] Explicit user to switch for (useful in auth-transition flows)
    # @raise [Organizations::NotAMember] if user is not a member
    def switch_to_organization!(org, user: nil)
      acting_user = user || organizations_current_user(refresh: true)

      unless membership_exists_for?(acting_user, org)
        raise Organizations::NotAMember.new(
          "You are not a member of this organization",
          organization: org,
          user: acting_user
        )
      end

      self.current_organization = org
      # current_organization= calls organizations_current_user (without refresh) and
      # updates that user's _current_organization_id. But in auth-transition flows:
      # 1. The memoized user may still be nil (sign-in just happened)
      # 2. An explicit user: was passed that differs from the memoized user
      # In either case, acting_user won't be updated by current_organization=.
      # This explicit assignment ensures acting_user always gets the correct org ID.
      acting_user._current_organization_id = org.id if acting_user.respond_to?(:_current_organization_id=)
      mark_membership_as_recent!(acting_user, org)
    end

    # === Permission Guards ===
    # Use these as before_action callbacks

    # Requires a current organization to be set
    # @example
    #   before_action :require_organization!
    def require_organization!
      return if current_organization

      handle_no_organization
    end

    # Requires the user to have at least the specified role
    # @param role [Symbol] The minimum required role
    # @example
    #   before_action -> { require_organization_role!(:admin) }, only: [:edit]
    def require_organization_role!(role)
      require_organization!
      return unless current_organization

      user = organizations_current_user
      return if user&.is_at_least?(role, in: current_organization)

      handle_unauthorized(
        permission: role,
        required_role: role
      )
    end

    # Requires the user to have a specific permission
    # @param permission [Symbol] The permission to check
    # @example
    #   before_action -> { require_organization_permission_to!(:invite_members) }
    def require_organization_permission_to!(permission)
      require_organization!
      return unless current_organization

      user = organizations_current_user
      return if user&.has_organization_permission_to?(permission)

      handle_unauthorized(permission: permission)
    end

    # Requires the user to be an admin (or owner) of the current organization
    # Convenience method for require_organization_role!(:admin)
    # @example
    #   before_action :require_organization_admin!, only: [:edit, :update]
    def require_organization_admin!
      require_organization_role!(:admin)
    end

    # Requires the user to be the owner of the current organization
    # Convenience method for require_organization_role!(:owner)
    # @example
    #   before_action :require_organization_owner!, only: [:destroy]
    def require_organization_owner!
      require_organization_role!(:owner)
    end

    private

    def organizations_current_user(refresh: false)
      resolve_organizations_current_user(
        cache_ivar: :@_organizations_current_user,
        refresh: refresh,
        cache_nil: false
      )
    end

    def invitation_acceptance_failure(reason, return_failure:, invitation: nil)
      return nil unless return_failure

      Organizations::InvitationAcceptanceFailure.new(
        reason: reason,
        invitation: invitation
      )
    end

    # Clear organization session and cached values
    def clear_organization_session!
      session_key = Organizations.configuration.session_key
      session.delete(session_key)
      @_current_organization = nil
      @_current_membership = nil

      user = organizations_current_user
      user&.clear_organization_cache!
    end

    def fallback_organization_for(user)
      membership = user.memberships.includes(:organization).order(updated_at: :desc, created_at: :desc).first
      membership&.organization
    end

    def mark_membership_as_recent!(user, org)
      user.memberships.where(organization_id: org.id).update_all(updated_at: Time.current)
    end

    # DB-authoritative membership check to avoid stale loaded association issues
    # @param user [User, nil]
    # @param org [Organization, nil]
    # @return [Boolean]
    def membership_exists_for?(user, org)
      return false unless user && org

      Organizations::Membership.exists?(user_id: user.id, organization_id: org.id)
    end

    # Handle unauthorized access
    def handle_unauthorized(permission: nil, required_role: nil)
      config = Organizations.configuration
      user = organizations_current_user

      # Use custom handler if configured
      if config.unauthorized_handler
        context = CallbackContext.new(
          event: :unauthorized,
          user: user,
          organization: current_organization,
          permission: permission,
          required_role: required_role
        )
        instance_exec(context, &config.unauthorized_handler)
        return
      end

      # Default behavior
      error = Organizations::NotAuthorized.new(
        build_unauthorized_message(permission, required_role),
        permission: permission,
        organization: current_organization,
        user: user
      )

      respond_to_unauthorized(error)
    end

    def build_unauthorized_message(permission, required_role)
      if required_role
        "You need #{required_role} access to perform this action"
      elsif permission
        "You don't have permission to #{permission.to_s.humanize.downcase}"
      else
        "You are not authorized to perform this action"
      end
    end

    def respond_to_unauthorized(error)
      respond_to do |format|
        format.html { redirect_back fallback_location: main_app.root_path, alert: error.message }
        format.json { render json: { error: error.message }, status: :forbidden }
      end
    end

    # Handle no organization
    def handle_no_organization
      config = Organizations.configuration
      user = organizations_current_user

      # Use custom handler if configured
      if config.no_organization_handler
        context = CallbackContext.new(
          event: :no_organization,
          user: user
        )
        instance_exec(context, &config.no_organization_handler)
        return
      end

      # Default behavior
      respond_to do |format|
        format.html do
          redirect_to_no_organization!(
            alert: config.no_organization_alert,
            notice: config.no_organization_notice
          )
        end
        format.json { render json: { error: "Organization required" }, status: :forbidden }
      end
    end

    def set_pending_invitation_acceptance_notice!(result, user:, notice:)
      return unless notice
      return unless respond_to?(:flash) && flash

      message = case notice
                when true
                  default_pending_invitation_acceptance_notice(result.invitation)
                when Proc
                  resolve_pending_invitation_notice_message(notice, result, user)
                when String
                  notice
                else
                  notice.to_s
                end

      flash[:notice] = message if message.present?
    end

    def resolve_pending_invitation_notice_message(notice_proc, result, user)
      case notice_proc.arity
      when 0
        instance_exec(&notice_proc)
      when 1
        instance_exec(result, &notice_proc)
      when 2
        instance_exec(result.invitation, user, &notice_proc)
      else
        instance_exec(result, result.invitation, user, &notice_proc)
      end
    rescue StandardError => e
      if defined?(Rails) && Rails.respond_to?(:env) && (Rails.env.development? || Rails.env.test?)
        raise
      end
      if defined?(Rails) && Rails.respond_to?(:logger)
        Rails.logger.error "[Organizations] Invitation notice proc failed: #{e.message}"
      end
      default_pending_invitation_acceptance_notice(result.invitation)
    end

    # Session key for pending invitation token
    # @return [Symbol]
    def pending_invitation_session_key
      :organizations_pending_invitation_token
    end

    # Resolve a redirect path from config value (nil, String, or Proc)
    # @param config_value [nil, String, Proc] The configured value
    # @param args [Array] Optional proc arguments
    # @param default [Proc] Lambda returning default path
    # @return [String]
    def resolve_controller_redirect_path(config_value, *args, default:)
      return default.call if config_value.nil?
      return config_value if config_value.is_a?(String)
      return default.call unless config_value.is_a?(Proc)

      begin
        case config_value.arity
        when 0
          instance_exec(&config_value)
        when 1
          instance_exec(args[0], &config_value)
        when 2
          instance_exec(args[0], args[1], &config_value)
        else
          exec_args = config_value.arity.negative? ? args : args.first(config_value.arity)
          instance_exec(*exec_args, &config_value)
        end
      rescue StandardError => e
        # Re-raise in dev/test to surface misconfigurations; fall back in production
        if defined?(Rails) && Rails.respond_to?(:env) && (Rails.env.development? || Rails.env.test?)
          raise
        end
        if defined?(Rails) && Rails.respond_to?(:logger)
          Rails.logger.error "[Organizations] Redirect path proc failed: #{e.message}"
        end
        default.call
      end
    end

    # Default path when invitation requires authentication
    # @return [String]
    def default_auth_required_redirect_path
      if main_app.respond_to?(:new_user_registration_path)
        main_app.new_user_registration_path
      elsif main_app.respond_to?(:root_path)
        main_app.root_path
      else
        "/"
      end
    end

    # Default path after invitation acceptance
    # @return [String]
    def default_after_accept_redirect_path
      if main_app.respond_to?(:root_path)
        main_app.root_path
      else
        "/"
      end
    end

    # Default path after organization switch
    # @return [String]
    def default_after_switch_redirect_path
      if main_app.respond_to?(:root_path)
        main_app.root_path
      else
        "/"
      end
    end

    def default_pending_invitation_acceptance_notice(invitation)
      "Welcome to #{invitation.organization.name}!"
    end
  end
end
