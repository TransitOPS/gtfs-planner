# API Authentication

This guide explains how to authenticate with the GTFS Planner companion API using
user-owned session tokens.

## Overview

Programmatic access to `/api/v1` uses **user-owned companion sessions**, not
organization API keys. A client logs in with a member's email and password,
receives a Bearer token stored under the `api_session` token context, and sends
that token on subsequent requests. Organization selection uses the
`X-Organization-Id` header when the user belongs to more than one organization.

Organization-scoped legacy API keys (`GtfsPlanner.V1.*`) are retired and are
rejected as unauthorized.

## Login

```http
POST /api/v1/auth/login
Content-Type: application/json
Accept: application/json

{
  "email": "member@example.com",
  "password": "your-password"
}
```

### Success (200)

```json
{
  "data": {
    "token": "<base64url-session-token>",
    "user": { "id": "<user-uuid>", "email": "member@example.com" },
    "organization_id": "<default-organization-uuid>",
    "roles": ["pathways_studio_editor"],
    "expires_at": "2026-09-18T12:00:00Z"
  }
}
```

- `token` is a Base64url-encoded opaque secret. Store it securely; it is not
  recoverable after creation.
- Tokens expire after **60 days** from creation (`expires_at` is informational).
- `organization_id` is the first membership returned for the user. Multi-org
  clients must still send `X-Organization-Id` when calling protected routes that
  require a specific tenant.

### Errors

| Status | Code | When |
| --- | --- | --- |
| 400 | `bad_request` | Missing email or password |
| 401 | `invalid_credentials` | Unknown email or wrong password (same body either way) |
| 403 | `no_organization` | User has no organization membership |

Example invalid-credentials body:

```json
{
  "error": {
    "code": "invalid_credentials",
    "message": "Invalid email or password."
  }
}
```

Login responses are time-padded on the server to reduce timing differences
between success and failure paths.

## Authenticated requests

Send the session token as a Bearer credential:

```http
Authorization: Bearer <token>
Accept: application/json
X-Organization-Id: <organization-uuid>
```

`X-Organization-Id` is required when the user has multiple memberships. Single-org
users may omit it; the server selects their only membership.

### Example

```bash
TOKEN=$(curl -s -X POST https://example.com/api/v1/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"email":"member@example.com","password":"your-password"}' \
  | jq -r '.data.token')

curl -s https://example.com/api/v1/versions \
  -H "Authorization: Bearer $TOKEN" \
  -H "X-Organization-Id: $ORG_ID" \
  -H 'Accept: application/json'
```

## Logout

```http
DELETE /api/v1/auth/session
Authorization: Bearer <token>
```

Success (200):

```json
{ "data": { "message": "Logged out." } }
```

The server deletes the `api_session` token. Replaying the same Bearer value after
logout returns unauthorized.

## Unauthorized responses

Missing, invalid, expired, revoked, or legacy-shaped Bearer values receive:

```json
{ "error": { "code": "unauthorized" } }
```

HTTP status is **401**. Legacy organization-key prefixes such as
`Bearer GtfsPlanner.V1.<payload>` are not accepted.

## Pipeline order (companion API)

Protected companion routes use this plug order exactly:

1. JSON accept + CORS (`:api_session` / `:api_cors`)
2. `GtfsPlannerWeb.Plugs.VerifyApiSession` — validates Bearer via
   `Accounts.get_user_by_api_session_token/1`
3. `GtfsPlannerWeb.Plugs.AssignApiOrganization` — selects org from membership /
   `X-Organization-Id`
4. Write routes additionally run `GtfsPlannerWeb.Plugs.RequireApiEditor`

Public health (`GET /health`) accepts JSON and does not require authentication.

## Security notes

- Tokens are stored hashed in `users_tokens` with context `"api_session"`.
- Changing a password replaces browser and companion sessions for that user.
- Do not log Bearer tokens or embed them in URLs.
- Prefer short-lived client storage and call logout when the companion signs out.
