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
    include Organizations::CurrentUserResolution

    # Protect from forgery if available
    protect_from_forgery with: :exception if respond_to?(:protect_from_forgery)

    if respond_to?(:layout)
      # Resolve layout at request-time so runtime config changes are respected.
      layout :organizations_public_layout
    end

    # Include main app route helpers so host app layouts work correctly
    # (e.g., root_path, pricing_path in navbar partials)
    include Rails.application.routes.url_helpers if defined?(Rails.application.routes.url_helpers)
    helper Rails.application.routes.url_helpers if respond_to?(:helper)

    # Minimal helpers needed for public routes
    helper_method :current_user if respond_to?(:helper_method)

    private

    # Returns the current user from the host application (if any).
    # Uses the configured method name (defaults to :current_user)
    #
    # NOTE: Nil values are intentionally not cached to handle auth-transition flows
    # where user state changes mid-request (e.g., sign_in during invitation acceptance).
    def current_user
      resolve_organizations_current_user(
        cache_ivar: :@_current_user,
        cache_nil: false,
        prefer_super_for_current_user: true
      )
    end

    def organizations_public_layout
      configured_layout = Organizations.configuration.public_controller_layout
      return nil if configured_layout.nil?
      return configured_layout unless configured_layout.is_a?(Symbol)

      send(configured_layout)
    end

    # Access main_app routes from engine views
    def main_app
      Rails.application.routes.url_helpers
    end
    helper_method :main_app if respond_to?(:helper_method)
  end
end
