# frozen_string_literal: true

require "digest"
require "active_support/security_utils"

module Organizations
  # A user's petition to join an organization — the mirror image of Invitation
  # (invitation = org→user, join request = user→org; both converge on
  # Membership). Memberships stay active-only: all "pending" state lives here,
  # so every existing membership invariant (counter cache, single owner,
  # uniqueness) is untouched.
  #
  # Stored statuses: pending → approved | rejected | withdrawn.
  # `:expired` is DERIVED from expires_at (same approach as invitations).
  #
  # A request may carry an email-verification challenge: the user proves
  # control of an inbox that either belongs to one of the organization's
  # Domains or matches an unclaimed AllowlistEntry. The 6-digit code is
  # stored as a SHA-256 digest only (peppered with the row id) — plaintext
  # never touches the database.
  #
  # @example Request to join (manual approval)
  #   request = user.request_to_join!(org, message: "Soy socio nº 442")
  #   org.approve_join_request!(request, approved_by: admin)
  #
  # @example Domain-email verified join
  #   request = user.request_to_join!(org)
  #   request.start_email_verification!(email: "j.doe@inizio.com")
  #   request.verify_email_code!("492817") # => Membership (auto-approved)
  #
  # The class carries the request's FULL lifecycle (statuses, challenge,
  # decisions) exactly like its mirror Invitation does — splitting it would
  # scatter one cohesive state machine across files.
  # rubocop:disable Metrics/ClassLength
  class JoinRequest < ActiveRecord::Base
    self.table_name = "organizations_join_requests"

    STATUSES = %w[pending approved rejected withdrawn].freeze

    # === Associations ===

    belongs_to :organization,
               class_name: "Organizations::Organization",
               inverse_of: :join_requests

    # Explicit class_name (NOT inferred from the association name) so hosts
    # with a differently-named account model work: config.user_class.
    belongs_to :user, class_name: Organizations.user_class_name

    belongs_to :join_code,
               class_name: "Organizations::JoinCode",
               inverse_of: :join_requests,
               optional: true

    belongs_to :decided_by,
               class_name: Organizations.user_class_name,
               optional: true

    # === Validations ===

    validates :status, presence: true, inclusion: { in: STATUSES }
    validate :unique_pending_request, on: :create

    # === Callbacks ===

    before_validation :set_expiry, on: :create, if: -> { expires_at.blank? }

    # === Scopes ===

    # Open requests (pending status and not past expiry)
    scope :pending, lambda {
      where(status: "pending")
        .where("expires_at IS NULL OR expires_at > ?", Time.current)
    }

    # Requests that timed out while pending
    scope :expired, lambda {
      where(status: "pending")
        .where("expires_at IS NOT NULL AND expires_at <= ?", Time.current)
    }

    scope :approved, -> { where(status: "approved") }
    scope :rejected, -> { where(status: "rejected") }
    scope :withdrawn, -> { where(status: "withdrawn") }

    # === Status Methods ===

    # @return [Boolean]
    def pending?
      status == "pending" && !expired?
    end

    # @return [Boolean]
    def approved?
      status == "approved"
    end

    # @return [Boolean]
    def rejected?
      status == "rejected"
    end

    # @return [Boolean]
    def withdrawn?
      status == "withdrawn"
    end

    # @return [Boolean] request timed out while pending
    def expired?
      status == "pending" && expires_at.present? && expires_at <= Time.current
    end

    # @return [Boolean] a terminal decision was made
    def decided?
      approved? || rejected? || withdrawn?
    end

    # Effective status as a symbol (derives :expired)
    # @return [Symbol] :pending, :approved, :rejected, :withdrawn, or :expired
    def effective_status
      return :expired if expired?

      status.to_sym
    end

    # @return [Boolean] the email challenge was completed
    def email_verified?
      verified_at.present?
    end

    # === Email Verification Challenge ===

    # Start (or restart) the emailed-code challenge for an address the user
    # claims to control. The address must belong to one of the organization's
    # domains or match an unclaimed allowlist entry — proof of control is
    # required in BOTH cases (a leaked roster must not grant membership
    # without inbox access).
    #
    # @param email [String] the address to prove (may differ from user.email)
    # @return [self]
    # @raise [VerificationEmailNotEligible] address invalid or not eligible for this org
    # @raise [VerificationEmailAlreadyClaimed] address already proven by another membership
    # @raise [VerificationThrottled] resend interval / send cap hit
    # @raise [JoinRequestExpired, JoinRequestAlreadyDecided] request not open
    def start_email_verification!(email:)
      address = email.to_s.strip

      unless address.match?(URI::MailTo::EMAIL_REGEXP)
        raise VerificationEmailNotEligible, Organizations.t(:"errors.verification_email_invalid")
      end

      code = nil

      ActiveRecord::Base.transaction do
        lock!
        ensure_open!

        matched_domain, matched_entry = eligible_instruments_for!(address)
        ensure_address_unclaimed!(address)
        ensure_send_allowed!

        code = generate_verification_code
        update!(challenge_attributes(address, code, matched_domain, matched_entry))
      end

      deliver_verification_email(code)
      self
    end

    # Verify the emailed code. On success, auto-approves when the governing
    # instrument allows it (domain/roster joins: always; code joins: per the
    # code's auto_approve flag).
    #
    # @param code [String] the 6-digit code as typed
    # @return [Membership] when verification auto-approved the request
    # @return [self] when verified but awaiting manual approval
    # @raise [VerificationCodeInvalid, VerificationCodeExpired, VerificationAttemptsExceeded]
    # @raise [JoinRequestExpired, JoinRequestAlreadyDecided]
    def verify_email_code!(code)
      failure = nil

      ActiveRecord::Base.transaction do
        lock!
        ensure_open!
        ensure_active_challenge!

        if correct_code?(code)
          # Burn the code: single-use by construction.
          update!(verified_at: Time.current, verification_code_digest: nil)
        else
          # Persist the failed attempt, then raise OUTSIDE the transaction —
          # raising here would roll the increment back and give attackers
          # unlimited tries.
          update!(verification_attempts: verification_attempts + 1)
          failure = VerificationCodeInvalid.new(Organizations.t(:"errors.verification_code_invalid"))
        end
      end

      raise failure if failure

      return approve!(decided_by: nil) if auto_approvable_after_verification?

      self
    end

    # === Decisions ===

    # Approve this request and create the membership (the ONLY way a join
    # request becomes a membership). Row-locked and idempotent: approving an
    # already-approved request returns the existing membership.
    #
    # Provenance is stamped on the membership (joined_via, verified_email,
    # verified_at) and `membership_metadata` from the governing instruments is
    # merged in (matched domain, then matched allowlist entry, then join code
    # — later wins).
    #
    # @param decided_by [User, nil] approver (nil for auto-approvals)
    # @return [Membership]
    # @raise [JoinRequestExpired, JoinRequestAlreadyDecided]
    def approve!(decided_by: nil)
      membership = nil
      reused_existing = false

      ActiveRecord::Base.transaction do
        lock!

        return approved_membership! if approved? # idempotent re-approval

        ensure_open!

        existing = existing_membership

        if existing
          membership = existing
          reused_existing = true
        else
          membership = create_membership!
          claim_matched_allowlist_entry!
        end

        update!(status: "approved", decided_by_id: decided_by&.id, decided_at: Time.current)
      end

      dispatch_approval_callbacks(membership, decided_by, reused_existing)
      membership
    end

    # Reject this request.
    # @param rejected_by [User, nil]
    # @param reason [String, nil] stored in metadata for audit; never shown by the gem
    # @return [self]
    # @raise [JoinRequestAlreadyDecided]
    def reject!(rejected_by: nil, reason: nil)
      ActiveRecord::Base.transaction do
        lock!
        ensure_undecided!

        new_metadata = metadata || {}
        new_metadata = new_metadata.merge("rejection_reason" => reason) if reason.present?

        update!(
          status: "rejected",
          decided_by_id: rejected_by&.id,
          decided_at: Time.current,
          metadata: new_metadata
        )
      end

      Callbacks.dispatch(
        :join_request_rejected,
        organization: organization,
        user: user,
        join_request: self,
        decided_by: rejected_by
      )

      self
    end

    # Withdraw this request (the user cancels their own petition).
    # @return [self]
    # @raise [JoinRequestAlreadyDecided]
    def withdraw!
      ActiveRecord::Base.transaction do
        lock!
        ensure_undecided!

        update!(status: "withdrawn", decided_at: Time.current)
      end

      self
    end

    # Digest a verification code, peppered with the row id so identical codes
    # on different requests produce different digests.
    # @return [String]
    def self.digest_verification_code(code, request_id)
      Digest::SHA256.hexdigest("#{code}-#{request_id}")
    end

    private

    # Raise unless this request is still open (pending and not expired)
    def ensure_open!
      raise JoinRequestExpired, Organizations.t(:"errors.join_request_expired") if expired?
      raise JoinRequestAlreadyDecided, already_decided_message if decided?
    end

    # Like ensure_open! but tolerates expiry — used by reject!/withdraw! so
    # stale requests can still be cleaned up explicitly.
    def ensure_undecided!
      raise JoinRequestAlreadyDecided, already_decided_message if decided?
    end

    # "…has already been %{status}" — the status word itself is translated
    # (organizations.join_request_status.*, lowercase for mid-sentence use)
    # so the whole sentence localizes as one unit.
    def already_decided_message
      Organizations.t(:"errors.join_request_already_decided",
                      status: Organizations.t(:"join_request_status.#{status}", default: status))
    end

    def auto_approvable_after_verification?
      return join_code.auto_approve? if join_code

      true
    end

    def existing_membership
      organization.memberships.find_by(user_id: user_id)
    end

    # The membership behind an already-approved request (idempotent path).
    # Raises if it was removed after approval — the request can't be reused.
    def approved_membership!
      membership = existing_membership
      raise JoinRequestAlreadyDecided, Organizations.t(:"errors.join_request_membership_gone") unless membership

      membership
    end

    # Post-approval callback dispatches (outside the approval transaction).
    # member_joined is skipped when the membership pre-existed via another
    # path — it already fired when that membership was created.
    def dispatch_approval_callbacks(membership, decided_by, reused_existing)
      unless reused_existing
        Callbacks.dispatch(
          :member_joined,
          organization: organization,
          membership: membership,
          user: user
        )
      end

      Callbacks.dispatch(
        :join_request_approved,
        organization: organization,
        user: user,
        join_request: self,
        membership: membership,
        decided_by: decided_by
      )
    end

    # === Challenge guards & builders (all called under lock) ===

    # Resolve which join instrument makes this address eligible.
    # Domains win over allowlist entries (an org can have both).
    # @return [Array(Domain|nil, AllowlistEntry|nil)]
    def eligible_instruments_for!(address)
      matched_domain = organization.domains.matching_email(address).first
      matched_entry = matched_domain ? nil : organization.allowlist_entries.unclaimed.for_email(address).first

      unless matched_domain || matched_entry
        raise VerificationEmailNotEligible,              Organizations.t(:"errors.verification_email_not_eligible")
      end

      [matched_domain, matched_entry]
    end

    # One proven email => one membership per org. Pre-check for a friendly
    # error; the unique index on memberships is the backstop.
    def ensure_address_unclaimed!(address)
      normalized = Organizations.configuration.normalize_verification_email(address)
      return unless Membership.where(organization_id: organization_id, verified_email_normalized: normalized).exists?

      raise VerificationEmailAlreadyClaimed,
            Organizations.t(:"errors.verification_email_already_claimed")
    end

    def ensure_send_allowed!
      config = Organizations.configuration

      if verification_sends_count >= config.verification_max_sends
        raise VerificationThrottled, Organizations.t(:"errors.verification_sends_exceeded")
      end

      resend_floor = interval_ago(config.verification_resend_interval)
      return unless verification_sent_at.present? && verification_sent_at > resend_floor

      raise VerificationThrottled, Organizations.t(:"errors.verification_resend_throttled")
    end

    def ensure_active_challenge!
      config = Organizations.configuration

      raise VerificationCodeInvalid, Organizations.t(:"errors.verification_code_missing") if verification_code_digest.blank?

      if verification_attempts >= config.verification_max_attempts
        raise VerificationAttemptsExceeded, Organizations.t(:"errors.verification_attempts_exceeded")
      end

      return unless verification_expires_at.blank? || verification_expires_at <= Time.current

      raise VerificationCodeExpired, Organizations.t(:"errors.verification_code_expired")
    end

    def correct_code?(code)
      submitted = self.class.digest_verification_code(code.to_s.strip, id)
      ActiveSupport::SecurityUtils.secure_compare(submitted, verification_code_digest)
    end

    def challenge_attributes(address, code, matched_domain, matched_entry)
      config = Organizations.configuration

      {
        verification_email: address,
        verification_email_normalized: config.normalize_verification_email(address),
        verification_code_digest: self.class.digest_verification_code(code, id),
        verification_sent_at: Time.current,
        verification_expires_at: Time.current + config.verification_code_ttl,
        verification_attempts: 0,
        verification_sends_count: verification_sends_count + 1,
        verified_at: nil,
        joined_via: joined_via.presence || (matched_domain ? "domain_email" : "allowlist"),
        metadata: (metadata || {}).merge(
          "matched_domain_id" => matched_domain&.id,
          "matched_allowlist_entry_id" => matched_entry&.id
        ).compact
      }
    end

    def create_membership!
      effective_joined_via = joined_via.presence || "manual"

      # THE MEMBERSHIP GATE (strict, vetoing, pre-persist) — covers every
      # verified-joining path, since approval is the only way a request
      # becomes a membership (codes, domains, allowlists, account-email
      # shortcut all funnel here). Runs inside approve!'s locked transaction:
      # a veto rolls back the status flip too, so the request stays PENDING —
      # a safe, resumable state (approve again once the host unblocks).
      # ⚠️ Join-code nuance: redemption consumes a use BEFORE approval, so a
      # vetoed redemption still spends a use — max_uses is an anti-abuse cap,
      # not a seat count (see README "Verified joining").
      Callbacks.dispatch(
        :member_joining,
        strict: true,
        organization: organization,
        user: user,
        role: "member",
        joined_via: effective_joined_via,
        join_request: self
      )

      organization.memberships.create!(
        user: user,
        role: "member",
        joined_via: effective_joined_via,
        verified_email: email_verified? ? verification_email : nil,
        verified_email_normalized: email_verified? ? verification_email_normalized : nil,
        verified_at: verified_at,
        metadata: resolved_membership_metadata
      )
    rescue ActiveRecord::RecordNotUnique
      # Two possible unique collisions:
      # 1. (user, org) membership race — another path just made them a member.
      # 2. (org, verified_email_normalized) — the proven address was claimed
      #    concurrently. Surface the same friendly error as the pre-check.
      existing = organization.memberships.find_by(user_id: user_id)
      return existing if existing

      raise VerificationEmailAlreadyClaimed,
            Organizations.t(:"errors.verification_email_already_claimed")
    end

    def resolved_membership_metadata
      merged = {}
      merged = merged.merge(hashify(matched_domain&.membership_metadata))
      merged = merged.merge(hashify(matched_allowlist_entry&.membership_metadata))
      merged.merge(hashify(join_code&.membership_metadata))
    end

    def hashify(value)
      value.is_a?(Hash) ? value : {}
    end

    def matched_domain
      domain_id = (metadata || {})["matched_domain_id"]
      return nil unless domain_id

      @matched_domain ||= organization.domains.find_by(id: domain_id)
    end

    def matched_allowlist_entry
      entry_id = (metadata || {})["matched_allowlist_entry_id"]
      return nil unless entry_id

      @matched_allowlist_entry ||= organization.allowlist_entries.find_by(id: entry_id)
    end

    def claim_matched_allowlist_entry!
      matched_allowlist_entry&.claim!(user)
    end

    def generate_verification_code
      format("%06d", SecureRandom.random_number(1_000_000))
    end

    def interval_ago(interval)
      Time.current - interval
    end

    def deliver_verification_email(code)
      mailer_class = Organizations.configuration.verification_mailer.constantize
      mailer_class.code_email(self, code).deliver_later
    rescue StandardError => e
      # The challenge row already COMMITTED (throttle stamped, send counted)
      # before delivery was attempted — if we only logged here, the user
      # would sit behind the resend throttle (and burn one of max_sends)
      # waiting for a code that never left the building. Roll the throttle
      # bookkeeping back so an immediate retry is allowed, and give the host
      # a real signal (the on_verification_delivery_failed callback) instead
      # of a log line nobody watches.
      rollback_undelivered_challenge!(code)
      Callbacks.log_error("[Organizations] Failed to send verification email: #{e.message}")
      Callbacks.dispatch(
        :verification_delivery_failed,
        organization: organization,
        user: user,
        join_request: self,
        metadata: { "error_class" => e.class.name, "error_message" => e.message }
      )
    end

    # Revert the challenge bookkeeping for a code that never got delivered.
    # Digest-guarded under lock: if a concurrent resend already minted a new
    # code (different digest) or a verify burned this one (nil digest), the
    # state belongs to that other operation — leave it alone.
    def rollback_undelivered_challenge!(code)
      with_lock do
        break unless verification_code_digest == self.class.digest_verification_code(code, id)

        update!(
          verification_code_digest: nil,
          verification_sent_at: nil,
          verification_expires_at: nil,
          verification_attempts: 0,
          verification_sends_count: [ verification_sends_count - 1, 0 ].max
        )
      end
    rescue StandardError => e
      # Never let cleanup failure mask the original delivery failure.
      Callbacks.log_error("[Organizations] Failed to roll back undelivered challenge: #{e.message}")
    end

    def set_expiry
      expiry = Organizations.configuration.join_request_expiry
      self.expires_at = expiry ? Time.current + expiry : nil
    end

    # Mirrors the DB partial unique index: one open request per (org, user)
    def unique_pending_request
      return unless organization_id && user_id
      return unless status == "pending"

      existing = JoinRequest.where(organization_id: organization_id, user_id: user_id, status: "pending")
        .where.not(id: id)
        .exists?

      errors.add(:user_id, Organizations.t(:"attributes.pending_request_taken")) if existing
    end
  end
  # rubocop:enable Metrics/ClassLength
end
