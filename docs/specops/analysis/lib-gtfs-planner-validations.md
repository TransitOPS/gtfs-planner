# Validation Context (lib/gtfs_planner/validations)

## Target

- **Slug:** `lib-gtfs-planner-validations`
- **Structural unit:** `lib/gtfs_planner/validations`
- **Source globs:** `lib/gtfs_planner/validations/**`
- **Source hash:** `sha256:56a202835ffffc268d3d7031eab62b32de03ef9f292767370770294d06bcbc5f`
- **Generated:** 2026-06-26
- **Origin:** derived

## 1. System Summary

The Validation Context is the persistence and orchestration boundary for GTFS validation runs. It manages three distinct validation run types—`mobility_data` (MobilityData validator integration), `pathways_tests` (walkability/pathways OTP-based reachability testing), and `station_reachability` (station-scoped reachability testing)—through a unified lifecycle spanning creation, status transitions (pending/started/running/completed/failed), result persistence, and structured error reporting.

The context provides a modular preflight system (`PathwaysPreflight`) that runs deterministic checks against GTFS datasets (station coordinates, boarding area integrity, referential integrity, stop-time time formats, service-window coverage), a walkability suite selector (`WalkabilitySuite`) that validates and classifies test cases, and an imperative runner (`PathwaysTripTestRunner`) that orchestrates OTP runtime execution with downstream `PathwaysValidity` to drive walk-plan GraphQL queries.

Results are persisted via three database schemas: `gtfs_validation_runs` for run-level metadata and aggregated counts, `walkability_tests` for expected test parameters, and `walkability_test_run_results` for per-case outcome rows. A run-level report envelope (versioned JSON) is produced via `transform_pathways_run_result/1` and includes summaries, selection diagnostics, failure categories, and stage timestamps. Station reachability runs carry extra metadata (`station_stop_id`, `station_feed_summary`) in their `result_json`.

## 2. Module Map

| Module | Role | Key Types/Structs |
|---|---|---|
| `GtfsPlanner.Validations` | Context boundary: lifecycle orchestration, persistence, status queries, result transformation | `ValidationRun`, `WalkabilityTest`, `WalkabilityTestRunResult` |
| `GtfsPlanner.Validations.ValidationRun` | Ecto schema for `gtfs_validation_runs` | `:run_type`, `:status`, `:errors_count`, `:warnings_count`, `:infos_count`, `:duration_ms`, `:result_json`, `:error_details`, `:started_at`, `:completed_at` |
| `GtfsPlanner.Validations.WalkabilityTest` | Ecto schema for `walkability_tests` | `:stop_id`, `:address`, `:address_lat`, `:address_lon`, `:expected_traversable`, `:expected_wheelchair_accessible`, duration/distance bounds |
| `GtfsPlanner.Validations.WalkabilityTestRunResult` | Ecto schema for `walkability_test_run_results` | `:order_index`, `:status`, `:failure_category`, route output fields, wheelchair output fields, `:details_json`, `:itinerary_steps_json` |
| `GtfsPlanner.Validations.PathwaysPreflight` | Deterministic preflight gate: loads GTFS records, evaluates rules, returns tagged outcomes | `:blocking_errors`, `:warnings`, `:metadata` with `:record_counts` |
| `GtfsPlanner.Validations.PathwaysTripTestRunner` | Imperative runner: orchestrates OTP runtime + pathways validity, persists terminal outcomes | Run options (`:status_callback`, `:otp_runtime_module`, `:pathways_validity_module`, `:validations_module`) |
| `GtfsPlanner.Validations.PathwaysCaseSummary` | Pure helpers: case display status classification, trip-level overview aggregation | `:case_display_status/1`, `:trip_overview/1` |
| `GtfsPlanner.Validations.WalkabilitySuite` | Suite selector: validates test cases, produces structured suite/invalid/selection metadata | `:suite`, `:invalid_cases`, `:meta`, `:selection` |

## 3. Public API Contract

### 3.1 GtfsPlanner.Validations

**run creation and queries:**
- `create_validation_run(organization_id, gtfs_version_id, run_type)` → `{:ok, %ValidationRun{}}` | `{:error, changeset}` — creates run with `status: "started"`
- `create_pathways_validation_run(org_id, version_id)` → `{:ok, %ValidationRun{}}` | `{:error, changeset}`
- `create_station_reachability_run(org_id, version_id, station_stop_id)` → `{:ok, %ValidationRun{}}` | `{:error, changeset}` — creates with `status: "pending"` and `result_json.metadata.station_stop_id`
- `start_pathways_trip_test(org_id, version_id, opts)` → `{:ok, %ValidationRun{}}` | `{:error, term}` — creates, marks running, spawns runner
- `start_station_reachability_test(org_id, version_id, station_stop_id, opts)` → `{:ok, %ValidationRun{}}` | `{:error, term}` — creates station run, injects station reachability runtime opts (materializer fun, station scope), spawns runner
- `get_active_pathways_trip_test(org_id, version_id)` → `%ValidationRun{}` | `nil` — newest active (started/running) pathways run
- `get_active_station_reachability_run(org_id, version_id, station_stop_id)` → `%ValidationRun{}` | `nil` — newest active (pending/started/running) station run, matches via `result_json->'metadata'->>'station_stop_id'` or fallback `result_json->>'station_stop_id'`
- `reusable_station_reachability_run(org_id, version_id, station_stop_id, opts)` → `{:ok, %ValidationRun{}}` | `:none`
- `get_latest_completed_pathways_trip_test(org_id, version_id)` → `%ValidationRun{}` | `nil`
- `get_validation_run!(id)` → `%ValidationRun{}` | raises `Ecto.NoResultsError`
- `get_validation_run(id)` → `%ValidationRun{}` | `nil`
- `list_validation_runs(org_id, version_id)` → `[%ValidationRun{}, ...]` — ordered `desc: started_at`, limit 20
- `list_recent_validation_runs(org_id, version_id, limit \\ 5)` → `[%ValidationRun{}, ...]` — terminal runs only (completed/failed), `desc: started_at`
- `list_recent_station_reachability_runs(org_id, version_id, station_stop_id, limit \\ 5)` → `[%ValidationRun{}, ...]` — terminal station runs, filtered by station JSON metadata

**status transitions:**
- `mark_running(run)` → `{:ok, %ValidationRun{}}` | `{:error, changeset}` — sets status to `"running"`
- `mark_pathways_running(run)` → `{:ok, %ValidationRun{}}` | `{:error, :invalid_status_transition}` — guard: run_type must be `"pathways_tests"`, status must be `"started"`
- `mark_completed(run, result)` → `{:ok, %ValidationRun{}}` | `{:error, changeset}` — stores notices JSON, counts, duration, completed_at; uses `stale_error_field: :id`
- `mark_failed(run, reason)` → `{:ok, %ValidationRun{}}` | `{:error, changeset}` — stores `inspect(reason)` as error_details; uses `stale_error_field: :id`
- `mark_pathways_failed(run, reason)` → `{:ok, %ValidationRun{}}` | `{:error, changeset}` | `{:error, :invalid_run_type}` — serializes structured JSON error with `scope`, `reason`, `details`, `issues`
- `mark_pathways_completed(run, run_result, duration_ms)` → `{:ok, %ValidationRun{}}` | `{:error, term}` — **transactional**: calls `transform_pathways_run_result/1`, updates run record, bulk-inserts walkability_test_run_results rows; rolls back on any failure

**pathways reporting:**
- `get_pathways_trip_test_status(validation_run_id)` → `{:ok, map}` | `{:error, :not_found | :invalid_run_type}` — normalized status including decoded error payload for failed runs
- `get_pathways_trip_test_results(validation_run_id)` → `{:ok, %{id, run_type, status, result_json, walkability_test_run_results}}` | `{:error, :not_found | :invalid_run_type | :run_not_completed}`
- `get_pathways_run_report(validation_run_id)` → `map` | `nil` — raw `result_json` for pathways runs only
- `list_walkability_test_run_results(validation_run_id)` → `[%WalkabilityTestRunResult{}, ...]` — ordered `asc: order_index, asc: walkability_test_id`, preloads `walkability_test`
- `transform_pathways_run_result(run_result)` → `%{result_json: map, case_row_attrs: [map]}` — transforms runtime result into persistence-ready payloads

**walkability tests CRUD:**
- `list_walkability_tests(org_id, version_id)` → `[%WalkabilityTest{}, ...]` — ordered `asc: stop_id, asc: address, asc: id`
- `list_walkability_tests_for_stop_ids(org_id, version_id, stop_ids)` → `[%WalkabilityTest{}, ...]` — returns `[]` for empty stop_ids; ordered `desc: inserted_at`
- `get_walkability_test!(id)` → `%WalkabilityTest{}` | raises
- `get_walkability_test(id)` → `%WalkabilityTest{}` | `nil`
- `create_walkability_test(org_id, version_id, attrs)` → `{:ok, %WalkabilityTest{}}` | `{:error, changeset}`
- `update_walkability_test(test, attrs)` → `{:ok, %WalkabilityTest{}}` | `{:error, changeset}`
- `delete_walkability_test(test)` → `{:ok, %WalkabilityTest{}}` | `{:error, changeset}`
- `change_walkability_test(test, attrs \\ %{})` → `%Ecto.Changeset{}`
- `stop_ids_with_walkability_tests(org_id, stop_ids)` → `%{stop_id => count}` — grouped counts; returns `%{}` for empty stop_ids

### 3.2 PathwaysPreflight

- `run(organization_id, gtfs_version_id, opts)` → `{:ok, result}` | `{:error, result}`
  - `opts` may include `:test_window_context` (map with optional `:service_date`/`:query_date`/`:date`/`:test_date`/`:query_datetime`/`:datetime`) and `:expected_longitude_sign` (`:negative`/`:west`/`:positive`/`:east`)
  - `result`: `%{blocking_errors: [issue], warnings: [issue], metadata: %{organization_id, gtfs_version_id, test_window_context, record_counts}}`
  - Returns `{:ok, result}` when `blocking_errors` is empty, `{:error, result}` otherwise
- `load_required_records(organization_id, gtfs_version_id)` → `%{stops, pathways, stop_times, trips, routes, calendars, calendar_dates}` — public helper for external callers

**Issue codes emitted:**
- `:station_stop_lat_missing`, `:station_stop_lon_missing` — missing coordinates on station (location_type=1)
- `:station_stop_lat_not_numeric`, `:station_stop_lon_not_numeric` — non-numeric coordinates
- `:station_stop_lat_out_of_range`, `:station_stop_lon_out_of_range` — out of valid range (-90..90, -180..180)
- `:station_stop_lon_sign_mismatch` — longitude sign doesn't match configured region
- `:boarding_area_parent_station_missing` — boarding area (location_type=4) missing parent_station
- `:boarding_area_parent_station_not_found` — boarding area references unknown parent_station
- `:stop_time_trip_not_found` — stop_time references unknown trip_id
- `:stop_time_stop_not_found` — stop_time references unknown stop_id
- `:trip_route_not_found` — trip references unknown route_id
- `:trip_service_not_found` — trip references unknown service_id
- `:stop_time_arrival_time_invalid_format`, `:stop_time_departure_time_invalid_format` — invalid H:MM:SS format
- `:service_window_no_active_service` — no active service_id for the selected service date
- `:pathway_endpoint_stop_missing` (warning) — pathway missing from_stop_id or to_stop_id
- `:pathway_endpoint_stop_not_found` (warning) — pathway references unknown stop_id

### 3.3 PathwaysTripTestRunner

- `run(validation_run, organization_id, gtfs_version_id, opts)` → `{:ok, %ValidationRun{}}` | `{:error, map}`
  - Orchestrates OTP runtime with in-session pathways validity checks
  - On success: calls `validations_module.mark_pathways_completed(validation_run, run_result, duration_ms)`
  - On `{:error, issues}` with list of issues: calls `persist_failed_run` with `reason: :otp_runtime_failed`
  - On other `{:error, reason}`: normalizes failure reason and persists
  - Detects stale validation run errors (`%Ecto.Changeset{}` with `stale: true` in errors) and returns `:validation_run_stale`
  - Extracts `station_feed_summary` from runtime metadata and injects into `run_result.suite_meta`
- **Run options:** `:status_callback`, `:otp_runtime_module` (default `Application.get_env(:gtfs_planner, :otp_runtime_module, Runtime)`), `:otp_pathways_validity_module` (default `Application.get_env(:gtfs_planner, :otp_pathways_validity_module, PathwaysValidity)`), `:validations_module` (default `Validations`), `:pathways_validity_opts`, `:runtime_opts`
- **Runtime opts always include:** `preflight_mode: :strict`, `force_rebuild: true`

### 3.4 PathwaysCaseSummary

- `case_display_status(row)` → `"failed"` | `"warning"` | `"pass"` — classifies a case result row: `query_failure` → `"failed"`, traversable mismatch → `"failed"`, other criteria mismatches → `"warning"`, otherwise → `"pass"`
- `trip_overview(pathways_case_results)` → `%{total_tests, pass_count, warning_count, fail_count}` — aggregates statuses across a list of case results

### 3.5 WalkabilitySuite

- `select_suite(organization_id, gtfs_version_id, opts)` → `{:ok, %{suite, invalid_cases, meta, selection}}`
  - Loads valid stop IDs from `Gtfs.list_stops/2`, then all walkability tests for the org/version
  - Applies `:allowed_stop_ids` scope filter (MapSet or list, nil = no filter)
  - Classifies each candidate as `:valid` or `:invalid` and returns structured selection
- **Invalid case reasons:** `:missing_coordinates` (nil address_lat/lon), `:invalid_coordinate_range` (out of -90..90/-180..180), `:invalid_stop_id_for_version` (stop_id not in GTFS version), `:invalid_expectation_bounds` (min > max for duration or distance)
- **Suite ordering:** `"stop_id ASC, address ASC, id ASC"`
- Default scope label is normalized (trimmed, nil if empty)
- Suite cases are returned with normalized coordinate types (Decimal→float) and optional fields normalized (nil for non-boolean expected_traversable, nil for non-integer bounds)

### 3.6 Schemas

**ValidationRun (gtfs_validation_runs):**
- `run_type` ∈ `["mobility_data", "pathways_tests", "station_reachability"]`
- `status` ∈ `["pending", "started", "running", "completed", "failed"]`
- `organization_id`, `gtfs_version_id` — programmatically set, not cast
- `errors_count`, `warnings_count`, `infos_count` — default 0
- `has_many :walkability_test_run_results`
- Unique constraint on address: `walkability_tests_organization_id_gtfs_version_id_stop_id_addre`
- Validates min/max range for `expected_min/max_duration_seconds` and `expected_min/max_distance_meters`
- All string fields trimmed via `ChangesetHelpers.trim_string_fields/1`

**WalkabilityTestRunResult (walkability_test_run_results):**
- `status` ∈ `["passed", "failed"]`
- `failure_category` ∈ `["query_failure", "scoring_failure"]` (nullable)
- Unique constraints: `(validation_run_id, walkability_test_id)` and `(validation_run_id, order_index)`

## 4. Business Logic & Rules

### 4.1 Validation Run Lifecycle

```
create (started) → mark_running → [runner execution] → mark_completed / mark_failed
```

**Pathways-specific:**
```
create_pathways_validation_run (started) → mark_pathways_running (running, guard: must be "started") → [runner spawns PathwaysTripTestRunner] → mark_pathways_completed / mark_pathways_failed
```

**Station reachability-specific:**
```
create_station_reachability_run (pending, with station metadata) → mark_running → [runner spawns with station materializer opts] → mark_pathways_completed / mark_pathways_failed
```

- Station reachability runs persist extra JSON fields: `metadata.station_stop_id`, `station_stop_id` (root), `station_feed_summary`
- On runner-spawn failure, the run is marked failed with structured error (not a raw inspection)
- Pathways trip tests always create a new run; they do not gate on existing active runs
- `mark_completed/2` and `mark_failed/2` use `stale_error_field: :id` for optimistic locking

### 4.2 Pathways Completed Transaction

`mark_pathways_completed/3` wraps everything in `Repo.transaction/1`:
1. Calls `transform_pathways_run_result/1` to produce `result_json` and normalized `case_row_attrs`
2. Adds `stage_timestamps` (started_at/completed_at ISO 8601) to `result_json`
3. For station reachability runs: merges `station_stop_id`, `metadata`, `station_feed_summary` into `result_json`
4. Updates the run record (status="completed", counters mapped: errors=failed, warnings=query_failure, infos=passed)
5. Bulk-inserts `walkability_test_run_results` via `Repo.insert_all/2`

### 4.3 Structured Error Serialization

For pathways failures, `serialize_pathways_error/1` produces:
```json
{"scope": "pathways_tests", "reason": "<reason_code>", "details": {...}, "issues": [...]}
```

Error decoding (`decode_pathways_error_payload/2`) handles:
- Valid JSON maps → normalized with required fields (`scope`, `reason`, `details`, `issues`)
- Non-map JSON → `legacy_error_details` payload with raw_error_details
- Invalid JSON (plain strings) → `legacy_error_details` payload
- Missing `reason` falls back to `reason_code` in payload (backward compat)

### 4.4 Preflight Rule Evaluation

Preflight evaluators are composed as closures run via `run_evaluators/2`. Results are flattened with `Enum.flat_map/2`.

**Blocking evaluators (in order):**
1. `evaluate_station_coordinates/1` — checks lat/lon presence, numeric validity, range for location_type=1 stops
2. `evaluate_station_longitude_sign/2` — validates sign matches configured region (western/eastern hemisphere)
3. `evaluate_boarding_area_parent_integrity/1` — checks location_type=4 stops have valid parent_station reference
4. `evaluate_referential_integrity/1` — cross-references stop_times→trips, stop_times→stops, trips→routes, trips→services
5. `evaluate_stop_time_time_formats/1` — validates H:MM:SS format with 0-59 minute/second bounds
6. `evaluate_active_service_window/2` — checks if any trip services are active on the selected test date

**Warning evaluators:**
- `evaluate_warnings/1` — checks pathway endpoints (from_stop_id, to_stop_id) reference known stops

### 4.5 Service Window Logic

- Active service date is extracted from `test_window_context` by checking candidates in order: `:service_date`, `:query_date`, `:date`, `:test_date`, `:query_datetime`, `:datetime`
- Supports `Date`, `DateTime`, `NaiveDateTime`, and ISO 8601 string formats
- Active services = calendar entries covering the date (by day-of-week + start/end date range) + calendar_dates with exception_type=1 (additions) - calendar_dates with exception_type=2 (removals)

### 4.6 Longitude Sign Region Detection

- Expected sign is resolved from: 1) explicit `:expected_longitude_sign` opt, 2) `test_window_context.expected_longitude_sign`
- Accepted values: `:negative`, `:west`, `-1` → negative; `:positive`, `:east`, `1` → positive
- Longitude 0.0 is exempt from sign checks

### 4.7 Case Status Classification (PathwaysCaseSummary)

From `details_json`:
- Extracts mismatch map from `details_json.mismatches` list keyed by mismatch `kind`
- `failure_category == "query_failure"` → `"failed"`
- `expected_traversable` mismatch → `"failed"`
- Any other mismatches (duration, distance, wheelchair) → `"warning"`
- Otherwise → `"pass"`

### 4.8 WalkabilitySuite Malformation Checks

Executed in priority order:
1. `:missing_coordinates` — nil address_lat or address_lon
2. `:invalid_coordinate_range` — lat outside -90..90 or lon outside -180..180
3. `:invalid_stop_id_for_version` — stop_id not in current GTFS version's stops
4. `:invalid_expectation_bounds` — min > max for duration or distance (both must be valid integers, nil/null bounds are accepted)

### 4.9 Counter Mapping

| Run-level field | mobility_data | pathways_tests / station_reachability |
|---|---|---|
| `errors_count` | `result.summary.errors` | `result.summary.failed` |
| `warnings_count` | `result.summary.warnings` | `result.summary.query_failure` |
| `infos_count` | `result.summary.infos` | `result.summary.passed` |

### 4.10 Report Envelope

`transform_pathways_run_result/1` produces:
- `report_version`: always `1`
- `suite_meta`: from runtime (total_candidates, selected_count, malformed_count)
- `selected_test_case_ids`: ordered list of test case IDs
- `selection`: normalized selection diagnostics (total/in_scope candidates, selected/invalid counts, scope_label, test case IDs, invalid cases)
- `summary`: total, passed, failed, query_failure, scoring_failure, pass_rate (rounded to 2 decimal places)
- `top_failure_categories`: non-zero-count categories sorted by count desc then name asc
- `stage_timestamps` (added by `mark_pathways_completed/3`): `started_at`, `completed_at` as ISO 8601 strings

## 5. Data Model

### 5.1 gtfs_validation_runs

```
id: binary_id (UUID, PK)
organization_id: binary_id (FK → organizations)
gtfs_version_id: binary_id (FK → gtfs_versions)
run_type: string ("mobility_data" | "pathways_tests" | "station_reachability")
status: string ("pending" | "started" | "running" | "completed" | "failed")
errors_count: integer, default 0
warnings_count: integer, default 0
infos_count: integer, default 0
duration_ms: integer, nullable
result_json: jsonb, nullable
error_details: text, nullable
started_at: utc_datetime_usec, NOT NULL
completed_at: utc_datetime_usec, nullable
inserted_at: utc_datetime_usec
updated_at: utc_datetime_usec
```

- `has_many :walkability_test_run_results`
- `belongs_to :organization`, `belongs_to :gtfs_version`

### 5.2 walkability_tests

```
id: binary_id (UUID, PK)
organization_id: binary_id (FK → organizations)
gtfs_version_id: binary_id (FK → gtfs_versions)
stop_id: string
address: string
address_lat: decimal
address_lon: decimal
description: string, nullable
expected_traversable: boolean, nullable
expected_wheelchair_accessible: boolean, nullable
expected_min_duration_seconds: integer, nullable
expected_max_duration_seconds: integer, nullable
expected_min_distance_meters: integer, nullable
expected_max_distance_meters: integer, nullable
inserted_at: utc_datetime_usec
updated_at: utc_datetime_usec
```

- Unique: `(organization_id, gtfs_version_id, stop_id, address)` via `walkability_tests_organization_id_gtfs_version_id_stop_id_addre`

### 5.3 walkability_test_run_results

```
id: binary_id (UUID, PK)
validation_run_id: binary_id (FK → gtfs_validation_runs)
walkability_test_id: binary_id (FK → walkability_tests)
order_index: integer, NOT NULL
status: string ("passed" | "failed")
failure_category: string ("query_failure" | "scoring_failure"), nullable
route_exists: boolean, nullable
duration_seconds: float, nullable
distance_meters: float, nullable
itinerary_start_time: utc_datetime_usec, nullable
itinerary_end_time: utc_datetime_usec, nullable
leg_count: integer, nullable
step_count: integer, nullable
itinerary_steps_json: jsonb, nullable
wheelchair_route_exists: boolean, nullable
wheelchair_duration_seconds: float, nullable
wheelchair_distance_meters: float, nullable
details_json: jsonb, nullable
inserted_at: utc_datetime_usec
updated_at: utc_datetime_usec
```

- Unique: `(validation_run_id, walkability_test_id)` via `walkability_test_run_results_run_case_unique_index`
- Unique: `(validation_run_id, order_index)` via `walkability_test_run_results_run_order_unique_index`

## 6. Integration Points

### 6.1 Inbound Dependencies

| Dependency | Usage |
|---|---|
| `GtfsPlanner.Gtfs` | `list_stops/2` (destination coordinate resolution), `list_station_scope_stop_ids/3` (station-scoped suite selection) |
| `GtfsPlanner.Repo` | All persistence operations |
| `GtfsPlanner.ChangesetHelpers` | `trim_string_fields/1` for whitespace normalization |
| `Ecto.Schema`, `Ecto.Changeset`, `Ecto.Query` | Schema definitions, validation, query building |
| `Application` | Runtime configuration reads (`:otp_runtime_module`, `:otp_pathways_validity_module`, `:pathways_trip_test_runner_module`, `:pathways_trip_test_task_supervisor`) |

### 6.2 Outbound Dependencies (modules the context spawns or delegates to)

| Dependency | Usage |
|---|---|
| `GtfsPlanner.Otp.PathwaysValidity` | `run_in_session/4` — executes OTP in-session walk-plan validation |
| `GtfsPlanner.Otp.Runtime` | `run_with_otp/4` — OTP Java runtime lifecycle |
| `GtfsPlanner.Otp.StationMaterializer` | `get_or_build_gtfs_zip/3` — station-scoped GTFS ZIP generation |
| `GtfsPlanner.TaskSupervisor` | `Task.Supervisor.start_child/2` — spawns runner tasks |
| `Req` | HTTP client used by `PathwaysValidity` for GraphQL walk-plan queries |

### 6.3 Configuration Keys

- `:gtfs_planner, :otp_runtime_module` → default `GtfsPlanner.Otp.Runtime`
- `:gtfs_planner, :otp_pathways_validity_module` → default `GtfsPlanner.Otp.PathwaysValidity`
- `:gtfs_planner, :pathways_trip_test_runner_module` → default `GtfsPlanner.Validations.PathwaysTripTestRunner`
- `:gtfs_planner, :pathways_trip_test_task_supervisor` → default `GtfsPlanner.TaskSupervisor`

### 6.4 Test Points

- Runner module is swappable via Application env for isolated testing (mocks in `validations_test.exs`)
- Task supervisor is swappable for spawn-failure testing
- Pathways validity tests use injected `:request_fun` to mock GraphQL responses
- Fixture modules: `GtfsPlanner.ValidationsFixtures`, `GtfsPlanner.GtfsFixtures`, `GtfsPlanner.OrganizationsFixtures`, `GtfsPlanner.VersionsFixtures`

## 7. Error Handling

### 7.1 Paths of Failure

1. **Invalid input** → `{:error, %Ecto.Changeset{}}` with field-level errors (foreign key violations, inclusion errors, validation failures)
2. **Runner spawn failure** → run marked failed with `{:error, {:pathways_runner_spawn_failed, reason}}`, error_details JSON with `scope: "pathways_tests"`, `reason: "pathways_runner_spawn_failed"`
3. **OTP runtime failure** → `PathwaysTripTestRunner` catches `{:error, issues}` and persists via `persist_failed_run/3`
4. **Pathways persistence failure** → `{:error, %{reason: :pathways_persistence_failed, details: ...}}`, run marked failed
5. **Stale validation run** → `{:error, %{reason: :validation_run_stale, details: ...}}` (detected via `stale_error_field: :id`)
6. **No walkability tests** → `{:error, reason}` with `reason.reason == :no_walkability_tests`, includes suite metadata and selection details
7. **Invalid run type transitions** → `{:error, :invalid_run_type}` or `{:error, :invalid_status_transition}`

### 7.2 Error Normalization

- `normalize_failure_reason/1` in PathwaysTripTestRunner normalizes various failure shapes into `%{reason: ..., details: ...}` format
- `decode_pathways_error_payload/2` handles both structured JSON errors and legacy string error_details
- `PathwaysCaseSummary` gracefully handles nil/missing `details_json`, returns `"pass"` for non-map input
- Station fallback: both `result_json->'metadata'->>'station_stop_id'` and `result_json->>'station_stop_id'` are checked

## 8. State Transitions

```
                                     ┌─────────────┐
                                     │   pending   │ (station_reachability only)
                                     └──────┬──────┘
                                            │ mark_running
                                     ┌──────▼──────┐
                            ┌───────►│   started   │◄────────── create_*_run
                            │        └──────┬──────┘
                            │               │ mark_running / mark_pathways_running
                            │        ┌──────▼──────┐
                            │        │   running   │
                            │        └──────┬──────┘
                            │               │
                    ┌───────┴───────┐       │       ┌───────────────┐
                    │ runner spawn  │       │       │  OTP runtime  │
                    │   failure     │       │       │    failure    │
                    └───────┬───────┘       │       └───────┬───────┘
                            │               │               │
                     ┌──────▼──────┐ ┌──────▼──────┐ ┌──────▼──────┐
                     │   failed    │ │  completed  │ │   failed    │
                     └─────────────┘ └─────────────┘ └─────────────┘
```

**Guard rules:**
- `mark_pathways_running/1`: requires `run_type == "pathways_tests"` AND `status == "started"`
- `mark_pathways_failed/2`: requires `run_type in ["pathways_tests", "station_reachability"]`
- `mark_pathways_completed/3`: requires `run_type in ["pathways_tests", "station_reachability"]`
- All completion/failure ops set `completed_at` and use `stale_error_field: :id`

## 9. Edge Cases & Corner Conditions

1. **Zero walkability tests** → `PathwaysValidity.run_in_session/4` returns `{:error, %{reason: :no_walkability_tests, ...}}` with suite metadata and selection details intact
2. **All candidates invalid** → suite selection returns `suite: []`, validity returns `:no_walkability_tests` error with `selection.selected_count == 0`
3. **Mixed valid/invalid candidates** → only valid cases are executed; invalid cases are reported in `selection.invalid_cases` with reason codes
4. **Longitude 0.0** → exempt from sign mismatch checks (treated as neutral)
5. **Pass rate for zero total** → `0.0` (avoiding division by zero)
6. **Zero-count failure categories** → filtered out of `top_failure_categories`
7. **Nil/blank parent_station** → boarding area check treats nil/"" as missing, returns `:boarding_area_parent_station_missing`
8. **Empty stop_ids list** → `list_walkability_tests_for_stop_ids/3` returns `[]`
9. **Nil/blank stop_time values** → `valid_gtfs_time_format?/1` treats nil and "" as valid (meaning time point unspecified)
10. **Duplicate station reachability runs** → multiple runs can exist concurrently; `get_active_station_reachability_run/3` returns newest
11. **Station reachability JSON fallback** → queries check both `result_json->'metadata'->>'station_stop_id'` and `result_json->>'station_stop_id'` for backward compatibility
12. **Non-pathways run type** → `get_pathways_trip_test_status/1` and `get_pathways_trip_test_results/1` return `{:error, :invalid_run_type}` for stations too; support is `pathways_tests` and `station_reachability`
13. **Wheelchair only when expected** → `PathwaysValidity` only executes wheelchair variant when `expected_wheelchair_accessible` is true or false (not nil)
14. **Empty `result_json` for station runs** → `station_terminal_result_json/3` handles nil `run.result_json`
15. **`WalkabilitySuite.selection` normalizes** `test_case_id`/`walkability_test_id` fields in invalid cases (uses either)
16. **Preflight no test_window_context** → service window check returns empty list when no service_date candidate resolves
17. **Preflight longitude_sign nil** → station longitude sign check is skipped entirely
18. **Decimal coordinates** → Both `WalkabilitySuite` and `PathwaysPreflight` handle Decimal types, converting to float

## 10. Assumptions & Preconditions

1. **Organization and GTFS version always exist** when creating validation runs — otherwise `foreign_key_constraint` errors
2. **OTP runtime is available** at `session.graphql_url` when pathways tests are executed
3. **`GtfsPlanner.TaskSupervisor` is started** in the supervision tree before spawning runners
4. **`Application` env is configured** for swappable modules (runtime_module, pathways_validity_module, runner_module, task_supervisor)
5. **Walkability tests reference valid stop_ids** for the given GTFS version — invalid refs are caught at suite selection time
6. **GTFS stop coordinates are stored as Decimal** in the database — handled by `normalize_coordinate/1` in both suite and preflight
7. **GraphQL endpoint responds** with OTP walk-plan contract (query, variables, itineraries with legs and steps)
8. **Database supports jsonb** for `result_json`, `details_json`, `itinerary_steps_json` fields
9. **Station reachability runs** are identified by `run_type == "station_reachability"` AND JSON metadata containing the station_stop_id
10. **`mark_pathways_running/1`** only accepts `pathways_tests` — station reachability uses `mark_running/1` directly
11. **Potential issue:** `get_pathways_trip_test_results/1` accepts `station_reachability` run_type (via guard `when run_type in ["pathways_tests", "station_reachability"]`) but `get_pathways_run_report/1` only queries `run_type == "pathways_tests"` — station reachability runs won't return a report via this function

## 11. Risks & Open Questions

### 11.1 Risks

1. **Race condition on runner spawn** — `start_pathways_trip_test/2` creates a run, marks it running, then spawns the runner. If the runner crashes before completing, the run stays in "running" status indefinitely with no watchdog.
2. **Stale running runs** — No cleanup mechanism for runs stuck in "running" status. `get_active_pathways_trip_test/2` returns newest active regardless of age; `reusable_station_reachability_run/4` accepts `max_age_seconds` but does not use it — all active runs are considered reusable.
3. **Transaction scope** — `mark_pathways_completed/3` uses a transaction but `mark_pathways_failed/2` does not. If the runner crashes between completing the run and persisting rows, result consistency is at risk.
4. **JSON field access in SQL** — `fragment("COALESCE((?->'metadata'->>'station_stop_id'), (?->>'station_stop_id')) = ?", ...)` relies on Postgres JSON operators and assumes the JSON shape. Changes to result_json structure could break queries silently.
5. **No idempotency for create** — `create_pathways_validation_run/2` does not check for existing runs; `start_pathways_trip_test/2` always creates a new run even when an active one exists. This is intentional but could lead to resource waste with concurrent triggers.
6. **Error detail size** — `mark_failed/2` stores `inspect(reason)` which for large OTP error structures could produce very large strings.
7. **Preflight loads all required records** — `load_required_records/2` loads full datasets (stops, stop_times, pathways, etc.) which could be memory-intensive for large GTFS feeds.

### 11.2 Ambiguities

1. **`reusable_station_reachability_run/4` accepts `max_age_seconds` in opts but never reads it** — the parameter is captured as `_opts` with a default. Tests for stale run behavior exist but don't verify the age gate. The function always returns the newest active run regardless of age. This is either an incomplete implementation or the stale-check logic belongs in the caller.
2. **`mark_pathways_running/1` rejects non-`pathways_tests` runs** but `start_station_reachability_test/4` uses `mark_running/1` for station reachability runs — two different code paths for the same conceptual operation.
3. **Station reachability `get_pathways_trip_test_results/1` accepted** — this function admits `station_reachability` run_type (line 494) but `get_pathways_run_report/1` only queries `run_type == "pathways_tests"` (line 433), suggesting station reachability reporting support is partially implemented.
4. **`WalkabilityTest` changeset validations** call `validate_required([:stop_id, :address, :address_lat, :address_lon, :gtfs_version_id])` but `gtfs_version_id` is set programmatically in `create_walkability_test/3` — if somehow it's nil, the changeset error message won't distinguish it from user-provided fields.

## Evidence

### File Inventory

| File | Lines | Purpose |
|---|---|---|
| `lib/gtfs_planner/validations.ex` | 1382 | Context boundary: run lifecycle, persistence, reporting, result transformation |
| `lib/gtfs_planner/validations/validation_run.ex` | 79 | Ecto schema: `gtfs_validation_runs` |
| `lib/gtfs_planner/validations/walkability_test.ex` | 89 | Ecto schema: `walkability_tests` |
| `lib/gtfs_planner/validations/walkability_test_run_result.ex` | 104 | Ecto schema: `walkability_test_run_results` |
| `lib/gtfs_planner/validations/pathways_preflight.ex` | 790 | Deterministic preflight gate with composable rule evaluators |
| `lib/gtfs_planner/validations/pathways_trip_test_runner.ex` | 212 | Imperative runner orchestrating OTP runtime + pathways validity |
| `lib/gtfs_planner/validations/pathways_case_summary.ex` | 108 | Pure helpers for case status/trip overview aggregation |
| `lib/gtfs_planner/validations/walkability_suite.ex` | 264 | Suite selector with deterministic classification |

### Downstream Modules (Integration)

| File | Lines | Purpose |
|---|---|---|
| `lib/gtfs_planner/otp/pathways_validity.ex` | 848 | OTP in-session walk plan validation via GraphQL |
| `lib/gtfs_planner/otp/runtime/runtime.ex` | — | OTP Java runtime lifecycle management |
| `lib/gtfs_planner/otp/station_materializer.ex` | — | Station-scoped GTFS ZIP generation |
| `lib/gtfs_planner/changeset_helpers.ex` | 23 | Shared trim_string_fields normalization |

### Test Files

| File | Lines | Coverage |
|---|---|---|
| `test/gtfs_planner/validations_test.exs` | 1987 | Run lifecycle, status transitions, reporting queries, walkability tests CRUD, transform_pathways_run_result, mark_pathways_completed |
| `test/gtfs_planner/otp/pathways_validity_test.exs` | 1305 | In-session execution, GraphQL contract, error attribution, wheelchair variants, suite progress, normalization |
| `test/support/fixtures/validations_fixtures.ex` | 29 | Test fixture helper for walkability tests |

### Design Decisions (from code)

- **Optimistic locking via `stale_error_field: :id`** on `mark_completed/2`, `mark_failed/2`, `mark_pathways_failed/2`, `update_pathways_completed_run/5` — ensures terminal transitions don't overwrite each other
- **`Repo.insert_all/2` for walkability test results** rather than individual inserts — bulk performance optimization
- **Module swappability via Application env** — all external modules (OTP runtime, pathways validity, runner, task supervisor) are configurable, enabling integration testing with mocks
- **Structured JSON error serialization** for pathways failures — enables UI error decoding and backward-compatible legacy string handling
- **Preflight evaluator composition** — evaluators are closures accepting a flat `records` map, making the preflight extensible by adding new evaluators to the pipeline
- **Deterministic ordering everywhere** — queries use multi-column ORDER BY with tie-breaking (e.g., `order_by: [desc: run.started_at, desc: run.inserted_at, desc: run.id]`)
- **Decimal coordinate handling** — both `WalkabilitySuite` and `PathwaysPreflight` normalize Decimal→float, supporting the database type while providing float to consumers
