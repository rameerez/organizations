# frozen_string_literal: true

Organizations::Engine.routes.draw do
  # TODO: Define routes
  # resources :organizations do
  #   resources :memberships, only: [:index, :update, :destroy]
  #   resources :invitations, only: [:new, :create, :destroy]
  # end
  #
  # # Accept invitation (public route with token)
  # get "invitations/:token", to: "invitations#show", as: :accept_invitation
  # post "invitations/:token/accept", to: "invitations#accept"
  #
  # # Organization switching
  # post "switch/:id", to: "organizations#switch", as: :switch_organization
end
