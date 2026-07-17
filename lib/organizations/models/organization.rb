# frozen_string_literal: true

module Organizations
  # Organization model representing a team, workspace, or account.
  # Users belong to organizations through memberships with specific roles.
  #
  # @example Creating an organization
  #   org = Organization.create!(name: "Acme Corp")
  #
  # @example Adding members
  #   org.add_member!(user, role: :admin)
  #
  # @example Querying members
  #   org.owner        # => User (the owner)
  #   org.admins       # => [User, User] (admins including owner)
  #   org.member_count # => 5
  #
  class Organization < ActiveRecord::Base
    self.table_name = "organizations_organizations"

    # Error raised when trying to perform invalid operations on organization
    class CannotRemoveOwner < Organizations::Error; end
    class CannotDemoteOwner < Organizations::Error; end
    class CannotHaveMultipleOwners < Organizations::Error; end
    class CannotTransferToNonMember < Organizations::Error; end
    class CannotTransferToNonAdmin < Organizations::Error; end
    class CannotInviteAsOwner < Organizations::Error; end
    class NoOwnerPresent < Organizations::Error; end
    class MemberAlreadyExists < Organizations::Error; end

    # === Associations ===

    has_many :memberships,
             class_name: "Organizations::Membership",
             inverse_of: :organization,
             dependent: :destroy

    has_many :users,
             through: :memberships

    has_many :invitations,
             class_name: "Organizations::Invitation",
             inverse_of: :organization,
             dependent: :destroy

    # === Verified joining (v0.5.0) ===

    has_many :domains,
             class_name: "Organizations::Domain",
             inverse_of: :organization,
             dependent: :destroy

    # NOTE: join_requests are declared BEFORE join_codes on purpose — Rails
    # runs dependent: :destroy cascades in DECLARATION order, and requests
    # hold an FK to the code that created them. Requests must die first (and
    # JoinCode#join_requests additionally nullifies for standalone deletes).
    has_many :join_requests,
             class_name: "Organizations::JoinRequest",
             inverse_of: :organization,
             dependent: :destroy

    has_many :join_codes,
             class_name: "Organizations::JoinCode",
             inverse_of: :organization,
             dependent: :destroy

    has_many :allowlist_entries,
             class_name: "Organizations::AllowlistEntry",
             inverse_of: :organization,
             dependent: :destroy

    # === Validations ===

    validates :name, presence: true

    # === Scopes ===

    # Find all organizations where a user is a member
    # Uses efficient JOIN query
    # @param user [User] The user
    # @return [ActiveRecord::Relation]
    scope :with_member, ->(user) {
      joins(:memberships).where(organizations_memberships: { user_id: user.id })
    }

    # === Member Query Methods ===

    # Get the owner of this organization
    # @return [User, nil]
    def owner
      owner_membership&.user
    end

    # Get the owner's membership
    # @return [Membership, nil]
    def owner_membership
      if association(:memberships).loaded?
        memberships.find { |membership| membership.role == "owner" }
      else
        memberships.find_by(role: "owner")
      end
    end

    # Get all admins (users with admin role or higher)
    # Uses efficient JOIN query to avoid N+1
    # @return [ActiveRecord::Relation<User>]
    def admins
      users.where(organizations_memberships: { role: %w[owner admin] }).distinct
    end

    # Alias for users (semantic convenience)
    alias members users

    # Check if organization has a specific user as member
    # @param user [User] The user to check
    # @return [Boolean]
    def has_member?(user)
      return false unless user

      memberships.exists?(user_id: user.id)
    end

    # Check if organization has any members
    # Uses efficient EXISTS query
    # @return [Boolean]
    def has_any_members?
      memberships.exists?
    end

    # Get member count from the organizations counter cache.
    # @return [Integer]
    def member_count
      memberships_count || 0
    end

    # Get pending invitations
    # @return [ActiveRecord::Relation<Invitation>]
    def pending_invitations
      invitations.pending
    end

    # === Member Management Methods ===

    # Add a user as member with specified role
    # Handles race conditions with unique constraint
    # @param user [User] The user to add
    # @param role [Symbol] The role (default: :member)
    # @return [Membership] The created or existing membership
    # @raise [ArgumentError] if role is invalid
    # @raise [CannotHaveMultipleOwners] if role is :owner (use transfer_ownership_to!)
    def add_member!(user, role: :member)
      role_sym = role.to_sym
      validate_role!(role_sym)

      # Owner role is only assignable via transfer_ownership_to! or initial creation
      if role_sym == :owner
        raise CannotHaveMultipleOwners, Organizations.t(:"errors.cannot_add_as_owner")
      end

      # Check if already a member (idempotent operation)
      existing = memberships.find_by(user_id: user.id)
      return existing if existing

      membership = nil
      ActiveRecord::Base.transaction do
        # THE MEMBERSHIP GATE (strict, vetoing, pre-persist): the one place a
        # host can abort ANY membership creation — seat limits, member caps.
        # Raising here rolls back cleanly (nothing persisted yet). Runs after
        # the idempotency check on purpose: an existing member isn't joining.
        Callbacks.dispatch(
          :member_joining,
          strict: true,
          organization: self,
          user: user,
          role: role_sym.to_s,
          joined_via: "manual"
        )

        membership = memberships.create!(
          user: user,
          role: role_sym.to_s
        )
      end

      Callbacks.dispatch(
        :member_joined,
        organization: self,
        membership: membership,
        user: user
      )

      membership
    rescue ActiveRecord::RecordNotUnique
      # Race condition: membership was created by another process
      memberships.find_by!(user_id: user.id)
    end

    # Remove a user from the organization
    # @param user [User] The user to remove
    # @param removed_by [User, nil] Who is removing them (for callbacks)
    # @raise [CannotRemoveOwner] if trying to remove the owner
    def remove_member!(user, removed_by: nil)
      membership = memberships.find_by(user_id: user.id)
      return unless membership

      if membership.role.to_sym == :owner
        raise CannotRemoveOwner, Organizations.t(:"errors.cannot_remove_owner")
      end

      ActiveRecord::Base.transaction do
        # Lock organization to prevent race conditions
        lock!
        membership.destroy!
      end

      Callbacks.dispatch(
        :member_removed,
        organization: self,
        membership: membership,
        user: user,
        removed_by: removed_by
      )
    end

    # Change a user's role in the organization
    # @param user [User] The user whose role to change
    # @param to [Symbol] The new role
    # @param changed_by [User, nil] Who is making the change (for callbacks)
    # @return [Membership] The updated membership
    # @raise [CannotHaveMultipleOwners] if promoting to owner when one exists
    # @raise [CannotRemoveLastOwner] if demoting the only owner
    def change_role_of!(user, to:, changed_by: nil)
      new_role = to.to_sym
      validate_role!(new_role)

      membership = memberships.find_by!(user_id: user.id)
      old_role = membership.role.to_sym

      return membership if old_role == new_role

      ActiveRecord::Base.transaction do
        # Lock organization to prevent race conditions
        lock!

        # Lock membership row to prevent concurrent changes
        membership.lock!

        # Enforce exactly-one-owner invariant
        if new_role == :owner && old_role != :owner
          # Promoting to owner - this is only allowed via transfer_ownership_to!
          # Direct role change to owner is not permitted
          raise CannotHaveMultipleOwners, Organizations.t(:"errors.cannot_promote_to_owner")
        end

        if old_role == :owner && new_role != :owner
          # Demoting owner - not allowed directly
          raise CannotDemoteOwner, Organizations.t(:"errors.cannot_demote_owner_directly")
        end

        membership.update!(role: new_role.to_s)
      end

      Callbacks.dispatch(
        :role_changed,
        organization: self,
        membership: membership,
        old_role: old_role,
        new_role: new_role,
        changed_by: changed_by
      )

      membership
    end

    # Transfer ownership to another user
    # The new owner must be an admin of the organization
    # Old owner becomes admin
    # @param new_owner [User] The user to become owner
    # @raise [CannotTransferToNonMember] if user is not a member
    # @raise [CannotTransferToNonAdmin] if user is not an admin
    def transfer_ownership_to!(new_owner)
      ActiveRecord::Base.transaction do
        # Lock organization first to prevent concurrent operations
        lock!

        # Always perform a fresh read in this write path, even if memberships
        # are preloaded on this instance, to avoid stale-owner selection.
        old_owner_membership = memberships.find_by(role: "owner")
        new_owner_membership = memberships.find_by(user_id: new_owner.id)

        unless old_owner_membership
          raise NoOwnerPresent, Organizations.t(:"errors.transfer_no_owner")
        end

        unless new_owner_membership
          raise CannotTransferToNonMember, Organizations.t(:"errors.transfer_to_non_member")
        end

        # New owner must be at least an admin (per README: "Ownership can be transferred to any admin")
        unless Roles.at_least?(new_owner_membership.role.to_sym, :admin)
          raise CannotTransferToNonAdmin, Organizations.t(:"errors.transfer_to_non_admin")
        end

        # No-op transfer to the current owner.
        return old_owner_membership if old_owner_membership.user_id == new_owner.id

        # Lock both memberships
        old_owner_membership.lock!
        new_owner_membership.lock!

        old_owner_user = old_owner_membership.user

        # Demote old owner to admin
        old_owner_membership.update!(role: "admin")

        # Promote new owner
        new_owner_membership.update!(role: "owner")

        Callbacks.dispatch(
          :ownership_transferred,
          organization: self,
          old_owner: old_owner_user,
          new_owner: new_owner
        )
      end
    end

    # === Invitation Methods ===

    # Send an invitation to join this organization
    # @param email [String] Email address to invite
    # @param invited_by [User, nil] Who is sending the invitation (uses Current.user if not provided)
    # @param role [Symbol] Role for the invitation (default: from config)
    # @return [Invitation] The created or existing invitation
    # @raise [CannotInviteAsOwner] if role is :owner
    def send_invite_to!(email, invited_by: nil, role: nil)
      inviter = invited_by || current_user_from_context
      unless inviter
        raise ArgumentError, "invited_by is required (or set Current.user)"
      end

      authorize_inviter!(inviter)

      role ||= Organizations.configuration.default_invitation_role
      role_sym = role.to_sym

      # Owner role cannot be assigned via invitation - only via transfer_ownership_to!
      if role_sym == :owner
        raise CannotInviteAsOwner, Organizations.t(:"errors.invite_as_owner")
      end

      normalized_email = email.downcase.strip

      # Check for existing pending invitation (idempotent)
      existing = invitations.pending.for_email(normalized_email).first
      return existing if existing

      # Check if already a member (case-insensitive)
      if users.where("LOWER(email) = ?", normalized_email).exists?
        raise Organizations::InvitationError, Organizations.t(:"errors.invitation_already_member")
      end

      # Allow callback hooks to veto invitations (e.g., plan seat limits) before write.
      invitation_context = invitations.build(
        email: normalized_email,
        invited_by: inviter,
        role: role.to_s,
        expires_at: calculate_expiry
      )

      Callbacks.dispatch(
        :member_invited,
        strict: true,
        organization: self,
        invitation: invitation_context,
        invited_by: inviter
      )

      invitation = nil
      ActiveRecord::Base.transaction do
        # Check for expired invitation and refresh it instead of creating duplicate
        expired_invitation = invitations.expired.for_email(normalized_email).first
        if expired_invitation
          expired_invitation.lock!
          expired_invitation.update!(
            invited_by: inviter,
            role: role.to_s,
            token: generate_unique_token,
            expires_at: calculate_expiry
          )
          invitation = expired_invitation
        else
          invitation = invitations.create!(
            email: normalized_email,
            invited_by: inviter,
            role: role.to_s,
            token: generate_unique_token,
            expires_at: calculate_expiry
          )
        end
      end

      # Send invitation email
      send_invitation_email(invitation)

      invitation
    rescue ActiveRecord::RecordNotUnique
      # Race condition: invitation was created by another process
      invitations.pending.for_email(normalized_email).first!
    end

    # === Verified Joining Methods (v0.5.0) ===

    # Enroll an email domain for domain-verified joining.
    # @param domain [String] e.g. "inizio.com" (exact match — subdomains must be enrolled separately)
    # @param membership_metadata [Hash] copied onto memberships created through this domain
    # @return [Domain]
    def add_domain!(domain, membership_metadata: {})
      domains.create!(domain: domain, membership_metadata: membership_metadata)
    end

    # Generate a shareable join code (PIN).
    # @param label [String, nil] campaign attribution ("cafeteria poster")
    # @param requires_verified_domain_email [Boolean] chain the emailed-code challenge ("reinforced" level)
    # @param auto_approve [Boolean] false parks redemptions as pending requests for manual approval
    # @param expires_at [Time, nil]
    # @param max_uses [Integer, nil]
    # @param created_by [User, nil]
    # @param membership_metadata [Hash] copied onto memberships created through this code
    # @return [JoinCode]
    # Every parameter is an optional keyword with a safe default — this IS
    # the public API surface, not incidental complexity.
    # rubocop:disable Metrics/ParameterLists
    def generate_join_code!(label: nil, requires_verified_domain_email: false, auto_approve: true,
                            expires_at: nil, max_uses: nil, created_by: nil, membership_metadata: {})
      join_codes.create!(
        label: label,
        requires_verified_domain_email: requires_verified_domain_email,
        auto_approve: auto_approve,
        expires_at: expires_at,
        max_uses: max_uses,
        created_by_id: created_by&.id,
        membership_metadata: membership_metadata
      )
    end
    # rubocop:enable Metrics/ParameterLists

    # Bulk-import roster emails as allowlist entries (idempotent per address:
    # already-enrolled addresses are skipped, not duplicated).
    # @param emails [Enumerable<String>]
    # @param source [String, nil] provenance tag ("csv_2026-07")
    # @param membership_metadata [Hash] copied onto memberships created through these entries
    # @return [Array<AllowlistEntry>] the newly created entries
    def import_allowlist!(emails, source: nil, membership_metadata: {})
      Array(emails).filter_map do |email|
        entry = allowlist_entries.create!(
          email: email,
          source: source,
          membership_metadata: membership_metadata
        )
        entry
      rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
        # Skip duplicates silently (idempotent import); re-raise anything else.
        raise e unless duplicate_allowlist_error?(e)

        nil
      end
    end

    # Open join requests awaiting a decision
    # @return [ActiveRecord::Relation<JoinRequest>]
    def pending_join_requests
      join_requests.pending
    end

    # Whether this organization accepts EMAIL-PROOF joining: an enrolled
    # domain or an unclaimed roster entry (both run the same emailed-code
    # challenge). Drives whether a join screen shows the email form.
    # @return [Boolean]
    def accepts_domain_joining?
      domains.exists? || allowlist_entries.unclaimed.exists?
    end

    # Whether this organization has at least one code that can actually be
    # redeemed right now (not revoked/expired/exhausted). Drives whether a
    # join screen shows the code form.
    # @return [Boolean]
    def accepts_code_joining?
      join_codes.active.exists?
    end

    # Whether this organization exposes any self-serve joining mechanism.
    # NOTE (0.5.0 refinement): codes now count only while actually
    # redeemable — an org whose every code expired or ran out no longer
    # reads as joinable.
    # @return [Boolean]
    def accepts_join_requests?
      accepts_domain_joining? || accepts_code_joining?
    end

    # Approve a join request (creates the membership). See JoinRequest#approve!.
    # @param join_request [JoinRequest]
    # @param approved_by [User, nil]
    # @return [Membership]
    def approve_join_request!(join_request, approved_by: nil)
      ensure_join_request_belongs_here!(join_request)
      join_request.approve!(decided_by: approved_by)
    end

    # Reject a join request. See JoinRequest#reject!.
    # @param join_request [JoinRequest]
    # @param rejected_by [User, nil]
    # @param reason [String, nil]
    # @return [JoinRequest]
    def reject_join_request!(join_request, rejected_by: nil, reason: nil)
      ensure_join_request_belongs_here!(join_request)
      join_request.reject!(rejected_by: rejected_by, reason: reason)
    end

    # Zero-friction domain join for hosts with confirmed account emails
    # (e.g. Devise :confirmable): if the user's own account email is confirmed
    # and its domain is enrolled, the inbox was already proven at signup — no
    # emailed code needed.
    #
    # @param user [User] must respond to #email; #confirmed_at gates trust
    # @return [Membership]
    # @raise [VerificationEmailNotEligible] when the account email's domain isn't enrolled,
    #   the email is unconfirmed, or the feature is disabled
    def join_with_account_email!(user)
      unless Organizations.configuration.trust_confirmed_account_email
        raise VerificationEmailNotEligible, Organizations.t(:"errors.account_email_trust_disabled")
      end

      email = user.respond_to?(:email) ? user.email.to_s : ""
      confirmed = user.respond_to?(:confirmed_at) && user.confirmed_at.present?

      unless confirmed
        raise VerificationEmailNotEligible, Organizations.t(:"errors.account_email_unconfirmed")
      end

      matched_domain = domains.matching_email(email).first
      unless matched_domain
        raise VerificationEmailNotEligible, Organizations.t(:"errors.verification_email_not_eligible")
      end

      # Uniform funnel: every self-serve join goes through a JoinRequest so
      # provenance and audit trail come for free.
      request = join_requests.pending.find_by(user_id: user.id) || join_requests.new(user: user)
      normalized = Organizations.configuration.normalize_verification_email(email)

      ActiveRecord::Base.transaction do
        if Membership.where(organization_id: id, verified_email_normalized: normalized).exists?
          raise VerificationEmailAlreadyClaimed,
                Organizations.t(:"errors.verification_email_already_claimed")
        end

        request.assign_attributes(
          joined_via: "domain_email",
          verification_email: email,
          verification_email_normalized: normalized,
          verified_at: Time.current,
          metadata: (request.metadata || {}).merge("matched_domain_id" => matched_domain.id)
        )
        request.save!
      end

      request.approve!(decided_by: nil)
    end

    private

    def ensure_join_request_belongs_here!(join_request)
      return if join_request.organization_id == id

      raise ArgumentError, "Join request does not belong to this organization"
    end

    def duplicate_allowlist_error?(error)
      return true if error.is_a?(ActiveRecord::RecordNotUnique)

      error.is_a?(ActiveRecord::RecordInvalid) &&
        error.record.is_a?(Organizations::AllowlistEntry) &&
        error.record.errors.of_kind?(:email_normalized, :taken)
    end

    # Defense in depth for organization-centric API usage.
    # The user-level API already checks this, but direct calls to `org.send_invite_to!`
    # must enforce membership and invite permission as well.
    def authorize_inviter!(inviter)
      inviter_membership = memberships.find_by(user_id: inviter.id)

      unless inviter_membership
        raise Organizations::NotAMember.new(
          Organizations.t(:"errors.invite_not_a_member"),
          organization: self,
          user: inviter
        )
      end

      return if Roles.has_permission?(inviter_membership.role.to_sym, :invite_members)

      raise Organizations::NotAuthorized.new(
        Organizations.t(:"errors.invite_not_authorized"),
        permission: :invite_members,
        organization: self,
        user: inviter
      )
    end

    def validate_role!(role)
      unless Roles.valid_role?(role)
        raise ArgumentError, "Invalid role: #{role}. Must be one of: #{Roles.valid_roles.join(', ')}"
      end
    end

    def generate_unique_token
      loop do
        token = SecureRandom.urlsafe_base64(32)
        break token unless Invitation.exists?(token: token)
      end
    end

    def calculate_expiry
      expiry = Organizations.configuration.invitation_expiry
      return nil unless expiry

      Time.current + expiry
    end

    def send_invitation_email(invitation)
      mailer_class = Organizations.configuration.invitation_mailer.constantize
      mailer_class.invitation_email(invitation).deliver_later
    rescue StandardError => e
      # Log but don't fail - invitation is created, email can be resent
      Callbacks.log_error("[Organizations] Failed to send invitation email: #{e.message}")
    end

    def current_user_from_context
      # Try to get Current.user if available (Rails 5.2+)
      if defined?(Current) && Current.respond_to?(:user)
        Current.user
      end
    end
  end
end
