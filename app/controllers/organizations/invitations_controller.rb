# frozen_string_literal: true

module Organizations
  # Controller for managing organization invitations.
  # Requires admin/invite_members permission for all actions.
  #
  # Note: Public invitation routes (show/accept) are handled by
  # PublicInvitationsController to avoid host app authentication filters.
  #
  class InvitationsController < ApplicationController
    before_action -> { require_organization_permission_to!(:invite_members) }
    before_action :set_invitation, only: [:destroy, :resend]

    # GET /invitations
    # List all invitations for the current organization
    def index
      @invitations = current_organization.invitations.includes(:invited_by).order(created_at: :desc)

      respond_to do |format|
        format.html
        format.json { render json: invitations_json(@invitations) }
      end
    end

    # GET /invitations/new
    # Form to create a new invitation
    def new
      @invitation = current_organization.invitations.build
      @return_to = request.referer
    end

    # POST /invitations
    # Create a new invitation for the current organization
    def create
      email = invitation_params[:email]
      role = invitation_params[:role] || ::Organizations.configuration.default_invitation_role

      begin
        @invitation = current_user.send_organization_invite_to!(
          email,
          organization: current_organization,
          role: role
        )

        respond_to do |format|
          return_to = params[:return_to].presence || organization_invitations_path
          format.html { redirect_to return_to, notice: "Invitation sent to #{email}" }
          format.json { render json: invitation_json(@invitation), status: :created }
        end
      rescue ::Organizations::InvitationError, ActiveRecord::RecordInvalid, ArgumentError => e
        respond_to do |format|
          format.html do
            @invitation = current_organization.invitations.build(invitation_params)
            flash.now[:alert] = e.message
            render :new, status: :unprocessable_entity
          end
          format.json { render json: { error: e.message }, status: :unprocessable_entity }
        end
      end
    end

    # DELETE /invitations/:id
    # Revoke/delete an invitation
    def destroy
      @invitation.destroy!

      respond_to do |format|
        format.html { redirect_back fallback_location: organization_invitations_path, notice: "Invitation revoked" }
        format.json { head :no_content }
      end
    end

    # POST /invitations/:id/resend
    # Resend an invitation email
    def resend
      begin
        @invitation.resend!

        respond_to do |format|
          format.html { redirect_back fallback_location: organization_invitations_path, notice: "Invitation resent to #{@invitation.email}" }
          format.json { render json: invitation_json(@invitation) }
        end
      rescue ::Organizations::InvitationAlreadyAccepted => e
        respond_to do |format|
          format.html { redirect_back fallback_location: organization_invitations_path, alert: e.message }
          format.json { render json: { error: e.message }, status: :unprocessable_entity }
        end
      end
    end

    private

    def invitation_params
      params.require(:invitation).permit(:email, :role)
    end

    def set_invitation
      @invitation = current_organization.invitations.find(params[:id])
    end

    # JSON serialization helpers

    def invitations_json(invitations)
      invitations.map { |i| invitation_json(i) }
    end

    def invitation_json(invitation)
      inviter = invitation.invited_by
      {
        id: invitation.id,
        email: invitation.email,
        role: invitation.role,
        status: invitation.status,
        invited_by: inviter ? {
          id: inviter.id,
          email: inviter.email,
          name: inviter.respond_to?(:name) ? inviter.name : nil
        } : nil,
        expires_at: invitation.expires_at,
        accepted_at: invitation.accepted_at,
        created_at: invitation.created_at
      }
    end
  end
end
