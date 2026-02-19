# frozen_string_literal: true

require "test_helper"

module Organizations
  class HardeningTest < Organizations::Test
    test "owner cannot be destroyed while still owning organizations" do
      org, owner = create_org_with_owner!(name: "Acme")

      error = assert_raises(ActiveRecord::RecordNotDestroyed) do
        owner.destroy!
      end

      assert_instance_of ActiveRecord::RecordNotDestroyed, error
      assert User.exists?(owner.id)
      assert Organizations::Organization.exists?(org.id)
      assert_equal 1, org.memberships.where(role: "owner").count
      assert_includes owner.errors.full_messages.join(", "), "Cannot delete a user who still owns organizations"
    end

    test "organization-centric invitation API requires inviter membership" do
      org, _owner = create_org_with_owner!(name: "Team Rocket")
      outsider = create_user!(email: "outsider@example.com")

      assert_raises(Organizations::NotAMember) do
        org.send_invite_to!("new@example.com", invited_by: outsider)
      end
    end

    test "organization-centric invitation API requires invite permission" do
      org, _owner = create_org_with_owner!(name: "Alpha")
      viewer = create_user!(email: "viewer@example.com")
      Organizations::Membership.create!(user: viewer, organization: org, role: "viewer")

      assert_raises(Organizations::NotAuthorized) do
        org.send_invite_to!("new@example.com", invited_by: viewer)
      end
    end

    test "ownership transfer raises domain error when owner membership is missing" do
      org = Organizations::Organization.create!(name: "No Owner Org")
      admin = create_user!(email: "admin@example.com")
      Organizations::Membership.create!(user: admin, organization: org, role: "admin")

      assert_raises(Organizations::Organization::NoOwnerPresent) do
        org.transfer_ownership_to!(admin)
      end
    end
  end
end
