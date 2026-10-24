# frozen_string_literal: true

require "test_helper"

# The engine's organization deletion when config.retain_organization keeps
# the organization: the controller answers like a refused form, not with an
# error page, and nothing changes (the organization, its members, its
# invitations, the current organization in the session).
#
# Run: cd test/dummy && bin/rails test test/integration/retained_organization_test.rb
class RetainedOrganizationTest < ActionDispatch::IntegrationTest
  setup do
    @saved_config = Organizations.configuration
    Organizations.configuration = @saved_config.dup
    # The fictional rule of this test: a flag in the organization's metadata.
    Organizations.configure { |config| config.retain_organization = ->(org) { org.metadata["retain"] == true } }

    @owner = User.create!(email: "owner-#{SecureRandom.hex(4)}@example.com", name: "Owner")
    @org = Organizations::Organization.create_with_owner!(owner: @owner, name: "Kept Books",
                                                          metadata: { "retain" => true })
    @org.add_member!(User.create!(email: "member-#{SecureRandom.hex(4)}@example.com", name: "Member"))
    @invitation = @org.send_invite_to!("guest-#{SecureRandom.hex(4)}@example.com", invited_by: @owner)

    post switch_user_path, params: { email: @owner.email }
    post "/organizations/switch/#{@org.id}"
  end

  teardown do
    Organizations.configuration = @saved_config
  end

  test "HTML: the deletion goes back with the reason, and nothing changes" do
    delete "/organizations/#{@org.id}", headers: { "HTTP_REFERER" => "http://www.example.com/organizations/#{@org.id}/edit" }

    assert_redirected_to "http://www.example.com/organizations/#{@org.id}/edit"
    assert_equal Organizations.t(:"errors.organization_retained", organization: @org), flash[:alert]
    assert_everything_kept
  end

  test "JSON: the deletion answers 422 with the reason, and nothing changes" do
    delete "/organizations/#{@org.id}", as: :json

    assert_response 422
    assert_equal({ "error" => Organizations.t(:"errors.organization_retained", organization: @org) }, response.parsed_body)
    assert_everything_kept
  end

  private

  def assert_everything_kept
    assert Organizations::Organization.exists?(@org.id)
    assert_equal 2, @org.memberships.count
    assert_equal @owner, @org.reload.owner
    assert Organizations::Invitation.exists?(@invitation.id)
    assert_equal @org.id, session[:current_organization_id]
  end
end
