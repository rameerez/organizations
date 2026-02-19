# frozen_string_literal: true

# Demo: Verify INSERT-time race condition handling works for Organizations
#
# This simulates the exact race condition that Codex identified:
# 1. Two processes try to create orgs with same name simultaneously
# 2. Both compute slug "acme-corp" in before_validation
# 3. First INSERT succeeds
# 4. Second INSERT fails with RecordNotUnique
# 5. around_create retries with recomputed slug
#
# Run: bundle exec ruby test/demo_insert_race_condition.rb

require "bundler/setup"
require "active_record"
require "sqlite3"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "organizations"

puts "=" * 70
puts "INSERT-TIME RACE CONDITION DEMO"
puts "=" * 70
puts

# Setup
ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
ActiveRecord::Base.logger = Logger.new(nil)

ActiveRecord::Schema.define do
  create_table :users, force: :cascade do |t|
    t.string :email, null: false
    t.timestamps
  end

  create_table :organizations, force: :cascade do |t|
    t.string :name, null: false
    t.string :slug, null: false  # NOT NULL - key for this test
    t.timestamps
  end
  add_index :organizations, :slug, unique: true

  create_table :memberships, force: :cascade do |t|
    t.references :user, null: false
    t.references :organization, null: false
    t.string :role, null: false, default: "member"
    t.timestamps
  end

  create_table :organization_invitations, force: :cascade do |t|
    t.references :organization, null: false
    t.string :email, null: false
    t.string :token, null: false
    t.string :role, null: false, default: "member"
    t.datetime :accepted_at
    t.datetime :expires_at
    t.timestamps
  end
end

class User < ActiveRecord::Base
  extend Organizations::Models::Concerns::HasOrganizations::ClassMethods
  has_organizations
end

# ============================================================================
# Test 1: Verify around_create hook is available
# ============================================================================
puts "TEST 1: Verify around_create hook exists"
puts "-" * 40

org = Organizations::Organization.new(name: "Test")
has_hook = org.respond_to?(:retry_create_on_slug_unique_violation, true)
puts "Has retry_create_on_slug_unique_violation: #{has_hook ? '✅ YES' : '❌ NO'}"
puts

# ============================================================================
# Test 2: Simulate race condition with injected conflicting INSERT
# ============================================================================
puts "TEST 2: Simulate INSERT-time race condition"
puts "-" * 40

# Create a subclass that injects a conflicting row on first INSERT attempt
class RaceSimulationOrg < Organizations::Organization
  self.table_name = "organizations"

  class_attribute :insert_attempts, default: 0
  class_attribute :collision_injected, default: false

  before_create :inject_collision_once

  private

  def inject_collision_once
    self.class.insert_attempts += 1
    puts "  [DEBUG] INSERT attempt ##{self.class.insert_attempts}, slug=#{slug}"

    return if self.class.collision_injected

    self.class.collision_injected = true

    # Inject a row with the same slug BEFORE this INSERT completes
    conn = self.class.connection
    now = Time.current
    conn.execute(<<~SQL)
      INSERT INTO organizations (name, slug, created_at, updated_at)
      VALUES (
        #{conn.quote("Injected by race simulation")},
        #{conn.quote(slug)},
        #{conn.quote(now)},
        #{conn.quote(now)}
      )
    SQL
    puts "  [DEBUG] Injected conflicting row with slug=#{slug}"
  end
end

begin
  org = RaceSimulationOrg.create!(name: "Acme Corp")

  puts
  puts "Result:"
  puts "  Created successfully: #{org.persisted? ? '✅ YES' : '❌ NO'}"
  puts "  INSERT attempts: #{RaceSimulationOrg.insert_attempts}"
  puts "  Final slug: #{org.slug}"
  puts "  Slug changed after retry: #{org.slug != 'acme-corp' ? '✅ YES' : '❌ NO'}"

  if RaceSimulationOrg.insert_attempts == 2 && org.slug.start_with?("acme-corp-")
    puts
    puts "✅ PASS - Race condition handled correctly!"
  else
    puts
    puts "⚠️ Unexpected behavior - check debug output"
  end
rescue => e
  puts
  puts "❌ FAIL - #{e.class}: #{e.message}"
end
puts

# ============================================================================
# Test 3: Verify non-slug unique violations still bubble up
# ============================================================================
puts "TEST 3: Non-slug unique violations bubble up"
puts "-" * 40

class NonSlugViolationOrg < Organizations::Organization
  self.table_name = "organizations"

  before_create do
    raise ActiveRecord::RecordNotUnique, "UNIQUE constraint failed: organizations.external_id"
  end
end

begin
  NonSlugViolationOrg.create!(name: "Should Fail")
  puts "❌ FAIL - Should have raised RecordNotUnique"
rescue ActiveRecord::RecordNotUnique => e
  if e.message.include?("external_id")
    puts "✅ PASS - Non-slug violation bubbled up correctly"
  else
    puts "⚠️ Unexpected error: #{e.message}"
  end
rescue => e
  puts "❌ FAIL - Wrong error type: #{e.class}"
end
puts

# ============================================================================
# Test 4: High-volume stress test with real database
# ============================================================================
puts "TEST 4: High-volume concurrent-like test (100 orgs, same name)"
puts "-" * 40

Organizations::Organization.delete_all

start_time = Time.now
orgs = []
100.times do |i|
  orgs << Organizations::Organization.create!(name: "Stress Test Corp")
end
elapsed = Time.now - start_time

slugs = orgs.map(&:slug)
unique_count = slugs.uniq.length

puts "Created 100 organizations in #{(elapsed * 1000).round(2)}ms"
puts "Unique slugs: #{unique_count}/100"
puts "First slug: #{orgs.first.slug}"
puts "Last slug: #{orgs.last.slug}"
puts "Result: #{unique_count == 100 ? '✅ PASS' : '❌ FAIL'}"
puts

# ============================================================================
# Summary
# ============================================================================
puts "=" * 70
puts "SUMMARY"
puts "=" * 70
puts
puts "The around_create hook in slugifiable correctly handles INSERT-time"
puts "race conditions for NOT NULL slug columns."
puts
puts "Flow:"
puts "1. before_validation: compute slug ('acme-corp')"
puts "2. around_create: wrap INSERT"
puts "3. INSERT fails: RecordNotUnique (slug collision)"
puts "4. around_create: recompute slug ('acme-corp-123456')"
puts "5. Retry INSERT: success"
puts
puts "This is the fix Codex added in slugifiable Round 9."
puts "=" * 70
