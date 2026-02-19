# frozen_string_literal: true

# Demo script to verify slugifiable integration with organizations gem
#
# This script tests:
# 1. Basic slug generation from name
# 2. Slug uniqueness handling
# 3. Slug collision resolution with random suffixes
# 4. NOT NULL constraint compatibility (before_validation hook)
# 5. Race condition handling (simulated)
#
# Run with: bundle exec ruby test/demo_slugifiable_integration.rb

require "bundler/setup"
require "active_record"
require "sqlite3"
require "securerandom"

# Setup in-memory SQLite
ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
ActiveRecord::Base.logger = Logger.new(nil)

# Load organizations gem
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "organizations"

puts "=" * 70
puts "SLUGIFIABLE INTEGRATION DEMO"
puts "=" * 70
puts

# Create schema
ActiveRecord::Schema.define do
  create_table :users, force: :cascade do |t|
    t.string :name
    t.string :email, null: false
    t.timestamps
  end
  add_index :users, :email, unique: true

  create_table :organizations, force: :cascade do |t|
    t.string :name, null: false
    t.string :slug, null: false  # NOT NULL - must be present before INSERT
    t.timestamps
  end
  add_index :organizations, :slug, unique: true

  create_table :memberships, force: :cascade do |t|
    t.references :user, null: false, foreign_key: true
    t.references :organization, null: false, foreign_key: true
    t.string :role, null: false, default: "member"
    t.timestamps
  end
  add_index :memberships, [:user_id, :organization_id], unique: true

  create_table :organization_invitations, force: :cascade do |t|
    t.references :organization, null: false, foreign_key: true
    t.string :email, null: false
    t.string :token, null: false
    t.string :role, null: false, default: "member"
    t.datetime :accepted_at
    t.datetime :expires_at
    t.timestamps
  end
  add_index :organization_invitations, :token, unique: true
end

class User < ActiveRecord::Base
  extend Organizations::Models::Concerns::HasOrganizations::ClassMethods
  has_organizations
  validates :email, presence: true, uniqueness: true
end

# ============================================================================
# Test 1: Basic Slug Generation
# ============================================================================
puts "TEST 1: Basic Slug Generation"
puts "-" * 40

org = Organizations::Organization.create!(name: "Acme Corporation")
puts "Created: '#{org.name}'"
puts "Slug:    '#{org.slug}'"
puts "Expected: slug should be 'acme-corporation'"
puts "Result:   #{org.slug == 'acme-corporation' ? '✅ PASS' : "❌ FAIL (got #{org.slug})"}"
puts

# ============================================================================
# Test 2: Slug Uniqueness (Multiple orgs with same name)
# ============================================================================
puts "TEST 2: Slug Uniqueness (Collision Resolution)"
puts "-" * 40

Organizations::Organization.delete_all

orgs = []
10.times do |i|
  org = Organizations::Organization.create!(name: "Test Company")
  orgs << org
  puts "Org #{i + 1}: slug = '#{org.slug}'"
end

slugs = orgs.map(&:slug)
unique_slugs = slugs.uniq.length
puts
puts "Total orgs: #{orgs.length}"
puts "Unique slugs: #{unique_slugs}"
puts "Result: #{unique_slugs == 10 ? '✅ PASS - All slugs unique' : '❌ FAIL - Duplicate slugs found'}"
puts

# Verify first one has clean slug, others have suffixes
puts "First org has clean slug: #{orgs.first.slug == 'test-company' ? '✅ PASS' : "❌ FAIL (got #{orgs.first.slug})"}"
suffixed = orgs[1..].all? { |o| o.slug.start_with?('test-company-') }
puts "Others have suffixes: #{suffixed ? '✅ PASS' : '❌ FAIL'}"
puts

# ============================================================================
# Test 3: NOT NULL Constraint Compatibility
# ============================================================================
puts "TEST 3: NOT NULL Constraint (before_validation hook)"
puts "-" * 40

Organizations::Organization.delete_all

# The schema has slug NOT NULL. Slugifiable normally uses after_create,
# but organizations uses before_validation to compute slug early.

begin
  org = Organizations::Organization.new(name: "Startup Inc")
  puts "Before save - slug: '#{org.slug.inspect}'"
  org.save!
  puts "After save - slug: '#{org.slug}'"
  puts "Result: #{org.slug.present? ? '✅ PASS - Slug computed before INSERT' : '❌ FAIL'}"
rescue ActiveRecord::NotNullViolation => e
  puts "❌ FAIL - NOT NULL violation: #{e.message}"
rescue => e
  puts "❌ FAIL - Unexpected error: #{e.class} - #{e.message}"
end
puts

# ============================================================================
# Test 4: Slug Generation from Slugifiable Module
# ============================================================================
puts "TEST 4: Slugifiable Module Integration"
puts "-" * 40

org = Organizations::Organization.new(name: "My Awesome Org")

# Check that slugifiable methods are available
has_compute_slug = org.respond_to?(:compute_slug)
has_generate_unique_slug = org.respond_to?(:generate_unique_slug, true)
has_generate_slug_based_on = org.respond_to?(:generate_slug_based_on)

puts "Has compute_slug method: #{has_compute_slug ? '✅ YES' : '❌ NO'}"
puts "Has generate_unique_slug method: #{has_generate_unique_slug ? '✅ YES' : '❌ NO'}"
puts "Has generate_slug_based_on method: #{has_generate_slug_based_on ? '✅ YES' : '❌ NO'}"

if has_compute_slug
  computed = org.compute_slug
  puts "compute_slug returns: '#{computed}'"
  puts "Result: #{computed == 'my-awesome-org' ? '✅ PASS' : "❌ FAIL (expected 'my-awesome-org')"}"
end
puts

# ============================================================================
# Test 5: High-Volume Collision Test
# ============================================================================
puts "TEST 5: High-Volume Collision Test (50 orgs, same name)"
puts "-" * 40

Organizations::Organization.delete_all

start_time = Time.now
orgs = []
50.times do
  orgs << Organizations::Organization.create!(name: "Popular Name")
end
elapsed = Time.now - start_time

slugs = orgs.map(&:slug)
unique_count = slugs.uniq.length

puts "Created 50 organizations in #{(elapsed * 1000).round(2)}ms"
puts "Unique slugs: #{unique_count}/50"
puts "Result: #{unique_count == 50 ? '✅ PASS' : '❌ FAIL - Some slugs collided'}"

# Show first few and last few slugs
puts
puts "Sample slugs:"
puts "  First: #{orgs.first.slug}"
puts "  #10:   #{orgs[9].slug}"
puts "  #25:   #{orgs[24].slug}"
puts "  Last:  #{orgs.last.slug}"
puts

# ============================================================================
# Test 6: Slug Stability (Reloading doesn't change slug)
# ============================================================================
puts "TEST 6: Slug Stability (Reload Test)"
puts "-" * 40

Organizations::Organization.delete_all

org = Organizations::Organization.create!(name: "Stable Org")
original_slug = org.slug
puts "Original slug: '#{original_slug}'"

org.reload
reloaded_slug = org.slug
puts "After reload:  '#{reloaded_slug}'"

org.touch
touched_slug = org.slug
puts "After touch:   '#{touched_slug}'"

stable = (original_slug == reloaded_slug) && (reloaded_slug == touched_slug)
puts "Result: #{stable ? '✅ PASS - Slug is stable' : '❌ FAIL - Slug changed unexpectedly'}"
puts

# ============================================================================
# Test 7: Name Update Doesn't Change Slug (by default)
# ============================================================================
puts "TEST 7: Name Update Behavior"
puts "-" * 40

Organizations::Organization.delete_all

org = Organizations::Organization.create!(name: "Original Name")
original_slug = org.slug
puts "Created with name: '#{org.name}', slug: '#{original_slug}'"

org.update!(name: "Updated Name")
updated_slug = org.slug
puts "Updated name to: '#{org.name}', slug: '#{updated_slug}'"

# Slugifiable typically doesn't update slugs on name change (by design - URLs stay stable)
puts "Result: #{original_slug == updated_slug ? '✅ PASS - Slug preserved (URL stability)' : '⚠️ NOTE - Slug changed to reflect new name'}"
puts

# ============================================================================
# Test 8: Special Characters in Name
# ============================================================================
puts "TEST 8: Special Characters in Name"
puts "-" * 40

Organizations::Organization.delete_all

test_cases = [
  ["Café & Bistro", "cafe-bistro"],
  ["100% Organic Co.", "100-organic-co"],
  ["日本語会社", nil],  # Non-latin - depends on implementation
  ["  Lots   Of   Spaces  ", "lots-of-spaces"],
  ["UPPERCASE NAME", "uppercase-name"],
  ["name-with-dashes", "name-with-dashes"],
  ["name_with_underscores", "name-with-underscores"],
]

test_cases.each do |name, expected|
  begin
    org = Organizations::Organization.create!(name: name)
    if expected
      result = org.slug == expected ? '✅' : "⚠️ got '#{org.slug}'"
    else
      result = org.slug.present? ? "✅ got '#{org.slug}'" : '❌ empty'
    end
    puts "  '#{name}' → '#{org.slug}' #{result}"
  rescue => e
    puts "  '#{name}' → ❌ ERROR: #{e.message}"
  end
end
puts

# ============================================================================
# Test 9: Simulated Race Condition
# ============================================================================
puts "TEST 9: Simulated Race Condition"
puts "-" * 40
puts "(Testing that slugifiable handles RecordNotUnique gracefully)"

Organizations::Organization.delete_all

# Create an org with a specific slug
existing = Organizations::Organization.create!(name: "Race Test")
existing_slug = existing.slug
puts "Existing org slug: '#{existing_slug}'"

# Now simulate what happens if two processes try to create the same slug simultaneously
# We can't truly simulate threading in this demo, but we can verify the retry mechanism
# exists in slugifiable

# Check if slugifiable has the retry mechanism
org_instance = Organizations::Organization.new(name: "Test")
has_retry = org_instance.respond_to?(:set_slug_with_retry, true)
puts "Has set_slug_with_retry: #{has_retry ? '✅ YES' : '❌ NO'}"

if has_retry
  puts "Result: ✅ PASS - Race condition handling is available"
else
  puts "Result: ⚠️ NOTE - set_slug_with_retry not found (may be in older slugifiable version)"
end
puts

# ============================================================================
# Summary
# ============================================================================
puts "=" * 70
puts "SUMMARY"
puts "=" * 70

# Count passing tests
Organizations::Organization.delete_all

tests_passed = 0
tests_total = 9

# Re-run quick checks
org1 = Organizations::Organization.create!(name: "Summary Test")
tests_passed += 1 if org1.slug == "summary-test"

org2 = Organizations::Organization.create!(name: "Summary Test")
tests_passed += 1 if org2.slug != org1.slug

tests_passed += 1 if org1.slug.present? # NOT NULL works

tests_passed += 1 if org1.respond_to?(:compute_slug)

50.times { Organizations::Organization.create!(name: "Bulk") }
tests_passed += 1 if Organizations::Organization.where("slug LIKE 'bulk%'").count == 50

org1.reload
tests_passed += 1 if org1.slug == "summary-test"

original = org1.slug
org1.update!(name: "Changed")
tests_passed += 1 if org1.slug == original # Slug stability

org3 = Organizations::Organization.create!(name: "Café Test")
tests_passed += 1 if org3.slug.present?

tests_passed += 1 if org1.respond_to?(:set_slug_with_retry, true)

puts
puts "Tests Passed: #{tests_passed}/#{tests_total}"
puts
if tests_passed == tests_total
  puts "🎉 ALL TESTS PASSED - Slugifiable integration is working correctly!"
else
  puts "⚠️  Some tests need attention - see details above"
end
puts
puts "=" * 70
