# frozen_string_literal: true

require "active_support/current_attributes"

module Organizations
  # The organization the current request or job acts for.
  #
  # The controller helpers set it whenever `current_organization` resolves
  # or changes (a switch, a fallback, a sign-out from the organization).
  # Jobs and scripts set it with `Organizations.with_organization`. Rails
  # resets it before every request and every job, so a value never leaks
  # from one to the next.
  #
  #   Organizations::Current.organization # => #<Organizations::Organization id: 42>
  #
  # It is the one place a host hooks its own tenant context, such as a
  # PostgreSQL setting that row-level security policies read: every change
  # goes through `organization=`, and every reset through `resets`.
  #
  #   module TenantContext
  #     def organization=(organization)
  #       super
  #       Tenant.enter(organization)
  #     end
  #   end
  #
  #   Organizations::Current.prepend(TenantContext)
  #   Organizations::Current.resets { Tenant.leave }
  class Current < ActiveSupport::CurrentAttributes
    attribute :organization
  end
end
