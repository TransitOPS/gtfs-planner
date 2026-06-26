# HTTP Controllers Agent Doc

Source target: `lib-gtfs-planner-web-controllers`
Scope: Handles non-LiveView browser and HTTP endpoints for sessions, health checks, map data, errors, and the station resolution prototype.
Deep analysis: [`docs/specops/analysis/lib-gtfs-planner-web-controllers.md`](../analysis/lib-gtfs-planner-web-controllers.md)
Freshness: `source_hash=f51a70c7cf75e03d34641116884ef172d91db72818d0a990a605d01e7e27d92e`, `last_synthesized=null`

## Use When
- Adding or changing a non-LiveView controller route under `/health`, `/users`, `/map`, or `/station-data-resolution-prototype`
- Changing Geoapify or Overpass API integration behavior
- Modifying session login/logout logic or authorization gates
- Changing error view rendering for HTML or JSON
- Auditing controller-level authentication coverage

## Read First
- `lib/gtfs_planner_web/router.ex` — all controller route wiring across three pipeline scopes (`:api`, `:browser`+`:redirect_if_user_is_authenticated`, `:browser`+`:require_authenticated_user`)
- `lib/gtfs_planner_web/controllers/user_session_controller.ex` — login `create/2` (POST) and logout `delete/2` (DELETE); only controller that modifies session state
- `lib/gtfs_planner_web/controllers/map_tiles_controller.ex` — Geoapify tile reverse proxy; most complex controller (81 lines, private validation chain)
- `lib/gtfs_planner_web/controllers/map_buildings_controller.ex` — Overpass API buildings GeoJSON proxy (107 lines, private helpers for parsing/geometry)

## Interfaces

| Controller | Route | Method | Pipeline | Key External Calls |
|---|---|---|---|---|
| `HealthController` | `/health` | GET | `:api` (no auth) | None |
| `UserSessionController` | `/users/log_in` | POST | `:browser` + redirect-if-authenticated | `Accounts.get_user_by_email_and_password/2`, `UserAuth.log_in_user/3` |
| `UserSessionController` | `/users/log_out` | DELETE | `:browser` + require-authenticated | `UserAuth.log_out_user/1` |
| `StationResolutionPrototypeController` | `/station-data-resolution-prototype` | GET | `:browser` + require-authenticated | `Application.app_dir/2`, `send_file/3` |
| `StationResolutionPrototypeController` | `/station-data-resolution-prototype/station-resolution-v2.css` | GET | `:browser` + require-authenticated | Same as above |
| `MapTilesController` | `/map/tiles/:style/:z/:x/:y` | GET | `:browser` + require-authenticated | `Req.get/2` → `maps.geoapify.com` |
| `MapBuildingsController` | `/map/buildings` | GET | `:browser` + require-authenticated | `Req.post/3` → `overpass-api.de` |
| `ErrorHTML` / `ErrorJSON` | (via endpoint `render_errors` config) | — | — | `Phoenix.Controller.status_message_from_template/1` |

### Configuration Keys (Runtime)
- `:geoapify_api_key` — required for `MapTilesController`; sourced from `GEOAPIFY_API_KEY` env var in `config/runtime.exs:136-142`; nil → 500
- `:map_tiles_req_plug` / `:map_buildings_req_plug` — test-only Req stub plugs configured in `config/test.exs:28-35`

## Rules & Invariants
- **Session scope separation:** only `UserSessionController` reads/writes session (via `UserAuth`). All other controllers are read-only and stateless beyond the request.
- **Authorization gate in login:** even after valid credentials, user is denied access if they are neither an administrator nor have an organization (`UserAuth.is_administrator?/1` OR `UserAuth.fetch_user_organization/1`). Redirect with flash on failure.
- **Anti-enumeration:** login returns identical flash message ("Invalid email or password") for both unknown email and wrong password. Echoes submitted email (first 160 chars) only into flash, not the page URL.
- **Error views use Phoenix defaults:** `ErrorHTML` and `ErrorJSON` delegate to `status_message_from_template/1`. No custom error templates (the `embed_templates` call in `ErrorHTML` is commented out).
- **Deactivated accounts:** `UserAuth.log_in_user` may return `{:error, :deactivated}` — only error tuple pattern-matched. Any other return value from `log_in_user` is treated as success (potential gap — see deep analysis §11.4).

## State, I/O & Side Effects

### Session
| Controller | Reads Session | Writes Session |
|---|---|---|
| `UserSessionController.create` | No | Yes (sets user token cookie via `UserAuth.log_in_user`) |
| `UserSessionController.delete` | No | Yes (clears token via `UserAuth.log_out_user`) |
| All others | No | No |

### External HTTP (both idempotent, read-only)
| Controller | Endpoint | Timeout | Retries |
|---|---|---|---|
| `MapTilesController` | `maps.geoapify.com/v1/tile/...` (GET) | 10s | 2 × 100ms (`:safe_transient`) |
| `MapBuildingsController` | `overpass-api.de/api/interpreter` (POST) | 30s | 2 × 200ms |

### File System
- `StationResolutionPrototypeController` reads `priv/prototypes/station-resolution-v2.html` and `.css` via `Application.app_dir/2`. No filesystem writes.

## Failure Modes
| Controller | Trigger | Status | Response Body | Risk |
|---|---|---|---|---|
| `UserSessionController` | Invalid credentials | 302 | Flash: "Invalid email or password" | Low |
| `UserSessionController` | Deactivated account | 302 | Flash: deactivation message | Low |
| `UserSessionController` | No org / not admin | 302 | Flash: org assignment message | Low |
| `MapTilesController` | Unknown `style` param | 400 | `"unknown tile style"` | Low |
| `MapTilesController` | Non-integer `z`/`x`/`y` | 400 | `"non-integer tile coordinate"` | Low |
| `MapTilesController` | Missing `:geoapify_api_key` | 500 | `"geoapify_api_key is not configured"` | High (prod: raises at boot) |
| `MapTilesController` | Upstream non-200 | 502 | `"upstream #{status}"` | Medium |
| `MapTilesController` | Upstream network error | 502 | `"upstream network error"` | Medium |
| `MapBuildingsController` | Invalid/missing `lat`/`lon` | 400 | `"invalid lat or lon"` | Low |
| `MapBuildingsController` | Invalid `radius` (>2000 or ≤0) | 400 | `"invalid radius"` | Low |
| `MapBuildingsController` | Upstream non-200 | 502 | `"upstream #{status}"` | Medium |
| `MapBuildingsController` | Upstream network error | 502 | `"upstream network error"` | Medium |
| `StationResolutionPrototypeController` | File missing/unreadable | **Unhandled** | Likely 500 from Phoenix | Low (file shipped in priv) |
| `HealthController` | None | N/A | N/A | N/A |

## Change Checklist
- [ ] All new or changed controller actions are wired in `router.ex` under the correct pipeline
- [ ] Auth gates are correct (`:api` = public, authenticated routes use `:require_authenticated_user`)
- [ ] Req timeouts and retries are sensible for new external HTTP calls; configurable Req plug slot added for testability
- [ ] All error branches return appropriate HTTP status codes (400 for client error, 502 for upstream failure, 500 for server config)
- [ ] New configuration keys are wired in `config/runtime.exs` (prod) and `config/test.exs` (test)
- [ ] Test coverage: controller-level tests with `Req.Test` stubs for external HTTP; auth gate tests (unauthenticated → 302)
- [ ] Dead modules `page_html.ex` and `user_session_html.ex` should not be expanded — they are likely scaffolding artifacts with zero route references

## Escalate To Deep Analysis
- Full controller behavior specs with pre/postconditions: §5
- Session state and side-effect ownership: §6
- Auth gate detail (admin/org check in login): §7
- Complete error handling table: §8
- `UserAuth.log_in_user` contract ambiguity (only `{:error, :deactivated}` matched): §11.4, item 7
- `UserAuth.fetch_user_organization` return-value interpretation: §11.4, item 8
- Geoapify API key in URL query string logging risk: §11.1, item 1
- Proto file serving error gap: §11.2, item 5
- Untested controllers (Health, UserSession): §10.2
- Test strategy details (`Req.Test` stubs, auth redirect patterns): §10.3
