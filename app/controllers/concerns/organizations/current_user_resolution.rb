# frozen_string_literal: true

module Organizations
  # Shared logic for resolving the current user across engine controllers.
  # Provides a Warden fallback that works regardless of controller inheritance.
  module CurrentUserResolution
    extend ActiveSupport::Concern

    private

    # Get the current user via Warden/Devise middleware directly.
    # Uses warden.user (read-only) instead of warden.authenticate to avoid
    # triggering authentication strategies unnecessarily.
    # Works from any controller regardless of inheritance chain.
    # @return [User, nil]
    def warden_user
      return nil unless respond_to?(:warden, true)

      scope = defined?(Devise) ? Devise.default_scope : :user
      warden.user(scope)
    end

    # Resolve custom auth method (Rodauth, Sorcery, etc.)
    # @return [User, nil]
    def resolve_custom_auth_user
      user_method = Organizations.configuration.current_user_method
      return nil unless user_method && user_method != :current_user
      return nil unless respond_to?(user_method, true)

      send(user_method)
    end
  end
end
