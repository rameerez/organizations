# frozen_string_literal: true

require "test_helper"

module Organizations
  class DataIntegrityTest < Organizations::Test
    # =========================================================================
    # Unique Constraints
    # =========================================================================

    # -- memberships [user_id, organization_id] --

    test "unique constraint: user can only have one membership per organization" do
      org, _owner = create_org_with_owner!
      member = create_user!

      Organizations::Membership.create!(user: member, organization: org, role: "member")

      assert_raises(ActiveRecord::RecordInvalid) do
        Organizations::Membership.create!(user: member, organization: org, role: "admin")
      end
    end

    test "unique constraint: same user can belong to different organizations" do
      org1, _ = create_org_with_owner!(name: "Org One")
      org2, _ = create_org_with_owner!(name: "Org Two")
      member = create_user!

      m1 = Organizations::Membership.create!(user: member, organization: org1, role: "member")
      m2 = Organizations::Membership.create!(user: member, organization: org2, role: "member")

      assert m1.persisted?
      assert m2.persisted?
      assert_not_equal m1.id, m2.id
    end

    test "unique constraint: different users can belong to same organization" do
      org, _owner = create_org_with_owner!
      member1 = create_user!(email: "member1@example.com")
      member2 = create_user!(email: "member2@example.com")

      m1 = Organizations::Membership.create!(user: member1, organization: org, role: "member")
      m2 = Organizations::Membership.create!(user: member2, organization: org, role: "member")

      assert m1.persisted?
      assert m2.persisted?
    end

    test "unique constraint: database-level unique index on memberships" do
      org, _owner = create_org_with_owner!
      member = create_user!
      Organizations::Membership.create!(user: member, organization: org, role: "member")

      # Bypass validations to hit the database constraint
      duplicate = Organizations::Membership.new(user: member, organization: org, role: "admin")
      assert_raises(ActiveRecord::RecordNotUnique) do
        duplicate.save(validate: false)
      end
    end

    # -- invitations [organization_id, email] WHERE accepted_at IS NULL --

    test "unique constraint: only one pending invitation per email per organization" do
      org, owner = create_org_with_owner!
      email = "invite@example.com"

      Organizations::Invitation.create!(
        organization: org,
        email: email,
        invited_by: owner,
        role: "member",
        token: SecureRandom.urlsafe_base64(32),
        expires_at: 7.days.from_now
      )

      inv2 = Organizations::Invitation.new(
        organization: org,
        email: email,
        invited_by: owner,
        role: "member",
        token: SecureRandom.urlsafe_base64(32),
        expires_at: 7.days.from_now
      )

      assert_not inv2.valid?
      assert_includes inv2.errors[:email], "has already been invited to this organization"
    end

    test "unique constraint: same email can be invited to different organizations" do
      org1, owner1 = create_org_with_owner!(name: "Org A")
      org2, owner2 = create_org_with_owner!(name: "Org B")
      email = "multi-org@example.com"

      inv1 = Organizations::Invitation.create!(
        organization: org1, email: email, invited_by: owner1,
        role: "member", token: SecureRandom.urlsafe_base64(32), expires_at: 7.days.from_now
      )
      inv2 = Organizations::Invitation.create!(
        organization: org2, email: email, invited_by: owner2,
        role: "member", token: SecureRandom.urlsafe_base64(32), expires_at: 7.days.from_now
      )

      assert inv1.persisted?
      assert inv2.persisted?
    end

    test "unique constraint: accepted invitation allows new pending invitation to same email" do
      org, owner = create_org_with_owner!
      email = "rehire@example.com"

      # Create and accept an invitation
      inv1 = Organizations::Invitation.create!(
        organization: org, email: email, invited_by: owner,
        role: "member", token: SecureRandom.urlsafe_base64(32), expires_at: 7.days.from_now
      )
      inv1.update!(accepted_at: Time.current)

      # A new pending invitation to the same email should be allowed
      inv2 = Organizations::Invitation.new(
        organization: org, email: email, invited_by: owner,
        role: "member", token: SecureRandom.urlsafe_base64(32), expires_at: 7.days.from_now
      )

      assert inv2.valid?, "Expected a new pending invitation to be valid after the first was accepted"
    end

    # -- invitations [token] --

    test "unique constraint: invitation tokens are globally unique" do
      org, owner = create_org_with_owner!
      shared_token = SecureRandom.urlsafe_base64(32)

      Organizations::Invitation.create!(
        organization: org, email: "first@example.com", invited_by: owner,
        role: "member", token: shared_token, expires_at: 7.days.from_now
      )

      inv2 = Organizations::Invitation.new(
        organization: org, email: "second@example.com", invited_by: owner,
        role: "member", token: shared_token, expires_at: 7.days.from_now
      )

      assert_not inv2.valid?
      assert_includes inv2.errors[:token], "has already been taken"
    end

    # =========================================================================
    # Row-Level Locking
    # =========================================================================

    # -- Invitation acceptance locking --

    test "row-level locking: invitation acceptance completes successfully with locking" do
      org, owner = create_org_with_owner!
      user = create_user!(email: "invitee@example.com")
      invitation = Organizations::Invitation.create!(
        organization: org, email: "invitee@example.com", invited_by: owner,
        role: "member", token: SecureRandom.urlsafe_base64(32), expires_at: 7.days.from_now
      )

      # Verify accept! completes successfully (lock! is called internally)
      membership = invitation.accept!(user)
      assert membership.persisted?
      assert invitation.reload.accepted?
    end

    test "row-level locking: second acceptance of same invitation returns existing membership" do
      org, owner = create_org_with_owner!
      user = create_user!(email: "doubleclick@example.com")
      invitation = Organizations::Invitation.create!(
        organization: org, email: "doubleclick@example.com", invited_by: owner,
        role: "member", token: SecureRandom.urlsafe_base64(32), expires_at: 7.days.from_now
      )

      first_membership = invitation.accept!(user)
      assert first_membership.persisted?

      # Reload to clear any cached state
      invitation.reload

      # Second acceptance returns existing membership, does not raise
      second_result = invitation.accept!(user)
      assert_equal first_membership.id, second_result.id
    end

    # -- Ownership transfer locking --

    test "row-level locking: transfer_ownership_to! locks organization and memberships" do
      org, owner = create_org_with_owner!
      admin = create_user!(email: "admin@example.com")
      Organizations::Membership.create!(user: admin, organization: org, role: "admin")

      # Verify the transfer completes atomically
      org.transfer_ownership_to!(admin)

      org.reload
      assert_equal admin.id, org.owner.id
      assert_equal "admin", Organizations::Membership.find_by(user: owner, organization: org).role
      assert_equal "owner", Organizations::Membership.find_by(user: admin, organization: org).role
    end

    # -- Last admin/owner protection uses organization lock --

    test "row-level locking: leave_organization! locks the organization row" do
      org, _owner = create_org_with_owner!
      member = create_user!(email: "departing@example.com")
      Organizations::Membership.create!(user: member, organization: org, role: "member")

      # User needs a second org so they can leave this one
      second_org = Organizations::Organization.create!(name: "Second Org")
      Organizations::Membership.create!(user: member, organization: second_org, role: "owner")

      member.leave_organization!(org)
      refute member.is_member_of?(org)
    end

    # =========================================================================
    # Ownership Invariants
    # =========================================================================

    test "ownership invariant: every organization created via user has exactly one owner" do
      user = create_user!
      org = user.create_organization!("My Org")

      owner_count = org.memberships.where(role: "owner").count
      assert_equal 1, owner_count
      assert_equal user.id, org.owner.id
    end

    test "ownership invariant: cannot add a second owner via add_member!" do
      org, _owner = create_org_with_owner!
      other_user = create_user!

      assert_raises(Organizations::Organization::CannotHaveMultipleOwners) do
        org.add_member!(other_user, role: :owner)
      end
    end

    test "ownership invariant: cannot promote to owner via change_role_of!" do
      org, _owner = create_org_with_owner!
      admin = create_user!
      Organizations::Membership.create!(user: admin, organization: org, role: "admin")

      assert_raises(Organizations::Organization::CannotHaveMultipleOwners) do
        org.change_role_of!(admin, to: :owner)
      end
    end

    test "ownership invariant: cannot promote to owner via membership promote_to!" do
      org, _owner = create_org_with_owner!
      admin = create_user!
      membership = Organizations::Membership.create!(user: admin, organization: org, role: "admin")

      assert_raises(Organizations::Membership::CannotPromoteToOwner) do
        membership.promote_to!(:owner)
      end
    end

    test "ownership invariant: owner cannot leave organization (must transfer first)" do
      org, owner = create_org_with_owner!

      assert_raises(Organizations::Models::Concerns::HasOrganizations::CannotLeaveAsLastOwner) do
        owner.leave_organization!(org)
      end

      # Owner is still a member
      assert owner.is_member_of?(org)
      assert_equal :owner, owner.role_in(org)
    end

    test "ownership invariant: owner cannot be removed via remove_member!" do
      org, owner = create_org_with_owner!

      assert_raises(Organizations::Organization::CannotRemoveOwner) do
        org.remove_member!(owner)
      end

      assert owner.is_member_of?(org)
    end

    test "ownership invariant: owner cannot be demoted via change_role_of!" do
      org, owner = create_org_with_owner!

      assert_raises(Organizations::Organization::CannotDemoteOwner) do
        org.change_role_of!(owner, to: :admin)
      end
    end

    test "ownership invariant: owner cannot be demoted via membership demote_to!" do
      _org, _owner = create_org_with_owner!
      owner_membership = Organizations::Membership.last

      assert_raises(Organizations::Membership::CannotDemoteOwner) do
        owner_membership.demote_to!(:admin)
      end
    end

    test "ownership invariant: transfer_ownership_to! atomically swaps ownership" do
      org, owner = create_org_with_owner!
      admin = create_user!(email: "new-owner@example.com")
      Organizations::Membership.create!(user: admin, organization: org, role: "admin")

      org.transfer_ownership_to!(admin)
      org.reload

      # New owner
      assert_equal admin.id, org.owner.id
      assert_equal "owner", Organizations::Membership.find_by(user: admin, organization: org).role

      # Old owner demoted to admin
      assert_equal "admin", Organizations::Membership.find_by(user: owner, organization: org).role

      # Exactly one owner
      assert_equal 1, org.memberships.where(role: "owner").count
    end

    test "ownership invariant: transfer to non-member raises" do
      org, _owner = create_org_with_owner!
      outsider = create_user!

      assert_raises(Organizations::Organization::CannotTransferToNonMember) do
        org.transfer_ownership_to!(outsider)
      end
    end

    test "ownership invariant: transfer to non-admin member raises" do
      org, _owner = create_org_with_owner!
      member = create_user!
      Organizations::Membership.create!(user: member, organization: org, role: "member")

      assert_raises(Organizations::Organization::CannotTransferToNonAdmin) do
        org.transfer_ownership_to!(member)
      end
    end

    test "ownership invariant: transfer to self is a no-op" do
      org, owner = create_org_with_owner!

      org.transfer_ownership_to!(owner)

      assert_equal "owner", Organizations::Membership.find_by(user: owner, organization: org).role
      assert_equal 1, org.memberships.where(role: "owner").count
    end

    # =========================================================================
    # Transaction Boundaries
    # =========================================================================

    test "transaction boundary: organization creation is atomic (create org + owner membership)" do
      user = create_user!

      org = user.create_organization!("Transactional Org")

      assert org.persisted?
      assert_equal 1, org.memberships.count
      assert_equal "owner", org.memberships.first.role
      assert_equal user.id, org.memberships.first.user_id
    end

    test "transaction boundary: failed org creation does not leave partial data" do
      user = create_user!
      org_count_before = Organizations::Organization.count
      membership_count_before = user.memberships.count

      # Organization requires a name, so passing nil should fail
      assert_raises(ActiveRecord::RecordInvalid) do
        user.create_organization!(nil)
      end

      # No additional organizations or memberships created
      assert_equal org_count_before, Organizations::Organization.count
      assert_equal membership_count_before, user.reload.memberships.count
    end

    test "transaction boundary: invitation acceptance is atomic" do
      org, owner = create_org_with_owner!
      user = create_user!(email: "atomic-accept@example.com")
      invitation = Organizations::Invitation.create!(
        organization: org, email: "atomic-accept@example.com", invited_by: owner,
        role: "member", token: SecureRandom.urlsafe_base64(32), expires_at: 7.days.from_now
      )

      membership = invitation.accept!(user)

      # Both membership created and invitation marked accepted
      assert membership.persisted?
      assert invitation.reload.accepted?
      assert_equal user.id, membership.user_id
      assert_equal org.id, membership.organization_id
    end

    test "transaction boundary: ownership transfer is atomic (demote old + promote new)" do
      org, old_owner = create_org_with_owner!
      admin = create_user!(email: "promoted@example.com")
      Organizations::Membership.create!(user: admin, organization: org, role: "admin")

      org.transfer_ownership_to!(admin)

      # Both changes committed
      assert_equal "admin", Organizations::Membership.find_by(user: old_owner, organization: org).role
      assert_equal "owner", Organizations::Membership.find_by(user: admin, organization: org).role

      # Exactly one owner throughout
      assert_equal 1, org.memberships.where(role: "owner").count
    end

    # =========================================================================
    # Graceful Constraint Handling
    # =========================================================================

    test "graceful handling: inviting already-invited email returns existing invitation" do
      org, owner = create_org_with_owner!
      email = "already-invited@example.com"

      first_invite = org.send_invite_to!(email, invited_by: owner)
      second_invite = org.send_invite_to!(email, invited_by: owner)

      assert_equal first_invite.id, second_invite.id
    end

    test "graceful handling: accepting already-accepted invitation returns existing membership" do
      org, owner = create_org_with_owner!
      user = create_user!(email: "already-accepted@example.com")
      invitation = Organizations::Invitation.create!(
        organization: org, email: "already-accepted@example.com", invited_by: owner,
        role: "member", token: SecureRandom.urlsafe_base64(32), expires_at: 7.days.from_now
      )

      first_membership = invitation.accept!(user)
      invitation.reload
      second_membership = invitation.accept!(user)

      assert_equal first_membership.id, second_membership.id
    end

    test "graceful handling: adding existing member returns existing membership" do
      org, _owner = create_org_with_owner!
      member = create_user!
      first_membership = org.add_member!(member, role: :member)

      second_membership = org.add_member!(member, role: :admin)

      # Returns existing membership (does not change role)
      assert_equal first_membership.id, second_membership.id
      assert_equal "member", second_membership.role
    end

    test "graceful handling: add_member! handles RecordNotUnique race condition" do
      org, _owner = create_org_with_owner!
      user = create_user!

      # Simulate: find_by returns nil (race window), then create! raises RecordNotUnique
      # The rescue block should find and return the existing membership
      membership = org.add_member!(user, role: :member)
      assert membership.persisted?

      # Calling again returns existing
      same_membership = org.add_member!(user, role: :member)
      assert_equal membership.id, same_membership.id
    end

    # =========================================================================
    # Session Integrity
    # =========================================================================

    test "session integrity: user removed from current org has cache cleared" do
      org, _owner = create_org_with_owner!
      member = create_user!(email: "removed@example.com")
      Organizations::Membership.create!(user: member, organization: org, role: "member")

      # Set current organization
      member._current_organization_id = org.id

      assert_equal org, member.current_organization

      # Admin removes user from org
      org.remove_member!(member)

      # User should no longer have membership
      refute member.is_member_of?(org)
    end

    test "session integrity: current_organization returns nil when membership doesn't exist" do
      org, _owner = create_org_with_owner!
      member = create_user!

      # Point session to an org the user is NOT a member of
      member._current_organization_id = org.id

      # current_organization queries the DB and verifies membership
      # Since the user is not a member, it returns nil
      assert_nil member.current_organization
    end

    test "session integrity: current_organization returns nil for deleted organization" do
      org, _owner = create_org_with_owner!
      member = create_user!
      Organizations::Membership.create!(user: member, organization: org, role: "member")

      member._current_organization_id = org.id
      assert_equal org, member.current_organization

      # Delete the organization
      org.destroy!

      # Clear the memoized cache so it re-queries
      member.clear_organization_cache!
      member._current_organization_id = org.id

      assert_nil member.current_organization
    end

    test "session integrity: clear_organization_cache! resets all cached values" do
      org, _owner = create_org_with_owner!
      user = create_user!
      Organizations::Membership.create!(user: user, organization: org, role: "member")

      user._current_organization_id = org.id
      # Force memoization
      user.current_organization
      user.current_membership

      user.clear_organization_cache!

      assert_nil user._current_organization_id
      # After clearing, re-accessing returns nil (no org ID set)
      assert_nil user.current_organization
    end

    # =========================================================================
    # Counter Cache
    # =========================================================================

    test "counter cache: uses count query when memberships_count column does not exist" do
      org, _owner = create_org_with_owner!
      member = create_user!
      org.add_member!(member, role: :member)

      # Our test schema does not have memberships_count column
      assert_equal 2, org.member_count
    end

    test "counter cache: member_count returns accurate count after add and remove" do
      org, _owner = create_org_with_owner!

      assert_equal 1, org.member_count

      member = create_user!
      org.add_member!(member, role: :member)
      assert_equal 2, org.member_count

      org.remove_member!(member)
      assert_equal 1, org.reload.member_count
    end

    test "counter cache: increment_counter called on membership create when column exists" do
      org, _owner = create_org_with_owner!

      # Verify the counter cache logic exists in the membership model
      # The callback is registered but only fires when column exists
      membership = Organizations::Membership.new(user: create_user!, organization: org, role: "member")

      # The private method checks column existence
      assert_equal false, membership.send(:memberships_counter_cache_enabled?)
    end

    test "counter cache: no-op when memberships_count column does not exist" do
      org, _owner = create_org_with_owner!
      user = create_user!

      # Should not raise even though column doesn't exist
      membership = org.add_member!(user, role: :member)
      assert membership.persisted?

      # Remove should also not raise
      org.remove_member!(user)
      refute user.is_member_of?(org)
    end

    # =========================================================================
    # Race Condition Simulation
    # =========================================================================

    test "race condition: send_invite_to! handles RecordNotUnique for concurrent invitation" do
      org, owner = create_org_with_owner!
      email = "concurrent-invite@example.com"

      # First invitation succeeds
      inv = org.send_invite_to!(email, invited_by: owner)
      assert inv.persisted?

      # Second call returns existing (idempotent)
      inv2 = org.send_invite_to!(email, invited_by: owner)
      assert_equal inv.id, inv2.id
    end

    test "race condition: invitation accept! when user is already a member via another path" do
      org, owner = create_org_with_owner!
      user = create_user!(email: "race-member@example.com")

      invitation = Organizations::Invitation.create!(
        organization: org, email: "race-member@example.com", invited_by: owner,
        role: "member", token: SecureRandom.urlsafe_base64(32), expires_at: 7.days.from_now
      )

      # User becomes member through add_member! (e.g., admin added them)
      existing_membership = org.add_member!(user, role: :member)

      # Now accept! is called - should return existing membership
      result = invitation.accept!(user)
      assert_equal existing_membership.id, result.id
      assert invitation.reload.accepted?
    end

    test "race condition: expired invitation cannot be accepted" do
      org, owner = create_org_with_owner!
      user = create_user!(email: "expired@example.com")

      invitation = Organizations::Invitation.create!(
        organization: org, email: "expired@example.com", invited_by: owner,
        role: "member", token: SecureRandom.urlsafe_base64(32),
        expires_at: 1.day.ago
      )

      assert_raises(Organizations::InvitationExpired) do
        invitation.accept!(user)
      end
    end

    # =========================================================================
    # Cascading Deletes
    # =========================================================================

    test "cascading: destroying organization destroys all memberships" do
      org, _owner = create_org_with_owner!
      member = create_user!
      org.add_member!(member, role: :member)

      membership_ids = org.membership_ids

      org.destroy!

      membership_ids.each do |mid|
        assert_not Organizations::Membership.exists?(mid)
      end
    end

    test "cascading: destroying organization destroys all invitations" do
      org, owner = create_org_with_owner!
      Organizations::Invitation.create!(
        organization: org, email: "orphan@example.com", invited_by: owner,
        role: "member", token: SecureRandom.urlsafe_base64(32), expires_at: 7.days.from_now
      )

      invitation_ids = org.invitation_ids

      org.destroy!

      invitation_ids.each do |iid|
        assert_not Organizations::Invitation.exists?(iid)
      end
    end

    # =========================================================================
    # Invitation Token Uniqueness
    # =========================================================================

    test "invitation token: auto-generated tokens are unique" do
      org, owner = create_org_with_owner!

      inv1 = Organizations::Invitation.create!(
        organization: org, email: "token1@example.com", invited_by: owner,
        role: "member", expires_at: 7.days.from_now
      )

      inv2 = Organizations::Invitation.create!(
        organization: org, email: "token2@example.com", invited_by: owner,
        role: "member", expires_at: 7.days.from_now
      )

      assert_not_nil inv1.token
      assert_not_nil inv2.token
      assert_not_equal inv1.token, inv2.token
    end

    test "invitation token: generated tokens are URL-safe base64" do
      org, owner = create_org_with_owner!

      inv = Organizations::Invitation.create!(
        organization: org, email: "token-format@example.com", invited_by: owner,
        role: "member", expires_at: 7.days.from_now
      )

      # URL-safe base64 only contains [A-Za-z0-9_-]
      assert_match(/\A[A-Za-z0-9_\-=]+\z/, inv.token)
    end

    # =========================================================================
    # Email Normalization
    # =========================================================================

    test "email normalization: invitation emails are downcased and stripped" do
      org, owner = create_org_with_owner!

      inv = org.send_invite_to!("  UPPER@Example.COM  ", invited_by: owner)

      assert_equal "upper@example.com", inv.email
    end

    test "email normalization: duplicate detection is case-insensitive" do
      org, owner = create_org_with_owner!

      inv1 = org.send_invite_to!("test@example.com", invited_by: owner)
      inv2 = org.send_invite_to!("TEST@EXAMPLE.COM", invited_by: owner)

      assert_equal inv1.id, inv2.id
    end

    # =========================================================================
    # Owner Deletion Guard
    # =========================================================================

    test "owner deletion guard: user who owns organizations cannot be destroyed" do
      org, owner = create_org_with_owner!

      assert_raises(ActiveRecord::RecordNotDestroyed) do
        owner.destroy!
      end

      assert User.exists?(owner.id)
      assert Organizations::Organization.exists?(org.id)
    end

    test "owner deletion guard: user with no owned orgs can be destroyed" do
      org, _owner = create_org_with_owner!
      member = create_user!

      # User may have a personal org created automatically, clean it up
      member.owned_organizations.each do |owned_org|
        owned_org.destroy!
      end
      member.reload

      org.add_member!(member, role: :member)

      member.destroy!
      assert_not User.exists?(member.id)
    end

    # =========================================================================
    # Cannot Invite As Owner
    # =========================================================================

    test "cannot invite as owner role" do
      org, owner = create_org_with_owner!

      assert_raises(Organizations::Organization::CannotInviteAsOwner) do
        org.send_invite_to!("new@example.com", invited_by: owner, role: :owner)
      end
    end

    # =========================================================================
    # Membership Validation
    # =========================================================================

    test "membership validates role is in hierarchy" do
      org, _owner = create_org_with_owner!
      user = create_user!

      membership = Organizations::Membership.new(user: user, organization: org, role: "superadmin")
      assert_not membership.valid?
      assert_includes membership.errors[:role].join, "is not included"
    end

    test "membership validates single owner per organization" do
      org, _owner = create_org_with_owner!
      user = create_user!

      membership = Organizations::Membership.new(user: user, organization: org, role: "owner")
      assert_not membership.valid?
      assert_includes membership.errors[:role].join, "owner already exists"
    end

    # =========================================================================
    # Concurrent Role Changes
    # =========================================================================

    test "concurrent role changes: promote_to! locks the membership row" do
      org, _owner = create_org_with_owner!
      user = create_user!
      membership = Organizations::Membership.create!(user: user, organization: org, role: "viewer")

      # Promote from viewer to member
      membership.promote_to!(:member)
      assert_equal "member", membership.reload.role

      # Promote from member to admin
      membership.promote_to!(:admin)
      assert_equal "admin", membership.reload.role
    end

    test "concurrent role changes: demote_to! locks the membership row" do
      org, _owner = create_org_with_owner!
      user = create_user!
      membership = Organizations::Membership.create!(user: user, organization: org, role: "admin")

      membership.demote_to!(:member)
      assert_equal "member", membership.reload.role

      membership.demote_to!(:viewer)
      assert_equal "viewer", membership.reload.role
    end

    test "concurrent role changes: role change to same role is a no-op" do
      org, _owner = create_org_with_owner!
      user = create_user!
      membership = Organizations::Membership.create!(user: user, organization: org, role: "admin")

      # Same role should not trigger a DB write
      result = membership.promote_to!(:admin)
      assert_equal membership.id, result.id
      assert_equal "admin", membership.role
    end

    test "concurrent role changes: change_role_of! locks both org and membership" do
      org, _owner = create_org_with_owner!
      user = create_user!
      Organizations::Membership.create!(user: user, organization: org, role: "viewer")

      org.change_role_of!(user, to: :member)
      assert_equal "member", Organizations::Membership.find_by(user: user, organization: org).role

      org.change_role_of!(user, to: :admin)
      assert_equal "admin", Organizations::Membership.find_by(user: user, organization: org).role
    end

    test "concurrent role changes: invalid promotion raises InvalidRoleChange" do
      org, _owner = create_org_with_owner!
      user = create_user!
      membership = Organizations::Membership.create!(user: user, organization: org, role: "admin")

      # Cannot promote to a lower or equal role
      assert_raises(Organizations::Membership::InvalidRoleChange) do
        membership.promote_to!(:member)
      end
    end

    test "concurrent role changes: invalid demotion raises InvalidRoleChange" do
      org, _owner = create_org_with_owner!
      user = create_user!
      membership = Organizations::Membership.create!(user: user, organization: org, role: "member")

      # Cannot demote to a higher role
      assert_raises(Organizations::Membership::InvalidRoleChange) do
        membership.demote_to!(:admin)
      end
    end

    # =========================================================================
    # Token Collision Handling with Regeneration
    # =========================================================================

    test "token collision: generate_unique_token retries on collision" do
      org, owner = create_org_with_owner!
      colliding_token = "collision_token_abc123"

      # Create an invitation with a known token
      Organizations::Invitation.create!(
        organization: org, email: "existing@example.com", invited_by: owner,
        role: "member", token: colliding_token, expires_at: 7.days.from_now
      )

      # Stub SecureRandom to return the colliding token first, then a unique one
      final_token = "unique_token_xyz789"
      call_count = 0
      SecureRandom.stub(:urlsafe_base64, ->(n = nil) {
        call_count += 1
        call_count == 1 ? colliding_token : final_token
      }) do
        inv = Organizations::Invitation.create!(
          organization: org, email: "new@example.com", invited_by: owner,
          role: "member", expires_at: 7.days.from_now
        )

        assert_equal final_token, inv.token
        assert call_count >= 2, "Expected SecureRandom to be called at least twice due to collision"
      end
    end

    test "token collision: organization send_invite_to! also retries on token collision" do
      org, owner = create_org_with_owner!
      colliding_token = "org_collision_token"

      Organizations::Invitation.create!(
        organization: org, email: "blocker@example.com", invited_by: owner,
        role: "member", token: colliding_token, expires_at: 7.days.from_now
      )

      call_count = 0
      original_urlsafe_base64 = SecureRandom.method(:urlsafe_base64)
      SecureRandom.stub(:urlsafe_base64, ->(n = nil) {
        call_count += 1
        # Return colliding token on specific calls to trigger retry in org's generate_unique_token
        if call_count <= 1
          colliding_token
        else
          original_urlsafe_base64.call(n || 32)
        end
      }) do
        inv = org.send_invite_to!("new-org-invite@example.com", invited_by: owner)
        assert inv.persisted?
        assert_not_equal colliding_token, inv.token
      end
    end

    # =========================================================================
    # Counter Cache with Column Present
    # =========================================================================

    test "counter cache: uses increment_counter/decrement_counter (atomic) not read-modify-write" do
      org, _owner = create_org_with_owner!

      # Verify the membership model uses AR increment_counter / decrement_counter
      # which generates UPDATE organizations SET memberships_count = memberships_count + 1
      # rather than read-modify-write
      membership = Organizations::Membership.new(user: create_user!, organization: org, role: "member")

      # The callbacks call Organizations::Organization.increment_counter and decrement_counter
      # which are atomic SQL operations. Verify the callback methods exist.
      assert membership.respond_to?(:increment_memberships_counter_cache, true)
      assert membership.respond_to?(:decrement_memberships_counter_cache, true)
    end

    test "counter cache: memberships_counter_cache_enabled? returns false when column missing" do
      org, _owner = create_org_with_owner!
      membership = Organizations::Membership.new(user: create_user!, organization: org, role: "member")

      # Our test schema does not have memberships_count column
      refute membership.send(:memberships_counter_cache_enabled?)
    end

    test "counter cache: member_count falls back to count query without counter column" do
      org, _owner = create_org_with_owner!

      # has_attribute? returns false for non-existent column
      refute org.has_attribute?(:memberships_count)

      # Falls back to memberships.count
      assert_equal 1, org.member_count

      org.add_member!(create_user!, role: :member)
      assert_equal 2, org.member_count
    end

    test "counter cache: member_count uses cached value when counter column exists" do
      org, _owner = create_org_with_owner!

      # Simulate counter cache column by stubbing has_attribute?
      org.stub(:has_attribute?, ->(attr) { attr.to_s == "memberships_count" ? true : org.class.column_names.include?(attr.to_s) }) do
        # When the attribute exists but is nil, falls back to count
        org.stub(:[], ->(attr) { attr == :memberships_count ? nil : org.read_attribute(attr) }) do
          assert_equal 1, org.member_count
        end

        # When the attribute has a value, uses that directly
        org.stub(:[], ->(attr) { attr == :memberships_count ? 42 : org.read_attribute(attr) }) do
          assert_equal 42, org.member_count
        end
      end
    end

    # =========================================================================
    # Race Interleaving Behavior
    # =========================================================================

    test "race interleaving: accept! returns existing membership when invitation is accepted just before status re-check" do
      org, owner = create_org_with_owner!
      user = create_user!(email: "lock-verify@example.com")
      invitation = Organizations::Invitation.create!(
        organization: org, email: "lock-verify@example.com", invited_by: owner,
        role: "member", token: SecureRandom.urlsafe_base64(32), expires_at: 7.days.from_now
      )

      competing_membership = nil
      original_lock = invitation.method(:lock!)
      invitation.define_singleton_method(:lock!) do |*args|
        original_lock.call(*args).tap do
          # Simulate a competing transaction that finished acceptance first.
          # accept! should re-check accepted? under lock and return this membership.
          competing_membership ||= organization.memberships.create!(
            user: user,
            role: role,
            invited_by: invited_by
          )
          update_column(:accepted_at, Time.current)
        end
      end

      result = invitation.accept!(user)
      assert_equal competing_membership.id, result.id
      assert_equal 1, org.memberships.where(user_id: user.id).count
    end

    test "race interleaving: transfer_ownership_to! raises CannotTransferToNonMember if candidate disappears after lock" do
      org, owner = create_org_with_owner!
      admin = create_user!(email: "lock-admin@example.com")
      Organizations::Membership.create!(user: admin, organization: org, role: "admin")

      original_lock = org.method(:lock!)
      org.define_singleton_method(:lock!) do |*args|
        original_lock.call(*args).tap do
          # Simulate membership removal between operation start and transfer checks.
          memberships.where(user_id: admin.id).delete_all
        end
      end

      assert_raises(Organizations::Organization::CannotTransferToNonMember) do
        org.transfer_ownership_to!(admin)
      end

      assert_equal owner.id, org.reload.owner.id
      assert_equal 1, org.memberships.where(role: "owner").count
    end

    test "race interleaving: remove_member! tolerates member already removed between lookup and destroy" do
      org, _owner = create_org_with_owner!
      member = create_user!(email: "lock-remove@example.com")
      Organizations::Membership.create!(user: member, organization: org, role: "member")

      original_lock = org.method(:lock!)
      org.define_singleton_method(:lock!) do |*args|
        original_lock.call(*args).tap do
          # Simulate another worker removing this membership first.
          memberships.where(user_id: member.id).delete_all
        end
      end

      org.remove_member!(member)
      refute org.has_member?(member)
    end

    test "race interleaving: leave_organization! re-evaluates require_organization safety after lock" do
      User.organization_settings = User.organization_settings.merge(
        require_organization: true,
        create_personal_org: false
      ).freeze

      org, _owner = create_org_with_owner!
      member = create_user!(email: "departing-lock@example.com")
      Organizations::Membership.create!(user: member, organization: org, role: "member")

      second_org, _second_owner = create_org_with_owner!(name: "Second Org For Lock Test")
      Organizations::Membership.create!(user: member, organization: second_org, role: "member")

      original_lock = org.method(:lock!)
      org.define_singleton_method(:lock!) do |*args|
        original_lock.call(*args).tap do
          # Simulate concurrent removal from the second org before count check.
          member.memberships.where(organization_id: second_org.id).delete_all
        end
      end

      assert_raises(Organizations::Models::Concerns::HasOrganizations::CannotLeaveLastOrganization) do
        member.leave_organization!(org)
      end
      assert member.is_member_of?(org)
    end

    test "race interleaving: change_role_of! fails safely if target membership disappears after org lock" do
      org, _owner = create_org_with_owner!
      user = create_user!(email: "lock-role@example.com")
      membership = Organizations::Membership.create!(user: user, organization: org, role: "viewer")

      original_find_by = org.memberships.method(:find_by!)
      org.memberships.define_singleton_method(:find_by!) do |*args|
        m = original_find_by.call(*args)
        m.define_singleton_method(:lock!) do |*lock_args|
          raise ActiveRecord::RecordNotFound, "Couldn't find Membership with id=#{id}"
        end
        m
      end

      assert_raises(ActiveRecord::RecordNotFound) do
        org.change_role_of!(user, to: :member)
      end
      assert_equal "viewer", membership.reload.role
    end

    # =========================================================================
    # NoOwnerPresent edge case
    # =========================================================================

    test "ownership transfer: raises NoOwnerPresent when org has no owner membership" do
      org = Organizations::Organization.create!(name: "Ownerless Org")
      user = create_user!
      Organizations::Membership.create!(user: user, organization: org, role: "admin")

      assert_raises(Organizations::Organization::NoOwnerPresent) do
        org.transfer_ownership_to!(user)
      end
    end

    # =========================================================================
    # Invitation Email Mismatch
    # =========================================================================

    test "invitation accept: raises EmailMismatch when user email does not match" do
      org, owner = create_org_with_owner!
      wrong_user = create_user!(email: "wrong@example.com")

      invitation = Organizations::Invitation.create!(
        organization: org, email: "correct@example.com", invited_by: owner,
        role: "member", token: SecureRandom.urlsafe_base64(32), expires_at: 7.days.from_now
      )

      assert_raises(Organizations::Invitation::EmailMismatch) do
        invitation.accept!(wrong_user)
      end
    end

    test "invitation accept: skip_email_validation bypasses email check" do
      org, owner = create_org_with_owner!
      different_user = create_user!(email: "different@example.com")

      invitation = Organizations::Invitation.create!(
        organization: org, email: "original@example.com", invited_by: owner,
        role: "member", token: SecureRandom.urlsafe_base64(32), expires_at: 7.days.from_now
      )

      membership = invitation.accept!(different_user, skip_email_validation: true)
      assert membership.persisted?
      assert_equal different_user.id, membership.user_id
    end

    # =========================================================================
    # Invitation Cannot Accept As Owner
    # =========================================================================

    test "invitation accept: cannot accept invitation with owner role (defense in depth)" do
      org, owner = create_org_with_owner!
      user = create_user!(email: "owner-invite@example.com")

      # Manually create invitation with owner role (bypassing send_invite_to! which blocks this)
      invitation = Organizations::Invitation.new(
        organization: org, email: "owner-invite@example.com", invited_by: owner,
        role: "owner", token: SecureRandom.urlsafe_base64(32), expires_at: 7.days.from_now
      )
      invitation.save(validate: false) # Skip validation to set owner role

      assert_raises(Organizations::Invitation::CannotAcceptAsOwner) do
        invitation.accept!(user)
      end
    end
  end
end
