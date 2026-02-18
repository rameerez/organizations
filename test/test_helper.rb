# frozen_string_literal: true

require "simplecov"

ENV["RAILS_ENV"] ||= "test"
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "organizations"

require "minitest/autorun"
require "minitest/mock"
require "active_support/test_case"
require "active_support/testing/time_helpers"
require "active_record"
require "sqlite3"

puts "Setting up test environment..."

# In-memory SQLite database
ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")

# Define test schema
ActiveRecord::Schema.define do
  create_table :users, force: :cascade do |t|
    t.string :name
    t.string :email
    t.timestamps
  end

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
    t.string :role, null: false, default: "member"
    t.text :metadata, default: "{}"
    t.timestamps
  end
  add_index :memberships, [:user_id, :organization_id], unique: true

  create_table :organization_invitations, force: :cascade do |t|
    t.references :organization, null: false, foreign_key: true
    t.references :invited_by, null: false, foreign_key: { to_table: :users }
    t.string :email, null: false
    t.string :token, null: false
    t.string :role, null: false, default: "member"
    t.datetime :accepted_at
    t.datetime :expires_at
    t.timestamps
  end
  add_index :organization_invitations, :token, unique: true
end

puts "Database schema loaded."

# Test User model
class User < ActiveRecord::Base
  include Organizations::Models::Concerns::HasOrganizations
  has_organizations
end

# Base test class
class Organizations::Test < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  def setup
    Organizations.reset_configuration!
    Organizations::Organization.delete_all
    Organizations::Membership.delete_all
    Organizations::Invitation.delete_all
    User.delete_all
  end

  def teardown
    Organizations::Organization.delete_all
    Organizations::Membership.delete_all
    Organizations::Invitation.delete_all
    User.delete_all
  end
end

puts "Test helper setup complete."
