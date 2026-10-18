# frozen_string_literal: true

require "test_helper"
require_relative "controller_helpers_test"

# The permission helpers and the hierarchy with custom roles, end to end:
# Roles, the user and membership checks, the view helpers and the
# controller guards must agree on one configured hierarchy.
#
# Hierarchy under test (highest first):
#   owner > admin > lead > member > auditor > client > viewer > guest
class CustomRoleHelpersTest < Organizations::Test
  include Organizations::ViewHelpers

  ROLES = proc do
    role :client, inherits: :viewer do
      can :answer_questions
    end
    role :auditor, inherits: :client do
      can :view_billing_reports
    end
    role :lead, inherits: :member do
      can :invite_members
      can :remove_members
      can :manage_settings
    end
    role :guest do
      can :view_organization
    end
  end

  def setup
    super
    Organizations.configure { |config| config.roles(&ROLES) }
    @org, @owner = create_org_with_owner!(name: "Custom Co")
    @lead = member_with(:lead)
    @auditor = member_with(:auditor)
    @client = member_with(:client)
    @guest = member_with(:guest)
    @member = member_with(:member)
  end

  # === Roles ===

  test "the hierarchy places each custom role above its parent, and a parentless one at the bottom" do
    assert_equal %i[owner admin lead member auditor client viewer guest], Organizations::Roles.hierarchy
  end

  test "rank comparisons follow the configured hierarchy" do
    roles = Organizations::Roles

    assert roles.at_least?(:lead, :member)
    refute roles.at_least?(:lead, :admin)
    assert roles.at_least?(:auditor, :client)
    refute roles.at_least?(:client, :auditor)
    assert roles.at_least?(:viewer, :guest)
    assert_equal(-1, roles.compare(:lead, :member))
    assert_equal 1, roles.compare(:guest, :viewer)
    assert_equal :lead, roles.higher_role(:member)
    assert_equal :client, roles.lower_role(:auditor)
    assert_nil roles.lower_role(:guest)
  end

  test "permissions inherit through a chain of custom roles" do
    perms = Organizations::Roles.permissions_for(:auditor)

    assert_includes perms, :view_billing_reports
    assert_includes perms, :answer_questions
    assert_includes perms, :view_members
    refute_includes perms, :create_resources
    assert_equal %i[view_organization], Organizations::Roles.permissions_for(:guest)
  end

  # === User checks ===

  test "user role checks in a specific organization" do
    assert @lead.is_at_least?(:member, in: @org)
    refute @lead.is_admin_of?(@org)
    refute @client.is_at_least?(:member, in: @org)
    assert @client.is_viewer_of?(@org)
    assert_equal :auditor, @auditor.role_in(@org)
  end

  test "user role checks in the current organization" do
    use_current(@client)

    refute_predicate @client, :is_organization_member?
    assert_predicate @client, :is_organization_viewer?
    assert @client.has_organization_role?(:client)
    refute @client.has_organization_role?(:auditor)
    assert @client.has_organization_permission_to?(:answer_questions)
    refute @client.has_organization_permission_to?(:create_resources)

    use_current(@lead)

    assert_predicate @lead, :is_organization_member?
    refute_predicate @lead, :is_organization_admin?
    assert @lead.has_organization_permission_to?(:invite_members)
  end

  # === Membership checks ===

  test "membership checks and the assignment rule" do
    lead_membership = membership_of(@lead)

    assert lead_membership.has_permission_to?(:manage_settings)
    assert lead_membership.is_at_least?(:member)
    assert lead_membership.can_assign_role?(:member)
    refute lead_membership.can_assign_role?(:client),
           "below admin, an actor must hold the role's permissions (answer_questions)"
    refute lead_membership.can_assign_role?(:admin)
    refute membership_of(@client).can_assign_role?(:auditor), "a lower role never assigns a higher one"
  end

  # === View helpers ===

  test "view helpers follow the custom permissions" do
    assert can_manage_organization?(@lead, @org)
    assert can_invite_members?(@lead, @org)
    refute can_invite_members?(@auditor, @org)
    refute can_manage_billing?(@lead, @org)
    refute can_transfer_ownership?(@lead, @org)
    refute can_delete_organization?(@lead, @org)
    assert can_view_billing?(@owner, @org)
  end

  test "view helpers apply the role rule to member actions" do
    admin = member_with(:admin)

    assert can_remove_member?(@lead, membership_of(@member))
    refute can_remove_member?(@lead, membership_of(@client)), "the client role has a permission the lead lacks"
    refute can_remove_member?(@lead, membership_of(admin)), "a lead never removes an admin"
    refute can_remove_member?(@auditor, membership_of(@client)), "no remove_members permission"
    refute can_change_member_role?(@lead, membership_of(@member)), "no edit_member_roles permission"
  end

  test "role labels humanize custom roles and keep the I18n catalog for built-in ones" do
    assert_equal "Lead", organization_role_label(:lead)
    assert_equal "Admin", organization_role_label(:admin)
    assert_equal({ role: :guest, label: "Guest", color: organization_role_info(:guest)[:color] },
                 organization_role_info(:guest))
  end

  # === Controller guards ===

  test "require_organization_permission_to! follows the custom permissions" do
    allowed = guard_for(@lead) { |c| c.require_organization_permission_to!(:manage_settings) }
    denied = guard_for(@auditor) { |c| c.require_organization_permission_to!(:manage_settings) }

    assert_nil allowed.redirected_to
    refute_nil denied.redirected_to
  end

  test "require_organization_role! follows the custom hierarchy" do
    assert_nil guard_for(@lead) { |c| c.require_organization_role!(:member) }.redirected_to
    refute_nil guard_for(@auditor) { |c| c.require_organization_role!(:member) }.redirected_to
    assert_nil guard_for(@auditor) { |c| c.require_organization_role!(:client) }.redirected_to
  end

  private

  def member_with(role)
    user = create_user!
    @org.add_member!(user, role: role)
    user
  end

  def membership_of(user)
    @org.memberships.find_by!(user_id: user.id)
  end

  def use_current(user)
    user._current_organization_id = @org.id
  end

  def guard_for(user)
    controller = Organizations::ControllerHelpersTest::MockController.new
    controller.test_current_user = user
    controller.session[:current_organization_id] = @org.id
    controller.set_format(:html)
    yield controller
    controller
  end
end
