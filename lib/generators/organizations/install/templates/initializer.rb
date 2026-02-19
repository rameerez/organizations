# frozen_string_literal: true

Organizations.configure do |config|
  # ============================================================================
  # PERSONAL ORGANIZATIONS
  # ============================================================================

  # Automatically create a personal organization when a user signs up.
  # The organization will be named after the user (e.g., "John's Organization").
  # Set to true if you want every user to have their own organization on signup.
  # Default: false (invite-to-join flow)
  # config.create_personal_organization = false

  # ============================================================================
  # ORGANIZATION REQUIREMENTS
  # ============================================================================

  # Require users to belong to at least one organization.
  # When true, users cannot leave their last organization.
  # Set to true if users should always have an organization.
  # Default: false (users can exist without any organization)
  # config.require_organization = false

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
  # URL SLUGS
  # ============================================================================

  # Organizations use slugifiable for URL-friendly slugs.
  # Slugs are auto-generated from the organization name.
  # Example: "Acme Corp" → "acme-corp"
  #
  # To customize slug generation, configure slugifiable separately.
end
