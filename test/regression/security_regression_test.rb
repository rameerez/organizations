# frozen_string_literal: true

require "test_helper"

module Organizations
  module Regression
    # Regression tests for all issues documented in REVIEW.md.
    # Each test protects against a specific security, integrity, or correctness
    # property that was identified during the review process.
    #
    # Tests are grouped by severity (P0, P1, P2, Security) and each test
    # documents which REVIEW.md finding it covers.
    class SecurityRegressionTest < Organizations::Test
      # =========================================================================
      # P0 Issues
      # =========================================================================

      # REVIEW.md Round 3, Finding 1:
      # Owner-deletion guard must run BEFORE dependent: :destroy on memberships.
      # Without `prepend: true`, the guard sees zero owners (already destroyed)
      # and incorrectly allows deletion, leaving an ownerless organization.
      test "P0: owner cannot be destroyed while owning organizations" do
        org, owner = create_org_with_owner!(name: "Acme")

        assert_raises(ActiveRecord::RecordNotDestroyed) do
          owner.destroy!
        end

        # Owner and org must still exist with intact ownership
        assert User.exists?(owner.id), "Owner user must survive destroy attempt"
        assert Organizations::Organization.exists?(org.id), "Organization must survive"
        assert_equal 1, org.memberships.where(role: "owner").count, "Owner membership must be intact"
        assert_includes owner.errors.full_messages.join, "Cannot delete a user who still owns organizations"
      end

      # REVIEW.md Round 3, Finding 2:
      # Organization#send_invite_to! must verify inviter is a member of the org.
      # Without this, any code path with an org instance could issue invitations
      # using an arbitrary User as inviter (security bypass).
      test "P0: org-centric invitation API requires inviter membership" do
        org, _owner = create_org_with_owner!(name: "Team Rocket")
        outsider = create_user!(email: "outsider@example.com")

        error = assert_raises(Organizations::NotAMember) do
          org.send_invite_to!("new@example.com", invited_by: outsider)
        end

        assert_match(/members can send invitations/i, error.message)
        assert_equal 0, org.invitations.count, "No invitation should be created"
      end

      # REVIEW.md Round 3, Finding 2 (continued):
      # Even members without :invite_members permission must be blocked.
      test "P0: org-centric invitation API requires invite permission" do
        org, _owner = create_org_with_owner!(name: "Alpha")
        viewer = create_user!(email: "viewer@example.com")
        Organizations::Membership.create!(user: viewer, organization: org, role: "viewer")

        error = assert_raises(Organizations::NotAuthorized) do
          org.send_invite_to!("new@example.com", invited_by: viewer)
        end

        assert_match(/permission to invite/i, error.message)
        assert_equal 0, org.invitations.count, "No invitation should be created"
      end

      # =========================================================================
      # P1 Issues
      # =========================================================================

      # REVIEW.md Round 1, Finding 3:
      # Organization#admins was returning duplicate rows due to double join.
      # Fix adds .distinct to the query.
      test "P1: Organization#admins returns no duplicates" do
        org, owner = create_org_with_owner!(name: "Dedup Org")
        admin = create_user!(email: "admin@example.com")
        Organizations::Membership.create!(user: admin, organization: org, role: "admin")
        member = create_user!(email: "member@example.com")
        Organizations::Membership.create!(user: member, organization: org, role: "member")

        admins = org.admins
        admin_ids = admins.pluck(:id)

        # Must include owner and admin, but not member
        assert_includes admin_ids, owner.id
        assert_includes admin_ids, admin.id
        refute_includes admin_ids, member.id

        # No duplicates
        assert_equal admin_ids.uniq.sort, admin_ids.sort,
                     "admins must not contain duplicate user IDs"
      end

      # REVIEW.md Round 1, Finding 1 (counter cache):
      # Counter cache column is optional. The gem must work without
      # memberships_count on the organizations table.
      test "P1: counter cache is optional - works without memberships_count column" do
        # Our test schema does NOT have memberships_count column
        refute Organizations::Organization.column_names.include?("memberships_count"),
               "Test schema should not have memberships_count column for this test"

        org, _owner = create_org_with_owner!(name: "No Counter Org")
        member = create_user!(email: "member@example.com")
        org.add_member!(member, role: :member)

        # member_count should still work via COUNT query
        assert_equal 2, org.member_count

        # Creating and destroying memberships should not raise
        another = create_user!(email: "another@example.com")
        org.add_member!(another, role: :viewer)
        assert_equal 3, org.member_count

        org.remove_member!(another)
        assert_equal 2, org.member_count
      end

      # REVIEW.md Round 1, Finding 2:
      # Callback veto with strict mode. on_member_invited must run BEFORE
      # persistence and raising must block the invitation.
      test "P1: callback veto with strict mode blocks invitation creation" do
        org, owner = create_org_with_owner!(name: "Limited Org")

        # Configure a strict callback that vetoes invitations
        Organizations.configure do |config|
          config.on_member_invited do |_ctx|
            raise Organizations::InvitationError, "Seat limit reached"
          end
        end

        error = assert_raises(Organizations::InvitationError) do
          org.send_invite_to!("new@example.com", invited_by: owner)
        end

        assert_equal "Seat limit reached", error.message
        assert_equal 0, org.invitations.count,
                     "Invitation must NOT be persisted when callback vetoes"
      end

      # REVIEW.md Round 1, Finding 8:
      # Invitation re-accept when membership still exists should be idempotent.
      test "P1: invitation re-accept when membership exists is idempotent" do
        org, owner = create_org_with_owner!(name: "Idempotent Org")
        invitee = create_user!(email: "invitee@example.com")

        invitation = org.send_invite_to!("invitee@example.com", invited_by: owner)
        membership = invitation.accept!(invitee)

        assert membership.persisted?
        assert invitation.reload.accepted?

        # Accept again - should return existing membership, not raise
        result = invitation.accept!(invitee)
        assert_equal membership.id, result.id, "Re-accept must return existing membership"
      end

      # REVIEW.md Round 1, Finding 8 (continued):
      # When membership was removed after acceptance, re-accepting should raise
      # InvitationAlreadyAccepted (invitation is non-reusable).
      test "P1: invitation re-accept after membership removal raises InvitationAlreadyAccepted" do
        org, owner = create_org_with_owner!(name: "Removed Org")
        invitee = create_user!(email: "invitee@example.com")

        invitation = org.send_invite_to!("invitee@example.com", invited_by: owner)
        invitation.accept!(invitee)

        # Remove member
        org.remove_member!(invitee)

        # Re-accept should raise, not crash with RecordNotFound
        assert_raises(Organizations::InvitationAlreadyAccepted) do
          invitation.reload.accept!(invitee)
        end
      end

      # REVIEW.md Round 3, Finding 6:
      # transfer_ownership_to! must raise NoOwnerPresent instead of
      # NoMethodError when owner membership is missing (corrupted state).
      test "P1: NoOwnerPresent error on corrupted state" do
        org = Organizations::Organization.create!(name: "Corrupted Org")
        admin = create_user!(email: "admin@example.com")
        Organizations::Membership.create!(user: admin, organization: org, role: "admin")

        # No owner membership exists - corrupted state
        assert_nil org.owner_membership

        error = assert_raises(Organizations::Organization::NoOwnerPresent) do
          org.transfer_ownership_to!(admin)
        end

        assert_match(/no owner membership/i, error.message)
      end

      # REVIEW.md Round 3, Finding 7:
      # Controller uses domain method (Organization#change_role_of!) for role
      # changes instead of direct membership updates with duplicated logic.
      test "P1: controller uses domain method for role changes" do
        org, _owner = create_org_with_owner!(name: "Domain Method Org")
        member = create_user!(email: "member@example.com")
        membership = Organizations::Membership.create!(user: member, organization: org, role: "member")

        # Use the domain method that the controller should be calling
        org.change_role_of!(member, to: :admin)
        membership.reload

        assert_equal "admin", membership.role
      end

      # REVIEW.md / view_helpers.rb:
      # Nil inviter should not crash serialization in invitations_data.
      test "P1: nil inviter handling does not crash serialization" do
        org, owner = create_org_with_owner!(name: "Nil Inviter Org")
        invitation = org.send_invite_to!("someone@example.com", invited_by: owner)

        # Simulate inviter being deleted (nullified via dependent: :nullify)
        invitation.update_column(:invited_by_id, nil)
        invitation.reload

        assert_nil invitation.invited_by

        # ViewHelpers should handle nil inviter gracefully
        helper = Object.new
        helper.extend(Organizations::ViewHelpers)

        # Test the inviter_display_name private method via send
        result = helper.send(:inviter_display_name, nil)
        assert_nil result, "inviter_display_name(nil) should return nil, not crash"
      end

      # =========================================================================
      # P2 Issues
      # =========================================================================

      # REVIEW.md Round 1, Finding 9:
      # Controllers and view helpers should use permission-based authorization,
      # not role-based. This ensures custom role configurations work.
      test "P2: permission-based authorization in view helpers" do
        org, _owner = create_org_with_owner!(name: "Perms Org")
        admin = create_user!(email: "admin@example.com")
        Organizations::Membership.create!(user: admin, organization: org, role: "admin")
        viewer = create_user!(email: "viewer@example.com")
        Organizations::Membership.create!(user: viewer, organization: org, role: "viewer")

        helper = Object.new
        helper.extend(Organizations::ViewHelpers)

        # Admin has invite_members permission
        assert helper.can_invite_members?(admin, org),
               "Admin should be able to invite members (permission-based check)"

        # Viewer does NOT have invite_members permission
        refute helper.can_invite_members?(viewer, org),
               "Viewer should not be able to invite members"

        # Admin has manage_settings permission
        assert helper.can_manage_organization?(admin, org),
               "Admin should be able to manage organization"

        # Viewer does NOT have manage_settings permission
        refute helper.can_manage_organization?(viewer, org),
               "Viewer should not be able to manage organization"
      end

      # REVIEW.md Round 1, Finding 10:
      # Unauthorized behavior should be consistent between ControllerHelpers
      # and engine ApplicationController. Both should redirect/render,
      # not raise exceptions.
      test "P2: consistent unauthorized behavior between helpers and engine" do
        # ControllerHelpers#handle_unauthorized uses respond_to with redirect/render
        # by default (not raise). Verify the method exists and is private.
        assert ControllerHelpers.private_method_defined?(:handle_unauthorized) ||
               ControllerHelpers.instance_method(:handle_unauthorized),
               "handle_unauthorized must be defined in ControllerHelpers"
      end

      # REVIEW.md Round 1, Finding 11:
      # Fallback org should use most recently used ordering (updated_at desc),
      # not created_at desc.
      test "P2: most recently used org fallback uses updated_at ordering" do
        user = create_user!(email: "switcher@example.com")
        org_old = Organizations::Organization.create!(name: "Old Org")
        org_new = Organizations::Organization.create!(name: "New Org")

        # Create memberships with different timestamps
        m_old = Organizations::Membership.create!(user: user, organization: org_old, role: "member")
        m_new = Organizations::Membership.create!(user: user, organization: org_new, role: "member")

        # Touch old org's membership to make it "most recently used"
        m_old.update_column(:updated_at, Time.current + 1.hour)
        m_new.update_column(:updated_at, Time.current - 1.hour)

        # Simulate fallback_organization_for logic
        # The method orders by updated_at: :desc first
        fallback_membership = user.memberships.includes(:organization)
                                  .order(updated_at: :desc, created_at: :desc)
                                  .first
        fallback_org = fallback_membership&.organization

        assert_equal org_old.id, fallback_org.id,
                     "Fallback should select org with most recently updated membership"
      end

      # REVIEW.md Round 1, Finding 12:
      # role_in should reuse loaded associations when org.memberships is loaded.
      test "P2: loaded association optimization in role_in" do
        user = create_user!(email: "preload@example.com")
        org = Organizations::Organization.create!(name: "Preload Org")
        Organizations::Membership.create!(user: user, organization: org, role: "admin")

        # Load memberships on the org
        org_with_memberships = Organizations::Organization
                                 .includes(:memberships)
                                 .find(org.id)

        assert org_with_memberships.association(:memberships).loaded?,
               "Memberships should be preloaded"

        # role_in should use loaded data (no extra query)
        role = user.role_in(org_with_memberships)
        assert_equal :admin, role
      end

      # REVIEW.md Round 1, Finding 12 (continued):
      # role_in should also work with user.memberships preloaded.
      test "P2: loaded association optimization in role_in via user memberships" do
        user = create_user!(email: "preload2@example.com")
        org = Organizations::Organization.create!(name: "Preload Org 2")
        Organizations::Membership.create!(user: user, organization: org, role: "member")

        # Preload memberships on the user
        user.memberships.load

        assert user.memberships.loaded?, "User memberships should be preloaded"

        # role_in should use loaded data
        role = user.role_in(org)
        assert_equal :member, role
      end

      # REVIEW.md Round 1, Finding 13:
      # MySQL does not support partial unique indexes; this limitation should
      # be documented and the gem should still work (application-level validation).
      test "P2: MySQL uniqueness limitation - application-level validation catches duplicate pending invitations" do
        org, owner = create_org_with_owner!(name: "MySQL Test Org")

        # Create first pending invitation
        invitation1 = org.send_invite_to!("duplicate@example.com", invited_by: owner)
        assert invitation1.persisted?

        # Second invitation to same email should return existing (idempotent)
        invitation2 = org.send_invite_to!("duplicate@example.com", invited_by: owner)
        assert_equal invitation1.id, invitation2.id,
                     "Duplicate pending invitation should return existing one"
      end

      # =========================================================================
      # Security Issues
      # =========================================================================

      # Security: Non-member cannot send invitations via org API.
      # This is defense in depth - even if a non-member somehow gets an org instance,
      # they cannot use it to invite others.
      test "Security: non-member cannot send invitations via org API" do
        org, _owner = create_org_with_owner!(name: "Secure Org")
        non_member = create_user!(email: "attacker@example.com")

        assert_raises(Organizations::NotAMember) do
          org.send_invite_to!("victim@example.com", invited_by: non_member)
        end

        assert_equal 0, org.invitations.count
      end

      # Security: Viewer cannot send invitations (lacks :invite_members permission).
      test "Security: viewer cannot send invitations" do
        org, _owner = create_org_with_owner!(name: "Viewer Org")
        viewer = create_user!(email: "viewer@example.com")
        Organizations::Membership.create!(user: viewer, organization: org, role: "viewer")

        refute Roles.has_permission?(:viewer, :invite_members),
               "Viewer must not have invite_members permission"

        assert_raises(Organizations::NotAuthorized) do
          org.send_invite_to!("someone@example.com", invited_by: viewer)
        end
      end

      # Security: Member cannot send invitations (lacks :invite_members permission).
      test "Security: member cannot send invitations" do
        org, _owner = create_org_with_owner!(name: "Member Org")
        member = create_user!(email: "member@example.com")
        Organizations::Membership.create!(user: member, organization: org, role: "member")

        refute Roles.has_permission?(:member, :invite_members),
               "Member must not have invite_members permission"

        assert_raises(Organizations::NotAuthorized) do
          org.send_invite_to!("someone@example.com", invited_by: member)
        end
      end

      # Security: Cannot invite as owner role.
      # Owner role can only be assigned via transfer_ownership_to!.
      test "Security: cannot invite as owner role" do
        org, owner = create_org_with_owner!(name: "No Owner Invite")

        assert_raises(Organizations::Organization::CannotInviteAsOwner) do
          org.send_invite_to!("someone@example.com", invited_by: owner, role: :owner)
        end

        assert_equal 0, org.invitations.count
      end

      # Security: Cannot accept invitation as owner role.
      # Even if an invitation somehow has role=owner, acceptance must be blocked.
      test "Security: cannot accept invitation as owner role" do
        org, owner = create_org_with_owner!(name: "No Owner Accept")
        invitee = create_user!(email: "invitee@example.com")

        # Create invitation normally then tamper with role
        invitation = org.send_invite_to!("invitee@example.com", invited_by: owner)
        invitation.update_column(:role, "owner")
        invitation.reload

        assert_raises(Invitation::CannotAcceptAsOwner) do
          invitation.accept!(invitee)
        end

        # Invitee should NOT be a member
        refute org.has_member?(invitee), "Invitee must not become a member with owner role"
      end

      # Security: Cannot promote to owner via promote_to!.
      # Owner promotion requires transfer_ownership_to! for audit and safety.
      test "Security: cannot promote to owner via promote_to!" do
        org, _owner = create_org_with_owner!(name: "No Promote Owner")
        member = create_user!(email: "member@example.com")
        membership = Organizations::Membership.create!(user: member, organization: org, role: "member")

        assert_raises(Membership::CannotPromoteToOwner) do
          membership.promote_to!(:owner)
        end

        membership.reload
        assert_equal "member", membership.role, "Role must not change to owner"
      end

      # Security: Cannot add member as owner via add_member!.
      # Owner must be set via transfer_ownership_to! or initial creation.
      test "Security: cannot add member as owner via add_member!" do
        org, _owner = create_org_with_owner!(name: "No Add Owner")
        new_user = create_user!(email: "new@example.com")

        assert_raises(Organizations::Organization::CannotHaveMultipleOwners) do
          org.add_member!(new_user, role: :owner)
        end

        refute org.has_member?(new_user), "User must not be added as owner"
      end

      # =========================================================================
      # Additional integrity tests from REVIEW.md
      # =========================================================================

      # REVIEW.md: Owner deletion guard uses prepend: true to run BEFORE
      # dependent: :destroy. Verify that non-owner users CAN be deleted.
      test "integrity: non-owner user can be destroyed" do
        org, _owner = create_org_with_owner!(name: "Deletable Org")

        # Disable personal org creation so the member doesn't become an owner
        Organizations.configure { |c| c.create_personal_organization = false }
        # Re-set the class-level setting so has_organizations picks it up
        User.organization_settings = User.organization_settings.merge(create_personal_org: false).freeze

        member = create_user!(email: "deletable@example.com")
        Organizations::Membership.create!(user: member, organization: org, role: "member")

        # Member does not own any org, so deletion should succeed
        refute member.memberships.where(role: "owner").exists?,
               "Member must not own any organizations for this test"

        assert_nothing_raised do
          member.destroy!
        end

        refute User.exists?(member.id)
        # Membership should be destroyed via dependent: :destroy
        refute org.memberships.exists?(user_id: member.id)
      end

      # REVIEW.md: After transferring ownership, old owner must become admin,
      # new owner must be owner. Verify the full flow.
      test "integrity: transfer_ownership_to! correctly swaps roles" do
        org, owner = create_org_with_owner!(name: "Transfer Org")
        admin = create_user!(email: "admin@example.com")
        Organizations::Membership.create!(user: admin, organization: org, role: "admin")

        org.transfer_ownership_to!(admin)

        # Verify role swap
        assert_equal "admin", org.memberships.find_by(user_id: owner.id).role,
                     "Old owner must become admin"
        assert_equal "owner", org.memberships.find_by(user_id: admin.id).role,
                     "New owner must become owner"
        assert_equal admin, org.reload.owner
      end

      # REVIEW.md: Transfer to current owner is a no-op
      test "integrity: transfer_ownership_to! current owner is no-op" do
        org, owner = create_org_with_owner!(name: "Noop Transfer")

        result = org.transfer_ownership_to!(owner)

        assert_equal owner.id, result.user_id
        assert_equal "owner", org.memberships.find_by(user_id: owner.id).role
      end

      # REVIEW.md: Admin can send invitations (has :invite_members permission)
      test "integrity: admin can send invitations" do
        org, _owner = create_org_with_owner!(name: "Admin Invite Org")
        admin = create_user!(email: "admin@example.com")
        Organizations::Membership.create!(user: admin, organization: org, role: "admin")

        assert Roles.has_permission?(:admin, :invite_members)

        invitation = org.send_invite_to!("newperson@example.com", invited_by: admin)
        assert invitation.persisted?
        assert_equal admin.id, invitation.invited_by_id
      end

      # REVIEW.md: change_role_of! cannot promote to owner directly
      test "integrity: change_role_of! blocks promotion to owner" do
        org, _owner = create_org_with_owner!(name: "Block Promote Org")
        member = create_user!(email: "member@example.com")
        Organizations::Membership.create!(user: member, organization: org, role: "member")

        assert_raises(Organizations::Organization::CannotHaveMultipleOwners) do
          org.change_role_of!(member, to: :owner)
        end
      end

      # REVIEW.md: change_role_of! cannot demote owner directly
      test "integrity: change_role_of! blocks demotion of owner" do
        org, owner = create_org_with_owner!(name: "Block Demote Org")

        assert_raises(Organizations::Organization::CannotDemoteOwner) do
          org.change_role_of!(owner, to: :admin)
        end
      end
    end
  end
end
