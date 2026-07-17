# frozen_string_literal: true

module Organizations
  # Membership model representing a user's membership in an organization.
  # Each membership has a role that determines permissions.
  #
  # The role hierarchy is: owner > admin > member > viewer
  # Each role inherits permissions from lower roles.
  #
  # @example Checking permissions
  #   membership.has_permission_to?(:invite_members) # => true/false
  #   membership.is_at_least?(:admin) # => true/false
  #
  # @example Changing roles
  #   membership.promote_to!(:admin)
  #   membership.demote_to!(:member)
  #
  class Membership < ActiveRecord::Base
    self.table_name = "organizations_memberships"

    # Error raised when trying to demote below current role
    class CannotDemoteOwner < Organizations::Error; end
    class CannotPromoteToOwner < Organizations::Error; end
    class InvalidRoleChange < Organizations::Error; end

    # === Associations ===

    # Explicit class_name (NOT inferred from the association name) so hosts
    # with a differently-named account model work: config.user_class.
    belongs_to :user, class_name: Organizations.user_class_name
    belongs_to :organization,
               class_name: "Organizations::Organization",
               inverse_of: :memberships,
               counter_cache: :memberships_count

    belongs_to :invited_by,
               class_name: Organizations.user_class_name,
               optional: true

    # === Validations ===

    validates :role, presence: true, inclusion: { in: ->(_) { Roles::HIERARCHY.map(&:to_s) } }
    # Proc message: resolved at VALIDATION time so it follows I18n.locale —
    # a literal string here would be frozen in whatever locale loaded first.
    validates :user_id, uniqueness: { scope: :organization_id,
                                      message: ->(*) { Organizations.t(:"attributes.membership_taken") } }
    validate :single_owner_per_organization, if: :owner?

    # === Scopes ===

    # Memberships with owner role
    scope :owners, -> { where(role: "owner") }

    # Memberships with admin role (not including owner)
    scope :admins, -> { where(role: "admin") }

    # Memberships with admin role or higher (includes owner)
    scope :admins_and_above, -> { where(role: %w[owner admin]) }

    # Memberships with member role
    scope :members, -> { where(role: "member") }

    # Memberships with viewer role
    scope :viewers, -> { where(role: "viewer") }

    # Order by role hierarchy (owners first)
    scope :by_role_hierarchy, -> {
      order(Arel.sql(<<~SQL.squish))
        CASE role
          WHEN 'owner' THEN 0
          WHEN 'admin' THEN 1
          WHEN 'member' THEN 2
          WHEN 'viewer' THEN 3
          ELSE 4
        END
      SQL
    }

    # === Verified Joining (v0.5.0) ===

    # Whether this membership was created with a proven email address
    # (emailed-code challenge, confirmed account email, or accepted invitation)
    # @return [Boolean]
    def verified?
      verified_at.present?
    end

    # === Role Methods ===

    # Get the role as a symbol
    # @return [Symbol]
    def role_sym
      role&.to_sym
    end

    # Check if this membership is for an owner
    # @return [Boolean]
    def owner?
      role_sym == :owner
    end

    # Check if this membership is for an admin (not owner)
    # @return [Boolean]
    def admin?
      role_sym == :admin
    end

    # Check if this membership is for a member
    # @return [Boolean]
    def member?
      role_sym == :member
    end

    # Check if this membership is for a viewer
    # @return [Boolean]
    def viewer?
      role_sym == :viewer
    end

    # === Permission Methods ===

    # Check if this membership has a specific permission
    # Uses pre-computed permission sets for O(1) lookup
    # @param permission [Symbol, String] The permission to check
    # @return [Boolean]
    def has_permission_to?(permission)
      Roles.has_permission?(role_sym, permission)
    end

    # Get all permissions for this membership
    # @return [Array<Symbol>]
    def permissions
      Roles.permissions_for(role_sym)
    end

    # Check if this membership's role is at least as high as the specified role
    # @param minimum_role [Symbol, String] The minimum required role
    # @return [Boolean]
    #
    # @example
    #   membership.is_at_least?(:admin) # => true if admin or owner
    #   membership.is_at_least?(:owner) # => true only if owner
    #
    def is_at_least?(minimum_role)
      Roles.at_least?(role_sym, minimum_role.to_sym)
    end

    # Compare roles with another membership
    # @param other [Membership] Another membership
    # @return [Integer] -1 if higher, 0 if equal, 1 if lower
    def compare_role(other)
      Roles.compare(role_sym, other.role_sym)
    end

    # === Role Change Methods ===

    # Promote to a higher role
    # @param new_role [Symbol, String] The new role
    # @param changed_by [User, nil] Who is making the change
    # @return [self]
    # @raise [InvalidRoleChange] if new role is not higher
    # @raise [CannotPromoteToOwner] if trying to promote to owner (use transfer_ownership_to!)
    def promote_to!(new_role, changed_by: nil)
      new_role_sym = new_role.to_sym
      validate_role!(new_role_sym)

      # Owner role is only assignable via transfer_ownership_to!
      if new_role_sym == :owner
        raise CannotPromoteToOwner, Organizations.t(:"errors.cannot_promote_to_owner")
      end

      unless Roles.at_least?(new_role_sym, role_sym)
        raise InvalidRoleChange, Organizations.t(:"errors.promote_not_higher", new_role: new_role, role: role)
      end

      change_role_to!(new_role_sym, changed_by: changed_by)
    end

    # Demote to a lower role
    # @param new_role [Symbol, String] The new role
    # @param changed_by [User, nil] Who is making the change
    # @return [self]
    # @raise [CannotDemoteOwner] if trying to demote owner
    # @raise [InvalidRoleChange] if new role is not lower
    def demote_to!(new_role, changed_by: nil)
      new_role_sym = new_role.to_sym
      validate_role!(new_role_sym)

      if owner?
        raise CannotDemoteOwner, Organizations.t(:"errors.cannot_demote_owner")
      end

      unless Roles.at_least?(role_sym, new_role_sym)
        raise InvalidRoleChange, Organizations.t(:"errors.demote_not_lower", new_role: new_role, role: role)
      end

      change_role_to!(new_role_sym, changed_by: changed_by)
    end

    private

    def single_owner_per_organization
      return unless organization_id

      existing_owner = self.class.where(organization_id: organization_id, role: "owner")
      existing_owner = existing_owner.where.not(id: id) if persisted?

      return unless existing_owner.exists?

      errors.add(:role, Organizations.t(:"attributes.owner_taken"))
    end

    def validate_role!(role)
      unless Roles.valid_role?(role)
        raise ArgumentError, "Invalid role: #{role}. Must be one of: #{Roles.valid_roles.join(', ')}"
      end
    end

    def change_role_to!(new_role, changed_by: nil)
      old_role = role_sym

      return self if old_role == new_role

      ActiveRecord::Base.transaction do
        # Lock row to prevent concurrent changes
        lock!
        update!(role: new_role.to_s)
      end

      Callbacks.dispatch(
        :role_changed,
        organization: organization,
        membership: self,
        old_role: old_role,
        new_role: new_role,
        changed_by: changed_by
      )

      self
    end
  end
end

# Host extension seam — see the load-hooks note in models/organization.rb.
ActiveSupport.run_load_hooks(:organizations_membership, Organizations::Membership)
