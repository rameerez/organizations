# frozen_string_literal: true

module Organizations
  # Grant management shared by Membership and Invitation (an invitation holds
  # grants until it is accepted, then they move to the membership).
  module GrantHolder
    # Give access to one resource with these capabilities. Again on the same
    # resource, it replaces the capabilities. No capabilities removes the
    # grant (and returns nil).
    #
    # @param resource [ActiveRecord::Base, Organizations::Resource, #id]
    # @param capabilities [Array<Symbol, String>]
    # @param granted_by [User, nil] checked when it is a member of the
    #   organization: it needs config.grant_management_permission, may act
    #   only on roles at or below its own, and, when grants limit it, may give
    #   only capabilities it has on that resource. nil (a console, a job, your
    #   own authorization) is not checked.
    # @return [Organizations::Grant, nil]
    # @raise [Organizations::NotAuthorized]
    # @raise [ArgumentError] when the resource belongs to another organization
    def grant!(resource, capabilities:, granted_by: nil)
      ensure_resource_in_organization!(resource)
      capabilities = Array(capabilities).map { |c| c.to_s.strip }.compact_blank.uniq
      authorize_grant!(resource, capabilities, granted_by)
      if capabilities.empty?
        destroy_grants_on(resource)
        return nil
      end

      upsert_grant!(*Organizations::Grant.resource_key(resource), capabilities, granted_by)
    end

    # Remove the grant on a resource, if any.
    # @param resource [ActiveRecord::Base, Organizations::Resource, #id]
    # @param revoked_by [User, nil] checked like granted_by in grant!
    # @return [self]
    def revoke_grant!(resource, revoked_by: nil)
      authorize_grant!(resource, [], revoked_by)
      destroy_grants_on(resource)
    end

    # Check grants before they are written (an invitation checks them before
    # it is saved). Same rules as grant!.
    # @param grants [Array<Array(resource, capabilities)>]
    # @param actor [User, nil]
    # @raise [Organizations::NotAuthorized]
    def authorize_grants!(grants, actor)
      grants.each do |resource, capabilities|
        ensure_resource_in_organization!(resource)
        authorize_grant!(resource, Array(capabilities).map(&:to_s), actor)
      end
    end

    # @param resource [ActiveRecord::Base, Organizations::Resource, #id]
    # @return [Organizations::Grant, nil]
    def grant_for(resource)
      grants.for_resource(resource).first
    end

    # @param resource [ActiveRecord::Base, Organizations::Resource, #id]
    # @return [Boolean] whether a grant on the resource exists
    def granted?(resource)
      grants.for_resource(resource).exists?
    end

    private

    def destroy_grants_on(resource)
      grants.for_resource(resource).destroy_all
      grants.reset
      self
    end

    def upsert_grant!(type, id, capabilities, granted_by)
      # SAVEPOINT: the unique-index race below must stay rescuable inside a
      # host transaction on PostgreSQL.
      ActiveRecord::Base.transaction(requires_new: true) do
        grant = grants.find_or_initialize_by(grantable_type: type, grantable_id: id)
        grant.update!(capabilities: capabilities, granted_by_id: granted_by&.id || grant.granted_by_id)
        grant
      end
    rescue ActiveRecord::RecordNotUnique
      # A concurrent grant! on the same resource won; apply ours on top.
      grants.reset
      grant = grants.find_by!(grantable_type: type, grantable_id: id)
      grant.update!(capabilities: capabilities)
      grant
    end

    # A resource that says which organization it belongs to must belong to
    # this one.
    def ensure_resource_in_organization!(resource)
      return unless resource.respond_to?(:organization_id) && resource.organization_id.present?
      return if resource.organization_id == organization_id

      raise ArgumentError, "The resource belongs to another organization"
    end

    def authorize_grant!(resource, capabilities, actor)
      actor_membership = actor && organization.memberships.find_by(user_id: actor.id)
      return unless actor_membership

      permission = Organizations.configuration.grant_management_permission
      unless actor_membership.has_permission_to?(permission)
        raise_grant_refusal(:"errors.grant_not_authorized", actor, permission)
      end

      Membership.authorize_rank!(organization, actor, [role], permission: permission,
                                                              message_key: :"errors.grant_outranks_actor")
      return unless actor_membership.limited_by_grants?

      held = actor_membership.capabilities_for(resource).map(&:to_s)
      return if held.any? && (capabilities - held).empty?

      raise_grant_refusal(:"errors.grant_exceeds_actor", actor, permission)
    end

    def raise_grant_refusal(key, actor, permission)
      raise Organizations::NotAuthorized.new(Organizations.t(key, organization: organization),
                                             permission: permission, organization: organization, user: actor)
    end
  end
end
