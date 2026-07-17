# frozen_string_literal: true

# ISOLATED boot script (run as a subprocess by user_class_test.rb — never
# loaded into the main suite): proves that `config.user_class` wires every
# gem association to a differently-named host account model.
#
# Why a subprocess: user_class is read when each model CLASS BODY executes
# (association definitions), so testing it requires controlling boot order —
# configure first, touch models second. Inside the main suite the models are
# already loaded with the default "User", and re-`load`ing model files there
# would duplicate validations/callbacks on live classes. A fresh process is
# the honest way to test boot-order-sensitive configuration.
$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)

require "active_record"
require "active_job"
require "action_mailer"
require "globalid"
require "sqlite3"

ActionMailer::Base.delivery_method = :test
ActiveJob::Base.queue_adapter = :test
ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
ActiveRecord::Base.logger = nil

require "organizations"

# 1. Configure BEFORE any gem model class is referenced.
Organizations.configure do |config|
  config.user_class = "Account"
end

# 2. Schema: the account model lives in an `accounts` table (the whole point).
ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table :accounts, force: :cascade do |t|
    t.string :name
    t.string :email, null: false
    t.datetime :confirmed_at
    t.timestamps
  end

  create_table :organizations_organizations, force: :cascade do |t|
    t.string :name, null: false
    t.integer :memberships_count, default: 0, null: false
    t.json :metadata, default: {}
    t.timestamps
  end

  create_table :organizations_memberships, force: :cascade do |t|
    t.references :user, null: false
    t.references :organization, null: false
    t.references :invited_by
    t.string :role, null: false, default: "member"
    t.string :joined_via
    t.string :verified_email
    t.string :verified_email_normalized
    t.datetime :verified_at
    t.json :metadata, default: {}
    t.timestamps
    t.index %i[user_id organization_id], unique: true
  end

  create_table :organizations_invitations, force: :cascade do |t|
    t.references :organization, null: false
    t.string :email, null: false
    t.string :token, null: false
    t.string :role, null: false, default: "member"
    t.references :invited_by
    t.datetime :accepted_at
    t.datetime :expires_at
    t.json :metadata, default: {}
    t.json :membership_metadata, default: {}
    t.timestamps
    t.index :token, unique: true
  end

  create_table :organizations_domains, force: :cascade do |t|
    t.references :organization, null: false
    t.string :domain, null: false
    t.json :membership_metadata, default: {}
    t.json :metadata, default: {}
    t.timestamps
  end

  create_table :organizations_join_codes, force: :cascade do |t|
    t.references :organization, null: false
    t.string :code, null: false
    t.string :label
    t.boolean :requires_verified_domain_email, null: false, default: false
    t.boolean :auto_approve, null: false, default: true
    t.datetime :expires_at
    t.integer :max_uses
    t.integer :uses_count, null: false, default: 0
    t.datetime :revoked_at
    t.references :created_by
    t.json :membership_metadata, default: {}
    t.json :metadata, default: {}
    t.timestamps
    t.index :code, unique: true
  end

  create_table :organizations_allowlist_entries, force: :cascade do |t|
    t.references :organization, null: false
    t.string :email, null: false
    t.string :email_normalized, null: false
    t.string :source
    t.datetime :claimed_at
    t.references :claimed_by
    t.json :membership_metadata, default: {}
    t.json :metadata, default: {}
    t.timestamps
  end

  create_table :organizations_join_requests, force: :cascade do |t|
    t.references :organization, null: false
    t.references :user, null: false
    t.string :status, null: false, default: "pending"
    t.string :joined_via
    t.references :join_code
    t.string :message
    t.string :verification_email
    t.string :verification_email_normalized
    t.string :verification_code_digest
    t.datetime :verification_sent_at
    t.datetime :verification_expires_at
    t.integer :verification_attempts, null: false, default: 0
    t.integer :verification_sends_count, null: false, default: 0
    t.datetime :verified_at
    t.references :decided_by
    t.datetime :decided_at
    t.datetime :expires_at
    t.json :metadata, default: {}
    t.timestamps
  end
end

class Account < ActiveRecord::Base
  # Outside Rails the engine initializer that extends ActiveRecord::Base
  # never runs — extend explicitly (same as the main test_helper).
  extend Organizations::Models::Concerns::HasOrganizations::ClassMethods
  has_organizations
end

def check!(condition, label)
  raise "FAILED: #{label}" unless condition
end

# 3. Association reflections resolve to Account on every model.
check! Organizations::Membership.reflect_on_association(:user).options[:class_name] == "Account",
       "Membership#user class_name"
check! Organizations::Membership.reflect_on_association(:invited_by).options[:class_name] == "Account",
       "Membership#invited_by class_name"
check! Organizations::Invitation.reflect_on_association(:invited_by).options[:class_name] == "Account",
       "Invitation#invited_by class_name"
check! Organizations::JoinRequest.reflect_on_association(:user).options[:class_name] == "Account",
       "JoinRequest#user class_name"
check! Organizations::JoinRequest.reflect_on_association(:decided_by).options[:class_name] == "Account",
       "JoinRequest#decided_by class_name"
check! Organizations::JoinCode.reflect_on_association(:created_by).options[:class_name] == "Account",
       "JoinCode#created_by class_name"
check! Organizations::AllowlistEntry.reflect_on_association(:claimed_by).options[:class_name] == "Account",
       "AllowlistEntry#claimed_by class_name"

# 4. End-to-end: create org, invite, verified-join via code — all with Account.
owner = Account.create!(email: "owner@corp.test", name: "Owner")
org = owner.create_organization!("Account Corp")
check! org.owner == owner, "owner resolution through Account"
check! org.users.first.is_a?(Account), "Organization#users returns Account instances"

joiner = Account.create!(email: "joiner@corp.test", name: "Joiner")
code = org.generate_join_code!(created_by: owner, auto_approve: true)
membership = Organizations::JoinCode.redeem(code.code, user: joiner)
check! membership.is_a?(Organizations::Membership), "code redemption creates membership"
check! membership.user == joiner, "membership.user is the Account"
check! org.reload.member_count == 2, "counter cache"

# 5. The test-helper factory follows user_class too.
helper = Object.new.extend(Organizations::TestHelpers)
made = helper.create_user(email: "made@corp.test")
check! made.is_a?(Account), "TestHelpers#create_user uses config.user_class"

puts "OK"
