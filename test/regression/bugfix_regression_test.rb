# frozen_string_literal: true

require "test_helper"

module Organizations
  # Regression tests for all issues documented in REVIEW.md.
  # Each test targets a specific bug or missing behavior that was found
  # during the Codex review rounds (1-4). These tests ensure those fixes
  # remain in place and do not regress.
  class BugfixRegressionTest < Organizations::Test
    # =========================================================================
    # Round 1 - Critical Findings
    # =========================================================================

    # Regression: Round 1, Critical #1
    # Engine controllers used `send(:current_user)` which, when the configured
    # method was `:current_user` (the default), would call itself infinitely
    # and raise SystemStackError. The fix delegates to `super` when the method
    # name matches :current_user.
    #
    # We verify the fix indirectly: the engine ApplicationController should
    # define a `current_user` method that breaks recursion by calling `super`
    # instead of re-dispatching via `send`.
    test "default current_user_method configuration is :current_user" do
      # The default configuration should use :current_user as the method name.
      # This is important because the engine controller has special handling
      # to prevent infinite recursion when the configured method matches
      # the controller's own current_user method.
      assert_equal :current_user, Organizations.configuration.current_user_method
    end

    test "current user resolver can call parent current_user when configured method is :current_user" do
      base_class = Class.new do
        def initialize(user)
          @base_user = user
        end

        def current_user
          @base_user
        end
      end

      resolver_class = Class.new(base_class) do
        include Organizations::CurrentUserResolution

        def current_user
          resolve_organizations_current_user(
            cache_ivar: :@_resolved_user,
            cache_nil: false,
            prefer_super_for_current_user: true
          )
        end
      end

      user = Struct.new(:id).new(42)
      resolver = resolver_class.new(user)

      assert_equal user, resolver.current_user
    end

    test "current user resolver gracefully handles NameError from parent current_user" do
      base_class = Class.new do
        def current_user
          UndefinedAuthNamespace::User
        end
      end

      resolver_class = Class.new(base_class) do
        include Organizations::CurrentUserResolution

        def current_user
          resolve_organizations_current_user(
            cache_ivar: :@_resolved_user,
            cache_nil: true,
            prefer_super_for_current_user: true
          )
        end
      end

      resolver = resolver_class.new
      assert_nil resolver.current_user
    end

    test "current user resolver uses warden fallback before super for public controllers" do
      user = Struct.new(:id).new(42)

      warden_proxy = Class.new do
        attr_reader :scopes

        def initialize(user)
          @user = user
          @scopes = []
        end

        def user(scope)
          @scopes << scope
          @user
        end
      end.new(user)

      base_class = Class.new do
        def current_user
          :from_super
        end
      end

      resolver_class = Class.new(base_class) do
        include Organizations::CurrentUserResolution

        def initialize(warden_proxy)
          @warden_proxy = warden_proxy
        end

        def current_user
          resolve_organizations_current_user(
            cache_ivar: :@_resolved_user,
            cache_nil: false,
            prefer_super_for_current_user: true,
            prefer_warden_for_current_user: true
          )
        end

        private

        def warden
          @warden_proxy
        end
      end

      resolver = resolver_class.new(warden_proxy)

      assert_equal user, resolver.current_user
      assert_equal [:user], warden_proxy.scopes
    end

    test "current user resolver handles nil warden middleware safely" do
      resolver_class = Class.new do
        include Organizations::CurrentUserResolution

        def current_user
          resolve_organizations_current_user(
            cache_ivar: :@_resolved_user,
            cache_nil: true,
            prefer_super_for_current_user: true,
            prefer_warden_for_current_user: true
          )
        end

        private

        def warden
          nil
        end
      end

      resolver = resolver_class.new
      assert_nil resolver.current_user
    end

    # Regression: Round 1, Critical #2
    # The Membership model depends on an `invited_by_id` column (belongs_to :invited_by).
    # The original migration template was missing this column. Verify the schema
    # has the column so accepting invitations does not raise DB errors.
    test "membership schema has invited_by_id column" do
      assert Organizations::Membership.column_names.include?("invited_by_id"),
        "memberships table must have invited_by_id column for the invited_by association"
    end

    # Regression: Round 1, Critical #3
    # Pending invitation uniqueness was only enforced at the application level.
    # A DB-level partial unique index should exist for PostgreSQL and SQLite.
    # At application level, the model validation prevents duplicates.
    test "pending invitation uniqueness enforced at application level" do
      owner = create_user!
      org = Organizations::Organization.create!(name: "Uniqueness Org")
      Organizations::Membership.create!(user: owner, organization: org, role: "owner")

      # Create first pending invitation
      invitation = Organizations::Invitation.create!(
        organization: org,
        email: "unique-test@example.com",
        invited_by: owner,
        role: "member",
        token: SecureRandom.urlsafe_base64(32),
        expires_at: 7.days.from_now
      )

      assert invitation.persisted?

      # Second invitation to same email (non-accepted) should fail validation
      duplicate = Organizations::Invitation.new(
        organization: org,
        email: "unique-test@example.com",
        invited_by: owner,
        role: "member",
        token: SecureRandom.urlsafe_base64(32),
        expires_at: 7.days.from_now
      )

      refute duplicate.valid?, "Duplicate pending invitation should fail validation"
      assert_includes duplicate.errors[:email].join, "already been invited"
    end

    # Regression: Round 1, Critical #4
    # The owner integrity rule ("exactly one owner") must be enforced.
    # change_role_of! must prevent promoting to owner (use transfer_ownership_to!)
    # and prevent demoting the owner directly.
    test "owner integrity: cannot promote to owner via change_role_of!" do
      org, _owner = create_org_with_owner!
      admin = create_user!
      org.add_member!(admin, role: :admin)

      error = assert_raises(Organizations::Organization::CannotHaveMultipleOwners) do
        org.change_role_of!(admin, to: :owner)
      end
      assert_match(/owner/i, error.message)
    end

    test "owner integrity: cannot demote owner via change_role_of!" do
      org, owner = create_org_with_owner!

      error = assert_raises(Organizations::Organization::CannotDemoteOwner) do
        org.change_role_of!(owner, to: :admin)
      end
      assert_match(/owner/i, error.message)
    end

    # Regression: Round 1, Critical #5
    # current_membership was memoized without keying on org_id, so switching
    # organizations could return the wrong membership. The fix keys the
    # memoization by org_id.
    test "current membership cache is keyed by org_id" do
      user = create_user!

      org1 = Organizations::Organization.create!(name: "Org One")
      org2 = Organizations::Organization.create!(name: "Org Two")
      Organizations::Membership.create!(user: user, organization: org1, role: "owner")
      Organizations::Membership.create!(user: user, organization: org2, role: "admin")

      # Set context to org1
      user._current_organization_id = org1.id
      membership1 = user.current_membership
      assert_equal org1.id, membership1.organization_id
      assert_equal "owner", membership1.role

      # Switch context to org2 -- cache should not return stale org1 membership
      user._current_organization_id = org2.id
      membership2 = user.current_membership
      assert_equal org2.id, membership2.organization_id
      assert_equal "admin", membership2.role

      # Memberships should be different objects for different orgs
      refute_equal membership1.id, membership2.id
    end

    # Regression: Round 1, Critical #7
    # Invite permission check was hardcoded to admin role instead of using
    # the permission system. Custom role configurations should be respected.
    test "invite permission uses permission-based check, not role-based" do
      org, _owner = create_org_with_owner!
      member = create_user!
      org.add_member!(member, role: :member)

      # Members do not have :invite_members permission by default
      refute Roles.has_permission?(:member, :invite_members),
        "Default member role should not have invite_members permission"

      # Admins have :invite_members permission
      assert Roles.has_permission?(:admin, :invite_members),
        "Default admin role should have invite_members permission"

      # Member should not be able to invite
      member._current_organization_id = org.id
      error = assert_raises(Organizations::NotAuthorized) do
        member.send_organization_invite_to!("someone@example.com")
      end
      assert_equal :invite_members, error.permission
    end

    # Regression: Round 1, Critical #8
    # When session pointed to an org user was no longer a member of (or no
    # session), the system should auto-switch to the next available org.
    # current_organization should return nil for invalid org IDs.
    test "auto-switch returns nil when current org is invalid" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Valid Org")
      Organizations::Membership.create!(user: user, organization: org, role: "owner")

      # Point to a non-existent org
      user._current_organization_id = -999
      result = user.current_organization

      # Should return nil because user is not a member of org -999
      assert_nil result, "current_organization should return nil for invalid org ID"
    end

    # Regression: Round 1, Critical #9
    # create_organization! must set current organization context after creation.
    test "create_organization! sets current organization context" do
      # Disable personal org creation so we control the flow
      Organizations.configure do |config|
        config.always_create_personal_organization_for_each_user = false
      end

      user = User.create!(email: "creator-#{SecureRandom.hex(4)}@example.com", name: "Creator")

      org = user.create_organization!("My New Org")

      assert_equal org.id, user._current_organization_id,
        "create_organization! should set _current_organization_id"
      assert_equal org, user.current_organization,
        "create_organization! should set current_organization"
      assert user.is_organization_owner?,
        "User should be owner of newly created organization"
    end

    # Regression: Round 1, Critical #10
    # Token generation should use a loop with uniqueness check.
    # The generate_unique_token method produces urlsafe_base64 tokens
    # that are checked against existing tokens before use.
    test "invitation token generation produces unique tokens" do
      org, owner = create_org_with_owner!

      # Create multiple invitations and verify tokens are all unique
      tokens = 10.times.map do |i|
        inv = Organizations::Invitation.create!(
          organization: org,
          email: "token-test-#{i}@example.com",
          invited_by: owner,
          role: "member",
          expires_at: 7.days.from_now
        )
        inv.token
      end

      assert_equal tokens.uniq.length, tokens.length,
        "All invitation tokens must be unique"

      # Tokens should not be blank
      tokens.each do |token|
        refute_nil token
        refute token.empty?, "Token must not be empty"
      end
    end

    # Regression: Round 1, Critical #11
    # dependent: :nullify requires invited_by_id to be nullable.
    # When a user who sent invitations is deleted, their invited_by_id
    # should be set to NULL rather than raising a constraint error.
    test "dependent nullify works with nullable invited_by" do
      org, _owner = create_org_with_owner!
      inviter = create_user!
      org.add_member!(inviter, role: :admin)

      invitation = Organizations::Invitation.create!(
        organization: org,
        email: "nullify-test@example.com",
        invited_by: inviter,
        role: "member",
        token: SecureRandom.urlsafe_base64(32),
        expires_at: 7.days.from_now
      )

      assert_equal inviter.id, invitation.invited_by_id

      # Delete the inviter -- should nullify invited_by_id, not raise
      # First remove their owner memberships concern
      inviter.memberships.destroy_all
      inviter.destroy!

      invitation.reload
      assert_nil invitation.invited_by_id,
        "invited_by_id should be nullified after inviter deletion"
      assert_nil invitation.invited_by,
        "invited_by association should return nil after inviter deletion"
    end

    # =========================================================================
    # Round 2 - Critical Remaining
    # =========================================================================

    # Regression: Round 2, Critical #1 (controller routes role changes)
    # The MembershipsController#update must route role changes through
    # Organization#change_role_of! to enforce the owner invariant,
    # instead of calling @membership.update! directly.
    test "change_role_of! enforces owner invariant" do
      org, _owner = create_org_with_owner!
      admin = create_user!
      org.add_member!(admin, role: :admin)
      member = create_user!
      org.add_member!(member, role: :member)

      # Valid role change: member -> admin
      result = org.change_role_of!(member, to: :admin)
      assert_equal "admin", result.role

      # Invalid: admin -> owner (must use transfer_ownership_to!)
      assert_raises(Organizations::Organization::CannotHaveMultipleOwners) do
        org.change_role_of!(admin, to: :owner)
      end

      # Owner count should still be exactly 1
      assert_equal 1, org.memberships.where(role: "owner").count
    end

    # Regression: Round 2, Critical #5
    # Nullable inviter should be safe in mailer and JSON serialization.
    # The invited_by association is optional: true, so nil inviter should
    # not crash any code paths.
    test "nullable inviter is safe in invitation model" do
      org, _owner = create_org_with_owner!

      invitation = Organizations::Invitation.create!(
        organization: org,
        email: "no-inviter@example.com",
        invited_by: nil,
        role: "member",
        token: SecureRandom.urlsafe_base64(32),
        expires_at: 7.days.from_now
      )

      # Should not raise when accessing nil inviter
      assert_nil invitation.invited_by
      assert_nil invitation.from
      assert_nil invitation.invited_by_id

      # The invitation should still be fully functional
      assert invitation.pending?
      refute invitation.accepted?
      refute invitation.expired?
    end

    # =========================================================================
    # Round 3 - Critical Findings
    # =========================================================================

    # Regression: Round 3, Critical #1 (owner deletion guard prepend: true)
    # The before_destroy callback for preventing deletion of users who own
    # organizations must run BEFORE dependent: :destroy on memberships.
    # If it ran after, the owner membership would already be destroyed and
    # the guard would not detect the ownership.
    test "owner deletion guard prevents deleting user who owns organizations" do
      _org, owner = create_org_with_owner!

      # Owner should not be deletable while owning organizations
      result = owner.destroy
      assert_equal false, result, "destroy should return false for user who owns organizations"
      assert owner.persisted?, "User who owns organizations should not be deleted"
      assert_includes owner.errors[:base].join, "Cannot delete",
        "Should have error about organization ownership"
    end

    test "owner deletion guard runs before membership destruction" do
      org, owner = create_org_with_owner!
      original_membership_count = org.memberships.count

      # Try to destroy -- should fail
      owner.destroy

      # Memberships should still exist (guard ran before dependent: :destroy)
      assert_equal original_membership_count, org.memberships.reload.count,
        "Memberships should not be destroyed if owner deletion is blocked"
    end

    # Regression: Round 3, Critical #2 (org-centric invitation API)
    # org.send_invite_to! requires the inviter to be a member with
    # :invite_members permission. Non-members and members without
    # permission should be rejected.
    test "org-centric invitation API requires membership" do
      org, _owner = create_org_with_owner!
      non_member = create_user!

      error = assert_raises(Organizations::NotAMember) do
        org.send_invite_to!("someone@example.com", invited_by: non_member)
      end
      assert_match(/member/i, error.message)
    end

    test "org-centric invitation API requires invite_members permission" do
      org, _owner = create_org_with_owner!
      viewer = create_user!
      org.add_member!(viewer, role: :viewer)

      error = assert_raises(Organizations::NotAuthorized) do
        org.send_invite_to!("someone@example.com", invited_by: viewer)
      end
      assert_equal :invite_members, error.permission
    end

    test "org-centric invitation API succeeds for admin with permission" do
      org, _owner = create_org_with_owner!
      admin = create_user!
      org.add_member!(admin, role: :admin)

      invitation = org.send_invite_to!("invitee@example.com", invited_by: admin)
      assert invitation.persisted?
      assert_equal "invitee@example.com", invitation.email
      assert_equal admin.id, invitation.invited_by_id
    end

    # Regression: Round 3, Critical (NoOwnerPresent error)
    # If an organization somehow has no owner (corrupted state), calling
    # transfer_ownership_to! should raise a descriptive error.
    test "transfer_ownership_to! raises NoOwnerPresent for corrupted state" do
      org = Organizations::Organization.create!(name: "No Owner Org")
      user = create_user!
      Organizations::Membership.create!(user: user, organization: org, role: "admin")

      error = assert_raises(Organizations::Organization::NoOwnerPresent) do
        org.transfer_ownership_to!(user)
      end
      assert_match(/no owner/i, error.message)
    end

    # =========================================================================
    # Round 4 - Critical Findings
    # =========================================================================

    # Regression: Round 4, Critical #1
    # Owner role must be blocked in add_member! and promote_to!.
    # Only transfer_ownership_to! should assign the owner role.
    test "add_member! blocks owner role" do
      org, _owner = create_org_with_owner!
      new_user = create_user!

      error = assert_raises(Organizations::Organization::CannotHaveMultipleOwners) do
        org.add_member!(new_user, role: :owner)
      end
      assert_match(/owner/i, error.message)

      # User should not have been added
      refute org.has_member?(new_user)
    end

    test "promote_to! blocks owner role" do
      org, _owner = create_org_with_owner!
      admin = create_user!
      org.add_member!(admin, role: :admin)

      membership = org.memberships.find_by(user: admin)
      error = assert_raises(Organizations::Membership::CannotPromoteToOwner) do
        membership.promote_to!(:owner)
      end
      assert_match(/owner/i, error.message)

      # Role should not have changed
      membership.reload
      assert_equal "admin", membership.role
    end

    # Regression: Round 4, High #1
    # Re-inviting an email with an expired invitation should refresh
    # the expired invitation rather than failing.
    test "expired invitation refresh works when re-inviting" do
      org, owner = create_org_with_owner!

      # Create an invitation that is already expired
      expired_invitation = Organizations::Invitation.create!(
        organization: org,
        email: "expired-user@example.com",
        invited_by: owner,
        role: "member",
        token: SecureRandom.urlsafe_base64(32),
        expires_at: 1.day.ago
      )

      assert expired_invitation.expired?

      old_token = expired_invitation.token

      # Re-invite the same email -- should refresh the expired invitation
      new_invitation = org.send_invite_to!("expired-user@example.com", invited_by: owner)

      assert new_invitation.persisted?
      assert_equal expired_invitation.id, new_invitation.id,
        "Should refresh the existing expired invitation, not create a new one"
      refute_equal old_token, new_invitation.token,
        "Token should be regenerated"
      assert new_invitation.pending?,
        "Refreshed invitation should be pending"
      refute new_invitation.expired?,
        "Refreshed invitation should not be expired"
    end

    # Regression: Round 4, High #2
    # Existing-member check should be case-insensitive so that invitations
    # are not created for users who are already members but with different
    # email casing.
    test "case-insensitive existing-member check prevents duplicate invites" do
      org, owner = create_org_with_owner!
      member = User.create!(email: "MixedCase@Example.com", name: "Mixed Case User")
      org.add_member!(member, role: :member)

      # Invite with lowercase version of same email
      error = assert_raises(Organizations::InvitationError) do
        org.send_invite_to!("mixedcase@example.com", invited_by: owner)
      end
      assert_match(/already a member/i, error.message)
    end

    # Regression: Round 4, High #3
    # Ownership transfer must be admin-only (per README contract).
    # Transferring to a viewer or member should raise CannotTransferToNonAdmin.
    test "ownership transfer requires admin role" do
      org, owner = create_org_with_owner!
      member = create_user!
      org.add_member!(member, role: :member)

      error = assert_raises(Organizations::Organization::CannotTransferToNonAdmin) do
        org.transfer_ownership_to!(member)
      end
      assert_match(/admin/i, error.message)

      # Owner should still be the original owner
      assert_equal owner.id, org.reload.owner.id
    end

    test "ownership transfer works for admin" do
      org, owner = create_org_with_owner!
      admin = create_user!
      org.add_member!(admin, role: :admin)

      org.transfer_ownership_to!(admin)

      # Verify ownership transferred
      org_reloaded = Organizations::Organization.find(org.id)
      assert_equal admin.id, org_reloaded.owner.id

      # Old owner should now be admin
      old_owner_membership = org_reloaded.memberships.find_by(user: owner)
      assert_equal "admin", old_owner_membership.role
    end

    test "ownership transfer to non-member raises error" do
      org, _owner = create_org_with_owner!
      non_member = create_user!

      error = assert_raises(Organizations::Organization::CannotTransferToNonMember) do
        org.transfer_ownership_to!(non_member)
      end
      assert_match(/non-member/i, error.message)
    end

    # =========================================================================
    # Additional cross-cutting regression tests
    # =========================================================================

    # Verify that the full owner invariant protection chain works end-to-end.
    # All paths to assigning the owner role (except transfer_ownership_to!)
    # should be blocked.
    test "owner invariant is enforced at all entry points" do
      org, owner = create_org_with_owner!
      user = create_user!
      org.add_member!(user, role: :admin)

      # 1. add_member! with role: :owner
      new_user = create_user!
      assert_raises(Organizations::Organization::CannotHaveMultipleOwners) do
        org.add_member!(new_user, role: :owner)
      end

      # 2. promote_to!(:owner)
      membership = org.memberships.find_by(user: user)
      assert_raises(Organizations::Membership::CannotPromoteToOwner) do
        membership.promote_to!(:owner)
      end

      # 3. change_role_of! to :owner
      assert_raises(Organizations::Organization::CannotHaveMultipleOwners) do
        org.change_role_of!(user, to: :owner)
      end

      # 4. send_invite_to! with role: :owner
      assert_raises(Organizations::Organization::CannotInviteAsOwner) do
        org.send_invite_to!("owner-invite@example.com", invited_by: owner, role: :owner)
      end

      # 5. Invitation#accept! with owner role
      invitation = Organizations::Invitation.create!(
        organization: org,
        email: "accept-owner@example.com",
        invited_by: owner,
        role: "owner",
        token: SecureRandom.urlsafe_base64(32),
        expires_at: 7.days.from_now
      )
      acceptor = User.create!(email: "accept-owner@example.com", name: "Acceptor")
      assert_raises(Organizations::Invitation::CannotAcceptAsOwner) do
        invitation.accept!(acceptor)
      end

      # After all attempts, there should still be exactly one owner
      assert_equal 1, org.memberships.where(role: "owner").count,
        "There must be exactly one owner after all blocked attempts"
    end

    # Verify that clear_organization_cache! resets _current_organization_id
    test "clear_organization_cache! resets all cached state" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Cache Org")
      Organizations::Membership.create!(user: user, organization: org, role: "owner")

      user._current_organization_id = org.id
      assert_equal org, user.current_organization

      user.clear_organization_cache!

      assert_nil user._current_organization_id,
        "clear_organization_cache! must reset _current_organization_id"
      assert_nil user.current_organization,
        "clear_organization_cache! must clear cached current_organization"
    end

    # Verify invitation email matching is enforced at model level
    test "invitation accept! validates email match at model level" do
      org, owner = create_org_with_owner!

      invitation = Organizations::Invitation.create!(
        organization: org,
        email: "correct@example.com",
        invited_by: owner,
        role: "member",
        token: SecureRandom.urlsafe_base64(32),
        expires_at: 7.days.from_now
      )

      wrong_user = User.create!(email: "wrong@example.com", name: "Wrong User")

      assert_raises(Organizations::Invitation::EmailMismatch) do
        invitation.accept!(wrong_user)
      end

      # Invitation should still be pending
      invitation.reload
      assert invitation.pending?
    end

    # Verify invitation accept! can skip email validation (for admin acceptance)
    test "invitation accept! with skip_email_validation works" do
      org, owner = create_org_with_owner!

      invitation = Organizations::Invitation.create!(
        organization: org,
        email: "invitee@example.com",
        invited_by: owner,
        role: "member",
        token: SecureRandom.urlsafe_base64(32),
        expires_at: 7.days.from_now
      )

      # Accept with a different email but skip validation
      different_user = User.create!(email: "different@example.com", name: "Different User")
      membership = invitation.accept!(different_user, skip_email_validation: true)

      assert membership.persisted?
      assert invitation.reload.accepted?
    end

    # Verify that for_email scope is case-insensitive
    test "for_email scope is case-insensitive" do
      org, owner = create_org_with_owner!

      invitation = Organizations::Invitation.create!(
        organization: org,
        email: "case@example.com",
        invited_by: owner,
        role: "member",
        token: SecureRandom.urlsafe_base64(32),
        expires_at: 7.days.from_now
      )

      # Should find with different casing
      found = Organizations::Invitation.for_email("CASE@Example.COM").first
      assert_equal invitation.id, found.id
    end

    # Verify that the Controller alias exists for README compatibility
    test "Organizations::Controller alias exists" do
      assert_equal Organizations::ControllerHelpers, Organizations::Controller,
        "Organizations::Controller should be an alias for ControllerHelpers"
    end

    # =========================================================================
    # Edge cases from task #10
    # =========================================================================

    # Edge case: inviting an existing member returns an error, not a duplicate.
    # This ensures the existing-member guard fires even for exact email match.
    test "invitation for existing member returns error" do
      org, owner = create_org_with_owner!
      member = User.create!(email: "existing-member@example.com", name: "Existing")
      org.add_member!(member, role: :member)

      error = assert_raises(Organizations::InvitationError) do
        org.send_invite_to!("existing-member@example.com", invited_by: owner)
      end
      assert_match(/already a member/i, error.message)

      # No invitation should have been created
      assert_equal 0, org.invitations.count,
        "No invitation should be created for an existing member"
    end

    # Edge case: two admins inviting the same email concurrently should return
    # the existing pending invitation idempotently (not duplicate).
    test "two admins inviting same email returns existing invitation" do
      org, owner = create_org_with_owner!
      admin = create_user!
      org.add_member!(admin, role: :admin)

      # First admin invites
      invitation1 = org.send_invite_to!("shared-invite@example.com", invited_by: owner)
      assert invitation1.persisted?

      # Second admin invites the same email -- should get back the same invitation
      invitation2 = org.send_invite_to!("shared-invite@example.com", invited_by: admin)
      assert_equal invitation1.id, invitation2.id,
        "Second invite to same email should return existing pending invitation"

      # Only one invitation should exist
      assert_equal 1, org.invitations.where(email: "shared-invite@example.com").count,
        "Only one invitation should exist for the same email"
    end

    # Edge case: session points to an org the user was removed from.
    # current_organization should detect the stale session and return nil.
    test "stale session after removal from org returns nil for current_organization" do
      user = create_user!
      org1 = Organizations::Organization.create!(name: "Org To Leave")
      org2 = Organizations::Organization.create!(name: "Fallback Org")
      Organizations::Membership.create!(user: user, organization: org1, role: "admin")
      Organizations::Membership.create!(user: user, organization: org2, role: "member")

      # Set current org to org1
      user._current_organization_id = org1.id
      assert_equal org1, user.current_organization

      # Simulate removal: destroy user's membership in org1
      org1.memberships.find_by(user: user).destroy!

      # Clear cache to simulate next request
      user.clear_organization_cache!
      user._current_organization_id = org1.id

      # current_organization should return nil because user is no longer a member
      result = user.current_organization
      assert_nil result,
        "current_organization should return nil when session points to org user was removed from"
    end

    # Edge case: duplicate/stale session handling -- user with no _current_organization_id
    # should get nil from current_organization (no crash).
    test "nil current_organization_id returns nil current_organization" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Some Org")
      Organizations::Membership.create!(user: user, organization: org, role: "member")

      user._current_organization_id = nil
      assert_nil user.current_organization,
        "current_organization should be nil when _current_organization_id is nil"
    end

    # Edge case: create_organization! populates current_membership correctly.
    # After creating an org, user.current_membership should reflect the owner
    # membership in the new org without requiring a page refresh.
    test "create_organization! makes current_membership available immediately" do
      Organizations.configure do |config|
        config.always_create_personal_organization_for_each_user = false
      end

      user = User.create!(email: "immediate-#{SecureRandom.hex(4)}@example.com", name: "Immediate")
      org = user.create_organization!("Immediate Org")

      membership = user.current_membership
      refute_nil membership, "current_membership should be available immediately after create_organization!"
      assert_equal org.id, membership.organization_id
      assert_equal "owner", membership.role
    end

    # Edge case: expired invitation resend! generates new token and resets expiry.
    test "expired invitation can be resent with resend!" do
      org, owner = create_org_with_owner!

      invitation = Organizations::Invitation.create!(
        organization: org,
        email: "resend-target@example.com",
        invited_by: owner,
        role: "member",
        token: SecureRandom.urlsafe_base64(32),
        expires_at: 1.day.ago
      )

      assert invitation.expired?
      old_token = invitation.token

      invitation.resend!
      invitation.reload

      refute_equal old_token, invitation.token,
        "resend! should generate a new token"
      refute invitation.expired?,
        "resend! should reset expiry so invitation is no longer expired"
      assert invitation.pending?,
        "resend! should make invitation pending again"
    end

    # Edge case: current_membership cache updates correctly during rapid org switches.
    # Switching back and forth between orgs should always return the correct membership.
    test "rapid org switches return correct membership each time" do
      user = create_user!
      org_a = Organizations::Organization.create!(name: "Org A")
      org_b = Organizations::Organization.create!(name: "Org B")
      Organizations::Membership.create!(user: user, organization: org_a, role: "owner")
      Organizations::Membership.create!(user: user, organization: org_b, role: "viewer")

      # Switch back and forth multiple times
      5.times do
        user._current_organization_id = org_a.id
        assert_equal "owner", user.current_membership.role
        assert_equal org_a.id, user.current_membership.organization_id

        user._current_organization_id = org_b.id
        assert_equal "viewer", user.current_membership.role
        assert_equal org_b.id, user.current_membership.organization_id
      end
    end

    # Edge case: invitation uniqueness is scoped to non-accepted invitations.
    # An accepted invitation should not block a new invitation to the same email.
    test "accepted invitation does not block new invitation to same email" do
      org, owner = create_org_with_owner!

      # Create and accept first invitation
      user = User.create!(email: "reusable@example.com", name: "Reusable")
      invitation1 = Organizations::Invitation.create!(
        organization: org,
        email: "reusable@example.com",
        invited_by: owner,
        role: "member",
        token: SecureRandom.urlsafe_base64(32),
        expires_at: 7.days.from_now
      )
      invitation1.accept!(user)
      assert invitation1.reload.accepted?

      # Remove user from org
      org.remove_member!(user)

      # Should be able to create a new invitation to the same email
      invitation2 = Organizations::Invitation.create!(
        organization: org,
        email: "reusable@example.com",
        invited_by: owner,
        role: "member",
        token: SecureRandom.urlsafe_base64(32),
        expires_at: 7.days.from_now
      )

      assert invitation2.persisted?
      refute_equal invitation1.id, invitation2.id,
        "A new invitation should be created after the first was accepted"
    end
  end
end
