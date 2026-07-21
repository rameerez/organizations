# frozen_string_literal: true

require "test_helper"

# The 0.5.0 DX bundle: create_with_owner!, purge_stale!, metadata_flag,
# top-level error aliases, mount-aware acceptance URLs, and the known-user
# sign-in promotion default.
class SmallApisTest < ActiveSupport::TestCase
  def setup
    Organizations.reset_configuration!
    @owner = User.create!(email: "owner-#{SecureRandom.hex(4)}@example.com", name: "Owner")
  end

  def teardown
    Organizations.reset_configuration!
  end

  # === Organization.create_with_owner! ===

  test "create_with_owner! creates org + owner membership atomically and fires organization_created" do
    events = []
    Organizations.configure do |config|
      config.on_organization_created { |ctx| events << [ctx.organization, ctx.user] }
      # Must NOT fire — owner-at-creation is not "joining".
      config.on_member_joining { |_ctx| raise Organizations::MembershipVetoed, "never" }
    end

    org = Organizations::Organization.create_with_owner!(owner: @owner, name: "Provisioned Org")

    assert_predicate org, :persisted?
    assert_equal @owner, org.owner
    assert_equal 1, org.member_count
    assert_equal [[org, @owner]], events
  end

  test "create_with_owner! ignores max_organizations_per_user (ops primitive)" do
    Organizations.configure { |config| config.max_organizations_per_user = 1 }
    Organizations::Organization.create_with_owner!(owner: @owner, name: "One")

    # user.create_organization! would raise OrganizationLimitReached here;
    # the ops primitive must not (an admin provisions many partner orgs).
    org = Organizations::Organization.create_with_owner!(owner: @owner, name: "Two")

    assert_predicate org, :persisted?
  end

  test "create_with_owner! rolls back the org when the owner membership fails" do
    assert_raises(ArgumentError) { Organizations::Organization.create_with_owner!(owner: nil, name: "X") }

    before = Organizations::Organization.count
    # An unsaved user has no id → the membership INSERT fails inside the txn
    # (NotNullViolation on sqlite, RecordInvalid elsewhere — assert the
    # common ancestor; the ROLLBACK is what this test pins).
    assert_raises(ActiveRecord::ActiveRecordError) do
      Organizations::Organization.create_with_owner!(owner: User.new, name: "Half Org")
    end
    assert_equal before, Organizations::Organization.count, "no orphan org without its owner"
  end

  # === JoinRequest.purge_stale! ===

  test "purge_stale! removes old decided/expired requests, keeps approved and recent ones" do
    org = @owner.create_organization!("Purge Org")

    old_rejected = User.create!(email: "r-#{SecureRandom.hex(4)}@example.com").request_to_join!(org)
    old_rejected.reject!(rejected_by: @owner)
    old_rejected.update!(decided_at: 13.months.ago)

    old_withdrawn = User.create!(email: "w-#{SecureRandom.hex(4)}@example.com").request_to_join!(org)
    old_withdrawn.withdraw!
    old_withdrawn.update!(decided_at: 13.months.ago)

    old_expired = User.create!(email: "e-#{SecureRandom.hex(4)}@example.com").request_to_join!(org)
    old_expired.update!(expires_at: 13.months.ago)

    approved = User.create!(email: "a-#{SecureRandom.hex(4)}@example.com").request_to_join!(org)
    org.approve_join_request!(approved, approved_by: @owner)
    approved.update!(decided_at: 13.months.ago)

    recent_rejected = User.create!(email: "rr-#{SecureRandom.hex(4)}@example.com").request_to_join!(org)
    recent_rejected.reject!(rejected_by: @owner)

    purged = Organizations::JoinRequest.purge_stale!(older_than: 12.months)

    assert_equal 3, purged
    assert Organizations::JoinRequest.exists?(approved.id), "approved requests are the join audit trail — kept"
    assert Organizations::JoinRequest.exists?(recent_rejected.id), "recent decisions are kept"
    refute Organizations::JoinRequest.exists?(old_rejected.id)
    refute Organizations::JoinRequest.exists?(old_withdrawn.id)
    refute Organizations::JoinRequest.exists?(old_expired.id)
  end

  # === metadata_flag ===

  test "metadata_flag: default when unset, cast on read, writer and toggle persist" do
    Organizations::Membership.metadata_flag :probe_show_on_profile, default: true

    org = @owner.create_organization!("Flag Org")
    membership = org.owner_membership

    assert_predicate membership, :probe_show_on_profile?, "unset ⇒ default"

    membership.probe_show_on_profile = false
    membership.save!

    refute_predicate membership.reload, :probe_show_on_profile?
    refute membership.metadata["probe_show_on_profile"]

    # String forms cast like Rails booleans
    membership.update!(metadata: membership.metadata.merge("probe_show_on_profile" => "1"))

    assert_predicate membership, :probe_show_on_profile?

    membership.toggle_probe_show_on_profile!

    refute_predicate membership.reload, :probe_show_on_profile?
  end

  test "metadata_flag works over a different bag column and false defaults" do
    Organizations::Organization.metadata_flag :probe_beta, default: false

    org = @owner.create_organization!("Beta Org")

    refute_predicate org, :probe_beta?

    org.probe_beta = true

    assert_predicate org, :probe_beta?
  end

  # === Top-level error aliases ===

  test "user-level errors live at Organizations:: top level and stay rescuable at the nested path" do
    assert_equal Organizations::CannotLeaveAsLastOwner,
                 Organizations::Models::Concerns::HasOrganizations::CannotLeaveAsLastOwner

    org = @owner.create_organization!("Leave Org")
    error = assert_raises(Organizations::CannotLeaveAsLastOwner) { @owner.leave_organization!(org) }
    assert_kind_of Organizations::Models::Concerns::HasOrganizations::CannotLeaveAsLastOwner, error
  end

  # === Mount-aware acceptance URLs ===

  test "acceptance_url prefixes the engine mount path" do
    org = @owner.create_organization!("URL Org")
    invitation = org.send_invite_to!("invitee@example.com", invited_by: @owner)

    # Outside Rails there is no mount → no prefix (today's behavior).
    assert_equal "", Organizations.engine_mount_path
    assert_includes invitation.acceptance_url(base_url: "https://app.test"),
                    "https://app.test/invitations/#{invitation.token}"

    # Simulate a host that mounted the engine at /orgs.
    Organizations.instance_variable_set(:@engine_mount_path, "/orgs")

    assert_includes invitation.acceptance_url(base_url: "https://app.test"),
                    "https://app.test/orgs/invitations/#{invitation.token}"
  ensure
    Organizations.reset_configuration! # clears the memoized mount path
  end

  # === Known-user promotion default ===

  test "auth-required redirect defaults to sign-in for known emails, sign-up otherwise" do
    org = @owner.create_organization!("Redirect Org")
    known = org.send_invite_to!("known-#{SecureRandom.hex(4)}@example.com", invited_by: @owner)
    User.create!(email: known.email)
    unknown = org.send_invite_to!("unknown-#{SecureRandom.hex(4)}@example.com", invited_by: @owner)

    helper = Class.new do
      include Organizations::ControllerHelpers

      # Minimal main_app stub exposing devise-ish named routes.
      def main_app
        Class.new do
          def new_user_session_path = "/users/sign_in"
          def new_user_registration_path = "/users/sign_up"
          def root_path = "/"

          # rubocop:disable Style/OptionalBooleanParameter -- Ruby core respond_to? signature
          def respond_to?(name, _all = false)
            # rubocop:enable Style/OptionalBooleanParameter
            %i[new_user_session_path new_user_registration_path
               root_path].include?(name) || super
          end
        end.new
      end
    end.new

    assert_equal "/users/sign_in",
                 helper.redirect_path_when_invitation_requires_authentication(known)
    assert_equal "/users/sign_up",
                 helper.redirect_path_when_invitation_requires_authentication(unknown)
  end
end
