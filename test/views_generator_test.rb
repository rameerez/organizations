# frozen_string_literal: true

require "test_helper"
require "rails/generators"
require "rails/generators/test_case"
require "generators/organizations/views/views_generator"

# rails g organizations:views — the devise-views pattern for a BYO-UI engine.
class ViewsGeneratorTest < Rails::Generators::TestCase
  tests Organizations::Generators::ViewsGenerator
  destination File.expand_path("../tmp/generator-dest", __dir__)
  setup :prepare_destination

  EXPECTED_VIEWS = %w[
    organizations/organizations/index.html.erb
    organizations/organizations/show.html.erb
    organizations/organizations/new.html.erb
    organizations/organizations/edit.html.erb
    organizations/organizations/_form.html.erb
    organizations/memberships/index.html.erb
    organizations/invitations/index.html.erb
    organizations/invitations/new.html.erb
    organizations/invitations/show.html.erb
    organizations/invitations/_form.html.erb
  ].freeze

  test "copies every reference view into app/views/organizations" do
    run_generator

    EXPECTED_VIEWS.each do |view|
      assert_file "app/views/#{view}"
    end
  end

  # DRIFT GUARD: the generator templates must stay byte-identical to the
  # dummy app's views — the dummy is the LIVING, boot-able preview of what
  # `rails g organizations:views` produces. Edit the dummy view, then copy it
  # into lib/generators/organizations/views/templates/ (cp -R keeps them in
  # lockstep); this test is what makes forgetting that step impossible.
  test "generator templates are byte-identical to the dummy reference views" do
    templates_root = File.expand_path("../lib/generators/organizations/views/templates/organizations", __dir__)
    dummy_root = File.expand_path("dummy/app/views/organizations", __dir__)

    template_files = Dir[File.join(templates_root, "**/*.erb")].map { |f| f.delete_prefix("#{templates_root}/") }.sort
    dummy_files = Dir[File.join(dummy_root, "**/*.erb")].map { |f| f.delete_prefix("#{dummy_root}/") }.sort

    assert_equal dummy_files, template_files,
                 "template file list drifted from test/dummy/app/views/organizations"

    template_files.each do |relative|
      assert_equal File.read(File.join(dummy_root, relative)),
                   File.read(File.join(templates_root, relative)),
                   "#{relative} drifted — re-copy it from the dummy (the dummy is the SSOT)"
    end
  end
end
