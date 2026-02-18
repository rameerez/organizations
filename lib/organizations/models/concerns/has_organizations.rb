# frozen_string_literal: true

require "active_support/concern"

module Organizations
  module Models
    module Concerns
      # Concern to add organization capabilities to a user model.
      # This module provides the `has_organizations` class method when extended onto ActiveRecord::Base.
      #
      # @example Basic usage
      #   class User < ApplicationRecord
      #     has_organizations
      #   end
      #
      # @example With options
      #   class User < ApplicationRecord
      #     has_organizations max_organizations: 5, create_personal_org: false
      #   end
      #
      # @example With block DSL
      #   class User < ApplicationRecord
      #     has_organizations do
      #       max_organizations 5
      #       create_personal_org false
      #       require_organization true
      #     end
      #   end
      #
      module HasOrganizations
        extend ActiveSupport::Concern

        # Module containing class methods to be extended onto ActiveRecord::Base
        module ClassMethods
          def has_organizations(**options, &block)
            # Include instance methods
            include Organizations::Models::Concerns::HasOrganizations unless included_modules.include?(Organizations::Models::Concerns::HasOrganizations)

            # Define associations
            has_many :memberships,
                     class_name: "Organizations::Membership",
                     dependent: :destroy

            has_many :organizations,
                     through: :memberships,
                     class_name: "Organizations::Organization"

            has_many :owned_organizations,
                     -> { joins(:memberships).where(memberships: { role: "owner" }) },
                     through: :memberships,
                     source: :organization,
                     class_name: "Organizations::Organization"

            has_many :sent_organization_invitations,
                     class_name: "Organizations::Invitation",
                     foreign_key: :invited_by_id,
                     dependent: :nullify

            # Define class_attribute for settings
            unless respond_to?(:organization_settings)
              class_attribute :organization_settings, instance_writer: false, default: {}
            end

            # Initialize settings with defaults from configuration
            current_settings = {
              max_organizations: nil,
              create_personal_org: Organizations.configuration&.create_personal_organization,
              require_organization: Organizations.configuration&.require_organization
            }.merge(options)

            # Apply DSL block if provided
            if block_given?
              dsl = DslProvider.new(current_settings)
              dsl.instance_eval(&block)
            end

            # Store final settings
            self.organization_settings = current_settings
          end
        end

        # DSL provider for block configuration
        class DslProvider
          def initialize(settings)
            @settings = settings
          end

          def max_organizations(value)
            @settings[:max_organizations] = value
          end

          def create_personal_org(value)
            @settings[:create_personal_org] = value
          end

          def require_organization(value)
            @settings[:require_organization] = value
          end
        end

        # --- Instance Methods ---
        # Methods included in the user model.

        # Current organization context (session-based, set by controller)
        attr_accessor :current_organization_id

        # Returns the current organization for this session
        # @return [Organizations::Organization, nil]
        def current_organization
          return @current_organization if defined?(@current_organization)
          return nil unless current_organization_id

          @current_organization = organizations.find_by(id: current_organization_id)
        end

        # Alias for current_organization (convenience)
        alias_method :organization, :current_organization

        # Returns the membership in the current organization
        # @return [Organizations::Membership, nil]
        def current_membership
          return nil unless current_organization

          memberships.find_by(organization: current_organization)
        end

        # Returns the role in the current organization
        # @return [Symbol, nil]
        def current_organization_role
          current_membership&.role&.to_sym
        end

        # Check if user belongs to any organization
        # @return [Boolean]
        def belongs_to_any_organization?
          organizations.exists?
        end

        # Check if user has pending invitations
        # @return [Boolean]
        def has_pending_organization_invitations?
          Organizations::Invitation.pending.where(email: email).exists?
        end

        # Get pending invitations for this user
        # @return [ActiveRecord::Relation]
        def pending_organization_invitations
          Organizations::Invitation.pending.where(email: email)
        end

        # --- Role Checks (current organization) ---

        def is_organization_owner?
          current_organization_role == :owner
        end

        def is_organization_admin?
          %i[owner admin].include?(current_organization_role)
        end

        def is_organization_member?
          %i[owner admin member].include?(current_organization_role)
        end

        def is_organization_viewer?
          current_organization_role.present?
        end

        def has_organization_role?(role)
          Organizations::Roles.at_least?(current_organization_role, role)
        end

        # --- Role Checks (specific organization) ---

        def role_in(org)
          memberships.find_by(organization: org)&.role&.to_sym
        end

        def is_owner_of?(org)
          role_in(org) == :owner
        end

        def is_admin_of?(org)
          %i[owner admin].include?(role_in(org))
        end

        def is_member_of?(org)
          memberships.exists?(organization: org)
        end

        def is_viewer_of?(org)
          role_in(org).present?
        end

        def is_at_least?(role, in: nil)
          org = binding.local_variable_get(:in)
          user_role = org ? role_in(org) : current_organization_role
          return false unless user_role

          Organizations::Roles.at_least?(user_role, role)
        end

        # --- Permission Checks ---

        def has_organization_permission_to?(permission)
          return false unless current_organization_role

          Organizations::Roles.has_permission?(current_organization_role, permission)
        end

        # --- Actions ---

        # Creates a new organization with this user as owner
        # @param name [String] Organization name
        # @return [Organizations::Organization]
        def create_organization!(name_or_options)
          name = name_or_options.is_a?(Hash) ? name_or_options[:name] : name_or_options

          # Check max organizations limit
          settings = self.class.organization_settings
          max = settings[:max_organizations]
          if max && owned_organizations.count >= max
            raise Organizations::Error, "Maximum number of organizations (#{max}) reached"
          end

          org = nil
          ActiveRecord::Base.transaction do
            org = Organizations::Organization.create!(name: name)

            Organizations::Membership.create!(
              user: self,
              organization: org,
              role: :owner
            )
          end

          Organizations::Callbacks.dispatch(:organization_created, organization: org, user: self)

          org
        end

        # Leave an organization
        # @param org [Organizations::Organization]
        def leave_organization!(org)
          membership = memberships.find_by!(organization: org)

          # Check if this is the only owner
          if membership.role.to_sym == :owner && org.memberships.where(role: :owner).count == 1
            raise Organizations::Error, "Cannot leave organization as the only owner"
          end

          # Check require_organization setting
          settings = self.class.organization_settings
          if settings[:require_organization] && organizations.count == 1
            raise Organizations::Error, "Cannot leave your only organization"
          end

          membership.destroy!

          Organizations::Callbacks.dispatch(:member_removed, organization: org, user: self, membership: membership)
        end

        # Leave current organization
        def leave_current_organization!
          raise Organizations::Error, "No current organization" unless current_organization

          leave_organization!(current_organization)
        end

        # Send invitation to join organization
        # @param email [String]
        # @param organization [Organizations::Organization] (optional, defaults to current)
        # @param role [Symbol] (optional, defaults to configured default)
        # @return [Organizations::Invitation]
        def send_organization_invite_to!(email, organization: nil, role: nil)
          org = organization || current_organization
          raise Organizations::Error, "No organization specified" unless org

          role ||= Organizations.configuration.default_invitation_role

          # Check permission
          unless is_admin_of?(org)
            raise Organizations::NotAuthorized.new(
              "You don't have permission to invite members",
              permission: :invite_members,
              organization: org,
              user: self
            )
          end

          invitation = Organizations::Invitation.create!(
            organization: org,
            invited_by: self,
            email: email,
            role: role,
            token: SecureRandom.urlsafe_base64(32),
            expires_at: Organizations.configuration.invitation_expiry.from_now
          )

          # TODO: Send invitation email via configured mailer

          invitation
        end

        private

        def within_organization_quota?
          settings = self.class.organization_settings
          limit = settings[:max_organizations]
          return true unless limit

          owned_organizations.count < limit
        end
      end
    end
  end
end
