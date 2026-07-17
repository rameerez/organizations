Rails.application.routes.draw do
  # Mount the organizations engine
  mount Organizations::Engine => "/"

  # ── Verified joining: REFERENCE host routes (BYO-UI — copy these) ──
  # The join screen (all four states at one URL) + the user's own actions.
  get    "orgs/:organization_id/join", to: "joins#show", as: :join
  post   "orgs/:organization_id/join", to: "joins#create"
  delete "orgs/:organization_id/join", to: "joins#withdraw", as: :withdraw_join

  # The org-admin Access surface (instruments + request queue), URL-scoped
  # via Organizations::OrganizationScoped.
  scope "orgs/:organization_id" do
    get    "access", to: "access#show", as: :access
    post   "access/domains", to: "access#add_domain", as: :add_access_domain
    delete "access/domains/:domain_id", to: "access#remove_domain", as: :remove_access_domain
    post   "access/codes", to: "access#generate_code", as: :generate_access_code
    post   "access/codes/:code_id/revoke", to: "access#revoke_code", as: :revoke_access_code
    post   "access/allowlist", to: "access#import_allowlist", as: :import_access_allowlist
    post   "access/requests/:request_id/approve", to: "access#approve_request", as: :approve_access_request
    post   "access/requests/:request_id/reject", to: "access#reject_request", as: :reject_access_request
  end

  # Demo home page
  root "home#index"

  # Demo actions (simulated SaaS actions to show permission handling)
  post "/demo_action" => "home#demo_action", as: :demo_action

  # Demo user switching (for testing multi-user flows)
  post "/switch_user" => "application#switch_user", as: :switch_user

  # Allow visitors to reset their demo state
  get "/reset" => "application#reset_demo!", as: :reset_demo

  # Health check
  get "up" => "rails/health#show", as: :rails_health_check
end
