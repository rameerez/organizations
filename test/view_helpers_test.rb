# frozen_string_literal: true

require "test_helper"

module Organizations
  class ViewHelpersTest < Organizations::Test
    include Organizations::ViewHelpers

    # Simulate controller/view context methods that ViewHelpers relies on
    attr_accessor :current_user, :current_organization

    # Simulate content_tag for invitation badge
    def content_tag(tag, content, options = {})
      class_attr = options[:class] ? " class=\"#{options[:class]}\"" : ""
      "<#{tag}#{class_attr}>#{content}</#{tag}>"
    end

    # === organization_switcher_data ===

    test "organization_switcher_data returns hash with current, others, and switch_path" do
      org, owner = create_org_with_owner!(name: "Acme Corp")
      self.current_user = owner
      self.current_organization = org

      data = organization_switcher_data
      assert_kind_of Hash, data
      assert data.key?(:current)
      assert data.key?(:others)
      assert data.key?(:switch_path)
    end

    test "organization_switcher_data current contains id, name, slug, role, and role_label" do
      org, owner = create_org_with_owner!(name: "Acme Corp")
      self.current_user = owner
      self.current_organization = org

      data = organization_switcher_data
      current = data[:current]

      assert_equal org.id, current[:id]
      assert_equal "Acme Corp", current[:name]
      assert_equal "acme-corp", current[:slug]
      assert_equal :owner, current[:role]
      assert_equal "Owner", current[:role_label]
      assert current[:current]
    end

    test "organization_switcher_data others is array of other orgs user belongs to" do
      org1, owner = create_org_with_owner!(name: "Primary Org")
      org2 = Organizations::Organization.create!(name: "Secondary Org")
      Organizations::Membership.create!(user: owner, organization: org2, role: "admin")

      self.current_user = owner
      self.current_organization = org1

      data = organization_switcher_data
      others = data[:others]

      assert_equal 1, others.size
      assert_equal org2.id, others.first[:id]
      assert_equal "Secondary Org", others.first[:name]
      assert_equal :admin, others.first[:role]
      refute others.first[:current]
    end

    test "organization_switcher_data switch_path is a lambda that generates switch URL" do
      org, owner = create_org_with_owner!(name: "Test Org")
      self.current_user = owner
      self.current_organization = org

      data = organization_switcher_data
      path_lambda = data[:switch_path]

      assert_respond_to path_lambda, :call
      assert_equal "/organizations/switch/#{org.id}", path_lambda.call(org.id)
    end

    test "organization_switcher_data returns empty data when no current_user" do
      self.current_user = nil
      self.current_organization = nil

      data = organization_switcher_data
      assert_nil data[:current][:id]
      assert_nil data[:current][:name]
      assert_nil data[:current][:slug]
      assert_empty data[:others]
    end

    test "organization_switcher_data with user belonging to no organizations" do
      user = create_user!
      self.current_user = user
      self.current_organization = nil

      data = organization_switcher_data
      assert_nil data[:current][:id]
      assert_empty data[:others]
    end

    test "organization_switcher_data is memoized within the request" do
      org, owner = create_org_with_owner!(name: "Memoized Org")
      self.current_user = owner
      self.current_organization = org

      data1 = organization_switcher_data
      data2 = organization_switcher_data

      assert_same data1, data2
    end

    # === organization_invitation_badge ===

    test "organization_invitation_badge returns badge HTML when user has pending invitations" do
      org, owner = create_org_with_owner!(name: "Invite Org")
      user = create_user!(email: "invitee@example.com")

      Organizations::Invitation.create!(
        organization: org,
        email: "invitee@example.com",
        role: "member",
        invited_by: owner,
        token: SecureRandom.urlsafe_base64(32),
        expires_at: 7.days.from_now
      )

      result = organization_invitation_badge(user)
      assert_equal '<span class="badge">1</span>', result
    end

    test "organization_invitation_badge returns nil when no pending invitations" do
      user = create_user!(email: "noinvites@example.com")

      result = organization_invitation_badge(user)
      assert_nil result
    end

    test "organization_invitation_badge returns nil for nil user" do
      result = organization_invitation_badge(nil)
      assert_nil result
    end

    test "organization_invitation_badge count reflects actual pending invitations" do
      org1, owner1 = create_org_with_owner!(name: "Org A")
      org2, owner2 = create_org_with_owner!(name: "Org B")
      user = create_user!(email: "multi@example.com")

      Organizations::Invitation.create!(
        organization: org1,
        email: "multi@example.com",
        role: "member",
        invited_by: owner1,
        token: SecureRandom.urlsafe_base64(32),
        expires_at: 7.days.from_now
      )

      Organizations::Invitation.create!(
        organization: org2,
        email: "multi@example.com",
        role: "admin",
        invited_by: owner2,
        token: SecureRandom.urlsafe_base64(32),
        expires_at: 7.days.from_now
      )

      result = organization_invitation_badge(user)
      assert_equal '<span class="badge">2</span>', result
    end

    test "organization_invitation_badge excludes expired invitations" do
      org, owner = create_org_with_owner!(name: "Expired Org")
      user = create_user!(email: "expired@example.com")

      Organizations::Invitation.create!(
        organization: org,
        email: "expired@example.com",
        role: "member",
        invited_by: owner,
        token: SecureRandom.urlsafe_base64(32),
        expires_at: 1.day.ago
      )

      result = organization_invitation_badge(user)
      assert_nil result
    end

    test "organization_invitation_badge excludes accepted invitations" do
      org, owner = create_org_with_owner!(name: "Accepted Org")
      user = create_user!(email: "accepted@example.com")

      Organizations::Invitation.create!(
        organization: org,
        email: "accepted@example.com",
        role: "member",
        invited_by: owner,
        token: SecureRandom.urlsafe_base64(32),
        expires_at: 7.days.from_now,
        accepted_at: 1.hour.ago
      )

      result = organization_invitation_badge(user)
      assert_nil result
    end

    # === Role Labels ===

    test "organization_role_label returns correct labels for standard roles" do
      assert_equal "Owner", organization_role_label(:owner)
      assert_equal "Admin", organization_role_label(:admin)
      assert_equal "Member", organization_role_label(:member)
      assert_equal "Viewer", organization_role_label(:viewer)
    end

    test "organization_role_label humanizes unknown roles" do
      assert_equal "Custom role", organization_role_label(:custom_role)
    end

    test "organization_role_label works with string arguments" do
      assert_equal "Owner", organization_role_label("owner")
      assert_equal "Admin", organization_role_label("admin")
    end

    # === Role Info ===

    test "organization_role_info returns hash with role, label, and color" do
      info = organization_role_info(:admin)

      assert_equal :admin, info[:role]
      assert_equal "Admin", info[:label]
      assert_equal :blue, info[:color]
    end

    test "organization_role_info returns correct colors for all standard roles" do
      assert_equal :purple, organization_role_info(:owner)[:color]
      assert_equal :blue, organization_role_info(:admin)[:color]
      assert_equal :green, organization_role_info(:member)[:color]
      assert_equal :gray, organization_role_info(:viewer)[:color]
    end

    # === Invitation Status ===

    test "organization_invitation_status returns pending for non-expired non-accepted invitation" do
      invitation = Organizations::Invitation.new(
        accepted_at: nil,
        expires_at: 7.days.from_now
      )

      assert_equal :pending, organization_invitation_status(invitation)
    end

    test "organization_invitation_status returns accepted for accepted invitation" do
      invitation = Organizations::Invitation.new(
        accepted_at: 1.hour.ago,
        expires_at: 7.days.from_now
      )

      assert_equal :accepted, organization_invitation_status(invitation)
    end

    test "organization_invitation_status returns expired for expired invitation" do
      invitation = Organizations::Invitation.new(
        accepted_at: nil,
        expires_at: 1.day.ago
      )

      assert_equal :expired, organization_invitation_status(invitation)
    end

    test "organization_invitation_status_label returns human-readable strings" do
      pending_inv = Organizations::Invitation.new(accepted_at: nil, expires_at: 7.days.from_now)
      accepted_inv = Organizations::Invitation.new(accepted_at: 1.hour.ago)
      expired_inv = Organizations::Invitation.new(accepted_at: nil, expires_at: 1.day.ago)

      assert_equal "Pending", organization_invitation_status_label(pending_inv)
      assert_equal "Accepted", organization_invitation_status_label(accepted_inv)
      assert_equal "Expired", organization_invitation_status_label(expired_inv)
    end

    test "organization_invitation_status_info returns hash with status, label, and color" do
      invitation = Organizations::Invitation.new(accepted_at: nil, expires_at: 7.days.from_now)

      info = organization_invitation_status_info(invitation)
      assert_equal :pending, info[:status]
      assert_equal "Pending", info[:label]
      assert_equal :yellow, info[:color]
    end

    test "organization_invitation_status_info colors for all statuses" do
      pending_inv = Organizations::Invitation.new(accepted_at: nil, expires_at: 7.days.from_now)
      accepted_inv = Organizations::Invitation.new(accepted_at: 1.hour.ago)
      expired_inv = Organizations::Invitation.new(accepted_at: nil, expires_at: 1.day.ago)

      assert_equal :yellow, organization_invitation_status_info(pending_inv)[:color]
      assert_equal :green, organization_invitation_status_info(accepted_inv)[:color]
      assert_equal :red, organization_invitation_status_info(expired_inv)[:color]
    end

    # === Permission-based helpers ===

    test "can_invite_members? returns true for admin" do
      org, _owner = create_org_with_owner!(name: "Perm Org")
      admin = create_user!(email: "admin@example.com")
      Organizations::Membership.create!(user: admin, organization: org, role: "admin")

      assert can_invite_members?(admin, org)
    end

    test "can_invite_members? returns false for member" do
      org, _owner = create_org_with_owner!(name: "Perm Org")
      member = create_user!(email: "member@example.com")
      Organizations::Membership.create!(user: member, organization: org, role: "member")

      refute can_invite_members?(member, org)
    end

    test "can_invite_members? returns false for nil user" do
      org, _owner = create_org_with_owner!(name: "Perm Org")
      refute can_invite_members?(nil, org)
    end

    test "can_invite_members? returns false for nil organization" do
      user = create_user!
      refute can_invite_members?(user, nil)
    end

    test "can_remove_member? returns true for admin removing non-owner" do
      org, _owner = create_org_with_owner!(name: "Remove Org")
      admin = create_user!(email: "admin@example.com")
      Organizations::Membership.create!(user: admin, organization: org, role: "admin")
      member = create_user!(email: "member@example.com")
      member_membership = Organizations::Membership.create!(user: member, organization: org, role: "member")

      assert can_remove_member?(admin, member_membership)
    end

    test "can_remove_member? returns false when trying to remove owner" do
      org, owner = create_org_with_owner!(name: "Remove Org")
      owner_membership = org.memberships.find_by(user: owner)

      refute can_remove_member?(owner, owner_membership)
    end

    test "can_change_member_role? returns true for admin changing non-owner role" do
      org, _owner = create_org_with_owner!(name: "Role Change Org")
      admin = create_user!(email: "admin@example.com")
      Organizations::Membership.create!(user: admin, organization: org, role: "admin")
      member = create_user!(email: "member@example.com")
      member_membership = Organizations::Membership.create!(user: member, organization: org, role: "member")

      assert can_change_member_role?(admin, member_membership)
    end

    test "can_change_member_role? returns false when changing own role" do
      org, _owner = create_org_with_owner!(name: "Self Role Org")
      admin = create_user!(email: "admin@example.com")
      admin_membership = Organizations::Membership.create!(user: admin, organization: org, role: "admin")

      refute can_change_member_role?(admin, admin_membership)
    end

    test "can_change_member_role? returns false for non-owner changing owner role" do
      org, owner = create_org_with_owner!(name: "Owner Role Org")
      admin = create_user!(email: "admin@example.com")
      Organizations::Membership.create!(user: admin, organization: org, role: "admin")
      owner_membership = org.memberships.find_by(user: owner)

      refute can_change_member_role?(admin, owner_membership)
    end

    test "can_transfer_ownership? returns true for owner" do
      org, owner = create_org_with_owner!(name: "Transfer Org")
      assert can_transfer_ownership?(owner, org)
    end

    test "can_transfer_ownership? returns false for admin" do
      org, _owner = create_org_with_owner!(name: "Transfer Org")
      admin = create_user!(email: "admin@example.com")
      Organizations::Membership.create!(user: admin, organization: org, role: "admin")

      refute can_transfer_ownership?(admin, org)
    end

    test "can_delete_organization? returns true for owner" do
      org, owner = create_org_with_owner!(name: "Delete Org")
      assert can_delete_organization?(owner, org)
    end

    test "can_delete_organization? returns false for admin" do
      org, _owner = create_org_with_owner!(name: "Delete Org")
      admin = create_user!(email: "admin@example.com")
      Organizations::Membership.create!(user: admin, organization: org, role: "admin")

      refute can_delete_organization?(admin, org)
    end

    test "can_delete_organization? returns false for nil user" do
      org, _owner = create_org_with_owner!(name: "Delete Org")
      refute can_delete_organization?(nil, org)
    end

    test "can_manage_organization? returns true for admin" do
      org, _owner = create_org_with_owner!(name: "Manage Org")
      admin = create_user!(email: "admin@example.com")
      Organizations::Membership.create!(user: admin, organization: org, role: "admin")

      assert can_manage_organization?(admin, org)
    end

    test "can_manage_organization? returns false for member" do
      org, _owner = create_org_with_owner!(name: "Manage Org")
      member = create_user!(email: "member@example.com")
      Organizations::Membership.create!(user: member, organization: org, role: "member")

      refute can_manage_organization?(member, org)
    end

    test "can_manage_organization? returns false for nil user" do
      org, _owner = create_org_with_owner!(name: "Manage Org")
      refute can_manage_organization?(nil, org)
    end

    test "can_manage_organization? returns false for nil organization" do
      user = create_user!
      refute can_manage_organization?(user, nil)
    end

    # === user_has_permission_in_org? (private, tested via public helpers) ===

    test "user_has_permission_in_org? returns false for user not in org" do
      org, _owner = create_org_with_owner!(name: "No Member Org")
      outsider = create_user!(email: "outsider@example.com")

      refute send(:user_has_permission_in_org?, outsider, org, :invite_members)
    end

    test "user_has_permission_in_org? returns true for user with permission" do
      org, owner = create_org_with_owner!(name: "Has Perm Org")

      assert send(:user_has_permission_in_org?, owner, org, :transfer_ownership)
    end

    # === Data helpers ===

    test "organization_members_data returns array of membership hashes" do
      org, owner = create_org_with_owner!(name: "Members Data Org")
      admin = create_user!(email: "admin@example.com", name: "Admin User")
      Organizations::Membership.create!(user: admin, organization: org, role: "admin")

      data = organization_members_data(org)

      assert_kind_of Array, data
      assert_equal 2, data.size

      # Ordered by role hierarchy (owner first)
      owner_data = data.first
      assert_equal owner.id, owner_data[:id]
      assert_equal owner.email, owner_data[:email]
      assert_equal :owner, owner_data[:role]
      assert_equal "Owner", owner_data[:role_label]
      assert owner_data[:is_owner]
      assert_kind_of Hash, owner_data[:role_info]

      admin_data = data.last
      assert_equal admin.id, admin_data[:id]
      assert_equal "Admin User", admin_data[:name]
      assert_equal "admin@example.com", admin_data[:email]
      assert_equal :admin, admin_data[:role]
      refute admin_data[:is_owner]
    end

    test "organization_members_data uses name when available, falls back to email" do
      org, _owner = create_org_with_owner!(name: "Name Org")
      named_user = create_user!(email: "named@example.com", name: "Named User")
      Organizations::Membership.create!(user: named_user, organization: org, role: "member")

      unnamed_user = User.create!(email: "unnamed@example.com", name: nil)
      Organizations::Membership.create!(user: unnamed_user, organization: org, role: "viewer")

      data = organization_members_data(org)

      named_data = data.find { |d| d[:email] == "named@example.com" }
      assert_equal "Named User", named_data[:name]

      unnamed_data = data.find { |d| d[:email] == "unnamed@example.com" }
      assert_equal "unnamed@example.com", unnamed_data[:name]
    end

    test "organization_invitations_data returns array of invitation hashes" do
      org, owner = create_org_with_owner!(name: "Invitations Data Org")

      invitation = Organizations::Invitation.create!(
        organization: org,
        email: "pending@example.com",
        role: "member",
        invited_by: owner,
        token: SecureRandom.urlsafe_base64(32),
        expires_at: 7.days.from_now
      )

      data = organization_invitations_data(org)

      assert_kind_of Array, data
      assert_equal 1, data.size

      inv_data = data.first
      assert_equal invitation.id, inv_data[:id]
      assert_equal "pending@example.com", inv_data[:email]
      assert_equal :member, inv_data[:role]
      assert_equal "Member", inv_data[:role_label]
      assert_equal owner, inv_data[:invited_by]
      assert_equal owner.name, inv_data[:invited_by_name]
      assert_equal :pending, inv_data[:status]
      assert_kind_of Hash, inv_data[:status_info]
      assert_not_nil inv_data[:expires_at]
      assert_not_nil inv_data[:created_at]
    end

    test "organization_invitations_data handles nil inviter gracefully" do
      org, owner = create_org_with_owner!(name: "Nil Inviter Org")

      invitation = Organizations::Invitation.create!(
        organization: org,
        email: "orphan@example.com",
        role: "admin",
        invited_by: owner,
        token: SecureRandom.urlsafe_base64(32),
        expires_at: 7.days.from_now
      )

      # Simulate inviter being deleted (nullified)
      invitation.update_column(:invited_by_id, nil)

      data = organization_invitations_data(org)

      assert_equal 1, data.size
      inv_data = data.first
      assert_nil inv_data[:invited_by]
      assert_nil inv_data[:invited_by_name]
    end

    test "organization_invitations_data only returns pending invitations" do
      org, owner = create_org_with_owner!(name: "Filter Org")

      # Pending invitation
      Organizations::Invitation.create!(
        organization: org,
        email: "pending@example.com",
        role: "member",
        invited_by: owner,
        token: SecureRandom.urlsafe_base64(32),
        expires_at: 7.days.from_now
      )

      # Accepted invitation
      Organizations::Invitation.create!(
        organization: org,
        email: "accepted@example.com",
        role: "member",
        invited_by: owner,
        token: SecureRandom.urlsafe_base64(32),
        expires_at: 7.days.from_now,
        accepted_at: 1.hour.ago
      )

      # Expired invitation
      Organizations::Invitation.create!(
        organization: org,
        email: "expired@example.com",
        role: "member",
        invited_by: owner,
        token: SecureRandom.urlsafe_base64(32),
        expires_at: 1.day.ago
      )

      data = organization_invitations_data(org)
      assert_equal 1, data.size
      assert_equal "pending@example.com", data.first[:email]
    end

    test "organization_invitations_data returns empty array for org with no invitations" do
      org, _owner = create_org_with_owner!(name: "Empty Org")

      data = organization_invitations_data(org)
      assert_empty data
    end

    test "organization_invitations_data inviter_display_name uses name when present" do
      org, owner = create_org_with_owner!(name: "Name Inviter Org")

      Organizations::Invitation.create!(
        organization: org,
        email: "test@example.com",
        role: "member",
        invited_by: owner,
        token: SecureRandom.urlsafe_base64(32),
        expires_at: 7.days.from_now
      )

      data = organization_invitations_data(org)
      assert_equal owner.name, data.first[:invited_by_name]
    end

    test "organization_invitations_data inviter_display_name falls back to email" do
      org = Organizations::Organization.create!(name: "Email Inviter Org")
      owner = User.create!(email: "owner@example.com", name: nil)
      Organizations::Membership.create!(user: owner, organization: org, role: "owner")

      Organizations::Invitation.create!(
        organization: org,
        email: "test@example.com",
        role: "member",
        invited_by: owner,
        token: SecureRandom.urlsafe_base64(32),
        expires_at: 7.days.from_now
      )

      data = organization_invitations_data(org)
      assert_equal "owner@example.com", data.first[:invited_by_name]
    end

    # === Route helper resolution ===

    test "switch_path falls back to hardcoded path when no route helpers are available" do
      org, owner = create_org_with_owner!(name: "Fallback Org")
      self.current_user = owner
      self.current_organization = org

      data = organization_switcher_data
      assert_equal "/organizations/switch/123", data[:switch_path].call(123)
    end

    test "switch_path uses organizations engine helper when available" do
      org, owner = create_org_with_owner!(name: "Engine Org")
      self.current_user = owner
      self.current_organization = org

      engine_helper = Object.new
      def engine_helper.switch_organization_path(id)
        "/engine/switch/#{id}"
      end

      # Define organizations method to return the engine helper
      define_singleton_method(:organizations) { engine_helper }

      # Clear memoization
      remove_instance_variable(:@_organization_switcher_data) if instance_variable_defined?(:@_organization_switcher_data)

      data = organization_switcher_data
      assert_equal "/engine/switch/42", data[:switch_path].call(42)
    ensure
      # Clean up the singleton method
      class << self; remove_method(:organizations) if method_defined?(:organizations); end
    end

    test "switch_path uses main_app helper as fallback" do
      org, owner = create_org_with_owner!(name: "Main App Org")
      self.current_user = owner
      self.current_organization = org

      main_app_helper = Object.new
      def main_app_helper.switch_organization_path(id)
        "/main_app/switch/#{id}"
      end

      define_singleton_method(:main_app) { main_app_helper }

      # Clear memoization
      remove_instance_variable(:@_organization_switcher_data) if instance_variable_defined?(:@_organization_switcher_data)

      data = organization_switcher_data
      assert_equal "/main_app/switch/99", data[:switch_path].call(99)
    ensure
      class << self; remove_method(:main_app) if method_defined?(:main_app); end
    end

    # === Edge cases ===

    test "organization_switcher_data with multiple organizations" do
      user = create_user!(email: "multi@example.com")
      org1 = Organizations::Organization.create!(name: "Org One")
      org2 = Organizations::Organization.create!(name: "Org Two")
      org3 = Organizations::Organization.create!(name: "Org Three")

      Organizations::Membership.create!(user: user, organization: org1, role: "owner")
      Organizations::Membership.create!(user: user, organization: org2, role: "admin")
      Organizations::Membership.create!(user: user, organization: org3, role: "member")

      self.current_user = user
      self.current_organization = org1

      data = organization_switcher_data
      assert_equal org1.id, data[:current][:id]
      assert_equal 2, data[:others].size

      other_ids = data[:others].map { |o| o[:id] }
      assert_includes other_ids, org2.id
      assert_includes other_ids, org3.id
    end

    test "organization_switcher_data when current org is not in user memberships" do
      user = create_user!(email: "removed@example.com")
      org = Organizations::Organization.create!(name: "Left Org")

      self.current_user = user
      self.current_organization = org

      data = organization_switcher_data
      # Current should fall back to nil values since user is not a member
      assert_nil data[:current][:id]
      assert_nil data[:current][:name]
    end

    test "permission helpers return false for viewer role" do
      org, _owner = create_org_with_owner!(name: "Viewer Org")
      viewer = create_user!(email: "viewer@example.com")
      Organizations::Membership.create!(user: viewer, organization: org, role: "viewer")

      refute can_invite_members?(viewer, org)
      refute can_transfer_ownership?(viewer, org)
      refute can_delete_organization?(viewer, org)
      refute can_manage_organization?(viewer, org)
    end

    test "permission helpers return true for owner role on all permissions" do
      org, owner = create_org_with_owner!(name: "Owner Perm Org")

      assert can_invite_members?(owner, org)
      assert can_transfer_ownership?(owner, org)
      assert can_delete_organization?(owner, org)
      assert can_manage_organization?(owner, org)
    end

    # Reset memoization between tests and disable personal org creation
    def setup
      super
      User.organization_settings = { max_organizations: nil, create_personal_org: false, require_organization: false }.freeze
      remove_instance_variable(:@_organization_switcher_data) if instance_variable_defined?(:@_organization_switcher_data)
      self.current_user = nil
      self.current_organization = nil
    end
  end
end
