# frozen_string_literal: true

require "test_helper"

# One lock order on every path (0.8.0 for the destroys, 0.8.1 for the
# joins): the user rows, then the organization row, then the rows of the
# organization. A user's deletion locks the user row, then the row of every
# organization in which it writes. An organization's destroy locks its row
# before its cascades. Each test here starts one of those first, and the
# other path while it holds its locks. Before 0.8.1 each pair deadlocked on
# PostgreSQL.
class LockOrderTest < Organizations::Test
  def setup
    super
    skip "Row locks across connections need PostgreSQL (ORGS_TEST_DATABASE_URL)" unless postgresql?
  end

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

  test "an invitation is revoked while its organization is destroyed, and neither deadlocks" do
    org, owner = create_org_with_owner!
    invitation = org.send_invite_to!("guest@example.com", invited_by: owner,
                                                          grants: { Document.create!(organization: org) => %w[read] })

    assert_equal 1, invitation.grants.count
    # The revoke holds its first locks a moment. The destroy starts then:
    # its cascade deletes the invitation's grants, then the invitation.
    revoke = lambda do |ready|
      revoking = Organizations::Invitation.find(invitation.id)
      revoking.define_singleton_method(:authorize_management!) { |actor| (ready << true) && sleep(0.5) && super(actor) }
      revoking.revoke!(revoked_by: owner)
    end

    concurrently(revoke) { Organizations::Organization.find(org.id).destroy! }

    refute Organizations::Organization.exists?(org.id)
    refute Organizations::Invitation.exists?(invitation.id)
    refute Organizations::Grant.exists?(invitation_id: invitation.id)
  end

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

  test "an emailed code is checked while its organization is destroyed, and neither deadlocks" do
    org, = create_org_with_owner!
    domain = org.add_domain!("acme.test")
    request = create_user!.request_to_join!(org)
    request.start_email_verification!(email: "ana@acme.test")
    code = Organizations::TestHelpers.issue_verification_code(request)
    # The check holds its first locks a moment. The destroy starts then: its
    # cascade deletes the domain, then the request.
    check = lambda do |ready|
      checking = Organizations::JoinRequest.find(request.id)
      checking.define_singleton_method(:ensure_open!) { (ready << true) && sleep(0.5) && super() }
      checking.verify_email_code!(code)
    rescue ActiveRecord::RecordNotFound
      :gone # the approval after the check found the request deleted
    end

    concurrently(check) { Organizations::Organization.find(org.id).destroy! }

    refute Organizations::Organization.exists?(org.id)
    refute Organizations::Domain.exists?(domain.id)
    refute Organizations::JoinRequest.exists?(request.id)
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

  # The deletion's first callback (lock_rows_for_deletion) has taken its
  # locks. It holds them a moment before the deletion writes.
  def pausing_after_the_deletion_locks(user, ready)
    user.define_singleton_method(:lock_rows_for_deletion) { super().tap { (ready << true) && sleep(0.5) } }
    yield user
  end

  def postgresql?
    ActiveRecord::Base.connection.adapter_name.downcase.include?("postg")
  end
end
