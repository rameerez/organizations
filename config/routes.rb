# frozen_string_literal: true

Organizations::Engine.routes.draw do
  # Organization switching
  # POST /organizations/switch/:id
  post "organizations/switch/:id", to: "switch#create", as: :switch_organization

  # Invitation acceptance (public routes with token)
  # GET  /invitations/:token        → View invitation details
  # POST /invitations/:token/accept → Accept the invitation
  get "invitations/:token", to: "invitations#show", as: :invitation
  post "invitations/:token/accept", to: "invitations#accept", as: :accept_invitation

  # Organization management
  # All operations are scoped to current_organization (from session)
  resources :organizations, only: [:index, :show, :new, :create, :edit, :update, :destroy]

  # Membership management (scoped to current_organization)
  # These are flat routes - the organization is determined by session, not URL
  resources :memberships, only: [:index, :update, :destroy]

  # Invitation management (scoped to current_organization)
  # These are flat routes - the organization is determined by session, not URL
  resources :invitations, only: [:index, :new, :create, :destroy], as: :organization_invitations do
    member do
      post :resend
    end
  end
end
