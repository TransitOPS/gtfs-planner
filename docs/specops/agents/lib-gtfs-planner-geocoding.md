# Geocoding Context Agent Doc

Source target: `lib-gtfs-planner-geocoding`
Scope: Routes address autocomplete requests through a behavior-backed geocoding service and the Geoapify implementation.
Deep analysis: [`../analysis/lib-gtfs-planner-geocoding.md`](../analysis/lib-gtfs-planner-geocoding.md)
Freshness: `source_hash=0d390f7a5c1d372c640a89c4b2d7650e76a07dede4a1c6181d9fcb2ee57cb927`, `last_synthesized=null`

## Use When
- Adding, modifying, or removing geocoding/autocomplete features.
- Changing the geocoding service provider or API integration.
- Debugging autocomplete failures, timeouts, or error returns.
- Adding new callers that consume `GtfsPlanner.Geocoding.autocomplete/2`.
- Investigating `GtfsPlanner.GeocodingMock` test behavior or Mox stub setup.
- Configuring `:geocoding_service` or `:geoapify_api_key` env.

## Read First
- `lib/gtfs_planner/geocoding.ex` — facade entry point, `Result` struct definition, runtime dispatch.
- `lib/gtfs_planner/geocoding/behaviour.ex` — callback contract: `autocomplete/2` → `{:ok, [Result.t()]} | {:error, atom() | tuple()}`.
- `lib/gtfs_planner/geocoding/geoapify.ex` — Geoapify API adapter, error handling, request/response logic.

## Interfaces

### Public API
- `GtfsPlanner.Geocoding.autocomplete(text, opts \\ [])` — resolves configured service at runtime via `Application.get_env(:gtfs_planner, :geocoding_service)`, applies `behaviour`'s `autocomplete/2`, returns `{:ok, [%Result{}]}` or `{:error, reason}`.
- `opts` keyword list is passed through but **ignored** (`_opts`) by `Geoapify`. Dead parameter space.

### Caller modules (3 direct)
- `lib/gtfs_planner_web/live/components_live.ex:153` — `normalize_result/1` expecting `%Geocoding.Result{}`
- `lib/gtfs_planner_web/live/gtfs/station_diagram_live.ex:4680` — `normalize_geocoding_result/1`
- `lib/gtfs_planner_web/live/gtfs/station_reachability_live.ex:1657` — `normalize_geocoding_result/1`
- `lib/gtfs_planner_web/controllers/map_tiles_controller.ex` — shares `:geoapify_api_key` config only; does **not** call geocoding.

### Key external dependency
- `lib/gtfs_planner_web/controllers/map_tiles_controller.ex:50-66` — has retry/timeout config for its own Geoapify tile calls; the geocoding endpoint does **not** share this infrastructure.

## Rules & Invariants

### Dispatch (runtime dependency inversion)
- `config/config.exs:14` — `geocoding_service: GtfsPlanner.Geocoding.Geoapify` (default prod/dev).
- `config/test.exs:26` — `geocoding_service: GtfsPlanner.GeocodingMock` (Mox mock).
- `config/runtime.exs:137-142` — `geoapify_api_key` from `System.get_env("GEOAPIFY_API_KEY")`; raises in `:prod` if missing, defaults to `nil` in `:dev`.
- Dispatch is fully runtime — `Kernel.apply/3` is used at `geocoding.ex:52-54`. No compile-time dependency on implementation.

### Geoapify API contract (hardcoded)
- **Endpoint:** `GET https://api.geoapify.com/v1/geocode/autocomplete`
- **Params:** `text` (query), `apiKey` (key), `format=json`, `limit=5`, `filter=countrycode:us`
- **All parameters are hardcoded** in `geoapify.ex:26-32` — no config overrides for `limit`, `filter`, or `format`.
- **No explicit timeout/retry** on the `Req.get/2` call. Unlike `map_tiles_controller.ex` which has `receive_timeout: 10_000` and `max_retries: 2`.

### Result struct
- `GtfsPlanner.Geocoding.Result` — nested in `geocoding.ex`, derives `Jason.Encoder`.
- Enforced keys: `[:formatted_address, :lat, :lon]`. Optional: `[:country, :state, :city]` (default `nil`).
- Not an Ecto schema. Never persisted.
- Field mapping in `parse_results/1` (`geoapify.ex:47-61`) uses `Map.get/3` with silent defaults: `lat`/`lon` default to `0.0`, strings default to `""` or `nil`.

## State, I/O & Side Effects
- **Stateless module.** No GenServer, no supervision tree, no ETS, no persistent state.
- **Network I/O:** `Req.get/2` to Geoapify autocomplete endpoint on every `autocomplete/2` call (except when `api_key` is `nil` or `text < 3` chars — rejected before HTTP).
- **Config reads:** `Application.get_env/2` for both `:geocoding_service` (module resolution) and `:geoapify_api_key` (API key).
- **No caching.** Every call hits the API (or mock in test).
- **No disk I/O.** No database reads/writes.

## Failure Modes

| Condition | Module:line | Return |
|-----------|-------------|--------|
| `text` < 3 chars | `geoapify.ex:13-14` | `{:error, :text_too_short}` |
| `api_key` is `nil` | `geoapify.ex:23-24` | `{:error, :api_key_missing}` |
| HTTP non-200 | `geoapify.ex:38-39` | `{:error, {:api_error, status}}` |
| Req transport failure | `geoapify.ex:41-42` | `{:error, :network_error}` |

### Unhandled crash risks (HIGH severity)
- **HTTP 200 with missing/nil `"results"` key** — pattern match at `geoapify.ex:34-35` requires `%{status: 200, body: %{"results" => results}}`. A 200 with a different body shape falls through with no catch-all → `FunctionClauseError` crash in caller.
- **`"results"` is non-list** — `parse_results/1` guard at `geoapify.ex:47` requires `is_list(results)`. `nil` or a map → `FunctionClauseError`.
- **No HTTP timeout** — `Req.get/2` called with no `:receive_timeout`. Could block the calling LiveView process indefinitely on network stall.

### Other risks
- **`:geoapify_api_key` shared across concerns** — map tiles controller and geocoding use the same config key. Misconfiguration breaks both.
- **Silent defaults for missing fields** — lat/lon default to `0.0` if missing from API response, producing misleading map markers.
- **`:api_error` path untested** — no test covers `{:error, {:api_error, status}}` (4 tests in `test/gtfs_planner/geocoding_test.exs`, all via Mox mock, none exercise `Geoapify` directly).

## Change Checklist
- [ ] If adding a new implementation: create module implementing `GtfsPlanner.Geocoding.Behaviour`, then update `config.exs` `:geocoding_service`.
- [ ] If changing API parameters (`limit`, `filter`, `format`): update hardcoded values in `geoapify.ex:26-32`.
- [ ] If adding timeout/retry: add `:receive_timeout` to `Req.get/2` call in `geoapify.ex` and handle timeout in error branches.
- [ ] If removing the US-only filter: update `geoapify.ex` and verify callers don't assume US-only results.
- [ ] If changing `Result` struct: update `@enforce_keys` and `parse_results/1` field mapping. Callers may need updates.
- [ ] If changing error return shapes or adding new error atoms: update all caller error handling and add Mox stubs in `test/support/mocks.ex`.
- [ ] After changes: run `mix test test/gtfs_planner/geocoding_test.exs`. Consider adding integration tests for actual Geoapify responses.

## Escalate To Deep Analysis
- Full caller integration details (sections 8, 3.3).
- Complete risk inventory with severity ratings (section 10).
- Detailed Geoapify API contract and response shapes (section 5).
- Environment behavior matrix across dev/test/prod (section 7.4).
- Test coverage gap analysis (section 9.4).
- Evidence file:line references for every claim (sections 1.3, 2.4, 3.3, 4.1, 5.6, 6.3, 7.5, 8.3, 9.5).
