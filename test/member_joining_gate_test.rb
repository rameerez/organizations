# frozen_string_literal: true

require "test_helper"

# The membership gate: `on_member_joining` is the STRICT, VETOING, pre-persist
# callback that runs inside the creating transaction on EVERY join path.
#
# Why it exists (the design gap it closes): the after-callbacks
# (on_member_joined etc.) are error-isolated BY DESIGN and cannot abort, and
# `on_member_invited` only guards the invitation path — so before this gate,
# a host enforcing plan seat limits at invite time silently lost enforcement
# the moment it enabled any verified-joining instrument (join codes, domains,
# allowlists). Both known production hosts hit exactly this shape.
#
# Contract pinned here:
#   1. The gate fires (and can veto) on: add_member!, invitation acceptance,
#      join-request approval — which transitively covers join codes,
#      domain-email verification, allowlists, join_with_account_email!.
#   2. A veto rolls back CLEANLY: no membership row, join requests stay
#      pending (resumable), invitations stay unaccepted (re-acceptable).
#   3. The gate does NOT fire for: owner-at-org-creation, already-a-member
#      idempotent paths, role changes / ownership transfers.
#   4. Context carries organization, user, role, joined_via + the instrument.
# rubocop:disable Metrics/ClassLength -- every join path + every non-path, one contract suite on purpose
class MemberJoiningGateTest < ActiveSupport::TestCase
  include Organizations::TestHelpers

  def setup
    Organizations.reset_configuration!
    @owner = User.create!(email: "owner-#{SecureRandom.hex(4)}@example.com", name: "Owner")
    @user = User.create!(email: "joiner-#{SecureRandom.hex(4)}@example.com", name: "Joiner")
    @org = @owner.create_organization!("Gated Org")
  end

  def teardown
    Organizations.reset_configuration!
  end

  def install_veto_gate(message = nil)
    contexts = []
    Organizations.configure do |config|
      config.on_member_joining do |ctx|
        contexts << ctx
        raise Organizations::MembershipVetoed, message
      end
    end
    contexts
  end

  def install_recording_gate
    contexts = []
    Organizations.configure do |config|
      config.on_member_joining { |ctx| contexts << ctx }
    end
    contexts
  end

  # === Path 1: add_member! ===

  test "veto aborts add_member! with no membership created" do
    install_veto_gate("No room")

    error = assert_raises(Organizations::MembershipVetoed) { @org.add_member!(@user) }
    assert_equal "No room", error.message
    refute @org.reload.has_member?(@user)
    assert_equal 1, @org.member_count
  end

  test "gate context for add_member! carries role and manual provenance" do
    contexts = install_recording_gate
    @org.add_member!(@user, role: :viewer)

    ctx = contexts.last

    assert_equal :member_joining, ctx.event
    assert_equal @org, ctx.organization
    assert_equal @user, ctx.user
    assert_equal "viewer", ctx.role
    assert_equal "manual", ctx.joined_via
    assert_nil ctx.invitation
    assert_nil ctx.join_request
  end

  # === Path 2: invitation acceptance ===

  test "veto aborts invitation acceptance and leaves the invitation pending (re-acceptable)" do
    invitation = @org.send_invite_to!(@user.email, invited_by: @owner)
    install_veto_gate

    assert_raises(Organizations::MembershipVetoed) { invitation.accept!(@user) }

    invitation.reload

    assert_predicate invitation, :pending?, "a vetoed acceptance must leave the invitation pending"
    refute @org.reload.has_member?(@user)

    # Unblock (simulate the host raising the cap) → the SAME invitation works.
    Organizations.reset_configuration!
    membership = invitation.accept!(@user)

    assert_equal "invited", membership.joined_via
  end

  test "gate context for invitation acceptance carries the invitation" do
    invitation = @org.send_invite_to!(@user.email, invited_by: @owner, role: :admin)
    contexts = install_recording_gate

    invitation.accept!(@user)

    ctx = contexts.last

    assert_equal "admin", ctx.role
    assert_equal "invited", ctx.joined_via
    assert_equal invitation, ctx.invitation
  end

  # === Path 3: join-request approval (covers codes/domains/allowlists) ===

  test "veto aborts manual join-request approval and leaves the request pending (resumable)" do
    request = @user.request_to_join!(@org)
    install_veto_gate

    assert_raises(Organizations::MembershipVetoed) do
      @org.approve_join_request!(request, approved_by: @owner)
    end

    request.reload

    assert_predicate request, :pending?, "a vetoed approval must leave the request pending, not approved"
    refute @org.reload.has_member?(@user)

    # Unblock → the SAME request approves.
    Organizations.reset_configuration!
    membership = @org.approve_join_request!(request, approved_by: @owner)

    assert @org.reload.has_member?(@user)
    assert_equal(membership, request.reload.then { |r| @org.memberships.find_by(user_id: r.user_id) })
  end

  test "veto aborts instant join-code redemption (use is consumed; request parked pending)" do
    code = @org.generate_join_code!(label: "poster", auto_approve: true)
    install_veto_gate

    assert_raises(Organizations::MembershipVetoed) do
      Organizations::JoinCode.redeem(code.code, user: @user)
    end

    refute @org.reload.has_member?(@user)
    # Documented contract: uses are counted at redemption (anti-abuse cap,
    # not a seat count), so the vetoed join still consumed one...
    assert_equal 1, code.reload.uses_count
    # ...and the request is parked pending — resumable once unblocked.
    request = @org.join_requests.pending.find_by(user_id: @user.id)

    assert_predicate request, :present?
    assert_equal "code", request.joined_via
  end

  test "veto aborts domain-email verification auto-approval" do
    @org.add_domain!("example.com")
    request = @user.request_to_join!(@org)
    request.start_email_verification!(email: "joiner@example.com")
    code = extract_plaintext_code(request)
    install_veto_gate

    assert_raises(Organizations::MembershipVetoed) { request.verify_email_code!(code) }

    refute @org.reload.has_member?(@user)
    request.reload

    assert_predicate request, :pending?
    # The verification itself committed before approval ran — the user proved
    # the inbox; only membership creation was vetoed. Approving later works
    # without a fresh challenge:
    assert_predicate request, :email_verified?
  end

  test "veto aborts join_with_account_email! shortcut" do
    @org.add_domain!("corp-example.com")
    confirmed = User.create!(email: "ana@corp-example.com", confirmed_at: Time.current)
    install_veto_gate

    assert_raises(Organizations::MembershipVetoed) { @org.join_with_account_email!(confirmed) }
    refute @org.reload.has_member?(confirmed)
  end

  test "gate fires for allowlist-provenance joins with the roster joined_via" do
    @org.import_allowlist!(["rostered@club-example.com"])
    request = @user.request_to_join!(@org)
    request.start_email_verification!(email: "rostered@club-example.com")
    code = extract_plaintext_code(request)
    contexts = install_recording_gate

    request.verify_email_code!(code)

    ctx = contexts.last

    assert_equal "allowlist", ctx.joined_via
    assert_equal request, ctx.join_request
    assert @org.reload.has_member?(@user)
  end

  test "gate context for join-request approval carries the request and provenance" do
    code = @org.generate_join_code!(label: "poster", auto_approve: true)
    contexts = install_recording_gate

    Organizations::JoinCode.redeem(code.code, user: @user)

    ctx = contexts.last

    assert_equal "member", ctx.role
    assert_equal "code", ctx.joined_via
    assert_equal @org.join_requests.last, ctx.join_request
  end

  # === Non-paths: where the gate must NOT fire ===

  test "gate does not fire for the owner membership created with the organization" do
    contexts = install_recording_gate
    founder = User.create!(email: "founder-#{SecureRandom.hex(4)}@example.com")

    org = founder.create_organization!("Fresh Org")

    assert org.has_member?(founder)
    assert_empty contexts, "creating your own organization is not 'joining' — the gate must not fire"
  end

  test "gate does not fire for idempotent already-a-member paths" do
    # Invitation sent BEFORE the user becomes a member (send_invite_to!
    # rightly refuses to invite existing members), accepted after.
    invitation = @org.send_invite_to!(@user.email, invited_by: @owner)
    @org.add_member!(@user)
    contexts = install_recording_gate

    @org.add_member!(@user) # idempotent no-op
    code = @org.generate_join_code!(auto_approve: true)
    Organizations::JoinCode.redeem(code.code, user: @user) # already a member

    # Accepting an invitation while ALREADY a member reuses the membership —
    # nobody is joining, so the gate must stay silent on this path too.
    invitation.accept!(@user)

    assert_empty contexts, "an existing member re-joining must not hit the gate"
  end

  test "gate does not fire for role changes or ownership transfers" do
    @org.add_member!(@user)
    contexts = install_recording_gate

    @org.change_role_of!(@user, to: :admin, changed_by: @owner)
    @org.transfer_ownership_to!(@user)

    assert_empty contexts
  end

  # === Semantics ===

  test "gate raising MembershipVetoed without a message uses the localized default" do
    Organizations.configure do |config|
      config.on_member_joining { |_ctx| raise Organizations::MembershipVetoed }
    end

    error = assert_raises(Organizations::MembershipVetoed) { @org.add_member!(@user) }
    assert_equal "You can't join this organization right now", error.message

    I18n.with_locale(:es) do
      spanish = assert_raises(Organizations::MembershipVetoed) { @org.add_member!(@user) }
      assert_equal "Ahora mismo no puedes unirte a esta organización", spanish.message
    end
  end

  test "no configured gate keeps every path working unchanged" do
    membership = @org.add_member!(@user)

    assert_predicate membership, :persisted?
  end

  test "the seat-limit pattern: one gate enforces caps across every join path" do
    # The exact pattern hosts should use (README "Limit seats per plan"):
    # cap at 2 members total for this org. lock! is part of the pattern —
    # the gate runs inside the creating transaction but does NOT serialize
    # on the org row, so hard caps must take the lock themselves (it also
    # refreshes member_count). Copy THIS shape, not a lockless one.
    Organizations.configure do |config|
      config.on_member_joining do |ctx|
        ctx.organization.lock!
        raise Organizations::MembershipVetoed, "Member limit reached" if ctx.organization.member_count >= 2
      end
    end

    @org.add_member!(@user) # 2nd member — allowed

    third = User.create!(email: "third-#{SecureRandom.hex(4)}@example.com")
    code = @org.generate_join_code!(auto_approve: true)
    assert_raises(Organizations::MembershipVetoed) do
      Organizations::JoinCode.redeem(code.code, user: third)
    end

    invitation = @org.send_invite_to!("fourth@example.com", invited_by: @owner)
    fourth = User.create!(email: "fourth@example.com")
    assert_raises(Organizations::MembershipVetoed) { invitation.accept!(fourth) }

    assert_equal 2, @org.reload.member_count
  end

  private

  # The gem-shipped helper (Organizations::TestHelpers) - hosts should use
  # this too instead of reverse-engineering the digest recipe.
  def extract_plaintext_code(request)
    issue_verification_code(request)
  end
end
# rubocop:enable Metrics/ClassLength
