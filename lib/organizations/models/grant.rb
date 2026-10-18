# frozen_string_literal: true

module Organizations
  # Access to one resource of the host app, with a list of capabilities. A
  # grant belongs to a membership, or to an invitation until it is accepted.
  #
  # Grants narrow a membership: a member whose role ranks below
  # config.full_resource_access_role sees only the resources granted to it,
  # and on each one only the granted capabilities that its role also has.
  # See Organizations::GrantHolder and Membership#can?.
  #
  # The resource is polymorphic (grantable_type, grantable_id). It can be
  # an ActiveRecord record (`grant.grantable` loads it) or any object with an
  # id, such as an Organizations::Resource (then only the type and id are
  # stored, and `grantable` is not used).
  class Grant < ActiveRecord::Base
    self.table_name = "organizations_grants"

    # === Associations ===

    belongs_to :membership, class_name: "Organizations::Membership", inverse_of: :grants, optional: true
    belongs_to :invitation, class_name: "Organizations::Invitation", inverse_of: :grants, optional: true
    belongs_to :grantable, polymorphic: true, optional: true
    belongs_to :granted_by, class_name: Organizations.user_class_name, optional: true

    # === Validations ===

    validates :grantable_type, :grantable_id, presence: true
    validate :one_holder
    validate :capabilities_listed

    # === Callbacks ===

    before_validation :normalize_capabilities

    # === Scopes ===

    # Grants on one resource (a record, any object with an id, or a Resource)
    scope :for_resource, lambda { |resource|
      type, id = Grant.resource_key(resource)
      where(grantable_type: type, grantable_id: id)
    }

    # Grants on resources of one type (a class or a type name)
    scope :of_type, ->(type) { where(grantable_type: Grant.type_name(type)) }

    # Grants held by memberships (accepted), not by pending invitations
    scope :active, -> { where.not(membership_id: nil) }

    # [type, id] for a resource. The id must fit the grantable_id column
    # without loss ("42-a" never becomes 42).
    # @param resource [ActiveRecord::Base, Organizations::Resource, #id]
    # @return [Array(String, Object)]
    # @raise [ArgumentError] for an object without an id, or an id that does not fit
    def self.resource_key(resource)
      type, id =
        case resource
        when Organizations::Resource then [resource.type.to_s, resource.id]
        when ActiveRecord::Base then [resource.class.polymorphic_name, resource.id]
        else
          raise ArgumentError, "A grant needs a resource with an id, got #{resource.inspect}" unless resource.respond_to?(:id)

          [resource.class.name, resource.id]
        end
      [type, lossless_id(id)]
    end

    # @api private
    # The id as the grantable_id column stores it, or ArgumentError when the
    # column would change it.
    def self.lossless_id(id)
      cast = type_for_attribute("grantable_id").cast(id)
      return cast if cast.to_s == id.to_s

      raise ArgumentError, "The id #{id.inspect} does not fit the grantable_id column (#{columns_hash['grantable_id']&.type})"
    end

    # @api private
    # The organization a resource belongs to, or nil when it does not say:
    # an object with organization_id, or an Organizations::Resource naming
    # an ActiveRecord model with an organization_id column (one query).
    def self.resource_organization_id(resource)
      if resource.is_a?(Organizations::Resource)
        model = resource.type.to_s.safe_constantize
        return nil unless tenant_model?(model)

        model.where(model.primary_key => resource.id).pick(:organization_id)
      elsif resource.respond_to?(:organization_id)
        resource.organization_id.presence
      end
    end

    # The stored type name for a class or a name.
    # @return [String]
    def self.type_name(type)
      type.respond_to?(:polymorphic_name) ? type.polymorphic_name : type.to_s
    end

    # @api private
    def self.tenant_model?(model)
      model.is_a?(Class) && model < ActiveRecord::Base && model.column_names.include?("organization_id")
    end

    # @return [Array<String>]
    def capabilities
      Array(super).map(&:to_s)
    end

    # @param capability [Symbol, String]
    # @return [Boolean] whether this grant lists the capability
    def allows?(capability)
      capabilities.include?(capability.to_s)
    end

    # The resource as an Organizations::Resource (no loading).
    # @return [Organizations::Resource]
    def resource
      Organizations::Resource.new(grantable_type, grantable_id)
    end

    private

    def normalize_capabilities
      self.capabilities = Array(read_attribute(:capabilities)).map { |c| c.to_s.strip }.compact_blank.uniq
    end

    def one_holder
      return if membership_id.present? ^ invitation_id.present?

      errors.add(:base, Organizations.t(:"attributes.grant_one_holder"))
    end

    def capabilities_listed
      if capabilities.empty?
        errors.add(:capabilities, Organizations.t(:"attributes.grant_capabilities_blank"))
        return
      end

      allowed = Organizations.configuration.grant_capabilities
      return if allowed.nil?

      unknown = capabilities - allowed.map(&:to_s)
      return if unknown.empty?

      errors.add(:capabilities,
                 Organizations.t(:"attributes.grant_capabilities_unknown", capabilities: unknown.join(", ")))
    end
  end
end

# Host extension seam — see the load-hooks note in models/organization.rb.
ActiveSupport.run_load_hooks(:organizations_grant, Organizations::Grant)
