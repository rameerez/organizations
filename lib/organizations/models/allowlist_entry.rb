# frozen_string_literal: true

module Organizations
  # A pre-approved email address on an organization's roster/allowlist,
  # used for verified joining when the organization has no email domain
  # of its own (clubs, associations, mixed-provider orgs).
  #
  # A user who proves control of a rostered inbox (emailed code) becomes a
  # verified member and the entry is marked claimed. Proof-of-control is
  # still required — a leaked roster must never grant membership without
  # inbox access.
  #
  # Entries are typically bulk-imported: see Organization#import_allowlist!.
  #
  # @example
  #   org.import_allowlist!(["ana@gmail.com", "luis@yahoo.es"], source: "csv_2026-07")
  #
  class AllowlistEntry < ActiveRecord::Base
    self.table_name = "organizations_allowlist_entries"

    # === Associations ===

    belongs_to :organization,
               class_name: "Organizations::Organization",
               inverse_of: :allowlist_entries

    belongs_to :claimed_by,
               class_name: Organizations.user_class_name,
               optional: true

    # === Validations ===

    validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
    # Proc message: resolved at VALIDATION time so it follows I18n.locale.
    validates :email_normalized, presence: true,
                                 uniqueness: { scope: :organization_id,
                                               message: ->(*) { Organizations.t(:"attributes.allowlist_taken") } }

    # === Callbacks ===

    before_validation :normalize_email

    # === Scopes ===

    # Entries not yet consumed by a membership
    scope :unclaimed, -> { where(claimed_at: nil) }

    # Entries matching an email (through the configured normalizer)
    scope :for_email, lambda { |email|
      where(email_normalized: Organizations.configuration.normalize_verification_email(email))
    }

    # === Status ===

    # @return [Boolean]
    def claimed?
      claimed_at.present?
    end

    # Mark this entry as consumed by a user's membership.
    # Idempotent: claiming an already-claimed entry is a no-op.
    # @param user [User]
    # @return [self]
    def claim!(user)
      return self if claimed?

      with_lock do
        break if claimed?

        update!(claimed_at: Time.current, claimed_by_id: user.id)
      end

      self
    end

    private

    def normalize_email
      return if email.blank?

      self.email = email.to_s.strip
      self.email_normalized = Organizations.configuration.normalize_verification_email(email)
    end
  end
end

# Host extension seam — see the load-hooks note in models/organization.rb.
ActiveSupport.run_load_hooks(:organizations_allowlist_entry, Organizations::AllowlistEntry)
