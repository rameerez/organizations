## [Unreleased]

## [0.8.1] - 2026-10-25

**The joins take the lock order of the destroys.** A patch release with one fix. No migration is needed.

### Fixed

- **A join could deadlock with a deletion on PostgreSQL.** 0.8.0 made every destroy lock the user row, then the organization rows, then their child rows. Several joins locked their own row first, and the organization row (or a user row) only later, when they wrote. So a join and a deletion could each hold a row that the other waited for. PostgreSQL then aborted one of them with `ActiveRecord::Deadlocked`. These paths now take a guard on the user rows that their writes name (in id order), then lock the organization row, then their own row:
  - `Invitation#accept!` (the accepting user and the inviter). Before, an acceptance deadlocked with the inviter's account deletion or with a destroy of the organization.
  - `Invitation#revoke!` (no user row). Before, the revoke of an invitation with grants deadlocked with a destroy of its organization or with the inviter's account deletion.
  - `JoinRequest#approve!` and the automatic approval after a verified email (the requester and the decider). Before, an approval deadlocked with the requester's account deletion.
  - `JoinRequest#verify_email_code!` (the requester). Before, the check of an emailed code deadlocked with a destroy of the organization, which deletes the domain before the request. The requester's guard comes first, so the automatic approval inside a host transaction asks for no user row while it holds the organization row.
  - `JoinCode#redeem!` (the redeeming user). Before, a redemption deadlocked with the account deletion of the code's creator or with a destroy of the organization.
- **The user guard is a key share lock** (`FOR KEY SHARE` on PostgreSQL, a shared lock on MySQL, nothing on SQLite). It conflicts with the deletion's `FOR UPDATE`, and with nothing else: an update of the user and the foreign key checks of other writers pass. So `reject!` (which names its decider), `withdraw!`, `resend!` and a grant on a pending invitation (which names its granter) keep their single row lock and do not wait for the guards.
- **An acceptance from a stale copy locks the current inviter.** A reissue of an expired invitation (`send_invite_to!`) names the new inviter. A loaded copy can still name the old one. The acceptance reads the row again under its lock. When the row names other ids than the ones locked, the acceptance releases its locks (a savepoint) and tries again with the current ids, up to three times. Then it raises `Invitation::InvitationChanged`, an `InvitationError`. `accept_pending_organization_invitation!` returns it as the failure `:invitation_changed` and keeps the session token. The engine's accept action answers with the localized message: HTML goes back to the invitation page, JSON gets a 409. Before, the acceptance could insert a membership that named an unlocked inviter, and deadlock with an ownership transfer to that inviter.
- Inside a host transaction, the order holds only when the locks that the host took earlier in that transaction keep it too.
- README: "Row-level locking" states the one lock order. The steps of the ownership transfer now start with the new owner's row, as the code has done since 0.7.0.

## [0.8.0] - 2026-10-24

**Hand a personal organization over, and keep organizations that hold records with a retention period.** An invoicing app on the fleet built both by hand and runs them in production. This release moves them into the gem, with their tests. Both are opt-in, and no migration is needed.

### Added

- **Hand a personal organization over.** The need: the owner confirms that a member takes over their personal workspace, which then becomes shared, and a refused handover must leave nothing half done. `org.transfer_ownership_to!(admin, convert_to_shared: true)` makes a personal organization shared and transfers it in one step, in its own savepoint. A refused transfer leaves it personal, also when the caller rescues the error inside its own transaction, and the record in memory is read again. The transfer locks the new owner's row before the organization row, as the deletion guard does. A transfer to the personal owner itself is still refused. `config.convert_personal_organizations_on_transfer = true` makes the conversion the default, also for the engine's transfer action. The default (`false`) keeps the refusal of 0.7.0.
- **Keep organizations that hold records with a retention period.** The need: an organization that holds records the law makes you keep, such as issued invoices or the books, must never be destroyed when its owner deletes their account. `config.retain_organization = ->(organization) { ... }` (default `nil`) names those organizations. `user.account_deletion_plan.organizations_to_retain` lists them apart from `organizations_to_destroy`. They do not block, so `allowed?` is unchanged. `user.destroy` returns false while the user owns one, with a message that names it, and the app closes the account instead. Any other destroy of a retained organization raises `Organizations::Organization::CannotDestroyRetainedOrganization` before any row goes. The destroy reads the organization again under its row lock, and the rule gets that copy, so a stale record cannot destroy it. Whatever creates the retained records must lock the organization row, or insert them with a foreign key that restricts deletion. The engine's controllers answer the error with a redirect back and the message (HTML), or a 422 (JSON).

### Changed

- `AccountDeletionPlan#to_h` has an `organizations_to_retain` key. It is an empty list when nothing is retained.
- `user.destroy` takes its locks before its first write. It locks the user row, then the row of every organization in which it writes, in id order: its memberships, the invitations it sent and their grants, the memberships it invited, its join requests, the requests it decided, its join codes, the allowlist entries it claimed, the domains it verified and the grants it gave. Before, it locked only the owned organizations, after it deleted the grants of its sent invitations. **The callback order changes:** a new first `before_destroy` callback, `lock_rows_for_deletion`, takes the locks. It runs before `drop_grants_of_sent_invitations` and the guard, which keep their order and their names.
- Every organization destroy locks its row before its `dependent: :destroy` cascades, with or without `retain_organization`. With the account deletion above, both paths take the organization row first. Before, a member's account deletion and a destroy of their organization could deadlock on PostgreSQL.
- The account-deletion guard reads its plan with the query cache off. Before, a plan built earlier in the same request (a confirmation screen's preview) could answer from the cache, and miss a member that another connection had added.

### Upgrading

No migration is needed, and nothing changes until you set one of the two options. An app that prepends its own `transfer_ownership_to!` to convert personal organizations can remove it and set `config.convert_personal_organizations_on_transfer = true`. An app that refuses the destroy of such organizations in its own `before_destroy` can remove it and set `config.retain_organization`.

## [0.7.1] - 2026-10-19

**A user whose invitation was accepted can now be deleted.** A patch release with one fix and one README correction. No migration is needed.

### Fixed

- **A user whose invitation was accepted could not be deleted.** Accepting an invitation copies the inviter into `organizations_memberships.invited_by_id`, whose foreign key has no `ON DELETE` rule, and nothing cleared it. `user.destroy` raised `ActiveRecord::InvalidForeignKey` and rolled back, whatever `account_deletion_policy` said. `has_organizations` now declares `invited_organization_memberships` with `dependent: :nullify`, as it does for sent invitations. No migration is needed. A deletion path that skips callbacks (`delete`, raw SQL) still meets the foreign key: give it `ON DELETE SET NULL` in your own migration if you have one.
- README: the scoped resource grants example redefined only `viewer` and `member` in `config.roles`. A block that redefines a built-in role defines only the built-in roles it lists, so `admin` and `owner` were left with no permissions. The example now lists all four roles.

## [0.7.0] - 2026-10-18

**Personal organizations, safe account deletion, domain authority, join screens, vocabularies and scoped resource grants.** This release closes issue #21. Every new feature is opt-in: an existing app that upgrades and runs `rails g organizations:upgrade` keeps its behaviour, apart from the changes listed under "Changed".

### Added

- **Personal organizations** (issue #21). `config.record_personal_organizations = true` records the auto-created organization as the user's personal organization. New API: `user.personal_organization` (a lookup, never creates), `user.create_personal_organization!` (idempotent, the repair path after a failed sign-up provisioning, converges under concurrency), `org.personal?`, `org.personal_owner`, `org.convert_to_shared!`, and the scopes `Organization.personal` and `Organization.not_personal`. The link is `organizations_organizations.personal_owner_id`: unique per user, `ON DELETE SET NULL`.
- `Organizations::Organization.backfill_personal_owners!(mapping, dry_run:)` links reviewed users to existing organizations. It never guesses. It reports conflicts (`:organization_not_found`, `:not_the_owner`, `:organization_personal_for_another_user`, `:user_has_another_personal_organization`, `:organization_mapped_twice`, `:user_mapped_twice`) and writes nothing when any pair conflicts. It writes in its own savepoint, also inside a host transaction.
- **Safe account deletion.** `user.account_deletion_plan` lists what `user.destroy` would do, with each blocking organization and its reason, and changes nothing. `config.account_deletion_policy = :destroy_personal_organization` deletes the user's personal organization with the account when the user is its only member. Any other owned organization still blocks. The check covers the complete owned set first, and one transaction holds the organization and the user deletion, so a veto or a failure rolls back everything.
- **Domain authority** (issue #21). Proof that an organization controls a domain, separate from proof of one inbox. `domain.start_verification!` issues a token bound to one claim (one organization, one exact domain); `domain.verify!` checks the DNS TXT record (`verification_record_name`, `verification_record_value`) and raises `Organizations::DomainVerificationFailed` with a `reason` (`:not_started`, `:expired`, `:changed`, `:record_not_found`, `:lookup_failed`). `domain.verify_by_operator!(operator:, note:)` records a platform operator's approval; a member of the organization cannot approve its own claim. `revoke_verification!`, `recheck_verification!`, `verified?`, `revoked?`, and the scopes `Domain.verified`, `Domain.joinable` and `Domain.with_join_policy`.
- `config.require_verified_domains` (default `false`): admit through a domain only when it is verified. It covers the emailed challenge, the account-email shortcut, domain-restricted codes and `JoinFlow`.
- `config.blocked_email_domains` with the opt-in preset `Organizations::PUBLIC_EMAIL_DOMAINS`: a blocked domain cannot be enrolled and no longer admits. Invitations and allowlists are not affected.
- **Sign-up domain policies.** `domain.join_policy` is `"none"` (default), `"suggest"` or `"auto_join"`, and acts only while the domain is verified and the account email is confirmed. `user.suggested_organizations` lists the organizations to offer. `user.join_organizations_by_domain!` joins the auto-join ones through the membership gate; it runs on its own after sign-up and after the email confirmation. `org.add_domain!` takes `join_policy:`.
- Configuration: `domain_verification_record_prefix`, `domain_verification_ttl`, `domain_verification_timeout`, `domain_txt_resolver`.
- **`rails g organizations:join`** (issue #21). It copies a host-owned join screen (`OrganizationJoinsController`: code, work email, 6-digit code, request, withdraw) and an access screen (`OrganizationAccessController`: request queue, domains with DNS verification and the sign-up policy, join codes, allowlist import and removal), and adds their routes under `/orgs/:organization_id`. `--skip-access` and `--skip-routes` narrow it, and a second run adds only the routes that are missing. The generated code requires a signed-in user (through `config.current_user_method`), changes data only with POST and DELETE, redirects with 303 after a successful POST (Turbo), cuts inputs to fixed lengths, never joins on a GET (a `?code=` link only fills in the form), keeps the generic invalid-code message, rate-limits (Rails 7.2+), scopes every admin lookup to the URL's organization, and shows a disclosure before any submit. The engine adds no route, so existing apps change nothing.
- `OrganizationScoped.require_organization_permission(permission, **options)` gates actions by a permission of the viewer's role, with the same 404 posture as `require_organization_role`.
- README: a recipe for URL handles (slugs) with `OrganizationScoped` (issue #21).
- **Vocabulary** (issue #21). `config.vocabulary` selects organization-specific wording: a Symbol for the whole app, or a callable that receives the organization. `Organizations.t(key, organization: record)` uses `organizations.vocabularies.<name>.<key>` when that key exists (in the locale or its I18n fallbacks); otherwise the call is exactly the ordinary one, defaults and options included. `%{organization}` interpolates the record's name. `Organizations.i18n_keys(key, organization:)` gives the chain for the Rails `t` helper (`_html` keys). `organization_role_label` and `organization_role_info` take `organization:`. The gem's models (organization, membership, invitation, join request and domain messages), mailers and controller notices pass the organization they act on; the join-code errors stay generic on purpose. The default (`nil`) changes nothing.
- **Scoped resource grants** (optional). A membership can be limited to some records of the host app, with a capability list per record: `membership.grant!(record, capabilities:, granted_by:)`, `revoke_grant!`, `grant_for`, `granted?`, `can?(capability, record)`, `capabilities_for`, `limited_by_grants?`, `visible(relation, capability:)` and `granted_ids(type, capability:)`. Members whose role ranks below `config.full_resource_access_role` (`:admin`) see only granted records; the role's permissions stay the ceiling, so a grant narrows and never widens. `include Organizations::Grantable` adds `Model.visible_to(membership, capability:)` and `record.organization_grants`. `Organizations::Resource.new(type, id)` grants records that are not ActiveRecord models. Invitations carry grants (`send_invite_to!(..., grants: { record => caps })`, `invitation.grant!`), which move to the membership on acceptance. `Membership.with_grant_on(record)`, `Organization#grants` and `Grant.for_resource` answer "who has access". Granting checks `config.grant_management_permission` (`:edit_member_roles`), the rank rule, and, for a limited granter, its own access; an actor that is not a member is refused. Records of a model with `organization_id` stay inside their organization for `can?`, `visible_to` and `grant!`. Invitation grants are checked again at acceptance. `config.grant_capabilities` lists the allowed names. `rails g organizations:grants` adds the table; nothing changes until you run it.
- `rails g organizations:upgrade` now adds only the migrations an install lacks: the 0.5.0 verified-joining migration and the two 0.7.0 migrations (personal organizations, domain verification). It asks the database when it can and reads `db/migrate` otherwise. `--steps NAME…` generates exactly the named steps, for squashed histories. Before, it always generated the 0.5.0 migration, which broke installs made on 0.5.0 or later.

### Changed

- `transfer_ownership_to!` raises `Organization::CannotTransferPersonalOrganization` for a personal organization. Call `convert_to_shared!` first. Organizations that are not personal are not affected.
- `User#destroy` (from `has_organizations`, prepended so a host override cannot drop it) runs in its own savepoint, so an aborted destroy inside a host transaction rolls back what the deletion guard did.
- `transfer_ownership_to!` locks the new owner's user row before the organization row (the same order as the deletion guard, so the two cannot deadlock), so a transfer cannot race the deletion of that user. `create_with_owner!` and `create_organization!` raise `ArgumentError` for a `personal_owner` who is not the new owner.
- The account-deletion guard now locks the user row and the owned organization rows before it checks ownership. A concurrent organization creation for the user can no longer slip past the check and lose its owner membership. The default policy (`:prevent`) and its error message are unchanged, and the guard keeps its method name (`prevent_deletion_while_owning_organizations`), so a host `skip_callback` for it still works.
- A domain-backed admission checks its domain (or allowlist entry) again: `verify_email_code!` refuses with `VerificationEmailNotEligible` when the matched domain was removed, revoked or blocked, or the roster entry was removed, while the code was in flight. The request stays pending, and an admin can still approve it by hand. `JoinFlow` reports this as `:email_not_eligible`. Before, the code still granted membership.
- A revoked domain never admits, whatever `require_verified_domains` says. The admission locks the matched domain or roster row, so a concurrent revocation or removal either finishes first or waits.
- `Organizations.t` treats an `organization:` that is an `Organizations::Organization` record as the vocabulary selector, and interpolates its name. A String keeps working as before.
- `handle_unauthorized` takes `organization:` (default: the current organization) for the message's vocabulary and for `NotAuthorized#organization`. The organization CRUD controller passes the organization it checked, so the error now names that organization.
- The views of `rails g organizations:views` print role labels through `organization_role_label(role, organization:)` instead of `role.capitalize`. A custom role such as `team_lead` now reads "Team lead", the same as the gem's other labels. Views you copied earlier are not changed.
- The dummy app's reference join and access controllers are now `OrganizationJoinsController` and `OrganizationAccessController`, with `organization_*` route names. They are the generator's templates.
- Engine controllers answer validation failures with status 422 instead of the `:unprocessable_entity` symbol, which Rack 3.2 (Rails 8.1) deprecates. The status code is the same.
- `organization_members_data`, `organization_invitations_data` and `organization_role_info` pass the organization to the role labels (vocabulary). A host override of `organization_role_label` that takes only the role keeps working.

### Development

- RuboCop runs in CI, and the 8 open offenses are fixed (`rubocop:disable-next`, RuboCop 1.92+).
- SimpleCov uses its 1.x API (`skip`, `cover`, `SimpleCov.start` in the test helper) with no deprecation output, and still works with 0.22 on Ruby 3.2. CI enforces a coverage floor for the full suite.
- The Appraisal gemfiles are regenerated from the Gemfile.
- New coverage for the permission helpers and the hierarchy with custom roles (`test/custom_role_helpers_test.rb`).
- README: the public API of the models, the helpers, `Roles` and `JoinState` is documented, with the authorization limits of `authorize_role_change!`, the join request decisions and `grant.allows?`; every configuration option is in the configuration block; the "Future API" example for bulk invitations, which does not exist, is gone.
- The CI step that uploaded a test report directory that nothing writes is gone.

### Upgrading

1. Coming from 0.6.0: read the 0.6.1 notes below first (audit pending invitations and recent role changes; `resend!` overrides must accept `resent_by:`).
2. Run `rails g organizations:upgrade`. It generates the migrations for `organizations_organizations.personal_owner_id` and the domain verification columns, and nothing else. If your user model is not `User`, change `to_table: :users` in them. Then run `rails db:migrate`.
3. Existing organizations stay unclassified. To link reviewed personal organizations: `Organizations::Organization.backfill_personal_owners!({ user_id => organization_id }, dry_run: true)`, then the same call without `dry_run`.
4. Existing domains start unverified with the `"none"` policy. Verify them before you turn on `require_verified_domains`.
5. Optional features need their own step:
   - scoped resource grants: `rails g organizations:grants`, check the type of `grantable_id` (and `to_table: :users`), `rails db:migrate`, then `include Organizations::Grantable` in the models you grant;
   - join and access screens: `rails g organizations:join`.
6. Check the behaviour changes under "Changed": `transfer_ownership_to!` on a personal organization, the re-check of domain-backed admissions, and `NotAuthorized#organization` from the organization CRUD controller.

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
