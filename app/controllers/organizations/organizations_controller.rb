# frozen_string_literal: true

module Organizations
  # Controller for managing organizations.
  # Provides CRUD operations for organizations the user owns/manages.
  #
  class OrganizationsController < ApplicationController
    before_action :set_organization, only: [:show, :edit, :update, :destroy]
    before_action :authorize_manage_settings!, only: [:edit, :update]
    before_action :authorize_delete_organization!, only: [:destroy]

    # GET /organizations
    # List all organizations the user belongs to
    def index
      # Optimized query: preload memberships and use counter cache or subquery for counts
      @memberships = current_user.memberships.includes(:organization)

      respond_to do |format|
        format.html { @organizations = @memberships.map(&:organization) }
        format.json { render json: organizations_json_optimized(@memberships) }
      end
    end

    # GET /organizations/:id
    # Show organization details
    def show
      respond_to do |format|
        format.html
        format.json { render json: organization_json(@organization) }
      end
    end

    # GET /organizations/new
    # Form to create a new organization
    def new
      @organization = Organization.new
    end

    # POST /organizations
    # Create a new organization
    def create
      begin
        @organization = current_user.create_organization!(organization_params.to_h)

        # Switch to the new organization
        switch_to_organization!(@organization)

        respond_to do |format|
          format.html { redirect_to after_create_redirect_path(@organization), notice: "Organization created successfully." }
          format.json { render json: organization_json(@organization), status: :created }
        end
      rescue Organizations::Models::Concerns::HasOrganizations::OrganizationLimitReached => e
        respond_to do |format|
          format.html do
            @organization = Organization.new(organization_params)
            flash.now[:alert] = e.message
            render :new, status: :unprocessable_entity
          end
          format.json { render json: { error: e.message }, status: :unprocessable_entity }
        end
      rescue ActiveRecord::RecordInvalid => e
        respond_to do |format|
          format.html do
            @organization = Organization.new(organization_params)
            flash.now[:alert] = e.record.errors.full_messages.join(", ")
            render :new, status: :unprocessable_entity
          end
          format.json { render json: { errors: e.record.errors }, status: :unprocessable_entity }
        end
      end
    end

    # GET /organizations/:id/edit
    # Form to edit organization
    def edit
    end

    # PATCH/PUT /organizations/:id
    # Update organization
    def update
      if @organization.update(organization_params)
        respond_to do |format|
          format.html { redirect_to organization_path(@organization), notice: "Organization updated successfully." }
          format.json { render json: organization_json(@organization) }
        end
      else
        respond_to do |format|
          format.html { render :edit, status: :unprocessable_entity }
          format.json { render json: { errors: @organization.errors }, status: :unprocessable_entity }
        end
      end
    end

    # DELETE /organizations/:id
    # Delete organization (owner only)
    def destroy
      @organization.destroy!

      # Clear session if this was the current organization
      clear_organization_session! if current_organization&.id == @organization.id

      respond_to do |format|
        format.html { redirect_to organizations_path, notice: "Organization deleted successfully." }
        format.json { head :no_content }
      end
    end

    private

    def set_organization
      @organization = current_user.organizations.find(params[:id])
    rescue ActiveRecord::RecordNotFound
      respond_to do |format|
        format.html { redirect_to organizations_path, alert: "Organization not found." }
        format.json { render json: { error: "Organization not found" }, status: :not_found }
      end
    end

    def organization_params
      base_params = [:name]
      additional_params = Organizations.configuration.additional_organization_params || []
      params.require(:organization).permit(base_params + additional_params)
    end

    def after_create_redirect_path(organization)
      custom_path = Organizations.configuration.after_organization_created_redirect_path
      case custom_path
      when Proc
        instance_exec(organization, &custom_path)
      when String
        custom_path
      else
        organization_path(organization)
      end
    end

    def authorize_manage_settings!
      role = current_user.role_in(@organization)
      return if role && Roles.has_permission?(role, :manage_settings)

      handle_unauthorized(permission: :manage_settings)
    end

    def authorize_delete_organization!
      role = current_user.role_in(@organization)
      return if role && Roles.has_permission?(role, :delete_organization)

      handle_unauthorized(permission: :delete_organization)
    end

    # JSON serialization helpers

    # Optimized: uses preloaded memberships to avoid N+1
    def organizations_json_optimized(memberships)
      # Batch load member counts for all orgs in one query
      org_ids = memberships.map { |m| m.organization_id }
      counts = Organization.where(id: org_ids)
                           .joins(:memberships)
                           .group(:id)
                           .count("memberships.id")

      memberships.map do |membership|
        org = membership.organization
        {
          id: org.id,
          name: org.name,
          member_count: counts[org.id] || 0,
          role: membership.role,
          created_at: org.created_at,
          updated_at: org.updated_at
        }
      end
    end

    def organizations_json(organizations)
      organizations.map { |org| organization_json(org) }
    end

    def organization_json(org)
      membership = current_user.memberships.find_by(organization_id: org.id)
      {
        id: org.id,
        name: org.name,
        member_count: org.member_count,
        role: membership&.role,
        created_at: org.created_at,
        updated_at: org.updated_at
      }
    end
  end
end
