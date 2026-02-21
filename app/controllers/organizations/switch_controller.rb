# frozen_string_literal: true

module Organizations
  # Controller for switching between organizations.
  # Handles the POST /organizations/switch/:id route.
  #
  # @example Using the switch route
  #   POST /organizations/switch/123
  #   # Redirects to root_path with new current_organization set
  #
  class SwitchController < ApplicationController
    # Switch to a different organization
    # POST /organizations/switch/:id
    def create
      user = organizations_current_user(refresh: true)
      return respond_unauthorized unless user

      org = user.organizations.find_by(id: params[:id])

      if org
        switch_to_organization!(org, user: user)

        respond_to do |format|
          format.html { redirect_to after_switch_path(org, user: user), notice: "Switched to #{org.name}" }
          format.json { render json: { organization: { id: org.id, name: org.name } } }
        end
      else
        respond_to do |format|
          format.html { redirect_back fallback_location: main_app.root_path, alert: "Organization not found or you're not a member" }
          format.json { render json: { error: "Organization not found" }, status: :not_found }
        end
      end
    end

    private

    def after_switch_path(organization, user:)
      redirect_path_after_organization_switched(organization, user: user)
    end

    def respond_unauthorized
      respond_to do |format|
        format.html { redirect_to main_app.root_path, alert: "You need to sign in to switch organizations." }
        format.json { render json: { error: "Unauthorized" }, status: :unauthorized }
      end
    end
  end
end
