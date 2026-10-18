# frozen_string_literal: true

require "test_helper"

# The engine controllers and reference views over HTTP: a custom role that may
# invite members, edit member roles and remove members still cannot act on a
# role above its own with a crafted request, and the views only offer what it
# may do. The rule lives in the models; this pins that the controllers turn
# the refusal into their usual alert and 422 instead of an error page.
#
# Run: cd test/dummy && bin/rails test test/integration/role_assignment_cap_test.rb
class RoleAssignmentCapTest < ActionDispatch::IntegrationTest
  setup do
    @saved_config = Organizations.configuration
    Organizations.configuration = @saved_config.dup
    Organizations.configure do |config|
      config.roles do
        role :lead, inherits: :member do
          can :invite_members
          can :edit_member_roles
          can :remove_members
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

  test "a crafted admin invitation is refused with the form's 422" do
    post "/invitations", params: { invitation: { email: "crafted@example.com", role: "admin" } }

    assert_response :unprocessable_entity
    assert_equal 0, @org.invitations.count
  end

  test "a crafted admin invitation over JSON is refused with a 422 and the reason" do
    post "/invitations", params: { invitation: { email: "crafted@example.com", role: "admin" } }, as: :json

    assert_response :unprocessable_entity
    assert_equal Organizations.t(:"errors.invite_role_outranks_actor", role: Organizations.t(:"roles.admin")),
                 response.parsed_body["error"]
    assert_equal 0, @org.invitations.count
  end

  test "a crafted owner invitation is refused with the form's 422, not an error page" do
    post "/invitations", params: { invitation: { email: "crafted@example.com", role: "owner" } }

    assert_response :unprocessable_entity
    assert_equal 0, @org.invitations.count
  end

  test "the lead can still invite to a role at or below its own" do
    post "/invitations", params: { invitation: { email: "fine@example.com", role: "lead" } }

    assert_response :redirect
    assert_equal "lead", @org.invitations.find_by!(email: "fine@example.com").role
  end

  test "a crafted promotion of a viewer to admin is refused with an alert" do
    patch "/memberships/#{membership_of(@viewer).id}", params: { membership: { role: "admin" } }

    assert_response :redirect
    assert_equal Organizations.t(:"errors.role_change_outranks_actor", role: Organizations.t(:"roles.admin")),
                 flash[:alert]
    assert_equal "viewer", membership_of(@viewer).role
  end

  test "a crafted demotion of an admin is refused with a 422 over JSON" do
    patch "/memberships/#{membership_of(@admin).id}", params: { membership: { role: "viewer" } }, as: :json

    assert_response :unprocessable_entity
    assert_equal "admin", membership_of(@admin).role
  end

  test "the lead can still move a viewer up to its own role" do
    patch "/memberships/#{membership_of(@viewer).id}", params: { membership: { role: "lead" } }, as: :json

    assert_response :ok
    assert_equal "lead", membership_of(@viewer).role
  end

  test "a crafted removal of an admin is refused with an alert" do
    delete "/memberships/#{membership_of(@admin).id}"

    assert_response :redirect
    assert_equal Organizations.t(:"errors.member_removal_outranks_actor", role: Organizations.t(:"roles.admin")),
                 flash[:alert]
    assert @org.has_member?(@admin)
  end

  test "a crafted removal of an admin is refused with a 422 over JSON" do
    delete "/memberships/#{membership_of(@admin).id}", as: :json

    assert_response :unprocessable_entity
    assert @org.has_member?(@admin)
  end

  test "the lead can still remove a viewer" do
    delete "/memberships/#{membership_of(@viewer).id}", as: :json

    assert_response :no_content
    refute @org.has_member?(@viewer)
  end

  test "a crafted revoke of an admin invitation is refused with an alert" do
    invitation = @org.send_invite_to!("admin-invite@example.com", invited_by: @owner, role: :admin)

    delete "/invitations/#{invitation.id}"

    assert_response :redirect
    assert_equal Organizations.t(:"errors.invitation_management_outranks_actor", role: Organizations.t(:"roles.admin")),
                 flash[:alert]
    assert Organizations::Invitation.exists?(invitation.id)
  end

  test "a crafted revoke of an admin invitation is refused with a 422 over JSON" do
    invitation = @org.send_invite_to!("admin-invite@example.com", invited_by: @owner, role: :admin)

    delete "/invitations/#{invitation.id}", as: :json

    assert_response :unprocessable_entity
    assert Organizations::Invitation.exists?(invitation.id)
  end

  test "a crafted resend of an admin invitation is refused with an alert, and over JSON with a 422" do
    invitation = @org.send_invite_to!("admin-invite@example.com", invited_by: @owner, role: :admin)
    token = invitation.token

    post "/invitations/#{invitation.id}/resend"
    assert_response :redirect
    assert_equal Organizations.t(:"errors.invitation_management_outranks_actor", role: Organizations.t(:"roles.admin")),
                 flash[:alert]

    post "/invitations/#{invitation.id}/resend", as: :json
    assert_response :unprocessable_entity
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

  test "the invitation form offers the lead only roles at or below its own" do
    get "/invitations/new"

    assert_response :ok
    assert_equal %w[lead member viewer], role_options('select[name="invitation[role]"]')
  end

  test "the invitation form offers an admin every role but owner" do
    sign_in_as @admin.email
    get "/invitations/new"

    assert_response :ok
    assert_equal %w[admin lead member viewer], role_options('select[name="invitation[role]"]')
  end

  test "the members page gives the lead no controls on an admin, and no admin option elsewhere" do
    get "/memberships"

    assert_response :ok
    assert_select "form[action='/memberships/#{membership_of(@admin).id}']", count: 0
    assert_select "form[action='/memberships/#{membership_of(@viewer).id}'] select[name='membership[role]']" do |selects|
      options = selects.first.css("option").map { |option| option["value"] }
      assert_equal %w[lead member viewer], options
    end
  end

  test "the invitations page gives the lead no actions on an admin invitation" do
    admin_invite = @org.send_invite_to!("admin-invite@example.com", invited_by: @owner, role: :admin)
    member_invite = @org.send_invite_to!("member-invite@example.com", invited_by: @owner, role: :member)

    get "/invitations"

    assert_response :ok
    assert_select "form[action='/invitations/#{admin_invite.id}/resend']", count: 0
    assert_select "form[action='/invitations/#{admin_invite.id}']", count: 0
    assert_select "form[action='/invitations/#{member_invite.id}/resend']", count: 1
    assert_select "form[action='/invitations/#{member_invite.id}']", count: 1
  end

  private

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
