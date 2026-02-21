# frozen_string_literal: true

require "test_helper"

module Organizations
  class InvitationAcceptanceFailureTest < Organizations::Test
    test "initializes with reason and invitation" do
      org, owner = create_org_with_owner!
      invitation = org.send_invite_to!("invitee@example.com", invited_by: owner)

      failure = InvitationAcceptanceFailure.new(
        reason: :email_mismatch,
        invitation: invitation
      )

      assert_equal :email_mismatch, failure.reason
      assert_equal invitation, failure.invitation
      assert failure.email_mismatch?
    end

    test "raises for invalid reason" do
      assert_raises(ArgumentError) do
        InvitationAcceptanceFailure.new(reason: :invalid_reason)
      end
    end

    test "exposes unified success and failure helpers" do
      failure = InvitationAcceptanceFailure.new(reason: :missing_token)

      refute failure.success?
      assert failure.failure?
      assert_equal :missing_token, failure.failure_reason
      assert failure.missing_token?
      refute failure.missing_user?
    end
  end
end
