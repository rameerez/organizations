Rails.application.routes.draw do
  # Mount the organizations engine
  mount Organizations::Engine => "/"

  # organizations: join and access screens (rails g organizations:join)
  scope "orgs/:organization_id", as: :organization do
    get    "join", to: "organization_joins#show", as: :join
    post   "join", to: "organization_joins#create"
    delete "join", to: "organization_joins#withdraw", as: :withdraw_join

    get    "access", to: "organization_access#show", as: :access
    post   "access/domains", to: "organization_access#add_domain", as: :access_domains
    patch  "access/domains/:domain_id", to: "organization_access#update_domain", as: :access_domain
    delete "access/domains/:domain_id", to: "organization_access#remove_domain"
    post   "access/domains/:domain_id/verification", to: "organization_access#start_domain_verification", as: :access_domain_verification
    post   "access/domains/:domain_id/verify", to: "organization_access#verify_domain", as: :verify_access_domain
    post   "access/codes", to: "organization_access#generate_code", as: :access_codes
    post   "access/codes/:code_id/revoke", to: "organization_access#revoke_code", as: :revoke_access_code
    post   "access/allowlist", to: "organization_access#import_allowlist", as: :access_allowlist
    delete "access/allowlist/:entry_id", to: "organization_access#remove_allowlist_entry", as: :access_allowlist_entry
    post   "access/requests/:request_id/approve", to: "organization_access#approve_request", as: :approve_access_request
    post   "access/requests/:request_id/reject", to: "organization_access#reject_request", as: :reject_access_request
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
