# frozen_string_literal: true

require "test_helper"

# Vocabulary (issue #21, part 6): organization-specific wording, such as
# "Student" instead of "Member", without forking templates. Display text
# only: roles and permissions never change.
class VocabularyTest < Organizations::Test
  def setup
    super
    I18n.t(:"organizations.roles.owner") # load the locale files first, so the stores below win
    YAML.load_file(File.expand_path("fixtures/vocabulary.yml", __dir__)).each do |locale, tree|
      I18n.backend.store_translations(locale, tree)
    end
    @school, @teacher = create_org_with_owner!(name: "Riverside School")
    @library, = create_org_with_owner!(name: "City Library")
    @school.update!(metadata: { "vocabulary" => "classroom" })
    @library.update!(metadata: { "vocabulary" => "library" })
  end

  def teardown
    I18n.reload!
    super
  end

  test "the default configuration keeps today's translations" do
    assert_nil Organizations.configuration.vocabulary
    assert_equal "Member", Organizations.t("roles.member", organization: @school)
  end

  test "one vocabulary for the whole app" do
    Organizations.configure { |c| c.vocabulary = :classroom }

    assert_equal "Student", Organizations.t("roles.member")
    assert_equal "Student", Organizations.t("roles.member", organization: @library)
  end

  test "a vocabulary per organization from host-owned data" do
    use_resolver

    assert_equal "Student", Organizations.t("roles.member", organization: @school)
    assert_equal "Patron", Organizations.t("roles.member", organization: @library)
    assert_equal "Member", Organizations.t("roles.member"), "no organization: the resolver is not called"
  end

  test "two organizations interleaved never leak wording" do
    use_resolver

    labels = [@school, @library, @school, @library].map { |org| Organizations.t("roles.member", organization: org) }

    assert_equal %w[Student Patron Student Patron], labels
  end

  test "a partial vocabulary falls back to the ordinary key, host overrides included" do
    use_resolver
    I18n.backend.store_translations(:en, organizations: { roles: { owner: "Founder" } })

    assert_equal "Teacher", Organizations.t("roles.admin", organization: @school)
    assert_equal "Founder", Organizations.t("roles.owner", organization: @school)
    assert_equal "Admin", Organizations.t("roles.admin", organization: @library)
  end

  test "a resolver that returns nil selects the ordinary translations" do
    Organizations.configure { |c| c.vocabulary = ->(_org) {} }

    assert_equal "Member", Organizations.t("roles.member", organization: @school)
  end

  test "the caller's default comes after the vocabulary and the ordinary key" do
    use_resolver

    assert_equal "Student", Organizations.t("roles.member", organization: @school, default: "Fallback")
    assert_equal "Guest Speaker",
                 Organizations.t("roles.guest_speaker", organization: @school, default: "Guest Speaker")
  end

  test "count, interpolation and locale behave as in I18n" do
    use_resolver

    assert_equal "1 student", Organizations.t("members_count", organization: @school, count: 1)
    assert_equal "3 students", Organizations.t("members_count", organization: @school, count: 3)
    assert_equal "3 members", Organizations.t("members_count", organization: @library, count: 3)
    assert_equal "Alumno", Organizations.t("roles.member", organization: @school, locale: :es)
    I18n.with_locale(:es) { assert_equal "Alumno", Organizations.t("roles.member", organization: @school) }
  end

  test "an organization record interpolates its name" do
    use_resolver

    subject = Organizations.t(:"mailers.invitation.subject", inviter: "Ana", organization: @school)

    assert_equal "Ana added you to the class Riverside School", subject
  end

  test "a String organization keeps working as a plain interpolation" do
    use_resolver

    subject = Organizations.t(:"mailers.invitation.subject", inviter: "Ana", organization: "Acme")

    assert_equal I18n.t("organizations.mailers.invitation.subject", inviter: "Ana", organization: "Acme"), subject
  end

  test "i18n_keys gives the lookup chain for view translate helpers" do
    use_resolver

    assert_equal %i[organizations.vocabularies.classroom.roles.member organizations.roles.member],
                 Organizations.i18n_keys("roles.member", organization: @school)
    assert_equal %i[organizations.roles.member], Organizations.i18n_keys("roles.member", organization: nil)
  end

  test "roles and permissions are unchanged" do
    use_resolver
    student = create_user!
    membership = @school.add_member!(student)

    assert_equal "member", membership.role
    assert membership.has_permission_to?(:create_resources)
    refute membership.has_permission_to?(:invite_members)
  end

  # === Gem call sites pass the organization ===

  test "the invitation email uses the organization's wording" do
    use_resolver
    invitation = @school.send_invite_to!("kid@example.com", invited_by: @teacher)

    mail = Organizations::InvitationMailer.invitation_email(invitation)

    assert_match "added you to the class Riverside School", mail.subject
    assert_match "Student", mail.text_part.body.to_s
  end

  test "the role refusal message uses the organization's wording" do
    use_resolver
    student = create_user!
    @school.add_member!(student)
    lead = create_user!
    @school.add_member!(lead)

    error = assert_raises(Organizations::NotAuthorized) do
      @school.change_role_of!(lead, to: :admin, changed_by: student)
    end

    assert_match "Teacher", error.message
  end

  test "the role label view helper takes the organization explicitly" do
    use_resolver
    helper = Object.new.extend(Organizations::ViewHelpers)

    assert_equal "Student", helper.organization_role_label(:member, organization: @school)
    assert_equal "Member", helper.organization_role_label(:member)
    assert_equal "Patron", helper.organization_role_info(:member, organization: @library)[:label]
  end

  test "vocabulary must be nil, a Symbol, a String or callable" do
    assert_raises(Organizations::ConfigurationError) { Organizations.configure { |c| c.vocabulary = 42 } }
  end

  private

  def use_resolver
    Organizations.configure { |c| c.vocabulary = ->(org) { org.metadata["vocabulary"] } }
  end
end
