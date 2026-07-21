# frozen_string_literal: true

module Organizations
  # Invitation model for inviting users to join an organization.
  # Handles both existing users and new signups with a single invitation link.
  #
  # @example Creating an invitation
  #   invitation = org.send_invite_to!("user@example.com", invited_by: current_user)
  #
  # @example Accepting an invitation
  #   invitation.accept!(user)
  #   # or with auto-inference
  #   invitation.accept! # uses Current.user
  #
  # @example Checking invitation status
  #   invitation.pending?   # => true
  #   invitation.accepted?  # => false
  #   invitation.expired?   # => false
  #
  class Invitation < ActiveRecord::Base
    self.table_name = "organizations_invitations"

    # === Associations ===

    belongs_to :organization,
               class_name: "Organizations::Organization",
               inverse_of: :invitations

    # Optional because inviter can be deleted (dependent: :nullify on User)
    belongs_to :invited_by,
               class_name: Organizations.user_class_name,
               optional: true

    # Alias for invited_by (semantic convenience as per README)
    alias_method :from, :invited_by

    # === Validations ===

    validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
    validates :token, presence: true, uniqueness: true
    validates :role, presence: true, inclusion: { in: ->(_) { Roles::HIERARCHY.map(&:to_s) } }

    # Validate only one non-accepted invitation per email per organization
    # This matches the DB constraint (accepted_at IS NULL), not expiry status
    validate :unique_non_accepted_invitation, on: :create

    # === Callbacks ===

    before_validation :normalize_email
    before_validation :generate_token, on: :create, if: -> { token.blank? }
    before_validation :set_expiry, on: :create, if: -> { expires_at.blank? }

    # === Scopes ===

    # Pending invitations (not accepted and not expired)
    scope :pending, -> {
      where(accepted_at: nil)
        .where("expires_at IS NULL OR expires_at > ?", Time.current)
    }

    # Expired invitations
    scope :expired, -> {
      where(accepted_at: nil)
        .where("expires_at IS NOT NULL AND expires_at <= ?", Time.current)
    }

    # Accepted invitations
    scope :accepted, -> {
      where.not(accepted_at: nil)
    }

    # Find by email (case insensitive)
    scope :for_email, ->(email) {
      where("LOWER(email) = ?", email.to_s.downcase.strip)
    }

    # === Status Methods ===

    # Check if invitation is pending (not accepted and not expired)
    # @return [Boolean]
    def pending?
      accepted_at.nil? && !expired?
    end

    # Check if invitation has been accepted
    # @return [Boolean]
    def accepted?
      accepted_at.present?
    end

    # Check if invitation has expired
    # @return [Boolean]
    def expired?
      return false if expires_at.nil?

      expires_at <= Time.current
    end

    # Get the status as a symbol
    # @return [Symbol] :pending, :accepted, or :expired
    def status
      return :accepted if accepted?
      return :expired if expired?

      :pending
    end

    # === Actions ===

    # Error raised when invitation email doesn't match accepting user
    class EmailMismatch < Organizations::InvitationError; end

    # Error raised when trying to accept an invitation with owner role
    class CannotAcceptAsOwner < Organizations::InvitationError; end

    # Accept the invitation and create membership
    # Uses row-level locking to prevent race conditions
    # @param user [User, nil] The user accepting (uses Current.user if not provided)
    # @param skip_email_validation [Boolean] Skip email matching (for admin acceptance)
    # @return [Membership] The created membership
    # @raise [InvitationExpired] if invitation has expired
    # @raise [InvitationAlreadyAccepted] if already accepted
    # @raise [EmailMismatch] if user email doesn't match invitation email
    def accept!(user = nil, skip_email_validation: false)
      accepting_user = user || current_user_from_context

      unless accepting_user
        raise ArgumentError, "User is required to accept invitation (or set Current.user)"
      end

      # Validate email matches at model level (security)
      unless skip_email_validation
        if accepting_user.respond_to?(:email) && !for_email?(accepting_user.email)
          raise EmailMismatch, Organizations.t(:"errors.invitation_email_mismatch")
        end
      end

      membership = nil

      ActiveRecord::Base.transaction do
        # Lock the invitation row to prevent race conditions
        lock!

        # Re-check status after acquiring lock
        if accepted?
          # Already accepted - return existing membership when present.
          # If membership was removed later, keep this invitation non-reusable.
          existing_membership = organization.memberships.find_by(user_id: accepting_user.id)
          return existing_membership if existing_membership

          raise InvitationAlreadyAccepted, Organizations.t(:"errors.invitation_already_accepted")
        end

        if expired?
          raise InvitationExpired, Organizations.t(:"errors.invitation_expired")
        end

        # Owner role cannot be assigned via invitation (defense in depth)
        if role.to_sym == :owner
          raise CannotAcceptAsOwner, Organizations.t(:"errors.invitation_accept_as_owner")
        end

        # Check if user is already a member (race condition from another invitation)
        existing_membership = organization.memberships.find_by(user_id: accepting_user.id)
        if existing_membership
          update!(accepted_at: Time.current)
          return existing_membership
        end

        # Create the membership (with verified-joining provenance)
        membership = create_membership_for!(accepting_user, skip_email_validation)

        # Mark invitation as accepted
        update!(accepted_at: Time.current)
      end

      Callbacks.dispatch(
        :member_joined,
        organization: organization,
        membership: membership,
        user: accepting_user
      )

      membership
    end

    # Resend the invitation email
    # Generates new token and resets expiry
    # @return [self]
    def resend!
      ActiveRecord::Base.transaction do
        lock!

        if accepted?
          raise InvitationAlreadyAccepted, Organizations.t(:"errors.invitation_cannot_resend_accepted")
        end

        update!(
          token: generate_unique_token,
          expires_at: calculate_expiry
        )
      end

      send_invitation_email
      self
    end

    # Get the acceptance URL
    # @param base_url [String, nil] Base URL for the link
    # @return [String]
    def acceptance_url(base_url: nil)
      base = base_url || default_base_url
      # Organizations.engine_mount_path keeps this correct for hosts that
      # mount the engine somewhere other than root ("/orgs/invitations/…") —
      # a hardcoded "/invitations/…" silently 404'd for them.
      "#{base}#{Organizations.engine_mount_path}/invitations/#{token}"
    end

    # Check if invitation matches a specific email
    # @param check_email [String] Email to check
    # @return [Boolean]
    def for_email?(check_email)
      email.downcase == check_email.to_s.downcase.strip
    end

    private

    # Create the membership for an acceptance.
    # Uses invited_by_id instead of invited_by to avoid Rails class reloading
    # issues (AssociationTypeMismatch when User is reloaded in development).
    #
    # Verified-joining provenance (v0.5.0): accepting the emailed token is
    # proof of control of the invited address, so the membership records it
    # as a verified email — UNLESS the acceptance bypassed the email match
    # (skip_email_validation with a different account email), where no inbox
    # proof exists. If the address was already claimed by another membership
    # in this org (rare recycled-address edge), the membership is still
    # created, just without the verified-email stamp.
    def create_membership_for!(accepting_user, skip_email_validation)
      # THE MEMBERSHIP GATE (strict, vetoing, pre-persist) — see
      # Configuration#on_member_joining. Runs inside accept!'s locked
      # transaction: a veto rolls back accepted_at too, so the invitation
      # stays pending and can be accepted again once the host unblocks.
      Callbacks.dispatch(
        :member_joining,
        strict: true,
        organization: organization,
        user: accepting_user,
        role: role,
        joined_via: "invited",
        invitation: self
      )

      # SAVEPOINT (requires_new): rescued unique-violation inside accept!'s
      # transaction — see JoinRequest#create_membership! for the PostgreSQL
      # aborted-transaction rationale (proven by the PG leg of the suite).
      ActiveRecord::Base.transaction(requires_new: true) do
        organization.memberships.create!(
          **base_membership_attributes(accepting_user),
          **verified_email_attributes_for(accepting_user, skip_email_validation)
        )
      end
    rescue ActiveRecord::RecordNotUnique
      # Two unique indexes can fire here (same disambiguation as
      # JoinRequest#create_membership!):
      # 1. (user, org) — another acceptance/join path just made them a member:
      #    reuse it (invitations to one address aren't normalization-aware, so
      #    two plus-variant invitations can race).
      # 2. (org, verified_email_normalized) — the address was claimed between
      #    our pre-check and the INSERT: degrade gracefully by creating the
      #    membership WITHOUT the verified-email stamp. Acceptance never breaks.
      existing = organization.memberships.find_by(user_id: accepting_user.id)
      return existing if existing

      # Its own savepoint too: this fallback INSERT can itself lose the
      # (user, org) race, and accept!'s rescue must stay reachable on PG.
      ActiveRecord::Base.transaction(requires_new: true) do
        organization.memberships.create!(**base_membership_attributes(accepting_user))
      end
    end

    def base_membership_attributes(accepting_user)
      {
        user: accepting_user,
        role: role,
        invited_by_id: invited_by_id,
        joined_via: "invited",
        metadata: membership_metadata.is_a?(Hash) ? membership_metadata : {}
      }
    end

    # Provenance attributes for the membership created by this acceptance.
    # See create_membership_for! for the trust rules.
    def verified_email_attributes_for(accepting_user, skip_email_validation)
      email_proven =
        !skip_email_validation ||
        (accepting_user.respond_to?(:email) && for_email?(accepting_user.email))

      return {} unless email_proven

      normalized = Organizations.configuration.normalize_verification_email(email)

      already_claimed = Membership
                        .where(organization_id: organization_id, verified_email_normalized: normalized)
                        .exists?

      return {} if already_claimed

      {
        verified_email: email,
        verified_email_normalized: normalized,
        verified_at: Time.current
      }
    end

    def normalize_email
      self.email = email.to_s.downcase.strip if email.present?
    end

    def generate_token
      self.token = generate_unique_token
    end

    def generate_unique_token
      loop do
        new_token = SecureRandom.urlsafe_base64(32)
        break new_token unless Invitation.exists?(token: new_token)
      end
    end

    def set_expiry
      self.expires_at = calculate_expiry
    end

    def calculate_expiry
      expiry = Organizations.configuration.invitation_expiry
      return nil unless expiry

      Time.current + expiry
    end

    # Matches the DB constraint: only one non-accepted invitation per email per org
    def unique_non_accepted_invitation
      return unless organization_id && email.present?

      # Check for any non-accepted invitation (matches DB partial unique index)
      existing = Invitation.where(organization_id: organization_id, accepted_at: nil)
                           .for_email(email)
                           .where.not(id: id)
                           .exists?

      if existing
        errors.add(:email, Organizations.t(:"attributes.invitation_taken"))
      end
    end

    def send_invitation_email
      mailer_class = Organizations.configuration.invitation_mailer.constantize
      mailer_class.invitation_email(self).deliver_later
    rescue StandardError => e
      Callbacks.log_error("[Organizations] Failed to send invitation email: #{e.message}")
    end

    def current_user_from_context
      if defined?(Current) && Current.respond_to?(:user)
        Current.user
      end
    end

    def default_base_url
      if Organizations.full_rails_app? && Rails.application.routes
        Rails.application.routes.url_helpers.root_url.chomp("/")
      else
        ""
      end
    rescue StandardError
      ""
    end
  end
end

# Host extension seam — see the load-hooks note in models/organization.rb.
ActiveSupport.run_load_hooks(:organizations_invitation, Organizations::Invitation)
