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
    self.table_name = "organization_invitations"

    # === Associations ===

    belongs_to :organization,
               class_name: "Organizations::Organization",
               inverse_of: :invitations

    # Optional because inviter can be deleted (dependent: :nullify on User)
    belongs_to :invited_by,
               class_name: "User",
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
          raise EmailMismatch, "This invitation was sent to a different email address"
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

          raise InvitationAlreadyAccepted, "This invitation has already been accepted"
        end

        if expired?
          raise InvitationExpired, "This invitation has expired"
        end

        # Owner role cannot be assigned via invitation (defense in depth)
        if role.to_sym == :owner
          raise CannotAcceptAsOwner, "Cannot accept invitation as owner. Invite as admin, then use transfer_ownership_to! after joining."
        end

        # Check if user is already a member (race condition from another invitation)
        existing_membership = organization.memberships.find_by(user_id: accepting_user.id)
        if existing_membership
          update!(accepted_at: Time.current)
          return existing_membership
        end

        # Create the membership
        # Use invited_by_id instead of invited_by to avoid Rails class reloading issues
        # (AssociationTypeMismatch when User class is reloaded in development)
        membership = organization.memberships.create!(
          user: accepting_user,
          role: role,
          invited_by_id: invited_by_id
        )

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
          raise InvitationAlreadyAccepted, "Cannot resend an accepted invitation"
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
      "#{base}/invitations/#{token}"
    end

    # Check if invitation matches a specific email
    # @param check_email [String] Email to check
    # @return [Boolean]
    def for_email?(check_email)
      email.downcase == check_email.to_s.downcase.strip
    end

    private

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
        errors.add(:email, "has already been invited to this organization")
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
      if defined?(Rails) && Rails.application&.routes
        Rails.application.routes.url_helpers.root_url.chomp("/")
      else
        ""
      end
    rescue StandardError
      ""
    end
  end
end
