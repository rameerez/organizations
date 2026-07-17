# frozen_string_literal: true

require "test_helper"

# config.engine_routes — the devise_for-style only:/except: toggle for engine
# route groups. The route FILE reads engine_route_groups at draw time (config
# is set in initializers, which run before routes load; reload_routes!
# re-reads it), so what's tested here is the resolution contract the routes
# file consumes.
class EngineRoutesConfigTest < ActiveSupport::TestCase
  ALL = Organizations::Configuration::ENGINE_ROUTE_GROUPS

  def teardown
    Organizations.reset_configuration!
  end

  test "default draws every group" do
    assert_equal ALL, Organizations.configuration.engine_route_groups
  end

  test "except: removes groups, keeping declaration order" do
    Organizations.configure { |c| c.engine_routes = { except: [:organizations] } }

    groups = Organizations.configuration.engine_route_groups

    refute_includes groups, :organizations
    assert_equal ALL - [:organizations], groups
  end

  test "only: keeps exactly the named groups (array shorthand too)" do
    Organizations.configure { |c| c.engine_routes = { only: [:switching, :public_invitations] } }

    assert_equal [:switching, :public_invitations], Organizations.configuration.engine_route_groups

    Organizations.configure { |c| c.engine_routes = [:memberships] }

    assert_equal [:memberships], Organizations.configuration.engine_route_groups
  end

  test "unknown groups and malformed values raise loudly at configure time" do
    error = assert_raises(Organizations::ConfigurationError) do
      Organizations.configure { |c| c.engine_routes = { except: [:billing] } }
    end
    assert_match(/Unknown engine route group/, error.message)
    assert_match(/billing/, error.message)

    assert_raises(Organizations::ConfigurationError) do
      Organizations.configure { |c| c.engine_routes = { only: [:switching], except: [:memberships] } }
    end

    assert_raises(Organizations::ConfigurationError) do
      Organizations.configure { |c| c.engine_routes = "switching" }
    end
  end

  test "nil restores the draw-everything default" do
    Organizations.configure { |c| c.engine_routes = [:switching] }
    Organizations.configure { |c| c.engine_routes = nil }

    assert_equal ALL, Organizations.configuration.engine_route_groups
  end
end
