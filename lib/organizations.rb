# frozen_string_literal: true

require_relative "organizations/version"
require_relative "organizations/engine" if defined?(Rails::Engine)

module Organizations
  # === Error Classes ===

  # Base error class for all Organizations errors
  class Error < StandardError; end

  # Configuration errors
  class ConfigurationError < Error; end

  # Authorization errors - raised when user doesn't have permission
  class NotAuthorized < Error
    attr_reader :permission, :organization, :user

    def initialize(message = nil, permission: nil, organization: nil, user: nil)
      super(message)
      @permission = permission
      @organization = organization
      @user = user
    end
  end

  # Membership errors - raised when user is not a member
  class NotAMember < Error
    attr_reader :organization, :user

    def initialize(message = nil, organization: nil, user: nil)
      super(message)
      @organization = organization
      @user = user
    end
  end

  # Invitation errors
  class InvitationError < Error; end
  class InvitationExpired < InvitationError; end
  class InvitationAlreadyAccepted < InvitationError; end
  class InvitationEmailMismatch < InvitationError; end

  # Join request errors (verified joining)
  class JoinRequestError < Error; end
  class JoinRequestExpired < JoinRequestError; end
  class JoinRequestAlreadyDecided < JoinRequestError; end

  # Raised (typically by the host's `on_member_joining` gate) to VETO a
  # membership that is about to be created — seat limits, member caps,
  # compliance holds. The gate dispatches strictly inside the creating
  # transaction, so raising this rolls everything back cleanly: no membership
  # row, join requests stay pending (resumable), invitations stay unaccepted.
  # Raising without a message gets the localized default
  # (organizations.errors.membership_vetoed).
  class MembershipVetoed < Error
    def initialize(message = nil)
      super(message || Organizations.t(:"errors.membership_vetoed"))
    end
  end

  # Join code errors (verified joining)
  # JoinCodeInvalid covers unknown, revoked, and expired codes — hosts should
  # show the same generic message for all three (don't leak which codes exist).
  class JoinCodeError < Error; end
  class JoinCodeInvalid < JoinCodeError; end
  class JoinCodeExhausted < JoinCodeInvalid; end

  # Email verification errors (verified joining)
  class VerificationError < JoinRequestError; end
  class VerificationEmailNotEligible < VerificationError; end
  class VerificationEmailAlreadyClaimed < VerificationError; end
  class VerificationCodeInvalid < VerificationError; end
  class VerificationCodeExpired < VerificationError; end
  class VerificationAttemptsExceeded < VerificationError; end
  class VerificationThrottled < VerificationError; end

  # === Autoload Components (lazy loading) ===

  autoload :Configuration, "organizations/configuration"
  autoload :ControllerHelpers, "organizations/controller_helpers"
  autoload :ViewHelpers, "organizations/view_helpers"
  autoload :Roles, "organizations/roles"
  autoload :Callbacks, "organizations/callbacks"
  autoload :CallbackContext, "organizations/callback_context"
  autoload :ActsAsTenantIntegration, "organizations/acts_as_tenant_integration"
  autoload :TestHelpers, "organizations/test_helpers"
  autoload :CurrentUserResolution, "organizations/current_user_resolution"
  autoload :InvitationAcceptanceResult, "organizations/invitation_acceptance_result"
  autoload :InvitationAcceptanceFailure, "organizations/invitation_acceptance_failure"
  autoload :EmailNormalizer, "organizations/email_normalizer"
  autoload :JoinFlow, "organizations/join_flow"
  autoload :JoinState, "organizations/join_state"

  # Alias for README compatibility: `include Organizations::Controller`
  Controller = ControllerHelpers

  # Models module kept for backwards compatibility
  module Models
    module Concerns
      # HasOrganizations is always autoloaded from lib/ because:
      # 1. It's extended onto ActiveRecord::Base at boot time via the engine initializer
      # 2. It doesn't define any associations that point to reloadable classes
      autoload :HasOrganizations, "organizations/models/concerns/has_organizations"
    end
  end

  # In Rails apps, Organization/Membership/Invitation models are loaded from
  # app/models via Zeitwerk (reload-safe). This is critical because these models
  # define associations to other reloadable classes (like Pay::Customer), and we
  # need the association reflections to point to current class objects after reload.
  #
  # In non-Rails environments (plain Ruby, tests without Rails), use lib-based autoloading.
  #
  # NOTE on the guard: Rails::Engine is defined when `railties` has been required.
  # In typical usage, this means a Rails app context where Zeitwerk manages app/models.
  # Edge cases (e.g., requiring railties without a full app) are rare and would need
  # custom setup anyway. For standard Rails apps, this correctly delegates to Zeitwerk.
  #
  # IMPORTANT: The app/models/*.rb entrypoints delegate to lib/ via `load`. This means
  # Zeitwerk watches the entrypoint files, not the lib/ files. Changes to lib/ model
  # files during gem development won't auto-reload; restart the server in that case.
  unless defined?(Rails::Engine)
    autoload :Organization, "organizations/models/organization"
    autoload :Membership, "organizations/models/membership"
    autoload :Invitation, "organizations/models/invitation"
    autoload :Domain, "organizations/models/domain"
    autoload :JoinCode, "organizations/models/join_code"
    autoload :AllowlistEntry, "organizations/models/allowlist_entry"
    autoload :JoinRequest, "organizations/models/join_request"

    # Non-Rails contexts (plain ActiveRecord, the gem's own test suite) don't
    # get the Rails engine's automatic `config/locales` pickup, so register
    # the gem's locale files directly. `|=` keeps this idempotent. In Rails
    # apps the engine handles it (Rails::Engine adds paths["config/locales"]
    # to I18n.load_path — https://guides.rubyonrails.org/engines.html).
    # I18n itself is always available: it's a hard dependency of
    # activesupport, which this gem depends on.
    I18n.load_path |= Dir[File.expand_path("../config/locales/*.yml", __dir__)]
  end

  class << self
    attr_writer :configuration

    # Get the configuration instance
    # @return [Configuration]
    def configuration
      @configuration ||= Configuration.new
    end

    # Configure the gem
    # @yield [Configuration] The configuration instance
    #
    # @example
    #   Organizations.configure do |config|
    #     config.always_create_personal_organization_for_each_user = true
    #     config.invitation_expiry = 7.days
    #   end
    #
    def configure
      yield(configuration)
      configuration.validate!
    end

    # Reset configuration to defaults
    # Primarily used in tests
    def reset_configuration!
      @configuration = nil
      Roles.reset!
    end

    # Get the roles module
    # @return [Module]
    def roles
      Roles
    end

    # The host's user model class name (config.user_class, default "User").
    # Used as `class_name:` at association-definition time in the gem's
    # models — they load AFTER initializers in Rails (Zeitwerk shims) and on
    # first constant reference in plain Ruby, so a configured value is
    # visible as long as hosts configure before touching the models.
    # @return [String]
    def user_class_name
      configuration.user_class
    end

    # The host's user model class (constantized user_class_name).
    # @return [Class]
    def user_class
      user_class_name.constantize
    end

    # Resolve a gem string through I18n under the `organizations.` namespace.
    # This is the ONE door every user-facing string the gem produces goes
    # through — error messages, labels, mailer copy. en.yml is the catalog
    # SSOT (no inline English defaults on purpose: a missing key renders as
    # "Translation missing: …", a loud and findable bug, instead of silently
    # drifting from the catalog).
    #
    # Hosts override any key the standard Rails way — app locale files load
    # after engine locale files, so the host's value wins.
    #
    # @param key [String, Symbol] key under the `organizations.` scope,
    #   e.g. :"errors.join_code_invalid" or "roles.owner"
    # @param options [Hash] I18n options (interpolations, :locale, :default…)
    # @return [String]
    def translate(key, **options)
      I18n.t(key, scope: :organizations, **options)
    end
    alias t translate
  end
end
