# frozen_string_literal: true

require "test_helper"

# The engine controllers and reference views over HTTP: a custom role that may
# invite members, edit member roles and remove members still cannot act on a
# role above its own, or on a sibling role with permissions it lacks, with a
# crafted request, and the views only offer what it may do. The rule lives in
# the models; this pins that the controllers answer a refusal like a failed
# permission guard (through config.unauthorized_handler) instead of an error
# page.
#
# Run: cd test/dummy && bin/rails test test/integration/role_assignment_cap_test.rb
class RoleAssignmentCapTest < ActionDispatch::IntegrationTest
  # Refusals seen by the unauthorized handler installed below.
  REFUSALS = [] # rubocop:disable Style/MutableConstant -- reset in setup, read by the tests

  setup do
    REFUSALS.clear
    @saved_config = Organizations.configuration
    Organizations.configuration = @saved_config.dup
    Organizations.configure do |config|
      config.roles do
        role :lead, inherits: :member do
          can :invite_members
          can :edit_member_roles
          can :remove_members
        end
        # Defined after lead with the same parent, so it ranks below lead,
        # but it has permissions lead lacks.
        role :finance, inherits: :member do
          can :view_billing
          can :manage_settings
        end
      end
      # Mirrors the gem's default answer (alert, or 403 over JSON) and records
      # what the handler sees.
      config.on_unauthorized do |context|
        REFUSALS << context
        respond_to do |format|
          format.html { redirect_back fallback_location: "/", alert: context.metadata&.dig(:message) }
          format.json { render json: { error: context.metadata&.dig(:message) }, status: :forbidden }
        end
      end
    end

    @owner = User.create!(email: "owner-#{SecureRandom.hex(4)}@example.com", name: "Owner")
    @org = Organizations::Organization.create_with_owner!(owner: @owner, name: "Role Cap Org")
    @lead = member!("lead")
    @admin = member!("admin")
    @viewer = member!("viewer")
    sign_in_as @lead.email
  end

  teardown do
    Organizations.configuration = @saved_config
  end

  # ── Invitations ────────────────────────────────────────────────────────

  test "a crafted admin invitation goes through the unauthorized handler with the reason" do
    post "/invitations", params: { invitation: { email: "crafted@example.com", role: "admin" } }

    assert_response :redirect
    assert_equal outranks(:invite_role_outranks_actor, "admin"), flash[:alert]
    assert_equal 1, REFUSALS.size
    assert_equal :invite_members, REFUSALS.first.permission
    assert_equal @org, REFUSALS.first.organization
    assert_equal 0, @org.invitations.count
  end

  test "a crafted admin invitation over JSON is refused with a 403 and the reason" do
    post "/invitations", params: { invitation: { email: "crafted@example.com", role: "admin" } }, as: :json

    assert_response :forbidden
    assert_equal outranks(:invite_role_outranks_actor, "admin"), response.parsed_body["error"]
    assert_equal 0, @org.invitations.count
  end

  test "a crafted invitation to a sibling role with other permissions is refused with a 403" do
    post "/invitations", params: { invitation: { email: "crafted@example.com", role: "finance" } }, as: :json

    assert_response :forbidden
    assert_equal lacks("finance"), response.parsed_body["error"]
    assert_equal 0, @org.invitations.count
  end

  test "a crafted owner invitation is refused with the form's 422, not an error page" do
    post "/invitations", params: { invitation: { email: "crafted@example.com", role: "owner" } }

    assert_response 422
    assert_equal 0, @org.invitations.count
  end

  test "the lead can still invite to a role at or below its own" do
    post "/invitations", params: { invitation: { email: "fine@example.com", role: "lead" } }

    assert_response :redirect
    assert_equal "lead", @org.invitations.find_by!(email: "fine@example.com").role
  end

  # ── Role changes ───────────────────────────────────────────────────────

  test "a crafted promotion of a viewer to admin is refused with an alert" do
    patch "/memberships/#{membership_of(@viewer).id}", params: { membership: { role: "admin" } }

    assert_response :redirect
    assert_equal outranks(:role_change_outranks_actor, "admin"), flash[:alert]
    assert_equal :edit_member_roles, REFUSALS.first.permission
    assert_equal "viewer", membership_of(@viewer).role
  end

  test "a crafted promotion to a sibling role with other permissions is refused" do
    patch "/memberships/#{membership_of(@viewer).id}", params: { membership: { role: "finance" } }

    assert_response :redirect
    assert_equal lacks("finance"), flash[:alert]
    assert_equal "viewer", membership_of(@viewer).role
  end

  test "a crafted demotion of an admin is refused with a 403 over JSON" do
    patch "/memberships/#{membership_of(@admin).id}", params: { membership: { role: "viewer" } }, as: :json

    assert_response :forbidden
    assert_equal "admin", membership_of(@admin).role
  end

  test "a crafted change of your own role is refused with a 403, not an error page" do
    patch "/memberships/#{membership_of(@lead).id}", params: { membership: { role: "viewer" } }, as: :json

    assert_response :forbidden
    assert_equal Organizations.t(:"errors.cannot_change_own_role"), response.parsed_body["error"]
    assert_equal "lead", membership_of(@lead).role
  end

  test "the lead can still move a viewer up to its own role" do
    patch "/memberships/#{membership_of(@viewer).id}", params: { membership: { role: "lead" } }, as: :json

    assert_response :ok
    assert_equal "lead", membership_of(@viewer).role
  end

  # ── Removals ───────────────────────────────────────────────────────────

  test "a crafted removal of an admin is refused with an alert" do
    delete "/memberships/#{membership_of(@admin).id}"

    assert_response :redirect
    assert_equal outranks(:member_removal_outranks_actor, "admin"), flash[:alert]
    assert_equal :remove_members, REFUSALS.first.permission
    assert @org.has_member?(@admin)
  end

  test "a crafted removal of an admin is refused with a 403 over JSON" do
    delete "/memberships/#{membership_of(@admin).id}", as: :json

    assert_response :forbidden
    assert @org.has_member?(@admin)
  end

  test "a crafted removal of a sibling role with other permissions is refused" do
    finance = member!("finance")

    delete "/memberships/#{membership_of(finance).id}", as: :json

    assert_response :forbidden
    assert @org.has_member?(finance)
  end

  test "the lead can still remove a viewer" do
    delete "/memberships/#{membership_of(@viewer).id}", as: :json

    assert_response :no_content
    refute @org.has_member?(@viewer)
  end

  # ── Invitation management ──────────────────────────────────────────────

  test "a crafted revoke of an admin invitation is refused with an alert" do
    invitation = admin_invitation

    delete "/invitations/#{invitation.id}"

    assert_response :redirect
    assert_equal outranks(:invitation_management_outranks_actor, "admin"), flash[:alert]
    assert Organizations::Invitation.exists?(invitation.id)
  end

  test "a crafted revoke of an admin invitation is refused with a 403 over JSON" do
    invitation = admin_invitation

    delete "/invitations/#{invitation.id}", as: :json

    assert_response :forbidden
    assert Organizations::Invitation.exists?(invitation.id)
  end

  test "a crafted resend of an admin invitation is refused with an alert, and over JSON with a 403" do
    invitation = admin_invitation
    token = invitation.token

    post "/invitations/#{invitation.id}/resend"

    assert_response :redirect
    assert_equal outranks(:invitation_management_outranks_actor, "admin"), flash[:alert]

    post "/invitations/#{invitation.id}/resend", as: :json

    assert_response :forbidden
    assert_equal token, invitation.reload.token
  end

  test "the lead can still resend and revoke an invitation for a role below its own" do
    invitation = @org.send_invite_to!("member-invite@example.com", invited_by: @owner, role: :member)

    post "/invitations/#{invitation.id}/resend", as: :json

    assert_response :ok

    delete "/invitations/#{invitation.id}", as: :json

    assert_response :no_content
    refute Organizations::Invitation.exists?(invitation.id)
  end

  # ── The reference views offer only what the viewer may do ──────────────

  test "the invitation form offers the lead only roles it may act on" do
    get "/invitations/new"

    assert_response :ok
    assert_equal %w[lead member viewer], role_options('select[name="invitation[role]"]')
  end

  test "the invitation form offers an admin every role but owner" do
    sign_in_as @admin.email
    get "/invitations/new"

    assert_response :ok
    assert_equal %w[admin lead finance member viewer], role_options('select[name="invitation[role]"]')
  end

  test "the members page gives the lead no controls on an admin or a finance member" do
    finance = member!("finance")

    get "/memberships"

    assert_response :ok
    assert_select "form[action='/memberships/#{membership_of(@admin).id}']", count: 0
    assert_select "form[action='/memberships/#{membership_of(finance).id}']", count: 0
    assert_equal %w[lead member viewer],
                 role_options("form[action='/memberships/#{membership_of(@viewer).id}'] select[name='membership[role]']")
  end

  test "the members page gives a member with only view_members no controls at all" do
    plain = member!("member")
    sign_in_as plain.email

    get "/memberships"

    assert_response :ok
    assert_select "form[action='/memberships/#{membership_of(@viewer).id}']", count: 0
    assert_select "select[name='membership[role]']", count: 0
  end

  test "the members page shows the picker but no trash button without remove_members" do
    Organizations.configure do |config|
      config.roles do
        role :editor, inherits: :member do
          can :edit_member_roles
        end
      end
    end
    editor = member!("editor")
    sign_in_as editor.email

    get "/memberships"

    assert_response :ok
    viewer_form = "form[action='/memberships/#{membership_of(@viewer).id}']"
    assert_select "#{viewer_form} select[name='membership[role]']", count: 1
    assert_select "#{viewer_form} input[name='_method'][value='delete']", count: 0
  end

  test "the invitations page gives the lead no actions on an admin invitation" do
    admin_invite = admin_invitation
    member_invite = @org.send_invite_to!("member-invite@example.com", invited_by: @owner, role: :member)

    get "/invitations"

    assert_response :ok
    assert_select "form[action='/invitations/#{admin_invite.id}/resend']", count: 0
    assert_select "form[action='/invitations/#{admin_invite.id}']", count: 0
    assert_select "form[action='/invitations/#{member_invite.id}/resend']", count: 1
    assert_select "form[action='/invitations/#{member_invite.id}']", count: 1
  end

  private

  def outranks(key, role)
    Organizations.t(:"errors.#{key}", role: Organizations.t(:"roles.#{role}", default: role.humanize))
  end

  def lacks(role)
    Organizations.t(:"errors.role_has_permissions_actor_lacks", role: role.humanize)
  end

  def admin_invitation
    @org.send_invite_to!("admin-invite@example.com", invited_by: @owner, role: :admin)
  end

  def role_options(select_selector)
    # A required select carries a blank prompt option; only the roles matter here.
    css_select("#{select_selector} option").map { |option| option["value"] }.compact_blank
  end

  def member!(role)
    user = User.create!(email: "#{role}-#{SecureRandom.hex(4)}@example.com", name: role.capitalize)
    Organizations::Membership.create!(user: user, organization: @org, role: role)
    user
  end

  def membership_of(user)
    @org.memberships.find_by!(user_id: user.id)
  end

  def sign_in_as(email)
    post switch_user_path, params: { email: email }
  end
end
