# frozen_string_literal: true

require "test_helper"

# The engine controllers over HTTP: a custom role that may invite members and
# edit member roles still cannot reach a role above its own with a crafted
# request. The rule lives in the models; this pins that the controllers turn
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

  private

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
