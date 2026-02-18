# frozen_string_literal: true

module Organizations
  module Roles
    HIERARCHY = %i[owner admin member viewer].freeze

    # Default role permissions
    # Higher roles inherit all permissions from lower roles
    PERMISSIONS = {
      owner: %i[
        delete_organization
        transfer_ownership
        manage_billing
        manage_roles
        invite_members
        remove_members
        manage_settings
        view_members
        view_settings
      ],
      admin: %i[
        manage_roles
        invite_members
        remove_members
        manage_settings
        view_members
        view_settings
      ],
      member: %i[
        view_members
        view_settings
      ],
      viewer: %i[
        view_members
      ]
    }.freeze

    class << self
      def default
        PERMISSIONS
      end

      def hierarchy
        HIERARCHY
      end

      # Check if role_a >= role_b in hierarchy
      def at_least?(role_a, role_b)
        HIERARCHY.index(role_a.to_sym) <= HIERARCHY.index(role_b.to_sym)
      end

      # Get all permissions for a role (including inherited)
      def permissions_for(role)
        role_sym = role.to_sym
        idx = HIERARCHY.index(role_sym)
        return [] unless idx

        # Collect permissions from this role and all lower roles
        HIERARCHY[idx..].flat_map { |r| PERMISSIONS[r] || [] }.uniq
      end

      # Check if role has permission
      def has_permission?(role, permission)
        permissions_for(role).include?(permission.to_sym)
      end
    end
  end
end
