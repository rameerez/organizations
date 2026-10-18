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

    # One published roles configuration (see Roles.snapshot).
    Snapshot = Struct.new(:definition, :hierarchy, :permissions, :permission_sets)

    class << self
      # Get the default permission structure
      # @return [Hash<Symbol, Array<Symbol>>]
      def default
        DEFAULT_PERMISSIONS
      end

      # Get the role hierarchy
      # @return [Array<Symbol>]
      def hierarchy
        snapshot.hierarchy
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

        order = hierarchy # one snapshot for both lookups
        idx_a = order.index(role_a.to_sym)
        idx_b = order.index(role_b.to_sym)

        return false unless idx_a && idx_b

        # Lower index = higher rank (owner is index 0)
        idx_a <= idx_b
      end

      # Compare two roles
      # @param role_a [Symbol, String] First role
      # @param role_b [Symbol, String] Second role
      # @return [Integer] -1 if a > b, 0 if equal, 1 if a < b
      def compare(role_a, role_b)
        # A role that is no longer configured ranks below every configured role.
        order = hierarchy # one snapshot for both lookups
        idx_a = order.index(role_a.to_sym) || order.length
        idx_b = order.index(role_b.to_sym) || order.length

        return 0 if idx_a == idx_b

        idx_a < idx_b ? -1 : 1
      end

      # Check if an account holding actor_role may act on role: give it to a
      # member, take it away, remove a member who holds it, or invite to it.
      # See assignment_refusal for the rule.
      # @param actor_role [Symbol, String] The role of the account making the change
      # @param role [Symbol, String] The role being acted on
      # @return [Boolean]
      #
      # @example
      #   Roles.can_assign?(:admin, :admin)  # => true (same rank)
      #   Roles.can_assign?(:admin, :member) # => true
      #   Roles.can_assign?(:member, :admin) # => false (admin ranks above member)
      #
      def can_assign?(actor_role, role) = assignment_refusal(actor_role, role).nil?

      # Why an account holding actor_role may not act on role, or nil when it
      # may. A role acts only on roles at or below its own rank, so a custom
      # role that can edit member roles still cannot create or demote an
      # admin. Rank alone is not enough below admin: two custom roles with the
      # same parent are ranked by definition order, so a role below admin may
      # also act only on roles whose permissions it holds itself. Admins and
      # the owner keep the rank rule alone, as before. A role that is no
      # longer configured ranks below every configured role and has no
      # permissions; an actor whose own role is no longer configured may act
      # on nothing. The owner role keeps its own rules on top of this: it
      # moves only through transfer_ownership_to!.
      # @param actor_role [Symbol, String] The role of the account making the change
      # @param role [Symbol, String] The role being acted on
      # @return [nil, :outranks, :lacks_permissions]
      #
      # @example
      #   Roles.assignment_refusal(:member, :admin)  # => :outranks
      #   Roles.assignment_refusal(:lead, :finance)  # => :lacks_permissions (a sibling with other powers)
      #   Roles.assignment_refusal(:lead, :member)   # => nil
      #
      def assignment_refusal(actor_role, role)
        return :outranks if actor_role.nil? || role.nil?

        current = snapshot # one snapshot for the ranks and the permissions
        actor_role = actor_role.to_sym
        role = role.to_sym
        return :outranks unless ranks_at_or_above?(current.hierarchy, actor_role, role)
        return nil if ranks_at_or_above?(current.hierarchy, actor_role, :admin)

        holds_permissions_of?(current.permission_sets, actor_role, role) ? nil : :lacks_permissions
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
        snapshot.permissions
      end

      # Get the pre-computed permission sets (for O(1) lookups)
      # @return [Hash<Symbol, Set<Symbol>>]
      def permission_sets
        snapshot.permission_sets
      end

      # Reset computed permissions (used when custom roles are defined)
      def reset!
        @snapshot = nil
      end

      # Get the next role up in hierarchy
      # @param role [Symbol, String] Current role
      # @return [Symbol, nil] Next higher role or nil if already highest
      def higher_role(role)
        return nil if role.nil?

        order = hierarchy # one snapshot for the lookup and the result
        idx = order.index(role.to_sym)
        return nil unless idx && idx > 0

        order[idx - 1]
      end

      # Get the next role down in hierarchy
      # @param role [Symbol, String] Current role
      # @return [Symbol, nil] Next lower role or nil if already lowest
      def lower_role(role)
        return nil if role.nil?

        order = hierarchy # one snapshot for the lookup and the result
        idx = order.index(role.to_sym)
        return nil unless idx && idx < order.length - 1

        order[idx + 1]
      end

      # The role hierarchy (highest first) of a roles definition: the four
      # built-in roles, and each custom role directly above the role it
      # inherits from (a custom role without `inherits:` sits at the bottom).
      def hierarchy_for(definition)
        return HIERARCHY unless definition

        builder = RoleBuilder.new
        builder.instance_eval(&definition)
        builder.validate_privileges!
        builder.hierarchy
      end

      private

      # A role missing from order ranks below every configured role; an actor
      # missing from it ranks at or above nothing.
      def ranks_at_or_above?(order, actor_role, role)
        actor_rank = order.index(actor_role)
        !actor_rank.nil? && actor_rank <= (order.index(role) || order.length)
      end

      def holds_permissions_of?(sets, actor_role, role) = (sets[role] || Set.new).subset?(sets[actor_role] || Set.new)

      # The hierarchy and permissions of one roles definition, computed
      # together and published as one immutable value. It belongs to the
      # definition object it was built from: after a reconfiguration (or a
      # rolled-back one) the next reader sees the identity change and builds a
      # new snapshot, so a reader that raced a reset can never keep an
      # obsolete hierarchy in place.
      def snapshot
        definition = Organizations.configuration&.custom_roles_definition
        current = @snapshot
        return current if current && current.definition.equal?(definition)

        @snapshot = build_snapshot(definition)
      end

      def build_snapshot(definition)
        if definition
          builder = RoleBuilder.new
          builder.instance_eval(&definition)
          builder.validate_privileges!
          hierarchy = builder.hierarchy
          permissions = builder.to_permissions
        else
          hierarchy = HIERARCHY
          permissions = DEFAULT_PERMISSIONS
        end
        sets = permissions.transform_values { |perms| Set.new(perms).freeze }.freeze
        Snapshot.new(definition, hierarchy, permissions, sets).freeze
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
        # Process roles in reverse hierarchy order (lowest first)
        # so inheritance works correctly
        hierarchy.reverse_each.with_object({}) do |role_name, result|
          perms = @roles.key?(role_name) ? defined_permissions(role_name, result) : omitted_permissions(role_name)
          result[role_name] = perms.freeze if perms
        end.freeze
      end

      # An admin can assign a custom role, so a custom role may not grant a
      # permission that the owner role has and the admin role lacks (for
      # example manage_billing or transfer_ownership). Otherwise an admin
      # could give another account a power that the admin does not have.
      def validate_privileges!
        validate_built_in_parents!
        permissions = to_permissions
        owner_only = (permissions[:owner] || DEFAULT_PERMISSIONS[:owner]) -
                     (permissions[:admin] || DEFAULT_PERMISSIONS[:admin])
        custom_roles.each do |name|
          granted = @roles[name][:permissions] & owner_only
          next if granted.empty?

          raise ConfigurationError, "Custom role #{name} cannot grant #{granted.join(', ')}: " \
                                    "admins can assign it, and only the owner has that permission"
        end
      end

      private

      # A built-in role may inherit a custom role only when that custom role
      # ranks below it; otherwise the inheritance would be dropped silently.
      def validate_built_in_parents!
        order = hierarchy
        (@roles.keys & Roles::HIERARCHY).each do |name|
          parent = @roles[name][:inherits]
          next unless parent && custom_roles.include?(parent)
          next if order.index(parent) > order.index(name)

          raise ConfigurationError, "Role #{name} cannot inherit from #{parent}: #{parent} ranks above #{name}"
        end
      end

      def custom_roles = @roles.keys - Roles::HIERARCHY

      # A role's own permissions plus its parent's. A custom role that inherits
      # a built-in role the block does not redefine inherits its defaults.
      def defined_permissions(role_name, result)
        role_def = @roles[role_name]
        parent = role_def[:inherits]
        inherited = parent && (result[parent] || (custom_roles.include?(role_name) && DEFAULT_PERMISSIONS[parent]))
        inherited ? (inherited + role_def[:permissions]).uniq : role_def[:permissions].dup
      end

      # A block that only adds custom roles keeps the built-in roles' defaults.
      # An empty block still defines no permissions, as before custom roles.
      def omitted_permissions(role_name) = custom_only? ? DEFAULT_PERMISSIONS[role_name] : nil
      def custom_only? = custom_roles.any? && !@roles.keys.intersect?(Roles::HIERARCHY)

      # A custom role needs a plain name, and a parent that already exists (a
      # built-in role below admin or a custom role defined above it). Nothing
      # inherits admin or owner.
      def validate_role_definition!(name, inherits)
        unless name.to_s.match?(/\A[a-z][a-z0-9_]{0,31}\z/)
          raise ConfigurationError, "Role name #{name.inspect} must be lowercase letters, digits and underscores"
        end
        return if Roles::HIERARCHY.include?(name)
        raise ConfigurationError, "Role #{name} is defined twice" if @roles.key?(name)
        # A custom role ranks below admin, so it never outranks the people who can assign it.
        if %i[owner admin].include?(inherits)
          raise ConfigurationError, "Custom role #{name} cannot inherit from #{inherits}: a custom role ranks below admin"
        end
        return if inherits.nil? || %i[member viewer].include?(inherits) || @roles.key?(inherits)

        raise ConfigurationError, "Custom role #{name} inherits from #{inherits}, which is not defined above it"
      end
    end
  end
end
