# frozen_string_literal: true

require "rails/generators/base"
require "rails/generators/active_record"

module Organizations
  module Generators
    # Upgrades an existing organizations install (<= 0.4.x) to 0.5.0
    # ("Verified Joining"): new tables for domains, join codes, allowlist
    # entries and join requests, plus provenance columns on memberships and
    # metadata columns on invitations.
    #
    # Fresh installs don't need this — `rails g organizations:install`
    # already includes everything.
    #
    #   rails g organizations:upgrade
    #   rails db:migrate
    #
    class UpgradeGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)
      desc "Add the verified-joining tables/columns (organizations 0.5.0) to an existing install"

      def self.next_migration_number(dir)
        ActiveRecord::Generators::Base.next_migration_number(dir)
      end

      def create_migration_file
        migration_template "add_verified_joining_to_organizations.rb.erb",
                           File.join(db_migrate_path, "add_verified_joining_to_organizations.rb"),
                           migration_version: migration_version
      end

      def display_post_upgrade_message
        say "\n✅ organizations verified-joining migration created.", :green
        say "\nNext steps:"
        say "  1. Run 'rails db:migrate'."
        say "  2. See the README's \"Verified joining\" section for the new API"
        say "     (domains, join codes, allowlists, join requests)."
      end

      private

      def migration_version
        "[#{ActiveRecord::VERSION::STRING.to_f}]"
      end
    end
  end
end
