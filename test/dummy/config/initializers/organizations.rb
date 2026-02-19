# frozen_string_literal: true

Organizations.configure do |config|
  # === Authentication ===
  # Method that returns the current user (default: :current_user)
  config.current_user_method = :current_user

  # === Auto-creation ===
  # Don't auto-create orgs - users must create or be invited (default behavior)
  # config.create_personal_organization = false

  # Name for auto-created organizations (only used if create_personal_organization is true)
  config.personal_organization_name = ->(user) { "My Organization" }

  # === Invitations ===
  # How long invitations are valid
  config.invitation_expiry = 7.days

  # === Handlers ===
  # Called when authorization fails
  config.on_unauthorized do |context|
    redirect_to main_app.root_path, alert: "You don't have permission to do that."
  end

  # Called when no organization is set
  config.on_no_organization do |context|
    redirect_to new_organization_path, alert: "Please create or join an organization first."
  end
end
