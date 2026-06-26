# Companion API Controllers Agent Doc

Source target: `lib-gtfs-planner-web-api`
Scope: Serves the JSON companion API for login, GTFS versions, station bundles, CORS preflight, and pathway sync updates.
Deep analysis: [`lib-gtfs-planner-web-api.md`](../analysis/lib-gtfs-planner-web-api.md)
Freshness: `source_hash=dd533899b58837342646f3ea88321cde78794dedccb4609cf5b7a8fa084a3dca`, `last_synthesized=null`

## Use When
- Modifying any companion API endpoint or pipeline (auth, versions, stations, sync, CORS).
- Changing organization-scoping, Bearer token auth, login, or logout logic.

## Read First
- `lib/gtfs_planner_web/router.ex:145-183` — all API v1 routes, pipeline composition (`:api_cors`, `:api_session`).
- `lib/gtfs_planner_web/api/v1/station_controller.ex` — most complex controller (index + bundle + floorplan URLs + N+1 query pattern).
- `lib/gtfs_planner_web/api/v1/sync_controller.ex` — partial-success batch update with editable field whitelisting + endpoint-swap-only policy.

## Interfaces

### Routes & Pipelines

| Method | Pipeline | Controller.action | Auth |
|--------|----------|-------------------|------|
| OPTIONS `*` | `:api_cors` | `FallbackController.preflight` | No |
| POST `auth/login` | `:api_cors` | `AuthController.login` | No |
| DELETE `auth/session` | `:api_session` | `AuthController.logout` | Yes |
| GET `versions` | `:api_session` | `VersionController.index` | Yes |
| GET `versions/:vid/stations` | `:api_session` | `StationController.index` | Yes |
| GET `versions/:vid/stations/:sid/bundle` | `:api_session` | `StationController.bundle` | Yes |
| POST `versions/:vid/stations/:sid/sync` | `:api_session` | `SyncController.create` | Yes |

### Pipeline Plugs (set `conn.assigns`, run before controllers)

| Plug | Assigns Set | Halts On |
|------|------------|----------|
| `CORS` (`plugs/cors.ex`) | CORS headers; handles OPTIONS preflight | — |
| `VerifyApiSession` (`plugs/verify_api_session.ex`) | `current_user`, `current_user_id`, `api_session_token` | 401 |
| `AssignApiOrganization` (`plugs/assign_api_organization.ex`) | `current_organization_id` | 400 (bad UUID), 403 (forbidden/no-org/multi-org) |

### Context Module Dependencies

| Controller | Key Context Functions |
|-----------|----------------------|
| `AuthController` | `Accounts` — get_user_by_email_and_password, list_user_org_memberships, generate/delete API session token |
| `VersionController` | `Versions` — list_gtfs_versions |
| `StationController` | `Versions` — get_gtfs_version; `Gtfs` — list_stations, count_stations, list_child_stops_for_parent, list_levels_for_station, list_pathways_for_station, get_stop; `PathSafety`, `StopLevel`, `Endpoint.url()` |
| `SyncController` | `Repo` — get_by, update; `Pathway` — changeset |
| `FallbackController` | None (dead code — CORS plug halts before it executes) |

## Rules & Invariants

### Auth & Org Resolution
- Login has no auth; all other routes require valid Bearer token (SHA-256 hashed, 60-day TTL).
- **Timing defense**: 800ms minimum response time via `Process.sleep/1`, uniform for success/failure.
- **Login org selection**: picks first membership (`Enum.at(memberships, 0)`) — deterministic, not user-selectable.
- **AssignApiOrganization plug**: `X-Organization-Id` header → validate UUID + membership (not a member → 403). No header → uses sole membership; 0 orgs → 403; >1 org → 403 with `available_organization_ids`.
- All data-access controllers cross-check `resource.organization_id == current_organization_id`. Mismatch returns **404** (not 403) to avoid leaking existence.

### Station Index
- Only `location_type == 1` rows returned (GTFS stations, not stops/platforms). Hardcoded in list_opts/count_opts.
- `search` param filters by `stop_name` substring at query level.
- Pagination: `page` ≥1 (default 1), `per_page` 1–100 (default 25). Out-of-range clamps or defaults.
- **N+1 query pattern**: for each station, 3 additional queries (child stops, levels, pathways). With default per_page=25, up to 75 extra queries per request.

### Station Bundle Validation Chain (order matters)
1. `version_id` is valid UUID → else 400
2. `station_id` is valid UUID → else 400
3. Version exists → else 404
4. Version belongs to current org → else 404
5. Station exists → else 404
6. Station belongs to current org → else 404
7. Station belongs to version (`station.gtfs_version_id == version_id`) → else 404
8. Station is `location_type == 1` → else 404
9. Station has `parent_station == nil` (top-level, not a child) → else 404

### Station Bundle Serialization
- Coordinates: `Decimal.to_float/1`; `nil` if either lat or lon missing (pair considered incomplete).
- Floorplan: emitted only when `diagram_filename` non-empty. URL = `Endpoint.url()` + `/uploads/diagrams/{org_id}/{encoded_storage_dir}/{uri_encoded_filename}`. Storage dir via `PathSafety.stop_storage_dir(station_stop_id)` (base64url stop_id). If `PathSafety` returns non-binary, floorplan is `nil`.
- Alignment fields: all four present only when `StopLevel.alignment_complete?/1` is true; otherwise all `null`.
- `diagrams` array always `[]` (legacy field for companion client compatibility).

### Sync Endpoint
- **Editable fields** (whitelist via `@editable_fields`): `traversal_time`, `stair_count`, `min_width`, `signposted_as`, `reversed_signposted_as`, `field_notes`, `field_completed_at`.
- **Endpoint swap rule**: only `from_stop_id`/`to_stop_id` reversal allowed; any other pair → `invalid_endpoints`, entire pathway update rejected. Partial pair (only one) also rejected.
- **version_id and station_id in the URL are ignored** — sync filters pathways only by `organization_id`.
- Sync always returns HTTP 200 (even on total failure). Caller inspects `data.synced_count` and `data.errors`.
- No deduplication on duplicate pathway IDs; no optimistic locking — last-write-wins at DB level.

## State, I/O & Side Effects

**All controllers are stateless** — state in `conn.assigns` (set by plugs) and Ecto-backed DB. No GenServer, Agent, ETS, or process dict.

| Operation | DB Write | Side Effect |
|-----------|---------|-------------|
| Login | Insert `UserToken` row | `Process.sleep` up to 800ms; `DateTime.utc_now()` for `expires_at` |
| Logout | Delete `UserToken` row | — |
| Sync | Update `Pathway` rows | `DateTime.utc_now()` for `synced_at` |
| Bundle (read) | — | `DateTime.utc_now()` for `downloaded_at`; `Endpoint.url()` dependency |

## Failure Modes

### Error Response Shape
All errors: `{"error": {"code": "string", "message": "string"}}`. Sync errors in `data.errors` array, not top-level.

### Key Error Codes
| HTTP | Code | When |
|------|------|------|
| 400 | `bad_request` | Missing body fields, missing pathways array, invalid UUID |
| 401 | `unauthorized` | Missing/invalid/empty Bearer token |
| 401 | `invalid_credentials` | Wrong email or password (same error for both — does not leak user existence) |
| 403 | `no_organization` | User has no org memberships (login or AssignApiOrganization) |
| 403 | `forbidden` | X-Organization-Id specifies non-member org |
| 403 | `organization_required` | Multi-org user omitted X-Organization-Id |
| 404 | `not_found` | Resource missing, wrong org (org scoping), station not location_type=1 |

### Sync-Specific
- `invalid_id`, `not_found`, `invalid_endpoints`, `validation_error` — per-pathway errors embedded in `data.errors` array.
- Plug halts (`VerifyApiSession`, `AssignApiOrganization`) stop the pipeline — controller never runs.

## Change Checklist
- [ ] New routes added to `:api_session` pipeline (never `:api_cors` unless intentionally unauthenticated).
- [ ] New sync fields added to `@editable_fields` in `SyncController` **and** `Pathway.changeset/2` cast.
- [ ] Organization-scoped queries compare `resource.organization_id == current_organization_id`; mismatch → 404.
- [ ] Bundle validation chain in `StationController.bundle/2` preserved in order (9-step `with` chain).
- [ ] Floorplan URL construction matches `UploadsPlug` expectations (directory encoding, URI encoding).
- [ ] Login timing defense preserved at 800ms minimum.
- [ ] Station index still filters `location_type == 1` after query changes.
- [ ] Token TTL updated in both `AuthController` (`@token_ttl_days`) and `UserToken` (`@api_session_validity_in_days`).
- [ ] Tests for new behavior; existing test files: `test/gtfs_planner_web/api/v1/{auth,version,station,sync}_controller_test.exs`.

## Escalate To Deep Analysis
- Login multi-org selection (first-membership-only) — intentional?
- Sync endpoint ignoring URL `version_id`/`station_id` — deliberate or should it scope to station?
- Sync 200-on-total-failure — should a threshold change HTTP status?
- Station index N+1 query performance — preload/denormalize counts?
- Floorplan URL: `Endpoint.url()` with misconfigured `:url` — fallback needed?
- `diagrams` array always `[]` — can it be removed or does companion client require it?
- No rate limiting — infrastructure-level or accepted risk?
- Token TTL duplicated in `AuthController` and `UserToken` — intentional?
- `FallbackController.preflight/2` — dead code or safety net?
- `@editable_fields` vs `Pathway.changeset/2` cast field drift risk?
