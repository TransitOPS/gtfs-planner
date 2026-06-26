# SpecOps Analysis: Companion API Controllers

**Target**: `lib/gtfs_planner_web/api`  
**Structural unit**: `lib/gtfs_planner_web/api/**`  
**Source hash**: `dd533899b58837342646f3ea88321cde78794dedccb4609cf5b7a8fa084a3dca`

---

## 1. Purpose & Responsibilities

The Companion API controllers expose a JSON API consumed by the Pathways Field Companion web app (`field-companion.pathways.jarv.us`). This API layer handles:

1. **Authentication** — login (POST `/api/v1/auth/login`) and logout (DELETE `/api/v1/auth/session`) with Bearer token management.
2. **GTFS version listing** — listing available GTFS versions for the authenticated user's organization (GET `/api/v1/versions`).
3. **Station listing** — paginated, searchable listing of stations within a GTFS version, including child stop, pathway, and level counts (GET `/api/v1/versions/:version_id/stations`).
4. **Station data bundle** — a full data dump for a single station: the station itself, its levels (with floorplan metadata and alignment transforms), its child stops, its pathways, and a `downloaded_at` timestamp (GET `/api/v1/versions/:version_id/stations/:station_id/bundle`).
5. **Pathway sync** — applies field data updates (traversal_time, signposted_as, field_notes, etc.) and supports reversing a pathway's direction via endpoint swap (POST `/api/v1/versions/:version_id/stations/:station_id/sync`).
6. **CORS preflight** — an OPTIONS catch-all that returns 204 after the CORS plug handles headers.

### Evidence

- `lib/gtfs_planner_web/router.ex:157-183` — route definitions for all API v1 endpoints.
- `lib/gtfs_planner_web/api/v1/fallback_controller.ex:1-9` — preflight handler comment explains CORS plug responsibility.

---

## 2. Public Interfaces & Entry Points

### Routes

| Method | Path | Controller Action | Auth Required | Pipeline |
|--------|------|-------------------|---------------|----------|
| OPTIONS | `/api/v1/*path` | `FallbackController.preflight/2` | No | `:api_cors` |
| POST | `/api/v1/auth/login` | `AuthController.login/2` | No | `:api_cors` |
| DELETE | `/api/v1/auth/session` | `AuthController.logout/2` | Yes | `:api_session` |
| GET | `/api/v1/versions` | `VersionController.index/2` | Yes | `:api_session` |
| GET | `/api/v1/versions/:version_id/stations` | `StationController.index/2` | Yes | `:api_session` |
| GET | `/api/v1/versions/:version_id/stations/:station_id/bundle` | `StationController.bundle/2` | Yes | `:api_session` |
| POST | `/api/v1/versions/:version_id/stations/:station_id/sync` | `SyncController.create/2` | Yes | `:api_session` |

### Authentication Model

- Login is unauthenticated; all other POST/GET/DELETE routes require a valid Bearer token.
- The `:api_cors` pipeline applies `GtfsPlannerWeb.Plugs.CORS` (origin check + CORS headers) and `plug :accepts, ["json"]`.
- The `:api_session` pipeline adds `GtfsPlannerWeb.Plugs.VerifyApiSession` (Bearer token extraction and validation) and `GtfsPlannerWeb.Plugs.AssignApiOrganization` (organization resolution).
- Post-auth assigns available to controllers: `conn.assigns.current_user`, `conn.assigns.current_user_id`, `conn.assigns.api_session_token`, `conn.assigns.current_organization_id`.
- The login endpoint is deliberately excluded from `:api_session` — it only runs through `:api_cors`.

### Evidence

- `lib/gtfs_planner_web/router.ex:145-183` — pipeline and route definitions.
- `lib/gtfs_planner_web/plugs/verify_api_session.ex:1-45` — token extraction and validation.
- `lib/gtfs_planner_web/plugs/assign_api_organization.ex:1-118` — organization resolution logic.
- `lib/gtfs_planner_web/plugs/cors.ex:1-53` — CORS origin filtering and preflight response.

---

## 3. Data Models & Structures

### Request Parameters

**Login (`POST /api/v1/auth/login`)**:
- Body (JSON): `{"email": string, "password": string}`
- Both fields required; missing either → 400 `bad_request`

**Station index (`GET /api/v1/versions/:version_id/stations`)**:
- Query params: `search` (optional string, filters `stop_name` substring), `page` (integer ≥1, defaults to 1), `per_page` (integer 1–100, defaults to 25)

**Sync (`POST /api/v1/versions/:version_id/stations/:station_id/sync`)**:
- Body (JSON): `{"pathways": [{"id": uuid, ...editable_fields}]}`
- `pathways` key is required; missing → 400 `bad_request`

### Response Shapes

**Login success (200)**:
```json
{
  "data": {
    "token": "<bearer token string>",
    "user": {"id": "<uuid>", "email": "string"},
    "organization_id": "<uuid>",
    "expires_at": "ISO8601 string"
  }
}
```

**Station index (200)**:
```json
{
  "data": [
    {
      "id": "<uuid>",
      "stop_id": "string",
      "stop_name": "string",
      "child_stop_count": int,
      "pathway_count": int,
      "level_count": int
    }
  ],
  "meta": {"total": int, "page": int, "per_page": int}
}
```

**Station bundle (200)**:
```json
{
  "data": {
    "station": {"id": "<uuid>", "stop_id": "string", "stop_name": "string", "lat": number|null, "lon": number|null},
    "levels": [{"id": "<uuid>", "level_id": "string", "level_index": float, "level_name": "string", "floorplan": object|null}],
    "stops": [{"id": "<uuid>", "stop_id": "string", "stop_name": "string", "location_type": int, "level_id": string|null, "parent_station": string|null, "wheelchair_boarding": int|null, "platform_code": string|null, "diagram_coordinate": string|null, "lat": number|null, "lon": number|null}],
    "pathways": [{"id": "<uuid>", "pathway_id": "string", "pathway_mode": int, "is_bidirectional": bool, "from_stop_id": "string", "to_stop_id": "string", "length": number|null, "traversal_time": int|null, "stair_count": int|null, "max_slope": number|null, "min_width": number|null, "signposted_as": "string|null", "reversed_signposted_as": "string|null", "field_notes": "string|null", "field_completed_at": "ISO8601|null"}],
    "diagrams": [],
    "downloaded_at": "ISO8601 string"
  }
}
```

**Floorplan sub-object** (inside level, when diagram exists):
```json
{
  "filename": "string",
  "url": "absolute URL to /uploads/diagrams/...",
  "center_lat": number|null,
  "center_lon": number|null,
  "scale_mpp": number|null,
  "rotation_deg": number|null
}
```
Alignment fields are all present together only when `StopLevel.alignment_complete?/1` returns true; otherwise all four are `null`.

**Sync response (200)**:
```json
{
  "data": {
    "synced_count": int,
    "synced_at": "ISO8601 string",
    "errors": [{"id": "string", "code": "string", "message": "string"}] // only present when errors exist
  }
}
```

**All error responses** follow the shape `{"error": {"code": "string", "message": "string"}}`.

### Editable Fields for Sync

The sync controller allows updating only these fields (from `@editable_fields`):
- `traversal_time` (integer)
- `stair_count` (integer)
- `min_width` (Decimal)
- `signposted_as` (string)
- `reversed_signposted_as` (string)
- `field_notes` (string)
- `field_completed_at` (ISO8601 datetime string)

Plus the `from_stop_id`/`to_stop_id` pair (only for direction reversal).

### Evidence

- `lib/gtfs_planner_web/api/v1/auth_controller.ex:34-89` — request/response shapes for login.
- `lib/gtfs_planner_web/api/v1/station_controller.ex:15-63,67-117` — response shapes for index and bundle.
- `lib/gtfs_planner_web/api/v1/sync_controller.ex:7,95-109` — editable fields and sync response shape.
- `lib/gtfs_planner_web/api/v1/version_controller.ex:7-21` — version list response shape.

---

## 4. Behavioral Contracts

### 4A. Decision Logic, Business Rules & Policy Surface

#### Authorization & Organization Resolution

1. **Bearer token extraction**: `VerifyApiSession` extracts the token from the `Authorization: Bearer <token>` header. Missing or malformed header → 401 `unauthorized`. Empty token string → 401.
2. **Token validation**: Tokens are hashed (SHA-256), looked up in the `user_tokens` table with context `"api_session"`, and must not exceed 60 days since `inserted_at`. (Evidence: `lib/gtfs_planner/accounts/user_token.ex:19,115-120`)
3. **Organization resolution**: After authentication, `AssignApiOrganization` resolves the org:
   - If `X-Organization-Id` header present → validates UUID format, then checks membership. If not a member → 403 `forbidden`. If invalid UUID → 400 `bad_request`.
   - If header absent → auto-selects the user's sole membership (1 org). If 0 orgs → 403 `no_organization`. If >1 org → 403 `organization_required` with `available_organization_ids` in response.
4. **Organization-scoped data access**: Controllers use `conn.assigns.current_organization_id` and check that fetched resources (`version.organization_id`, `station.organization_id`, `Pathway.organization_id`) match. Mismatch returns 404 (not 403) to avoid leaking existence information.
5. **Login organization selection**: On login, the controller picks the user's first membership (`Enum.at(memberships, 0)`) — deterministic but not configurable. A user with no memberships gets 403 `no_organization`. (Evidence: `lib/gtfs_planner_web/api/v1/auth_controller.ex:54-58`)

#### Login Timing Side-Channel Defense

The login endpoint enforces an 800ms minimum response time (`@login_floor_ms`) to mitigate timing attacks. If credential validation returns faster than 800ms, the server sleeps for the remainder. This applies uniformly regardless of success/failure.

#### Station Index Filtering

- Only stops with `location_type == 1` (stations, per GTFS spec) are returned. This filter is hardcoded in the `list_opts` and `count_opts`.
- The `search` parameter filters by `stop_name` substring match at the query level. (Evidence: `lib/gtfs_planner_web/api/v1/station_controller.ex:25-26`)

#### Station Bundle Validation Chain

The `with` chain in `bundle/2` validates in order:
1. `version_id` is a valid UUID
2. `station_id` is a valid UUID
3. Version exists
4. Version belongs to the current user's organization
5. Station exists
6. Station belongs to the current user's organization
7. Station belongs to the requested version (`station.gtfs_version_id == version_id`)
8. Station has `location_type == 1` (is a station, not a stop/platform)
9. Station has `parent_station == nil` (is a top-level station, not a child)

Any failure returns 400 for UUID format errors, 404 for any other failure. This is a hard gate — you cannot request a bundle for a non-station stop.

#### Pathway Endpoint Swap Only Rule

The sync controller enforces a strict "reverse only, never rewire" policy for `from_stop_id`/`to_stop_id`:
- If neither field is present → no-op on endpoints, other fields still applied.
- If both fields are present:
  - Matching the stored pair exactly → no-op on endpoints (accepted, other fields applied).
  - Matching the stored pair reversed → endpoints are swapped (and other fields applied atomically in the same update).
  - Any other value pair → `invalid_endpoints` error, **no fields are applied** (the entire update for that pathway is rejected).
- If only one of the two fields is present → `invalid_endpoints` error, no fields applied.

This is documented with a comment referencing the companion app's `specs/api/sync.md`.

#### Floorplan Serialization

- A floorplan is emitted when and only when the `StopLevel` record has a non-empty `diagram_filename`.
- The diagram URL is constructed as an absolute URL using `Endpoint.url()` with the path `/uploads/diagrams/{org_id}/{encoded_storage_dir}/{encoded_filename}`.
- The storage directory is computed via `PathSafety.stop_storage_dir(station_stop_id)` which encodes the station's `stop_id` (e.g., `sid_{base64url(stop_id)}`).
- The filename is URI-encoded for the URL.
- If `PathSafety.stop_storage_dir` returns `nil` (non-binary), the URL is `nil` and the floorplan is serialized as `nil`.
- Alignment fields (`center_lat`, `center_lon`, `scale_mpp`, `rotation_deg`) are included only when `StopLevel.alignment_complete?/1` returns true; otherwise all four are `null`. This follows the "diagram is primary, geo-alignment is enrichment" principle.
- The `diagrams` array in the bundle response is always `[]` (legacy field preserved for companion client compatibility).

#### Coordinate Serialization

- `Decimal` values are converted to floats via `Decimal.to_float/1`.
- `nil` values remain `nil`.
- If either `stop_lat` or `stop_lon` is `nil`, both coordinates serialize as `nil` (the pair is considered incomplete). This applies at the top-level `serialize_coordinates/2` function.

#### Version Listing

- `created_at` in the response is sourced from `version.inserted_at` (Ecto timestamp), not a separate `created_at` field.

### 4B. Policy Tests & Behavioral Scenarios

The following scenarios are covered by tests:

**Auth Controller**:
1. Valid credentials return token + user + org_id + expires_at (200)
2. Invalid password returns 401 with `invalid_credentials`
3. Nonexistent email returns 401 with `invalid_credentials` (same error shape as wrong password — does not leak user existence)
4. User with no org membership returns 403 `no_organization`
5. Deactivated user returns 403 `no_organization` (deactivated memberships filtered at query level)
6. Missing email or password returns 400 `bad_request`
7. Logout revokes the token (subsequent lookup fails)

**Version Controller**:
1. Returns versions scoped to authenticated user's organization
2. Does not return versions from other organizations
3. Returns 401 without auth token

**Station Controller — Index**:
1. Returns stations with correct counts (child_stop_count, pathway_count, level_count)
2. Returns 404 for nonexistent version
3. Returns 404 for version belonging to another org
4. Returns 400 for invalid UUID format in version_id
5. Filtering: only `location_type=1` rows returned, meta.total reflects filtered count
6. Pagination: page=2&per_page=2 returns correct slice
7. per_page=1000 clamps to 100
8. per_page=0, per_page=abc defaults to 25
9. page=-5, page=abc defaults to 1
10. search filters by stop_name substring
11. Mixed location_type data returns only stations

**Station Controller — Bundle**:
1. Full bundle returns station, levels, stops, pathways
2. Station coordinates serialize as numbers
3. Stop coordinates serialize Decimal values as numbers and nil as null
4. Level floorplan with complete alignment carries url + all alignment fields
5. Level floorplan with diagram but incomplete alignment carries url + null alignment fields
6. Level floorplan with no diagram is null
7. Floorplan URL uses encoded storage directory for unsafe station stop_id
8. Pathway serialization includes field_notes and field_completed_at
9. downloaded_at is a valid ISO8601 string
10. 404 for station belonging to another org
11. 400 for invalid UUID in station_id
12. 400 for invalid UUID in version_id
13. 404 for location_type=0 stop (not a station)
14. 200 with expected shape for location_type=1 station

**Sync Controller**:
1. Syncs editable fields successfully (traversal_time, signposted_as, field_notes, field_completed_at)
2. Does not modify read-only fields (pathway_mode)
3. Endpoint pair matching stored order is accepted (no-op on endpoints)
4. Swapped endpoint pair reverses the pathway atomically with other fields
5. Foreign endpoint pair rejected with invalid_endpoints, no fields applied
6. Partial endpoint pair (only one field) rejected
7. Pathway ID from another org returns not_found error
8. Invalid UUID returns invalid_id error
9. Missing pathways array returns 400
10. Partial failure: some succeed, some fail, response reports both synced_count and errors

### Evidence

- `test/gtfs_planner_web/api/v1/auth_controller_test.exs:1-153`
- `test/gtfs_planner_web/api/v1/version_controller_test.exs:1-80`
- `test/gtfs_planner_web/api/v1/station_controller_test.exs:1-690`
- `test/gtfs_planner_web/api/v1/sync_controller_test.exs:1-373`

---

## 5. State Management

These controllers are **stateless** — they do not maintain server-side state between requests. All state is passed through:

1. **`conn.assigns`** — set by pipeline plugs (`current_user`, `current_user_id`, `api_session_token`, `current_organization_id`). Controllers read from assigns but never modify them (except `AuthController.logout/2` which reads `api_session_token`).
2. **Database** — all persistent state lives in Ecto-backed tables (users, user_tokens, organizations, memberships, stops, levels, stop_levels, pathways, gtfs_versions). Controllers are pure readers/writers to the database via context modules (`Accounts`, `Gtfs`, `Versions`, `Repo`).
3. **Token state** — API session tokens are created on login (persisted to `user_tokens` table) and deleted on logout. Token expiry is enforced by a 60-day TTL checked in the query.

No in-memory caches, ETS tables, or process state are used by these controllers.

### Evidence

- No `GenServer`, `Agent`, `ETS`, or process dictionary usage in any controller file.
- `lib/gtfs_planner/accounts/user_token.ex:19,115-120` — API session token TTL of 60 days.
- `lib/gtfs_planner/accounts.ex:303-341` — token generation, verification, and deletion.

---

## 6. Dependencies

### Direct Module Dependencies

| Controller | Depends On |
|------------|-----------|
| `AuthController` | `GtfsPlanner.Accounts`, `Plug.Conn`, `Phoenix.Controller` |
| `VersionController` | `GtfsPlanner.Versions`, `Plug.Conn`, `Phoenix.Controller` |
| `StationController` | `GtfsPlanner.Gtfs`, `GtfsPlanner.Gtfs.Extensions.PathSafety`, `GtfsPlanner.Gtfs.StopLevel`, `GtfsPlanner.Versions`, `GtfsPlannerWeb.Endpoint`, `Plug.Conn`, `Phoenix.Controller`, `Ecto.UUID` |
| `SyncController` | `GtfsPlanner.Repo`, `GtfsPlanner.Gtfs.Pathway`, `Plug.Conn`, `Phoenix.Controller`, `Ecto.UUID` |
| `FallbackController` | `Plug.Conn`, `Phoenix.Controller` |

### Pipeline Plug Dependencies

All authenticated controllers depend on these plugs being run before them:
- `GtfsPlannerWeb.Plugs.CORS` — sets CORS response headers, handles OPTIONS preflight
- `GtfsPlannerWeb.Plugs.VerifyApiSession` — extracts and validates Bearer token, assigns `current_user`, `current_user_id`, `api_session_token`
- `GtfsPlannerWeb.Plugs.AssignApiOrganization` — resolves organization, assigns `current_organization_id`

### External Service Dependencies

- `GtfsPlannerWeb.Endpoint.url()` — used by `StationController.floorplan_url/3` to construct absolute URLs. Depends on the endpoint's configured `:url` (host, port, scheme).

### Evidence

- `lib/gtfs_planner_web/api/v1/auth_controller.ex:1-5` — `use GtfsPlannerWeb, :controller`, alias `Accounts`
- `lib/gtfs_planner_web/api/v1/station_controller.ex:1-8` — aliases for `Gtfs`, `PathSafety`, `StopLevel`, `Versions`, `Endpoint`
- `lib/gtfs_planner_web/api/v1/sync_controller.ex:1-5` — aliases for `Repo`, `Pathway`
- `lib/gtfs_planner_web/router.ex:150-155` — `:api_session` pipeline composition

---

## 7. Side Effects & I/O

### Database Reads

| Operation | Context Function(s) Called |
|-----------|---------------------------|
| Login | `Accounts.get_user_by_email_and_password/2`, `Accounts.list_user_org_memberships/1`, `Accounts.generate_api_session_token/1` |
| Logout | `Accounts.delete_api_session_token/1` |
| Version list | `Versions.list_gtfs_versions/1` |
| Station index | `Versions.get_gtfs_version/1`, `Gtfs.list_stations/4`, `Gtfs.count_stations/4`, `Gtfs.list_child_stops_for_parent/4`, `Gtfs.list_levels_for_station/4`, `Gtfs.list_pathways_for_station/4` |
| Station bundle | `Versions.get_gtfs_version/1`, `Gtfs.get_stop/1`, `Gtfs.list_child_stops_for_parent/4`, `Gtfs.list_levels_for_station/4`, `Gtfs.list_pathways_for_station/4` |
| Sync | `Repo.get_by(Pathway, ...)` for each pathway ID, `Repo.update(changeset)` for valid updates |

### Database Writes

| Operation | Effect |
|-----------|--------|
| Login success | Inserts a `UserToken` record via `Accounts.generate_api_session_token/1` → `Repo.insert!/1` |
| Logout | Deletes the `UserToken` record via `Accounts.delete_api_session_token/1` → `Repo.delete_all/1` |
| Sync success | Updates `Pathway` records via `Repo.update/1` with `Pathway.changeset/2` |

### Side Effects

1. **Timing side-channel mitigation**: `AuthController.login/2` sleeps for up to 800ms using `Process.sleep/1` to enforce a constant minimum response time. This is a deliberate blocking side effect.
2. **`DateTime.utc_now()` calls**: Station bundle includes `downloaded_at`, sync response includes `synced_at`, and login sets `expires_at` — all use `DateTime.utc_now()`. These are non-deterministic timestamps embedded in the response.
3. **Endpoint.url()**: Station bundle floorplan URLs depend on runtime endpoint configuration.

### Evidence

- `lib/gtfs_planner_web/api/v1/auth_controller.ex:11-20` — Process.sleep for timing defense.
- `lib/gtfs_planner_web/api/v1/auth_controller.ex:40-43` — expires_at computation.
- `lib/gtfs_planner_web/api/v1/station_controller.ex:103` — downloaded_at in bundle.
- `lib/gtfs_planner_web/api/v1/sync_controller.ex:98` — synced_at in sync response.

---

## 8. Error Handling & Failure Modes

### Error Response Format

All error responses are JSON with shape:
```json
{"error": {"code": "string", "message": "string"}}
```

Some also include additional fields (e.g., `available_organization_ids` in `organization_required`). Sync errors are embedded in the data payload as `data.errors` rather than using a top-level error envelope.

### Error Codes and Conditions

| HTTP Status | Error Code | Trigger |
|-------------|-----------|---------|
| 400 | `bad_request` | Missing email/password in login, missing pathways array in sync, invalid UUID format in version_id or station_id |
| 401 | `unauthorized` | Missing/invalid Bearer token, empty token |
| 401 | `invalid_credentials` | Wrong email or password |
| 403 | `no_organization` | Authenticated user has no organization memberships (login) |
| 403 | `forbidden` | `X-Organization-Id` header specifies an org the user doesn't belong to |
| 403 | `organization_required` | Multi-org user didn't specify `X-Organization-Id` header |
| 403 | `no_organization` | User has no memberships (AssignApiOrganization plug) |
| 404 | `not_found` | Version/station not found, resource belongs to another org, station is not location_type=1 |

### Sync-Specific Error Handling

The sync endpoint uses a **partial success model**: it processes all pathways in the array independently and returns:
- `synced_count`: number of successfully updated pathways
- `errors`: array of per-pathway errors (only present if any failures)

Per-pathway error codes:
- `invalid_id` — pathway ID is not a valid UUID
- `not_found` — pathway ID is valid UUID but no Pathway record found for this org
- `invalid_endpoints` — endpoint swap validation failed (foreign endpoints, partial pair)
- `validation_error` — `Pathway.changeset/2` + `Repo.update/1` returned an error

For `invalid_endpoints`, **all fields in that pathway update are rejected** — the update is atomic per-pathway.

### Observer Note

The sync controller always returns HTTP 200 even when some or all pathways fail. The caller must inspect `data.synced_count` and `data.errors` to determine success. This is by design — it's a batch operation.

### Plugs' Error Behavior

- `VerifyApiSession` halts the connection with `send_resp(401, ...)` and does not proceed to the controller.
- `AssignApiOrganization` halts with 400 (invalid org ID UUID), 403 (forbidden/no_org/multi-org), or 401 (if somehow `current_user` is absent despite passing `VerifyApiSession` — defensive fallback).

### Evidence

- `lib/gtfs_planner_web/api/v1/auth_controller.ex:61-90` — error response generation.
- `lib/gtfs_planner_web/api/v1/sync_controller.ex:24-109` — per-pathway error accumulation.
- `lib/gtfs_planner_web/plugs/assign_api_organization.ex:41-116` — plug-level error halts.
- `lib/gtfs_planner_web/plugs/verify_api_session.ex:39-44` — plug-level unauthorized halt.

---

## 9. Integration Points & Data Flow

### Request Flow (Authenticated)

```
Client (companion app)
  → Phoenix Endpoint
    → Router matches route, applies pipeline
      → CORS plug (origin check, CORS headers)
      → VerifyApiSession plug (Bearer token → current_user assign)
      → AssignApiOrganization plug (org resolution → current_organization_id assign)
      → Controller action (reads assigns, calls context modules, returns JSON)
```

### Request Flow (Login)

```
Client (companion app)
  → Phoenix Endpoint
    → Router matches POST /api/v1/auth/login
      → :api_cors pipeline (CORS plug, accepts JSON)
      → AuthController.login/2
        → Accounts.get_user_by_email_and_password/2
        → Accounts.list_user_org_memberships/1
        → Accounts.generate_api_session_token/1 (inserts UserToken)
```

### Cross-Module Data Flow

1. **Auth → Station/Version/Sync controllers**: The API session token generated by `AuthController` is sent as a Bearer token in subsequent requests, validated by `VerifyApiSession`, which fetches the user via `Accounts.get_user_by_api_session_token/1`.
2. **Station bundle → UploadsPlugs**: Floorplan URLs reference `/uploads/diagrams/...` which are served by `GtfsPlannerWeb.UploadsPlug` (endpoint-level plug). The URL encoding must match what `UploadsPlug` expects (organization-scoped directory with base64url-encoded stop_id).
3. **Sync → Pathway.changeset**: The sync controller manually constructs changeset attrs by whitelisting only `@editable_fields` and then merging endpoint changes. This bypasses the normal cast-based whitelisting but still goes through `Pathway.changeset/2` for validation.

### Evidence

- `lib/gtfs_planner_web/router.ex:145-183` — pipeline composition and route wiring.
- `lib/gtfs_planner_web/api/v1/auth_controller.ex:37-38` — token generation.
- `lib/gtfs_planner_web/api/v1/sync_controller.ex:56-62` — manual attr whitelisting before changeset.
- `lib/gtfs_planner_web/api/v1/station_controller.ex:169-179` — floorplan URL construction.
- `lib/gtfs_planner_web/plugs/uploads_plug.ex:31-34` — UploadsPlug applies CORS itself.

---

## 10. Edge Cases & Implicit Behavior

### Inferred / Observed Edge Cases

1. **Login with deactivated user**: A deactivated membership is filtered at the query level in `Accounts.list_user_org_memberships/1`, so the user appears to have no organization → returns 403 `no_organization`. The test confirms this behavior is considered correct. (Evidence: `test/gtfs_planner_web/api/v1/auth_controller_test.exs:108-117`)
2. **Station index with empty search results**: Returns empty data array with meta.total = 0. Implied by pagination behavior — no special empty-state handling in controller.
3. **Station bundle with no child stops/levels/pathways**: Returns empty arrays for those sections. No special handling needed.
4. **Station bundle for station with no coordinates**: Serialized as `"lat": null, "lon": null`. This is the camera fallback case for the companion — documented in code comments.
5. **Floorplan with diagram but no storage directory**: If `PathSafety.stop_storage_dir/1` returns `nil` (non-binary), the `floorplan_url/3` returns `nil`, and the floorplan serializes as `nil` even though a `diagram_filename` exists. This could happen for stop_ids that don't pass `PathSafety` validation.
6. **Floorplan URL double-encoding**: The filename is URI-encoded, and the storage directory is computed from `PathSafety.stop_storage_dir/1` which produces a base64url-encoded stop_id. There's no re-encoding of the directory component — it's used raw in the URL string.
7. **Sync with empty pathways array**: `Enum.reduce([], initial_acc, ...)` returns the initial accumulator → `synced_count: 0, errors: []`. Since errors is empty, the response has no `errors` key. This is arguably inconsistent with missing-pathways-array returning 400, but empty array returns 200 with zero synced.
8. **Sync with duplicate pathway IDs**: Each occurrence is processed independently. If the same pathway ID appears twice with different field values, the second update wins (last-write-wins). This is implicit — no deduplication or conflict detection.
9. **Token expiry**: The 60-day TTL is enforced at query time (`inserted_at > ago(60, "day")`). If a user's token is within the 60-day window but the user_tokens record was manually deleted, the token is simply invalid (returns nil, plug halts with 401).
10. **Race between login and token use**: The token is inserted before responding, so it's valid immediately. No distributed consistency concerns since it's a single-node database operation.
11. **Concurrent sync updates**: No optimistic locking or version checking. Concurrent updates from multiple clients will last-write-wins at the database level. Ecto timestamps (`updated_at`) are updated on each write.
12. **Station index N+1 queries**: For each station in the result set, the controller makes 3 additional queries (`list_child_stops_for_parent`, `list_levels_for_station`, `list_pathways_for_station`). With default per_page=25, this means up to 75 additional queries per request.
13. **Organization isolation via URI path**: The `version_id` and `station_id` in the URL path are not sufficient for org isolation — the controller always cross-checks against `current_organization_id`. A user from org A requesting `version_id` of org B's version gets 404, not 403.

### Confidence Notes

- **High confidence**: Edge cases 1–5, 7, 9–11, 13 — directly observable from code and tests.
- **Medium confidence**: Edge cases 6, 8, 12 — inferred from code structure; tests don't explicitly cover these.

---

## 11. Open Questions & Ambiguities

1. **Login organization selection is first-membership-only**: `AuthController.first_membership/1` picks `Enum.at(memberships, 0)`. For multi-org users, this is non-deterministic with respect to user intent — they cannot choose which org to log into. Is this intentional or an acknowledged limitation?
2. **Sync endpoint ignores version_id/station_id in URL**: The sync controller pattern-matches `version_id` and `station_id` in the function head but never uses them. It filters pathways solely by `organization_id`. This means any authenticated user can sync any pathway in their org regardless of which station/version URL they hit. Is this deliberate or should the endpoint scope updates to the specified station?
3. **Sync always returns 200 even on total failure**: If all pathways in the batch fail, the response is still HTTP 200 with `synced_count: 0` and an errors array. Should there be a threshold where the status code changes (e.g., 422)?
4. **Station index N+1 query performance**: Each station in the index triggers 3 additional queries. For large station lists, this could be a performance concern. Should counts be preloaded or denormalized?
5. **Floorplan URL construction reliability**: `Endpoint.url()` depends on the endpoint's `:url` configuration. If this is misconfigured (e.g., wrong scheme in production), floorplan URLs will be incorrect. Is there a fallback or validation?
6. **`diagrams` array is always empty**: The bundle response includes `"diagrams": []` as a legacy field. What was this field originally for? Is it safe to remove, or does the companion app still expect it?
7. **No rate limiting**: There is no rate limiting on any API endpoint. Is this handled at the infrastructure level (load balancer, reverse proxy) or is it an accepted risk?
8. **Token TTL is hardcoded**: The 60-day token expiry is defined in both `AuthController` (`@token_ttl_days 60`) and `UserToken` (`@api_session_validity_in_days 60`). These are independent constants — a change must be made in two places. Is this duplication intentional?
9. **FallbackController preflight comment**: The comment says "OPTIONS preflight is handled by the CORS plug before reaching this action, but Phoenix needs a controller action to match the route." The CORS plug indeed halts for OPTIONS, so `FallbackController.preflight/2` should never actually execute. Is this dead code or a safety net?
10. **Pathway changeset bypass for editable fields**: The sync controller manually constructs attrs by taking `Map.take` of string-keyed params and converting keys to atoms with `String.to_existing_atom/1`. This means if any key in the whitelist doesn't exist as an atom in the system, it would raise. The `@editable_fields` module attribute is the source of truth for this — is there a risk of drift between `@editable_fields` and `Pathway.changeset/2`'s cast fields?
