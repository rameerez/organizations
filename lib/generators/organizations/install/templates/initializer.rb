# frozen_string_literal: true

Organizations.configure do |config|
  # ============================================================================
  # PERSONAL ORGANIZATIONS
  # ============================================================================

  # Automatically create a personal organization when a user signs up.
  # The organization will be named after the user (e.g., "John's Organization").
  # Set to true if you want every user to have their own organization on signup.
  # Default: false (invite-to-join flow)
  # config.always_create_personal_organization_for_each_user = false

  # ============================================================================
  # ORGANIZATION REQUIREMENTS
  # ============================================================================

  # Require users to belong to at least one organization.
  # When true, users cannot leave their last organization.
  # Set to true if users should always have an organization.
  # Default: false (users can exist without any organization)
  # config.always_require_users_to_belong_to_one_organization = false

  # ============================================================================
  # INVITATIONS
  # ============================================================================

  # How long invitation tokens remain valid before expiring.
  # Default: 7.days
  # config.invitation_expiry = 7.days

  # The default role assigned to invited users when they accept.
  # Default: :member
  # config.default_invitation_role = :member

  # ============================================================================
  # ROLES & PERMISSIONS
  # ============================================================================

  # Built-in roles (in order of hierarchy, highest to lowest):
  #   :owner  - Full control, can delete organization, transfer ownership
  #   :admin  - Can manage members, invitations, and settings
  #   :member - Standard access, can view and collaborate
  #   :viewer - Read-only access
  #
  # Custom roles can be defined using the config.roles DSL:
  #
  # config.roles do
  #   role :viewer do
  #     can :view_organization
  #     can :view_members
  #   end
  #   role :member, inherits: :viewer do
  #     can :create_resources
  #   end
  #   role :admin, inherits: :member do
  #     can :invite_members
  #     can :manage_settings
  #   end
  #   role :owner, inherits: :admin do
  #     can :manage_billing
  #     can :delete_organization
  #   end
  # end

  # ============================================================================
  # ORGANIZATION SWITCHING
  # ============================================================================

  # The session key used to store the current organization ID.
  # Default: :current_organization_id
  # config.session_key = :current_organization_id

  # ============================================================================
  # ORGANIZATIONS CONTROLLER
  # ============================================================================

  # Additional params to permit when creating/updating organizations.
  # Use this to add custom fields to organizations (e.g., support_email, logo).
  # Default: [] (only :name is permitted)
  # config.additional_organization_params = [:support_email, :billing_email]

  # Where to redirect after organization is created.
  # Can be a String path or a Proc that receives the organization.
  # Default: nil (redirects to organization show page)
  # config.after_organization_created_redirect_path = "/dashboard"
  # config.after_organization_created_redirect_path = ->(org) { "/orgs/#{org.id}/setup" }

  # ============================================================================
  # REDIRECTS
  # ============================================================================

  # Where to redirect when user has no organization.
  # Default: "/organizations/new"
  # config.redirect_path_when_no_organization = "/onboarding"

  # Optional flash messages used by the built-in no-organization handler.
  # Leave both nil to keep the default alert:
  # "Please select or create an organization."
  # config.no_organization_alert = "Please create an organization first."
  # config.no_organization_notice = "Please create or join an organization to continue."

  # ============================================================================
  # INVITATION FLOW REDIRECTS
  # ============================================================================

  # Where to redirect unauthenticated users when they try to accept an invitation.
  # Use this to customize the signup/login page for invited users.
  # Can be a String path or a Proc receiving (invitation, user).
  # Default: nil (uses new_user_registration_path or root_path)
  # config.redirect_path_when_invitation_requires_authentication = "/users/sign_up"
  # config.redirect_path_when_invitation_requires_authentication = ->(inv, _user) { "/signup?invite=#{inv.token}" }

  # Where to redirect after an invitation is accepted.
  # Can be a String path or a Proc receiving (invitation, user).
  # Default: nil (uses root_path)
  # config.redirect_path_after_invitation_accepted = "/dashboard"
  # config.redirect_path_after_invitation_accepted = ->(inv, user) { "/org/#{inv.organization_id}/welcome" }

  # Where to redirect after switching organizations.
  # Can be a String path or a Proc receiving (organization, user).
  # Default: nil (uses root_path)
  # config.redirect_path_after_organization_switched = "/dashboard"
  # config.redirect_path_after_organization_switched = ->(org, user) { "/orgs/#{org.id}?user=#{user.id}" }

  # ============================================================================
  # ENGINE CONTROLLERS
  # ============================================================================

  # Base controller for authenticated routes (default: ::ApplicationController)
  # All organization management controllers inherit from this.
  # config.parent_controller = "::ApplicationController"

  # Base controller for public routes like invitation acceptance.
  # Uses a minimal base to avoid host app filters that enforce authentication.
  # Works with Devise out of the box - no configuration needed.
  # Only override if using custom auth or needing specific inheritance.
  # Default: ActionController::Base
  # config.public_controller = "ActionController::Base"

  # Layout override for authenticated engine controllers.
  # Use this to avoid host-side layout monkey patches.
  # Default: nil (inherits host controller defaults)
  # config.authenticated_controller_layout = "dashboard"

  # Layout override for public engine controllers (invitation pages).
  # Default: nil (inherits host controller defaults)
  # config.public_controller_layout = "devise"

end
