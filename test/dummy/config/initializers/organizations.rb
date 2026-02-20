# frozen_string_literal: true

Organizations.configure do |config|
  # === Authentication ===
  # Method that returns the current user (default: :current_user)
  config.current_user_method = :current_user

  # === Auto-creation ===
  # Don't auto-create orgs - users must create or be invited (default behavior)
  # config.always_create_personal_organization_for_each_user = false

  # Name for auto-created organizations (only used if always_create_personal_organization_for_each_user is true)
  config.default_organization_name = ->(user) { "My Organization" }

  # === Invitations ===
  # How long invitations are valid
  config.invitation_expiry = 7.days

  # === Engine Controllers ===
  # Base controller for public routes (invitation acceptance, etc.)
  # Uses minimal base to avoid host app authentication filters
  config.public_controller = "ActionController::Base"

  # === Handlers ===
  # Called when authorization fails
  config.on_unauthorized do |context|
    redirect_to "/", alert: "You don't have permission to do that."
  end

  # Called when no organization is set
  config.on_no_organization do |context|
    redirect_to new_organization_path, alert: "Please create or join an organization first."
  end
end
