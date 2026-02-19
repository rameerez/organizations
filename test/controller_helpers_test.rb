# frozen_string_literal: true

require "test_helper"

module Organizations
  class ControllerHelpersTest < Organizations::Test
    # A lightweight mock controller that includes ControllerHelpers.
    # Simulates the parts of ActionController::Base that ControllerHelpers depends on.
    class MockController
      include Organizations::ControllerHelpers

      attr_reader :session, :redirected_to, :redirect_alert, :rendered_json, :rendered_status
      attr_accessor :test_current_user

      def initialize
        @session = {}
        @redirected_to = nil
        @redirect_alert = nil
        @rendered_json = nil
        @rendered_status = nil
        @test_current_user = nil
        @_respond_to_format = :html
      end

      # Simulate current_user (the default configured method)
      def current_user
        @test_current_user
      end

      # Simulate format for respond_to
      def set_format(format)
        @_respond_to_format = format
      end

      def respond_to
        format_responder = FormatResponder.new(@_respond_to_format)
        yield format_responder
        format_responder.execute(self)
      end

      def redirect_back(fallback_location:, alert: nil)
        @redirected_to = fallback_location
        @redirect_alert = alert
      end

      def redirect_to(path, alert: nil)
        @redirected_to = path
        @redirect_alert = alert
      end

      def render(json: nil, status: nil)
        @rendered_json = json
        @rendered_status = status
      end

      # Simulate main_app for default redirect
      def main_app
        self
      end

      def root_path
        "/"
      end

      # Reset memoized state between tests
      def reset!
        remove_instance_variable(:@_current_organization) if defined?(@_current_organization)
        remove_instance_variable(:@_current_membership) if defined?(@_current_membership)
        remove_instance_variable(:@_organizations_current_user) if defined?(@_organizations_current_user)
        @redirected_to = nil
        @redirect_alert = nil
        @rendered_json = nil
        @rendered_status = nil
      end

      # A simple format responder to handle respond_to blocks
      class FormatResponder
        def initialize(active_format)
          @active_format = active_format
          @blocks = {}
        end

        def html(&block)
          @blocks[:html] = block
        end

        def json(&block)
          @blocks[:json] = block
        end

        def execute(controller)
          block = @blocks[@active_format]
          controller.instance_eval(&block) if block
        end
      end
    end

    def setup
      super
      # Suppress personal org auto-creation so we control memberships precisely
      User.skip_callback(:create, :after, :create_personal_organization_if_configured, raise: false)
      @controller = MockController.new
    end

    def teardown
      User.set_callback(:create, :after, :create_personal_organization_if_configured, if: -> {
        self.class.organization_settings[:create_personal_org]
      })
      super
    end

    # =====================
    # Context helpers
    # =====================

    test "current_organization returns active org from session" do
      org, owner = create_org_with_owner!
      @controller.test_current_user = owner
      @controller.session[:current_organization_id] = org.id

      assert_equal org, @controller.current_organization
    end

    test "current_organization returns nil when no user" do
      @controller.test_current_user = nil

      assert_nil @controller.current_organization
    end

    test "current_organization returns nil when user has no orgs" do
      user = create_user!
      Organizations.configuration.create_personal_organization = false
      @controller.test_current_user = user

      assert_nil @controller.current_organization
    end

    test "current_organization is memoized within request" do
      org, owner = create_org_with_owner!
      @controller.test_current_user = owner
      @controller.session[:current_organization_id] = org.id

      result1 = @controller.current_organization
      result2 = @controller.current_organization

      assert_same result1, result2
    end

    test "current_organization auto-switches to next available when current is invalid" do
      org1, owner = create_org_with_owner!(name: "Org 1")
      org2 = Organizations::Organization.create!(name: "Org 2")
      Organizations::Membership.create!(user: owner, organization: org2, role: "member")

      @controller.test_current_user = owner
      # Set session to a non-existent org id
      @controller.session[:current_organization_id] = 999_999

      result = @controller.current_organization
      # Should fall back to one of user's orgs (most recently updated)
      assert_includes [org1, org2], result
      assert_not_nil result
    end

    test "current_organization auto-switches when user removed from current org" do
      org1, owner = create_org_with_owner!(name: "Org A")
      org2 = Organizations::Organization.create!(name: "Org B")
      Organizations::Membership.create!(user: owner, organization: org2, role: "owner")

      @controller.test_current_user = owner
      # Set to org1 in session
      @controller.session[:current_organization_id] = org1.id

      # Now remove user from org1
      owner.memberships.where(organization_id: org1.id).destroy_all

      result = @controller.current_organization
      assert_equal org2, result
      assert_equal org2.id, @controller.session[:current_organization_id]
    end

    test "current_organization clears session when org does not exist" do
      user = create_user!
      @controller.test_current_user = user
      @controller.session[:current_organization_id] = 999_999

      result = @controller.current_organization
      assert_nil result
      assert_nil @controller.session[:current_organization_id]
    end

    test "current_organization sets user._current_organization_id" do
      org, owner = create_org_with_owner!
      @controller.test_current_user = owner
      @controller.session[:current_organization_id] = org.id

      @controller.current_organization

      assert_equal org.id, owner._current_organization_id
    end

    test "current_membership returns users membership in current org" do
      org, owner = create_org_with_owner!
      @controller.test_current_user = owner
      @controller.session[:current_organization_id] = org.id

      membership = @controller.current_membership

      assert_not_nil membership
      assert_equal owner.id, membership.user_id
      assert_equal org.id, membership.organization_id
    end

    test "current_membership returns nil when no user" do
      @controller.test_current_user = nil

      assert_nil @controller.current_membership
    end

    test "current_membership returns nil when no current organization" do
      user = create_user!
      @controller.test_current_user = user

      assert_nil @controller.current_membership
    end

    test "current_membership is memoized" do
      org, owner = create_org_with_owner!
      @controller.test_current_user = owner
      @controller.session[:current_organization_id] = org.id

      m1 = @controller.current_membership
      m2 = @controller.current_membership

      assert_same m1, m2
    end

    test "organization_signed_in? returns true when current_organization exists" do
      org, owner = create_org_with_owner!
      @controller.test_current_user = owner
      @controller.session[:current_organization_id] = org.id

      assert @controller.organization_signed_in?
    end

    test "organization_signed_in? returns false when no current_organization" do
      @controller.test_current_user = nil

      refute @controller.organization_signed_in?
    end

    # =====================
    # Most recently used org / fallback
    # =====================

    test "fallback org selection uses most recently updated membership" do
      user = create_user!
      org_old = Organizations::Organization.create!(name: "Old Org")
      org_new = Organizations::Organization.create!(name: "New Org")

      # Create memberships with controlled updated_at
      travel_to 2.days.ago do
        Organizations::Membership.create!(user: user, organization: org_old, role: "member")
      end
      travel_to 1.day.ago do
        Organizations::Membership.create!(user: user, organization: org_new, role: "member")
      end

      @controller.test_current_user = user
      # No session org set, should fallback to most recently updated
      result = @controller.current_organization

      assert_equal org_new, result
    end

    test "mark_membership_as_recent! touches updated_at" do
      org, owner = create_org_with_owner!
      membership = owner.memberships.find_by(organization_id: org.id)
      original_updated_at = membership.updated_at

      travel_to 1.hour.from_now do
        @controller.test_current_user = owner
        @controller.session[:current_organization_id] = org.id
        @controller.send(:mark_membership_as_recent!, owner, org)

        membership.reload
        assert membership.updated_at > original_updated_at
      end
    end

    # =====================
    # Switching
    # =====================

    test "switch_to_organization! changes session org" do
      org1, owner = create_org_with_owner!(name: "Org 1")
      org2 = Organizations::Organization.create!(name: "Org 2")
      Organizations::Membership.create!(user: owner, organization: org2, role: "member")

      @controller.test_current_user = owner
      @controller.session[:current_organization_id] = org1.id

      @controller.switch_to_organization!(org2)

      assert_equal org2.id, @controller.session[:current_organization_id]
    end

    test "switch_to_organization! marks membership as recent" do
      org1, owner = create_org_with_owner!(name: "Org 1")
      org2 = Organizations::Organization.create!(name: "Org 2")
      Organizations::Membership.create!(user: owner, organization: org2, role: "member")

      @controller.test_current_user = owner
      @controller.session[:current_organization_id] = org1.id

      membership_before = owner.memberships.find_by(organization_id: org2.id)
      old_updated_at = membership_before.updated_at

      travel_to 1.hour.from_now do
        @controller.switch_to_organization!(org2)

        membership_before.reload
        assert membership_before.updated_at > old_updated_at
      end
    end

    test "switch_to_organization! clears cached membership" do
      org1, owner = create_org_with_owner!(name: "Org 1")
      org2 = Organizations::Organization.create!(name: "Org 2")
      Organizations::Membership.create!(user: owner, organization: org2, role: "admin")

      @controller.test_current_user = owner
      @controller.session[:current_organization_id] = org1.id

      # Access current_membership to cache it
      first_membership = @controller.current_membership
      assert_equal org1.id, first_membership.organization_id

      # Switch
      @controller.switch_to_organization!(org2)

      # After reset, re-query
      @controller.reset!
      @controller.session[:current_organization_id] = org2.id
      new_membership = @controller.current_membership
      assert_equal org2.id, new_membership.organization_id
    end

    test "switch_to_organization! raises NotAMember for non-members" do
      org, _owner = create_org_with_owner!
      outsider = create_user!(email: "outsider@example.com")

      @controller.test_current_user = outsider

      assert_raises(Organizations::NotAMember) do
        @controller.switch_to_organization!(org)
      end
    end

    test "switch_to_organization! raises NotAMember when user is nil" do
      org, _owner = create_org_with_owner!
      @controller.test_current_user = nil

      assert_raises(Organizations::NotAMember) do
        @controller.switch_to_organization!(org)
      end
    end

    test "current_organization= sets session and cache" do
      org, owner = create_org_with_owner!
      @controller.test_current_user = owner

      @controller.current_organization = org

      assert_equal org.id, @controller.session[:current_organization_id]
      assert_equal org.id, owner._current_organization_id
    end

    test "current_organization= with nil clears session" do
      org, owner = create_org_with_owner!
      @controller.test_current_user = owner
      @controller.session[:current_organization_id] = org.id

      @controller.current_organization = nil

      assert_nil @controller.session[:current_organization_id]
    end

    # =====================
    # Authorization helpers
    # =====================

    test "require_organization! does nothing when org is present" do
      org, owner = create_org_with_owner!
      @controller.test_current_user = owner
      @controller.session[:current_organization_id] = org.id

      @controller.require_organization!

      assert_nil @controller.redirected_to
    end

    test "require_organization! redirects when no org (default handler, html)" do
      @controller.test_current_user = create_user!
      @controller.set_format(:html)

      @controller.require_organization!

      assert_equal "/organizations/new", @controller.redirected_to
      assert_equal "Please select or create an organization.", @controller.redirect_alert
    end

    test "require_organization! renders json when no org (default handler, json)" do
      @controller.test_current_user = create_user!
      @controller.set_format(:json)

      @controller.require_organization!

      assert_equal({ error: "Organization required" }, @controller.rendered_json)
      assert_equal :forbidden, @controller.rendered_status
    end

    test "require_organization_role! with admin checks role hierarchy" do
      org, _owner = create_org_with_owner!
      member = create_user!(email: "member@example.com")
      Organizations::Membership.create!(user: member, organization: org, role: "member")

      @controller.test_current_user = member
      @controller.session[:current_organization_id] = org.id
      @controller.set_format(:html)

      @controller.require_organization_role!(:admin)

      assert_not_nil @controller.redirected_to
    end

    test "require_organization_role! allows higher role" do
      org, owner = create_org_with_owner!
      @controller.test_current_user = owner
      @controller.session[:current_organization_id] = org.id

      @controller.require_organization_role!(:admin)

      # Owner is above admin, so no redirect
      assert_nil @controller.redirected_to
    end

    test "require_organization_role! allows exact role" do
      org = Organizations::Organization.create!(name: "Exact Role Org")
      admin = create_user!(email: "admin@example.com")
      Organizations::Membership.create!(user: admin, organization: org, role: "admin")

      @controller.test_current_user = admin
      @controller.session[:current_organization_id] = org.id

      @controller.require_organization_role!(:admin)

      assert_nil @controller.redirected_to
    end

    test "require_organization_role! calls require_organization! first" do
      @controller.test_current_user = create_user!
      @controller.set_format(:html)

      @controller.require_organization_role!(:admin)

      # Should have redirected because no org, not because of role
      assert_equal "/organizations/new", @controller.redirected_to
    end

    test "require_organization_permission_to! allows user with permission" do
      org, owner = create_org_with_owner!
      @controller.test_current_user = owner
      @controller.session[:current_organization_id] = org.id

      @controller.require_organization_permission_to!(:invite_members)

      assert_nil @controller.redirected_to
    end

    test "require_organization_permission_to! blocks user without permission" do
      org = Organizations::Organization.create!(name: "Perm Org")
      viewer = create_user!(email: "viewer@example.com")
      Organizations::Membership.create!(user: viewer, organization: org, role: "viewer")

      @controller.test_current_user = viewer
      @controller.session[:current_organization_id] = org.id
      @controller.set_format(:html)

      @controller.require_organization_permission_to!(:invite_members)

      assert_not_nil @controller.redirected_to
    end

    test "require_organization_owner! is shortcut for role owner" do
      org = Organizations::Organization.create!(name: "Owner Check Org")
      admin = create_user!(email: "admin@example.com")
      Organizations::Membership.create!(user: admin, organization: org, role: "admin")

      @controller.test_current_user = admin
      @controller.session[:current_organization_id] = org.id
      @controller.set_format(:html)

      @controller.require_organization_owner!

      # Admin is below owner, should redirect
      assert_not_nil @controller.redirected_to
    end

    test "require_organization_owner! passes for owner" do
      org, owner = create_org_with_owner!
      @controller.test_current_user = owner
      @controller.session[:current_organization_id] = org.id

      @controller.require_organization_owner!

      assert_nil @controller.redirected_to
    end

    test "require_organization_admin! is shortcut for role admin" do
      org = Organizations::Organization.create!(name: "Admin Check Org")
      member = create_user!(email: "member@example.com")
      Organizations::Membership.create!(user: member, organization: org, role: "member")

      @controller.test_current_user = member
      @controller.session[:current_organization_id] = org.id
      @controller.set_format(:html)

      @controller.require_organization_admin!

      # Member is below admin, should redirect
      assert_not_nil @controller.redirected_to
    end

    test "require_organization_admin! passes for admin" do
      org = Organizations::Organization.create!(name: "Admin Pass Org")
      admin = create_user!(email: "admin@example.com")
      Organizations::Membership.create!(user: admin, organization: org, role: "admin")

      @controller.test_current_user = admin
      @controller.session[:current_organization_id] = org.id

      @controller.require_organization_admin!

      assert_nil @controller.redirected_to
    end

    test "require_organization_admin! passes for owner" do
      org, owner = create_org_with_owner!
      @controller.test_current_user = owner
      @controller.session[:current_organization_id] = org.id

      @controller.require_organization_admin!

      assert_nil @controller.redirected_to
    end

    # =====================
    # Default unauthorized handler (HTML)
    # =====================

    test "default unauthorized handler redirects with alert for html" do
      org = Organizations::Organization.create!(name: "Unauth Org")
      viewer = create_user!(email: "viewer@example.com")
      Organizations::Membership.create!(user: viewer, organization: org, role: "viewer")

      @controller.test_current_user = viewer
      @controller.session[:current_organization_id] = org.id
      @controller.set_format(:html)

      @controller.require_organization_role!(:admin)

      assert_equal "/", @controller.redirected_to
      assert_includes @controller.redirect_alert, "admin"
    end

    test "default unauthorized handler renders json for json format" do
      org = Organizations::Organization.create!(name: "JSON Unauth Org")
      viewer = create_user!(email: "viewer@example.com")
      Organizations::Membership.create!(user: viewer, organization: org, role: "viewer")

      @controller.test_current_user = viewer
      @controller.session[:current_organization_id] = org.id
      @controller.set_format(:json)

      @controller.require_organization_role!(:admin)

      assert_equal :forbidden, @controller.rendered_status
      assert_not_nil @controller.rendered_json
      assert_includes @controller.rendered_json[:error], "admin"
    end

    # =====================
    # Handler callbacks
    # =====================

    test "on_unauthorized handler invoked when auth fails" do
      handler_called = false
      handler_context = nil

      Organizations.configure do |config|
        config.on_unauthorized do |context|
          handler_called = true
          handler_context = context
        end
      end

      org = Organizations::Organization.create!(name: "Handler Org")
      viewer = create_user!(email: "viewer@example.com")
      Organizations::Membership.create!(user: viewer, organization: org, role: "viewer")

      @controller.test_current_user = viewer
      @controller.session[:current_organization_id] = org.id

      @controller.require_organization_role!(:admin)

      assert handler_called, "Expected unauthorized handler to be called"
      assert_equal :unauthorized, handler_context.event
      assert_equal viewer, handler_context.user
      assert_equal org, handler_context.organization
      assert_equal :admin, handler_context.permission
      assert_equal :admin, handler_context.required_role
    end

    test "on_no_organization handler invoked when no org" do
      handler_called = false
      handler_context = nil

      Organizations.configure do |config|
        config.on_no_organization do |context|
          handler_called = true
          handler_context = context
        end
      end

      user = create_user!
      @controller.test_current_user = user

      @controller.require_organization!

      assert handler_called, "Expected no_organization handler to be called"
      assert_equal :no_organization, handler_context.event
      assert_equal user, handler_context.user
    end

    test "on_unauthorized handler runs in controller context" do
      redirected = false

      Organizations.configure do |config|
        config.on_unauthorized do |_context|
          # Should be able to call controller methods
          redirected = true
          redirect_to "/custom-unauthorized"
        end
      end

      org = Organizations::Organization.create!(name: "Context Org")
      viewer = create_user!(email: "viewer@example.com")
      Organizations::Membership.create!(user: viewer, organization: org, role: "viewer")

      @controller.test_current_user = viewer
      @controller.session[:current_organization_id] = org.id

      @controller.require_organization_role!(:admin)

      assert redirected
      assert_equal "/custom-unauthorized", @controller.redirected_to
    end

    test "on_no_organization handler runs in controller context" do
      Organizations.configure do |config|
        config.on_no_organization do |_context|
          redirect_to "/custom-no-org"
        end
      end

      @controller.test_current_user = create_user!
      @controller.require_organization!

      assert_equal "/custom-no-org", @controller.redirected_to
    end

    # =====================
    # Session management
    # =====================

    test "session stores org id" do
      org, owner = create_org_with_owner!
      @controller.test_current_user = owner

      @controller.current_organization = org

      assert_equal org.id, @controller.session[:current_organization_id]
    end

    test "stale session handled gracefully when user removed from org" do
      org1, owner = create_org_with_owner!(name: "Stale Org")
      org2 = Organizations::Organization.create!(name: "Fallback Org")
      Organizations::Membership.create!(user: owner, organization: org2, role: "member")

      @controller.test_current_user = owner
      @controller.session[:current_organization_id] = org1.id

      # Remove user from org1 (stale session)
      owner.memberships.where(organization_id: org1.id).destroy_all

      result = @controller.current_organization

      assert_equal org2, result
      assert_equal org2.id, @controller.session[:current_organization_id]
    end

    test "session cleared when org does not exist" do
      user = create_user!
      @controller.test_current_user = user
      @controller.session[:current_organization_id] = 999_999

      @controller.current_organization

      assert_nil @controller.session[:current_organization_id]
    end

    test "custom session key is respected" do
      Organizations.configure do |config|
        config.session_key = :my_org_id
      end

      org, owner = create_org_with_owner!
      @controller.test_current_user = owner
      @controller.session[:my_org_id] = org.id

      assert_equal org, @controller.current_organization
    end

    # =====================
    # Edge cases
    # =====================

    test "user belongs to multiple orgs can switch between them" do
      user = create_user!
      org1 = Organizations::Organization.create!(name: "Org 1")
      org2 = Organizations::Organization.create!(name: "Org 2")
      org3 = Organizations::Organization.create!(name: "Org 3")

      Organizations::Membership.create!(user: user, organization: org1, role: "member")
      Organizations::Membership.create!(user: user, organization: org2, role: "admin")
      Organizations::Membership.create!(user: user, organization: org3, role: "owner")

      @controller.test_current_user = user

      @controller.switch_to_organization!(org1)
      assert_equal org1.id, @controller.session[:current_organization_id]

      @controller.reset!
      @controller.switch_to_organization!(org3)
      assert_equal org3.id, @controller.session[:current_organization_id]

      @controller.reset!
      @controller.switch_to_organization!(org2)
      assert_equal org2.id, @controller.session[:current_organization_id]
    end

    test "user removed from current org while session active falls back" do
      user = create_user!
      org_current = Organizations::Organization.create!(name: "Current")
      org_fallback = Organizations::Organization.create!(name: "Fallback")

      Organizations::Membership.create!(user: user, organization: org_current, role: "member")
      Organizations::Membership.create!(user: user, organization: org_fallback, role: "member")

      @controller.test_current_user = user
      @controller.session[:current_organization_id] = org_current.id

      # Simulate removal
      user.memberships.where(organization_id: org_current.id).destroy_all

      result = @controller.current_organization
      assert_equal org_fallback, result
    end

    test "first login with no prior session selects most recent org" do
      user = create_user!
      org_old = Organizations::Organization.create!(name: "Old Org")
      org_new = Organizations::Organization.create!(name: "New Org")

      travel_to 2.days.ago do
        Organizations::Membership.create!(user: user, organization: org_old, role: "member")
      end
      travel_to 1.day.ago do
        Organizations::Membership.create!(user: user, organization: org_new, role: "member")
      end

      @controller.test_current_user = user
      # No session key set

      result = @controller.current_organization
      assert_equal org_new, result
      assert_equal org_new.id, @controller.session[:current_organization_id]
    end

    test "first login with no orgs at all returns nil" do
      user = create_user!
      @controller.test_current_user = user

      result = @controller.current_organization
      assert_nil result
      assert_nil @controller.session[:current_organization_id]
    end

    test "current_organization with valid session but org deleted from db" do
      org, owner = create_org_with_owner!
      @controller.test_current_user = owner
      @controller.session[:current_organization_id] = org.id

      # Delete the org from the database
      org.memberships.delete_all
      org.delete

      result = @controller.current_organization
      # The org was deleted, so user has no orgs, should return nil
      assert_nil result
    end

    test "switching preserves session key across multiple switches" do
      user = create_user!
      org_a = Organizations::Organization.create!(name: "A")
      org_b = Organizations::Organization.create!(name: "B")

      Organizations::Membership.create!(user: user, organization: org_a, role: "member")
      Organizations::Membership.create!(user: user, organization: org_b, role: "member")

      @controller.test_current_user = user

      @controller.switch_to_organization!(org_a)
      assert_equal org_a.id, @controller.session[:current_organization_id]

      @controller.reset!
      @controller.switch_to_organization!(org_b)
      assert_equal org_b.id, @controller.session[:current_organization_id]

      @controller.reset!
      @controller.switch_to_organization!(org_a)
      assert_equal org_a.id, @controller.session[:current_organization_id]
    end

    test "require_organization_permission_to! calls require_organization! first" do
      @controller.test_current_user = create_user!
      @controller.set_format(:html)

      @controller.require_organization_permission_to!(:invite_members)

      # Should redirect to no-org path, not unauthorized
      assert_equal "/organizations/new", @controller.redirected_to
    end

    test "unauthorized message includes role when role check fails" do
      org = Organizations::Organization.create!(name: "Msg Org")
      member = create_user!(email: "member@example.com")
      Organizations::Membership.create!(user: member, organization: org, role: "member")

      @controller.test_current_user = member
      @controller.session[:current_organization_id] = org.id
      @controller.set_format(:json)

      @controller.require_organization_role!(:admin)

      assert_includes @controller.rendered_json[:error], "admin"
    end

    test "unauthorized message includes permission when permission check fails" do
      org = Organizations::Organization.create!(name: "Perm Msg Org")
      viewer = create_user!(email: "viewer@example.com")
      Organizations::Membership.create!(user: viewer, organization: org, role: "viewer")

      @controller.test_current_user = viewer
      @controller.session[:current_organization_id] = org.id
      @controller.set_format(:json)

      @controller.require_organization_permission_to!(:invite_members)

      assert_includes @controller.rendered_json[:error].downcase, "invite members"
    end

    test "clear_organization_session! resets everything" do
      org, owner = create_org_with_owner!
      @controller.test_current_user = owner
      @controller.session[:current_organization_id] = org.id

      # Populate caches
      @controller.current_organization
      @controller.current_membership

      # Clear
      @controller.send(:clear_organization_session!)

      assert_nil @controller.session[:current_organization_id]
    end

    test "configured current_user_method is used" do
      Organizations.configure do |config|
        config.current_user_method = :logged_in_user
      end

      user = create_user!
      org = Organizations::Organization.create!(name: "Custom User Org")
      Organizations::Membership.create!(user: user, organization: org, role: "member")

      # Define the custom method on the controller
      @controller.define_singleton_method(:logged_in_user) { user }
      @controller.session[:current_organization_id] = org.id

      assert_equal org, @controller.current_organization
    end

    test "no_organization_path configuration is respected for default handler" do
      Organizations.configure do |config|
        config.no_organization_path = "/setup"
      end

      @controller.test_current_user = create_user!
      @controller.set_format(:html)

      @controller.require_organization!

      assert_equal "/setup", @controller.redirected_to
    end

    test "viewer role blocked from admin operations" do
      org = Organizations::Organization.create!(name: "Viewer Block Org")
      viewer = create_user!(email: "viewer@example.com")
      Organizations::Membership.create!(user: viewer, organization: org, role: "viewer")

      @controller.test_current_user = viewer
      @controller.session[:current_organization_id] = org.id
      @controller.set_format(:html)

      @controller.require_organization_admin!
      assert_not_nil @controller.redirected_to

      @controller.reset!
      @controller.session[:current_organization_id] = org.id

      @controller.require_organization_owner!
      assert_not_nil @controller.redirected_to
    end

    test "member role blocked from admin and owner operations" do
      org = Organizations::Organization.create!(name: "Member Block Org")
      member = create_user!(email: "member@example.com")
      Organizations::Membership.create!(user: member, organization: org, role: "member")

      @controller.test_current_user = member
      @controller.session[:current_organization_id] = org.id
      @controller.set_format(:html)

      @controller.require_organization_admin!
      assert_not_nil @controller.redirected_to, "member should be blocked from admin"

      @controller.reset!
      @controller.session[:current_organization_id] = org.id

      @controller.require_organization_owner!
      assert_not_nil @controller.redirected_to, "member should be blocked from owner"
    end

    test "on_unauthorized handler receives permission info for permission check" do
      handler_context = nil

      Organizations.configure do |config|
        config.on_unauthorized do |context|
          handler_context = context
        end
      end

      org = Organizations::Organization.create!(name: "Perm Handler Org")
      viewer = create_user!(email: "viewer@example.com")
      Organizations::Membership.create!(user: viewer, organization: org, role: "viewer")

      @controller.test_current_user = viewer
      @controller.session[:current_organization_id] = org.id

      @controller.require_organization_permission_to!(:manage_billing)

      assert_equal :manage_billing, handler_context.permission
      assert_nil handler_context.required_role
    end
  end
end
