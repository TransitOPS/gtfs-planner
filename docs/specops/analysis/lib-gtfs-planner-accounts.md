# SpecOps Analysis: lib-gtfs-planner-accounts (Accounts Context)

**Target:** `lib/gtfs_planner/accounts`  
**Source hash:** `b8865893f1df3f41936e7008f0463913ad6ffa5568508d9fbffcdbb224a1d004`  
**Date:** 2026-06-26  
**Structural unit:** `lib/gtfs_planner/accounts/**`

---

## 1. Overview

The Accounts context is the identity and authentication subsystem for the Pathways Studio multi-tenant GTFS planning application. It manages user lifecycle (registration, confirmation, password reset, invitation), session tokens (web and API), organization memberships with role-based authorization, and email notifications.

The context is implemented as an Ecto-based Phoenix context module (`GtfsPlanner.Accounts`) backed by three Ecto schemas (`User`, `UserToken`, `UserOrgMembership`), a notifier module, three polished email template modules, and shared changeset helpers.

**Key design characteristics:**
- Case-insensitive emails via PostgreSQL `citext` extension at the database layer, with application-level downcasing
- Password hashing with Argon2, minimum 12 characters
- Token-based authentication with SHA-256 hashed tokens stored as binary
- Context-isolated token types (session, api_session, confirm, reset_password, invite, change:<email>)
- Soft-delete for organization memberships via `deactivated_at`
- Multi-step transactional operations via `Ecto.Multi`
- Two parallel email implementations: `UserNotifier` (simple inline HTML) and dedicated email modules (polished HTML+text with Swoosh)

---

## 2. Files

| File | Role |
|------|------|
| `lib/gtfs_planner/accounts.ex` | Context module: all public business logic for user lifecycle, sessions, invites, memberships |
| `lib/gtfs_planner/accounts/user.ex` | Ecto schema and changesets for the `users` table |
| `lib/gtfs_planner/accounts/user_token.ex` | Ecto schema and token generation/verification logic for the `users_tokens` table |
| `lib/gtfs_planner/accounts/user_notifier.ex` | Email delivery for confirmation, email update, password reset, and invite (simple HTML) |
| `lib/gtfs_planner/accounts/user_org_membership.ex` | Ecto schema and changeset for `user_org_memberships` |
| `lib/gtfs_planner/accounts/emails/email_confirmation_email.ex` | Polished HTML+text email for email confirmation (Swoosh) |
| `lib/gtfs_planner/accounts/emails/reset_password_email.ex` | Polished HTML+text email for password reset (Swoosh) |
| `lib/gtfs_planner/accounts/emails/user_invite_email.ex` | Polished HTML+text email for user invitation (Swoosh) |
| `test/gtfs_planner/accounts_test.exs` | Integration tests for the Accounts context module |
| `test/gtfs_planner/accounts/user_token_test.exs` | Unit tests for the UserToken schema |
| `test/support/fixtures/accounts_fixtures.ex` | Test fixtures and helpers |
| `priv/repo/migrations/20251223034104_create_users_auth_tables.exs` | Migration: `users` and `users_tokens` tables |
| `priv/repo/migrations/20251223034106_create_user_org_memberships.exs` | Migration: `user_org_memberships` table |
| `priv/repo/migrations/20260120062625_add_deactivated_at_to_user_org_memberships.exs` | Migration: soft-delete column for memberships |
| `lib/gtfs_planner/changeset_helpers.ex` | Shared string trimming helper used by User changesets |
| `lib/gtfs_planner/authorization/roles.ex` | Canonical role definitions and validation (used by UserOrgMembership) |

---

## 3. Database Schema

### Table: `users`
| Column | Type | Constraints |
|------|------|------|
| `id` | `binary_id` (UUID) | PRIMARY KEY |
| `email` | `citext` | NOT NULL, UNIQUE INDEX |
| `hashed_password` | `string` | nullable (invited users have no password) |
| `confirmed_at` | `naive_datetime` | nullable |
| `inserted_at` | `utc_datetime_usec` | NOT NULL |
| `updated_at` | `utc_datetime_usec` | NOT NULL |

### Table: `users_tokens`
| Column | Type | Constraints |
|------|------|------|
| `id` | `binary_id` (UUID) | PRIMARY KEY |
| `user_id` | `binary_id` (FK → users) | NOT NULL, ON DELETE CASCADE |
| `token` | `binary` | NOT NULL, UNIQUE INDEX (with context) |
| `context` | `string` | NOT NULL, UNIQUE INDEX (with token) |
| `sent_to` | `string` | nullable |
| `inserted_at` | `utc_datetime_usec` | NOT NULL |

Indexes: `(user_id)`, unique `(context, token)`.

### Table: `user_org_memberships`
| Column | Type | Constraints |
|------|------|------|
| `id` | `binary_id` (UUID) | PRIMARY KEY |
| `user_id` | `binary_id` (FK → users) | NOT NULL, ON DELETE CASCADE |
| `organization_id` | `binary_id` (FK → organizations) | NOT NULL, ON DELETE CASCADE |
| `roles` | `array(string)` | DEFAULT `[]` |
| `deactivated_at` | `utc_datetime` | nullable |
| `inserted_at` | `utc_datetime_usec` | NOT NULL |
| `updated_at` | `utc_datetime_usec` | NOT NULL |

Indexes: unique `(user_id, organization_id)`, `(organization_id, deactivated_at)`.

---

## 4. User Lifecycle

### 4.1 Registration

**Entry point:** `Accounts.register_user/1`

1. Accepts a map with `:email` and `:password`.
2. Email is trimmed of whitespace; password whitespace is preserved.
3. Email is validated: required, format `~r/^[^\s]+@[^\s]+$/`, max 160 chars, unique (unsafe validation + unique constraint).
4. Password is validated: required, 12–72 characters.
5. Password is hashed with Argon2 via `Argon2.hash_pwd_salt/1`.
6. User is inserted into the database with `confirmed_at: nil`.
7. Returns `{:ok, %User{}}` on success or `{:error, %Ecto.Changeset{}}` on failure.

**First administrator registration:** `Accounts.register_first_admin/2`
- Creates a user, organization, default GTFS version, and membership atomically.
- Membership is created with the `"administrator"` role (system-level).
- User is immediately confirmed (no email confirmation flow).
- All operations execute in a single `Ecto.Multi` transaction.

### 4.2 Email Confirmation

**Entry points:** `Accounts.deliver_user_confirmation_instructions/2`, `Accounts.confirm_user/1`

1. A confirmation email is sent with a 7-day token (context: `"confirm"`).
2. If the user is already confirmed (`confirmed_at` is set), delivery returns `{:error, :already_confirmed}`.
3. The user clicks the confirmation link; `confirm_user/1` verifies the token.
4. On success: `confirmed_at` is set to current time, the confirm token is deleted.
5. On failure (expired, invalid, or user not found): returns `:error`.

### 4.3 Email Change

**Entry points:** `Accounts.apply_user_email/3`, `Accounts.deliver_user_update_email_instructions/3`, `Accounts.update_user_email/2`

1. `apply_user_email/3` validates the new email and current password (without persisting).
2. `deliver_user_update_email_instructions/3` creates a token with context `"change:<current_email>"` (7-day expiry) and sends it to the *new* email address (note: the token's `sent_to` is the user's current email, but the email is delivered to `user.email` which may have been updated in memory).
3. `update_user_email/2` uses `verify_change_email_token_query` to find the token, then in a transaction: applies the `sent_to` email from the token record to the user and confirms the user.
4. The token is deleted after successful use.

### 4.4 Password Change

**Entry point:** `Accounts.update_user_password/3`

1. Validates new password (12-72 chars, confirmation match) and current password.
2. On success: updates the password hash **and deletes all tokens** for the user (including sessions, API sessions, email tokens), effectively logging the user out of all devices and invalidating all pending email operations.
3. This is a transaction: `Ecto.Multi.update(:user, ...)` + `Ecto.Multi.delete_all(:tokens, ...)`.

### 4.5 Password Reset

**Entry points:** `Accounts.deliver_user_reset_password_instructions/2`, `Accounts.get_user_by_reset_password_token/1`, `Accounts.reset_user_password/2`

1. A reset email is sent with a 1-day token (context: `"reset_password"`).
2. Token validation via `verify_email_token_query` with `days_for_context("reset_password") == 1`.
3. `reset_user_password/2` in a transaction: updates password, confirms the user (sets `confirmed_at`), and deletes all tokens.
4. Password reset always confirms the account (first-time users who were invited can also use this flow).

### 4.6 Invitation

**Entry points:** `Accounts.invite_user/2`, `Accounts.deliver_user_invite/2`, `Accounts.resend_user_invite/2`, `Accounts.get_user_by_invite_token/1`, `Accounts.accept_invite_set_password/2`

1. `invite_user/2`:
   - Downcases email.
   - If user exists by email: returns `{:ok, existing_user}` (idempotent, does not create duplicate).
   - If user does not exist: creates a new user record with only email (no password, no confirmation). Note: `_organization_id` parameter is accepted but not used in user creation; it is documented but the implementation ignores it.

2. `deliver_user_invite/2`: Creates a token with context `"invite"` (7-day expiry) and sends the invite email.

3. `resend_user_invite/2`:
   - If the user has a `hashed_password` set: returns `{:error, :already_accepted}`.
   - Otherwise: calls `deliver_user_invite/2` (creates a new token, new email).

4. `accept_invite_set_password/2`:
   - In a transaction:
     - Sets password (validates, hashes), confirms user (sets `confirmed_at`).
     - Deletes all invite tokens for the user.
     - If `organization_id` is present in attrs (string or atom key): creates a `UserOrgMembership` with the `"pathways_studio_editor"` role (note: doc says "default viewer role" but code uses `pathways_studio_editor`).
   - The membership insertion can fail independently, returning `{:error, changeset}` for membership errors.

### 4.7 Membership Deactivation (Soft-Delete)

**Behavior:**
- Memberships can be soft-deleted by setting `deactivated_at` to a timestamp.
- `Accounts.list_user_org_memberships/1` **excludes** deactivated memberships (filters `is_nil(m.deactivated_at)`).
- `Accounts.list_user_org_memberships_including_deactivated/1` returns all memberships regardless of `deactivated_at`.
- `Accounts.get_user_org_membership/2` returns a membership even if deactivated (no filter on `deactivated_at`).
- `Accounts.delete_user_org_membership/1` performs a hard delete via `Repo.delete/1`.
- There is no dedicated "deactivate" or "reactivate" function in the accounts context. Deactivation is done externally by setting `deactivated_at` via an update changeset.

---

## 5. Token System

### 5.1 Token Generation

All tokens are generated uniformly:
1. 32 bytes of cryptographically secure random data via `:crypto.strong_rand_bytes(32)`.
2. Base64 URL-encoded (no padding) for transport to the user.
3. SHA-256 hashed for storage in the `token` binary column.

### 5.2 Token Contexts and Expiry

| Context | Purpose | Expiry | Stored in `sent_to` |
|------|------|------|------|
| `"session"` | Web browser session | 60 days | `nil` |
| `"api_session"` | API authentication session | 60 days | `nil` |
| `"confirm"` | Email confirmation | 7 days | `user.email` |
| `"reset_password"` | Password reset | 1 day | `user.email` |
| `"invite"` | User invitation | 7 days | `user.email` |
| `"change:<email>"` | Email change confirmation | 7 days | current email at token creation |

### 5.3 Token Verification

- **Session tokens** (`verify_session_token_query/1`): Decodes base64, hashes with SHA-256, queries `users_tokens` where context="session" and `inserted_at > 60 days ago`, joins to user.
- **API session tokens** (`verify_api_session_token_query/1`): Same but context="api_session". Context isolation: a valid web session token will NOT match api_session context.
- **Email tokens** (`verify_email_token_query/2`): Generic verifier for any context. Looks up by hashed token + context, joins to user, checks `inserted_at > days_for_context(context)`.
- **Email change tokens** (`verify_change_email_token_query/2`): Like email tokens but returns the token record (not joined to user) — used to retrieve the `sent_to` email.
- **`valid_token?/2`**: Existence check only (no expiry, no user join). Not used by the main Accounts context (appears to be a utility for external callers).

### 5.4 Token Deletion Semantics

| Operation | Tokens Affected |
|------|------|
| Password change (`update_user_password`) | ALL tokens (contexts: all) |
| Password reset (`reset_user_password`) | ALL tokens (contexts: all) |
| Session logout (`delete_session_token`) | Single session token by value |
| API session logout (`delete_api_session_token`) | Single API session token by value |
| User deactivation (`delete_user_sessions`) | All "session" and "api_session" tokens |
| Invite acceptance | Only "invite" context tokens |
| Email confirmation (`confirm_user`) | Only "confirm" context tokens |
| Email change (`update_user_email`) | Single token record deleted |

---

## 6. Organization Membership System

### 6.1 Membership Lifecycle

1. **Creation:** Via `create_user_org_membership/1`, `accept_invite_set_password/2`, or `register_first_admin/2`.
2. **Roles validation:** Roles must be valid according to `GtfsPlanner.Authorization.Roles`. Invalid roles cause a changeset error.
3. **Uniqueness:** A user can only have one membership per organization (unique constraint on `[user_id, organization_id]`).
4. **Update:** Via `update_user_org_membership/2` (roles update).
5. **Deactivation (soft-delete):** Setting `deactivated_at` (done externally, not via a dedicated context function).
6. **Hard delete:** Via `delete_user_org_membership/1` (`Repo.delete/1`).

### 6.2 Canonical Roles

Defined in `GtfsPlanner.Authorization.Roles`:

| Role | Scope | Description |
|------|------|------|
| `administrator` | `:system` | Manages organizations (tenants) in the multi-tenant system |
| `pathways_studio_admin` | `:organization` | Manages users within their organization |
| `pathways_studio_editor` | `:organization` | Full access to view and modify GTFS data |

- Role validation accepts both atoms and strings.
- `String.to_existing_atom/1` is used (safe, avoids atom table leaks).

### 6.3 Quirks and Observations

- `invite_user/2` accepts an `organization_id` parameter but **does not create a membership**. The membership is only created later during `accept_invite_set_password/2`.
- The `list_user_org_memberships/1` query filters `is_nil(m.deactivated_at)` at the query level (Ecto), not at the schema level.
- There is no bulk operation for deactivating/reactivating memberships.
- `get_user_org_membership/2` does NOT filter out deactivated memberships, so callers must check `deactivated_at` themselves if needed.

---

## 7. Email Notification System

### 7.1 Dual Email Implementations

The codebase has **two parallel email implementations** for the same notification types:

**UserNotifier** (`lib/gtfs_planner/accounts/user_notifier.ex`):
- Simple inline HTML strings (no CSS styling, no text alternative).
- Used by the `Accounts` context for `deliver_confirmation_instructions`, `deliver_update_email_instructions`, `deliver_reset_password_instructions`, `deliver_user_invite`.
- From: `"no-reply@{mail_domain}"` (configurable domain).

**Dedicated email modules** (`lib/gtfs_planner/accounts/emails/`):
- `EmailConfirmationEmail`, `ResetPasswordEmail`, `UserInviteEmail`.
- Full HTML+text multipart emails with CSS styling, responsive design, branded buttons.
- From: `"no-reply@{mail_domain}"` (same sender).
- All three use Swoosh directly (`GtfsPlanner.Mailer`).
- Text alternatives claim "24 hours" expiry for confirmation and reset links, but actual token expiry is 7 days (confirm) and 1 day (reset).
- There is NO `update_email` equivalent in the dedicated email modules.

**Ambiguity:** It's unclear which email implementation is canonical. `UserNotifier` is the one actually wired into the `Accounts` context. The dedicated email modules (`Emails.*`) appear to be newer, more polished replacements that may not be fully integrated. The `UserNotifier` module's `deliver_user_invite` logs the invite URL to Logger (potential security concern).

### 7.2 Email Content Discrepancies

| Aspect | UserNotifier | Dedicated Email Modules |
|------|------|------|
| Confirmation expiry stated | Not stated | "24 hours" (actual: 7 days) |
| Password reset expiry stated | Not stated | "24 hours" (actual: 1 day) |
| Invite expiry stated | Not stated | "7 days" (correct) |
| HTML styling | None | Full CSS |
| Text alternative | None | Yes |
| Logger for invites | Yes (`Logger.info`) | No |

---

## 8. Password and Security Rules

### 8.1 Password Policy

- **Minimum length:** 12 characters
- **Maximum length:** 72 characters (bcrypt/Argon2 limit)
- **Format:** No restrictions other than length (allows spaces, unicode, etc.)
- **Hashing:** Argon2 via `Argon2.hash_pwd_salt/1`
- **Confirmation:** Required on password change and reset (must match `password_confirmation` field)
- **Current password verification:** Required for password change and email change

### 8.2 Security Behaviors

- **Timing attack mitigation:** `valid_password?/2` calls `Argon2.no_user_verify()` when the user has no password (invited users), preventing user enumeration via timing.
- **Token hashing:** Tokens are SHA-256 hashed before storage; the raw token only exists in transport.
- **Full logout on password change:** All tokens (sessions + email tokens) are deleted when password changes.
- **Full logout on password reset:** Same behavior — all tokens deleted.
- **Email uniqueness:** Enforced at database level via `citext` + unique constraint, and at application level via `unsafe_validate_unique`.
- **No account lockout:** There is no brute-force protection (no login attempt tracking, no rate limiting in this context).
- **No email verification for password reset:** Any user (including unconfirmed) can receive a password reset email.

---

## 9. API Session Token System

### 9.1 Design

API session tokens are a separate token context (`"api_session"`) with the same 60-day validity as web session tokens. They are context-isolated: a web session token (`"session"`) cannot authenticate API requests, and vice versa.

### 9.2 Operations

| Operation | Function |
|------|------|
| Generate | `Accounts.generate_api_session_token/1` |
| Verify | `Accounts.get_user_by_api_session_token/1` |
| Delete one | `Accounts.delete_api_session_token/1` |
| Delete all for user | `Accounts.delete_api_session_tokens/1` |

### 9.3 Distinctness from Web Sessions

- Separate generation: `build_api_session_token/1` vs `build_session_token/1` (only difference is the context string).
- Separate verification: `verify_api_session_token_query/1` vs `verify_session_token_query/1`.
- `delete_user_sessions/1` deletes BOTH session and api_session contexts (intended for user deactivation).
- `delete_api_session_tokens/1` deletes ONLY api_session tokens (leaving web sessions intact).

---

## 10. Data Integrity and Constraints

### 10.1 Database-Level Constraints

| Table | Constraint | Type |
|------|------|------|
| `users` | `email` NOT NULL | Column |
| `users` | UNIQUE(`email`) | Index |
| `users_tokens` | `user_id` NOT NULL, FK → users ON DELETE CASCADE | Column |
| `users_tokens` | `token` NOT NULL | Column |
| `users_tokens` | `context` NOT NULL | Column |
| `users_tokens` | UNIQUE(`context`, `token`) | Index |
| `user_org_memberships` | `user_id` NOT NULL, FK → users ON DELETE CASCADE | Column |
| `user_org_memberships` | `organization_id` NOT NULL, FK → organizations ON DELETE CASCADE | Column |
| `user_org_memberships` | UNIQUE(`user_id`, `organization_id`) | Index |

### 10.2 Application-Level Validations

| Field | Validation | Module |
|------|------|------|
| `email` | Required, format `~r/^[^\s]+@[^\s]+$/`, max 160 chars, unique | `User` |
| `password` | Required, 12–72 chars, confirmation match | `User` |
| `current_password` | Required, must match stored hash | `User` |
| `roles` (membership) | Must be valid canonical roles | `UserOrgMembership` |
| `user_id` (membership) | Required | `UserOrgMembership` |
| `organization_id` (membership) | Required | `UserOrgMembership` |

### 10.3 Cascading Deletes

- Deleting a user cascades to delete all their tokens (`users_tokens.user_id ON DELETE CASCADE`) and all their memberships (`user_org_memberships.user_id ON DELETE CASCADE`).
- Deleting an organization cascades to delete all memberships for that org (`user_org_memberships.organization_id ON DELETE CASCADE`).

---

## 11. Dependencies and Boundaries

### 11.1 Internal Dependencies (within Accounts)

```
Accounts (context)
├── User (schema)
│   ├── ChangesetHelpers (trim_string_fields)
│   └── Argon2 (password hashing)
├── UserToken (schema + token logic)
│   └── :crypto (random bytes, SHA-256)
├── UserOrgMembership (schema)
│   └── GtfsPlanner.Authorization.Roles (role validation)
├── UserNotifier (simple emails)
│   └── Swoosh.Email + GtfsPlanner.Mailer
└── Emails.* (polished emails, NOT wired into context)
    └── Swoosh.Email + GtfsPlanner.Mailer
```

### 11.2 External Dependencies

| Dependency | Module | Usage |
|------|------|------|
| Organizations | `GtfsPlanner.Organizations.Organization` | Schema reference in `UserOrgMembership`; `Organization.changeset` in `register_first_admin` |
| Versions | `GtfsPlanner.Versions` | `create_default_version/1` in first admin registration |
| Authorization | `GtfsPlanner.Authorization.Roles` | Role validation for memberships |
| Repo | `GtfsPlanner.Repo` | All database operations |
| Mailer | `GtfsPlanner.Mailer` | Email delivery |
| Argon2 | `Argon2` | Password hashing and verification |
| Swoosh | `Swoosh.Email` | Email composition |
| Configuration | `Application.get_env(:gtfs_planner, :mail_domain)` | Mail domain for from addresses |

### 11.3 Callers (who depends on Accounts)

Based on the codebase structure:
- Phoenix authentication plugs (session verification)
- API authentication pipeline (api_session verification)
- LiveView modules for settings, registration, login, invitation flows
- The `register_first_admin/2` function is a bootstrap entry point

---

## Evidence

### Evidence: User Schema
- **File:** `lib/gtfs_planner/accounts/user.ex`
- **Key facts:**
  - UUID primary keys (line 20)
  - Email is `:string` in Ecto schema, `citext` in PostgreSQL (line 23)
  - Password is virtual field, hashed_password is persisted (lines 24-25)
  - confirmed_at is naive_datetime (line 27)
  - Has `has_many :tokens` and `has_many :memberships` (lines 29-30)
  - 6 changeset functions: registration, email, password, confirm_password, confirm, invite (lines 38-101)
  - Email validation: required, format regex, max 160, unsafe_unique + unique_constraint (lines 130-137)
  - Password validation: required, 12-72 chars, Argon2 hashing (lines 139-157)
  - Password verification uses Argon2.verify_pass and Argon2.no_user_verify for non-existent passwords (lines 186-194)

### Evidence: UserToken Schema
- **File:** `lib/gtfs_planner/accounts/user_token.ex`
- **Key facts:**
  - 32 random bytes per token (line 16)
  - SHA-256 hashing for storage (line 39, 53, 77)
  - Base64 URL-encode for transport (line 41, 55, 79)
  - 6 context types: session (60d), api_session (60d), confirm (7d), reset_password (1d), invite (7d), change:<email> (7d)
  - Token expiry via `days_for_context/1` (lines 168-172)
  - `valid_token?/2` exists but is not used by Accounts context (line 177)
  - Deletion functions: `delete_user_token/2` (by context), `delete_session_tokens/1`, `delete_user_tokens/1` (lines 228-251)

### Evidence: Accounts Context
- **File:** `lib/gtfs_planner/accounts.ex`
- **Key facts:**
  - `register_user/1`: Insert with registration_changeset (line 93-97)
  - `invite_user/2`: Idempotent creation — returns existing user if found, creates new if not; `organization_id` parameter documented but unused in user creation (lines 469-481)
  - `resend_user_invite/2`: Guards against re-inviting users who have already set a password via `hashed_password` check (lines 512-518)
  - `accept_invite_set_password/2`: Sets password, confirms user, deletes invite tokens, and optionally creates membership with `"pathways_studio_editor"` role; membership errors propagated (lines 555-591)
  - `update_user_password/3`: Deletes ALL tokens (multi with `:all` context) (lines 228-242)
  - `reset_user_password/2`: Confirms user AND deletes all tokens (lines 439-451)
  - `confirm_user/1`: Only deletes "confirm" context tokens, not all tokens (lines 372-386)
  - `deliver_user_confirmation_instructions/2`: Guards against re-sending to confirmed users (line 357-359)
  - `update_user_email/2`: Uses `verify_change_email_token_query` which returns the token record for `sent_to` retrieval (lines 162-183)
  - `delete_user_sessions/1`: Deletes both "session" and "api_session" tokens (lines 292-296)
  - `list_user_org_memberships/1`: Excludes deactivated (line 648: `is_nil(m.deactivated_at)`)
  - `list_user_org_memberships_including_deactivated/1`: No deactivated_at filter (lines 655-659)
  - `get_user_org_membership/2`: No deactivated_at filter (line 675)
  - `register_first_admin/2`: 5-step transaction (user, org, version, membership with "administrator", confirm) (lines 609-633)

### Evidence: UserOrgMembership Schema
- **File:** `lib/gtfs_planner/accounts/user_org_membership.ex`
- **Key facts:**
  - `deactivated_at` field for soft-delete (line 27)
  - Unique constraint on `[user_id, organization_id]` (line 42)
  - Roles validated against `Roles.valid?/1` via `validate_roles/1` (lines 46-63)
  - Default roles: empty list (line 26)

### Evidence: Email System
- **File:** `lib/gtfs_planner/accounts/user_notifier.ex`
- Sender: `"no-reply@#{mail_domain}"` (configurable, line 23-27 pattern)
- 4 notification types: confirmation, update email, password reset, invite
- All inline HTML only, no text alternatives
- `deliver_user_invite/2` logs URL to Logger (line 84)

- **Files:** `lib/gtfs_planner/accounts/emails/*.ex`
- Polished HTML+text emails with CSS styling
- `EmailConfirmationEmail` and `ResetPasswordEmail` state "24 hours" expiry in templates (text is incorrect for confirmation which is 7 days)
- `UserInviteEmail` correctly states "7 days" expiry
- These modules are NOT called from the Accounts context module

### Evidence: Password Policy
- **File:** `lib/gtfs_planner/accounts/user.ex`
- `validate_password/2`: Required, 12 min, 72 max, Argon2 hash (lines 139-144)
- `maybe_hash_password/2`: Only hashes if `hash_password: true` (default) AND changeset is valid (lines 146-157)
- `valid_password?/2`: Pattern matches on `hashed_password` being binary and password length > 0; calls `Argon2.no_user_verify()` for fallback (lines 186-194)

### Evidence: Database Schema
- **Files:** `priv/repo/migrations/*.exs`
- `citext` extension enabled for case-insensitive emails (migration line 5)
- `users_tokens` has cascading delete from `users` (migration line 20)
- `user_org_memberships` has cascading delete from both `users` and `organizations` (migration lines 7-10)
- `deactivated_at` added in a later migration with composite index (migration 20260120062625)
- `users_tokens` has unique constraint on `(context, token)` (migration line 29)

### Evidence: Tests
- **File:** `test/gtfs_planner/accounts_test.exs` (905 lines, comprehensive)
  - Covers: registration, email change, password change, session tokens, API tokens, confirmation, password reset, invite flow, membership CRUD, whitespace handling
  - Tests for expired tokens by backdating `inserted_at`
  - Tests for context isolation (web token not valid for API)
  - Tests for deactivated membership exclusion
  - Tests for invite token deletion after acceptance
  - Tests for all-token deletion on password change/reset

- **File:** `test/gtfs_planner/accounts/user_token_test.exs` (85 lines)
  - Tests `build_api_session_token/1` uniqueness
  - Tests `verify_api_session_token_query/1`: valid token, garbage input, non-existent token, context isolation, 60-day expiry window

- **File:** `test/support/fixtures/accounts_fixtures.ex`
  - `extract_user_token/1`: Extracts token from email body via regex (waits for `{:email, email}` message with 100ms timeout)
  - `user_fixture/1`: Registers a user with `valid_user_attributes`
  - `valid_user_password/0`: Returns `"valid user password 123456"` (17 chars, meets 12-char minimum)

---

## Assumptions

1. **The `Emails.*` modules are intended to eventually replace `UserNotifier`** — they share the same notification types but are not currently wired into the `Accounts` context. Which one is canonical is ambiguous.

2. **`invite_user/2` ignoring `organization_id` is intentional** — the membership is deferred until invitation acceptance. The parameter may exist for API compatibility or future use.

3. **Password reset always confirms the user** — this is by design (line 443: `User.confirm_changeset()` in `reset_user_password`), so unconfirmed users can become confirmed through password reset even without email confirmation.

4. **No notification module exists for email change** — the `UserNotifier.deliver_update_email_instructions/2` sends to the user's current email, not the new email. The "update email" notification goes to the old address, which is the correct security practice.

5. **The `valid_token?/2` function on UserToken is an unused utility** — it exists for external callers but is not consumed by the Accounts context itself.

6. **The email templates in `Emails.*` have hardcoded "24 hours" text** — this is a documentation bug in the templates that doesn't match the actual 7-day token expiry for confirmations.

---

## Risks and Ambiguities

1. **HIGH — Dual email implementations:** Two parallel email systems for the same notification types creates maintenance burden and confusion. The `Emails.*` modules reference a 24-hour expiry for confirmations that is factually incorrect (actual: 7 days). Only `UserNotifier` is wired into the context.

2. **MEDIUM — Logger leaking invite URLs:** `UserNotifier.deliver_user_invite/2` logs the full invite URL including the token to Logger (line 84). This is a security risk — tokens could appear in log files.

3. **MEDIUM — `invite_user/2` dead parameter:** The `_organization_id` parameter is accepted but never used in the user creation flow. It is misleading and may cause callers to assume a membership is being created.

4. **MEDIUM — No account lockout or rate limiting:** There is no brute-force protection for login attempts, password reset requests, or invitation resends.

5. **LOW — `accept_invite_set_password` doc/code mismatch:** The documentation says "default viewer role" but the code creates a membership with `"pathways_studio_editor"` (which is an editor role, not viewer).

6. **LOW — `get_user_org_membership/2` ignores soft-delete:** Returns deactivated memberships without filtering, which could cause callers to accidentally operate on deactivated memberships.

7. **LOW — No explicit deactivation/reactivation API:** The deactivated_at field must be set manually via `Ecto.Changeset.change/2` + `Repo.update!/1` (as done in tests), with no context-level function for this operation.

8. **LOW — `:naive_datetime` vs `:utc_datetime` inconsistency:** `User.confirmed_at` is `:naive_datetime` while `UserOrgMembership.deactivated_at` is `:utc_datetime`. This inconsistency could cause timezone-related issues.

9. **LOW — Missing email change notification module:** There is no `Emails.EmailChangeEmail` module corresponding to the email change flow, while all other notification types have dedicated email modules.
