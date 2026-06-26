# API and Upload Plugs Agent Doc

Source target: `lib-gtfs-planner-web-plugs`
Scope: Defines request plugs for CORS, companion API session verification, organization assignment, and upload handling.
Deep analysis: [`docs/specops/analysis/lib-gtfs-planner-web-plugs.md`](../analysis/lib-gtfs-planner-web-plugs.md)
Freshness: `source_hash=sha256:02f695f3946271ff648791130d131475beccdac06ba94b95c00623d9499f4123`, `last_synthesized=null`

## Use When
- Adding or modifying CORS rules for the companion API or uploads
- Changing API authentication (Bearer token verification, session context, TTL)
- Adjusting organization resolution logic (X-Organization-Id header handling, auto-assign fallback)
- Modifying upload file serving (path traversal, CORS, routing)
- Adding new plugs to the `:api_cors` or `:api_session` router pipelines
- Debugging 401/403/400 JSON error responses from the companion API
- Changing which `Accounts` functions the plugs depend on

## Read First
- `lib/gtfs_planner_web/router.ex:145-183` — pipeline composition; ordering is critical: CORS → VerifyApiSession → AssignApiOrganization
- `lib/gtfs_planner_web/endpoint.ex:18-19` — UploadsPlug mounted before router; no auth on /uploads/*
- `lib/gtfs_planner_web/plugs/cors.ex` — CORS policy entry point
- `lib/gtfs_planner_web/plugs/verify_api_session.ex` — Bearer token auth entry point
- `lib/gtfs_planner_web/plugs/assign_api_organization.ex` — organization resolution entry point
- `lib/gtfs_planner_web/plugs/uploads_plug.ex` — upload serving entry point

## Interfaces

### Plugs and Their Conn Assigns

| Plug | Namespace | Sets on Conn | Reads from Conn |
|---|---|---|---|
| `CORS` | `GtfsPlannerWeb.Plugs.CORS` | (CORS headers only) | `origin` header |
| `VerifyApiSession` | `GtfsPlannerWeb.Plugs.VerifyApiSession` | `:current_user`, `:current_user_id`, `:api_session_token` | `authorization` header |
| `AssignApiOrganization` | `GtfsPlannerWeb.Plugs.AssignApiOrganization` | `:current_organization_id` (string) | `:current_user` (must be set), `x-organization-id` header |
| `UploadsPlug` | `GtfsPlannerWeb.UploadsPlug` | (CORS via inline call) | `path_info` |

### Accounts Module Dependencies

| Plug | Accounts Function | Returns |
|---|---|---|
| `VerifyApiSession` | `Accounts.get_user_by_api_session_token/1` | `%User{}` or `nil` |
| `AssignApiOrganization` | `Accounts.list_user_org_memberships/1` | `[%UserOrgMembership{}]` (active only) |

### Inter-Plug Contract
- `AssignApiOrganization` **must** run after `VerifyApiSession`. If `:current_user` is nil, it halts 401.
- `UploadsPlug` calls `GtfsPlannerWeb.Plugs.CORS.call/2` inline (endpoint-mounted, no router pipeline available). Honors CORS halt (OPTIONS preflight → 204, no file served).
- `CORS` runs in both `:api_cors` and `:api_session` pipelines, before auth plugs, so OPTIONS preflight never requires authentication.

### Configuration

| Key | Used By | Notes |
|---|---|---|
| `:gtfs_planner, :uploads_path` | `UploadsPlug` | Required; crash on startup if missing (`Application.fetch_env!`) |
| `@allowed_origins` (compile-time) | `CORS` | Hardcoded: `https://field-companion.pathways.jarv.us` + any localhost/127.0.0.1 over http/https |

## Rules & Invariants

### CORS
- Allowed origins: one production origin + all localhost/127.0.0.1 (any port, http or https).
- Allowed methods: `GET, POST, PUT, PATCH, DELETE, OPTIONS`.
- Allowed headers: `authorization, content-type, x-organization-id`.
- Max age: 86400s. `vary: origin` always set. No `access-control-allow-credentials`.
- OPTIONS preflight always answered with 204 regardless of origin validity. Non-OPTIONS on disallowed origin: no CORS headers added (conn passes through).

### Authentication
- Token format: `Authorization: Bearer <token>`. Empty Bearer value → 401.
- Token context must be `"api_session"`. Web `"session"` tokens are rejected.
- Token TTL: 60 days (enforced in `UserToken.verify_api_session_token_query/1`, not this plug).
- Expired tokens → 401 (indistinguishable from invalid).

### Organization Resolution
- Active memberships only (`deactivated_at IS NULL` in query). Deactivated memberships are invisible to the plug.
- Single active membership + no header → auto-assign.
- Multi-org user + no header → 403 with `available_organization_ids` list.
- Multi-org user + valid UUID header matching a membership → assign.
- Multi-org user + valid UUID header not in memberships → 403.
- Multi-org user + invalid UUID header → 400.
- Zero active memberships → 403 `"no_organization"`.
- No `:current_user` on conn → 401.

### Upload Serving
- URL prefix: `/uploads/*`. Path traversal blocked (resolved path must be child of `uploads_base` via `Path.expand` + `String.starts_with?`).
- File not found → pass through to router (typically Phoenix 404).
- No authentication or org-scoping enforced — any client that knows the path can download.
- Convention: `diagrams/:org_id/:stop_id/:filename` for floorplan images.

## State, I/O & Side Effects
- All plugs are stateless (no process state beyond conn). `VerifyApiSession` and `AssignApiOrganization` each make one synchronous DB call per request.
- `UploadsPlug` reads from the filesystem; returns `send_file/3` (200 + halt) or passes through.

## Failure Modes

| Plug | Status | Body | Trigger |
|---|---|---|---|
| VerifyApiSession | 401 | `{"error":{"code":"unauthorized"}}` (JSON) | Missing/invalid/expired token, wrong context |
| AssignApiOrganization | 401 | `{"error":{"code":"unauthorized"}}` (JSON) | No `:current_user` on conn |
| AssignApiOrganization | 400 | `{"error":{"code":"bad_request","message":"..."}}` (JSON) | Invalid UUID in `X-Organization-Id` |
| AssignApiOrganization | 403 | `{"error":{"code":"forbidden"}}` / `"no_organization"` / `"organization_required"` (JSON) | Org not in memberships / zero memberships / multi-org no header |
| UploadsPlug | 403 | `"Forbidden"` (text/plain) | Path traversal |
| CORS | 204 | (empty) | Any OPTIONS preflight |

All API errors use `application/json`. UploadsPlug 403 uses `text/plain`.

## Change Checklist
- [ ] If adding a new plug to a router pipeline: ensure ordering preserves CORS-before-auth.
- [ ] If changing CORS origins: `@allowed_origins` is compile-time only. Add a config key if runtime configurability is needed.
- [ ] If modifying token verification: the TTL and context check live in `UserToken`, not this target. Verify both sides.
- [ ] If changing organization resolution: test the `list_user_org_memberships` query filter (active-only) in `Accounts`.
- [ ] If changing upload paths: verify path traversal guard (`starts_with?` after `Path.expand`). Test symlink edge cases.
- [ ] If adding a required assign on conn: ensure the assign-producing plug runs earlier in every pipeline that needs it.
- [ ] Test commands: `mix test test/gtfs_planner_web/plugs/verify_api_session_test.exs`, `mix test test/gtfs_planner_web/plugs/assign_api_organization_test.exs`, `mix test test/gtfs_planner_web/plugs/uploads_plug_test.exs`
- [ ] No dedicated unit tests exist for `CORS`. Covered indirectly through `UploadsPlug` tests and API integration.
- [ ] `UploadsPlug` crashes on startup if `:uploads_path` env is missing. Always validate config presence.

## Escalate To Deep Analysis
- Full request lifecycle flowcharts for each plug (section 5)
- Complete business rules and policies tables (section 7)
- Integration contract details between plugs and Accounts (section 8)
- Test coverage gaps and untested paths (section 10.2)
- Ambiguities: unauthenticated upload access (A2), org ID leak in error responses (A3), namespace inconsistency (A1), CORS preflight route exposure (A4) — section 11.1
- Risks: hardcoded CORS origins (R2), synchronous DB calls in plugs (R3), path traversal edge cases (R4) — section 11.2
