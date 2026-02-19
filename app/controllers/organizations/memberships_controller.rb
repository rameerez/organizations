# frozen_string_literal: true

module Organizations
  # Controller for managing organization memberships.
  # Provides listing members, changing roles, and removing members.
  #
  class MembershipsController < ApplicationController
    before_action :require_organization!
    before_action -> { require_organization_permission_to!(:view_members) }, only: [:index]
    before_action :set_membership, only: [:update, :destroy, :transfer_ownership]
    before_action -> { require_organization_permission_to!(:edit_member_roles) }, only: [:update]
    before_action -> { require_organization_permission_to!(:remove_members) }, only: [:destroy]
    before_action -> { require_organization_permission_to!(:transfer_ownership) }, only: [:transfer_ownership]

    # GET /memberships
    # List all members of the current organization
    def index
      @memberships = current_organization.memberships.includes(:user).by_role_hierarchy

      respond_to do |format|
        format.html
        format.json { render json: memberships_json(@memberships) }
      end
    end

    # PATCH/PUT /memberships/:id
    # Change a member's role
    def update
      # Validate the requester can make this change
      validate_role_change!

      new_role = membership_params[:role].to_sym

      begin
        # Use the invariant-safe domain method that enforces owner rules
        current_organization.change_role_of!(
          @membership.user,
          to: new_role,
          changed_by: current_user
        )

        # Reload to get updated role
        @membership.reload

        respond_to do |format|
          format.html { redirect_to memberships_path, notice: "Role updated successfully." }
          format.json { render json: membership_json(@membership) }
        end
      rescue Organizations::Organization::CannotHaveMultipleOwners,
             Organizations::Organization::CannotDemoteOwner,
             Organizations::Error => e
        respond_to do |format|
          format.html { redirect_to memberships_path, alert: e.message }
          format.json { render json: { error: e.message }, status: :unprocessable_entity }
        end
      rescue ActiveRecord::RecordInvalid => e
        respond_to do |format|
          format.html { redirect_to memberships_path, alert: e.record.errors.full_messages.join(", ") }
          format.json { render json: { errors: e.record.errors }, status: :unprocessable_entity }
        end
      end
    end

    # DELETE /memberships/:id
    # Remove a member from the current organization
    def destroy
      # Validate the requester can make this change
      validate_removal!
      current_organization.remove_member!(@membership.user, removed_by: current_user)

      respond_to do |format|
        format.html { redirect_to memberships_path, notice: "Member removed successfully." }
        format.json { head :no_content }
      end
    rescue Organizations::Organization::CannotRemoveOwner, Organizations::Error => e
      respond_to do |format|
        format.html { redirect_to memberships_path, alert: e.message }
        format.json { render json: { error: e.message }, status: :unprocessable_entity }
      end
    end

    # POST /memberships/:id/transfer_ownership
    # Transfer organization ownership to another member
    def transfer_ownership
      new_owner = @membership.user

      begin
        current_organization.transfer_ownership_to!(new_owner)

        respond_to do |format|
          format.html { redirect_to memberships_path, notice: "Ownership transferred to #{new_owner.email}." }
          format.json { render json: { success: true, new_owner: new_owner.email } }
        end
      rescue Organizations::Organization::CannotTransferToNonMember,
             Organizations::Organization::CannotTransferToSelf,
             Organizations::Error => e
        respond_to do |format|
          format.html { redirect_to memberships_path, alert: e.message }
          format.json { render json: { error: e.message }, status: :unprocessable_entity }
        end
      end
    end

    private

    def set_membership
      @membership = current_organization.memberships.find(params[:id])
    end

    def membership_params
      params.require(:membership).permit(:role)
    end

    def validate_role_change!
      new_role = membership_params[:role]&.to_sym

      # Can't change your own role
      if @membership.user_id == current_user.id
        raise Organizations::NotAuthorized.new(
          "You cannot change your own role",
          permission: :edit_member_roles,
          organization: current_organization,
          user: current_user
        )
      end

      # Validate the new role is valid
      unless Roles.valid_role?(new_role)
        raise Organizations::Error, "Invalid role: #{new_role}"
      end

      # Note: Owner promotion/demotion rules are enforced by Organization#change_role_of!
      # which will raise CannotHaveMultipleOwners or CannotDemoteOwner as appropriate
    end

    def validate_removal!
      # Can't remove yourself
      if @membership.user_id == current_user.id
        raise Organizations::NotAuthorized.new(
          "You cannot remove yourself. Use 'Leave Organization' instead.",
          permission: :remove_members,
          organization: current_organization,
          user: current_user
        )
      end

      # Can't remove the owner
      if @membership.owner?
        raise Organizations::NotAuthorized.new(
          "Cannot remove the organization owner. Transfer ownership first.",
          permission: :remove_members,
          organization: current_organization,
          user: current_user
        )
      end
    end

    # JSON serialization helpers

    def memberships_json(memberships)
      memberships.map { |m| membership_json(m) }
    end

    def membership_json(membership)
      user = membership.user
      {
        id: membership.id,
        user: {
          id: user.id,
          email: user.email,
          name: user.respond_to?(:name) ? user.name : nil
        },
        role: membership.role,
        is_owner: membership.owner?,
        joined_at: membership.created_at
      }
    end
  end
end
