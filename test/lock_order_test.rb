# frozen_string_literal: true

require "test_helper"

# One lock order on every path (0.8.0 for the destroys, 0.8.1 for the
# joins): the user rows, then the organization row, then the rows of the
# organization. A user's deletion locks the user row, then the row of every
# organization in which it writes. An organization's destroy locks its row
# before its cascades. The joins take a key share guard on the user rows,
# which only a deletion waits for.
#
# Each test runs one path in another connection. That path takes its first
# locks, then holds them until this connection waits for a lock in the
# second path. Then the first path goes on. Before 0.8.1 each pair
# deadlocked on PostgreSQL.

# Helpers of the lock order tests.
module LockOrderTestHelpers
  WAITING_SQL = <<~SQL
    SELECT count(*) FROM pg_stat_activity
    WHERE datname = current_database() AND pid <> pg_backend_pid() AND wait_event_type = 'Lock'
  SQL

  def setup
    super
    skip "Row locks across connections need PostgreSQL (ORGS_TEST_DATABASE_URL)" unless postgresql?
  end

  private

  # Runs work in another connection, and the block once work pushes to
  # `ready`. Errors of the work are raised here. Returns the block's value.
  def concurrently(work)
    ready = Queue.new
    thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection { work.call(ready) }
    ensure
      ready << :done
    end
    ready.pop
    result = yield
    thread.value
    result
  ensure
    thread.join if thread&.alive?
  end

  # A step for the first path, once: tell this connection to start, then
  # wait until it waits for a lock. Returns nil, so `pause.call || super()`
  # goes on with the original method.
  def holding(ready)
    done = false
    lambda do
      next if done

      done = true
      ready << true
      wait_for_a_lock_wait!
      nil
    end
  end

  # The deletion's first callback (lock_rows_for_deletion) has taken its
  # locks. It holds them until the other path waits.
  def pausing_after_the_deletion_locks(user, ready)
    pause = holding(ready)
    user.define_singleton_method(:lock_rows_for_deletion) { super().tap { pause.call } }
    yield user
  end

  # Waits (bounded) until another connection of this database waits for a
  # lock. Inside a transaction PostgreSQL keeps the first snapshot of
  # pg_stat_activity, so each read clears it.
  def wait_for_a_lock_wait!(timeout: 5)
    connection = ActiveRecord::Base.connection
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      waiting = ActiveRecord::Base.uncached do
        connection.select_value("SELECT pg_stat_clear_snapshot()")
        connection.select_value(WAITING_SQL).to_i.positive?
      end
      return if waiting
      raise "No other connection waited for a lock within #{timeout} seconds" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.02
    end
  end

  def postgresql?
    ActiveRecord::Base.connection.adapter_name.downcase.include?("postg")
  end
end

class InvitationLockOrderTest < Organizations::Test
  include LockOrderTestHelpers

  test "an invitation is accepted while its inviter deletes their account, and neither deadlocks" do
    org, = create_org_with_owner!
    inviter = create_user!
    org.add_member!(inviter, role: :admin)
    invitation = org.send_invite_to!("guest@example.com", invited_by: inviter)
    guest = create_user!(email: "guest@example.com")
    # The deletion has locked the inviter's row and the organization row.
    # It writes to the invitation (invited_by_id) only later.
    deletion = lambda do |ready|
      pausing_after_the_deletion_locks(User.find(inviter.id), ready, &:destroy!)
    end

    membership = concurrently(deletion) { invitation.accept!(guest) }

    refute User.exists?(inviter.id)
    assert_equal guest.id, membership.user_id
    assert_nil membership.reload.invited_by_id
    assert_predicate invitation.reload, :accepted?
  end

  test "an invitation is accepted while its inviter adds a grant to it, and neither deadlocks" do
    org, = create_org_with_owner!
    inviter = create_user!
    org.add_member!(inviter, role: :admin)
    invitation = org.send_invite_to!("guest@example.com", invited_by: inviter)
    guest = create_user!(email: "guest@example.com")
    document = Document.create!(organization: org)
    # The grant holds the invitation row. It inserts a grant that names the
    # inviter only later.
    granting = lambda do |ready|
      pending = Organizations::Invitation.find(invitation.id)
      pause = holding(ready)
      pending.define_singleton_method(:lock_for_grant_write!) { super().tap { pause.call } }
      pending.grant!(document, capabilities: %w[read], granted_by: User.find(inviter.id))
    end

    membership = concurrently(granting) { invitation.accept!(guest) }

    assert membership.granted?(document)
    assert_predicate invitation.reload, :accepted?
  end

  test "a reissued invitation is accepted from a stale copy while its new inviter becomes the owner" do
    org, = create_org_with_owner!
    first_inviter = create_user!
    new_inviter = create_user!
    org.add_member!(first_inviter, role: :admin)
    org.add_member!(new_inviter, role: :admin)
    invitation = org.send_invite_to!("guest@example.com", invited_by: first_inviter)
    invitation.update!(expires_at: 1.day.ago)
    stale = Organizations::Invitation.find(invitation.id)
    org.send_invite_to!("guest@example.com", invited_by: new_inviter) # reissues the expired row

    assert_equal new_inviter.id, invitation.reload.invited_by_id
    guest = create_user!(email: "guest@example.com")
    # The acceptance has locked its rows. It inserts the membership, which
    # names the new inviter, only later.
    acceptance = lambda do |ready|
      pause = holding(ready)
      stale.define_singleton_method(:accepted?) { pause.call || super() }
      stale.accept!(guest)
    end

    concurrently(acceptance) do
      Organizations::Organization.find(org.id).transfer_ownership_to!(User.find(new_inviter.id))
    end

    assert_equal new_inviter.id, org.memberships.find_by!(user_id: guest.id).invited_by_id
    assert_equal new_inviter, org.reload.owner
  end

  test "an invitation is revoked while its organization is destroyed, and neither deadlocks" do
    org, owner = create_org_with_owner!
    invitation = org.send_invite_to!("guest@example.com", invited_by: owner,
                                                          grants: { Document.create!(organization: org) => %w[read] })

    assert_equal 1, invitation.grants.count
    # The revoke holds its first locks. The destroy's cascade deletes the
    # invitation's grants, then the invitation.
    revoke = lambda do |ready|
      revoking = Organizations::Invitation.find(invitation.id)
      pause = holding(ready)
      revoking.define_singleton_method(:authorize_management!) { |actor| pause.call || super(actor) }
      revoking.revoke!(revoked_by: owner)
    end

    concurrently(revoke) { Organizations::Organization.find(org.id).destroy! }

    refute Organizations::Organization.exists?(org.id)
    refute Organizations::Invitation.exists?(invitation.id)
    refute Organizations::Grant.exists?(invitation_id: invitation.id)
  end
end

class JoinLockOrderTest < Organizations::Test
  include LockOrderTestHelpers

  test "a join request is approved while its requester deletes their account, and neither deadlocks" do
    org, owner = create_org_with_owner!
    requester = create_user!
    request = requester.request_to_join!(org)
    # The deletion has locked the requester's row and the organization row.
    # It deletes the request only later.
    deletion = lambda do |ready|
      pausing_after_the_deletion_locks(User.find(requester.id), ready, &:destroy!)
    end

    # The request goes with the account: the approval finds no row, and
    # nothing deadlocks.
    concurrently(deletion) do
      assert_raises(ActiveRecord::RecordNotFound) { request.approve!(decided_by: owner) }
    end

    refute User.exists?(requester.id)
    refute Organizations::JoinRequest.exists?(request.id)
    refute Organizations::Membership.exists?(user_id: requester.id)
  end

  test "a join request is rejected while an approval of it waits, and neither deadlocks" do
    org, = create_org_with_owner!
    admin = create_user!
    org.add_member!(admin, role: :admin)
    request = create_user!.request_to_join!(org)
    # The rejection holds the request row. It writes decided_by_id, whose
    # foreign key check reads the admin's row, only later.
    rejection = lambda do |ready|
      rejecting = Organizations::JoinRequest.find(request.id)
      pause = holding(ready)
      rejecting.define_singleton_method(:ensure_undecided!) { pause.call || super() }
      rejecting.reject!(rejected_by: User.find(admin.id))
    end

    concurrently(rejection) do
      assert_raises(Organizations::JoinRequestAlreadyDecided) { request.approve!(decided_by: admin) }
    end

    assert_predicate request.reload, :rejected?
    assert_equal admin.id, request.decided_by_id
    refute Organizations::Membership.exists?(user_id: request.user_id)
  end

  test "an emailed code is checked while its organization is destroyed, and neither deadlocks" do
    org, = create_org_with_owner!
    domain = org.add_domain!("acme.test")
    request = create_user!.request_to_join!(org)
    request.start_email_verification!(email: "ana@acme.test")
    code = Organizations::TestHelpers.issue_verification_code(request)
    # The check holds its first locks. The destroy's cascade deletes the
    # domain, then the request.
    check = lambda do |ready|
      checking = Organizations::JoinRequest.find(request.id)
      pause = holding(ready)
      checking.define_singleton_method(:ensure_open!) { pause.call || super() }
      checking.verify_email_code!(code)
    rescue ActiveRecord::RecordNotFound
      :gone # the approval after the check found the request deleted
    end

    concurrently(check) { Organizations::Organization.find(org.id).destroy! }

    refute Organizations::Organization.exists?(org.id)
    refute Organizations::Domain.exists?(domain.id)
    refute Organizations::JoinRequest.exists?(request.id)
  end

  test "an emailed code is checked inside a host transaction while the requester deletes their account" do
    org, = create_org_with_owner!
    org.add_domain!("acme.test")
    requester = create_user!
    request = requester.request_to_join!(org)
    request.start_email_verification!(email: "ana@acme.test")
    code = Organizations::TestHelpers.issue_verification_code(request)
    # The host's transaction holds the check's locks. The automatic approval
    # in the same transaction comes only later.
    host = lambda do |ready|
      checking = Organizations::JoinRequest.find(request.id)
      pause = holding(ready)
      checking.define_singleton_method(:auto_approvable_after_verification?) { pause.call || super() }
      ActiveRecord::Base.transaction { checking.verify_email_code!(code) }
    end

    concurrently(host) { assert User.find(requester.id).destroy }

    refute User.exists?(requester.id)
    refute Organizations::JoinRequest.exists?(request.id)
    refute Organizations::Membership.exists?(user_id: requester.id)
  end

  test "a join code is redeemed while its creator deletes their account, and neither deadlocks" do
    org, = create_org_with_owner!
    creator = create_user!
    org.add_member!(creator, role: :admin)
    join_code = org.join_codes.create!(created_by: creator)
    joiner = create_user!
    # The deletion has locked the creator's row and the organization row. It
    # writes to the code (created_by_id) only later.
    deletion = lambda do |ready|
      pausing_after_the_deletion_locks(User.find(creator.id), ready, &:destroy!)
    end

    membership = concurrently(deletion) { join_code.redeem!(user: joiner) }

    refute User.exists?(creator.id)
    assert_kind_of Organizations::Membership, membership
    assert_equal joiner.id, membership.user_id
    assert_nil join_code.reload.created_by_id
    assert_equal 1, join_code.uses_count
  end
end
