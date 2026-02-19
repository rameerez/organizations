# frozen_string_literal: true

module Organizations
  # Test helpers for Minitest.
  # Include in your test helper to get organization-related test utilities.
  #
  # @example Include in test_helper.rb
  #   require "organizations/test_helpers"
  #
  #   class ActiveSupport::TestCase
  #     include Organizations::TestHelpers
  #   end
  #
  # @example Using in tests
  #   test "admin can invite members" do
  #     sign_in_as_organization_member(@user, @org, role: :admin)
  #     post invitations_path, params: { email: "new@example.com" }
  #     assert_response :success
  #   end
  #
  module TestHelpers
    # Set the current organization in the session/context
    # @param org [Organizations::Organization] The organization to set
    def set_current_organization(org)
      if respond_to?(:session)
        session[Organizations.configuration.session_key] = org.id
      end

      # Also set on Current if available
      if defined?(Current) && Current.respond_to?(:organization=)
        Current.organization = org
      end
    end

    # Clear the current organization from session/context
    def clear_current_organization
      if respond_to?(:session)
        session.delete(Organizations.configuration.session_key)
      end

      if defined?(Current) && Current.respond_to?(:organization=)
        Current.organization = nil
      end
    end

    # Sign in as a member of an organization with a specific role
    # @param user [User] The user to sign in
    # @param org [Organizations::Organization] The organization
    # @param role [Symbol] The role (default: :member)
    def sign_in_as_organization_member(user, org, role: :member)
      # Ensure membership exists with the correct role
      membership = Organizations::Membership.find_or_create_by!(
        user: user,
        organization: org
      ) do |m|
        m.role = role.to_s
      end

      # Update role if different
      membership.update!(role: role.to_s) if membership.role != role.to_s

      # Sign in the user (if Devise or similar is available)
      if respond_to?(:sign_in)
        sign_in(user)
      end

      # Set current organization
      set_current_organization(org)

      # Set on user
      user._current_organization_id = org.id if user.respond_to?(:_current_organization_id=)

      membership
    end

    # Create a test organization with an owner
    # @param name [String] Organization name
    # @param owner [User] The owner user
    # @return [Organizations::Organization]
    def create_organization(name: "Test Org", owner:)
      org = Organizations::Organization.create!(name: name)
      Organizations::Membership.create!(
        user: owner,
        organization: org,
        role: "owner"
      )
      org
    end

    # Create a test invitation
    # @param org [Organizations::Organization] The organization
    # @param email [String] Email to invite
    # @param invited_by [User] Who is inviting
    # @param role [Symbol] Role for the invitation
    # @return [Organizations::Invitation]
    def create_invitation(org:, email:, invited_by:, role: :member)
      Organizations::Invitation.create!(
        organization: org,
        email: email,
        invited_by: invited_by,
        role: role.to_s,
        token: SecureRandom.urlsafe_base64(32),
        expires_at: 7.days.from_now
      )
    end

    # Create a test user with optional organization membership
    # @param email [String] User email
    # @param name [String] User name
    # @param org [Organizations::Organization, nil] Organization to join
    # @param role [Symbol] Role in the organization
    # @return [User]
    def create_user(email: "user@example.com", name: "Test User", org: nil, role: :member)
      user = User.create!(email: email, name: name)

      if org
        Organizations::Membership.create!(
          user: user,
          organization: org,
          role: role.to_s
        )
      end

      user
    end

    # Assert that a user is a member of an organization
    # @param user [User] The user
    # @param org [Organizations::Organization] The organization
    def assert_member_of(user, org)
      assert user.is_member_of?(org), "Expected #{user.email} to be a member of #{org.name}"
    end

    # Assert that a user is NOT a member of an organization
    # @param user [User] The user
    # @param org [Organizations::Organization] The organization
    def refute_member_of(user, org)
      refute user.is_member_of?(org), "Expected #{user.email} NOT to be a member of #{org.name}"
    end

    # Assert that a user has a specific role in an organization
    # @param user [User] The user
    # @param role [Symbol] The expected role
    # @param org [Organizations::Organization] The organization
    def assert_role(user, role, in: nil)
      org = binding.local_variable_get(:in)
      actual_role = user.role_in(org)
      assert_equal role.to_sym, actual_role, "Expected #{user.email} to have role #{role} in #{org.name}, got #{actual_role}"
    end

    # Assert that a user has a specific permission
    # @param user [User] The user
    # @param permission [Symbol] The permission
    def assert_permission(user, permission)
      assert user.has_organization_permission_to?(permission),
             "Expected #{user.email} to have permission #{permission}"
    end

    # Assert that a user does NOT have a specific permission
    # @param user [User] The user
    # @param permission [Symbol] The permission
    def refute_permission(user, permission)
      refute user.has_organization_permission_to?(permission),
             "Expected #{user.email} NOT to have permission #{permission}"
    end
  end
end
