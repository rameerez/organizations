# frozen_string_literal: true

require "test_helper"

module Organizations
  class MembershipTest < Organizations::Test
    # ─── Associations ────────────────────────────────────────────────────

    test "belongs_to user" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Acme")
      membership = Organizations::Membership.create!(user: user, organization: org, role: "member")

      assert_equal user, membership.user
    end

    test "belongs_to organization" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Acme")
      membership = Organizations::Membership.create!(user: user, organization: org, role: "member")

      assert_equal org, membership.organization
      assert_instance_of Organizations::Organization, membership.organization
    end

    test "belongs_to invited_by (optional)" do
      inviter = create_user!(email: "inviter@example.com")
      user = create_user!(email: "invitee@example.com")
      org = Organizations::Organization.create!(name: "Acme")

      membership = Organizations::Membership.create!(
        user: user,
        organization: org,
        role: "member",
        invited_by: inviter
      )

      assert_equal inviter, membership.invited_by
    end

    test "invited_by can be nil" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Acme")

      membership = Organizations::Membership.create!(user: user, organization: org, role: "member")

      assert_nil membership.invited_by
    end

    # ─── Role Attribute ──────────────────────────────────────────────────

    test "default role is member" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Acme")

      membership = Organizations::Membership.create!(user: user, organization: org)

      assert_equal "member", membership.role
    end

    test "valid roles are viewer, member, admin, owner" do
      org = Organizations::Organization.create!(name: "Acme")

      %w[viewer member admin].each do |valid_role|
        user = create_user!
        membership = Organizations::Membership.new(user: user, organization: org, role: valid_role)
        assert membership.valid?, "Expected role '#{valid_role}' to be valid, but it wasn't: #{membership.errors.full_messages.join(', ')}"
      end

      # Owner is special - must be the only owner
      owner_user = create_user!
      owner_membership = Organizations::Membership.new(user: owner_user, organization: org, role: "owner")
      assert owner_membership.valid?, "Expected role 'owner' to be valid"
    end

    test "invalid role raises validation error" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Acme")

      membership = Organizations::Membership.new(user: user, organization: org, role: "superadmin")

      assert_not membership.valid?
      assert_includes membership.errors[:role], "is not included in the list"
    end

    test "blank role is invalid" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Acme")

      membership = Organizations::Membership.new(user: user, organization: org, role: "")

      assert_not membership.valid?
      assert membership.errors[:role].any?
    end

    test "nil role is invalid" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Acme")

      membership = Organizations::Membership.new(user: user, organization: org, role: nil)

      assert_not membership.valid?
      assert membership.errors[:role].any?
    end

    # ─── Role Query Methods ──────────────────────────────────────────────

    test "owner? returns true only for owner role" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Acme")
      membership = Organizations::Membership.create!(user: user, organization: org, role: "owner")

      assert membership.owner?
      assert_not membership.admin?
      assert_not membership.member?
      assert_not membership.viewer?
    end

    test "admin? returns true only for admin role" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Acme")
      membership = Organizations::Membership.create!(user: user, organization: org, role: "admin")

      assert_not membership.owner?
      assert membership.admin?
      assert_not membership.member?
      assert_not membership.viewer?
    end

    test "member? returns true only for member role" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Acme")
      membership = Organizations::Membership.create!(user: user, organization: org, role: "member")

      assert_not membership.owner?
      assert_not membership.admin?
      assert membership.member?
      assert_not membership.viewer?
    end

    test "viewer? returns true only for viewer role" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Acme")
      membership = Organizations::Membership.create!(user: user, organization: org, role: "viewer")

      assert_not membership.owner?
      assert_not membership.admin?
      assert_not membership.member?
      assert membership.viewer?
    end

    test "role_sym returns role as symbol" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Acme")
      membership = Organizations::Membership.create!(user: user, organization: org, role: "admin")

      assert_equal :admin, membership.role_sym
    end

    # ─── Permission Checks ───────────────────────────────────────────────

    test "has_permission_to? returns true for permissions the role has" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Acme")
      membership = Organizations::Membership.create!(user: user, organization: org, role: "admin")

      assert membership.has_permission_to?(:invite_members)
      assert membership.has_permission_to?(:view_members)
      assert membership.has_permission_to?(:manage_settings)
    end

    test "has_permission_to? returns false for permissions the role lacks" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Acme")
      membership = Organizations::Membership.create!(user: user, organization: org, role: "member")

      assert_not membership.has_permission_to?(:invite_members)
      assert_not membership.has_permission_to?(:manage_settings)
      assert_not membership.has_permission_to?(:manage_billing)
    end

    test "viewer has only view permissions" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Acme")
      membership = Organizations::Membership.create!(user: user, organization: org, role: "viewer")

      assert membership.has_permission_to?(:view_organization)
      assert membership.has_permission_to?(:view_members)
      assert_not membership.has_permission_to?(:create_resources)
      assert_not membership.has_permission_to?(:invite_members)
    end

    test "owner has all permissions" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Acme")
      membership = Organizations::Membership.create!(user: user, organization: org, role: "owner")

      assert membership.has_permission_to?(:view_organization)
      assert membership.has_permission_to?(:manage_billing)
      assert membership.has_permission_to?(:transfer_ownership)
      assert membership.has_permission_to?(:delete_organization)
    end

    test "permissions returns array of permission symbols for role" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Acme")
      membership = Organizations::Membership.create!(user: user, organization: org, role: "member")

      permissions = membership.permissions

      assert_kind_of Array, permissions
      assert_includes permissions, :view_organization
      assert_includes permissions, :create_resources
      assert_not_includes permissions, :invite_members
    end

    test "permissions for viewer returns minimal set" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Acme")
      membership = Organizations::Membership.create!(user: user, organization: org, role: "viewer")

      assert_equal %i[view_organization view_members], membership.permissions
    end

    # ─── Role Hierarchy Checks ───────────────────────────────────────────

    test "is_at_least? viewer is true for all roles" do
      org = Organizations::Organization.create!(name: "Acme")

      %w[viewer member admin owner].each do |role|
        user = create_user!
        membership = Organizations::Membership.create!(user: user, organization: org, role: role)
        assert membership.is_at_least?(:viewer), "Expected #{role} to be at least viewer"
      end
    end

    test "is_at_least? member is true for member, admin, owner" do
      org = Organizations::Organization.create!(name: "Acme")

      %w[member admin owner].each do |role|
        user = create_user!
        membership = Organizations::Membership.create!(user: user, organization: org, role: role)
        assert membership.is_at_least?(:member), "Expected #{role} to be at least member"
      end

      viewer_user = create_user!
      viewer = Organizations::Membership.create!(user: viewer_user, organization: org, role: "viewer")
      assert_not viewer.is_at_least?(:member)
    end

    test "is_at_least? admin is true for admin and owner only" do
      org = Organizations::Organization.create!(name: "Acme")

      %w[admin owner].each do |role|
        user = create_user!
        membership = Organizations::Membership.create!(user: user, organization: org, role: role)
        assert membership.is_at_least?(:admin), "Expected #{role} to be at least admin"
      end

      %w[viewer member].each do |role|
        user = create_user!
        membership = Organizations::Membership.create!(user: user, organization: org, role: role)
        assert_not membership.is_at_least?(:admin), "Expected #{role} NOT to be at least admin"
      end
    end

    test "is_at_least? owner is true only for owner" do
      org = Organizations::Organization.create!(name: "Acme")

      owner_user = create_user!
      owner = Organizations::Membership.create!(user: owner_user, organization: org, role: "owner")
      assert owner.is_at_least?(:owner)

      %w[viewer member admin].each do |role|
        user = create_user!
        membership = Organizations::Membership.create!(user: user, organization: org, role: role)
        assert_not membership.is_at_least?(:owner), "Expected #{role} NOT to be at least owner"
      end
    end

    test "is_at_least? accepts string argument" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Acme")
      membership = Organizations::Membership.create!(user: user, organization: org, role: "admin")

      assert membership.is_at_least?("member")
      assert membership.is_at_least?("admin")
      assert_not membership.is_at_least?("owner")
    end

    # ─── compare_role ────────────────────────────────────────────────────

    test "compare_role returns -1 when role is higher" do
      org = Organizations::Organization.create!(name: "Acme")
      owner_user = create_user!
      member_user = create_user!
      owner = Organizations::Membership.create!(user: owner_user, organization: org, role: "owner")
      member = Organizations::Membership.create!(user: member_user, organization: org, role: "member")

      assert_equal(-1, owner.compare_role(member))
    end

    test "compare_role returns 0 when roles are equal" do
      org = Organizations::Organization.create!(name: "Acme")
      user_a = create_user!
      user_b = create_user!
      member_a = Organizations::Membership.create!(user: user_a, organization: org, role: "member")
      member_b = Organizations::Membership.create!(user: user_b, organization: org, role: "member")

      assert_equal 0, member_a.compare_role(member_b)
    end

    test "compare_role returns 1 when role is lower" do
      org = Organizations::Organization.create!(name: "Acme")
      viewer_user = create_user!
      admin_user = create_user!
      viewer = Organizations::Membership.create!(user: viewer_user, organization: org, role: "viewer")
      admin = Organizations::Membership.create!(user: admin_user, organization: org, role: "admin")

      assert_equal 1, viewer.compare_role(admin)
    end

    # ─── Role Changes: promote_to! ───────────────────────────────────────

    test "promote_to! changes role to a higher role" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Acme")
      membership = Organizations::Membership.create!(user: user, organization: org, role: "member")

      result = membership.promote_to!(:admin)

      assert_equal "admin", membership.reload.role
      assert_equal membership, result
    end

    test "promote_to! from viewer to member" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Acme")
      membership = Organizations::Membership.create!(user: user, organization: org, role: "viewer")

      membership.promote_to!(:member)

      assert_equal "member", membership.reload.role
    end

    test "promote_to! from viewer to admin" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Acme")
      membership = Organizations::Membership.create!(user: user, organization: org, role: "viewer")

      membership.promote_to!(:admin)

      assert_equal "admin", membership.reload.role
    end

    test "promote_to! owner raises CannotPromoteToOwner" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Acme")
      membership = Organizations::Membership.create!(user: user, organization: org, role: "admin")

      error = assert_raises(Organizations::Membership::CannotPromoteToOwner) do
        membership.promote_to!(:owner)
      end

      assert_match(/Cannot promote to owner/, error.message)
      assert_equal "admin", membership.reload.role
    end

    test "promote_to! with same role is a no-op" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Acme")
      membership = Organizations::Membership.create!(user: user, organization: org, role: "admin")

      result = membership.promote_to!(:admin)

      assert_equal membership, result
      assert_equal "admin", membership.reload.role
    end

    test "promote_to! to a lower role raises InvalidRoleChange" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Acme")
      membership = Organizations::Membership.create!(user: user, organization: org, role: "admin")

      assert_raises(Organizations::Membership::InvalidRoleChange) do
        membership.promote_to!(:viewer)
      end

      assert_equal "admin", membership.reload.role
    end

    test "promote_to! with invalid role raises ArgumentError" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Acme")
      membership = Organizations::Membership.create!(user: user, organization: org, role: "member")

      assert_raises(ArgumentError) do
        membership.promote_to!(:superadmin)
      end
    end

    test "promote_to! accepts string argument" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Acme")
      membership = Organizations::Membership.create!(user: user, organization: org, role: "member")

      membership.promote_to!("admin")

      assert_equal "admin", membership.reload.role
    end

    test "promote_to! with changed_by parameter" do
      user = create_user!
      changer = create_user!(email: "changer@example.com")
      org = Organizations::Organization.create!(name: "Acme")
      membership = Organizations::Membership.create!(user: user, organization: org, role: "member")

      membership.promote_to!(:admin, changed_by: changer)

      assert_equal "admin", membership.reload.role
    end

    # ─── Role Changes: demote_to! ────────────────────────────────────────

    test "demote_to! changes role to a lower role" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Acme")
      membership = Organizations::Membership.create!(user: user, organization: org, role: "admin")

      result = membership.demote_to!(:member)

      assert_equal "member", membership.reload.role
      assert_equal membership, result
    end

    test "demote_to! from admin to viewer" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Acme")
      membership = Organizations::Membership.create!(user: user, organization: org, role: "admin")

      membership.demote_to!(:viewer)

      assert_equal "viewer", membership.reload.role
    end

    test "demote_to! owner raises CannotDemoteOwner" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Acme")
      membership = Organizations::Membership.create!(user: user, organization: org, role: "owner")

      error = assert_raises(Organizations::Membership::CannotDemoteOwner) do
        membership.demote_to!(:admin)
      end

      assert_match(/Cannot demote owner/, error.message)
      assert_equal "owner", membership.reload.role
    end

    test "demote_to! to a higher role raises InvalidRoleChange" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Acme")
      membership = Organizations::Membership.create!(user: user, organization: org, role: "viewer")

      assert_raises(Organizations::Membership::InvalidRoleChange) do
        membership.demote_to!(:admin)
      end

      assert_equal "viewer", membership.reload.role
    end

    test "demote_to! with same role is a no-op" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Acme")
      membership = Organizations::Membership.create!(user: user, organization: org, role: "member")

      result = membership.demote_to!(:member)

      assert_equal membership, result
      assert_equal "member", membership.reload.role
    end

    test "demote_to! with invalid role raises ArgumentError" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Acme")
      membership = Organizations::Membership.create!(user: user, organization: org, role: "admin")

      assert_raises(ArgumentError) do
        membership.demote_to!(:superadmin)
      end
    end

    test "demote_to! accepts string argument" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Acme")
      membership = Organizations::Membership.create!(user: user, organization: org, role: "admin")

      membership.demote_to!("member")

      assert_equal "member", membership.reload.role
    end

    test "demote_to! with changed_by parameter" do
      user = create_user!
      changer = create_user!(email: "changer@example.com")
      org = Organizations::Organization.create!(name: "Acme")
      membership = Organizations::Membership.create!(user: user, organization: org, role: "admin")

      membership.demote_to!(:member, changed_by: changer)

      assert_equal "member", membership.reload.role
    end

    # ─── Single Owner Validation ─────────────────────────────────────────

    test "cannot have two owner memberships in same organization" do
      org = Organizations::Organization.create!(name: "Acme")
      owner = create_user!(email: "owner@example.com")
      Organizations::Membership.create!(user: owner, organization: org, role: "owner")

      second_owner = create_user!(email: "second-owner@example.com")
      membership = Organizations::Membership.new(user: second_owner, organization: org, role: "owner")

      assert_not membership.valid?
      assert_includes membership.errors[:role], "owner already exists for this organization"
    end

    test "different organizations can each have an owner" do
      org_a = Organizations::Organization.create!(name: "Acme A")
      org_b = Organizations::Organization.create!(name: "Acme B")

      owner_a = create_user!(email: "owner-a@example.com")
      owner_b = create_user!(email: "owner-b@example.com")

      membership_a = Organizations::Membership.create!(user: owner_a, organization: org_a, role: "owner")
      membership_b = Organizations::Membership.create!(user: owner_b, organization: org_b, role: "owner")

      assert membership_a.persisted?
      assert membership_b.persisted?
    end

    test "owner validation allows updating existing owner membership" do
      org = Organizations::Organization.create!(name: "Acme")
      owner = create_user!(email: "owner@example.com")
      membership = Organizations::Membership.create!(user: owner, organization: org, role: "owner")

      # Updating the same owner membership should not trigger the single-owner validation
      membership.touch
      assert membership.valid?
    end

    test "non-owner roles can have multiple memberships in same org" do
      org = Organizations::Organization.create!(name: "Acme")

      admin_a = create_user!(email: "admin-a@example.com")
      admin_b = create_user!(email: "admin-b@example.com")

      membership_a = Organizations::Membership.create!(user: admin_a, organization: org, role: "admin")
      membership_b = Organizations::Membership.create!(user: admin_b, organization: org, role: "admin")

      assert membership_a.persisted?
      assert membership_b.persisted?
    end

    # ─── Uniqueness Validation ───────────────────────────────────────────

    test "user cannot have duplicate membership in same organization" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Acme")
      Organizations::Membership.create!(user: user, organization: org, role: "member")

      duplicate = Organizations::Membership.new(user: user, organization: org, role: "admin")

      assert_not duplicate.valid?
      assert_includes duplicate.errors[:user_id], "is already a member of this organization"
    end

    test "user can be member of multiple organizations" do
      user = create_user!
      org_a = Organizations::Organization.create!(name: "Org A")
      org_b = Organizations::Organization.create!(name: "Org B")

      membership_a = Organizations::Membership.create!(user: user, organization: org_a, role: "member")
      membership_b = Organizations::Membership.create!(user: user, organization: org_b, role: "admin")

      assert membership_a.persisted?
      assert membership_b.persisted?
    end

    test "uniqueness constraint enforced at database level" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Acme")
      Organizations::Membership.create!(user: user, organization: org, role: "member")

      assert_raises(ActiveRecord::RecordInvalid) do
        Organizations::Membership.create!(user: user, organization: org, role: "viewer")
      end
    end

    # ─── Scopes ──────────────────────────────────────────────────────────

    test "owners scope returns only owner memberships" do
      org = Organizations::Organization.create!(name: "Acme")
      owner = create_user!(email: "owner@example.com")
      member = create_user!(email: "member@example.com")

      Organizations::Membership.create!(user: owner, organization: org, role: "owner")
      Organizations::Membership.create!(user: member, organization: org, role: "member")

      assert_equal 1, org.memberships.owners.count
      assert_equal "owner", org.memberships.owners.first.role
    end

    test "admins scope returns only admin memberships" do
      org = Organizations::Organization.create!(name: "Acme")
      admin = create_user!(email: "admin@example.com")
      owner = create_user!(email: "owner@example.com")

      Organizations::Membership.create!(user: admin, organization: org, role: "admin")
      Organizations::Membership.create!(user: owner, organization: org, role: "owner")

      assert_equal 1, org.memberships.admins.count
      assert_equal "admin", org.memberships.admins.first.role
    end

    test "admins_and_above scope returns admin and owner memberships" do
      org = Organizations::Organization.create!(name: "Acme")
      admin = create_user!(email: "admin@example.com")
      owner = create_user!(email: "owner@example.com")
      member = create_user!(email: "member@example.com")

      Organizations::Membership.create!(user: admin, organization: org, role: "admin")
      Organizations::Membership.create!(user: owner, organization: org, role: "owner")
      Organizations::Membership.create!(user: member, organization: org, role: "member")

      assert_equal 2, org.memberships.admins_and_above.count
    end

    test "members scope returns only member memberships" do
      org = Organizations::Organization.create!(name: "Acme")
      member = create_user!(email: "member@example.com")
      admin = create_user!(email: "admin@example.com")

      Organizations::Membership.create!(user: member, organization: org, role: "member")
      Organizations::Membership.create!(user: admin, organization: org, role: "admin")

      assert_equal 1, org.memberships.members.count
      assert_equal "member", org.memberships.members.first.role
    end

    test "viewers scope returns only viewer memberships" do
      org = Organizations::Organization.create!(name: "Acme")
      viewer = create_user!(email: "viewer@example.com")
      member = create_user!(email: "member@example.com")

      Organizations::Membership.create!(user: viewer, organization: org, role: "viewer")
      Organizations::Membership.create!(user: member, organization: org, role: "member")

      assert_equal 1, org.memberships.viewers.count
      assert_equal "viewer", org.memberships.viewers.first.role
    end

    test "by_role_hierarchy scope orders owners first" do
      org = Organizations::Organization.create!(name: "Acme")
      viewer = create_user!(email: "viewer@example.com")
      owner = create_user!(email: "owner@example.com")
      member = create_user!(email: "member@example.com")
      admin = create_user!(email: "admin@example.com")

      Organizations::Membership.create!(user: viewer, organization: org, role: "viewer")
      Organizations::Membership.create!(user: owner, organization: org, role: "owner")
      Organizations::Membership.create!(user: member, organization: org, role: "member")
      Organizations::Membership.create!(user: admin, organization: org, role: "admin")

      ordered = org.memberships.by_role_hierarchy.map(&:role)

      assert_equal %w[owner admin member viewer], ordered
    end

    # ─── Counter Cache ───────────────────────────────────────────────────

    test "counter cache methods do not raise when memberships_count column is absent" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Acme")

      # The test schema does not have memberships_count, so this should work fine
      membership = Organizations::Membership.create!(user: user, organization: org, role: "member")
      assert membership.persisted?

      membership.destroy!
      assert membership.destroyed?
    end

    test "memberships_counter_cache_enabled? returns false when column absent" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Acme")
      membership = Organizations::Membership.create!(user: user, organization: org, role: "member")

      # Accessing private method to verify behavior
      assert_not membership.send(:memberships_counter_cache_enabled?)
    end

    # ─── Callbacks: role_changed dispatch ────────────────────────────────

    test "promote_to! dispatches role_changed callback" do
      callback_called = false
      callback_data = nil

      Organizations.configure do |config|
        config.on_role_changed do |ctx|
          callback_called = true
          callback_data = ctx
        end
      end

      user = create_user!
      org = Organizations::Organization.create!(name: "Acme")
      membership = Organizations::Membership.create!(user: user, organization: org, role: "member")

      membership.promote_to!(:admin)

      assert callback_called, "Expected role_changed callback to be dispatched"
      assert_equal :member, callback_data.old_role
      assert_equal :admin, callback_data.new_role
      assert_equal org, callback_data.organization
      assert_equal membership, callback_data.membership
    end

    test "demote_to! dispatches role_changed callback" do
      callback_called = false

      Organizations.configure do |config|
        config.on_role_changed do |_ctx|
          callback_called = true
        end
      end

      user = create_user!
      org = Organizations::Organization.create!(name: "Acme")
      membership = Organizations::Membership.create!(user: user, organization: org, role: "admin")

      membership.demote_to!(:member)

      assert callback_called, "Expected role_changed callback to be dispatched"
    end

    test "role change with same role does not dispatch callback" do
      callback_called = false

      Organizations.configure do |config|
        config.on_role_changed do |_ctx|
          callback_called = true
        end
      end

      user = create_user!
      org = Organizations::Organization.create!(name: "Acme")
      membership = Organizations::Membership.create!(user: user, organization: org, role: "admin")

      membership.promote_to!(:admin) # same role, no-op

      assert_not callback_called, "Expected no callback for same-role change"
    end

    # ─── Edge Cases ──────────────────────────────────────────────────────

    test "membership with invited_by set correctly associates inviter" do
      org = Organizations::Organization.create!(name: "Acme")
      inviter = create_user!(email: "inviter@example.com")
      invitee = create_user!(email: "invitee@example.com")

      membership = Organizations::Membership.create!(
        user: invitee,
        organization: org,
        role: "member",
        invited_by: inviter
      )

      assert_equal inviter, membership.reload.invited_by
      assert_instance_of User, membership.invited_by
    end

    test "membership timestamps are set on creation" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Acme")

      membership = Organizations::Membership.create!(user: user, organization: org, role: "member")

      assert_not_nil membership.created_at
      assert_not_nil membership.updated_at
    end

    test "membership without user fails to save at database level" do
      org = Organizations::Organization.create!(name: "Acme")

      assert_raises(ActiveRecord::NotNullViolation) do
        Organizations::Membership.create!(organization: org, role: "member")
      end
    end

    test "membership without organization fails to save at database level" do
      user = create_user!

      assert_raises(ActiveRecord::NotNullViolation) do
        Organizations::Membership.create!(user: user, role: "member")
      end
    end

    test "table_name is organizations_memberships" do
      assert_equal "organizations_memberships", Organizations::Membership.table_name
    end

    # ─── Error class hierarchy ───────────────────────────────────────────

    test "CannotDemoteOwner inherits from Organizations::Error" do
      assert Organizations::Membership::CannotDemoteOwner < Organizations::Error
    end

    test "CannotPromoteToOwner inherits from Organizations::Error" do
      assert Organizations::Membership::CannotPromoteToOwner < Organizations::Error
    end

    test "InvalidRoleChange inherits from Organizations::Error" do
      assert Organizations::Membership::InvalidRoleChange < Organizations::Error
    end
  end
end
