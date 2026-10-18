# frozen_string_literal: true

require "rails/generators/base"
require "rails/generators/active_record"

module Organizations
  module Generators
    # Brings an existing organizations install up to date. Each step is one
    # additive migration, generated only when the app does not have it yet:
    #
    #   0.5.0 - verified joining: domains, join codes, allowlist entries,
    #           join requests, membership provenance, invitation metadata
    #   0.7.0 - personal organizations (organizations.personal_owner_id)
    #
    # A step counts as present when its upgrade migration is already in
    # db/migrate, or when the app's install migration already creates it (an
    # install made on a later version). Run it after every upgrade of the gem:
    #
    #   rails g organizations:upgrade
    #   rails db:migrate
    #
    class UpgradeGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)
      desc "Add the tables and columns of newer organizations versions to an existing install"

      # [migration name, text that the install migration contains when it already creates this step]
      STEPS = [
        %w[add_verified_joining_to_organizations organizations_domains],
        %w[add_personal_organizations personal_owner]
      ].freeze

      def self.next_migration_number(dir)
        ActiveRecord::Generators::Base.next_migration_number(dir)
      end

      def create_migration_files
        @created = []
        STEPS.each do |name, marker|
          next if step_present?(name, marker)

          migration_template "#{name}.rb.erb", File.join(db_migrate_path, "#{name}.rb"),
                             migration_version: migration_version
          @created << name
        end
      end

      def display_post_upgrade_message
        if @created.empty?
          say "\n✅ organizations is up to date: no migration needed.", :green
          return
        end

        say "\n✅ organizations upgrade migrations created: #{@created.join(', ')}.", :green
        say "\nNext steps:"
        say "  1. Run 'rails db:migrate'."
        say "  2. See CHANGELOG.md for what each version adds."
      end

      private

      def step_present?(name, marker)
        migration_files.any? do |file|
          File.basename(file).match?(/\A\d+_#{name}\.rb\z/) ||
            (File.basename(file).match?(/\A\d+_create_organizations_tables\.rb\z/) && File.read(file).include?(marker))
        end
      end

      def migration_files
        @migration_files ||= Dir[File.join(destination_root, db_migrate_path, "*.rb")]
      end

      def migration_version
        "[#{ActiveRecord::VERSION::STRING.to_f}]"
      end
    end
  end
end
