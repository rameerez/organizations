# frozen_string_literal: true

require "test_helper"

module Organizations
  class EmailNormalizerTest < Organizations::Test
    # =========================================================================
    # normalize
    # =========================================================================

    test "downcases and strips whitespace" do
      assert_equal "j.doe@inizio.com", EmailNormalizer.normalize("  J.Doe@INIZIO.COM  ")
    end

    test "strips plus-tag from the local part" do
      assert_equal "j.doe@inizio.com", EmailNormalizer.normalize("j.doe+carpool@inizio.com")
    end

    test "strips everything after the first plus" do
      assert_equal "j.doe@inizio.com", EmailNormalizer.normalize("j.doe+a+b+c@inizio.com")
    end

    test "strips a trailing dot from the domain (FQDN form)" do
      assert_equal "j.doe@inizio.com", EmailNormalizer.normalize("j.doe@inizio.com.")
    end

    test "the full E3 collapse: case + plus-tag + FQDN dot at once" do
      assert_equal "j.doe@inizio.com", EmailNormalizer.normalize("  J.Doe+carpool@INIZIO.COM. ")
    end

    test "does NOT collapse dots in the local part (corporate mailboxes differ)" do
      refute_equal EmailNormalizer.normalize("j.doe@inizio.com"),
                   EmailNormalizer.normalize("jdoe@inizio.com")
    end

    test "returns empty string for blank input" do
      assert_equal "", EmailNormalizer.normalize(nil)
      assert_equal "", EmailNormalizer.normalize("")
      assert_equal "", EmailNormalizer.normalize("   ")
    end

    test "leaves non-email shapes as-is (validation rejects them upstream)" do
      assert_equal "not-an-email", EmailNormalizer.normalize("Not-An-Email")
    end

    test "plus-tagged aliases collapse to the same normalized value" do
      a = EmailNormalizer.normalize("ana+1@iberozoa.com")
      b = EmailNormalizer.normalize("ana+2@iberozoa.com")
      c = EmailNormalizer.normalize("ana@iberozoa.com")

      assert_equal a, b
      assert_equal b, c
    end

    # =========================================================================
    # domain_of
    # =========================================================================

    test "extracts the domain, lowercased" do
      assert_equal "inizio.com", EmailNormalizer.domain_of("J.Doe@INIZIO.COM")
    end

    test "tolerates and strips a single trailing dot" do
      assert_equal "inizio.com", EmailNormalizer.domain_of("j@inizio.com.")
    end

    test "rejects multi-@ evasion shapes (E4)" do
      assert_nil EmailNormalizer.domain_of("evil@a.com@b.com")
      assert_nil EmailNormalizer.domain_of("a@b@c@d.com")
    end

    test "returns nil for blank or @-less input" do
      assert_nil EmailNormalizer.domain_of(nil)
      assert_nil EmailNormalizer.domain_of("")
      assert_nil EmailNormalizer.domain_of("no-at-sign")
    end

    test "returns nil when the domain part is empty" do
      assert_nil EmailNormalizer.domain_of("user@")
      assert_nil EmailNormalizer.domain_of("user@.")
    end

    test "lookalike suffix domains do NOT equal the real domain (E4)" do
      refute_equal "urjc.es", EmailNormalizer.domain_of("x@urjc.es.evil.com")
      refute_equal "urjc.es", EmailNormalizer.domain_of("x@evilurjc.es")
    end
  end
end
