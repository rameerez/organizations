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
end
