# frozen_string_literal: true

require "active_support/concern"

module Organizations
  module Models
    module Concerns
      # Concern to add organization capabilities to a user model.
      # Provides associations, role checks, permission checks, and actions.
      #
      # @example Basic usage
      #   class User < ApplicationRecord
      #     has_organizations
      #   end
      #
      # @example With options
      #   class User < ApplicationRecord
      #     has_organizations do
      #       max_organizations 5
      #       create_personal_org true
      #       require_organization false
      #     end
      #   end
      #
      module HasOrganizations
        extend ActiveSupport::Concern

        # Error raised when org limits are exceeded
        class OrganizationLimitReached < Organizations::Error; end
        class CannotLeaveLastOrganization < Organizations::Error; end
        class CannotLeaveAsLastOwner < Organizations::Error; end
        class CannotDeleteAsOrganizationOwner < Organizations::Error; end
        class NoCurrentOrganization < Organizations::Error; end

        # Module containing class methods to be extended onto ActiveRecord::Base
        module ClassMethods
          # Enable organization support on this model
          # @param options [Hash] Configuration options
          # @option options [Integer, nil] :max_organizations Maximum orgs user can own
          # @option options [Boolean] :create_personal_org Create personal org on signup
          # @option options [Boolean] :require_organization Require user to have an org
          # @yield Configuration block using DSL
          def has_organizations(**options, &block)
            # Include instance methods
            include InstanceMethods

            # Define associations
            define_organization_associations

            # Define class_attribute for settings
            define_organization_settings(options, &block)

            # Setup callbacks for personal org creation
            setup_personal_org_callback

            # Preserve owner integrity on user deletion
            setup_owner_deletion_guard
          end

          private

          def define_organization_associations
            # User has many memberships
            has_many :memberships,
                     class_name: "Organizations::Membership",
                     foreign_key: :user_id,
                     inverse_of: :user,
                     dependent: :destroy

            # User has many organizations through memberships
            has_many :organizations,
                     through: :memberships,
                     class_name: "Organizations::Organization"

            # Organizations where user is owner (efficient JOIN)
            has_many :owned_organizations,
                     -> { where(memberships: { role: "owner" }) },
                     through: :memberships,
                     source: :organization,
                     class_name: "Organizations::Organization"

            # Invitations sent by this user
            has_many :sent_organization_invitations,
                     class_name: "Organizations::Invitation",
                     foreign_key: :invited_by_id,
                     inverse_of: :invited_by,
                     dependent: :nullify
          end

          def define_organization_settings(options, &block)
            unless respond_to?(:organization_settings)
              class_attribute :organization_settings, instance_writer: false, default: {}
            end

            # Initialize settings with defaults from configuration
            config = Organizations.configuration
            current_settings = {
              max_organizations: options.fetch(:max_organizations, config&.max_organizations_per_user),
              create_personal_org: options.fetch(:create_personal_org, config&.always_create_personal_organization_for_each_user),
              require_organization: options.fetch(:require_organization, config&.always_require_users_to_belong_to_one_organization)
            }

            # Apply DSL block if provided
            if block_given?
              dsl = DslProvider.new(current_settings)
              dsl.instance_eval(&block)
            end

            # Store final settings
            self.organization_settings = current_settings.freeze
          end

          def setup_personal_org_callback
            after_create :create_personal_organization_if_configured, if: -> {
              self.class.organization_settings[:create_personal_org]
            }
          end

          def setup_owner_deletion_guard
            # `memberships` uses `dependent: :destroy`; this guard must run first
            # so owner memberships still exist when we verify ownership.
            before_destroy :prevent_deletion_while_owning_organizations, prepend: true
          end
        end

        # DSL provider for block configuration
        class DslProvider
          def initialize(settings)
            @settings = settings
          end

          # Set maximum organizations a user can own
          # @param value [Integer, nil] Max organizations (nil = unlimited)
          def max_organizations(value)
            @settings[:max_organizations] = value
          end

          # Enable/disable personal organization creation on signup
          # @param value [Boolean]
          def create_personal_org(value)
            @settings[:create_personal_org] = value
          end

          # Require user to have at least one organization
          # @param value [Boolean]
          def require_organization(value)
            @settings[:require_organization] = value
          end
        end

        # Instance methods included in the user model
        module InstanceMethods
          # === Current Organization Context ===
          # These are set by the controller based on session

          # Store for current organization ID (set by controller)
          attr_accessor :_current_organization_id

          # Returns the current organization for this session
          # @return [Organizations::Organization, nil]
          def current_organization
            return @_current_organization if defined?(@_current_organization) && @_current_organization_id_cached == _current_organization_id

            @_current_organization_id_cached = _current_organization_id
            @_current_organization = _current_organization_id ? organizations.find_by(id: _current_organization_id) : nil
          end

          # Alias for current_organization (convenience as per README)
          def organization
            current_organization
          end

          # Returns the membership in the current organization
          # Keyed by org_id to handle org switches correctly
          # @return [Organizations::Membership, nil]
          def current_membership
            return nil unless current_organization

            # Key memoization by org_id to avoid staleness after org switch
            if @_current_membership_org_id != current_organization.id
              @_current_membership = nil
              @_current_membership_org_id = current_organization.id
            end

            @_current_membership ||= memberships.find_by(organization_id: current_organization.id)
          end

          # Returns the role in the current organization
          # @return [Symbol, nil]
          def current_organization_role
            current_membership&.role&.to_sym
          end

          # Clear cached organization data (called when switching orgs)
          def clear_organization_cache!
            @_current_organization = nil
            @_current_organization_id_cached = nil
            @_current_membership = nil
            @_current_membership_org_id = nil
            @_current_organization_id = nil
          end

          # === Boolean Checks ===

          # Check if user belongs to any organization
          # Uses efficient EXISTS query
          # @return [Boolean]
          def belongs_to_any_organization?
            memberships.loaded? ? memberships.any? : memberships.exists?
          end

          # Check if user has pending invitations
          # Uses efficient EXISTS query
          # @return [Boolean]
          def has_pending_organization_invitations?
            return false unless respond_to?(:email) && email.present?

            Organizations::Invitation.pending.for_email(email).exists?
          end

          # Get pending invitations for this user
          # @return [ActiveRecord::Relation]
          def pending_organization_invitations
            return Organizations::Invitation.none unless respond_to?(:email) && email.present?

            Organizations::Invitation.pending.for_email(email)
          end

          # === Role Checks (current organization) ===

          # Check if user is owner of current organization
          # @return [Boolean]
          def is_organization_owner?
            current_organization_role == :owner
          end

          # Check if user is admin (or owner) of current organization
          # @return [Boolean]
          def is_organization_admin?
            role = current_organization_role
            return false unless role

            Roles.at_least?(role, :admin)
          end

          # Check if user is member (or higher) of current organization
          # @return [Boolean]
          def is_organization_member?
            role = current_organization_role
            return false unless role

            Roles.at_least?(role, :member)
          end

          # Check if user is viewer (or higher) of current organization
          # @return [Boolean]
          def is_organization_viewer?
            current_organization_role.present?
          end

          # Check if user has at least the specified role
          # @param role [Symbol, String] The minimum required role
          # @return [Boolean]
          def has_organization_role?(role)
            current_role = current_organization_role
            return false unless current_role

            Roles.at_least?(current_role, role.to_sym)
          end

          # === Role Checks (specific organization) ===

          # Get user's role in a specific organization
          # Smart about reusing loaded associations
          # @param org [Organization] The organization
          # @return [Symbol, nil]
          def role_in(org)
            return nil unless org

            if org.respond_to?(:association) && org.association(:memberships).loaded?
              membership = org.memberships.find { |m| m.user_id == id }
              return membership&.role&.to_sym
            end

            # Try to use already-loaded association first
            if memberships.loaded?
              membership = memberships.find { |m| m.organization_id == org.id }
              return membership&.role&.to_sym
            end

            if organizations.loaded?
              loaded_org = organizations.find { |candidate| candidate.id == org.id }
              if loaded_org && loaded_org.respond_to?(:association) && loaded_org.association(:memberships).loaded?
                membership = loaded_org.memberships.find { |m| m.user_id == id }
                return membership&.role&.to_sym
              end
            end

            memberships.find_by(organization_id: org.id)&.role&.to_sym
          end

          # Check if user is owner of specific organization
          # @param org [Organization] The organization
          # @return [Boolean]
          def is_owner_of?(org)
            role_in(org) == :owner
          end

          # Check if user is admin (or owner) of specific organization
          # @param org [Organization] The organization
          # @return [Boolean]
          def is_admin_of?(org)
            role = role_in(org)
            return false unless role

            Roles.at_least?(role, :admin)
          end

          # Check if user is a member of specific organization
          # Uses efficient EXISTS query
          # @param org [Organization] The organization
          # @return [Boolean]
          def is_member_of?(org)
            return false unless org

            if memberships.loaded?
              memberships.any? { |membership| membership.organization_id == org.id }
            else
              memberships.exists?(organization_id: org.id)
            end
          end

          # Check if user is viewer (or higher) of specific organization
          # @param org [Organization] The organization
          # @return [Boolean]
          def is_viewer_of?(org)
            role_in(org).present?
          end

          # Check if user is at least the specified role in an organization
          # @param role [Symbol, String] The minimum required role
          # @param in [Organization] The organization (keyword arg)
          # @return [Boolean]
          #
          # @example
          #   user.is_at_least?(:admin, in: org)
          #
          def is_at_least?(role, in: nil)
            org = binding.local_variable_get(:in)
            user_role = org ? role_in(org) : current_organization_role
            return false unless user_role

            Roles.at_least?(user_role, role.to_sym)
          end

          # === Permission Checks ===

          # Check if user has a specific permission in current organization
          # Uses pre-computed permission sets for O(1) lookup
          # @param permission [Symbol, String] The permission to check
          # @return [Boolean]
          def has_organization_permission_to?(permission)
            return false unless current_organization_role

            Roles.has_permission?(current_organization_role, permission)
          end

          # === Actions ===

          # Creates a new organization with this user as owner
          # Sets the new organization as the current organization
          # @param name_or_options [String, Hash] Organization name or options hash
          # @return [Organizations::Organization]
          # @raise [OrganizationLimitReached] if user has reached their organization limit
          def create_organization!(name_or_options)
            name = name_or_options.is_a?(Hash) ? name_or_options[:name] : name_or_options

            # Check max organizations limit
            settings = self.class.organization_settings
            max = settings[:max_organizations]
            if max && owned_organizations.count >= max
              raise OrganizationLimitReached, "Maximum number of organizations (#{max}) reached"
            end

            org = nil
            ActiveRecord::Base.transaction do
              org = Organizations::Organization.create!(name: name)

              Organizations::Membership.create!(
                user: self,
                organization: org,
                role: "owner"
              )
            end

            # Set as current organization context
            # Order matters: set the ID first, then set the cached values
            # (don't call clear_organization_cache! which would clear the ID)
            @_current_organization = org
            @_current_organization_id_cached = org.id
            @_current_membership = nil
            @_current_membership_org_id = nil
            self._current_organization_id = org.id

            Callbacks.dispatch(:organization_created, organization: org, user: self)

            org
          end

          # Leave an organization
          # @param org [Organizations::Organization]
          # @raise [CannotLeaveAsLastOwner] if user is the only owner
          # @raise [CannotLeaveLastOrganization] if require_organization is true
          def leave_organization!(org)
            membership = memberships.find_by(organization_id: org.id)
            return unless membership

            ActiveRecord::Base.transaction do
              # Lock organization to prevent race condition with other leave operations
              org.lock!

              # Check if this is the only owner
              if membership.role.to_sym == :owner
                owner_count = org.memberships.where(role: "owner").count
                if owner_count == 1
                  raise CannotLeaveAsLastOwner, "Cannot leave organization as the only owner. Transfer ownership first."
                end
              end

              # Check require_organization setting
              settings = self.class.organization_settings
              if settings[:require_organization] && organizations.count == 1
                raise CannotLeaveLastOrganization, "Cannot leave your only organization"
              end

              membership.destroy!
            end

            # Clear cache if leaving current organization
            clear_organization_cache! if _current_organization_id == org.id

            Callbacks.dispatch(
              :member_removed,
              organization: org,
              user: self,
              membership: membership,
              removed_by: self
            )
          end

          # Leave current organization
          # @raise [NoCurrentOrganization] if no current organization
          def leave_current_organization!
            unless current_organization
              raise NoCurrentOrganization, "No current organization to leave"
            end

            leave_organization!(current_organization)
          end

          # Send invitation to join organization
          # @param email [String] Email address to invite
          # @param organization [Organizations::Organization] (optional, defaults to current)
          # @param role [Symbol] (optional, defaults to configured default)
          # @return [Organizations::Invitation]
          # @raise [Organizations::NotAuthorized] if user doesn't have permission
          def send_organization_invite_to!(email, organization: nil, role: nil)
            org = organization || current_organization

            unless org
              raise NoCurrentOrganization, "No organization specified and no current organization set"
            end

            # Check permission (permission-based, not role-based)
            # This respects custom role configurations
            user_role = role_in(org)
            unless user_role && Roles.has_permission?(user_role, :invite_members)
              raise Organizations::NotAuthorized.new(
                "You don't have permission to invite members",
                permission: :invite_members,
                organization: org,
                user: self
              )
            end

            org.send_invite_to!(email, invited_by: self, role: role)
          end

          private

          def create_personal_organization_if_configured
            org_name = Organizations.configuration.resolve_default_organization_name(self)
            create_organization!(org_name)
          rescue StandardError => e
            # Log but don't fail user creation
            Callbacks.log_error("[Organizations] Failed to create personal organization: #{e.message}")
          end

          def prevent_deletion_while_owning_organizations
            return unless memberships.where(role: "owner").exists?

            errors.add(:base, "Cannot delete a user who still owns organizations. Transfer ownership first.")
            throw(:abort)
          end
        end
      end
    end
  end
end
