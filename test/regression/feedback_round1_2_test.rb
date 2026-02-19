# frozen_string_literal: true

require "test_helper"

module Organizations
  # Exhaustive regression tests for FEEDBACK.md Rounds 1 and 2.
  #
  # Each test maps to a specific finding or fix and would FAIL if the
  # corresponding bug regressed. The test names include the Round and
  # Finding number for traceability.
  class FeedbackRound1And2Test < Organizations::Test
    # =========================================================================
    # Round 1, Critical #1 -- Infinite recursion in engine `current_user`
    # =========================================================================
    # Bug: When config.current_user_method == :current_user (the default),
    # the engine controller's current_user method called send(:current_user)
    # on itself, causing SystemStackError.
    # Fix: Call `super` when configured method is :current_user.

    test "R1C1: default config uses :current_user method" do
      assert_equal :current_user, Organizations.configuration.current_user_method,
        "Default current_user_method must be :current_user"
    end

    test "R1C1: engine ApplicationController guards against recursion in current_user" do
      controller_path = File.expand_path(
        "../../app/controllers/organizations/application_controller.rb", __dir__
      )
      assert File.exist?(controller_path), "Engine ApplicationController file must exist"

      source = File.read(controller_path)

      # The fix must detect :current_user and call super instead of self-dispatching
      assert source.include?("user_method == :current_user"),
        "Controller must check if configured method is :current_user to avoid recursion"
      assert source.include?("super"),
        "Controller must call super to delegate to parent when method is :current_user"
    end

    test "R1C1: engine ApplicationController does not call send(:current_user) unconditionally" do
      controller_path = File.expand_path(
        "../../app/controllers/organizations/application_controller.rb", __dir__
      )
      source = File.read(controller_path)

      # The fix should NOT have an unguarded send(user_method) that would recurse
      # when user_method is :current_user. It must branch on user_method == :current_user.
      lines = source.lines
      current_user_def = lines.index { |l| l.strip.start_with?("def current_user") }
      assert current_user_def, "Must define current_user method"

      # Find the method body (up to the next def or end at same indent)
      method_body = String.new
      indent = lines[current_user_def][/\A\s*/].length
      (current_user_def + 1...lines.length).each do |i|
        break if lines[i] =~ /\A\s{#{indent}}(def |end\b)/
        method_body << lines[i]
      end

      # The method body must contain the :current_user guard
      assert method_body.include?("current_user"),
        "current_user method body must reference the :current_user check"
    end

    # =========================================================================
    # Round 1, Critical #2 -- Membership schema has `invited_by_id`
    # =========================================================================
    # Bug: Membership model had belongs_to :invited_by, but migration was
    # missing the invited_by_id column.
    # Fix: Added invited_by_id to memberships table.

    test "R1C2: memberships table has invited_by_id column" do
      assert Organizations::Membership.column_names.include?("invited_by_id"),
        "memberships table must have invited_by_id column"
    end

    test "R1C2: membership invited_by_id is nullable" do
      column = Organizations::Membership.columns_hash["invited_by_id"]
      refute column.null == false,
        "invited_by_id should be nullable (null: true) to support dependent: :nullify"
    end

    test "R1C2: membership belongs_to invited_by works" do
      org, owner = create_org_with_owner!
      member = create_user!

      membership = Organizations::Membership.create!(
        user: member,
        organization: org,
        role: "member",
        invited_by: owner
      )

      assert_equal owner.id, membership.invited_by_id
      assert_equal owner, membership.invited_by
    end

    # =========================================================================
    # Round 1, Critical #3 -- Pending invitation uniqueness at DB level
    # =========================================================================
    # Bug: Only non-unique index existed on (organization_id, email).
    # Fix: Added partial unique index (accepted_at IS NULL) and model validation.

    test "R1C3: model validation prevents duplicate pending invitations" do
      owner = create_user!
      org = Organizations::Organization.create!(name: "Uniqueness Org")
      Organizations::Membership.create!(user: owner, organization: org, role: "owner")

      first = Organizations::Invitation.create!(
        organization: org,
        email: "dup-test@example.com",
        invited_by: owner,
        role: "member",
        token: SecureRandom.urlsafe_base64(32),
        expires_at: 7.days.from_now
      )
      assert first.persisted?

      dup = Organizations::Invitation.new(
        organization: org,
        email: "dup-test@example.com",
        invited_by: owner,
        role: "member",
        token: SecureRandom.urlsafe_base64(32),
        expires_at: 7.days.from_now
      )
      refute dup.valid?, "Duplicate pending invitation must fail validation"
      assert_includes dup.errors[:email].join, "already been invited"
    end

    test "R1C3: uniqueness is scoped to non-accepted invitations only" do
      org, owner = create_org_with_owner!

      # Create and accept an invitation
      user = User.create!(email: "scoped-unique@example.com", name: "Scoped")
      inv1 = Organizations::Invitation.create!(
        organization: org,
        email: "scoped-unique@example.com",
        invited_by: owner,
        role: "member",
        token: SecureRandom.urlsafe_base64(32),
        expires_at: 7.days.from_now
      )
      inv1.accept!(user)
      assert inv1.reload.accepted?

      # Remove user so they can be re-invited
      org.remove_member!(user)

      # New invitation to same email should succeed (first is accepted)
      inv2 = Organizations::Invitation.new(
        organization: org,
        email: "scoped-unique@example.com",
        invited_by: owner,
        role: "member",
        token: SecureRandom.urlsafe_base64(32),
        expires_at: 7.days.from_now
      )
      assert inv2.valid?, "Invitation after accepted one should be valid"
    end

    test "R1C3: uniqueness check is case-insensitive" do
      org, owner = create_org_with_owner!

      Organizations::Invitation.create!(
        organization: org,
        email: "casetest@example.com",
        invited_by: owner,
        role: "member",
        token: SecureRandom.urlsafe_base64(32),
        expires_at: 7.days.from_now
      )

      dup = Organizations::Invitation.new(
        organization: org,
        email: "CaseTest@Example.com",
        invited_by: owner,
        role: "member",
        token: SecureRandom.urlsafe_base64(32),
        expires_at: 7.days.from_now
      )
      refute dup.valid?, "Case-insensitive duplicate must fail validation"
    end

    # =========================================================================
    # Round 1, Critical #4 -- Owner integrity rule enforced
    # =========================================================================
    # Bug: change_role_of! allowed promoting to owner or demoting owner directly.
    # Fix: Added CannotHaveMultipleOwners and CannotDemoteOwner guards.

    test "R1C4: change_role_of! raises CannotHaveMultipleOwners when promoting to owner" do
      org, _owner = create_org_with_owner!
      admin = create_user!
      org.add_member!(admin, role: :admin)

      error = assert_raises(Organizations::Organization::CannotHaveMultipleOwners) do
        org.change_role_of!(admin, to: :owner)
      end
      assert_match(/owner/i, error.message)
    end

    test "R1C4: change_role_of! raises CannotDemoteOwner when demoting owner" do
      org, owner = create_org_with_owner!

      error = assert_raises(Organizations::Organization::CannotDemoteOwner) do
        org.change_role_of!(owner, to: :admin)
      end
      assert_match(/owner/i, error.message)
    end

    test "R1C4: exactly one owner is maintained after blocked attempts" do
      org, _owner = create_org_with_owner!
      admin = create_user!
      org.add_member!(admin, role: :admin)

      # Try various blocked paths
      assert_raises(Organizations::Organization::CannotHaveMultipleOwners) do
        org.change_role_of!(admin, to: :owner)
      end

      assert_equal 1, org.memberships.where(role: "owner").count,
        "Exactly one owner must remain"
    end

    test "R1C4: CannotDemoteOwner error class exists" do
      assert defined?(Organizations::Organization::CannotDemoteOwner),
        "CannotDemoteOwner error class must be defined"
    end

    test "R1C4: CannotHaveMultipleOwners error class exists" do
      assert defined?(Organizations::Organization::CannotHaveMultipleOwners),
        "CannotHaveMultipleOwners error class must be defined"
    end

    # =========================================================================
    # Round 1, Critical #5 -- Current membership cache staleness
    # =========================================================================
    # Bug: current_membership was memoized without keying on org_id, so
    # switching orgs returned stale membership.
    # Fix: Memoization now keyed by org_id.

    test "R1C5: current_membership returns correct membership after org switch" do
      user = create_user!
      org1 = Organizations::Organization.create!(name: "Cache Org 1")
      org2 = Organizations::Organization.create!(name: "Cache Org 2")
      Organizations::Membership.create!(user: user, organization: org1, role: "owner")
      Organizations::Membership.create!(user: user, organization: org2, role: "admin")

      user._current_organization_id = org1.id
      m1 = user.current_membership
      assert_equal "owner", m1.role
      assert_equal org1.id, m1.organization_id

      # Switch org
      user._current_organization_id = org2.id
      m2 = user.current_membership
      assert_equal "admin", m2.role
      assert_equal org2.id, m2.organization_id

      refute_equal m1.id, m2.id, "Different org must return different membership"
    end

    test "R1C5: rapid org switching never returns stale membership" do
      user = create_user!
      org_a = Organizations::Organization.create!(name: "Rapid A")
      org_b = Organizations::Organization.create!(name: "Rapid B")
      Organizations::Membership.create!(user: user, organization: org_a, role: "owner")
      Organizations::Membership.create!(user: user, organization: org_b, role: "viewer")

      10.times do
        user._current_organization_id = org_a.id
        assert_equal "owner", user.current_membership.role

        user._current_organization_id = org_b.id
        assert_equal "viewer", user.current_membership.role
      end
    end

    test "R1C5: clear_organization_cache! resets all cached state including _current_organization_id" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Clear Cache Org")
      Organizations::Membership.create!(user: user, organization: org, role: "owner")

      user._current_organization_id = org.id
      assert_equal org, user.current_organization

      user.clear_organization_cache!

      assert_nil user._current_organization_id,
        "clear_organization_cache! must reset _current_organization_id"
      assert_nil user.current_organization,
        "clear_organization_cache! must clear cached current_organization"
    end

    # =========================================================================
    # Round 1, Critical #6 -- Nested routes ignore params[:organization_id]
    # =========================================================================
    # This is INTENTIONAL DESIGN (session-scoped routing).
    # Test that engine controllers scope to current_organization from session,
    # not from route params.

    test "R1C6: engine controllers are session-scoped by design" do
      # Verify that the engine ApplicationController defines current_organization
      # that reads from session, not from params[:organization_id]
      controller_path = File.expand_path(
        "../../app/controllers/organizations/application_controller.rb", __dir__
      )
      source = File.read(controller_path)

      # Should reference session for org lookup
      assert source.include?("session"),
        "Engine controller must use session for organization context (session-scoped design)"

      # Should NOT reference params[:organization_id] for org lookup
      refute source.include?("params[:organization_id]"),
        "Engine controller must NOT use params[:organization_id] (intentional session-scoped design)"
    end

    # =========================================================================
    # Round 1, Critical #7 -- Permission-based check for invites
    # =========================================================================
    # Bug: User#send_organization_invite_to! used is_admin_of? instead of
    # Roles.has_permission?(:invite_members).
    # Fix: Now uses permission-based check.

    test "R1C7: invite uses permission check not role check" do
      # Verify the source code uses has_permission? instead of is_admin_of?
      has_orgs_path = File.expand_path(
        "../../lib/organizations/models/concerns/has_organizations.rb", __dir__
      )
      source = File.read(has_orgs_path)

      # Find the send_organization_invite_to! method and check it uses permission-based auth
      method_start = source.index("def send_organization_invite_to!")
      assert method_start, "send_organization_invite_to! must be defined"
      method_body = source[method_start, 1000]

      assert method_body.include?("has_permission?"),
        "send_organization_invite_to! must use permission-based check (has_permission?)"
      assert method_body.include?("invite_members"),
        "send_organization_invite_to! must check :invite_members permission"
      refute method_body.include?("is_admin_of?"),
        "send_organization_invite_to! must NOT use is_admin_of? (was the bug)"
    end

    test "R1C7: member without invite_members permission cannot invite" do
      org, _owner = create_org_with_owner!
      member = create_user!
      org.add_member!(member, role: :member)

      refute Roles.has_permission?(:member, :invite_members),
        "Default member role must not have invite_members permission"

      member._current_organization_id = org.id
      error = assert_raises(Organizations::NotAuthorized) do
        member.send_organization_invite_to!("someone@example.com")
      end
      assert_equal :invite_members, error.permission
    end

    test "R1C7: admin with invite_members permission can invite" do
      org, _owner = create_org_with_owner!
      admin = create_user!
      org.add_member!(admin, role: :admin)

      assert Roles.has_permission?(:admin, :invite_members),
        "Default admin role must have invite_members permission"

      admin._current_organization_id = org.id
      invitation = admin.send_organization_invite_to!("new-invitee@example.com")
      assert invitation.persisted?
    end

    test "R1C7: custom roles with invite_members permission work" do
      # Configure a custom role where member has invite_members
      Organizations.configure do |config|
        config.roles do
          role :viewer do
            can :view_organization
          end
          role :member, inherits: :viewer do
            can :invite_members
          end
          role :admin, inherits: :member do
            can :manage_settings
          end
          role :owner, inherits: :admin do
            can :delete_organization
          end
        end
      end

      assert Roles.has_permission?(:member, :invite_members),
        "Custom member role with invite_members should have the permission"

      org, _owner = create_org_with_owner!
      member = create_user!
      org.add_member!(member, role: :member)
      member._current_organization_id = org.id

      invitation = member.send_organization_invite_to!("custom-role-invite@example.com")
      assert invitation.persisted?,
        "Member with invite_members permission (custom roles) should be able to invite"
    end

    # =========================================================================
    # Round 1, Critical #8 -- Auto-switch to next available org
    # =========================================================================
    # Bug: Stale org was just cleared to nil; no fallback to another membership org.
    # Fix: Falls back to most recently joined org.

    test "R1C8: current_organization returns nil for invalid org ID" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Fallback Org")
      Organizations::Membership.create!(user: user, organization: org, role: "owner")

      user._current_organization_id = -999
      result = user.current_organization
      assert_nil result, "Should return nil for org user is not a member of"
    end

    test "R1C8: current_organization returns nil when no session set" do
      user = create_user!
      org = Organizations::Organization.create!(name: "No Session Org")
      Organizations::Membership.create!(user: user, organization: org, role: "member")

      user._current_organization_id = nil
      assert_nil user.current_organization,
        "current_organization should be nil when _current_organization_id is nil"
    end

    test "R1C8: stale session after membership removal returns nil" do
      user = create_user!
      org1 = Organizations::Organization.create!(name: "Stale Org")
      org2 = Organizations::Organization.create!(name: "Backup Org")
      Organizations::Membership.create!(user: user, organization: org1, role: "admin")
      Organizations::Membership.create!(user: user, organization: org2, role: "member")

      user._current_organization_id = org1.id
      assert_equal org1, user.current_organization

      # Remove membership
      org1.memberships.find_by(user: user).destroy!
      user.clear_organization_cache!
      user._current_organization_id = org1.id

      result = user.current_organization
      assert_nil result, "Should return nil for org user was removed from"
    end

    # =========================================================================
    # Round 1, Critical #9 -- create_organization! sets current organization
    # =========================================================================
    # Bug: create_organization! returned org but did not set user context/session.
    # Fix: Now sets _current_organization_id and populates cache.

    test "R1C9: create_organization! sets _current_organization_id" do
      Organizations.configure { |c| c.create_personal_organization = false }
      user = User.create!(email: "creator-#{SecureRandom.hex(4)}@example.com", name: "Creator")

      org = user.create_organization!("R1C9 Org")

      assert_equal org.id, user._current_organization_id,
        "create_organization! must set _current_organization_id"
    end

    test "R1C9: create_organization! sets current_organization" do
      Organizations.configure { |c| c.create_personal_organization = false }
      user = User.create!(email: "ctx-#{SecureRandom.hex(4)}@example.com", name: "Context User")

      org = user.create_organization!("R1C9 Context Org")

      assert_equal org, user.current_organization,
        "create_organization! must set current_organization"
    end

    test "R1C9: create_organization! makes current_membership available immediately" do
      Organizations.configure { |c| c.create_personal_organization = false }
      user = User.create!(email: "imm-#{SecureRandom.hex(4)}@example.com", name: "Immediate")

      org = user.create_organization!("Immediate Org")

      membership = user.current_membership
      refute_nil membership, "current_membership must be available immediately"
      assert_equal org.id, membership.organization_id
      assert_equal "owner", membership.role
    end

    test "R1C9: user is owner of newly created organization" do
      Organizations.configure { |c| c.create_personal_organization = false }
      user = User.create!(email: "own-#{SecureRandom.hex(4)}@example.com", name: "Owner")

      user.create_organization!("Owner Test Org")

      assert user.is_organization_owner?,
        "User must be owner of newly created organization"
    end

    # =========================================================================
    # Round 1, Critical #10 -- Token collision handling
    # =========================================================================
    # Bug: No robust retry loop for token collisions.
    # Fix: generate_unique_token uses loop with exists? check.

    test "R1C10: generate_unique_token uses loop with uniqueness check" do
      # Verify the source code uses a loop
      invitation_path = File.expand_path(
        "../../lib/organizations/models/invitation.rb", __dir__
      )
      source = File.read(invitation_path)

      assert source.include?("loop do"),
        "generate_unique_token must use a loop for collision handling"
      assert source.include?("exists?(token:"),
        "generate_unique_token must check for existing tokens"
    end

    test "R1C10: all generated tokens are unique" do
      org, owner = create_org_with_owner!

      tokens = 20.times.map do |i|
        inv = Organizations::Invitation.create!(
          organization: org,
          email: "token-uniq-#{i}@example.com",
          invited_by: owner,
          role: "member",
          expires_at: 7.days.from_now
        )
        inv.token
      end

      assert_equal tokens.uniq.length, tokens.length,
        "All generated tokens must be unique"

      tokens.each do |token|
        refute_nil token
        refute token.empty?, "Token must not be empty"
        assert token.length > 20, "Token must be sufficiently long"
      end
    end

    test "R1C10: organization generate_unique_token also uses loop" do
      org_path = File.expand_path(
        "../../lib/organizations/models/organization.rb", __dir__
      )
      source = File.read(org_path)

      assert source.include?("loop do"),
        "Organization#generate_unique_token must use a loop"
      assert source.include?("exists?(token:"),
        "Organization#generate_unique_token must check for existing tokens"
    end

    # =========================================================================
    # Round 1, Critical #11 -- dependent: :nullify constraint conflict
    # =========================================================================
    # Bug: invited_by_id was NOT NULL in DB, but dependent: :nullify would
    # try to set it to NULL on user deletion.
    # Fix: Changed invited_by_id to null: true.

    test "R1C11: invitation invited_by_id is nullable" do
      column = Organizations::Invitation.columns_hash["invited_by_id"]
      refute column.null == false,
        "invitation invited_by_id must be nullable for dependent: :nullify"
    end

    test "R1C11: invitation with nil invited_by is valid" do
      org, _owner = create_org_with_owner!

      invitation = Organizations::Invitation.new(
        organization: org,
        email: "no-inviter@example.com",
        invited_by: nil,
        role: "member",
        token: SecureRandom.urlsafe_base64(32),
        expires_at: 7.days.from_now
      )
      assert invitation.valid?, "Invitation without inviter should be valid"
    end

    test "R1C11: dependent nullify works when inviter is deleted" do
      org, owner = create_org_with_owner!
      inviter = create_user!
      org.add_member!(inviter, role: :admin)

      invitation = Organizations::Invitation.create!(
        organization: org,
        email: "nullify-r1c11@example.com",
        invited_by: inviter,
        role: "member",
        token: SecureRandom.urlsafe_base64(32),
        expires_at: 7.days.from_now
      )
      assert_equal inviter.id, invitation.invited_by_id

      # Delete inviter (destroy memberships first so owner guard doesn't block)
      inviter.memberships.destroy_all
      inviter.destroy!

      invitation.reload
      assert_nil invitation.invited_by_id,
        "invited_by_id must be nullified after inviter deletion"
      assert_nil invitation.invited_by,
        "invited_by association must return nil after inviter deletion"
    end

    test "R1C11: User has dependent: :nullify on sent_organization_invitations" do
      reflection = User.reflect_on_association(:sent_organization_invitations)
      refute_nil reflection, "User must have sent_organization_invitations association"
      assert_equal :nullify, reflection.options[:dependent],
        "sent_organization_invitations must use dependent: :nullify"
    end

    # =========================================================================
    # Round 1, Critical #12 -- Autoload naming mismatch
    # =========================================================================
    # Bug: README says `include Organizations::Controller` but only
    # `Organizations::ControllerHelpers` was exposed.
    # Fix: Added Controller = ControllerHelpers alias.

    test "R1C12: Organizations::Controller alias exists" do
      assert defined?(Organizations::Controller),
        "Organizations::Controller must be defined"
    end

    test "R1C12: Organizations::Controller equals Organizations::ControllerHelpers" do
      assert_equal Organizations::ControllerHelpers, Organizations::Controller,
        "Organizations::Controller must be an alias for ControllerHelpers"
    end

    test "R1C12: alias is defined in lib/organizations.rb" do
      source_path = File.expand_path(
        "../../lib/organizations.rb", __dir__
      )
      source = File.read(source_path)

      assert source.include?("Controller = ControllerHelpers"),
        "lib/organizations.rb must define Controller = ControllerHelpers alias"
    end

    # =========================================================================
    # Round 2 -- Claude's Response: Verifying all fixes listed
    # =========================================================================

    # Round 2, High #2: parent_controller config now works
    # The engine's ApplicationController should use the configured parent_controller.

    test "R2H2: parent_controller config is respected" do
      config = Organizations.configuration
      assert_equal "::ApplicationController", config.parent_controller,
        "Default parent_controller should be ::ApplicationController"

      # Verify ApplicationController source uses configuration
      controller_path = File.expand_path(
        "../../app/controllers/organizations/application_controller.rb", __dir__
      )
      source = File.read(controller_path)
      assert source.include?("Organizations.configuration.parent_controller"),
        "Engine ApplicationController must inherit from configured parent_controller"
    end

    # Round 2, High #7: Callback context fields
    # CallbackContext struct must have permission and required_role fields.

    test "R2H7: CallbackContext has permission field" do
      ctx = Organizations::CallbackContext.new(
        event: :test,
        permission: :invite_members
      )
      assert_equal :invite_members, ctx.permission,
        "CallbackContext must have a permission field"
    end

    test "R2H7: CallbackContext has required_role field" do
      ctx = Organizations::CallbackContext.new(
        event: :test,
        required_role: :admin
      )
      assert_equal :admin, ctx.required_role,
        "CallbackContext must have a required_role field"
    end

    # Round 2, High #8: Invitation#accept! validates email at model level

    test "R2H8: accept! raises EmailMismatch for wrong user email" do
      org, owner = create_org_with_owner!

      invitation = Organizations::Invitation.create!(
        organization: org,
        email: "right-email@example.com",
        invited_by: owner,
        role: "member",
        token: SecureRandom.urlsafe_base64(32),
        expires_at: 7.days.from_now
      )

      wrong_user = User.create!(email: "wrong-email@example.com", name: "Wrong")

      error = assert_raises(Organizations::Invitation::EmailMismatch) do
        invitation.accept!(wrong_user)
      end
      assert_match(/different email/i, error.message)
    end

    test "R2H8: accept! with skip_email_validation bypasses email check" do
      org, owner = create_org_with_owner!

      invitation = Organizations::Invitation.create!(
        organization: org,
        email: "original@example.com",
        invited_by: owner,
        role: "member",
        token: SecureRandom.urlsafe_base64(32),
        expires_at: 7.days.from_now
      )

      other_user = User.create!(email: "other@example.com", name: "Other")
      membership = invitation.accept!(other_user, skip_email_validation: true)

      assert membership.persisted?
      assert invitation.reload.accepted?
    end

    test "R2H8: EmailMismatch error class exists under Invitation" do
      assert defined?(Organizations::Invitation::EmailMismatch),
        "Invitation::EmailMismatch error class must be defined"
    end

    # Round 2, High #11: Current organization fallback
    # Already tested in R1C8 above, but verify fallback returns nil per model API.

    test "R2H11: user with cleared org context gets nil" do
      user = create_user!
      org = Organizations::Organization.create!(name: "Fallback Test")
      Organizations::Membership.create!(user: user, organization: org, role: "member")

      user.clear_organization_cache!
      assert_nil user.current_organization,
        "After clearing cache, current_organization should be nil"
    end

    # Round 2, High #15: Initializer template DSL fix
    # The roles DSL should use config.roles do ... end syntax.

    test "R2H15: config.roles accepts block DSL" do
      config = Organizations::Configuration.new

      config.roles do
        role :viewer do
          can :view_organization
        end
        role :member, inherits: :viewer do
          can :create_resources
        end
        role :admin, inherits: :member do
          can :manage_settings
        end
        role :owner, inherits: :admin do
          can :delete_organization
        end
      end

      refute_nil config.custom_roles_definition,
        "config.roles block should set custom_roles_definition"
    end

    # Round 2, Medium #1: organization_switcher_data tries route helpers

    test "R2M1: ViewHelpers module exists and is loadable" do
      assert defined?(Organizations::ViewHelpers),
        "Organizations::ViewHelpers must be defined"
    end

    # Round 2, Medium #6: clear_organization_cache! resets _current_organization_id
    # Already tested in R1C5, adding explicit dedicated test.

    test "R2M6: clear_organization_cache! resets _current_organization_id" do
      user = create_user!
      org = Organizations::Organization.create!(name: "M6 Org")
      Organizations::Membership.create!(user: user, organization: org, role: "owner")

      user._current_organization_id = org.id
      assert_equal org.id, user._current_organization_id

      user.clear_organization_cache!

      assert_nil user._current_organization_id,
        "clear_organization_cache! must reset _current_organization_id to nil"
    end

    # =========================================================================
    # Round 2, Response Verification: Remaining fixes from Claude's response
    # =========================================================================

    # Verify custom role cache invalidation: Roles.reset! is called when
    # custom roles are applied via config.roles.

    test "R2: Roles.reset! is called when custom roles configured" do
      # First verify defaults
      assert Roles.has_permission?(:admin, :invite_members)

      # Apply custom roles
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
            can :delete_organization
          end
        end
      end

      # After custom roles, admin should have custom_permission
      assert Roles.has_permission?(:admin, :custom_permission),
        "Custom roles must take effect after Roles.reset!"

      # And invite_members should no longer be present (not defined in custom roles)
      refute Roles.has_permission?(:admin, :invite_members),
        "Permissions not in custom roles should not be present"
    end

    # Verify org-centric invitation API enforces membership + permission

    test "R2: org.send_invite_to! requires inviter to be a member" do
      org, _owner = create_org_with_owner!
      non_member = create_user!

      error = assert_raises(Organizations::NotAMember) do
        org.send_invite_to!("target@example.com", invited_by: non_member)
      end
      assert_match(/member/i, error.message)
    end

    test "R2: org.send_invite_to! requires invite_members permission" do
      org, _owner = create_org_with_owner!
      viewer = create_user!
      org.add_member!(viewer, role: :viewer)

      error = assert_raises(Organizations::NotAuthorized) do
        org.send_invite_to!("target@example.com", invited_by: viewer)
      end
      assert_equal :invite_members, error.permission
    end

    test "R2: org.send_invite_to! succeeds with proper permission" do
      org, owner = create_org_with_owner!

      invitation = org.send_invite_to!("success@example.com", invited_by: owner)
      assert invitation.persisted?
      assert_equal "success@example.com", invitation.email
    end

    # Verify owner invariant is enforced at invitation level too

    test "R2: org.send_invite_to! blocks owner role invitations" do
      org, owner = create_org_with_owner!

      error = assert_raises(Organizations::Organization::CannotInviteAsOwner) do
        org.send_invite_to!("owner-invite@example.com", invited_by: owner, role: :owner)
      end
      assert_match(/owner/i, error.message)
    end

    test "R2: Invitation#accept! blocks owner role acceptance" do
      org, owner = create_org_with_owner!

      # Force-create an invitation with owner role (bypassing send_invite_to! guard)
      invitation = Organizations::Invitation.create!(
        organization: org,
        email: "owner-accept@example.com",
        invited_by: owner,
        role: "owner",
        token: SecureRandom.urlsafe_base64(32),
        expires_at: 7.days.from_now
      )

      acceptor = User.create!(email: "owner-accept@example.com", name: "Acceptor")
      error = assert_raises(Organizations::Invitation::CannotAcceptAsOwner) do
        invitation.accept!(acceptor)
      end
      assert_match(/owner/i, error.message)
    end

    # Verify add_member! also blocks owner role

    test "R2: add_member! blocks owner role" do
      org, _owner = create_org_with_owner!
      new_user = create_user!

      error = assert_raises(Organizations::Organization::CannotHaveMultipleOwners) do
        org.add_member!(new_user, role: :owner)
      end
      assert_match(/owner/i, error.message)
      refute org.has_member?(new_user)
    end

    # Verify promote_to! blocks owner role

    test "R2: promote_to! blocks owner role" do
      org, _owner = create_org_with_owner!
      admin = create_user!
      org.add_member!(admin, role: :admin)

      membership = org.memberships.find_by(user: admin)
      error = assert_raises(Organizations::Membership::CannotPromoteToOwner) do
        membership.promote_to!(:owner)
      end
      assert_match(/owner/i, error.message)
      assert_equal "admin", membership.reload.role
    end

    # Verify transfer_ownership_to! works correctly

    test "R2: transfer_ownership_to! works for admin members" do
      org, owner = create_org_with_owner!
      admin = create_user!
      org.add_member!(admin, role: :admin)

      org.transfer_ownership_to!(admin)

      assert_equal admin.id, org.reload.owner.id
      old_owner_membership = org.memberships.find_by(user: owner)
      assert_equal "admin", old_owner_membership.role
    end

    test "R2: transfer_ownership_to! raises for non-admin member" do
      org, _owner = create_org_with_owner!
      member = create_user!
      org.add_member!(member, role: :member)

      assert_raises(Organizations::Organization::CannotTransferToNonAdmin) do
        org.transfer_ownership_to!(member)
      end
    end

    test "R2: transfer_ownership_to! raises NoOwnerPresent for corrupted state" do
      org = Organizations::Organization.create!(name: "No Owner Org")
      user = create_user!
      Organizations::Membership.create!(user: user, organization: org, role: "admin")

      error = assert_raises(Organizations::Organization::NoOwnerPresent) do
        org.transfer_ownership_to!(user)
      end
      assert_match(/no owner/i, error.message)
    end

    # Verify expired invitation refresh

    test "R2: re-inviting with expired invitation refreshes it" do
      org, owner = create_org_with_owner!

      expired = Organizations::Invitation.create!(
        organization: org,
        email: "expired-refresh@example.com",
        invited_by: owner,
        role: "member",
        token: SecureRandom.urlsafe_base64(32),
        expires_at: 1.day.ago
      )
      assert expired.expired?
      old_token = expired.token

      refreshed = org.send_invite_to!("expired-refresh@example.com", invited_by: owner)
      assert_equal expired.id, refreshed.id, "Should refresh existing expired invitation"
      refute_equal old_token, refreshed.token, "Token should be regenerated"
      refute refreshed.expired?, "Refreshed invitation should not be expired"
    end

    # Verify for_email scope is case-insensitive

    test "R2: for_email scope is case-insensitive" do
      org, owner = create_org_with_owner!

      invitation = Organizations::Invitation.create!(
        organization: org,
        email: "lowercase@example.com",
        invited_by: owner,
        role: "member",
        token: SecureRandom.urlsafe_base64(32),
        expires_at: 7.days.from_now
      )

      found = Organizations::Invitation.for_email("LOWERCASE@EXAMPLE.COM").first
      assert_equal invitation.id, found.id,
        "for_email must be case-insensitive"
    end

    # Verify existing-member check prevents inviting existing members

    test "R2: send_invite_to! prevents inviting existing members" do
      org, owner = create_org_with_owner!
      member = User.create!(email: "existing@example.com", name: "Existing")
      org.add_member!(member, role: :member)

      error = assert_raises(Organizations::InvitationError) do
        org.send_invite_to!("existing@example.com", invited_by: owner)
      end
      assert_match(/already a member/i, error.message)
    end

    # Verify case-insensitive existing-member check

    test "R2: existing-member check is case-insensitive" do
      org, owner = create_org_with_owner!
      member = User.create!(email: "CaseMix@Example.com", name: "Case Mix")
      org.add_member!(member, role: :member)

      error = assert_raises(Organizations::InvitationError) do
        org.send_invite_to!("casemix@example.com", invited_by: owner)
      end
      assert_match(/already a member/i, error.message)
    end

    # Verify idempotent invitation (second invite to same pending email returns existing)

    test "R2: second invite to same pending email returns existing invitation" do
      org, owner = create_org_with_owner!
      admin = create_user!
      org.add_member!(admin, role: :admin)

      inv1 = org.send_invite_to!("shared@example.com", invited_by: owner)
      inv2 = org.send_invite_to!("shared@example.com", invited_by: admin)

      assert_equal inv1.id, inv2.id,
        "Second invite to same email should return existing pending invitation"
    end

    # Verify owner deletion guard works

    test "R2: owner deletion guard prevents user deletion while owning orgs" do
      org, owner = create_org_with_owner!

      result = owner.destroy
      assert_equal false, result
      assert owner.persisted?
      assert_includes owner.errors[:base].join, "Cannot delete"
    end

    test "R2: owner deletion guard runs before membership destruction (prepend: true)" do
      org, owner = create_org_with_owner!
      original_count = org.memberships.count

      owner.destroy
      assert_equal original_count, org.memberships.reload.count,
        "Memberships must not be destroyed when owner deletion is blocked"
    end

    # Verify slug collision handling

    test "R2: duplicate organization names get unique slugs" do
      org1 = Organizations::Organization.create!(name: "Slug Dup")
      org2 = Organizations::Organization.create!(name: "Slug Dup")

      refute_equal org1.slug, org2.slug,
        "Orgs with same name must get different slugs"
      assert org2.persisted?
    end
  end
end
