# frozen_string_literal: true

require "test_helper"
require "action_controller"

# Organizations::OrganizationScoped — URL-scoped org resolution (the overlay
# addressing mode). Tested through a mock controller implementing the
# ActionController surface the concern touches (params/before_action/head),
# mirroring the ControllerHelpersTest harness style.
class OrganizationScopedTest < ActiveSupport::TestCase
  class MockScopedController
    # Minimal before_action registry: the concern registers callbacks at
    # class-definition time; run_callbacks! plays them per "request".
    def self.before_action(*args, **_options, &block)
      (@before_actions ||= []) << (block || args.first)
    end

    def self.before_actions
      own = @before_actions || []
      superclass.respond_to?(:before_actions) ? superclass.before_actions + own : own
    end

    # class_attribute comes from ActiveSupport's core_ext on Class — the
    # real thing, so subclass overrides inherit correctly (the concern's
    # knobs are class_attributes precisely for that).
    include Organizations::OrganizationScoped

    attr_reader :params, :head_status
    attr_accessor :test_current_user

    def initialize(params = {})
      @params = params
      @head_status = nil
    end

    def current_user = test_current_user

    def head(status)
      @head_status = status
    end

    def run_callbacks!
      self.class.before_actions.each do |callback|
        callback.is_a?(Symbol) ? send(callback) : instance_exec(&callback)
      end
      self
    end
  end

  class SlugPortalController < MockScopedController
    self.organization_param = :slug
    self.organization_finder = ->(param) { Organizations::Organization.find_by(name: param) }
    require_organization_role :admin
  end

  class ForbiddenModeController < MockScopedController
    self.organization_not_found_behavior = :forbidden
  end

  def setup
    Organizations.reset_configuration!
    @owner = User.create!(email: "owner-#{SecureRandom.hex(4)}@example.com")
    @member = User.create!(email: "member-#{SecureRandom.hex(4)}@example.com")
    @stranger = User.create!(email: "stranger-#{SecureRandom.hex(4)}@example.com")
    # UNIQUE name per test: this suite has no transactional fixtures, so rows
    # accumulate — a fixed name would make the by-name finder resolve an org
    # from an EARLIER test (whose memberships don't include this test's
    # users). Burned once; don't reuse literal names in by-name lookups.
    @org_name = "Scoped Org #{SecureRandom.hex(4)}"
    @org = @owner.create_organization!(@org_name)
    @org.add_member!(@member)
  end

  def teardown
    Organizations.reset_configuration!
  end

  test "resolves the organization through the configured param and finder" do
    controller = SlugPortalController.new(slug: @org_name)
    controller.test_current_user = @owner
    controller.run_callbacks!

    assert_equal @org, controller.current_scoped_organization
    assert_equal @org.owner_membership, controller.current_scoped_membership
  end

  test "unknown org, non-member, and under-role member are indistinguishable (RoutingError)" do
    # No existence oracle: all three 404 the same way.
    [
      [ { slug: "Nope Org" }, @owner ],   # unknown org
      [ { slug: @org_name }, @stranger ], # stranger
      [ { slug: @org_name }, @member ]    # plain member below :admin
    ].each do |params, user|
      controller = SlugPortalController.new(params)
      controller.test_current_user = user

      assert_raises(ActionController::RoutingError, "expected 404 for #{user.email} on #{params}") do
        controller.run_callbacks!
      end
    end
  end

  test "role gate admits admin-and-above" do
    admin = User.create!(email: "admin-#{SecureRandom.hex(4)}@example.com")
    @org.add_member!(admin, role: :admin)

    controller = SlugPortalController.new(slug: @org_name)
    controller.test_current_user = admin
    controller.run_callbacks!

    assert_equal @org, controller.current_scoped_organization
  end

  test ":forbidden mode responds 403 instead of raising" do
    controller = ForbiddenModeController.new(organization_id: 0)
    controller.test_current_user = @owner
    controller.run_callbacks!

    assert_equal :forbidden, controller.head_status
  end

  test "default finder resolves by id" do
    controller = MockScopedController.new(organization_id: @org.id)
    controller.test_current_user = @owner
    controller.run_callbacks!

    assert_equal @org, controller.current_scoped_organization
  end

  test "signed-out viewers have no membership and fail role gates" do
    controller = SlugPortalController.new(slug: @org_name)
    controller.test_current_user = nil

    assert_raises(ActionController::RoutingError) { controller.run_callbacks! }
  end
end
