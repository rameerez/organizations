# frozen_string_literal: true

Organizations::Engine.routes.draw do
  # Organization switching
  # POST /organizations/switch/:id
  post "organizations/switch/:id", to: "switch#create", as: :switch_organization

  # Organization management
  # All operations are scoped to current_organization (from session)
  resources :organizations, only: [:index, :show, :new, :create, :edit, :update, :destroy]

  # Membership management (scoped to current_organization)
  # These are flat routes - the organization is determined by session, not URL
  resources :memberships, only: [:index, :update, :destroy] do
    member do
      post :transfer_ownership
    end
  end

  # Invitation management (scoped to current_organization)
  # These are flat routes - the organization is determined by session, not URL
  # NOTE: Must come BEFORE token-based routes so /invitations/new doesn't match /:token
  resources :invitations, only: [:index, :new, :create, :destroy], as: :organization_invitations do
    member do
      post :resend
    end
  end

  # Invitation acceptance (public routes with token)
  # These use PublicInvitationsController which inherits from a minimal base controller
  # to avoid host app filters that might enforce authentication.
  # GET  /invitations/:token        → View invitation details
  # POST /invitations/:token/accept → Accept the invitation
  # NOTE: These must come AFTER resourceful routes to avoid matching "new" as a token
  get "invitations/:token", to: "public_invitations#show", as: :invitation
  post "invitations/:token/accept", to: "public_invitations#accept", as: :accept_invitation
end
