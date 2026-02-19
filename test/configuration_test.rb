# frozen_string_literal: true

require "test_helper"

module Organizations
  class ConfigurationTest < Organizations::Test
    # ── Authentication defaults ──────────────────────────────────────

    test "current_user_method defaults to :current_user" do
      assert_equal :current_user, Organizations.configuration.current_user_method
    end

    test "authenticate_user_method defaults to :authenticate_user!" do
      assert_equal :authenticate_user!, Organizations.configuration.authenticate_user_method
    end

    test "current_user_method can be customized" do
      Organizations.configure do |config|
        config.current_user_method = :logged_in_user
      end

      assert_equal :logged_in_user, Organizations.configuration.current_user_method
    end

    test "authenticate_user_method can be customized" do
      Organizations.configure do |config|
        config.authenticate_user_method = :require_login!
      end

      assert_equal :require_login!, Organizations.configuration.authenticate_user_method
    end

    # ── Auto-creation defaults ───────────────────────────────────────

    test "always_create_personal_organization_for_each_user defaults to false" do
      assert_equal false, Organizations.configuration.always_create_personal_organization_for_each_user
    end

    test "default_organization_name defaults to 'Personal'" do
      assert_equal "Personal", Organizations.configuration.default_organization_name
    end

    test "always_create_personal_organization_for_each_user can be set to true" do
      Organizations.configure do |config|
        config.always_create_personal_organization_for_each_user = true
      end

      assert_equal true, Organizations.configuration.always_create_personal_organization_for_each_user
    end

    test "default_organization_name can be a string" do
      Organizations.configure do |config|
        config.default_organization_name = "My Workspace"
      end

      assert_equal "My Workspace", Organizations.configuration.default_organization_name
    end

    test "default_organization_name can be a proc" do
      Organizations.configure do |config|
        config.default_organization_name = ->(user) { "#{user.name}'s Workspace" }
      end

      assert_instance_of Proc, Organizations.configuration.default_organization_name
    end

    # ── resolve_default_organization_name ────────────────────────────

    test "resolve_default_organization_name returns string directly" do
      Organizations.configure do |config|
        config.default_organization_name = "Team Space"
      end

      user = create_user!(name: "Alice")
      assert_equal "Team Space", Organizations.configuration.resolve_default_organization_name(user)
    end

    test "resolve_default_organization_name calls proc with user" do
      Organizations.configure do |config|
        config.default_organization_name = ->(user) { "#{user.name}'s Workspace" }
      end

      user = create_user!(name: "Alice")
      assert_equal "Alice's Workspace", Organizations.configuration.resolve_default_organization_name(user)
    end

    test "resolve_default_organization_name falls back to Personal for unknown types" do
      config = Configuration.new
      config.default_organization_name = 42

      assert_equal "Personal", config.resolve_default_organization_name(nil)
    end

    # ── Invitation defaults ──────────────────────────────────────────

    test "invitation_expiry defaults to 7 days" do
      assert_equal 7.days, Organizations.configuration.invitation_expiry
    end

    test "invitation_mailer defaults to Organizations::InvitationMailer" do
      assert_equal "Organizations::InvitationMailer", Organizations.configuration.invitation_mailer
    end

    test "default_invitation_role defaults to :member" do
      assert_equal :member, Organizations.configuration.default_invitation_role
    end

    test "invitation_expiry can be customized" do
      Organizations.configure do |config|
        config.invitation_expiry = 14.days
      end

      assert_equal 14.days, Organizations.configuration.invitation_expiry
    end

    test "invitation_mailer can be customized" do
      Organizations.configure do |config|
        config.invitation_mailer = "CustomInvitationMailer"
      end

      assert_equal "CustomInvitationMailer", Organizations.configuration.invitation_mailer
    end

    test "default_invitation_role can be customized" do
      Organizations.configure do |config|
        config.default_invitation_role = :viewer
      end

      assert_equal :viewer, Organizations.configuration.default_invitation_role
    end

    # ── Limits defaults ──────────────────────────────────────────────

    test "max_organizations_per_user defaults to nil (unlimited)" do
      assert_nil Organizations.configuration.max_organizations_per_user
    end

    test "max_organizations_per_user can be set to a number" do
      Organizations.configure do |config|
        config.max_organizations_per_user = 5
      end

      assert_equal 5, Organizations.configuration.max_organizations_per_user
    end

    # ── Onboarding defaults ──────────────────────────────────────────

    test "always_require_users_to_belong_to_one_organization defaults to false" do
      assert_equal false, Organizations.configuration.always_require_users_to_belong_to_one_organization
    end

    test "always_require_users_to_belong_to_one_organization can be set to true" do
      Organizations.configure do |config|
        config.always_require_users_to_belong_to_one_organization = true
      end

      assert_equal true, Organizations.configuration.always_require_users_to_belong_to_one_organization
    end

    # ── Redirect defaults ────────────────────────────────────────────

    test "redirect_path_when_no_organization defaults to /organizations/new" do
      assert_equal "/organizations/new", Organizations.configuration.redirect_path_when_no_organization
    end

    test "redirect_path_when_no_organization can be customized" do
      Organizations.configure do |config|
        config.redirect_path_when_no_organization = "/onboarding"
      end

      assert_equal "/onboarding", Organizations.configuration.redirect_path_when_no_organization
    end

    # ── Session/Switching defaults ───────────────────────────────────

    test "session_key defaults to :current_organization_id" do
      assert_equal :current_organization_id, Organizations.configuration.session_key
    end

    # ── Engine defaults ──────────────────────────────────────────────

    test "parent_controller defaults to ::ApplicationController" do
      assert_equal "::ApplicationController", Organizations.configuration.parent_controller
    end

    # ── Handler callbacks ────────────────────────────────────────────

    test "unauthorized_handler defaults to nil" do
      assert_nil Organizations.configuration.unauthorized_handler
    end

    test "no_organization_handler defaults to nil" do
      assert_nil Organizations.configuration.no_organization_handler
    end

    test "on_unauthorized stores handler block" do
      handler = proc { |context| "unauthorized: #{context}" }

      Organizations.configure do |config|
        config.on_unauthorized(&handler)
      end

      assert_equal handler, Organizations.configuration.unauthorized_handler
    end

    test "on_no_organization stores handler block" do
      handler = proc { |context| "no org: #{context}" }

      Organizations.configure do |config|
        config.on_no_organization(&handler)
      end

      assert_equal handler, Organizations.configuration.no_organization_handler
    end

    test "on_unauthorized handler receives context when called" do
      received_context = nil

      Organizations.configure do |config|
        config.on_unauthorized do |context|
          received_context = context
        end
      end

      Organizations.configuration.unauthorized_handler.call({ user: "test", permission: :admin })
      assert_equal({ user: "test", permission: :admin }, received_context)
    end

    test "on_no_organization handler receives context when called" do
      received_context = nil

      Organizations.configure do |config|
        config.on_no_organization do |context|
          received_context = context
        end
      end

      Organizations.configuration.no_organization_handler.call({ user: "test" })
      assert_equal({ user: "test" }, received_context)
    end

    test "on_unauthorized does nothing without a block" do
      config = Configuration.new
      config.on_unauthorized
      assert_nil config.unauthorized_handler
    end

    test "on_no_organization does nothing without a block" do
      config = Configuration.new
      config.on_no_organization
      assert_nil config.no_organization_handler
    end

    # ── Lifecycle callbacks ──────────────────────────────────────────

    test "on_organization_created_callback defaults to nil" do
      assert_nil Organizations.configuration.on_organization_created_callback
    end

    test "on_member_invited_callback defaults to nil" do
      assert_nil Organizations.configuration.on_member_invited_callback
    end

    test "on_member_joined_callback defaults to nil" do
      assert_nil Organizations.configuration.on_member_joined_callback
    end

    test "on_member_removed_callback defaults to nil" do
      assert_nil Organizations.configuration.on_member_removed_callback
    end

    test "on_role_changed_callback defaults to nil" do
      assert_nil Organizations.configuration.on_role_changed_callback
    end

    test "on_ownership_transferred_callback defaults to nil" do
      assert_nil Organizations.configuration.on_ownership_transferred_callback
    end

    test "on_organization_created stores callback block" do
      callback = proc { |ctx| ctx }

      Organizations.configure do |config|
        config.on_organization_created(&callback)
      end

      assert_equal callback, Organizations.configuration.on_organization_created_callback
    end

    test "on_member_invited stores callback block" do
      callback = proc { |ctx| ctx }

      Organizations.configure do |config|
        config.on_member_invited(&callback)
      end

      assert_equal callback, Organizations.configuration.on_member_invited_callback
    end

    test "on_member_joined stores callback block" do
      callback = proc { |ctx| ctx }

      Organizations.configure do |config|
        config.on_member_joined(&callback)
      end

      assert_equal callback, Organizations.configuration.on_member_joined_callback
    end

    test "on_member_removed stores callback block" do
      callback = proc { |ctx| ctx }

      Organizations.configure do |config|
        config.on_member_removed(&callback)
      end

      assert_equal callback, Organizations.configuration.on_member_removed_callback
    end

    test "on_role_changed stores callback block" do
      callback = proc { |ctx| ctx }

      Organizations.configure do |config|
        config.on_role_changed(&callback)
      end

      assert_equal callback, Organizations.configuration.on_role_changed_callback
    end

    test "on_ownership_transferred stores callback block" do
      callback = proc { |ctx| ctx }

      Organizations.configure do |config|
        config.on_ownership_transferred(&callback)
      end

      assert_equal callback, Organizations.configuration.on_ownership_transferred_callback
    end

    test "lifecycle callbacks do nothing without a block" do
      config = Configuration.new
      config.on_organization_created
      config.on_member_invited
      config.on_member_joined
      config.on_member_removed
      config.on_role_changed
      config.on_ownership_transferred

      assert_nil config.on_organization_created_callback
      assert_nil config.on_member_invited_callback
      assert_nil config.on_member_joined_callback
      assert_nil config.on_member_removed_callback
      assert_nil config.on_role_changed_callback
      assert_nil config.on_ownership_transferred_callback
    end

    # ── Roles DSL ────────────────────────────────────────────────────

    test "custom_roles_definition defaults to nil" do
      assert_nil Organizations.configuration.custom_roles_definition
    end

    test "roles DSL stores block as custom_roles_definition" do
      Organizations.configure do |config|
        config.roles do
          role :viewer do
            can :view_organization
          end
        end
      end

      assert_instance_of Proc, Organizations.configuration.custom_roles_definition
    end

    test "roles DSL calls Roles.reset! to apply changes" do
      reset_called = false
      Organizations::Roles.stub(:reset!, -> { reset_called = true }) do
        config = Configuration.new
        config.roles do
          role :viewer do
            can :view_organization
          end
        end
      end

      assert reset_called
    end

    test "roles DSL does nothing without a block" do
      config = Configuration.new
      config.roles
      assert_nil config.custom_roles_definition
    end

    test "roles DSL with inheritance defines parent-child relationship" do
      Organizations.configure do |config|
        config.roles do
          role :viewer do
            can :view_organization
          end
          role :member, inherits: :viewer do
            can :create_resources
          end
        end
      end

      permissions = Roles.permissions_for(:member)
      assert_includes permissions, :view_organization
      assert_includes permissions, :create_resources
    end

    test "roles DSL with multiple permissions on a single role" do
      Organizations.configure do |config|
        config.roles do
          role :viewer do
            can :view_organization
            can :view_members
          end
        end
      end

      permissions = Roles.permissions_for(:viewer)
      assert_includes permissions, :view_organization
      assert_includes permissions, :view_members
    end

    # ── Organizations.configure ──────────────────────────────────────

    test "configure yields configuration object" do
      yielded = nil

      Organizations.configure do |config|
        yielded = config
      end

      assert_instance_of Configuration, yielded
      assert_same Organizations.configuration, yielded
    end

    test "configure calls validate! after block" do
      assert_raises(ConfigurationError) do
        Organizations.configure do |config|
          config.current_user_method = "not_a_symbol"
        end
      end
    end

    test "configure allows setting multiple options at once" do
      Organizations.configure do |config|
        config.current_user_method = :signed_in_user
        config.always_create_personal_organization_for_each_user = false
        config.invitation_expiry = 30.days
        config.max_organizations_per_user = 10
        config.always_require_users_to_belong_to_one_organization = false
        config.redirect_path_when_no_organization = "/setup"
      end

      config = Organizations.configuration
      assert_equal :signed_in_user, config.current_user_method
      assert_equal false, config.always_create_personal_organization_for_each_user
      assert_equal 30.days, config.invitation_expiry
      assert_equal 10, config.max_organizations_per_user
      assert_equal false, config.always_require_users_to_belong_to_one_organization
      assert_equal "/setup", config.redirect_path_when_no_organization
    end

    # ── reset_configuration! ─────────────────────────────────────────

    test "reset_configuration! restores all defaults" do
      Organizations.configure do |config|
        config.current_user_method = :signed_in_user
        config.authenticate_user_method = :require_login!
        config.always_create_personal_organization_for_each_user = false
        config.default_organization_name = "Custom"
        config.invitation_expiry = 30.days
        config.invitation_mailer = "CustomMailer"
        config.max_organizations_per_user = 5
        config.always_require_users_to_belong_to_one_organization = false
        config.redirect_path_when_no_organization = "/custom"
      end

      Organizations.reset_configuration!

      config = Organizations.configuration
      assert_equal :current_user, config.current_user_method
      assert_equal :authenticate_user!, config.authenticate_user_method
      assert_equal false, config.always_create_personal_organization_for_each_user
      assert_equal "Personal", config.default_organization_name
      assert_equal 7.days, config.invitation_expiry
      assert_equal "Organizations::InvitationMailer", config.invitation_mailer
      assert_nil config.max_organizations_per_user
      assert_equal false, config.always_require_users_to_belong_to_one_organization
      assert_equal "/organizations/new", config.redirect_path_when_no_organization
    end

    test "reset_configuration! clears custom roles" do
      Organizations.configure do |config|
        config.roles do
          role :viewer do
            can :custom_permission
          end
        end
      end

      Organizations.reset_configuration!

      assert_nil Organizations.configuration.custom_roles_definition
    end

    test "reset_configuration! clears handlers and callbacks" do
      Organizations.configure do |config|
        config.on_unauthorized { |ctx| ctx }
        config.on_no_organization { |ctx| ctx }
        config.on_organization_created { |ctx| ctx }
        config.on_member_invited { |ctx| ctx }
      end

      Organizations.reset_configuration!

      config = Organizations.configuration
      assert_nil config.unauthorized_handler
      assert_nil config.no_organization_handler
      assert_nil config.on_organization_created_callback
      assert_nil config.on_member_invited_callback
    end

    test "reset_configuration! creates a fresh configuration instance" do
      original = Organizations.configuration

      Organizations.reset_configuration!

      refute_same original, Organizations.configuration
    end

    # ── Validation ───────────────────────────────────────────────────

    test "validate! raises if current_user_method is not a Symbol" do
      assert_raises(ConfigurationError) do
        Organizations.configure do |config|
          config.current_user_method = "string_method"
        end
      end
    end

    test "validate! raises if authenticate_user_method is not a Symbol" do
      assert_raises(ConfigurationError) do
        Organizations.configure do |config|
          config.authenticate_user_method = "string_method"
        end
      end
    end

    test "validate! raises if invitation_expiry is not a Duration or Numeric" do
      assert_raises(ConfigurationError) do
        Organizations.configure do |config|
          config.invitation_expiry = "seven days"
        end
      end
    end

    test "validate! accepts nil invitation_expiry" do
      Organizations.configure do |config|
        config.invitation_expiry = nil
      end

      assert_nil Organizations.configuration.invitation_expiry
    end

    test "validate! accepts numeric invitation_expiry" do
      Organizations.configure do |config|
        config.invitation_expiry = 604800
      end

      assert_equal 604800, Organizations.configuration.invitation_expiry
    end

    test "validate! raises if default_invitation_role is not in hierarchy" do
      assert_raises(ConfigurationError) do
        Organizations.configure do |config|
          config.default_invitation_role = :superadmin
        end
      end
    end

    test "validate! raises if max_organizations_per_user is not an Integer" do
      assert_raises(ConfigurationError) do
        Organizations.configure do |config|
          config.max_organizations_per_user = 5.5
        end
      end
    end

    test "validate! raises if max_organizations_per_user is less than 1" do
      assert_raises(ConfigurationError) do
        Organizations.configure do |config|
          config.max_organizations_per_user = 0
        end
      end
    end

    test "validate! raises if max_organizations_per_user is negative" do
      assert_raises(ConfigurationError) do
        Organizations.configure do |config|
          config.max_organizations_per_user = -1
        end
      end
    end

    test "validate! accepts nil max_organizations_per_user" do
      Organizations.configure do |config|
        config.max_organizations_per_user = nil
      end

      assert_nil Organizations.configuration.max_organizations_per_user
    end

    test "validate! returns true on valid configuration" do
      config = Configuration.new
      assert_equal true, config.validate!
    end
  end
end
