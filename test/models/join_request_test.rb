# frozen_string_literal: true

require "test_helper"

module Organizations
  class JoinRequestTest < Organizations::Test
    include ActiveJob::TestHelper

    def setup
      super
      @org, @owner = create_org_with_owner!(name: "Inizio")
      @user = create_user!(email: "personal@gmail.com", name: "Joiner")
    end

    # Deterministic challenge: stub the code RNG so the emailed code is known.
    FIXED_CODE_NUMBER = 424_242
    FIXED_CODE = "424242"

    def start_challenge!(request, email:)
      SecureRandom.stub(:random_number, FIXED_CODE_NUMBER) do
        request.start_email_verification!(email: email)
      end
      request
    end

    test "table_name is organizations_join_requests" do
      assert_equal "organizations_join_requests", Organizations::JoinRequest.table_name
    end

    # =========================================================================
    # request_to_join! (P8)
    # =========================================================================

    test "request_to_join! creates a pending request with expiry from config" do
      request = @user.request_to_join!(@org, message: "Soy socio nº 442")

      assert request.pending?
      assert_equal "Soy socio nº 442", request.message
      assert_in_delta 30.days.from_now.to_i, request.expires_at.to_i, 5
    end

    test "request_to_join! is idempotent — returns the existing open request" do
      first = @user.request_to_join!(@org)
      second = @user.request_to_join!(@org)
      assert_equal first.id, second.id
      assert_equal 1, @org.join_requests.count
    end

    test "request_to_join! raises for existing members" do
      @org.add_member!(@user)
      assert_raises(JoinRequestAlreadyDecided) { @user.request_to_join!(@org) }
    end

    test "request_to_join! fires the join_request_created callback" do
      created = nil
      Organizations.configure do |config|
        config.on_join_request_created { |ctx| created = ctx }
      end

      request = @user.request_to_join!(@org)

      assert_equal :join_request_created, created.event
      assert_equal @org, created.organization
      assert_equal @user, created.user
      assert_equal request, created.join_request
    end

    test "pending uniqueness is validated (one open request per org per user)" do
      @user.request_to_join!(@org)
      duplicate = @org.join_requests.new(user: @user)
      refute duplicate.valid?
      assert duplicate.errors[:user_id].any?
    end

    test "a decided request does not block a new one" do
      request = @user.request_to_join!(@org)
      request.withdraw!

      fresh = @user.request_to_join!(@org)
      refute_equal request.id, fresh.id
    end

    # =========================================================================
    # Expiry
    # =========================================================================

    test "requests expire by derived status, mirroring invitations" do
      request = @user.request_to_join!(@org)

      travel_to(31.days.from_now) do
        assert request.expired?
        refute request.pending?
        assert_equal :expired, request.effective_status
        assert_empty @org.join_requests.pending
        assert_includes @org.join_requests.expired, request
      end
    end

    test "approve! refuses expired requests" do
      request = @user.request_to_join!(@org)
      travel_to(31.days.from_now) do
        assert_raises(JoinRequestExpired) { request.approve!(decided_by: @owner) }
      end
    end

    test "reject! still works on expired requests (cleanup path)" do
      request = @user.request_to_join!(@org)
      travel_to(31.days.from_now) do
        request.reject!(rejected_by: @owner)
        assert request.rejected?
      end
    end

    test "nil join_request_expiry means requests never expire" do
      Organizations.configure { |c| c.join_request_expiry = nil }
      request = @user.request_to_join!(@org)
      assert_nil request.expires_at

      travel_to(10.years.from_now) { assert request.pending? }
    end

    # =========================================================================
    # Decisions: approve / reject / withdraw
    # =========================================================================

    test "approve! creates a member-role membership with manual provenance" do
      request = @user.request_to_join!(@org)
      membership = @org.approve_join_request!(request, approved_by: @owner)

      assert_equal "member", membership.role
      assert_equal "manual", membership.joined_via
      refute membership.verified?
      assert request.reload.approved?
      assert_equal @owner, request.decided_by
      assert_not_nil request.decided_at
    end

    test "approve! is idempotent — double approval returns the same membership" do
      request = @user.request_to_join!(@org)
      first = request.approve!(decided_by: @owner)
      second = request.approve!(decided_by: @owner)
      assert_equal first.id, second.id
    end

    test "approve! reuses an existing membership without firing member_joined twice" do
      joined_events = 0
      Organizations.configure do |config|
        config.on_member_joined { |_ctx| joined_events += 1 }
      end

      request = @user.request_to_join!(@org)
      @org.add_member!(@user) # membership arrives via another path first
      joined_before = joined_events

      membership = request.approve!(decided_by: @owner)

      assert_equal @org.memberships.find_by(user_id: @user.id).id, membership.id
      assert_equal joined_before, joined_events, "member_joined must not fire for a reused membership"
      assert request.reload.approved?
    end

    test "approve! fires member_joined and join_request_approved with decided_by" do
      events = []
      Organizations.configure do |config|
        config.on_member_joined { |ctx| events << [:joined, ctx.membership.user_id] }
        config.on_join_request_approved { |ctx| events << [:approved, ctx.decided_by&.id, ctx.membership.present?] }
      end

      request = @user.request_to_join!(@org)
      request.approve!(decided_by: @owner)

      assert_includes events, [:joined, @user.id]
      assert_includes events, [:approved, @owner.id, true]
    end

    test "reject! stamps decision, stores the reason in metadata, fires callback" do
      rejected = nil
      Organizations.configure do |config|
        config.on_join_request_rejected { |ctx| rejected = ctx }
      end

      request = @user.request_to_join!(@org)
      request.reject!(rejected_by: @owner, reason: "no consta como socio")

      assert request.rejected?
      assert_equal @owner, request.decided_by
      assert_equal "no consta como socio", request.metadata["rejection_reason"]
      assert_equal :join_request_rejected, rejected.event
      assert_equal @owner, rejected.decided_by
    end

    test "approve! refuses already-rejected requests" do
      request = @user.request_to_join!(@org)
      request.reject!(rejected_by: @owner)
      assert_raises(JoinRequestAlreadyDecided) { request.approve!(decided_by: @owner) }
    end

    test "withdraw! closes the request; further decisions refuse" do
      request = @user.request_to_join!(@org)
      request.withdraw!

      assert request.withdrawn?
      assert_raises(JoinRequestAlreadyDecided) { request.withdraw! }
      assert_raises(JoinRequestAlreadyDecided) { request.reject!(rejected_by: @owner) }
    end

    test "organization-level helpers guard against foreign requests" do
      other_org, = create_org_with_owner!(name: "Other")
      request = @user.request_to_join!(other_org)

      assert_raises(ArgumentError) { @org.approve_join_request!(request, approved_by: @owner) }
      assert_raises(ArgumentError) { @org.reject_join_request!(request, rejected_by: @owner) }
    end

    # =========================================================================
    # Email verification — eligibility & sending (P4/P6)
    # =========================================================================

    test "start_email_verification! rejects invalid email shapes" do
      request = @user.request_to_join!(@org)
      assert_raises(VerificationEmailNotEligible) do
        request.start_email_verification!(email: "not-an-email")
      end
    end

    test "start_email_verification! rejects emails not eligible for the org" do
      @org.add_domain!("inizio.com")
      request = @user.request_to_join!(@org)

      assert_raises(VerificationEmailNotEligible) do
        request.start_email_verification!(email: "j@otracosa.com")
      end
    end

    test "start_email_verification! rejects lookalike domains (E4)" do
      @org.add_domain!("inizio.com")
      request = @user.request_to_join!(@org)

      assert_raises(VerificationEmailNotEligible) do
        request.start_email_verification!(email: "j@inizio.com.evil.com")
      end
    end

    test "a matching org domain starts the challenge and enqueues the code email" do
      @org.add_domain!("inizio.com")
      request = @user.request_to_join!(@org)

      assert_enqueued_jobs 1, only: ActionMailer::MailDeliveryJob do
        start_challenge!(request, email: "j.doe@inizio.com")
      end

      assert_equal "j.doe@inizio.com", request.verification_email
      assert_equal "j.doe@inizio.com", request.verification_email_normalized
      assert_equal "domain_email", request.joined_via
      assert_not_nil request.verification_sent_at
      assert_equal 1, request.verification_sends_count
    end

    test "the code is stored as a digest only — plaintext never persisted" do
      @org.add_domain!("inizio.com")
      request = @user.request_to_join!(@org)
      start_challenge!(request, email: "j@inizio.com")

      assert_not_nil request.verification_code_digest
      refute_equal FIXED_CODE, request.verification_code_digest
      assert_equal JoinRequest.digest_verification_code(FIXED_CODE, request.id),
                   request.verification_code_digest

      # No column anywhere carries the plaintext
      refute request.attributes.values.map(&:to_s).include?(FIXED_CODE)
    end

    test "an unclaimed allowlist entry is eligible (P6) and sets allowlist provenance" do
      @org.import_allowlist!(["ana@gmail.com"])
      request = @user.request_to_join!(@org)

      start_challenge!(request, email: "ana@gmail.com")

      assert_equal "allowlist", request.joined_via
    end

    test "a claimed allowlist entry is NOT eligible" do
      entry = @org.allowlist_entries.create!(email: "ana@gmail.com")
      entry.claim!(create_user!(email: "prior@gmail.com"))

      request = @user.request_to_join!(@org)
      assert_raises(VerificationEmailNotEligible) do
        request.start_email_verification!(email: "ana@gmail.com")
      end
    end

    test "an email already claimed by a membership is rejected up front (E2)" do
      @org.add_domain!("inizio.com")
      prior = create_user!(email: "prior@gmail.com")
      prior_request = prior.request_to_join!(@org)
      start_challenge!(prior_request, email: "j.doe@inizio.com")
      prior_request.verify_email_code!(FIXED_CODE)

      request = @user.request_to_join!(@org)
      error = assert_raises(VerificationEmailAlreadyClaimed) do
        request.start_email_verification!(email: "J.Doe+bis@inizio.com") # plus-tag collapses (E3)
      end
      # The error must not reveal WHO holds the address
      refute_match(/prior/, error.message)
    end

    # =========================================================================
    # Email verification — throttles
    # =========================================================================

    test "resend inside the interval is throttled" do
      @org.add_domain!("inizio.com")
      request = @user.request_to_join!(@org)
      start_challenge!(request, email: "j@inizio.com")

      assert_raises(VerificationThrottled) do
        request.start_email_verification!(email: "j@inizio.com")
      end
    end

    test "resend after the interval succeeds and resets attempts" do
      @org.add_domain!("inizio.com")
      request = @user.request_to_join!(@org)
      start_challenge!(request, email: "j@inizio.com")
      request.update!(verification_attempts: 3)

      travel_to(61.seconds.from_now) do
        start_challenge!(request, email: "j@inizio.com")
      end

      assert_equal 0, request.verification_attempts
      assert_equal 2, request.verification_sends_count
    end

    test "the per-request send cap is enforced" do
      Organizations.configure { |c| c.verification_max_sends = 2 }
      @org.add_domain!("inizio.com")
      request = @user.request_to_join!(@org)

      start_challenge!(request, email: "j@inizio.com")
      travel_to(2.minutes.from_now) { start_challenge!(request, email: "j@inizio.com") }

      travel_to(4.minutes.from_now) do
        assert_raises(VerificationThrottled) do
          request.start_email_verification!(email: "j@inizio.com")
        end
      end
    end

    # =========================================================================
    # Email verification — verify_email_code!
    # =========================================================================

    test "the correct code verifies and auto-approves a domain join (P4)" do
      @org.add_domain!("inizio.com", membership_metadata: { member_kind: "employee" })
      request = @user.request_to_join!(@org)
      start_challenge!(request, email: "j.doe@inizio.com")

      membership = request.verify_email_code!(FIXED_CODE)

      assert_instance_of Organizations::Membership, membership
      assert membership.verified?
      assert_equal "j.doe@inizio.com", membership.verified_email
      assert_equal "j.doe@inizio.com", membership.verified_email_normalized
      assert_equal "domain_email", membership.joined_via
      assert_equal "employee", membership.metadata["member_kind"]
      assert request.reload.approved?
      assert_nil request.decided_by
    end

    test "verification input tolerates surrounding whitespace" do
      @org.add_domain!("inizio.com")
      request = @user.request_to_join!(@org)
      start_challenge!(request, email: "j@inizio.com")

      assert_instance_of Organizations::Membership, request.verify_email_code!(" #{FIXED_CODE} ")
    end

    test "a wrong code raises AND persists the attempt (no rollback loophole)" do
      @org.add_domain!("inizio.com")
      request = @user.request_to_join!(@org)
      start_challenge!(request, email: "j@inizio.com")

      assert_raises(VerificationCodeInvalid) { request.verify_email_code!("000000") }
      assert_equal 1, request.reload.verification_attempts
    end

    test "attempts exhaust after verification_max_attempts wrong tries" do
      @org.add_domain!("inizio.com")
      request = @user.request_to_join!(@org)
      start_challenge!(request, email: "j@inizio.com")

      5.times do
        assert_raises(VerificationCodeInvalid) { request.verify_email_code!("000000") }
      rescue VerificationAttemptsExceeded
        # Reached the cap inside the loop on the 5th, fine
      end

      assert_raises(VerificationAttemptsExceeded) { request.verify_email_code!(FIXED_CODE) }
    end

    test "codes expire after verification_code_ttl" do
      @org.add_domain!("inizio.com")
      request = @user.request_to_join!(@org)
      start_challenge!(request, email: "j@inizio.com")

      travel_to(16.minutes.from_now) do
        assert_raises(VerificationCodeExpired) { request.verify_email_code!(FIXED_CODE) }
      end
    end

    test "a verified code is burned — it cannot be replayed" do
      @org.add_domain!("inizio.com")
      request = @user.request_to_join!(@org)
      start_challenge!(request, email: "j@inizio.com")
      request.verify_email_code!(FIXED_CODE)

      # Request is approved now; a new user can't replay anything, and even
      # re-verifying this request refuses (decided + no active code).
      assert_raises(JoinRequestAlreadyDecided) { request.verify_email_code!(FIXED_CODE) }
      assert_nil request.reload.verification_code_digest
    end

    test "verify without any active challenge raises VerificationCodeInvalid" do
      request = @user.request_to_join!(@org)
      assert_raises(VerificationCodeInvalid) { request.verify_email_code!(FIXED_CODE) }
    end

    # =========================================================================
    # Reinforced code joins (P3) & metadata precedence
    # =========================================================================

    test "reinforced code join: code + domain challenge => membership with code provenance" do
      @org.add_domain!("inizio.com", membership_metadata: { member_kind: "employee", from: "domain" })
      code = @org.generate_join_code!(requires_verified_domain_email: true,
                                      membership_metadata: { from: "code" })

      request = JoinCode.redeem(code.code, user: @user)
      start_challenge!(request, email: "j@inizio.com")
      membership = request.verify_email_code!(FIXED_CODE)

      assert_instance_of Organizations::Membership, membership
      assert_equal "code", membership.joined_via
      assert membership.verified?
      # Precedence: domain < code (later wins)
      assert_equal "code", membership.metadata["from"]
      assert_equal "employee", membership.metadata["member_kind"]
    end

    test "reinforced code with auto_approve: false stays pending after verification" do
      @org.add_domain!("inizio.com")
      code = @org.generate_join_code!(requires_verified_domain_email: true, auto_approve: false)

      request = JoinCode.redeem(code.code, user: @user)
      start_challenge!(request, email: "j@inizio.com")
      outcome = request.verify_email_code!(FIXED_CODE)

      assert_equal request, outcome
      assert request.pending?
      assert request.email_verified?
      refute @org.has_member?(@user)

      membership = @org.approve_join_request!(request, approved_by: @owner)
      assert membership.verified?
      assert_equal "j@inizio.com", membership.verified_email
    end

    test "allowlist join claims the entry on approval (P6)" do
      @org.import_allowlist!(["ana@gmail.com"], membership_metadata: { member_kind: "member" })
      request = @user.request_to_join!(@org)
      start_challenge!(request, email: "ana@gmail.com")

      membership = request.verify_email_code!(FIXED_CODE)

      entry = @org.allowlist_entries.first
      assert entry.claimed?
      assert_equal @user, entry.claimed_by
      assert_equal "allowlist", membership.joined_via
      assert_equal "member", membership.metadata["member_kind"]
    end

    test "verified_email uniqueness race is backstopped at membership creation (E2 race form)" do
      @org.add_domain!("inizio.com")
      request = @user.request_to_join!(@org)
      start_challenge!(request, email: "j@inizio.com")

      # Simulate a concurrent claim landing between challenge start and verify:
      rival = create_user!(email: "rival@gmail.com")
      @org.memberships.create!(user: rival, role: "member",
                               verified_email: "j@inizio.com",
                               verified_email_normalized: "j@inizio.com",
                               verified_at: Time.current)

      assert_raises(VerificationEmailAlreadyClaimed) { request.verify_email_code!(FIXED_CODE) }
      refute @org.has_member?(@user)
    end

    # =========================================================================
    # join_with_account_email! (P5)
    # =========================================================================

    test "confirmed account email under an org domain joins in one call" do
      @org.add_domain!("urjc.es", membership_metadata: { member_kind: "employee" })
      prof = User.create!(email: "prof@urjc.es", name: "Prof", confirmed_at: Time.current)

      membership = @org.join_with_account_email!(prof)

      assert_equal "domain_email", membership.joined_via
      assert_equal "prof@urjc.es", membership.verified_email
      assert membership.verified?
      assert_equal "employee", membership.metadata["member_kind"]

      # Uniform funnel: the join left an approved request behind
      assert @org.join_requests.find_by(user_id: prof.id).approved?
    end

    test "unconfirmed account email is refused" do
      @org.add_domain!("urjc.es")
      prof = User.create!(email: "prof@urjc.es", name: "Prof", confirmed_at: nil)

      assert_raises(VerificationEmailNotEligible) { @org.join_with_account_email!(prof) }
    end

    test "non-enrolled domain is refused" do
      @org.add_domain!("urjc.es")
      someone = User.create!(email: "x@gmail.com", confirmed_at: Time.current)

      assert_raises(VerificationEmailNotEligible) { @org.join_with_account_email!(someone) }
    end

    test "config.trust_confirmed_account_email = false disables the shortcut" do
      Organizations.configure { |c| c.trust_confirmed_account_email = false }
      @org.add_domain!("urjc.es")
      prof = User.create!(email: "prof@urjc.es", confirmed_at: Time.current)

      assert_raises(VerificationEmailNotEligible) { @org.join_with_account_email!(prof) }
    end

    test "account email already claimed in the org is refused" do
      @org.add_domain!("urjc.es")
      first = User.create!(email: "prof@urjc.es", confirmed_at: Time.current)
      @org.join_with_account_email!(first)

      # A second account somehow presenting the same confirmed address
      impostor = User.create!(email: "prof@urjc.es".upcase, confirmed_at: Time.current)
      assert_raises(VerificationEmailAlreadyClaimed) { @org.join_with_account_email!(impostor) }
    end

    # =========================================================================
    # accepts_join_requests?
    # =========================================================================

    test "accepts_join_requests? reflects available mechanisms" do
      refute @org.accepts_join_requests?

      domain = @org.add_domain!("inizio.com")
      assert @org.accepts_join_requests?

      domain.destroy!
      code = @org.generate_join_code!
      assert @org.accepts_join_requests?

      code.revoke!
      refute @org.accepts_join_requests?

      @org.import_allowlist!(["ana@gmail.com"])
      assert @org.accepts_join_requests?
    end
  end
end
