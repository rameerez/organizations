# frozen_string_literal: true

require "test_helper"

# Scoped resource grants: a membership limited to some records of the host
# app, with a capability list per record. The role's permissions stay the
# ceiling: a grant narrows, never widens.
class ResourceGrantsTest < Organizations::Test
  def setup
    super
    configure_roles
    @org, @owner = create_org_with_owner!(name: "Firm")
    @alpha = Document.create!(organization: @org, title: "Alpha")
    @beta = Document.create!(organization: @org, title: "Beta")
    @gamma = Document.create!(organization: @org, title: "Gamma")
    @accountant = create_user!
    @membership = @org.add_member!(@accountant, role: :member)
  end

  # Roles with resource capabilities: a client is narrower than a member.
  ROLES = proc do
    role :viewer do
      can :view_organization
      can :read
    end
    role :client, inherits: :viewer do
      can :answer
    end
    role :member, inherits: :viewer do
      can :answer
      can :edit
    end
    role :admin, inherits: :member do
      can :invite_members
      can :remove_members
      can :edit_member_roles
      can :manage_settings
      can :approve
    end
    role :owner, inherits: :admin do
      can :manage_billing
      can :transfer_ownership
      can :delete_organization
    end
  end

  def configure_roles
    Organizations.configure { |config| config.roles(&ROLES) }
  end

  # === Granting ===

  test "grant! records the resource and its capabilities" do
    grant = @membership.grant!(@alpha, capabilities: %w[read edit])

    assert_equal @alpha, grant.grantable
    assert_equal %w[read edit], grant.capabilities
    assert_equal [grant], @membership.grants.to_a
    assert @membership.granted?(@alpha)
    refute @membership.granted?(@beta)
  end

  test "grant! again replaces the capabilities (an upsert)" do
    @membership.grant!(@alpha, capabilities: %w[read edit])

    grant = @membership.grant!(@alpha, capabilities: [:read])

    assert_equal %w[read], grant.capabilities
    assert_equal 1, @membership.grants.count
  end

  test "grant! with no capabilities removes the grant" do
    @membership.grant!(@alpha, capabilities: %w[read])

    assert_nil @membership.grant!(@alpha, capabilities: [])
    refute @membership.granted?(@alpha)
  end

  test "revoke_grant! removes the grant and is idempotent" do
    @membership.grant!(@alpha, capabilities: %w[read])

    @membership.revoke_grant!(@alpha)
    @membership.revoke_grant!(@alpha)

    refute @membership.granted?(@alpha)
  end

  test "capabilities are normalized to unique strings" do
    grant = @membership.grant!(@alpha, capabilities: [:read, "read", " edit "])

    assert_equal %w[read edit], grant.capabilities
  end

  test "config.grant_capabilities limits the capability names" do
    Organizations.configure { |c| c.grant_capabilities = %i[read edit answer] }

    error = assert_raises(ActiveRecord::RecordInvalid) { @membership.grant!(@alpha, capabilities: %w[read fly]) }

    assert_match "fly", error.message
  end

  test "a resource that is not an ActiveRecord model is granted by type and id" do
    entity = Organizations::Resource.new("Ledger::Entity", 42)

    grant = @membership.grant!(entity, capabilities: %w[read])

    assert_equal "Ledger::Entity", grant.grantable_type
    assert_equal 42, grant.grantable_id
    assert @membership.granted?(entity)
    assert @membership.can?(:read, Organizations::Resource.new("Ledger::Entity", 42))
  end

  test "any object with an id works as a resource, typed by its class name" do
    value_class = Struct.new(:id)
    stub_const_name(value_class, "Ledger::Value") do
      @membership.grant!(value_class.new(7), capabilities: %w[read])

      assert_equal "Ledger::Value", @membership.grants.first.grantable_type
    end
  end

  test "a resource of another organization is refused when it says so" do
    other_org, = create_org_with_owner!(name: "Other")
    foreign = Document.create!(organization: other_org, title: "Foreign")

    assert_raises(ArgumentError) { @membership.grant!(foreign, capabilities: %w[read]) }
  end

  # === Checking: the role is the ceiling ===

  test "a limited member can do only what a grant lists, within the role" do
    @membership.grant!(@alpha, capabilities: %w[read edit approve])

    assert @membership.can?(:read, @alpha)
    assert @membership.can?(:edit, @alpha)
    refute @membership.can?(:approve, @alpha), "a grant never widens the role"
    refute @membership.can?(:read, @beta), "no grant, no access"
    assert_equal %i[edit read], @membership.capabilities_for(@alpha).to_a.sort
  end

  test "a client role is narrower than a member with the same grant" do
    client = create_user!
    client_membership = @org.add_member!(client, role: :client)
    client_membership.grant!(@alpha, capabilities: %w[read answer edit])

    assert client_membership.can?(:answer, @alpha)
    refute client_membership.can?(:edit, @alpha)
  end

  test "admins and the owner see every resource through their role" do
    admin = create_user!
    admin_membership = @org.add_member!(admin, role: :admin)

    refute_predicate admin_membership, :limited_by_grants?
    assert admin_membership.can?(:approve, @gamma)
    assert @org.owner_membership.can?(:edit, @beta)
    assert_predicate @membership, :limited_by_grants?
  end

  test "config.full_resource_access_role moves the line" do
    Organizations.configure { |c| c.full_resource_access_role = :owner }
    admin_membership = @org.add_member!(create_user!, role: :admin)

    assert_predicate admin_membership, :limited_by_grants?
    refute admin_membership.can?(:read, @alpha)

    Organizations.configure { |c| c.full_resource_access_role = nil }

    assert_predicate @org.owner_membership, :limited_by_grants?
  end

  test "promotion and demotion change access without touching grants" do
    @membership.grant!(@alpha, capabilities: %w[read])
    @org.change_role_of!(@accountant, to: :admin)

    assert @membership.reload.can?(:read, @beta)

    @org.change_role_of!(@accountant, to: :member)

    refute @membership.reload.can?(:read, @beta)
    assert @membership.can?(:read, @alpha)
  end

  test "a removed member loses every grant" do
    @membership.grant!(@alpha, capabilities: %w[read])

    @org.remove_member!(@accountant)

    assert_equal 0, Organizations::Grant.count
  end

  # === Scopes: what a member may see ===

  test "visible_to lists the granted records for a limited member" do
    @membership.grant!(@alpha, capabilities: %w[read])
    @membership.grant!(@gamma, capabilities: %w[read edit])

    assert_equal [@alpha, @gamma], Document.visible_to(@membership).order(:id).to_a
    assert_equal [@gamma], Document.visible_to(@membership, capability: :edit).to_a
    assert_empty Document.visible_to(@membership, capability: :approve), "the role is the ceiling"
  end

  test "visible_to lists every record for an admin, within the caller's scope" do
    admin_membership = @org.add_member!(create_user!, role: :admin)

    assert_equal 3, Document.where(organization: @org).visible_to(admin_membership).count
    assert_empty Document.visible_to(admin_membership, capability: :fly)
  end

  test "visible_to with nil is empty" do
    assert_empty Document.visible_to(nil)
  end

  test "membership.visible filters any relation" do
    @membership.grant!(@beta, capabilities: %w[read])

    assert_equal [@beta], @membership.visible(Document.all).to_a
  end

  test "granted_ids lists the ids of one type, optionally by capability" do
    entity_type = "Ledger::Entity"
    @membership.grant!(Organizations::Resource.new(entity_type, 1), capabilities: %w[read])
    @membership.grant!(Organizations::Resource.new(entity_type, 2), capabilities: %w[read edit])
    @membership.grant!(@alpha, capabilities: %w[read])

    assert_equal [1, 2], @membership.granted_ids(entity_type).sort
    assert_equal [2], @membership.granted_ids(entity_type, capability: :edit)
    assert_equal [@alpha.id], @membership.granted_ids(Document)
  end

  test "who has a grant on a resource" do
    @membership.grant!(@alpha, capabilities: %w[read])
    other = @org.add_member!(create_user!, role: :client)
    other.grant!(@beta, capabilities: %w[read])

    assert_equal [@membership], @org.memberships.with_grant_on(@alpha).to_a
    assert_equal [@membership], Organizations::Membership.with_grant_on(@alpha).to_a
    assert_equal 2, @org.grants.count
    assert_equal [@membership.grants.first], Organizations::Grant.for_resource(@alpha).to_a
    assert_equal 1, @alpha.organization_grants.count
  end

  test "destroying a grantable record destroys its grants" do
    @membership.grant!(@alpha, capabilities: %w[read])

    @alpha.destroy!

    assert_equal 0, Organizations::Grant.count
  end

  # === Who may grant ===

  test "a member without the management permission cannot grant" do
    peer = @org.add_member!(create_user!, role: :member)

    assert_raises(Organizations::NotAuthorized) do
      @membership.grant!(@alpha, capabilities: %w[read], granted_by: peer.user)
    end
  end

  test "an admin can grant and is recorded" do
    admin = create_user!
    @org.add_member!(admin, role: :admin)

    grant = @membership.grant!(@alpha, capabilities: %w[read], granted_by: admin)

    assert_equal admin, grant.granted_by
  end

  test "nobody grants to a role above their own" do
    Organizations.configure { |c| c.grant_management_permission = :answer }
    admin_membership = @org.add_member!(create_user!, role: :admin)

    assert_raises(Organizations::NotAuthorized) do
      admin_membership.grant!(@alpha, capabilities: %w[read], granted_by: @accountant)
    end
  end

  test "a limited granter cannot give more than they have" do
    Organizations.configure { |c| c.grant_management_permission = :answer }
    @membership.grant!(@alpha, capabilities: %w[read])
    client = @org.add_member!(create_user!, role: :client)

    assert_raises(Organizations::NotAuthorized) do
      client.grant!(@alpha, capabilities: %w[read answer], granted_by: @accountant)
    end
    assert_raises(Organizations::NotAuthorized) do
      client.grant!(@beta, capabilities: %w[read], granted_by: @accountant)
    end
    assert client.grant!(@alpha, capabilities: %w[read], granted_by: @accountant)
  end

  test "config.grant_management_permission names the permission" do
    Organizations.configure { |c| c.grant_management_permission = :manage_settings }

    assert_equal :manage_settings, Organizations.configuration.grant_management_permission
  end

  # === Invitations carry grants ===

  test "an invitation carries grants to the membership it creates" do
    invitation = @org.send_invite_to!("client@example.com", invited_by: @owner, role: :client,
                                                            grants: { @alpha => %w[read answer], @beta => %w[read] })
    client = create_user!(email: "client@example.com")

    membership = invitation.accept!(client)

    assert_equal({ @alpha.id => %w[read answer], @beta.id => %w[read] },
                 membership.grants.to_h { |g| [g.grantable_id, g.capabilities] })
    assert_equal 0, Organizations::Grant.where.not(invitation_id: nil).count
    assert membership.can?(:answer, @alpha)
  end

  test "accepting as an existing member merges the invitation grants" do
    @membership.grant!(@alpha, capabilities: %w[read])
    invitation = @org.invitations.create!(email: @accountant.email, invited_by: @owner, role: "member")
    invitation.grant!(@alpha, capabilities: %w[read edit])
    invitation.grant!(@beta, capabilities: %w[read])

    invitation.accept!(@accountant)

    assert_equal %w[read edit], @membership.grant_for(@alpha).capabilities
    assert @membership.granted?(@beta)
  end

  test "revoking an invitation drops its grants" do
    invitation = @org.send_invite_to!("gone@example.com", invited_by: @owner, grants: { @alpha => %w[read] })

    invitation.revoke!

    assert_equal 0, Organizations::Grant.count
  end

  test "a vetoed acceptance keeps the grants on the invitation" do
    invitation = @org.send_invite_to!("vetoed@example.com", invited_by: @owner, grants: { @alpha => %w[read] })
    Organizations.configure { |c| c.on_member_joining { raise Organizations::MembershipVetoed } }

    assert_raises(Organizations::MembershipVetoed) { invitation.accept!(create_user!(email: "vetoed@example.com")) }

    assert_equal 1, invitation.grants.count
  end

  test "an inviter without the management permission cannot attach grants" do
    Organizations.configure { |c| c.grant_management_permission = :manage_billing }
    admin = create_user!
    @org.add_member!(admin, role: :admin)

    assert_raises(Organizations::NotAuthorized) do
      @org.send_invite_to!("x@example.com", invited_by: admin, grants: { @alpha => %w[read] })
    end
    assert_equal 0, @org.invitations.count
  end

  test "the user API passes grants through" do
    @owner._current_organization_id = @org.id

    invitation = @owner.send_organization_invite_to!("y@example.com", role: :client, grants: { @alpha => %w[read] })

    assert_equal 1, invitation.grants.count
  end

  # === Review findings ===

  test "apps without the grants table can still remove members and revoke invitations" do
    invitation = @org.send_invite_to!("no-table@example.com", invited_by: @owner)
    without_grants_table do
      @org.remove_member!(@accountant)
      invitation.revoke!
      @org.reload.destroy!
    end

    refute Organizations::Organization.exists?(@org.id)
  end

  test "an explicit actor who is not a member is refused" do
    outsider = create_user!

    assert_raises(Organizations::NotAuthorized) do
      @membership.grant!(@alpha, capabilities: %w[read], granted_by: outsider)
    end
    assert_raises(Organizations::NotAuthorized) { @membership.revoke_grant!(@alpha, revoked_by: outsider) }
  end

  test "another organization's record is never accessible, also to admins and through Resource" do
    other_org, = create_org_with_owner!(name: "Other")
    foreign = Document.create!(organization: other_org, title: "Foreign")
    admin_membership = @org.add_member!(create_user!, role: :admin)

    refute admin_membership.can?(:read, foreign)
    refute admin_membership.can?(:read, Organizations::Resource.new("Document", foreign.id))
    assert_raises(ArgumentError) do
      @membership.grant!(Organizations::Resource.new("Document", foreign.id), capabilities: %w[read])
    end
  end

  test "a record moved to another organization loses its access" do
    @membership.grant!(@alpha, capabilities: %w[read])
    other_org, = create_org_with_owner!(name: "Other")

    @alpha.update!(organization: other_org)

    refute @membership.can?(:read, @alpha)
    refute_includes Document.visible_to(@membership), @alpha
  end

  test "visible filters by the membership's organization when the model has organization_id" do
    other_org, = create_org_with_owner!(name: "Other")
    Document.create!(organization: other_org, title: "Foreign")
    admin_membership = @org.add_member!(create_user!, role: :admin)

    assert_equal 3, Document.visible_to(admin_membership).count
  end

  test "enumeration respects the role ceiling" do
    @membership.grant!(@alpha, capabilities: %w[approve])
    @membership.grant!(@beta, capabilities: %w[read approve])

    assert_empty @membership.granted_ids(Document, capability: :approve)
    assert_equal [@beta.id], @membership.granted_ids(Document)
    assert_equal [@beta], Document.visible_to(@membership).to_a
  end

  test "reissuing an expired invitation drops its old grants" do
    invitation = @org.send_invite_to!("again@example.com", invited_by: @owner, grants: { @alpha => %w[read] })
    invitation.update_column(:expires_at, 1.day.ago)

    reissued = @org.send_invite_to!("again@example.com", invited_by: @owner, grants: { @beta => %w[read] })

    assert_equal invitation.id, reissued.id
    assert_equal [@beta.id], reissued.grants.pluck(:grantable_id)
  end

  test "acceptance checks the grants again against the inviter and the recipient" do
    Organizations.configure { |c| c.full_resource_access_role = nil }
    admin = create_user!
    @org.add_member!(admin, role: :admin)
    invitation = @org.invitations.create!(email: @owner.email, invited_by: admin, role: "member")
    invitation.grants.create!(grantable_type: "Document", grantable_id: @alpha.id, capabilities: %w[read])

    invitation.accept!(@owner)

    assert_equal 0, @org.owner_membership.grants.count, "an admin cannot grant to the owner, not even by invitation"
  end

  test "grants cannot be added to an accepted invitation" do
    invitation = @org.send_invite_to!("done@example.com", invited_by: @owner)
    invitation.accept!(create_user!(email: "done@example.com"))

    assert_raises(Organizations::InvitationAlreadyAccepted) do
      invitation.grant!(@alpha, capabilities: %w[read])
    end
  end

  test "an id that does not fit the grantable_id column is refused, never truncated" do
    assert_raises(ArgumentError) do
      @membership.grant!(Organizations::Resource.new("Ledger::Entity", "42-client-a"), capabilities: %w[read])
    end
    assert_raises(ArgumentError) { @membership.can?(:read, Organizations::Resource.new("Ledger::Entity", "42-x")) }
  end

  # === Configuration ===

  test "grant settings are validated" do
    assert_raises(Organizations::ConfigurationError) { Organizations.configure { |c| c.full_resource_access_role = :wizard } }
    assert_raises(Organizations::ConfigurationError) { Organizations.configure { |c| c.grant_capabilities = "read" } }
    assert_raises(Organizations::ConfigurationError) { Organizations.configure { |c| c.grant_management_permission = nil } }
  end

  private

  # The table as in an app that never ran rails g organizations:grants.
  def without_grants_table
    connection = ActiveRecord::Base.connection
    connection.rename_table(:organizations_grants, :organizations_grants_parked)
    forget_schema
    yield
  ensure
    connection.rename_table(:organizations_grants_parked, :organizations_grants)
    forget_schema
  end

  def forget_schema
    ActiveRecord::Base.connection.schema_cache.clear!
    Organizations::Grant.reset_column_information
  end

  def stub_const_name(klass, name, &)
    klass.stub(:name, name, &)
  end
end
