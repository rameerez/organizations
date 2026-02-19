# frozen_string_literal: true

module Organizations
  # Base controller for the Organizations engine.
  # Inherits from the host application's configured controller
  # (defaults to ::ApplicationController).
  #
  # All engine controllers inherit from this class and get:
  # - Authentication via configured method
  # - Organization context helpers
  # - Permission guards
  #
  class ApplicationController < (Organizations.configuration.parent_controller.constantize rescue ::ApplicationController)
    # Protect from forgery if the parent controller does
    protect_from_forgery with: :exception if respond_to?(:protect_from_forgery)

    # Ensure user is authenticated for all actions
    before_action :authenticate_organizations_user!

    # Expose helpers to views
    helper_method :current_user
    helper_method :current_organization
    helper_method :current_membership
    helper_method :organization_signed_in?

    private

    # === Authentication ===

    # Authenticates the user accessing the engine.
    # Uses the configured authentication method from Organizations.configuration
    def authenticate_organizations_user!
      auth_method = Organizations.configuration.authenticate_user_method

      if auth_method && respond_to?(auth_method, true)
        send(auth_method)
      else
        unless current_user
          respond_to do |format|
            format.html { redirect_to main_app.root_path, alert: "You need to sign in before continuing." }
            format.json { render json: { error: "Unauthorized" }, status: :unauthorized }
          end
        end
      end
    end

    # === User Context ===

    # Returns the current user from the host application.
    # Uses the configured method name (defaults to :current_user)
    # NOTE: We call the PARENT class method to avoid infinite recursion
    def current_user
      return @_current_user if defined?(@_current_user)

      user_method = Organizations.configuration.current_user_method

      # Avoid infinite recursion: if configured method is :current_user,
      # call the parent implementation, not this method
      @_current_user = if user_method == :current_user
                         super rescue nil
                       elsif user_method && respond_to?(user_method, true)
                         send(user_method)
                       end
    end

    # Alias for compatibility
    alias_method :current_organizations_user, :current_user

    # === Organization Context ===

    # Returns the current organization from the session
    # Validates membership - if user was removed, auto-switches to next available org
    # Falls back to most recently joined org if no session set
    def current_organization
      return @_current_organization if defined?(@_current_organization)
      return @_current_organization = nil unless current_user

      session_key = Organizations.configuration.session_key
      org_id = session[session_key]

      org = org_id ? Organization.find_by(id: org_id) : nil

      if org && current_user.is_member_of?(org)
        # Valid membership - use this org
        current_user._current_organization_id = org.id
        @_current_organization = org
      else
        # User was removed from this org OR no session set
        # Auto-switch to next available org (most recently joined)
        clear_organization_session!

        fallback_org = fallback_organization_for(current_user)
        if fallback_org
          session[session_key] = fallback_org.id
          current_user._current_organization_id = fallback_org.id
          @_current_organization = fallback_org
        else
          @_current_organization = nil
        end
      end
    end

    # Returns the current user's membership in the current organization
    def current_membership
      return @_current_membership if defined?(@_current_membership)
      return @_current_membership = nil unless current_user && current_organization

      @_current_membership = current_user.memberships.find_by(organization_id: current_organization.id)
    end

    # Check if there's an active organization
    def organization_signed_in?
      current_organization.present?
    end

    # Sets the current organization in session
    def current_organization=(org)
      session_key = Organizations.configuration.session_key

      if org
        session[session_key] = org.id
        @_current_organization = org
        @_current_membership = nil
        current_user&._current_organization_id = org.id
      else
        clear_organization_session!
      end
    end

    # Switches to a different organization
    def switch_to_organization!(org)
      unless current_user&.is_member_of?(org)
        raise Organizations::NotAMember.new(
          "You are not a member of this organization",
          organization: org,
          user: current_user
        )
      end

      self.current_organization = org
      mark_membership_as_recent!(current_user, org)
    end

    # Clear organization session and cached values
    def clear_organization_session!
      session_key = Organizations.configuration.session_key
      session.delete(session_key)
      @_current_organization = nil
      @_current_membership = nil
      current_user&.clear_organization_cache!
    end

    # === Permission Guards ===

    # Requires a current organization to be set
    def require_organization!
      return if current_organization

      config = Organizations.configuration

      if config.no_organization_handler
        context = CallbackContext.new(event: :no_organization, user: current_user)
        instance_exec(context, &config.no_organization_handler)
      else
        respond_to do |format|
          format.html { redirect_to config.no_organization_path, alert: "Please select or create an organization." }
          format.json { render json: { error: "Organization required" }, status: :forbidden }
        end
      end
    end

    # Requires the user to have at least the specified role
    def require_organization_role!(role)
      require_organization!
      return unless current_organization

      return if current_user&.is_at_least?(role, in: current_organization)

      handle_unauthorized(required_role: role)
    end

    # Requires the user to have a specific permission
    def require_organization_permission_to!(permission)
      require_organization!
      return unless current_organization

      return if current_user&.has_organization_permission_to?(permission)

      handle_unauthorized(permission: permission)
    end

    # Requires the user to be an admin of the current organization
    def require_organization_admin!
      require_organization_role!(:admin)
    end

    # Requires the user to be the owner of the current organization
    def require_organization_owner!
      require_organization_role!(:owner)
    end

    # Handle unauthorized access
    def handle_unauthorized(permission: nil, required_role: nil)
      config = Organizations.configuration

      if config.unauthorized_handler
        context = CallbackContext.new(
          event: :unauthorized,
          user: current_user,
          organization: current_organization,
          permission: permission,
          required_role: required_role
        )
        instance_exec(context, &config.unauthorized_handler)
      else
        error = Organizations::NotAuthorized.new(
          build_unauthorized_message(permission, required_role),
          permission: permission || required_role,
          organization: current_organization,
          user: current_user
        )

        respond_to do |format|
          format.html { redirect_back fallback_location: main_app.root_path, alert: error.message }
          format.json { render json: { error: error.message }, status: :forbidden }
        end
      end
    end

    def fallback_organization_for(user)
      membership = user.memberships.includes(:organization).order(updated_at: :desc, created_at: :desc).first
      membership&.organization
    end

    def mark_membership_as_recent!(user, org)
      return unless user && org

      user.memberships.where(organization_id: org.id).update_all(updated_at: Time.current)
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
  end
end
