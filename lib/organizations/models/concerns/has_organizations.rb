# frozen_string_literal: true

require "active_support/concern"

module Organizations
  module Models
    module Concerns
      module HasOrganizations
        extend ActiveSupport::Concern

        module ClassMethods
          # Main DSL entry point for User model
          #
          # Example:
          #   class User < ApplicationRecord
          #     has_organizations
          #   end
          #
          #   class User < ApplicationRecord
          #     has_organizations do
          #       max_organizations 5
          #       create_personal_org true
          #       require_organization false
          #     end
          #   end
          def has_organizations(**options, &block)
            include Organizations::Models::Concerns::HasOrganizations unless included_modules.include?(Organizations::Models::Concerns::HasOrganizations)

            # Define associations
            has_many :memberships, class_name: "Organizations::Membership", dependent: :destroy
            has_many :organizations, through: :memberships, class_name: "Organizations::Organization"
            has_many :pending_organization_invitations,
                     ->(user) { pending.where(email: user.email) },
                     class_name: "Organizations::Invitation",
                     foreign_key: false,
                     primary_key: false

            # Store settings
            unless respond_to?(:organization_settings)
              class_attribute :organization_settings, instance_writer: false, default: {}
            end

            # TODO: Implement DSL block handling
            # TODO: Implement settings merge
          end
        end

        # Instance methods added to User

        # TODO: Implement instance methods:
        # - current_organization
        # - current_organization=
        # - current_membership
        # - organization (alias for current_organization)
        # - owned_organizations
        # - create_organization!(name)
        # - leave_organization!(org)
        # - send_organization_invite_to!(email, organization:, role:)
        # - is_organization_owner?
        # - is_organization_admin?
        # - is_organization_member?
        # - is_organization_viewer?
        # - is_owner_of?(org)
        # - is_admin_of?(org)
        # - is_member_of?(org)
        # - is_viewer_of?(org)
        # - is_at_least?(role, in: org)
        # - role_in(org)
        # - has_organization_role?(role)
        # - has_organization_permission_to?(permission)
        # - belongs_to_any_organization?
        # - has_pending_organization_invitations?
      end
    end
  end
end
