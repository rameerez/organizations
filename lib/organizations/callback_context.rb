# frozen_string_literal: true

module Organizations
  # Immutable context object passed to all callbacks
  # Provides consistent, typed access to event data
  CallbackContext = Struct.new(
    :event,           # Symbol - the event type
    :organization,    # Organizations::Organization instance
    :user,            # User instance
    :membership,      # Organizations::Membership instance (if applicable)
    :invitation,      # Organizations::Invitation instance (if applicable)
    :role,            # Symbol - role involved (if applicable)
    :metadata,        # Hash - additional contextual data
    keyword_init: true
  ) do
    def to_h
      super.compact
    end
  end
end
