# frozen_string_literal: true

require "test_helper"

# This test verifies that Organizations models are reload-safe.
# Run with: cd test/dummy && bin/rails test test/zeitwerk_reload_test.rb
#
# Background: When models are loaded via `require` (non-reloadable), their
# association reflections cache class references. After a Zeitwerk reload,
# those references point to stale class objects, causing STI errors like:
#   "Invalid single-table inheritance type: Pay::Stripe::Customer is not a subclass of Pay::Customer"
#
# The fix makes Organizations models reloadable by loading them from app/models
# via Zeitwerk, ensuring association reflections always point to current classes.
class ZeitwerkReloadTest < ActiveSupport::TestCase
  test "Organizations::Organization class object changes after reload" do
    skip "Reloading is only enabled in development" unless Rails.application.config.reloading_enabled?

    object_id_before = Organizations::Organization.object_id

    Rails.application.reloader.reload!

    object_id_after = Organizations::Organization.object_id

    assert_not_equal object_id_before, object_id_after,
      "Organizations::Organization should be a new class object after reload"
  end

  test "Organizations::Membership class object changes after reload" do
    skip "Reloading is only enabled in development" unless Rails.application.config.reloading_enabled?

    object_id_before = Organizations::Membership.object_id

    Rails.application.reloader.reload!

    object_id_after = Organizations::Membership.object_id

    assert_not_equal object_id_before, object_id_after,
      "Organizations::Membership should be a new class object after reload"
  end

  test "Organizations::Invitation class object changes after reload" do
    skip "Reloading is only enabled in development" unless Rails.application.config.reloading_enabled?

    object_id_before = Organizations::Invitation.object_id

    Rails.application.reloader.reload!

    object_id_after = Organizations::Invitation.object_id

    assert_not_equal object_id_before, object_id_after,
      "Organizations::Invitation should be a new class object after reload"
  end

  test "model associations remain functional after multiple reloads" do
    skip "Reloading is only enabled in development" unless Rails.application.config.reloading_enabled?

    # Create test data
    user = User.create!(email: "test@example.com")
    org = Organizations::Organization.create!(name: "Test Org")
    membership = Organizations::Membership.create!(user: user, organization: org, role: "owner")

    # Perform multiple reload cycles
    3.times do |i|
      Rails.application.reloader.reload!

      # Re-fetch to get current class instances
      org_reloaded = Organizations::Organization.find(org.id)
      user_reloaded = User.find(user.id)

      # Verify associations still work
      assert_equal 1, org_reloaded.memberships.count,
        "Organization should have 1 membership after reload cycle #{i + 1}"
      assert_equal user_reloaded.id, org_reloaded.memberships.first.user_id,
        "Membership should reference correct user after reload cycle #{i + 1}"
      assert_equal org_reloaded.id, user_reloaded.memberships.first.organization_id,
        "User membership should reference correct organization after reload cycle #{i + 1}"
    end
  end
end
