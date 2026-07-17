# frozen_string_literal: true

require "test_helper"

# The i18n layer: every user-facing string the gem produces resolves through
# Organizations.t against config/locales/*.yml (en = catalog SSOT, es shipped).
#
# These tests pin three contracts:
#   1. en.yml answers every key the code raises/labels with (no
#      "Translation missing" ever reaches a user in the default locale).
#   2. es.yml has full key parity with en.yml (a key added to one file but
#      not the other is a bug — CI catches it here, not a Spanish user).
#   3. Locale switching actually changes the produced strings (errors,
#      labels, mailer subjects) — the whole point of the layer.
class I18nTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  def setup
    Organizations.reset_configuration!
    @user = User.create!(email: "i18n-#{SecureRandom.hex(4)}@example.com", name: "I18n User")
    @org = Organizations::Organization.create!(name: "Localized Org")
    Organizations::Membership.create!(user: @user, organization: @org, role: "owner")
  end

  def teardown
    I18n.locale = I18n.default_locale
    Organizations.reset_configuration!
  end

  # === Catalog integrity ===

  test "es.yml has full key parity with en.yml" do
    en = flatten_keys(load_locale("en"))
    es = flatten_keys(load_locale("es"))

    missing_in_es = en - es
    extra_in_es = es - en

    assert_empty missing_in_es, "Keys present in en.yml but missing in es.yml: #{missing_in_es.join(', ')}"
    assert_empty extra_in_es, "Keys present in es.yml but missing in en.yml: #{extra_in_es.join(', ')}"
  end

  test "every Organizations.t call site in lib/ and app/ has an en.yml key" do
    en = flatten_keys(load_locale("en"))

    # Static keys only — interpolated key paths (roles.#{role} etc.) are
    # exercised by the behavioral tests below.
    called_keys = []
    Dir[File.expand_path("../{lib,app}/**/*.{rb,erb}", __dir__)].each do |file|
      File.read(file).scan(/Organizations\.t\(:"([^"#]+)"/) { |match| called_keys << match.first }
      File.read(file).scan(/t\("organizations\.([^"#]+)"/) { |match| called_keys << match.first }
    end

    missing = called_keys.uniq - en

    assert_empty missing, "Organizations.t call sites without an en.yml key: #{missing.join(', ')}"
  end

  # Key families addressed with interpolated key paths (roles.#{role} etc.)
  # rather than static literals — exempt from the dead-key sweep below.
  DYNAMIC_KEY_FAMILIES = %w[roles. invitation_status. join_request_status.].freeze

  test "every en.yml key is referenced from lib/ or app/ (no dead catalog keys)" do
    en = flatten_keys(load_locale("en"))
    source = Dir[File.expand_path("../{lib,app}/**/*.{rb,erb}", __dir__)]
      .map { |file| File.read(file) }.join("\n")

    dead = en.reject do |key|
      DYNAMIC_KEY_FAMILIES.any? { |family| key.start_with?(family) } || source.include?(key)
    end

    assert_empty dead,
                 "en.yml keys never referenced from lib/ or app/ (drifted catalog): #{dead.join(', ')}"
  end

  test "en.yml and es.yml agree on interpolation variables for every key" do
    en = flatten_pairs(load_locale("en"))
    es = flatten_pairs(load_locale("es"))

    mismatched = en.keys.select do |key|
      next false unless es.key?(key)

      en[key].to_s.scan(/%\{(\w+)\}/).sort != es[key].to_s.scan(/%\{(\w+)\}/).sort
    end

    assert_empty mismatched,
                 "Keys whose %{...} interpolation variables differ between en and es " \
                 "(raises MissingInterpolationArgument at runtime in one locale): #{mismatched.join(', ')}"
  end

  # === Behavioral: errors localize ===

  test "error messages resolve from the catalog in English" do
    error = assert_raises(Organizations::JoinCodeInvalid) do
      Organizations::JoinCode.redeem("NOPE-NOPE", user: @user)
    end
    assert_equal "This code is not valid", error.message
  end

  test "error messages localize to Spanish" do
    I18n.with_locale(:es) do
      error = assert_raises(Organizations::JoinCodeInvalid) do
        Organizations::JoinCode.redeem("NOPE-NOPE", user: @user)
      end
      assert_equal "Este código no es válido", error.message
    end
  end

  test "already-decided message interpolates a translated status word" do
    other = User.create!(email: "requester-#{SecureRandom.hex(4)}@example.com")
    request = other.request_to_join!(@org)
    request.reject!(rejected_by: @user)

    error = assert_raises(Organizations::JoinRequestAlreadyDecided) { request.withdraw! }
    assert_equal "This join request has already been rejected", error.message

    I18n.with_locale(:es) do
      spanish = assert_raises(Organizations::JoinRequestAlreadyDecided) { request.withdraw! }
      assert_equal "Esta solicitud ya está rechazada", spanish.message
    end
  end

  test "validation messages localize at validation time" do
    other = User.create!(email: "dup-#{SecureRandom.hex(4)}@example.com")
    @org.add_member!(other)

    duplicate = Organizations::Membership.new(user: other, organization: @org, role: "member")

    refute_predicate duplicate, :valid?
    assert_includes duplicate.errors[:user_id], "is already a member of this organization"

    I18n.with_locale(:es) do
      refute_predicate duplicate, :valid?
      assert_includes duplicate.errors[:user_id], "ya es miembro de esta organización"
    end
  end

  # === Behavioral: mailer copy localizes ===

  # Mailer tests render the Mail::Message DIRECTLY (mailer.code_email(...))
  # instead of round-tripping through deliver_later + the ActiveJob test
  # adapter — this plain-ActiveRecord test env has no Rails job plumbing, and
  # what we're pinning is the COPY, which is fixed at render time anyway.
  test "verification mailer subject and body localize" do
    @org.add_domain!("example.com")
    requester = User.create!(email: "verify-#{SecureRandom.hex(4)}@example.com")
    request = requester.request_to_join!(@org)
    request.update!(verification_email: "someone@example.com")

    english = Organizations::VerificationMailer.code_email(request, "123456")

    assert_equal "123456 is your Localized Org verification code", english.subject

    I18n.with_locale(:es) do
      spanish = Organizations::VerificationMailer.code_email(request, "123456")

      assert_equal "123456 es tu código de verificación de Localized Org", spanish.subject
      # Multipart mail: `body.to_s` is empty on a multipart — read the part.
      body = spanish.text_part ? spanish.text_part.body.to_s : spanish.body.to_s

      assert_match(/El código caduca en \d+ minutos/, body)
    end
  end

  test "invitation mailer subject and body localize" do
    invitation = @org.send_invite_to!("invitee-es@example.com", invited_by: @user)

    I18n.with_locale(:es) do
      mail = Organizations::InvitationMailer.invitation_email(invitation)

      assert_equal "I18n User te ha invitado a unirte a Localized Org", mail.subject
      body = mail.text_part ? mail.text_part.body.to_s : mail.body.to_s

      assert_match(/Te unirás como: Miembro/, body)
    end
  end

  # === Behavioral: labels localize ===

  test "role and invitation status labels localize" do
    helper = Object.new.extend(Organizations::ViewHelpers)

    assert_equal "Owner", helper.organization_role_label(:owner)
    I18n.with_locale(:es) { assert_equal "Propietario", helper.organization_role_label(:owner) }

    # Custom roles without a catalog key fall back to humanize
    assert_equal "Superfan", helper.organization_role_label(:superfan)
  end

  test "host locale files override gem keys" do
    # Simulate a host override: app locale files load AFTER engine files,
    # which in I18n's simple backend means store_translations wins.
    I18n.backend.store_translations(:en, organizations: { errors: { join_code_invalid: "Nope!" } })

    error = assert_raises(Organizations::JoinCodeInvalid) do
      Organizations::JoinCode.redeem("NOPE-NOPE", user: @user)
    end
    assert_equal "Nope!", error.message
  ensure
    I18n.backend.reload!
    I18n.load_path |= Dir[File.expand_path("../config/locales/*.yml", __dir__)]
  end

  private

  def load_locale(locale)
    # Dig into the `organizations:` subtree so flattened keys match the
    # relative keys used at Organizations.t call sites.
    YAML.safe_load_file(File.expand_path("../config/locales/#{locale}.yml", __dir__))
      .fetch(locale).fetch("organizations")
  end

  def flatten_keys(hash, prefix = nil)
    hash.flat_map do |key, value|
      full = [prefix, key].compact.join(".")
      value.is_a?(Hash) ? flatten_keys(value, full) : [full]
    end
  end

  def flatten_pairs(hash, prefix = nil)
    hash.flat_map do |key, value|
      full = [prefix, key].compact.join(".")
      value.is_a?(Hash) ? flatten_pairs(value, full).to_a : [[full, value]]
    end.to_h
  end
end
