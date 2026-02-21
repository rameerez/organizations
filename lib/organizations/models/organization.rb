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

    # Get member count (uses counter cache if available, otherwise COUNT)
    # @return [Integer]
    def member_count
      if has_attribute?(:memberships_count)
        self[:memberships_count] || memberships.count
      else
        memberships.count
      end
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
        raise CannotHaveMultipleOwners, "Cannot add member as owner. Use transfer_ownership_to! instead."
      end

      # Check if already a member (idempotent operation)
      existing = memberships.find_by(user_id: user.id)
      return existing if existing

      membership = nil
      ActiveRecord::Base.transaction do
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
        raise CannotRemoveOwner, "Cannot remove the organization owner. Transfer ownership first."
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
          raise CannotHaveMultipleOwners, "Cannot promote to owner. Use transfer_ownership_to! instead."
        end

        if old_role == :owner && new_role != :owner
          # Demoting owner - not allowed directly
          raise CannotDemoteOwner, "Cannot demote owner directly. Use transfer_ownership_to! instead."
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
          raise NoOwnerPresent, "Cannot transfer ownership because organization has no owner membership"
        end

        unless new_owner_membership
          raise CannotTransferToNonMember, "Cannot transfer ownership to a non-member"
        end

        # New owner must be at least an admin (per README: "Ownership can be transferred to any admin")
        unless Roles.at_least?(new_owner_membership.role.to_sym, :admin)
          raise CannotTransferToNonAdmin, "Cannot transfer ownership to non-admin. Promote them to admin first."
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
        raise CannotInviteAsOwner, "Cannot invite as owner. Invite as admin, then use transfer_ownership_to! after they join."
      end

      normalized_email = email.downcase.strip

      # Check for existing pending invitation (idempotent)
      existing = invitations.pending.for_email(normalized_email).first
      return existing if existing

      # Check if already a member (case-insensitive)
      if users.where("LOWER(email) = ?", normalized_email).exists?
        raise Organizations::InvitationError, "User is already a member of this organization"
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

    private

    # Defense in depth for organization-centric API usage.
    # The user-level API already checks this, but direct calls to `org.send_invite_to!`
    # must enforce membership and invite permission as well.
    def authorize_inviter!(inviter)
      inviter_membership = memberships.find_by(user_id: inviter.id)

      unless inviter_membership
        raise Organizations::NotAMember.new(
          "Only organization members can send invitations",
          organization: self,
          user: inviter
        )
      end

      return if Roles.has_permission?(inviter_membership.role.to_sym, :invite_members)

      raise Organizations::NotAuthorized.new(
        "You don't have permission to invite members",
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
