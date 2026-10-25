# frozen_string_literal: true

require "test_helper"

module Organizations
  # Organizations::Current and Organizations.with_organization: the request
  # and job seam a host hooks its tenant context on. The controller side is
  # in ControllerHelpersTest.
  class CurrentTest < Organizations::Test
    # The hook the README documents, recording what it sees. Prepended once;
    # it records only while a test has set a recorder.
    module RecordsTenant
      def organization=(organization)
        super
        Thread.current[:organizations_current_test_hook]&.push(organization)
      end
    end
    Organizations::Current.prepend(RecordsTenant) unless Organizations::Current <= RecordsTenant

    def setup
      super
      @acme = Organizations::Organization.create!(name: "Acme")
      @globex = Organizations::Organization.create!(name: "Globex")
    end

    def teardown
      Thread.current[:organizations_current_test_hook] = nil
      super
    end

    test "Current is an ActiveSupport::CurrentAttributes, so Rails resets it per request and job" do
      assert_operator Organizations::Current, :<, ActiveSupport::CurrentAttributes

      Organizations::Current.organization = @acme
      Organizations::Current.reset

      assert_nil Organizations::Current.organization
    end

    test "with_organization sets the organization for the block and restores the previous one" do
      Organizations::Current.organization = @globex

      inside = Organizations.with_organization(@acme) { Organizations::Current.organization }

      assert_equal @acme, inside
      assert_equal @globex, Organizations::Current.organization
    end

    test "with_organization restores nil when nothing was current" do
      Organizations.with_organization(@acme) { assert_equal @acme, Organizations::Current.organization }

      assert_nil Organizations::Current.organization
    end

    test "with_organization restores the previous organization when the block raises" do
      Organizations::Current.organization = @globex

      assert_raises(RuntimeError) do
        Organizations.with_organization(@acme) { raise "job failed" }
      end
      assert_equal @globex, Organizations::Current.organization
    end

    test "nested blocks each restore their own outer organization" do
      seen = []

      Organizations.with_organization(@acme) do
        seen << Organizations::Current.organization
        Organizations.with_organization(@globex) do
          seen << Organizations::Current.organization
          Organizations.with_organization(nil) { seen << Organizations::Current.organization }
          seen << Organizations::Current.organization
        end
        seen << Organizations::Current.organization
      end
      seen << Organizations::Current.organization

      assert_equal [@acme, @globex, nil, @globex, @acme, nil], seen
    end

    test "with_organization returns the block's value" do
      assert_equal "Acme", Organizations.with_organization(@acme) { Organizations::Current.organization.name }
    end

    test "every change, the block form's restore included, goes through organization= for the host's hook" do
      recorded = Thread.current[:organizations_current_test_hook] = []

      Organizations.with_organization(@acme) do
        Organizations.with_organization(@globex) { :nothing_to_do }
      end

      assert_equal [@acme, @globex, @acme, nil], recorded
    end
  end
end
