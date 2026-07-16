# frozen_string_literal: true

require "test_helper"

module Organizations
  class AllowlistEntryTest < Organizations::Test
    def setup
      super
      @org, @owner = create_org_with_owner!(name: "Iberozoa")
      @user = create_user!(email: "ana.personal@gmail.com", name: "Ana")
    end

    test "table_name is organizations_allowlist_entries" do
      assert_equal "organizations_allowlist_entries", Organizations::AllowlistEntry.table_name
    end

    # =========================================================================
    # Creation & normalization
    # =========================================================================

    test "stores the email as provided and a normalized twin" do
      entry = @org.allowlist_entries.create!(email: "Ana+Socia@Gmail.com")

      assert_equal "Ana+Socia@Gmail.com", entry.email
      assert_equal "ana@gmail.com", entry.email_normalized
    end

    test "rejects invalid email shapes" do
      assert_raises(ActiveRecord::RecordInvalid) { @org.allowlist_entries.create!(email: "not-an-email") }
    end

    test "unique per organization on the NORMALIZED form (plus-tag aliases collide)" do
      @org.allowlist_entries.create!(email: "ana@gmail.com")
      assert_raises(ActiveRecord::RecordInvalid) { @org.allowlist_entries.create!(email: "ANA+bis@gmail.com") }
    end

    test "the same email can be rostered by two different organizations" do
      other_org, = create_org_with_owner!(name: "Other")
      @org.allowlist_entries.create!(email: "ana@gmail.com")

      assert_predicate other_org.allowlist_entries.create!(email: "ana@gmail.com"), :persisted?
    end

    # =========================================================================
    # import_allowlist!
    # =========================================================================

    test "import_allowlist! bulk-creates entries with source and metadata" do
      entries = @org.import_allowlist!(
        ["ana@gmail.com", "luis@yahoo.es"],
        source: "csv_2026-07",
        membership_metadata: { member_kind: "member" }
      )

      assert_equal 2, entries.size
      assert(entries.all? { |e| e.source == "csv_2026-07" })
      assert_equal "member",
                   entries.first.membership_metadata["member_kind"] || entries.first.membership_metadata[:member_kind]
    end

    test "import_allowlist! is idempotent — duplicates are skipped, not duplicated" do
      @org.import_allowlist!(["ana@gmail.com"])
      created = @org.import_allowlist!(["ana@gmail.com", "nuevo@gmail.com"])

      assert_equal ["nuevo@gmail.com"], created.map(&:email)
      assert_equal 2, @org.allowlist_entries.count
    end

    test "import_allowlist! raises loudly on invalid addresses (bad CSV rows must not vanish silently)" do
      assert_raises(ActiveRecord::RecordInvalid) do
        @org.import_allowlist!(["ok@gmail.com", "broken-row"])
      end
    end

    # =========================================================================
    # Scopes & claiming
    # =========================================================================

    test "for_email matches through the normalizer" do
      entry = @org.allowlist_entries.create!(email: "ana@gmail.com")

      assert_equal [entry], @org.allowlist_entries.for_email("ANA+x@gmail.com").to_a
    end

    test "unclaimed excludes claimed entries" do
      entry = @org.allowlist_entries.create!(email: "ana@gmail.com")

      assert_includes @org.allowlist_entries.unclaimed, entry

      entry.claim!(@user)

      assert_empty @org.allowlist_entries.unclaimed
    end

    test "claim! stamps claimed_at and claimed_by" do
      entry = @org.allowlist_entries.create!(email: "ana@gmail.com")
      entry.claim!(@user)

      assert_predicate entry, :claimed?
      assert_equal @user, entry.claimed_by
      assert_not_nil entry.claimed_at
    end

    test "claim! is idempotent — second claim does not steal the entry" do
      other = create_user!(email: "other@gmail.com")
      entry = @org.allowlist_entries.create!(email: "ana@gmail.com")

      entry.claim!(@user)
      first_claimed_at = entry.claimed_at
      entry.claim!(other)

      assert_equal @user, entry.reload.claimed_by
      assert_equal first_claimed_at.to_i, entry.claimed_at.to_i
    end
  end
end
