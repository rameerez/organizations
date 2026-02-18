# 🏢 `organizations` – Add organizations with members to your Rails SaaS

[![Gem Version](https://badge.fury.io/rb/organizations.svg)](https://badge.fury.io/rb/organizations) [![Build Status](https://github.com/rameerez/organizations/workflows/Tests/badge.svg)](https://github.com/rameerez/organizations/actions)

> [!TIP]
> **🚀 Ship your next Rails app 10x faster!** I've built **[RailsFast](https://railsfast.com/?ref=organizations)**, a production-ready Rails boilerplate template that comes with everything you need to launch a software business in days, not weeks. Go [check it out](https://railsfast.com/?ref=organizations)!

`organizations` adds organizations with members to any Rails app. It handles team invites, user memberships, roles, and permissions.

[TODO: invitation / member management gif]

It's everything you need to turn a `User`-based app into a multi-tenant, `Organization`-based B2B SaaS (users belong in organizations, and organizations share resources and billing, etc.)

It's super easy:

```ruby
class User < ApplicationRecord
  has_organizations
end
```

That's it. Your users can now create organizations, invite teammates, and jump between accounts:

```ruby
current_user.create_organization!("Acme Corp")
current_user.send_organization_invite_to!("teammate@acme.com")
```

Then you could switch to the new org like this:

```ruby
switch_to_organization!(@org)
```

And check your roles / permissions in relation to that organization like this:

```ruby
current_user.is_organization_owner?     # => true
current_user.is_organization_admin?     # => true (owners inherit admin permissions)
```

> [!NOTE]
> This gem uses the term "organization", but the concept is the same as "team", "workspace", or "account". It's essentially just an umbrella under which users / members are organized. This gem works for all those use cases, in the same way. Just use whichever term fits your product best in your UI.

## Installation

Add to your Gemfile:

```ruby
gem "organizations"
```

> [!NOTE]
> The `organizations` gem depends on [`slugifiable`](https://github.com/rameerez/slugifiable) for URL-friendly organization slugs (auto-included). For beautiful invitation emails, optionally add [`goodmail`](https://github.com/rameerez/goodmail).

Then:

```bash
bundle install
rails g organizations:install
rails db:migrate
```

Add `has_organizations` to your User model:

```ruby
class User < ApplicationRecord
  has_organizations
end
```

That's the simplest setup. You can also configure per-model options:

```ruby
class User < ApplicationRecord
  has_organizations do
    max_organizations 5         # Limit how many orgs a user can own (nil = unlimited)
    create_personal_org true    # Auto-create org on signup (default: true)
    require_organization false  # Allow users to exist without any org (default: true)
  end
end
```

> **Note:** Set `require_organization false` for onboarding flows where users sign up first, then create/join an organization later.

Mount the engine in your routes:

```ruby
# config/routes.rb
mount Organizations::Engine => '/'
```

Done. Your app now has full organizations / teams support.

## Quick start

### Create an organization

```ruby
org = current_user.create_organization!("Acme Corp")
# User automatically becomes the owner
```

### Invite teammates

```ruby
current_user.send_organization_invite_to!("teammate@example.com")
# Sends invitation email: "John invited you to join Acme Corp"
# When accepted, user joins as :member (default role)
```

The invitation goes from user to user. The organization is inferred from `current_organization`. You can also be explicit:

```ruby
current_user.send_organization_invite_to!("teammate@example.com", organization: other_org)
```

### Check roles and permissions

```ruby
# Quick role checks (in current organization)
current_user.is_organization_owner?   # => true/false
current_user.is_organization_admin?   # => true/false

# Permission checks
current_user.has_organization_permission_to?(:invite_members)
# "Does current user have organization permission to invite members?"

# Check role in a specific org
current_user.is_admin_of?(@org)
# "Is current user an admin of this org?"

current_user.is_member_of?(@org)
# "Is current user a member of this org?"
```

### Switch between organizations

```ruby
# User belongs to multiple organizations? No problem.
current_user.organizations        # => [acme, startup_co, personal]
switch_to_organization!(startup_co)  # Changes active org in session
```

### Protect controllers

```ruby
class ProjectsController < ApplicationController
  before_action :require_organization!
  before_action :require_organization_admin!, only: [:create, :destroy]
end
```

## Why this gem exists

Organizations / teams are tough to do alone. Wiring up accounts, roles, and invites by hand is a pain you only want to go through once. If you don't implement organizations / teams on day one, adding them later becomes a major refactor — the kind that touches every model, controller, and permission in your app. Even experienced Rails developers have built accounts / teams poorly multiple times before getting it right.

No more asking yourself "should I just roll my own?" No more stitching together `acts_as_tenant` + `rolify` + `devise_invitable` + `pundit` and writing 500 lines of glue code. No more paying $250/year for a boilerplate template just because it has organizations / teams built in. The `organizations` gem gives you everything in a single `bundle add`.

Every B2B Rails app eventually needs organizations / teams. Yet there's no standalone gem that allows you to just flip a switch and add organizations to your app.

| What you need | What exists today |
|---------------|-------------------|
| Organization model | ✅ Easy, just scaffold it |
| Membership (User ↔ Organization join table) | ❌ Write it yourself |
| Invite users to a *specific* organization | ❌ `devise_invitable` invites to the *app*, not to an org |
| Roles scoped to each organization | ❌ `rolify` stores roles globally, not per-org |
| Let users jump between organizations | ❌ Write it yourself |
| **All of the above, integrated** | ❌ **Pay $250+ for a boilerplate** |

The day will come when you need to associate your users in organizations — and it will be the refactor from your worst nightmares. Rails does not make your life easy when you want to work this way, with multiple tenants. The typical Rails developer stitches together `acts_as_tenant` + `rolify` + `devise_invitable` + `pundit` and writes 500-1,000 lines of glue code that feels brittle compared to the usual simplicity of Rails. That takes 1-2 months. Some developers have estimated 200+ hours of work. Or you pay $250+/year for a boilerplate template where organizations / teams is the headline feature.

Laravel has Jetstream with a `--teams` flag. Django has `django-organizations`. Rails has had nothing — until now.

| Framework | Organizations / Teams Solution | Cost |
|-----------|-------------------------------|------|
| Laravel | Jetstream `--teams` | Free |
| Django | django-organizations | Free |
| Rails | `organizations` gem | Free |

`organizations` gives you the complete `User → Membership → Organization` pattern with scoped invitations, hierarchical roles, and the ability to switch between organizations – all in a single, well-tested gem that works with your existing Devise setup. What previously took 1.5 months now takes 3 days.

> ![NOTE]
> This gem handles organization membership and org-level permissions (who can invite members, who can manage billing). For per-record authorization ("can user X edit document Y"), use [Pundit](https://github.com/varvet/pundit) or [CanCanCan](https://github.com/CanCanCommunity/cancancan) alongside this gem.

## The complete API

### User methods

When you add `has_organizations` to your User model, you get:

```ruby
# Associations
user.organizations                      # All organizations user belongs to
user.memberships                        # All memberships (with roles)
user.owned_organizations                # Organizations where user is owner
user.pending_organization_invitations   # Invitations waiting to be accepted

# Current organization context
user.organization                       # Alias for current_organization (most common use)
user.current_organization               # Active org for this session
user.current_membership                 # Membership in active org
user.current_organization_role          # Role in current org => :admin

# Quick boolean checks
user.belongs_to_any_organization?           # "Does user belong to any org?"
user.has_pending_organization_invitations?  # "Does user have pending invites?"

# Permission checks (in current organization)
user.has_organization_permission_to?(:invite_members)   # => true/false
user.has_organization_role?(:admin)                     # => true/false

# Role shortcuts (in current organization)
user.is_organization_owner?             # Same as has_organization_role?(:owner)
user.is_organization_admin?             # Same as has_organization_role?(:admin)
user.is_organization_member?            # Same as has_organization_role?(:member)
user.is_organization_viewer?            # Same as has_organization_role?(:viewer)

# Role checks (explicit organization)
user.is_owner_of?(org)                  # "Is user an owner of this org?"
user.is_admin_of?(org)                  # "Is user an admin of this org?"
user.is_member_of?(org)                 # "Is user a member of this org?"
user.is_viewer_of?(org)                 # "Is user a viewer of this org?"
user.is_at_least?(:admin, in: org)      # "Is user at least an admin in this org?"
user.role_in(org)                       # => :admin

# Actions
user.create_organization!("Acme")            # Positional arg
user.create_organization!(name: "Acme")      # Keyword arg (both work)
user.leave_organization!(org)
user.leave_current_organization!             # Leave the active org
user.send_organization_invite_to!(email)                     # Invite to current org
user.send_organization_invite_to!(email, organization: org)  # Invite to specific org
```

### Organization methods

```ruby
# Associations
org.memberships                 # All memberships
org.members                     # All users (alias for org.users)
org.users                       # All users (through memberships)
org.invitations                 # All invitations (pending + accepted)
org.pending_invitations         # Invitations not yet accepted

# Queries
org.owner                       # User who owns this org
org.admins                      # Users with admin role or higher
org.has_member?(user)           # "Does org have this user as a member?"
org.has_any_members?            # "Does org have any members?"
org.member_count                # Number of members

# Class methods / Scopes
Organization.with_member(user)  # Find all orgs where user is a member

# Actions
org.add_member!(user, role: :member)
org.remove_member!(user)
org.change_role_of!(user, to: :admin)
org.transfer_ownership_to!(other_user)

# Invitations
org.send_invite_to!(email)                  # Auto-infers invited_by from Current.user
org.send_invite_to!(email, invited_by: user) # Explicit inviter

# Scopes
org.memberships.owners          # Memberships with owner role
org.memberships.admins          # Memberships with admin role
org.invitations.pending         # Not yet accepted
org.invitations.expired         # Past expiration date
```

### Membership methods

```ruby
membership.role                 # => "admin"
membership.organization         # The organization
membership.user                 # The user
membership.invited_by           # User who invited them (if any)

# Permission checks
membership.has_permission_to?(:invite_members)   # => true/false
membership.permissions                           # => [:view_members, :invite_members, ...]

# Role hierarchy checks
membership.is_at_least?(:member)    # => true (if member, admin, or owner)

# Role changes
membership.promote_to!(:admin)      # Change role to admin
membership.demote_to!(:member)      # Change role to member
```

### Invitation methods

```ruby
invitation.email                # => "teammate@example.com"
invitation.organization         # The organization
invitation.role                 # Role they'll have when accepted
invitation.invited_by           # User who sent the invitation
invitation.from                 # Alias for invited_by
invitation.pending?             # => true (not yet accepted)
invitation.accepted?            # => true (has accepted_at)
invitation.expired?             # => true (past expires_at)

# Actions
invitation.accept!              # Accept (auto-infers Current.user)
invitation.accept!(user)        # Accept with explicit user
invitation.resend!              # Send invitation email again
```

## Controller helpers

Include the controller concern in your ApplicationController:

```ruby
class ApplicationController < ActionController::Base
  include Organizations::Controller
end
```

This gives you:

```ruby
# Context helpers
current_organization            # Active organization (from session)
current_membership              # Current user's membership in active org
organization_signed_in?         # Is there an active organization?

# Authorization
require_organization!                               # Redirect if no active org
require_organization_role!(:admin)                  # Require at least admin role
require_organization_permission_to!(:invite_members) # Require specific permission

# Authorization shortcuts (for common roles)
require_organization_owner!     # Same as require_organization_role!(:owner)
require_organization_admin!     # Same as require_organization_role!(:admin)

# Switching
switch_to_organization!(org)       # Change active org in session
```

### Protecting resources

```ruby
class SettingsController < ApplicationController
  before_action :require_organization!
  before_action :require_organization_admin!  # Shortcut for require_organization_role!(:admin)

  def billing
    require_organization_owner!  # Only owners can manage billing
  end
end
```

### Handling unauthorized access

Configure how unauthorized access is handled:

```ruby
# config/initializers/organizations.rb
Organizations.configure do |config|
  config.on_unauthorized do |context|
    # context.user, context.organization, context.permission, context.required_role
    redirect_to root_path, alert: "You don't have permission to do that."
  end

  config.on_no_organization do |context|
    redirect_to new_organization_path, alert: "Please create or join an organization first."
  end
end
```

## View helpers

Include in your ApplicationHelper:

```ruby
module ApplicationHelper
  include Organizations::ViewHelpers
end
```

### Permission checks in views

```ruby
<% if current_user.has_organization_permission_to?(:invite_members) %>
  <%= link_to "Invite teammate", new_invitation_path %>
<% end %>

<% if current_user.is_organization_admin? %>
  <%= link_to "Settings", organization_settings_path %>
<% end %>
```

### Organization switcher

Build your own switcher UI with the helper:

```ruby
<% data = organization_switcher_data %>

<div class="org-switcher">
  <button><%= data[:current][:name] %></button>
  <ul>
    <% data[:others].each do |org| %>
      <li>
        <%= link_to org[:name], data[:switch_path].call(org[:id]) %>
      </li>
    <% end %>
  </ul>
</div>
```

The helper returns:

```ruby
{
  current: { id: "...", name: "Acme Corp", slug: "acme-corp" },
  others: [
    { id: "...", name: "Personal", slug: "personal" },
    { id: "...", name: "StartupCo", slug: "startupco" }
  ],
  switch_path: ->(org_id) { "/organizations/switch/#{org_id}" }
}
```

### Invitation badge

```ruby
# Show pending invitation count in your navbar
<%= organization_invitation_badge(current_user) %>
# => <span class="badge">3</span> (if 3 pending invitations)
# => nil (if no pending invitations)
```

## Roles and permissions

### Organization permissions vs. resource authorization

`organizations` handles **org-level permissions** — what a user can do *within an organization*:

```ruby
current_user.has_organization_permission_to?(:invite_members)
# "Can they invite people to this org?"

current_user.has_organization_permission_to?(:manage_billing)
# "Can they manage this org's billing?"

require_organization_permission_to!(:manage_settings)
# Gate org settings pages
```

This is different from **resource authorization** (Pundit, CanCanCan) — what a user can do *to a specific record*:

```ruby
# Pundit/CanCanCan territory (not what this gem does)
policy(@document).update?      # "Can they edit THIS specific document?"
authorize! :destroy, @project  # "Can they delete THIS specific project?"
```

| | `organizations` gem | Pundit / CanCanCan |
|---|---------------------|-------------------|
| **Question** | "What can this user do in this org?" | "Can this user do X to record Y?" |
| **Scope** | Organization-wide capabilities | Per-record authorization |
| **Based on** | Role in Membership | Policy classes / Ability rules |
| **Example** | "Admins can invite members" | "Users can edit their own posts" |

**Most B2B apps need both.** Use `organizations` for org membership and capabilities. Use Pundit/CanCanCan for fine-grained resource authorization. They're complementary, not competing.

### Built-in roles

`organizations` ships with four hierarchical roles:

```
owner > admin > member > viewer
```

Each role inherits all permissions from roles below it.

### Default permissions

| Permission | viewer | member | admin | owner |
|------------|--------|--------|-------|-------|
| `view_organization` | ✅ | ✅ | ✅ | ✅ |
| `view_members` | ✅ | ✅ | ✅ | ✅ |
| `create_resources` | | ✅ | ✅ | ✅ |
| `edit_own_resources` | | ✅ | ✅ | ✅ |
| `delete_own_resources` | | ✅ | ✅ | ✅ |
| `invite_members` | | | ✅ | ✅ |
| `remove_members` | | | ✅ | ✅ |
| `edit_member_roles` | | | ✅ | ✅ |
| `manage_settings` | | | ✅ | ✅ |
| `view_billing` | | | ✅ | ✅ |
| `manage_billing` | | | | ✅ |
| `transfer_ownership` | | | | ✅ |
| `delete_organization` | | | | ✅ |

### Customize roles and permissions

Define your own roles in the initializer:

```ruby
# config/initializers/organizations.rb
Organizations.configure do |config|
  config.roles do
    role :viewer do
      can :view_organization
      can :view_members
    end

    role :member, inherits: :viewer do
      can :create_resources
      can :edit_own_resources
      can :delete_own_resources
    end

    role :admin, inherits: :member do
      can :invite_members
      can :remove_members
      can :edit_member_roles
      can :manage_settings
    end

    role :owner, inherits: :admin do
      can :manage_billing
      can :transfer_ownership
      can :delete_organization
    end
  end
end
```

### Add custom permissions

```ruby
role :admin, inherits: :member do
  can :invite_members
  can :remove_members
  can :manage_api_keys      # Your custom permission
  can :export_data          # Your custom permission
end
```

Then check them anywhere:

```ruby
current_user.has_organization_permission_to?(:manage_api_keys)
require_organization_permission_to!(:export_data)
```

## Invitations

### Sending invitations

Invitations are user-to-user. The inviter is always explicit, and the email reads *"John invited you to join Acme Corp"*.

```ruby
# Invite to your current organization (most common)
current_user.send_organization_invite_to!("teammate@example.com")

# Invite to a specific organization
current_user.send_organization_invite_to!("teammate@example.com", organization: other_org)

# All invitees join as :member by default. Admins can promote after joining.
```

There's also an organization-centric API if you prefer:

```ruby
org.send_invite_to!("teammate@example.com", invited_by: current_user)
```

### Invitation flow

The gem handles **both existing users and new signups** with a single invitation link:

**For existing users:**
1. Invitation created → Email sent with unique link
2. User clicks link → Sees invitation details (org name, inviter, role)
3. User clicks "Accept" → Membership created, redirected to org

**For new users:**
1. Invitation created → Email sent with unique link
2. User clicks link → Sees invitation details + "Sign up to accept" button
3. User registers → Invitation auto-accepted on signup, redirected to org

No need to handle these cases separately in your UI — one invitation flow works for everyone.

### Invitation emails

The gem ships with a clean ActionMailer-based invitation email. If you have the [`goodmail`](https://github.com/rameerez/goodmail) gem installed, it automatically uses goodmail for beautiful transactional emails.

```ruby
# Customize the mailer in config
Organizations.configure do |config|
  config.invitation_mailer = "Organizations::InvitationMailer"  # Default
  # Or use your own: config.invitation_mailer = "CustomInvitationMailer"
end
```

### Invitation expiration

Invitations expire after 7 days by default:

```ruby
Organizations.configure do |config|
  config.invitation_expiry = 7.days  # Default
  # config.invitation_expiry = 30.days
  # config.invitation_expiry = nil  # Never expire
end
```

Expired invitations can be resent:

```ruby
invitation.expired?   # => true
invitation.resend!    # Generates new token, resets expiry, sends email
```

### Accepted invitations

Accepted invitations are kept for audit purposes:

```ruby
org.invitations.accepted  # Who was invited and when
invitation.accepted_at    # When they joined
invitation.invited_by     # Who sent the invitation
```

## Organization switching

Users can belong to multiple organizations. The "current" organization is stored in session, and all your queries scope to it automatically.

### How it works

1. User logs in → `current_organization` set to their most recently used org
2. User switches org → Session updated, `current_organization` changes
3. User is removed from current org → Auto-switches to next available org

### Manual switching

```ruby
# In a controller
def switch
  org = current_user.organizations.find(params[:id])
  switch_to_organization!(org)
  redirect_to dashboard_path
end
```

### Routes provided by the engine

When you mount the engine, you get:

```
POST /organizations/switch/:id  → Organizations::SwitchController#create
GET  /invitations/:token        → Organizations::InvitationsController#show
POST /invitations/:token/accept → Organizations::InvitationsController#accept
```

## Auto-created organizations

By default, every user gets a personal organization on signup:

```ruby
# When user is created:
# 1. Organization created with name from config
# 2. User becomes owner of that organization
# 3. current_organization set to this new org
```

### Configure auto-creation

```ruby
Organizations.configure do |config|
  # Enable/disable auto-creation
  config.create_personal_organization = true  # Default

  # Customize the name
  config.personal_organization_name = ->(user) { "#{user.email.split('@').first}'s Workspace" }
  # Default: "Personal"
end
```

### Disable auto-creation

```ruby
Organizations.configure do |config|
  config.create_personal_organization = false
end
```

When disabled, users must explicitly create or be invited to an organization.

### Users without organizations (limbo state)

Many apps have onboarding flows where users sign up first, then create or join an organization later:

1. User signs up → verifies email
2. User is in "limbo" (no organization yet)
3. User creates org OR accepts invitation
4. User now has an organization

To support this flow, configure your User model:

```ruby
class User < ApplicationRecord
  has_organizations do
    create_personal_org false    # Don't auto-create on signup
    require_organization false   # Allow users without any org
  end
end
```

When a user has no organization:

```ruby
current_user.organization                    # => nil
current_user.current_organization            # => nil
current_user.belongs_to_any_organization?    # => false
current_user.is_organization_admin?          # => false (no org context)

# In controllers
current_organization                         # => nil
organization_signed_in?                      # => false
require_organization!                        # Redirects to on_no_organization handler
```

Handle the limbo state in your views:

```erb
<% if current_user.belongs_to_any_organization? %>
  <%= render "dashboard" %>
<% else %>
  <%= render "onboarding/create_or_join_organization" %>
<% end %>
```

Configure where to redirect users without an organization:

```ruby
Organizations.configure do |config|
  config.on_no_organization do |context|
    redirect_to new_organization_path, notice: "Create or join an organization to continue."
  end
end
```

## Configuration

Full configuration options:

```ruby
# config/initializers/organizations.rb
Organizations.configure do |config|
  # === Authentication ===
  # Method that returns the current user (default: :current_user)
  config.current_user_method = :current_user

  # Method that ensures user is authenticated (default: :authenticate_user!)
  config.authenticate_user_method = :authenticate_user!

  # === Auto-creation ===
  # Create personal organization on user signup
  config.create_personal_organization = true

  # Name for auto-created organizations
  config.personal_organization_name = ->(user) { "Personal" }

  # === Invitations ===
  # How long invitations are valid
  config.invitation_expiry = 7.days

  # Custom mailer for invitations
  config.invitation_mailer = "Organizations::InvitationMailer"

  # === Limits ===
  # Maximum organizations a user can own (nil = unlimited)
  config.max_organizations_per_user = nil

  # === Onboarding ===
  # Allow users to exist without any organization membership
  # Set to false for flows where users sign up first, then create/join org later
  config.require_organization = true  # Default

  # === Redirects ===
  # Where to redirect when user has no organization
  config.no_organization_path = "/organizations/new"

  # === Handlers ===
  # Called when authorization fails
  config.on_unauthorized do |context|
    redirect_to root_path, alert: "Not authorized"
  end

  # Called when no organization is set
  config.on_no_organization do |context|
    redirect_to config.no_organization_path
  end

  # === Roles & Permissions ===
  config.roles do
    # ... (see Roles and Permissions section)
  end

  # === Callbacks ===
  config.on_organization_created do |ctx|
    # ctx.organization, ctx.user (owner)
  end

  config.on_member_invited do |ctx|
    # ctx.organization, ctx.invitation, ctx.invited_by
  end

  config.on_member_joined do |ctx|
    # ctx.organization, ctx.membership, ctx.user
  end

  config.on_member_removed do |ctx|
    # ctx.organization, ctx.membership, ctx.user, ctx.removed_by
  end

  config.on_role_changed do |ctx|
    # ctx.organization, ctx.membership, ctx.old_role, ctx.new_role, ctx.changed_by
  end

  config.on_ownership_transferred do |ctx|
    # ctx.organization, ctx.old_owner, ctx.new_owner
  end
end
```

## Integrations

### Works with Devise out of the box

`organizations` is built for Devise. It uses `current_user` and `authenticate_user!` by default. Just add `has_organizations` and you're done.

### Works with other auth systems

Using Rodauth, Sorcery, or custom auth? Configure the methods:

```ruby
Organizations.configure do |config|
  config.current_user_method = :current_account
  config.authenticate_user_method = :require_login
end
```

### Integrates with acts_as_tenant

For automatic query scoping, include the integration concern:

```ruby
class ApplicationController < ActionController::Base
  include Organizations::Controller
  include Organizations::ActsAsTenantIntegration
  # Automatically calls: set_current_tenant(current_organization)
end
```

### Integrates with pricing_plans

Enforce member limits based on pricing plans:

```ruby
# In your Organization model
class Organization < ApplicationRecord
  include PricingPlans::PlanOwner
end

# In config/initializers/pricing_plans.rb
plan :starter do
  limits :members, to: 5
end

plan :pro do
  limits :members, to: 50
end
```

The `organizations` gem checks `pricing_plans` limits before allowing new invitations.

### Integrates with your gem ecosystem

`organizations` is designed to work with rameerez's gem ecosystem:

```ruby
# Organization owns API keys (api_keys gem)
class Organization < ApplicationRecord
  has_api_keys do
    max_keys 10
  end
end

# Organization has credits (usage_credits gem)
class Organization < ApplicationRecord
  has_credits
end

# Organization has pricing plan (pricing_plans gem)
class Organization < ApplicationRecord
  include PricingPlans::PlanOwner
end
```

All scoped through `current_organization`:

```ruby
current_organization.api_keys
current_organization.credits
current_organization.current_pricing_plan
current_organization.memberships  # From organizations gem
```

## Callbacks

Hook into organization lifecycle events:

```ruby
Organizations.configure do |config|
  config.on_organization_created do |ctx|
    SlackNotifier.notify("New org: #{ctx.organization.name}")
    Analytics.track(ctx.user, "organization_created")
  end

  config.on_member_joined do |ctx|
    WelcomeMailer.send_team_welcome(ctx.user, ctx.organization).deliver_later
    Analytics.track(ctx.user, "joined_organization", org: ctx.organization.name)
  end

  config.on_member_removed do |ctx|
    AuditLog.record(
      action: :member_removed,
      organization: ctx.organization,
      user: ctx.user,
      actor: ctx.removed_by
    )
  end
end
```

### Available callbacks

| Callback | Context fields |
|----------|----------------|
| `on_organization_created` | `organization`, `user` |
| `on_member_invited` | `organization`, `invitation`, `invited_by` |
| `on_member_joined` | `organization`, `membership`, `user` |
| `on_member_removed` | `organization`, `membership`, `user`, `removed_by` |
| `on_role_changed` | `organization`, `membership`, `old_role`, `new_role`, `changed_by` |
| `on_ownership_transferred` | `organization`, `old_owner`, `new_owner` |

## Testing

### Test helpers

```ruby
# test/test_helper.rb
require "organizations/test_helpers"

class ActiveSupport::TestCase
  include Organizations::TestHelpers
end
```

### Fixtures

The gem works with Rails fixtures:

```yaml
# test/fixtures/organizations.yml
acme:
  name: Acme Corp
  slug: acme-corp

# test/fixtures/memberships.yml
john_at_acme:
  user: john
  organization: acme
  role: admin
```

### Test helpers

```ruby
# Set organization context in tests
sign_in_as_organization_member(user, org, role: :admin)
set_current_organization(org)

# Or manually
sign_in user
switch_to_organization!(org)
```

### Minitest assertions

```ruby
assert user.is_member_of?(org)
assert user.is_owner_of?(org)
assert user.is_organization_admin?
assert user.has_organization_permission_to?(:invite_members)
assert user.belongs_to_any_organization?
```

## Extending the Organization model

The gem creates a base `Organization` model. **You should extend it** with your app's specific fields:

```ruby
# db/migrate/xxx_add_custom_fields_to_organizations.rb
class AddCustomFieldsToOrganizations < ActiveRecord::Migration[8.0]
  def change
    add_column :organizations, :support_email, :string
    add_column :organizations, :billing_address, :text
    add_column :organizations, :settings, :jsonb, default: {}
  end
end
```

```ruby
# app/models/organization.rb
class Organization < ApplicationRecord
  # Add your own associations
  has_many :projects
  has_many :documents

  # Add your own validations
  validates :support_email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }

  # Add your own methods
  def active_projects
    projects.where(archived: false)
  end
end
```

This is standard Rails practice — the gem provides the foundation (memberships, invitations, roles), your app extends it with domain-specific features.

## Database schema

The gem creates three tables:

### organizations

```sql
organizations
  - id (primary key, auto-detects UUID or integer from your app)
  - name (string, required)
  - slug (string, unique, indexed) -- auto-generated via slugifiable gem
  - metadata (jsonb, default: {})
  - created_at
  - updated_at
```

> **Note:** The gem automatically detects your app's primary key type (UUID or integer) and uses it for all tables. Slugs are auto-generated from the organization name using the [`slugifiable`](https://github.com/rameerez/slugifiable) gem.

### memberships

```sql
memberships
  - id (primary key)
  - user_id (foreign key, indexed)
  - organization_id (foreign key, indexed)
  - role (string, default: 'member')
  - invited_by_id (foreign key, nullable)
  - created_at
  - updated_at

  unique index: [user_id, organization_id]
```

### invitations

```sql
invitations
  - id (primary key)
  - organization_id (foreign key, indexed)
  - email (string, required, indexed)
  - role (string, default: 'member')
  - token (string, unique, indexed)
  - invited_by_id (foreign key)
  - accepted_at (datetime, nullable)
  - expires_at (datetime)
  - created_at
  - updated_at

  unique index: [organization_id, email] where accepted_at is null
```

## Ownership rules

- Every organization has exactly one owner
- Owner cannot leave the organization (must transfer ownership first)
- Ownership can be transferred to any admin: `org.transfer_ownership_to!(other_admin)`
- When ownership is transferred, old owner becomes admin

## Edge cases handled

| Scenario | Behavior |
|----------|----------|
| User removed from current org | Auto-switches to next available org |
| User has no organizations | Redirects to configurable path (or allowed if `require_organization: false`) |
| User signs up, no org yet | `current_organization` returns `nil`, `belongs_to_any_organization?` returns `false` |
| Last admin tries to leave | Must transfer ownership first |
| Invitation accepted twice (race condition) | Gracefully returns existing membership |
| Invitation for existing member | Returns error, doesn't duplicate |
| Expired invitation resent | New token generated, expiry reset |

## Migration from 1:1 relationships

If your app currently has `User belongs_to :organization` (1:1), see our [migration guide](docs/migration-guide.md) for upgrading to many-to-many.

## Roadmap

- [ ] Domain-based auto-join (users with @acme.com auto-join Acme org)
- [ ] Bulk invitations (CSV upload)
- [ ] Request-to-join workflow
- [ ] Organization-level audit logs
- [ ] Team hierarchies within organizations

## Development

```bash
git clone https://github.com/rameerez/organizations
cd organizations
bin/setup
bundle exec rake test
```

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/rameerez/organizations. Our code of conduct is: just be nice and make your mom proud of what you do and post online.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
