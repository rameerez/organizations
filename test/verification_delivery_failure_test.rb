# frozen_string_literal: true

require "test_helper"

# Delivery-failure handling for the emailed verification code.
#
# The failure mode this closes: start_email_verification! COMMITS the
# challenge (throttle stamp + send count) before attempting delivery. If
# enqueueing the email then fails (queue down, bad mailer config), the old
# behavior logged one line and left the user throttled for a code that never
# left the building — and each retry burned one of max_sends until the
# request bricked. Now the gem rolls the bookkeeping back (immediate retry
# allowed) and fires on_verification_delivery_failed so the host's error
# tracker sees the outage.
class VerificationDeliveryFailureTest < ActiveSupport::TestCase
  # A mailer whose enqueue always explodes — simulates a down queue backend
  # or a broken custom mailer, at the exact seam the gem calls.
  class BrokenMailer
    def self.code_email(_join_request, _code)
      raise "queue backend down"
    end
  end

  def setup
    Organizations.reset_configuration!
    @owner = User.create!(email: "owner-#{SecureRandom.hex(4)}@example.com")
    @user = User.create!(email: "user-#{SecureRandom.hex(4)}@example.com")
    @org = @owner.create_organization!("Delivery Org")
    @org.add_domain!("example.com")
    @request = @user.request_to_join!(@org)
  end

  def teardown
    Organizations.reset_configuration!
  end

  def use_broken_mailer
    Organizations.configure do |config|
      config.verification_mailer = "VerificationDeliveryFailureTest::BrokenMailer"
    end
  end

  test "a failed delivery rolls the challenge back instead of stranding the user" do
    use_broken_mailer

    # Does NOT raise — same outward posture as before (delivery failures are
    # never fatal to the request flow).
    @request.start_email_verification!(email: "someone@example.com")

    @request.reload
    assert_nil @request.verification_code_digest, "undelivered code must not stay redeemable"
    assert_nil @request.verification_sent_at, "throttle stamp must be reverted"
    assert_equal 0, @request.verification_sends_count, "the failed send must not count against max_sends"
  end

  test "the user can retry immediately after a failed delivery (no throttle window)" do
    use_broken_mailer
    @request.start_email_verification!(email: "someone@example.com")

    # Restore a working mailer and retry AT ONCE — before the fix this raised
    # VerificationThrottled for verification_resend_interval seconds.
    Organizations.reset_configuration!
    @request.reload.start_email_verification!(email: "someone@example.com")

    @request.reload
    assert_not_nil @request.verification_code_digest
    assert_equal 1, @request.verification_sends_count
  end

  test "on_verification_delivery_failed fires with the request and error details" do
    contexts = []
    Organizations.configure do |config|
      config.verification_mailer = "VerificationDeliveryFailureTest::BrokenMailer"
      config.on_verification_delivery_failed { |ctx| contexts << ctx }
    end

    @request.start_email_verification!(email: "someone@example.com")

    assert_equal 1, contexts.size
    ctx = contexts.first
    assert_equal :verification_delivery_failed, ctx.event
    assert_equal @org, ctx.organization
    assert_equal @user, ctx.user
    assert_equal @request, ctx.join_request
    assert_equal "RuntimeError", ctx.metadata["error_class"]
    assert_equal "queue backend down", ctx.metadata["error_message"]
  end

  test "a callback that itself raises never breaks the flow (error-isolated)" do
    Organizations.configure do |config|
      config.verification_mailer = "VerificationDeliveryFailureTest::BrokenMailer"
      config.on_verification_delivery_failed { |_ctx| raise "observer exploded" }
    end

    assert_nothing_raised do
      @request.start_email_verification!(email: "someone@example.com")
    end
  end

  test "successful deliveries keep normal bookkeeping (no rollback)" do
    @request.start_email_verification!(email: "someone@example.com")

    @request.reload
    assert_not_nil @request.verification_code_digest
    assert_not_nil @request.verification_sent_at
    assert_equal 1, @request.verification_sends_count
  end
end
