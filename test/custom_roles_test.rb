# frozen_string_literal: true

require "test_helper"

module Organizations
  class CustomRolesTest < Organizations::Test
    def define_client_role!
      Organizations.configure do |config|
        config.roles do
          role :viewer do
            can :view_organization
          end
          role :client, inherits: :viewer do
            can :view_own_records
            can :answer_questions
          end
          role :member, inherits: :viewer do
            can :create_resources
          end
          role :admin, inherits: :member do
            can :invite_members
          end
          role :owner, inherits: :admin do
            can :delete_organization
          end
        end
      end
    end

    teardown { Organizations.reset_configuration! }

    test "a custom role sits directly above the role it inherits from" do
      define_client_role!

      assert_equal %i[owner admin member client viewer], Roles.hierarchy
      assert Roles.valid_role?(:client)
      assert Roles.at_least?(:client, :viewer)
      refute Roles.at_least?(:client, :member)
      assert_equal :member, Roles.higher_role(:client)
      assert_equal :client, Roles.lower_role(:member)
    end

    test "a custom role has its own capabilities plus its parent's, and no others" do
      define_client_role!

      assert_equal %i[view_organization view_own_records answer_questions], Roles.permissions_for(:client)
      assert Roles.has_permission?(:client, :answer_questions)
      refute Roles.has_permission?(:client, :create_resources)
      refute Roles.has_permission?(:member, :answer_questions)
    end

    test "a custom role works in add_member!, on memberships, invitations and permission checks" do
      define_client_role!
      org, _owner = create_org_with_owner!
      user = create_user!

      membership = org.add_member!(user, role: :client)

      assert_equal "client", membership.role
      assert_predicate membership, :valid?
      assert_equal :client, user.role_in(org)
      assert membership.has_permission_to?(:answer_questions)
      refute membership.has_permission_to?(:create_resources)
      invitation = Organizations::Invitation.new(organization: org, email: "client@example.com", role: "client")
      invitation.validate

      assert_empty invitation.errors[:role]
    end

    test "a custom role inherits the defaults of a built-in role the block does not redefine" do
      Organizations.configure do |config|
        config.roles do
          role :auditor, inherits: :viewer do
            can :read_audit_log
          end
        end
      end

      assert_equal Roles::DEFAULT_PERMISSIONS[:viewer] + [:read_audit_log], Roles.permissions_for(:auditor)
      assert_equal %i[owner admin member auditor viewer], Roles.hierarchy
    end

    test "custom roles without a parent sit at the bottom, in the order they are defined" do
      Organizations.configure do |config|
        config.roles do
          role :guest do
            can :view_organization
          end
        end
      end

      assert_equal %i[owner admin member viewer guest], Roles.hierarchy
      refute Roles.at_least?(:guest, :viewer)
    end

    test "the default invitation role may be a custom role" do
      Organizations.configure do |config|
        config.roles do
          role :client, inherits: :viewer
        end
        config.default_invitation_role = :client
      end

      assert_equal :client, Organizations.configuration.default_invitation_role.to_sym
    end

    test "an invalid custom role is refused at configuration time" do
      [
        proc { role :client, inherits: :owner },
        proc { role :senior_admin, inherits: :admin },
        proc { role :client, inherits: :nobody },
        proc { role :"Bad Name" },
        proc do
          role :client
          role :client
        end
      ].each do |definition|
        assert_raises(ConfigurationError) { Organizations.configure { |config| config.roles(&definition) } }
        Organizations.reset_configuration!
      end
    end

    test "without custom roles the hierarchy is the built-in one" do
      assert_equal Roles::HIERARCHY, Roles.hierarchy
      refute Roles.valid_role?(:client)
    end
  end

  # The safety rules of custom roles (an adversarial review of the feature).
  class CustomRolesSafetyTest < Organizations::Test
    teardown { Organizations.reset_configuration! }

    def define_client_role!
      Organizations.configure { |config| config.roles { role :client, inherits: :viewer } }
    end

    test "a block that only adds custom roles keeps the built-in roles' defaults" do
      Organizations.configure do |config|
        config.roles do
          role :client, inherits: :viewer do
            can :answer_questions
          end
        end
      end

      Roles::HIERARCHY.each { |role| assert_equal Roles::DEFAULT_PERMISSIONS[role], Roles.permissions_for(role) }
      assert Roles.has_permission?(:owner, :transfer_ownership)
    end

    test "a rejected configuration leaves no trace of its roles, even with warm caches" do
      Organizations.configure { |config| config.roles { role :client, inherits: :viewer } }

      assert Roles.valid_role?(:client)

      assert_raises(ConfigurationError) do
        Organizations.configure do |config|
          config.roles { role :auditor, inherits: :viewer }
          Roles.hierarchy # warm the cache inside the attempt
          config.default_invitation_role = :nobody
        end
      end

      assert Roles.valid_role?(:client)
      refute Roles.valid_role?(:auditor)
    end

    test "a snapshot of an older definition is never served for a newer one" do
      Organizations.configure { |config| config.roles { role :client, inherits: :viewer } }
      stale = Roles.send(:snapshot)
      Organizations.configure { |config| config.roles { role :auditor, inherits: :viewer } }
      Roles.instance_variable_set(:@snapshot, stale) # a reader that raced the reset publishes late

      assert Roles.valid_role?(:auditor)
      refute Roles.valid_role?(:client)
    end

    test "a role retired from the configuration does not block other updates, and ranks last" do
      define_client_role!
      org, _owner = create_org_with_owner!
      membership = org.add_member!(create_user!, role: :client)
      Organizations.reset_configuration!

      membership.reload.update!(updated_at: Time.current)

      assert_equal 1, Roles.compare(:viewer, :client) * -1
      refute_predicate org.memberships.new(user: create_user!, role: "client"), :valid?
    end

    test "memberships order by the configured hierarchy, custom roles included" do
      define_client_role!
      org, _owner = create_org_with_owner!
      org.add_member!(create_user!, role: :viewer)
      org.add_member!(create_user!, role: :client)
      org.add_member!(create_user!, role: :member)

      assert_equal %w[owner member client viewer], org.memberships.by_role_hierarchy.pluck(:role)
    end

    test "a custom role cannot grant a permission that only the owner has" do
      %i[manage_billing transfer_ownership delete_organization].each do |permission|
        error = assert_raises(ConfigurationError) do
          Organizations.configure do |config|
            config.roles { role(:finance, inherits: :viewer) { can permission } }
          end
        end
        assert_match(/finance cannot grant #{permission}/, error.message)
        Organizations.reset_configuration!
      end

      Organizations.configure { |config| config.roles { role(:finance, inherits: :viewer) { can :view_billing } } }

      assert Roles.has_permission?(:finance, :view_billing)
    end

    test "the owner-only rule follows a redefined owner and admin" do
      assert_raises(ConfigurationError) do
        Organizations.configure do |config|
          config.roles do
            role(:member) { can :view_organization }
            role(:admin, inherits: :member) { can :invite_members }
            role(:owner, inherits: :admin) { can :approve_payouts }
            role(:finance, inherits: :member) { can :approve_payouts }
          end
        end
      end
    end

    test "an empty roles block still defines no permissions" do
      Organizations.configure { |config| config.roles { nil } } # a block that defines no role

      assert_equal Roles::HIERARCHY, Roles.hierarchy
      assert_empty Roles.permissions
      refute Roles.has_permission?(:owner, :view_organization)
    end

    test "a comparison reads the hierarchy once, so a reconfiguration in between cannot mix two orders" do
      orders = [%i[owner admin member viewer], %i[owner admin a b c member viewer]]
      calls = 0
      next_order = lambda do
        calls += 1
        orders[(calls - 1) % 2]
      end

      Roles.stub(:hierarchy, next_order) do
        refute Roles.at_least?(:viewer, :member)
        assert_equal 1, Roles.compare(:viewer, :member)
        assert_equal :member, Roles.higher_role(:viewer)
        assert_equal :a, Roles.lower_role(:admin)
      end
      assert_equal 4, calls
    end
  end
end
