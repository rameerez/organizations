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
    t.timestamps
  end
  add_index :users, :email, unique: true

  create_table :organizations, force: :cascade do |t|
    t.string :name, null: false
    t.string :slug, null: false
    t.text :metadata, default: "{}"
    t.timestamps
  end
  add_index :organizations, :slug, unique: true

  create_table :memberships, force: :cascade do |t|
    t.references :user, null: false, foreign_key: true
    t.references :organization, null: false, foreign_key: true
    t.references :invited_by, null: true, foreign_key: { to_table: :users }
    t.string :role, null: false, default: "member"
    t.text :metadata, default: "{}"
    t.timestamps
  end
  add_index :memberships, [:user_id, :organization_id], unique: true
  add_index :memberships, :role

  create_table :organization_invitations, force: :cascade do |t|
    t.references :organization, null: false, foreign_key: true
    t.references :invited_by, null: true, foreign_key: { to_table: :users }
    t.string :email, null: false
    t.string :token, null: false
    t.string :role, null: false, default: "member"
    t.datetime :accepted_at
    t.datetime :expires_at
    t.timestamps
  end
  add_index :organization_invitations, :token, unique: true
  add_index :organization_invitations, :email
  add_index :organization_invitations, [:organization_id, :email]
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

# Load engine mailer class for default invitation_mailer constantization.
mailer_path = File.expand_path("../app/mailers/organizations/invitation_mailer.rb", __dir__)
require mailer_path if File.exist?(mailer_path)

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
