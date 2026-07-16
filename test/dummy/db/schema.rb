# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.0].define(version: 2025_02_19_000002) do
  create_table "organizations_invitations", force: :cascade do |t|
    t.bigint "organization_id", null: false
    t.bigint "invited_by_id"
    t.string "email", null: false
    t.string "token", null: false
    t.string "role", default: "member", null: false
    t.datetime "accepted_at"
    t.datetime "expires_at"
    t.json "metadata", default: {}, null: false
    t.json "membership_metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index "organization_id, LOWER(email)", name: "index_organizations_invitations_pending_unique", unique: true, where: "accepted_at IS NULL"
    t.index ["email"], name: "index_organizations_invitations_on_email"
    t.index ["invited_by_id"], name: "index_organizations_invitations_on_invited_by_id"
    t.index ["organization_id"], name: "index_organizations_invitations_on_organization_id"
    t.index ["token"], name: "index_organizations_invitations_on_token", unique: true
  end

  create_table "organizations_memberships", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "organization_id", null: false
    t.bigint "invited_by_id"
    t.string "role", default: "member", null: false
    t.json "metadata", default: {}, null: false
    t.string "joined_via"
    t.string "verified_email"
    t.string "verified_email_normalized"
    t.datetime "verified_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["invited_by_id"], name: "index_organizations_memberships_on_invited_by_id"
    t.index ["organization_id", "verified_email_normalized"], name: "index_org_memberships_verified_email_unique", unique: true
    t.index ["organization_id"], name: "index_organizations_memberships_on_organization_id"
    t.index ["organization_id"], name: "index_organizations_memberships_single_owner", unique: true, where: "role = 'owner'"
    t.index ["role"], name: "index_organizations_memberships_on_role"
    t.index ["user_id", "organization_id"], name: "index_organizations_memberships_on_user_id_and_organization_id", unique: true
    t.index ["user_id"], name: "index_organizations_memberships_on_user_id"
  end

  create_table "organizations_organizations", force: :cascade do |t|
    t.integer "memberships_count", default: 0, null: false
    t.string "name", null: false
    t.json "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "organizations_domains", force: :cascade do |t|
    t.bigint "organization_id", null: false
    t.string "domain", null: false
    t.json "membership_metadata", default: {}, null: false
    t.json "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["domain"], name: "index_organizations_domains_on_domain"
    t.index ["organization_id", "domain"], name: "index_organizations_domains_on_organization_id_and_domain", unique: true
    t.index ["organization_id"], name: "index_organizations_domains_on_organization_id"
  end

  create_table "organizations_join_codes", force: :cascade do |t|
    t.bigint "organization_id", null: false
    t.string "code", null: false
    t.string "label"
    t.boolean "requires_verified_domain_email", default: false, null: false
    t.boolean "auto_approve", default: true, null: false
    t.datetime "expires_at"
    t.integer "max_uses"
    t.integer "uses_count", default: 0, null: false
    t.datetime "revoked_at"
    t.bigint "created_by_id"
    t.json "membership_metadata", default: {}, null: false
    t.json "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["code"], name: "index_organizations_join_codes_on_code", unique: true
    t.index ["created_by_id"], name: "index_organizations_join_codes_on_created_by_id"
    t.index ["organization_id"], name: "index_organizations_join_codes_on_organization_id"
  end

  create_table "organizations_allowlist_entries", force: :cascade do |t|
    t.bigint "organization_id", null: false
    t.string "email", null: false
    t.string "email_normalized", null: false
    t.string "source"
    t.json "membership_metadata", default: {}, null: false
    t.datetime "claimed_at"
    t.bigint "claimed_by_id"
    t.json "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["claimed_by_id"], name: "index_organizations_allowlist_entries_on_claimed_by_id"
    t.index ["organization_id", "email_normalized"], name: "idx_org_allowlist_entries_on_org_and_email_normalized", unique: true
    t.index ["organization_id"], name: "index_organizations_allowlist_entries_on_organization_id"
  end

  create_table "organizations_join_requests", force: :cascade do |t|
    t.bigint "organization_id", null: false
    t.bigint "user_id", null: false
    t.string "status", default: "pending", null: false
    t.string "joined_via"
    t.bigint "join_code_id"
    t.string "message"
    t.string "verification_email"
    t.string "verification_email_normalized"
    t.string "verification_code_digest"
    t.datetime "verification_sent_at"
    t.datetime "verification_expires_at"
    t.integer "verification_attempts", default: 0, null: false
    t.integer "verification_sends_count", default: 0, null: false
    t.datetime "verified_at"
    t.bigint "decided_by_id"
    t.datetime "decided_at"
    t.datetime "expires_at"
    t.json "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["decided_by_id"], name: "index_organizations_join_requests_on_decided_by_id"
    t.index ["join_code_id"], name: "index_organizations_join_requests_on_join_code_id"
    t.index ["organization_id", "user_id"], name: "index_org_join_requests_pending_unique", unique: true, where: "status = 'pending'"
    t.index ["organization_id"], name: "index_organizations_join_requests_on_organization_id"
    t.index ["status"], name: "index_organizations_join_requests_on_status"
    t.index ["user_id"], name: "index_organizations_join_requests_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.string "email"
    t.string "name"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  add_foreign_key "organizations_invitations", "organizations_organizations", column: "organization_id"
  add_foreign_key "organizations_invitations", "users", column: "invited_by_id"
  add_foreign_key "organizations_memberships", "organizations_organizations", column: "organization_id"
  add_foreign_key "organizations_memberships", "users"
  add_foreign_key "organizations_memberships", "users", column: "invited_by_id"
  add_foreign_key "organizations_domains", "organizations_organizations", column: "organization_id"
  add_foreign_key "organizations_join_codes", "organizations_organizations", column: "organization_id"
  add_foreign_key "organizations_join_codes", "users", column: "created_by_id"
  add_foreign_key "organizations_allowlist_entries", "organizations_organizations", column: "organization_id"
  add_foreign_key "organizations_allowlist_entries", "users", column: "claimed_by_id"
  add_foreign_key "organizations_join_requests", "organizations_organizations", column: "organization_id"
  add_foreign_key "organizations_join_requests", "organizations_join_codes", column: "join_code_id"
  add_foreign_key "organizations_join_requests", "users"
  add_foreign_key "organizations_join_requests", "users", column: "decided_by_id"
end
