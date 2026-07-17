# frozen_string_literal: true

require "rails/generators/base"

module Organizations
  module Generators
    # Copies the reference views into the host app — the devise-views pattern
    # (https://github.com/heartcombo/devise#configuring-views) for a BYO-UI
    # engine: the engine's controllers render HOST views, so a fresh install
    # hits missing-template errors until these exist. Run:
    #
    #   rails generate organizations:views
    #
    # and retheme freely — the copies are yours. Tailwind-styled, matching
    # the gem's test/dummy reference app (the templates here are kept
    # byte-identical to the dummy's views by a sync test in the gem's suite,
    # so the dummy remains the living, boot-able preview of what you get).
    #
    # NOTE: verified joining (join screens, request queues, access
    # management) is deliberately NOT part of this set — those surfaces are
    # host ROUTES + CONTROLLERS too, not just views. Copy the reference
    # implementation from the gem's test/dummy app instead (see README
    # "Verified joining — reference UI").
    class ViewsGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      desc "Copies the organizations reference views (organizations, memberships, invitations) into app/views/organizations"

      def copy_views
        directory "organizations", "app/views/organizations"
      end

      def show_readme
        say ""
        say "Organizations views copied to app/views/organizations/ — they're yours now; retheme freely.", :green
        say "Verified-joining surfaces (join screen, request queue, access management) are host"
        say "controllers + views: copy the reference implementation from the gem's test/dummy app."
        say ""
      end
    end
  end
end
