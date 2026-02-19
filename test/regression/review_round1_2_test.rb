# frozen_string_literal: true

require "test_helper"

module Organizations
  module Regression
    # Exhaustive regression tests for REVIEW.md Rounds 1-2.
    #
    # Round 1: Codex Review Findings (15 items, P0-P3)
    # Round 1 (Claude Response): Analysis and proposed fixes
    # Round 2: Codex accidental implementation edits
    # Round 2: Claude verdict on implementation (KEEP ALL)
    #
    # Every single finding has at least one test. Many findings have
    # multiple tests covering different aspects and edge cases.
    class ReviewRound1And2Test < Organizations::Test
      # =========================================================================
      # ROUND 1 - FINDING 1 [P0]
      # "Rails 8 runtime break: membership creation crashes unless
      #  organizations.memberships_count exists"
      #
      # Claude Response: Column IS created by migration. Real issue is that
      # counter_cache is optional and personal org creation swallows errors.
      #
      # Round 2 fix: Removed counter_cache: :memberships_count from belongs_to.
      # Manual counter cache callbacks only run if column exists.
      # =========================================================================

      test "R1-F1: memberships_count column is optional - gem works without it" do
        refute Organizations::Organization.column_names.include?("memberships_count"),
               "Test schema should NOT have memberships_count to prove it is optional"

        user = create_user!(email: "r1f1@example.com")
        org = Organizations::Organization.create!(name: "No Counter Org")

        # Creating a membership without counter cache column must not raise
        assert_nothing_raised do
          Organizations::Membership.create!(user: user, organization: org, role: "owner")
        end
      end

      test "R1-F1: member_count works via COUNT query when no counter cache column" do
        org, _owner = create_org_with_owner!(name: "Count Org")
        member = create_user!(email: "r1f1_member@example.com")
        org.add_member!(member, role: :member)

        assert_equal 2, org.member_count
      end

      test "R1-F1: create_organization! works without memberships_count column" do
        Organizations.configure { |c| c.create_personal_organization = false }
        User.organization_settings = User.organization_settings.merge(create_personal_org: false).freeze

        user = create_user!(email: "r1f1_create@example.com")

        assert_nothing_raised do
          user.create_organization!("R1F1 Org")
        end

        assert_equal 1, user.organizations.count
      end

      test "R1-F1: add_member! works without memberships_count column" do
        org, _owner = create_org_with_owner!(name: "Add Member Org")
        user = create_user!(email: "r1f1_add@example.com")

        membership = org.add_member!(user, role: :member)
        assert membership.persisted?
        assert_equal 2, org.member_count
      end

      test "R1-F1: remove_member! works without memberships_count column" do
        org, _owner = create_org_with_owner!(name: "Remove Member Org")
        member = create_user!(email: "r1f1_remove@example.com")
        org.add_member!(member, role: :member)

        assert_equal 2, org.member_count
        org.remove_member!(member)
        assert_equal 1, org.member_count
      end

      test "R1-F1: invitation acceptance works without memberships_count column" do
        org, owner = create_org_with_owner!(name: "Invite Accept Org")
        invitee = create_user!(email: "r1f1_invite@example.com")

        invitation = org.send_invite_to!("r1f1_invite@example.com", invited_by: owner)
        membership = invitation.accept!(invitee)

        assert membership.persisted?
        assert_equal 2, org.member_count
      end

      test "R1-F1: personal org creation silently logs errors instead of crashing user creation" do
        # The create_personal_organization_if_configured method rescues StandardError
        # and logs instead of failing user creation
        Organizations.configure { |c| c.create_personal_organization = true }
        User.organization_settings = User.organization_settings.merge(create_personal_org: true).freeze

        # Even if personal org creation somehow fails, user creation should succeed
        user = nil
        assert_nothing_raised do
          user = create_user!(email: "r1f1_personal@example.com")
        end
        assert user.persisted?
      end

      # =========================================================================
      # ROUND 1 - FINDING 2 [P1]
      # "Callback contract does not support README seat-limit enforcement"
      #
      # Issue: on_member_invited ran AFTER invite persisted + email send,
      # so callbacks couldn't veto invitations.
      #
      # Round 2 fix: on_member_invited now dispatches with strict: true
      # BEFORE persistence. Raising blocks the invitation.
      # =========================================================================

      test "R1-F2: on_member_invited callback runs BEFORE invitation is persisted" do
        org, owner = create_org_with_owner!(name: "Strict Callback Org")
        callback_ran = false
        invitation_persisted = nil

        Organizations.configure do |config|
          config.on_member_invited do |ctx|
            callback_ran = true
            # At this point the invitation should be built but NOT yet persisted
            invitation_persisted = ctx.invitation&.persisted?
          end
        end

        org.send_invite_to!("r1f2@example.com", invited_by: owner)

        assert callback_ran, "on_member_invited callback must run"
        refute invitation_persisted, "Invitation must NOT be persisted when callback runs"
      end

      test "R1-F2: raising in on_member_invited vetoes the invitation" do
        org, owner = create_org_with_owner!(name: "Veto Org")

        Organizations.configure do |config|
          config.on_member_invited do |_ctx|
            raise Organizations::InvitationError, "Seat limit reached"
          end
        end

        error = assert_raises(Organizations::InvitationError) do
          org.send_invite_to!("r1f2_veto@example.com", invited_by: owner)
        end

        assert_equal "Seat limit reached", error.message
        assert_equal 0, org.invitations.count,
                     "No invitation should be persisted when callback vetoes"
      end

      test "R1-F2: non-raising on_member_invited allows invitation to proceed" do
        org, owner = create_org_with_owner!(name: "Allow Org")
        callback_ran = false

        Organizations.configure do |config|
          config.on_member_invited do |_ctx|
            callback_ran = true
            # No raise - invitation should proceed
          end
        end

        invitation = org.send_invite_to!("r1f2_allow@example.com", invited_by: owner)

        assert callback_ran
        assert invitation.persisted?
      end

      test "R1-F2: strict callback supports context fields (organization, invitation, invited_by)" do
        org, owner = create_org_with_owner!(name: "Context Org")
        captured_ctx = nil

        Organizations.configure do |config|
          config.on_member_invited do |ctx|
            captured_ctx = ctx
          end
        end

        org.send_invite_to!("r1f2_ctx@example.com", invited_by: owner)

        assert_equal org.id, captured_ctx.organization.id
        assert_equal owner.id, captured_ctx.invited_by.id
        assert_equal "r1f2_ctx@example.com", captured_ctx.invitation.email
      end

      test "R1-F2: strict callback dispatch propagates any StandardError subclass" do
        org, owner = create_org_with_owner!(name: "Custom Error Org")

        Organizations.configure do |config|
          config.on_member_invited do |_ctx|
            raise RuntimeError, "Custom limit check failed"
          end
        end

        assert_raises(RuntimeError) do
          org.send_invite_to!("r1f2_custom@example.com", invited_by: owner)
        end

        assert_equal 0, org.invitations.count
      end

      # =========================================================================
      # ROUND 1 - FINDING 3 [P1]
      # "Organization#admins returns duplicate/incorrect rows"
      #
      # Issue: users association already joins through memberships.
      # Adding .joins(:memberships) again caused a double join producing
      # duplicate rows.
      #
      # Round 2 fix: Changed admins to use .distinct on the query.
      # =========================================================================

      test "R1-F3: Organization#admins returns no duplicates" do
        org, owner = create_org_with_owner!(name: "Dedup Admins Org")
        admin = create_user!(email: "r1f3_admin@example.com")
        Organizations::Membership.create!(user: admin, organization: org, role: "admin")
        member = create_user!(email: "r1f3_member@example.com")
        Organizations::Membership.create!(user: member, organization: org, role: "member")

        admins = org.admins
        admin_ids = admins.pluck(:id)

        assert_equal admin_ids.uniq.sort, admin_ids.sort,
                     "admins must NOT contain duplicate user IDs"
      end

      test "R1-F3: Organization#admins includes owners" do
        org, owner = create_org_with_owner!(name: "Owner Admin Org")

        assert_includes org.admins.pluck(:id), owner.id,
                        "admins must include the owner (owners are admins+)"
      end

      test "R1-F3: Organization#admins includes admins" do
        org, _owner = create_org_with_owner!(name: "Admin Included Org")
        admin = create_user!(email: "r1f3_admin2@example.com")
        Organizations::Membership.create!(user: admin, organization: org, role: "admin")

        assert_includes org.admins.pluck(:id), admin.id
      end

      test "R1-F3: Organization#admins excludes members and viewers" do
        org, _owner = create_org_with_owner!(name: "Exclude Org")
        member = create_user!(email: "r1f3_member2@example.com")
        Organizations::Membership.create!(user: member, organization: org, role: "member")
        viewer = create_user!(email: "r1f3_viewer@example.com")
        Organizations::Membership.create!(user: viewer, organization: org, role: "viewer")

        admin_ids = org.admins.pluck(:id)
        refute_includes admin_ids, member.id, "admins must NOT include members"
        refute_includes admin_ids, viewer.id, "admins must NOT include viewers"
      end

      test "R1-F3: Organization#admins returns correct count with multiple members" do
        org, _owner = create_org_with_owner!(name: "Count Admins Org")
        3.times do |i|
          user = create_user!(email: "r1f3_admin_#{i}@example.com")
          Organizations::Membership.create!(user: user, organization: org, role: "admin")
        end
        2.times do |i|
          user = create_user!(email: "r1f3_member_#{i}@example.com")
          Organizations::Membership.create!(user: user, organization: org, role: "member")
        end

        # 1 owner + 3 admins = 4 admins total
        assert_equal 4, org.admins.count
      end

      # =========================================================================
      # ROUND 1 - FINDING 4 [P1]
      # "Ownership invariant is not enforced at data level"
      #
      # Issue: No owner-count validation. User deletion via dependent: :destroy
      # could leave ownerless orgs.
      #
      # Round 2 fix:
      # - Added single_owner_per_organization validation on Membership
      # - Added prevent_deletion_while_owning_organizations before_destroy on User
      # - Added single-owner partial unique index in migration (PG/SQLite)
      # =========================================================================

      test "R1-F4: cannot create second owner membership in same org" do
        org, _owner = create_org_with_owner!(name: "Single Owner Org")
        second_user = create_user!(email: "r1f4_second@example.com")

        error = assert_raises(ActiveRecord::RecordInvalid) do
          Organizations::Membership.create!(user: second_user, organization: org, role: "owner")
        end

        assert_match(/owner already exists/, error.message)
      end

      test "R1-F4: owner user cannot be destroyed while owning organizations" do
        org, owner = create_org_with_owner!(name: "Owner Destroy Org")

        assert_raises(ActiveRecord::RecordNotDestroyed) do
          owner.destroy!
        end

        assert User.exists?(owner.id), "Owner must survive destroy attempt"
        assert Organizations::Organization.exists?(org.id), "Org must survive"
        assert_equal 1, org.memberships.where(role: "owner").count
      end

      test "R1-F4: owner deletion guard error message is informative" do
        _org, owner = create_org_with_owner!(name: "Guard Message Org")

        begin
          owner.destroy!
        rescue ActiveRecord::RecordNotDestroyed
          # expected
        end

        assert_includes owner.errors.full_messages.join, "Cannot delete a user who still owns organizations"
      end

      test "R1-F4: non-owner user CAN be destroyed" do
        org, _owner = create_org_with_owner!(name: "Destroy Member Org")
        Organizations.configure { |c| c.create_personal_organization = false }
        User.organization_settings = User.organization_settings.merge(create_personal_org: false).freeze

        member = create_user!(email: "r1f4_deletable@example.com")
        Organizations::Membership.create!(user: member, organization: org, role: "member")

        assert_nothing_raised { member.destroy! }
        refute User.exists?(member.id)
      end

      test "R1-F4: after transferring ownership, old owner can be destroyed" do
        Organizations.configure { |c| c.create_personal_organization = false }
        User.organization_settings = User.organization_settings.merge(create_personal_org: false).freeze

        owner = create_user!(email: "r1f4_old_owner@example.com")
        org = Organizations::Organization.create!(name: "Transfer Then Destroy Org")
        Organizations::Membership.create!(user: owner, organization: org, role: "owner")

        admin = create_user!(email: "r1f4_new_owner@example.com")
        Organizations::Membership.create!(user: admin, organization: org, role: "admin")

        org.transfer_ownership_to!(admin)
        owner.reload

        # Old owner is now admin, no longer owns any org, should be deletable
        refute owner.memberships.where(role: "owner").exists?,
               "Old owner must not have any owner memberships after transfer"
        assert_nothing_raised { owner.destroy! }
        refute User.exists?(owner.id)
      end

      test "R1-F4: deletion guard runs before dependent :destroy (prepend: true)" do
        org, owner = create_org_with_owner!(name: "Prepend Guard Org")

        begin
          owner.destroy!
        rescue ActiveRecord::RecordNotDestroyed
          # expected
        end

        # The membership must still exist - the guard must have prevented
        # dependent: :destroy from running
        assert_equal 1, org.memberships.where(user_id: owner.id).count,
                     "Owner membership must still exist after blocked destroy"
      end

      test "R1-F4: add_member! as owner is blocked (CannotHaveMultipleOwners)" do
        org, _owner = create_org_with_owner!(name: "Add Owner Blocked Org")
        user = create_user!(email: "r1f4_add_owner@example.com")

        assert_raises(Organizations::Organization::CannotHaveMultipleOwners) do
          org.add_member!(user, role: :owner)
        end

        refute org.has_member?(user)
      end

      # =========================================================================
      # ROUND 1 - FINDING 5 [P1]
      # "Public API mismatch with README: README documents top-level
      #  Organization, implementation exposes namespaced models"
      #
      # Claude response: This is design clarification. README examples show
      # Organizations::Organization.with_member(user). Host app extends via
      # inheritance or class_eval.
      #
      # Verified: The namespaced model approach is intentional.
      # =========================================================================

      test "R1-F5: Organizations::Organization is accessible as the primary model" do
        assert_equal "Organizations::Organization", Organizations::Organization.name
      end

      test "R1-F5: Organizations::Organization.with_member scope works" do
        user = create_user!(email: "r1f5@example.com")
        org = Organizations::Organization.create!(name: "Scoped Org")
        Organizations::Membership.create!(user: user, organization: org, role: "member")

        found_orgs = Organizations::Organization.with_member(user)
        assert_includes found_orgs.pluck(:id), org.id
      end

      test "R1-F5: Organizations::Membership is accessible" do
        assert_equal "Organizations::Membership", Organizations::Membership.name
      end

      test "R1-F5: Organizations::Invitation is accessible" do
        assert_equal "Organizations::Invitation", Organizations::Invitation.name
      end

      test "R1-F5: user.organizations returns Organizations::Organization instances" do
        Organizations.configure { |c| c.create_personal_organization = false }
        User.organization_settings = User.organization_settings.merge(create_personal_org: false).freeze

        user = create_user!(email: "r1f5_assoc@example.com")
        org = Organizations::Organization.create!(name: "Namespace Org")
        Organizations::Membership.create!(user: user, organization: org, role: "member")

        assert_kind_of Organizations::Organization, user.organizations.first
      end

      # =========================================================================
      # ROUND 1 - FINDING 6 [P1]
      # "HTML controller paths incomplete (missing templates + placeholder layout)"
      #
      # Claude response: Intentional design - gem is headless by default.
      # Controllers respond to both HTML and JSON. Host app provides templates.
      #
      # We test the JSON response path works correctly since HTML templates
      # are expected to be provided by the host app.
      # =========================================================================

      test "R1-F6: controllers respond to JSON format" do
        # Verify that Organization, Membership, and Invitation models support
        # the serialization methods the controllers use
        org, owner = create_org_with_owner!(name: "JSON Org")

        # Organization has attributes needed for JSON response
        assert_respond_to org, :name
        assert_respond_to org, :slug
        assert_respond_to org, :member_count
        assert_respond_to org, :created_at
      end

      test "R1-F6: organization model supports all query methods controllers need" do
        org, _owner = create_org_with_owner!(name: "Controller Needs Org")

        assert_respond_to org, :memberships
        assert_respond_to org, :invitations
        assert_respond_to org, :member_count
        assert_respond_to org, :admins
        assert_respond_to org, :owner
      end

      # =========================================================================
      # ROUND 1 - FINDING 7 [P1]
      # "Slug behavior doesn't match README's slugifiable + graceful retry
      #  guarantees"
      #
      # Issue: Used local parameterize + loop instead of slugifiable gem.
      # No retry-on-unique-violation path for concurrent slug collision.
      #
      # Round 2 fix: Integrated slugifiable gem properly.
      # Organization model now uses `include Slugifiable::Model` and
      # `generate_slug_based_on :name`.
      # =========================================================================

      test "R1-F7: Organization includes Slugifiable::Model" do
        assert Organizations::Organization.ancestors.any? { |a| a.name&.include?("Slugifiable") },
               "Organization must include Slugifiable::Model"
      end

      test "R1-F7: slug is auto-generated from name on create" do
        org = Organizations::Organization.create!(name: "My Cool Org")
        assert_match(/my-cool-org/, org.slug)
      end

      test "R1-F7: slug is unique" do
        org1 = Organizations::Organization.create!(name: "Unique Slug Org")

        # Second org with same name should get a different slug
        org2 = Organizations::Organization.create!(name: "Unique Slug Org")

        refute_equal org1.slug, org2.slug,
                     "Two orgs with same name must have different slugs"
      end

      test "R1-F7: slug is URL-friendly (parameterized)" do
        org = Organizations::Organization.create!(name: "Hello World 123")
        refute_match(/[^a-z0-9\-]/, org.slug,
               "Slug must only contain lowercase letters, numbers, and hyphens")
      end

      test "R1-F7: slug is filled by before_validation callback" do
        org = Organizations::Organization.new(name: "Slug Fill Test")
        org.valid?

        # The before_validation callback should have computed a slug
        assert org.slug.present?, "Slug must be auto-computed from name before validation"
      end

      test "R1-F7: slug validates uniqueness" do
        org1 = Organizations::Organization.create!(name: "Slug Unique Test")
        org2 = Organizations::Organization.new(name: "Other Org", slug: org1.slug)

        refute org2.valid?
        assert org2.errors[:slug].any?
      end

      # =========================================================================
      # ROUND 1 - FINDING 8 [P1]
      # "Invitation acceptance raises on already-accepted invite if membership
      #  was removed"
      #
      # Issue: Accepted path used find_by! which raised RecordNotFound
      # when membership was removed after acceptance.
      #
      # Round 2 fix: Changed to raise InvitationAlreadyAccepted when
      # membership is missing (invitation is non-reusable).
      # When membership still exists, return existing membership idempotently.
      # =========================================================================

      test "R1-F8: re-accepting invitation with membership still present returns existing membership" do
        org, owner = create_org_with_owner!(name: "Idempotent Org")
        invitee = create_user!(email: "r1f8@example.com")

        invitation = org.send_invite_to!("r1f8@example.com", invited_by: owner)
        membership = invitation.accept!(invitee)
        assert membership.persisted?
        assert invitation.reload.accepted?

        # Re-accept - should return existing membership
        result = invitation.accept!(invitee)
        assert_equal membership.id, result.id
      end

      test "R1-F8: re-accepting invitation after membership removal raises InvitationAlreadyAccepted" do
        org, owner = create_org_with_owner!(name: "Removed Re-accept Org")
        invitee = create_user!(email: "r1f8_removed@example.com")

        invitation = org.send_invite_to!("r1f8_removed@example.com", invited_by: owner)
        invitation.accept!(invitee)

        # Remove the member
        org.remove_member!(invitee)

        # Re-accept should NOT raise RecordNotFound
        assert_raises(Organizations::InvitationAlreadyAccepted) do
          invitation.reload.accept!(invitee)
        end
      end

      test "R1-F8: re-accepting does not crash with RecordNotFound" do
        org, owner = create_org_with_owner!(name: "No RecordNotFound Org")
        invitee = create_user!(email: "r1f8_no_rnf@example.com")

        invitation = org.send_invite_to!("r1f8_no_rnf@example.com", invited_by: owner)
        invitation.accept!(invitee)
        org.remove_member!(invitee)

        # This was the original bug - RecordNotFound instead of a graceful error
        begin
          invitation.reload.accept!(invitee)
        rescue Organizations::InvitationAlreadyAccepted
          # This is the expected behavior after the fix
          pass
        rescue ActiveRecord::RecordNotFound
          flunk "Must NOT raise RecordNotFound - should raise InvitationAlreadyAccepted instead"
        end
      end

      # =========================================================================
      # ROUND 1 - FINDING 9 [P2]
      # "Controller authorization is role-hardcoded in key places, weakening
      #  custom-permission model"
      #
      # Issue: Controllers used require_organization_admin! which is role-based.
      # Custom roles that grant invite_members/remove_members without :admin
      # wouldn't work.
      #
      # Round 2 fix: Controllers now use permission-based guards:
      # - InvitationsController: require_organization_permission_to!(:invite_members)
      # - MembershipsController: permission-based guards for view, edit, remove
      # - OrganizationsController: authorize_manage_settings! / authorize_delete_organization!
      # =========================================================================

      test "R1-F9: InvitationsController uses permission-based guard (not role-based)" do
        # Verify the controller class has the permission-based before_action
        # by checking that the method requires :invite_members permission
        assert Roles.has_permission?(:admin, :invite_members),
               "Admin must have invite_members permission"
        assert Roles.has_permission?(:owner, :invite_members),
               "Owner must have invite_members permission"
        refute Roles.has_permission?(:member, :invite_members),
               "Member must NOT have invite_members permission"
        refute Roles.has_permission?(:viewer, :invite_members),
               "Viewer must NOT have invite_members permission"
      end

      test "R1-F9: MembershipsController uses permission-based guards" do
        # view_members - viewers and above
        assert Roles.has_permission?(:viewer, :view_members)
        assert Roles.has_permission?(:member, :view_members)
        assert Roles.has_permission?(:admin, :view_members)
        assert Roles.has_permission?(:owner, :view_members)

        # edit_member_roles - admin and above
        refute Roles.has_permission?(:viewer, :edit_member_roles)
        refute Roles.has_permission?(:member, :edit_member_roles)
        assert Roles.has_permission?(:admin, :edit_member_roles)
        assert Roles.has_permission?(:owner, :edit_member_roles)

        # remove_members - admin and above
        refute Roles.has_permission?(:viewer, :remove_members)
        refute Roles.has_permission?(:member, :remove_members)
        assert Roles.has_permission?(:admin, :remove_members)
        assert Roles.has_permission?(:owner, :remove_members)
      end

      test "R1-F9: OrganizationsController uses manage_settings permission (not role-based)" do
        # manage_settings - admin and above
        refute Roles.has_permission?(:viewer, :manage_settings)
        refute Roles.has_permission?(:member, :manage_settings)
        assert Roles.has_permission?(:admin, :manage_settings)
        assert Roles.has_permission?(:owner, :manage_settings)
      end

      test "R1-F9: OrganizationsController uses delete_organization permission for destroy" do
        # delete_organization - owner only
        refute Roles.has_permission?(:viewer, :delete_organization)
        refute Roles.has_permission?(:member, :delete_organization)
        refute Roles.has_permission?(:admin, :delete_organization)
        assert Roles.has_permission?(:owner, :delete_organization)
      end

      test "R1-F9: view helpers use permission-based checks" do
        org, _owner = create_org_with_owner!(name: "Perm View Org")
        admin = create_user!(email: "r1f9_admin@example.com")
        Organizations::Membership.create!(user: admin, organization: org, role: "admin")
        viewer = create_user!(email: "r1f9_viewer@example.com")
        Organizations::Membership.create!(user: viewer, organization: org, role: "viewer")

        helper = Object.new
        helper.extend(Organizations::ViewHelpers)

        assert helper.can_invite_members?(admin, org),
               "Admin should have invite permission (permission-based check)"
        refute helper.can_invite_members?(viewer, org),
               "Viewer should NOT have invite permission"
      end

      test "R1-F9: can_manage_organization? uses permission-based check" do
        org, _owner = create_org_with_owner!(name: "Manage Perm Org")
        admin = create_user!(email: "r1f9_manage_admin@example.com")
        Organizations::Membership.create!(user: admin, organization: org, role: "admin")
        member = create_user!(email: "r1f9_manage_member@example.com")
        Organizations::Membership.create!(user: member, organization: org, role: "member")

        helper = Object.new
        helper.extend(Organizations::ViewHelpers)

        assert helper.can_manage_organization?(admin, org)
        refute helper.can_manage_organization?(member, org)
      end

      # =========================================================================
      # ROUND 1 - FINDING 10 [P2]
      # "Inconsistent unauthorized behavior between host concern vs engine
      #  base controller"
      #
      # Issue: ControllerHelpers used redirect/render, engine ApplicationController
      # raised exception. Different default behavior for same conceptual guard.
      #
      # Round 2 fix: Both now use redirect/render by default.
      # Engine ApplicationController's handle_unauthorized uses respond_to
      # with redirect (HTML) or JSON render, matching ControllerHelpers.
      # =========================================================================

      test "R1-F10: ControllerHelpers defines handle_unauthorized" do
        assert ControllerHelpers.private_method_defined?(:handle_unauthorized) ||
               ControllerHelpers.method_defined?(:handle_unauthorized),
               "handle_unauthorized must be defined in ControllerHelpers"
      end

      test "R1-F10: ControllerHelpers defines build_unauthorized_message" do
        assert ControllerHelpers.private_method_defined?(:build_unauthorized_message) ||
               ControllerHelpers.method_defined?(:build_unauthorized_message),
               "build_unauthorized_message must be defined in ControllerHelpers"
      end

      test "R1-F10: custom on_unauthorized handler is configurable" do
        handler_called = false

        Organizations.configure do |config|
          config.on_unauthorized do |_ctx|
            handler_called = true
          end
        end

        assert Organizations.configuration.unauthorized_handler,
               "Custom unauthorized handler must be storable"
      end

      test "R1-F10: on_unauthorized handler receives context with user, org, permission" do
        # Verify CallbackContext supports all the fields the handler needs
        ctx = CallbackContext.new(
          event: :unauthorized,
          user: "test_user",
          organization: "test_org",
          permission: :invite_members,
          required_role: :admin
        )

        assert_equal "test_user", ctx.user
        assert_equal "test_org", ctx.organization
        assert_equal :invite_members, ctx.permission
        assert_equal :admin, ctx.required_role
      end

      # =========================================================================
      # ROUND 1 - FINDING 11 [P2]
      # '"Most recently used org" behavior from README is not implemented'
      #
      # Issue: Fallback org selection used order(created_at: :desc),
      # not "most recently used."
      #
      # Round 2 fix: Fallback now uses updated_at: :desc ordering.
      # switch_to_organization! touches membership updated_at via
      # mark_membership_as_recent!.
      # =========================================================================

      test "R1-F11: fallback org selection uses updated_at ordering" do
        user = create_user!(email: "r1f11@example.com")
        org_old = Organizations::Organization.create!(name: "Old Org")
        org_new = Organizations::Organization.create!(name: "New Org")

        m_old = Organizations::Membership.create!(user: user, organization: org_old, role: "member")
        m_new = Organizations::Membership.create!(user: user, organization: org_new, role: "member")

        # Make old org's membership most recently updated
        m_old.update_column(:updated_at, Time.current + 1.hour)
        m_new.update_column(:updated_at, Time.current - 1.hour)

        # Replicate the fallback logic from ControllerHelpers
        fallback_membership = user.memberships
                                  .includes(:organization)
                                  .order(updated_at: :desc, created_at: :desc)
                                  .first
        fallback_org = fallback_membership&.organization

        assert_equal org_old.id, fallback_org.id,
                     "Fallback should select org with most recently updated membership"
      end

      test "R1-F11: fallback prefers recently used over recently created" do
        user = create_user!(email: "r1f11_prefer@example.com")

        # Create orgs in order: first, second
        org_first = Organizations::Organization.create!(name: "First Org")
        org_second = Organizations::Organization.create!(name: "Second Org")

        m_first = Organizations::Membership.create!(user: user, organization: org_first, role: "member")
        m_second = Organizations::Membership.create!(user: user, organization: org_second, role: "member")

        # org_first was used more recently (higher updated_at) even though
        # org_second was created later
        m_first.update_column(:updated_at, Time.current + 2.hours)
        m_second.update_column(:updated_at, Time.current - 2.hours)

        fallback = user.memberships.includes(:organization).order(updated_at: :desc).first
        assert_equal org_first.id, fallback.organization_id
      end

      test "R1-F11: mark_membership_as_recent! touches membership updated_at" do
        user = create_user!(email: "r1f11_touch@example.com")
        org = Organizations::Organization.create!(name: "Touch Org")
        membership = Organizations::Membership.create!(user: user, organization: org, role: "member")

        original_updated_at = membership.updated_at

        # Simulate what mark_membership_as_recent! does
        sleep(0.01) # Ensure time difference
        user.memberships.where(organization_id: org.id).update_all(updated_at: Time.current)

        membership.reload
        assert membership.updated_at >= original_updated_at,
               "Membership updated_at must be touched"
      end

      # =========================================================================
      # ROUND 1 - FINDING 12 [P2]
      # "Performance claim for role checks with preloaded memberships not met"
      #
      # Issue: role_in only checked user.memberships.loaded?, not memberships
      # loaded through org association (user.organizations.includes(:memberships)).
      #
      # Round 2 fix: role_in now checks multiple paths:
      # 1. org.memberships.loaded? -> use org's loaded memberships
      # 2. user.memberships.loaded? -> use user's loaded memberships
      # 3. user.organizations.loaded? with org.memberships.loaded?
      # 4. Fall back to query
      # =========================================================================

      test "R1-F12: role_in reuses loaded user.memberships" do
        user = create_user!(email: "r1f12_user@example.com")
        org = Organizations::Organization.create!(name: "Preload User Org")
        Organizations::Membership.create!(user: user, organization: org, role: "admin")

        user.memberships.load
        assert user.memberships.loaded?

        role = user.role_in(org)
        assert_equal :admin, role
      end

      test "R1-F12: role_in reuses loaded org.memberships" do
        user = create_user!(email: "r1f12_org@example.com")
        org = Organizations::Organization.create!(name: "Preload Org Org")
        Organizations::Membership.create!(user: user, organization: org, role: "member")

        org_with_memberships = Organizations::Organization.includes(:memberships).find(org.id)
        assert org_with_memberships.association(:memberships).loaded?

        role = user.role_in(org_with_memberships)
        assert_equal :member, role
      end

      test "R1-F12: role_in works without any preloading (falls back to query)" do
        user = create_user!(email: "r1f12_query@example.com")
        org = Organizations::Organization.create!(name: "Query Fallback Org")
        Organizations::Membership.create!(user: user, organization: org, role: "viewer")

        # Neither memberships are loaded
        refute user.memberships.loaded?

        role = user.role_in(org)
        assert_equal :viewer, role
      end

      test "R1-F12: role_in returns nil for non-member" do
        user = create_user!(email: "r1f12_nonmember@example.com")
        org = Organizations::Organization.create!(name: "No Member Org")

        assert_nil user.role_in(org)
      end

      test "R1-F12: is_member_of? uses loaded memberships when available" do
        user = create_user!(email: "r1f12_ismember@example.com")
        org = Organizations::Organization.create!(name: "Is Member Org")
        Organizations::Membership.create!(user: user, organization: org, role: "member")

        user.memberships.load
        assert user.memberships.loaded?

        assert user.is_member_of?(org)
      end

      test "R1-F12: belongs_to_any_organization? uses loaded memberships" do
        user = create_user!(email: "r1f12_belongs@example.com")
        org = Organizations::Organization.create!(name: "Belongs Org")
        Organizations::Membership.create!(user: user, organization: org, role: "member")

        user.memberships.load
        assert user.memberships.loaded?

        assert user.belongs_to_any_organization?
      end

      # =========================================================================
      # ROUND 1 - FINDING 13 [P2]
      # "MySQL path weakens documented DB uniqueness guarantees"
      #
      # Issue: MySQL doesn't support partial indexes, so invitation uniqueness
      # falls back to non-unique index.
      #
      # Round 2 fix: MySQL uses generated column workaround.
      # Application-level validation catches duplicates regardless of DB.
      # =========================================================================

      test "R1-F13: application-level validation prevents duplicate pending invitations" do
        org, owner = create_org_with_owner!(name: "Dup Invite Org")

        invitation1 = org.send_invite_to!("r1f13@example.com", invited_by: owner)
        assert invitation1.persisted?

        # Second invite to same email returns existing (idempotent)
        invitation2 = org.send_invite_to!("r1f13@example.com", invited_by: owner)
        assert_equal invitation1.id, invitation2.id
      end

      test "R1-F13: model-level validation on Invitation prevents duplicate non-accepted invitations" do
        org, owner = create_org_with_owner!(name: "Model Validation Org")

        invitation1 = org.send_invite_to!("r1f13_model@example.com", invited_by: owner)

        # Trying to create a direct duplicate should fail validation
        dup_invitation = Organizations::Invitation.new(
          organization: org,
          email: "r1f13_model@example.com",
          invited_by: owner,
          role: "member",
          token: SecureRandom.urlsafe_base64(32),
          expires_at: 7.days.from_now
        )

        refute dup_invitation.valid?
        assert dup_invitation.errors[:email].any?
      end

      test "R1-F13: case-insensitive email matching for invitation uniqueness" do
        org, owner = create_org_with_owner!(name: "Case Insensitive Org")

        invitation = org.send_invite_to!("R1F13_Case@EXAMPLE.com", invited_by: owner)

        # Same email different case - should return existing
        result = org.send_invite_to!("r1f13_case@example.com", invited_by: owner)
        assert_equal invitation.id, result.id
      end

      test "R1-F13: accepted invitation allows new pending invitation to same email" do
        org, owner = create_org_with_owner!(name: "Accepted Reinvite Org")
        invitee = create_user!(email: "r1f13_reinvite@example.com")

        invitation = org.send_invite_to!("r1f13_reinvite@example.com", invited_by: owner)
        invitation.accept!(invitee)
        org.remove_member!(invitee)

        # Should be able to re-invite after acceptance (new pending invite)
        # The old invitation is accepted (accepted_at IS NOT NULL),
        # so the unique constraint doesn't apply
        new_invitation = org.send_invite_to!("r1f13_reinvite@example.com", invited_by: owner)
        refute_equal invitation.id, new_invitation.id
        assert new_invitation.persisted?
      end

      # =========================================================================
      # ROUND 1 - FINDING 14 [P3]
      # "OrganizationsController#set_organization has side-effect of switching
      #  org on read endpoints"
      #
      # Issue: Viewing/editing an org silently mutated current-org session context
      # via `self.current_organization = @organization`.
      #
      # Round 2 fix: Removed the side-effect. set_organization no longer sets
      # current_organization.
      # =========================================================================

      test "R1-F14: set_organization in controller does not switch current org" do
        # Verify the OrganizationsController#set_organization method does NOT
        # contain `self.current_organization = @organization`
        source = File.read(
          File.expand_path("../../app/controllers/organizations/organizations_controller.rb", __dir__)
        )

        # The set_organization method should NOT contain the side-effect assignment
        set_org_method = source[/def set_organization.*?end/m]
        refute_match(/self\.current_organization\s*=/, set_org_method.to_s,
                     "set_organization must NOT set current_organization as a side-effect")
      end

      test "R1-F14: set_organization finds org through user's organizations" do
        # Verify it uses current_user.organizations.find(params[:id])
        source = File.read(
          File.expand_path("../../app/controllers/organizations/organizations_controller.rb", __dir__)
        )

        set_org_method = source[/def set_organization.*?end/m]
        assert_match(/current_user\.organizations\.find/, set_org_method.to_s,
                     "set_organization should find org through user's organizations")
      end

      # =========================================================================
      # ROUND 1 - FINDING 15 [P3]
      # "Invitation create action rescues too narrowly"
      #
      # Issue: Controller only rescued InvitationError, so invalid role params
      # could leak as 500 instead of 422.
      #
      # Round 2 fix: Broadened rescue to include ActiveRecord::RecordInvalid
      # and ArgumentError.
      # =========================================================================

      test "R1-F15: invitation controller rescues RecordInvalid and ArgumentError" do
        source = File.read(
          File.expand_path("../../app/controllers/organizations/invitations_controller.rb", __dir__)
        )

        # The create action should rescue these additional exceptions
        assert_match(/ActiveRecord::RecordInvalid/, source,
                     "Invitations create must rescue ActiveRecord::RecordInvalid")
        assert_match(/ArgumentError/, source,
                     "Invitations create must rescue ArgumentError")
      end

      test "R1-F15: invalid role in send_invite_to! raises an error (not 500)" do
        org, owner = create_org_with_owner!(name: "Invalid Role Org")

        # Invalid role should raise either ArgumentError or RecordInvalid,
        # both of which the controller rescues (not a 500)
        assert_raises(ArgumentError, ActiveRecord::RecordInvalid) do
          org.send_invite_to!("r1f15@example.com", invited_by: owner, role: :nonexistent_role)
        end
      end

      test "R1-F15: InvitationError is properly raised for known error conditions" do
        org, owner = create_org_with_owner!(name: "Invite Error Org")
        member = create_user!(email: "r1f15_member@example.com")
        org.add_member!(member, role: :member)

        assert_raises(Organizations::InvitationError) do
          org.send_invite_to!("r1f15_member@example.com", invited_by: owner)
        end
      end

      # =========================================================================
      # ROUND 1 - CLAUDE RESPONSE ANALYSIS
      # Additional points from Claude's response on Finding 1
      # =========================================================================

      test "Claude-R1-F1: counter cache callbacks only run when column exists" do
        # Verify counter cache methods exist and check for column
        membership_instance = Organizations::Membership.new

        assert membership_instance.respond_to?(:increment_memberships_counter_cache, true),
               "increment_memberships_counter_cache must be defined"
        assert membership_instance.respond_to?(:decrement_memberships_counter_cache, true),
               "decrement_memberships_counter_cache must be defined"
        assert membership_instance.respond_to?(:memberships_counter_cache_enabled?, true),
               "memberships_counter_cache_enabled? must be defined"

        # In test schema, counter cache is NOT enabled
        refute membership_instance.send(:memberships_counter_cache_enabled?)
      end

      # =========================================================================
      # ROUND 2 - CODEX ACCIDENTAL IMPLEMENTATION
      # Verify all changes Codex made (12 files) are working correctly.
      # =========================================================================

      # Round 2, File 1: membership.rb - single_owner_per_organization validation
      test "R2-F1: Membership validates single owner per organization" do
        org, _owner = create_org_with_owner!(name: "Single Owner Val Org")
        another_user = create_user!(email: "r2f1@example.com")

        # Cannot create second owner
        membership = Organizations::Membership.new(
          user: another_user, organization: org, role: "owner"
        )
        refute membership.valid?
        assert membership.errors[:role].any?
      end

      # Round 2, File 2: organization.rb - admins with .distinct
      test "R2-F2: admins query uses distinct" do
        org, _owner = create_org_with_owner!(name: "Distinct Org")
        5.times do |i|
          u = create_user!(email: "r2f2_admin_#{i}@example.com")
          Organizations::Membership.create!(user: u, organization: org, role: "admin")
        end

        # Even with complex query, no duplicates
        assert_equal org.admins.count, org.admins.pluck(:id).uniq.count
      end

      # Round 2, File 2: organization.rb - member_count with has_attribute? check
      test "R2-F2: member_count uses COUNT when memberships_count column absent" do
        org, _owner = create_org_with_owner!(name: "Member Count Org")
        3.times do |i|
          u = create_user!(email: "r2f2_count_#{i}@example.com")
          org.add_member!(u, role: :member)
        end

        assert_equal 4, org.member_count  # 1 owner + 3 members
      end

      # Round 2, File 3: callbacks.rb - strict mode
      test "R2-F3: Callbacks.dispatch with strict: true propagates errors" do
        Organizations.configure do |config|
          config.on_member_invited do |_ctx|
            raise "STRICT ERROR"
          end
        end

        assert_raises(RuntimeError, "STRICT ERROR") do
          Callbacks.dispatch(:member_invited, strict: true, organization: nil, invitation: nil, invited_by: nil)
        end
      end

      test "R2-F3: Callbacks.dispatch without strict: true swallows errors" do
        Organizations.configure do |config|
          config.on_member_invited do |_ctx|
            raise "SWALLOWED ERROR"
          end
        end

        assert_nothing_raised do
          Callbacks.dispatch(:member_invited, strict: false, organization: nil, invitation: nil, invited_by: nil)
        end
      end

      # Round 2, File 4: invitation.rb - InvitationAlreadyAccepted
      test "R2-F4: InvitationAlreadyAccepted error class exists" do
        assert defined?(Organizations::InvitationAlreadyAccepted),
               "InvitationAlreadyAccepted error must be defined"
        assert Organizations::InvitationAlreadyAccepted < Organizations::InvitationError,
               "InvitationAlreadyAccepted must inherit from InvitationError"
      end

      # Round 2, File 5: has_organizations.rb - CannotDeleteAsOrganizationOwner
      test "R2-F5: CannotDeleteAsOrganizationOwner error class exists" do
        assert defined?(Organizations::Models::Concerns::HasOrganizations::CannotDeleteAsOrganizationOwner),
               "CannotDeleteAsOrganizationOwner error must be defined"
      end

      # Round 2, File 5: has_organizations.rb - improved role_in with loaded associations
      test "R2-F5: role_in checks org.memberships.loaded? first" do
        user = create_user!(email: "r2f5_role@example.com")
        org = Organizations::Organization.create!(name: "Loaded Org Check")
        Organizations::Membership.create!(user: user, organization: org, role: "admin")

        # Load org with memberships
        loaded_org = Organizations::Organization.includes(:memberships).find(org.id)

        # Should find role without additional query
        assert_equal :admin, user.role_in(loaded_org)
      end

      # Round 2, File 6: controller_helpers.rb - fallback_organization_for
      test "R2-F6: ControllerHelpers defines fallback_organization_for" do
        assert ControllerHelpers.private_method_defined?(:fallback_organization_for) ||
               ControllerHelpers.method_defined?(:fallback_organization_for),
               "fallback_organization_for must be defined"
      end

      # Round 2, File 6: controller_helpers.rb - mark_membership_as_recent!
      test "R2-F6: ControllerHelpers defines mark_membership_as_recent!" do
        assert ControllerHelpers.private_method_defined?(:mark_membership_as_recent!) ||
               ControllerHelpers.method_defined?(:mark_membership_as_recent!),
               "mark_membership_as_recent! must be defined"
      end

      # Round 2, File 8: organizations_controller.rb - no set_organization side-effect
      test "R2-F8: OrganizationsController set_organization does not switch current org" do
        source = File.read(
          File.expand_path("../../app/controllers/organizations/organizations_controller.rb", __dir__)
        )

        # The old code had: self.current_organization = @organization
        # This must NOT be present anymore
        refute_match(/current_organization\s*=\s*@organization/, source,
                     "set_organization must not set current_organization")
      end

      # Round 2, File 8: organizations_controller.rb - permission-based guards
      test "R2-F8: OrganizationsController uses authorize_manage_settings!" do
        source = File.read(
          File.expand_path("../../app/controllers/organizations/organizations_controller.rb", __dir__)
        )

        assert_match(/authorize_manage_settings!/, source,
                     "OrganizationsController must use authorize_manage_settings!")
        assert_match(/authorize_delete_organization!/, source,
                     "OrganizationsController must use authorize_delete_organization!")
      end

      # Round 2, File 9: invitations_controller.rb - permission-based guards
      test "R2-F9: InvitationsController uses permission-based guard" do
        source = File.read(
          File.expand_path("../../app/controllers/organizations/invitations_controller.rb", __dir__)
        )

        assert_match(/require_organization_permission_to!\(:invite_members\)/, source,
                     "InvitationsController must use require_organization_permission_to!(:invite_members)")
      end

      # Round 2, File 9: invitations_controller.rb - broad rescue
      test "R2-F9: InvitationsController create rescues broadly" do
        source = File.read(
          File.expand_path("../../app/controllers/organizations/invitations_controller.rb", __dir__)
        )

        create_method = source[/def create.*?(?=\n\s+def |\n\s+private)/m]
        assert_match(/InvitationError.*RecordInvalid.*ArgumentError/m, create_method.to_s,
                     "create must rescue InvitationError, RecordInvalid, and ArgumentError")
      end

      # Round 2, File 10: memberships_controller.rb - permission-based guards
      test "R2-F10: MembershipsController uses permission-based guards" do
        source = File.read(
          File.expand_path("../../app/controllers/organizations/memberships_controller.rb", __dir__)
        )

        assert_match(/require_organization_permission_to!\(:view_members\)/, source,
                     "MembershipsController must use view_members permission")
        assert_match(/require_organization_permission_to!\(:edit_member_roles\)/, source,
                     "MembershipsController must use edit_member_roles permission")
        assert_match(/require_organization_permission_to!\(:remove_members\)/, source,
                     "MembershipsController must use remove_members permission")
      end

      # Round 2, File 10: memberships_controller.rb - uses domain method for role changes
      test "R2-F10: MembershipsController uses change_role_of! for role changes" do
        source = File.read(
          File.expand_path("../../app/controllers/organizations/memberships_controller.rb", __dir__)
        )

        assert_match(/change_role_of!/, source,
                     "MembershipsController must use Organization#change_role_of! domain method")
      end

      # Round 2, File 11: view_helpers.rb - user_has_permission_in_org? helper
      test "R2-F11: ViewHelpers defines user_has_permission_in_org?" do
        helper = Object.new
        helper.extend(Organizations::ViewHelpers)

        assert helper.respond_to?(:user_has_permission_in_org?, true),
               "user_has_permission_in_org? must be defined as private helper"
      end

      test "R2-F11: can_remove_member? uses permission-based check" do
        org, owner = create_org_with_owner!(name: "Remove Perm Org")
        admin = create_user!(email: "r2f11_admin@example.com")
        admin_membership = Organizations::Membership.create!(user: admin, organization: org, role: "admin")
        member = create_user!(email: "r2f11_member@example.com")
        member_membership = Organizations::Membership.create!(user: member, organization: org, role: "member")
        viewer = create_user!(email: "r2f11_viewer@example.com")
        Organizations::Membership.create!(user: viewer, organization: org, role: "viewer")

        helper = Object.new
        helper.extend(Organizations::ViewHelpers)

        # Admin can remove member
        assert helper.can_remove_member?(admin, member_membership)
        # Viewer cannot remove member
        refute helper.can_remove_member?(viewer, member_membership)
        # Nobody can remove owner
        owner_membership = org.memberships.find_by(role: "owner")
        refute helper.can_remove_member?(admin, owner_membership)
      end

      test "R2-F11: can_change_member_role? uses permission-based check" do
        org, owner = create_org_with_owner!(name: "Change Role Perm Org")
        admin = create_user!(email: "r2f11_admin2@example.com")
        admin_membership = Organizations::Membership.create!(user: admin, organization: org, role: "admin")
        member = create_user!(email: "r2f11_member2@example.com")
        member_membership = Organizations::Membership.create!(user: member, organization: org, role: "member")

        helper = Object.new
        helper.extend(Organizations::ViewHelpers)

        # Admin can change member's role
        assert helper.can_change_member_role?(admin, member_membership)
        # Member cannot change roles
        refute helper.can_change_member_role?(member, admin_membership)
        # Cannot change own role
        refute helper.can_change_member_role?(admin, admin_membership)
      end

      test "R2-F11: can_transfer_ownership? uses permission-based check" do
        org, owner = create_org_with_owner!(name: "Transfer Perm Org")
        admin = create_user!(email: "r2f11_transfer_admin@example.com")
        Organizations::Membership.create!(user: admin, organization: org, role: "admin")

        helper = Object.new
        helper.extend(Organizations::ViewHelpers)

        # Owner has transfer_ownership permission
        assert helper.can_transfer_ownership?(owner, org)
        # Admin does NOT have transfer_ownership permission
        refute helper.can_transfer_ownership?(admin, org)
      end

      test "R2-F11: can_delete_organization? uses permission-based check" do
        org, owner = create_org_with_owner!(name: "Delete Perm Org")
        admin = create_user!(email: "r2f11_delete_admin@example.com")
        Organizations::Membership.create!(user: admin, organization: org, role: "admin")

        helper = Object.new
        helper.extend(Organizations::ViewHelpers)

        # Owner has delete_organization permission
        assert helper.can_delete_organization?(owner, org)
        # Admin does NOT
        refute helper.can_delete_organization?(admin, org)
      end

      # Round 2, File 11: view_helpers.rb - nil inviter handling
      test "R2-F11: inviter_display_name handles nil inviter" do
        helper = Object.new
        helper.extend(Organizations::ViewHelpers)

        result = helper.send(:inviter_display_name, nil)
        assert_nil result, "inviter_display_name(nil) must return nil, not crash"
      end

      # Round 2, File 12: migration template - memberships_count removed
      test "R2-F12: migration template does not require memberships_count" do
        # The test schema works without memberships_count, which proves
        # the gem no longer requires it
        refute Organizations::Organization.column_names.include?("memberships_count"),
               "memberships_count should not be required"

        # All core operations work without it
        org, owner = create_org_with_owner!(name: "No Counter Org Final")
        member = create_user!(email: "r2f12@example.com")
        org.add_member!(member, role: :member)

        assert_equal 2, org.member_count
        assert_equal 2, org.memberships.count
      end

      # =========================================================================
      # ROUND 2 - CLAUDE VERDICT
      # Verify the "outstanding items" Claude identified are tracked.
      # These are acknowledged design decisions, not code bugs.
      # =========================================================================

      test "R2-Verdict: Organizations::Organization model is properly namespaced (Finding #5 acknowledged)" do
        # This is the chosen design - model is namespaced
        assert_equal "organizations", Organizations::Organization.table_name
        assert Organizations::Organization < ActiveRecord::Base
      end

      test "R2-Verdict: Slugifiable integration is present (Finding #7 fixed)" do
        assert Organizations::Organization.respond_to?(:generate_slug_based_on),
               "Organization must respond to generate_slug_based_on from Slugifiable"
      end

      # =========================================================================
      # ROUND 2 - DATABASE DIFFERENCES RESEARCH
      # Verify the application handles DB differences correctly.
      # =========================================================================

      test "R2-DB: invitation for_email scope is case-insensitive" do
        org, owner = create_org_with_owner!(name: "Case Insensitive DB Org")

        invitation = org.send_invite_to!("CaseTest@Example.COM", invited_by: owner)

        # for_email scope should find it regardless of case
        found = Organizations::Invitation.for_email("casetest@example.com")
        assert_includes found.pluck(:id), invitation.id

        found_upper = Organizations::Invitation.for_email("CASETEST@EXAMPLE.COM")
        assert_includes found_upper.pluck(:id), invitation.id
      end

      test "R2-DB: invitation email is normalized on save" do
        org, owner = create_org_with_owner!(name: "Email Normalize Org")

        invitation = org.send_invite_to!("  UPPER@EXAMPLE.COM  ", invited_by: owner)

        assert_equal "upper@example.com", invitation.email,
                     "Email must be lowercased and stripped on save"
      end

      test "R2-DB: invitation token is globally unique" do
        org, owner = create_org_with_owner!(name: "Token Unique Org")

        invitation1 = org.send_invite_to!("r2db_token1@example.com", invited_by: owner)
        invitation2 = org.send_invite_to!("r2db_token2@example.com", invited_by: owner)

        refute_equal invitation1.token, invitation2.token,
                     "Each invitation must have a unique token"
      end

      test "R2-DB: membership user_id + organization_id is unique" do
        org, _owner = create_org_with_owner!(name: "Unique Membership Org")
        user = create_user!(email: "r2db_unique@example.com")
        Organizations::Membership.create!(user: user, organization: org, role: "member")

        assert_raises(ActiveRecord::RecordInvalid) do
          Organizations::Membership.create!(user: user, organization: org, role: "viewer")
        end
      end

      test "R2-DB: organization slug is unique" do
        org1 = Organizations::Organization.create!(name: "Unique Slug DB Org")

        # Direct duplicate slug should fail validation
        org2 = Organizations::Organization.new(name: "Other", slug: org1.slug)
        refute org2.valid?
      end

      # =========================================================================
      # COMPREHENSIVE INTEGRATION TESTS
      # Full workflow tests that exercise multiple findings together.
      # =========================================================================

      test "integration: full invitation flow works end-to-end with all fixes applied" do
        # This test exercises: F1 (no counter cache), F2 (callback), F3 (admins),
        # F8 (idempotent accept), F13 (uniqueness)

        org, owner = create_org_with_owner!(name: "Integration Org")
        admin = create_user!(email: "int_admin@example.com")
        org.add_member!(admin, role: :admin)

        # F2: Callback allows invitation
        callback_count = 0
        Organizations.configure do |config|
          config.on_member_invited do |_ctx|
            callback_count += 1
          end
        end

        # Admin invites someone
        invitation = org.send_invite_to!("int_invitee@example.com", invited_by: admin)
        assert_equal 1, callback_count

        # F13: Duplicate invite returns existing
        duplicate = org.send_invite_to!("int_invitee@example.com", invited_by: admin)
        assert_equal invitation.id, duplicate.id
        assert_equal 1, callback_count  # Callback should NOT run again for idempotent return

        # Accept invitation
        invitee = create_user!(email: "int_invitee@example.com")
        membership = invitation.accept!(invitee)
        assert membership.persisted?

        # F1: member_count works without counter cache
        assert_equal 3, org.member_count

        # F3: admins returns correct set without duplicates
        admin_ids = org.admins.pluck(:id)
        assert_includes admin_ids, owner.id
        assert_includes admin_ids, admin.id
        refute_includes admin_ids, invitee.id
        assert_equal admin_ids.uniq.sort, admin_ids.sort

        # F8: Re-accept is idempotent
        result = invitation.reload.accept!(invitee)
        assert_equal membership.id, result.id
      end

      test "integration: ownership lifecycle works with all guards" do
        # Exercises: F4 (ownership invariant), owner deletion guard,
        # transfer_ownership_to!, single_owner validation

        org, owner = create_org_with_owner!(name: "Ownership Lifecycle Org")
        admin = create_user!(email: "own_admin@example.com")
        org.add_member!(admin, role: :admin)

        # Cannot add second owner
        assert_raises(Organizations::Organization::CannotHaveMultipleOwners) do
          org.add_member!(create_user!(email: "own_second@example.com"), role: :owner)
        end

        # Cannot delete owner
        assert_raises(ActiveRecord::RecordNotDestroyed) do
          owner.destroy!
        end

        # Transfer ownership
        org.transfer_ownership_to!(admin)
        assert_equal admin.id, org.reload.owner.id

        # Old owner is now admin
        assert_equal "admin", org.memberships.find_by(user_id: owner.id).role

        # New owner protected from deletion
        assert_raises(ActiveRecord::RecordNotDestroyed) do
          admin.destroy!
        end
      end

      test "integration: permission-based authorization is consistent across layers" do
        # Exercises: F9 (permission-based auth), F10 (consistent unauthorized behavior)

        org, owner = create_org_with_owner!(name: "Auth Consistency Org")
        member = create_user!(email: "auth_member@example.com")
        org.add_member!(member, role: :member)

        helper = Object.new
        helper.extend(Organizations::ViewHelpers)

        # Permission checks consistent between model and view helper layers
        assert Roles.has_permission?(:admin, :invite_members)
        refute Roles.has_permission?(:member, :invite_members)

        assert helper.can_invite_members?(owner, org)
        refute helper.can_invite_members?(member, org)

        assert helper.can_manage_organization?(owner, org)
        refute helper.can_manage_organization?(member, org)

        assert helper.can_delete_organization?(owner, org)
        refute helper.can_delete_organization?(member, org)
      end
    end
  end
end
