# frozen_string_literal: true

module Organizations
  # What a membership may do with the resources of the host app (scoped
  # resource grants). Included in Membership.
  module GrantAccess
    # Whether grants limit this membership: its role ranks below
    # config.full_resource_access_role (:admin by default). A limited member
    # sees only the resources granted to it.
    # @return [Boolean]
    def limited_by_grants?
      full_access_role = Organizations.configuration.full_resource_access_role
      full_access_role.nil? || !Roles.at_least?(role_sym, full_access_role)
    end

    # The capabilities this member has on a resource: its role's permissions,
    # narrowed by the grant when grants limit it. A grant never widens the
    # role.
    # @param resource [ActiveRecord::Base, Organizations::Resource, #id]
    # @return [Set<Symbol>]
    def capabilities_for(resource)
      permitted = Roles.permissions_for(role_sym).to_set
      return permitted unless limited_by_grants?

      granted = grant_for(resource)&.capabilities&.map(&:to_sym) || []
      permitted & granted
    end

    # @param capability [Symbol, String]
    # @param resource [ActiveRecord::Base, Organizations::Resource, #id]
    # @return [Boolean]
    #
    # @example
    #   membership.can?(:edit, document)
    def can?(capability, resource)
      capabilities_for(resource).include?(capability.to_sym)
    end

    # The records of a relation this member may see: all of them when
    # grants do not limit it, else the granted ones. With capability:, only
    # where it holds that capability (and its role has it).
    # @param relation [ActiveRecord::Relation]
    # @param capability [Symbol, String, nil]
    # @return [ActiveRecord::Relation]
    def visible(relation, capability: nil)
      return relation.none if capability && !has_permission_to?(capability)
      return relation unless limited_by_grants?

      relation.where(relation.klass.primary_key => granted_ids(relation.klass, capability: capability))
    end

    # Ids of the granted resources of one type.
    # @param type [Class, String] e.g. Document or "Ledger::Entity"
    # @param capability [Symbol, String, nil] only grants that list it
    # @return [Array]
    def granted_ids(type, capability: nil)
      rows = grants.of_type(type)
      return rows.pluck(:grantable_id) unless capability

      rows.select { |grant| grant.allows?(capability) }.map(&:grantable_id)
    end
  end
end
