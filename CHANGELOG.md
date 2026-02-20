## [0.3.0] - 2026-02-20

### Added

- **Invitation flow helpers** in `ControllerHelpers`:
  - `pending_organization_invitation_token` - Get pending invitation token from session
  - `pending_organization_invitation` - Get pending invitation record (clears if expired/accepted)
  - `pending_organization_invitation?` - Check if valid pending invitation exists
  - `clear_pending_organization_invitation!` - Clear invitation token and cache
  - `accept_pending_organization_invitation!(user, token:, switch:, skip_email_validation:)` - Canonical invitation acceptance helper for post-signup flows
  - `redirect_path_when_invitation_requires_authentication(invitation, user:)` - Get configured auth-required redirect
  - `redirect_path_after_invitation_accepted(invitation, user:)` - Get configured post-accept redirect

- **Invitation redirect configuration**:
  - `config.redirect_path_when_invitation_requires_authentication` - Where to redirect unauthenticated users (String or Proc)
  - `config.redirect_path_after_invitation_accepted` - Where to redirect after acceptance (String or Proc)

- **InvitationAcceptanceResult** - Value object returned by `accept_pending_organization_invitation!` with:
  - `status` (`:accepted` or `:already_member`)
  - `invitation`, `membership`, `switched?` attributes
  - `accepted?`, `already_member?`, `switched?` predicates

### Changed

- `PublicInvitationsController` now uses configurable redirect paths and the canonical acceptance helper
- **DRY refactor**: Engine's `ApplicationController` now delegates to `ControllerHelpers` instead of duplicating logic (~200 lines removed)

## [0.2.0] - 2026-02-20

- Namespaced all tables with `organizations_` prefix to prevent collisions with host apps

## [0.1.1] - 2026-02-19

- Removed `slugifiable` dependency (deferred to host app)

## [0.1.0] - 2026-02-19

Initial release.

- User → Membership → Organization pattern with `has_organizations` macro
- Hierarchical roles (owner > admin > member > viewer) with customizable permissions
- Token-based invitation system with email delivery
- Organization switching for multi-org users
- Ownership transfer with role demotion for previous owner
- Controller helpers and authorization (`require_organization!`, `require_organization_admin!`)
- Lifecycle callbacks for integrations (`on_member_joined`, `on_role_changed`, etc.)
- Row-level locking for race conditions (concurrent invitations, ownership transfers)
- Works with any auth system (Devise, Rodauth, Sorcery)
- Edge case handling (last owner can't leave, stale session cleanup, concurrent invitation acceptance)
