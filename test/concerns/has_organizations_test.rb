# frozen_string_literal: true

require "test_helper"

module Organizations
  class HasOrganizationsTest < Organizations::Test
    def setup
      super
      # Disable personal org auto-creation for most tests to keep them isolated
      User.organization_settings = { max_organizations: nil, create_personal_org: false, require_organization: false }.freeze
    end

    def teardown
      User.organization_settings = { max_organizations: nil, create_personal_org: false, require_organization: false }.freeze
      super
    end

    # =========================================================================
    # Associations
    # =========================================================================

    test "organizations returns all orgs user belongs to" do
      user = create_user!
      org1 = Organizations::Organization.create!(name: "Org One")
      org2 = Organizations::Organization.create!(name: "Org Two")
      Organizations::Membership.create!(user: user, organization: org1, role: "member")
      Organizations::Membership.create!(user: user, organization: org2, role: "admin")

      assert_equal 2, user.organizations.count
      assert_includes user.organizations, org1
      assert_includes user.organizations, org2
    end

    test "memberships returns all memberships" do
      user = create_user!
      org1 = Organizations::Organization.create!(name: "Org A")
      org2 = Organizations::Organization.create!(name: "Org B")
      m1 = Organizations::Membership.create!(user: user, organization: org1, role: "owner")
      m2 = Organizations::Membership.create!(user: user, organization: org2, role: "member")

      assert_equal 2, user.memberships.count
      assert_includes user.memberships, m1
      assert_includes user.memberships, m2
    end

    test "owned_organizations returns only orgs where role is owner" do
      user = create_user!
      owned = Organizations::Organization.create!(name: "Owned")
      not_owned = Organizations::Organization.create!(name: "Not Owned")
      Organizations::Membership.create!(user: user, organization: owned, role: "owner")
      Organizations::Membership.create!(user: user, organization: not_owned, role: "admin")

      assert_equal 1, user.owned_organizations.count
      assert_includes user.owned_organizations, owned
      refute_includes user.owned_organizations, not_owned
    end

    test "pending_organization_invitations returns invitations for user email" do
      user = create_user!(email: "invited@example.com")
      org = Organizations::Organization.create!(name: "Inviting Org")
      inviter = create_user!
      Organizations::Membership.create!(user: inviter, organization: org, role: "owner")

      invitation = Organizations::Invitation.create!(
        organization: org,
        email: "invited@example.com",
        invited_by: inviter,
        role: "member",
        token: SecureRandom.urlsafe_base64(32),
        expires_at: 7.days.from_now
      )

      assert_equal 1, user.pending_organization_invitations.count
      assert_includes user.pending_organization_invitations, invitation
    end

    test "pending_organization_invitations returns none when no invitations exist" do
      user = create_user!

      assert_equal 0, user.pending_organization_invitations.count
    end

    test "sent_organization_invitations tracks invitations sent by user" do
      user = create_user!
      org = Organizations::Organization.create!(name: "My Org")
      Organizations::Membership.create!(user: user, organization: org, role: "owner")

      invitation = Organizations::Invitation.create!(
        organization: org,
        email: "someone@example.com",
        invited_by: user,
        role: "member",
        token: SecureRandom.urlsafe_base64(32),
        expires_at: 7.days.from_now
      )

      assert_includes user.sent_organization_invitations, invitation
    end

    test "destroying user destroys memberships via dependent destroy" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Temp Org")
      Organizations::Membership.create!(user: user, organization: org, role: "member")

      assert_equal 1, Organizations::Membership.where(user_id: user.id).count
      user.destroy!
      assert_equal 0, Organizations::Membership.where(user_id: user.id).count
    end

    test "destroying user nullifies sent invitations via dependent nullify" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Inv Org")
      Organizations::Membership.create!(user: user, organization: org, role: "admin")
      owner = create_user!
      Organizations::Membership.create!(user: owner, organization: org, role: "owner")

      invitation = Organizations::Invitation.create!(
        organization: org,
        email: "someone@example.com",
        invited_by: user,
        role: "member",
        token: SecureRandom.urlsafe_base64(32),
        expires_at: 7.days.from_now
      )

      user.destroy!
      invitation.reload
      assert_nil invitation.invited_by_id
    end

    # =========================================================================
    # Current Organization Context
    # =========================================================================

    test "current_organization returns nil when no current org set" do
      user = create_user!

      assert_nil user.current_organization
    end

    test "current_organization returns the org matching _current_organization_id" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Active Org")
      Organizations::Membership.create!(user: user, organization: org, role: "member")
      user._current_organization_id = org.id

      assert_equal org, user.current_organization
    end

    test "organization is alias for current_organization" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Alias Org")
      Organizations::Membership.create!(user: user, organization: org, role: "member")
      user._current_organization_id = org.id

      assert_equal user.current_organization, user.organization
    end

    test "current_organization returns nil for non-member org id" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Other Org")
      user._current_organization_id = org.id

      assert_nil user.current_organization
    end

    test "current_membership returns membership in active org" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Current Org")
      membership = Organizations::Membership.create!(user: user, organization: org, role: "admin")
      user._current_organization_id = org.id

      assert_equal membership, user.current_membership
    end

    test "current_membership returns nil when no current org" do
      user = create_user!

      assert_nil user.current_membership
    end

    test "current_organization_role returns role symbol in current org" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Role Org")
      Organizations::Membership.create!(user: user, organization: org, role: "admin")
      user._current_organization_id = org.id

      assert_equal :admin, user.current_organization_role
    end

    test "current_organization_role returns nil when no current org" do
      user = create_user!

      assert_nil user.current_organization_role
    end

    test "_current_organization_id stores the current org id" do
      user = create_user!

      assert_nil user._current_organization_id

      user._current_organization_id = 42
      assert_equal 42, user._current_organization_id
    end

    # =========================================================================
    # Boolean Checks
    # =========================================================================

    test "belongs_to_any_organization? returns true when user has memberships" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Some Org")
      Organizations::Membership.create!(user: user, organization: org, role: "member")

      assert user.belongs_to_any_organization?
    end

    test "belongs_to_any_organization? returns false with no memberships" do
      user = create_user!

      refute user.belongs_to_any_organization?
    end

    test "has_pending_organization_invitations? returns true with pending invites" do
      user = create_user!(email: "pending@example.com")
      org = Organizations::Organization.create!(name: "Pending Org")
      inviter = create_user!
      Organizations::Membership.create!(user: inviter, organization: org, role: "owner")

      Organizations::Invitation.create!(
        organization: org,
        email: "pending@example.com",
        invited_by: inviter,
        role: "member",
        token: SecureRandom.urlsafe_base64(32),
        expires_at: 7.days.from_now
      )

      assert user.has_pending_organization_invitations?
    end

    test "has_pending_organization_invitations? returns false with no invites" do
      user = create_user!

      refute user.has_pending_organization_invitations?
    end

    test "has_pending_organization_invitations? returns false for accepted invites" do
      user = create_user!(email: "accepted@example.com")
      org = Organizations::Organization.create!(name: "Accepted Org")
      inviter = create_user!
      Organizations::Membership.create!(user: inviter, organization: org, role: "owner")

      Organizations::Invitation.create!(
        organization: org,
        email: "accepted@example.com",
        invited_by: inviter,
        role: "member",
        token: SecureRandom.urlsafe_base64(32),
        expires_at: 7.days.from_now,
        accepted_at: Time.current
      )

      refute user.has_pending_organization_invitations?
    end

    test "has_pending_organization_invitations? returns false for expired invites" do
      user = create_user!(email: "expired@example.com")
      org = Organizations::Organization.create!(name: "Expired Org")
      inviter = create_user!
      Organizations::Membership.create!(user: inviter, organization: org, role: "owner")

      Organizations::Invitation.create!(
        organization: org,
        email: "expired@example.com",
        invited_by: inviter,
        role: "member",
        token: SecureRandom.urlsafe_base64(32),
        expires_at: 1.day.ago
      )

      refute user.has_pending_organization_invitations?
    end

    # =========================================================================
    # Permission Checks (current organization)
    # =========================================================================

    test "has_organization_permission_to? returns true when role has permission" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Perm Org")
      Organizations::Membership.create!(user: user, organization: org, role: "admin")
      user._current_organization_id = org.id

      assert user.has_organization_permission_to?(:invite_members)
    end

    test "has_organization_permission_to? returns false when role lacks permission" do
      user = create_user!
      org = Organizations::Organization.create!(name: "No Perm Org")
      Organizations::Membership.create!(user: user, organization: org, role: "member")
      user._current_organization_id = org.id

      refute user.has_organization_permission_to?(:invite_members)
    end

    test "has_organization_permission_to? returns false with no current org" do
      user = create_user!

      refute user.has_organization_permission_to?(:view_organization)
    end

    test "has_organization_role? checks role hierarchy" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Hierarchy Org")
      Organizations::Membership.create!(user: user, organization: org, role: "admin")
      user._current_organization_id = org.id

      assert user.has_organization_role?(:admin)
      assert user.has_organization_role?(:member)
      assert user.has_organization_role?(:viewer)
      refute user.has_organization_role?(:owner)
    end

    test "has_organization_role? returns false with no current org" do
      user = create_user!

      refute user.has_organization_role?(:member)
    end

    # =========================================================================
    # Role Shortcuts (current organization)
    # =========================================================================

    test "is_organization_owner? returns true for owner" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Owner Org")
      Organizations::Membership.create!(user: user, organization: org, role: "owner")
      user._current_organization_id = org.id

      assert user.is_organization_owner?
    end

    test "is_organization_owner? returns false for admin" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Not Owner Org")
      Organizations::Membership.create!(user: user, organization: org, role: "admin")
      user._current_organization_id = org.id

      refute user.is_organization_owner?
    end

    test "is_organization_admin? returns true for admin" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Admin Org")
      Organizations::Membership.create!(user: user, organization: org, role: "admin")
      user._current_organization_id = org.id

      assert user.is_organization_admin?
    end

    test "is_organization_admin? returns true for owner (higher)" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Owner Admin Org")
      Organizations::Membership.create!(user: user, organization: org, role: "owner")
      user._current_organization_id = org.id

      assert user.is_organization_admin?
    end

    test "is_organization_admin? returns false for member" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Member Only")
      Organizations::Membership.create!(user: user, organization: org, role: "member")
      user._current_organization_id = org.id

      refute user.is_organization_admin?
    end

    test "is_organization_member? returns true for member" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Member Org")
      Organizations::Membership.create!(user: user, organization: org, role: "member")
      user._current_organization_id = org.id

      assert user.is_organization_member?
    end

    test "is_organization_member? returns true for admin (higher)" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Admin Member")
      Organizations::Membership.create!(user: user, organization: org, role: "admin")
      user._current_organization_id = org.id

      assert user.is_organization_member?
    end

    test "is_organization_member? returns false for viewer" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Viewer Only")
      Organizations::Membership.create!(user: user, organization: org, role: "viewer")
      user._current_organization_id = org.id

      refute user.is_organization_member?
    end

    test "is_organization_viewer? returns true for any role" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Viewer Org")
      Organizations::Membership.create!(user: user, organization: org, role: "viewer")
      user._current_organization_id = org.id

      assert user.is_organization_viewer?
    end

    test "is_organization_viewer? returns false with no current org" do
      user = create_user!

      refute user.is_organization_viewer?
    end

    # =========================================================================
    # Role Checks (explicit organization)
    # =========================================================================

    test "is_owner_of? returns true when user is owner" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Owner Check")
      Organizations::Membership.create!(user: user, organization: org, role: "owner")

      assert user.is_owner_of?(org)
    end

    test "is_owner_of? returns false when user is admin" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Not Owner Check")
      Organizations::Membership.create!(user: user, organization: org, role: "admin")

      refute user.is_owner_of?(org)
    end

    test "is_admin_of? returns true for admin" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Admin Check")
      Organizations::Membership.create!(user: user, organization: org, role: "admin")

      assert user.is_admin_of?(org)
    end

    test "is_admin_of? returns true for owner (higher than admin)" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Owner as Admin")
      Organizations::Membership.create!(user: user, organization: org, role: "owner")

      assert user.is_admin_of?(org)
    end

    test "is_admin_of? returns false for member" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Member Not Admin")
      Organizations::Membership.create!(user: user, organization: org, role: "member")

      refute user.is_admin_of?(org)
    end

    test "is_member_of? returns true for any membership" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Member Check")
      Organizations::Membership.create!(user: user, organization: org, role: "viewer")

      assert user.is_member_of?(org)
    end

    test "is_member_of? returns false for non-member" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Non Member")

      refute user.is_member_of?(org)
    end

    test "is_member_of? returns false for nil org" do
      user = create_user!

      refute user.is_member_of?(nil)
    end

    test "is_viewer_of? returns true when user has any role in org" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Viewer Check")
      Organizations::Membership.create!(user: user, organization: org, role: "viewer")

      assert user.is_viewer_of?(org)
    end

    test "is_viewer_of? returns false for non-member" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Not Viewer")

      refute user.is_viewer_of?(org)
    end

    test "is_at_least? checks hierarchy in specific org" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Hierarchy Check")
      Organizations::Membership.create!(user: user, organization: org, role: "admin")

      assert user.is_at_least?(:admin, in: org)
      assert user.is_at_least?(:member, in: org)
      assert user.is_at_least?(:viewer, in: org)
      refute user.is_at_least?(:owner, in: org)
    end

    test "is_at_least? uses current org when no org specified" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Default Org")
      Organizations::Membership.create!(user: user, organization: org, role: "member")
      user._current_organization_id = org.id

      assert user.is_at_least?(:member)
      assert user.is_at_least?(:viewer)
      refute user.is_at_least?(:admin)
    end

    test "is_at_least? returns false when user has no role" do
      user = create_user!
      org = Organizations::Organization.create!(name: "No Role")

      refute user.is_at_least?(:viewer, in: org)
    end

    test "role_in returns role symbol for specific org" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Role In Org")
      Organizations::Membership.create!(user: user, organization: org, role: "admin")

      assert_equal :admin, user.role_in(org)
    end

    test "role_in returns nil for non-member" do
      user = create_user!
      org = Organizations::Organization.create!(name: "No Role Org")

      assert_nil user.role_in(org)
    end

    test "role_in returns nil for nil org" do
      user = create_user!

      assert_nil user.role_in(nil)
    end

    test "role_in uses loaded memberships when available" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Loaded Org")
      Organizations::Membership.create!(user: user, organization: org, role: "member")

      # Force-load the memberships association
      user.memberships.load

      assert_equal :member, user.role_in(org)
    end

    # =========================================================================
    # Actions - create_organization!
    # =========================================================================

    test "create_organization! with positional string arg" do
      user = create_user!
      org = user.create_organization!("Acme Corp")

      assert_equal "Acme Corp", org.name
      assert org.persisted?
      assert_equal :owner, user.role_in(org)
    end

    test "create_organization! with keyword arg" do
      user = create_user!
      org = user.create_organization!(name: "Keyword Org")

      assert_equal "Keyword Org", org.name
      assert org.persisted?
    end

    test "create_organization! sets current_organization context" do
      user = create_user!
      org = user.create_organization!("Context Org")

      assert_equal org, user.current_organization
      assert_equal org.id, user._current_organization_id
    end

    test "create_organization! creates owner membership" do
      user = create_user!
      org = user.create_organization!("Owner Membership Org")

      membership = Organizations::Membership.find_by(user: user, organization: org)
      assert membership
      assert_equal "owner", membership.role
    end

    test "create_organization! raises OrganizationLimitReached when limit exceeded" do
      User.organization_settings = { max_organizations: 1, create_personal_org: false, require_organization: false }.freeze

      user = create_user!
      user.create_organization!("First Org")

      assert_raises(Organizations::Models::Concerns::HasOrganizations::OrganizationLimitReached) do
        user.create_organization!("Second Org")
      end
    end

    # =========================================================================
    # Actions - leave_organization!
    # =========================================================================

    test "leave_organization! destroys membership" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Leave Org")
      Organizations::Membership.create!(user: user, organization: org, role: "member")
      owner = create_user!
      Organizations::Membership.create!(user: owner, organization: org, role: "owner")

      assert user.is_member_of?(org)

      user.leave_organization!(org)

      refute user.is_member_of?(org)
    end

    test "leave_organization! raises CannotLeaveAsLastOwner for sole owner" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Sole Owner Org")
      Organizations::Membership.create!(user: user, organization: org, role: "owner")

      assert_raises(Organizations::Models::Concerns::HasOrganizations::CannotLeaveAsLastOwner) do
        user.leave_organization!(org)
      end
    end

    test "leave_organization! allows non-owner to leave freely" do
      user = create_user!
      owner = create_user!
      org = Organizations::Organization.create!(name: "Free Leave Org")
      Organizations::Membership.create!(user: owner, organization: org, role: "owner")
      Organizations::Membership.create!(user: user, organization: org, role: "admin")

      user.leave_organization!(org)

      refute user.is_member_of?(org)
      assert owner.is_member_of?(org)
    end

    test "leave_organization! clears cache when leaving current organization" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Cache Clear Org")
      Organizations::Membership.create!(user: user, organization: org, role: "member")
      owner = create_user!
      Organizations::Membership.create!(user: owner, organization: org, role: "owner")
      user._current_organization_id = org.id

      assert_equal org, user.current_organization

      user.leave_organization!(org)

      assert_nil user._current_organization_id
      assert_nil user.current_organization
    end

    test "leave_organization! is no-op when user is not a member" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Not A Member Org")
      owner = create_user!
      Organizations::Membership.create!(user: owner, organization: org, role: "owner")

      membership_count_before = Organizations::Membership.count

      user.leave_organization!(org)

      assert_equal membership_count_before, Organizations::Membership.count
    end

    test "leave_organization! raises CannotLeaveLastOrganization when require_organization is true" do
      User.organization_settings = { max_organizations: nil, create_personal_org: false, require_organization: true }.freeze

      user = create_user!
      org = Organizations::Organization.create!(name: "Required Org")
      Organizations::Membership.create!(user: user, organization: org, role: "member")
      owner = create_user!
      Organizations::Membership.create!(user: owner, organization: org, role: "owner")

      assert_raises(Organizations::Models::Concerns::HasOrganizations::CannotLeaveLastOrganization) do
        user.leave_organization!(org)
      end
    end

    # =========================================================================
    # Actions - leave_current_organization!
    # =========================================================================

    test "leave_current_organization! leaves the active org" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Leave Current")
      Organizations::Membership.create!(user: user, organization: org, role: "member")
      owner = create_user!
      Organizations::Membership.create!(user: owner, organization: org, role: "owner")
      user._current_organization_id = org.id

      user.leave_current_organization!

      refute user.is_member_of?(org)
    end

    test "leave_current_organization! raises NoCurrentOrganization when no current org" do
      user = create_user!

      assert_raises(Organizations::Models::Concerns::HasOrganizations::NoCurrentOrganization) do
        user.leave_current_organization!
      end
    end

    # =========================================================================
    # Actions - send_organization_invite_to!
    # =========================================================================

    test "send_organization_invite_to! invites to current org" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Invite Org")
      Organizations::Membership.create!(user: user, organization: org, role: "owner")
      user._current_organization_id = org.id

      invitation = user.send_organization_invite_to!("newuser@example.com")

      assert invitation.persisted?
      assert_equal "newuser@example.com", invitation.email
      assert_equal org, invitation.organization
    end

    test "send_organization_invite_to! invites to specific org" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Specific Invite Org")
      Organizations::Membership.create!(user: user, organization: org, role: "admin")

      invitation = user.send_organization_invite_to!("specific@example.com", organization: org)

      assert invitation.persisted?
      assert_equal org, invitation.organization
    end

    test "send_organization_invite_to! requires invite_members permission" do
      user = create_user!
      org = Organizations::Organization.create!(name: "No Invite Perm Org")
      Organizations::Membership.create!(user: user, organization: org, role: "member")
      user._current_organization_id = org.id

      assert_raises(Organizations::NotAuthorized) do
        user.send_organization_invite_to!("nope@example.com")
      end
    end

    test "send_organization_invite_to! raises NoCurrentOrganization without org" do
      user = create_user!

      assert_raises(Organizations::Models::Concerns::HasOrganizations::NoCurrentOrganization) do
        user.send_organization_invite_to!("no-org@example.com")
      end
    end

    test "send_organization_invite_to! viewer cannot invite" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Viewer Invite Org")
      Organizations::Membership.create!(user: user, organization: org, role: "viewer")
      user._current_organization_id = org.id

      assert_raises(Organizations::NotAuthorized) do
        user.send_organization_invite_to!("viewer-invite@example.com")
      end
    end

    # =========================================================================
    # Owner Deletion Guard
    # =========================================================================

    test "before_destroy prevents deletion while owning organizations" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Guard Org")
      Organizations::Membership.create!(user: user, organization: org, role: "owner")

      assert_raises(ActiveRecord::RecordNotDestroyed) do
        user.destroy!
      end

      assert User.exists?(user.id)
      assert_includes user.errors.full_messages.join(", "), "Cannot delete a user who still owns organizations"
    end

    test "user can be deleted after transferring ownership" do
      user = create_user!
      other = create_user!
      org = Organizations::Organization.create!(name: "Transfer Guard Org")
      Organizations::Membership.create!(user: user, organization: org, role: "owner")
      Organizations::Membership.create!(user: other, organization: org, role: "admin")

      org.transfer_ownership_to!(other)

      user.reload
      user.destroy!

      refute User.exists?(user.id)
    end

    test "user with no owned orgs can be deleted" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Member Delete Org")
      Organizations::Membership.create!(user: user, organization: org, role: "member")

      user.destroy!

      refute User.exists?(user.id)
    end

    # =========================================================================
    # Personal Organization Auto-Creation
    # =========================================================================

    test "creates personal org when create_personal_org is true" do
      User.organization_settings = { max_organizations: nil, create_personal_org: true, require_organization: false }.freeze

      user = User.create!(email: "personal-org@example.com", name: "Personal User")

      assert_equal 1, user.organizations.count
      assert_equal "Personal", user.organizations.first.name
      assert_equal :owner, user.role_in(user.organizations.first)
    end

    test "personal org uses configured name" do
      Organizations.configure do |config|
        config.personal_organization_name = ->(u) { "#{u.name}'s Workspace" }
      end
      User.organization_settings = { max_organizations: nil, create_personal_org: true, require_organization: false }.freeze

      user = User.create!(email: "named-org@example.com", name: "Jane")

      assert_equal "Jane's Workspace", user.organizations.first.name
    ensure
      Organizations.reset_configuration!
    end

    test "no personal org when create_personal_org is false" do
      user = User.create!(email: "no-personal@example.com", name: "No Personal")

      assert_equal 0, user.organizations.count
    end

    # =========================================================================
    # Cache Handling
    # =========================================================================

    test "clear_organization_cache! clears all memoized values" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Cache Org")
      Organizations::Membership.create!(user: user, organization: org, role: "admin")
      user._current_organization_id = org.id

      # Trigger memoization
      user.current_organization
      user.current_membership

      user.clear_organization_cache!

      assert_nil user._current_organization_id
      assert_nil user.current_organization
    end

    test "current_membership is cached by org_id and re-fetched on org switch" do
      user = create_user!
      org1 = Organizations::Organization.create!(name: "Org Alpha")
      org2 = Organizations::Organization.create!(name: "Org Beta")
      Organizations::Membership.create!(user: user, organization: org1, role: "admin")
      Organizations::Membership.create!(user: user, organization: org2, role: "viewer")

      user._current_organization_id = org1.id
      membership1 = user.current_membership
      assert_equal "admin", membership1.role

      # Switch org via clear + re-set
      user.clear_organization_cache!
      user._current_organization_id = org2.id

      membership2 = user.current_membership
      assert_equal "viewer", membership2.role
    end

    test "cache invalidation on org switch via clear_organization_cache!" do
      user = create_user!
      org1 = Organizations::Organization.create!(name: "Switch Org 1")
      org2 = Organizations::Organization.create!(name: "Switch Org 2")
      Organizations::Membership.create!(user: user, organization: org1, role: "owner")
      Organizations::Membership.create!(user: user, organization: org2, role: "member")

      user._current_organization_id = org1.id
      assert_equal :owner, user.current_organization_role

      user.clear_organization_cache!
      user._current_organization_id = org2.id
      assert_equal :member, user.current_organization_role
    end

    # =========================================================================
    # Edge Cases
    # =========================================================================

    test "role shortcuts return false when no current org is set" do
      user = create_user!

      refute user.is_organization_owner?
      refute user.is_organization_admin?
      refute user.is_organization_member?
      refute user.is_organization_viewer?
    end

    test "owner has all role shortcuts true" do
      user = create_user!
      org = Organizations::Organization.create!(name: "All Roles Org")
      Organizations::Membership.create!(user: user, organization: org, role: "owner")
      user._current_organization_id = org.id

      assert user.is_organization_owner?
      assert user.is_organization_admin?
      assert user.is_organization_member?
      assert user.is_organization_viewer?
    end

    test "create_organization! dispatches organization_created callback" do
      callback_fired = false
      Organizations.configure do |config|
        config.on_organization_created do |ctx|
          callback_fired = true
        end
      end

      user = create_user!
      user.create_organization!("Callback Org")

      assert callback_fired
    ensure
      Organizations.reset_configuration!
    end

    test "leave_organization! dispatches member_removed callback" do
      callback_fired = false
      Organizations.configure do |config|
        config.on_member_removed do |ctx|
          callback_fired = true
        end
      end

      user = create_user!
      org = Organizations::Organization.create!(name: "Callback Leave Org")
      Organizations::Membership.create!(user: user, organization: org, role: "member")
      owner = create_user!
      Organizations::Membership.create!(user: owner, organization: org, role: "owner")

      user.leave_organization!(org)

      assert callback_fired
    ensure
      Organizations.reset_configuration!
    end

    test "multiple orgs with different roles" do
      user = create_user!
      org1 = Organizations::Organization.create!(name: "Multi Org 1")
      org2 = Organizations::Organization.create!(name: "Multi Org 2")
      org3 = Organizations::Organization.create!(name: "Multi Org 3")
      Organizations::Membership.create!(user: user, organization: org1, role: "owner")
      Organizations::Membership.create!(user: user, organization: org2, role: "admin")
      Organizations::Membership.create!(user: user, organization: org3, role: "viewer")

      assert_equal :owner, user.role_in(org1)
      assert_equal :admin, user.role_in(org2)
      assert_equal :viewer, user.role_in(org3)

      assert_equal 1, user.owned_organizations.count
      assert_equal 3, user.organizations.count
    end

    test "is_admin_of? returns false for nil org" do
      user = create_user!

      refute user.is_admin_of?(nil)
    end

    test "has_organization_permission_to? works for all default roles" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Perm All Roles")

      # Test viewer
      Organizations::Membership.create!(user: user, organization: org, role: "viewer")
      user._current_organization_id = org.id

      assert user.has_organization_permission_to?(:view_organization)
      refute user.has_organization_permission_to?(:create_resources)
      refute user.has_organization_permission_to?(:invite_members)
      refute user.has_organization_permission_to?(:manage_billing)
    end

    test "create_organization! sets current_membership to nil for lazy fetch" do
      user = create_user!
      _org = user.create_organization!("Lazy Fetch Org")

      # current_membership should be fetchable after create
      membership = user.current_membership
      assert membership
      assert_equal "owner", membership.role
    end

    test "leave_organization! does not clear cache when leaving non-current org" do
      user = create_user!
      org1 = Organizations::Organization.create!(name: "Current Stay")
      org2 = Organizations::Organization.create!(name: "Leave Other")
      Organizations::Membership.create!(user: user, organization: org1, role: "owner")
      Organizations::Membership.create!(user: user, organization: org2, role: "member")
      # Add another owner to org2 so user can leave
      other = create_user!
      Organizations::Membership.create!(user: other, organization: org2, role: "owner")

      user._current_organization_id = org1.id
      assert_equal org1, user.current_organization

      user.leave_organization!(org2)

      # Current org should remain unchanged
      assert_equal org1.id, user._current_organization_id
      assert_equal org1, user.current_organization
    end
  end
end
