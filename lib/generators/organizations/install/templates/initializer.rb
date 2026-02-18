# frozen_string_literal: true

Organizations.configure do |config|
  # ============================================================================
  # PERSONAL ORGANIZATIONS
  # ============================================================================

  # Automatically create a personal organization when a user signs up.
  # The organization will be named after the user (e.g., "John's Organization").
  # Set to false if your onboarding flow creates organizations separately.
  # Default: true
  # config.create_personal_organization = true

  # ============================================================================
  # ORGANIZATION REQUIREMENTS
  # ============================================================================

  # Require users to belong to at least one organization.
  # When true, users cannot leave their last organization.
  # Set to false to allow users to exist without any organization.
  # Default: true
  # config.require_organization = true

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
  # Custom roles can be defined using the `define_organization_role` DSL
  # in your User model. See README for examples.

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
