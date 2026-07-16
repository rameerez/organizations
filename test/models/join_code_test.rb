# frozen_string_literal: true

require "test_helper"

module Organizations
  # Comprehensive lifecycle suite — size is the point.
  # rubocop:disable Metrics/ClassLength
  class JoinCodeTest < Organizations::Test
    def setup
      super
      @org, @owner = create_org_with_owner!(name: "Inizio")
      @user = create_user!(email: "personal@gmail.com", name: "Joiner")
    end

    test "table_name is organizations_join_codes" do
      assert_equal "organizations_join_codes", Organizations::JoinCode.table_name
    end

    # =========================================================================
    # Generation & normalization
    # =========================================================================

    test "generate_join_code! creates an 8-char code from the ambiguity-free alphabet" do
      code = @org.generate_join_code!

      assert_equal 8, code.code.length
      assert(code.code.chars.all? { |c| JoinCode::CODE_ALPHABET.include?(c) })
    end

    test "generated codes never contain lookalike characters" do
      20.times do
        code = @org.generate_join_code!

        assert_no_match(/[ILO01]/, code.code)
      end
    end

    test "codes are globally unique — same code cannot exist twice across orgs" do
      other_org, = create_org_with_owner!(name: "Other")
      code = @org.join_codes.create!(code: "AAAABBBB")

      assert_predicate code, :persisted?

      assert_raises(ActiveRecord::RecordInvalid) { other_org.join_codes.create!(code: "AAAABBBB") }
    end

    test "custom generator from config is used and normalized" do
      Organizations.configure { |c| c.join_code_generator = -> { "custom-code" } }
      code = @org.generate_join_code!

      assert_equal "CUSTOMCODE", code.code
    end

    test "input normalization strips case, hyphens, and spaces" do
      assert_equal "7FHK2MPX", JoinCode.normalize("  7fhk-2mpx ")
    end

    test "display_code groups in fours" do
      code = @org.join_codes.create!(code: "7FHK2MPX")

      assert_equal "7FHK-2MPX", code.display_code
    end

    test "generate_join_code! carries label, caps, expiry, metadata and creator" do
      code = @org.generate_join_code!(
        label: "cartel cafetería",
        requires_verified_domain_email: true,
        auto_approve: false,
        expires_at: 3.months.from_now,
        max_uses: 500,
        created_by: @owner,
        membership_metadata: { member_kind: "employee" }
      )

      assert_equal "cartel cafetería", code.label
      assert_predicate code, :requires_verified_domain_email?
      refute_predicate code, :auto_approve?
      assert_equal 500, code.max_uses
      assert_equal @owner, code.created_by
    end

    # =========================================================================
    # Status
    # =========================================================================

    test "status transitions: active, revoked, expired, exhausted" do
      code = @org.generate_join_code!(max_uses: 1, expires_at: 1.day.from_now)

      assert_predicate code, :active?
      assert_equal :active, code.status

      travel_to(2.days.from_now) { assert_equal :expired, code.status }

      code.update!(expires_at: 1.day.from_now, uses_count: 1)

      assert_equal :exhausted, code.status

      code.revoke!

      assert_equal :revoked, code.status
    end

    test "revoke! is idempotent" do
      code = @org.generate_join_code!
      code.revoke!
      first = code.revoked_at
      code.revoke!

      assert_equal first.to_i, code.reload.revoked_at.to_i
    end

    # =========================================================================
    # Redemption — failure modes
    # =========================================================================

    test "redeem raises JoinCodeInvalid for unknown codes" do
      assert_raises(JoinCodeInvalid) { JoinCode.redeem("NOPE9999", user: @user) }
    end

    test "redeem raises JoinCodeInvalid for blank input" do
      assert_raises(JoinCodeInvalid) { JoinCode.redeem("  - -", user: @user) }
    end

    test "redeem raises JoinCodeInvalid for revoked codes" do
      code = @org.generate_join_code!
      code.revoke!
      assert_raises(JoinCodeInvalid) { JoinCode.redeem(code.code, user: @user) }
    end

    test "redeem raises JoinCodeInvalid for expired codes" do
      code = @org.generate_join_code!(expires_at: 1.hour.from_now)

      travel_to(2.hours.from_now) do
        assert_raises(JoinCodeInvalid) { JoinCode.redeem(code.code, user: @user) }
      end
    end

    test "redeem raises JoinCodeExhausted at max_uses (E10 deterministic form)" do
      code = @org.generate_join_code!(max_uses: 1)
      JoinCode.redeem(code.code, user: @user)

      second_user = create_user!(email: "second@gmail.com")
      assert_raises(JoinCodeExhausted) { JoinCode.redeem(code.code, user: second_user) }
      assert_equal 1, code.reload.uses_count
    end

    test "redeem requires a user" do
      code = @org.generate_join_code!
      assert_raises(ArgumentError) { code.redeem!(user: nil) }
    end

    # =========================================================================
    # Redemption — P2 (basic, instant membership)
    # =========================================================================

    test "basic auto-approve code grants instant membership with provenance" do
      code = @org.generate_join_code!(membership_metadata: { member_kind: "employee" })

      membership = JoinCode.redeem(code.code, user: @user)

      assert_instance_of Organizations::Membership, membership
      assert_equal "member", membership.role
      assert_equal "code", membership.joined_via
      refute_predicate membership, :verified?
      assert_equal "employee", membership.metadata["member_kind"]
      assert_equal 1, code.reload.uses_count
    end

    test "instant join records an approved join request (audit trail)" do
      code = @org.generate_join_code!
      JoinCode.redeem(code.code, user: @user)

      request = @org.join_requests.find_by(user_id: @user.id)

      assert_predicate request, :approved?
      assert_equal code, request.join_code
      assert_nil request.decided_by
    end

    test "input is normalized at redemption (typed with hyphens/lowercase)" do
      @org.join_codes.create!(code: "7FHK2MPX")
      membership = JoinCode.redeem("7fhk-2mpx", user: @user)

      assert_instance_of Organizations::Membership, membership
    end

    test "member_joined and join_request_approved callbacks fire on instant join" do
      events = []
      Organizations.configure do |config|
        config.on_member_joined { |ctx| events << [:member_joined, ctx.user.id] }
        config.on_join_request_approved { |ctx| events << [:approved, ctx.decided_by] }
      end

      code = @org.generate_join_code!
      JoinCode.redeem(code.code, user: @user)

      assert_includes events, [:member_joined, @user.id]
      assert_includes events, [:approved, nil]
    end

    # =========================================================================
    # Redemption — pending outcomes (P3 / manual approval)
    # =========================================================================

    test "reinforced code (requires_verified_domain_email) parks a pending request" do
      @org.add_domain!("inizio.com")
      code = @org.generate_join_code!(requires_verified_domain_email: true)

      outcome = JoinCode.redeem(code.code, user: @user)

      assert_instance_of Organizations::JoinRequest, outcome
      assert_predicate outcome, :pending?
      assert_equal "code", outcome.joined_via
      refute @org.has_member?(@user)
      assert_equal 1, code.reload.uses_count
    end

    test "auto_approve: false parks a pending request for manual review" do
      code = @org.generate_join_code!(auto_approve: false)

      outcome = JoinCode.redeem(code.code, user: @user)

      assert_instance_of Organizations::JoinRequest, outcome
      assert_predicate outcome, :pending?
      refute @org.has_member?(@user)
    end

    # =========================================================================
    # Redemption — idempotency
    # =========================================================================

    test "redeeming as an existing member returns the membership WITHOUT consuming a use" do
      @org.add_member!(@user)
      code = @org.generate_join_code!(max_uses: 5)

      membership = JoinCode.redeem(code.code, user: @user)

      assert_instance_of Organizations::Membership, membership
      assert_equal 0, code.reload.uses_count
    end

    test "re-redeeming the same pending code does not double-consume uses" do
      code = @org.generate_join_code!(auto_approve: false, max_uses: 5)

      first = JoinCode.redeem(code.code, user: @user)
      second = JoinCode.redeem(code.code, user: @user)

      assert_equal first.id, second.id
      assert_equal 1, code.reload.uses_count
    end

    test "redeeming a code upgrades an existing plain join request instead of colliding (E9 family)" do
      request = @user.request_to_join!(@org, message: "hola")
      code = @org.generate_join_code!(auto_approve: false)

      outcome = JoinCode.redeem(code.code, user: @user)

      assert_equal request.id, outcome.id
      assert_equal code, outcome.join_code
      assert_equal "code", outcome.joined_via
      assert_equal 1, code.reload.uses_count
    end

    test "redeeming a basic code mid-challenge approves immediately; the unfinished challenge dies with the approval" do
      # Reviewer-requested transition: user starts a domain-email challenge,
      # then redeems a basic auto-approve code BEFORE completing it. The code
      # wins: instant membership with code provenance, NOT email-verified
      # (the inbox was never proven), domain metadata still merged (the
      # matched_domain_id survives on the request).
      @org.add_domain!("inizio.com", membership_metadata: { member_kind: "employee" })
      request = @user.request_to_join!(@org)
      SecureRandom.stub(:random_number, 424_242) do
        request.start_email_verification!(email: "j@inizio.com")
      end

      code = @org.generate_join_code!(membership_metadata: { from: "code" })
      membership = JoinCode.redeem(code.code, user: @user)

      assert_instance_of Organizations::Membership, membership
      assert_equal "code", membership.joined_via
      refute_predicate membership, :verified?, "an unfinished challenge must not stamp verified_email"
      assert_nil membership.verified_email
      assert_equal "employee", membership.metadata["member_kind"]
      assert_equal "code", membership.metadata["from"]
      assert_predicate request.reload, :approved?
    end

    test "redeeming a second different code moves the pending request to it and consumes a use" do
      code_a = @org.generate_join_code!(auto_approve: false)
      code_b = @org.generate_join_code!(auto_approve: false)

      first = JoinCode.redeem(code_a.code, user: @user)
      second = JoinCode.redeem(code_b.code, user: @user)

      assert_equal first.id, second.id
      assert_equal code_b, second.reload.join_code
      assert_equal 1, code_a.reload.uses_count
      assert_equal 1, code_b.reload.uses_count
    end
  end
  # rubocop:enable Metrics/ClassLength
end
