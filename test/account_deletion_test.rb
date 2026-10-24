# frozen_string_literal: true

require "test_helper"

# Safe account deletion (issue #21, part 2). The default keeps the old guard:
# a user who owns any organization cannot be deleted. The opt-in
# :destroy_personal_organization policy also deletes an explicitly personal
# organization whose only member is its owner, and nothing else.
class AccountDeletionTest < Organizations::Test
  # === Default policy (:prevent) ===

  test "the default policy is :prevent" do
    assert_equal :prevent, Organizations.configuration.account_deletion_policy
  end

  test "a user with no owned organizations is deleted and leaves their memberships" do
    org, = create_org_with_owner!
    user = create_user!
    org.add_member!(user)

    user.destroy!

    refute User.exists?(user.id)
    assert_equal 1, org.reload.member_count
  end

  test "a user whose invitation was accepted is deleted, and the membership keeps no inviter" do
    org, owner = create_org_with_owner!
    invitee = create_user!
    org.send_invite_to!(invitee.email, invited_by: owner, role: :admin).accept!(invitee)
    org.transfer_ownership_to!(invitee)
    membership = org.memberships.find_by!(user: invitee)

    assert_equal owner.id, membership.invited_by_id

    owner.destroy!

    refute User.exists?(owner.id)
    assert_nil membership.reload.invited_by_id
    assert_equal invitee, org.reload.owner
  end

  test ":prevent blocks a sole-member personal organization and keeps everything" do
    user = create_user!
    org = user.create_personal_organization!

    refute user.destroy
    assert User.exists?(user.id)
    assert Organizations::Organization.exists?(org.id)
    assert_includes user.errors.full_messages.join, "still owns organizations"
  end

  test ":prevent blocks a shared organization with members" do
    org, owner = create_org_with_owner!
    org.add_member!(create_user!)

    assert_raises(ActiveRecord::RecordNotDestroyed) { owner.destroy! }
    assert User.exists?(owner.id)
  end

  # === :destroy_personal_organization ===

  test "a personal-only owner is deleted together with the personal organization" do
    use_policy :destroy_personal_organization
    user = create_user!
    org = user.create_personal_organization!
    invitation = org.send_invite_to!("someone@example.com", invited_by: user)

    user.destroy!

    refute User.exists?(user.id)
    refute Organizations::Organization.exists?(org.id)
    refute Organizations::Invitation.exists?(invitation.id)
    assert_equal 0, Organizations::Membership.where(organization_id: org.id).count
  end

  test "a personal organization with another member blocks deletion" do
    use_policy :destroy_personal_organization
    user = create_user!
    org = user.create_personal_organization!
    org.add_member!(create_user!)

    refute user.destroy
    assert User.exists?(user.id)
    assert Organizations::Organization.exists?(org.id)
  end

  test "a sole-member shared organization still blocks deletion" do
    use_policy :destroy_personal_organization
    org, owner = create_org_with_owner!

    refute owner.destroy
    assert Organizations::Organization.exists?(org.id)
  end

  test "mixed personal and shared ownership is blocked with no partial deletion" do
    use_policy :destroy_personal_organization
    user = create_user!
    personal = user.create_personal_organization!
    shared, = create_org_with_owner!(name: "Shared", owner: user)
    shared.add_member!(create_user!)

    refute user.destroy
    assert Organizations::Organization.exists?(personal.id)
    assert Organizations::Organization.exists?(shared.id)
    assert_equal user, personal.reload.owner
  end

  test "a host veto on the personal organization rolls everything back with a useful error" do
    use_policy :destroy_personal_organization
    user = create_user!
    org = user.create_personal_organization!
    org_class = Organizations::Organization
    org_class.before_destroy(:veto_for_test, prepend: true)
    org_class.define_method(:veto_for_test) do
      errors.add(:base, "billing is still active")
      throw(:abort)
    end

    refute user.destroy
    assert User.exists?(user.id)
    assert Organizations::Organization.exists?(org.id)
    assert_includes user.errors.full_messages.join, "billing is still active"
  ensure
    org_class.skip_callback(:destroy, :before, :veto_for_test)
    org_class.remove_method(:veto_for_test)
  end

  test "a failure after the personal organization is gone rolls the organization back" do
    use_policy :destroy_personal_organization
    user = create_user!
    org = user.create_personal_organization!
    User.before_destroy(:fail_late_for_test)
    User.define_method(:fail_late_for_test) { throw(:abort) }

    refute user.destroy
    assert Organizations::Organization.exists?(org.id)
    assert_equal user, org.reload.owner
  ensure
    User.skip_callback(:destroy, :before, :fail_late_for_test)
    User.remove_method(:fail_late_for_test)
  end

  test "a late veto inside a host transaction rolls back the personal organization too" do
    use_policy :destroy_personal_organization
    user = create_user!
    org = user.create_personal_organization!
    User.before_destroy(:fail_late_for_test)
    User.define_method(:fail_late_for_test) { throw(:abort) }

    ActiveRecord::Base.transaction do
      refute user.destroy
    end

    assert User.exists?(user.id)
    assert Organizations::Organization.exists?(org.id)
    assert_equal user, org.reload.owner
  ensure
    User.skip_callback(:destroy, :before, :fail_late_for_test)
    User.remove_method(:fail_late_for_test)
  end

  test "destroy! inside a host transaction raises and keeps everything" do
    use_policy :destroy_personal_organization
    user = create_user!
    org = user.create_personal_organization!
    org.add_member!(create_user!)

    ActiveRecord::Base.transaction do
      assert_raises(ActiveRecord::RecordNotDestroyed) { user.destroy! }
    end

    assert User.exists?(user.id)
    assert Organizations::Organization.exists?(org.id)
  end

  test "ownership transfer locks the new owner's row so it cannot race a deletion" do
    org, = create_org_with_owner!
    admin = create_user!
    org.add_member!(admin, role: :admin)
    locked = []
    relation_class = ActiveRecord::Relation
    original = relation_class.instance_method(:lock)
    relation_class.define_method(:lock) do |*args|
      locked << model.table_name if model == User
      original.bind_call(self, *args)
    end

    org.transfer_ownership_to!(admin)

    assert_includes locked, "users"
  ensure
    relation_class.define_method(:lock, original)
  end

  test "ownership transfer to a user deleted meanwhile is refused" do
    org, = create_org_with_owner!
    admin = create_user!
    org.add_member!(admin, role: :admin)
    gone = User.new(id: admin.id)
    Organizations::Membership.where(user_id: admin.id).delete_all
    User.where(id: admin.id).delete_all

    assert_raises(Organizations::Organization::CannotTransferToNonMember) { org.transfer_ownership_to!(gone) }
  end

  test "an orphaned personal link counts as ownership for the guard" do
    user = create_user!
    org = user.create_personal_organization!
    # Raw write: the owner membership is gone but the link remains.
    Organizations::Membership.where(organization_id: org.id).delete_all

    plan = user.account_deletion_plan

    refute_predicate plan, :allowed?
    assert_equal :personal_organization, plan.blockers.first.reason
  end

  # === Dry run ===

  test "account_deletion_plan lists every consequence and changes nothing" do
    use_policy :destroy_personal_organization
    user = create_user!
    personal = user.create_personal_organization!
    team, = create_org_with_owner!(name: "Team")
    team.add_member!(user)

    plan = nil
    assert_no_difference [-> { User.count }, -> { Organizations::Organization.count }, lambda {
      Organizations::Membership.count
    }] do
      plan = user.account_deletion_plan
    end

    assert_predicate plan, :allowed?
    assert_equal [personal], plan.organizations_to_destroy
    assert_equal [team.memberships.find_by(user_id: user.id)], plan.memberships_to_remove
    assert_empty plan.blockers
    assert_equal :destroy_personal_organization, plan.policy
  end

  test "account_deletion_plan names each blocking organization and why" do
    use_policy :destroy_personal_organization
    user = create_user!
    personal = user.create_personal_organization!
    personal.add_member!(create_user!)
    solo, = create_org_with_owner!(name: "Solo", owner: user)
    busy, = create_org_with_owner!(name: "Busy", owner: user)
    busy.add_member!(create_user!)

    plan = user.account_deletion_plan

    refute_predicate plan, :allowed?
    reasons = plan.blockers.to_h { |b| [b.organization, b.reason] }

    assert_equal :personal_organization_with_members, reasons[personal]
    assert_equal :owns_organization, reasons[solo]
    assert_equal :owns_organization_with_members, reasons[busy]
    assert_empty plan.organizations_to_destroy
  end

  test "account_deletion_plan under :prevent blocks the personal organization too" do
    user = create_user!
    personal = user.create_personal_organization!

    plan = user.account_deletion_plan

    assert_equal([[personal, :personal_organization]], plan.blockers.map { |b| [b.organization, b.reason] })
  end

  test "account_deletion_plan can preview another policy" do
    user = create_user!
    personal = user.create_personal_organization!

    plan = user.account_deletion_plan(policy: :destroy_personal_organization)

    assert_predicate plan, :allowed?
    assert_equal [personal], plan.organizations_to_destroy
  end

  test "account_deletion_plan to_h is serializable for an audit log" do
    user = create_user!

    hash = user.account_deletion_plan.to_h

    assert_equal({ allowed: true, policy: :prevent, blockers: [], organizations_to_destroy: [],
                   organizations_to_retain: [], memberships_to_remove: [] }, hash)
  end

  # === Retained organizations (config.retain_organization) ===
  #
  # An organization that holds records with a retention period (issued
  # invoices, the books) is never destroyed with the account. The plan lists
  # it apart, user.destroy refuses, and the app closes the account instead.

  test "a user whose personal organization holds retained records is not deleted, and the refusal names it" do
    retain_organizations_with_documents
    user = create_user!
    org = user.create_personal_organization!("Ana's books")
    Document.create!(organization: org, title: "Invoice 1")

    refute user.destroy
    assert_includes user.errors.full_messages, "Ana's books holds records that must be kept, so it cannot be deleted."
    assert User.exists?(user.id)
    assert Organizations::Organization.exists?(org.id)
    assert_equal user, org.reload.owner
    assert_equal user, org.personal_owner
  end

  test "destroy! of such a user raises and keeps everything" do
    retain_organizations_with_documents
    user = create_user!
    org = user.create_personal_organization!
    Document.create!(organization: org)

    assert_raises(ActiveRecord::RecordNotDestroyed) { user.destroy! }
    assert User.exists?(user.id)
    assert_equal user, org.reload.owner
  end

  test "an account with no retained records is still deleted with its personal organization" do
    retain_organizations_with_documents
    user = create_user!
    org = user.create_personal_organization!

    assert user.destroy
    refute User.exists?(user.id)
    refute Organizations::Organization.exists?(org.id)
  end

  test "the plan lists a retained organization apart and does not block on it" do
    retain_organizations_with_documents
    user = create_user!
    org = user.create_personal_organization!
    Document.create!(organization: org)
    team, = create_org_with_owner!(name: "Team")
    team.add_member!(user)

    plan = user.account_deletion_plan

    assert_predicate plan, :allowed?
    assert_empty plan.blockers
    assert_equal [org], plan.organizations_to_retain
    assert_empty plan.organizations_to_destroy
    assert_equal [team.memberships.find_by(user_id: user.id)], plan.memberships_to_remove
    assert_equal [org.id], plan.to_h[:organizations_to_retain]
  end

  test "an organization with other members still blocks, retained or not" do
    retain_organizations_with_documents
    user = create_user!
    org = user.create_personal_organization!
    org.add_member!(create_user!)
    Document.create!(organization: org)

    plan = user.account_deletion_plan

    refute_predicate plan, :allowed?
    assert_equal([[org, :personal_organization_with_members]], plan.blockers.map { |b| [b.organization, b.reason] })
    assert_empty plan.organizations_to_retain
  end

  test "under :prevent the personal organization blocks and nothing is listed as retained" do
    Organizations.configure { |c| c.retain_organization = ->(_organization) { true } }
    user = create_user!
    org = user.create_personal_organization!

    plan = user.account_deletion_plan

    assert_equal([[org, :personal_organization]], plan.blockers.map { |b| [b.organization, b.reason] })
    assert_empty plan.organizations_to_retain
  end

  test "the deletion asks again under its locks: a record added after the preview keeps the organization" do
    retain_organizations_with_documents
    user = create_user!
    org = user.create_personal_organization!

    assert_equal [org], user.account_deletion_plan.organizations_to_destroy

    Document.create!(organization: org)

    refute user.destroy
    assert Organizations::Organization.exists?(org.id)
  end

  test "the closure an app runs instead keeps the retained organization with its owner" do
    retain_organizations_with_documents
    user = create_user!
    org = user.create_personal_organization!
    Document.create!(organization: org)
    team, = create_org_with_owner!(name: "Team")
    team.add_member!(user)

    # What the app does instead of user.destroy, under the guard's lock order.
    User.transaction do
      user.lock!
      plan = Organizations::AccountDeletionPlan.for(user, lock: true)
      plan.organizations_to_destroy.each(&:destroy!)
      plan.memberships_to_remove.each(&:destroy!)
    end

    assert_equal user, org.reload.owner
    refute team.reload.has_member?(user)
    assert Document.exists?(organization_id: org.id)
  end

  test "destroying a retained organization raises and keeps every row" do
    retain_organizations_with_documents
    org, owner = create_org_with_owner!(name: "Books")
    invitation = org.send_invite_to!("someone@example.com", invited_by: owner)
    Document.create!(organization: org)

    error = assert_raises(Organizations::Organization::CannotDestroyRetainedOrganization) { org.destroy }
    assert_equal "Books holds records that must be kept, so it cannot be deleted.", error.message
    assert_raises(Organizations::Organization::CannotDestroyRetainedOrganization) { org.destroy! }
    assert Organizations::Organization.exists?(org.id)
    assert_equal owner, org.reload.owner
    assert Organizations::Invitation.exists?(invitation.id)
  end

  test "an organization without retained records is destroyed as before" do
    retain_organizations_with_documents
    org, = create_org_with_owner!

    org.destroy!

    refute Organizations::Organization.exists?(org.id)
  end

  # === Configuration ===

  test "account_deletion_policy rejects unknown values" do
    assert_raises(Organizations::ConfigurationError) do
      Organizations.configure { |c| c.account_deletion_policy = :destroy_everything }
    end
  end

  test "retain_organization is nil by default and must be callable" do
    assert_nil Organizations.configuration.retain_organization
    assert_raises(Organizations::ConfigurationError) do
      Organizations.configure { |c| c.retain_organization = true }
    end
  end

  private

  def use_policy(policy)
    Organizations.configure { |c| c.account_deletion_policy = policy }
  end

  # The fictional rule of these tests: an organization that holds documents
  # is kept.
  def retain_organizations_with_documents
    Organizations.configure do |c|
      c.account_deletion_policy = :destroy_personal_organization
      c.retain_organization = ->(organization) { Document.exists?(organization_id: organization.id) }
    end
  end
end
