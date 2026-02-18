# frozen_string_literal: true

module Organizations
  # Base controller for the Organizations engine.
  # Inherits from the host application's configured controller
  # (defaults to ::ApplicationController).
  class ApplicationController < ::ApplicationController
    # Protect from forgery if the parent controller does
    protect_from_forgery with: :exception if respond_to?(:protect_from_forgery)

    # Ensure user is authenticated for all actions
    before_action :authenticate_organizations_user!

    # Expose helpers
    helper_method :current_organizations_user
    helper_method :current_organization

    private

    # Authenticates the user accessing the engine.
    # Uses the configured authentication method from Organizations.configuration
    def authenticate_organizations_user!
      auth_method = Organizations.configuration.authenticate_user_method

      if auth_method && respond_to?(auth_method, true)
        send(auth_method)
      else
        unless current_organizations_user
          redirect_to main_app.root_path, alert: "You need to sign in before continuing."
        rescue StandardError
          render plain: "Unauthorized", status: :unauthorized
        end
      end
    end

    # Returns the current user from the host application.
    # Uses the configured method name (defaults to :current_user)
    def current_organizations_user
      user_method = Organizations.configuration.current_user_method

      if user_method && respond_to?(user_method, true)
        send(user_method)
      else
        nil
      end
    end

    # Returns the current organization from the session
    def current_organization
      return @current_organization if defined?(@current_organization)

      session_key = Organizations.configuration.session_key
      org_id = session[session_key]
      return nil unless org_id

      @current_organization = current_organizations_user&.organizations&.find_by(id: org_id)
    end

    # Sets the current organization in session
    def current_organization=(org)
      session_key = Organizations.configuration.session_key

      if org
        session[session_key] = org.id
        @current_organization = org
      else
        session.delete(session_key)
        @current_organization = nil
      end
    end

    # Switches to a different organization
    def switch_to_organization!(org)
      unless current_organizations_user.is_member_of?(org)
        raise Organizations::NotAMember.new(
          "You are not a member of this organization",
          organization: org,
          user: current_organizations_user
        )
      end

      self.current_organization = org
    end

    # Requires a current organization to be set
    def require_organization!
      return if current_organization

      redirect_to main_app.root_path, alert: "Please select an organization."
    rescue StandardError
      render plain: "Organization required", status: :forbidden
    end

    # Requires the user to be an admin of the current organization
    def require_organization_admin!
      require_organization!
      return unless current_organization

      unless current_organizations_user.is_admin_of?(current_organization)
        raise Organizations::NotAuthorized.new(
          "You need admin access to perform this action",
          permission: :admin,
          organization: current_organization,
          user: current_organizations_user
        )
      end
    end

    # Requires the user to be the owner of the current organization
    def require_organization_owner!
      require_organization!
      return unless current_organization

      unless current_organizations_user.is_owner_of?(current_organization)
        raise Organizations::NotAuthorized.new(
          "You need owner access to perform this action",
          permission: :owner,
          organization: current_organization,
          user: current_organizations_user
        )
      end
    end

    # Requires the user to have a specific permission in the current organization
    def require_organization_permission!(permission)
      require_organization!
      return unless current_organization

      unless current_organizations_user.has_organization_permission_to?(permission)
        raise Organizations::NotAuthorized.new(
          "You don't have permission to #{permission.to_s.humanize.downcase}",
          permission: permission,
          organization: current_organization,
          user: current_organizations_user
        )
      end
    end
  end
end
