# frozen_string_literal: true

module Organizations
  # Value object representing a failed invitation acceptance attempt.
  class InvitationAcceptanceFailure
    REASONS = %i[
      missing_user
      missing_token
      invitation_not_found
      invitation_expired
      email_mismatch
      already_accepted_without_membership
    ].freeze

    attr_reader :reason, :invitation

    def initialize(reason:, invitation: nil)
      unless REASONS.include?(reason)
        raise ArgumentError, "Invalid reason: #{reason.inspect}. Must be one of: #{REASONS.join(', ')}"
      end

      @reason = reason
      @invitation = invitation
    end

    def success?
      false
    end

    def failure?
      true
    end

    def failure_reason
      reason
    end

    REASONS.each do |value|
      define_method("#{value}?") do
        reason == value
      end
    end
  end
end
