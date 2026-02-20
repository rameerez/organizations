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

    included do
      # Make helpers available in views
      if respond_to?(:helper_method)
        helper_method :current_organization
        helper_method :current_membership
        helper_method :organization_signed_in?
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

    # Get the current user using the configured method
    # NOTE: This method safely calls the host app's current_user method
    # @param refresh [Boolean] Force re-resolution (clears cached value)
    # @return [User, nil]
    #
    # Nil values are intentionally not cached to handle auth-transition flows where
    # user state changes mid-request (e.g., sign_in during invitation acceptance).
    # This is safe because Devise memoizes current_user at the Warden level.
    def organizations_current_user(refresh: false)
      # Clear cache if refresh requested
      remove_instance_variable(:@_organizations_current_user) if refresh && defined?(@_organizations_current_user)

      # Return cached value only if non-nil (avoid sticky nil memoization)
      if defined?(@_organizations_current_user) && !@_organizations_current_user.nil?
        return @_organizations_current_user
      end

      method_name = Organizations.configuration.current_user_method

      # The configured method should exist on the host controller
      # (e.g., Devise's current_user). We call it directly.
      @_organizations_current_user = if respond_to?(method_name, true)
                                       send(method_name)
                                     end
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
          path = config.redirect_path_when_no_organization
          redirect_to path, alert: "Please select or create an organization."
        end
        format.json { render json: { error: "Organization required" }, status: :forbidden }
      end
    end
  end
end
