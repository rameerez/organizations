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

    belongs_to :user
    belongs_to :organization,
               class_name: "Organizations::Organization",
               inverse_of: :memberships

    belongs_to :invited_by,
               class_name: "User",
               optional: true

    # === Validations ===

    validates :role, presence: true, inclusion: { in: ->(_) { Roles::HIERARCHY.map(&:to_s) } }
    validates :user_id, uniqueness: { scope: :organization_id, message: "is already a member of this organization" }
    validate :single_owner_per_organization, if: :owner?

    # Keep memberships_count accurate when the optional counter cache column exists.
    after_create_commit :increment_memberships_counter_cache
    after_destroy_commit :decrement_memberships_counter_cache
    after_update_commit :sync_memberships_counter_cache_for_org_change, if: :saved_change_to_organization_id?

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
        raise CannotPromoteToOwner, "Cannot promote to owner. Use organization.transfer_ownership_to! instead."
      end

      unless Roles.at_least?(new_role_sym, role_sym)
        raise InvalidRoleChange, "Cannot promote to #{new_role} - it's not a higher role than #{role}"
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
        raise CannotDemoteOwner, "Cannot demote owner. Transfer ownership first."
      end

      unless Roles.at_least?(role_sym, new_role_sym)
        raise InvalidRoleChange, "Cannot demote to #{new_role} - it's not a lower role than #{role}"
      end

      change_role_to!(new_role_sym, changed_by: changed_by)
    end

    private

    def single_owner_per_organization
      return unless organization_id

      existing_owner = self.class.where(organization_id: organization_id, role: "owner")
      existing_owner = existing_owner.where.not(id: id) if persisted?

      return unless existing_owner.exists?

      errors.add(:role, "owner already exists for this organization")
    end

    def increment_memberships_counter_cache
      return unless memberships_counter_cache_enabled?
      return unless organization_id

      Organizations::Organization.increment_counter(:memberships_count, organization_id)
    end

    def decrement_memberships_counter_cache
      return unless memberships_counter_cache_enabled?
      return unless organization_id

      Organizations::Organization.decrement_counter(:memberships_count, organization_id)
    end

    def sync_memberships_counter_cache_for_org_change
      return unless memberships_counter_cache_enabled?

      old_org_id, new_org_id = saved_change_to_organization_id
      Organizations::Organization.decrement_counter(:memberships_count, old_org_id) if old_org_id
      Organizations::Organization.increment_counter(:memberships_count, new_org_id) if new_org_id
    end

    def memberships_counter_cache_enabled?
      Organizations::Organization.column_names.include?("memberships_count")
    rescue StandardError
      false
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
