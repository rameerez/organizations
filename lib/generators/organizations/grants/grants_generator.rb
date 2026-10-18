# frozen_string_literal: true

require "rails/generators/base"
require "rails/generators/active_record"

module Organizations
  module Generators
    # Adds the table for scoped resource grants (optional feature):
    #
    #   rails g organizations:grants
    #   rails db:migrate
    #
    # Then include Organizations::Grantable in the models you grant, and use
    # membership.grant!, membership.can? and Model.visible_to(membership).
    class GrantsGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)
      desc "Add the organizations_grants table (scoped resource grants)"

      def self.next_migration_number(dir)
        ActiveRecord::Generators::Base.next_migration_number(dir)
      end

      def create_migration_file
        migration_template "create_organizations_grants.rb.erb",
                           File.join(db_migrate_path, "create_organizations_grants.rb"),
                           migration_version: migration_version
      end

      def display_post_install_message
        say "\n✅ organizations grants migration created.", :green
        say "\nNext steps:"
        say "  1. Check the type of grantable_id in the migration (it must match your resources' ids)."
        say "  2. Run 'rails db:migrate'."
        say "  3. Add `include Organizations::Grantable` to the models you grant."
        say "  4. See the README section \"Scoped resource grants\"."
      end

      private

      def migration_version
        "[#{ActiveRecord::VERSION::STRING.to_f}]"
      end
    end
  end
end
