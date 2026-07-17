# frozen_string_literal: true

require "test_helper"

# Organizations::JoinFlow — the result-returning facade every join UI needs.
# Pins: dispatch order, every outcome, every REASONS symbol, the security
# posture (foreign/unknown codes are indistinguishable), veto integration,
# and that messages ride the i18n catalog.
# rubocop:disable Metrics/ClassLength -- exhaustive outcome/reason contract suite, one class on purpose
class JoinFlowTest < ActiveSupport::TestCase
  include Organizations::TestHelpers

  def setup
    Organizations.reset_configuration!
    @owner = User.create!(email: "owner-#{SecureRandom.hex(4)}@example.com")
    @user = User.create!(email: "joiner-#{SecureRandom.hex(4)}@example.com")
    @org = @owner.create_organization!("Flow Org")
  end

  def teardown
    Organizations.reset_configuration!
  end

  def attempt(**)
    Organizations::JoinFlow.attempt(user: @user, organization: @org, **)
  end

  # === Already a member ===

  test "any input resolves to :member for an existing member without consuming anything" do
    membership = @org.add_member!(@user)
    code = @org.generate_join_code!(auto_approve: true)

    result = attempt(code: code.code)

    assert_predicate result, :member?
    assert_equal membership, result.membership
    assert_equal 0, code.reload.uses_count, "an existing member must not consume a code use"
  end

  test "the already-member short-circuit covers the email and verification_code inputs too" do
    @org.add_domain!("example.com")
    membership = @org.add_member!(@user)

    email_result = attempt(email: "someone@example.com")

    assert_predicate email_result, :member?, "an existing member must not start a challenge"
    assert_equal membership, email_result.membership
    assert_equal 0, @org.join_requests.count, "no request may be minted for a member"

    verify_result = attempt(verification_code: "123456")

    assert_predicate verify_result, :member?, "an existing member must not reach code verification"
  end

  # === Code path ===

  test "valid auto-approve code returns :member with the membership" do
    code = @org.generate_join_code!(auto_approve: true)

    result = attempt(code: code.code)

    assert_predicate result, :member?
    assert_equal "code", result.membership.joined_via
  end

  test "manual-approval code returns :pending with the request" do
    code = @org.generate_join_code!(auto_approve: false)

    result = attempt(code: code.code)

    assert_predicate result, :pending?
    assert_predicate result.join_request, :pending?
  end

  test "reinforced code (requires domain email) returns :pending awaiting the challenge" do
    @org.add_domain!("example.com")
    code = @org.generate_join_code!(requires_verified_domain_email: true)

    result = attempt(code: code.code)

    assert_predicate result, :pending?
    refute @org.has_member?(@user)
  end

  test "unknown, foreign, revoked, and expired codes are indistinguishable (:join_code_invalid)" do
    other_org = @owner.create_organization!("Other Org")
    foreign = other_org.generate_join_code!(auto_approve: true)
    revoked = @org.generate_join_code!(auto_approve: true).tap(&:revoke!)
    # Expired takes a DIFFERENT code path than the others (it survives the
    # not_revoked lookup and only fails inside redeem! → ensure_redeemable!),
    # so it must be pinned separately or an existence leak on that branch
    # ships undetected.
    expired = @org.generate_join_code!(auto_approve: true, expires_at: 1.minute.ago)

    ["NOPE-NOPE", foreign.code, revoked.code, expired.code].each do |code|
      result = attempt(code: code)

      assert_predicate result, :error?, "expected error for #{code}"
      assert_equal :join_code_invalid, result.reason
      assert_equal "This code is not valid", result.message
    end

    assert_equal 0, foreign.reload.uses_count, "a foreign code must not be consumed"
    assert_equal 0, expired.reload.uses_count, "an expired code must not be consumed"
  end

  test "exhausted code returns :join_code_exhausted" do
    code = @org.generate_join_code!(auto_approve: true, max_uses: 1)
    first = User.create!(email: "first-#{SecureRandom.hex(4)}@example.com")
    Organizations::JoinCode.redeem(code.code, user: first)

    result = attempt(code: code.code)

    assert_equal :join_code_exhausted, result.reason
  end

  # === Email challenge path ===

  test "eligible email returns :challenge_sent with the request" do
    @org.add_domain!("example.com")

    result = attempt(email: "someone@example.com")

    assert_predicate result, :challenge_sent?
    assert_predicate result.join_request.verification_sent_at, :present?
  end

  test "ineligible email returns :email_not_eligible" do
    @org.add_domain!("example.com")

    result = attempt(email: "someone@elsewhere.com")

    assert_equal :email_not_eligible, result.reason
  end

  test "claimed email returns :email_already_claimed" do
    @org.add_domain!("example.com")
    claimed = User.create!(email: "claimed-#{SecureRandom.hex(4)}@example.com")
    request = claimed.request_to_join!(@org)
    request.start_email_verification!(email: "shared@example.com")
    request.verify_email_code!(mint_code(request))

    result = attempt(email: "shared@example.com")

    assert_equal :email_already_claimed, result.reason
  end

  test "resend inside the throttle window returns :throttled" do
    @org.add_domain!("example.com")
    attempt(email: "someone@example.com")

    result = attempt(email: "someone@example.com")

    assert_equal :throttled, result.reason
  end

  # === Verification path ===

  test "correct emailed code returns :member (domain auto-approve)" do
    @org.add_domain!("example.com")
    attempt(email: "someone@example.com")
    request = @user.pending_join_request_for(@org)

    result = attempt(verification_code: mint_code(request))

    assert_predicate result, :member?
    assert_equal "domain_email", result.membership.joined_via
    assert_equal "someone@example.com", result.membership.verified_email
  end

  test "wrong emailed code returns :verification_code_invalid" do
    @org.add_domain!("example.com")
    attempt(email: "someone@example.com")

    result = attempt(verification_code: "000000")

    assert_equal :verification_code_invalid, result.reason
  end

  test "verify without any pending request returns :verification_code_missing" do
    result = attempt(verification_code: "123456")

    assert_equal :verification_code_missing, result.reason
  end

  test "attempts exhaustion returns :verification_attempts_exceeded" do
    @org.add_domain!("example.com")
    attempt(email: "someone@example.com")

    Organizations.configuration.verification_max_attempts.times { attempt(verification_code: "000000") }
    result = attempt(verification_code: "000000")

    assert_equal :verification_attempts_exceeded, result.reason
  end

  # === Shortcut + plain request ===

  test "confirmed account email matching a domain short-circuits to :member" do
    @org.add_domain!("corp.test")
    confirmed = User.create!(email: "ana@corp.test", confirmed_at: Time.current)

    result = Organizations::JoinFlow.attempt(user: confirmed, organization: @org)

    assert_predicate result, :member?
    assert_equal "domain_email", result.membership.joined_via
  end

  test "no inputs and no shortcut falls back to a plain request when the org accepts them" do
    @org.generate_join_code!(auto_approve: false) # any live instrument opens requests

    result = attempt(message: "let me in")

    assert_predicate result, :pending?
    assert_equal "let me in", result.join_request.message
  end

  test "no joining mechanism at all returns :not_accepting_requests" do
    result = attempt

    assert_equal :not_accepting_requests, result.reason
    assert_equal "This organization is not accepting join requests right now", result.message
  end

  # === Veto integration ===

  test "a vetoed join surfaces as :vetoed with the veto message" do
    code = @org.generate_join_code!(auto_approve: true)
    Organizations.configure do |config|
      config.on_member_joining { |_ctx| raise Organizations::MembershipVetoed, "Cap reached" }
    end

    result = attempt(code: code.code)

    assert_predicate result, :vetoed?
    assert_predicate result, :failed?
    assert_equal :membership_vetoed, result.reason
    assert_equal "Cap reached", result.message
  end

  # === i18n ===

  test "messages localize through the catalog" do
    I18n.with_locale(:es) do
      result = attempt(code: "NOPE-NOPE")

      assert_equal "Este código no es válido", result.message
    end
  end

  test "every emitted reason is declared in REASONS" do
    # Guards the reason vocabulary: a new error path must register its symbol
    # so hosts can exhaustively map reasons to copy.
    emitted = File.read(File.expand_path("../lib/organizations/join_flow.rb", __dir__))
      .scan(/error\(:(\w+)/).flatten.map(&:to_sym).uniq
    emitted << :membership_vetoed

    assert_empty emitted.uniq - Organizations::JoinFlow::REASONS,
                 "reasons emitted but not declared in REASONS"
  end

  private

  # The gem-shipped helper (Organizations::TestHelpers).
  def mint_code(request)
    issue_verification_code(request)
  end
end
# rubocop:enable Metrics/ClassLength
