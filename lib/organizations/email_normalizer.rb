# frozen_string_literal: true

module Organizations
  # Default email normalization for verified joining.
  #
  # Verified joining enforces "one proven email address => one membership per
  # organization" (partial unique index on memberships.verified_email_normalized).
  # That invariant is only meaningful if trivially-aliased addresses collapse to
  # the same normalized value, otherwise one inbox can mint unlimited "distinct"
  # identities via plus-addressing (user+1@corp.com, user+2@corp.com, ...).
  #
  # Normalization rules (deliberately conservative):
  # - downcase + strip surrounding whitespace
  # - strip a single trailing dot from the domain (FQDN form: "corp.com.")
  # - drop the +tag suffix from the local part (RFC 5233 subaddressing)
  #
  # Gmail-style dot-collapsing in the local part is intentionally NOT applied:
  # dots are significant in most corporate mail systems, and collapsing them
  # would wrongly merge distinct mailboxes (j.doe@ vs jdoe@).
  #
  # Hosts can replace this wholesale via:
  #   config.verification_email_normalizer = ->(email) { ... }
  #
  # @example
  #   EmailNormalizer.normalize("  J.Doe+carpool@INIZIO.COM. ") # => "j.doe@inizio.com"
  #   EmailNormalizer.domain_of("j.doe@inizio.com")             # => "inizio.com"
  #   EmailNormalizer.domain_of("evil@a.com@b.com")             # => nil (multi-@ rejected)
  #
  module EmailNormalizer
    module_function

    # Normalize an email address for uniqueness comparison.
    # @param email [String, nil]
    # @return [String] normalized email ("" for blank input)
    def normalize(email)
      value = email.to_s.strip.downcase
      return "" if value.empty?

      local, at, domain = value.rpartition("@")
      return value if at.empty? # not an email shape; leave as-is (validation rejects it upstream)

      local = local.split("+", 2).first.to_s
      domain = domain.chomp(".")

      "#{local}@#{domain}"
    end

    # Extract the domain of an email address, hardened against evasion shapes.
    # Returns nil (instead of guessing) when the address doesn't have exactly
    # one "@" — multi-@ addresses are a classic trick against naive splitting.
    # A single trailing dot (FQDN form) is tolerated and stripped.
    # @param email [String, nil]
    # @return [String, nil] lowercased domain, or nil if not extractable
    def domain_of(email)
      value = email.to_s.strip.downcase
      return nil if value.empty?
      return nil unless value.count("@") == 1

      domain = value.split("@", 2).last.to_s.chomp(".")
      return nil if domain.empty? || domain.include?("@")

      domain
    end
  end
end
