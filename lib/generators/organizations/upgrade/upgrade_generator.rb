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
    #   0.7.0 - domain authority (verification and join policy on domains)
    #
    # A step counts as present when the database already has its table or
    # column (when the generator can connect), when its upgrade migration is
    # already in db/migrate, or when the app's install migration already
    # creates it (an install made on a later version). Run it after every
    # upgrade of the gem:
    #
    #   rails g organizations:upgrade
    #   rails db:migrate
    #
    # For a squashed or renamed migration history, name the steps you need:
    #
    #   rails g organizations:upgrade --steps add_personal_organizations
    #
    class UpgradeGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)
      desc "Add the tables and columns of newer organizations versions to an existing install"

      # migration name => [text the install migration contains when it creates
      # this step, [table, column] that exist once it ran (column nil = table only)]
      STEPS = {
        "add_verified_joining_to_organizations" => ["organizations_domains", ["organizations_domains", nil]],
        "add_personal_organizations" => ["personal_owner", %w[organizations_organizations personal_owner_id]],
        "add_domain_verification" => ["verification_token", %w[organizations_domains verification_token]]
      }.freeze

      class_option :steps, type: :array, default: nil,
                           desc: "Generate exactly these steps and skip detection (#{STEPS.keys.join(', ')})"

      def self.next_migration_number(dir)
        ActiveRecord::Generators::Base.next_migration_number(dir)
      end

      def create_migration_files
        @created = []
        selected_steps.each do |name|
          next if options[:steps].nil? && step_present?(name)

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

      def selected_steps
        return STEPS.keys unless options[:steps]

        unknown = options[:steps] - STEPS.keys
        raise Thor::Error, "Unknown step(s): #{unknown.join(', ')}. Valid: #{STEPS.keys.join(', ')}" if unknown.any?

        STEPS.keys & options[:steps]
      end

      def step_present?(name)
        marker, (table, column) = STEPS.fetch(name)
        in_database?(table, column) || in_migrations?(name, marker)
      end

      # false when there is no database to ask (the generator still works offline).
      def in_database?(table, column)
        check = ->(c) { c.table_exists?(table) && (column.nil? || c.column_exists?(table, column)) }
        return ActiveRecord::Base.with_connection(&check) if ActiveRecord::Base.respond_to?(:with_connection)

        check.call(ActiveRecord::Base.connection) # Rails 7.1
      rescue StandardError
        false
      end

      def in_migrations?(name, marker)
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
