# SpecOps Analysis: API and Upload Plugs

**Target:** `lib/gtfs_planner_web/plugs`  
**Source hash:** `093f95012431275a2a07b5d0d4a9843e28f45a8ff65c230310ad292c5b356812`  
**Date:** 2026-06-26  
**Status:** analysis

---

## 1. Overview

This structural unit defines four request plugs responsible for CORS policy enforcement, companion API session authentication, organization assignment for API requests, and serving uploaded files from the filesystem. Three plugs (`CORS`, `VerifyApiSession`, `AssignApiOrganization`) are composed into router pipelines for the companion API. The fourth plug (`UploadsPlug`) is mounted directly in the endpoint, before the router, to serve uploaded files (e.g., floorplan diagrams) at `/uploads/*`.

### Evidence

- `lib/gtfs_planner_web/plugs/cors.ex:1-53`
- `lib/gtfs_planner_web/plugs/verify_api_session.ex:1-45`
- `lib/gtfs_planner_web/plugs/assign_api_organization.ex:1-118`
- `lib/gtfs_planner_web/plugs/uploads_plug.ex:1-70`
- `lib/gtfs_planner_web/router.ex:145-155` (pipeline composition)
- `lib/gtfs_planner_web/endpoint.ex:18-19` (UploadsPlug mount)

---

## 2. Module Inventory & Purpose

| Module | File | Role |
|---|---|---|
| `GtfsPlannerWeb.Plugs.CORS` | `cors.ex` | Applies CORS headers for companion-app cross-origin requests. Answers OPTIONS preflight with 204 halt. |
| `GtfsPlannerWeb.Plugs.VerifyApiSession` | `verify_api_session.ex` | Authenticates API requests by extracting and verifying a Bearer token. Assigns `:current_user`, `:current_user_id`, `:api_session_token` or halts with 401 JSON. |
| `GtfsPlannerWeb.Plugs.AssignApiOrganization` | `assign_api_organization.ex` | Resolves and assigns `:current_organization_id` from the `X-Organization-Id` header or from sole-membership inference. Requires `:current_user` set on conn. |
| `GtfsPlannerWeb.UploadsPlug` | `uploads_plug.ex` | Serves static files from the configured uploads directory at `/uploads/*`. Applies CORS inline and enforces path-traversal protection. |

### Evidence

- `lib/gtfs_planner_web/plugs/cors.ex:1-5`
- `lib/gtfs_planner_web/plugs/verify_api_session.ex:1-9`
- `lib/gtfs_planner_web/plugs/assign_api_organization.ex:1-13`
- `lib/gtfs_planner_web/plugs/uploads_plug.ex:1-24`

---

## 3. Structural Boundaries

### 3.1 Module Namespacing

- `CORS`, `VerifyApiSession`, and `AssignApiOrganization` live under `GtfsPlannerWeb.Plugs.*`. They are standard `Plug` modules, with `VerifyApiSession` explicitly declaring `@behaviour Plug`.
- `UploadsPlug` lives under `GtfsPlannerWeb.*` directly (not `Plugs.*`), making it a peer of `Endpoint` rather than a child of the `Plugs` sub-namespace. This is a structural inconsistency but reflects its different mounting point (endpoint vs. router pipeline).

### Evidence

- `lib/gtfs_planner_web/plugs/verify_api_session.ex:14` (`@behaviour Plug`)
- `lib/gtfs_planner_web/plugs/uploads_plug.ex:1` (`GtfsPlannerWeb.UploadsPlug`)
- `lib/gtfs_planner_web/endpoint.ex:1,19` (same `GtfsPlannerWeb` scope as `UploadsPlug`)

### 3.2 Router Mounting

Three distinct router pipelines use these plugs:

| Pipeline | Plugs in Order | Routes |
|---|---|---|
| `:api_cors` | `accepts("json")`, `CORS` | preflight `OPTIONS /*path`, public `POST /auth/login` |
| `:api_session` | `accepts("json")`, `CORS`, `VerifyApiSession`, `AssignApiOrganization` | `DELETE /auth/session`, `GET /versions`, `GET /versions/.../stations`, `POST /.../sync` |
| _none_ (endpoint) | `UploadsPlug` (before router) | all `/uploads/*` paths |

CORS is present in both pipelines: `:api_cors` (for unauthenticated endpoints) and `:api_session` (for authenticated endpoints). Ordering ensures `CORS` runs before `VerifyApiSession` and `AssignApiOrganization`, so preflight OPTIONS requests are answered without authentication.

### Evidence

- `lib/gtfs_planner_web/router.ex:145-183`
- `lib/gtfs_planner_web/endpoint.ex:18-19`

---

## 4. Data Flow

### 4.1 Conn Assigns Produced

| Assign | Set By | Condition |
|---|---|---|
| `:current_user` | `VerifyApiSession` | On valid Bearer token verification (always set) |
| `:current_user_id` | `VerifyApiSession` | On valid Bearer token verification (always set) |
| `:api_session_token` | `VerifyApiSession` | On valid Bearer token verification (always set) |
| `:current_organization_id` | `AssignApiOrganization` | On successful membership resolution (string) |

### Evidence

- `lib/gtfs_planner_web/plugs/verify_api_session.ex:23-26`
- `lib/gtfs_planner_web/plugs/assign_api_organization.ex:64,84`

### 4.2 Conn Assigns Required as Input

| Assign | Required By | Source |
|---|---|---|
| `:current_user` | `AssignApiOrganization` | Set earlier by `VerifyApiSession` in `:api_session` pipeline |

If `:current_user` is `nil` (plug invoked out of order or without authentication), `AssignApiOrganization` halts with 401.

### Evidence

- `lib/gtfs_planner_web/plugs/assign_api_organization.ex:20-27`
- `lib/gtfs_planner_web/router.ex:150-155`

### 4.3 External Dependencies

| Module | Dependency | Function |
|---|---|---|
| `VerifyApiSession` | `GtfsPlanner.Accounts` | `get_user_by_api_session_token/1` |
| `AssignApiOrganization` | `GtfsPlanner.Accounts` | `list_user_org_memberships/1` |
| `UploadsPlug` | `GtfsPlannerWeb.Plugs.CORS` | `call/2` |

### Evidence

- `lib/gtfs_planner_web/plugs/verify_api_session.ex:12,22`
- `lib/gtfs_planner_web/plugs/assign_api_organization.ex:16,29`
- `lib/gtfs_planner_web/plugs/uploads_plug.ex:34`

---

## 5. Request Lifecycle

### 5.1 CORS Plug (`cors.ex`)

```
call(conn, _opts)
├─ Extract "origin" header
├─ Set "vary: origin" response header (always)
├─ If origin is allowed:
│  ├─ Set access-control-allow-origin (echo origin)
│  ├─ Set access-control-allow-methods (GET, POST, PUT, PATCH, DELETE, OPTIONS)
│  ├─ Set access-control-allow-headers (authorization, content-type, x-organization-id)
│  ├─ Set access-control-max-age: 86400
│  └─ handle_preflight() → if OPTIONS, send 204 + halt
└─ If origin not allowed:
   └─ handle_preflight() → if OPTIONS, send 204 + halt (no CORS headers)
```

Allowed origins: the hardcoded production origin `https://field-companion.pathways.jarv.us` plus any `localhost`/`127.0.0.1` origin on `http` or `https`.

### Evidence

- `lib/gtfs_planner_web/plugs/cors.ex:9-53`

### 5.2 VerifyApiSession Plug (`verify_api_session.ex`)

```
call(conn, _opts)
├─ extract_token(conn)
│  └─ Read "authorization" header, match "Bearer <token>"
│     ├─ Success → {:ok, token}
│     └─ Failure/missing/empty → :error
├─ Accounts.get_user_by_api_session_token(token)
│  ├─ Success → assign :current_user, :current_user_id, :api_session_token
│  └─ Failure (nil or error) → unauthorized(conn)
└─ unauthorized(conn): 401 JSON {"error":{"code":"unauthorized"}} + halt
```

Token verification delegates to `Accounts.get_user_by_api_session_token/1`, which internally calls `UserToken.verify_api_session_token_query/1`. This verifies the token's hash, checks the context is `"api_session"`, and validates the token hasn't expired (60-day TTL enforced at the `UserToken` query level, not in this plug).

### Evidence

- `lib/gtfs_planner_web/plugs/verify_api_session.ex:20-44`
- `lib/gtfs_planner/accounts.ex:312-320`
- `test/gtfs_planner_web/plugs/verify_api_session_test.exs:57-85` (expired token test)

### 5.3 AssignApiOrganization Plug (`assign_api_organization.ex`)

```
call(conn, _opts)
├─ If conn.assigns.current_user is nil → 401 halt
├─ Accounts.list_user_org_memberships(user.id) → active memberships only
├─ If "x-organization-id" header present:
│  ├─ Cast to UUID:
│  │  ├─ Invalid UUID → 400 halt ("bad_request")
│  │  └─ Valid UUID → resolve_valid_org_id()
│  │     ├─ Membership found matching org_id → assign :current_organization_id
│  │     └─ No matching membership → 403 halt ("forbidden")
│  └─
├─ If no header:
   ├─ 1 active membership → auto-assign :current_organization_id
   ├─ 0 active memberships → 403 halt ("no_organization")
   └─ 2+ active memberships → 403 halt ("organization_required") with available_organization_ids
```

The plug uses `Accounts.list_user_org_memberships/1`, which filters `deactivated_at IS NULL` at the query level. Deactivated memberships are invisible; a user with only deactivated memberships receives `"no_organization"`.

### Evidence

- `lib/gtfs_planner_web/plugs/assign_api_organization.ex:20-117`
- `lib/gtfs_planner/accounts.ex:646-649` (active-only filter)
- `test/gtfs_planner_web/plugs/assign_api_organization_test.exs:133-188` (deactivated membership tests)

### 5.4 UploadsPlug (`uploads_plug.ex`)

```
call(conn, opts)
├─ If path_info starts with ["uploads" | rest]:
│  ├─ Invoke CORS.call(conn, []) for cross-origin header support
│  ├─ If conn halted (CORS preflight answered) → return
│  ├─ serve_upload(conn, rest):
│  │  ├─ Expand configured uploads_base
│  │  ├─ Join resolved path from uploads_base + rest segments
│  │  ├─ Expand joined path
│  │  ├─ If resolved path is outside uploads_base → 403"Forbidden" + halt
│  │  ├─ If resolved path is a regular file → send_file(200) + halt
│  │  └─ Otherwise → pass through (conn unchanged)
└─ If path_info does not match "uploads" → pass through (conn unchanged)
```

Key points:
- CORS is applied inline by calling `GtfsPlannerWeb.Plugs.CORS.call/2` directly. The CORS plug's own preflight handling (OPTIONS → 204 halt) prevents the upload from being served on preflight.
- Path traversal protection uses `Path.expand` + `String.starts_with?` to ensure the resolved file is within `uploads_base`.
- Missing files pass through to the next plug (the router), resulting in a 404 from Phoenix.

### Evidence

- `lib/gtfs_planner_web/plugs/uploads_plug.ex:30-69`
- `lib/gtfs_planner_web/endpoint.ex:18-19`
- `test/gtfs_planner_web/plugs/uploads_plug_test.exs:181-201` (path traversal tests)

---

## 6. Error Modes

### 6.1 Error Response Summary

| Plug | Status | Body | Trigger |
|---|---|---|---|
| `VerifyApiSession` | 401 | `{"error":{"code":"unauthorized"}}` | Missing/invalid/expired/non-API token, failed lookup |
| `AssignApiOrganization` | 401 | `{"error":{"code":"unauthorized"}}` | No `:current_user` on conn |
| `AssignApiOrganization` | 400 | `{"error":{"code":"bad_request","message":"..."}}` | Invalid UUID in `X-Organization-Id` |
| `AssignApiOrganization` | 403 | `{"error":{"code":"forbidden","message":"..."}}` | Org not in user's memberships |
| `AssignApiOrganization` | 403 | `{"error":{"code":"no_organization","message":"..."}}` | User has zero active memberships |
| `AssignApiOrganization` | 403 | `{"error":{"code":"organization_required","message":"...", "available_organization_ids":[...]}}` | Multi-org user without header |
| `UploadsPlug` | 403 | `"Forbidden"` | Path traversal attempt |
| `UploadsPlug` | 204 | (empty) | CORS preflight OPTIONS for /uploads/* |
| `CORS` | 204 | (empty) | Preflight OPTIONS for any allowed/non-allowed origin |

All API error responses (401, 400, 403) use `application/json` content type except `UploadsPlug`'s 403 which uses `text/plain`.

### Evidence

- `lib/gtfs_planner_web/plugs/verify_api_session.ex:39-44`
- `lib/gtfs_planner_web/plugs/assign_api_organization.ex:22-27,42-55,63-78,82-116`
- `lib/gtfs_planner_web/plugs/uploads_plug.ex:56-59`
- `lib/gtfs_planner_web/plugs/cors.ex:46-49`

---

## 7. Business Rules & Policies

### 7.1 CORS Policy

| Rule | Detail |
|---|---|
| Allowed origins | `https://field-companion.pathways.jarv.us` (production) + all `localhost`/`127.0.0.1` origins |
| Allowed methods | `GET, POST, PUT, PATCH, DELETE, OPTIONS` |
| Allowed headers | `authorization, content-type, x-organization-id` |
| Max age | 86400 seconds (24 hours) |
| Vary | `origin` (always set) |
| Preflight behavior | Always answers OPTIONS with 204, regardless of whether the origin is allowed |
| Credentials | Not supported (no `access-control-allow-credentials` header) |

### Evidence

- `lib/gtfs_planner_web/plugs/cors.ex:9-53`

### 7.2 Authentication Policy

| Rule | Detail |
|---|---|
| Token format | `Authorization: Bearer <token>` header |
| Token context | Must be `"api_session"` (web `"session"` tokens rejected) |
| Token TTL | 60 days (enforced by `UserToken.verify_api_session_token_query/1`) |
| Expired tokens | 401 response, indistinguishable from invalid |
| Empty Bearer value | Treated as missing token (401) |

### Evidence

- `lib/gtfs_planner_web/plugs/verify_api_session.ex:33-37`
- `test/gtfs_planner_web/plugs/verify_api_session_test.exs:57-99`

### 7.3 Organization Resolution Policy

| Rule | Detail |
|---|---|
| Inactive memberships | Deactivated memberships (`deactivated_at IS NOT NULL`) are excluded from resolution |
| Single-org, no header | Auto-assign (no header needed) |
| Multi-org, valid header | Assign specified org if user is a member |
| Multi-org, no header | 403 with list of available org IDs |
| Multi-org, invalid header UUID | 400 |
| Multi-org, valid UUID but non-member | 403 |
| Zero memberships | 403 |
| Authentication required | `:current_user` must be set; otherwise 401 |

### Evidence

- `lib/gtfs_planner_web/plugs/assign_api_organization.ex:20-117`
- `lib/gtfs_planner/accounts.ex:646-649`
- `test/gtfs_planner_web/plugs/assign_api_organization_test.exs:1-190`

### 7.4 Upload Serving Policy

| Rule | Detail |
|---|---|
| URL base | `/uploads/*` |
| Storage base | `Application.get_env(:gtfs_planner, :uploads_path)` (expanded) |
| CORS for uploads | Same policy as API (`CORS.call/2` applied inline) |
| Path traversal | Blocked (403) — resolved path must be a child of uploads base |
| File not found | Pass through to router (typically becomes 404 from Phoenix) |
| Root `/uploads` | Passes through (no file at directory root) |
| Directory structure | Organization-scoped: `diagrams/:org_id/:stop_id/:filename` (by convention, not enforced by plug) |

### Evidence

- `lib/gtfs_planner_web/plugs/uploads_plug.ex:45-69`
- `lib/gtfs_planner_web/endpoint.ex:18-19`
- `test/gtfs_planner_web/plugs/uploads_plug_test.exs:31-179`

---

## 8. Integration Contracts

### 8.1 Between `VerifyApiSession` and `AssignApiOrganization`

- **Ordering:** `VerifyApiSession` must run before `AssignApiOrganization` in any pipeline.
- **Contract:** `AssignApiOrganization` reads `conn.assigns.current_user` and `conn.assigns.current_user_id`. If either is absent, it halts with 401.
- **Fulfillment:** The `:api_session` router pipeline lists them in correct order (`router.ex:150-155`). No other pipeline chains these two plugs.

### Evidence

- `lib/gtfs_planner_web/router.ex:150-155`
- `lib/gtfs_planner_web/plugs/assign_api_organization.ex:21` (reads `assigns[:current_user]`)

### 8.2 Between `UploadsPlug` and `CORS`

- `UploadsPlug` invokes `GtfsPlannerWeb.Plugs.CORS.call(conn, [])` inline rather than going through a router pipeline (because it's endpoint-mounted, before the router).
- The CORS plug's halt behavior is honored: if CORS halts (OPTIONS preflight), `UploadsPlug` returns early without serving files.

### Evidence

- `lib/gtfs_planner_web/plugs/uploads_plug.ex:34-38`

### 8.3 Accounts Module Contracts

| Calling Plug | Accounts Function | Returns | Notes |
|---|---|---|---|
| `VerifyApiSession` | `get_user_by_api_session_token/1` | `%User{}` or `nil` | Token context must be `"api_session"`; 60-day TTL |
| `AssignApiOrganization` | `list_user_org_memberships/1` | `[%UserOrgMembership{}]` | Filters out deactivated memberships via SQL `WHERE deactivated_at IS NULL` |

### Evidence

- `lib/gtfs_planner/accounts.ex:312-320` (`get_user_by_api_session_token`)
- `lib/gtfs_planner/accounts.ex:646-649` (`list_user_org_memberships`)

---

## 9. Configuration

| Config Key | Used By | Purpose | Default/Example |
|---|---|---|---|
| `:gtfs_planner, :uploads_path` | `UploadsPlug` | Filesystem path for uploaded files | No default — must be set or `Application.fetch_env!` crashes |

The `CORS` plug has a compile-time module attribute `@allowed_origins` with one hardcoded production origin. There is no runtime configuration for allowed origins.

### Evidence

- `lib/gtfs_planner_web/plugs/uploads_plug.ex:46`
- `lib/gtfs_planner_web/plugs/cors.ex:9-11`

---

## 10. Testing & Coverage

### 10.1 Test Files

| Test File | Target Module | Test Count |
|---|---|---|
| `test/gtfs_planner_web/plugs/verify_api_session_test.exs` | `VerifyApiSession` | 7 tests |
| `test/gtfs_planner_web/plugs/assign_api_organization_test.exs` | `AssignApiOrganization` | 7 tests (across 5 describe blocks) |
| `test/gtfs_planner_web/plugs/uploads_plug_test.exs` | `UploadsPlug` | 10 tests |

### Evidence

- `test/gtfs_planner_web/plugs/verify_api_session_test.exs:1-111`
- `test/gtfs_planner_web/plugs/assign_api_organization_test.exs:1-190`
- `test/gtfs_planner_web/plugs/uploads_plug_test.exs:1-203`

### 10.2 Test Coverage Summary

| Module | Functional Paths Covered | Gaps |
|---|---|---|
| `CORS` | No dedicated tests | Allowed origin responses, non-allowed origin behavior, localhost parsing, preflight behavior all untested at the unit level. Covered indirectly via `UploadsPlug` tests (CORS headers on upload responses, preflight for uploads) and implicitly via API integration tests. |
| `VerifyApiSession` | Valid token, missing header, malformed header, empty Bearer, expired token (>60 days), web session token (wrong context), invalid token string | Good coverage of all error paths and the success path |
| `AssignApiOrganization` | Single-org auto-assign, multi-org with valid header, multi-org without header (403 + list), non-member org (403), zero memberships (403), deactivated sole membership, deactivated member excluded from multi-org | Missing: invalid UUID header test (400 path). The "excludes deactivated membership from available orgs" test implicitly covers the auto-assign fallback but not the 400 branch. |
| `UploadsPlug` | File served, CORS header for localhost, CORS preflight (OPTIONS), disallowed origin (no CORS), file not found pass-through, non-upload path pass-through, tenant isolation (different org), nested paths, root /uploads, path traversal, encoded path traversal | Missing: CORS behavior with production origin (`https://field-companion.pathways.jarv.us`). Missing: test for when `uploads_path` config is missing (crash path). |

### Evidence

- Test file contents as listed above; test directories do not contain a `cors_test.exs` file (confirmed by glob result).

---

## 11. Ambiguities & Risks

### 11.1 Ambiguities

| # | Description | Impact |
|---|---|---|
| A1 | `UploadsPlug` lives at `GtfsPlannerWeb.UploadsPlug` while other plugs live at `GtfsPlannerWeb.Plugs.*`. Unclear if this is intentional (endpoint-level vs. router-level) or accidental. | Low — structural only, no runtime effect. |
| A2 | `UploadsPlug` does not enforce authentication or organization-scoped access. Any client that knows the file path can download any uploaded file. The current convention (`diagrams/:org_id/:stop_id/:filename`) provides path-based isolation but no access control. | Medium — files are only as private as their path is guessable. The comment in `station_controller.ex:167` confirms this is for floorplan images served to the companion app, but authentication to `/uploads/*` is not enforced. |
| A3 | The `AssignApiOrganization` plug's 403 for multi-org users without a header returns `available_organization_ids` — this leaks org ID structure to the authenticated client. | Low — the user already has memberships to these orgs, but it reveals internal UUIDs in the response. |
| A4 | `CORS` plug allows all HTTP methods on allowed origins but only preflights are answered without auth. There's no explicit documentation clarifying whether POST/PUT/DELETE on preflight paths through `:api_cors` pipeline are intentionally left unprotected (they would hit the `FallbackController`). | Low — the `:api_cors` pipeline only has `OPTIONS /*path` and `POST /auth/login` routes, so non-OPTIONS on other /api/v1 paths would 404 anyway. |

### Evidence

- A1: `lib/gtfs_planner_web/plugs/uploads_plug.ex:1` vs `lib/gtfs_planner_web/plugs/cors.ex:1`
- A2: `lib/gtfs_planner_web/plugs/uploads_plug.ex:30-69` (no auth check)
- A3: `lib/gtfs_planner_web/plugs/assign_api_organization.ex:100-115`
- A4: `lib/gtfs_planner_web/router.ex:159-165`

### 11.2 Risks

| # | Risk | Severity | Mitigation |
|---|---|---|---|
| R1 | `UploadsPlug` uses `Application.fetch_env!/2` which crashes the entire application startup if `:uploads_path` is not configured. | Medium | Default to a reasonable path or document as a required config. |
| R2 | `CORS` allowed origins are hardcoded at compile time. Adding a new production origin requires a code change and redeploy. | Low | Could be made configurable via application env. |
| R3 | `VerifyApiSession` and `AssignApiOrganization` both access the database synchronously within the plug pipeline, blocking the conn process. Under high API load, this could become a bottleneck. | Low | No async alternatives currently in use; acceptable for expected load. |
| R4 | `UploadsPlug` path traversal check uses string prefix matching with `String.starts_with?` after `Path.expand`. While effective against `..` traversal, edge cases with symlinks or filesystem tricks on certain OS configurations could theoretically bypass this. | Low | Current implementation follows standard Phoenix/LiveView community practices. |
| R5 | `AssignApiOrganization` does not accept multiple `X-Organization-Id` values. If multiple headers are sent, only the first is used (`List.first` behavior in `get_req_header`). | Low | Documented behavior. |

### Evidence

- R1: `lib/gtfs_planner_web/plugs/uploads_plug.ex:46` (`Application.fetch_env!`)
- R2: `lib/gtfs_planner_web/plugs/cors.ex:9-11` (`@allowed_origins`)
- R3: `lib/gtfs_planner_web/plugs/verify_api_session.ex:22` (DB call per request)
- R4: `lib/gtfs_planner_web/plugs/uploads_plug.ex:53-54`
- R5: `lib/gtfs_planner_web/plugs/assign_api_organization.ex:31`

---

*Generated by SpecOps analysis on 2026-06-26*
