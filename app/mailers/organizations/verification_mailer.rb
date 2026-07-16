# frozen_string_literal: true

module Organizations
  # Mailer for emailed verification codes (verified joining).
  # Can be customized via Organizations.configuration.verification_mailer —
  # custom mailers must implement `code_email(join_request, code)`.
  #
  # SECURITY: `code` is the plaintext one-time code. It exists only in this
  # delivery path — the database stores a digest (see JoinRequest).
  #
  # @example
  #   VerificationMailer.code_email(join_request, "492817").deliver_later
  #
  class VerificationMailer < ActionMailer::Base
    default from: -> { default_from_address }

    # Verification code email
    # @param join_request [Organizations::JoinRequest]
    # @param code [String] the plaintext 6-digit code
    # @return [Mail::Message]
    def code_email(join_request, code)
      @join_request = join_request
      @organization = join_request.organization
      @code = code
      @expires_in_minutes = ttl_minutes

      mail(
        to: join_request.verification_email,
        subject: "#{@code} is your #{@organization.name} verification code"
      )
    end

    private

    def ttl_minutes
      ttl = Organizations.configuration.verification_code_ttl
      (ttl.to_i / 60.0).ceil
    end

    def default_from_address
      if defined?(Rails) && Rails.application&.config&.action_mailer&.default_options
        Rails.application.config.action_mailer.default_options[:from] || "noreply@example.com"
      else
        "noreply@example.com"
      end
    end
  end
end
