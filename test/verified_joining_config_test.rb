# frozen_string_literal: true

require "test_helper"

module Organizations
  class VerifiedJoiningConfigTest < Organizations::Test
    # =========================================================================
    # Defaults
    # =========================================================================

    test "verified-joining defaults" do
      config = Organizations.configuration

      assert_equal "Organizations::VerificationMailer", config.verification_mailer
      assert_equal 15.minutes, config.verification_code_ttl
      assert_equal 5, config.verification_max_attempts
      assert_equal 60.seconds, config.verification_resend_interval
      assert_equal 5, config.verification_max_sends
      assert_nil config.verification_email_normalizer
      assert_equal true, config.trust_confirmed_account_email
      assert_equal 30.days, config.join_request_expiry
      assert_nil config.join_code_generator
    end

    # =========================================================================
    # Validation
    # =========================================================================

    test "verification_code_ttl must be a duration — codes must expire" do
      assert_raises(ConfigurationError) do
        Organizations.configure { |c| c.verification_code_ttl = nil }
      end
    end

    test "verification_resend_interval must be a duration" do
      assert_raises(ConfigurationError) do
        Organizations.configure { |c| c.verification_resend_interval = "soon" }
      end
    end

    test "verification_max_attempts must be a positive integer" do
      assert_raises(ConfigurationError) do
        Organizations.configure { |c| c.verification_max_attempts = 0 }
      end
      assert_raises(ConfigurationError) do
        Organizations.configure { |c| c.verification_max_attempts = "five" }
      end
    end

    test "verification_max_sends must be a positive integer" do
      assert_raises(ConfigurationError) do
        Organizations.configure { |c| c.verification_max_sends = 0 }
      end
    end

    test "verification_email_normalizer must be nil or callable" do
      assert_raises(ConfigurationError) do
        Organizations.configure { |c| c.verification_email_normalizer = "downcase" }
      end

      Organizations.configure { |c| c.verification_email_normalizer = ->(e) { e.to_s.downcase } }

      assert_equal "x@y.com", Organizations.configuration.normalize_verification_email("X@Y.COM")
    end

    test "trust_confirmed_account_email must be boolean" do
      assert_raises(ConfigurationError) do
        Organizations.configure { |c| c.trust_confirmed_account_email = "yes" }
      end
    end

    test "join_request_expiry accepts nil (never expire) and durations" do
      Organizations.configure { |c| c.join_request_expiry = nil }
      Organizations.configure { |c| c.join_request_expiry = 90.days }

      assert_raises(ConfigurationError) do
        Organizations.configure { |c| c.join_request_expiry = "forever" }
      end
    end

    test "join_code_generator must be nil or callable" do
      assert_raises(ConfigurationError) do
        Organizations.configure { |c| c.join_code_generator = "ABC" }
      end
    end

    # =========================================================================
    # normalize_verification_email plumbing
    # =========================================================================

    test "normalize_verification_email uses the default normalizer when unset" do
      assert_equal "j.doe@inizio.com",
                   Organizations.configuration.normalize_verification_email("J.Doe+x@INIZIO.COM.")
    end
  end
end
