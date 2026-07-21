# Warbler Authentication Implementation Specification

> **Historical document.** This file records a prior Warbler/org-key design for
> archaeology only. It is **not** the current GTFS Planner authentication
> contract. Live companion access uses user-owned `api_session` Bearer tokens
> (`POST /api/v1/auth/login`, `VerifyApiSession`). See
> [API Authentication](./api-authentication.md) and
> [Authentication Guide](./authentication-guide.md).

## Overview

The Warbler project implements a comprehensive multi-tenant authentication system with organization-based access control, supporting both user authentication via email/password and programmatic access via API keys. The system is built on Phoenix LiveView with Ecto for database management and follows security best practices including secure password hashing, token-based authentication, and role-based authorization.

## Dependencies & Libraries

### Core Authentication Libraries

- **`argon2_elixir` (~> 4.1)**: Password hashing using Argon2 algorithm for secure password storage
- **`phoenix` (~> 1.8.0)**: Web framework providing session management and authentication utilities
- **`phoenix_live_view` (~> 1.0)**: Real-time authentication hooks for LiveView applications
- **`ecto_sql` (~> 3.10)**: Database abstraction layer for user and token management
- **`postgrex`**: PostgreSQL adapter for database connectivity

### Supporting Libraries

- **`phoenix_ecto` (~> 4.5)**: Phoenix and Ecto integration
- **`phoenix_html` (~> 4.1)**: HTML rendering for authentication forms
- **`jason` (~> 1.2)**: JSON encoding for API responses
- **`ex_cldr_plugs` (~> 1.3)**: Internationalization support with locale management

## Database Schema

### Users Table (`users`)

```sql
CREATE TABLE users (
  id BINARY_ID PRIMARY KEY DEFAULT gen_random_uuid(),
  email CITEXT NOT NULL UNIQUE,
  hashed_password STRING,
  inserted_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);
```

**Key Features:**

- Binary UUID primary key for security
- Case-insensitive email using PostgreSQL `citext` extension
- Optional hashed password (users can be invited without passwords initially)
- UTC timestamps with microsecond precision

### User Tokens Table (`users_tokens`)

```sql
CREATE TABLE users_tokens (
  id BINARY_ID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id BINARY_ID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token BINARY NOT NULL,
  context STRING NOT NULL,
  sent_to STRING,
  inserted_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX users_tokens_user_id_index ON users_tokens(user_id);
CREATE UNIQUE INDEX users_tokens_context_token_index ON users_tokens(context, token);
```

**Token Contexts:**

- `"session"`: User login sessions (60-day expiry)
- `"invite"`: User invitation emails (7-day expiry)
- `"reset_password"`: Password reset emails (1-day expiry)
- `"change:<email>"`: Email change confirmation (7-day expiry)

### Organizations Table (`organizations`)

```sql
CREATE TABLE organizations (
  id BINARY_ID PRIMARY KEY DEFAULT gen_random_uuid(),
  alias STRING NOT NULL UNIQUE,
  name STRING NOT NULL,
  inserted_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);
```

### User Organization Memberships Table (`user_org_memberships`)

```sql
CREATE TABLE user_org_memberships (
  id BINARY_ID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id BINARY_ID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  organization_id BINARY_ID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  roles STRING[] DEFAULT '{}',
  inserted_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  UNIQUE(user_id, organization_id)
);
```

### API Keys Table (`api_keys`)

```sql
CREATE TABLE api_keys (
  id BINARY_ID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id BINARY_ID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  description STRING NOT NULL,
  roles STRING[] DEFAULT '{}',
  version INTEGER DEFAULT 1,
  secret_hash BINARY NOT NULL,
  inserted_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);
```

## Core Authentication Components

### 1. UserAuth Module (`lib/warbler_web/user_auth.ex`)

**Purpose:** Central authentication module handling session management, login/logout flows, and LiveView authentication hooks.

**Key Functions:**

- `log_in_user/3`: Authenticates user, creates session token, handles remember-me cookies
- `log_out_user/1`: Clears session, invalidates tokens, disconnects LiveView sessions
- `fetch_current_user/2`: Retrieves current user from session or remember-me cookie
- `on_mount/4`: LiveView authentication hooks for different scenarios

**LiveView Mount Hooks:**

- `:mount_current_user`: Assigns current_user without authentication requirement
- `:ensure_authenticated`: Requires authenticated user, redirects to login if not authenticated
- `:redirect_if_user_is_authenticated`: Redirects authenticated users away from login pages

**Session Management:**

- 60-day session token expiry
- Optional remember-me cookie with 60-day persistence
- Session renewal on login to prevent fixation attacks
- LiveView session tracking for forced disconnection on logout

### 2. Accounts Context (`lib/warbler/accounts.ex`)

**Purpose:** Business logic for user management, authentication, and organization membership.

**Key Features:**

- User invitation system with email-based registration
- Password reset functionality with secure token validation
- Email change confirmation workflow
- Session token generation and validation
- Organization membership management

**User Invitation Flow:**

1. Admin creates user invitation via `invite_user/2`
2. System generates email token and sends invitation
3. User clicks invitation link and sets initial password
4. System creates user organization membership

**Token Management:**

- Session tokens: 60-day expiry, stored in database
- Email tokens: Context-based expiry (1-7 days depending on type)
- Secure token generation using cryptographically secure random bytes
- Hashed token storage to prevent database compromise

### 3. Organizations Context (`lib/warbler/organizations.ex`)

**Purpose:** Multi-tenant organization management with API key authentication.

**Key Functions:**

- Organization CRUD operations with PubSub broadcasting
- API key generation and validation
- Organization membership management
- Multi-tenant access control

**API Key System:**

- Versioned API keys with format `Warbler.V1.<encoded_data>`
- Secure token generation using SHA3-512 hashing
- Organization-scoped access control
- Role-based permissions for API access

### 4. API Key Authentication (`lib/warbler_web/api_key_auth.ex`)

**Purpose:** HTTP API authentication using bearer tokens.

**Authentication Methods:**

- RFC 6750 compliant: `Authorization: Bearer Warbler.V1.abcdefg`
- Compatibility mode: `Authorization: Warbler.V1.abcdefg`

**Security Features:**

- Constant-time token comparison
- Rate limiting through random delays on failed authentication
- Organization-based access control
- Automatic error responses for missing/invalid tokens

### 5. Role-Based Authorization (`lib/warbler_web/ensure_role.ex`)

**Purpose:** Fine-grained permission control for both users and API keys.

**Role Specifications:**

- Single role: `:administrator`
- Any membership: `nil` (requires organization membership but no specific role)
- Any role in list: `any: [:role1, :role2]`
- All roles in list: `all: [:role1, :role2]`

**Implementation:**

- LiveView `on_mount` hook for client-side authentication
- Plug implementation for server-side API authentication
- Organization-scoped role checking
- Graceful handling of unauthorized access

## Authentication Flows

### 1. User Registration (Invitation System)

**Flow:**

1. Administrator navigates to organization management
2. Uses `ManageUsersLive` to invite new user by email
3. System calls `Accounts.invite_user/2` which:
   - Creates user record with email only (no password initially)
   - Generates invitation token via `UserToken.build_email_token/2`
   - Sends invitation email with secure link
4. User receives email and clicks invitation link
5. System validates token via `Accounts.get_user_by_invite_token/1`
6. User sets initial password using `UserAcceptInviteLive`
7. System calls `Accounts.accept_invite_set_password/2` to:
   - Hash and store password using Argon2
   - Create user organization membership
   - Invalidate all user tokens
8. User can now log in with email/password

**Security Features:**

- Invitation tokens expire after 7 days
- Tokens are single-use and invalidated after password set
- Email validation prevents token reuse
- Organization membership created automatically

### 2. User Login/Authentication

**Flow:**

1. User navigates to login page (`/users/log_in`)
2. `UserLoginLive` renders email/password form
3. User submits credentials to `UserSessionController.create/2`
4. System validates credentials via `Accounts.get_user_by_email_and_password/2`
5. If valid:
   - Generates session token via `Accounts.generate_user_session_token/1`
   - Calls `UserAuth.log_in_user/3` which:
     - Renews session to prevent fixation attacks
     - Stores session token in database and session
     - Sets remember-me cookie if requested
     - Redirects to `signed_in_path` (organizations list)
6. If invalid:
   - Returns error message
   - Stores email in flash for form repopulation

**Security Features:**

- Password comparison uses Argon2 verification with timing attack protection
- Session tokens stored in database for revocation capability
- Remember-me cookies are signed and have 60-day expiry
- Session renewal prevents fixation attacks

### 3. API Key Authentication

**Flow:**

1. Administrator creates API key via `ApiKeyLive`
2. System calls `Organizations.create_api_key/2` which:
   - Generates cryptographically secure random secret
   - Creates SHA3-512 hash of API key data
   - Returns token string `Warbler.V1.<encoded_data>`
3. Client makes API request with `Authorization: Bearer Warbler.V1.abcdefg`
4. `ApiKeyAuth.fetch_current_api_key/2` extracts token from header
5. System validates token via `Organizations.get_api_key_by_token/1`:
   - Parses token to extract API key ID and secret
   - Retrieves API key record by ID
   - Verifies token using constant-time comparison
   - Applies random delay (500-800ms) on failed attempts
6. If valid:
   - Assigns `current_api_key` to connection
   - Continues to requested endpoint
7. If invalid:
   - Returns 401 Unauthorized with error JSON

**Security Features:**

- API keys never stored in plaintext (only hashes)
- Constant-time comparison prevents timing attacks
- Random delays prevent enumeration attacks
- Organization-scoped access control

### 4. Password Reset

**Flow:**

1. User navigates to forgot password page
2. `UserForgotPasswordLive` renders email form
3. User submits email address
4. System generates reset token via `UserToken.build_email_token/2`
5. Sends password reset email with secure link
6. User clicks link and lands on `UserResetPasswordLive`
7. System validates token via `Accounts.get_user_by_reset_password_token/1`
8. User sets new password
9. System calls `Accounts.reset_user_password/2`:
   - Hashes new password with Argon2
   - Updates user record
   - Invalidates all user tokens
   - Returns success

**Security Features:**

- Reset tokens expire after 1 day
- Tokens are single-use and invalidated after password change
- All existing sessions are invalidated after password reset
- Email validation ensures token goes to correct user

## Route Protection

### Browser Routes

**Authentication Pipelines:**

```elixir
# Public routes (no authentication required)
pipeline :browser do
  plug :accepts, ["html"]
  plug :fetch_session
  plug :fetch_live_flash
  plug :protect_from_forgery
  plug :put_secure_browser_headers
  plug :fetch_current_user
end

# Routes that redirect if user is already authenticated
pipeline :redirect_if_user_is_authenticated do
  plug :browser
  plug :redirect_if_user_is_authenticated
end

# Routes that require authentication
pipeline :require_authenticated_user do
  plug :browser
  plug :require_authenticated_user
end
```

**Protected Routes:**

```elixir
# Login/forgot password routes (redirect if already authenticated)
scope "/", WarblerWeb do
  pipe_through [:browser, :redirect_if_user_is_authenticated]

  live_session :redirect_if_user_is_authenticated,
    on_mount: [{WarblerWeb.UserAuth, :redirect_if_user_is_authenticated}] do
    live "/users/log_in", UserLoginLive, :new
    live "/users/reset_password", UserForgotPasswordLive, :new
    live "/users/reset_password/:token", UserResetPasswordLive, :edit
    live "/users/accept_invite/:token", UserAcceptInviteLive, :edit
  end
end

# Authenticated routes
scope "/", WarblerWeb do
  pipe_through [:browser, :require_authenticated_user]

  live_session :require_authenticated_user,
    on_mount: [{WarblerWeb.UserAuth, :ensure_authenticated}] do
    live "/users/settings", UserSettingsLive, :edit
    live "/organizations", OrganizationsListLive, :index
  end
end

# Organization-scoped routes
scope "/organizations/:org_alias", WarblerWeb do
  pipe_through [:browser, :require_authenticated_user]

  live_session :require_authenticated_user_and_org,
    on_mount: [{WarblerWeb.UserAuth, :ensure_authenticated}, WarblerWeb.AssignOrganization] do
    live "/map", MapLive.Index, :index
    live "/manage/users", ManageUsersLive, :edit
    # ... other organization-scoped routes
  end
end
```

### API Routes

**API Authentication Pipelines:**

```elixir
# Public API routes
pipeline :api_public do
  plug :accepts, ["json"]
  plug OpenApiSpex.Plug.PutApiSpec, module: WarblerWeb.ApiSpec
end

# Authenticated API routes
pipeline :api do
  plug :api_public
  plug :fetch_current_api_key
end

# Organization-scoped API routes
pipeline :api_organization do
  plug :api
  plug WarblerWeb.AssignOrganization
end
```

**Protected API Endpoints:**

```elixir
# API key authentication required
scope "/api", WarblerWeb do
  pipe_through [:api_json, :api]
  get "/test-key", TestKeyController, :show
end

# Organization-scoped API endpoints
scope "/api/info/:org_alias", WarblerWeb do
  pipe_through [:api_json, :api_organization]
  get "/", AgencyInfoController, :info
  get "/routes", AgencyRoutesController, :show
end

scope "/api/real-time/:org_alias", WarblerWeb do
  pipe_through [:api_json, :api_organization]
  get "/vehicles", VehiclePositionsController, :show
  get "/predictions", PredictionsController, :show
end
```

## Security Features

### Password Security

- **Hashing Algorithm**: Argon2 (memory-hard, resistant to GPU attacks)
- **Password Requirements**: Minimum 12 characters, maximum 72 characters
- **Validation**: Confirmation matching, current password verification for changes
- **Storage**: Only hashed passwords stored, never plaintext
- **Timing Attack Protection**: `Argon2.no_user_verify/0` for non-existent users

### Token Security

- **Generation**: Cryptographically secure random bytes (`:crypto.strong_rand_bytes/1`)
- **Storage**: Hashed tokens stored in database, raw tokens never persisted
- **Expiry**: Context-based expiry (1-60 days depending on token type)
- **Validation**: Constant-time comparison to prevent timing attacks
- **Single Use**: Email tokens invalidated after use
- **Revocation**: Database storage allows token revocation

### Session Security

- **Session Fixation Protection**: Session renewal on login
- **Secure Cookies**: Signed cookies with `same_site: "Lax"`
- **CSRF Protection**: Built-in Phoenix CSRF tokens
- **SSL Enforcement**: SSL plug enforces HTTPS in production
- **LiveView Integration**: Automatic disconnection on logout

### API Security

- **Bearer Token Authentication**: RFC 6750 compliant
- **Constant-Time Comparison**: Prevents timing attacks
- **Rate Limiting**: Random delays on failed authentication attempts
- **Organization Scoping**: API keys only work for their organization
- **Role-Based Access**: Fine-grained permissions via roles

## File Inventory

### Core Authentication Files

| File                                     | Purpose                         | Key Functions/Components                         |
| ---------------------------------------- | ------------------------------- | ------------------------------------------------ |
| `lib/warbler_web/user_auth.ex`           | Central authentication module   | Session management, LiveView hooks, login/logout |
| `lib/warbler/accounts.ex`                | User management business logic  | Invitations, password reset, session tokens      |
| `lib/warbler/accounts/user.ex`           | User schema and validation      | Password hashing, email validation               |
| `lib/warbler/accounts/user_token.ex`     | Token generation and validation | Session/email tokens, security                   |
| `lib/warbler/organizations.ex`           | Organization management         | Multi-tenancy, API keys                          |
| `lib/warbler/organizations/api_key.ex`   | API key implementation          | Token generation, verification                   |
| `lib/warbler_web/api_key_auth.ex`        | HTTP API authentication         | Bearer token validation                          |
| `lib/warbler_web/ensure_role.ex`         | Role-based authorization        | Permission checking                              |
| `lib/warbler_web/assign_organization.ex` | Organization assignment         | URL-based org resolution                         |

### Router and Pipeline Files

| File                        | Purpose                         | Key Components                             |
| --------------------------- | ------------------------------- | ------------------------------------------ |
| `lib/warbler_web/router.ex` | Route definitions and pipelines | Authentication pipelines, protected routes |
| `lib/warbler_web/plugs.ex`  | Custom plugs                    | Authentication helpers                     |

### Controllers and LiveViews

| File                                                     | Purpose              | Key Actions             |
| -------------------------------------------------------- | -------------------- | ----------------------- |
| `lib/warbler_web/controllers/user_session_controller.ex` | Session management   | Login/logout actions    |
| `lib/warbler_web/live/user_login_live.ex`                | Login form rendering | User authentication UI  |
| `lib/warbler_web/live/user_settings_live.ex`             | User settings        | Password/email changes  |
| `lib/warbler_web/live/user_forgot_password_live.ex`      | Password reset       | Forgot password flow    |
| `lib/warbler_web/live/user_reset_password_live.ex`       | Password reset       | New password form       |
| `lib/warbler_web/live/user_accept_invite_live.ex`        | User invitation      | Initial password setup  |
| `lib/warbler_web/live/manage_users_live.ex`              | User management      | Admin user management   |
| `lib/warbler_web/live/api_key_live.ex`                   | API key management   | API key CRUD operations |

### Database Migration Files

| File                                                                  | Purpose                    | Tables Created       |
| --------------------------------------------------------------------- | -------------------------- | -------------------- |
| `priv/repo/migrations/20250519234905_create_organizations.exs`        | Organizations table        | organizations        |
| `priv/repo/migrations/20250521032935_create_users_auth_tables.exs`    | User authentication tables | users, users_tokens  |
| `priv/repo/migrations/20250525150652_create_user_org_memberships.exs` | Membership table           | user_org_memberships |
| `priv/repo/migrations/20250603235447_create_api_keys.exs`             | API keys table             | api_keys             |

### Configuration Files

| File                | Purpose                   | Authentication Settings                |
| ------------------- | ------------------------- | -------------------------------------- |
| `config/config.exs` | Application configuration | Secret key base, session configuration |
| `mix.exs`           | Dependencies              | Authentication libraries               |

## Implementation Details

### Password Hashing Implementation

```elixir
# In lib/warbler/accounts/user.ex
defp maybe_hash_password(changeset, opts) do
  hash_password? = Keyword.get(opts, :hash_password, true)
  password = get_change(changeset, :password)

  if hash_password? && password && changeset.valid? do
    changeset
    |> put_change(:hashed_password, Argon2.hash_pwd_salt(password))
    |> delete_change(:password)
  else
    changeset
  end
end

def valid_password?(%Warbler.Accounts.User{hashed_password: hashed_password}, password)
    when is_binary(hashed_password) and byte_size(password) > 0 do
  Argon2.verify_pass(password, hashed_password)
end

def valid_password?(_, _) do
  Argon2.no_user_verify()
  false
end
```

### Session Token Generation

```elixir
# In lib/warbler/accounts/user_token.ex
def build_session_token(user) do
  token = :crypto.strong_rand_bytes(@rand_size)
  {token, %UserToken{token: token, context: "session", user_id: user.id}}
end

def verify_session_token_query(token) do
  query =
    from token in by_token_and_context_query(token, "session"),
      where: token.inserted_at > ago(@session_validity_in_days, "day"),
      preload: [user: [memberships: :organization]]

  {:ok, query}
end
```

### API Key Generation

```elixir
# In lib/warbler/organizations/api_key.ex
def build_hashed_token(organization_id, changeset) do
  version = 1
  api_key_id = Ecto.UUID.generate()
  token_secret = :crypto.strong_rand_bytes(@secret_size)
  hash = hash_api_key(api_key_id, version, organization_id, token_secret)
  token = serialize_token(version, api_key_id, token_secret)

  changeset = cast(changeset, %{id: api_key_id, version: version, secret_hash: hash}, [:id, :version, :secret_hash])

  {token, changeset}
end

defp serialize_token(version, api_key_id, secret) do
  Enum.join(
    [@prefix, "V#{version}", Base.encode32(Ecto.UUID.dump!(api_key_id) <> secret, case: :lower, padding: false)],
    "."
  )
end
```

### LiveView Authentication Hooks

```elixir
# In lib/warbler_web/user_auth.ex
def on_mount(:ensure_authenticated, _params, session, socket) do
  socket = mount_current_user(socket, session)

  if socket.assigns.current_user do
    {:cont, socket}
  else
    socket =
      socket
      |> Phoenix.LiveView.put_flash(:error, "You must log in to access this page.")
      |> Phoenix.LiveView.redirect(to: ~p"/users/log_in")

    {:halt, socket}
  end
end
```

### Role-Based Authorization

```elixir
# In lib/warbler_web/ensure_role.ex
defp roles_match_spec(roles, spec)

defp roles_match_spec(nil, _), do: false

defp roles_match_spec(roles, nil) when is_list(roles), do: true
defp roles_match_spec(roles, role) when is_atom(role), do: role in roles

defp roles_match_spec(roles, any: spec) when is_list(spec) do
  Enum.any?(spec, &roles_match_spec(roles, &1))
end

defp roles_match_spec(roles, all: spec) when is_list(spec) do
  Enum.all?(spec, &roles_match_spec(roles, &1))
end
```

This comprehensive authentication system provides secure, multi-tenant access control with both user and API authentication, following industry best practices for security and usability.
