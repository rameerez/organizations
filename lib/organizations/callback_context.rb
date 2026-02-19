# frozen_string_literal: true

module Organizations
  # Immutable context object passed to all callbacks.
  # Provides consistent, typed access to event data.
  #
  # Different events populate different fields:
  # - :organization_created => organization, user
  # - :member_invited => organization, invitation, invited_by
  # - :member_joined => organization, membership, user
  # - :member_removed => organization, membership, user, removed_by
  # - :role_changed => organization, membership, old_role, new_role, changed_by
  # - :ownership_transferred => organization, old_owner, new_owner
  #
  # @example Accessing context data
  #   config.on_organization_created do |ctx|
  #     Analytics.track(ctx.user, "org_created", name: ctx.organization.name)
  #   end
  #
  CallbackContext = Struct.new(
    :event,           # Symbol - the event type (:organization_created, :member_joined, etc.)
    :organization,    # Organizations::Organization instance
    :user,            # User instance (the subject of the action)
    :membership,      # Organizations::Membership instance (if applicable)
    :invitation,      # Organizations::Invitation instance (if applicable)
    :invited_by,      # User instance - who sent the invitation
    :removed_by,      # User instance - who removed the member
    :changed_by,      # User instance - who changed the role
    :old_role,        # Symbol - previous role (for role_changed)
    :new_role,        # Symbol - new role (for role_changed)
    :old_owner,       # User instance - previous owner (for ownership_transferred)
    :new_owner,       # User instance - new owner (for ownership_transferred)
    :permission,      # Symbol - the permission that was required (for unauthorized)
    :required_role,   # Symbol - the role that was required (for unauthorized)
    :metadata,        # Hash - additional contextual data
    keyword_init: true
  ) do
    # Convert to hash, removing nil values
    # @return [Hash]
    def to_h
      super.compact
    end

    # Check if this is a specific event type
    # @param event_name [Symbol] Event to check
    # @return [Boolean]
    def event?(event_name)
      event == event_name
    end
  end
end
