# frozen_string_literal: true

require "test_helper"

# The engine's invitation acceptance when a reissue changes the invitation at
# each try to lock its rows (Invitation::InvitationChanged): the person gets
# the localized "try again" message, not an error page, and nothing changes.
#
# Run: cd test/dummy && bin/rails test test/integration/invitation_changed_test.rb
class InvitationChangedTest < ActionDispatch::IntegrationTest
  setup do
    @owner = User.create!(email: "owner-#{SecureRandom.hex(4)}@example.com", name: "Owner")
    @org = Organizations::Organization.create_with_owner!(owner: @owner, name: "Sample Team")
    @other_inviter = User.create!(email: "admin-#{SecureRandom.hex(4)}@example.com", name: "Admin")
    @org.add_member!(@other_inviter, role: :admin)
    @guest = User.create!(email: "guest-#{SecureRandom.hex(4)}@example.com", name: "Guest")
    @invitation = @org.send_invite_to!(@guest.email, invited_by: @owner)
    signed_in_on_public_pages(@guest)
  end

  teardown do
    Organizations::PublicInvitationsController.remove_method(:warden)
  end

  test "HTML: the acceptance goes back to the invitation with the message, and nothing changes" do
    reissued_at_every_lock do
      post "/invitations/#{@invitation.token}/accept"
    end

    assert_redirected_to "/invitations/#{@invitation.token}"
    assert_equal Organizations.t(:"errors.invitation_changed", organization: @org), flash[:alert]
    assert_nothing_changed
  end

  test "JSON: the acceptance answers 409 with the message, and nothing changes" do
    reissued_at_every_lock do
      post "/invitations/#{@invitation.token}/accept", as: :json
    end

    assert_response 409
    assert_equal({ "error" => Organizations.t(:"errors.invitation_changed", organization: @org) }, response.parsed_body)
    assert_nothing_changed
  end

  private

  # The engine's public pages inherit ActionController::Base, so they do not
  # read the dummy's demo session. A host with Devise signs people in
  # through Warden, which the public pages ask first. This stands in for it.
  def signed_in_on_public_pages(user)
    warden = Object.new
    warden.define_singleton_method(:user) { |_scope = nil| user }
    Organizations::PublicInvitationsController.define_method(:warden) { warden }
  end

  # Each row lock of an invitation reads a row that names the other inviter
  # than the one just locked, as a reissue in another connection at each
  # try would.
  def reissued_at_every_lock
    ids = [@owner.id, @other_inviter.id]
    original = Organizations::Invitation.instance_method(:lock!)
    Organizations::Invitation.define_method(:lock!) do |*args|
      self.class.where(id: id).update_all(invited_by_id: (ids - [invited_by_id]).first)
      original.bind_call(self, *args)
    end
    yield
  ensure
    Organizations::Invitation.remove_method(:lock!)
  end

  def assert_nothing_changed
    refute Organizations::Membership.exists?(user_id: @guest.id, organization_id: @org.id)
    @invitation.reload
    refute_predicate @invitation, :accepted?
    assert_equal @owner.id, @invitation.invited_by_id
  end
end
