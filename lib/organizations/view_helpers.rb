# frozen_string_literal: true

module Organizations
  # View helpers for displaying organization information.
  #
  # These helpers provide formatted data without HTML opinions,
  # allowing integrators to build their own UI while using
  # consistent data formatting.
  #
  # @example Include in your ApplicationHelper
  #   module ApplicationHelper
  #     include Organizations::ViewHelpers
  #   end
  #
  # @example Or include in a specific controller
  #   class Settings::OrganizationsController < ApplicationController
  #     helper Organizations::ViewHelpers
  #   end
  #
  module ViewHelpers
    # Returns a human-readable role label
    #
    # @param role [Symbol, String] The role
    # @return [String] "Owner", "Admin", "Member", or "Viewer"
    #
    # @example
    #   organization_role_label(:admin) # => "Admin"
    #
    def organization_role_label(role)
      case role.to_sym
      when :owner then "Owner"
      when :admin then "Admin"
      when :member then "Member"
      when :viewer then "Viewer"
      else role.to_s.humanize
      end
    end

    # Returns a hash of role information for building badges
    #
    # @param role [Symbol, String] The role
    # @return [Hash] Hash with :role, :label, and :color keys
    #
    # @example
    #   info = organization_role_info(:admin)
    #   # => { role: :admin, label: "Admin", color: :blue }
    #
    def organization_role_info(role)
      role_sym = role.to_sym
      {
        role: role_sym,
        label: organization_role_label(role_sym),
        color: role_color(role_sym)
      }
    end

    # Returns invitation status as a symbol
    #
    # @param invitation [Organizations::Invitation] The invitation
    # @return [Symbol] :pending, :accepted, or :expired
    #
    def organization_invitation_status(invitation)
      return :accepted if invitation.accepted_at.present?
      return :expired if invitation.expires_at && invitation.expires_at < Time.current

      :pending
    end

    # Returns a human-readable invitation status label
    #
    # @param invitation [Organizations::Invitation] The invitation
    # @return [String] "Pending", "Accepted", or "Expired"
    #
    def organization_invitation_status_label(invitation)
      case organization_invitation_status(invitation)
      when :pending then "Pending"
      when :accepted then "Accepted"
      when :expired then "Expired"
      end
    end

    # Returns a hash of invitation status information
    #
    # @param invitation [Organizations::Invitation] The invitation
    # @return [Hash] Hash with :status, :label, and :color keys
    #
    def organization_invitation_status_info(invitation)
      status = organization_invitation_status(invitation)
      {
        status: status,
        label: organization_invitation_status_label(invitation),
        color: invitation_status_color(status)
      }
    end

    # Returns data for building an organization switcher
    #
    # @param user [User] The user
    # @param current_org [Organizations::Organization] The current organization
    # @return [Array<Hash>] Array of hashes with organization data
    #
    # @example
    #   organization_switcher_data(current_user, current_organization)
    #   # => [
    #   #   { id: 1, name: "Acme Corp", slug: "acme-corp", role: :owner, current: true },
    #   #   { id: 2, name: "Startup Co", slug: "startup-co", role: :member, current: false }
    #   # ]
    #
    def organization_switcher_data(user, current_org = nil)
      user.memberships.includes(:organization).map do |membership|
        org = membership.organization
        {
          id: org.id,
          name: org.name,
          slug: org.slug,
          role: membership.role.to_sym,
          role_label: organization_role_label(membership.role),
          current: current_org && org.id == current_org.id
        }
      end
    end

    # Returns data for displaying organization members
    #
    # @param organization [Organizations::Organization] The organization
    # @return [Array<Hash>] Array of hashes with member data
    #
    def organization_members_data(organization)
      organization.memberships.includes(:user).map do |membership|
        user = membership.user
        {
          id: user.id,
          membership_id: membership.id,
          name: user.respond_to?(:name) ? user.name : user.email,
          email: user.email,
          role: membership.role.to_sym,
          role_label: organization_role_label(membership.role),
          role_info: organization_role_info(membership.role),
          joined_at: membership.created_at
        }
      end
    end

    # Returns data for displaying pending invitations
    #
    # @param organization [Organizations::Organization] The organization
    # @return [Array<Hash>] Array of hashes with invitation data
    #
    def organization_invitations_data(organization)
      organization.invitations.pending.includes(:invited_by).map do |invitation|
        {
          id: invitation.id,
          email: invitation.email,
          role: invitation.role.to_sym,
          role_label: organization_role_label(invitation.role),
          invited_by: invitation.invited_by,
          invited_by_name: invitation.invited_by.respond_to?(:name) ? invitation.invited_by.name : invitation.invited_by.email,
          status: organization_invitation_status(invitation),
          status_info: organization_invitation_status_info(invitation),
          expires_at: invitation.expires_at,
          created_at: invitation.created_at
        }
      end
    end

    # Check if current user can manage organization
    #
    # @param user [User] The user
    # @param organization [Organizations::Organization] The organization
    # @return [Boolean]
    #
    def can_manage_organization?(user, organization)
      user.is_admin_of?(organization)
    end

    # Check if current user can invite members
    #
    # @param user [User] The user
    # @param organization [Organizations::Organization] The organization
    # @return [Boolean]
    #
    def can_invite_members?(user, organization)
      user.is_admin_of?(organization)
    end

    # Check if current user can remove a member
    #
    # @param user [User] The user (performing the action)
    # @param membership [Organizations::Membership] The membership to remove
    # @return [Boolean]
    #
    def can_remove_member?(user, membership)
      return false unless user.is_admin_of?(membership.organization)
      return false if membership.role.to_sym == :owner # Can't remove owners via this

      true
    end

    # Check if current user can change a member's role
    #
    # @param user [User] The user (performing the action)
    # @param membership [Organizations::Membership] The membership to update
    # @return [Boolean]
    #
    def can_change_member_role?(user, membership)
      return false unless user.is_admin_of?(membership.organization)
      return false if membership.user_id == user.id # Can't change own role

      # Only owners can change roles to/from owner
      if membership.role.to_sym == :owner
        user.is_owner_of?(membership.organization)
      else
        true
      end
    end

    private

    def role_color(role)
      case role.to_sym
      when :owner then :purple
      when :admin then :blue
      when :member then :green
      when :viewer then :gray
      else :gray
      end
    end

    def invitation_status_color(status)
      case status
      when :pending then :yellow
      when :accepted then :green
      when :expired then :red
      else :gray
      end
    end
  end
end
