# frozen_string_literal: true

require "test_helper"
require "rails/generators"
require "rails/generators/test_case"
require "generators/organizations/join/join_generator"

# rails g organizations:join — host-owned join and access screens.
class JoinGeneratorTest < Rails::Generators::TestCase
  tests Organizations::Generators::JoinGenerator
  destination File.expand_path("../tmp/join-generator-dest", __dir__)
  setup :prepare_destination
  setup :write_routes

  ALL_FILES = (Organizations::Generators::JoinGenerator::JOIN_FILES +
               Organizations::Generators::JoinGenerator::ACCESS_FILES).freeze

  test "copies the join and access screens and adds their routes" do
    run_generator

    ALL_FILES.each { |file| assert_file file }
    assert_file "config/routes.rb" do |routes|
      assert_match 'scope "orgs/:organization_id", as: :organization do', routes
      assert_match "organization_joins#create", routes
      assert_match "organization_access#verify_domain", routes
      assert_match(/draw do\n\n  # organizations: join and access screens/, routes)
    end
  end

  test "--skip-access copies the join screen only, with its routes only" do
    run_generator %w[--skip-access]

    Organizations::Generators::JoinGenerator::JOIN_FILES.each { |file| assert_file file }
    Organizations::Generators::JoinGenerator::ACCESS_FILES.each { |file| assert_no_file file }
    assert_file "config/routes.rb" do |routes|
      assert_match "organization_joins#withdraw", routes
      refute_match "organization_access", routes
      assert_match(/as: :withdraw_join\n  end/, routes)
    end
  end

  test "a second run adds no second routes block" do
    run_generator
    run_generator %w[--force]

    assert_file "config/routes.rb" do |routes|
      assert_equal 1, routes.scan("# organizations: join and access screens").size
      assert_equal 1, routes.scan("organization_joins#show").size
    end
  end

  test "running again without --skip-access adds only the access routes" do
    run_generator %w[--skip-access]
    run_generator %w[--force]

    assert_file "config/routes.rb" do |routes|
      assert_equal 1, routes.scan("organization_joins#show").size
      assert_equal 1, routes.scan("organization_access#show").size
      assert_match(/as: :withdraw_join\n\n    get    "access"/, routes)
    end
    Organizations::Generators::JoinGenerator::ACCESS_FILES.each { |file| assert_file file }
  end

  test "--skip-routes leaves config/routes.rb alone" do
    run_generator %w[--skip-routes]

    assert_file "config/routes.rb", "Rails.application.routes.draw do\nend\n"
  end

  test "the generated controllers keep the safety rules" do
    run_generator

    assert_file "app/controllers/organization_joins_controller.rb" do |controller|
      assert_match "Organizations.configuration.authenticate_user_method", controller
      assert_match "rate_limit", controller
      assert_match "MAX_MESSAGE_LENGTH", controller
      refute_match "switch_to_organization", controller
    end
    assert_file "app/controllers/organization_access_controller.rb" do |controller|
      assert_match "include Organizations::OrganizationScoped", controller
      assert_match "require_organization_permission :invite_members", controller
      assert_match "organization.domains.find", controller
    end
  end

  # DRIFT GUARD: the templates are the dummy app's files, byte for byte, and
  # the dummy's routes contain the generated routes block. The dummy's HTTP
  # suite (test/dummy/test/integration/reference_surfaces_test.rb) is what
  # certifies the generated code. Edit the dummy, then copy into templates.
  test "templates are byte-identical to the dummy reference files" do
    templates = File.expand_path("../lib/generators/organizations/join/templates", __dir__)
    dummy = File.expand_path("dummy", __dir__)

    ALL_FILES.each do |file|
      assert_equal File.read(File.join(dummy, file)), File.read(File.join(templates, file)),
                   "#{file} drifted. Copy it again from test/dummy (the dummy is the source of truth)."
    end
  end

  test "the dummy routes contain the generated routes block" do
    dummy_routes = File.read(File.expand_path("dummy/config/routes.rb", __dir__))

    assert_includes dummy_routes, Organizations::Generators::JoinGenerator.routes_snippet
  end

  private

  def write_routes
    FileUtils.mkdir_p(File.join(destination_root, "config"))
    File.write(File.join(destination_root, "config/routes.rb"), "Rails.application.routes.draw do\nend\n")
  end
end
