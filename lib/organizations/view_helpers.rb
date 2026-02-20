# frozen_string_literal: true

module Organizations
  # View helpers for displaying organization information.
  # Provides formatted data for building UI components without HTML opinions.
  #
  # @example Include in your ApplicationHelper
  #   module ApplicationHelper
  #     include Organizations::ViewHelpers
  #   end
  #
  # @example Using the organization switcher
  #   <% data = organization_switcher_data %>
  #   <div class="org-switcher">
  #     <button><%= data[:current][:name] %></button>
  #     <ul>
  #       <% data[:others].each do |org| %>
  #         <li><%= link_to org[:name], data[:switch_path].call(org[:id]) %></li>
  #       <% end %>
  #     </ul>
  #   </div>
  #
  module ViewHelpers
    # === Host App Route Helper Delegation ===
    #
    # When views are rendered from engine controllers, route helpers like `root_path`
    # resolve to the engine's routes, not the host app's routes. This delegation
    # forwards missing route methods to `main_app` so host app routes work transparently.
    #
    # Instead of requiring `main_app.root_path` everywhere, you can just use `root_path`.
    #
    def method_missing(method, *args, &block)
      if _organizations_route_helper?(method) && respond_to?(:main_app) && main_app.respond_to?(method)
        main_app.public_send(method, *args, &block)
      else
        super
      end
    end

    def respond_to_missing?(method, include_private = false)
      (_organizations_route_helper?(method) && respond_to?(:main_app) && main_app.respond_to?(method)) || super
    end

    private

    def _organizations_route_helper?(method)
      method_name = method.to_s
      method_name.end_with?("_path") || method_name.end_with?("_url")
    end

    public
    # === Organization Switcher ===

    # Returns optimized data for building an organization switcher
    # Only selects needed columns (id, name) for performance
    # Memoized within the request
    #
    # @return [Hash] Hash with :current, :others, and :switch_path
    #
    # @example
    #   organization_switcher_data
    #   # => {
    #   #   current: { id: "...", name: "Acme Corp" },
    #   #   others: [
    #   #     { id: "...", name: "Personal" },
    #   #     { id: "...", name: "StartupCo" }
    #   #   ],
    #   #   switch_path: ->(org_id) { "/organizations/switch/#{org_id}" }
    #   # }
    #
    def organization_switcher_data
      @_organization_switcher_data ||= build_switcher_data
    end

    # === Invitation Badge ===

    # Returns pending invitation badge HTML or nil
    # @param user [User] The user
    # @return [String, nil] Badge HTML or nil if no invitations
    #
    # @example
    #   <%= organization_invitation_badge(current_user) %>
    #   # => <span class="badge">3</span>
    #
    def organization_invitation_badge(user)
      return nil unless user&.respond_to?(:pending_organization_invitations)

      count = user.pending_organization_invitations.count
      return nil if count.zero?

      content_tag(:span, count.to_s, class: "badge")
    end

    # === Role Labels ===

    # Returns a human-readable role label
    # @param role [Symbol, String] The role
    # @return [String]
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
    # @param role [Symbol, String] The role
    # @return [Hash] Hash with :role, :label, and :color keys
    #
    # @example
    #   organization_role_info(:admin)
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

    # === Invitation Status ===

    # Returns invitation status as a symbol
    # @param invitation [Organizations::Invitation] The invitation
    # @return [Symbol] :pending, :accepted, or :expired
    def organization_invitation_status(invitation)
      return :accepted if invitation.accepted_at.present?
      return :expired if invitation.expires_at && invitation.expires_at < Time.current

      :pending
    end

    # Returns a human-readable invitation status label
    # @param invitation [Organizations::Invitation] The invitation
    # @return [String]
    def organization_invitation_status_label(invitation)
      case organization_invitation_status(invitation)
      when :pending then "Pending"
      when :accepted then "Accepted"
      when :expired then "Expired"
      end
    end

    # Returns a hash of invitation status information
    # @param invitation [Organizations::Invitation] The invitation
    # @return [Hash]
    def organization_invitation_status_info(invitation)
      status = organization_invitation_status(invitation)
      {
        status: status,
        label: organization_invitation_status_label(invitation),
        color: invitation_status_color(status)
      }
    end

    # === Members Data ===

    # Returns data for displaying organization members
    # @param organization [Organizations::Organization] The organization
    # @return [Array<Hash>]
    def organization_members_data(organization)
      organization.memberships.includes(:user).by_role_hierarchy.map do |membership|
        user = membership.user
        {
          id: user.id,
          membership_id: membership.id,
          name: user.respond_to?(:name) && user.name.present? ? user.name : user.email,
          email: user.email,
          role: membership.role.to_sym,
          role_label: organization_role_label(membership.role),
          role_info: organization_role_info(membership.role),
          joined_at: membership.created_at,
          is_owner: membership.owner?
        }
      end
    end

    # Returns data for displaying pending invitations
    # @param organization [Organizations::Organization] The organization
    # @return [Array<Hash>]
    def organization_invitations_data(organization)
      organization.invitations.pending.includes(:invited_by).map do |invitation|
        inviter = invitation.invited_by
        {
          id: invitation.id,
          email: invitation.email,
          role: invitation.role.to_sym,
          role_label: organization_role_label(invitation.role),
          invited_by: inviter,
          invited_by_name: inviter_display_name(inviter),
          status: organization_invitation_status(invitation),
          status_info: organization_invitation_status_info(invitation),
          expires_at: invitation.expires_at,
          created_at: invitation.created_at
        }
      end
    end

    # === Permission Checks for Views ===

    # Check if current user can manage organization settings
    # Uses permission-based check to respect custom role configurations
    # @param user [User] The user
    # @param organization [Organizations::Organization] The organization
    # @return [Boolean]
    def can_manage_organization?(user, organization)
      return false unless user && organization

      role = user.role_in(organization)
      role && Roles.has_permission?(role, :manage_settings)
    end

    # Check if current user can invite members
    # Uses permission-based check to respect custom role configurations
    # @param user [User] The user
    # @param organization [Organizations::Organization] The organization
    # @return [Boolean]
    def can_invite_members?(user, organization)
      return false unless user && organization

      role = user.role_in(organization)
      role && Roles.has_permission?(role, :invite_members)
    end

    # Check if current user can remove a member
    # @param user [User] The user performing the action
    # @param membership [Organizations::Membership] The membership to remove
    # @return [Boolean]
    def can_remove_member?(user, membership)
      return false unless user_has_permission_in_org?(user, membership.organization, :remove_members)
      return false if membership.owner? # Can't remove owner

      true
    end

    # Check if current user can change a member's role
    # @param user [User] The user performing the action
    # @param membership [Organizations::Membership] The membership to update
    # @return [Boolean]
    def can_change_member_role?(user, membership)
      return false unless user_has_permission_in_org?(user, membership.organization, :edit_member_roles)
      return false if membership.user_id == user.id # Can't change own role

      # Only owners can change roles to/from owner
      if membership.owner?
        user_has_permission_in_org?(user, membership.organization, :transfer_ownership)
      else
        true
      end
    end

    # Check if current user can transfer ownership
    # @param user [User] The user
    # @param organization [Organizations::Organization] The organization
    # @return [Boolean]
    def can_transfer_ownership?(user, organization)
      user_has_permission_in_org?(user, organization, :transfer_ownership)
    end

    # Check if current user can delete the organization
    # @param user [User] The user
    # @param organization [Organizations::Organization] The organization
    # @return [Boolean]
    def can_delete_organization?(user, organization)
      user_has_permission_in_org?(user, organization, :delete_organization)
    end

    private

    def build_switcher_data
      user = respond_to?(:current_user) ? current_user : nil
      current_org = respond_to?(:current_organization) ? current_organization : nil

      return empty_switcher_data unless user

      # Optimized query: select only needed columns
      memberships = user.memberships
                        .includes(:organization)
                        .joins(:organization)
                        .select("organizations_memberships.id, organizations_memberships.organization_id, organizations_memberships.role, " \
                                "organizations_organizations.id AS org_id, organizations_organizations.name AS org_name")

      current_data = nil
      others = []

      memberships.each do |m|
        org_data = {
          id: m.organization_id,
          name: m.org_name,
          role: m.role.to_sym,
          role_label: organization_role_label(m.role)
        }

        if current_org && m.organization_id == current_org.id
          current_data = org_data.merge(current: true)
        else
          others << org_data.merge(current: false)
        end
      end

      # If no current org was found in memberships, user might not be a member anymore
      current_data ||= { id: nil, name: nil, role: nil, current: true }

      {
        current: current_data,
        others: others,
        switch_path: build_switch_path_lambda
      }
    end

    def empty_switcher_data
      {
        current: { id: nil, name: nil, role: nil, current: true },
        others: [],
        switch_path: build_switch_path_lambda
      }
    end

    # Build a lambda for generating switch paths
    # Uses route helpers when available, falls back to hardcoded path
    def build_switch_path_lambda
      # Try to use route helpers if available
      # The route name is :switch_organization (POST /organizations/switch/:id)
      if respond_to?(:organizations) && organizations.respond_to?(:switch_organization_path)
        ->(org_id) { organizations.switch_organization_path(org_id) }
      elsif respond_to?(:main_app) && main_app.respond_to?(:switch_organization_path)
        ->(org_id) { main_app.switch_organization_path(org_id) }
      else
        # Fallback to standard path
        ->(org_id) { "/organizations/switch/#{org_id}" }
      end
    end

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

    def user_has_permission_in_org?(user, organization, permission)
      return false unless user && organization

      role = user.role_in(organization)
      role && Roles.has_permission?(role, permission)
    end

    # Returns display name for invitation sender (handles nil inviter)
    def inviter_display_name(inviter)
      return nil unless inviter

      if inviter.respond_to?(:name) && inviter.name.present?
        inviter.name
      else
        inviter.email
      end
    end
  end
end
