# frozen_string_literal: true

# ═══════════════════════════════════════════════════════════════════════════
# REFERENCE IMPLEMENTATION — the verified-joining screen (copy me!)
# ═══════════════════════════════════════════════════════════════════════════
#
# Verified joining is deliberately BYO-UI: the gem ships the mechanism
# (JoinFlow, JoinState, the models) and the HOST ships routes + controllers +
# views, because every product's join screen carries its own brand and
# funnel. This controller is the canonical wiring to start from:
#
#   - ONE screen at GET /orgs/:organization_id/join renders whichever state
#     the viewer is in (entry → verifying → pending → member) via JoinState.
#   - ONE action funnels every join input through JoinFlow.attempt — no
#     rescue ladders; Result.outcome/reason drive the render.
#
# ⚠️ PRODUCTION CHECKLIST for your copy (the gem cannot do these for you):
#   1. REQUIRE AUTHENTICATION — every action here assumes a signed-in user
#      (JoinFlow needs one). This demo auto-creates a user per visitor; your
#      copy needs its own guard, e.g. `before_action :authenticate_user!`.
#   2. RATE-LIMIT these endpoints — code redemption and code verification
#      are enumeration surfaces. Rails 8 built-in, e.g.:
#        rate_limit to: 10, within: 1.hour, by: -> { current_user.id }, only: :create
#      (https://api.rubyonrails.org/classes/ActionController/RateLimiting.html)
#   3. Keep the generic error copy for unknown codes (JoinFlow already
#      collapses unknown/revoked/expired/foreign codes into one reason —
#      don't "improve" it into an oracle).
#   4. Add your product's consent/disclosure copy to the entry state.
class JoinsController < ApplicationController
  before_action :set_organization

  # The adaptive join screen: JoinState decides which state renders.
  def show
    @state = Organizations::JoinState.for(user: current_user, organization: @organization)
  end

  # Every join input lands here: a code, an email for the challenge, the
  # typed 6-digit verification code, or nothing (request to join).
  def create
    result = Organizations::JoinFlow.attempt(
      user: current_user,
      organization: @organization,
      code: params[:code].presence,
      email: params[:email].presence,
      verification_code: params[:verification_code].presence,
      message: params[:message].presence
    )

    if result.member?
      redirect_to join_path(@organization), notice: "Welcome to #{@organization.name}!"
    else
      # Failed or intermediate states re-render the screen; JoinState prefers
      # the fresh result's records over stale association caches.
      @state = Organizations::JoinState.for(user: current_user, organization: @organization, result: result)
      flash.now[:alert] = @state.error_message if @state.error_message
      render :show, status: (result.failed? ? :unprocessable_entity : :ok)
    end
  end

  # The user cancels their own pending request.
  def withdraw
    current_user.pending_join_request_for(@organization)&.withdraw!
    redirect_to join_path(@organization), notice: "Request withdrawn."
  end

  private

  def set_organization
    @organization = Organizations::Organization.find(params[:organization_id])
  end
end
