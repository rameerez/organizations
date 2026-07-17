# frozen_string_literal: true

module Organizations
  # The headless state machine behind any "join this organization" screen —
  # BYO-UI in its truest form: the gem ships the STATE, the host ships the
  # pixels. One object answers "which state is this screen in" so a page
  # body, a pinned CTA, and a Turbo Stream response can never disagree
  # (splitting these predicates across partials is exactly how a submit
  # button ends up pointing at a form that no longer exists — a bug the
  # first production host paid for before extracting this).
  #
  #   :member    — the viewer belongs; show the success/hub state
  #   :verifying — an emailed-code challenge is in flight; show the 6-digit
  #                input (+ resend with #resend_seconds cooldown)
  #   :pending   — a request awaits manual approval; show the waiting state
  #   :entry     — no relationship yet; show the join form(s) the org's
  #                instruments allow (organization.accepts_domain_joining? /
  #                accepts_code_joining? / accepts_join_requests?)
  #
  # @example In a controller
  #   @result = Organizations::JoinFlow.attempt(user: current_user, organization: @org, **join_params)
  #   @state  = Organizations::JoinState.for(user: current_user, organization: @org, result: @result)
  #
  # @example In the view
  #   case @state.status
  #   when :member    then render "joined"
  #   when :verifying then render "code_input", seconds: @state.resend_seconds
  #   when :pending   then render "waiting"
  #   when :entry     then render "join_form"
  #   end
  class JoinState
    STATUSES = %i[member verifying pending entry].freeze

    attr_reader :organization, :membership, :join_request, :result

    # Build the state for a viewer. Pass the JoinFlow::Result of the action
    # that JUST ran (nil on a plain GET): its records are fresher than any
    # association cache — right after a successful verify, the new membership
    # lives on the result, not necessarily in a reloaded association.
    #
    # @param user [User]
    # @param organization [Organizations::Organization]
    # @param result [Organizations::JoinFlow::Result, nil]
    # @return [JoinState]
    def self.for(user:, organization:, result: nil)
      new(
        organization: organization,
        membership: result&.membership || organization.memberships.find_by(user_id: user.id),
        join_request: result&.join_request || user.pending_join_request_for(organization),
        result: result
      )
    end

    def initialize(organization:, membership:, join_request:, result: nil)
      @organization = organization
      @membership = membership
      @join_request = join_request
      @result = result
    end

    # @return [Symbol] one of STATUSES
    def status
      return :member if member?
      return :verifying if verifying?
      return :pending if pending?

      :entry
    end

    def member?
      membership.present? || result&.member?
    end

    def verifying?
      return false if member?
      return true if result&.challenge_sent?

      challenge.present? && challenge.verification_sent_at.present? && !challenge.email_verified?
    end

    def pending?
      return false if member? || verifying?

      join_request.present? || result&.pending?
    end

    def entry?
      status == :entry
    end

    # The join request whose emailed challenge is being answered (feeds the
    # verify form and #resend_seconds).
    # @return [Organizations::JoinRequest, nil]
    def challenge
      result&.join_request || join_request
    end

    # Seconds until the gem will accept another code send for this challenge
    # — drive a client-side resend cooldown from this instead of mirroring
    # config.verification_resend_interval as a magic number in the host
    # (mirrored constants desync the day someone tunes the config).
    # @return [Integer] 0 when a resend is allowed now
    def resend_seconds
      sent_at = challenge&.verification_sent_at
      return 0 if sent_at.blank?

      interval = Organizations.configuration.verification_resend_interval.to_i
      [interval - (Time.current - sent_at).to_i, 0].max
    end

    # Localized message of a just-failed action, nil otherwise.
    # @return [String, nil]
    def error_message
      result&.message if result&.failed?
    end
  end
end
