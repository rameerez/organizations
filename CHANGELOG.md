## [Unreleased]

### Added

- **Personal organizations** (issue #21). `config.record_personal_organizations = true` records the auto-created organization as the user's personal organization. New API: `user.personal_organization` (a lookup, never creates), `user.create_personal_organization!` (idempotent, the repair path after a failed sign-up provisioning, converges under concurrency), `org.personal?`, `org.personal_owner`, `org.convert_to_shared!`, and the scopes `Organization.personal` and `Organization.not_personal`. The link is `organizations.personal_owner_id`: unique per user, `ON DELETE SET NULL`.
- `Organization.backfill_personal_owners!(mapping, dry_run:)` links reviewed users to existing organizations. It never guesses. It reports conflicts (`:organization_not_found`, `:not_the_owner`, `:organization_personal_for_another_user`, `:user_has_another_personal_organization`, `:organization_mapped_twice`, `:user_mapped_twice`) and writes nothing when any pair conflicts. It writes in its own savepoint, also inside a host transaction.
- **Safe account deletion.** `user.account_deletion_plan` lists what `user.destroy` would do, with each blocking organization and its reason, and changes nothing. `config.account_deletion_policy = :destroy_personal_organization` deletes the user's personal organization with the account when the user is its only member. Any other owned organization still blocks. The check covers the complete owned set first, and one transaction holds the organization and the user deletion, so a veto or a failure rolls back everything.
- `rails g organizations:upgrade` now adds only the migrations an install lacks: the 0.5.0 verified-joining migration and the 0.7.0 personal-organizations migration. It asks the database when it can and reads `db/migrate` otherwise. `--steps NAME…` generates exactly the named steps, for squashed histories. Before, it always generated the 0.5.0 migration, which broke installs made on 0.5.0 or later.

### Changed

- `transfer_ownership_to!` raises `Organization::CannotTransferPersonalOrganization` for a personal organization. Call `convert_to_shared!` first. Organizations that are not personal are not affected.
- `User#destroy` (from `has_organizations`, prepended so a host override cannot drop it) runs in its own savepoint, so an aborted destroy inside a host transaction rolls back what the deletion guard did.
- `transfer_ownership_to!` locks the new owner's user row before the organization row (the same order as the deletion guard, so the two cannot deadlock), so a transfer cannot race the deletion of that user. `create_with_owner!` and `create_organization!` raise `ArgumentError` for a `personal_owner` who is not the new owner.
- The account-deletion guard now locks the user row and the owned organization rows before it checks ownership. A concurrent organization creation for the user can no longer slip past the check and lose its owner membership. The default policy (`:prevent`) and its error message are unchanged, and the guard keeps its method name (`prevent_deletion_while_owning_organizations`), so a host `skip_callback` for it still works.

### Upgrading

Run `rails g organizations:upgrade && rails db:migrate`. Existing organizations stay unclassified until you backfill them.

## [0.6.1] - 2026-10-18

**Upgrade note.** Before this release, a custom role with `invite_members` or `edit_member_roles` could invite to, or promote to, a role above its own. An admin invitation crafted that way on 0.6.0 still grants admin when it is accepted after the upgrade. If your app has custom roles with those permissions, audit pending invitations and recent role changes made by members of those roles.

### Fixed

- **Security: a member could act on roles above their own.** Found by a template reviewer with a real request.
  - What was wrong: invitations, role changes and removals only refused or protected the `owner` role. Invitation revoke and resend checked no role at all.
  - Who hit it: apps with 0.6.0 custom roles. A role such as `role :lead, inherits: :member do can :invite_members; can :edit_member_roles end` passes the configuration rules. A crafted request from such a member could create an `admin` invitation, promote a viewer to `admin`, or demote an admin. With `remove_members` it could remove an admin. With `invite_members` it could revoke or resend an admin's invitation.
  - The rule now: a role acts only on roles at or below its own in `Roles.hierarchy`. That covers invitations (the invited role), role changes (the old and the new role), removals (the removed member's role) and invitation management (the invitation's role).
  - Below admin, rank is not enough. Two custom roles with the same parent are ranked only by definition order. So a role below admin must also hold every permission of the role it acts on. A `lead` defined before a `finance` role cannot hand out `finance`. Admins and the owner keep the rank rule alone.
  - Where it is enforced: in the models. `Organization#send_invite_to!` (and `user.send_organization_invite_to!`), `Organization#change_role_of!`, `Membership#promote_to!`, `Membership#demote_to!`, `Organization#remove_member!`, `Invitation#revoke!` and `Invitation#resend!`. The view helpers `can_remove_member?` and `can_change_member_role?` follow the same rule.
  - Who is checked: the member passed as `changed_by:`, `removed_by:`, `revoked_by:` or `resent_by:`, and the inviter. A nil actor, or one who is not a member of the organization, is only recorded for callbacks, as before.
  - Not re-checked: `add_member!` and `approve_join_request!` take no actor. `Invitation#accept!` trusts the role the invitation was sent with. Direct `Membership` writes bypass every rule. Authorize those yourself.
  - The owner keeps every power it had. Owner changes still go through `transfer_ownership_to!`.
  - A refusal raises `Organizations::NotAuthorized` with a localized message (en and es). There is one message per action, and one for a role with permissions the actor lacks.
- `remove_member!` read the member's role before taking the lock. A member promoted to admin, or made owner, in that window could still be removed, and the owner case left the organization with no owner. The role is now read again under a row lock.
- The engine controllers answer a refused role, an attempt to change your own role, and a refused removal like a failed permission guard. They go through `config.unauthorized_handler` when one is set, with the reason in `context.metadata[:message]`. Otherwise they show the alert, or return a 403 over JSON. Before, an attempt to change your own role was an error page. Removing yourself or the owner now also returns 403 instead of 422.
- `InvitationsController#create` answered an `owner` invitation with an error page, because `CannotInviteAsOwner` was not rescued. It now re-renders the form with the alert and a 422.
- `current_membership` in controllers returned nil for the rest of a request that switched organization. `current_organization=`, and the fallback when the organization in the session is gone, assigned nil to the memoized membership. `current_membership` treated that nil as the answer. Host forms that read it on the first request of a session, such as an invitation form, rendered empty. The memoized value is now removed instead, so the next read finds the membership again.
- `current_organization` and `current_membership` memoized nil when they were read before a user was resolved. They now memoize nothing until there is a user.
- The generated views (`rails g organizations:views`) and the dummy reference views offered every role but owner in their role pickers, whatever the viewer's own role. The pickers now list only roles the viewer can assign. The members page shows the role picker only with `edit_member_roles` and the remove button only with `remove_members`. Members and invitations the viewer may not act on show no actions.

### Changed

- A custom role without `inherits:` sits below viewer. With the new rule, such a role with `invite_members` can invite only to its own role, so an invitation with the default `member` role now raises `NotAuthorized`. Give the role the parent it should invite to, for example `role :recruiter, inherits: :member do can :invite_members end`.
- `InvitationsController#resend` now calls `resend!(resent_by: current_user)`. A host that overrides `Invitation#resend!` without keyword arguments gets an `ArgumentError` from the controller. Accept `resent_by:` in the override.
- `InvitationsController#destroy` now calls `Invitation#revoke!` instead of `destroy!`.

### Added

- `Roles.can_assign?(actor_role, role)` and `Membership#can_assign_role?(role)` tell whether an actor may act on a role, for example to filter a role picker. `Roles.assignment_refusal(actor_role, role)` says why not (`:outranks` or `:lacks_permissions`).
- `Membership#authorize_role_change!(new_role, changed_by:)` raises `NotAuthorized` when the actor may not make that change.
- `Invitation#revoke!(revoked_by: nil)` deletes an invitation after the check. `Invitation#resend!` takes an optional `resent_by:`.

## [0.6.0] - 2026-10-18

**Custom role names.** Register a role outside owner > admin > member > viewer (a `client`, an `auditor`, a `guest`) in the existing `config.roles` block. No migration is needed. Installs without custom roles change nothing.

### Added

- **Custom roles.** `role :client, inherits: :viewer do can :answer_questions end` in `config.roles` adds a role with its own permissions plus its parent's. A custom role sits directly above its parent in `Roles.hierarchy`. A custom role without `inherits:` sits at the bottom. Two custom roles with the same parent stack in the order you define them.
- Custom roles work in `add_member!`, memberships, invitations, `default_invitation_role`, promotions, demotions, `at_least?`, `by_role_hierarchy` and every permission helper. The generated views and the dummy reference views list them in the role pickers.
- **Safety rules, checked when the configuration loads.** A custom role inherits from `member`, `viewer` or another custom role, never from `admin` or `owner`, so it ranks below admin. A custom role cannot grant a permission that the owner role has and the admin role lacks (`manage_billing`, `transfer_ownership`, `delete_organization` by default), because admins can assign it. A built-in role cannot inherit a custom role that ranks above it. A role name is lowercase letters, digits and underscores, and a parent must be defined above its child.
- `Roles.hierarchy_for(definition)` returns the hierarchy of a roles definition.

### Changed

- `RoleBuilder` keeps roles outside the four built-in ones as custom roles. Before, it dropped them without an error. A `config.roles` block with such a role now registers it, or raises `ConfigurationError` when the role breaks a safety rule.
- A block that only adds custom roles keeps the default permissions of the built-in roles. A block that redefines a built-in role defines only the built-in roles it lists, as before. An empty block still defines no permissions.
- `Membership` and `Invitation` check the role against the configured roles only when the role is set or changed. A membership of a role that you remove from the configuration stays readable and updatable, and ranks below every configured role. Move such memberships with `org.change_role_of!(user, to: :member)`. A pending invitation for a removed role cannot be accepted.
- `by_role_hierarchy` follows the configured hierarchy, custom roles included, with unknown roles last.
- The hierarchy and the permissions are one immutable snapshot for each roles definition, and each comparison reads one snapshot. A reconfiguration, or a rolled-back one, can no longer leave a stale hierarchy in place.

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

**Pre-release hardening wave** (added before the public 0.5.0 cut, driven by the first two production integrations):

- **`on_member_joining` — THE membership gate**: a strict, vetoing, pre-persist callback dispatched inside the creating transaction on EVERY join path (`add_member!`, invitation acceptance, join-request approval — which covers codes, domains, allowlists, and the account-email shortcut). Raise `Organizations::MembershipVetoed` (localized default message) to veto; rollback is clean (requests stay pending, invitations stay unaccepted). This is where plan seat limits and member caps belong — the previous "enforce caps before calling approve/redeem in host code" guidance is superseded. Deliberately does NOT fire for owner-at-org-creation, idempotent already-a-member paths, or role changes.
- **`Organizations::JoinFlow`** — the controller-facing facade: `JoinFlow.attempt(user:, organization:, code:, email:, verification_code:, message:)` returns a `Result` (`outcome` ∈ member/challenge_sent/pending/vetoed/error; stable `reason` symbols from `JoinFlow::REASONS`; localized `message`) instead of raising — no more hand-written rescue ladders in host controllers. Foreign/unknown/revoked/expired codes collapse into one reason (no enumeration oracle) and a foreign code is never consumed.
- **`Organizations::JoinState`** — the headless join-screen state machine: `:member`/`:verifying`/`:pending`/`:entry`, `resend_seconds` (derived from config — stop mirroring the throttle as a magic number), `error_message`. Plus granular capability predicates `Organization#accepts_domain_joining?`/`#accepts_code_joining?` and the `JoinCode.active` scope. `accepts_join_requests?` refined: codes count only while actually redeemable.
- **i18n layer** — every user-facing string (errors, validation messages, role/status labels, invitation-flow notices, stock mailer copy) resolves through `config/locales/en.yml` (catalog SSOT) with a full **Spanish (`es`) locale shipped**. Hosts override any key in their own locale files. Developer-facing errors stay English on purpose.
- **`config.user_class`** — hosts whose account model isn't `User` (e.g. `Account`) are now supported; every gem association resolves through it. `TestHelpers#create_user` follows it.
- **Extension load hooks** — `ActiveSupport.on_load(:organizations_organization) { include MyExtensions }` (one hook per model + `:organizations_application_controller`/`:organizations_public_controller`), reload-safe under Zeitwerk; supersedes the initializer `class_eval` recipe (which evaporated on the first dev reload) and hand-rolled `to_prepare` blocks. `config.public_controller_helpers = ["ApplicationHelper"]` declares host helper modules for the public engine controller (it inherits `ActionController::Base`, so host layouts otherwise miss app helpers).
- **`config.engine_routes`** — devise_for-style `only:`/`except:` over engine route groups (`:switching`, `:organizations`, `:memberships`, `:invitations`, `:public_invitations`), replacing order-load-bearing shadow-route hacks in hosts that don't want the full engine UI.
- **`Organizations::OrganizationScoped`** — the URL-scoped addressing mode for overlay-style hosts (`/org/:slug/admin`): configurable `organization_param`/`organization_finder`, `current_scoped_organization`/`current_scoped_membership`, `require_organization_role :admin`, and a configurable not-found posture (default 404-never-403: unknown orgs, strangers, and under-role members are indistinguishable).
- **Verification delivery-failure handling** — if the code email fails to enqueue, the gem rolls the throttle bookkeeping back (immediate retry allowed; the failed send doesn't count against `max_sends`) and fires the new `on_verification_delivery_failed` callback so host error trackers see mail outages instead of users silently stranding.
- **DX bundle** — `Organization.create_with_owner!(owner:, **attrs)` (the ops/provisioning primitive: no session switching, no per-user cap, fires `organization_created`); `JoinRequest.purge_stale!(older_than:)` (GDPR sweep: decided/expired requests hold verification emails with no purpose; approved ones are kept as the join audit trail); `metadata_flag` macro on Organization/Membership (typed boolean accessors with defaults over the metadata bag); user-level errors get canonical top-level homes (`Organizations::CannotLeaveAsLastOwner` — nested paths remain as aliases); `Invitation#acceptance_url` is engine-mount-aware (previously 404'd for non-root mounts); known-user promotion is the default invitation auth redirect (sign-in for existing accounts, sign-up otherwise).
- **`rails g organizations:views`** — copies the Tailwind reference views (organizations/memberships/invitations) into the host, devise-views style; templates are drift-guarded byte-identical to the `test/dummy` reference app. The dummy now also carries a **verified-joining reference implementation** (four-state join screen + Access admin surface) to copy, and boots as a living 0.5.0 demo.
- **`TestHelpers#issue_verification_code(join_request, code: "424242")`** — force a known plaintext code onto a challenge in tests; host suites were reverse-engineering the digest recipe by hand.
- **PostgreSQL correctness for every rescued unique-violation** — all six rescue-RecordNotUnique INSERT sites now run under their own SAVEPOINT (transaction(requires_new: true)): PG aborts the whole transaction on a statement error, so the graceful fallbacks (idempotent membership reuse, degraded verified-email stamp, duplicate-allowlist skip) previously EXPLODED with PG::InFailedSqlTransaction instead of degrading — SQLite forgave the pattern, which is how it stayed green. Proven + guarded by a new ORGS_TEST_DATABASE_URL suite leg and a PostgreSQL CI cell. metadata_flag toggles are now with_lock-serialized; add_member! re-checks membership inside the transaction so a racing duplicate join is resolved idempotently without firing the gate (and without re-dispatching member_joined).

### Changed

- `Organizations.configure` is now **atomic**: if the block (or the `validate!` it triggers) raises, the previous configuration is restored instead of leaving half-applied settings behind — a raising initializer no longer poisons later `configure` calls. Restoration is a shallow snapshot: use setters in configure blocks (`config.x = [...]`), never in-place mutation (`config.x << ...`).
- `organization_role_label`/`organization_invitation_status_label` and the default unauthorized messages resolve through I18n (English output unchanged; the unauthorized-role message now uses the translated label, e.g. "You need Admin access…").
- The two near-duplicate cannot-promote-to-owner messages were unified into one catalog key.
- Stock mailers self-register their view path and guard `Rails.application` access properly, so they render outside a full Rails app (found by the first tests to ever render them).

### Notes

- BYO-UI as always: the gem ships models/APIs/mailers and state (`JoinFlow`/`JoinState`); routes, controllers and pixels for joining are the host's. Copy the reference implementation from `test/dummy` and **rate-limit your join/redemption/verification endpoints** (see README "Rate limiting your join endpoints").
- Join-code nuance under the gate: uses are counted at redemption, so a vetoed redemption still consumes a use — `max_uses` is an anti-abuse cap, not a seat count.

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
