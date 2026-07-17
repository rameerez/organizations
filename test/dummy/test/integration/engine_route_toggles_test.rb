# frozen_string_literal: true

require "test_helper"

# config.engine_routes proven against a REAL routeset — the unit suite only
# checks config normalization (engine_route_groups), which would stay green
# if routes.rb gated a group on the wrong symbol. Here we redraw the routes
# under different configs and assert over HTTP that excluded groups 404 and
# kept groups still route.
class EngineRouteTogglesTest < ActionDispatch::IntegrationTest
  setup do
    @saved_config = Organizations.configuration
    Organizations.configuration = @saved_config.dup
  end

  teardown do
    Organizations.configuration = @saved_config
    Rails.application.reload_routes!
  end

  test "all groups drawn by default: the engine org index routes" do
    get "/organizations"
    assert_response :ok
  end

  test "except: [:organizations] removes org CRUD but keeps the other groups" do
    user = User.create!(email: "toggles-#{SecureRandom.hex(4)}@example.com", name: "Toggles")
    org = Organizations::Organization.create_with_owner!(owner: user, name: "Toggle Org")

    Organizations.configure { |config| config.engine_routes = { except: [:organizations] } }
    Rails.application.reload_routes!

    get "/organizations"
    assert_response :not_found

    get "/organizations/new"
    assert_response :not_found

    # The switching group must survive — exercised over HTTP end to end.
    post "/switch_user", params: { email: user.email }
    post "/organizations/switch/#{org.id}"
    assert_response :redirect, "switching group must survive except: [:organizations]"

    # The memberships group must survive AT THE ROUTE LEVEL. (Deliberately
    # not a full GET: the engine's reference memberships view links to
    # organization_path — helpers of the excluded group — so route groups
    # compose freely but the stock VIEWS assume all groups exist. Both
    # couplings are documented in the README's engine_routes section.)
    memberships_paths = Organizations::Engine.routes.routes.map { |r| r.path.spec.to_s }
    assert(memberships_paths.any? { |p| p.start_with?("/memberships") },
           "memberships group must survive except: [:organizations]")
  end

  test "only: [:public_invitations] removes everything else" do
    Organizations.configure { |config| config.engine_routes = { only: [:public_invitations] } }
    Rails.application.reload_routes!

    get "/memberships"
    assert_response :not_found

    get "/organizations"
    assert_response :not_found

    # The public invitation page still routes (unknown token renders the
    # engine's own error state, not a routing 404).
    get "/invitations/not-a-real-token"
    assert_not_equal 404, response.status, "public_invitations group must survive only:"
  end
end
