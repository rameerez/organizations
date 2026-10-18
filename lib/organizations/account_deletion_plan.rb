# frozen_string_literal: true

module Organizations
  # What deleting a user would do to their organizations, under a policy
  # (config.account_deletion_policy). user.account_deletion_plan returns one
  # without changing anything; the deletion guard builds one under row locks
  # and acts on it.
  #
  #   plan = user.account_deletion_plan
  #   plan.allowed?                  # => false
  #   plan.blockers                  # => [#<Blocker organization=…, reason=:owns_organization_with_members>]
  #   plan.organizations_to_destroy  # personal organizations deleted with the account
  #   plan.memberships_to_remove     # the user's other memberships, removed with the account
  #
  # Blocker reasons:
  #   :owns_organization_with_members     - transfer ownership first
  #   :owns_organization                  - the user is the only member; delete the organization first
  #   :personal_organization_with_members - the personal organization has other members
  #   :personal_organization              - the policy is :prevent
  #
  # Database effects only. Subscriptions, external services and retained
  # records belong to the host's account-closure workflow: a rollback cannot
  # undo an external call, so run those after the deletion commits.
  class AccountDeletionPlan
    Blocker = Struct.new(:organization, :reason, keyword_init: true)

    BLOCKER_REASONS = %i[
      owns_organization_with_members
      owns_organization
      personal_organization_with_members
      personal_organization
    ].freeze

    attr_reader :user, :policy, :blockers, :organizations_to_destroy, :memberships_to_remove

    # @param user [User]
    # @param policy [Symbol] one of Configuration::ACCOUNT_DELETION_POLICIES
    # @param lock [Boolean] lock the owned organizations (the deletion guard does)
    def self.for(user, policy: Organizations.configuration.account_deletion_policy, lock: false)
      new(user, policy.to_sym, lock: lock)
    end

    def initialize(user, policy, lock: false)
      unless Configuration::ACCOUNT_DELETION_POLICIES.include?(policy)
        raise ArgumentError, "Unknown account deletion policy: #{policy.inspect}"
      end

      @user = user
      @policy = policy
      @blockers = []
      @organizations_to_destroy = []
      classify(owned_organizations(lock: lock))
      @memberships_to_remove = remaining_memberships
    end

    # @return [Boolean] true when the user can be deleted
    def allowed?
      blockers.empty?
    end

    # A plain Hash (ids and symbols) for audit logs and confirmation screens.
    # @return [Hash]
    def to_h
      {
        allowed: allowed?,
        policy: policy,
        blockers: blockers.map { |b| { organization_id: b.organization.id, reason: b.reason } },
        organizations_to_destroy: organizations_to_destroy.map(&:id),
        memberships_to_remove: memberships_to_remove.map(&:id)
      }
    end

    private

    # Organizations the user owns, plus any organization still linked to them
    # as personal owner (a raw write can leave a link without the membership).
    def owned_organizations(lock:)
      owned_ids = Membership.where(user_id: user.id, role: "owner").select(:organization_id)
      scope = Organization.where(id: owned_ids)
      scope = scope.or(Organization.where(personal_owner_id: user.id)) if personal_column?
      scope = scope.order(:id)
      lock ? scope.lock.to_a : scope.to_a
    end

    def classify(organizations)
      @shared_ids = Membership.where(organization_id: organizations.map(&:id)).where.not(user_id: user.id)
        .distinct.pluck(:organization_id).to_set
      organizations.each do |organization|
        reason = blocker_reason(organization)
        if reason
          blockers << Blocker.new(organization: organization, reason: reason)
        else
          organizations_to_destroy << organization
        end
      end
    end

    def blocker_reason(organization)
      others = @shared_ids.include?(organization.id)
      personal = personal_column? && organization.personal_owner_id == user.id

      return (others ? :owns_organization_with_members : :owns_organization) unless personal
      return :personal_organization_with_members if others
      return :personal_organization unless policy == :destroy_personal_organization

      nil
    end

    def remaining_memberships
      Membership.where(user_id: user.id).where.not(organization_id: organizations_to_destroy.map(&:id))
        .where.not(role: "owner").order(:id).to_a
    end

    def personal_column?
      Organization.column_names.include?("personal_owner_id")
    end
  end
end
