# frozen_string_literal: true

module Organizations
  # A shareable join code ("PIN") for an organization — the classroom/Slack
  # style joining mechanism. Codes are globally unique so redemption needs no
  # organization context (QR posters, links, plain typing).
  #
  # Per-code knobs:
  # - `requires_verified_domain_email` — redemption additionally requires the
  #   emailed-code challenge against one of the org's domains (the "reinforced"
  #   level). Per-code (not per-org) so one org can run both levels at once.
  # - `auto_approve` — false means redemption parks a pending JoinRequest for
  #   manual approval instead of granting membership immediately.
  # - `expires_at`, `max_uses`, `revoked_at` — abuse containment. Rotation is
  #   revoke + generate a new code (history preserved for audit).
  # - `label` — campaign attribution ("cafeteria poster" vs "newsletter").
  #
  # `membership_metadata` is copied onto memberships created through this code.
  #
  # @example
  #   code = org.generate_join_code!(label: "poster", requires_verified_domain_email: true)
  #   Organizations::JoinCode.redeem(code.code, user: user)
  #   # => Membership (instant join) or JoinRequest (challenge/approval pending)
  #
  class JoinCode < ActiveRecord::Base
    self.table_name = "organizations_join_codes"

    # Ambiguity-free alphabet (no I/L/O/0/1 lookalikes) — same idea as
    # user-facing referral codes: survives posters, print, and dictation.
    CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
    DEFAULT_CODE_LENGTH = 8

    # === Associations ===

    belongs_to :organization,
               class_name: "Organizations::Organization",
               inverse_of: :join_codes

    belongs_to :created_by,
               class_name: Organizations.user_class_name,
               optional: true

    # Requests OUTLIVE the codes that created them (they are the join audit
    # trail; joined_via/metadata are already snapshotted) — deleting a code
    # nullifies the linkage instead of cascading or violating the FK.
    # Prefer revoke! over destroy for rotation; destroy stays safe regardless.
    has_many :join_requests,
             class_name: "Organizations::JoinRequest",
             inverse_of: :join_code,
             dependent: :nullify

    # === Validations ===

    validates :code, presence: true, uniqueness: true
    validates :max_uses, numericality: { only_integer: true, greater_than: 0, allow_nil: true }
    validates :uses_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

    # === Callbacks ===

    before_validation :normalize_code
    before_validation :generate_code, on: :create, if: -> { code.blank? }

    # === Scopes ===

    scope :not_revoked, -> { where(revoked_at: nil) }

    # Codes that can actually be redeemed right now — the SQL twin of
    # #active? (not revoked, not expired, not exhausted). Powers
    # Organization#accepts_code_joining? without loading rows.
    scope :active, lambda {
      not_revoked
        .where("expires_at IS NULL OR expires_at > ?", Time.current)
        .where("max_uses IS NULL OR uses_count < max_uses")
    }

    # === Status ===

    # @return [Boolean]
    def revoked?
      revoked_at.present?
    end

    # @return [Boolean]
    def expired?
      expires_at.present? && expires_at <= Time.current
    end

    # @return [Boolean]
    def exhausted?
      max_uses.present? && uses_count >= max_uses
    end

    # @return [Boolean]
    def active?
      !revoked? && !expired? && !exhausted?
    end

    # @return [Symbol] :active, :revoked, :expired, or :exhausted
    def status
      return :revoked if revoked?
      return :expired if expired?
      return :exhausted if exhausted?

      :active
    end

    # Revoke this code (rotation = revoke + generate a new one). Idempotent.
    # @return [self]
    def revoke!
      return self if revoked?

      with_lock do
        break if revoked?

        update!(revoked_at: Time.current)
      end

      self
    end

    # Presentation form, grouped for readability: "7FHK2MPX" => "7FHK-2MPX".
    # Storage and matching always use the bare form.
    # @return [String]
    def display_code
      code.to_s.scan(/.{1,4}/).join("-")
    end

    # === Redemption ===

    # Redeem a code for a user.
    # @param code [String] the code as typed (case/hyphen/space insensitive)
    # @param user [User] the redeeming user
    # @return [Membership] when the code grants instant membership (or the
    #   user is already a member)
    # @return [JoinRequest] when a challenge or manual approval is still needed
    # @raise [JoinCodeInvalid] for unknown, revoked, or expired codes
    # @raise [JoinCodeExhausted] when max_uses is spent
    def self.redeem(code, user:)
      normalized = normalize(code)
      raise JoinCodeInvalid, Organizations.t(:"errors.join_code_invalid") if normalized.blank?

      join_code = find_by(code: normalized)
      raise JoinCodeInvalid, Organizations.t(:"errors.join_code_invalid") unless join_code

      join_code.redeem!(user: user)
    end

    # Instance-level redemption. See .redeem for semantics.
    def redeem!(user:)
      raise ArgumentError, "user is required" unless user

      outcome = nil

      ActiveRecord::Base.transaction do
        # Lock the code row: uses_count accounting and the max_uses cap must
        # be race-safe (two concurrent redemptions of a max_uses: 1 code must
        # yield exactly one success).
        lock!
        ensure_redeemable!

        # Already a member — idempotent no-op that does NOT consume a use.
        existing_membership = organization.memberships.find_by(user_id: user.id)
        if existing_membership
          outcome = existing_membership
          raise ActiveRecord::Rollback # nothing to persist
        end

        outcome = attach_request!(user)
      end

      # Instant-join path: no email challenge required and auto-approve on.
      # Approval runs AFTER the redemption transaction commits so the
      # member_joined/join_request_approved callbacks never fire for a
      # transaction that could still roll back. If approval fails, the
      # pending request survives — a safe, resumable state.
      return outcome unless outcome.is_a?(JoinRequest)
      return outcome if requires_verified_domain_email? || !auto_approve?

      outcome.approve!(decided_by: nil)
    end

    # Normalize user input to storage form: uppercase, strip separators.
    # @param code [String, nil]
    # @return [String]
    def self.normalize(code)
      code.to_s.upcase.gsub(/[\s-]/, "")
    end

    private

    def ensure_redeemable!
      raise JoinCodeInvalid, Organizations.t(:"errors.join_code_invalid") if revoked? || expired?
      raise JoinCodeExhausted, Organizations.t(:"errors.join_code_exhausted") if exhausted?
    end

    # Attach this code to the user's open request (creating one if needed),
    # consuming a use — except for idempotent re-redemptions of the same code.
    def attach_request!(user)
      request = pending_request_for(user)

      # Same user re-redeeming the same code: idempotent, no extra use.
      return request if request.persisted? && request.join_code_id == id

      request.join_code = self
      request.joined_via = "code"
      request.save!
      increment!(:uses_count)
      request
    end

    # Find or build this user's open request for the organization.
    # Reuses an existing pending request (partial unique index: one pending
    # request per user per org) so re-entry via a different mechanism upgrades
    # the same request instead of exploding.
    def pending_request_for(user)
      organization.join_requests.pending.find_by(user_id: user.id) ||
        organization.join_requests.new(user: user)
    end

    def normalize_code
      self.code = self.class.normalize(code) if code.present?
    end

    def generate_code
      generator = Organizations.configuration.join_code_generator

      self.code = loop do
        candidate =
          if generator.respond_to?(:call)
            self.class.normalize(generator.call)
          else
            Array.new(DEFAULT_CODE_LENGTH) { CODE_ALPHABET[SecureRandom.random_number(CODE_ALPHABET.length)] }.join
          end

        break candidate unless self.class.exists?(code: candidate)
      end
    end
  end
end

# Host extension seam — see the load-hooks note in models/organization.rb.
ActiveSupport.run_load_hooks(:organizations_join_code, Organizations::JoinCode)
