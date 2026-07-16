# frozen_string_literal: true

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
  # @example
  #   org.add_domain!("inizio.com")
  #   org.add_domain!("alumnos.urjc.es", membership_metadata: { member_kind: "student" })
  #   Organizations::Domain.matching_email("j.doe@inizio.com") # => [domain]
  #
  class Domain < ActiveRecord::Base
    self.table_name = "organizations_domains"

    # === Associations ===

    belongs_to :organization,
               class_name: "Organizations::Organization",
               inverse_of: :domains

    # === Validations ===

    validates :domain, presence: true, uniqueness: { scope: :organization_id }
    validate :domain_shape

    # === Callbacks ===

    before_validation :normalize_domain

    # === Scopes ===

    # All domain rows (across organizations) matching an email's domain.
    # Returns none for emails whose domain can't be safely extracted
    # (multi-@ evasion shapes, blanks).
    scope :matching_email, ->(email) {
      extracted = EmailNormalizer.domain_of(email)
      extracted ? where(domain: extracted) : none
    }

    # === Matching ===

    # Whether an email address belongs to this domain (exact match).
    # @param email [String]
    # @return [Boolean]
    def matches_email?(email)
      extracted = EmailNormalizer.domain_of(email)
      extracted.present? && extracted == domain
    end

    private

    def normalize_domain
      return if domain.blank?

      self.domain = domain.to_s.strip.downcase.delete_prefix("@").chomp(".")
    end

    # Pragmatic hostname shape check: lowercase labels, at least one dot,
    # no whitespace or "@". (IDN domains should be enrolled in punycode form.)
    def domain_shape
      return if domain.blank? # presence validation covers this

      unless domain.match?(/\A[a-z0-9]([a-z0-9\-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9\-]*[a-z0-9])?)+\z/)
        errors.add(:domain, "is not a valid domain name")
      end
    end
  end
end
