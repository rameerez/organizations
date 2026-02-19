# frozen_string_literal: true

require "test_helper"

module Organizations
  class CallbacksTest < Organizations::Test
    # ── CallbackContext ──────────────────────────────────────────────────

    test "CallbackContext stores all event fields" do
      org, owner = create_org_with_owner!
      member = create_user!(email: "member@example.com")
      membership = Organizations::Membership.create!(user: member, organization: org, role: "member")
      invitation = Organizations::Invitation.create!(
        organization: org,
        email: "inv@example.com",
        invited_by: owner,
        role: "member"
      )

      ctx = CallbackContext.new(
        event: :member_invited,
        organization: org,
        user: member,
        membership: membership,
        invitation: invitation,
        invited_by: owner,
        removed_by: owner,
        changed_by: owner,
        old_role: :member,
        new_role: :admin,
        old_owner: owner,
        new_owner: member,
        permission: :manage_members,
        required_role: :admin,
        metadata: { source: "test" }
      )

      assert_equal :member_invited, ctx.event
      assert_equal org, ctx.organization
      assert_equal member, ctx.user
      assert_equal membership, ctx.membership
      assert_equal invitation, ctx.invitation
      assert_equal owner, ctx.invited_by
      assert_equal owner, ctx.removed_by
      assert_equal owner, ctx.changed_by
      assert_equal :member, ctx.old_role
      assert_equal :admin, ctx.new_role
      assert_equal owner, ctx.old_owner
      assert_equal member, ctx.new_owner
      assert_equal :manage_members, ctx.permission
      assert_equal :admin, ctx.required_role
      assert_equal({ source: "test" }, ctx.metadata)
    end

    test "CallbackContext#to_h excludes nil values" do
      ctx = CallbackContext.new(event: :organization_created, organization: "org")

      h = ctx.to_h
      assert_equal :organization_created, h[:event]
      assert_equal "org", h[:organization]
      refute h.key?(:user)
      refute h.key?(:membership)
    end

    test "CallbackContext#event? checks event type" do
      ctx = CallbackContext.new(event: :member_joined)

      assert ctx.event?(:member_joined)
      refute ctx.event?(:member_removed)
    end

    # ── EVENTS constant ──────────────────────────────────────────────────

    test "EVENTS contains all six lifecycle events" do
      expected = %i[
        organization_created
        member_invited
        member_joined
        member_removed
        role_changed
        ownership_transferred
      ]
      assert_equal expected, Callbacks::EVENTS
    end

    # ── Dispatch with no callback configured ─────────────────────────────

    test "dispatch is a no-op when no callback is configured" do
      Organizations.configure { |c| }

      # Should not raise
      result = Callbacks.dispatch(:organization_created, organization: "org", user: "u")
      assert_nil result
    end

    test "dispatch is a no-op when callback is explicitly nil" do
      Organizations.configure do |c|
        c.instance_variable_set(:@on_organization_created_callback, nil)
      end

      assert_nil Callbacks.dispatch(:organization_created, organization: "o")
    end

    test "dispatch is a no-op when configuration is nil" do
      Organizations.reset_configuration!
      # @configuration is nil after reset without configure call
      assert_nil Callbacks.dispatch(:organization_created, organization: "o")
    end

    # ── on_organization_created callback ─────────────────────────────────

    test "on_organization_created fires with correct context" do
      # Create entities before configuring callback to avoid triggering
      # the personal org creation callback from has_organizations
      org, owner = create_org_with_owner!

      fired = []
      Organizations.configure do |config|
        config.on_organization_created do |ctx|
          fired << ctx
        end
      end

      Callbacks.dispatch(:organization_created, organization: org, user: owner)

      assert_equal 1, fired.size
      assert_equal :organization_created, fired.first.event
      assert_equal org, fired.first.organization
      assert_equal owner, fired.first.user
    end

    # ── on_member_invited callback ───────────────────────────────────────

    test "on_member_invited fires with organization, invitation, invited_by" do
      fired = []

      Organizations.configure do |config|
        config.on_member_invited do |ctx|
          fired << ctx
        end
      end

      org, owner = create_org_with_owner!
      invitation = Organizations::Invitation.create!(
        organization: org,
        email: "new@example.com",
        invited_by: owner,
        role: "member"
      )

      Callbacks.dispatch(:member_invited, organization: org, invitation: invitation, invited_by: owner)

      assert_equal 1, fired.size
      ctx = fired.first
      assert_equal :member_invited, ctx.event
      assert_equal org, ctx.organization
      assert_equal invitation, ctx.invitation
      assert_equal owner, ctx.invited_by
    end

    # ── on_member_joined callback ────────────────────────────────────────

    test "on_member_joined fires with organization, membership, user" do
      fired = []

      Organizations.configure do |config|
        config.on_member_joined do |ctx|
          fired << ctx
        end
      end

      org, owner = create_org_with_owner!
      member = create_user!(email: "member@example.com")
      membership = Organizations::Membership.create!(user: member, organization: org, role: "member")

      Callbacks.dispatch(:member_joined, organization: org, membership: membership, user: member)

      assert_equal 1, fired.size
      ctx = fired.first
      assert_equal :member_joined, ctx.event
      assert_equal org, ctx.organization
      assert_equal membership, ctx.membership
      assert_equal member, ctx.user
    end

    # ── on_member_removed callback ───────────────────────────────────────

    test "on_member_removed fires with organization, membership, user, removed_by" do
      fired = []

      Organizations.configure do |config|
        config.on_member_removed do |ctx|
          fired << ctx
        end
      end

      org, owner = create_org_with_owner!
      member = create_user!(email: "member@example.com")
      membership = Organizations::Membership.create!(user: member, organization: org, role: "member")

      Callbacks.dispatch(:member_removed, organization: org, membership: membership, user: member, removed_by: owner)

      assert_equal 1, fired.size
      ctx = fired.first
      assert_equal :member_removed, ctx.event
      assert_equal org, ctx.organization
      assert_equal membership, ctx.membership
      assert_equal member, ctx.user
      assert_equal owner, ctx.removed_by
    end

    # ── on_role_changed callback ─────────────────────────────────────────

    test "on_role_changed fires with organization, membership, old_role, new_role, changed_by" do
      fired = []

      Organizations.configure do |config|
        config.on_role_changed do |ctx|
          fired << ctx
        end
      end

      org, owner = create_org_with_owner!
      member = create_user!(email: "member@example.com")
      membership = Organizations::Membership.create!(user: member, organization: org, role: "member")

      Callbacks.dispatch(
        :role_changed,
        organization: org,
        membership: membership,
        old_role: :member,
        new_role: :admin,
        changed_by: owner
      )

      assert_equal 1, fired.size
      ctx = fired.first
      assert_equal :role_changed, ctx.event
      assert_equal org, ctx.organization
      assert_equal membership, ctx.membership
      assert_equal :member, ctx.old_role
      assert_equal :admin, ctx.new_role
      assert_equal owner, ctx.changed_by
    end

    # ── on_ownership_transferred callback ────────────────────────────────

    test "on_ownership_transferred fires with organization, old_owner, new_owner" do
      fired = []

      Organizations.configure do |config|
        config.on_ownership_transferred do |ctx|
          fired << ctx
        end
      end

      org, owner = create_org_with_owner!
      new_owner = create_user!(email: "new_owner@example.com")
      Organizations::Membership.create!(user: new_owner, organization: org, role: "admin")

      Callbacks.dispatch(
        :ownership_transferred,
        organization: org,
        old_owner: owner,
        new_owner: new_owner
      )

      assert_equal 1, fired.size
      ctx = fired.first
      assert_equal :ownership_transferred, ctx.event
      assert_equal org, ctx.organization
      assert_equal owner, ctx.old_owner
      assert_equal new_owner, ctx.new_owner
    end

    # ── Non-strict mode (error isolation) ────────────────────────────────

    test "non-strict mode swallows callback errors" do
      Organizations.configure do |config|
        config.on_organization_created do |ctx|
          raise "Boom!"
        end
      end

      # Should not raise - capture_io suppresses the warn output
      _out, err = capture_io do
        Callbacks.dispatch(:organization_created, organization: "org", user: "u")
      end
      assert_match(/Boom!/, err)
    end

    test "non-strict mode logs callback errors to stderr" do
      Organizations.configure do |config|
        config.on_member_joined do |ctx|
          raise RuntimeError, "analytics service down"
        end
      end

      output = capture_io do
        Callbacks.dispatch(:member_joined, organization: "org", user: "u")
      end

      assert_match(/Callback error for member_joined/, output[1])
      assert_match(/RuntimeError/, output[1])
      assert_match(/analytics service down/, output[1])
    end

    test "non-strict mode handles Organizations::Error without propagating" do
      Organizations.configure do |config|
        config.on_member_removed do |ctx|
          raise Organizations::Error, "custom org error"
        end
      end

      # Should not raise even though it's an Organizations error
      _out, err = capture_io do
        Callbacks.dispatch(:member_removed, organization: "org", user: "u")
      end
      assert_match(/custom org error/, err)
    end

    # ── Strict mode (errors propagate) ───────────────────────────────────

    test "strict mode propagates callback errors" do
      Organizations.configure do |config|
        config.on_member_invited do |ctx|
          raise Organizations::InvitationError, "Seat limit reached"
        end
      end

      error = assert_raises(Organizations::InvitationError) do
        Callbacks.dispatch(:member_invited, strict: true, organization: "org", invitation: "inv")
      end

      assert_equal "Seat limit reached", error.message
    end

    test "strict mode propagates non-Organizations errors" do
      Organizations.configure do |config|
        config.on_member_invited do |ctx|
          raise ArgumentError, "unexpected"
        end
      end

      assert_raises(ArgumentError) do
        Callbacks.dispatch(:member_invited, strict: true, organization: "org")
      end
    end

    test "strict mode allows callback to veto operation" do
      Organizations.configure do |config|
        config.on_member_invited do |ctx|
          raise Organizations::InvitationError, "Max seats reached" if ctx.organization == "full_org"
        end
      end

      # Should raise for full org
      assert_raises(Organizations::InvitationError) do
        Callbacks.dispatch(:member_invited, strict: true, organization: "full_org")
      end

      # Should NOT raise for org with capacity
      Callbacks.dispatch(:member_invited, strict: true, organization: "small_org")
    end

    test "strict mode does not raise when callback succeeds" do
      fired = false

      Organizations.configure do |config|
        config.on_member_invited do |ctx|
          fired = true
        end
      end

      Callbacks.dispatch(:member_invited, strict: true, organization: "org")
      assert fired
    end

    # ── callback_for ─────────────────────────────────────────────────────

    test "callback_for returns the configured proc for each event" do
      procs = {}
      Organizations.configure do |config|
        config.on_organization_created { procs[:org_created] = true }
        config.on_member_invited { procs[:invited] = true }
        config.on_member_joined { procs[:joined] = true }
        config.on_member_removed { procs[:removed] = true }
        config.on_role_changed { procs[:role] = true }
        config.on_ownership_transferred { procs[:transfer] = true }
      end

      Callbacks::EVENTS.each do |event|
        callback = Callbacks.callback_for(event)
        assert_respond_to callback, :call, "Expected callback for #{event} to respond to :call"
      end
    end

    test "callback_for returns nil for unknown event" do
      Organizations.configure { |c| }

      assert_nil Callbacks.callback_for(:unknown_event)
    end

    test "callback_for returns nil when no configuration exists" do
      Organizations.reset_configuration!

      assert_nil Callbacks.callback_for(:organization_created)
    end

    # ── Callback arity support ───────────────────────────────────────────

    test "callback with zero arity is invoked without arguments" do
      fired = false

      Organizations.configure do |config|
        config.on_organization_created { fired = true }
      end

      Callbacks.dispatch(:organization_created, organization: "org", user: "u")
      assert fired
    end

    test "callback with one argument receives context" do
      received_ctx = nil

      Organizations.configure do |config|
        config.on_organization_created do |ctx|
          received_ctx = ctx
        end
      end

      Callbacks.dispatch(:organization_created, organization: "org", user: "u")

      assert_instance_of CallbackContext, received_ctx
      assert_equal :organization_created, received_ctx.event
    end

    test "callback with splat arguments receives context" do
      received_args = nil

      Organizations.configure do |config|
        config.on_organization_created do |*args|
          received_args = args
        end
      end

      Callbacks.dispatch(:organization_created, organization: "org", user: "u")

      assert_equal 1, received_args.size
      assert_instance_of CallbackContext, received_args.first
    end

    # ── Edge cases ───────────────────────────────────────────────────────

    test "callback that is not callable is skipped" do
      Organizations.configure do |config|
        # Force a non-callable value
        config.instance_variable_set(:@on_organization_created_callback, "not_a_proc")
      end

      # Should not raise because execute_safely checks respond_to?(:call)
      result = Callbacks.dispatch(:organization_created, organization: "org")
      assert_nil result
    end

    test "callback that modifies context does not raise" do
      modified = false

      Organizations.configure do |config|
        config.on_member_joined do |ctx|
          ctx.metadata = { modified: true }
          modified = true
        end
      end

      Callbacks.dispatch(:member_joined, organization: "org", user: "u")
      assert modified
    end

    test "multiple callbacks for different events fire independently" do
      created_fired = false
      joined_fired = false

      Organizations.configure do |config|
        config.on_organization_created { created_fired = true }
        config.on_member_joined { joined_fired = true }
      end

      Callbacks.dispatch(:organization_created, organization: "org", user: "u")
      assert created_fired
      refute joined_fired

      Callbacks.dispatch(:member_joined, organization: "org", user: "u")
      assert joined_fired
    end

    test "replacing a callback uses the latest one" do
      call_log = []

      Organizations.configure do |config|
        config.on_organization_created { call_log << :first }
        config.on_organization_created { call_log << :second }
      end

      Callbacks.dispatch(:organization_created, organization: "org", user: "u")

      assert_equal [:second], call_log
    end

    test "non-strict callback error does not affect subsequent dispatches" do
      call_count = 0

      Organizations.configure do |config|
        config.on_organization_created do |ctx|
          call_count += 1
          raise "fail!" if call_count == 1
        end
      end

      # First call raises internally but is swallowed
      Callbacks.dispatch(:organization_created, organization: "org", user: "u")
      assert_equal 1, call_count

      # Second call should still work
      Callbacks.dispatch(:organization_created, organization: "org", user: "u")
      assert_equal 2, call_count
    end

    # ── Configuration DSL ────────────────────────────────────────────────

    test "callbacks are configured through Organizations.configure block" do
      fired = false

      Organizations.configure do |config|
        config.on_organization_created { |ctx| fired = true }
      end

      Callbacks.dispatch(:organization_created, organization: "org", user: "u")
      assert fired
    end

    test "callback set to nil effectively disables it" do
      fired = false

      Organizations.configure do |config|
        config.on_organization_created { fired = true }
        config.instance_variable_set(:@on_organization_created_callback, nil)
      end

      Callbacks.dispatch(:organization_created, organization: "org", user: "u")
      refute fired
    end

    test "on_organization_created only sets callback when block given" do
      Organizations.configure do |config|
        config.on_organization_created
      end

      assert_nil Callbacks.callback_for(:organization_created)
    end

    # ── Logging ──────────────────────────────────────────────────────────

    test "execute_safely logs error message and class" do
      Organizations.configure do |config|
        config.on_role_changed do |ctx|
          raise TypeError, "wrong type"
        end
      end

      output = capture_io do
        Callbacks.dispatch(:role_changed, organization: "org")
      end

      assert_match(/\[Organizations\] Callback error for role_changed: TypeError: wrong type/, output[1])
    end

    # ── invoke_callback arity handling ───────────────────────────────────

    test "lambda with explicit arity of 1 receives context" do
      received = nil

      Organizations.configure do |config|
        config.instance_variable_set(
          :@on_organization_created_callback,
          ->(ctx) { received = ctx }
        )
      end

      Callbacks.dispatch(:organization_created, organization: "test_org")

      assert_instance_of CallbackContext, received
      assert_equal "test_org", received.organization
    end

    test "lambda with arity 0 is called without arguments" do
      fired = false

      Organizations.configure do |config|
        config.instance_variable_set(
          :@on_organization_created_callback,
          -> { fired = true }
        )
      end

      Callbacks.dispatch(:organization_created, organization: "test_org")
      assert fired
    end

    # ── Strict mode with non-callable ────────────────────────────────────

    test "strict mode with non-callable callback is a no-op" do
      Organizations.configure do |config|
        config.instance_variable_set(:@on_member_invited_callback, 42)
      end

      # Should not raise
      result = Callbacks.dispatch(:member_invited, strict: true, organization: "org")
      assert_nil result
    end
  end
end
