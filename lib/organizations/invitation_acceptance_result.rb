# frozen_string_literal: true

module Organizations
  # Value object returned by accept_pending_organization_invitation!
  # Encapsulates the result of an invitation acceptance attempt.
  #
  # @example Checking result status
  #   result = accept_pending_organization_invitation!(user)
  #   if result&.accepted?
  #     redirect_to dashboard_path, notice: "Welcome!"
  #   end
  #
  class InvitationAcceptanceResult
    STATUSES = %i[accepted already_member].freeze

    attr_reader :status, :invitation, :membership, :switched

    # @param status [Symbol] :accepted or :already_member
    # @param invitation [Organizations::Invitation] The invitation that was accepted
    # @param membership [Organizations::Membership] The resulting membership
    # @param switched [Boolean] Whether organization context was switched (default: true)
    def initialize(status:, invitation:, membership:, switched: true)
      unless STATUSES.include?(status)
        raise ArgumentError, "Invalid status: #{status.inspect}. Must be one of: #{STATUSES.join(', ')}"
      end

      @status = status
      @invitation = invitation
      @membership = membership
      @switched = switched
    end

    # @return [Boolean] true if invitation was freshly accepted
    def accepted?
      status == :accepted
    end

    # @return [Boolean] true if user was already a member
    def already_member?
      status == :already_member
    end

    # @return [Boolean] true if organization context was switched
    def switched?
      !!switched
    end
  end
end
