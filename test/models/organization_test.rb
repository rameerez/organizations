# frozen_string_literal: true

require "test_helper"

module Organizations
  class OrganizationTest < Organizations::Test
    # =========================================================================
    # Associations
    # =========================================================================

    test "has many memberships" do
      org, owner = create_org_with_owner!
      member = create_user!(email: "member@example.com")
      Membership.create!(user: member, organization: org, role: "member")

      assert_equal 2, org.memberships.count
      assert org.memberships.all? { |m| m.is_a?(Membership) }
    end

    test "has many users through memberships" do
      org, owner = create_org_with_owner!
      member = create_user!(email: "member@example.com")
      Membership.create!(user: member, organization: org, role: "member")

      assert_includes org.users, owner
      assert_includes org.users, member
      assert_equal 2, org.users.count
    end

    test "members is an alias for users" do
      org, owner = create_org_with_owner!

      assert_equal org.users.to_a, org.members.to_a
    end

    test "has many invitations" do
      org, owner = create_org_with_owner!
      Invitation.create!(
        organization: org,
        email: "invite@example.com",
        invited_by: owner,
        role: "member",
        token: SecureRandom.urlsafe_base64(32),
        expires_at: 7.days.from_now
      )

      assert_equal 1, org.invitations.count
      assert org.invitations.first.is_a?(Invitation)
    end

    test "pending_invitations returns only non-expired, non-accepted invitations" do
      org, owner = create_org_with_owner!

      # Pending invitation
      pending = Invitation.create!(
        organization: org,
        email: "pending@example.com",
        invited_by: owner,
        role: "member",
        token: SecureRandom.urlsafe_base64(32),
        expires_at: 7.days.from_now
      )

      # Accepted invitation
      Invitation.create!(
        organization: org,
        email: "accepted@example.com",
        invited_by: owner,
        role: "member",
        token: SecureRandom.urlsafe_base64(32),
        expires_at: 7.days.from_now,
        accepted_at: Time.current
      )

      # Expired invitation
      Invitation.create!(
        organization: org,
        email: "expired@example.com",
        invited_by: owner,
        role: "member",
        token: SecureRandom.urlsafe_base64(32),
        expires_at: 1.day.ago
      )

      assert_equal [pending], org.pending_invitations.to_a
    end

    test "destroying organization destroys memberships" do
      org, _owner = create_org_with_owner!

      assert_difference -> { Membership.count }, -1 do
        org.destroy!
      end
    end

    test "destroying organization destroys invitations" do
      org, owner = create_org_with_owner!
      Invitation.create!(
        organization: org,
        email: "test@example.com",
        invited_by: owner,
        role: "member",
        token: SecureRandom.urlsafe_base64(32),
        expires_at: 7.days.from_now
      )

      org.destroy!
      assert_equal 0, Invitation.count
    end

    # =========================================================================
    # Validations
    # =========================================================================

    test "requires name" do
      org = Organization.new(name: nil)
      assert_not org.valid?
      assert_includes org.errors[:name], "can't be blank"
    end

    test "requires slug" do
      # before_validation auto-computes slug from name, so we need to
      # bypass that by creating a record and then blanking the slug
      org = Organization.new(name: nil, slug: nil)
      assert_not org.valid?
      assert_includes org.errors[:slug], "can't be blank"
    end

    test "enforces slug uniqueness case-insensitively" do
      Organization.create!(name: "First Org")

      duplicate = Organization.new(name: "Something Else")
      duplicate.slug = "first-org"
      assert_not duplicate.valid?
      assert_includes duplicate.errors[:slug], "has already been taken"
    end

    # =========================================================================
    # Slug Generation
    # =========================================================================

    test "generates slug from name on create" do
      org = Organization.create!(name: "Acme Corporation")
      assert_equal "acme-corporation", org.slug
    end

    test "duplicate names get unique slugs with suffix" do
      org1 = Organization.create!(name: "Test Company")
      org2 = Organization.create!(name: "Test Company")

      assert_equal "test-company", org1.slug
      assert org2.slug.start_with?("test-company-")
      assert_not_equal org1.slug, org2.slug
    end

    test "slug does not change when name changes" do
      org = Organization.create!(name: "Original Name")
      original_slug = org.slug

      org.update!(name: "Updated Name")
      assert_equal original_slug, org.slug
    end

    # =========================================================================
    # Scopes
    # =========================================================================

    test "with_member returns only organizations where user is a member" do
      user = create_user!(email: "multi@example.com")
      org1, _owner1 = create_org_with_owner!(name: "Org One")
      org2, _owner2 = create_org_with_owner!(name: "Org Two")
      _org3, _owner3 = create_org_with_owner!(name: "Org Three")

      Membership.create!(user: user, organization: org1, role: "member")
      Membership.create!(user: user, organization: org2, role: "admin")

      orgs = Organization.with_member(user)
      assert_includes orgs, org1
      assert_includes orgs, org2
      assert_not_includes orgs, _org3
    end

    # =========================================================================
    # Query Methods: owner
    # =========================================================================

    test "owner returns the owner user" do
      org, owner = create_org_with_owner!

      assert_equal owner, org.owner
    end

    test "owner returns nil when no owner membership exists" do
      org = Organization.create!(name: "No Owner Org")

      assert_nil org.owner
    end

    test "owner_membership returns the owner's membership" do
      org, owner = create_org_with_owner!

      membership = org.owner_membership
      assert_equal owner, membership.user
      assert_equal "owner", membership.role
    end

    # =========================================================================
    # Query Methods: admins
    # =========================================================================

    test "admins returns users with admin role or higher" do
      org, owner = create_org_with_owner!
      admin = create_user!(email: "admin@example.com")
      member = create_user!(email: "member@example.com")
      Membership.create!(user: admin, organization: org, role: "admin")
      Membership.create!(user: member, organization: org, role: "member")

      admins = org.admins
      assert_includes admins, owner
      assert_includes admins, admin
      assert_not_includes admins, member
    end

    test "admins returns no duplicates" do
      org, owner = create_org_with_owner!
      admin = create_user!(email: "admin@example.com")
      Membership.create!(user: admin, organization: org, role: "admin")

      admins = org.admins
      assert_equal admins.to_a.uniq.size, admins.to_a.size
    end

    # =========================================================================
    # Query Methods: has_member? / has_any_members?
    # =========================================================================

    test "has_member? returns true for an existing member" do
      org, owner = create_org_with_owner!

      assert org.has_member?(owner)
    end

    test "has_member? returns false for a non-member" do
      org, _owner = create_org_with_owner!
      outsider = create_user!(email: "outsider@example.com")

      assert_not org.has_member?(outsider)
    end

    test "has_member? returns false for nil" do
      org, _owner = create_org_with_owner!

      assert_not org.has_member?(nil)
    end

    test "has_any_members? returns true when members exist" do
      org, _owner = create_org_with_owner!

      assert org.has_any_members?
    end

    test "has_any_members? returns false when no members exist" do
      org = Organization.create!(name: "Empty Org")

      assert_not org.has_any_members?
    end

    # =========================================================================
    # Query Methods: member_count
    # =========================================================================

    test "member_count returns the number of memberships" do
      org, _owner = create_org_with_owner!
      member = create_user!(email: "member@example.com")
      Membership.create!(user: member, organization: org, role: "member")

      assert_equal 2, org.member_count
    end

    test "member_count works without memberships_count column" do
      org, _owner = create_org_with_owner!

      # The test schema doesn't have memberships_count column,
      # so this exercises the COUNT(*) fallback
      assert_equal 1, org.member_count
    end

    # =========================================================================
    # Action Methods: add_member!
    # =========================================================================

    test "add_member! creates a membership with the given role" do
      org, _owner = create_org_with_owner!
      user = create_user!(email: "new@example.com")

      membership = org.add_member!(user, role: :admin)

      assert_equal "admin", membership.role
      assert_equal user, membership.user
      assert_equal org, membership.organization
    end

    test "add_member! defaults to member role" do
      org, _owner = create_org_with_owner!
      user = create_user!(email: "new@example.com")

      membership = org.add_member!(user)

      assert_equal "member", membership.role
    end

    test "add_member! returns existing membership for idempotency" do
      org, _owner = create_org_with_owner!
      user = create_user!(email: "new@example.com")

      first = org.add_member!(user, role: :admin)
      second = org.add_member!(user, role: :member)

      assert_equal first.id, second.id
      assert_equal "admin", second.role # role unchanged
    end

    test "add_member! with role :owner raises CannotHaveMultipleOwners" do
      org, _owner = create_org_with_owner!
      user = create_user!(email: "new@example.com")

      assert_raises(Organization::CannotHaveMultipleOwners) do
        org.add_member!(user, role: :owner)
      end
    end

    test "add_member! raises ArgumentError for invalid role" do
      org, _owner = create_org_with_owner!
      user = create_user!(email: "new@example.com")

      assert_raises(ArgumentError) do
        org.add_member!(user, role: :superadmin)
      end
    end

    # =========================================================================
    # Action Methods: remove_member!
    # =========================================================================

    test "remove_member! destroys the membership" do
      org, _owner = create_org_with_owner!
      user = create_user!(email: "member@example.com")
      org.add_member!(user)

      org.remove_member!(user)

      assert_not org.has_member?(user)
    end

    test "remove_member! raises CannotRemoveOwner for owner" do
      org, owner = create_org_with_owner!

      assert_raises(Organization::CannotRemoveOwner) do
        org.remove_member!(owner)
      end
    end

    test "remove_member! is a no-op for non-members" do
      org, _owner = create_org_with_owner!
      outsider = create_user!(email: "outsider@example.com")

      assert_no_difference -> { Membership.count } do
        org.remove_member!(outsider)
      end
    end

    # =========================================================================
    # Action Methods: change_role_of!
    # =========================================================================

    test "change_role_of! updates the membership role" do
      org, _owner = create_org_with_owner!
      user = create_user!(email: "member@example.com")
      org.add_member!(user, role: :member)

      membership = org.change_role_of!(user, to: :admin)

      assert_equal "admin", membership.role
    end

    test "change_role_of! is a no-op when role is the same" do
      org, _owner = create_org_with_owner!
      user = create_user!(email: "admin@example.com")
      org.add_member!(user, role: :admin)

      membership = org.change_role_of!(user, to: :admin)
      assert_equal "admin", membership.role
    end

    test "change_role_of! cannot change TO owner role" do
      org, _owner = create_org_with_owner!
      user = create_user!(email: "admin@example.com")
      org.add_member!(user, role: :admin)

      assert_raises(Organization::CannotHaveMultipleOwners) do
        org.change_role_of!(user, to: :owner)
      end
    end

    test "change_role_of! cannot change FROM owner role" do
      org, owner = create_org_with_owner!

      assert_raises(Organization::CannotDemoteOwner) do
        org.change_role_of!(owner, to: :admin)
      end
    end

    test "change_role_of! raises RecordNotFound for non-member" do
      org, _owner = create_org_with_owner!
      outsider = create_user!(email: "outsider@example.com")

      assert_raises(ActiveRecord::RecordNotFound) do
        org.change_role_of!(outsider, to: :admin)
      end
    end

    test "change_role_of! raises ArgumentError for invalid role" do
      org, _owner = create_org_with_owner!
      user = create_user!(email: "member@example.com")
      org.add_member!(user, role: :member)

      assert_raises(ArgumentError) do
        org.change_role_of!(user, to: :superadmin)
      end
    end

    # =========================================================================
    # Action Methods: transfer_ownership_to!
    # =========================================================================

    test "transfer_ownership_to! swaps owner and admin roles" do
      org, owner = create_org_with_owner!
      admin = create_user!(email: "admin@example.com")
      org.add_member!(admin, role: :admin)

      org.transfer_ownership_to!(admin)

      org.reload
      assert_equal admin, org.owner
      assert_equal "admin", Membership.find_by(user: owner, organization: org).role
      assert_equal "owner", Membership.find_by(user: admin, organization: org).role
    end

    test "transfer_ownership_to! is a no-op when transferring to current owner" do
      org, owner = create_org_with_owner!
      # Owner is also at_least?(:admin) so this should be a no-op
      result = org.transfer_ownership_to!(owner)

      assert_equal owner, org.owner
      assert result # returns the existing owner membership
    end

    test "transfer_ownership_to! raises CannotTransferToNonAdmin for member" do
      org, _owner = create_org_with_owner!
      member = create_user!(email: "member@example.com")
      org.add_member!(member, role: :member)

      assert_raises(Organization::CannotTransferToNonAdmin) do
        org.transfer_ownership_to!(member)
      end
    end

    test "transfer_ownership_to! raises CannotTransferToNonMember for non-member" do
      org, _owner = create_org_with_owner!
      outsider = create_user!(email: "outsider@example.com")

      assert_raises(Organization::CannotTransferToNonMember) do
        org.transfer_ownership_to!(outsider)
      end
    end

    test "transfer_ownership_to! raises NoOwnerPresent when org has no owner" do
      org = Organization.create!(name: "Orphan Org")
      admin = create_user!(email: "admin@example.com")
      Membership.create!(user: admin, organization: org, role: "admin")

      assert_raises(Organization::NoOwnerPresent) do
        org.transfer_ownership_to!(admin)
      end
    end

    test "transfer_ownership_to! raises CannotTransferToNonAdmin for viewer" do
      org, _owner = create_org_with_owner!
      viewer = create_user!(email: "viewer@example.com")
      org.add_member!(viewer, role: :viewer)

      assert_raises(Organization::CannotTransferToNonAdmin) do
        org.transfer_ownership_to!(viewer)
      end
    end

    # =========================================================================
    # Invitation Methods: send_invite_to!
    # =========================================================================

    test "send_invite_to! creates an invitation when inviter has permission" do
      org, owner = create_org_with_owner!

      invitation = org.send_invite_to!("newuser@example.com", invited_by: owner)

      assert_equal "newuser@example.com", invitation.email
      assert_equal owner, invitation.invited_by
      assert_equal "member", invitation.role
      assert invitation.token.present?
      assert invitation.pending?
    end

    test "send_invite_to! normalizes email" do
      org, owner = create_org_with_owner!

      invitation = org.send_invite_to!("  UPPER@Example.COM  ", invited_by: owner)

      assert_equal "upper@example.com", invitation.email
    end

    test "send_invite_to! raises NotAMember when inviter is not a member" do
      org, _owner = create_org_with_owner!
      outsider = create_user!(email: "outsider@example.com")

      assert_raises(Organizations::NotAMember) do
        org.send_invite_to!("new@example.com", invited_by: outsider)
      end
    end

    test "send_invite_to! raises NotAuthorized when inviter lacks permission" do
      org, _owner = create_org_with_owner!
      viewer = create_user!(email: "viewer@example.com")
      org.add_member!(viewer, role: :viewer)

      assert_raises(Organizations::NotAuthorized) do
        org.send_invite_to!("new@example.com", invited_by: viewer)
      end
    end

    test "send_invite_to! raises NotAuthorized for regular member without invite_members permission" do
      org, _owner = create_org_with_owner!
      member = create_user!(email: "member@example.com")
      org.add_member!(member, role: :member)

      assert_raises(Organizations::NotAuthorized) do
        org.send_invite_to!("new@example.com", invited_by: member)
      end
    end

    test "send_invite_to! raises CannotInviteAsOwner when role is owner" do
      org, owner = create_org_with_owner!

      assert_raises(Organization::CannotInviteAsOwner) do
        org.send_invite_to!("new@example.com", invited_by: owner, role: :owner)
      end
    end

    test "send_invite_to! raises error for existing member" do
      org, owner = create_org_with_owner!

      assert_raises(Organizations::InvitationError) do
        org.send_invite_to!(owner.email, invited_by: owner)
      end
    end

    test "send_invite_to! returns existing pending invitation for same email" do
      org, owner = create_org_with_owner!

      first = org.send_invite_to!("repeat@example.com", invited_by: owner)
      second = org.send_invite_to!("repeat@example.com", invited_by: owner)

      assert_equal first.id, second.id
    end

    test "send_invite_to! refreshes an expired invitation" do
      org, owner = create_org_with_owner!

      # Create an expired invitation directly
      expired = Invitation.create!(
        organization: org,
        email: "expired@example.com",
        invited_by: owner,
        role: "member",
        token: SecureRandom.urlsafe_base64(32),
        expires_at: 1.day.ago
      )

      refreshed = org.send_invite_to!("expired@example.com", invited_by: owner)

      assert_equal expired.id, refreshed.id
      assert refreshed.expires_at > Time.current
    end

    test "send_invite_to! uses admin role when specified" do
      org, owner = create_org_with_owner!

      invitation = org.send_invite_to!("admin@example.com", invited_by: owner, role: :admin)

      assert_equal "admin", invitation.role
    end

    test "send_invite_to! raises ArgumentError when no inviter provided and no Current.user" do
      org, _owner = create_org_with_owner!

      assert_raises(ArgumentError) do
        org.send_invite_to!("new@example.com")
      end
    end

    # =========================================================================
    # Edge Cases
    # =========================================================================

    test "organization with no members for corrupted state testing" do
      org = Organization.create!(name: "Ghost Org")

      assert_nil org.owner
      assert_not org.has_any_members?
      assert_equal 0, org.member_count
      assert_empty org.admins
    end

    test "counter cache is optional and falls back to COUNT" do
      org, _owner = create_org_with_owner!

      # The test schema has no memberships_count column, so
      # has_attribute?(:memberships_count) returns false and
      # member_count falls back to COUNT(*)
      assert_not org.has_attribute?(:memberships_count)
      assert_equal 1, org.member_count
    end
  end
end
