# Accounts Context Agent Doc

Source target: `lib-gtfs-planner-accounts`
Scope: Manages users, credentials, session and email tokens, invitations, organization memberships, notifications, and companion API session tokens.
Deep analysis: [`docs/specops/analysis/lib-gtfs-planner-accounts.md`](../analysis/lib-gtfs-planner-accounts.md)
Freshness: `source_hash=b8865893f1df3f41936e7008f0463913ad6ffa5568508d9fbffcdbb224a1d004`, `last_synthesized=2026-06-26`

## Use When
- Adding or modifying user lifecycle flows (registration, confirmation, password reset, invitation, email change)
- Changing authentication token behavior (session, api_session, email tokens)
- Modifying organization membership creation, roles, or deactivation
- Updating email notification content or wiring
- Changing password policy or security behaviors
- Working on `register_first_admin/2` (bootstrap flow)

## Read First
- `lib/gtfs_planner/accounts.ex` — All public business logic (context module); every entry point lives here
- `lib/gtfs_planner/accounts/user.ex` — Schema + 6 changeset functions (registration, email, password, confirm_password, confirm, invite)
- `lib/gtfs_planner/accounts/user_token.ex` — Token generation (32 random bytes → Base64 → SHA-256), verification, expiry, and deletion
- `lib/gtfs_planner/accounts/user_org_membership.ex` — Membership schema with soft-delete (`deactivated_at`) and role validation
- `lib/gtfs_planner/accounts/user_notifier.ex` — Email delivery actually wired into the context (simple inline HTML)
- `lib/gtfs_planner/authorization/roles.ex` — Canonical role definitions: `administrator` (system), `pathways_studio_admin` (org), `pathways_studio_editor` (org)

## Interfaces

### Public Functions (Accounts context)
| Function | Purpose |
|---|---|
| `register_user/1` | Create unconfirmed user with email+password |
| `register_first_admin/2` | Atomic bootstrap: user + org + version + admin membership + confirm |
| `confirm_user/1` | Verify "confirm" token, set `confirmed_at`, delete confirm token |
| `apply_user_email/3` | Validate new email + current password (no persist) |
| `deliver_user_update_email_instructions/3` | Send change-email token to *current* email, token context=`"change:<email>"` |
| `update_user_email/2` | Apply email from token's `sent_to`, confirm user, delete token |
| `update_user_password/3` | Change password + delete ALL tokens (sessions+email); full logout |
| `deliver_user_reset_password_instructions/2` | Send 1-day reset token |
| `get_user_by_reset_password_token/1` | Lookup user from reset token |
| `reset_user_password/2` | Set new password, confirm user, delete ALL tokens |
| `invite_user/2` | Idempotent: return existing user or create new (no password, no membership) |
| `deliver_user_invite/2` | Send 7-day invite token |
| `resend_user_invite/2` | Resend invite; guards against re-inviting accepted users (checks `hashed_password`) |
| `accept_invite_set_password/2` | Set password, confirm, delete invite tokens; optionally create membership with `pathways_studio_editor` role |
| `get_user_by_session_token/1` | Verify 60-day web session token |
| `generate_user_session_token/1` | Create web session token |
| `delete_session_token/1` | Delete single web session token |
| `generate_api_session_token/1` | Create API session token (context=`"api_session"`) |
| `get_user_by_api_session_token/1` | Verify 60-day API session token |
| `delete_api_session_token/1` | Delete single API session token |
| `delete_api_session_tokens/1` | Delete all API session tokens for user |
| `delete_user_sessions/1` | Delete both "session" + "api_session" tokens |
| `create_user_org_membership/1` | Create membership with role validation |
| `update_user_org_membership/2` | Update membership roles |
| `delete_user_org_membership/1` | Hard delete membership |
| `list_user_org_memberships/1` | List active memberships (excludes `deactivated_at` not null) |
| `list_user_org_memberships_including_deactivated/1` | List all memberships |
| `get_user_org_membership/2` | Get single membership (does NOT filter deactivated) |

### Token System
- 6 token contexts with expiry: `session` (60d), `api_session` (60d), `confirm` (7d), `reset_password` (1d), `invite` (7d), `change:<email>` (7d)
- Generation: `:crypto.strong_rand_bytes(32)` → Base64 URL-encode (no padding) → SHA-256 hash for storage
- Context isolation: web session token does NOT match `api_session` queries
- `valid_token?/2` exists on UserToken but is NOT used by the Accounts context (utility for external callers)

### Email System (dual implementation)
- **Active:** `UserNotifier` — 4 types (confirm, update_email, reset, invite); inline HTML only, no text alt
- **Unwired:** `Emails.EmailConfirmationEmail`, `Emails.ResetPasswordEmail`, `Emails.UserInviteEmail` — polished HTML+text, Swoosh; NOT called from Accounts context
- Sender: `"no-reply@#{mail_domain}"` (configurable via `Application.get_env(:gtfs_planner, :mail_domain)`)
- `UserNotifier.deliver_user_invite` logs invite URL to Logger (potential security concern)

### External Dependencies
- `GtfsPlanner.Organizations.Organization` — schema ref in memberships; `Organization.changeset` in `register_first_admin`
- `GtfsPlanner.Versions` — `create_default_version/1` in first admin registration
- `GtfsPlanner.Repo` — all DB operations
- `GtfsPlanner.Mailer` — email delivery via Swoosh
- `Argon2` — password hashing (`hash_pwd_salt`, `verify_pass`, `no_user_verify` for non-existent passwords)
- `:crypto` — random bytes and SHA-256 for tokens

## Rules & Invariants

### Password Policy
- 12 chars min, 72 chars max; no format restrictions (spaces/unicode allowed)
- Argon2 hashing; current password verification required for password/email changes
- `Argon2.no_user_verify()` used for users with no password (invited), preventing timing-based enumeration

### Token Lifecycle
- Password change deletes ALL tokens (session + api_session + all email tokens)
- Password reset deletes ALL tokens AND confirms the user (unconfirmed users can become confirmed via reset)
- Invite acceptance deletes only `"invite"` context tokens
- Session logout deletes a single session token by value

### Membership Rules
- One membership per user per organization (unique constraint on `[user_id, organization_id]`)
- Roles must be valid canonical roles (validated against `Roles.valid?/1`)
- `list_user_org_memberships/1` excludes soft-deleted (deactivated); `get_user_org_membership/2` does NOT filter
- No dedicated deactivate/reactivate function; `deactivated_at` set externally via changeset

### Data Constraints
- `users.email`: citext (case-insensitive) + unique + NOT NULL
- `users_tokens`: unique on `(context, token)` + FK cascade from users
- `user_org_memberships`: unique on `(user_id, organization_id)` + FK cascade from both users and organizations
- All operations touching tokens + user state use `Ecto.Multi` transactions

## State, I/O & Side Effects

- **Database:** All user/token/membership state persisted via `GtfsPlanner.Repo` in `users`, `users_tokens`, `user_org_memberships` tables
- **Email delivery:** Side effect via `GtfsPlanner.Mailer.deliver/1` (Swoosh); not wrapped in DB transactions
- **Logger:** `UserNotifier.deliver_user_invite/2` writes full invite URL to Logger (risk: token exposure in logs)
- **`register_first_admin/2`:** Creates user, organization, default version, admin membership, and confirms user — all in one `Ecto.Multi`; this is the application bootstrap entry point
- **`accept_invite_set_password/2`:** Membership creation is inside the same transaction as password set + confirm; if membership fails, the whole transaction rolls back

## Failure Modes

- **No brute-force protection:** No login attempt tracking, rate limiting, or account lockout
- **Dual email implementations:** `Emails.*` modules unwired and have incorrect expiry text ("24 hours" vs actual 7 days for confirmations)
- **Logger leaks tokens:** Invite URLs with tokens logged in plaintext
- **`invite_user/2` dead parameter:** `organization_id` accepted but ignored; membership deferred to `accept_invite_set_password/2`
- **Doc/code mismatch:** `accept_invite_set_password` doc says "default viewer role" but code uses `pathways_studio_editor`
- **`get_user_org_membership/2` ignores soft-delete:** Returns deactivated memberships (callers must check `deactivated_at`)
- **No deactivation/reactivation API:** Must manually set `deactivated_at` via changeset; no context function
- **Datetime type inconsistency:** `User.confirmed_at` is `naive_datetime`, `UserOrgMembership.deactivated_at` is `utc_datetime`
- **No email-change notification module:** All other notification types have `Emails.*` modules but email change does not

## Change Checklist
- [ ] Run `mix test test/gtfs_planner/accounts_test.exs`
- [ ] Run `mix test test/gtfs_planner/accounts/user_token_test.exs`
- [ ] If changing tokens: verify context isolation tests pass (web token ≠ api_session)
- [ ] If changing password/reset: verify all-token deletion behavior
- [ ] If changing membership: verify soft-delete exclusion in `list_user_org_memberships/1`
- [ ] If changing emails: verify which implementation is canonical and update both or remove unused
- [ ] Run `mix precommit`

## Escalate To Deep Analysis
- Full token expiry/days mapping: `UserToken.days_for_context/1`
- Complete changeset validation rules: `lib/gtfs_planner/accounts/user.ex` lines 38-194
- Test fixtures and helpers: `test/support/fixtures/accounts_fixtures.ex`
- Database migration details: `priv/repo/migrations/20251223034104_create_users_auth_tables.exs` and `...06_create_user_org_memberships.exs`
- Email template HTML/text content: `lib/gtfs_planner/accounts/emails/*.ex`
- Full deep analysis with evidence references: `docs/specops/analysis/lib-gtfs-planner-accounts.md`
