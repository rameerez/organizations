# frozen_string_literal: true

# Upgrades organizations <= 0.6.x to 0.7.0: personal organizations.
# Additive only. Existing organizations stay unclassified (personal_owner_id
# is NULL): link the ones you have reviewed with
# Organizations::Organization.backfill_personal_owners!(mapping, dry_run: true).
class AddPersonalOrganizations < ActiveRecord::Migration[8.0]
  def change
    # ⚠️ If your user model is NOT `User` (config.user_class), change
    # `to_table: :users` to your user table before migrating.
    add_reference :organizations_organizations, :personal_owner,
                  null: true, type: foreign_key_type, index: { unique: true },
                  foreign_key: { to_table: :users, on_delete: :nullify }
  end

  private

  def foreign_key_type
    config = Rails.configuration.generators
    config.options[config.orm][:primary_key_type] || :bigint
  end
end
