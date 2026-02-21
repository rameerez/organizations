## [0.3.0] - 2026-02-20

- Invitation onboarding is now first-class and configurable, so host apps can remove most custom signup/invite glue code.
- Public invitation flows now work with Devise out of the box under the default public controller setup.
- Redirect behavior is now configurable for auth-required invitation acceptance, post-acceptance, post-switch, and no-organization flows.
- Invitation acceptance now returns structured success/failure objects, making controller handling clearer and safer.
- Switching and current-user resolution were hardened for auth-transition and stale-cache edge cases.
- Engine views now delegate host-app route helpers more cleanly, reducing `main_app.` boilerplate in host layouts/partials.
- `create_organization!` now forwards full attribute hashes, enabling custom organization validations/fields without workarounds.
- Performance improved: owner lookup avoids unnecessary SQL when memberships are preloaded (lower N+1 risk on list/admin pages).
- Test coverage expanded significantly around invitation flow, switching behavior, current-user resolution, and configuration contracts.

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
