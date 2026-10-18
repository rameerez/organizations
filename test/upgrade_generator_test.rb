# frozen_string_literal: true

require "test_helper"
require "rails/generators"
require "rails/generators/test_case"
require "generators/organizations/upgrade/upgrade_generator"
require "generators/organizations/install/install_generator"

# rails g organizations:upgrade generates only the steps an install lacks.
class UpgradeGeneratorTest < Rails::Generators::TestCase
  tests Organizations::Generators::UpgradeGenerator
  destination File.expand_path("../tmp/upgrade-generator-dest", __dir__)
  setup :prepare_destination

  test "an install from 0.4 gets every step" do
    write_migration("20250101000000_create_organizations_tables.rb", "create_table :organizations_organizations")

    run_generator

    assert_migration "db/migrate/add_verified_joining_to_organizations.rb"
    assert_migration "db/migrate/add_personal_organizations.rb" do |content|
      assert_match "add_reference :organizations_organizations, :personal_owner", content
      assert_match "unique: true", content
      assert_match "on_delete: :nullify", content
    end
  end

  test "an install that already ran the 0.5 upgrade gets only the 0.7 step" do
    write_migration("20250101000000_create_organizations_tables.rb", "create_table :organizations_organizations")
    write_migration("20250601000000_add_verified_joining_to_organizations.rb", "# done")

    run_generator

    assert_migration "db/migrate/add_personal_organizations.rb"
    assert_equal 1, Dir[File.join(destination_root, "db/migrate/*_add_verified_joining_to_organizations.rb")].size
  end

  test "an install made on 0.5 or 0.6 skips verified joining" do
    write_migration("20250101000000_create_organizations_tables.rb", "create_table :organizations_domains")

    run_generator

    assert_empty Dir[File.join(destination_root, "db/migrate/*_add_verified_joining_to_organizations.rb")]
    assert_migration "db/migrate/add_personal_organizations.rb"
  end

  test "an up-to-date install gets nothing" do
    write_migration("20250101000000_create_organizations_tables.rb",
                    "create_table :organizations_domains\nt.references :personal_owner")

    output = run_generator

    assert_empty Dir[File.join(destination_root, "db/migrate/*_add_*.rb")]
    assert_match "up to date", output
  end

  test "the install migration creates the personal owner column" do
    path = "../lib/generators/organizations/install/templates/create_organizations_tables.rb.erb"
    template = File.read(File.expand_path(path, __dir__))

    assert_match "t.references :personal_owner", template
    assert_match "on_delete: :nullify", template
  end

  private

  def write_migration(name, body)
    path = File.join(destination_root, "db/migrate", name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
  end
end
