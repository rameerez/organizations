# frozen_string_literal: true

require "test_helper"

module Organizations
  # Verified-joining provenance stamped by invitation acceptance (v0.5.0).
  class InvitationProvenanceTest < Organizations::Test
    def setup
      super
      @org, @owner = create_org_with_owner!(name: "Acme")
      @invitee = create_user!(email: "invitee@example.com", name: "Invitee")
    end

    def invite!(email: "invitee@example.com", membership_metadata: {})
      invitation = @org.send_invite_to!(email, invited_by: @owner)
      invitation.update!(membership_metadata: membership_metadata) if membership_metadata.any?
      invitation
    end

    test "accepting an invitation stamps invited provenance + verified email" do
      membership = invite!.accept!(@invitee)

      assert_equal "invited", membership.joined_via
      assert_predicate membership, :verified?
      assert_equal "invitee@example.com", membership.verified_email
      assert_equal "invitee@example.com", membership.verified_email_normalized
    end

    test "membership_metadata copies through to the membership" do
      membership = invite!(membership_metadata: { member_kind: "employee" }).accept!(@invitee)

      assert_equal "employee", membership.metadata["member_kind"]
    end

    test "skip_email_validation acceptance by a DIFFERENT email does NOT stamp verified email" do
      other = create_user!(email: "different@example.com")
      membership = invite!.accept!(other, skip_email_validation: true)

      assert_equal "invited", membership.joined_via
      refute_predicate membership, :verified?
      assert_nil membership.verified_email
    end

    test "skip_email_validation acceptance by the MATCHING email still stamps verified email" do
      membership = invite!.accept!(@invitee, skip_email_validation: true)

      assert_predicate membership, :verified?
      assert_equal "invitee@example.com", membership.verified_email
    end

    test "an address already claimed in the org degrades gracefully (no stamp, membership still created)" do
      rival = create_user!(email: "rival@example.com")
      @org.memberships.create!(user: rival, role: "member",
                               verified_email: "invitee@example.com",
                               verified_email_normalized: "invitee@example.com",
                               verified_at: Time.current)

      membership = invite!.accept!(@invitee)

      assert_predicate membership, :persisted?
      refute_predicate membership, :verified?
      assert_nil membership.verified_email
    end

    test "verified_email is unique per organization at the DB level" do
      @org.memberships.create!(user: @invitee, role: "member",
                               verified_email: "x@corp.com",
                               verified_email_normalized: "x@corp.com",
                               verified_at: Time.current)

      rival = create_user!(email: "rival@example.com")
      assert_raises(ActiveRecord::RecordNotUnique) do
        @org.memberships.create!(user: rival, role: "member",
                                 verified_email: "x@corp.com",
                                 verified_email_normalized: "x@corp.com",
                                 verified_at: Time.current)
      end
    end

    test "the same verified_email CAN exist in two different organizations" do
      other_org, = create_org_with_owner!(name: "Other")
      @org.memberships.create!(user: @invitee, role: "member",
                               verified_email: "x@corp.com",
                               verified_email_normalized: "x@corp.com",
                               verified_at: Time.current)

      membership = other_org.memberships.create!(user: @invitee, role: "member",
                                                 verified_email: "x@corp.com",
                                                 verified_email_normalized: "x@corp.com",
                                                 verified_at: Time.current)

      assert_predicate membership, :persisted?
    end

    test "concurrent verified-email claim during acceptance degrades gracefully (race form)" do
      # Simulate the race where a rival claims the address BETWEEN accept!'s
      # pre-check and the INSERT: force the stamped attributes despite the
      # claim and let the unique index fire.
      rival = create_user!(email: "rival@example.com")
      invitation = invite!
      stamped = {
        verified_email: "invitee@example.com",
        verified_email_normalized: "invitee@example.com",
        verified_at: Time.current
      }

      invitation.stub(:verified_email_attributes_for, stamped) do
        @org.memberships.create!(user: rival, role: "member",
                                 verified_email: "invitee@example.com",
                                 verified_email_normalized: "invitee@example.com",
                                 verified_at: Time.current)

        membership = invitation.accept!(@invitee)

        assert_predicate membership, :persisted?
        assert_equal @invitee, membership.user
        refute_predicate membership, :verified?, "the loser of the race must degrade to an unstamped membership"
        assert_equal "invited", membership.joined_via
      end
      assert_predicate invitation.reload, :accepted?
    end

    test "memberships without verified_email are unconstrained (multiple NULLs allowed)" do
      user_b = create_user!(email: "b@example.com")
      @org.add_member!(@invitee)
      @org.add_member!(user_b)

      assert_equal 3, @org.memberships.count # owner + 2
    end
  end
end
