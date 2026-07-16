## [0.5.0] - 2026-07-16

**Verified Joining** — users can now join organizations by proving they belong, closing three roadmap items (domain-based joining, request-to-join, roster/bulk import). Fully additive: existing installs change nothing until they enroll a domain, generate a code, or import a roster. Run `rails g organizations:upgrade` + `rails db:migrate` to get the new tables/columns.

### Added

- **Join requests** (`Organizations::JoinRequest`) — the mirror image of invitations (user→org). Memberships stay active-only; all pending state lives on the request (`pending → approved | rejected | withdrawn`, `:expired` derived like invitations). `user.request_to_join!(org)`, `org.approve_join_request!/reject_join_request!`, `request.withdraw!`. One open request per (org, user), DB-enforced.
- **Email domains** (`Organizations::Domain`) — `org.add_domain!("corp.com")`. Exact, dot-boundary-safe matching (subdomains are separate domains; lookalike and multi-@ evasion shapes rejected).
- **Emailed-code verification** — `request.start_email_verification!(email:)` + `request.verify_email_code!(code)`. Codes are 6 digits, stored as SHA-256 digests only (peppered by row id), single-use, TTL'd (15 min default), attempt-capped (5), resend-throttled. The proven address can differ from the account email — recorded as `verified_email` on the membership, **unique per organization** (one proven inbox = one member).
- **Join codes** (`Organizations::JoinCode`) — globally-unique shareable PINs: `org.generate_join_code!(label:, requires_verified_domain_email:, auto_approve:, expires_at:, max_uses:)`, `JoinCode.redeem(code, user:)`, `code.revoke!` (rotation = revoke + regenerate). `requires_verified_domain_email` chains the email challenge per-code ("reinforced" level); `auto_approve: false` parks redemptions for manual approval. Race-safe use accounting.
- **Allowlists / rosters** (`Organizations::AllowlistEntry`) — `org.import_allowlist!(emails, source:, membership_metadata:)` (idempotent). Rostered addresses still complete the email challenge (a leaked roster grants nothing without inbox access); entries are claimed on join.
- **Account-email trust shortcut** — `org.join_with_account_email!(user)`: when the host user's account email is confirmed (e.g. Devise `:confirmable`) and its domain is enrolled, joining needs no code. Gate with `config.trust_confirmed_account_email`.
- **Membership provenance** — memberships gain `joined_via` (`invited|code|domain_email|allowlist|manual`), `verified_email(_normalized)`, `verified_at`, plus `Membership#verified?`. Invitation acceptance now stamps provenance too (accepting the emailed token proves the inbox).
- **`membership_metadata` copy-through** — domains, join codes, allowlist entries, and invitations carry a `membership_metadata` hash merged onto memberships they create (cohort tags like `{ member_kind: "student" }`) — the gem never interprets it. Invitations also gained a `metadata` column (parity with other tables).
- **Callbacks** — `on_join_request_created`, `on_join_request_approved` (with `decided_by`, nil for auto-approvals), `on_join_request_rejected`.
- **Config** — `verification_mailer`, `verification_code_ttl`, `verification_max_attempts`, `verification_resend_interval`, `verification_max_sends`, `verification_email_normalizer` (default collapses case/whitespace/+tags), `trust_confirmed_account_email`, `join_request_expiry`, `join_code_generator`.
- **`Organizations::VerificationMailer`** (+ HTML/text templates), `Organizations::EmailNormalizer`, `organizations:upgrade` generator.

### Notes

- BYO-UI as always: the gem ships models/APIs/mailers, no controllers or views for joining. **Rate-limit your join/redemption endpoints in the host app.**
- After-callbacks stay error-isolated: enforce hard member caps BEFORE calling approve/redeem in host code.

## [0.4.3] - 2026-03-19

- Added `can_view_billing?` and `can_manage_billing?` view helpers for billing permission checks
- Refactored `can_manage_organization?` and `can_invite_members?` to use shared permission predicate
- Fixed `pricing_plans` integration examples to use `current_pricing_plan` (effective plan API)
- Clarified that billing permissions are authorization checks only, not subscription state indicators

## [0.4.2] - 2026-03-19

- Added `should_create_personal_organization?` predicate as extension seam for conditional personal org creation
- DSL `create_personal_organization` setting now accepts procs for dynamic evaluation
- Added `DELETE /memberships/leave` route for users to leave organizations
- Updated owner deletion guard message to clarify transfer/delete solution
- Documentation: added "Pattern 4: Hybrid Onboarding" to README

## [0.4.1] - 2026-03-17

- Fixed `memberships_count` counter cache writes on `Organizations::Membership.create!`
- Removed `attr_readonly :memberships_count`, which conflicted with Rails' native `counter_cache`

## [0.4.0] - 2026-03-17

**Breaking:** `memberships_count` column is now required on the organizations table.

- Added `memberships_count` to the install migration template (fresh installs get it automatically)
- Switched to Rails' native `counter_cache` so in-memory organization instances stay accurate after member changes
- `member_count` now reads directly from the counter cache (no fallback to COUNT query)

## [0.3.1] - 2026-02-28

- Fixed `organization_switcher_data[:switch_path]` generating broken URLs when engine mounted with custom name (e.g., `as: 'organizations_engine'`)
- `switch_path` now uses engine's own route helpers, works regardless of mount name or path

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
