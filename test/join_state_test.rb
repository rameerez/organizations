# frozen_string_literal: true

require "test_helper"

# Organizations::JoinState — the headless join-screen state machine — and the
# granular capability predicates that drive which forms an entry screen shows.
class JoinStateTest < ActiveSupport::TestCase
  def setup
    Organizations.reset_configuration!
    @owner = User.create!(email: "owner-#{SecureRandom.hex(4)}@example.com")
    @user = User.create!(email: "viewer-#{SecureRandom.hex(4)}@example.com")
    @org = @owner.create_organization!("State Org")
  end

  def teardown
    Organizations.reset_configuration!
  end

  def state(result: nil)
    Organizations::JoinState.for(user: @user, organization: @org, result: result)
  end

  # === Status derivation ===

  test "no relationship → :entry" do
    assert_equal :entry, state.status
    assert_predicate state, :entry?
  end

  test "membership → :member" do
    @org.add_member!(@user)

    assert_equal :member, state.status
  end

  test "pending manual request → :pending" do
    @user.request_to_join!(@org)

    assert_equal :pending, state.status
  end

  test "rejected request → :entry (a decided request must not read as waiting)" do
    request = @user.request_to_join!(@org)
    request.reject!(rejected_by: @owner)

    assert_equal :entry, state.status
  end

  test "expired request → :entry (a timed-out request must not read as waiting forever)" do
    request = @user.request_to_join!(@org)
    request.update!(expires_at: 1.minute.ago)

    assert_equal :entry, state.status
  end

  test "challenge in flight → :verifying (until verified)" do
    @org.add_domain!("example.com")
    request = @user.request_to_join!(@org)
    request.start_email_verification!(email: "v@example.com")

    assert_equal :verifying, state.status

    # Verified but NOT auto-approved (reinforced code without auto_approve
    # would sit here): falls back to :pending.
    request.reload.update!(verified_at: Time.current, verification_code_digest: nil)

    assert_equal :pending, state.status
  end

  test "a just-run result wins over stale association state" do
    # Right after a successful join, the fresh membership lives on the
    # result — the state must read :member even before any reload.
    code = @org.generate_join_code!(auto_approve: true)
    result = Organizations::JoinFlow.attempt(user: @user, organization: @org, code: code.code)

    fresh = state(result: result)

    assert_equal :member, fresh.status
    assert_equal result.membership, fresh.membership
  end

  test "a challenge_sent result renders :verifying" do
    @org.add_domain!("example.com")
    result = Organizations::JoinFlow.attempt(user: @user, organization: @org, email: "v@example.com")

    assert_equal :verifying, state(result: result).status
  end

  # === Resend cooldown ===

  test "resend_seconds derives from config, not a mirrored constant" do
    @org.add_domain!("example.com")
    request = @user.request_to_join!(@org)
    request.start_email_verification!(email: "v@example.com")

    seconds = state.resend_seconds

    assert_includes 1..Organizations.configuration.verification_resend_interval.to_i, seconds

    travel(Organizations.configuration.verification_resend_interval + 1.second) do
      assert_equal 0, state.resend_seconds
    end
  end

  test "resend_seconds is 0 with no challenge" do
    assert_equal 0, state.resend_seconds
  end

  # === Error surface ===

  test "error_message exposes a failed result's localized message" do
    result = Organizations::JoinFlow.attempt(user: @user, organization: @org, code: "NOPE")

    assert_equal "This code is not valid", state(result: result).error_message

    ok = Organizations::JoinFlow.attempt(
      user: @user, organization: @org.tap { |o| o.generate_join_code!(auto_approve: true) },
      code: @org.join_codes.last.code
    )

    assert_nil state(result: ok).error_message
  end

  # === Capability predicates (Organization) ===

  test "accepts_domain_joining? tracks domains and unclaimed allowlist entries" do
    refute_predicate @org, :accepts_domain_joining?

    @org.add_domain!("example.com")

    assert_predicate @org, :accepts_domain_joining?

    @org.domains.destroy_all
    entries = @org.import_allowlist!(["roster@gmail.test"])

    assert_predicate @org, :accepts_domain_joining?

    entries.first.claim!(@user)

    refute_predicate @org.reload, :accepts_domain_joining?, "claimed entries no longer open joining"
  end

  test "accepts_code_joining? counts only actually-redeemable codes" do
    refute_predicate @org, :accepts_code_joining?

    code = @org.generate_join_code!(max_uses: 1)

    assert_predicate @org, :accepts_code_joining?

    # Exhaust it → no longer counts.
    Organizations::JoinCode.redeem(code.code, user: @user)

    refute_predicate @org, :accepts_code_joining?

    expired = @org.generate_join_code!(expires_at: 1.hour.ago)

    refute_predicate @org, :accepts_code_joining?, "expired codes must not count"
    assert_predicate expired, :expired?

    revoked = @org.generate_join_code!.tap(&:revoke!)

    refute_predicate @org, :accepts_code_joining?, "revoked codes must not count"
    assert_predicate revoked, :revoked?
  end

  test "accepts_join_requests? is the union of the granular predicates" do
    refute_predicate @org, :accepts_join_requests?

    @org.generate_join_code!

    assert_predicate @org, :accepts_join_requests?
  end
end
