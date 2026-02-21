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
      return respond_invitation_authentication_required unless current_user

      result = accept_pending_organization_invitation!(
        current_user,
        token: @invitation.token,
        switch: true,
        skip_email_validation: false,
        return_failure: true
      )

      return respond_invitation_acceptance_failure(result) if result.failure?

      respond_invitation_acceptance_success(result)
    end

    private

    def respond_invitation_authentication_required
      session[pending_invitation_session_key] = @invitation.token

      respond_to do |format|
        format.html do
          redirect_to redirect_path_when_invitation_requires_authentication(@invitation),
                      alert: "Please sign in or create an account to accept this invitation."
        end
        format.json { render json: { error: "Authentication required" }, status: :unauthorized }
      end
    end

    def respond_invitation_acceptance_failure(failure)
      case failure.failure_reason
      when :email_mismatch
        return respond_invitation_email_mismatch
      when :invitation_expired
        return respond_invitation_expired
      end

      respond_invitation_error(
        html_path: main_app.root_path,
        alert: "Unable to accept this invitation.",
        json_error: "Acceptance failed",
        status: :unprocessable_entity
      )
    end

    def respond_invitation_email_mismatch
      respond_invitation_error(
        html_path: invitation_path(@invitation.token),
        alert: "This invitation was sent to a different email address.",
        json_error: "Email mismatch",
        status: :forbidden
      )
    end

    def respond_invitation_expired
      respond_invitation_error(
        html_path: main_app.root_path,
        alert: "This invitation has expired. Please request a new one.",
        json_error: "Invitation expired",
        status: :gone
      )
    end

    def respond_invitation_acceptance_success(result)
      after_path = redirect_path_after_invitation_accepted(result.invitation, user: current_user)
      payload, status = invitation_acceptance_json_response(result)

      respond_to do |format|
        format.html { redirect_to after_path, notice: invitation_acceptance_notice(result) }
        format.json { render json: payload, status: status }
      end
    end

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

    def respond_invitation_error(html_path:, alert:, json_error:, status:)
      respond_to do |format|
        format.html { redirect_to html_path, alert: alert }
        format.json { render json: { error: json_error }, status: status }
      end
    end

    def invitation_acceptance_notice(result)
      org_name = result.invitation.organization.name

      if result.already_member?
        "You're already a member of #{org_name}."
      elsif result.switched?
        "Welcome to #{org_name}!"
      else
        # Rare edge case: membership was created but context switch failed
        "You've joined #{org_name}! Navigate to the organization to get started."
      end
    end

    def invitation_acceptance_json_response(result)
      if result.already_member?
        [{ message: "Already accepted" }, :ok]
      elsif result.switched?
        [{ membership: membership_json(result.membership) }, :created]
      else
        # Rare edge case: membership was created but context switch failed
        [{ membership: membership_json(result.membership), warning: "Could not switch context automatically" }, :created]
      end
    end

    # Route helpers for engine routes
    def invitation_path(token)
      Organizations::Engine.routes.url_helpers.invitation_path(token)
    end
  end
end
