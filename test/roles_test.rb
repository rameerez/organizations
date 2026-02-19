# frozen_string_literal: true

require "test_helper"

module Organizations
  class RolesTest < Organizations::Test
    # =================================================================
    # Built-in Role Hierarchy
    # =================================================================

    test "HIERARCHY contains all four built-in roles in order" do
      assert_equal %i[owner admin member viewer], Roles::HIERARCHY
    end

    test "HIERARCHY is frozen" do
      assert Roles::HIERARCHY.frozen?
    end

    test "valid_roles returns same list as HIERARCHY" do
      assert_equal Roles::HIERARCHY, Roles.valid_roles
    end

    # =================================================================
    # valid_role?
    # =================================================================

    test "valid_role? returns true for each built-in role" do
      %i[owner admin member viewer].each do |role|
        assert Roles.valid_role?(role), "Expected #{role} to be valid"
      end
    end

    test "valid_role? accepts string arguments" do
      assert Roles.valid_role?("owner")
      assert Roles.valid_role?("viewer")
    end

    test "valid_role? returns false for unknown roles" do
      refute Roles.valid_role?(:superadmin)
      refute Roles.valid_role?(:moderator)
      refute Roles.valid_role?(:guest)
    end

    test "valid_role? returns false for nil" do
      refute Roles.valid_role?(nil)
    end

    # =================================================================
    # at_least? (role comparison)
    # =================================================================

    test "at_least? owner is at least every role" do
      %i[owner admin member viewer].each do |role|
        assert Roles.at_least?(:owner, role), "Expected owner to be at_least? #{role}"
      end
    end

    test "at_least? admin is at least admin, member, viewer but not owner" do
      assert Roles.at_least?(:admin, :admin)
      assert Roles.at_least?(:admin, :member)
      assert Roles.at_least?(:admin, :viewer)
      refute Roles.at_least?(:admin, :owner)
    end

    test "at_least? member is at least member and viewer but not admin or owner" do
      assert Roles.at_least?(:member, :member)
      assert Roles.at_least?(:member, :viewer)
      refute Roles.at_least?(:member, :admin)
      refute Roles.at_least?(:member, :owner)
    end

    test "at_least? viewer is only at least viewer" do
      assert Roles.at_least?(:viewer, :viewer)
      refute Roles.at_least?(:viewer, :member)
      refute Roles.at_least?(:viewer, :admin)
      refute Roles.at_least?(:viewer, :owner)
    end

    test "at_least? accepts string arguments" do
      assert Roles.at_least?("owner", "admin")
      refute Roles.at_least?("member", "admin")
    end

    test "at_least? returns false for nil arguments" do
      refute Roles.at_least?(nil, :admin)
      refute Roles.at_least?(:admin, nil)
      refute Roles.at_least?(nil, nil)
    end

    test "at_least? returns false for unknown roles" do
      refute Roles.at_least?(:superadmin, :admin)
      refute Roles.at_least?(:admin, :superadmin)
    end

    # =================================================================
    # compare
    # =================================================================

    test "compare returns -1 when first role outranks second" do
      assert_equal(-1, Roles.compare(:owner, :admin))
      assert_equal(-1, Roles.compare(:admin, :member))
      assert_equal(-1, Roles.compare(:member, :viewer))
      assert_equal(-1, Roles.compare(:owner, :viewer))
    end

    test "compare returns 0 for equal roles" do
      %i[owner admin member viewer].each do |role|
        assert_equal 0, Roles.compare(role, role)
      end
    end

    test "compare returns 1 when first role is lower than second" do
      assert_equal 1, Roles.compare(:admin, :owner)
      assert_equal 1, Roles.compare(:member, :admin)
      assert_equal 1, Roles.compare(:viewer, :member)
      assert_equal 1, Roles.compare(:viewer, :owner)
    end

    # =================================================================
    # higher_role / lower_role
    # =================================================================

    test "higher_role returns next role up in hierarchy" do
      assert_equal :admin, Roles.higher_role(:member)
      assert_equal :member, Roles.higher_role(:viewer)
      assert_equal :owner, Roles.higher_role(:admin)
    end

    test "higher_role returns nil for owner (already highest)" do
      assert_nil Roles.higher_role(:owner)
    end

    test "higher_role returns nil for nil" do
      assert_nil Roles.higher_role(nil)
    end

    test "higher_role returns nil for unknown role" do
      assert_nil Roles.higher_role(:superadmin)
    end

    test "lower_role returns next role down in hierarchy" do
      assert_equal :admin, Roles.lower_role(:owner)
      assert_equal :member, Roles.lower_role(:admin)
      assert_equal :viewer, Roles.lower_role(:member)
    end

    test "lower_role returns nil for viewer (already lowest)" do
      assert_nil Roles.lower_role(:viewer)
    end

    test "lower_role returns nil for nil" do
      assert_nil Roles.lower_role(nil)
    end

    test "lower_role returns nil for unknown role" do
      assert_nil Roles.lower_role(:superadmin)
    end

    # =================================================================
    # Default Permissions
    # =================================================================

    test "DEFAULT_PERMISSIONS hash is frozen" do
      assert Roles::DEFAULT_PERMISSIONS.frozen?
      Roles::DEFAULT_PERMISSIONS.each_value do |perms|
        assert perms.frozen?, "Expected permissions array to be frozen"
      end
    end

    test "default method returns DEFAULT_PERMISSIONS" do
      assert_equal Roles::DEFAULT_PERMISSIONS, Roles.default
    end

    # --- Viewer permissions ---

    test "viewer has view_organization and view_members" do
      viewer_perms = Roles.permissions_for(:viewer)
      assert_includes viewer_perms, :view_organization
      assert_includes viewer_perms, :view_members
    end

    test "viewer has exactly 2 permissions" do
      assert_equal 2, Roles.permissions_for(:viewer).length
    end

    test "viewer does not have create_resources" do
      refute_includes Roles.permissions_for(:viewer), :create_resources
    end

    # --- Member permissions ---

    test "member inherits viewer permissions" do
      member_perms = Roles.permissions_for(:member)
      assert_includes member_perms, :view_organization
      assert_includes member_perms, :view_members
    end

    test "member has create, edit_own, and delete_own resources" do
      member_perms = Roles.permissions_for(:member)
      assert_includes member_perms, :create_resources
      assert_includes member_perms, :edit_own_resources
      assert_includes member_perms, :delete_own_resources
    end

    test "member has exactly 5 permissions" do
      assert_equal 5, Roles.permissions_for(:member).length
    end

    test "member does not have invite_members" do
      refute_includes Roles.permissions_for(:member), :invite_members
    end

    # --- Admin permissions ---

    test "admin inherits member permissions" do
      admin_perms = Roles.permissions_for(:admin)
      Roles.permissions_for(:member).each do |perm|
        assert_includes admin_perms, perm, "Expected admin to inherit #{perm} from member"
      end
    end

    test "admin has invite_members, remove_members, edit_member_roles, manage_settings, view_billing" do
      admin_perms = Roles.permissions_for(:admin)
      %i[invite_members remove_members edit_member_roles manage_settings view_billing].each do |perm|
        assert_includes admin_perms, perm
      end
    end

    test "admin has exactly 10 permissions" do
      assert_equal 10, Roles.permissions_for(:admin).length
    end

    test "admin does not have manage_billing" do
      refute_includes Roles.permissions_for(:admin), :manage_billing
    end

    test "admin does not have transfer_ownership" do
      refute_includes Roles.permissions_for(:admin), :transfer_ownership
    end

    test "admin does not have delete_organization" do
      refute_includes Roles.permissions_for(:admin), :delete_organization
    end

    # --- Owner permissions ---

    test "owner inherits admin permissions" do
      owner_perms = Roles.permissions_for(:owner)
      Roles.permissions_for(:admin).each do |perm|
        assert_includes owner_perms, perm, "Expected owner to inherit #{perm} from admin"
      end
    end

    test "owner has manage_billing, transfer_ownership, delete_organization" do
      owner_perms = Roles.permissions_for(:owner)
      %i[manage_billing transfer_ownership delete_organization].each do |perm|
        assert_includes owner_perms, perm
      end
    end

    test "owner has exactly 13 permissions" do
      assert_equal 13, Roles.permissions_for(:owner).length
    end

    # =================================================================
    # has_permission?
    # =================================================================

    test "has_permission? owner has all permissions" do
      all_permissions = Roles::DEFAULT_PERMISSIONS[:owner]
      all_permissions.each do |perm|
        assert Roles.has_permission?(:owner, perm), "Expected owner to have #{perm}"
      end
    end

    test "has_permission? admin has invite_members but not manage_billing" do
      assert Roles.has_permission?(:admin, :invite_members)
      refute Roles.has_permission?(:admin, :manage_billing)
    end

    test "has_permission? member has create_resources but not invite_members" do
      assert Roles.has_permission?(:member, :create_resources)
      refute Roles.has_permission?(:member, :invite_members)
    end

    test "has_permission? viewer has view_members but not create_resources" do
      assert Roles.has_permission?(:viewer, :view_members)
      refute Roles.has_permission?(:viewer, :create_resources)
    end

    test "has_permission? accepts string arguments" do
      assert Roles.has_permission?("owner", "manage_billing")
      refute Roles.has_permission?("viewer", "manage_billing")
    end

    test "has_permission? returns false for nil role" do
      refute Roles.has_permission?(nil, :view_organization)
    end

    test "has_permission? returns false for nil permission" do
      refute Roles.has_permission?(:owner, nil)
    end

    test "has_permission? returns false for unknown role" do
      refute Roles.has_permission?(:superadmin, :view_organization)
    end

    test "has_permission? returns false for unknown permission" do
      refute Roles.has_permission?(:owner, :fly_to_moon)
    end

    # =================================================================
    # permissions_for
    # =================================================================

    test "permissions_for returns empty array for nil" do
      assert_equal [], Roles.permissions_for(nil)
    end

    test "permissions_for returns empty array for unknown role" do
      assert_equal [], Roles.permissions_for(:superadmin)
    end

    test "permissions_for accepts string arguments" do
      assert_equal Roles.permissions_for(:admin), Roles.permissions_for("admin")
    end

    test "permissions_for returns no duplicates" do
      %i[owner admin member viewer].each do |role|
        perms = Roles.permissions_for(role)
        assert_equal perms.uniq, perms, "Expected no duplicates for #{role}"
      end
    end

    test "permissions_for each role is a superset of the role below" do
      viewer = Set.new(Roles.permissions_for(:viewer))
      member = Set.new(Roles.permissions_for(:member))
      admin = Set.new(Roles.permissions_for(:admin))
      owner = Set.new(Roles.permissions_for(:owner))

      assert viewer.subset?(member), "viewer should be subset of member"
      assert member.subset?(admin), "member should be subset of admin"
      assert admin.subset?(owner), "admin should be subset of owner"
    end

    # =================================================================
    # permission_sets (O(1) Set-based lookups)
    # =================================================================

    test "permission_sets returns Sets for each role" do
      Roles.permission_sets.each_value do |set|
        assert_instance_of Set, set
      end
    end

    test "permission_sets content matches permissions_for" do
      %i[owner admin member viewer].each do |role|
        expected = Set.new(Roles.permissions_for(role))
        assert_equal expected, Roles.permission_sets[role]
      end
    end

    # =================================================================
    # reset!
    # =================================================================

    test "reset! clears memoized permissions" do
      # Force memoization
      Roles.permissions
      Roles.permission_sets

      Roles.reset!

      # After reset, accessing again should recompute
      # We verify it works by checking the result is correct
      assert_equal 13, Roles.permissions_for(:owner).length
    end

    # =================================================================
    # Custom Roles via Configuration DSL
    # =================================================================

    test "custom roles override default permissions" do
      Organizations.configure do |config|
        config.roles do
          role :viewer do
            can :read_stuff
          end

          role :member, inherits: :viewer do
            can :write_stuff
          end

          role :admin, inherits: :member do
            can :manage_stuff
          end

          role :owner, inherits: :admin do
            can :own_stuff
          end
        end
      end

      assert_includes Roles.permissions_for(:viewer), :read_stuff
      refute_includes Roles.permissions_for(:viewer), :view_organization

      assert_includes Roles.permissions_for(:member), :read_stuff
      assert_includes Roles.permissions_for(:member), :write_stuff

      assert_includes Roles.permissions_for(:admin), :read_stuff
      assert_includes Roles.permissions_for(:admin), :write_stuff
      assert_includes Roles.permissions_for(:admin), :manage_stuff

      assert_includes Roles.permissions_for(:owner), :own_stuff
      assert_includes Roles.permissions_for(:owner), :manage_stuff
      assert_includes Roles.permissions_for(:owner), :write_stuff
      assert_includes Roles.permissions_for(:owner), :read_stuff
    end

    test "custom roles do not duplicate inherited permissions" do
      Organizations.configure do |config|
        config.roles do
          role :viewer do
            can :read
          end

          role :member, inherits: :viewer do
            can :read
            can :write
          end

          role :admin, inherits: :member do
            can :admin_stuff
          end

          role :owner, inherits: :admin do
            can :own_stuff
          end
        end
      end

      member_perms = Roles.permissions_for(:member)
      assert_equal member_perms.uniq, member_perms
    end

    test "custom role with no block has empty own permissions" do
      Organizations.configure do |config|
        config.roles do
          role :viewer do
            can :read
          end

          role :member, inherits: :viewer do
          end

          role :admin, inherits: :member do
            can :admin_stuff
          end

          role :owner, inherits: :admin do
            can :own_stuff
          end
        end
      end

      # member inherits from viewer so still has :read
      assert_equal [:read], Roles.permissions_for(:member)
    end

    test "custom roles with multi-level inheritance" do
      Organizations.configure do |config|
        config.roles do
          role :viewer do
            can :perm_a
          end

          role :member, inherits: :viewer do
            can :perm_b
          end

          role :admin, inherits: :member do
            can :perm_c
          end

          role :owner, inherits: :admin do
            can :perm_d
          end
        end
      end

      owner_perms = Roles.permissions_for(:owner)
      assert_includes owner_perms, :perm_a
      assert_includes owner_perms, :perm_b
      assert_includes owner_perms, :perm_c
      assert_includes owner_perms, :perm_d
      assert_equal 4, owner_perms.length
    end

    test "reset_configuration! reverts to default permissions" do
      Organizations.configure do |config|
        config.roles do
          role :viewer do
            can :custom_perm
          end

          role :member, inherits: :viewer do
          end

          role :admin, inherits: :member do
          end

          role :owner, inherits: :admin do
          end
        end
      end

      assert_includes Roles.permissions_for(:viewer), :custom_perm

      Organizations.reset_configuration!

      refute_includes Roles.permissions_for(:viewer), :custom_perm
      assert_includes Roles.permissions_for(:viewer), :view_organization
    end

    test "has_permission? works with custom roles" do
      Organizations.configure do |config|
        config.roles do
          role :viewer do
            can :read
          end

          role :member, inherits: :viewer do
            can :write
          end

          role :admin, inherits: :member do
            can :manage
          end

          role :owner, inherits: :admin do
            can :destroy
          end
        end
      end

      assert Roles.has_permission?(:owner, :destroy)
      assert Roles.has_permission?(:owner, :read)
      refute Roles.has_permission?(:viewer, :write)
      refute Roles.has_permission?(:member, :manage)
      assert Roles.has_permission?(:admin, :write)
    end

    # =================================================================
    # RoleBuilder DSL
    # =================================================================

    test "RoleBuilder can raises error when called outside role block" do
      builder = Roles::RoleBuilder.new
      error = assert_raises(RuntimeError) do
        builder.can(:some_permission)
      end
      assert_equal "can must be called within a role block", error.message
    end

    test "RoleBuilder to_permissions returns frozen hash" do
      builder = Roles::RoleBuilder.new
      builder.role(:viewer) { builder.can(:read) }
      builder.role(:member, inherits: :viewer) { builder.can(:write) }
      builder.role(:admin, inherits: :member) { builder.can(:manage) }
      builder.role(:owner, inherits: :admin) { builder.can(:own) }

      result = builder.to_permissions
      assert result.frozen?
      result.each_value do |perms|
        assert perms.frozen?
      end
    end

    test "RoleBuilder processes roles only from HIERARCHY" do
      builder = Roles::RoleBuilder.new
      builder.role(:viewer) { builder.can(:read) }
      builder.role(:unknown_role) { builder.can(:special) }
      builder.role(:member, inherits: :viewer) { builder.can(:write) }
      builder.role(:admin, inherits: :member) { builder.can(:manage) }
      builder.role(:owner, inherits: :admin) { builder.can(:own) }

      result = builder.to_permissions
      # :unknown_role is not in HIERARCHY so it should be excluded
      refute result.key?(:unknown_role)
      assert result.key?(:viewer)
    end

    # =================================================================
    # Edge Cases
    # =================================================================

    test "permissions_for with empty custom configuration" do
      Organizations.configure do |config|
        config.roles do
          # Define roles with no permissions at all
          role :viewer do
          end

          role :member, inherits: :viewer do
          end

          role :admin, inherits: :member do
          end

          role :owner, inherits: :admin do
          end
        end
      end

      assert_equal [], Roles.permissions_for(:viewer)
      assert_equal [], Roles.permissions_for(:member)
      assert_equal [], Roles.permissions_for(:admin)
      assert_equal [], Roles.permissions_for(:owner)
    end

    test "hierarchy and valid_role? are unaffected by custom role configuration" do
      Organizations.configure do |config|
        config.roles do
          role :viewer do
            can :custom
          end

          role :member, inherits: :viewer do
          end

          role :admin, inherits: :member do
          end

          role :owner, inherits: :admin do
          end
        end
      end

      # HIERARCHY is a constant, unaffected by custom config
      assert_equal %i[owner admin member viewer], Roles.hierarchy
      assert Roles.valid_role?(:owner)
      assert Roles.valid_role?(:viewer)
    end

    test "at_least? works correctly across all role pairs" do
      roles = %i[owner admin member viewer]
      roles.each_with_index do |higher, i|
        roles.each_with_index do |lower, j|
          if i <= j
            assert Roles.at_least?(higher, lower),
              "Expected #{higher} to be at_least? #{lower}"
          else
            refute Roles.at_least?(higher, lower),
              "Expected #{higher} NOT to be at_least? #{lower}"
          end
        end
      end
    end

    test "higher_role and lower_role are inverses" do
      %i[admin member viewer].each do |role|
        higher = Roles.higher_role(role)
        assert_equal role, Roles.lower_role(higher) if higher
      end

      %i[owner admin member].each do |role|
        lower = Roles.lower_role(role)
        assert_equal role, Roles.higher_role(lower) if lower
      end
    end
  end
end
