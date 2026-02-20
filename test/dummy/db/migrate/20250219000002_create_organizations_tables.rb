# frozen_string_literal: true

class CreateOrganizationsTables < ActiveRecord::Migration[8.0]
  def change
    primary_key_type, foreign_key_type = primary_and_foreign_key_types
    adapter = connection.adapter_name.downcase

    # Organizations table
    create_table :organizations_organizations, id: primary_key_type do |t|
      t.string :name, null: false
      t.send(json_column_type, :metadata, null: json_column_null, default: json_column_default)

      t.timestamps
    end

    # Memberships join table (User ↔ Organization)
    create_table :organizations_memberships, id: primary_key_type do |t|
      t.references :user, null: false, type: foreign_key_type, foreign_key: true
      t.references :organization, null: false, type: foreign_key_type, foreign_key: { to_table: :organizations_organizations }
      t.references :invited_by, null: true, type: foreign_key_type, foreign_key: { to_table: :users }
      t.string :role, null: false, default: "member"
      t.send(json_column_type, :metadata, null: json_column_null, default: json_column_default)

      t.timestamps
    end

    add_index :organizations_memberships, [:user_id, :organization_id], unique: true
    add_index :organizations_memberships, :role

    # Enforce "at most one owner membership per organization" at DB level where possible.
    # Both PostgreSQL and SQLite support partial indexes with identical syntax.
    if adapter.include?("postgresql") || adapter.include?("sqlite")
      execute <<-SQL
        CREATE UNIQUE INDEX index_organizations_memberships_single_owner
        ON organizations_memberships (organization_id)
        WHERE role = 'owner'
      SQL
    end

    # Invitations table
    create_table :organizations_invitations, id: primary_key_type do |t|
      t.references :organization, null: false, type: foreign_key_type, foreign_key: { to_table: :organizations_organizations }
      # invited_by is nullable to support dependent: :nullify when user is deleted
      t.references :invited_by, null: true, type: foreign_key_type, foreign_key: { to_table: :users }
      t.string :email, null: false
      t.string :token, null: false
      t.string :role, null: false, default: "member"
      t.datetime :accepted_at
      t.datetime :expires_at

      t.timestamps
    end

    add_index :organizations_invitations, :token, unique: true
    add_index :organizations_invitations, :email

    # Unique partial index: only one pending (non-accepted) invitation per email per org
    # Both PostgreSQL and SQLite (3.8.0+) support partial indexes with identical syntax.
    if adapter.include?("postgresql") || adapter.include?("sqlite")
      execute <<-SQL
        CREATE UNIQUE INDEX index_organizations_invitations_pending_unique
        ON organizations_invitations (organization_id, LOWER(email))
        WHERE accepted_at IS NULL
      SQL
    elsif adapter.include?("mysql")
      # MySQL doesn't support partial indexes, so we use a generated column that is
      # only non-NULL for pending invitations and enforce uniqueness on that value.
      execute <<-SQL
        ALTER TABLE organizations_invitations
        ADD COLUMN pending_email VARCHAR(255)
        GENERATED ALWAYS AS (
          CASE
            WHEN accepted_at IS NULL THEN LOWER(email)
            ELSE NULL
          END
        ) STORED
      SQL

      add_index :organizations_invitations, [:organization_id, :pending_email], unique: true, name: "index_organizations_invitations_pending_unique"
    else
      # For other adapters, fall back to app-level validation.
      add_index :organizations_invitations, [:organization_id, :email], name: "index_organizations_invitations_on_org_and_email"
    end
  end

  private

  def primary_and_foreign_key_types
    config = Rails.configuration.generators
    setting = config.options[config.orm][:primary_key_type]
    primary_key_type = setting || :primary_key
    foreign_key_type = setting || :bigint
    [primary_key_type, foreign_key_type]
  end

  def json_column_type
    return :jsonb if connection.adapter_name.downcase.include?('postgresql')
    :json
  end

  # MySQL 8+ doesn't allow default values on JSON columns.
  # Returns an empty hash default for SQLite/PostgreSQL, nil for MySQL.
  def json_column_default
    return nil if connection.adapter_name.downcase.include?('mysql')
    {}
  end

  # Keep inserts safe on MySQL where JSON defaults are restricted.
  # Other adapters keep metadata required with a {} default.
  def json_column_null
    connection.adapter_name.downcase.include?('mysql')
  end
end
