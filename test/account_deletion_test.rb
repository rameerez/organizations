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

  test "a stale copy cannot destroy an organization that became retained" do
    Organizations.configure { |c| c.retain_organization = ->(organization) { organization.metadata["retain"] == true } }
    org, owner = create_org_with_owner!
    stale = Organizations::Organization.find(org.id)
    Organizations::Organization.find(org.id).update!(metadata: { "retain" => true })

    assert_raises(Organizations::Organization::CannotDestroyRetainedOrganization) { stale.destroy! }
    assert Organizations::Organization.exists?(org.id)
    assert_equal owner, org.reload.owner
  end

  test "a cached association that is now wrong cannot let a retained organization go" do
    Organizations.configure { |c| c.retain_organization = ->(organization) { organization.invitations.any? } }
    org, owner = create_org_with_owner!
    stale = Organizations::Organization.find(org.id)
    stale.invitations.load # cached: no invitations
    invitation = Organizations::Organization.find(org.id).send_invite_to!("someone@example.com", invited_by: owner)

    assert_raises(Organizations::Organization::CannotDestroyRetainedOrganization) { stale.destroy! }
    assert Organizations::Organization.exists?(org.id)
    assert Organizations::Invitation.exists?(invitation.id)
  end

  test "the destroy locks the organization row before it asks the rule" do
    locked = []
    seen = nil
    Organizations.configure { |c| c.retain_organization = ->(_organization) { (seen = locked.dup) && false } }
    org, = create_org_with_owner!
    relation_class = ActiveRecord::Relation
    original = relation_class.instance_method(:lock)
    relation_class.define_method(:lock) do |*args|
      locked << model.table_name
      original.bind_call(self, *args)
    end

    org.destroy!

    assert_includes seen, "organizations_organizations"
  ensure
    relation_class.define_method(:lock, original)
  end

  test "a retained record created during the destroy keeps the organization" do
    skip "Row locks across connections need PostgreSQL (ORGS_TEST_DATABASE_URL)" unless postgresql?

    retain_organizations_with_documents
    org, = create_org_with_owner!
    stale = Organizations::Organization.find(org.id)

    # The app's writer locks the organization row, creates the retained
    # record, and commits a moment later.
    writer = lambda do |ready|
      Organizations::Organization.transaction do
        Organizations::Organization.lock.find(org.id)
        Document.create!(organization_id: org.id)
        ready << true
        sleep 0.5 # the destroy starts now and waits for this lock
      end
    end

    concurrently(writer) do
      assert_raises(Organizations::Organization::CannotDestroyRetainedOrganization) { stale.destroy! }
    end

    assert Organizations::Organization.exists?(org.id)
    assert Document.exists?(organization_id: org.id)
  end

  test "a query cache filled earlier cannot let a retained organization go" do
    retain_organizations_with_documents
    org, = create_org_with_owner!

    ActiveRecord::Base.cache do
      refute Document.exists?(organization_id: org.id) # the request caches "none"
      insert_document_elsewhere(org)

      assert_raises(Organizations::Organization::CannotDestroyRetainedOrganization) { org.destroy! }
    end
    assert Organizations::Organization.exists?(org.id)
    assert Document.exists?(organization_id: org.id)
  end

  test "a query cache filled by the preview cannot hide a new member from the deletion guard" do
    use_policy :destroy_personal_organization
    user = create_user!
    org = user.create_personal_organization!
    friend = create_user!

    # No grants table: no write clears the cache before the guard runs.
    Organizations::GrantHolder.stub(:grants_table?, false) do
      ActiveRecord::Base.cache do
        assert_equal [org], user.account_deletion_plan.organizations_to_destroy # cached: no other member
        add_member_elsewhere(org, friend)

        refute user.destroy
      end
    end

    assert Organizations::Organization.exists?(org.id)
    assert Organizations::Membership.exists?(organization_id: org.id, user_id: friend.id)
  end

  test "a member deletes their account while the organization is destroyed, and neither deadlocks" do
    skip "Row locks across connections need PostgreSQL (ORGS_TEST_DATABASE_URL)" unless postgresql?

    org, = create_org_with_owner!
    member = create_user!
    org.add_member!(member)
    # The rule runs just after the destroy locked the organization row. It
    # holds the lock a moment, so the member's deletion starts inside it.
    destroyer = lambda do |ready|
      hold_the_lock = ->(_organization) { (ready << true) && sleep(0.5) && false }
      Organizations.configure { |c| c.retain_organization = hold_the_lock }
      Organizations::Organization.find(org.id).destroy!
    end

    concurrently(destroyer) do
      assert member.destroy
    end

    refute User.exists?(member.id)
    refute Organizations::Organization.exists?(org.id)
  end

  test "without retention, a member deletes their account while the cascades of a destroy run, and neither deadlocks" do
    skip "Row locks across connections need PostgreSQL (ORGS_TEST_DATABASE_URL)" unless postgresql?

    org, = create_org_with_owner!
    member = create_user!
    org.add_member!(member)
    # The destroy has deleted the memberships and waits a moment before it
    # deletes the organization row. The member's deletion starts then.
    destroyer = lambda do |ready|
      pausing_after_the_cascades(ready) { Organizations::Organization.find(org.id).destroy! }
    end

    concurrently(destroyer) do
      assert member.destroy
    end
    refute User.exists?(member.id)
    refute Organizations::Organization.exists?(org.id)
  end

  test "a member whose pending invitation has a grant deletes their account while the organization is destroyed" do
    skip "Row locks across connections need PostgreSQL (ORGS_TEST_DATABASE_URL)" unless postgresql?

    org, = create_org_with_owner!
    member = create_user!
    org.add_member!(member, role: :admin)
    invitation = org.send_invite_to!("guest@example.com", invited_by: member,
                                                          grants: { Document.create!(organization: org) => %w[read] })

    assert_equal 1, invitation.grants.count
    # The destroy has locked the organization row and waits a moment before
    # its cascades delete the invitation and its grant.
    destroyer = lambda do |ready|
      hold_the_lock = ->(_organization) { (ready << true) && sleep(0.5) && false }
      Organizations.configure { |c| c.retain_organization = hold_the_lock }
      Organizations::Organization.find(org.id).destroy!
    end

    concurrently(destroyer) do
      assert member.destroy
    end
    refute User.exists?(member.id)
    refute Organizations::Organization.exists?(org.id)
    refute Organizations::Grant.exists?(invitation_id: invitation.id)
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

  # Runs work in another connection, and the block once work pushes to
  # `ready`. Errors of the work are raised here.
  def concurrently(work)
    ready = Queue.new
    thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection { work.call(ready) }
    ensure
      ready << :done
    end
    ready.pop
    yield
    thread.value
  ensure
    thread.join if thread&.alive?
  end

  # A host before_destroy callback, which runs after the gem's
  # dependent: :destroy cascades and before the organization row goes.
  def pausing_after_the_cascades(ready)
    organization_class = Organizations::Organization
    organization_class.define_method(:pause_after_the_cascades_for_test) { (ready << true) && sleep(0.5) }
    organization_class.before_destroy(:pause_after_the_cascades_for_test)
    yield
  ensure
    organization_class.skip_callback(:destroy, :before, :pause_after_the_cascades_for_test)
    organization_class.remove_method(:pause_after_the_cascades_for_test)
  end

  # A write that this connection's query cache does not see. On PostgreSQL
  # it is another connection. An in-memory SQLite database has only one
  # connection, so there the raw driver writes, past the query cache.
  def insert_document_elsewhere(org)
    return in_another_connection { Document.create!(organization_id: org.id) } if postgresql?

    ActiveRecord::Base.connection.raw_connection.execute("INSERT INTO documents (organization_id) VALUES (?)", [org.id])
  end

  def add_member_elsewhere(org, user)
    return in_another_connection { Organizations::Organization.find(org.id).add_member!(user) } if postgresql?

    now = Time.current.utc.strftime("%Y-%m-%d %H:%M:%S")
    ActiveRecord::Base.connection.raw_connection.execute(
      "INSERT INTO organizations_memberships (user_id, organization_id, role, created_at, updated_at) " \
      "VALUES (?, ?, 'member', ?, ?)", [user.id, org.id, now, now]
    )
  end

  def in_another_connection(&block)
    Thread.new { ActiveRecord::Base.connection_pool.with_connection(&block) }.value
  end

  def postgresql?
    ActiveRecord::Base.connection.adapter_name.downcase.include?("postg")
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
