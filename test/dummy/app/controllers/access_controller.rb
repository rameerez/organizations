# frozen_string_literal: true

# ═══════════════════════════════════════════════════════════════════════════
# REFERENCE IMPLEMENTATION — verified-joining ADMIN surfaces (copy me!)
# ═══════════════════════════════════════════════════════════════════════════
#
# The org-admin side of verified joining: manage the instruments (email
# domains, join codes, allowlist roster) and decide pending join requests.
# Everything mutates through gem APIs — never raw row writes.
#
# This controller demonstrates Organizations::OrganizationScoped, the
# URL-scoped addressing mode: the org comes from the URL, the viewer's role
# is gated per-organization, and unknown orgs / strangers / under-role
# members all 404 identically (no existence oracle) — the right posture for
# customer-facing admin portals. Session-scoped engine controllers and this
# URL-scoped surface coexist in one app.
class AccessController < ApplicationController
  include Organizations::OrganizationScoped

  self.organization_param = :organization_id
  require_organization_role :admin

  helper_method :organization

  def show
    @domains = organization.domains.order(:domain)
    @join_codes = organization.join_codes.order(created_at: :desc)
    @allowlist_entries = organization.allowlist_entries.unclaimed.order(:email)
    @pending_requests = organization.join_requests.pending.includes(:user).order(created_at: :asc)
  end

  def add_domain
    organization.add_domain!(params[:domain].to_s)
    redirect_to access_path(organization), notice: "Domain added."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to access_path(organization), alert: e.message
  end

  def remove_domain
    organization.domains.find(params[:domain_id]).destroy!
    redirect_to access_path(organization), notice: "Domain removed. Existing members keep their provenance."
  end

  def generate_code
    code = organization.generate_join_code!(
      label: params[:label].presence,
      auto_approve: params[:auto_approve] == "1",
      created_by: current_user
    )
    redirect_to access_path(organization), notice: "Code #{code.display_code} created."
  end

  def revoke_code
    organization.join_codes.find(params[:code_id]).revoke!
    redirect_to access_path(organization), notice: "Code revoked. Rotation = revoke + create a new one."
  end

  def import_allowlist
    emails = params[:emails].to_s.split(/[\s,;]+/).reject(&:blank?)
    imported = organization.import_allowlist!(emails, source: "manual")
    redirect_to access_path(organization), notice: "#{imported.size} address(es) added to the allowlist."
  end

  # Approve/reject go through the gem's row-locked APIs. Hard caps (seat
  # limits) belong in config.on_member_joining — the strict gate covers this
  # path too, so there is NO pre-check to duplicate here.
  def approve_request
    request = organization.join_requests.find(params[:request_id])
    organization.approve_join_request!(request, approved_by: current_user)
    redirect_to access_path(organization), notice: "#{request.user.email} is now a member."
  rescue Organizations::MembershipVetoed, Organizations::JoinRequestError => e
    redirect_to access_path(organization), alert: e.message
  end

  def reject_request
    request = organization.join_requests.find(params[:request_id])
    organization.reject_join_request!(request, rejected_by: current_user, reason: params[:reason].presence)
    redirect_to access_path(organization), notice: "Request rejected."
  rescue Organizations::JoinRequestError => e
    redirect_to access_path(organization), alert: e.message
  end

  private

  def organization
    current_scoped_organization
  end
end
