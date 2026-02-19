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
      org = current_user.organizations.find_by(id: params[:id])

      if org
        switch_to_organization!(org)

        respond_to do |format|
          format.html { redirect_to after_switch_path, notice: "Switched to #{org.name}" }
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

    def after_switch_path
      main_app.respond_to?(:root_path) ? main_app.root_path : "/"
    end
  end
end
