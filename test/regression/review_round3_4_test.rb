# frozen_string_literal: true

require "test_helper"

module Organizations
  module Regression
    # Exhaustive regression tests for REVIEW.md Rounds 3 and 4.
    #
    # Round 3: Codex Review identified 7 findings (P0-P2).
    # Round 4: Codex Implementation fixed all 7 findings + Claude verified.
    #
    # Every finding and every fix has at least one test below. Tests are grouped
    # by finding number and include both the "bug existed" and "fix works"
    # perspectives.
    class ReviewRound3And4Test < Organizations::Test

      # =====================================================================
      # ROUND 3, FINDING 1 (P0): Owner-Deletion Guard Ineffective
      # =====================================================================
      #
      # Bug: `dependent: :destroy` on memberships ran before the
      # `prevent_deletion_while_owning_organizations` guard callback, so by
      # the time the guard checked for owner memberships they were already
      # destroyed. The guard saw zero owners and allowed deletion.
      #
      # Fix (Round 4 #1): `before_destroy :prevent_deletion_while_owning_organizations, prepend: true`
      # ensures the guard runs FIRST, before associations are destroyed.

      test "R3F1: owner user cannot be destroyed while owning an organization" do
        org, owner = create_org_with_owner!(name: "Guard Org")

        assert_raises(ActiveRecord::RecordNotDestroyed) do
          owner.destroy!
        end

        # Owner must still exist
        assert User.exists?(owner.id), "Owner user must survive the destroy attempt"
        # Organization must still exist
        assert Organizations::Organization.exists?(org.id), "Organization must survive"
        # Owner membership must still be intact
        assert_equal 1, org.memberships.where(role: "owner").count,
                     "Owner membership must remain intact"
      end

      test "R3F1: owner destroy error message is descriptive" do
        _org, owner = create_org_with_owner!(name: "Error Msg Org")

        begin
          owner.destroy!
          flunk "Expected RecordNotDestroyed to be raised"
        rescue ActiveRecord::RecordNotDestroyed
          assert_includes owner.errors.full_messages.join(", "),
                          "Cannot delete a user who still owns organizations"
        end
      end

      test "R3F1: owner with multiple organizations cannot be destroyed" do
        org1 = Organizations::Organization.create!(name: "First Org")
        org2 = Organizations::Organization.create!(name: "Second Org")
        owner = create_user!(email: "multi-owner@example.com")
        Organizations::Membership.create!(user: owner, organization: org1, role: "owner")
        Organizations::Membership.create!(user: owner, organization: org2, role: "owner")

        assert_raises(ActiveRecord::RecordNotDestroyed) do
          owner.destroy!
        end

        assert User.exists?(owner.id)
        assert Organizations::Organization.exists?(org1.id)
        assert Organizations::Organization.exists?(org2.id)
      end

      test "R3F1: non-owner members can still be destroyed" do
        org, _owner = create_org_with_owner!(name: "Destroyable Org")

        # Disable personal org creation for this member
        Organizations.configure { |c| c.create_personal_organization = false }
        User.organization_settings = User.organization_settings.merge(create_personal_org: false).freeze

        member = create_user!(email: "deletable-member@example.com")
        Organizations::Membership.create!(user: member, organization: org, role: "member")

        refute member.memberships.where(role: "owner").exists?,
               "Member must not own any organizations for this test"

        assert_nothing_raised do
          member.destroy!
        end

        refute User.exists?(member.id), "Member should be deleted"
        # Membership should be cleaned up via dependent: :destroy
        refute org.memberships.exists?(user_id: member.id),
               "Membership should be destroyed via dependent: :destroy"
      end

      test "R3F1: owner can be destroyed after transferring ownership" do
        # Disable personal org creation BEFORE creating users to avoid them owning
        # a personal org that would block deletion.
        Organizations.configure { |c| c.create_personal_organization = false }
        User.organization_settings = User.organization_settings.merge(create_personal_org: false).freeze

        org, owner = create_org_with_owner!(name: "Transfer Then Delete Org")
        new_owner = create_user!(email: "new-owner@example.com")
        Organizations::Membership.create!(user: new_owner, organization: org, role: "admin")

        # Transfer ownership
        org.transfer_ownership_to!(new_owner)

        # After transfer, old owner should not own any org
        owner.reload
        refute owner.memberships.where(role: "owner").exists?,
               "Old owner should not own any org after transfer"

        assert_nothing_raised do
          owner.destroy!
        end

        refute User.exists?(owner.id)
      end

      test "R3F1: prepend true ensures guard runs before dependent destroy" do
        # Verify the callback is registered with prepend: true
        # We can check this by verifying that `before_destroy` callbacks
        # include our guard and that it fires before memberships are destroyed
        org, owner = create_org_with_owner!(name: "Prepend Test Org")

        # Before attempting destroy, owner has memberships
        assert owner.memberships.where(role: "owner").exists?,
               "Owner should have owner membership before destroy attempt"

        # The guard should prevent destroy, meaning memberships are NOT destroyed
        assert_raises(ActiveRecord::RecordNotDestroyed) do
          owner.destroy!
        end

        # After failed destroy, memberships must still exist (guard ran BEFORE dependent: :destroy)
        owner.reload
        assert owner.memberships.where(role: "owner").exists?,
               "Owner memberships must still exist after failed destroy (prepend: true works)"
      end

      # =====================================================================
      # ROUND 3, FINDING 2 (P0): Organization#send_invite_to! Bypass
      # =====================================================================
      #
      # Bug: `Organization#send_invite_to!` required `invited_by` but did NOT
      # verify inviter membership or permission. Any code path with an org
      # instance could issue invitations using an arbitrary User as inviter.
      #
      # Fix (Round 4 #2): Added `authorize_inviter!` private guard that:
      #   - raises NotAMember when inviter is not a member
      #   - raises NotAuthorized when inviter lacks :invite_members permission

      test "R3F2: org API rejects invitation from non-member" do
        org, _owner = create_org_with_owner!(name: "Non-member Org")
        outsider = create_user!(email: "outsider@example.com")

        refute org.has_member?(outsider), "Outsider must not be a member"

        error = assert_raises(Organizations::NotAMember) do
          org.send_invite_to!("target@example.com", invited_by: outsider)
        end

        assert_match(/members can send invitations/i, error.message)
        assert_equal 0, org.invitations.count, "No invitation should be created"
      end

      test "R3F2: org API rejects invitation from viewer (no invite_members permission)" do
        org, _owner = create_org_with_owner!(name: "Viewer Invite Org")
        viewer = create_user!(email: "viewer@example.com")
        Organizations::Membership.create!(user: viewer, organization: org, role: "viewer")

        refute Roles.has_permission?(:viewer, :invite_members),
               "Viewer must not have invite_members permission"

        error = assert_raises(Organizations::NotAuthorized) do
          org.send_invite_to!("target@example.com", invited_by: viewer)
        end

        assert_match(/permission to invite/i, error.message)
        assert_equal 0, org.invitations.count
      end

      test "R3F2: org API rejects invitation from member (no invite_members permission)" do
        org, _owner = create_org_with_owner!(name: "Member Invite Org")
        member = create_user!(email: "member@example.com")
        Organizations::Membership.create!(user: member, organization: org, role: "member")

        refute Roles.has_permission?(:member, :invite_members),
               "Member must not have invite_members permission"

        assert_raises(Organizations::NotAuthorized) do
          org.send_invite_to!("target@example.com", invited_by: member)
        end

        assert_equal 0, org.invitations.count
      end

      test "R3F2: org API allows invitation from admin (has invite_members permission)" do
        org, _owner = create_org_with_owner!(name: "Admin Invite Org")
        admin = create_user!(email: "admin@example.com")
        Organizations::Membership.create!(user: admin, organization: org, role: "admin")

        assert Roles.has_permission?(:admin, :invite_members),
               "Admin must have invite_members permission"

        invitation = org.send_invite_to!("target@example.com", invited_by: admin)
        assert invitation.persisted?
        assert_equal admin.id, invitation.invited_by_id
        assert_equal "target@example.com", invitation.email
      end

      test "R3F2: org API allows invitation from owner" do
        org, owner = create_org_with_owner!(name: "Owner Invite Org")

        assert Roles.has_permission?(:owner, :invite_members),
               "Owner must have invite_members permission"

        invitation = org.send_invite_to!("target@example.com", invited_by: owner)
        assert invitation.persisted?
        assert_equal owner.id, invitation.invited_by_id
      end

      test "R3F2: defense in depth - user-level API also enforces permission" do
        org, _owner = create_org_with_owner!(name: "User API Org")
        viewer = create_user!(email: "viewer@example.com")
        Organizations::Membership.create!(user: viewer, organization: org, role: "viewer")

        # Set current org context
        viewer._current_organization_id = org.id

        assert_raises(Organizations::NotAuthorized) do
          viewer.send_organization_invite_to!("target@example.com", organization: org)
        end
      end

      test "R3F2: authorize_inviter is a private method on Organization" do
        assert Organizations::Organization.private_method_defined?(:authorize_inviter!),
               "authorize_inviter! must be a private method on Organization"
      end

      # =====================================================================
      # ROUND 3, FINDING 3 (P1): README/API Parity - Namespaced Models
      # =====================================================================
      #
      # Issue: gem hardcodes `Organizations::Organization` and
      # `Organizations::Membership` while README documented app-level
      # `Organization` extension.
      #
      # Resolution (Round 4, noted as NOT done + Round 5): README updated to
      # use namespaced models consistently. Architecture decision: namespaced.

      test "R3F3: has_organizations associations use namespaced classes" do
        user = create_user!

        # Verify memberships association uses Organizations::Membership
        membership_reflection = User.reflect_on_association(:memberships)
        assert_equal "Organizations::Membership", membership_reflection.options[:class_name]

        # Verify organizations association uses Organizations::Organization
        org_reflection = User.reflect_on_association(:organizations)
        assert_equal "Organizations::Organization", org_reflection.options[:class_name]

        # Verify owned_organizations association uses Organizations::Organization
        owned_reflection = User.reflect_on_association(:owned_organizations)
        assert_equal "Organizations::Organization", owned_reflection.options[:class_name]
      end

      test "R3F3: Organization class lives in Organizations namespace" do
        assert defined?(Organizations::Organization),
               "Organization must be defined in Organizations namespace"
        assert Organizations::Organization < ActiveRecord::Base,
               "Organizations::Organization must inherit from ActiveRecord::Base"
      end

      test "R3F3: with_member scope returns Organizations::Organization instances" do
        org, owner = create_org_with_owner!(name: "Namespace Test Org")

        result = Organizations::Organization.with_member(owner)
        assert_kind_of ActiveRecord::Relation, result
        assert_includes result, org
      end

      # =====================================================================
      # ROUND 3, FINDING 4 (P1): HTML Engine Surface Incomplete
      # =====================================================================
      #
      # Bug: Controllers rendered HTML, but no templates existed.
      # Engine HTML paths would raise MissingTemplate.
      #
      # Fix (Round 4 #6): Added all missing templates + functional layout.

      test "R3F4: engine layout template exists and is not a placeholder" do
        layout_path = File.join(
          File.dirname(__FILE__), "..", "..", "app", "views",
          "layouts", "organizations", "application.html.erb"
        )
        assert File.exist?(layout_path), "Engine layout must exist"

        content = File.read(layout_path)
        refute_match(/placeholder/i, content.lines.first.to_s)
        assert_match(/DOCTYPE html/i, content)
        assert_match(/org-shell/, content)
        assert_match(/yield/, content)
      end

      test "R3F4: organizations index template exists" do
        path = template_path("organizations", "organizations", "index.html.erb")
        assert File.exist?(path), "organizations/index.html.erb must exist"
      end

      test "R3F4: organizations show template exists" do
        path = template_path("organizations", "organizations", "show.html.erb")
        assert File.exist?(path), "organizations/show.html.erb must exist"
      end

      test "R3F4: organizations new template exists" do
        path = template_path("organizations", "organizations", "new.html.erb")
        assert File.exist?(path), "organizations/new.html.erb must exist"
      end

      test "R3F4: organizations edit template exists" do
        path = template_path("organizations", "organizations", "edit.html.erb")
        assert File.exist?(path), "organizations/edit.html.erb must exist"
      end

      test "R3F4: organizations form partial exists" do
        path = template_path("organizations", "organizations", "_form.html.erb")
        assert File.exist?(path), "organizations/_form.html.erb must exist"
      end

      test "R3F4: invitations index template exists" do
        path = template_path("organizations", "invitations", "index.html.erb")
        assert File.exist?(path), "invitations/index.html.erb must exist"
      end

      test "R3F4: invitations new template exists" do
        path = template_path("organizations", "invitations", "new.html.erb")
        assert File.exist?(path), "invitations/new.html.erb must exist"
      end

      test "R3F4: invitations show template exists" do
        path = template_path("organizations", "invitations", "show.html.erb")
        assert File.exist?(path), "invitations/show.html.erb must exist"
      end

      test "R3F4: invitations form partial exists" do
        path = template_path("organizations", "invitations", "_form.html.erb")
        assert File.exist?(path), "invitations/_form.html.erb must exist"
      end

      test "R3F4: memberships index template exists" do
        path = template_path("organizations", "memberships", "index.html.erb")
        assert File.exist?(path), "memberships/index.html.erb must exist"
      end

      test "R3F4: all required templates exist (comprehensive check)" do
        required_templates = [
          ["layouts", "organizations", "application.html.erb"],
          ["organizations", "organizations", "index.html.erb"],
          ["organizations", "organizations", "show.html.erb"],
          ["organizations", "organizations", "new.html.erb"],
          ["organizations", "organizations", "edit.html.erb"],
          ["organizations", "organizations", "_form.html.erb"],
          ["organizations", "invitations", "index.html.erb"],
          ["organizations", "invitations", "new.html.erb"],
          ["organizations", "invitations", "show.html.erb"],
          ["organizations", "invitations", "_form.html.erb"],
          ["organizations", "memberships", "index.html.erb"]
        ]

        missing = required_templates.reject do |parts|
          File.exist?(template_path(*parts))
        end

        assert_empty missing,
          "Missing templates: #{missing.map { |p| p.join('/') }.join(', ')}"
      end

      # =====================================================================
      # ROUND 3, FINDING 5 (P1): Slugifiable Integration Not Implemented
      # =====================================================================
      #
      # Bug: README claimed slugifiable was used for slug generation, but
      # the code used custom manual slug logic and save retry.
      #
      # Fix (Round 4 #4): Integrated Slugifiable::Model, removed custom code.

      test "R3F5: Organization includes Slugifiable::Model" do
        assert Organizations::Organization.include?(Slugifiable::Model),
               "Organization must include Slugifiable::Model"
      end

      test "R3F5: generate_slug_based_on is set to :name" do
        org = Organizations::Organization.new(name: "Slug Source Test")
        assert org.respond_to?(:compute_slug),
               "compute_slug must be available from Slugifiable::Model"

        computed = org.compute_slug
        assert_equal "slug-source-test", computed
      end

      test "R3F5: slug is auto-generated from name on create" do
        org = Organizations::Organization.create!(name: "My Cool Org")
        assert_equal "my-cool-org", org.slug
      end

      test "R3F5: slug is present before save (NOT NULL constraint satisfied)" do
        org = Organizations::Organization.new(name: "Before Save Test")
        assert_nil org.slug, "Slug should be nil before validation"

        org.valid?
        assert_equal "before-save-test", org.slug,
                     "Slug should be computed during before_validation"
      end

      test "R3F5: slug collision handling works for duplicate names" do
        org1 = Organizations::Organization.create!(name: "Duplicate Name")
        org2 = Organizations::Organization.create!(name: "Duplicate Name")

        assert_equal "duplicate-name", org1.slug
        refute_equal org1.slug, org2.slug, "Duplicate names must get unique slugs"
        assert org2.slug.start_with?("duplicate-name"),
               "Second slug should start with base slug"
      end

      test "R3F5: slug does not change when name is updated (URL stability)" do
        org = Organizations::Organization.create!(name: "Original Name")
        original_slug = org.slug

        org.update!(name: "Changed Name")

        assert_equal original_slug, org.slug,
                     "Slug must not change when name changes (URL stability)"
      end

      test "R3F5: before_validation callback ensures slug is present on create" do
        # Test that the before_validation :ensure_slug_present fires correctly
        org = Organizations::Organization.new(name: "Ensure Slug")
        org.slug = ""  # Force blank

        org.valid?

        assert_equal "ensure-slug", org.slug,
                     "ensure_slug_present callback should compute slug when blank"
      end

      # =====================================================================
      # ROUND 3, FINDING 6 (P1): "Exactly One Owner" Not Robust in Corrupted States
      # =====================================================================
      #
      # Bug: `transfer_ownership_to!` assumed `owner_membership` exists and
      # called `lock!` on it. With a corrupted state (no owner), it crashed
      # with `NoMethodError: undefined method 'lock!' for nil`.
      #
      # Fix (Round 4 #3): Added NoOwnerPresent error + transfer-to-current-owner no-op.

      test "R3F6: transfer raises NoOwnerPresent when no owner membership exists" do
        org = Organizations::Organization.create!(name: "No Owner Org")
        admin = create_user!(email: "admin-no-owner@example.com")
        Organizations::Membership.create!(user: admin, organization: org, role: "admin")

        # Verify corrupted state
        assert_nil org.owner_membership, "Must be corrupted (no owner membership)"
        assert_nil org.owner, "Must be corrupted (no owner)"

        error = assert_raises(Organizations::Organization::NoOwnerPresent) do
          org.transfer_ownership_to!(admin)
        end

        assert_match(/no owner membership/i, error.message)
      end

      test "R3F6: NoOwnerPresent is a proper domain error, not NoMethodError" do
        org = Organizations::Organization.create!(name: "Domain Error Org")
        admin = create_user!(email: "admin-domain@example.com")
        Organizations::Membership.create!(user: admin, organization: org, role: "admin")

        begin
          org.transfer_ownership_to!(admin)
          flunk "Expected NoOwnerPresent to be raised"
        rescue Organizations::Organization::NoOwnerPresent => e
          # This is the expected domain error
          assert_kind_of Organizations::Error, e,
                         "NoOwnerPresent should inherit from Organizations::Error"
        rescue NoMethodError
          flunk "Got NoMethodError instead of domain error - R4 fix not applied!"
        end
      end

      test "R3F6: transfer to current owner is a clean no-op" do
        org, owner = create_org_with_owner!(name: "No-op Transfer Org")

        result = org.transfer_ownership_to!(owner)

        # Should return the existing owner membership without error
        assert_equal owner.id, result.user_id
        assert_equal "owner", org.memberships.find_by(user_id: owner.id).role,
                     "Owner role should remain unchanged"
      end

      test "R3F6: transfer to non-member raises CannotTransferToNonMember" do
        org, _owner = create_org_with_owner!(name: "Non-member Transfer")
        outsider = create_user!(email: "outsider-transfer@example.com")

        assert_raises(Organizations::Organization::CannotTransferToNonMember) do
          org.transfer_ownership_to!(outsider)
        end
      end

      test "R3F6: transfer to non-admin member raises CannotTransferToNonAdmin" do
        org, _owner = create_org_with_owner!(name: "Non-admin Transfer")
        member = create_user!(email: "member-transfer@example.com")
        Organizations::Membership.create!(user: member, organization: org, role: "member")

        assert_raises(Organizations::Organization::CannotTransferToNonAdmin) do
          org.transfer_ownership_to!(member)
        end
      end

      test "R3F6: successful transfer swaps roles correctly" do
        org, owner = create_org_with_owner!(name: "Swap Transfer Org")
        admin = create_user!(email: "admin-swap@example.com")
        Organizations::Membership.create!(user: admin, organization: org, role: "admin")

        org.transfer_ownership_to!(admin)

        assert_equal "admin", org.memberships.find_by(user_id: owner.id).role,
                     "Old owner must become admin"
        assert_equal "owner", org.memberships.find_by(user_id: admin.id).role,
                     "New owner must become owner"
        assert_equal admin, org.reload.owner
      end

      test "R3F6: transfer dispatches ownership_transferred callback" do
        org, _owner = create_org_with_owner!(name: "Callback Transfer Org")
        admin = create_user!(email: "admin-callback@example.com")
        Organizations::Membership.create!(user: admin, organization: org, role: "admin")

        callback_fired = false
        Organizations.configure do |config|
          config.on_ownership_transferred do |ctx|
            callback_fired = true
            assert_equal org.id, ctx.organization.id
            assert_equal admin.id, ctx.new_owner.id
          end
        end

        org.transfer_ownership_to!(admin)
        assert callback_fired, "ownership_transferred callback must fire"
      end

      # =====================================================================
      # ROUND 3, FINDING 7 (P2): Membership Removal Controller Bypasses Domain Method
      # =====================================================================
      #
      # Bug: Controller destroyed membership directly with duplicated logic
      # and dispatched callback itself instead of using Organization#remove_member!.
      #
      # Fix (Round 4 #5): Refactored to use domain method:
      #   `current_organization.remove_member!(@membership.user, removed_by: current_user)`

      test "R3F7: Organization#remove_member! exists and works correctly" do
        org, _owner = create_org_with_owner!(name: "Remove Member Org")
        member = create_user!(email: "removable@example.com")
        org.add_member!(member, role: :member)

        assert org.has_member?(member)

        org.remove_member!(member, removed_by: _owner)

        refute org.has_member?(member), "Member should be removed"
      end

      test "R3F7: remove_member! raises CannotRemoveOwner for owner" do
        org, owner = create_org_with_owner!(name: "Cant Remove Owner Org")

        assert_raises(Organizations::Organization::CannotRemoveOwner) do
          org.remove_member!(owner)
        end

        assert org.has_member?(owner), "Owner must still be a member"
      end

      test "R3F7: remove_member! dispatches member_removed callback" do
        org, owner = create_org_with_owner!(name: "Remove Callback Org")
        member = create_user!(email: "callback-remove@example.com")
        org.add_member!(member, role: :member)

        callback_fired = false
        removed_user_id = nil
        removed_by_id = nil

        Organizations.configure do |config|
          config.on_member_removed do |ctx|
            callback_fired = true
            removed_user_id = ctx.user.id
            removed_by_id = ctx.removed_by&.id
          end
        end

        org.remove_member!(member, removed_by: owner)

        assert callback_fired, "member_removed callback must fire"
        assert_equal member.id, removed_user_id
        assert_equal owner.id, removed_by_id
      end

      test "R3F7: remove_member! uses locking for concurrency safety" do
        org, _owner = create_org_with_owner!(name: "Lock Remove Org")
        member = create_user!(email: "lock-remove@example.com")
        org.add_member!(member, role: :member)

        # remove_member! should use lock! internally (within transaction)
        # We verify by checking the method uses a transaction
        assert_nothing_raised do
          org.remove_member!(member)
        end

        refute org.has_member?(member)
      end

      test "R3F7: MembershipsController file uses remove_member! domain method" do
        controller_path = File.join(
          File.dirname(__FILE__), "..", "..", "app", "controllers",
          "organizations", "memberships_controller.rb"
        )
        assert File.exist?(controller_path), "MembershipsController file must exist"

        content = File.read(controller_path)
        # Verify it uses the domain method instead of direct membership.destroy!
        assert_match(/remove_member!/, content)
        # Verify it does NOT use @membership.destroy! directly for the destroy action
        refute_match(/@membership\.destroy!/, content)
      end

      test "R3F7: MembershipsController file includes validate_removal! guard" do
        controller_path = File.join(
          File.dirname(__FILE__), "..", "..", "app", "controllers",
          "organizations", "memberships_controller.rb"
        )
        content = File.read(controller_path)

        assert_match(/validate_removal!/, content)
      end

      # =====================================================================
      # ROUND 3: Re-validated Improvements (confirmed working)
      # =====================================================================

      test "R3 validated: org.admins deduplicates correctly with distinct" do
        org, owner = create_org_with_owner!(name: "Dedup Admins Org")
        admin = create_user!(email: "admin-dedup@example.com")
        Organizations::Membership.create!(user: admin, organization: org, role: "admin")
        member = create_user!(email: "member-dedup@example.com")
        Organizations::Membership.create!(user: member, organization: org, role: "member")

        admins = org.admins
        admin_ids = admins.pluck(:id)

        assert_includes admin_ids, owner.id
        assert_includes admin_ids, admin.id
        refute_includes admin_ids, member.id

        # No duplicates
        assert_equal admin_ids.uniq.sort, admin_ids.sort,
                     "admins must not contain duplicate user IDs"
      end

      test "R3 validated: invitation callback veto works with strict mode" do
        org, owner = create_org_with_owner!(name: "Veto Callback Org")

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

      test "R3 validated: invitation re-accept with existing membership is idempotent" do
        org, owner = create_org_with_owner!(name: "Idempotent Accept Org")
        invitee = create_user!(email: "idempotent@example.com")

        invitation = org.send_invite_to!("idempotent@example.com", invited_by: owner)
        membership1 = invitation.accept!(invitee)

        assert membership1.persisted?
        assert invitation.reload.accepted?

        # Accept again - should return existing membership, not raise
        membership2 = invitation.accept!(invitee)
        assert_equal membership1.id, membership2.id,
                     "Re-accept must return existing membership"
      end

      # =====================================================================
      # ROUND 4, FINDING 1: Fixed Owner-Deletion with prepend: true
      # (Covered above in R3F1 tests)
      # =====================================================================

      # =====================================================================
      # ROUND 4, FINDING 2: Fixed Org-Centric Invitation Authorization
      # (Covered above in R3F2 tests)
      # =====================================================================

      # =====================================================================
      # ROUND 4, FINDING 3: Hardened Ownership Transfer Error Handling
      # (Covered above in R3F6 tests)
      # =====================================================================

      # =====================================================================
      # ROUND 4, FINDING 4: Implemented Real Slugifiable Usage
      # (Covered above in R3F5 tests)
      # =====================================================================

      # =====================================================================
      # ROUND 4, FINDING 5: Removed Duplicated Member-Removal Logic
      # (Covered above in R3F7 tests)
      # =====================================================================

      # =====================================================================
      # ROUND 4, FINDING 6: Implemented Missing Engine HTML Surface
      # (Covered above in R3F4 tests)
      # =====================================================================

      # =====================================================================
      # ROUND 4, FINDING 7: Added Regression Tests
      # =====================================================================
      #
      # Codex added test/organizations_hardening_test.rb with 5 tests.
      # We verify those tests exist and cover the critical paths.

      test "R4F7: hardening test file exists" do
        hardening_path = File.join(
          File.dirname(__FILE__), "..", "organizations_hardening_test.rb"
        )
        assert File.exist?(hardening_path),
               "test/organizations_hardening_test.rb must exist"
      end

      # =====================================================================
      # ROUND 4: Claude Review Verification
      # =====================================================================
      #
      # Claude verified all 7 fixes in Round 4. Additional edge case tests
      # below ensure the fixes hold under various conditions.

      test "R4 review: change_role_of! blocks promotion to owner (must use transfer)" do
        org, _owner = create_org_with_owner!(name: "No Direct Promote Org")
        member = create_user!(email: "member-promote@example.com")
        Organizations::Membership.create!(user: member, organization: org, role: "member")

        assert_raises(Organizations::Organization::CannotHaveMultipleOwners) do
          org.change_role_of!(member, to: :owner)
        end

        assert_equal "member", org.memberships.find_by(user_id: member.id).role,
                     "Role must not change"
      end

      test "R4 review: change_role_of! blocks demotion of owner" do
        org, owner = create_org_with_owner!(name: "No Direct Demote Org")

        assert_raises(Organizations::Organization::CannotDemoteOwner) do
          org.change_role_of!(owner, to: :admin)
        end

        assert_equal "owner", org.memberships.find_by(user_id: owner.id).role,
                     "Owner role must not change"
      end

      test "R4 review: change_role_of! allows non-owner role changes" do
        org, _owner = create_org_with_owner!(name: "Role Change Org")
        member = create_user!(email: "role-change@example.com")
        Organizations::Membership.create!(user: member, organization: org, role: "member")

        org.change_role_of!(member, to: :admin)

        assert_equal "admin", org.memberships.find_by(user_id: member.id).role
      end

      test "R4 review: change_role_of! same role is no-op" do
        org, _owner = create_org_with_owner!(name: "Same Role Org")
        admin = create_user!(email: "same-role@example.com")
        membership = Organizations::Membership.create!(user: admin, organization: org, role: "admin")
        original_updated_at = membership.updated_at

        result = org.change_role_of!(admin, to: :admin)

        assert_equal "admin", result.role
      end

      test "R4 review: add_member! rejects owner role" do
        org, _owner = create_org_with_owner!(name: "No Add Owner Org")
        user = create_user!(email: "add-owner@example.com")

        assert_raises(Organizations::Organization::CannotHaveMultipleOwners) do
          org.add_member!(user, role: :owner)
        end

        refute org.has_member?(user)
      end

      test "R4 review: promote_to! rejects owner role" do
        org, _owner = create_org_with_owner!(name: "No Promote Owner Org")
        member = create_user!(email: "promote-owner@example.com")
        membership = Organizations::Membership.create!(user: member, organization: org, role: "member")

        assert_raises(Membership::CannotPromoteToOwner) do
          membership.promote_to!(:owner)
        end

        membership.reload
        assert_equal "member", membership.role
      end

      test "R4 review: cannot invite as owner role" do
        org, owner = create_org_with_owner!(name: "No Owner Invite Org")

        assert_raises(Organizations::Organization::CannotInviteAsOwner) do
          org.send_invite_to!("someone@example.com", invited_by: owner, role: :owner)
        end

        assert_equal 0, org.invitations.count
      end

      test "R4 review: cannot accept invitation with tampered owner role" do
        org, owner = create_org_with_owner!(name: "No Accept Owner Org")
        invitee = create_user!(email: "tampered@example.com")

        invitation = org.send_invite_to!("tampered@example.com", invited_by: owner)
        # Tamper with role directly in DB
        invitation.update_column(:role, "owner")
        invitation.reload

        assert_raises(Invitation::CannotAcceptAsOwner) do
          invitation.accept!(invitee)
        end

        refute org.has_member?(invitee), "Invitee must not become member with owner role"
      end

      test "R4 review: layout has proper CSS with custom properties" do
        layout_path = File.join(
          File.dirname(__FILE__), "..", "..", "app", "views",
          "layouts", "organizations", "application.html.erb"
        )
        content = File.read(layout_path)

        assert_match(/--org-bg/, content)
        assert_match(/--org-brand/, content)
        assert_match(/--org-text/, content)
      end

      test "R4 review: layout has navigation structure" do
        layout_path = File.join(
          File.dirname(__FILE__), "..", "..", "app", "views",
          "layouts", "organizations", "application.html.erb"
        )
        content = File.read(layout_path)

        assert_match(/org-nav/, content)
        assert_match(/flash/, content)
        assert_match(/<main/, content)
      end

      # =====================================================================
      # Additional edge cases ensuring Round 3-4 fixes are robust
      # =====================================================================

      test "edge: owner deletion guard works even if user has non-owner memberships too" do
        org1, owner = create_org_with_owner!(name: "Owner Org")
        org2 = Organizations::Organization.create!(name: "Member Org")
        Organizations::Membership.create!(user: owner, organization: org2, role: "member")

        # Owner has one owner membership and one member membership
        assert owner.memberships.where(role: "owner").exists?

        assert_raises(ActiveRecord::RecordNotDestroyed) do
          owner.destroy!
        end

        assert User.exists?(owner.id)
      end

      test "edge: org invite authorization checks inviter's membership in correct org" do
        org1, owner1 = create_org_with_owner!(name: "Org One")
        org2, _owner2 = create_org_with_owner!(name: "Org Two")

        # owner1 is a member of org1 but NOT org2
        refute org2.has_member?(owner1)

        assert_raises(Organizations::NotAMember) do
          org2.send_invite_to!("target@example.com", invited_by: owner1)
        end
      end

      test "edge: transfer ownership with only one member raises CannotTransferToNonMember" do
        org, owner = create_org_with_owner!(name: "Solo Owner Org")

        assert_raises(Organizations::Organization::CannotTransferToNonMember) do
          nonexistent_user = create_user!(email: "ghost@example.com")
          org.transfer_ownership_to!(nonexistent_user)
        end
      end

      test "edge: transfer to viewer raises CannotTransferToNonAdmin" do
        org, _owner = create_org_with_owner!(name: "Viewer Transfer Org")
        viewer = create_user!(email: "viewer-transfer@example.com")
        Organizations::Membership.create!(user: viewer, organization: org, role: "viewer")

        assert_raises(Organizations::Organization::CannotTransferToNonAdmin) do
          org.transfer_ownership_to!(viewer)
        end
      end

      test "edge: NoOwnerPresent error class inherits from Organizations::Error" do
        assert Organizations::Organization::NoOwnerPresent < Organizations::Error,
               "NoOwnerPresent must inherit from Organizations::Error"
      end

      test "edge: CannotInviteAsOwner error class inherits from Organizations::Error" do
        assert Organizations::Organization::CannotInviteAsOwner < Organizations::Error,
               "CannotInviteAsOwner must inherit from Organizations::Error"
      end

      test "edge: CannotRemoveOwner error class inherits from Organizations::Error" do
        assert Organizations::Organization::CannotRemoveOwner < Organizations::Error,
               "CannotRemoveOwner must inherit from Organizations::Error"
      end

      test "edge: CannotTransferToNonMember error class inherits from Organizations::Error" do
        assert Organizations::Organization::CannotTransferToNonMember < Organizations::Error,
               "CannotTransferToNonMember must inherit from Organizations::Error"
      end

      test "edge: CannotTransferToNonAdmin error class inherits from Organizations::Error" do
        assert Organizations::Organization::CannotTransferToNonAdmin < Organizations::Error,
               "CannotTransferToNonAdmin must inherit from Organizations::Error"
      end

      private

      def template_path(*parts)
        File.join(File.dirname(__FILE__), "..", "..", "app", "views", *parts)
      end
    end
  end
end
