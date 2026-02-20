# frozen_string_literal: true

module Organizations
  # Base controller for public routes that don't require authentication.
  # Inherits from the configured public_controller (defaults to ActionController::Base)
  # to avoid inheriting host app filters that might enforce authentication.
  #
  # Use cases:
  # - Invitation acceptance pages (users clicking email links)
  # - Any other routes that should work for unauthenticated users
  #
  class PublicController < (Organizations.configuration.public_controller.constantize rescue ActionController::Base)
    include CurrentUserResolution

    # Protect from forgery if available
    protect_from_forgery with: :exception if respond_to?(:protect_from_forgery)

    # Include main app route helpers so host app layouts work correctly
    # (e.g., root_path, pricing_path in navbar partials)
    include Rails.application.routes.url_helpers if defined?(Rails.application.routes.url_helpers)
    helper Rails.application.routes.url_helpers if respond_to?(:helper)

    # Minimal helpers needed for public routes
    helper_method :current_user if respond_to?(:helper_method)

    private

    # Returns the current user from the host application (if any).
    #
    # Resolution order:
    # 1. Custom method (if configured to something other than :current_user)
    # 2. Warden/Devise (works regardless of controller inheritance)
    # 3. Parent class method (if available)
    #
    # NOTE: Nil values are intentionally not cached to handle auth-transition flows
    # where user state changes mid-request (e.g., sign_in during invitation acceptance).
    def current_user
      # Return cached value only if non-nil (avoid sticky nil memoization)
      return @_current_user if defined?(@_current_user) && !@_current_user.nil?

      # Warden first (parent is ActionController::Base which has no current_user)
      @_current_user = resolve_custom_auth_user ||
                       warden_user ||
                       (super rescue nil)
    end

    # Access main_app routes from engine views
    def main_app
      Rails.application.routes.url_helpers
    end
    helper_method :main_app if respond_to?(:helper_method)
  end
end
