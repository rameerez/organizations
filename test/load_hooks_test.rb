# frozen_string_literal: true

require "test_helper"

# Load hooks: the sanctioned host-extension seam.
#
# ActiveSupport.on_load semantics we rely on (documented contract:
# https://api.rubyonrails.org/classes/ActiveSupport/LazyLoadHooks.html):
#   - a block registered BEFORE run_load_hooks fires when the hook runs;
#   - a block registered AFTER runs immediately against every base already
#     recorded — which is what these tests exercise (the models loaded when
#     the suite booted);
#   - every re-run (Zeitwerk reload via the app/models shims re-`load`s the
#     model file, whose tail re-fires the hook) re-executes registered
#     blocks against the FRESH class object — the property that makes this
#     reload-safe where a bare initializer class_eval is not.
class LoadHooksTest < ActiveSupport::TestCase
  def setup
    Organizations.reset_configuration!
  end

  def teardown
    Organizations.reset_configuration!
  end

  MODEL_HOOKS = {
    organizations_organization: "Organizations::Organization",
    organizations_membership: "Organizations::Membership",
    organizations_invitation: "Organizations::Invitation",
    organizations_domain: "Organizations::Domain",
    organizations_join_code: "Organizations::JoinCode",
    organizations_allowlist_entry: "Organizations::AllowlistEntry",
    organizations_join_request: "Organizations::JoinRequest"
  }.freeze

  test "every model fires its load hook with the model class as base" do
    MODEL_HOOKS.each do |hook, class_name|
      bases = []
      ActiveSupport.on_load(hook) { bases << self }

      assert_includes bases, class_name.constantize,
                      "expected #{hook} to have fired for #{class_name}"
    end
  end

  test "a host extension included via the hook actually lands on the model" do
    extension = Module.new do
      def load_hook_extension_probe
        "extended-#{self.class.name}"
      end
    end

    ActiveSupport.on_load(:organizations_organization) { include extension }

    org = Organizations::Organization.new(name: "Hooked")

    assert_equal "extended-Organizations::Organization", org.load_hook_extension_probe
  end

  test "public_controller_helpers validates shape" do
    error = assert_raises(Organizations::ConfigurationError) do
      Organizations.configure { |config| config.public_controller_helpers = "ApplicationHelper" }
    end
    assert_match(/must be an Array/, error.message)

    # Valid shapes pass
    Organizations.configure { |config| config.public_controller_helpers = ["ApplicationHelper", Module.new] }
  ensure
    Organizations.reset_configuration!
  end
end
