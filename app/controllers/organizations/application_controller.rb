# frozen_string_literal: true

module Organizations
  # Base controller for the Organizations engine.
  # Inherits from the host application's configured controller
  # (defaults to ::ApplicationController).
  #
  # All engine controllers inherit from this class and get:
  # - Authentication via configured method
  # - Organization context helpers (via ControllerHelpers)
  # - Permission guards (via ControllerHelpers)
  #
  class ApplicationController < (Organizations.configuration.parent_controller.constantize rescue ::ApplicationController)
    # Include ControllerHelpers for organization context and permission guards
    # This provides: current_organization, current_membership, organization_signed_in?,
    # switch_to_organization!, require_organization!, require_organization_admin!, etc.
    include Organizations::ControllerHelpers

    # Protect from forgery if the parent controller does
    protect_from_forgery with: :exception if respond_to?(:protect_from_forgery)

    # Ensure user is authenticated for all actions
    before_action :authenticate_organizations_user!

    # Expose current_user to views (ControllerHelpers exposes org-related helpers)
    helper_method :current_user

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
  end
end
