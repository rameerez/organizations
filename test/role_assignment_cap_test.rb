# frozen_string_literal: true

require "test_helper"

module Organizations
  # An account may only give out, or take away, roles that rank at or below
  # its own. Custom roles made this reachable: a role that inherits member and
  # adds invite_members and edit_member_roles passes the configuration rules,
  # and without this cap it could invite an admin, promote a viewer to admin,
  # or demote an admin, through every role-changing entry point.
  class RoleAssignmentCapTest < Organizations::Test
    def setup
      super
      Organizations.configure do |config|
        config.roles do
          role :lead, inherits: :member do
            can :invite_members
            can :edit_member_roles
          end
          # Same parent, defined after lead: ranks below lead by definition
          # order, but holds permissions lead lacks.
          role :finance, inherits: :member do
            can :view_billing
            can :manage_settings
          end
        end
      end

      @org, @owner = create_org_with_owner!
      @admin = add!(:admin)
      @lead = add!(:lead)
      @viewer = add!(:viewer)
    end

    def teardown
      I18n.locale = I18n.default_locale
      Organizations.reset_configuration!
      super
    end

    # === The rule itself ===

    test "lead and finance sit between admin and member, lead first" do
      assert_equal %i[owner admin lead finance member viewer], Roles.hierarchy
    end

    test "Roles.can_assign? allows roles at or below the actor's own and nothing above" do
      assert Roles.can_assign?(:lead, :lead)
      assert Roles.can_assign?(:lead, :member)
      assert Roles.can_assign?(:lead, :viewer)
      refute Roles.can_assign?(:lead, :admin)
      refute Roles.can_assign?(:lead, :owner)

      assert Roles.can_assign?(:admin, :admin)
      assert Roles.can_assign?(:admin, :lead)
      refute Roles.can_assign?(:admin, :owner)

      Roles.hierarchy.each { |role| assert Roles.can_assign?(:owner, role) }
    end

    test "rank alone is not enough below admin: a sibling with permissions the actor lacks is refused" do
      refute Roles.can_assign?(:lead, :finance)
      assert_equal :lacks_permissions, Roles.assignment_refusal(:lead, :finance)
      assert_equal :outranks, Roles.assignment_refusal(:finance, :lead)
      assert_equal :outranks, Roles.assignment_refusal(:lead, :admin)
      assert_nil Roles.assignment_refusal(:lead, :member)
    end

    test "admins and the owner keep the rank rule alone" do
      assert Roles.can_assign?(:admin, :finance)
      assert Roles.can_assign?(:owner, :finance)
    end

    test "Roles.can_assign? accepts strings" do
      assert Roles.can_assign?("admin", "member")
      refute Roles.can_assign?("lead", "admin")
    end

    test "Roles.can_assign? ranks a role that is not configured below every configured role" do
      assert Roles.can_assign?(:viewer, :retired_role)
    end

    test "Roles.can_assign? lets an actor whose role is not configured assign nothing" do
      refute Roles.can_assign?(:retired_role, :viewer)
      refute Roles.can_assign?(:retired_role, :retired_role)
    end

    test "Roles.can_assign? is false for nil" do
      refute Roles.can_assign?(nil, :viewer)
      refute Roles.can_assign?(:owner, nil)
    end

    test "Membership#can_assign_role? applies the rule to the member's role" do
      assert membership_of(@admin).can_assign_role?(:admin)
      assert membership_of(@lead).can_assign_role?(:viewer)
      refute membership_of(@lead).can_assign_role?(:admin)
      refute membership_of(@viewer).can_assign_role?(:member)
    end

    # === A custom role with invite and edit-roles permissions ===

    test "a lead cannot invite to admin through the user API" do
      error = assert_raises(Organizations::NotAuthorized) do
        @lead.send_organization_invite_to!("new@example.com", organization: @org, role: :admin)
      end

      assert_equal :invite_members, error.permission
      assert_equal @org, error.organization
      assert_equal @lead, error.user
      assert_equal "You can't invite someone as Admin because that role ranks above yours", error.message
      assert_equal 0, @org.invitations.count
    end

    test "a lead cannot invite to admin through the organization API, with a string role" do
      assert_raises(Organizations::NotAuthorized) do
        @org.send_invite_to!("new@example.com", invited_by: @lead, role: "admin")
      end

      assert_equal 0, @org.invitations.count
    end

    test "a lead cannot get an admin invitation back from a pending one for the same email" do
      @org.send_invite_to!("new@example.com", invited_by: @admin, role: :admin)

      assert_raises(Organizations::NotAuthorized) do
        @org.send_invite_to!("new@example.com", invited_by: @lead, role: :admin)
      end
    end

    test "a lead cannot refresh an expired invitation into an admin one" do
      expired = @org.send_invite_to!("new@example.com", invited_by: @admin, role: :member)
      expired.update_columns(expires_at: 1.day.ago)

      assert_raises(Organizations::NotAuthorized) do
        @org.send_invite_to!("new@example.com", invited_by: @lead, role: :admin)
      end

      assert_equal "member", expired.reload.role
    end

    test "a lead still gets the owner refusal when inviting as owner" do
      assert_raises(Organizations::Organization::CannotInviteAsOwner) do
        @org.send_invite_to!("new@example.com", invited_by: @lead, role: :owner)
      end
    end

    test "a lead cannot invite to a sibling role with permissions it lacks" do
      error = assert_raises(Organizations::NotAuthorized) do
        @org.send_invite_to!("new@example.com", invited_by: @lead, role: :finance)
      end

      assert_equal :invite_members, error.permission
      assert_equal "You can't act on the Finance role because it has permissions you do not have", error.message
      assert_equal 0, @org.invitations.count
    end

    test "a lead can invite to its own role and the roles below it" do
      %i[lead member viewer].each do |role|
        invitation = @lead.send_organization_invite_to!("#{role}@example.com", organization: @org, role: role)

        assert_equal role.to_s, invitation.role
      end
    end

    test "a lead cannot promote a viewer to admin through change_role_of!" do
      error = assert_raises(Organizations::NotAuthorized) do
        @org.change_role_of!(@viewer, to: :admin, changed_by: @lead)
      end

      assert_equal :edit_member_roles, error.permission
      assert_equal @org, error.organization
      assert_equal @lead, error.user
      assert_equal "You can't give or take away the Admin role because it ranks above yours", error.message
      assert_equal "viewer", membership_of(@viewer).role
    end

    test "a lead cannot promote a viewer to admin through Membership#promote_to!" do
      assert_raises(Organizations::NotAuthorized) do
        membership_of(@viewer).promote_to!(:admin, changed_by: @lead)
      end

      assert_equal "viewer", membership_of(@viewer).role
    end

    test "a lead cannot demote an admin through change_role_of!" do
      assert_raises(Organizations::NotAuthorized) do
        @org.change_role_of!(@admin, to: :member, changed_by: @lead)
      end

      assert_equal "admin", membership_of(@admin).role
    end

    test "a lead cannot demote an admin through Membership#demote_to!" do
      assert_raises(Organizations::NotAuthorized) do
        membership_of(@admin).demote_to!(:viewer, changed_by: @lead)
      end

      assert_equal "admin", membership_of(@admin).role
    end

    test "a lead cannot promote a member to a sibling role with permissions it lacks" do
      member = add!(:member)

      error = assert_raises(Organizations::NotAuthorized) do
        @org.change_role_of!(member, to: :finance, changed_by: @lead)
      end
      assert_raises(Organizations::NotAuthorized) do
        membership_of(member).promote_to!(:finance, changed_by: @lead)
      end

      assert_equal :edit_member_roles, error.permission
      assert_equal "member", membership_of(member).role
    end

    test "a lead cannot demote or remove a member of a sibling role with permissions it lacks" do
      finance = add!(:finance)

      assert_raises(Organizations::NotAuthorized) do
        @org.change_role_of!(finance, to: :member, changed_by: @lead)
      end
      assert_raises(Organizations::NotAuthorized) do
        @org.remove_member!(finance, removed_by: @lead)
      end

      assert_equal "finance", membership_of(finance).role
    end

    test "an admin can give and take away the finance role" do
      member = add!(:member)

      @org.change_role_of!(member, to: :finance, changed_by: @admin)

      assert_equal "finance", membership_of(member).role

      @org.change_role_of!(member, to: :member, changed_by: @admin)

      assert_equal "member", membership_of(member).role
    end

    test "a lead cannot promote itself to admin" do
      assert_raises(Organizations::NotAuthorized) do
        @org.change_role_of!(@lead, to: :admin, changed_by: @lead)
      end

      assert_equal "lead", membership_of(@lead).role
    end

    test "a lead still gets the owner refusals for owner changes" do
      assert_raises(Organizations::Organization::CannotHaveMultipleOwners) do
        @org.change_role_of!(@viewer, to: :owner, changed_by: @lead)
      end
      assert_raises(Organizations::Organization::CannotDemoteOwner) do
        @org.change_role_of!(@owner, to: :member, changed_by: @lead)
      end
    end

    test "a refused role change fires no role_changed callback" do
      fired = []
      Organizations.configure { |config| config.on_role_changed { |ctx| fired << ctx } }

      assert_raises(Organizations::NotAuthorized) do
        @org.change_role_of!(@viewer, to: :admin, changed_by: @lead)
      end
      assert_raises(Organizations::NotAuthorized) do
        membership_of(@admin).demote_to!(:member, changed_by: @lead)
      end

      assert_empty fired
    end

    test "a lead can move members among its own role and the roles below it" do
      @org.change_role_of!(@viewer, to: :lead, changed_by: @lead)

      assert_equal "lead", membership_of(@viewer).role

      @org.change_role_of!(@viewer, to: :member, changed_by: @lead)

      assert_equal "member", membership_of(@viewer).role

      membership_of(@viewer).demote_to!(:viewer, changed_by: @lead)

      assert_equal "viewer", membership_of(@viewer).role

      membership_of(@viewer).promote_to!(:member, changed_by: @lead)

      assert_equal "member", membership_of(@viewer).role
    end

    # === Admin and owner keep what they could do ===

    test "an admin can invite to admin, lead, member and viewer" do
      %i[admin lead member viewer].each do |role|
        invitation = @admin.send_organization_invite_to!("#{role}@example.com", organization: @org, role: role)

        assert_equal role.to_s, invitation.role
      end
    end

    test "an admin can promote to admin and to the roles below it" do
      @org.change_role_of!(@viewer, to: :lead, changed_by: @admin)

      assert_equal "lead", membership_of(@viewer).role

      @org.change_role_of!(@viewer, to: :admin, changed_by: @admin)

      assert_equal "admin", membership_of(@viewer).role

      membership_of(@lead).promote_to!(:admin, changed_by: @admin)

      assert_equal "admin", membership_of(@lead).role
    end

    test "an admin can demote another admin" do
      other_admin = add!(:admin)

      @org.change_role_of!(other_admin, to: :lead, changed_by: @admin)

      assert_equal "lead", membership_of(other_admin).role

      membership_of(other_admin).demote_to!(:viewer, changed_by: @admin)

      assert_equal "viewer", membership_of(other_admin).role

      membership_of(other_admin).promote_to!(:admin, changed_by: @admin)
      @org.change_role_of!(other_admin, to: :member, changed_by: @admin)

      assert_equal "member", membership_of(other_admin).role
    end

    test "an owner can invite to every role but owner" do
      %i[admin lead member viewer].each do |role|
        invitation = @owner.send_organization_invite_to!("#{role}@example.com", organization: @org, role: role)

        assert_equal role.to_s, invitation.role
      end
      assert_raises(Organizations::Organization::CannotInviteAsOwner) do
        @owner.send_organization_invite_to!("owner@example.com", organization: @org, role: :owner)
      end
    end

    test "an owner can promote and demote admins, and owner changes still need a transfer" do
      @org.change_role_of!(@viewer, to: :admin, changed_by: @owner)

      assert_equal "admin", membership_of(@viewer).role

      @org.change_role_of!(@admin, to: :viewer, changed_by: @owner)

      assert_equal "viewer", membership_of(@admin).role

      assert_raises(Organizations::Organization::CannotHaveMultipleOwners) do
        @org.change_role_of!(@viewer, to: :owner, changed_by: @owner)
      end
      assert_raises(Organizations::Membership::CannotPromoteToOwner) do
        membership_of(@viewer).promote_to!(:owner, changed_by: @owner)
      end
    end

    # === Who counts as the actor ===

    test "a role change without changed_by is not capped, as before" do
      @org.change_role_of!(@viewer, to: :admin)

      assert_equal "admin", membership_of(@viewer).role

      membership_of(@viewer).demote_to!(:member)

      assert_equal "member", membership_of(@viewer).role
    end

    test "a changed_by who is not a member of the organization is only recorded, as before" do
      outsider = create_user!

      @org.change_role_of!(@viewer, to: :admin, changed_by: outsider)

      assert_equal "admin", membership_of(@viewer).role

      membership_of(@viewer).demote_to!(:member, changed_by: outsider)

      assert_equal "member", membership_of(@viewer).role
    end

    test "the check reads the target's current role, not a stale copy" do
      stale = membership_of(@viewer)
      @org.change_role_of!(@viewer, to: :admin, changed_by: @owner)

      assert_raises(Organizations::NotAuthorized) do
        stale.promote_to!(:lead, changed_by: @lead)
      end

      assert_equal "admin", membership_of(@viewer).role
    end

    # === Removals ===

    test "a lead cannot remove an admin" do
      error = assert_raises(Organizations::NotAuthorized) do
        @org.remove_member!(@admin, removed_by: @lead)
      end

      assert_equal :remove_members, error.permission
      assert_equal @org, error.organization
      assert_equal @lead, error.user
      assert_equal "You can't remove a member with the Admin role because it ranks above yours", error.message
      assert @org.has_member?(@admin)
    end

    test "a refused removal fires no member_removed callback" do
      fired = []
      Organizations.configure { |config| config.on_member_removed { |ctx| fired << ctx } }

      assert_raises(Organizations::NotAuthorized) { @org.remove_member!(@admin, removed_by: @lead) }

      assert_empty fired
    end

    test "a lead can remove members at or below its own role" do
      other_lead = add!(:lead)

      @org.remove_member!(@viewer, removed_by: @lead)
      @org.remove_member!(other_lead, removed_by: @lead)

      refute @org.has_member?(@viewer)
      refute @org.has_member?(other_lead)
    end

    test "a lead still gets the owner refusal when removing the owner" do
      assert_raises(Organizations::Organization::CannotRemoveOwner) do
        @org.remove_member!(@owner, removed_by: @lead)
      end
    end

    test "an admin can remove another admin, and the owner can remove an admin" do
      other_admin = add!(:admin)

      @org.remove_member!(other_admin, removed_by: @admin)
      @org.remove_member!(@admin, removed_by: @owner)

      refute @org.has_member?(other_admin)
      refute @org.has_member?(@admin)
    end

    test "a removal judges the role held under the lock, not the one read before it" do
      target = @viewer
      org = @org
      # Promote the target between remove_member!'s lookup and its lock.
      org.define_singleton_method(:lock!) do |*args|
        Membership.where(organization_id: id, user_id: target.id).update_all(role: "admin")
        super(*args)
      end

      error = assert_raises(Organizations::NotAuthorized) { org.remove_member!(target, removed_by: @lead) }

      assert_match "Admin", error.message
      assert @org.has_member?(target) # the simulated promotion rolls back with the refusal
    end

    test "a removal refuses a member who became the owner after the lookup" do
      target = @admin
      owner = @owner
      org = @org
      # Transfer ownership to the target between the lookup and the lock.
      org.define_singleton_method(:lock!) do |*args|
        Membership.where(organization_id: id, user_id: owner.id).update_all(role: "admin")
        Membership.where(organization_id: id, user_id: target.id).update_all(role: "owner")
        super(*args)
      end

      assert_raises(Organizations::Organization::CannotRemoveOwner) { org.remove_member!(target, removed_by: owner) }

      assert_equal 1, @org.memberships.where(role: "owner").count
    end

    test "a removal without removed_by, or by a non-member, is not capped, as before" do
      other_admin = add!(:admin)

      @org.remove_member!(@admin)
      @org.remove_member!(other_admin, removed_by: create_user!)

      refute @org.has_member?(@admin)
      refute @org.has_member?(other_admin)
    end

    # === Invitation management ===

    test "a lead cannot revoke an admin invitation" do
      invitation = @org.send_invite_to!("admin-invite@example.com", invited_by: @admin, role: :admin)

      error = assert_raises(Organizations::NotAuthorized) { invitation.revoke!(revoked_by: @lead) }

      assert_equal :invite_members, error.permission
      assert_equal @lead, error.user
      assert_equal "You can't revoke or resend an invitation for the Admin role because it ranks above yours",
                   error.message
      assert Organizations::Invitation.exists?(invitation.id)
    end

    test "a lead cannot resend an admin invitation" do
      invitation = @org.send_invite_to!("admin-invite@example.com", invited_by: @admin, role: :admin)
      token = invitation.token

      assert_raises(Organizations::NotAuthorized) { invitation.resend!(resent_by: @lead) }

      assert_equal token, invitation.reload.token
    end

    test "a lead can revoke and resend invitations at or below its own role" do
      lead_invite = @org.send_invite_to!("lead-invite@example.com", invited_by: @admin, role: :lead)
      viewer_invite = @org.send_invite_to!("viewer-invite@example.com", invited_by: @admin, role: :viewer)
      token = lead_invite.token

      lead_invite.resend!(resent_by: @lead)
      viewer_invite.revoke!(revoked_by: @lead)

      refute_equal token, lead_invite.reload.token
      refute Organizations::Invitation.exists?(viewer_invite.id)
    end

    test "an admin and the owner can revoke and resend admin invitations" do
      first = @org.send_invite_to!("first@example.com", invited_by: @owner, role: :admin)
      second = @org.send_invite_to!("second@example.com", invited_by: @owner, role: :admin)

      first.resend!(resent_by: @admin)
      first.revoke!(revoked_by: @admin)
      second.resend!(resent_by: @owner)
      second.revoke!(revoked_by: @owner)

      assert_equal 0, @org.invitations.count
    end

    test "revoke! and resend! without an actor, or by a non-member, are not capped, as before" do
      invitation = @org.send_invite_to!("admin-invite@example.com", invited_by: @admin, role: :admin)

      invitation.resend!
      invitation.resend!(resent_by: create_user!)
      invitation.revoke!

      refute Organizations::Invitation.exists?(invitation.id)
    end

    # === View helpers ===

    test "can_remove_member? and can_change_member_role? follow the same rule" do
      Organizations.configure do |config|
        config.roles do
          role :lead, inherits: :member do
            can :invite_members
            can :edit_member_roles
            can :remove_members
          end
          role :finance, inherits: :member do
            can :view_billing
          end
        end
      end
      helper = Object.new.extend(Organizations::ViewHelpers)
      finance = add!(:finance)

      refute helper.can_remove_member?(@lead, membership_of(@admin))
      refute helper.can_change_member_role?(@lead, membership_of(@admin))
      refute helper.can_remove_member?(@lead, membership_of(finance))
      refute helper.can_change_member_role?(@lead, membership_of(finance))
      assert helper.can_remove_member?(@lead, membership_of(@viewer))
      assert helper.can_change_member_role?(@lead, membership_of(@viewer))
      assert helper.can_remove_member?(@admin, membership_of(finance))
      assert helper.can_change_member_role?(@admin, membership_of(finance))
    end

    # === Custom roles without a parent ===

    test "a custom role without inherits: sits at the bottom and can only invite to roles it covers" do
      Organizations.configure do |config|
        config.roles do
          role :recruiter do
            can :view_members
            can :invite_members
          end
        end
      end
      recruiter = add!(:recruiter)

      assert_equal :recruiter, Roles.hierarchy.last
      assert_raises(Organizations::NotAuthorized) do
        recruiter.send_organization_invite_to!("new@example.com", organization: @org)
      end
      assert_equal "recruiter",
                   recruiter.send_organization_invite_to!("peer@example.com", organization: @org, role: :recruiter).role
    end

    test "the recommended fix for such a role is to inherit the role it should invite to" do
      Organizations.configure do |config|
        config.roles do
          role :recruiter, inherits: :member do
            can :invite_members
          end
        end
      end
      recruiter = add!(:recruiter)

      assert_equal "member", recruiter.send_organization_invite_to!("new@example.com", organization: @org).role
    end

    # === Messages ===

    test "the refusals are localized" do
      I18n.with_locale(:es) do
        invite = assert_raises(Organizations::NotAuthorized) do
          @org.send_invite_to!("new@example.com", invited_by: @lead, role: :admin)
        end
        change = assert_raises(Organizations::NotAuthorized) do
          @org.change_role_of!(@admin, to: :member, changed_by: @lead)
        end

        assert_equal "No puedes invitar a nadie como Administrador porque ese rol está por encima del tuyo",
                     invite.message
        assert_equal "No puedes asignar ni retirar el rol Administrador porque está por encima del tuyo",
                     change.message

        removal = assert_raises(Organizations::NotAuthorized) do
          @org.remove_member!(@admin, removed_by: @lead)
        end
        assert_equal "No puedes eliminar a un miembro con el rol Administrador porque está por encima del tuyo",
                     removal.message

        invitation = @org.send_invite_to!("admin-invite@example.com", invited_by: @admin, role: :admin)
        management = assert_raises(Organizations::NotAuthorized) { invitation.revoke!(revoked_by: @lead) }
        assert_equal "No puedes revocar ni reenviar una invitación para el rol Administrador " \
                     "porque está por encima del tuyo", management.message

        sibling = assert_raises(Organizations::NotAuthorized) do
          @org.send_invite_to!("finance@example.com", invited_by: @lead, role: :finance)
        end
        assert_equal "No puedes actuar sobre el rol Finance porque tiene permisos que tú no tienes", sibling.message
      end
    end

    private

    def add!(role)
      user = create_user!
      Organizations::Membership.create!(user: user, organization: @org, role: role.to_s)
      user
    end

    def membership_of(user)
      @org.memberships.find_by!(user_id: user.id)
    end
  end
end
