# Analysis: HTTP Controllers (`lib/gtfs_planner_web/controllers`)

**Target slug:** `lib-gtfs-planner-web-controllers`
**Structural unit:** `lib/gtfs_planner_web/controllers/`
**Source globs:** `lib/gtfs_planner_web/controllers/**`
**Analyzed source_hash:** `d7adeab62ee9b041e155dc4b7904fd0deca1f4d19285046ec6a27bcb445a5e4a`

---

## 1. Target Summary

Eight files implement the application's non-LiveView HTTP controllers: three functional controllers (Health, UserSession, MapTiles, MapBuildings), two error-view modules (ErrorHTML, ErrorJSON), and two empty placeholder modules (PageHTML, UserSessionHTML). These together handle:

- **Health checks** — a no-auth JSON `/health` endpoint returning `{"status":"ok"}`
- **User session management** — login (POST) and logout (DELETE) via `UserSessionController`, gated by browser pipelines
- **Map tile proxying** — forwards `{style,z,x,y}` tile requests to the Geoapify raster tile API, hiding the API key from the client
- **Map buildings overlay** — queries the Overpass API for OSM building footprints near a lat/lon, returns GeoJSON Polygon features
- **Error rendering** — Phoenix fallback views for HTML and JSON error responses

Controllers are wired through `GtfsPlannerWeb.Router` under three scopes: a public `:api` pipeline (health), a `:browser` + `:redirect_if_user_is_authenticated` pipeline (login), and a `:browser` + `:require_authenticated_user` pipeline (logout, map tiles, map buildings). No controllers are registered in the `:api_session` or `:api_cors` companion API pipelines — those live under `lib/gtfs_planner_web/api/v1/`.

---

## 2. File Manifest

| File | Lines | Purpose |
|---|---|---|
| `health_controller.ex` | 7 | Unix‑style health check endpoint |
| `user_session_controller.ex` | 47 | Login form POST, logout DELETE |
| `user_session_html.ex` | 0 | Empty HTML module (Phoenix scaffolding artifact) |
| `map_tiles_controller.ex` | 81 | Reverse proxy for Geoapify raster tiles |
| `map_buildings_controller.ex` | 107 | Overpass API building‑footprint GeoJSON proxy |
| `error_html.ex` | 24 | Phoenix HTML error view |
| `error_json.ex` | 21 | Phoenix JSON error view |
| `page_html.ex` | 0 | Empty HTML module (Phoenix scaffolding artifact) |

---

## 3. Dependencies (Module-Level)

### 3.1 Framework / In-House Dependencies

- **`GtfsPlannerWeb` macro** (`use GtfsPlannerWeb, :controller` / `use GtfsPlannerWeb, :html`) — all controllers and views depend on this to import Phoenix controller/view conveniences.
- **`GtfsPlanner.Accounts`** — `UserSessionController` calls `Accounts.get_user_by_email_and_password/2`.
- **`GtfsPlannerWeb.UserAuth`** — `UserSessionController` calls `is_administrator?/1`, `fetch_user_organization/1`, `log_in_user/3`, `log_out_user/1`.
- **`Phoenix.Controller`** — `ErrorHTML` and `ErrorJSON` call `status_message_from_template/1`.
- **`Req`** (external HTTP client) — `MapTilesController` and `MapBuildingsController` use `Req.get/2` and `Req.post/3` respectively.

### 3.2 Configuration Keys Read at Runtime

| Key | Used By | Effect |
|---|---|---|
| `:geoapify_api_key` | `MapTilesController` | Required; missing → 500 |
| `:map_tiles_req_plug` | `MapTilesController` | Optional Req plug (test stubbing) |
| `:map_buildings_req_plug` | `MapBuildingsController` | Optional Req plug (test stubbing) |

### 3.3 External Services

| Service | Used By | Protocol | Auth |
|---|---|---|---|
| `https://maps.geoapify.com/v1/tile/...` | `MapTilesController` | HTTPS GET (streamed PNG) | `?apiKey=...` from env |
| `https://overpass-api.de/api/interpreter` | `MapBuildingsController` | HTTPS POST (form body) | None (public API) |

---

## 4. Route Wiring

All route-to-controller mappings extracted from `router.ex`:

| Method | Path | Controller | Action | Pipeline |
|---|---|---|---|---|
| GET | `/health` | `HealthController` | `:index` | `:api` |
| POST | `/users/log_in` | `UserSessionController` | `:create` | `:browser` + `:redirect_if_user_is_authenticated` |
| DELETE | `/users/log_out` | `UserSessionController` | `:delete` | `:browser` + `:require_authenticated_user` |
| GET | `/map/tiles/:style/:z/:x/:y` | `MapTilesController` | `:show` | `:browser` + `:require_authenticated_user` |
| GET | `/map/buildings` | `MapBuildingsController` | `:index` | `:browser` + `:require_authenticated_user` |

Error views are referenced in `config.exs` under `render_errors` on the endpoint — they are never directly routed.

---

## 5. Controller Behavior Specifications

### 5.1 HealthController

**`index/2`**

- **Preconditions:** Valid HTTP connection over the `:api` pipeline (JSON accepts, no authentication).
- **Action:** Returns `conn |> json(%{status: "ok"})`.
- **Postconditions:** HTTP 200; response body `{"status":"ok"}`; content-type `application/json`.
- **Error modes:** None — always returns 200 with the same body.

### 5.2 UserSessionController

#### `create/2`

- **Preconditions:**
  - Request params include `%{"user" => %{"email" => email, "password" => password}}`.
  - Connection is piped through `:browser` + `:redirect_if_user_is_authenticated` (redirects already-logged-in users away).
- **Logic:**
  1. Pattern-match `%{"email" => email, "password" => password}` from `user_params`.
  2. Look up user via `Accounts.get_user_by_email_and_password(email, password)`.
  3. If no user found: flash "Invalid email or password", echo `email` (first 160 chars) into flash, redirect to `~p"/users/log_in"`. This is an explicit anti‑enumeration measure.
  4. If user found: check authorization — `UserAuth.is_administrator?(user) OR UserAuth.fetch_user_organization(user)`.
     - If neither holds: flash "Your account has no organization assigned…", redirect to `~p"/users/log_in"`.
     - If authorized: call `UserAuth.log_in_user(conn, user, user_params)`.
       - On `{:error, :deactivated}`: flash deactivation message, redirect to `~p"/users/log_in"`.
       - Otherwise: return the (now-authenticated) `conn`.
- **Postconditions:**
  - On success: user session cookie set; user is authenticated; redirected or returned depends on `UserAuth.log_in_user`.
  - On failure: flash error message set; redirected to `/users/log_in`; no session created.
- **Error modes:** Invalid credentials (flashed, redirected), deactivated account (flashed, redirected), no org/not admin (flashed, redirected). All failures redirect to login page.

#### `delete/2`

- **Preconditions:** Authenticated user (pipeline: `:require_authenticated_user`).
- **Action:** Delegates to `UserAuth.log_out_user(conn)`.
- **Postconditions:** User session cleared; user is logged out.
- **Error modes:** None surfaced here; delegated to `UserAuth`.

### 5.3 MapTilesController

#### `show/2`

- **Preconditions:**
  - Authenticated user (`:require_authenticated_user`).
  - URL params `style`, `z`, `x`, `y` present (guaranteed by route pattern).
- **Logic (with chain):**
  1. `validate_style(style)` — checks `style in ~w(osm-bright osm-carto maptiler-3d satellite)`. Unknown → 400.
  2. `parse_coord(z)`, `parse_coord(x)`, `parse_coord(y)` — `Integer.parse` with empty remainder required. Non-integer → 400.
  3. `fetch_api_key()` — reads `Application.get_env(:gtfs_planner, :geoapify_api_key)`. nil → 500.
  4. `fetch_tile(conn, style, z_int, x_int, y_int, key)` — issues `Req.get/2` to `https://maps.geoapify.com/v1/tile/#{style}/#{z}/#{x}/#{y}.png?apiKey=#{key}`.
     - Upstream 200: returns 200 `image/png`, `cache-control: public, max-age=86400`.
     - Upstream non-200: returns 502 with `"upstream #{status}"`.
     - Network error: returns 502 with `"upstream network error"`.
- **Req options:** `receive_timeout: 10_000`, `max_retries: 2` with `retry: :safe_transient`, `retry_delay: 100ms`. If `:map_tiles_req_plug` is configured, it's prepended as `{:plug, plug}`.
- **Postconditions:** Image PNG bytes or error text with appropriate status code.
- **Error modes:** 400 (bad style or non-integer coord), 500 (missing API key), 502 (upstream failure). The API key is interpolated into the URL query string — **observed: no URI encoding of the key value**, though Geoapify keys are alphanumeric.

### 5.4 MapBuildingsController

#### `index/2`

- **Preconditions:**
  - Authenticated user (`:require_authenticated_user`).
  - Query params `lat`, `lon`, `radius` (optional, defaults to 500).
- **Logic:**
  1. `parse_float(lat)`, `parse_float(lon)` — `Float.parse` with empty remainder required. nil or invalid → 400.
  2. `parse_radius(radius)` — nil defaults to 500. Otherwise `Integer.parse`, must be `> 0 and <= 2000`. Invalid → 400.
  3. `fetch_buildings(conn, lat, lon, radius)` — POSTs Overpass QL `"[out:json][timeout:25];way[\"building\"](around:#{radius},#{lat},#{lon});out geom;"` to `https://overpass-api.de/api/interpreter` with `[form: [data: query]]`.
  4. `to_geojson(body)` — filters elements to polygons (ways with ≥3 geometry points), converts to GeoJSON FeatureCollection with Polygon features. Rings are closed if not already. Tags become feature properties.
  5. Returns `application/geo+json` with `cache-control: public, max-age=3600`.
- **Postconditions:** HTTP 200 with GeoJSON FeatureCollection, or 400/502 on errors.
- **Error modes:** 400 (invalid/missing lat/lon, invalid radius), 502 (upstream non-200 or network error).
- **Req options:** `receive_timeout: 30_000`, `max_retries: 2`, `retry_delay: 200ms`. Optional `:map_buildings_req_plug` prepended.
- **Int overflow concern:** `lat`, `lon`, `radius` are interpolated into an Overpass QL string without bounds checking beyond `radius <= 2000`. Float interpolation is stringified by Elixir — this is safe, as Overpass accepts scientific notation and the NSEW range for lat/lon is inherently bounded by the Earth. No injection risk: the values are parsed through `Float.parse`/`Integer.parse` before interpolation, and Overpass QL syntax does not use the float values as delimiters.

### 5.5 ErrorHTML

- **`render(template, _assigns)`** — delegates to `Phoenix.Controller.status_message_from_template(template)`, returning a plain‑text status message string (e.g., `"Not Found"` for `"404.html"`).
- Called by the Phoenix endpoint error handler per `config.exs` `render_errors`.
- No custom error templates are embedded (the `embed_templates` call is commented out).

### 5.6 ErrorJSON

- **`render(template, _assigns)`** — returns `%{errors: %{detail: status_message}}`.
- Same delegation pattern, but wraps in a JSON error envelope.
- No custom JSON error renderer for specific status codes exists.

### 5.7 page_html.ex

- Empty module (`use GtfsPlannerWeb, :html`). No render clauses. Phoenix scaffolding artifact — no known route uses it.
- **Confidence: LOW (inferred).** Not referenced in router or config. Likely dead code.

### 5.8 user_session_html.ex

- Empty module (`use GtfsPlannerWeb, :html`). No render clauses. The `UserSessionController` handles its own redirects and flash messages, never delegates to a view. Likely dead code.

---

## 6. State & Side Effects

### 6.1 Session State

| Controller | Reads Session | Writes Session |
|---|---|---|
| `UserSessionController.create` | No | Yes (via `UserAuth.log_in_user` — sets user token cookie) |
| `UserSessionController.delete` | No | Yes (via `UserAuth.log_out_user` — clears user token cookie) |
| All others | No | No |

### 6.2 Application Environment (Mutable)

| Controller | Reads `Application.get_env` | Writes `Application.put_env` |
|---|---|---|
| `MapTilesController` | `:geoapify_api_key`, `:map_tiles_req_plug` | No (only in tests) |
| `MapBuildingsController` | `:map_buildings_req_plug` | No (only in tests) |

### 6.3 External HTTP Calls

| Controller | Endpoint | Side Effect | Idempotent? |
|---|---|---|---|
| `MapTilesController` | Geoapify tile API | Read-only fetch | Yes (GET) |
| `MapBuildingsController` | Overpass API | Read-only query | Yes (POST with idempotent query body) |

---

## 7. Authentication & Authorization

### 7.1 Authentication Gates

| Endpoint | Gate |
|---|---|
| `GET /health` | **None** — public `:api` pipeline, no auth plug |
| `POST /users/log_in` | `:redirect_if_user_is_authenticated` — redirects already‑logged‑in users |
| `DELETE /users/log_out` | `:require_authenticated_user` — redirects to `/users/log_in` if no session |
| `GET /map/tiles/*` | `:require_authenticated_user` |
| `GET /map/buildings` | `:require_authenticated_user` |

### 7.2 Authorization Logic (In-Controller)

- `UserSessionController.create` performs an additional authorization check after credential validation: the user must be an administrator OR have organization membership. A user who authenticates successfully but has neither gets redirected with a flash message. This is a **break‑glass authorization gate**: a valid credential holder is still denied access if their account lacks an organization or admin role.

---

## 8. Error Handling Summary

| Controller | Error | HTTP Status | Body | User-Visible? |
|---|---|---|---|---|
| `UserSessionController` | Invalid credentials | 302 → `/users/log_in` | Flash: "Invalid email or password" | Yes |
| `UserSessionController` | Deactivated account | 302 → `/users/log_in` | Flash: deactivation message | Yes |
| `UserSessionController` | No org / not admin | 302 → `/users/log_in` | Flash: org message | Yes |
| `MapTilesController` | Unknown style | 400 | `"unknown tile style"` | Partially (plain text) |
| `MapTilesController` | Non‑integer coord | 400 | `"non-integer tile coordinate"` | Partially |
| `MapTilesController` | Missing API key | 500 | `"geoapify_api_key is not configured"` | Partially |
| `MapTilesController` | Upstream non‑200 | 502 | `"upstream #{status}"` | Partially |
| `MapTilesController` | Upstream network error | 502 | `"upstream network error"` | Partially |
| `MapBuildingsController` | Invalid lat/lon | 400 | `"invalid lat or lon"` | Partially |
| `MapBuildingsController` | Invalid radius | 400 | `"invalid radius"` | Partially |
| `MapBuildingsController` | Upstream non‑200 | 502 | `"upstream #{status}"` | Partially |
| `MapBuildingsController` | Upstream network error | 502 | `"upstream network error"` | Partially |
| `HealthController` | None | N/A | N/A | N/A |

---

## 9. Configuration & Runtime Dependencies

### 9.1 Required Environment Variables

| Variable | Read By | Where Defined | Required |
|---|---|---|---|
| `GEOAPIFY_API_KEY` | `MapTilesController` (via `Application.get_env(:gtfs_planner, :geoapify_api_key)`) | `config/runtime.exs:136-142` | In production (raises if missing); optional in dev/test (defaults to nil) |

### 9.2 Test‑Only Configuration

| Key | Value | Purpose |
|---|---|---|
| `:map_tiles_req_plug` | `{Req.Test, GtfsPlannerWeb.MapTilesController}` | Routes all `Req` calls through `Req.Test` |
| `:map_buildings_req_plug` | `{Req.Test, GtfsPlannerWeb.MapBuildingsController}` | Routes all `Req` calls through `Req.Test` |

---

## 10. Test Coverage

### 10.1 Test Files

| Test File | Controllers Covered |
|---|---|
| `test/gtfs_planner_web/controllers/error_json_test.exs` | `ErrorJSON` |
| `test/gtfs_planner_web/controllers/error_html_test.exs` | `ErrorHTML` |
| `test/gtfs_planner_web/controllers/map_tiles_controller_test.exs` | `MapTilesController` |
| `test/gtfs_planner_web/controllers/map_buildings_controller_test.exs` | `MapBuildingsController` |
| `test/gtfs_planner_web/controllers/station_resolution_prototype_retirement_test.exs` | Route-absence contract for retired prototype paths |

### 10.2 Untested Controllers

| Controller | Notes |
|---|---|
| `HealthController` | **No tests exist.** The `/health` endpoint has no dedicated or integration tests. |
| `UserSessionController` | **No dedicated tests.** Login/logout is likely exercised indirectly through LiveView authentication tests (e.g., `UserLoginLive` tests), but no controller‑level tests exist. |

### 10.3 Test Strategies Observed

- **MapTilesController / MapBuildingsController:** Use `Req.Test.stub/2` with the controller module as the stub owner. The `:map_tiles_req_plug` / `:map_buildings_req_plug` config in `test.exs` routes all `Req` calls through `Req.Test`, allowing deterministic stubs. Authentication is tested by verifying that unauthenticated requests redirect to `/users/log_in`.
- **Error views:** Direct function call tests — `render("404.json", %{})` / `render_to_string(..., "404", "html", [])` — bypassing the HTTP layer.
- **StationResolutionPrototypeRetirementTest:** Literal-path 404 behavior contract verifying that both former prototype paths return 404 for authenticated and unauthenticated requests, and that the raw `priv/prototypes` path is not statically published.

---

## 11. Risks, Ambiguities & Observations

### 11.1 Security

1. **Geoapify API key in URL query string** (`map_tiles_controller.ex:51`): The API key is interpolated into the URL as a query parameter. While this is standard for Geoapify's tile endpoint, query‑string keys may be logged by intermediate proxies or load balancers. **Risk: MEDIUM (design observation, not a code defect).**
2. **Anti‑enumeration in login** (`user_session_controller.ex:35-39`): The controller deliberately returns the same flash message ("Invalid email or password") regardless of whether the email exists. However, the `:redirect_if_user_is_authenticated` pipeline runs before the controller, and `UserAuth` may behave differently. **Risk: LOW** (mitigated by explicit design comment in code).
3. **No authorization on HealthController** (`health_controller.ex`): The health endpoint is completely public. **Risk: LOW** — standard practice for health checks, but may expose service existence.

### 11.2 Resilience

4. **No timeout or circuit breaker on Overpass calls** (`map_buildings_controller.ex`): `receive_timeout: 30_000` and 2 retries with 200ms delay may cause request queuing under upstream slowness. Upstream 502 responses from Overpass (e.g., rate limiting) are returned as 502 to the client. **Risk: LOW‑MEDIUM.**
### 11.3 Code Quality

6. **Dead modules:** `page_html.ex` and `user_session_html.ex` are empty `:html` modules with no render clauses and no route references. They appear to be Phoenix scaffolding leftovers. **Confidence: HIGH (observed from zero‑byte file content and lack of route references).**

### 11.4 Ambiguities

7. **`UserAuth.log_in_user` return shape** (`user_session_controller.ex:13-24`): The `case` expression treats `{:error, :deactivated}` as the sole error tuple and any other value as success (matching `conn`). Other potential error tuples from `log_in_user` would be silently treated as success. The full contract of `UserAuth.log_in_user` should be audited to confirm no other error variants exist. **Confidence: MEDIUM — inferred from pattern match structure.**
8. **`UserAuth.fetch_user_organization(user)` return value** (`user_session_controller.ex:12`): Used in a boolean context (`if ... || ...`). If it returns `nil` or `false` for users without an org, and a truthy value otherwise, the logic is correct. If it returns an ok/error tuple, the boolean test could be misleading. **Confidence: HIGH — inferred from name and usage pattern, but not confirmed by reading the source.**

### 11.5 Gaps

9. **No HealthController tests** — the health endpoint has zero test coverage. This is a simple endpoint but represents a monitoring dependency that should be verified.
10. **No UserSessionController tests** — login and logout logic has no controller‑level tests. This is partially mitigated by LiveView‑level auth tests but leaves the non‑LiveView session paths untested.
11. **Error views have no custom templates** — both `ErrorHTML` and `ErrorJSON` use Phoenix defaults. This is acceptable for an API‑focused application but means error pages are plain text (HTML) or minimal JSON with only a `detail` key.

---

## Evidence

### Evidence for Section 1 (Target Summary)
- File listing via glob: 8 files under `lib/gtfs_planner_web/controllers/`
- Router wiring: `lib/gtfs_planner_web/router.ex:41-75`
- Each controller's `@moduledoc` or code structure

### Evidence for Section 2 (File Manifest)
- Direct file read of all 8 source files; line counts from reads.

### Evidence for Section 3 (Dependencies)
- `use GtfsPlannerWeb, :controller` — present in every controller file
- `alias GtfsPlanner.Accounts` and `alias GtfsPlannerWeb.UserAuth` — `user_session_controller.ex:4-5`
- `Req.get/2` — `map_tiles_controller.ex:53`
- `Req.post/3` — `map_buildings_controller.ex:47`
- Config keys — `config/runtime.exs:136-142`, `config/test.exs:28-35`

### Evidence for Section 4 (Route Wiring)
- `lib/gtfs_planner_web/router.ex:41-75` — all scope blocks with controller routes.

### Evidence for Section 5 (Controller Behaviors)
- `health_controller.ex:4-6` — `index/2`
- `user_session_controller.ex:7-46` — `create/2` and `delete/2`
- `map_tiles_controller.ex:14-80` — `show/2`, `validate_style/1`, `parse_coord/1`, `fetch_api_key/0`, `fetch_tile/6`, `req_options/0`
- `map_buildings_controller.ex:14-106` — `index/2`, `parse_float/1`, `parse_radius/1`, `fetch_buildings/4`, `to_geojson/1`, `polygon?/1`, `element_to_feature/1`, `close_ring/1`, `req_options/0`
- `error_html.ex:21-23` — `render/2`
- `error_json.ex:18-20` — `render/2`

### Evidence for Section 6 (State & Side Effects)
- `user_session_controller.ex:13,45` — calls to `UserAuth.log_in_user` and `log_out_user` (session state)
- `map_tiles_controller.ex:44,76` — `Application.get_env` reads (no writes)
- `map_buildings_controller.ex:102` — `Application.get_env` reads

### Evidence for Section 7 (Auth)
- `router.ex:36-39` — `:api` pipeline has no auth plug
- `router.ex:63-64` — `:require_authenticated_user` pipeline wrapping controllers
- `user_session_controller.ex:10-13` — authorization logic for admin/org check
- Test files: `map_tiles_controller_test.exs:88-94`, `map_buildings_controller_test.exs:76-81` — verify unauthenticated redirect to `/users/log_in`

### Evidence for Section 8 (Error Handling)
- Each controller's `send_resp` calls, flash messages, and `with`/`else` error branches documented inline in Section 5.

### Evidence for Section 9 (Configuration)
- `config/runtime.exs:136-142` — `GEOAPIFY_API_KEY` binding
- `config/test.exs:28-35` — test‑only Req plug configs
- `config/config.exs:20-22` — endpoint `render_errors`

### Evidence for Section 10 (Test Coverage)
- Test file glob: 5 test files found; no tests for `HealthController` or `UserSessionController`
- Each test file read and summarized

### Evidence for Section 11 (Risks)
- `map_tiles_controller.ex:51` — API key in URL query string
- `user_session_controller.ex:35` — anti‑enumeration comment in code
- Empty files: `page_html.ex` (0 bytes), `user_session_html.ex` (0 bytes)
- `user_session_controller.ex:13` — `case UserAuth.log_in_user(...)` with only `{:error, :deactivated}` catch
