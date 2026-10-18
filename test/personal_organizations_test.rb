# frozen_string_literal: true

require "test_helper"

# Explicit personal organizations (issue #21, part 1): a persistent link from
# a user to the one organization that is their personal workspace, never
# guessed from names, member counts or creation order.
class PersonalOrganizationsTest < Organizations::Test
  # === Lookup and classification ===

  test "an ordinary organization is not personal and the user has no personal organization" do
    org, owner = create_org_with_owner!

    refute_predicate org, :personal?
    assert_nil owner.personal_organization
    assert_includes Organizations::Organization.not_personal, org
    refute_includes Organizations::Organization.personal, org
  end

  test "create_personal_organization! creates the organization, the owner membership and the link" do
    user = create_user!

    org = user.create_personal_organization!("Ana's space")

    assert_predicate org, :personal?
    assert_equal "Ana's space", org.name
    assert_equal user, org.personal_owner
    assert_equal user, org.owner
    assert_equal org, user.reload.personal_organization
    assert_includes Organizations::Organization.personal, org
  end

  test "create_personal_organization! uses the configured default name" do
    Organizations.configure { |c| c.default_organization_name = ->(u) { "#{u.name} HQ" } }
    user = create_user!(name: "Luis")

    assert_equal "Luis HQ", user.create_personal_organization!.name
  end

  test "create_personal_organization! accepts an attributes hash" do
    user = create_user!

    org = user.create_personal_organization!(name: "From hash")

    assert_equal "From hash", org.name
    assert_predicate org, :personal?
  end

  test "create_personal_organization! is idempotent and is the repair path" do
    user = create_user!
    first = user.create_personal_organization!("One")

    assert_no_difference -> { Organizations::Organization.count } do
      assert_equal first, user.create_personal_organization!("Two")
    end
  end

  test "create_personal_organization! converges on one organization when a concurrent call wins the race" do
    user = create_user!
    winner = Organizations::Organization.create_with_owner!(owner: user, name: "Winner", personal_owner: user)
    lookups = 0
    original = Organizations::Organization.method(:find_by)

    # The first lookup misses (the other process has not committed yet), so
    # the insert hits the unique index and the method reads the winner.
    stub = lambda do |*args, **kwargs|
      lookups += 1
      lookups == 1 ? nil : original.call(*args, **kwargs)
    end

    Organizations::Organization.stub(:find_by, stub) do
      assert_equal winner, user.create_personal_organization!("Loser")
    end
    assert_equal 1, Organizations::Organization.where(personal_owner_id: user.id).count
    assert_equal 1, user.reload.owned_organizations.count
  end

  test "create_personal_organization! fires organization_created" do
    events = []
    Organizations.configure { |c| c.on_organization_created { |ctx| events << ctx.organization } }
    user = create_user!

    org = user.create_personal_organization!

    assert_equal [org], events
  end

  test "personal_organization is a lookup with no creation side effect" do
    user = create_user!

    assert_no_difference -> { Organizations::Organization.count } do
      assert_nil user.personal_organization
    end
  end

  test "a user can have at most one personal organization at the database level" do
    user = create_user!
    user.create_personal_organization!

    other = Organizations::Organization.create!(name: "Second")
    assert_raises(ActiveRecord::RecordNotUnique) do
      other.update_column(:personal_owner_id, user.id)
    end
  end

  # === Sign-up provisioning ===

  test "sign-up auto-creation stays an ordinary organization unless record_personal_organizations is on" do
    Organizations.configure { |c| c.always_create_personal_organization_for_each_user = true }
    reload_user_settings!

    user = create_user!

    assert_equal 1, user.organizations.count
    refute_predicate user.organizations.first, :personal?
    assert_nil user.personal_organization
  end

  test "sign-up auto-creation records the personal organization when configured" do
    Organizations.configure do |c|
      c.always_create_personal_organization_for_each_user = true
      c.record_personal_organizations = true
    end
    reload_user_settings!

    user = create_user!

    org = user.personal_organization

    assert_predicate org, :personal?
    assert_equal user, org.owner
    assert_equal 1, user.organizations.count
  end

  test "an invited sign-up that skips auto-creation gets no personal organization" do
    Organizations.configure do |c|
      c.always_create_personal_organization_for_each_user = true
      c.record_personal_organizations = true
    end
    reload_user_settings!

    user = User.new(email: "invited-#{SecureRandom.hex(3)}@example.com", name: "Invited")
    user.define_singleton_method(:should_create_personal_organization?) { false }
    user.save!

    assert_nil user.personal_organization
    assert_equal 0, user.organizations.count
  end

  test "a failed sign-up provisioning keeps the user and can be repaired later" do
    Organizations.configure do |c|
      c.always_create_personal_organization_for_each_user = true
      c.record_personal_organizations = true
      c.on_organization_created { raise "callback errors are isolated" }
    end
    reload_user_settings!

    failing = ->(*) { raise ActiveRecord::StatementInvalid, "database hiccup" }
    user = nil
    Organizations::Organization.stub(:create!, failing) do
      user = create_user!
    end

    assert User.exists?(user.id)
    assert_nil user.personal_organization

    repaired = user.create_personal_organization!

    assert_predicate repaired, :personal?
  end

  # === Ownership integrity ===

  test "ownership of a personal organization cannot be transferred" do
    user = create_user!
    org = user.create_personal_organization!
    admin = create_user!
    org.add_member!(admin, role: :admin)

    assert_raises(Organizations::Organization::CannotTransferPersonalOrganization) do
      org.transfer_ownership_to!(admin)
    end
    assert_equal user, org.reload.owner
  end

  test "convert_to_shared! removes the personal link so ownership can move" do
    user = create_user!
    org = user.create_personal_organization!
    admin = create_user!
    org.add_member!(admin, role: :admin)

    org.convert_to_shared!
    org.transfer_ownership_to!(admin)

    refute_predicate org.reload, :personal?
    assert_equal admin, org.owner
    assert_nil user.reload.personal_organization
  end

  test "the personal owner must hold the owner membership" do
    org, _owner = create_org_with_owner!
    stranger = create_user!

    org.personal_owner = stranger

    refute_predicate org, :valid?
    assert_includes org.errors[:personal_owner].join, "owner"
  end

  test "personal identity alone does not prohibit collaborators" do
    user = create_user!
    org = user.create_personal_organization!
    friend = create_user!

    org.add_member!(friend)

    assert friend.is_member_of?(org)
    assert_predicate org.reload, :personal?
  end

  test "deleting the personal owner row at the database level clears the link instead of failing" do
    user = create_user!
    org = user.create_personal_organization!
    Organizations::Membership.where(organization_id: org.id).delete_all

    User.where(id: user.id).delete_all

    assert_nil org.reload.personal_owner_id
  end

  # === Backfill ===

  test "backfill dry run reports what it would assign and writes nothing" do
    org, owner = create_org_with_owner!

    report = Organizations::Organization.backfill_personal_owners!({ owner => org }, dry_run: true)

    refute_predicate report, :applied?
    assert_equal [[owner.id, org.id]], report.assignments
    assert_empty report.conflicts
    refute_predicate org.reload, :personal?
  end

  test "backfill assigns a reviewed mapping" do
    org, owner = create_org_with_owner!
    org2, owner2 = create_org_with_owner!(name: "Two")

    report = Organizations::Organization.backfill_personal_owners!({ owner.id => org.id, owner2 => org2 })

    assert_predicate report, :applied?
    assert_equal org, owner.reload.personal_organization
    assert_equal org2, owner2.reload.personal_organization
  end

  test "backfill rejects every conflict and applies nothing when any pair conflicts" do
    org, owner = create_org_with_owner!
    not_owned, = create_org_with_owner!(name: "Someone else's")
    member = create_user!
    not_owned.add_member!(member)

    report = Organizations::Organization.backfill_personal_owners!({ owner => org, member => not_owned })

    refute_predicate report, :applied?
    assert_equal [{ user_id: member.id, organization_id: not_owned.id, reason: :not_the_owner }], report.conflicts
    refute_predicate org.reload, :personal?
  end

  test "backfill reports each kind of conflict" do
    personal_user = create_user!
    personal = personal_user.create_personal_organization!
    org, owner = create_org_with_owner!
    second, = create_org_with_owner!(name: "Second", owner: personal_user)

    report = Organizations::Organization.backfill_personal_owners!(
      { owner => personal, personal_user => second, create_user! => -1 }
    )

    reasons = report.conflicts.map { |c| c[:reason] }.sort

    assert_equal %i[not_the_owner organization_not_found user_has_another_personal_organization], reasons
    refute_predicate org.reload, :personal?
  end

  test "backfill rejects one organization mapped to two users" do
    org, owner = create_org_with_owner!
    other = create_user!

    report = Organizations::Organization.backfill_personal_owners!({ owner => org, other => org })

    assert_includes report.conflicts.map { |c| c[:reason] }, :organization_mapped_twice
  end

  test "backfill leaves already-linked pairs unchanged" do
    user = create_user!
    org = user.create_personal_organization!

    report = Organizations::Organization.backfill_personal_owners!({ user => org })

    assert_equal [[user.id, org.id]], report.unchanged
    assert_empty report.assignments
    assert_predicate report, :applied?
  end

  # === Configuration ===

  test "record_personal_organizations must be a boolean" do
    assert_raises(Organizations::ConfigurationError) do
      Organizations.configure { |c| c.record_personal_organizations = "yes" }
    end
  end

  def teardown
    User.organization_settings = DEFAULT_USER_SETTINGS
    super
  end

  DEFAULT_USER_SETTINGS = { max_organizations: nil, create_personal_org: false, require_organization: false }.freeze

  private

  # has_organizations snapshots the global settings at class-definition time.
  def reload_user_settings!
    User.organization_settings = DEFAULT_USER_SETTINGS.merge(
      create_personal_org: Organizations.configuration.always_create_personal_organization_for_each_user
    ).freeze
  end
end
