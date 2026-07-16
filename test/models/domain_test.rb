# frozen_string_literal: true

require "test_helper"

module Organizations
  class DomainTest < Organizations::Test
    def setup
      super
      @org, @owner = create_org_with_owner!(name: "Inizio")
    end

    test "table_name is organizations_domains" do
      assert_equal "organizations_domains", Organizations::Domain.table_name
    end

    # =========================================================================
    # Creation & normalization
    # =========================================================================

    test "add_domain! creates a domain on the organization" do
      domain = @org.add_domain!("inizio.com")

      assert_predicate domain, :persisted?
      assert_equal @org, domain.organization
      assert_equal "inizio.com", domain.domain
    end

    test "normalizes case, whitespace, leading @ and trailing dot" do
      domain = @org.add_domain!("  @INIZIO.COM.  ")

      assert_equal "inizio.com", domain.domain
    end

    test "add_domain! carries membership_metadata (cohort copy-through source)" do
      domain = @org.add_domain!("alumnos.urjc.es", membership_metadata: { member_kind: "student" })

      assert_equal "student", domain.membership_metadata["member_kind"] || domain.membership_metadata[:member_kind]
    end

    test "rejects blank domains" do
      assert_raises(ActiveRecord::RecordInvalid) { @org.add_domain!("") }
    end

    test "rejects domains without a dot" do
      assert_raises(ActiveRecord::RecordInvalid) { @org.add_domain!("localhost") }
    end

    test "rejects domains with an @ inside" do
      assert_raises(ActiveRecord::RecordInvalid) { @org.add_domain!("user@inizio.com") }
    end

    test "rejects domains with spaces" do
      assert_raises(ActiveRecord::RecordInvalid) { @org.add_domain!("inizio .com") }
    end

    test "is unique per organization (case-insensitive via normalization)" do
      @org.add_domain!("inizio.com")
      assert_raises(ActiveRecord::RecordInvalid) { @org.add_domain!("INIZIO.com") }
    end

    test "the same domain can be enrolled by two different organizations" do
      other_org, = create_org_with_owner!(name: "Other")
      @org.add_domain!("shared.es")

      assert_predicate other_org.add_domain!("shared.es"), :persisted?
    end

    # =========================================================================
    # Matching (exact, dot-boundary safe)
    # =========================================================================

    test "matches_email? is exact" do
      domain = @org.add_domain!("urjc.es")

      assert domain.matches_email?("prof@urjc.es")
      assert domain.matches_email?("PROF@URJC.ES")
    end

    test "matches_email? does NOT match subdomains (E8 — different cohorts)" do
      domain = @org.add_domain!("urjc.es")

      refute domain.matches_email?("student@alumnos.urjc.es")
    end

    test "matches_email? rejects lookalike suffixes (E4)" do
      domain = @org.add_domain!("urjc.es")

      refute domain.matches_email?("x@urjc.es.evil.com")
      refute domain.matches_email?("x@evilurjc.es")
    end

    test "matches_email? rejects multi-@ evasion (E4)" do
      domain = @org.add_domain!("urjc.es")

      refute domain.matches_email?("x@urjc.es@evil.com")
    end

    test "matches_email? tolerates trailing-dot FQDN form" do
      domain = @org.add_domain!("urjc.es")

      assert domain.matches_email?("prof@urjc.es.")
    end

    test "matching_email scope finds candidate org domains across organizations" do
      d1 = @org.add_domain!("shared.es")
      other_org, = create_org_with_owner!(name: "Other")
      d2 = other_org.add_domain!("shared.es")

      matches = Organizations::Domain.matching_email("someone@shared.es")

      assert_equal [d1.id, d2.id].sort, matches.map(&:id).sort
    end

    test "matching_email scope returns none for evasion shapes" do
      @org.add_domain!("urjc.es")

      assert_empty Organizations::Domain.matching_email("x@urjc.es@evil.com")
      assert_empty Organizations::Domain.matching_email("")
    end

    test "destroyed with the organization" do
      @org.add_domain!("inizio.com")
      @org.destroy!

      assert_equal 0, Organizations::Domain.count
    end
  end
end
