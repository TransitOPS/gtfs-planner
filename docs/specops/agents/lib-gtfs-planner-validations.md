# Validation Context Agent Doc

Source target: `lib-gtfs-planner-validations`
Scope: Creates and tracks GTFS validation runs, pathway and station reachability tests, preflight checks, summaries, and persisted validation results.
Deep analysis: [`lib-gtfs-planner-validations.md`](../analysis/lib-gtfs-planner-validations.md)
Freshness: `source_hash=sha256:56a202835ffffc268d3d7031eab62b32de03ef9f292767370770294d06bcbc5f`, `last_synthesized=2026-06-26`

## Use When
- Creating, querying, or transitioning a GTFS validation run (pathways_tests, station_reachability, or mobility_data)
- Adding a new preflight check to the PathwaysPreflight evaluator pipeline
- Changing the walkability suite selection or case classification logic
- Modifying result persistence, the report envelope, or error serialization
- Debugging runner spawn, OTP runtime orchestration, or stale-run issues

## Read First
- `lib/gtfs_planner/validations.ex` — context boundary (1382 lines): run lifecycle, persistence, reporting, result transformation
- `lib/gtfs_planner/validations/pathways_trip_test_runner.ex` — imperative runner orchestrating OTP + pathways validity
- `lib/gtfs_planner/validations/pathways_preflight.ex` — composable preflight evaluator pipeline (790 lines)

## Interfaces

### Run Lifecycle
- `create_validation_run(org_id, version_id, run_type)` → `{:ok, run}` | `{:error, changeset}` — status: `"started"`
- `create_pathways_validation_run(org_id, version_id)` — alias, status `"started"`
- `create_station_reachability_run(org_id, version_id, station_stop_id)` → status `"pending"`, stores `station_stop_id` in `result_json`
- `start_pathways_trip_test(org_id, version_id, opts)` → creates run, marks running, spawns runner task
- `start_station_reachability_test(org_id, version_id, station_stop_id, opts)` → creates run, injects station materializer, spawns runner
- `reusable_station_reachability_run(org_id, version_id, station_stop_id, opts)` → `{:ok, run}` | `:none` — **`max_age_seconds` opt accepted but never read**; always returns newest active

### Status Transitions
- `mark_running(run)` → `{:ok, run}` — sets status `"running"`
- `mark_pathways_running(run)` → requires `run_type == "pathways_tests"` AND `status == "started"`
- `mark_completed(run, result)` → stores notices JSON, counts, duration, uses `stale_error_field: :id`
- `mark_failed(run, reason)` → stores `inspect(reason)` as error_details, uses `stale_error_field: :id`
- `mark_pathways_completed(run, run_result, duration_ms)` → **transactional**: transforms result, updates run, bulk-inserts `walkability_test_run_results` via `Repo.insert_all/2`
- `mark_pathways_failed(run, reason)` → serializes structured JSON `{scope, reason, details, issues}`, guard: `run_type in ["pathways_tests", "station_reachability"]`

### Queries
- `get_active_pathways_trip_test(org_id, version_id)` → newest `started`/`running` run or `nil`
- `get_active_station_reachability_run(org_id, version_id, station_stop_id)` → newest `pending`/`started`/`running`, matches via `result_json->'metadata'->>'station_stop_id'` OR fallback `result_json->>'station_stop_id'`
- `list_recent_validation_runs(org_id, version_id, limit \\ 5)` → terminal runs only (completed/failed)
- `get_pathways_trip_test_results(run_id)` → returns full results including `walkability_test_run_results`; accepts `station_reachability` run_type

### Preflight (`PathwaysPreflight`)
- `run(org_id, version_id, opts)` → `{:ok, %{blocking_errors, warnings, metadata}}` | `{:error, result}`
- `load_required_records(org_id, version_id)` → `%{stops, pathways, stop_times, trips, routes, calendars, calendar_dates}`
- 6 blocking evaluators + 1 warning evaluator, composed as closures via `run_evaluators/2`
- `test_window_context` opts: `:service_date`, `:expected_longitude_sign` (`:negative`/`:west` | `:positive`/`:east`)

### Suite & Summary
- `WalkabilitySuite.select_suite(org_id, version_id, opts)` → `{:ok, %{suite, invalid_cases, meta, selection}}`
- `PathwaysCaseSummary.case_display_status(row)` → `"failed"` | `"warning"` | `"pass"`
- `PathwaysCaseSummary.trip_overview(results)` → `%{total_tests, pass_count, warning_count, fail_count}`

### Walkability Tests CRUD
- Full CRUD on `WalkabilityTest` (stop_id, address, lat/lon, expected bounds)
- `stop_ids_with_walkability_tests(org_id, stop_ids)` → `%{stop_id => count}` group

## Rules & Invariants

### Lifecycle States
```
pending (station only) → started → running → completed | failed
```
- `mark_pathways_running/1`: guard `run_type=="pathways_tests"` AND `status=="started"`
- Station reachability uses `mark_running/1` directly (no pathways-specific guard)
- All terminal transitions (completed/failed) use `stale_error_field: :id` for optimistic locking
- `mark_pathways_completed/3` wraps everything in `Repo.transaction/1`; `mark_pathways_failed/2` does NOT

### Preflight Issue Codes (15 total)
Blocking: `:station_stop_lat_missing`, `:station_stop_lon_missing`, `:station_stop_lat_not_numeric`, `:station_stop_lon_not_numeric`, `:station_stop_lat_out_of_range`, `:station_stop_lon_out_of_range`, `:station_stop_lon_sign_mismatch`, `:boarding_area_parent_station_missing`, `:boarding_area_parent_station_not_found`, `:stop_time_trip_not_found`, `:stop_time_stop_not_found`, `:trip_route_not_found`, `:trip_service_not_found`, `:stop_time_arrival_time_invalid_format`, `:stop_time_departure_time_invalid_format`, `:service_window_no_active_service`
Warnings: `:pathway_endpoint_stop_missing`, `:pathway_endpoint_stop_not_found`

### Suite Malformation Priority
1. `:missing_coordinates` → 2. `:invalid_coordinate_range` → 3. `:invalid_stop_id_for_version` → 4. `:invalid_expectation_bounds`

### Case Classification
- `failure_category == "query_failure"` → `"failed"`
- `expected_traversable` mismatch → `"failed"`
- Any other mismatch (duration/distance/wheelchair) → `"warning"`
- Otherwise → `"pass"`

### Counter Mapping
| mobility_data | pathways_tests / station_reachability |
|---|---|
| `result.summary.errors` → `errors_count` | `result.summary.failed` → `errors_count` |
| `result.summary.warnings` → `warnings_count` | `result.summary.query_failure` → `warnings_count` |
| `result.summary.infos` → `infos_count` | `result.summary.passed` → `infos_count` |

### Report Envelope (`transform_pathways_run_result/1`)
`report_version: 1`, `suite_meta`, `selected_test_case_ids`, `selection`, `summary` (with pass_rate), `top_failure_categories`, `stage_timestamps` (added by `mark_pathways_completed`)

### Data Model
- `gtfs_validation_runs`: `run_type ∈ ["mobility_data","pathways_tests","station_reachability"]`, `status ∈ ["pending","started","running","completed","failed"]`, `has_many :walkability_test_run_results`
- `walkability_tests`: unique on `(org_id, version_id, stop_id, address)`
- `walkability_test_run_results`: unique on `(validation_run_id, walkability_test_id)` and `(validation_run_id, order_index)`, status ∈ `["passed","failed"]`, failure_category ∈ `["query_failure","scoring_failure"]`

## State, I/O & Side Effects

- **Persistence**: All writes through `GtfsPlanner.Repo`; bulk inserts via `Repo.insert_all/2` for test results
- **Runner spawn**: `Task.Supervisor.start_child/2` via configurable `:pathways_trip_test_task_supervisor`
- **OTP runtime**: Delegates to `GtfsPlanner.Otp.Runtime` (configurable via `:otp_runtime_module`); always `force_rebuild: true, preflight_mode: :strict`
- **Pathways validity**: Delegates to `GtfsPlanner.Otp.PathwaysValidity` (configurable via `:otp_pathways_validity_module`); uses `Req` for GraphQL walk-plan queries
- **Station materializer**: `GtfsPlanner.Otp.StationMaterializer.get_or_build_gtfs_zip/3` for station-scoped ZIP generation
- **Configuration**: 4 swappable Application env keys (`:otp_runtime_module`, `:otp_pathways_validity_module`, `:pathways_trip_test_runner_module`, `:pathways_trip_test_task_supervisor`)
- **No guard against duplicate active runs**: `start_pathways_trip_test` always creates a new run regardless of existing active runs

## Failure Modes

1. **Runner spawn failure** → run marked failed with `{:pathways_runner_spawn_failed, reason}`, structured JSON error
2. **OTP runtime failure** → `persist_failed_run/3` with `reason: :otp_runtime_failed`
3. **No walkability tests** → `{:error, %{reason: :no_walkability_tests}}` with suite metadata
4. **All candidates invalid** → `suite: []`, selection shows selected_count=0
5. **Stale run** → `{:error, %{reason: :validation_run_stale}}` detected via Ecto changeset `stale: true`
6. **Invalid run type transitions** → `{:error, :invalid_run_type}` or `{:error, :invalid_status_transition}`
7. **Pathways persistence failure** → `{:error, %{reason: :pathways_persistence_failed}}`
8. **Race on runner crash** → run stuck in `"running"` indefinitely; no watchdog or cleanup
9. **Large error details** → `mark_failed/2` stores `inspect(reason)` which can be very large for OTP errors

## Change Checklist
- [ ] If adding preflight evaluator, insert into evaluator pipeline in correct order (blocking vs warning), add issue code
- [ ] If adding run_type, update guards in `mark_pathways_running`, `mark_pathways_failed`, `mark_pathways_completed`, `get_pathways_trip_test_results`, `get_pathways_trip_test_status`
- [ ] If changing `result_json` shape, update both `result_json->'metadata'->>'station_stop_id'` and `result_json->>'station_stop_id'` JSON path queries
- [ ] If adding counter, update `counter_mapping` in both persistence paths
- [ ] If changing walkability_test schema, check uniqueness constraint name
- [ ] Run `mix test test/gtfs_planner/validations_test.exs` (1987 lines, lifecycle + CRUD + persistence) and `mix test test/gtfs_planner/otp/pathways_validity_test.exs` (1305 lines, GraphQL contract + error handling)
- [ ] Verify swappable module configs still resolve for all test mocks
- [ ] Check that station reachability paths aren't broken: `get_pathways_run_report/1` only queries `run_type == "pathways_tests"` — station reachability runs excluded from this query

## Escalate To Deep Analysis
- When debugging state transition guard subtleties or the full preflight evaluator composition
- When reasoning about the `reusable_station_reachability_run` stale-age gap (Section 11.2)
- When changing JSON path queries for station reachability (backward-compat fallback logic)
- When the full file inventory, test coverage stats, or downstream module contracts are needed
