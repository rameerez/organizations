# frozen_string_literal: true

require "test_helper"

# Integration tests for slugifiable gem usage in Organizations::Organization
#
# These tests verify that:
# 1. Slug generation works correctly via slugifiable
# 2. NOT NULL constraint is satisfied (before_validation hook)
# 3. Collision handling works for duplicate names
# 4. Race condition handling is available via set_slug_with_retry
# 5. URL stability (slug doesn't change when name changes)
#
class OrganizationsSlugifiableIntegrationTest < Organizations::Test
  # ==========================================================================
  # Basic Slug Generation
  # ==========================================================================

  def test_slug_generated_from_name
    org = Organizations::Organization.create!(name: "Acme Corporation")

    assert_equal "acme-corporation", org.slug
  end

  def test_slug_parameterizes_name
    org = Organizations::Organization.create!(name: "My Awesome Company Inc.")

    assert_equal "my-awesome-company-inc", org.slug
  end

  def test_slug_handles_special_characters
    org = Organizations::Organization.create!(name: "Café & Bistro")

    assert_equal "cafe-bistro", org.slug
  end

  def test_slug_handles_uppercase
    org = Organizations::Organization.create!(name: "UPPERCASE NAME")

    assert_equal "uppercase-name", org.slug
  end

  def test_slug_strips_whitespace
    org = Organizations::Organization.create!(name: "  Lots   Of   Spaces  ")

    assert_equal "lots-of-spaces", org.slug
  end

  # ==========================================================================
  # NOT NULL Constraint Compatibility
  # ==========================================================================

  def test_slug_present_before_insert
    # The schema has slug NOT NULL - this tests that before_validation works
    org = Organizations::Organization.new(name: "Test Org")

    # Slug should be nil before save
    assert_nil org.slug

    org.save!

    # Slug should be computed and persisted
    assert_equal "test-org", org.slug

    # Verify it's actually in the database
    org.reload
    assert_equal "test-org", org.slug
  end

  def test_blank_slug_is_computed_before_validation
    org = Organizations::Organization.new(name: "Validation Test", slug: "")

    org.valid?

    assert_equal "validation-test", org.slug
  end

  # ==========================================================================
  # Collision Resolution
  # ==========================================================================

  def test_duplicate_names_get_unique_slugs
    org1 = Organizations::Organization.create!(name: "Duplicate Name")
    org2 = Organizations::Organization.create!(name: "Duplicate Name")
    org3 = Organizations::Organization.create!(name: "Duplicate Name")

    assert_equal "duplicate-name", org1.slug
    refute_equal org1.slug, org2.slug
    refute_equal org2.slug, org3.slug
    refute_equal org1.slug, org3.slug

    # All should start with base slug
    assert org2.slug.start_with?("duplicate-name-")
    assert org3.slug.start_with?("duplicate-name-")
  end

  def test_high_volume_collision_handling
    # Create 50 orgs with same name - all should get unique slugs
    orgs = 50.times.map do
      Organizations::Organization.create!(name: "Popular Name")
    end

    slugs = orgs.map(&:slug)

    # All slugs should be unique
    assert_equal 50, slugs.uniq.length

    # First one should have clean slug
    assert_equal "popular-name", orgs.first.slug

    # Others should have suffixes
    orgs[1..].each do |org|
      assert org.slug.start_with?("popular-name-"),
        "Expected #{org.slug} to start with 'popular-name-'"
    end
  end

  # ==========================================================================
  # URL Stability
  # ==========================================================================

  def test_slug_stable_after_reload
    org = Organizations::Organization.create!(name: "Stable Org")
    original_slug = org.slug

    org.reload

    assert_equal original_slug, org.slug
  end

  def test_slug_stable_after_touch
    org = Organizations::Organization.create!(name: "Touch Test")
    original_slug = org.slug

    org.touch

    assert_equal original_slug, org.slug
  end

  def test_slug_preserved_when_name_changes
    org = Organizations::Organization.create!(name: "Original Name")
    original_slug = org.slug

    org.update!(name: "Changed Name")

    # Slug should NOT change - URL stability
    assert_equal original_slug, org.slug
    assert_equal "original-name", org.slug
  end

  # ==========================================================================
  # Slugifiable Integration
  # ==========================================================================

  def test_organization_includes_slugifiable_module
    org = Organizations::Organization.new

    assert org.class.include?(Slugifiable::Model)
  end

  def test_compute_slug_method_available
    org = Organizations::Organization.new(name: "Compute Test")

    assert org.respond_to?(:compute_slug)
    assert_equal "compute-test", org.compute_slug
  end

  def test_generate_unique_slug_method_available
    org = Organizations::Organization.new(name: "Generate Test")

    assert org.respond_to?(:generate_unique_slug, true)
  end

  def test_set_slug_with_retry_method_available
    org = Organizations::Organization.new(name: "Retry Test")

    # This method is key for race condition handling
    assert org.respond_to?(:set_slug_with_retry, true),
      "set_slug_with_retry should be available from slugifiable gem"
  end

  def test_slug_unique_violation_detection_available
    org = Organizations::Organization.new(name: "Detection Test")

    assert org.respond_to?(:slug_unique_violation?, true),
      "slug_unique_violation? should be available from slugifiable gem"
  end

  # ==========================================================================
  # Edge Cases
  # ==========================================================================

  def test_non_latin_characters_fallback
    # Non-latin characters parameterize to empty string, falls back to ID-based
    org = Organizations::Organization.create!(name: "日本語会社")

    # Should have SOME slug (ID-based fallback)
    refute_nil org.slug
    assert org.slug.present?
  end

  def test_numeric_only_name
    org = Organizations::Organization.create!(name: "123456")

    assert_equal "123456", org.slug
  end

  def test_dashes_preserved
    org = Organizations::Organization.create!(name: "name-with-dashes")

    assert_equal "name-with-dashes", org.slug
  end

  def test_very_long_name
    long_name = "A" * 200
    org = Organizations::Organization.create!(name: long_name)

    # Should have a slug (possibly truncated or hashed)
    assert org.slug.present?
  end

  # ==========================================================================
  # Validation Integration
  # ==========================================================================

  def test_slug_uniqueness_validation
    Organizations::Organization.create!(name: "Unique Test")

    # Try to create another with same slug manually
    org2 = Organizations::Organization.new(name: "Other Name")
    org2.slug = "unique-test"

    refute org2.valid?
    assert org2.errors[:slug].any?
  end

  def test_slug_presence_validation
    org = Organizations::Organization.new(name: "Presence Test")
    # Force blank slug
    org.slug = ""

    # before_validation should fill it in
    assert org.valid?
    assert_equal "presence-test", org.slug
  end
end
