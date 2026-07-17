# frozen_string_literal: true

module Organizations
  # The controller-facing facade over verified joining: ONE call that says
  # "this user is trying to join this organization with whatever they gave
  # us", returning a Result instead of raising — so host controllers render
  # states instead of writing ten-branch rescue ladders.
  #
  # The model APIs (JoinCode.redeem, JoinRequest#start_email_verification!,
  # …) remain the exception-raising programmatic layer; JoinFlow is the skin
  # every join UI ends up needing. Before this existed, the first production
  # host's "JoinService" was ~60% this exact translation, rewritten by hand.
  #
  # Dispatch order (first present input wins):
  #   verification_code → verify the emailed 6-digit code
  #   code              → redeem a join code (PIN)
  #   email             → start/restart the emailed challenge for an address
  #   (none)            → confirmed-account-email shortcut when eligible,
  #                       else a plain request-to-join
  #
  # @example A join endpoint in three lines
  #   result = Organizations::JoinFlow.attempt(
  #     user: current_user, organization: @org,
  #     code: params[:code], email: params[:email], message: params[:message]
  #   )
  #   result.member? ? redirect_to(@org) : render_state(result)
  #
  # Result contract:
  #   outcome — :member | :challenge_sent | :pending | :vetoed | :error
  #   reason  — nil on success; on :vetoed/:error a stable symbol from
  #             REASONS (build your copy off this, never off the message)
  #   message — localized human string (the caught error's message, already
  #             resolved through the gem's i18n catalog — override per key
  #             in your locale files, or ignore it and map reason yourself)
  #   membership / join_request — the record backing the outcome
  #
  # ⚠️ SECURITY (host responsibilities that CANNOT live in the gem):
  #   - Rate-limit the endpoints that call this (code redemption and
  #     verification are enumeration surfaces) — see README "Rate limiting
  #     your join endpoints".
  #   - :join_code_invalid deliberately covers unknown, revoked, expired AND
  #     foreign-organization codes with one reason — never tell users which
  #     codes exist.
  class JoinFlow
    # Stable machine-readable reasons a host can switch on.
    REASONS = %i[
      join_code_invalid
      join_code_exhausted
      email_not_eligible
      email_already_claimed
      throttled
      verification_code_invalid
      verification_code_expired
      verification_code_missing
      verification_attempts_exceeded
      request_closed
      not_accepting_requests
      membership_vetoed
    ].freeze

    Result = Struct.new(:outcome, :reason, :membership, :join_request, :message, keyword_init: true) do
      def member? = outcome == :member
      def challenge_sent? = outcome == :challenge_sent
      def pending? = outcome == :pending
      def vetoed? = outcome == :vetoed
      def error? = outcome == :error
      # Anything that should render as a problem state (veto included).
      def failed? = error? || vetoed?
    end

    # @param user [User] the joining user (required)
    # @param organization [Organizations::Organization] the org being joined
    #   (required — codes from OTHER organizations resolve to
    #   :join_code_invalid on purpose; for organization-less global
    #   redemption call Organizations::JoinCode.redeem directly)
    # @param code [String, nil] a join code (PIN) as typed
    # @param email [String, nil] address for the emailed challenge
    # @param verification_code [String, nil] the emailed 6-digit code as typed
    # @param message [String, nil] optional note for manual approval requests
    # @return [Result]
    # Every parameter is an optional keyword with a safe default — this IS
    # the public API surface, not incidental complexity (same posture as
    # Organization#generate_join_code!).
    # rubocop:disable Metrics/ParameterLists
    def self.attempt(user:, organization:, code: nil, email: nil, verification_code: nil, message: nil)
      new(user: user, organization: organization)
        .attempt(code: code, email: email, verification_code: verification_code, message: message)
    end
    # rubocop:enable Metrics/ParameterLists

    def initialize(user:, organization:)
      @user = user
      @organization = organization
    end

    def attempt(code: nil, email: nil, verification_code: nil, message: nil)
      # Already a member: every input resolves to the same quiet success —
      # never consume a code use or mint a request for someone who's in.
      if (existing = organization.memberships.find_by(user_id: user.id))
        return Result.new(outcome: :member, membership: existing)
      end

      return verify_emailed_code(verification_code) if verification_code.present?
      return redeem_code(code) if code.present?
      return start_challenge(email) if email.present?
      return account_email_shortcut if account_email_eligible?

      plain_request(message)
    rescue Organizations::MembershipVetoed => e
      # The host's on_member_joining gate said no — a first-class outcome,
      # not a generic error (hosts usually show cap-specific copy + support).
      Result.new(outcome: :vetoed, reason: :membership_vetoed, message: e.message)
    end

    private

    attr_reader :user, :organization

    def verify_emailed_code(typed_code)
      request = user.pending_join_request_for(organization)
      return error(:verification_code_missing, Organizations.t(:"errors.verification_code_missing")) unless request

      from_outcome(request.verify_email_code!(typed_code))
    rescue Organizations::VerificationAttemptsExceeded => e
      error(:verification_attempts_exceeded, e.message)
    rescue Organizations::VerificationCodeExpired => e
      error(:verification_code_expired, e.message)
    rescue Organizations::VerificationCodeInvalid => e
      error(:verification_code_invalid, e.message)
    rescue Organizations::VerificationEmailAlreadyClaimed => e
      error(:email_already_claimed, e.message)
    rescue Organizations::JoinRequestError => e
      error(:request_closed, e.message)
    end

    def redeem_code(raw_code)
      normalized = Organizations::JoinCode.normalize(raw_code)
      join_code = normalized.present? && Organizations::JoinCode.not_revoked.find_by(code: normalized)

      # One reason for unknown/revoked/expired/foreign codes — the code
      # endpoint is the enumeration surface; never reveal which codes exist
      # or whose they are.
      unless join_code && join_code.organization_id == organization.id
        return error(:join_code_invalid, Organizations.t(:"errors.join_code_invalid"))
      end

      from_outcome(join_code.redeem!(user: user))
    rescue Organizations::JoinCodeExhausted => e
      # NOTE: rescued before JoinCodeInvalid — it's a subclass.
      error(:join_code_exhausted, e.message)
    rescue Organizations::JoinCodeInvalid => e
      error(:join_code_invalid, e.message)
    end

    def start_challenge(email)
      request = user.pending_join_request_for(organization) || user.request_to_join!(organization)
      request.start_email_verification!(email: email)

      Result.new(outcome: :challenge_sent, join_request: request)
    rescue Organizations::VerificationEmailNotEligible => e
      error(:email_not_eligible, e.message)
    rescue Organizations::VerificationEmailAlreadyClaimed => e
      error(:email_already_claimed, e.message)
    rescue Organizations::VerificationThrottled => e
      error(:throttled, e.message)
    rescue Organizations::JoinRequestError => e
      error(:request_closed, e.message)
    end

    def account_email_shortcut
      from_outcome(organization.join_with_account_email!(user))
    rescue Organizations::VerificationEmailAlreadyClaimed => e
      error(:email_already_claimed, e.message)
    rescue Organizations::VerificationEmailNotEligible
      # Eligibility changed between the pre-check and the call (domain
      # removed, trust flipped) — degrade to the plain request path.
      plain_request(nil)
    end

    def plain_request(message)
      unless organization.accepts_join_requests?
        return error(:not_accepting_requests, Organizations.t(:"errors.not_accepting_requests"))
      end

      from_outcome(user.request_to_join!(organization, message: message))
    rescue Organizations::JoinRequestError => e
      error(:request_closed, e.message)
    end

    def account_email_eligible?
      Organizations.configuration.trust_confirmed_account_email &&
        user.respond_to?(:confirmed_at) && user.confirmed_at.present? &&
        user.respond_to?(:email) &&
        organization.domains.matching_email(user.email).exists?
    end

    def from_outcome(outcome)
      case outcome
      when Organizations::Membership
        Result.new(outcome: :member, membership: outcome)
      when Organizations::JoinRequest
        if outcome.verification_sent_at.present? && !outcome.email_verified?
          Result.new(outcome: :challenge_sent, join_request: outcome)
        else
          Result.new(outcome: :pending, join_request: outcome)
        end
      else
        error(:request_closed, Organizations.t(:"errors.join_request_create_failed"))
      end
    end

    def error(reason, message)
      # Developer guard (review finding): REASONS is a published contract
      # hosts switch on — a typo'd symbol here would silently ship a reason
      # nobody's copy mapping knows. (Hosts building their OWN Results may
      # use their own symbols; this guards the gem's internal emissions.)
      unless REASONS.include?(reason)
        raise ArgumentError, "unknown JoinFlow reason #{reason.inspect} — add it to JoinFlow::REASONS"
      end

      Result.new(outcome: :error, reason: reason, message: message)
    end
  end
end
