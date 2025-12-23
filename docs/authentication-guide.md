# Authentication Guide

## Overview

GTFS Planner implements a comprehensive, multi-tenant authentication and authorization system that provides secure user authentication, programmatic API access, and organization-based access control. The system is built on industry-standard security practices and integrates seamlessly with Phoenix LiveView and the existing application architecture.

### Architecture

The authentication system is organized into three primary layers:

1. **Context Layer** (`GtfsPlanner.Accounts`, `GtfsPlanner.Organizations`): Contains business logic, schemas, and data access for authentication and organization management
2. **Web Layer** (`GtfsPlannerWeb.UserAuth`, `GtfsPlannerWeb.ApiKeyAuth`, etc.): Provides authentication plugs, LiveView hooks, and HTTP controllers
3. **Database Layer**: PostgreSQL tables for users, tokens, organizations, memberships, and API keys with proper constraints and indexes

## User Authentication

### Password-Based Authentication

Users authenticate with email and password using the following flow:

1. User submits credentials via login form or API
2. System validates email exists (with timing attack protection)
3. Password is verified using Argon2 memory-hard hashing
4. Session token is generated and stored in database
5. User is logged in with session fixation protection

**Implementation**: `GtfsPlanner.Accounts.get_user_by_email_and_password/2`

### Password Security

- **Hashing Algorithm**: Argon2id (memory-hard, resistant to GPU/ASIC attacks)
- **Password Requirements**: 12-72 characters
- **Storage**: Never stored in plaintext; only Argon2 hash is stored
- **Timing Attack Protection**: Constant-time comparison and user-independent response times

### Session Management

Sessions are managed using database-backed tokens with the following properties:

- **Token Expiry**: 60 days (configurable)
- **Remember-Me**: Optional 60-day persistent cookie
- **Session Fixation**: Tokens regenerated on login
- **Revocation**: All sessions invalidated on password change or logout

**Implementation**: `GtfsPlannerWeb.UserAuth.log_in_user/3`, `GtfsPlannerWeb.UserAuth.log_out_user/1`

### LiveView Integration

LiveViews automatically track authentication state using:

- `:mount_current_user` hook: Assigns `current_user` without authentication requirement
- `:ensure_authenticated` hook: Requires authenticated user, redirects to login if not
- Session registry tracks connected sessions for disconnection on logout

**Example**:

```elixir
defmodule GtfsPlannerWeb.DashboardLive do
  use GtfsPlannerWeb, :live_view

  on_mount {GtfsPlannerWeb.UserAuth, :ensure_authenticated}

  def mount(_params, _session, socket) do
    {:ok, socket}
  end
end
```

## User Registration (Invitation)

### Invitation Flow

New users are invited to the system by organization administrators:

1. Admin initiates invitation with user email and organization
2. System generates invitation token (7-day expiry)
3. Invitation email is sent with secure acceptance link
4. User clicks link and sets initial password
5. User account is activated and organization membership created
6. User redirected to login page

**Implementation**:

```elixir
# Invite user
{:ok, user} = Accounts.invite_user(email, organization_id)

# Send invitation
Accounts.deliver_user_invite(user, accept_invite_url)

# Accept invitation (token comes from URL)
{:ok, user} = Accounts.get_user_by_invite_token(token)
{:ok, user} = Accounts.accept_invite_set_password(user, password)
```

**Security Features**:

- Tokens are single-use and invalidated after use
- Invitation links expire after 7 days
- Tokens hashed in database (never stored plaintext)
- Organization membership created atomically with password set

### Email Workflow

Invitation emails are sent via Swoosh with the following:

- **Sender**: Configured in `config/config.exs`
- **Subject**: "You're invited to join GTFS Planner"
- **Template**: HTML and plain text versions
- **Tracking**: Tokens tracked in `users_tokens` table with `context: "invite"`

**Implementation**: `GtfsPlanner.Accounts.UserNotifier.deliver_user_invite/2`

## Password Reset

### Reset Flow

Users can reset forgotten passwords via email:

1. User requests password reset with email address
2. System generates reset token (1-day expiry)
3. Reset instructions sent to email
4. User clicks link and sets new password
5. All existing sessions invalidated
6. User redirected to login

**Implementation**:

```elixir
# Request reset
Accounts.deliver_user_reset_password_instructions(user, reset_url)

# Reset password (token from URL)
{:ok, user} = Accounts.get_user_by_reset_password_token(token)
{:ok, user} = Accounts.reset_user_password(user, new_password)
```

**Security Features**:

- Tokens expire after 1 day
- Tokens are single-use
- All sessions invalidated after password change
- User-independent response time (security against enumeration)

**Implementation**: `GtfsPlanner.Accounts.deliver_user_reset_password_instructions/2`, `GtfsPlanner.Accounts.reset_user_password/2`

## API Key Authentication

### API Key Format

API keys follow RFC 6750 Bearer token format:

```
Authorization: Bearer GtfsPlanner.V1.abcdefg12345
```

For backward compatibility, the system also accepts:

```
Authorization: GtfsPlanner.V1.abcdefg12345
```

**Token Structure**:

- `GtfsPlanner.V1`: Version prefix identifying the system
- `abcdefg12345`: Base64-encoded random secret

### API Key Flow

1. Administrator creates API key for organization
2. System generates cryptographically secure random secret
3. Secret is hashed with SHA3-512 and stored in database
4. Unhashed token is returned to administrator (display once)
5. Client includes token in Authorization header
6. System validates token and retrieves organization and roles
7. Request proceeds with organization scope

**Implementation**:

```elixir
# Create API key
{:ok, api_key} = Organizations.create_api_key(organization, %{
  description: "Production API Key",
  roles: ["read", "write"]
})

# Token returned: "GtfsPlanner.V1.abc123..."
# This is the only time the unhashed token is visible
```

### API Key Authentication

**Implementation**: `GtfsPlannerWeb.ApiKeyAuth.fetch_current_api_key/2`

The authentication plug:

1. Extracts Authorization header from request
2. Parses Bearer token format
3. Looks up API key by hashed secret
4. Validates organization association
5. Assigns `current_api_key` and `current_organization` to connection

**Security Features**:

- Constant-time token comparison prevents timing attacks
- Random delay (500-800ms) on failed authentication prevents enumeration
- Tokens are organization-scoped (cannot access other organizations)
- Keys support role-based authorization

### API Key Authorization

API keys support the same role-based authorization system as users. Roles are specified when creating or updating an API key and are enforced using `GtfsPlannerWeb.EnsureRole`.

## Role-Based Authorization

### Role System

The authorization system supports flexible role matching:

- **Single role**: `:administrator` (user must have this specific role)
- **Any membership**: `nil` (user must be organization member, no role required)
- **Any of list**: `any: [:read, :write]` (user must have at least one of the roles)
- **All of list**: `all: [:read, :write]` (user must have all of the roles)

### LiveView Authorization

Use the `:ensure_role` mount hook to require specific roles:

```elixir
defmodule GtfsPlannerWeb.AdminLive do
  use GtfsPlannerWeb, :live_view

  on_mount {GtfsPlannerWeb.EnsureRole, :ensure_authenticated_and_role}
  on_mount {GtfsPlannerWeb.EnsureRole, :ensure_role, [:administrator]}

  def mount(_params, _session, socket) do
    {:ok, socket}
  end
end
```

**Available hooks**:

- `:ensure_role`: Generic hook, specify role as mount parameter
- `:ensure_authenticated_and_role`: Requires authentication and organization membership

### Plug Authorization

For API endpoints and controller routes, use the `ensure_role/2` plug:

```elixir
pipeline :require_admin do
  plug :accepts, ["json"]
  plug GtfsPlannerWeb.ApiKeyAuth.fetch_current_api_key
  plug GtfsPlannerWeb.EnsureRole, :ensure_role, :administrator
end

scope "/admin", as: :admin do
  pipe_through :require_admin
  # Admin routes here
end
```

### Role Storage

Roles are stored as PostgreSQL arrays in the database:

- `users.roles`: Array of role strings for user-wide roles
- `user_org_memberships.roles`: Array of role strings for organization-specific roles
- `api_keys.roles`: Array of role strings for API key permissions

**Implementation**: `GtfsPlannerWeb.EnsureRole.roles_match_spec/2`

## Multi-Tenant Organization Management

### Organization Scoping

The system provides two methods of organization scoping:

#### URL-Based Scoping (Browser)

Organization is identified by alias in URL:

```
/organizations/:org_alias/dashboard
```

The `GtfsPlannerWeb.AssignOrganization` plug:

1. Extracts `org_alias` from URL parameters
2. Fetches organization from database
3. Assigns `current_organization` to connection
4. Returns 404 if organization not found

**Implementation**: `GtfsPlannerWeb.AssignOrganization.call/2`

#### API Key Scoping (API)

API keys are inherently organization-scoped:

- API key is created for a specific organization
- Authentication automatically sets `current_organization`
- No URL parameter required

**Router Configuration**:

```elixir
# Browser routes with org scoping
scope "/organizations/:org_alias" do
  pipe_through [:browser, :require_authenticated_user, :require_organization]
  # Organization-scoped routes
end

# API routes with key-based scoping
scope "/api" do
  pipe_through [:api, :require_authenticated_api_key]
  # API-scoped routes
end
```

### User Membership

Users can belong to multiple organizations with different roles in each:

```elixir
# Add user to organization with roles
{:ok, membership} = Organizations.add_user_to_organization(
  user,
  organization,
  ["read", "write"]
)

# Update user roles in organization
{:ok, membership} = Organizations.update_user_roles(
  user,
  organization,
  ["read", "write", "admin"]
)

# Remove user from organization
{:ok, _} = Organizations.remove_user_from_organization(user, organization)
```

**Constraints**:

- Unique constraint on `(user_id, organization_id)` prevents duplicate memberships
- Cascade delete: removing user or organization deletes memberships
- Roles are validated on update

### Organization Management

**Organization CRUD**:

```elixir
# Create organization
{:ok, org} = Organizations.create_organization(%{
  alias: "transit-ops",
  name: "Transit Operations"
})

# Get by alias
org = Organizations.get_organization_by_alias("transit-ops")

# List organizations for user
organizations = Organizations.list_organizations_for_user(user)

# List users in organization
users = Organizations.list_users_in_organization(organization)
```

## Security Features

### Password Security

- **Argon2 Hashing**: Memory-hard algorithm resistant to GPU/ASIC attacks
- **Minimum Length**: 12 characters (enforced in changeset)
- **Maximum Length**: 72 characters (Argon2 limit)
- **No Plaintext Storage**: Only Argon2 hash stored in database
- **Timing Protection**: User-independent response times

### Token Security

- **Cryptographically Secure**: Generated with `:crypto.strong_rand_bytes/1`
- **Hashed Storage**: Tokens always hashed before database storage
- **Context-Based Expiry**: Different contexts have different expiry times
- **Constant-Time Comparison**: Prevents timing attacks via `Plug.Crypto.secure_compare`
- **Single-Use**: Email tokens invalidated after use
- **Revocation**: Database storage enables instant revocation

**Token Contexts**:

- `"session"`: 60-day expiry, multiple concurrent allowed
- `"confirm"`: 1-day expiry, single-use
- `"reset_password"`: 1-day expiry, single-use
- `"invite"`: 7-day expiry, single-use

### Session Security

- **Session Fixation Protection**: Token renewal on login
- **Secure Cookies**: Signed cookies with `same_site: "Lax"`
- **CSRF Protection**: Built-in Phoenix CSRF protection
- **SSL Enforcement**: Configured for production environments
- **LiveView Tracking**: Registry tracks sessions for disconnection

### API Security

- **Bearer Token Format**: RFC 6750 compliant
- **Constant-Time Comparison**: Prevents token enumeration
- **Rate Limiting**: Random delays (500-800ms) on failed auth
- **Organization Scoping**: Keys cannot access other organizations
- **Role-Based Permissions**: Fine-grained access control

## Usage Examples

### User Registration

```elixir
# Admin invites user
{:ok, user} = Accounts.invite_user(
  "user@example.com",
  organization_id
)

# User accepts invite (in LiveView or controller)
{:ok, user} = Accounts.get_user_by_invite_token(token)
{:ok, user} = Accounts.accept_invite_set_password(user, password)
```

### User Authentication

```elixir
# In controller
def create(conn, %{"user" => user_params}) do
  user = Accounts.get_user_by_email_and_password(
    user_params["email"],
    user_params["password"]
  )

  if user do
    UserAuth.log_in_user(conn, user, user_params)
    |> redirect(to: ~p"/dashboard")
  else
    # Show error
  end
end
```

### Protected LiveView

```elixir
defmodule GtfsPlannerWeb.DashboardLive do
  use GtfsPlannerWeb, :live_view

  on_mount {GtfsPlannerWeb.UserAuth, :ensure_authenticated}

  def mount(_params, _session, socket) do
    {:ok, socket}
  end
end
```

### Role-Protected Route

```elixir
# In router
pipeline :require_admin do
  plug :accepts, ["html"]
  plug :fetch_current_user
  plug :put_layout, {GtfsPlannerWeb.Layouts, :app}
  plug GtfsPlannerWeb.EnsureRole, :ensure_role, :administrator
end

scope "/admin" do
  pipe_through [:browser, :require_admin]
  live "/users", AdminUsersLive, :index
end
```

### API Key Usage

```elixir
# Create API key
{:ok, api_key} = Organizations.create_api_key(organization, %{
  description: "Production API",
  roles: ["read", "write"]
})

# Display token once to user
token = api_key.token  # "GtfsPlanner.V1.abc123..."

# Client makes request with Authorization header
curl -H "Authorization: Bearer GtfsPlanner.V1.abc123..." \
  https://api.example.com/v1/organizations/123/data
```

### Password Reset

```elixir
# Request reset
Accounts.deliver_user_reset_password_instructions(user, reset_url)

# Reset password (from email link)
{:ok, user} = Accounts.get_user_by_reset_password_token(token)
{:ok, user} = Accounts.reset_user_password(user, new_password)
```

### Organization Management

```elixir
# Create organization
{:ok, org} = Organizations.create_organization(%{
  alias: "transit-ops",
  name: "Transit Operations"
})

# Add user with roles
{:ok, membership} = Organizations.add_user_to_organization(
  user,
  org,
  ["read", "write"]
)

# Update roles
{:ok, membership} = Organizations.update_user_roles(
  user,
  org,
  ["read", "write", "admin"]
)
```

## Configuration

### Required Dependencies

```elixir
# mix.exs
defp deps do
  [
    {:argon2_elixir, "~> 4.1"},
    {:phoenix, "~> 1.8"},
    {:phoenix_ecto, "~> 4.5"},
    {:ecto_sql, "~> 3.10"},
    {:swoosh, "~> 1.16"}
  ]
end
```

### Session Configuration

```elixir
# config/config.exs
config :gtfs_planner, GtfsPlannerWeb.Endpoint,
  session_options: [
    store: :cookie,
    key: "_gtfs_planner_key",
    signing_salt: "secret_salt",
    encryption_salt: "encryption_salt"
  ]
```

### Email Configuration

```elixir
# config/dev.exs
config :gtfs_planner, GtfsPlanner.Mailer,
  adapter: Swoosh.Adapters.Local

# config/prod.exs
config :gtfs_planner, GtfsPlanner.Mailer,
  adapter: Swoosh.Adapters.Sendgrid,
  api_key: System.get_env("SENDGRID_API_KEY")
```

### Database Configuration

Ensure PostgreSQL `citext` extension is enabled (handled in migrations):

```elixir
# Migration
execute "CREATE EXTENSION IF NOT EXISTS citext"
```

## Best Practices

### For Developers

1. **Always use changesets** for validation and database operations
2. **Use tagged tuples** `{:ok, result}` or `{:error, changeset}` from contexts
3. **Leverage LiveView streams** for collections to avoid memory issues
4. **Use pattern matching** for control flow instead of conditionals
5. **Test authentication flows** with proper fixtures
6. **Document role requirements** for protected routes

### For Security

1. **Never store passwords in plaintext** - always use Argon2 hashing
2. **Validate all input** through changesets
3. **Use HTTPS in production** for all authentication flows
4. **Implement proper rate limiting** for API endpoints
5. **Log security events** (failed logins, password resets, etc.)
6. **Regularly rotate** API keys and session tokens
7. **Use environment variables** for sensitive configuration

### For Operations

1. **Monitor failed authentication attempts** for suspicious activity
2. **Set appropriate token expiry** based on security requirements
3. **Implement email verification** for new registrations
4. **Use organization scoping** to isolate tenant data
5. **Audit admin activities** with proper logging
6. **Regularly review** user roles and memberships

## Troubleshooting

### Common Issues

**User cannot log in**:

- Verify email exists (timing attack protection makes this difficult)
- Check password length (12-72 characters)
- Verify Argon2 hash matches (use `User.valid_password?/2`)
- Check for active session tokens

**API key authentication fails**:

- Verify Authorization header format: `Bearer GtfsPlanner.V1.abc123`
- Check API key is not revoked or expired
- Verify organization association
- Ensure roles match requirements

**LiveView authentication errors**:

- Ensure correct mount hook is used
- Check `current_scope` assignment in layouts
- Verify session token is valid
- Check browser cookie settings

### Debugging

Enable logging for authentication:

```elixir
# config/dev.exs
config :logger, :console,
  level: :debug
```

Check database for tokens:

```elixir
# List active session tokens
from(t in UserToken,
  where: t.context == "session",
  where: t.inserted_at > ago(@session_validity_in_days, :day))
|> Repo.all()
```

Verify API key hash:

```elixir
# Recreate hash for verification
hash = ApiKey.hash_api_key(organization.id, api_key.secret, api_key.version, api_key.inserted_at)
```

## References

- **Spec Document**: `docs/copy-auth-spec.md`
- **API Authentication**: `docs/api-authentication.md`
- **User Management**: `docs/user-management.md`
- **Engineering Standards**: `docs/elixir-phoenix-standards.md`

## Support

For questions or issues related to authentication:

1. Review this guide for common patterns
2. Check test files for usage examples
3. Refer to the implementation files for details
4. Consult engineering standards for coding practices
