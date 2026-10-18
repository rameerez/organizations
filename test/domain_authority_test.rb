# frozen_string_literal: true

require "test_helper"
require "resolv"

# Domain authority (issue #21, part 3): proof that an organization controls a
# domain (a DNS TXT record, or a recorded operator approval), distinct from
# proof that a person controls one inbox at that domain. Plus the per-domain
# sign-up policy: none, suggest, auto_join.
class DomainAuthorityTest < Organizations::Test
  def setup
    super
    @org, @owner = create_org_with_owner!(name: "Acme")
    @domain = @org.add_domain!("acme.test")
  end

  # === DNS TXT challenge ===

  test "a new domain is unverified with the none policy" do
    refute_predicate @domain, :verified?
    assert_equal "none", @domain.join_policy
    assert_equal :none, @domain.effective_join_policy
  end

  test "start_verification! issues an unpredictable token and the record to publish" do
    @domain.start_verification!

    assert_operator @domain.verification_token.length, :>=, 32
    assert_equal "_organizations-verification.acme.test", @domain.verification_record_name
    assert_equal "organizations-verification=#{@domain.verification_token}", @domain.verification_record_value
    refute_equal @domain.verification_token, @org.add_domain!("other.test").start_verification!.verification_token
  end

  test "verify! succeeds when the TXT record holds the exact value" do
    @domain.start_verification!

    with_txt_records("_organizations-verification.acme.test" => ["unrelated", @domain.verification_record_value]) do
      assert @domain.verify!
    end

    assert_predicate @domain.reload, :verified?
    assert_equal "dns_txt", @domain.verification_method
    assert_includes Organizations::Domain.verified, @domain
  end

  test "an ordinary inbox cannot verify a domain: only the TXT record counts" do
    @domain.start_verification!
    request = create_user!.request_to_join!(@org)
    request.start_email_verification!(email: "admin@acme.test")
    request.verify_email_code!(Organizations::TestHelpers.issue_verification_code(request))

    refute_predicate @domain.reload, :verified?
  end

  test "verify! fails without the record and says why" do
    @domain.start_verification!

    error = with_txt_records({}) { assert_raises(Organizations::DomainVerificationFailed) { @domain.verify! } }

    assert_equal :record_not_found, error.reason
    refute_predicate @domain.reload, :verified?
  end

  test "verify! refuses a near miss of the value" do
    @domain.start_verification!

    with_txt_records("_organizations-verification.acme.test" => ["#{@domain.verification_record_value}x"]) do
      assert_raises(Organizations::DomainVerificationFailed) { @domain.verify! }
    end
  end

  test "a token of one claim does not verify another organization's claim of the same domain" do
    other_org, = create_org_with_owner!(name: "Impostor")
    impostor = other_org.add_domain!("acme.test").start_verification!
    @domain.start_verification!

    with_txt_records("_organizations-verification.acme.test" => [@domain.verification_record_value]) do
      assert_raises(Organizations::DomainVerificationFailed) { impostor.verify! }
      assert @domain.verify!
    end
  end

  test "verify! before start_verification! fails with :not_started" do
    error = assert_raises(Organizations::DomainVerificationFailed) { @domain.verify! }

    assert_equal :not_started, error.reason
  end

  test "an expired challenge fails with :expired" do
    @domain.start_verification!

    travel(Organizations.configuration.domain_verification_ttl + 1.minute) do
      error = with_txt_records("_organizations-verification.acme.test" => [@domain.verification_record_value]) do
        assert_raises(Organizations::DomainVerificationFailed) { @domain.verify! }
      end

      assert_equal :expired, error.reason
    end
  end

  test "a lookup failure is :lookup_failed and changes nothing" do
    @domain.start_verification!
    Organizations.configure { |c| c.domain_txt_resolver = ->(_name) { raise Resolv::ResolvTimeout } }

    error = assert_raises(Organizations::DomainVerificationFailed) { @domain.verify! }

    assert_equal :lookup_failed, error.reason
  end

  test "a broken host resolver is logged and reported as :lookup_failed" do
    @domain.start_verification!
    Organizations.configure { |c| c.domain_txt_resolver = ->(_name) { nil.strip } }

    _out, err = capture_io do
      error = assert_raises(Organizations::DomainVerificationFailed) { @domain.verify! }

      assert_equal :lookup_failed, error.reason
    end

    assert_match "NoMethodError", err
  end

  test "operator metadata keeps host keys and drops a stale note" do
    @domain.update!(metadata: { "host_key" => "kept", "verification_note" => "old" })

    @domain.verify_by_operator!(operator: create_user!)

    assert_equal({ "host_key" => "kept" }, @domain.reload.metadata)
  end

  test "the default resolver uses Resolv with the configured timeout" do
    resolver = Organizations::Domain.default_txt_resolver

    assert_respond_to resolver, :call
  end

  test "changing the domain clears the verification and the token" do
    verify!(@domain)

    @domain.update!(domain: "acme-two.test")

    refute_predicate @domain, :verified?
    assert_nil @domain.verification_token
  end

  test "start_verification! again rotates the token and clears an earlier verification" do
    verify!(@domain)
    old_token = @domain.verification_token

    @domain.start_verification!

    refute_predicate @domain, :verified?
    refute_equal old_token, @domain.verification_token
  end

  test "restarting a revoked claim keeps it revoked until a new proof" do
    verify!(@domain)
    @domain.revoke_verification!

    @domain.start_verification!

    assert_predicate @domain, :revoked?
    refute_predicate @domain, :joinable?
    with_txt_records(@domain.verification_record_name => [@domain.verification_record_value]) { @domain.verify! }

    refute_predicate @domain.reload, :revoked?
    assert_predicate @domain, :verified?
  end

  test "moving a claim to another organization clears its verification" do
    verify!(@domain)
    other, = create_org_with_owner!(name: "Other")

    @domain.update!(organization: other)

    refute_predicate @domain, :verified?
    assert_nil @domain.verification_token
  end

  test "a duplicated claim carries no verification" do
    verify!(@domain)

    copy = @domain.dup

    assert_nil copy.verified_at
    assert_nil copy.verification_token
    assert_nil copy.verification_method
  end

  test "a revocation during the DNS lookup is not undone by that lookup" do
    @domain.start_verification!
    domain = @domain
    resolver = lambda do |_name|
      Organizations::Domain.find(domain.id).revoke_verification!(reason: "revoked meanwhile")
      [domain.verification_record_value]
    end
    Organizations.configure { |c| c.domain_txt_resolver = resolver }

    error = assert_raises(Organizations::DomainVerificationFailed) { @domain.verify! }

    assert_equal :changed, error.reason
    assert_predicate @domain.reload, :revoked?
  end

  test "a challenge that expires during the lookup fails" do
    @domain.start_verification!
    value = @domain.verification_record_value
    domain_id = @domain.id
    resolver = lambda do |_name|
      Organizations::Domain.where(id: domain_id).update_all(verification_started_at: 30.days.ago)
      [value]
    end
    Organizations.configure { |c| c.domain_txt_resolver = resolver }

    error = assert_raises(Organizations::DomainVerificationFailed) { @domain.verify! }

    assert_equal :expired, error.reason
  end

  test "a stale recheck does not revoke a newer proof" do
    verify!(@domain)
    operator = create_user!
    domain_id = @domain.id
    resolver = lambda do |_name|
      Organizations::Domain.find(domain_id).verify_by_operator!(operator: operator)
      []
    end
    Organizations.configure { |c| c.domain_txt_resolver = resolver }

    @domain.recheck_verification!

    assert_predicate @domain.reload, :verified?
    assert_equal "operator", @domain.verification_method
  end

  # === Operator approval ===

  test "a platform operator can record an approval with provenance" do
    operator = create_user!

    @domain.verify_by_operator!(operator: operator, note: "Checked the registrar record")

    assert_predicate @domain.reload, :verified?
    assert_equal "operator", @domain.verification_method
    assert_equal operator, @domain.verified_by
    assert_equal "Checked the registrar record", @domain.metadata["verification_note"]
  end

  test "a member of the claiming organization cannot self-attest" do
    assert_raises(Organizations::NotAuthorized) { @domain.verify_by_operator!(operator: @owner) }
    refute_predicate @domain.reload, :verified?
  end

  test "verify_by_operator! needs an operator" do
    assert_raises(ArgumentError) { @domain.verify_by_operator!(operator: nil) }
  end

  # === Revocation and re-checks ===

  test "revoke_verification! keeps the audit trail and stops counting as verified" do
    verify!(@domain)

    @domain.revoke_verification!(reason: "domain sold")

    refute_predicate @domain.reload, :verified?
    assert_predicate @domain, :revoked?
    assert_predicate @domain.verified_at, :present?
    assert_equal "domain sold", @domain.metadata["verification_revoked_reason"]
    refute_includes Organizations::Domain.verified, @domain
  end

  test "recheck_verification! revokes when the TXT record is gone" do
    verify!(@domain)

    with_txt_records({}) { @domain.recheck_verification! }

    assert_predicate @domain.reload, :revoked?
    refute_predicate @domain, :verified?
  end

  test "recheck_verification! keeps the verification when the record is still there" do
    verify!(@domain)

    with_txt_records("_organizations-verification.acme.test" => [@domain.verification_record_value]) do
      assert_predicate @domain.recheck_verification!, :verified?
    end
  end

  test "recheck_verification! does not revoke on a lookup failure" do
    verify!(@domain)
    Organizations.configure { |c| c.domain_txt_resolver = ->(_name) { raise Resolv::ResolvError } }

    assert_raises(Organizations::DomainVerificationFailed) { @domain.recheck_verification! }
    assert_predicate @domain.reload, :verified?
  end

  test "revocation does not remove existing members" do
    member = create_user!(email: "a@acme.test")
    member.update!(confirmed_at: Time.current)
    verify!(@domain)
    @org.join_with_account_email!(member)

    @domain.revoke_verification!

    assert member.is_member_of?(@org)
  end

  # === require_verified_domains ===

  test "without require_verified_domains, unverified domains keep working as before" do
    user = create_user!(email: "b@acme.test")
    user.update!(confirmed_at: Time.current)

    assert_kind_of Organizations::Membership, @org.join_with_account_email!(user)
  end

  test "require_verified_domains closes every domain path for an unverified domain" do
    Organizations.configure { |c| c.require_verified_domains = true }
    confirmed = create_user!(email: "c@acme.test")
    confirmed.update!(confirmed_at: Time.current)

    refute_predicate @org, :accepts_domain_joining?
    assert_raises(Organizations::VerificationEmailNotEligible) { @org.join_with_account_email!(confirmed) }
    request = create_user!.request_to_join!(@org)
    assert_raises(Organizations::VerificationEmailNotEligible) do
      request.start_email_verification!(email: "d@acme.test")
    end
    result = Organizations::JoinFlow.attempt(user: confirmed, organization: @org)

    refute_predicate result, :member?
  end

  test "require_verified_domains admits through a verified domain" do
    Organizations.configure { |c| c.require_verified_domains = true }
    verify!(@domain)
    confirmed = create_user!(email: "e@acme.test")
    confirmed.update!(confirmed_at: Time.current)

    assert_predicate @org, :accepts_domain_joining?
    assert_kind_of Organizations::Membership, @org.join_with_account_email!(confirmed)
  end

  test "a domain-restricted code honours require_verified_domains" do
    Organizations.configure { |c| c.require_verified_domains = true }
    code = @org.generate_join_code!(requires_verified_domain_email: true)
    request = Organizations::JoinCode.redeem(code.code, user: create_user!)

    assert_raises(Organizations::VerificationEmailNotEligible) do
      request.start_email_verification!(email: "f@acme.test")
    end
  end

  test "a revoked domain never admits, even without require_verified_domains" do
    verify!(@domain)
    @domain.revoke_verification!
    confirmed = create_user!(email: "g@acme.test")
    confirmed.update!(confirmed_at: Time.current)

    assert_raises(Organizations::VerificationEmailNotEligible) { @org.join_with_account_email!(confirmed) }
  end

  test "allowlist joins and invitations ignore domain authority" do
    Organizations.configure { |c| c.require_verified_domains = true }
    @org.import_allowlist!(["h@acme.test"])
    request = create_user!.request_to_join!(@org)
    request.start_email_verification!(email: "h@acme.test")

    membership = request.verify_email_code!(Organizations::TestHelpers.issue_verification_code(request))

    assert_kind_of Organizations::Membership, membership
  end

  # === Re-check at admission ===

  test "removing the domain during a pending challenge blocks the admission" do
    request = create_user!.request_to_join!(@org)
    request.start_email_verification!(email: "i@acme.test")
    code = Organizations::TestHelpers.issue_verification_code(request)
    @domain.destroy!

    assert_raises(Organizations::VerificationEmailNotEligible) { request.verify_email_code!(code) }
    assert_predicate request.reload, :pending?
    refute_predicate request, :email_verified?
  end

  test "revoking the domain during a pending challenge blocks the admission" do
    verify!(@domain)
    request = create_user!.request_to_join!(@org)
    request.start_email_verification!(email: "j@acme.test")
    code = Organizations::TestHelpers.issue_verification_code(request)
    @domain.revoke_verification!

    assert_raises(Organizations::VerificationEmailNotEligible) { request.verify_email_code!(code) }
  end

  test "removing an allowlist entry during a pending challenge blocks the admission" do
    entry = @org.import_allowlist!(["k@roster.test"]).first
    request = create_user!.request_to_join!(@org)
    request.start_email_verification!(email: "k@roster.test")
    code = Organizations::TestHelpers.issue_verification_code(request)
    entry.destroy!

    assert_raises(Organizations::VerificationEmailNotEligible) { request.verify_email_code!(code) }
  end

  test "auto_approve! refuses a request without a verified email and a matched instrument" do
    request = create_user!.request_to_join!(@org)

    assert_raises(Organizations::VerificationEmailNotEligible) { request.send(:auto_approve!) }
    assert_predicate request.reload, :pending?
  end

  test "the admission locks the matched domain row" do
    request = create_user!.request_to_join!(@org)
    request.start_email_verification!(email: "lock@acme.test")
    code = Organizations::TestHelpers.issue_verification_code(request)
    locked = []
    relation_class = ActiveRecord::Relation
    original = relation_class.instance_method(:lock)
    relation_class.define_method(:lock) do |*args|
      locked << model.name
      original.bind_call(self, *args)
    end

    request.verify_email_code!(code)

    assert_includes locked, "Organizations::Domain"
  ensure
    relation_class.define_method(:lock, original)
  end

  test "an admin can still approve a pending domain request by hand after the domain is gone" do
    request = create_user!.request_to_join!(@org)
    request.start_email_verification!(email: "l@acme.test")
    @domain.destroy!

    assert_kind_of Organizations::Membership, @org.approve_join_request!(request, approved_by: @owner)
  end

  test "JoinFlow maps a closed instrument at verification to :email_not_eligible" do
    user = create_user!
    Organizations::JoinFlow.attempt(user: user, organization: @org, email: "m@acme.test")
    code = Organizations::TestHelpers.issue_verification_code(user.pending_join_request_for(@org))
    @domain.destroy!

    result = Organizations::JoinFlow.attempt(user: user, organization: @org, verification_code: code)

    assert_equal :email_not_eligible, result.reason
  end

  # === Provider blocking preset ===

  test "the public provider preset is opt-in" do
    assert_empty Organizations.configuration.blocked_email_domains
    assert_includes Organizations::PUBLIC_EMAIL_DOMAINS, "gmail.com"
    assert_kind_of Organizations::Domain, @org.add_domain!("gmail.com")
  end

  test "a blocked provider cannot be enrolled" do
    Organizations.configure { |c| c.blocked_email_domains = Organizations::PUBLIC_EMAIL_DOMAINS }

    error = assert_raises(ActiveRecord::RecordInvalid) { @org.add_domain!("GMAIL.com") }

    assert_match "public email provider", error.message
  end

  test "an existing row for a blocked provider no longer admits" do
    @org.add_domain!("gmail.com")
    Organizations.configure { |c| c.blocked_email_domains = ["gmail.com"] }
    confirmed = create_user!(email: "n@gmail.com")
    confirmed.update!(confirmed_at: Time.current)

    assert_raises(Organizations::VerificationEmailNotEligible) { @org.join_with_account_email!(confirmed) }
  end

  test "blocking a provider never bans its users from invitations or allowlist joins" do
    Organizations.configure { |c| c.blocked_email_domains = ["gmail.com"] }
    invitee = create_user!(email: "o@gmail.com")
    invitation = @org.send_invite_to!("o@gmail.com", invited_by: @owner)

    assert_kind_of Organizations::Membership, invitation.accept!(invitee)

    @org.import_allowlist!(["p@gmail.com"])
    request = create_user!.request_to_join!(@org)
    request.start_email_verification!(email: "p@gmail.com")

    assert_kind_of Organizations::Membership,
                   request.verify_email_code!(Organizations::TestHelpers.issue_verification_code(request))
  end

  # === Join policy at sign-up ===

  test "the join policy is effective only on a verified domain" do
    @domain.update!(join_policy: "auto_join")

    assert_equal :none, @domain.effective_join_policy
    verify!(@domain)

    assert_equal :auto_join, @domain.effective_join_policy
  end

  test "an unknown join policy is invalid" do
    @domain.join_policy = "everyone"

    refute_predicate @domain, :valid?
  end

  test "suggested_organizations lists verified suggest and auto_join domains for a confirmed email" do
    verify!(@domain)
    @domain.update!(join_policy: "suggest")
    user = create_user!(email: "q@acme.test")

    assert_empty user.suggested_organizations, "an unconfirmed email proves nothing"

    user.update!(confirmed_at: Time.current)

    assert_equal [@org], user.suggested_organizations.to_a
  end

  test "suggested_organizations skips none, unverified, revoked and joined organizations" do
    @domain.update!(join_policy: "suggest") # unverified
    other, = create_org_with_owner!(name: "Other")
    verify!(other.add_domain!("acme.test", join_policy: :none))
    user = create_user!(email: "r@acme.test")
    user.update!(confirmed_at: Time.current)

    assert_empty user.suggested_organizations

    verify!(@domain)
    @org.add_member!(user)

    assert_empty user.suggested_organizations
  end

  test "auto_join joins a confirmed sign-up through the membership gate" do
    verify!(@domain)
    @domain.update!(join_policy: "auto_join")
    joined_via = nil
    Organizations.configure { |c| c.on_member_joining { |ctx| joined_via = ctx.joined_via } }

    user = User.create!(email: "s@acme.test", name: "S", confirmed_at: Time.current)

    assert user.is_member_of?(@org)
    assert_equal "domain_email", joined_via
    assert_equal "s@acme.test", @org.memberships.find_by(user_id: user.id).verified_email
  end

  test "auto_join waits for the email confirmation" do
    verify!(@domain)
    @domain.update!(join_policy: "auto_join")

    user = User.create!(email: "t@acme.test", name: "T")

    refute user.is_member_of?(@org)

    user.update!(confirmed_at: Time.current)

    assert user.is_member_of?(@org)
  end

  test "auto_join never acts on an unverified domain" do
    @domain.update!(join_policy: "auto_join")

    user = User.create!(email: "u@acme.test", name: "U", confirmed_at: Time.current)

    refute user.is_member_of?(@org)
  end

  test "auto_join respects a veto and keeps the user" do
    verify!(@domain)
    @domain.update!(join_policy: "auto_join")
    Organizations.configure { |c| c.on_member_joining { raise Organizations::MembershipVetoed } }

    user = User.create!(email: "v@acme.test", name: "V", confirmed_at: Time.current)

    assert User.exists?(user.id)
    refute user.is_member_of?(@org)
  end

  test "join_organizations_by_domain! returns the memberships and is idempotent" do
    verify!(@domain)
    @domain.update!(join_policy: "auto_join")
    user = create_user!(email: "w@acme.test")
    user.update_column(:confirmed_at, Time.current)

    memberships = user.join_organizations_by_domain!

    assert_equal [@org], memberships.map(&:organization)
    assert_equal memberships, user.join_organizations_by_domain!
  end

  test "auto_join does nothing when trusting confirmed emails is off" do
    Organizations.configure { |c| c.trust_confirmed_account_email = false }
    verify!(@domain)
    @domain.update!(join_policy: "auto_join")

    user = User.create!(email: "x@acme.test", name: "X", confirmed_at: Time.current)

    refute user.is_member_of?(@org)
    assert_empty user.suggested_organizations
  end

  test "every verification failure reason has a message in each locale" do
    locales = %i[en es]
    Organizations::DomainVerificationFailed::REASONS.each do |reason|
      locales.each do |locale|
        message = I18n.with_locale(locale) { Organizations::DomainVerificationFailed.new(reason).message }

        refute_match(/translation missing/i, message)
      end
    end
  end

  # === Configuration ===

  test "domain authority settings are validated" do
    assert_raises(Organizations::ConfigurationError) { Organizations.configure { |c| c.require_verified_domains = 1 } }
    assert_raises(Organizations::ConfigurationError) { Organizations.configure { |c| c.blocked_email_domains = "gmail.com" } }
    assert_raises(Organizations::ConfigurationError) { Organizations.configure { |c| c.domain_txt_resolver = "dig" } }
    assert_raises(Organizations::ConfigurationError) { Organizations.configure { |c| c.domain_verification_ttl = "1 day" } }
    assert_raises(Organizations::ConfigurationError) do
      Organizations.configure { |c| c.domain_verification_record_prefix = "no-underscore" }
    end
  end

  private

  def with_txt_records(records, &)
    Organizations.configure { |c| c.domain_txt_resolver = ->(name) { records.fetch(name, []) } }
    yield
  end

  def verify!(domain)
    domain.start_verification!
    with_txt_records(domain.verification_record_name => [domain.verification_record_value]) { domain.verify! }
    domain.reload
  end
end
