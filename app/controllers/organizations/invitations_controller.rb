# frozen_string_literal: true

module Organizations
  # Controller for handling organization invitations.
  # Supports both viewing/accepting invitations via token (public) and
  # managing invitations within an organization (requires admin).
  #
  class InvitationsController < ApplicationController
    # Skip authentication for public invitation routes
    skip_before_action :authenticate_organizations_user!, only: [:show, :accept]

    # Require invitation permission for invitation management
    before_action -> { require_organization_permission_to!(:invite_members) }, only: [:index, :new, :create, :destroy, :resend]
    before_action :set_invitation_by_token, only: [:show, :accept]
    before_action :set_invitation_by_id, only: [:destroy, :resend]

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
          format.html { redirect_to organization_invitations_path, notice: "Invitation sent to #{email}" }
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

    # GET /invitations/:token
    # View invitation details (public route)
    def show
      @user_exists = user_exists_for_invitation?
      @user_is_logged_in = current_user.present?
      @user_email_matches = @user_is_logged_in && current_user.email.downcase == @invitation.email.downcase

      respond_to do |format|
        format.html
        format.json { render json: invitation_show_json }
      end
    end

    # POST /invitations/:token/accept
    # Accept an invitation (public route)
    def accept
      # Require authentication to accept
      unless current_user
        # Store invitation token in session for post-signup acceptance
        session[:pending_invitation_token] = @invitation.token

        respond_to do |format|
          format.html do
            redirect_to main_app.respond_to?(:new_user_registration_path) ?
              main_app.new_user_registration_path :
              main_app.root_path,
              alert: "Please sign in or create an account to accept this invitation."
          end
          format.json { render json: { error: "Authentication required" }, status: :unauthorized }
        end
        return
      end

      # Verify email matches (for security)
      unless current_user.email.downcase == @invitation.email.downcase
        respond_to do |format|
          format.html { redirect_to invitation_path(@invitation.token), alert: "This invitation was sent to a different email address." }
          format.json { render json: { error: "Email mismatch" }, status: :forbidden }
        end
        return
      end

      begin
        membership = @invitation.accept!(current_user)

        # Switch to the new organization
        switch_to_organization!(@invitation.organization)

        respond_to do |format|
          format.html { redirect_to after_accept_path, notice: "Welcome to #{@invitation.organization.name}!" }
          format.json { render json: { membership: membership_json(membership) }, status: :created }
        end
      rescue ::Organizations::InvitationExpired
        respond_to do |format|
          format.html { redirect_to main_app.root_path, alert: "This invitation has expired. Please request a new one." }
          format.json { render json: { error: "Invitation expired" }, status: :gone }
        end
      rescue ::Organizations::InvitationAlreadyAccepted
        respond_to do |format|
          format.html { redirect_to after_accept_path, notice: "You're already a member of #{@invitation.organization.name}." }
          format.json { render json: { message: "Already accepted" }, status: :ok }
        end
      end
    end

    # DELETE /invitations/:id
    # Revoke/delete an invitation
    def destroy
      @invitation.destroy!

      respond_to do |format|
        format.html { redirect_to organization_invitations_path, notice: "Invitation revoked" }
        format.json { head :no_content }
      end
    end

    # POST /invitations/:id/resend
    # Resend an invitation email
    def resend
      begin
        @invitation.resend!

        respond_to do |format|
          format.html { redirect_to organization_invitations_path, notice: "Invitation resent to #{@invitation.email}" }
          format.json { render json: invitation_json(@invitation) }
        end
      rescue ::Organizations::InvitationAlreadyAccepted => e
        respond_to do |format|
          format.html { redirect_to organization_invitations_path, alert: e.message }
          format.json { render json: { error: e.message }, status: :unprocessable_entity }
        end
      end
    end

    private

    def invitation_params
      params.require(:invitation).permit(:email, :role)
    end

    def set_invitation_by_token
      @invitation = ::Organizations::Invitation.find_by!(token: params[:token])
    rescue ActiveRecord::RecordNotFound
      respond_to do |format|
        format.html { redirect_to main_app.root_path, alert: "Invitation not found or has been revoked." }
        format.json { render json: { error: "Invitation not found" }, status: :not_found }
      end
    end

    def set_invitation_by_id
      @invitation = current_organization.invitations.find(params[:id])
    end

    # Override to handle public routes where authentication is skipped
    # Avoids infinite recursion when method_name == :current_user
    def current_user
      return @_current_user if defined?(@_current_user)

      method_name = ::Organizations.configuration.current_user_method

      # Avoid infinite recursion: if configured method is :current_user,
      # call the parent implementation, not this method
      @_current_user = if method_name == :current_user
                         super rescue nil
                       elsif respond_to?(method_name, true)
                         send(method_name)
                       end
    end

    def user_exists_for_invitation?
      # Check if a user exists with this email
      # This requires knowledge of the User model
      if defined?(User) && User.respond_to?(:exists?)
        User.exists?(email: @invitation.email.downcase)
      else
        false
      end
    end

    def after_accept_path
      main_app.respond_to?(:root_path) ? main_app.root_path : "/"
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

    def invitation_show_json
      inviter = @invitation.invited_by
      inviter_name = if inviter
                       inviter.respond_to?(:name) && inviter.name.present? ? inviter.name : inviter.email
                     else
                       "Someone"
                     end
      {
        invitation: {
          organization_name: @invitation.organization.name,
          role: @invitation.role,
          invited_by_name: inviter_name,
          status: @invitation.status,
          expires_at: @invitation.expires_at
        },
        user_exists: @user_exists,
        user_is_logged_in: @user_is_logged_in,
        user_email_matches: @user_email_matches
      }
    end

    def membership_json(membership)
      {
        id: membership.id,
        organization_id: membership.organization_id,
        role: membership.role,
        created_at: membership.created_at
      }
    end
  end
end
