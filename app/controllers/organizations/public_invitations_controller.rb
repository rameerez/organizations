# frozen_string_literal: true

module Organizations
  # Controller for public invitation routes (show and accept).
  # Inherits from PublicController to avoid host app authentication filters.
  #
  # Routes:
  #   GET  /invitations/:token        → View invitation details
  #   POST /invitations/:token/accept → Accept the invitation
  #
  class PublicInvitationsController < PublicController
    include Organizations::Controller if defined?(Organizations::Controller)

    before_action :set_invitation

    # Use the same view path as InvitationsController so host apps
    # don't need to duplicate views for public routes
    def self.controller_path
      "organizations/invitations"
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
        session[pending_invitation_session_key] = @invitation.token

        respond_to do |format|
          format.html do
            redirect_to redirect_path_when_invitation_requires_authentication(@invitation),
                        alert: "Please sign in or create an account to accept this invitation."
          end
          format.json { render json: { error: "Authentication required" }, status: :unauthorized }
        end
        return
      end

      # Verify email matches (for security) - provide user-friendly message before attempting accept
      unless current_user.email.downcase == @invitation.email.downcase
        respond_to do |format|
          format.html { redirect_to invitation_path(@invitation.token), alert: "This invitation was sent to a different email address." }
          format.json { render json: { error: "Email mismatch" }, status: :forbidden }
        end
        return
      end

      # Use canonical accept helper with explicit token
      result = accept_pending_organization_invitation!(
        current_user,
        token: @invitation.token,
        switch: true,
        skip_email_validation: false
      )

      # Handle acceptance result
      if result.nil?
        # This shouldn't happen since we pre-validated, but handle gracefully
        if @invitation.expired?
          respond_to do |format|
            format.html { redirect_to redirect_path_after_invitation_accepted(@invitation, user: current_user), alert: "This invitation has expired. Please request a new one." }
            format.json { render json: { error: "Invitation expired" }, status: :gone }
          end
        else
          respond_to do |format|
            format.html { redirect_to redirect_path_after_invitation_accepted(@invitation, user: current_user), alert: "Unable to accept this invitation." }
            format.json { render json: { error: "Acceptance failed" }, status: :unprocessable_entity }
          end
        end
        return
      end

      # Build response based on result
      membership = result.membership
      after_path = redirect_path_after_invitation_accepted(@invitation, user: current_user)

      if result.already_member?
        respond_to do |format|
          format.html { redirect_to after_path, notice: "You're already a member of #{@invitation.organization.name}." }
          format.json { render json: { message: "Already accepted" }, status: :ok }
        end
      elsif !result.switched?
        # Rare edge case: membership was created but context switch failed
        respond_to do |format|
          format.html { redirect_to after_path, notice: "You've joined #{@invitation.organization.name}! Navigate to the organization to get started." }
          format.json { render json: { membership: membership_json(membership), warning: "Could not switch context automatically" }, status: :created }
        end
      else
        respond_to do |format|
          format.html { redirect_to after_path, notice: "Welcome to #{@invitation.organization.name}!" }
          format.json { render json: { membership: membership_json(membership) }, status: :created }
        end
      end
    end

    private

    def set_invitation
      @invitation = ::Organizations::Invitation.find_by!(token: params[:token])
    rescue ActiveRecord::RecordNotFound
      respond_to do |format|
        format.html { redirect_to main_app.root_path, alert: "Invitation not found or has been revoked." }
        format.json { render json: { error: "Invitation not found" }, status: :not_found }
      end
    end

    def user_exists_for_invitation?
      if defined?(User) && User.respond_to?(:exists?)
        User.exists?(email: @invitation.email.downcase)
      else
        false
      end
    end

    # JSON serialization helpers

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

    # Route helpers for engine routes
    def invitation_path(token)
      Organizations::Engine.routes.url_helpers.invitation_path(token)
    end
  end
end
