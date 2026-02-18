# frozen_string_literal: true

require "active_support/concern"

module Organizations
  # Controller helpers to be included in host application controllers.
  # Provides current_organization context and permission guards.
  #
  # @example Include in ApplicationController
  #   class ApplicationController < ActionController::Base
  #     include Organizations::ControllerHelpers
  #   end
  #
  module ControllerHelpers
    extend ActiveSupport::Concern

    included do
      helper_method :current_organization if respond_to?(:helper_method)
      helper_method :current_membership if respond_to?(:helper_method)
    end

    # Returns the current organization from the session
    # @return [Organizations::Organization, nil]
    def current_organization
      return @current_organization if defined?(@current_organization)

      session_key = Organizations.configuration.session_key
      org_id = session[session_key]
      return nil unless org_id

      user = send(Organizations.configuration.current_user_method)
      return nil unless user

      @current_organization = user.organizations.find_by(id: org_id)
    end

    # Returns the current user's membership in the current organization
    # @return [Organizations::Membership, nil]
    def current_membership
      return nil unless current_organization

      user = send(Organizations.configuration.current_user_method)
      return nil unless user

      user.memberships.find_by(organization: current_organization)
    end

    # Sets the current organization in session
    # @param org [Organizations::Organization, nil]
    def current_organization=(org)
      session_key = Organizations.configuration.session_key

      if org
        session[session_key] = org.id
        @current_organization = org
      else
        session.delete(session_key)
        @current_organization = nil
      end
    end

    # Switches to a different organization
    # @param org [Organizations::Organization]
    # @raise [Organizations::NotAMember] if user is not a member
    def switch_to_organization!(org)
      user = send(Organizations.configuration.current_user_method)

      unless user&.is_member_of?(org)
        raise Organizations::NotAMember.new(
          "You are not a member of this organization",
          organization: org,
          user: user
        )
      end

      self.current_organization = org
    end

    # --- Permission Guards ---
    # Use these as before_action callbacks

    # Requires a current organization to be set
    # @example
    #   before_action :require_organization!
    def require_organization!
      return if current_organization

      respond_to do |format|
        format.html { redirect_to main_app.root_path, alert: "Please select an organization." }
        format.json { render json: { error: "Organization required" }, status: :forbidden }
      end
    end

    # Requires the user to be an admin of the current organization
    # @example
    #   before_action :require_organization_admin!, only: [:edit, :update, :destroy]
    def require_organization_admin!
      require_organization!
      return unless current_organization

      user = send(Organizations.configuration.current_user_method)
      return if user&.is_admin_of?(current_organization)

      raise Organizations::NotAuthorized.new(
        "You need admin access to perform this action",
        permission: :admin,
        organization: current_organization,
        user: user
      )
    end

    # Requires the user to be the owner of the current organization
    # @example
    #   before_action :require_organization_owner!, only: [:destroy]
    def require_organization_owner!
      require_organization!
      return unless current_organization

      user = send(Organizations.configuration.current_user_method)
      return if user&.is_owner_of?(current_organization)

      raise Organizations::NotAuthorized.new(
        "You need owner access to perform this action",
        permission: :owner,
        organization: current_organization,
        user: user
      )
    end

    # Requires the user to have a specific permission
    # @param permission [Symbol] The permission to check
    # @example
    #   before_action -> { require_organization_permission!(:invite_members) }, only: [:create]
    def require_organization_permission!(permission)
      require_organization!
      return unless current_organization

      user = send(Organizations.configuration.current_user_method)
      return if user&.has_organization_permission_to?(permission)

      raise Organizations::NotAuthorized.new(
        "You don't have permission to #{permission.to_s.humanize.downcase}",
        permission: permission,
        organization: current_organization,
        user: user
      )
    end
  end
end
