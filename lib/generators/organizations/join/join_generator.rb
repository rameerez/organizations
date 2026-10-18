# frozen_string_literal: true

require "rails/generators/base"

module Organizations
  module Generators
    # Copies the join screen and the access screen into the host app, with
    # their routes: host-owned controllers and views around JoinFlow and
    # JoinState, in the style of `rails g organizations:views`.
    #
    #   rails g organizations:join                 # join screen + access screen + routes
    #   rails g organizations:join --skip-access   # the join screen only
    #   rails g organizations:join --skip-routes   # add the routes yourself
    #
    # The templates are byte-identical to the gem's test/dummy app, where an
    # HTTP test suite covers them. The engine adds no route: nothing changes
    # in an app until it runs this generator.
    class JoinGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)
      desc "Copies the organization join and access screens (controllers, views, routes) into your app"

      class_option :skip_access, type: :boolean, default: false,
                                 desc: "Skip the access screen (domains, codes, allowlist, request queue)"
      class_option :skip_routes, type: :boolean, default: false, desc: "Do not add the routes"

      JOIN_FILES = %w[
        app/controllers/organization_joins_controller.rb
        app/views/organization_joins/show.html.erb
        app/views/organization_joins/_disclosure.html.erb
      ].freeze

      ACCESS_FILES = %w[
        app/controllers/organization_access_controller.rb
        app/views/organization_access/show.html.erb
      ].freeze

      # The routes block, without the access routes when access: false.
      # @return [String]
      def self.routes_snippet(access: true)
        snippet = File.read(File.join(source_root, "routes.rb"))
        return snippet if access

        snippet.lines.reject { |line| line.include?("organization_access#") }.join.gsub(/\n\n+(\s*end)/, "\n\\1")
      end

      # Only the access routes of the block.
      # @return [String]
      def self.access_routes
        File.read(File.join(source_root, "routes.rb")).lines.select { |line| line.include?("organization_access#") }.join
      end

      def copy_join_screen
        JOIN_FILES.each { |file| copy_file file }
      end

      def copy_access_screen
        ACCESS_FILES.each { |file| copy_file file } unless options[:skip_access]
      end

      ROUTES_MARKER = "# organizations: join and access screens"

      # Adds the routes block once. A second run adds only what is missing:
      # the access routes after an earlier --skip-access run.
      def add_routes
        return if options[:skip_routes]

        routes = File.read(File.join(destination_root, "config/routes.rb"))
        if !routes.include?(ROUTES_MARKER)
          add_routes_block
        elsif !options[:skip_access] && !routes.include?("organization_access#")
          inject_into_file "config/routes.rb", "\n#{self.class.access_routes}", after: /as: :withdraw_join\n/
        else
          say_status :identical, "config/routes.rb (the organizations routes are already there)", :blue
        end
      end

      no_commands do
        def add_routes_block
          snippet = self.class.routes_snippet(access: !options[:skip_access])
          inject_into_file "config/routes.rb", "\n#{snippet}", after: /\.routes\.draw do\s*\n/
        end
      end

      def show_readme
        say ""
        say "Organization join screen copied: GET /orgs/:organization_id/join (organization_join_path).", :green
        unless options[:skip_access]
          say "Access screen copied: GET /orgs/:organization_id/access (organization_access_path)."
        end
        say "These views use Tailwind classes and the `heroicon` helper (gem \"heroicons\")."
        say "Before you ship: read the safety rules at the top of each controller,"
        say "check the rate limits, and edit the disclosure text to match your privacy policy."
        say ""
      end
    end
  end
end
