# frozen_string_literal: true

module Organizations
  module CurrentUserResolution
    private

    # Resolve current user for organizations integration with configurable caching behavior.
    #
    # @param cache_ivar [Symbol] Instance variable used for memoization (e.g. :@_current_user)
    # @param refresh [Boolean] Clear memoized value before resolving
    # @param cache_nil [Boolean] Whether nil values should be memoized
    # @param prefer_super_for_current_user [Boolean]
    #   When true and configured method is :current_user, call super instead of send(:current_user)
    #
    # @return [Object, nil] Resolved current user object
    def resolve_organizations_current_user(
      cache_ivar:,
      refresh: false,
      cache_nil: false,
      prefer_super_for_current_user: false
    )
      remove_instance_variable(cache_ivar) if refresh && instance_variable_defined?(cache_ivar)

      if instance_variable_defined?(cache_ivar)
        cached = instance_variable_get(cache_ivar)
        return cached if cache_nil || !cached.nil?
      end

      method_name = Organizations.configuration.current_user_method

      resolved_user = if prefer_super_for_current_user && method_name == :current_user
                        safe_super_current_user
                      elsif method_name && respond_to?(method_name, true)
                        send(method_name)
                      elsif prefer_super_for_current_user
                        safe_super_current_user
                      end

      instance_variable_set(cache_ivar, resolved_user) if cache_nil || !resolved_user.nil?
      resolved_user
    end

    def safe_super_current_user
      super_method = method(:current_user).super_method
      return nil unless super_method

      super_method.call
    rescue NoMethodError, NameError
      nil
    end
  end
end
