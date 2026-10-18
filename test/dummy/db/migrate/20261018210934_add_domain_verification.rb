# frozen_string_literal: true

# Upgrades organizations <= 0.6.x to 0.7.0: domain authority and sign-up
# domain policies. Additive only. Existing domains start unverified with the
# "none" policy: nothing changes until you verify a domain or turn on
# config.require_verified_domains.
class AddDomainVerification < ActiveRecord::Migration[8.0]
  def change
    # ⚠️ If your user model is NOT `User` (config.user_class), change
    # `to_table: :users` to your user table before migrating.
    change_table :organizations_domains do |t|
      t.string :join_policy, null: false, default: "none"
      t.string :verification_token
      t.datetime :verification_started_at
      t.datetime :verified_at
      t.string :verification_method
      t.references :verified_by, null: true, type: foreign_key_type,
                                 foreign_key: { to_table: :users, on_delete: :nullify }
      t.datetime :verification_revoked_at
    end
  end

  private

  def foreign_key_type
    config = Rails.configuration.generators
    config.options[config.orm][:primary_key_type] || :bigint
  end
end
