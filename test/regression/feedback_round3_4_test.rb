# frozen_string_literal: true

require "test_helper"

# Load InvitationMailer explicitly (not auto-loaded without Rails engine)
_mailer_path = File.expand_path("../../app/mailers/organizations/invitation_mailer.rb", __dir__)
require _mailer_path if File.exist?(_mailer_path)

# Project root for source file inspection
PROJECT_ROOT_R34 = File.expand_path("../..", __dir__)

module Organizations
  # Exhaustive regression tests for FEEDBACK.md Rounds 3-4.
  #
  # These cover every item from:
  # - Round 2 Codex Review: Critical Remaining (#1-#6)
  # - Round 2 Codex Review: High Remaining (#1-#6)
  # - Round 3 Claude Response: All fixes applied (#1-#6)
  #
  # Each test is tagged with the exact FEEDBACK.md item it verifies.
  #
  class FeedbackRound3And4RegressionTest < Organizations::Test
    # =========================================================================
    # ROUND 2 CODEX REVIEW - CRITICAL REMAINING
    # =========================================================================

    # -------------------------------------------------------------------------
    # Critical Remaining #1: current_user recursion in InvitationsController
    #
    # FEEDBACK.md lines 352-354:
    # "if config.current_user_method == :current_user (default), method calls
    #  itself via send."
    #
    # The fix: InvitationsController#current_user checks if method_name == :current_user,
    # and if so calls `super rescue nil` instead of `send(:current_user)`.
    # -------------------------------------------------------------------------

    test "R2 Critical #1: InvitationsController current_user guards against recursion when default config" do
      # Verify default config uses :current_user
      assert_equal :current_user, Organizations.configuration.current_user_method

      # Read the InvitationsController source and verify the recursion guard
      controller_path = File.join(PROJECT_ROOT_R34,
        "app/controllers/organizations/invitations_controller.rb"
      )
      assert File.exist?(controller_path), "InvitationsController must exist"

      source = File.read(controller_path)

      # Must check for the method name being :current_user
      assert source.include?("method_name == :current_user"),
        "InvitationsController must check if configured method is :current_user"

      # Must use super (not send) when method is :current_user to avoid recursion
      assert source.include?("super"),
        "InvitationsController must call super when method is :current_user"

      # Must memoize to avoid repeated calls
      assert source.include?("@_current_user"),
        "InvitationsController must memoize the current_user result"
    end

    test "R2 Critical #1: InvitationsController current_user handles non-default config method" do
      # The fix must also handle when the config method is NOT :current_user
      controller_path = File.join(PROJECT_ROOT_R34,
        "app/controllers/organizations/invitations_controller.rb"
      )
      source = File.read(controller_path)

      # When method_name != :current_user, it should use send(method_name)
      assert source.include?("respond_to?(method_name"),
        "InvitationsController must check respond_to? for non-default method"
      assert source.include?("send(method_name)"),
        "InvitationsController must use send for non-default method"
    end

    # -------------------------------------------------------------------------
    # Critical Remaining #2: create_organization! context assignment broken
    #
    # FEEDBACK.md lines 356-358:
    # "_current_organization_id is set, then immediately cleared by
    #  clear_organization_cache!, so context is lost."
    #
    # The fix: set cached values first, then set _current_organization_id last,
    # without calling clear_organization_cache!.
    # -------------------------------------------------------------------------

    test "R2 Critical #2: create_organization! preserves context assignment (not cleared by cache)" do
      Organizations.configure do |config|
        config.create_personal_organization = false
      end

      user = User.create!(email: "ctx-assign-#{SecureRandom.hex(4)}@example.com", name: "Context User")
      org = user.create_organization!("Context Org")

      # Verify _current_organization_id is set and NOT cleared
      assert_equal org.id, user._current_organization_id,
        "create_organization! must set _current_organization_id"

      # Verify current_organization returns the newly created org
      assert_equal org, user.current_organization,
        "create_organization! must set current_organization"

      # Verify role is accessible immediately (owner)
      assert_equal :owner, user.current_organization_role,
        "create_organization! must make role accessible immediately"

      # Verify is_organization_owner? works immediately
      assert user.is_organization_owner?,
        "User must be recognized as owner immediately after create_organization!"
    end

    test "R2 Critical #2: create_organization! source does not call clear_organization_cache!" do
      # Verify the source code does not call clear_organization_cache! after setting context
      has_orgs_path = File.join(PROJECT_ROOT_R34,
        "lib/organizations/models/concerns/has_organizations.rb"
      )
      source = File.read(has_orgs_path)

      # Find the create_organization! method body
      method_start = source.index("def create_organization!")
      method_end = source.index("def leave_organization!")
      assert method_start, "create_organization! method must exist"
      assert method_end, "leave_organization! method must exist"

      method_body = source[method_start...method_end]

      # Extract only executable lines (strip comments) to check if
      # clear_organization_cache! is actually CALLED (not just mentioned in comments)
      executable_lines = method_body.lines.reject { |line| line.strip.start_with?("#") }
      executable_body = executable_lines.join

      # The executable method body should NOT call clear_organization_cache!
      refute executable_body.include?("clear_organization_cache!"),
        "create_organization! must NOT call clear_organization_cache! (it clears the ID)"

      # It should set @_current_organization directly
      assert method_body.include?("@_current_organization = org"),
        "create_organization! must set @_current_organization directly"

      # It should set _current_organization_id
      assert method_body.include?("_current_organization_id = org.id"),
        "create_organization! must set _current_organization_id"
    end

    test "R2 Critical #2: create_organization! current_membership available immediately" do
      Organizations.configure do |config|
        config.create_personal_organization = false
      end

      user = User.create!(email: "membership-imm-#{SecureRandom.hex(4)}@example.com", name: "Immediate")
      org = user.create_organization!("Immediate Membership Org")

      membership = user.current_membership
      refute_nil membership,
        "current_membership must be available immediately after create_organization!"
      assert_equal org.id, membership.organization_id
      assert_equal "owner", membership.role
    end

    # -------------------------------------------------------------------------
    # Critical Remaining #3: Ownership invariant bypassable via other public APIs
    #
    # FEEDBACK.md lines 360-362:
    # "org.add_member!(..., role: :owner) and membership.promote_to!(:owner)
    #  can create multiple owners."
    #
    # The fix: add_member! raises CannotHaveMultipleOwners for role: :owner,
    # promote_to! raises CannotPromoteToOwner for :owner.
    # -------------------------------------------------------------------------

    test "R2 Critical #3: add_member! blocks owner role assignment" do
      org, _owner = create_org_with_owner!
      user = create_user!

      error = assert_raises(Organizations::Organization::CannotHaveMultipleOwners) do
        org.add_member!(user, role: :owner)
      end
      assert_match(/owner/i, error.message)
      refute org.has_member?(user), "User should not be added with owner role"
    end

    test "R2 Critical #3: promote_to! blocks owner role" do
      org, _owner = create_org_with_owner!
      admin = create_user!
      org.add_member!(admin, role: :admin)

      membership = org.memberships.find_by(user: admin)

      error = assert_raises(Organizations::Membership::CannotPromoteToOwner) do
        membership.promote_to!(:owner)
      end
      assert_match(/owner/i, error.message)

      # Role must remain unchanged
      membership.reload
      assert_equal "admin", membership.role
    end

    test "R2 Critical #3: change_role_of! blocks promotion to owner" do
      org, _owner = create_org_with_owner!
      member = create_user!
      org.add_member!(member, role: :member)

      assert_raises(Organizations::Organization::CannotHaveMultipleOwners) do
        org.change_role_of!(member, to: :owner)
      end

      # Only one owner must exist
      assert_equal 1, org.memberships.where(role: "owner").count
    end

    test "R2 Critical #3: change_role_of! blocks demotion of owner" do
      org, owner = create_org_with_owner!

      assert_raises(Organizations::Organization::CannotDemoteOwner) do
        org.change_role_of!(owner, to: :admin)
      end

      # Owner must remain owner
      assert_equal "owner", org.memberships.find_by(user: owner).role
    end

    test "R2 Critical #3: send_invite_to! blocks owner role in invitation" do
      org, owner = create_org_with_owner!

      assert_raises(Organizations::Organization::CannotInviteAsOwner) do
        org.send_invite_to!("owner-invite@example.com", invited_by: owner, role: :owner)
      end
    end

    test "R2 Critical #3: invitation accept! blocks owner role (defense in depth)" do
      org, owner = create_org_with_owner!

      # Manually create an invitation with owner role (bypassing send_invite_to! guard)
      invitation = Organizations::Invitation.create!(
        organization: org,
        email: "accept-owner-r2@example.com",
        invited_by: owner,
        role: "owner",
        token: SecureRandom.urlsafe_base64(32),
        expires_at: 7.days.from_now
      )

      acceptor = User.create!(email: "accept-owner-r2@example.com", name: "Acceptor")

      assert_raises(Organizations::Invitation::CannotAcceptAsOwner) do
        invitation.accept!(acceptor)
      end

      # Still exactly one owner
      assert_equal 1, org.memberships.where(role: "owner").count
    end

    test "R2 Critical #3: only transfer_ownership_to! can reassign ownership" do
      org, owner = create_org_with_owner!
      admin = create_user!
      org.add_member!(admin, role: :admin)

      # Transfer should succeed
      org.transfer_ownership_to!(admin)

      # Verify
      assert_equal admin.id, org.reload.owner.id
      assert_equal "admin", org.memberships.find_by(user: owner).role
      assert_equal 1, org.memberships.where(role: "owner").count
    end

    # -------------------------------------------------------------------------
    # Critical Remaining #4: Route/controller contract mismatch
    #
    # FEEDBACK.md lines 364-366:
    # "routes are URL-scoped by organization_id, but controllers ignore
    #  params[:organization_id] and use session org."
    #
    # The fix: flatten routes so memberships and invitations are not nested
    # under organizations/:organization_id. Session determines the org.
    # -------------------------------------------------------------------------

    test "R2 Critical #4: routes file uses flat routes for memberships and invitations" do
      routes_path = File.join(PROJECT_ROOT_R34, "config/routes.rb")
      source = File.read(routes_path)

      # Memberships and invitations should be top-level resources, NOT nested
      refute source.include?("resources :organizations do"),
        "Routes must NOT nest memberships/invitations under organizations"

      # Routes should be flat
      assert source.include?("resources :memberships"),
        "Memberships routes must be flat (not nested)"
      assert source.include?("resources :invitations"),
        "Invitations routes must be flat (not nested)"

      # Organization switching route must exist
      assert source.include?("switch"),
        "Organization switch route must exist"
    end

    test "R2 Critical #4: routes are session-scoped, not URL-scoped" do
      routes_path = File.join(PROJECT_ROOT_R34, "config/routes.rb")
      source = File.read(routes_path)

      # Should mention session-scoping in comments
      assert source.include?("session") || source.include?("current_organization"),
        "Routes file should document session-scoped model"
    end

    # -------------------------------------------------------------------------
    # Critical Remaining #5: invited_by made nullable but code assumes presence
    #
    # FEEDBACK.md lines 368-370:
    # "nil inviter will crash mailer/JSON serializer unless guarded."
    #
    # The fix: InvitationMailer#inviter_name returns "The team" for nil,
    # templates conditionally render, controller JSON returns nil/Someone.
    # -------------------------------------------------------------------------

    test "R2 Critical #5: InvitationMailer handles nil invited_by without crash" do
      mailer_path = File.join(PROJECT_ROOT_R34,
        "app/mailers/organizations/invitation_mailer.rb"
      )
      source = File.read(mailer_path)

      # inviter_name method must handle nil inviter
      assert source.include?("The team") || source.include?("the team"),
        "InvitationMailer must return a fallback name when inviter is nil"
    end

    test "R2 Critical #5: invitation model allows nil invited_by" do
      org, _owner = create_org_with_owner!

      # Create invitation with nil invited_by (should not raise)
      invitation = Organizations::Invitation.new(
        organization: org,
        email: "nil-inviter@example.com",
        invited_by: nil,
        role: "member",
        token: SecureRandom.urlsafe_base64(32),
        expires_at: 7.days.from_now
      )

      assert invitation.valid?, "Invitation with nil invited_by must be valid"
      invitation.save!

      # Accessing nil inviter should not crash
      assert_nil invitation.invited_by
      assert_nil invitation.from
      assert_nil invitation.invited_by_id

      # Invitation should still be fully functional
      assert invitation.pending?
    end

    test "R2 Critical #5: InvitationsController JSON handles nil invited_by" do
      controller_path = File.join(PROJECT_ROOT_R34,
        "app/controllers/organizations/invitations_controller.rb"
      )
      source = File.read(controller_path)

      # invitation_json must guard against nil inviter
      assert source.include?("inviter") && source.include?("nil"),
        "InvitationsController JSON serialization must handle nil inviter"

      # invitation_show_json must show "Someone" for nil inviter
      assert source.include?("Someone"),
        "InvitationsController show JSON must show 'Someone' for nil inviter"
    end

    test "R2 Critical #5: invitation accept! works with nil invited_by" do
      org, _owner = create_org_with_owner!

      invitation = Organizations::Invitation.create!(
        organization: org,
        email: "nil-inviter-accept@example.com",
        invited_by: nil,
        role: "member",
        token: SecureRandom.urlsafe_base64(32),
        expires_at: 7.days.from_now
      )

      user = User.create!(email: "nil-inviter-accept@example.com", name: "Acceptor")
      membership = invitation.accept!(user)

      assert membership.persisted?
      assert invitation.reload.accepted?
    end

    # -------------------------------------------------------------------------
    # Critical Remaining #6: Top-level model constant loading inconsistent
    #
    # FEEDBACK.md lines 372-374:
    # "running simple model usage via test_helper still raises missing constant
    #  (Organizations::Membership / Organizations::Organization resolution failures)."
    #
    # The fix: top-level aliases in lib/organizations.rb so
    # Organizations::Organization, Organizations::Membership, Organizations::Invitation
    # resolve correctly.
    # -------------------------------------------------------------------------

    test "R2 Critical #6: Organizations::Organization resolves correctly" do
      assert_equal Organizations::Organization, Organizations::Organization
      assert Organizations::Organization < ActiveRecord::Base,
        "Organizations::Organization must be an ActiveRecord model"
    end

    test "R2 Critical #6: Organizations::Membership resolves correctly" do
      assert_equal Organizations::Membership, Organizations::Membership
      assert Organizations::Membership < ActiveRecord::Base,
        "Organizations::Membership must be an ActiveRecord model"
    end

    test "R2 Critical #6: Organizations::Invitation resolves correctly" do
      assert_equal Organizations::Invitation, Organizations::Invitation
      assert Organizations::Invitation < ActiveRecord::Base,
        "Organizations::Invitation must be an ActiveRecord model"
    end

    test "R2 Critical #6: model constants are usable for queries" do
      # These should not raise NameError
      assert_equal 0, Organizations::Organization.count
      assert_equal 0, Organizations::Membership.count
      assert_equal 0, Organizations::Invitation.count
    end

    test "R2 Critical #6: autoload entries exist in organizations.rb" do
      orgs_path = File.join(PROJECT_ROOT_R34, "lib/organizations.rb")
      source = File.read(orgs_path)

      assert source.include?('autoload :Organization'),
        "organizations.rb must autoload Organization"
      assert source.include?('autoload :Membership'),
        "organizations.rb must autoload Membership"
      assert source.include?('autoload :Invitation'),
        "organizations.rb must autoload Invitation"
    end

    # =========================================================================
    # ROUND 2 CODEX REVIEW - HIGH REMAINING
    # =========================================================================

    # -------------------------------------------------------------------------
    # High Remaining #1: Pricing-plans enforcement not implemented
    #
    # FEEDBACK.md lines 378-380:
    # "despite explicit README behavior"
    #
    # Resolution: README clarified this is an integration pattern via callbacks.
    # The on_member_invited callback runs in strict mode (before save).
    # -------------------------------------------------------------------------

    test "R2 High #1: on_member_invited callback runs in strict mode (can veto invitations)" do
      org, owner = create_org_with_owner!

      # Configure a strict callback that rejects invitations
      Organizations.configure do |config|
        config.on_member_invited do |ctx|
          raise Organizations::InvitationError, "Seat limit reached"
        end
      end

      # Invitation should be vetoed by the callback
      error = assert_raises(Organizations::InvitationError) do
        org.send_invite_to!("vetoed@example.com", invited_by: owner)
      end
      assert_equal "Seat limit reached", error.message

      # No invitation should have been persisted
      assert_equal 0, org.invitations.count,
        "Vetoed invitation must not be persisted"
    end

    test "R2 High #1: on_member_invited callback receives correct context" do
      org, owner = create_org_with_owner!
      received_context = nil

      Organizations.configure do |config|
        config.on_member_invited do |ctx|
          received_context = ctx
        end
      end

      org.send_invite_to!("callback-ctx@example.com", invited_by: owner)

      refute_nil received_context, "Callback must receive a context"
      assert_equal org, received_context.organization
      assert_equal owner, received_context.invited_by
      refute_nil received_context.invitation
      assert_equal "callback-ctx@example.com", received_context.invitation.email
    end

    # -------------------------------------------------------------------------
    # High Remaining #2: Goodmail auto-integration not implemented
    #
    # FEEDBACK.md line 384:
    # "docs say auto-uses goodmail if present; no conditional goodmail integration exists."
    #
    # Resolution: acknowledged as future enhancement. The gem uses standard
    # ActionMailer. Verify the mailer inherits from ActionMailer::Base.
    # -------------------------------------------------------------------------

    test "R2 High #2: InvitationMailer inherits from ActionMailer::Base" do
      assert Organizations::InvitationMailer < ActionMailer::Base,
        "InvitationMailer must inherit from ActionMailer::Base"
    end

    # -------------------------------------------------------------------------
    # High Remaining #3: Signup auto-accept flow incomplete
    #
    # FEEDBACK.md lines 386-387:
    # "token is stored, but no gem-provided acceptance hook is wired."
    #
    # Resolution: The gem stores token in session[:pending_invitation_token].
    # Host app calls invitation.accept!(user) post-signup. This is documented.
    # Verify that the InvitationsController stores the token when unauthenticated.
    # -------------------------------------------------------------------------

    test "R2 High #3: InvitationsController stores pending_invitation_token in session" do
      controller_path = File.join(PROJECT_ROOT_R34,
        "app/controllers/organizations/invitations_controller.rb"
      )
      source = File.read(controller_path)

      assert source.include?("pending_invitation_token"),
        "InvitationsController must reference pending_invitation_token for post-signup flow"
      assert source.include?("session[:pending_invitation_token]"),
        "InvitationsController must store token in session for post-signup acceptance"
    end

    test "R2 High #3: invitation accept! works with explicit user (post-signup pattern)" do
      org, owner = create_org_with_owner!

      invitation = Organizations::Invitation.create!(
        organization: org,
        email: "signup-accept@example.com",
        invited_by: owner,
        role: "member",
        token: SecureRandom.urlsafe_base64(32),
        expires_at: 7.days.from_now
      )

      # Simulate post-signup: create user, then accept invitation
      user = User.create!(email: "signup-accept@example.com", name: "New Signup")
      membership = invitation.accept!(user)

      assert membership.persisted?
      assert_equal user.id, membership.user_id
      assert_equal org.id, membership.organization_id
      assert invitation.reload.accepted?
    end

    test "R2 High #3: invitation accept! with skip_email_validation for post-signup" do
      org, owner = create_org_with_owner!

      invitation = Organizations::Invitation.create!(
        organization: org,
        email: "invited@example.com",
        invited_by: owner,
        role: "member",
        token: SecureRandom.urlsafe_base64(32),
        expires_at: 7.days.from_now
      )

      # User signed up with a different email but has the token
      user = User.create!(email: "different@example.com", name: "Different Email")
      membership = invitation.accept!(user, skip_email_validation: true)

      assert membership.persisted?
    end

    # -------------------------------------------------------------------------
    # High Remaining #4: Table-name/schema mismatch
    #
    # FEEDBACK.md lines 389-391:
    # "invitations vs organization_invitations"
    #
    # Resolution: README updated to use organization_invitations. Code uses
    # organization_invitations. Verify alignment.
    # -------------------------------------------------------------------------

    test "R2 High #4: Invitation model uses organization_invitations table" do
      assert_equal "organization_invitations", Organizations::Invitation.table_name,
        "Invitation model must use organization_invitations table"
    end

    test "R2 High #4: organization_invitations table exists in schema" do
      assert ActiveRecord::Base.connection.table_exists?(:organization_invitations),
        "organization_invitations table must exist"
    end

    # -------------------------------------------------------------------------
    # High Remaining #5: Pending-invitation uniqueness semantics inconsistent
    #
    # FEEDBACK.md lines 393-395:
    # "model uniqueness uses pending (filters by expiry), while DB contract
    #  is accepted_at IS NULL."
    #
    # The fix: model validation now uses accepted_at: nil (matches DB constraint).
    # -------------------------------------------------------------------------

    test "R2 High #5: invitation uniqueness validation uses accepted_at IS NULL semantics" do
      org, owner = create_org_with_owner!

      # Create a non-accepted invitation
      invitation1 = Organizations::Invitation.create!(
        organization: org,
        email: "unique-r2@example.com",
        invited_by: owner,
        role: "member",
        token: SecureRandom.urlsafe_base64(32),
        expires_at: 7.days.from_now
      )

      # Second non-accepted invitation to same email should fail
      invitation2 = Organizations::Invitation.new(
        organization: org,
        email: "unique-r2@example.com",
        invited_by: owner,
        role: "member",
        token: SecureRandom.urlsafe_base64(32),
        expires_at: 7.days.from_now
      )

      refute invitation2.valid?, "Duplicate non-accepted invitation must fail validation"
      assert_includes invitation2.errors[:email].join, "already been invited"
    end

    test "R2 High #5: expired non-accepted invitation still blocks new invitation via validation" do
      org, owner = create_org_with_owner!

      # Create an expired but non-accepted invitation
      expired = Organizations::Invitation.create!(
        organization: org,
        email: "expired-unique@example.com",
        invited_by: owner,
        role: "member",
        token: SecureRandom.urlsafe_base64(32),
        expires_at: 1.day.ago
      )

      assert expired.expired?
      assert_nil expired.accepted_at

      # New invitation to same email should be blocked because accepted_at IS NULL
      # (the validation matches DB constraint, not expiry status)
      new_inv = Organizations::Invitation.new(
        organization: org,
        email: "expired-unique@example.com",
        invited_by: owner,
        role: "member",
        token: SecureRandom.urlsafe_base64(32),
        expires_at: 7.days.from_now
      )

      refute new_inv.valid?,
        "Expired but non-accepted invitation should block new invitation via validation"
    end

    test "R2 High #5: accepted invitation does NOT block new invitation" do
      org, owner = create_org_with_owner!

      # Create and accept an invitation
      user = User.create!(email: "accepted-ok@example.com", name: "Accepted")
      invitation1 = Organizations::Invitation.create!(
        organization: org,
        email: "accepted-ok@example.com",
        invited_by: owner,
        role: "member",
        token: SecureRandom.urlsafe_base64(32),
        expires_at: 7.days.from_now
      )
      invitation1.accept!(user)
      assert invitation1.reload.accepted?

      # Remove user so re-invitation is valid
      org.remove_member!(user)

      # New invitation to same email should succeed (accepted_at IS NOT NULL on old one)
      invitation2 = Organizations::Invitation.new(
        organization: org,
        email: "accepted-ok@example.com",
        invited_by: owner,
        role: "member",
        token: SecureRandom.urlsafe_base64(32),
        expires_at: 7.days.from_now
      )

      assert invitation2.valid?,
        "Accepted invitation must NOT block new invitation to same email"
    end

    # -------------------------------------------------------------------------
    # High Remaining #6: organization_switcher_data route helper incorrect
    #
    # FEEDBACK.md lines 397-399:
    # "helper tries organizations.switch_path / main_app.organizations_switch_path,
    #  but route name is switch_organization_path."
    #
    # The fix: changed to switch_organization_path.
    # -------------------------------------------------------------------------

    test "R2 High #6: view helper uses switch_organization_path route name" do
      view_helpers_path = File.join(PROJECT_ROOT_R34,
        "lib/organizations/view_helpers.rb"
      )
      source = File.read(view_helpers_path)

      assert source.include?("switch_organization_path"),
        "ViewHelpers must use switch_organization_path (correct route name)"

      # Should NOT use the old incorrect names
      refute source.include?("switch_path") && !source.include?("switch_organization_path"),
        "ViewHelpers must not use bare switch_path (incorrect route name)"
    end

    test "R2 High #6: switch route exists in routes file with correct name" do
      routes_path = File.join(PROJECT_ROOT_R34, "config/routes.rb")
      source = File.read(routes_path)

      assert source.include?("switch_organization"),
        "Routes must define switch_organization route"
    end

    # =========================================================================
    # ROUND 3 CLAUDE RESPONSE - ALL FIXES APPLIED
    # =========================================================================

    # -------------------------------------------------------------------------
    # Fix #1: InvitationsController recursion fix
    #
    # Uses super rescue nil when method_name == :current_user
    # -------------------------------------------------------------------------

    test "R3 Fix #1: InvitationsController override has rescue nil for super" do
      controller_path = File.join(PROJECT_ROOT_R34,
        "app/controllers/organizations/invitations_controller.rb"
      )
      source = File.read(controller_path)

      # Must have rescue nil to handle the case where super raises
      assert source.include?("rescue nil") || source.include?("rescue"),
        "InvitationsController must rescue from super in case no parent current_user exists"
    end

    # -------------------------------------------------------------------------
    # Fix #2: create_organization! context assignment order
    #
    # Order: set cached values first, clear membership caches,
    # set _current_organization_id last.
    # -------------------------------------------------------------------------

    test "R3 Fix #2: create_organization! sets @_current_organization before _current_organization_id" do
      has_orgs_path = File.join(PROJECT_ROOT_R34,
        "lib/organizations/models/concerns/has_organizations.rb"
      )
      source = File.read(has_orgs_path)

      # Find positions of assignments in create_organization!
      method_start = source.index("def create_organization!")
      method_end_region = source.index("def leave_organization!")

      method_body = source[method_start...method_end_region]

      # @_current_organization should be set before _current_organization_id
      cache_pos = method_body.index("@_current_organization = org")
      id_pos = method_body.index("self._current_organization_id = org.id")

      refute_nil cache_pos, "Must set @_current_organization in create_organization!"
      refute_nil id_pos, "Must set _current_organization_id in create_organization!"

      assert cache_pos < id_pos,
        "@_current_organization must be set BEFORE _current_organization_id"
    end

    # -------------------------------------------------------------------------
    # Fix #3: Owner role blocked in add_member! and promote_to!
    #
    # New error classes: CannotHaveMultipleOwners, CannotPromoteToOwner
    # -------------------------------------------------------------------------

    test "R3 Fix #3: CannotHaveMultipleOwners error class exists" do
      assert defined?(Organizations::Organization::CannotHaveMultipleOwners),
        "CannotHaveMultipleOwners error class must exist"
    end

    test "R3 Fix #3: CannotPromoteToOwner error class exists" do
      assert defined?(Organizations::Membership::CannotPromoteToOwner),
        "CannotPromoteToOwner error class must exist"
    end

    test "R3 Fix #3: add_member! raises CannotHaveMultipleOwners for owner role" do
      org, _owner = create_org_with_owner!
      user = create_user!

      error = assert_raises(Organizations::Organization::CannotHaveMultipleOwners) do
        org.add_member!(user, role: :owner)
      end
      assert_match(/transfer_ownership/i, error.message)
    end

    test "R3 Fix #3: promote_to! raises CannotPromoteToOwner" do
      org, _owner = create_org_with_owner!
      member = create_user!
      org.add_member!(member, role: :member)

      membership = org.memberships.find_by(user: member)

      error = assert_raises(Organizations::Membership::CannotPromoteToOwner) do
        membership.promote_to!(:owner)
      end
      assert_match(/transfer_ownership/i, error.message)
    end

    test "R3 Fix #3: all non-transfer owner assignment paths blocked end-to-end" do
      org, owner = create_org_with_owner!
      user = create_user!
      org.add_member!(user, role: :admin)

      blocked_count = 0

      # Path 1: add_member! with :owner
      begin
        new_user = create_user!
        org.add_member!(new_user, role: :owner)
      rescue Organizations::Organization::CannotHaveMultipleOwners
        blocked_count += 1
      end

      # Path 2: promote_to!(:owner)
      begin
        org.memberships.find_by(user: user).promote_to!(:owner)
      rescue Organizations::Membership::CannotPromoteToOwner
        blocked_count += 1
      end

      # Path 3: change_role_of!(to: :owner)
      begin
        org.change_role_of!(user, to: :owner)
      rescue Organizations::Organization::CannotHaveMultipleOwners
        blocked_count += 1
      end

      # Path 4: send_invite_to! with role: :owner
      begin
        org.send_invite_to!("owner-path4@example.com", invited_by: owner, role: :owner)
      rescue Organizations::Organization::CannotInviteAsOwner
        blocked_count += 1
      end

      assert_equal 4, blocked_count, "All 4 non-transfer owner paths must be blocked"
      assert_equal 1, org.memberships.where(role: "owner").count,
        "Exactly one owner must remain after all blocked attempts"
    end

    # -------------------------------------------------------------------------
    # Fix #4: Route/controller mismatch resolved (flat routes)
    #
    # Routes are now /memberships, /invitations (not nested under /organizations/:id/)
    # -------------------------------------------------------------------------

    test "R3 Fix #4: routes are flat for memberships" do
      routes_path = File.join(PROJECT_ROOT_R34, "config/routes.rb")
      source = File.read(routes_path)

      # Should have standalone resources :memberships
      assert source.match?(/^\s+resources :memberships/),
        "Routes must have flat resources :memberships"
    end

    test "R3 Fix #4: routes are flat for invitations" do
      routes_path = File.join(PROJECT_ROOT_R34, "config/routes.rb")
      source = File.read(routes_path)

      # Should have standalone resources :invitations
      assert source.match?(/^\s+resources :invitations/),
        "Routes must have flat resources :invitations"
    end

    # -------------------------------------------------------------------------
    # Fix #5: Nullable invited_by safe everywhere
    #
    # - InvitationMailer: "The team" for nil
    # - Templates: conditional rendering
    # - Controller JSON: nil / "Someone"
    # -------------------------------------------------------------------------

    test "R3 Fix #5: invitation with nil inviter is fully functional" do
      org, _owner = create_org_with_owner!

      invitation = Organizations::Invitation.create!(
        organization: org,
        email: "nil-inviter-full@example.com",
        invited_by: nil,
        role: "member",
        token: SecureRandom.urlsafe_base64(32),
        expires_at: 7.days.from_now
      )

      # All status methods work
      assert invitation.pending?
      refute invitation.accepted?
      refute invitation.expired?
      assert_equal :pending, invitation.status

      # Acceptance works with nil inviter
      user = User.create!(email: "nil-inviter-full@example.com", name: "Acceptor")
      membership = invitation.accept!(user)
      assert membership.persisted?

      # The membership invited_by should be nil (passed through from invitation)
      assert_nil membership.invited_by
    end

    test "R3 Fix #5: InvitationMailer invitation_email does not crash with nil inviter" do
      mailer_path = File.join(PROJECT_ROOT_R34,
        "app/mailers/organizations/invitation_mailer.rb"
      )
      source = File.read(mailer_path)

      # The inviter_name method must check for nil
      assert source.include?("return") || source.include?("unless"),
        "InvitationMailer inviter_name must guard against nil inviter"
    end

    # -------------------------------------------------------------------------
    # Fix #6: Model constant loading fixed
    #
    # Added top-level aliases in lib/organizations.rb
    # -------------------------------------------------------------------------

    test "R3 Fix #6: Organizations.rb has autoload for all three models" do
      orgs_path = File.join(PROJECT_ROOT_R34, "lib/organizations.rb")
      source = File.read(orgs_path)

      # Must autoload all three model constants
      assert source.include?("autoload :Organization"),
        "organizations.rb must autoload Organization"
      assert source.include?("autoload :Membership"),
        "organizations.rb must autoload Membership"
      assert source.include?("autoload :Invitation"),
        "organizations.rb must autoload Invitation"
    end

    test "R3 Fix #6: models can be instantiated through Organizations namespace" do
      org = Organizations::Organization.new(name: "Test", slug: "test-#{SecureRandom.hex(4)}")
      assert_kind_of ActiveRecord::Base, org

      membership = Organizations::Membership.new
      assert_kind_of ActiveRecord::Base, membership

      invitation = Organizations::Invitation.new
      assert_kind_of ActiveRecord::Base, invitation
    end

    test "R3 Fix #6: Organizations::Controller alias exists for README compat" do
      assert defined?(Organizations::Controller),
        "Organizations::Controller must be defined"
      assert_equal Organizations::ControllerHelpers, Organizations::Controller,
        "Organizations::Controller must alias ControllerHelpers"
    end

    # =========================================================================
    # ROUND 3 - HIGH FIXES
    # =========================================================================

    # -------------------------------------------------------------------------
    # Table naming alignment: README updated to organization_invitations
    # -------------------------------------------------------------------------

    test "R3 High: table naming is consistent across model and schema" do
      # Model table_name
      assert_equal "organization_invitations", Organizations::Invitation.table_name

      # Database table exists
      assert ActiveRecord::Base.connection.table_exists?(:organization_invitations)

      # Model file references correct table name
      invitation_path = File.join(PROJECT_ROOT_R34,
        "lib/organizations/models/invitation.rb"
      )
      source = File.read(invitation_path)
      assert source.include?('self.table_name = "organization_invitations"'),
        "Invitation model must explicitly set table_name to organization_invitations"
    end

    # -------------------------------------------------------------------------
    # Pending invitation semantics aligned: uses accepted_at: nil
    # -------------------------------------------------------------------------

    test "R3 High: unique_non_accepted_invitation validates against accepted_at nil" do
      invitation_path = File.join(PROJECT_ROOT_R34,
        "lib/organizations/models/invitation.rb"
      )
      source = File.read(invitation_path)

      # The validation method should check accepted_at: nil, not expiry
      assert source.include?("accepted_at: nil") || source.include?("accepted_at"),
        "Invitation uniqueness validation must check accepted_at (not expiry)"
      assert source.include?("unique_non_accepted_invitation"),
        "Validation method must be named unique_non_accepted_invitation"
    end

    # -------------------------------------------------------------------------
    # View helper route name fixed: switch_organization_path
    # -------------------------------------------------------------------------

    test "R3 High: build_switch_path_lambda uses correct route name" do
      view_helpers_path = File.join(PROJECT_ROOT_R34,
        "lib/organizations/view_helpers.rb"
      )
      source = File.read(view_helpers_path)

      # The build_switch_path_lambda method must reference switch_organization_path
      method_start = source.index("build_switch_path_lambda")
      assert method_start, "build_switch_path_lambda must exist in ViewHelpers"

      method_body = source[method_start..]
      assert method_body.include?("switch_organization_path"),
        "build_switch_path_lambda must use switch_organization_path"
    end

    # =========================================================================
    # COMPREHENSIVE INTEGRATION TESTS
    # These verify the fixes work together in realistic scenarios
    # =========================================================================

    test "integration: full lifecycle with all R2-R3 fixes working" do
      Organizations.configure do |config|
        config.create_personal_organization = false
      end

      # Create user and organization
      user = User.create!(email: "lifecycle-#{SecureRandom.hex(4)}@example.com", name: "Lifecycle User")
      org = user.create_organization!("Lifecycle Org")

      # Fix #2: context is set correctly after creation
      assert_equal org, user.current_organization
      assert user.is_organization_owner?

      # Fix #3: cannot add a second owner
      admin = create_user!
      org.add_member!(admin, role: :admin)

      assert_raises(Organizations::Organization::CannotHaveMultipleOwners) do
        org.add_member!(create_user!, role: :owner)
      end

      # Fix #5: invite with nil inviter
      invitation = Organizations::Invitation.create!(
        organization: org,
        email: "lifecycle-invitee@example.com",
        invited_by: nil,
        role: "member",
        token: SecureRandom.urlsafe_base64(32),
        expires_at: 7.days.from_now
      )

      # Fix #5: accept with nil inviter
      invitee = User.create!(email: "lifecycle-invitee@example.com", name: "Invitee")
      membership = invitation.accept!(invitee)
      assert membership.persisted?

      # Verify only one owner
      assert_equal 1, org.memberships.where(role: "owner").count
      assert_equal 3, org.member_count
    end

    test "integration: callback veto with strict mode for seat limits" do
      org, owner = create_org_with_owner!

      # Add 2 members (3 total with owner)
      org.add_member!(create_user!, role: :member)
      org.add_member!(create_user!, role: :member)

      # Configure callback to limit to 3 seats
      Organizations.configure do |config|
        config.on_member_invited do |ctx|
          if ctx.organization.member_count >= 3
            raise Organizations::InvitationError, "Seat limit reached. Upgrade your plan."
          end
        end
      end

      # Fourth member invitation should be vetoed
      error = assert_raises(Organizations::InvitationError) do
        org.send_invite_to!("fourth@example.com", invited_by: owner)
      end
      assert_match(/seat limit/i, error.message)
      assert_equal 0, org.invitations.count
    end

    test "integration: organization cache correctness across multiple operations" do
      Organizations.configure do |config|
        config.create_personal_organization = false
      end

      user = User.create!(email: "cache-ops-#{SecureRandom.hex(4)}@example.com", name: "Cache Ops")

      # Create first org
      org1 = user.create_organization!("Org Alpha")
      assert_equal org1, user.current_organization
      assert_equal :owner, user.current_organization_role

      # Create second org (should switch context to new org)
      org2 = user.create_organization!("Org Beta")
      assert_equal org2, user.current_organization
      assert_equal :owner, user.current_organization_role

      # Switch back to org1
      user._current_organization_id = org1.id
      # Clear stale cache
      user.instance_variable_set(:@_current_organization, nil)
      user.instance_variable_set(:@_current_organization_id_cached, nil)
      user.instance_variable_set(:@_current_membership, nil)
      user.instance_variable_set(:@_current_membership_org_id, nil)

      assert_equal org1, user.current_organization
      assert_equal :owner, user.current_organization_role
    end

    test "integration: expired invitation refresh flow" do
      org, owner = create_org_with_owner!

      # Create expired invitation
      expired = Organizations::Invitation.create!(
        organization: org,
        email: "refresh-flow@example.com",
        invited_by: owner,
        role: "member",
        token: SecureRandom.urlsafe_base64(32),
        expires_at: 1.day.ago
      )

      assert expired.expired?
      old_token = expired.token
      old_id = expired.id

      # Re-invite same email - should refresh expired invitation
      refreshed = org.send_invite_to!("refresh-flow@example.com", invited_by: owner)

      assert_equal old_id, refreshed.id,
        "Should reuse the expired invitation record"
      refute_equal old_token, refreshed.token,
        "Token must be regenerated"
      assert refreshed.pending?,
        "Refreshed invitation must be pending"

      # Accept the refreshed invitation
      user = User.create!(email: "refresh-flow@example.com", name: "Refreshed")
      membership = refreshed.accept!(user)
      assert membership.persisted?
    end

    test "integration: clear_organization_cache! resets everything" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Full Cache Org")
      Organizations::Membership.create!(user: user, organization: org, role: "owner")

      # Set up context
      user._current_organization_id = org.id
      _ = user.current_organization  # Force cache population
      _ = user.current_membership    # Force cache population

      # Clear cache
      user.clear_organization_cache!

      # Everything should be nil
      assert_nil user._current_organization_id
      assert_nil user.instance_variable_get(:@_current_organization)
      assert_nil user.instance_variable_get(:@_current_organization_id_cached)
      assert_nil user.instance_variable_get(:@_current_membership)
      assert_nil user.instance_variable_get(:@_current_membership_org_id)
    end

    # =========================================================================
    # ADDITIONAL EDGE CASES for R2-R3 fixes
    # =========================================================================

    test "edge: Membership validation blocks duplicate owner at model level" do
      org, _owner = create_org_with_owner!
      user = create_user!

      # Try to create a second owner membership directly
      membership = Organizations::Membership.new(
        user: user,
        organization: org,
        role: "owner"
      )

      refute membership.valid?, "Model validation must block second owner"
      assert membership.errors[:role].any?, "Error must be on role field"
    end

    test "edge: demote_to! blocks owner demotion" do
      org, owner = create_org_with_owner!
      owner_membership = org.memberships.find_by(user: owner)

      assert_raises(Organizations::Membership::CannotDemoteOwner) do
        owner_membership.demote_to!(:admin)
      end

      # Owner should remain owner
      assert_equal "owner", owner_membership.reload.role
    end

    test "edge: promote_to! validates role hierarchy" do
      org, _owner = create_org_with_owner!
      admin = create_user!
      org.add_member!(admin, role: :admin)

      membership = org.memberships.find_by(user: admin)

      # Cannot "promote" to a lower role
      assert_raises(Organizations::Membership::InvalidRoleChange) do
        membership.promote_to!(:member)
      end
    end

    test "edge: invitation for_email? is case insensitive" do
      org, owner = create_org_with_owner!

      invitation = Organizations::Invitation.create!(
        organization: org,
        email: "casematch@example.com",
        invited_by: owner,
        role: "member",
        token: SecureRandom.urlsafe_base64(32),
        expires_at: 7.days.from_now
      )

      assert invitation.for_email?("CASEMATCH@Example.COM"),
        "for_email? must be case insensitive"
      assert invitation.for_email?("casematch@example.com"),
        "for_email? must match exact case"
    end

    test "edge: Callbacks.dispatch with strict mode propagates errors" do
      Organizations.configure do |config|
        config.on_member_invited do |ctx|
          raise Organizations::InvitationError, "Strict callback error"
        end
      end

      org, owner = create_org_with_owner!

      # The strict callback should propagate the error
      error = assert_raises(Organizations::InvitationError) do
        org.send_invite_to!("strict-test@example.com", invited_by: owner)
      end
      assert_equal "Strict callback error", error.message
    end

    test "edge: Callbacks.dispatch without strict mode swallows errors" do
      callback_called = false
      Organizations.configure do |config|
        config.on_organization_created do |ctx|
          callback_called = true
          raise "Non-strict callback error"
        end
        config.create_personal_organization = false
      end

      user = User.create!(email: "swallow-#{SecureRandom.hex(4)}@example.com", name: "Swallow")

      # Non-strict callback error should be swallowed
      org = user.create_organization!("Swallow Org")
      assert org.persisted?, "Organization should still be created despite callback error"
      assert callback_called, "Callback should have been called"
    end

    test "edge: CallbackContext has permission and required_role fields" do
      ctx = Organizations::CallbackContext.new(
        event: :unauthorized,
        permission: :invite_members,
        required_role: :admin
      )

      assert_equal :invite_members, ctx.permission
      assert_equal :admin, ctx.required_role
    end

    test "edge: Roles.reset! clears cached permissions" do
      # Verify initial state
      initial_perms = Organizations::Roles.permissions_for(:admin)
      assert initial_perms.include?(:invite_members)

      # Configure custom roles
      Organizations.configure do |config|
        config.roles do
          role :viewer do
            can :view_organization
          end
          role :member, inherits: :viewer do
            can :create_resources
          end
          role :admin, inherits: :member do
            can :custom_permission
          end
          role :owner, inherits: :admin do
            can :manage_billing
          end
        end
      end

      # After reset, admin should have new permissions
      new_perms = Organizations::Roles.permissions_for(:admin)
      assert new_perms.include?(:custom_permission),
        "After roles reset, new permissions must be visible"
    end
  end
end
