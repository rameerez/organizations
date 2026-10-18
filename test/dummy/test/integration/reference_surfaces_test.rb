# frozen_string_literal: true

require "test_helper"

# THE HTTP SMOKE of the 0.5.0 reference surfaces: drives the dummy's
# verified-joining screen (all four JoinState states) and the Access admin
# surface through the full Rack stack — routes, controllers, JoinFlow,
# JoinState, the views, and the REAL test database (so schema.rb regressions
# like a lost partial-index WHERE clause fail here, not in production).
#
# Run: cd test/dummy && bin/rails test test/integration/reference_surfaces_test.rb
#
# Assertions reference gem copy through Organizations.t — the en.yml catalog
# is the SSOT; hardcoding the English here would drift.
class ReferenceSurfacesTest < ActionDispatch::IntegrationTest
  setup do
    @owner = User.create!(email: "owner-#{SecureRandom.hex(4)}@example.com", name: "Owner")
    @org = Organizations::Organization.create_with_owner!(owner: @owner, name: "Acme Rocket Club")
  end

  teardown do
    # Tests that touch global gem config restore it here.
    Organizations.configuration = @saved_config if @saved_config
  end

  # ── The four-state join screen ─────────────────────────────────────────

  test "entry → wrong code → right code: the full code-join journey" do
    code = @org.generate_join_code!(label: "poster", created_by: @owner)
    sign_in_as "joiner-code@example.com"

    get organization_join_path(@org)
    assert_response :ok
    assert_match "Join #{@org.name}", response.body
    assert_match 'name="code"', response.body

    post organization_join_path(@org), params: { code: "WRONGCODE" }
    assert_response :unprocessable_entity
    assert_match Organizations.t(:"errors.join_code_invalid"), response.body

    post organization_join_path(@org), params: { code: code.display_code } # hyphenated form must normalize
    assert_redirected_to organization_join_path(@org)
    follow_redirect!
    assert_match "You're a member!", response.body

    membership = @org.memberships.joins(:user).find_by(users: { email: "joiner-code@example.com" })
    assert_equal "code", membership.joined_via
  end

  test "domain challenge: email → verifying state → code → member, with resend cooldown" do
    @org.add_domain!("acme.test")
    sign_in_as "personal-gmail@example.com"

    get organization_join_path(@org)
    assert_response :ok
    assert_match 'name="email"', response.body

    post organization_join_path(@org), params: { email: "j.doe@acme.test" }
    assert_response :see_other
    follow_redirect!
    assert_match "Check your inbox", response.body
    assert_match "j.doe@acme.test", response.body
    assert_match(/You can request another code in \d+s/, response.body,
                 "resend cooldown (JoinState#resend_seconds) must render right after a send")

    request = @org.join_requests.last
    known_code = Organizations::TestHelpers.issue_verification_code(request)

    post organization_join_path(@org), params: { verification_code: known_code }
    assert_redirected_to organization_join_path(@org)
    follow_redirect!
    assert_match "You're a member!", response.body

    membership = @org.memberships.find_by(user_id: request.user_id)
    assert_equal "j.doe@acme.test", membership.verified_email
    assert membership.verified?
  end

  test "manual-approval code parks the joiner in the pending state; withdraw returns to entry" do
    code = @org.generate_join_code!(auto_approve: false, created_by: @owner)
    sign_in_as "patient@example.com"

    post organization_join_path(@org), params: { code: code.code }
    assert_response :see_other
    follow_redirect!
    assert_match "Request pending", response.body

    delete organization_withdraw_join_path(@org)
    follow_redirect!
    assert_match "Join #{@org.name}", response.body, "after withdrawing, the screen must offer the entry state again"
  end

  # Pins the PARTIAL unique index on join requests (one PENDING request per
  # user/org — decided history must never block a fresh request). Under a
  # schema.rb that lost the index's WHERE clause this second request raises
  # ActiveRecord::RecordNotUnique and this test fails with a 500.
  test "a rejected request does not block requesting again" do
    code = @org.generate_join_code!(auto_approve: false, created_by: @owner)
    sign_in_as "persistent@example.com"

    post organization_join_path(@org), params: { code: code.code }
    assert_response :see_other
    follow_redirect!

    @org.reject_join_request!(@org.join_requests.pending.last, rejected_by: @owner)

    post organization_join_path(@org), params: { code: code.code }
    assert_response :see_other
    follow_redirect!
    assert_match "Request pending", response.body
    assert_equal 1, @org.join_requests.pending.count
    assert_equal 1, @org.join_requests.rejected.count
  end

  test "an org with no joining instruments shows the not-accepting message" do
    sign_in_as "hopeful@example.com"

    get organization_join_path(@org)
    assert_response :ok
    assert_match "not accepting join requests", response.body
  end

  # ── The membership gate over HTTP ──────────────────────────────────────

  test "an on_member_joining veto surfaces as a 422 with the host's message" do
    code = @org.generate_join_code!(created_by: @owner)

    @saved_config = Organizations.configuration
    Organizations.configuration = @saved_config.dup
    Organizations.configure do |config|
      config.on_member_joining { raise Organizations::MembershipVetoed, "Demo is full" }
    end

    sign_in_as "unlucky@example.com"
    post organization_join_path(@org), params: { code: code.code }

    assert_response :unprocessable_entity
    assert_match "Demo is full", response.body
    assert_equal 0, @org.memberships.where.not(role: "owner").count
    assert_equal 1, @org.join_requests.pending.count,
                 "a vetoed redemption must leave a PENDING (resumable) request behind"
  end

  # ── The Access admin surface (OrganizationScoped posture) ──────────────

  test "access surface: 200 for admins, 404 for members, strangers, and unknown orgs alike" do
    member = User.create!(email: "plain-member@example.com", name: "Member")
    @org.add_member!(member)

    sign_in_as @owner.email
    get organization_access_path(@org)
    assert_response :ok
    assert_match "Join codes", response.body

    sign_in_as member.email
    get organization_access_path(@org)
    assert_response :not_found

    sign_in_as "total-stranger@example.com"
    get organization_access_path(@org)
    assert_response :not_found

    sign_in_as @owner.email
    get organization_access_path(organization_id: @org.id + 10_000)
    assert_response :not_found
  end

  # ── The generated surfaces: safety rules over HTTP ─────────────────────

  test "a GET with ?code only fills in the form: it never joins or spends a use" do
    code = @org.generate_join_code!(created_by: @owner)
    sign_in_as "link-follower@example.com"

    get organization_join_path(@org, code: code.display_code)

    assert_response :ok
    assert_match %(value="#{code.display_code}"), response.body
    assert_equal 0, code.reload.uses_count
    assert_equal 1, @org.memberships.count
  end

  test "the entry state shows the disclosure before any submit" do
    @org.generate_join_code!(created_by: @owner)
    sign_in_as "careful@example.com"

    get organization_join_path(@org)

    assert_match "will see your name, your account email, and the email address", response.body
  end

  test "a plain request carries its note and lands in the pending state" do
    @org.generate_join_code!(auto_approve: false, created_by: @owner)
    sign_in_as "asker@example.com"

    get organization_join_path(@org)
    assert_match "Ask to join", response.body

    post organization_join_path(@org), params: { message: "I run the Madrid office" }
    follow_redirect!

    assert_match "Request pending", response.body
    assert_equal "I run the Madrid office", @org.join_requests.pending.last.message
  end

  test "access: invalid allowlist addresses are skipped and counted, never a 500" do
    sign_in_as @owner.email

    post organization_access_allowlist_path(@org), params: { emails: "ok@example.com, not-an-email, #{'a' * 300}@x.com" }
    follow_redirect!

    assert_equal ["ok@example.com"], @org.allowlist_entries.pluck(:email)
    assert_match "2 skipped", response.body
  end

  test "overlong inputs are cut before they reach the gem" do
    @org.generate_join_code!(auto_approve: false, created_by: @owner)
    sign_in_as "verbose@example.com"

    post organization_join_path(@org), params: { message: "x" * 5_000 }

    assert_operator @org.join_requests.last&.message.to_s.length, :<=, 500
  end

  test "access: an admin verifies a domain through the DNS challenge and sets the policy" do
    domain = @org.add_domain!("acme.test")
    sign_in_as @owner.email

    post organization_access_domain_verification_path(@org, domain_id: domain.id)
    assert_response :see_other
    domain.reload
    get organization_access_path(@org)
    assert_match domain.verification_record_value, response.body

    with_txt_records(domain.verification_record_name => [domain.verification_record_value]) do
      post organization_verify_access_domain_path(@org, domain_id: domain.id)
    end
    assert_predicate domain.reload, :verified?

    patch organization_access_domain_path(@org, domain_id: domain.id), params: { join_policy: "suggest" }
    assert_equal "suggest", domain.reload.join_policy
  end

  test "access: a failed DNS check shows its reason" do
    domain = @org.add_domain!("acme.test")
    domain.start_verification!
    sign_in_as @owner.email

    with_txt_records({}) do
      post organization_verify_access_domain_path(@org, domain_id: domain.id)
    end
    follow_redirect!

    assert_match Organizations.t(:"errors.domain_verification.record_not_found"), response.body
    refute_predicate domain.reload, :verified?
  end

  test "access: the allowlist can be imported and pruned" do
    sign_in_as @owner.email

    post organization_access_allowlist_path(@org), params: { emails: "ana@example.com, luis@example.com" }
    entry = @org.allowlist_entries.find_by(email: "ana@example.com")
    delete organization_access_allowlist_entry_path(@org, entry_id: entry.id)

    assert_equal ["luis@example.com"], @org.allowlist_entries.pluck(:email)
  end

  test "access: another organization's domain id is a 404" do
    other_owner = User.create!(email: "other-owner-#{SecureRandom.hex(3)}@example.com", name: "Other")
    other = Organizations::Organization.create_with_owner!(owner: other_owner, name: "Other Org")
    foreign = other.add_domain!("other.test")
    sign_in_as @owner.email

    delete organization_access_domain_path(@org, domain_id: foreign.id)

    assert_response :not_found
    assert Organizations::Domain.exists?(foreign.id)
  end

  test "access: domain changes need manage_settings; codes need invite_members" do
    recruiter = User.create!(email: "recruiter@example.com", name: "Recruiter")
    @saved_config = Organizations.configuration
    Organizations.configuration = @saved_config.dup
    Organizations.configure do |config|
      config.roles do
        role :recruiter, inherits: :member do
          can :invite_members
        end
      end
    end
    @org.add_member!(recruiter, role: :recruiter)
    sign_in_as recruiter.email

    get organization_access_path(@org)
    assert_response :ok
    post organization_access_domains_path(@org), params: { domain: "sneaky.test" }
    assert_response :not_found
    assert_empty @org.domains
  end

  private

  def with_txt_records(records)
    @saved_config ||= Organizations.configuration
    Organizations.configuration = Organizations.configuration.dup
    Organizations.configure { |config| config.domain_txt_resolver = ->(name) { records.fetch(name, []) } }
    yield
  ensure
    Organizations.configuration = @saved_config
  end

  # The dummy's real identity mechanism: the same endpoint a human clicks.
  def sign_in_as(email)
    post switch_user_path, params: { email: email }
  end
end
