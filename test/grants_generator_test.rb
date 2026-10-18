# frozen_string_literal: true

require "test_helper"
require "rails/generators"
require "rails/generators/test_case"
require "generators/organizations/grants/grants_generator"

# rails g organizations:grants
class GrantsGeneratorTest < Rails::Generators::TestCase
  tests Organizations::Generators::GrantsGenerator
  destination File.expand_path("../tmp/grants-generator-dest", __dir__)
  setup :prepare_destination

  test "creates the grants table migration" do
    run_generator

    assert_migration "db/migrate/create_organizations_grants.rb" do |migration|
      assert_match "create_table :organizations_grants", migration
      assert_match "t.references :membership", migration
      assert_match "t.references :invitation", migration
      assert_match "t.string :grantable_type, null: false", migration
      assert_match "t.column :grantable_id, foreign_key_type, null: false", migration
      assert_match "org_grants_one_holder", migration
      assert_match "index_org_grants_on_membership_and_grantable", migration
      assert_match "on_delete: :cascade", migration
    end
  end
end
