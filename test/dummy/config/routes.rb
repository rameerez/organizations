Rails.application.routes.draw do
  # Mount the organizations engine
  mount Organizations::Engine => "/"

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
