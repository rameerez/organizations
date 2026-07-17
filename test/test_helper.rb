# frozen_string_literal: true

require "simplecov"
SimpleCov.start do
  add_filter "/test/"
  # Don't fail on low coverage during development
  # These thresholds will be increased as tests are added
  minimum_coverage line: 0, branch: 0
end

ENV["RAILS_ENV"] ||= "test"
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "minitest/autorun"
require "minitest/mock"
require "active_support/test_case"
require "active_support/testing/time_helpers"
require "active_record"
require "active_job"
require "action_mailer"
require "globalid"
require "sqlite3"

# Configure ActionMailer for testing
ActionMailer::Base.delivery_method = :test
ActionMailer::Base.perform_deliveries = true
ActiveJob::Base.queue_adapter = :test

# In-memory SQLite database
ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
ActiveRecord::Base.logger = Logger.new(nil) # Silence SQL logging in tests

# Load organizations gem
require "organizations"

# Define test schema
ActiveRecord::Schema.define do
  create_table :users, force: :cascade do |t|
    t.string :name
    t.string :email, null: false
    # Devise-style confirmation timestamp — exercised by the
    # join_with_account_email! trust shortcut (verified joining).
    t.datetime :confirmed_at
    t.timestamps
  end
  add_index :users, :email, unique: true

  create_table :organizations_organizations, force: :cascade do |t|
    t.string :name, null: false
    t.integer :memberships_count, default: 0, null: false
    # json (matches the real installs jsonb/json column) so Hash values
    # round-trip - metadata_flag and the copy-through channel depend on it
    t.json :metadata, default: {}
    t.timestamps
  end

  create_table :organizations_memberships, force: :cascade do |t|
    t.references :user, null: false, foreign_key: true
    t.references :organization, null: false, foreign_key: { to_table: :organizations_organizations }
    t.references :invited_by, null: true, foreign_key: { to_table: :users }
    t.string :role, null: false, default: "member"
    # json (not text) so Hash values round-trip — matches the jsonb/json
    # columns the install migration creates in real apps.
    t.json :metadata, default: {}
    # Verified-joining provenance (v0.5.0)
    t.string :joined_via
    t.string :verified_email
    t.string :verified_email_normalized
    t.datetime :verified_at
    t.timestamps
  end
  add_index :organizations_memberships, [:user_id, :organization_id], unique: true
  add_index :organizations_memberships, :role
  # One proven email => one membership per organization. NULLs never collide
  # in unique indexes, so unverified memberships are unconstrained — same
  # shape the install migration creates.
  add_index :organizations_memberships, [:organization_id, :verified_email_normalized],
            unique: true, name: "index_org_memberships_verified_email_unique"

  create_table :organizations_invitations, force: :cascade do |t|
    t.references :organization, null: false, foreign_key: { to_table: :organizations_organizations }
    t.references :invited_by, null: true, foreign_key: { to_table: :users }
    t.string :email, null: false
    t.string :token, null: false
    t.string :role, null: false, default: "member"
    t.datetime :accepted_at
    t.datetime :expires_at
    t.json :metadata, default: {}
    t.json :membership_metadata, default: {}
    t.timestamps
  end
  add_index :organizations_invitations, :token, unique: true
  add_index :organizations_invitations, :email
  add_index :organizations_invitations, [:organization_id, :email]

  # === Verified joining (v0.5.0) ===

  create_table :organizations_domains, force: :cascade do |t|
    t.references :organization, null: false, foreign_key: { to_table: :organizations_organizations }
    t.string :domain, null: false
    t.json :membership_metadata, default: {}
    t.json :metadata, default: {}
    t.timestamps
  end
  add_index :organizations_domains, [:organization_id, :domain], unique: true
  add_index :organizations_domains, :domain

  create_table :organizations_join_codes, force: :cascade do |t|
    t.references :organization, null: false, foreign_key: { to_table: :organizations_organizations }
    t.string :code, null: false
    t.string :label
    t.boolean :requires_verified_domain_email, null: false, default: false
    t.boolean :auto_approve, null: false, default: true
    t.datetime :expires_at
    t.integer :max_uses
    t.integer :uses_count, null: false, default: 0
    t.datetime :revoked_at
    t.references :created_by, null: true, foreign_key: { to_table: :users }
    t.json :membership_metadata, default: {}
    t.json :metadata, default: {}
    t.timestamps
  end
  add_index :organizations_join_codes, :code, unique: true

  create_table :organizations_allowlist_entries, force: :cascade do |t|
    t.references :organization, null: false, foreign_key: { to_table: :organizations_organizations }
    t.string :email, null: false
    t.string :email_normalized, null: false
    t.string :source
    t.json :membership_metadata, default: {}
    t.datetime :claimed_at
    t.references :claimed_by, null: true, foreign_key: { to_table: :users }
    t.json :metadata, default: {}
    t.timestamps
  end
  add_index :organizations_allowlist_entries, [:organization_id, :email_normalized], unique: true

  create_table :organizations_join_requests, force: :cascade do |t|
    t.references :organization, null: false, foreign_key: { to_table: :organizations_organizations }
    t.references :user, null: false, foreign_key: true
    t.string :status, null: false, default: "pending"
    t.string :joined_via
    t.references :join_code, null: true, foreign_key: { to_table: :organizations_join_codes }
    t.string :message
    t.string :verification_email
    t.string :verification_email_normalized
    t.string :verification_code_digest
    t.datetime :verification_sent_at
    t.datetime :verification_expires_at
    t.integer :verification_attempts, null: false, default: 0
    t.integer :verification_sends_count, null: false, default: 0
    t.datetime :verified_at
    t.references :decided_by, null: true, foreign_key: { to_table: :users }
    t.datetime :decided_at
    t.datetime :expires_at
    t.json :metadata, default: {}
    t.timestamps
  end
  add_index :organizations_join_requests, :status
  ActiveRecord::Base.connection.execute(<<~SQL)
    CREATE UNIQUE INDEX index_org_join_requests_pending_unique
    ON organizations_join_requests (organization_id, user_id)
    WHERE status = 'pending'
  SQL
end

# Test User model with has_organizations
class User < ActiveRecord::Base
  extend Organizations::Models::Concerns::HasOrganizations::ClassMethods
  has_organizations

  validates :email, presence: true, uniqueness: true
end

# ActiveRecord does not include GlobalID in this non-Rails test harness by default.
# Include it so ActionMailer.deliver_later can serialize AR models.
GlobalID.app = "organizations-test"
ActiveRecord::Base.include(GlobalID::Identification) unless ActiveRecord::Base.included_modules.include?(GlobalID::Identification)

# Load engine mailer classes for default mailer constantization.
mailer_path = File.expand_path("../app/mailers/organizations/invitation_mailer.rb", __dir__)
require mailer_path if File.exist?(mailer_path)
verification_mailer_path = File.expand_path("../app/mailers/organizations/verification_mailer.rb", __dir__)
require verification_mailer_path if File.exist?(verification_mailer_path)

# Require test helpers
require "organizations/test_helpers"

# Base test class
module Organizations
  class Test < ActiveSupport::TestCase
    include ActiveSupport::Testing::TimeHelpers
    include Organizations::TestHelpers

    def setup
      Organizations.reset_configuration!
      clean_database
    end

    def teardown
      clean_database
    end

    private

    def clean_database
      Organizations::JoinRequest.delete_all
      Organizations::AllowlistEntry.delete_all
      Organizations::JoinCode.delete_all
      Organizations::Domain.delete_all
      Organizations::Invitation.delete_all
      Organizations::Membership.delete_all
      Organizations::Organization.delete_all
      User.delete_all
    end

    # Helper to create a user
    def create_user!(email: "user#{SecureRandom.hex(4)}@example.com", name: "Test User")
      User.create!(email: email, name: name)
    end

    # Helper to create an organization with owner
    def create_org_with_owner!(name: "Test Org", owner: nil)
      owner ||= create_user!
      org = Organizations::Organization.create!(name: name)
      Organizations::Membership.create!(user: owner, organization: org, role: "owner")
      [org, owner]
    end
  end
end
