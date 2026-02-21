# frozen_string_literal: true

require "test_helper"

module Organizations
  class InvitationAcceptanceResultTest < Organizations::Test
    def setup
      super
      @org, @owner = create_org_with_owner!
      @user = create_user!(email: "invitee@example.com")
      @invitation = @org.send_invite_to!("invitee@example.com", invited_by: @owner)
      @membership = Organizations::Membership.create!(user: @user, organization: @org, role: "member")
    end

    test "initializes with all required attributes" do
      result = InvitationAcceptanceResult.new(
        status: :accepted,
        invitation: @invitation,
        membership: @membership,
        switched: true
      )

      assert_equal :accepted, result.status
      assert_equal @invitation, result.invitation
      assert_equal @membership, result.membership
      assert result.switched?
    end

    test "switched defaults to false" do
      result = InvitationAcceptanceResult.new(
        status: :accepted,
        invitation: @invitation,
        membership: @membership
      )

      refute result.switched?
    end

    test "raises ArgumentError for invalid status" do
      assert_raises(ArgumentError) do
        InvitationAcceptanceResult.new(
          status: :invalid,
          invitation: @invitation,
          membership: @membership
        )
      end
    end

    test "accepted? returns true when status is :accepted" do
      result = InvitationAcceptanceResult.new(
        status: :accepted,
        invitation: @invitation,
        membership: @membership
      )

      assert result.accepted?
      refute result.already_member?
    end

    test "already_member? returns true when status is :already_member" do
      result = InvitationAcceptanceResult.new(
        status: :already_member,
        invitation: @invitation,
        membership: @membership
      )

      assert result.already_member?
      refute result.accepted?
    end

    test "switched? returns true when switched is true" do
      result = InvitationAcceptanceResult.new(
        status: :accepted,
        invitation: @invitation,
        membership: @membership,
        switched: true
      )

      assert result.switched?
    end

    test "switched? returns false when switched is false" do
      result = InvitationAcceptanceResult.new(
        status: :accepted,
        invitation: @invitation,
        membership: @membership,
        switched: false
      )

      refute result.switched?
    end

    test "switched? returns false when switched is nil" do
      result = InvitationAcceptanceResult.new(
        status: :accepted,
        invitation: @invitation,
        membership: @membership,
        switched: nil
      )

      refute result.switched?
    end

    test "status can be :already_member" do
      result = InvitationAcceptanceResult.new(
        status: :already_member,
        invitation: @invitation,
        membership: @membership,
        switched: false
      )

      assert_equal :already_member, result.status
    end
  end
end
