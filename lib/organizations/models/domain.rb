# frozen_string_literal: true

require "active_support/security_utils"

module Organizations
  # An email domain owned/claimed by an organization, used for verified joining.
  #
  # A user who proves control of an inbox under one of the organization's
  # domains (emailed code, or an already-confirmed account email — see
  # Organization#join_with_account_email!) is considered a verified member.
  #
  # Matching is EXACT and dot-boundary safe: "alumnos.urjc.es" and "urjc.es"
  # are two different domains and must both be enrolled if both should join.
  # This is deliberate — subdomains often carry different member semantics
  # (e.g. students vs employees), and suffix matching would collapse them.
  # It also neutralizes lookalike attacks ("urjc.es.evil.com" never equals
  # "urjc.es").
  #
  # `membership_metadata` is copied onto memberships created through this
  # domain (see JoinRequest#approve!) — hosts use it for cohort tags like
  # { "member_kind" => "student" } without the gem interpreting the contents.
  #
  # DOMAIN AUTHORITY (v0.7.0). An emailed code proves control of one inbox,
  # never authority over the whole domain. Authority is a separate claim per
  # organization: a DNS TXT record with an unpredictable token bound to this
  # row (one organization, one exact domain), or an approval recorded by a
  # platform operator who is not a member of the organization.
  #
  #   domain.start_verification!
  #   domain.verification_record_name   # => "_organizations-verification.acme.com"
  #   domain.verification_record_value  # => "organizations-verification=…"
  #   domain.verify!                    # => true, or raises DomainVerificationFailed (#reason)
  #
  # `join_policy` decides what happens when someone with a confirmed account
  # email at this domain signs up: "none" (default), "suggest" (listed in
  # user.suggested_organizations) or "auto_join" (joined through the
  # membership gate). The policy acts only while the domain is verified.
  #
  # @example
  #   org.add_domain!("inizio.com")
  #   org.add_domain!("alumnos.urjc.es", membership_metadata: { member_kind: "student" })
  #   Organizations::Domain.matching_email("j.doe@inizio.com") # => [domain]
  #
  class Domain < ActiveRecord::Base
    self.table_name = "organizations_domains"

    JOIN_POLICIES = %w[none suggest auto_join].freeze
    VERIFICATION_METHODS = %w[dns_txt operator].freeze

    # === Associations ===

    belongs_to :organization,
               class_name: "Organizations::Organization",
               inverse_of: :domains

    # The platform operator who recorded an approval (verification_method "operator")
    belongs_to :verified_by,
               class_name: Organizations.user_class_name,
               optional: true

    # === Validations ===

    validates :domain, presence: true, uniqueness: { scope: :organization_id }
    validate :domain_shape
    validate :domain_not_blocked, if: -> { new_record? || will_save_change_to_domain? }
    validates :join_policy,
              inclusion: { in: JOIN_POLICIES, message: ->(*) { Organizations.t(:"attributes.join_policy_invalid") } },
              if: :authority_columns?

    # === Callbacks ===

    before_validation :normalize_domain
    before_validation :normalize_join_policy, if: :authority_columns?
    # A proof belongs to one claim: one organization and one exact domain.
    before_save :reset_verification, if: lambda {
      persisted? && authority_columns? && (will_save_change_to_domain? || will_save_change_to_organization_id?)
    }

    # === Scopes ===

    # All domain rows (across organizations) matching an email's domain.
    # Returns none for emails whose domain can't be safely extracted
    # (multi-@ evasion shapes, blanks).
    scope :matching_email, lambda { |email|
      extracted = EmailNormalizer.domain_of(email)
      extracted ? where(domain: extracted) : none
    }

    # Domains whose control was proven and not revoked
    scope :verified, -> { where.not(verified_at: nil).where(verification_revoked_at: nil) }

    # Domains with one of these sign-up policies
    scope :with_join_policy, ->(*policies) { where(join_policy: policies.flatten.map(&:to_s)) }

    # Domains that may admit members right now: not revoked, not blocked
    # (config.blocked_email_domains), and verified when
    # config.require_verified_domains is on. Every domain-backed join path
    # reads this scope, at the challenge and again at admission.
    scope :joinable, lambda {
      relation = all
      if authority_columns?
        relation = relation.where(verification_revoked_at: nil)
        relation = relation.verified if Organizations.configuration.require_verified_domains
      elsif Organizations.configuration.require_verified_domains
        relation = none # fail closed before the upgrade migration ran
      end
      blocked = Organizations.configuration.normalized_blocked_email_domains
      blocked.any? ? relation.where.not(domain: blocked) : relation
    }

    # Whether the domain-authority columns exist (rails g organizations:upgrade)
    # @return [Boolean]
    def self.authority_columns?
      table_exists? && column_names.include?("verified_at")
    end

    # The built-in TXT lookup: Resolv, with config.domain_verification_timeout.
    # @return [Proc] ->(record_name) { [String] }
    def self.default_txt_resolver
      lambda do |name|
        require "resolv"
        Resolv::DNS.open do |dns|
          dns.timeouts = Organizations.configuration.domain_verification_timeout
          # A trailing dot makes the name absolute: no resolver search list,
          # so a wildcard record under a search domain cannot answer.
          absolute = name.end_with?(".") ? name : "#{name}."
          dns.getresources(absolute, Resolv::DNS::Resource::IN::TXT).map { |record| record.strings.join }
        end
      end
    end

    # === Matching ===

    # Whether an email address belongs to this domain (exact match).
    # @param email [String]
    # @return [Boolean]
    def matches_email?(email)
      extracted = EmailNormalizer.domain_of(email)
      extracted.present? && extracted == domain
    end

    # === Domain authority ===

    # @return [Boolean] control was proven and not revoked
    def verified?
      authority_columns? && verified_at.present? && verification_revoked_at.blank?
    end

    # @return [Boolean] the verification was revoked
    def revoked?
      authority_columns? && verification_revoked_at.present?
    end

    # @return [Boolean] whether config.blocked_email_domains lists this domain
    def blocked?
      Organizations.configuration.normalized_blocked_email_domains.include?(domain)
    end

    # @return [Boolean] the instance twin of the joinable scope
    def joinable?
      return false if revoked? || blocked?
      return true unless Organizations.configuration.require_verified_domains

      verified?
    end

    # The sign-up policy that acts now: the stored policy while the domain is
    # verified and not blocked, :none otherwise.
    # @return [Symbol] :none, :suggest or :auto_join
    def effective_join_policy
      verified? && !blocked? ? join_policy.to_sym : :none
    end

    # A copy (dup) of a claim carries no proof.
    def initialize_dup(other)
      super
      reset_verification if authority_columns?
    end

    # Start (or restart) the DNS challenge: a new unpredictable token, and
    # any earlier verification cleared. A revocation stays until a new proof
    # succeeds. Publish verification_record_value as a TXT record at
    # verification_record_name, then call verify!.
    # @return [self]
    def start_verification!
      update!(
        verification_token: SecureRandom.urlsafe_base64(32),
        verification_started_at: Time.current,
        verified_at: nil, verification_method: nil, verified_by_id: nil
      )
      self
    end

    # @return [String] where the TXT record goes, e.g. "_organizations-verification.acme.com"
    def verification_record_name
      "#{Organizations.configuration.domain_verification_record_prefix}.#{domain}"
    end

    # @return [String, nil] the exact TXT value, e.g. "organizations-verification=…"
    def verification_record_value
      return nil if verification_token.blank?

      "#{Organizations.configuration.domain_verification_record_prefix.delete_prefix('_')}=#{verification_token}"
    end

    # @return [Boolean] the open challenge is past config.domain_verification_ttl
    def verification_expired?
      verification_started_at.blank? ||
        verification_started_at + Organizations.configuration.domain_verification_ttl <= Time.current
    end

    # Check the TXT record and mark the domain verified. The DNS lookup runs
    # outside any row lock; rate-limit the endpoint that calls this.
    # @return [self]
    # @raise [DomainVerificationFailed] reason :not_started, :expired,
    #   :record_not_found or :lookup_failed
    def verify!
      reload
      raise DomainVerificationFailed, :not_started if verification_token.blank?
      raise DomainVerificationFailed, :expired if verification_expired?

      snapshot = challenge_snapshot
      raise DomainVerificationFailed, :record_not_found unless txt_record_present?(verification_record_value)

      with_lock do
        # The claim changed during the lookup (new token, other domain or
        # organization, a revocation) or the challenge expired: the lookup
        # proves nothing about the claim as it is now.
        raise DomainVerificationFailed, :changed if challenge_snapshot != snapshot
        raise DomainVerificationFailed, :expired if verification_expired?

        update!(verified_at: Time.current, verification_method: "dns_txt",
                verified_by_id: nil, verification_revoked_at: nil)
      end
      self
    end

    # Record an approval by a trusted platform operator who checked the
    # claim another way. The claiming organization cannot self-attest: an
    # operator who is a member of it is refused. Authorizing the operator as
    # platform staff is the host's job.
    # @param operator [User]
    # @param note [String, nil] audit provenance, kept in metadata["verification_note"]
    # @return [self]
    # @raise [Organizations::NotAuthorized] when the operator is a member of the organization
    def verify_by_operator!(operator:, note: nil)
      raise ArgumentError, "operator is required" unless operator

      ActiveRecord::Base.transaction do
        # The organization row lock serializes this check with joins that
        # take it (the seat-limit gate pattern) and with ownership changes.
        organization.lock!
        lock!
        if organization.memberships.exists?(user_id: operator.id)
          raise Organizations::NotAuthorized.new(Organizations.t(:"errors.domain_operator_is_member", organization: organization),
                                                 organization: organization, user: operator)
        end

        update!(verified_at: Time.current, verification_method: "operator", verified_by_id: operator.id,
                verification_revoked_at: nil, metadata: metadata_with("verification_note" => note))
      end
      self
    end

    # Revoke the verification. New domain-backed admissions stop (also
    # pending ones); existing members stay. The verification stays on record
    # for audit. Idempotent.
    # @param reason [String, nil] kept in metadata["verification_revoked_reason"]
    # @return [self]
    def revoke_verification!(reason: nil)
      return self if revoked?

      update!(verification_revoked_at: Time.current, metadata: metadata_with("verification_revoked_reason" => reason))
      self
    end

    # Re-check a DNS verification (run it on a schedule if you like). Revokes
    # when the TXT record is gone; a lookup failure raises and changes
    # nothing. An operator approval is not re-checked. Read verified? after.
    # @return [self]
    # @raise [DomainVerificationFailed] reason :lookup_failed
    def recheck_verification!
      reload
      return self unless verified? && verification_method == "dns_txt"

      snapshot = proof_snapshot
      return self if txt_record_present?(verification_record_value)

      with_lock do
        # Revoke only the proof that was checked, never a newer one.
        revoke_verification!(reason: "dns_record_removed") if proof_snapshot == snapshot
      end
      self
    end

    private

    def authority_columns?
      self.class.authority_columns?
    end

    # metadata with these keys set, or removed when the value is nil. Other
    # keys (the host's) stay exactly as they are.
    def metadata_with(values)
      values.each_with_object((metadata || {}).dup) do |(key, value), result|
        value.nil? ? result.delete(key) : result[key] = value
      end
    end

    def challenge_snapshot
      [verification_token, domain, organization_id, verification_revoked_at]
    end

    def proof_snapshot
      [verification_token, verified_at, verification_method, domain, organization_id]
    end

    def txt_record_present?(expected)
      resolver = Organizations.configuration.domain_txt_resolver || self.class.default_txt_resolver
      values = Array(resolver.call(verification_record_name)).map { |value| value.to_s.strip }
      values.any? { |value| ActiveSupport::SecurityUtils.secure_compare(value, expected) }
    rescue StandardError => e
      # Resolv::ResolvError/ResolvTimeout, socket errors, or a host resolver's
      # own error. Logged, so a broken resolver does not look like an outage.
      Callbacks.log_warn("[Organizations] TXT lookup for #{verification_record_name} failed: #{e.class}: #{e.message}")
      raise DomainVerificationFailed, :lookup_failed
    end

    def normalize_join_policy
      self.join_policy = join_policy.to_s if join_policy.is_a?(Symbol)
    end

    def reset_verification
      self.verification_token = nil
      self.verification_started_at = nil
      self.verified_at = nil
      self.verification_method = nil
      self.verified_by_id = nil
      self.verification_revoked_at = nil
    end

    def domain_not_blocked
      return if domain.blank? || !blocked?

      errors.add(:domain, Organizations.t(:"attributes.domain_blocked", organization: organization))
    end

    def normalize_domain
      return if domain.blank?

      self.domain = domain.to_s.strip.downcase.delete_prefix("@").chomp(".")
    end

    # Pragmatic hostname shape check: lowercase labels, at least one dot,
    # no whitespace or "@". (IDN domains should be enrolled in punycode form.)
    def domain_shape
      return if domain.blank? # presence validation covers this

      unless domain.match?(/\A[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+\z/)
        errors.add(:domain, Organizations.t(:"attributes.domain_invalid", organization: organization))
      end
    end
  end
end

# Host extension seam — see the load-hooks note in models/organization.rb.
ActiveSupport.run_load_hooks(:organizations_domain, Organizations::Domain)
