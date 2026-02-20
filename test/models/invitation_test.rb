# frozen_string_literal: true

require "test_helper"

module Organizations
  class InvitationTest < Organizations::Test
    # =========================================================================
    # Table Configuration
    # =========================================================================

    test "table_name is organizations_invitations" do
      assert_equal "organizations_invitations", Organizations::Invitation.table_name
    end

    # =========================================================================
    # Setup
    # =========================================================================

    def setup
      super
      @org, @owner = create_org_with_owner!(name: "Acme Corp")
      @invitee = create_user!(email: "invitee@example.com", name: "Invitee")
    end

    # Helper to create an invitation directly
    def create_test_invitation(
      organization: @org,
      email: "invited@example.com",
      invited_by: @owner,
      role: "member",
      expires_at: 7.days.from_now,
      accepted_at: nil
    )
      Organizations::Invitation.create!(
        organization: organization,
        email: email,
        invited_by: invited_by,
        role: role,
        expires_at: expires_at,
        accepted_at: accepted_at
      )
    end

    # =========================================================================
    # Associations
    # =========================================================================

    test "belongs_to organization" do
      invitation = create_test_invitation
      assert_equal @org, invitation.organization
    end

    test "belongs_to invited_by" do
      invitation = create_test_invitation(invited_by: @owner)
      assert_equal @owner, invitation.invited_by
    end

    test "invited_by is optional (inviter can be nil)" do
      invitation = create_test_invitation(invited_by: nil)
      assert_nil invitation.invited_by
      assert invitation.persisted?
    end

    # =========================================================================
    # Alias: from
    # =========================================================================

    test "from is an alias for invited_by" do
      invitation = create_test_invitation(invited_by: @owner)
      assert_equal invitation.invited_by, invitation.from
      assert_equal @owner, invitation.from
    end

    test "from returns nil when inviter is nil" do
      invitation = create_test_invitation(invited_by: nil)
      assert_nil invitation.from
    end

    # =========================================================================
    # Attributes & Defaults
    # =========================================================================

    test "email is normalized to lowercase and stripped" do
      invitation = create_test_invitation(email: "  USER@EXAMPLE.COM  ")
      assert_equal "user@example.com", invitation.email
    end

    test "email normalization handles mixed case" do
      invitation = create_test_invitation(email: "John.Doe@Company.COM")
      assert_equal "john.doe@company.com", invitation.email
    end

    test "email normalization strips leading and trailing whitespace" do
      invitation = create_test_invitation(email: "\t hello@world.com \n")
      assert_equal "hello@world.com", invitation.email
    end

    test "token is auto-generated on create" do
      invitation = create_test_invitation
      assert_not_nil invitation.token
      assert invitation.token.length > 0
    end

    test "token is unique" do
      inv1 = create_test_invitation(email: "a@example.com")
      inv2 = create_test_invitation(email: "b@example.com")
      refute_equal inv1.token, inv2.token
    end

    test "role defaults to member" do
      invitation = Organizations::Invitation.new(
        organization: @org,
        email: "test@example.com",
        invited_by: @owner
      )
      # The default comes from the database column default
      assert_equal "member", invitation.role
    end

    test "expires_at is auto-set based on invitation_expiry config" do
      Organizations.configure do |config|
        config.invitation_expiry = 3.days
      end

      invitation = create_test_invitation(email: "expiry-test@example.com", expires_at: nil)
      # Should be approximately 3 days from now
      assert_in_delta 3.days.from_now.to_f, invitation.expires_at.to_f, 5.0
    end

    test "expires_at is nil when invitation_expiry config is nil" do
      Organizations.configure do |config|
        config.invitation_expiry = nil
      end

      invitation = create_test_invitation(email: "no-expiry@example.com", expires_at: nil)
      assert_nil invitation.expires_at
    end

    test "accepted_at is nil by default" do
      invitation = create_test_invitation
      assert_nil invitation.accepted_at
    end

    # =========================================================================
    # Validations
    # =========================================================================

    test "requires email" do
      invitation = Organizations::Invitation.new(
        organization: @org,
        invited_by: @owner,
        email: nil
      )
      refute invitation.valid?
      assert_includes invitation.errors[:email], "can't be blank"
    end

    test "requires valid email format" do
      invitation = Organizations::Invitation.new(
        organization: @org,
        invited_by: @owner,
        email: "not-an-email"
      )
      refute invitation.valid?
      assert invitation.errors[:email].any?
    end

    test "requires role" do
      invitation = Organizations::Invitation.new(
        organization: @org,
        invited_by: @owner,
        email: "test@example.com",
        role: nil
      )
      refute invitation.valid?
      assert invitation.errors[:role].any?
    end

    test "role must be a valid role from hierarchy" do
      invitation = Organizations::Invitation.new(
        organization: @org,
        invited_by: @owner,
        email: "test@example.com",
        role: "superadmin"
      )
      refute invitation.valid?
      assert invitation.errors[:role].any?
    end

    test "accepts valid roles from hierarchy" do
      %w[owner admin member viewer].each do |valid_role|
        invitation = Organizations::Invitation.new(
          organization: @org,
          invited_by: @owner,
          email: "#{valid_role}-test@example.com",
          role: valid_role
        )
        # Just check role validation passes (other validations may still fail)
        invitation.valid?
        refute_includes invitation.errors[:role].map(&:to_s), "is not included in the list",
          "Role '#{valid_role}' should be valid"
      end
    end

    test "token presence is validated" do
      invitation = Organizations::Invitation.new(
        organization: @org,
        invited_by: @owner,
        email: "test@example.com"
      )
      # Token is auto-generated by before_validation, so it should always be present
      # after validation runs. We verify the validation exists by checking the model.
      assert invitation.valid?
      assert_not_nil invitation.token, "Token should be auto-generated by before_validation"
    end

    # =========================================================================
    # Uniqueness: one pending invitation per email per org
    # =========================================================================

    test "cannot create duplicate pending invitation for same email in same org" do
      create_test_invitation(email: "dup@example.com")

      assert_raises(ActiveRecord::RecordInvalid) do
        create_test_invitation(email: "dup@example.com")
      end
    end

    test "duplicate check is case-insensitive" do
      create_test_invitation(email: "dup@example.com")

      assert_raises(ActiveRecord::RecordInvalid) do
        create_test_invitation(email: "DUP@Example.COM")
      end
    end

    test "accepted invitation does not block new invite to same email" do
      first_invitation = create_test_invitation(email: @invitee.email)
      first_invitation.accept!(@invitee)

      # Should be able to create a new invitation to the same email
      # (after removing membership to make this scenario valid)
      Organizations::Membership.find_by(user: @invitee, organization: @org)&.destroy

      new_invitation = create_test_invitation(email: @invitee.email)
      assert new_invitation.persisted?
    end

    test "same email can be invited to different organizations" do
      org2 = Organizations::Organization.create!(name: "Other Org")
      Organizations::Membership.create!(user: @owner, organization: org2, role: "admin")

      inv1 = create_test_invitation(organization: @org, email: "shared@example.com")
      inv2 = create_test_invitation(organization: org2, email: "shared@example.com")

      assert inv1.persisted?
      assert inv2.persisted?
    end

    # =========================================================================
    # Status Methods
    # =========================================================================

    test "pending? returns true for fresh invitation" do
      invitation = create_test_invitation
      assert invitation.pending?
    end

    test "pending? returns false for accepted invitation" do
      invitation = create_test_invitation(email: @invitee.email)
      invitation.accept!(@invitee)
      refute invitation.pending?
    end

    test "pending? returns false for expired invitation" do
      invitation = create_test_invitation

      travel_to 8.days.from_now do
        refute invitation.pending?
      end
    end

    test "accepted? returns false for fresh invitation" do
      invitation = create_test_invitation
      refute invitation.accepted?
    end

    test "accepted? returns true after acceptance" do
      invitation = create_test_invitation(email: @invitee.email)
      invitation.accept!(@invitee)
      assert invitation.accepted?
    end

    test "expired? returns false for fresh invitation" do
      invitation = create_test_invitation
      refute invitation.expired?
    end

    test "expired? returns true when past expires_at" do
      invitation = create_test_invitation(expires_at: 1.hour.ago)
      assert invitation.expired?
    end

    test "expired? returns false when expires_at is nil" do
      invitation = create_test_invitation(expires_at: nil)
      refute invitation.expired?
    end

    test "expired? returns false when expires_at is in the future" do
      invitation = create_test_invitation(expires_at: 1.day.from_now)
      refute invitation.expired?
    end

    test "status returns :pending for fresh invitation" do
      invitation = create_test_invitation
      assert_equal :pending, invitation.status
    end

    test "status returns :accepted after acceptance" do
      invitation = create_test_invitation(email: @invitee.email)
      invitation.accept!(@invitee)
      assert_equal :accepted, invitation.status
    end

    test "status returns :expired for expired invitation" do
      invitation = create_test_invitation(expires_at: 1.minute.ago)
      assert_equal :expired, invitation.status
    end

    test "status returns :accepted even if expired (accepted takes precedence)" do
      invitation = create_test_invitation(email: @invitee.email, expires_at: 1.day.from_now)
      invitation.accept!(@invitee)

      travel_to 2.days.from_now do
        assert_equal :accepted, invitation.status
      end
    end

    # =========================================================================
    # Scopes
    # =========================================================================

    test "pending scope returns non-accepted non-expired invitations" do
      pending_inv = create_test_invitation(email: "pending@example.com", expires_at: 7.days.from_now)

      accepted_inv = create_test_invitation(email: @invitee.email)
      accepted_inv.accept!(@invitee)

      expired_inv = create_test_invitation(email: "expired@example.com", expires_at: 1.hour.ago)

      results = Organizations::Invitation.pending
      assert_includes results, pending_inv
      refute_includes results, accepted_inv
      refute_includes results, expired_inv
    end

    test "pending scope includes invitations with nil expires_at" do
      invitation = create_test_invitation(email: "never-expires@example.com", expires_at: nil)
      results = Organizations::Invitation.pending
      assert_includes results, invitation
    end

    test "expired scope returns only expired non-accepted invitations" do
      pending_inv = create_test_invitation(email: "still-pending@example.com", expires_at: 7.days.from_now)
      expired_inv = create_test_invitation(email: "expired@example.com", expires_at: 1.hour.ago)

      results = Organizations::Invitation.expired
      assert_includes results, expired_inv
      refute_includes results, pending_inv
    end

    test "expired scope excludes accepted invitations" do
      invitation = create_test_invitation(email: @invitee.email, expires_at: 1.day.from_now)
      invitation.accept!(@invitee)

      travel_to 2.days.from_now do
        results = Organizations::Invitation.expired
        refute_includes results, invitation
      end
    end

    test "accepted scope returns only accepted invitations" do
      pending_inv = create_test_invitation(email: "pending@example.com")

      accepted_inv = create_test_invitation(email: @invitee.email)
      accepted_inv.accept!(@invitee)

      results = Organizations::Invitation.accepted
      assert_includes results, accepted_inv
      refute_includes results, pending_inv
    end

    test "for_email scope matches case-insensitively" do
      invitation = create_test_invitation(email: "CasE@Example.COM")

      results = Organizations::Invitation.for_email("case@example.com")
      assert_includes results, invitation
    end

    test "for_email scope strips whitespace" do
      invitation = create_test_invitation(email: "padded@example.com")

      results = Organizations::Invitation.for_email("  padded@example.com  ")
      assert_includes results, invitation
    end

    test "for_email scope returns empty for non-matching email" do
      create_test_invitation(email: "exists@example.com")

      results = Organizations::Invitation.for_email("missing@example.com")
      assert_empty results
    end

    # =========================================================================
    # Token Generation
    # =========================================================================

    test "auto-generated token is URL-safe base64" do
      invitation = create_test_invitation
      # urlsafe_base64 uses only alphanumeric, hyphens, and underscores
      assert_match(/\A[A-Za-z0-9_-]+={0,2}\z/, invitation.token)
    end

    test "auto-generated token has reasonable length" do
      invitation = create_test_invitation
      # SecureRandom.urlsafe_base64(32) produces ~43 characters
      assert invitation.token.length >= 20
    end

    test "token collision handling generates unique token via loop" do
      existing = create_test_invitation(email: "first@example.com")

      # Stub SecureRandom to return the existing token first, then a new one
      collision_token = existing.token
      call_count = 0

      SecureRandom.stub(:urlsafe_base64, ->(_n = nil) {
        call_count += 1
        if call_count == 1
          collision_token
        else
          "unique_token_#{SecureRandom.hex(8)}"
        end
      }) do
        new_inv = create_test_invitation(email: "second@example.com")
        assert new_inv.persisted?
        refute_equal collision_token, new_inv.token
      end
    end

    # =========================================================================
    # Accept Flow
    # =========================================================================

    test "accept! creates a membership" do
      invitation = create_test_invitation(email: @invitee.email)

      assert_difference -> { Organizations::Membership.count }, 1 do
        invitation.accept!(@invitee)
      end
    end

    test "accept! returns the membership" do
      invitation = create_test_invitation(email: @invitee.email)
      result = invitation.accept!(@invitee)

      assert_instance_of Organizations::Membership, result
      assert_equal @invitee, result.user
      assert_equal @org, result.organization
    end

    test "accept! sets accepted_at" do
      invitation = create_test_invitation(email: @invitee.email)

      freeze_time do
        invitation.accept!(@invitee)
        invitation.reload
        assert_equal Time.current, invitation.accepted_at
      end
    end

    test "accept! creates membership with correct role" do
      invitation = create_test_invitation(email: @invitee.email, role: "admin")
      membership = invitation.accept!(@invitee)

      assert_equal "admin", membership.role
    end

    test "accept! creates membership with invited_by set" do
      invitation = create_test_invitation(email: @invitee.email, invited_by: @owner)
      membership = invitation.accept!(@invitee)

      assert_equal @owner, membership.invited_by
    end

    test "accept! with explicit user parameter" do
      invitation = create_test_invitation(email: @invitee.email)
      membership = invitation.accept!(@invitee)

      assert_equal @invitee, membership.user
    end

    test "accept! validates email matches user email (case-insensitive)" do
      invitation = create_test_invitation(email: "INVITEE@EXAMPLE.COM")
      # @invitee has email "invitee@example.com" which should match case-insensitively
      membership = invitation.accept!(@invitee)

      assert_instance_of Organizations::Membership, membership
    end

    test "accept! raises EmailMismatch when emails do not match" do
      invitation = create_test_invitation(email: "someone-else@example.com")

      assert_raises(Organizations::Invitation::EmailMismatch) do
        invitation.accept!(@invitee)
      end
    end

    test "accept! with skip_email_validation bypasses email check" do
      invitation = create_test_invitation(email: "different@example.com")
      membership = invitation.accept!(@invitee, skip_email_validation: true)

      assert_instance_of Organizations::Membership, membership
      assert_equal @invitee, membership.user
    end

    test "accept! with owner role raises CannotAcceptAsOwner" do
      invitation = create_test_invitation(email: @invitee.email, role: "admin")
      # Manually update to owner role to bypass validation that might prevent it
      invitation.update_column(:role, "owner")

      assert_raises(Organizations::Invitation::CannotAcceptAsOwner) do
        invitation.accept!(@invitee)
      end
    end

    test "accept! for already-accepted invitation returns existing membership" do
      invitation = create_test_invitation(email: @invitee.email)
      original_membership = invitation.accept!(@invitee)

      # Accepting again should return the existing membership
      result = invitation.accept!(@invitee)
      assert_equal original_membership, result
    end

    test "accept! raises InvitationAlreadyAccepted if membership was removed after acceptance" do
      invitation = create_test_invitation(email: @invitee.email)
      membership = invitation.accept!(@invitee)

      # Remove the membership
      membership.destroy!

      assert_raises(Organizations::InvitationAlreadyAccepted) do
        invitation.accept!(@invitee)
      end
    end

    test "accept! raises InvitationExpired for expired invitation" do
      invitation = create_test_invitation(email: @invitee.email, expires_at: 1.day.from_now)

      travel_to 2.days.from_now do
        assert_raises(Organizations::InvitationExpired) do
          invitation.accept!(@invitee)
        end
      end
    end

    test "accept! raises ArgumentError when no user provided and no Current.user" do
      invitation = create_test_invitation(email: @invitee.email)

      assert_raises(ArgumentError) do
        invitation.accept!
      end
    end

    test "accept! dispatches member_joined callback" do
      callback_called = false
      callback_data = nil

      Organizations.configure do |config|
        config.on_member_joined do |context|
          callback_called = true
          callback_data = context
        end
      end

      invitation = create_test_invitation(email: @invitee.email)
      invitation.accept!(@invitee)

      assert callback_called, "member_joined callback should have been called"
      assert_equal @org, callback_data.organization
      assert_equal @invitee, callback_data.user
    end

    test "accept! does not create duplicate membership if user is already a member" do
      # Create an existing membership via another path
      Organizations::Membership.create!(user: @invitee, organization: @org, role: "member")

      invitation = create_test_invitation(email: @invitee.email)

      assert_no_difference -> { Organizations::Membership.count } do
        result = invitation.accept!(@invitee)
        assert_instance_of Organizations::Membership, result
      end

      invitation.reload
      assert invitation.accepted?
    end

    # =========================================================================
    # Resend Flow
    # =========================================================================

    test "resend! generates a new token" do
      invitation = create_test_invitation
      old_token = invitation.token

      invitation.resend!

      refute_equal old_token, invitation.token
    end

    test "resend! resets expires_at" do
      invitation = create_test_invitation(expires_at: 1.day.from_now)
      old_expires_at = invitation.expires_at

      travel_to 12.hours.from_now do
        invitation.resend!
        assert invitation.expires_at > old_expires_at
      end
    end

    test "resend! returns self" do
      invitation = create_test_invitation
      result = invitation.resend!
      assert_equal invitation, result
    end

    test "resend! raises InvitationAlreadyAccepted for accepted invitation" do
      invitation = create_test_invitation(email: @invitee.email)
      invitation.accept!(@invitee)

      assert_raises(Organizations::InvitationAlreadyAccepted) do
        invitation.resend!
      end
    end

    test "resend! works for expired invitation (reactivates it)" do
      invitation = create_test_invitation(expires_at: 1.hour.ago)
      assert invitation.expired?

      invitation.resend!
      invitation.reload

      refute invitation.expired?
      assert invitation.pending?
    end

    # =========================================================================
    # for_email? helper method
    # =========================================================================

    test "for_email? matches case-insensitively" do
      invitation = create_test_invitation(email: "test@example.com")
      assert invitation.for_email?("TEST@Example.COM")
    end

    test "for_email? strips whitespace from check_email" do
      invitation = create_test_invitation(email: "test@example.com")
      assert invitation.for_email?("  test@example.com  ")
    end

    test "for_email? returns false for non-matching email" do
      invitation = create_test_invitation(email: "test@example.com")
      refute invitation.for_email?("other@example.com")
    end

    # =========================================================================
    # acceptance_url
    # =========================================================================

    test "acceptance_url includes token" do
      invitation = create_test_invitation
      url = invitation.acceptance_url
      assert_includes url, invitation.token
    end

    test "acceptance_url with custom base_url" do
      invitation = create_test_invitation
      url = invitation.acceptance_url(base_url: "https://myapp.com")
      assert_equal "https://myapp.com/invitations/#{invitation.token}", url
    end

    # =========================================================================
    # Edge Cases
    # =========================================================================

    test "nil invited_by still allows invitation to work end-to-end" do
      invitation = create_test_invitation(email: @invitee.email, invited_by: nil)
      assert_nil invitation.invited_by
      assert_nil invitation.from

      membership = invitation.accept!(@invitee)
      assert_instance_of Organizations::Membership, membership
      assert_nil membership.invited_by
    end

    test "invitation with inviter that is subsequently deleted sets invited_by to nil" do
      inviter = create_user!(email: "temp-inviter@example.com")
      Organizations::Membership.create!(user: inviter, organization: @org, role: "admin")

      invitation = create_test_invitation(email: @invitee.email, invited_by: inviter)
      assert_equal inviter, invitation.invited_by

      # Simulate inviter being removed (nullify) - update the FK directly
      invitation.update_column(:invited_by_id, nil)
      invitation.reload

      assert_nil invitation.invited_by
      # Should still be able to accept
      membership = invitation.accept!(@invitee)
      assert_instance_of Organizations::Membership, membership
    end

    test "email normalization handles empty string gracefully in validation" do
      invitation = Organizations::Invitation.new(
        organization: @org,
        invited_by: @owner,
        email: ""
      )
      refute invitation.valid?
    end

    test "invitation can be created with viewer role" do
      invitation = create_test_invitation(email: "viewer@example.com", role: "viewer")
      assert invitation.persisted?
      assert_equal "viewer", invitation.role
    end

    test "invitation can be created with admin role" do
      invitation = create_test_invitation(email: "admin@example.com", role: "admin")
      assert invitation.persisted?
      assert_equal "admin", invitation.role
    end

    test "expires_at boundary - invitation at exact expiry time is expired" do
      freeze_time do
        invitation = create_test_invitation(expires_at: Time.current)
        assert invitation.expired?
        refute invitation.pending?
      end
    end

    test "pending scope excludes invitations that expired just now" do
      freeze_time do
        invitation = create_test_invitation(email: "just-expired@example.com", expires_at: Time.current)
        refute_includes Organizations::Invitation.pending, invitation
      end
    end

    test "expired scope includes invitations that expired just now" do
      freeze_time do
        invitation = create_test_invitation(email: "just-expired@example.com", expires_at: Time.current)
        assert_includes Organizations::Invitation.expired, invitation
      end
    end
  end
end
