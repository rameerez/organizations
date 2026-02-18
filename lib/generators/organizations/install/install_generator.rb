# frozen_string_literal: true

require "rails/generators/base"
require "rails/generators/active_record"

module Organizations
  module Generators
    class InstallGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)
      desc "Install organizations migrations and initializer"

      def self.next_migration_number(dir)
        ActiveRecord::Generators::Base.next_migration_number(dir)
      end

      def create_migration_file
        migration_template "create_organizations_tables.rb.erb", File.join(db_migrate_path, "create_organizations_tables.rb"), migration_version: migration_version
      end

      def create_initializer
        template "initializer.rb", "config/initializers/organizations.rb"
      end

      def display_post_install_message
        say "\n✅ organizations has been installed.", :green
        say "\nNext steps:"
        say "  1. Run 'rails db:migrate' to create the necessary tables."
        say "  2. Review and customize 'config/initializers/organizations.rb'."
        say "  3. Add 'has_organizations' to your User model."
        say "  4. Mount the engine in your routes: mount Organizations::Engine => '/'"
      end

      private

      def migration_version
        "[#{ActiveRecord::VERSION::STRING.to_f}]"
      end
    end
  end
end
