# GtfsPlanner.Geocoding – Analysis

## 1. Overview

The `GtfsPlanner.Geocoding` module provides a behavior-backed address autocomplete service. Clients call `GtfsPlanner.Geocoding.autocomplete/2`, which resolves to a configurable implementation at runtime via `Application.get_env/2`. The default (prod/dev) implementation is `GtfsPlanner.Geocoding.Geoapify`, which calls the Geoapify geocoding autocomplete API. In test, a `Mox`-based mock is substituted.

**Structural unit:** `lib/gtfs_planner/geocoding`

### 1.1 Files

| File | Role |
|------|------|
| `lib/gtfs_planner/geocoding.ex` | Facade context module; holds `Result` struct; delegates to configured implementation |
| `lib/gtfs_planner/geocoding/behaviour.ex` | Callback contract (`autocomplete/2`) |
| `lib/gtfs_planner/geocoding/geoapify.ex` | Geoapify API adapter implementing the behaviour |

### 1.2 Configuration

| Key | Scope | Value |
|-----|-------|-------|
| `:geocoding_service` | `config.exs` | `GtfsPlanner.Geocoding.Geoapify` (default) |
| `:geocoding_service` | `test.exs` | `GtfsPlanner.GeocodingMock` (Mox mock) |
| `:geoapify_api_key` | `runtime.exs` | `System.get_env("GEOAPIFY_API_KEY")`; raises in prod if missing, defaults to `nil` otherwise |
| `:map_tiles_req_plug` | `test.exs` | `{Req.Test, ...}` (only for map tiles, not the geocoding autocomplete endpoint) |

### 1.3 Evidence

* `lib/gtfs_planner/geocoding.ex:52-54` – `autocomplete/2` resolves `:geocoding_service` via `Application.get_env` then calls `Kernel.apply/3`
* `config/config.exs:14` – default service set to `Geoapify`
* `config/test.exs:26` – test override to `GeocodingMock`
* `config/runtime.exs:137-142` – API key from env var, required in prod
* `lib/gtfs_planner/geocoding/geoapify.ex:21` – `Application.get_env(:gtfs_planner, :geoapify_api_key)`

---

## 2. Module Structures & Internal Architecture

### 2.1 `GtfsPlanner.Geocoding` (Facade)

* **File:** `lib/gtfs_planner/geocoding.ex`
* **Line count:** 56
* **Role:** Public entry point; runtime delegation hub.

**Key functions:**
* `autocomplete(text, opts \\ [])` – Resolves the configured `geocoding_service` and calls its `autocomplete/2`. The `opts` keyword list is passed through but shadowed by `_opts` in `Geoapify`.

**Embedded struct:** `Result` is defined as a nested module within this file (`GtfsPlanner.Geocoding.Result`). It derives `Jason.Encoder`, enforces keys `[:formatted_address, :lat, :lon]`, and has optional fields `[:country, :state, :city]`.

**Runtime dispatch pattern:** `Application.get_env(:gtfs_planner, :geocoding_service) |> apply(:autocomplete, [text, opts])` – this is the runtime polymorphism mechanism. No compile-time module attribute. No supervision. No GenServer.

### 2.2 `GtfsPlanner.Geocoding.Behaviour` (Contract)

* **File:** `lib/gtfs_planner/geocoding/behaviour.ex`
* **Line count:** 10
* **Role:** Defines the `autocomplete/2` callback returning `{:ok, [Result.t()]} | {:error, atom() | tuple()}`.

### 2.3 `GtfsPlanner.Geocoding.Geoapify` (Implementation)

* **File:** `lib/gtfs_planner/geocoding/geoapify.ex`
* **Line count:** 62
* **Role:** Calls Geoapify v1 autocomplete endpoint via `Req.get/2`.

**Call chain:**
1. `autocomplete(text, _opts)` – validates `String.length(text) >= 3`, then calls `fetch_from_api/2`
2. `fetch_from_api(text, _opts)` – reads API key from app env, builds query params, calls `Req.get`
3. `parse_results(results)` – maps Geoapify JSON array into `[%Result{}]`

**Error cases:**
| Condition | Return |
|-----------|--------|
| `text` < 3 chars | `{:error, :text_too_short}` |
| `api_key` is `nil` | `{:error, :api_key_missing}` |
| HTTP 200 with `"results"` key | `{:ok, [%Result{}]}` |
| HTTP non-200 | `{:error, {:api_error, status}}` |
| Req connection/transport failure | `{:error, :network_error}` |

**Geoapify API contract:**
* **Endpoint:** `https://api.geoapify.com/v1/geocode/autocomplete`
* **Parameters:** `text` (query), `apiKey` (key), `format=json`, `limit=5`, `filter=countrycode:us`
* **Expected response shape:** `%{"results" => [%{"formatted" => ..., "lat" => ..., "lon" => ..., "country" => ..., "state" => ..., "city" => ...}]}`
* **Hardcoded constraints:**
  * `limit: 5` – max 5 results returned
  * `filter: "countrycode:us"` – restricted to US addresses
  * `format: "json"` – always JSON

**Result mapping (in `parse_results`):**
| Geoapify field | Result field | Default |
|----------------|-------------|---------|
| `"formatted"` | `formatted_address` | `""` |
| `"lat"` | `lat` | `0.0` |
| `"lon"` | `lon` | `0.0` |
| `"country"` | `country` | `nil` |
| `"state"` | `state` | `nil` |
| `"city"` | `city` | `nil` |

### 2.4 Evidence

* `lib/gtfs_planner/geocoding.ex:52-54` – dispatch mechanism
* `lib/gtfs_planner/geocoding/geoapify.ex:12-18` – text length guard
* `lib/gtfs_planner/geocoding/geoapify.ex:20-45` – `fetch_from_api` including all error paths
* `lib/gtfs_planner/geocoding/geoapify.ex:47-61` – `parse_results` field mapping
* `lib/gtfs_planner/geocoding/geoapify.ex:26-32` – hardcoded API parameters

---

## 3. Data Models

### 3.1 `GtfsPlanner.Geocoding.Result` struct

```elixir
defmodule Result do
  @derive Jason.Encoder
  @enforce_keys [:formatted_address, :lat, :lon]
  defstruct [:formatted_address, :lat, :lon, :country, :state, :city]

  @type t :: %__MODULE__{
    formatted_address: String.t(),
    lat: float(),
    lon: float(),
    country: String.t() | nil,
    state: String.t() | nil,
    city: String.t() | nil
  }
end
```

* **Serialization:** `@derive Jason.Encoder` – all fields are included in JSON encoding
* **Required fields:** `formatted_address`, `lat`, `lon` enforced at struct creation time
* **Optional fields:** `country`, `state`, `city` default to `nil`
* **No Ecto schema.** Result is a plain struct, never persisted to database.
* **No validation beyond struct enforcement.** Defaults are applied silently in `parse_results`.

### 3.2 Callback return types

```elixir
@callback autocomplete(String.t(), keyword()) ::
            {:ok, [Result.t()]} | {:error, atom() | tuple()}
```

`{:error, reason}` where reason can be:
* `:text_too_short` (atom)
* `:api_key_missing` (atom)
* `{:api_error, status}` (tuple with integer HTTP status)
* `:network_error` (atom)

### 3.3 Evidence

* `lib/gtfs_planner/geocoding.ex:14-31` – Result struct definition
* `lib/gtfs_planner/geocoding/behaviour.ex:8-9` – callback typespec
* `lib/gtfs_planner/geocoding/geoapify.ex:13-14,23-24,38-39,41-42` – error return sites

---

## 4. Behavior Pattern (Runtime Dependency Inversion)

The system uses Elixir's `@behaviour` + `Application.get_env` for runtime dependency inversion.

**Resolution flow:**
1. `config.exs` sets `:geocoding_service` to `GtfsPlanner.Geocoding.Geoapify`
2. `test.exs` overrides `:geocoding_service` to `GtfsPlanner.GeocodingMock` (a Mox mock defined in `test/support/mocks.ex`)
3. `GtfsPlanner.Geocoding.autocomplete/2` reads the config key at call time and applies the resolved module
4. The mock is backed by the `Behaviour` callback, so `Mox.stub/3` / `Mox.expect/4` enforce the contract at compile time

**Diagram:**
```
Caller → GtfsPlanner.Geocoding.autocomplete(text, opts)
           ↓ (runtime resolution via Application.get_env)
         GtfsPlanner.Geocoding.Geoapify.autocomplete(text, opts)  [prod/dev]
         GtfsPlanner.GeocodingMock.autocomplete(text, opts)       [test]
```

**Key characteristic:** The dispatch is fully runtime. No compile-time dependency on the implementation. Any module implementing the `Behaviour` can be swapped in.

### 4.1 Evidence

* `lib/gtfs_planner/geocoding.ex:52-54` – dispatch
* `config/config.exs:14` – default implementation
* `config/test.exs:26` – test mock
* `test/support/mocks.ex:3` – Mox mock definition

---

## 5. Geoapify API Contract

### 5.1 Endpoint

```
GET https://api.geoapify.com/v1/geocode/autocomplete
```

### 5.2 Request

| Parameter | Value | Source |
|-----------|-------|--------|
| `text` | User-provided query string | Caller input |
| `apiKey` | `Application.get_env(:gtfs_planner, :geoapify_api_key)` | Runtime config |
| `format` | `"json"` | Hardcoded |
| `limit` | `5` | Hardcoded |
| `filter` | `"countrycode:us"` | Hardcoded |

### 5.3 Successful Response (HTTP 200)

```json
{
  "results": [
    {
      "formatted": "Regent, ND, United States of America",
      "lat": 46.4216712,
      "lon": -102.555719,
      "country": "United States",
      "state": "North Dakota",
      "city": "Regent"
    }
  ]
}
```

### 5.4 Error Responses

| Status | Condition | Internal Error |
|--------|-----------|----------------|
| Any non-200 | API error | `{:error, {:api_error, status}}` |
| Connection failure | Network/transport | `{:error, :network_error}` |
| API key `nil` | Missing config | `{:error, :api_key_missing}` |

### 5.5 HTTP Client

Uses `Req.get/2` from the `:req` library. No explicit timeout, no retry, no custom headers, no plug/Req.Test injection for this endpoint (unlike the map tiles controller which has `req_options/0` with retry + `Req.Test` plug support in tests).

### 5.6 Evidence

* `lib/gtfs_planner/geocoding/geoapify.ex:26-32` – request parameters
* `lib/gtfs_planner/geocoding/geoapify.ex:34-43` – response handling
* `lib/gtfs_planner/geocoding/geoapify.ex:20-24` – API key check
* `lib/gtfs_planner_web/controllers/map_tiles_controller.ex:50-66` – comparison: map tiles controller has retry/timeout config; geocoding does not

---

## 6. Error Handling Inventory

| Error condition | Module | Line | Return value | Client impact |
|-----------------|--------|------|-------------|---------------|
| Text < 3 chars | `geoapify.ex` | 13-14 | `{:error, :text_too_short}` | Client must handle |
| API key is nil | `geoapify.ex` | 23-24 | `{:error, :api_key_missing}` | Client must handle |
| HTTP non-200 | `geoapify.ex` | 38-39 | `{:error, {:api_error, status}}` | Client must inspect tuple |
| Req transport error | `geoapify.ex` | 41-42 | `{:error, :network_error}` | Client must handle |
| Empty/malformed response | `geoapify.ex` | 35 | Falls to `:api_error` or no match → function clause error | **Unhandled crash risk** |
| `"results"` key absent in response body | `geoapify.ex` | 35 | Pattern match fails → `{:error, {:api_error, status}}` (only for non-200) or function clause error for 200 with missing `"results"` | **Unhandled crash risk** |

### 6.1 Risk: Unmatched 200 responses

The pattern match on line 34-35 requires exactly `%{status: 200, body: %{"results" => results}}`. If Geoapify returns HTTP 200 with a different body shape (e.g., `%{"results" => nil}` or missing the `"results"` key entirely), the match will fail for the `{:ok, %{status: 200}}` branch and fall through. But there is no catch-all for the 200 case. Only the `{:ok, %{status: status}}` branch catches non-200 responses. A 200 response missing `"results"` will cause a `FunctionClauseError` crash in the caller process.

### 6.2 Risk: Non-list `"results"`

If `"results"` is present but not a list (e.g., `nil`), `parse_results/1` will crash with a `FunctionClauseError` since its guard requires `is_list(results)`.

### 6.3 Evidence

* `lib/gtfs_planner/geocoding/geoapify.ex:34-43` – response pattern matching
* `lib/gtfs_planner/geocoding/geoapify.ex:47` – `is_list(results)` guard

---

## 7. Configuration & Environment

### 7.1 Compile-time config (`config.exs`)

```elixir
config :gtfs_planner,
  geocoding_service: GtfsPlanner.Geocoding.Geoapify
```

### 7.2 Runtime config (`runtime.exs`)

```elixir
config :gtfs_planner,
  :geoapify_api_key,
  System.get_env("GEOAPIFY_API_KEY") ||
    if(config_env() == :prod,
      do: raise("environment variable GEOAPIFY_API_KEY is missing"),
      else: nil
    )
```

### 7.3 Test config (`test.exs`)

```elixir
config :gtfs_planner, :geocoding_service, GtfsPlanner.GeocodingMock
```

### 7.4 Environment behavior matrix

| Env | `geocoding_service` | `geoapify_api_key` | Behavior |
|-----|---------------------|-------------------|----------|
| `:dev` | `Geoapify` | `nil` if env not set | Autocomplete returns `{:error, :api_key_missing}` unless `GEOAPIFY_API_KEY` is exported |
| `:prod` | `Geoapify` | Required (raises if missing) | Full autocomplete via Geoapify |
| `:test` | `GeocodingMock` (Mox) | `nil` (irrelevant) | All calls go through Mox stubs/expectations |

### 7.5 Evidence

* `config/config.exs:14` – default service
* `config/runtime.exs:136-142` – API key
* `config/test.exs:26` – test mock

---

## 8. Client Integration (Callers)

### 8.1 Direct callers of `GtfsPlanner.Geocoding.autocomplete/2`

* `lib/gtfs_planner_web/live/components_live.ex:153` – `normalize_result/1` expects `%Geocoding.Result{}`
* `lib/gtfs_planner_web/live/gtfs/station_diagram_live.ex:4680` – `normalize_geocoding_result/1`
* `lib/gtfs_planner_web/live/gtfs/station_reachability_live.ex:1657` – `normalize_geocoding_result/1`

### 8.2 Indirect consumer

* `lib/gtfs_planner_web/controllers/map_tiles_controller.ex` – uses the same `:geoapify_api_key` config key but calls Geoapify tile endpoints directly (no geocoding involved). Shares only the API key config, not the geocoding module.

### 8.3 Evidence

* `lib/gtfs_planner_web/live/components_live.ex:153,161`
* `lib/gtfs_planner_web/live/gtfs/station_diagram_live.ex:4680,4688`
* `lib/gtfs_planner_web/live/gtfs/station_reachability_live.ex:1657,1665`

---

## 9. Test Coverage

### 9.1 Test file

`test/gtfs_planner/geocoding_test.exs` (62 lines, 4 tests)

### 9.2 Tests

| Test | Covers | Approach |
|------|--------|----------|
| `returns error when text is less than 3 characters` | Text length guard | Stubs mock to return `:text_too_short`, asserts |
| `returns error when API key is missing` | API key check | Stubs mock to return `:api_key_missing`, asserts |
| `returns results with valid text` | Happy path | Stubs mock to return `{:ok, [%Result{}]}`, asserts list and struct shape |
| `handles network errors gracefully` | Network error | Stubs mock to return `:network_error`, asserts |

### 9.3 Test design notes

* All tests go through the `GeocodingMock` Mox mock – they never exercise the `Geoapify` implementation directly
* The valid-text test checks the Result struct shape but uses hardcoded test data (not actual API responses)
* **No integration tests** for the actual Geoapify API endpoint
* **No test** for `{:api_error, status}` error path
* **No test** for malformed or unexpected API response shapes
* **No test** for `parse_results` edge cases (empty list, missing fields, unexpected types)

### 9.4 Coverage gaps

* `Geoapify.fetch_from_api/2` response parsing edge cases
* `Geoapify.parse_results/1` with non-list or nil results
* HTTP 200 with unexpected body structure
* Actual HTTP call integration (requires key)

### 9.5 Evidence

* `test/gtfs_planner/geocoding_test.exs:1-62` – all four tests
* `test/support/mocks.ex:3` – mock definition

---

## 10. Risks & Ambiguities

| # | Severity | Description |
|---|----------|-------------|
| 1 | **High** | **Unmatched 200 response crash risk.** If Geoapify returns HTTP 200 without a `"results"` key in the body (or with `"results" => nil`), the pattern match in `geoapify.ex:35` will fail and crash the caller with a `FunctionClauseError`. No catch-all fallback exists. |
| 2 | **Medium** | **No HTTP timeout/retry on autocomplete endpoint.** Unlike `MapTilesController` which has `receive_timeout: 10_000` and `max_retries: 2`, the geocoding autocomplete call uses raw `Req.get/2` with no explicit timeout. This could block the calling LiveView process indefinitely on network issues. |
| 3 | **Medium** | **API key shared across concerns.** `:geoapify_api_key` is used by both the geocoding service and the map tiles controller. A misconfiguration affects both features simultaneously. |
| 4 | **Low** | **Hardcoded US-only filter.** `filter: "countrycode:us"` is hardcoded with no configuration override. International users cannot use the autocomplete feature. |
| 5 | **Low** | **Hardcoded result limit of 5.** The `limit: 5` parameter is not configurable. |
| 6 | **Low** | **Silent defaults for missing fields.** `Map.get(result, "lat", 0.0)` produces coordinates at (0.0, 0.0) for missing lat/lon, leading to potentially misleading map markers. |
| 7 | **Low** | **`parse_results/1` crashes on non-list.** If Geoapify returns `"results": null` or a non-list value, `parse_results/1` crashes since the guard `is_list(results)` fails. Combined with risk #1, this creates multiple crash paths for unexpected API responses. |
| 8 | **Info** | **`opts` parameter is unused.** Both the `Behaviour` callback signature and the `Geoapify` implementation accept `opts` but ignore it (`_opts`). This is dead parameter space. |

---

## 11. Assumptions

1. **Geoapify API response shape is stable.** The code assumes the `"results"` key in the JSON body will always be present and be a list when the status is 200.
2. **Geoapify API returns all response fields.** The code assumes `"formatted"`, `"lat"`, `"lon"`, `"country"`, `"state"`, `"city"` are always present in each result object. Missing fields are silently defaulted.
3. **US-only scope.** The `countrycode:us` filter is intentional and permanent.
4. **No pagination needed.** The hardcoded `limit: 5` is sufficient.
5. **Geoapify API key is a single string.** The code uses a flat string API key (query parameter authentication), not OAuth or bearer token.
6. **Geoapify accepts `text` as-is.** No input sanitization or encoding is applied beyond Elixir string behavior. Special characters, Unicode, or very long strings are sent directly to the API.
7. **Caller processes are supervised.** No `try/rescue` in `fetch_from_api`; crashes propagate to the caller and rely on its supervisor for recovery.
8. **`Req` default timeout is acceptable.** No custom `:receive_timeout` or `:connect_options` are passed to `Req.get/2` for this endpoint.

---

## Source Hash

```
sha256:0d390f7a5c1d372c640a89c4b2d7650e76a07dede4a1c6181d9fcb2ee57cb927
```
