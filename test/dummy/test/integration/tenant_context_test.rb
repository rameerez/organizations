# frozen_string_literal: true

require "test_helper"

# Organizations::Current over real requests: the controller helpers publish
# the organization they resolve, the host's hook sees it, and Rails resets it
# when the request ends, so nothing leaks into the next request.
#
# Run: cd test/dummy && bin/rails test test/integration/tenant_context_test.rb
class TenantContextTest < ActionDispatch::IntegrationTest
  # The hook the README documents: a host's tenant context follows every
  # change and every reset. It records only while a test listens.
  module RecordsTenant
    def organization=(organization)
      super
      Thread.current[:tenant_context_test]&.push(organization&.id)
    end
  end
  Organizations::Current.prepend(RecordsTenant) unless Organizations::Current <= RecordsTenant
  Organizations::Current.resets { Thread.current[:tenant_context_test]&.push(:reset) }

  setup do
    @owner = User.create!(email: "owner-#{SecureRandom.hex(4)}@example.com", name: "Owner")
    @org = Organizations::Organization.create_with_owner!(owner: @owner, name: "Tenant One")
    post switch_user_path, params: { email: @owner.email }
    post "/organizations/switch/#{@org.id}"
  end

  teardown do
    Thread.current[:tenant_context_test] = nil
  end

  test "a request publishes its organization to the host's hook, and is reset when it ends" do
    seen = Thread.current[:tenant_context_test] = []

    get root_path

    assert_response :success
    assert_includes seen, @org.id, "the helper published the organization it resolved"
    assert_equal :reset, seen.last, "and Rails reset it when the request ended"
    assert_nil Organizations::Current.organization
  end
end
