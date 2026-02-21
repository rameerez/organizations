## [0.3.0] - 2026-02-20

### Added

- **Invitation flow helpers** in `ControllerHelpers`:
  - `pending_organization_invitation_token` - Get pending invitation token from session
  - `pending_organization_invitation` - Get pending invitation record (clears if expired/accepted)
  - `pending_organization_invitation?` - Check if valid pending invitation exists
  - `pending_organization_invitation_email` - Get invited email for signup prefill
  - `clear_pending_organization_invitation!` - Clear invitation token and cache
  - `accept_pending_organization_invitation!(user, token:, switch:, skip_email_validation:)` - Canonical invitation acceptance helper for post-signup flows
  - `pending_invitation_acceptance_redirect_path_for(user, ...)` - Accept invitation and resolve redirect in one call
  - `handle_pending_invitation_acceptance_for(user, redirect: ...)` - Accept invitation and optionally perform redirect
  - `redirect_path_when_invitation_requires_authentication(invitation, user:)` - Get configured auth-required redirect
  - `redirect_path_after_invitation_accepted(invitation, user:)` - Get configured post-accept redirect
  - `redirect_path_when_no_organization` / `redirect_to_no_organization!` - Canonical no-organization redirect helpers
  - `create_organization_and_switch!` - Create organization and set current context in one call

- **Invitation redirect configuration**:
  - `config.redirect_path_when_invitation_requires_authentication` - Where to redirect unauthenticated users (String or Proc)
  - `config.redirect_path_after_invitation_accepted` - Where to redirect after acceptance (String or Proc)
  - `config.redirect_path_after_organization_switched` - Where to redirect after switching orgs (String or Proc)
  - `config.no_organization_alert` / `config.no_organization_notice` - Optional default flash messages for built-in no-organization redirects
  - `config.authenticated_controller_layout` - Layout override for authenticated engine controllers
  - `config.public_controller_layout` - Layout override for public engine controllers

- **InvitationAcceptanceResult** - Value object returned by `accept_pending_organization_invitation!` with:
  - `status` (`:accepted` or `:already_member`)
  - `invitation`, `membership`, `switched` attributes
  - `accepted?`, `already_member?`, `switched?` predicates

- **InvitationAcceptanceFailure** - Structured failure object for `accept_pending_organization_invitation!` when called with `return_failure: true`
  - `failure_reason` and reason predicates (`missing_token?`, `email_mismatch?`, etc.)
  - Unified `success?`/`failure?` API with `InvitationAcceptanceResult`

### Changed

- `PublicInvitationsController` now uses configurable redirect paths and the canonical acceptance helper
- **DRY refactor**: Engine's `ApplicationController` now delegates to `ControllerHelpers` instead of duplicating logic (~200 lines removed)
- `SwitchController` now uses `redirect_path_after_organization_switched` for post-switch redirects
- Engine current-user lookup is now consolidated through `CurrentUserResolution`

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
