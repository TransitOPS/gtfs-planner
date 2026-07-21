# Authentication Guide

## Overview

GTFS Planner provides multi-tenant authentication for:

1. **Browser sessions** — email/password LiveView login for operators
2. **Companion API sessions** — user-owned Bearer tokens for the field companion
3. **Organization membership and roles** — tenant scoping and authorization

Legacy organization API keys (`GtfsPlanner.V1.*`, `ApiKeyAuth`, org-key LiveView)
are retired. Current programmatic access uses companion `api_session` tokens only.
See [API Authentication](./api-authentication.md) for the companion contract.

## Architecture layers

1. **Domain** (`GtfsPlanner.Accounts`, `GtfsPlanner.Organizations`) — users,
   memberships, session/token lifecycle
2. **Web** (`GtfsPlannerWeb.UserAuth`, companion plugs under
   `GtfsPlannerWeb.Plugs`) — browser hooks and `/api/v1` Bearer verification
3. **Database** — `users`, `users_tokens`, `organizations`, membership tables

## Browser authentication

Operators sign in at `/users/log_in`. Sessions use the `"session"` token context
and LiveView `on_mount` hooks from `UserAuth`. Organization context for account
surfaces is assigned by `AssignOrganization`.

Password reset, email confirmation, and invite acceptance flows remain on the
browser pipeline. Account settings live at `/users/settings`.

## Companion API authentication

### Login

```http
POST /api/v1/auth/login
Content-Type: application/json

{"email":"member@example.com","password":"..."}
```

On success the server returns a Bearer token created by
`Accounts.generate_api_session_token/1` (context `"api_session"`, 60-day TTL),
plus the user, a default `organization_id`, roles, and `expires_at`.

Exact error codes:

- `400` / `bad_request` — missing credentials
- `401` / `invalid_credentials` — bad email or password
- `403` / `no_organization` — no membership

### Protected calls

```http
Authorization: Bearer <api_session_token>
X-Organization-Id: <organization-uuid>
```

Pipeline order for protected routes:

1. CORS + JSON accept
2. `VerifyApiSession`
3. `AssignApiOrganization`
4. `RequireApiEditor` on write routes only

### Logout

```http
DELETE /api/v1/auth/session
Authorization: Bearer <api_session_token>
```

Revokes that token. Replay yields `401` with
`{"error":{"code":"unauthorized"}}`.

### Rejected credentials

Legacy-shaped Bearer values (`GtfsPlanner.V1.*`) and other invalid tokens receive
the same unauthorized JSON. No `current_api_key` assign exists in the runtime.

## Organization selection

- Membership is required for companion access.
- Multi-org users must send `X-Organization-Id`.
- Single-org users may omit the header; the sole membership is selected.
- Browser account pages use session + `AssignOrganization` rather than API headers.

## Roles

Roles live on organization memberships (`UserOrgMembership.roles`). Common values
include `pathways_studio_admin` and `pathways_studio_editor`. Companion write
routes require an editor membership on the selected organization via
`RequireApiEditor`. LiveView admin surfaces use `EnsureRole` against the current
user membership only.

## Operator bootstrap (IEx)

```elixir
alias GtfsPlanner.{Accounts, Organizations}

{:ok, org} =
  Organizations.create_organization(%{alias: "demo", name: "Demo Transit"})

{:ok, user} =
  Accounts.register_user(%{
    email: "admin@example.com",
    password: "a-strong-password"
  })

{:ok, _membership} =
  Organizations.add_user_to_organization(user.id, org.id, [
    "pathways_studio_admin",
    "pathways_studio_editor"
  ])
```

Companion clients then call `POST /api/v1/auth/login` with that email and password.
Do **not** create organization API keys; that subsystem has been removed from
production code (the `api_keys` table may still exist until a later migration).

## Security practices

- Passwords are hashed (Argon2); tokens are stored hashed.
- Prefer HTTPS in every non-local environment.
- Rotate compromised companion sessions with logout or password change.
- Never commit provider secrets (`GEOAPIFY_API_KEY`, mailer keys). Those are
  third-party configuration keys, unrelated to companion auth.

## Troubleshooting

**Companion 401 unauthorized**

- Confirm `Authorization: Bearer <token>` (no legacy `GtfsPlanner.V1.` prefix)
- Confirm the token was not logged out or expired (60 days)
- Confirm the user still has an active membership

**403 no_organization on login**

- Add the user to an organization before companion login

**Multi-org wrong tenant data**

- Send the intended `X-Organization-Id`

**Browser cannot access admin LiveViews**

- Check membership roles via `EnsureRole` / admin invite flows

## Related docs

- [API Authentication](./api-authentication.md) — companion request contract
- [User Management](./user-management.md) — invites, roles, memberships
- [Warbler Authentication Implementation](./warbler-authentication-implementation.md) —
  **historical** reference only; describes a prior org-key design
