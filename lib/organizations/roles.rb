# frozen_string_literal: true

module Organizations
  # Roles and permissions management module.
  # Provides hierarchical roles with inherited permissions.
  #
  # The role hierarchy is: owner > admin > member > viewer
  # Each role inherits all permissions from roles below it.
  #
  # Permission lookups are O(1) using pre-computed permission sets.
  #
  module Roles
    # Role hierarchy from highest to lowest
    HIERARCHY = %i[owner admin member viewer].freeze

    # Default permissions for each role.
    # Matches the permission table in the README.
    DEFAULT_PERMISSIONS = {
      viewer: %i[
        view_organization
        view_members
      ].freeze,
      member: %i[
        view_organization
        view_members
        create_resources
        edit_own_resources
        delete_own_resources
      ].freeze,
      admin: %i[
        view_organization
        view_members
        create_resources
        edit_own_resources
        delete_own_resources
        invite_members
        remove_members
        edit_member_roles
        manage_settings
        view_billing
      ].freeze,
      owner: %i[
        view_organization
        view_members
        create_resources
        edit_own_resources
        delete_own_resources
        invite_members
        remove_members
        edit_member_roles
        manage_settings
        view_billing
        manage_billing
        transfer_ownership
        delete_organization
      ].freeze
    }.freeze

    class << self
      # Get the default permission structure
      # @return [Hash<Symbol, Array<Symbol>>]
      def default
        DEFAULT_PERMISSIONS
      end

      # Get the role hierarchy
      # @return [Array<Symbol>]
      def hierarchy
        @hierarchy ||= hierarchy_for(Organizations.configuration&.custom_roles_definition)
      end

      # Get all valid role names
      # @return [Array<Symbol>]
      def valid_roles
        hierarchy
      end

      # Check if a role is valid
      # @param role [Symbol, String] The role to check
      # @return [Boolean]
      def valid_role?(role)
        return false if role.nil?

        hierarchy.include?(role.to_sym)
      end

      # Check if role_a is at least as high as role_b in hierarchy
      # @param role_a [Symbol, String] The role to check
      # @param role_b [Symbol, String] The minimum required role
      # @return [Boolean]
      #
      # @example
      #   Roles.at_least?(:owner, :admin)  # => true (owner >= admin)
      #   Roles.at_least?(:member, :admin) # => false (member < admin)
      #
      def at_least?(role_a, role_b)
        return false if role_a.nil? || role_b.nil?

        idx_a = hierarchy.index(role_a.to_sym)
        idx_b = hierarchy.index(role_b.to_sym)

        return false unless idx_a && idx_b

        # Lower index = higher rank (owner is index 0)
        idx_a <= idx_b
      end

      # Compare two roles
      # @param role_a [Symbol, String] First role
      # @param role_b [Symbol, String] Second role
      # @return [Integer] -1 if a > b, 0 if equal, 1 if a < b
      def compare(role_a, role_b)
        idx_a = hierarchy.index(role_a.to_sym)
        idx_b = hierarchy.index(role_b.to_sym)

        return 0 if idx_a == idx_b

        idx_a < idx_b ? -1 : 1
      end

      # Get all permissions for a role (pre-computed, O(1) lookup)
      # @param role [Symbol, String] The role
      # @return [Array<Symbol>] All permissions for the role
      def permissions_for(role)
        return [] if role.nil?

        role_sym = role.to_sym
        permissions[role_sym] || []
      end

      # Check if a role has a specific permission (O(1) lookup)
      # @param role [Symbol, String] The role
      # @param permission [Symbol, String] The permission to check
      # @return [Boolean]
      #
      # @example
      #   Roles.has_permission?(:admin, :invite_members) # => true
      #   Roles.has_permission?(:member, :invite_members) # => false
      #
      def has_permission?(role, permission)
        return false if role.nil? || permission.nil?

        permission_sets[role.to_sym]&.include?(permission.to_sym) || false
      end

      # Get the pre-computed permission hash (for direct access)
      # @return [Hash<Symbol, Array<Symbol>>]
      def permissions
        @permissions ||= compute_permissions
      end

      # Get the pre-computed permission sets (for O(1) lookups)
      # @return [Hash<Symbol, Set<Symbol>>]
      def permission_sets
        @permission_sets ||= permissions.transform_values { |perms| Set.new(perms) }
      end

      # Reset computed permissions (used when custom roles are defined)
      def reset!
        @permissions = nil
        @permission_sets = nil
        @hierarchy = nil
      end

      # Get the next role up in hierarchy
      # @param role [Symbol, String] Current role
      # @return [Symbol, nil] Next higher role or nil if already highest
      def higher_role(role)
        return nil if role.nil?

        idx = hierarchy.index(role.to_sym)
        return nil unless idx && idx > 0

        hierarchy[idx - 1]
      end

      # Get the next role down in hierarchy
      # @param role [Symbol, String] Current role
      # @return [Symbol, nil] Next lower role or nil if already lowest
      def lower_role(role)
        return nil if role.nil?

        idx = hierarchy.index(role.to_sym)
        return nil unless idx && idx < hierarchy.length - 1

        hierarchy[idx + 1]
      end

      # The role hierarchy (highest first) of a roles definition: the four
      # built-in roles, and each custom role directly above the role it
      # inherits from (a custom role without `inherits:` sits at the bottom).
      def hierarchy_for(definition)
        return HIERARCHY unless definition

        builder = RoleBuilder.new
        builder.instance_eval(&definition)
        builder.hierarchy
      end

      private

      def compute_permissions
        # Use custom roles if defined, otherwise use defaults
        custom_def = Organizations.configuration&.custom_roles_definition
        return DEFAULT_PERMISSIONS.dup unless custom_def

        # Build custom permissions using DSL
        builder = RoleBuilder.new
        builder.instance_eval(&custom_def)
        builder.to_permissions
      end
    end

    # DSL builder for custom role definitions
    class RoleBuilder
      def initialize
        @roles = {}
        @current_role = nil
      end

      # Define a role with optional inheritance
      # @param name [Symbol] Role name
      # @param inherits [Symbol, nil] Role to inherit from
      # @yield Block to define permissions
      def role(name, inherits: nil, &block)
        name = name.to_sym
        inherits = inherits&.to_sym
        validate_role_definition!(name, inherits)

        @roles[name] = {
          inherits: inherits,
          permissions: []
        }
        @current_role = name
        instance_eval(&block) if block_given?
        @current_role = nil
      end

      # Add a permission to the current role
      # @param permission [Symbol] Permission to add
      def can(permission)
        raise "can must be called within a role block" unless @current_role

        @roles[@current_role][:permissions] << permission.to_sym
      end

      # The hierarchy, highest first: the built-in roles in their fixed order,
      # and each custom role inserted directly above the role it inherits from.
      # @return [Array<Symbol>]
      def hierarchy
        order = Roles::HIERARCHY.dup
        custom_roles.each do |name|
          parent = @roles[name][:inherits]
          parent ? order.insert(order.index(parent), name) : order << name
        end
        order.freeze
      end

      # Build final permissions hash with inheritance resolved
      # @return [Hash<Symbol, Array<Symbol>>]
      def to_permissions
        result = {}

        # Process roles in reverse hierarchy order (lowest first)
        # so inheritance works correctly
        hierarchy.reverse_each do |role_name|
          next unless @roles.key?(role_name)

          role_def = @roles[role_name]
          perms = role_def[:permissions].dup

          # Add inherited permissions. A custom role that inherits a built-in
          # role the block does not redefine inherits its default permissions.
          parent = role_def[:inherits]
          inherited = result[parent] || (custom_roles.include?(role_name) && DEFAULT_PERMISSIONS[parent])
          perms = (inherited + perms).uniq if parent && inherited

          result[role_name] = perms.freeze
        end

        result.freeze
      end

      private

      def custom_roles = @roles.keys - Roles::HIERARCHY

      # A custom role needs a plain name, and a parent that already exists (a
      # built-in role or a custom role defined above it). Nothing inherits the
      # owner: the owner stays the single top of every organization.
      def validate_role_definition!(name, inherits)
        unless name.to_s.match?(/\A[a-z][a-z0-9_]{0,31}\z/)
          raise ConfigurationError, "Role name #{name.inspect} must be lowercase letters, digits and underscores"
        end
        return if Roles::HIERARCHY.include?(name)
        raise ConfigurationError, "Role #{name} is defined twice" if @roles.key?(name)
        raise ConfigurationError, "Custom role #{name} cannot inherit from owner" if inherits == :owner
        return if inherits.nil? || Roles::HIERARCHY.include?(inherits) || @roles.key?(inherits)

        raise ConfigurationError, "Custom role #{name} inherits from #{inherits}, which is not defined above it"
      end
    end
  end
end
