# Copy Authentication System from Warbler to GTFS Planner

## Qualifications

- **Elixir & Phoenix**: Strong understanding of Phoenix framework, LiveView, and OTP
- **Ecto & PostgreSQL**: Experience with Ecto schemas, migrations, and database design
- **Authentication Systems**: Understanding of password hashing, token-based auth, and session management
- **Multi-tenant Architecture**: Experience with organization-based access control and scoping
- **Email Integration**: Familiarity with Swoosh and email workflows
- **Security Best Practices**: Knowledge of secure password storage, timing attacks, and CSRF protection

## Problem Statement

The GTFS Planner application currently lacks a comprehensive authentication and authorization system. The Warbler project implements a production-ready multi-tenant authentication system with the following features:

- User authentication via email/password with secure password hashing
- API key-based programmatic access
- Multi-tenant organization-based access control
- Role-based authorization
- User invitation and password reset workflows
- Session management with LiveView integration

Reimplementing this system from scratch would be inefficient and error-prone. Extracting and adapting the existing Warbler authentication implementation provides a proven, secure foundation.

## Goal

Extract and integrate the Warbler authentication system into GTFS Planner, adapting it to the existing project structure while maintaining all security features and functionality. The integration should follow GTFS Planner's engineering standards and maintain compatibility with the existing Phoenix v1.8 application.

## Architecture

### High-Level Architecture

```
GTFS Planner Application
├── Contexts (Business Logic)
│   ├── GtfsPlanner.Accounts
│   │   ├── User (schema)
│   │   ├── UserToken (schema)
│   │   ├── UserOrgMembership (schema)
│   │   └── UserNotifier (email)
│   └── GtfsPlanner.Organizations
│       ├── Organization (schema)
│       └── ApiKey (schema)
├── Web Layer (HTTP/LiveView)
│   ├── GtfsPlannerWeb.UserAuth (session management, hooks)
│   ├── GtfsPlannerWeb.ApiKeyAuth (bearer token validation)
│   ├── GtfsPlannerWeb.EnsureRole (authorization)
│   ├── GtfsPlannerWeb.AssignOrganization (URL scoping)
│   ├── Controllers (session management)
│   └── LiveViews (auth UI)
└── Database Schema
    ├── users (auth credentials)
    ├── users_tokens (session/email tokens)
    ├── organizations (multi-tenant tenants)
    ├── user_org_memberships (user-org relationships)
    └── api_keys (programmatic access)
```

### Authentication Flows

**User Registration (Invitation)**

1. Admin invites user by email → `Accounts.invite_user/2`
2. System generates invite token → `UserToken.build_email_token/2`
3. Email sent via `UserNotifier.deliver_user_invite/2`
4. User clicks link → Validates via `Accounts.get_user_by_invite_token/1`
5. User sets password → `Accounts.accept_invite_set_password/2`
6. Membership created automatically

**User Login**

1. User submits credentials → `UserSessionController.create/2`
2. Credentials validated → `Accounts.get_user_by_email_and_password/2`
3. Session token generated → `Accounts.generate_user_session_token/1`
4. User logged in → `UserAuth.log_in_user/3`
5. Redirected to protected area

**API Key Authentication**

1. Admin creates API key → `Organizations.create_api_key/2`
2. Token returned: `GtfsPlanner.V1.<encoded>`
3. Client includes: `Authorization: Bearer GtfsPlanner.V1.<encoded>`
4. Token validated → `ApiKeyAuth.fetch_current_api_key/2`
5. Request proceeds with organization scope

### Technology Stack

- **Password Hashing**: Argon2 (memory-hard algorithm)
- **Token Generation**: Cryptographically secure random bytes
- **Session Storage**: Database-backed with revocation capability
- **Email**: Swoosh with invitation/password reset workflows
- **Role System**: Postgres array-based with flexible matching
- **Multi-tenancy**: Organization scoping via URL and API key

## Acceptance Criteria

### Functional Requirements

1. **User Authentication**

   - Users can log in with email/password
   - Passwords are hashed with Argon2
   - Sessions have 60-day expiry
   - Remember-me functionality with signed cookies
   - Session fixation protection on login
   - LiveView sessions track authentication state

2. **User Registration (Invitation)**

   - Admins can invite users by email
   - Invitation tokens expire after 7 days
   - Invited users set initial password via secure link
   - Tokens are single-use and invalidated after use
   - Organization membership created automatically

3. **Password Reset**

   - Users can request password reset via email
   - Reset tokens expire after 1 day
   - Tokens are single-use
   - All sessions invalidated after password change

4. **API Key Authentication**

   - Organizations can create API keys
   - API keys use bearer token format: `GtfsPlanner.V1.<encoded>`
   - API keys support RFC 6750 compliant format
   - Keys are organization-scoped
   - Constant-time comparison prevents timing attacks
   - Random delays on failed auth prevent enumeration

5. **Multi-tenancy**

   - Users belong to organizations
   - Organizations have unique aliases
   - URL-based organization scoping: `/organizations/:org_alias/*`
   - API key authentication is organization-scoped

6. **Role-Based Authorization**

   - Support for single role: `:administrator`
   - Support for any membership: `nil`
   - Support for any role in list: `any: [:role1, :role2]`
   - Support for all roles in list: `all: [:role1, :role2]`
   - LiveView `on_mount` hooks for client-side auth
   - Plug implementation for API endpoints

7. **Route Protection**
   - Public routes accessible without authentication
   - Protected routes require authentication
   - Login routes redirect if already authenticated
   - Organization-scoped routes require both auth and org membership

### Security Requirements

1. **Password Security**

   - Minimum 12 characters, maximum 72 characters
   - Hashed with Argon2 algorithm
   - Never stored in plaintext
   - Timing attack protection for non-existent users

2. **Token Security**

   - Generated with cryptographically secure random bytes
   - Hashed in database, never plaintext
   - Context-based expiry (1-60 days)
   - Constant-time comparison
   - Single-use email tokens
   - Database storage enables revocation

3. **Session Security**

   - Session fixation protection (renewal on login)
   - Secure signed cookies with `same_site: "Lax"`
   - CSRF protection via Phoenix
   - SSL enforcement in production
   - LiveView auto-disconnection on logout

4. **API Security**
   - Bearer token authentication (RFC 6750)
   - Constant-time comparison
   - Rate limiting via random delays
   - Organization scoping
   - Role-based permissions

### Integration Requirements

1. **Project Structure**

   - Follow GTFS Planner's existing structure
   - Use `GtfsPlanner.Accounts` and `GtfsPlanner.Organizations` contexts
   - Place schemas in context subdirectories
   - Web modules in `GtfsPlannerWeb` namespace

2. **Dependencies**

   - Add `argon2_elixir ~ 4.1` to mix.exs
   - Use existing Phoenix, LiveView, Ecto dependencies
   - Optionally add `ex_cldr_plugs` for i18n

3. **Router**

   - Add authentication pipelines
   - Add protected routes with proper scoping
   - Integrate with existing router structure

4. **Database**

   - Create migrations for all auth tables
   - Use binary UUID primary keys
   - Add proper indexes and constraints
   - Enable PostgreSQL `citext` extension for case-insensitive emails

5. **Email**
   - Integrate with existing Swoosh mailer
   - Create email templates for auth workflows
   - Support invitation, password reset, email change

### Code Quality Requirements

1. Follow Elixir Phoenix Engineering Standards (docs/elixir-phoenix-standards.md)
2. Use pattern matching for control flow
3. Return tagged tuples from contexts
4. Use changesets for validation
5. Implement proper error handling
6. Add typespecs to public functions
7. Write tests for authentication flows
8. Use streams for LiveView collections

## Notes

### Adaptation Considerations

**Module Renaming**: All `Warbler.*` references must be changed to `GtfsPlanner.*`. This includes:

- Context modules: `Warbler.Accounts` → `GtfsPlanner.Accounts`
- Schemas: `Warbler.Accounts.User` → `GtfsPlanner.Accounts.User`
- Web modules: `WarblerWeb.UserAuth` → `GtfsPlannerWeb.UserAuth`

**Namespace Updates**: All function calls, imports, and aliases must be updated to reflect the new namespace.

**Configuration Adaptation**: Session configuration and secret key base settings must match GTFS Planner's config structure.

**Route Adaptation**: Route paths must be adapted to fit GTFS Planner's routing scheme. The current implementation uses `/users/*` for auth routes and `/organizations/:org_alias/*` for org-scoped routes.

**UI/UX Integration**: Authentication UI must integrate with GTFS Planner's existing design system using Tailwind CSS and DaisyUI components.

**Email Configuration**: Ensure Swoosh is configured correctly for the GTFS Planner environment.

### Optional Components

The following Warbler components may be optional depending on GTFS Planner's needs:

- Organization manager registry and supervision tree (for per-organization OTP supervision)
- Custom plugs beyond basic auth requirements
- Additional LiveViews for advanced user management

### Migration Strategy

All migrations should be:

- Append-only (never modify existing migrations)
- Use binary UUIDs for primary keys
- Include proper foreign key constraints
- Add indexes for frequently queried columns
- Use PostgreSQL `citext` for case-insensitive email comparison

### Testing Strategy

Test coverage should include:

- Context functions (public API)
- Authentication flows (login, logout, invitation, reset)
- API key generation and validation
- LiveView user interactions
- Role-based authorization
- Edge cases and error handling

## Implementation Steps

### Phase 1: Dependencies and Configuration

1. Add `{:argon2_elixir, "~> 4.1"}` to the `deps()` function in `mix.exs`.
2. Add `{:ex_cldr_plugs, "~> 1.3"}` to the `deps()` function in `mix.exs` if internationalization support is needed.
3. Run `mix deps.get` to install new dependencies.

### Phase 2: Database Schema

4. Create migration file `priv/repo/migrations/YYYYMMDDHHMMSS_create_organizations.exs` with the following schema:

   - Table: `organizations`
   - Columns: `id` (binary uuid, primary key), `alias` (string, not null, unique), `name` (string, not null), `inserted_at` (timestamp with time zone), `updated_at` (timestamp with time zone)
   - Enable extension `citext` for case-insensitive comparison

5. Create migration file `priv/repo/migrations/YYYYMMDDHHMMSS_create_users_auth_tables.exs` with the following schemas:

   - Table: `users` with columns: `id` (binary uuid, primary key), `email` (citext, not null, unique), `hashed_password` (string), `inserted_at` (timestamp with time zone), `updated_at` (timestamp with time zone)
   - Table: `users_tokens` with columns: `id` (binary uuid, primary key), `user_id` (binary uuid, references users on delete cascade), `token` (binary, not null), `context` (string, not null), `sent_to` (string), `inserted_at` (timestamp with time zone)
   - Index on `users_tokens(user_id)`
   - Unique index on `users_tokens(context, token)`

6. Create migration file `priv/repo/migrations/YYYYMMDDHHMMSS_create_user_org_memberships.exs` with the following schema:

   - Table: `user_org_memberships`
   - Columns: `id` (binary uuid, primary key), `user_id` (binary uuid, references users on delete cascade), `organization_id` (binary uuid, references organizations on delete cascade), `roles` (array of strings, default '{}'), `inserted_at` (timestamp with time zone), `updated_at` (timestamp with time zone)
   - Unique constraint on `(user_id, organization_id)`

7. Create migration file `priv/repo/migrations/YYYYMMDDHHMMSS_create_api_keys.exs` with the following schema:

   - Table: `api_keys`
   - Columns: `id` (binary uuid, primary key), `organization_id` (binary uuid, references organizations on delete cascade), `description` (string, not null), `roles` (array of strings, default '{}'), `version` (integer, default 1), `secret_hash` (binary, not null), `inserted_at` (timestamp with time zone), `updated_at` (timestamp with time zone)

8. Run `mix ecto.migrate` to apply all migrations.

### Phase 3: Core Authentication Modules

9. Create file `lib/gtfs_planner/accounts/user.ex` with the `GtfsPlanner.Accounts.User` schema:

   - Use Ecto.Schema with table `users`
   - Fields: `id`, `email`, `hashed_password`, `inserted_at`, `updated_at`
   - Virtual fields: `password`, `current_password` (redact: true)
   - Timestamps with type `:utc_datetime_usec`
   - Changeset functions: `changeset/2`, `registration_changeset/2`, `email_changeset/2`, `password_changeset/2`, `confirm_password_changeset/2`
   - Helper functions: `valid_password?/2`, `generate_user_password/1`, `maybe_hash_password/2`
   - Use Argon2 for password hashing and verification

10. Create file `lib/gtfs_planner/accounts/user_token.ex` with the `GtfsPlanner.Accounts.UserToken` schema:

    - Use Ecto.Schema with table `users_tokens`
    - Fields: `id`, `user_id`, `token`, `context`, `sent_to`, `inserted_at`
    - Belongs to `:user` with foreign key `:user_id`
    - Module attributes: `@rand_size`, `@session_validity_in_days`
    - Functions: `build_session_token/1`, `build_email_token/2`, `verify_session_token_query/1`, `verify_email_token_query/2`, `by_token_and_context_query/2`, `by_email_and_context_query/2`
    - Use `:crypto.strong_rand_bytes/1` for token generation
    - Hash tokens with `Base.encode64(token)`

11. Create file `lib/gtfs_planner/accounts/user_org_membership.ex` with the `GtfsPlanner.Accounts.UserOrgMembership` schema:

    - Use Ecto.Schema with table `user_org_memberships`
    - Fields: `id`, `user_id`, `organization_id`, `roles`, `inserted_at`, `updated_at`
    - Belongs to `:user` with foreign key `:user_id`
    - Belongs to `:organization` with foreign key `:organization_id`
    - Changeset function: `changeset/2`

12. Create file `lib/gtfs_planner/accounts.ex` with the `GtfsPlanner.Accounts` context module:

    - Import Ecto.Query for database queries
    - Public functions:
      - `get_user!/1`: Fetch user by ID or raise
      - `get_user_by_email/1`: Fetch user by email
      - `get_user_by_email_and_password/2`: Authenticate user
      - `register_user/1`: Create new user
      - `change_user_registration/2`: User registration changeset
      - `change_user_email/2`: Email update changeset
      - `apply_user_email/2`: Update user email
      - `update_user_password/2`: Update user password
      - `generate_user_session_token/1`: Create session token
      - `get_user_by_session_token/1`: Verify session token
      - `delete_session_token/2`: Delete session token
      - `deliver_user_confirmation_instructions/2`: Send confirmation email
      - `deliver_user_reset_password_instructions/2`: Send reset email
      - `get_user_by_reset_password_token/1`: Verify reset token
      - `reset_user_password/2`: Reset password
      - `invite_user/2`: Invite user to organization
      - `deliver_user_invite/2`: Send invitation email
      - `get_user_by_invite_token/1`: Verify invitation token
      - `accept_invite_set_password/2`: Set password on invite acceptance
    - Private helper functions for token validation, email generation, password hashing
    - Use Repo for all database operations
    - Return tagged tuples: `{:ok, result}` or `{:error, changeset}`

13. Create file `lib/gtfs_planner/accounts/user_notifier.ex` with the `GtfsPlanner.Accounts.UserNotifier` module:
    - Functions:
      - `deliver_confirmation_instructions/2`: Send email confirmation
      - `deliver_reset_password_instructions/2`: Send password reset email
      - `deliver_user_invite/2`: Send user invitation email
    - Use Swoosh for email sending
    - Create email templates for each type
    - Use `GtfsPlanner.Mailer` for delivery

### Phase 4: Organizations Context

14. Create file `lib/gtfs_planner/organizations/organization.ex` with the `GtfsPlanner.Organizations.Organization` schema:

    - Use Ecto.Schema with table `organizations`
    - Fields: `id`, `alias`, `name`, `inserted_at`, `updated_at`
    - Timestamps with type `:utc_datetime_usec`
    - Changeset function: `changeset/2`
    - Validate: `alias` presence and uniqueness, `name` presence

15. Create file `lib/gtfs_planner/organizations/api_key.ex` with the `GtfsPlanner.Organizations.ApiKey` schema:

    - Use Ecto.Schema with table `api_keys`
    - Fields: `id`, `organization_id`, `description`, `roles`, `version`, `secret_hash`, `inserted_at`, `updated_at`
    - Belongs to `:organization` with foreign key `:organization_id`
    - Module attributes: `@secret_size`, `@prefix`, `@hash_algorithm`
    - Changeset function: `changeset/2`
    - Functions: `build_hashed_token/2`, `hash_api_key/4`, `serialize_token/3`, `verify_token/2`
    - Use `:crypto.strong_rand_bytes/1` for secret generation
    - Use SHA3-512 for hashing

16. Create file `lib/gtfs_planner/organizations.ex` with the `GtfsPlanner.Organizations` context module:
    - Import Ecto.Query for database queries
    - Public functions:
      - `list_organizations/0`: List all organizations
      - `get_organization!/1`: Fetch organization by ID or raise
      - `get_organization_by_alias/1`: Fetch organization by alias
      - `create_organization/1`: Create new organization
      - `update_organization/2`: Update organization
      - `delete_organization/1`: Delete organization
      - `change_organization/2`: Organization changeset
      - `list_api_keys/1`: List API keys for organization
      - `get_api_key!/1`: Fetch API key by ID or raise
      - `get_api_key_by_token/1`: Validate API key token
      - `create_api_key/2`: Create new API key
      - `update_api_key/2`: Update API key
      - `delete_api_key/1`: Delete API key
      - `change_api_key/2`: API key changeset
      - `add_user_to_organization/3`: Add user with roles
      - `remove_user_from_organization/2`: Remove user from organization
      - `update_user_roles/3`: Update user roles in organization
      - `list_organizations_for_user/1`: List user's organizations
      - `list_users_in_organization/1`: List users in organization
    - Use Repo for all database operations
    - Return tagged tuples: `{:ok, result}` or `{:error, changeset}`
    - Use Phoenix.PubSub for broadcasting changes

### Phase 5: Web Authentication Layer

17. Create file `lib/gtfs_planner_web/user_auth.ex` with the `GtfsPlannerWeb.UserAuth` module:

    - Use Phoenix.Controller and LiveView
    - Functions:
      - `log_in_user/3`: Authenticate user, create session token, handle remember-me
      - `log_out_user/1`: Clear session, invalidate tokens, disconnect LiveView
      - `fetch_current_user/2`: Retrieve current user from session or cookie
      - `redirect_if_user_is_authenticated/2`: Plug to redirect authenticated users
      - `require_authenticated_user/2`: Plug to require authentication
      - `redirect_logged_out_user/2`: Plug to redirect unauthenticated users
      - `on_mount/4`: LiveView mount hooks for different scenarios
    - Mount hooks:
      - `:mount_current_user`: Assign current_user without auth requirement
      - `:ensure_authenticated`: Require authenticated user, redirect to login if not
      - `:redirect_if_user_is_authenticated`: Redirect authenticated users away from login
    - Session configuration: 60-day token expiry, optional remember-me with 60-day persistence
    - Session renewal on login to prevent fixation attacks
    - LiveView session tracking with registry for disconnection

18. Create file `lib/gtfs_planner_web/api_key_auth.ex` with the `GtfsPlannerWeb.ApiKeyAuth` module:

    - Use Plug.Conn
    - Functions:
      - `fetch_current_api_key/2`: Extract and validate API key from Authorization header
      - `require_authenticated_api_key/2`: Plug to require API key authentication
    - Authentication methods:
      - RFC 6750 compliant: `Authorization: Bearer GtfsPlanner.V1.abcdefg`
      - Compatibility mode: `Authorization: GtfsPlanner.V1.abcdefg`
    - Security features:
      - Constant-time token comparison using `Plug.Crypto.secure_compare`
      - Random delay (500-800ms) on failed authentication via `Process.sleep/1`
      - Return 401 Unauthorized with error JSON for missing/invalid tokens
    - Use `Organizations.get_api_key_by_token/1` for validation

19. Create file `lib/gtfs_planner_web/ensure_role.ex` with the `GtfsPlannerWeb.EnsureRole` module:

    - Provide role-based authorization for users and API keys
    - Functions:
      - `on_mount/4`: LiveView mount hook for client-side authorization
      - `ensure_role/2`: Plug for server-side authorization
    - Role specifications:
      - Single role: `:administrator`
      - Any membership: `nil` (requires org membership but no specific role)
      - Any role in list: `any: [:role1, :role2]`
      - All roles in list: `all: [:role1, :role2]`
    - Private helper functions: `roles_match_spec/2`, `has_role?/3`
    - Handle authorization by redirecting or returning 403 Unauthorized

20. Create file `lib/gtfs_planner_web/assign_organization.ex` with the `GtfsPlannerWeb.AssignOrganization` plug:
    - Use Plug.Conn
    - Function: `call/2` assigns organization from URL parameter
    - Extract `org_alias` from connection params
    - Fetch organization via `Organizations.get_organization_by_alias/1`
    - Assign `:current_organization` to connection if found
    - Return 404 Not Found if organization doesn't exist

### Phase 6: Router Configuration

21. Update `lib/gtfs_planner_web/router.ex` to import authentication helpers:

    - Add `import GtfsPlannerWeb.UserAuth` at top of router module
    - Add `import GtfsPlannerWeb.ApiKeyAuth` at top of router module

22. Add authentication pipelines to router:

    - `:browser` pipeline: Add `:fetch_current_user` plug to existing pipeline
    - `:redirect_if_user_is_authenticated` pipeline: Add after :browser with `:redirect_if_user_is_authenticated` plug
    - `:require_authenticated_user` pipeline: Add after :browser with `:require_authenticated_user` plug
    - `:api` pipeline: Create new pipeline with `:accepts, ["json"]`, `:fetch_current_api_key` plugs
    - `:api_organization` pipeline: Add after :api with `GtfsPlannerWeb.AssignOrganization` plug

23. Add authentication routes to router:

    - Scope "/" with `pipe_through [:browser, :redirect_if_user_is_authenticated]`
    - Live session `:redirect_if_user_is_authenticated` with `on_mount: [{GtfsPlannerWeb.UserAuth, :redirect_if_user_is_authenticated}]`
    - Routes:
      - `live "/users/log_in", UserLoginLive, :new`
      - `live "/users/reset_password", UserForgotPasswordLive, :new`
      - `live "/users/reset_password/:token", UserResetPasswordLive, :edit`
      - `live "/users/accept_invite/:token", UserAcceptInviteLive, :edit`

24. Add authenticated user routes to router:

    - Scope "/" with `pipe_through [:browser, :require_authenticated_user]`
    - Live session `:require_authenticated_user` with `on_mount: [{GtfsPlannerWeb.UserAuth, :ensure_authenticated}]`
    - Routes:
      - `live "/users/settings", UserSettingsLive, :edit`
      - `live "/organizations", OrganizationsListLive, :index`

25. Add organization-scoped routes to router:
    - Scope "/organizations/:org_alias" with `pipe_through [:browser, :require_authenticated_user]`
    - Live session `:require_authenticated_user_and_org` with `on_mount: [{GtfsPlannerWeb.UserAuth, :ensure_authenticated}, GtfsPlannerWeb.AssignOrganization]`
    - Routes for organization-specific features

### Phase 7: Controllers and LiveViews

26. Create file `lib/gtfs_planner_web/controllers/user_session_controller.ex` with `GtfsPlannerWeb.UserSessionController`:

    - Use `GtfsPlannerWeb, :controller`
    - Plug `:fetch_current_user` for login route
    - Actions:
      - `new/2`: Render login form, redirect if already authenticated
      - `create/2`: Process login, validate credentials, create session, redirect on success
      - `delete/2`: Logout user, clear session, redirect to login page
    - Use `Accounts.get_user_by_email_and_password/2` for authentication
    - Use `UserAuth.log_in_user/3` for session creation
    - Use `UserAuth.log_out_user/1` for logout

27. Create file `lib/gtfs_planner_web/live/user_login_live.ex` with `GtfsPlannerWeb.UserLoginLive`:

    - Use `GtfsPlannerWeb, :live_view`
    - Mount hook: `{GtfsPlannerWeb.UserAuth, :redirect_if_user_is_authenticated}`
    - Assigns: `form` (changeset for login form)
    - Handle params: `:new` action for login form
    - Handle event: `"save"` for form submission
    - Use `to_form/2` for form creation
    - Redirect to `signed_in_path` on successful login
    - Display error messages on failed authentication

28. Create file `lib/gtfs_planner_web/live/user_settings_live.ex` with `GtfsPlannerWeb.UserSettingsLive`:

    - Use `GtfsPlannerWeb, :live_view`
    - Mount hook: `{GtfsPlannerWeb.UserAuth, :ensure_authenticated}`
    - Assigns: `current_user`, `email_form`, `password_form`, `trigger_submit`
    - Handle params: `:edit` action for settings page
    - Handle events:
      - `"validate_email"` for email changeset validation
      - `"update_email"` for email update with confirmation
      - `"validate_password"` for password changeset validation
      - `"update_password"` for password update with current password verification
    - Use `Accounts.apply_user_email/2` for email update
    - Use `Accounts.update_user_password/2` for password update
    - Display success/error messages

29. Create file `lib/gtfs_planner_web/live/user_forgot_password_live.ex` with `GtfsPlannerWeb.UserForgotPasswordLive`:

    - Use `GtfsPlannerWeb, :live_view`
    - Mount hook: `{GtfsPlannerWeb.UserAuth, :redirect_if_user_is_authenticated}`
    - Assigns: `form` (changeset for email input)
    - Handle params: `:new` action for forgot password form
    - Handle event: `"send_instructions"` for sending reset email
    - Use `Accounts.deliver_user_reset_password_instructions/2` to send email
    - Display success message regardless of whether email exists (security)

30. Create file `lib/gtfs_planner_web/live/user_reset_password_live.ex` with `GtfsPlannerWeb.UserResetPasswordLive`:

    - Use `GtfsPlannerWeb, :live_view`
    - Mount hook: `{GtfsPlannerWeb.UserAuth, :redirect_if_user_is_authenticated}`
    - Assigns: `form` (changeset for password reset), `token`
    - Handle params: `:edit` action with token from URL
    - Handle event: `"reset_password"` for password reset
    - Validate token via `Accounts.get_user_by_reset_password_token/1`
    - Use `Accounts.reset_user_password/2` to update password
    - Redirect to login page on success

31. Create file `lib/gtfs_planner_web/live/user_accept_invite_live.ex` with `GtfsPlannerWeb.UserAcceptInviteLive`:

    - Use `GtfsPlannerWeb, :live_view`
    - Mount hook: `{GtfsPlannerWeb.UserAuth, :redirect_if_user_is_authenticated}`
    - Assigns: `form` (changeset for password setup), `token`, `user`
    - Handle params: `:edit` action with token from URL
    - Handle event: `"accept_invite"` for setting initial password
    - Validate token via `Accounts.get_user_by_invite_token/1`
    - Use `Accounts.accept_invite_set_password/2` to set password and create membership
    - Redirect to login page on success

32. Create file `lib/gtfs_planner_web/live/manage_users_live.ex` with `GtfsPlannerWeb.ManageUsersLive`:

    - Use `GtfsPlannerWeb, :live_view`
    - Mount hook: `[{GtfsPlannerWeb.UserAuth, :ensure_authenticated}, GtfsPlannerWeb.EnsureRole]`
    - Assigns: `organization`, `users` (stream), `invite_form`
    - Handle params: `:edit` action for user management
    - Handle events:
      - `"invite_user"` for inviting new user by email
      - `"remove_user"` for removing user from organization
      - `"update_roles"` for updating user roles
    - Use `Accounts.invite_user/2` for invitations
    - Use `Organizations.add_user_to_organization/3` for membership
    - Use streams for user list display

33. Create file `lib/gtfs_planner_web/live/api_key_live.ex` with `GtfsPlannerWeb.ApiKeyLive`:
    - Use `GtfsPlannerWeb, :live_view`
    - Mount hook: `[{GtfsPlannerWeb.UserAuth, :ensure_authenticated}, GtfsPlannerWeb.EnsureRole]`
    - Assigns: `organization`, `api_keys` (stream), `form`
    - Handle params: `:edit` action for API key management
    - Handle events:
      - `"create"` for creating new API key
      - `"delete"` for deleting API key
    - Use `Organizations.create_api_key/2` for key creation
    - Display API key token once after creation
    - Use streams for API key list display

### Phase 8: Email Templates

34. Create directory `lib/gtfs_planner/accounts/emails/` for email templates.

35. Create file `lib/gtfs_planner/accounts/emails/user_invite_email.ex` with `GtfsPlanner.Accounts.Emails.UserInviteEmail`:

    - Use Swoosh.Email
    - Function: `deliver/2` with user and invite URL parameters
    - Subject: "You're invited to join GTFS Planner"
    - HTML body with invitation link
    - Text body with invitation link
    - Configure sender address and name

36. Create file `lib/gtfs_planner/accounts/emails/reset_password_email.ex` with `GtfsPlanner.Accounts.Emails.ResetPasswordEmail`:

    - Use Swoosh.Email
    - Function: `deliver/2` with user and reset URL parameters
    - Subject: "Reset your GTFS Planner password"
    - HTML body with reset password link
    - Text body with reset password link
    - Configure sender address and name

37. Create file `lib/gtfs_planner/accounts/emails/email_confirmation_email.ex` with `GtfsPlanner.Accounts.Emails.EmailConfirmationEmail`:
    - Use Swoosh.Email
    - Function: `deliver/2` with user and confirmation URL parameters
    - Subject: "Confirm your GTFS Planner email"
    - HTML body with confirmation link
    - Text body with confirmation link
    - Configure sender address and name

### Phase 9: Application Integration

38. Update `lib/gtfs_planner/application.ex` to include authentication in supervision tree:

    - Add `GtfsPlanner.Repo` if not present
    - Add `GtfsPlannerWeb.Endpoint` if not present
    - Add `{Phoenix.PubSub, name: GtfsPlanner.PubSub}` if not present

39. Update `lib/gtfs_planner_web.ex` to include authentication imports and aliases:

    - In `html_helpers` function, add `import GtfsPlannerWeb.UserAuth`
    - Add `alias GtfsPlanner.Accounts`
    - Add `alias GtfsPlanner.Organizations`

40. Update `config/config.exs` with authentication configuration:
    - Configure secret_key_base if not already set
    - Configure session encryption and signing
    - Configure Swoosh mailer adapter

### Phase 10: Testing

41. Create test file `test/gtfs_planner/accounts_test.exs` for Accounts context tests:

    - Use `GtfsPlanner.DataCase`
    - Tests for:
      - User registration
      - User authentication
      - Email updates
      - Password updates
      - Session token generation and validation
      - Password reset flow
      - User invitation flow
    - Use fixtures for test data creation

42. Create test file `test/gtfs_planner/organizations_test.exs` for Organizations context tests:

    - Use `GtfsPlanner.DataCase`
    - Tests for:
      - Organization CRUD operations
      - API key generation and validation
      - User membership management
      - Role updates
    - Use fixtures for test data creation

43. Create test file `test/gtfs_planner_web/user_auth_test.exs` for authentication tests:

    - Use `GtfsPlannerWeb.ConnCase`
    - Tests for:
      - Login/logout flow
      - Session token validation
      - Remember-me functionality
      - Protected route access
      - Redirection logic

44. Create test file `test/gtfs_planner_web/api_key_auth_test.exs` for API key authentication tests:

    - Use `GtfsPlannerWeb.ConnCase`
    - Tests for:
      - Valid API key authentication
      - Invalid API key rejection
      - Missing header handling
      - Constant-time comparison
      - Random delay on failures

45. Create test file `test/support/fixtures/accounts_fixtures.ex` for account fixtures:

    - Define `:user` fixture
    - Define `:user_token` fixture
    - Define `:user_org_membership` fixture
    - Define `:valid_user_password` attribute
    - Define `:valid_user_email` attribute

46. Create test file `test/support/fixtures/organizations_fixtures.ex` for organization fixtures:
    - Define `:organization` fixture
    - Define `:api_key` fixture
    - Define `:valid_organization_alias` attribute
    - Define `:valid_organization_name` attribute

### Phase 11: Documentation

47. Create file `docs/authentication-guide.md` with authentication system documentation:

    - Overview of authentication architecture
    - User authentication flows
    - API key authentication flows
    - Role-based authorization
    - Multi-tenant organization management
    - Security features and best practices
    - Usage examples for developers

48. Update `README.md` with authentication section:

    - Describe authentication system
    - Document API authentication
    - Provide usage examples
    - Link to detailed documentation

49. Create file `docs/api-authentication.md` with API authentication documentation:

    - API key creation
    - Bearer token format
    - Authentication header format
    - Error responses
    - Organization scoping
    - Role-based access

50. Create file `docs/user-management.md` with user management documentation:
    - User invitation process
    - User registration flow
    - Password reset flow
    - Role management
    - Organization membership
    - Email configuration
