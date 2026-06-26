# lib/gtfs_planner/otp — SpecOps Analysis

**Target slug:** `lib-gtfs-planner-otp`  
**Structural unit:** `lib/gtfs_planner/otp/`  
**Source hash:** `sha256:20130303a556b16e3665498f69532fe7ade79befe21bdadb1a7f6fbdc112872c`  
**Analysis date:** 2026-06-26  

---

## 1. Overview  

The `GtfsPlanner.Otp` context is the OTP (OpenTripPlanner) integration boundary for the gtfs-planner application. It is responsible for:

- **Building OTP-ready GTFS zip artifacts** from the application's Ecto-backed GTFS data — exporting Postgres rows into CSV files, packaging them into deterministic `.zip` archives, and caching the result in the `otp_gtfs_artifacts` database table and on local disk.
- **Building OTP graph objects** — staging the GTFS zip + OSM `.pbf` file in a workspace directory, invoking the OTP JAR's `--build --save` command to produce a `Graph.obj`, and caching the graph with a JSON manifest keyed on content hashes.
- **Materializing station-scoped GTFS feeds** — slicing a full GTFS zip down to the rows transitively reachable from a given `station_stop_id`, performing referential integrity checks, and producing a `station_gtfs.zip` artifact.
- **Running OTP runtime sessions** — starting an OTP server as an OS process, polling its GraphQL endpoint until ready, executing a caller-supplied callback within the session, and stopping the server (including forced SIGKILL on timeout).
- **Validating pathways** — executing GraphQL walk-plan queries against a running OTP server to score walkability test cases (traversable?, duration, distance, wheelchair accessibility).
- **Checking prerequisites** — verifying Java version ≥21, OTP JAR presence, OSM `.pbf` presence, OTP directory writability, and heap size sanity before graph builds.

The context is organized into four sub-contexts with clear layering: `gtfs_artifact/` (Phase 1: GTFS zip materialization), `graph_cache/` (Phase 2: graph build), `runtime/` (Phase 3: server lifecycle), and `station_materializer/` (station-scoped feed slicing). Two top-level modules (`pathways_validity.ex`, `prerequisites.ex`) provide cross-cutting checks.

---

## 2. Architecture  

### 2.1 Module Tree  

```
GtfsPlanner.Otp                          (otp.ex)
├── Prerequisites                        (prerequisites.ex)
├── PathwaysValidity                     (pathways_validity.ex)
├── StationMaterializer                  (station_materializer.ex)
│   ├── StationClosure                   (station_materializer/station_closure.ex)
│   └── GtfsZipReader                    (station_materializer/gtfs_zip_reader.ex)
├── Gtfs Artifact Sub-context           (gtfs_artifact/)
│   ├── Artifact (Ecto schema)          (gtfs_artifact/artifact.ex)
│   ├── ArtifactPath                    (gtfs_artifact/artifact_path.ex)
│   ├── Hasher                          (gtfs_artifact/hasher.ex)
│   ├── Lifecycle                       (gtfs_artifact/lifecycle.ex)
│   ├── Manifest                        (gtfs_artifact/manifest.ex)
│   ├── Materializer                    (gtfs_artifact/materializer.ex)
│   ├── Packager                        (gtfs_artifact/packager.ex)
│   └── Preflight                       (gtfs_artifact/preflight.ex)
├── Graph Cache Sub-context            (graph_cache/)
│   ├── GraphBuilder                    (graph_cache/graph_builder.ex)
│   ├── GraphCommandRunner (behaviour)  (graph_cache/graph_command_runner.ex)
│   ├── GraphLifecycle                  (graph_cache/graph_lifecycle.ex)
│   ├── GraphManifest                   (graph_cache/graph_manifest.ex)
│   ├── GraphMaterializer               (graph_cache/graph_materializer.ex)
│   ├── GraphPath                       (graph_cache/graph_path.ex)
│   ├── GraphPreflight                  (graph_cache/graph_preflight.ex)
│   ├── OsmPath                         (graph_cache/osm_path.ex)
│   └── SystemGraphCommandRunner        (graph_cache/system_graph_command_runner.ex)
└── Runtime Sub-context                (runtime/)
    ├── CommandRunner (behaviour)        (runtime/command_runner.ex)
    ├── Readiness                        (runtime/readiness.ex)
    ├── Runtime                          (runtime/runtime.ex)
    ├── Server                           (runtime/server.ex)
    ├── Session                          (runtime/session.ex)
    └── SystemCommandRunner              (runtime/system_command_runner.ex)
```

### 2.2 Dependency Diagram  

```
┌──────────────────────────────────────────────────────────────┐
│ External callers (LiveViews, controllers, CLI)               │
└──────────┬───────────────────────────┬───────────────────────┘
           │                           │
     ┌─────▼─────────┐         ┌──────▼──────────────┐
     │  Prerequisites │         │  PathwaysValidity   │
     │  (one-shot)    │         │  (needs Session)    │
     └────────────────┘         └──────┬──────────────┘
                                       │
┌──────────────────────────────────────▼───────────────────────┐
│  GtfsPlanner.Otp.Runtime (orchestrator)                      │
│  ┌─────────────┐  ┌─────────────┐  ┌───────────────────┐    │
│  │ Materializer │  │ GraphMater- │  │ Server / Readiness│    │
│  │ (Phase 1)    │→ │ ializer     │→ │ / SystemCmdRunner │    │
│  │              │  │ (Phase 2)   │  │                   │    │
│  └──────┬───────┘  └─────┬───────┘  └───────────────────┘    │
│         │                │                                   │
└─────────┼────────────────┼───────────────────────────────────┘
          │                │
    ┌─────▼──────┐  ┌──────▼──────────┐
    │ Preflight  │  │ GraphPreflight  │
    │ Manifest   │  │ GraphBuilder    │
    │ Packager   │  │ GraphManifest   │
    │ Hasher     │  │ GraphPath       │
    │ Artifact   │  │ OsmPath         │
    │ Lifecycle  │  │ GraphLifecycle  │
    └────────────┘  └─────────────────┘

┌──────────────────────────────────────────────────────────────┐
│  StationMaterializer                                         │
│  ┌──────────────────┐  ┌──────────────────────┐              │
│  │ StationClosure   │  │ GtfsZipReader        │              │
│  │ (pure logic)     │  │ (zip I/O)            │              │
│  └──────────────────┘  └──────────────────────┘              │
│  Delegates to Materializer for source zip                    │
└──────────────────────────────────────────────────────────────┘
```

### 2.3 Phase Pipeline  

The `Runtime.prepare_runtime/3` orchestrates a sequential two-phase pipeline:

1. **Phase 1 — GTFS Zip Materialization** (`Materializer.get_or_build_gtfs_zip/3`):
   - Check DB cache (`otp_gtfs_artifacts` record + disk file match)
   - If `force_rebuild?` or cache miss: run preflight checks (DB referential integrity + pathways preflight), export Ecto-backed GTFS data to CSV files in a staging directory, package into a deterministic `.zip`, persist artifact record, return zip path + metadata
   
2. **Phase 2 — Graph Materialization** (`GraphMaterializer.get_or_build_graph/3`):
   - Resolve GTFS input SHA256 from the zip produced in Phase 1
   - Derive a scope key from `runtime_scope` + `gtfs_input_sha256`
   - Check disk cache: look for `Graph.obj` + `manifest.json` at scoped path, validate manifest against current input hashes
   - If cache miss: run GraphPreflight, stage GTFS zip + OSM `.pbf` into workspace, invoke OTP JAR `--build --save`, persist manifest, return `Graph.obj` path

The `Runtime.run_with_otp/4` then adds Phase 3:

3. **Phase 3 — Runtime Session**:
   - Acquire a global distributed lock (`:global.set_lock`) per organization
   - Start OTP JAR as an OS `Port` process (`Server.start/2` → `SystemCommandRunner.start/3`)
   - Poll GraphQL endpoint until ready (`Readiness.wait_until_ready/2`, default 30s timeout, 250ms interval)
   - Execute user callback (`fn Session.t() -> ...`)
   - Stop server (SIGTERM with timeout → SIGKILL fallback)
   - Release lock

---

## 3. Boundary & Dependencies  

### 3.1 Inbound Dependencies (who depends on this context)  

| Caller                                   | Functions used                                     |
|------------------------------------------|----------------------------------------------------|
| `GtfsPlannerWeb` LiveViews               | `Runtime.run_with_otp/4`, `PathwaysValidity.run_in_session/4`, `Prerequisites.check/1` |
| `GtfsPlanner.Validations`                | `PathwaysValidity.run_in_session/4`                |
| Test suites                              | All public functions (injectable via `opts` fns)   |

### 3.2 Outbound Dependencies (what this context depends on)  

| Module                        | Purpose                                              |
|-------------------------------|------------------------------------------------------|
| `GtfsPlanner.Repo`            | DB queries for artifact records, preflight checks    |
| `GtfsPlanner.Gtfs.Export`     | Exports GTFS data from DB to CSV files               |
| `GtfsPlanner.Gtfs.Export.FileSpec` | Defines which tables to export                  |
| `GtfsPlanner.Validations.PathwaysPreflight` | Fetch/write pathway preflight check        |
| `GtfsPlanner.Gtfs` (context)  | `list_stops/2`, `list_station_scope_stop_ids/3`      |
| `GtfsPlanner.Organizations.Organization` | Schema association                            |
| `GtfsPlanner.Versions.GtfsVersion` | Schema association                               |
| `Req`                          | HTTP client for GraphQL queries (Readiness, Pathways)|
| `Jason`                       | JSON encoding/decoding for manifests                 |
| `:zip` (Erlang)               | Zip creation (`:zip.create`)                         |
| `:crypto` (Erlang)            | SHA256 hashing                                       |
| `:global` (Erlang)            | Distributed lock for runtime sessions                |
| `Port` (Erlang)               | OS process management for OTP JAR                    |
| Application config            | 13 OTP-specific config keys (see §5)                 |

### 3.3 Database Artifact  

**Table:** `otp_gtfs_artifacts`  

| Column          | Type    | Notes                                     |
|-----------------|---------|-------------------------------------------|
| `id`            | UUID PK | Autogenerated                              |
| `organization_id` | UUID FK | → `organizations`, cascade delete          |
| `gtfs_version_id` | UUID FK | → `gtfs_versions`, cascade delete         |
| `zip_path`      | string  | Absolute path to the GTFS zip on disk      |
| `content_hash`  | string  | SHA256 of staged file contents            |
| `file_size_bytes` | integer| Size of the zip archive                   |
| `manifest_json` | jsonb   | `{"files": ["agency.txt", ...]}`           |
| `inserted_at`   | utc_usec|                                            |
| `updated_at`    | utc_usec|                                            |

**Unique constraint:** `(organization_id, gtfs_version_id)`  

---

## 4. Detailed Module Behavior  

### 4.1 GTFS Artifact Materialization (`GtfsPlanner.Otp.Materializer`)  

**Entry point:** `get_or_build_gtfs_zip(org_id, version_id, opts)`  

**Cache check** (`cache_hit/2`):
1. Look up `otp_gtfs_artifacts` record by `(organization_id, gtfs_version_id)`
2. Verify `artifact.zip_path == expected_zip_path` (ArtifactPath-predicted)
3. Verify the zip file exists on disk and is a regular file
4. Verify the file's current `stat.size == artifact.file_size_bytes`

**Build pipeline** (on miss or force rebuild):
1. Run `Preflight.run/2`:
   - Check required-file presence in DB (agency, stops, routes, trips, stop_times, pathways — at least one of calendar/calendar_dates)
   - Check referential integrity: stop_times→trips, stop_times→stops, trips→routes, pathways→stops (from/to)
2. If preflight returns errors in `:strict` mode → abort; in `:lenient` mode → continue with warnings
3. Run `PathwaysPreflight.run/3` — external validity check on pathways data
4. Export GTFS data via `Gtfs.Export.export_specs_to_directory/5` to a unique staging subdirectory
5. Package via `Packager.package_staging_dir/2`: list `*.txt` files, sort by basename, create deterministic zip
6. Hash via `Hasher.sha256_for_filenames/2`: hash each filename + `\0` + file content + `\0` in order
7. Upsert artifact record via `Otp.upsert_artifact/1` (upsert on conflict)
8. Clean up staging directory

**Status callbacks:** Emits `%{phase: :cache_check | :preflight | :exporting | :packaging | :persisting | :done | :failed}`  

### 4.2 Graph Building (`GtfsPlanner.Otp.GraphMaterializer`)  

**Entry point:** `get_or_build_graph(org_id, version_id, opts)`  

**Cache identity:** Derived from `(organization_id, gtfs_version_id, gtfs_input_sha256, scope_key)` where:
- `gtfs_input_sha256` = SHA256 of the GTFS zip file used as input
- `scope_key` = `%{runtime_scope: normalized_scope, gtfs_input_sha256: sha256_segment}`

**Cache hit validation** (`cache_hit/1`):
1. `Graph.obj` exists and is a regular file at scoped path
2. `manifest.json` exists, is valid JSON, has `schema_version == 1`
3. `manifest.gtfs_content_hash == artifact.content_hash` (matches DB record)
4. `manifest.gtfs_input_sha256 == expected_gtfs_input_sha256` (zip file SHA256)
5. `manifest.osm_fingerprint == file_sha256(current_osm_path)` (OSM hasn't changed)
6. `manifest.otp_jar_sha256 == configured_otp_jar_sha256` (JAR hasn't changed, if configured)

**Build pipeline** (on miss or force rebuild):
1. Run `GraphPreflight.run/3`:
   - Java binary exists and is an absolute path
   - OTP JAR exists, is absolute, ends with `.jar`, is readable
   - OSM `.pbf` resolves and is readable
   - GTFS zip artifact exists and is readable
   - Workspace directory is creatable/writable
2. **Stage inputs** (`stage_inputs/4`):
   - Create `data_dir` (scoped by org/version/runtime_scope/gtfs_input_sha256)
   - Copy GTFS zip to `data_dir/gtfs.zip`
   - Copy OSM `.pbf` to `data_dir/<osm_basename>`
3. **Build** via `GraphBuilder.build/2`:
   - Command: `java -Xmx<heap> -jar <otp_jar> --build --save <data_dir>`
   - Runner: `SystemGraphCommandRunner.run/3` (wraps `System.cmd/3` with `Task.async/1` + timeout at 600s)
   - Verifies exit status 0 and `Graph.obj` exists
   - Persists build output to `build.log`
4. **Persist manifest** (`persist_manifest/4`):
   - Write `manifest.json` containing: `schema_version`, `gtfs_content_hash`, `gtfs_input_sha256`, `osm_fingerprint`, `otp_jar_sha256`, build metadata (`command`, `args`, `graph_path`, `build_log_path`), timestamps

### 4.3 Station Materialization (`GtfsPlanner.Otp.StationMaterializer`)  

**Entry point:** `get_or_build_gtfs_zip(org_id, version_id, station_stop_id, opts)`  

**Pipeline:**
1. Requires `station_stop_id` in opts — returns error if missing
2. Delegates to `Materializer.get_or_build_gtfs_zip/3` to get/cache the full source zip (forces `:lenient` preflight mode)
3. Skips source-level pathways preflight entirely
4. Reads source zip via `GtfsZipReader.read_tables/1` (custom CSV parser)
5. Validates station: must exist in `stops.txt` with `location_type == 1`
6. Derives transitive closure via `StationClosure.derive_kept_stop_ids/2`: station + direct children + boarding areas whose parent is a kept platform
7. **Cascading filter pipeline** (16 files): For each GTFS file, filters rows to only those reachable from kept stop IDs:
   - `stops.txt` → kept stop IDs → collects `kept_level_ids`, `kept_zone_ids`
   - `levels.txt` → filtered by `kept_level_ids`
   - `pathways.txt` → filtered by `kept_stop_ids` (both `from_stop_id` and `to_stop_id`)
   - `transfers.txt` → filtered by `kept_stop_ids`
   - `stop_times.txt` → filtered by `kept_stop_ids` → collects `kept_trip_ids`
   - `trips.txt` → filtered by `kept_trip_ids` → collects `kept_route_ids`, `kept_service_ids`, `kept_shape_ids`
   - `attributions.txt` → filtered by `kept_route_ids` or `kept_trip_ids`
   - `routes.txt` → filtered by `kept_route_ids` → collects `kept_agency_ids`
   - `agency.txt` → filtered by `kept_agency_ids` (if `agency_id` in header)
   - `calendar.txt` → filtered by `kept_service_ids`
   - `calendar_dates.txt` → filtered by `kept_service_ids`
   - `frequencies.txt` → filtered by `kept_trip_ids`
   - `shapes.txt` → filtered by `kept_shape_ids`
   - `fare_rules.txt` → filtered by `kept_route_ids` or `kept_zone_ids` → collects `kept_fare_ids`
   - `fare_attributes.txt` → filtered by `kept_fare_ids`
8. Extension files (areas, booking_rules, fare_leg_rules, etc.) → passed through without filtering, with warnings for unknown extension files
9. **Referential integrity** re-checked on filtered rows (stop_times→trips, stop_times→stops, trips→routes, trips→service, pathways, transfers, fare_rules)
10. **Station preflight**: station coordinate sanity (lat [-90,90], lon [-180,180]), boarding area parent integrity
11. Renders filtered tables to CSV (preserving original header order, stable sort per file)
12. Replaces entries in the source zip with rendered CSV content
13. Writes `station_gtfs.zip` to `artifact_dir/station/<sha256(station_stop_id)>/`

### 4.4 Runtime Session Management  

**Session start** (`Server.start/2`):
- Reads Java path, JAR path, host, port, heap from config (env-overridable)
- Computes `data_dir` as `Path.dirname(graph_path)`, `graph_workspace_dir` as parent of `data_dir`
- Runs: `java -Xmx<heap> -jar <otp_jar> --load <data_dir> --serve --port <port>`
- Opens as an Erlang `Port` process via `SystemCommandRunner.start/3`
- Waits 100ms grace period — if the process exits during this window, returns `{:error, start_failed}`
- Returns a `%Session{}` struct with command metadata, URLs, process handle, log path

**Readiness polling** (`Readiness.wait_until_ready/2`):
- Sends `POST {graphql_url}` with body `{"query": "{__typename}"}` using `Req`
- Polls every `poll_interval_ms` (default 250ms) until 2xx response or `timeout_ms` (default 30s)
- Returns `:ok` on first 2xx, or `{:error, ready_timeout}` with `last_error`
- All timeouts, intervals, and request functions are injectable via opts

**Session stop** (`Server.stop/2`, `SystemCommandRunner.stop/2`):
- Monitors the Port process
- Sends SIGTERM via `kill -TERM <os_pid>`
- Waits up to `shutdown_timeout_ms` (default 5s) for DOWN message
- On timeout: sends SIGKILL via `kill -KILL <os_pid>`, waits `force_kill_wait_ms` (default 1s)
- Returns `:ok` on clean shutdown, `{:error, %{reason: :stop_timeout}}` on failure

**Distributed locking** (`Runtime.acquire_org_lock/1`):
- Uses `:global.set_lock({:gtfs_planner_otp_runtime_lock, org_id}, [node()], 0)`
- Non-blocking (0 retries) — returns `:ok` or error immediately
- Ensures only one OTP runtime per organization at a time

### 4.5 Pathways Validity (`GtfsPlanner.Otp.PathwaysValidity`)  

**Entry point:** `run_in_session(session, org_id, version_id, opts)`  

**Pipeline:**
1. Selects walkability test cases via `WalkabilitySuite.select_suite/3`
2. Optionally filters to a specific station's stop scope via `Gtfs.list_station_scope_stop_ids/3`
3. Builds destination stop lookup map from `Gtfs.list_stops/2`
4. For each test case (sequentially, with progress callbacks):
   - Resolves destination coordinates from the destination stop
   - Executes a walk-only GraphQL plan query (from address lat/lon to destination stop lat/lon)
   - Conditionally executes a wheelchair plan query if `expected_wheelchair_accessible` is set
   - Scores the route output against expected values: `expected_traversable`, `expected_min/max_duration_seconds`, `expected_min/max_distance_meters`, `expected_wheelchair_accessible`
   - Classifies outcome as `:passed`, `:query_failure`, or `:scoring_failure`
5. Summarizes results: total, passed, failed, query_failure, scoring_failure counts

**GraphQL query**: Uses a `plan` query with `transportModes: [{mode: WALK}]`, `numItineraries: 1`, optional `wheelchair: true`. Extracts itinerary duration, walkDistance, startTime, endTime, legs with steps (streetName, distance, absoluteDirection, relativeDirection).

### 4.6 Prerequisites (`GtfsPlanner.Otp.Prerequisites`)  

**Entry point:** `check(opts)` — returns `%{checks: [...], errors: non_neg_integer()}`  

**Checks performed (always all 5):**
1. **Java**: `java_path` config is set, binary exists, `java -version` succeeds, parsed major version ≥ 21 (handles both legacy `1.8.x` and modern `21.x.y` formats)
2. **OTP directory**: `Path.dirname(otp_jar_path)` exists (or `priv/otp` fallback). Optionally creates directory if `create_dir: true`
3. **OTP JAR**: `otp_jar_path` config is set, absolute path, ends with `.jar`, file exists, is regular file, is readable
4. **OSM**: `otp_osm_path` config is set, absolute path, ends with `.pbf`, file exists, is regular file, is readable
5. **Heap**: `otp_graph_build_heap` config parses to ≥4GB (supports `k/m/g/K/M/G` units), verifies heap ≤ detected system RAM (Darwin: `sysctl hw.memsize`, Linux: `/proc/meminfo`)

---

## 5. Configuration  

### 5.1 Application Config Keys  

All keys are read at call time (not cached at startup), and most support environment variable overrides in `runtime.exs`:

| Config Key                              | Type    | Default (dev)                           | Default (prod)               | Env Var                        |
|-----------------------------------------|---------|-----------------------------------------|------------------------------|--------------------------------|
| `:java_path`                            | string  | `/opt/homebrew/opt/openjdk@21/bin/java` | `"java"`                     | `JAVA_PATH`                    |
| `:otp_jar_path`                         | string  | `priv/otp/opentripplanner.jar`          | `/opt/otp/otp.jar`           | `OTP_JAR_PATH`                 |
| `:otp_osm_path`                         | string  | `priv/otp/region.osm.pbf`              | `/opt/otp/data/philadelphia.osm.pbf` | `OTP_OSM_PATH`          |
| `:otp_runtime_path`                     | string  | `$TMPDIR/gtfs_planner/otp_runtime`     | same                         | `OTP_RUNTIME_PATH`             |
| `:otp_artifacts_path`                   | string  | `$TMPDIR/gtfs_planner_otp_artifacts`   | same                         | `OTP_ARTIFACTS_PATH`           |
| `:otp_graph_build_heap`                 | string  | `"4G"`                                  | `"4G"`                       | `OTP_GRAPH_BUILD_HEAP`         |
| `:otp_graph_build_timeout_ms`           | integer | `600_000` (10 min)                      | same                         | `OTP_GRAPH_BUILD_TIMEOUT_MS`   |
| `:otp_server_host`                      | string  | `"127.0.0.1"`                           | same                         | `OTP_SERVER_HOST`              |
| `:otp_server_port`                      | integer | `8080`                                  | same                         | `OTP_SERVER_PORT`              |
| `:otp_server_heap`                      | string  | `"4G"`                                  | same                         | `OTP_SERVER_HEAP`              |
| `:otp_server_ready_timeout_ms`          | integer | `30_000` (30s)                          | same                         | `OTP_SERVER_READY_TIMEOUT_MS`  |
| `:otp_server_ready_poll_interval_ms`    | integer | `250`                                   | same                         | `OTP_SERVER_READY_POLL_INTERVAL_MS` |
| `:otp_server_shutdown_timeout_ms`       | integer | `5_000` (5s)                            | same                         | `OTP_SERVER_SHUTDOWN_TIMEOUT_MS` |
| `:otp_graphql_path`                     | string  | `"/otp/routers/default/index/graphql"`  | same                         | `OTP_GRAPHQL_PATH`             |
| `:otp_jar_sha256`                       | string  | `nil`                                   | system env                   | `OTP_JAR_SHA256`               |

### 5.2 Cache Key Composition  

**GTFS Artifact cache key:** `(organization_id, gtfs_version_id)` → single artifact per scope  

**Graph cache key:**  
```
workspace_root_dir = <otp_runtime_path>/<org_id>/<version_id>/graph
workspace_dir      = <workspace_root_dir>/<runtime_scope>/<gtfs_input_sha256>
data_dir           = <workspace_dir>/data
graph.obj          = <data_dir>/Graph.obj
manifest.json      = <workspace_dir>/manifest.json
```

The graph cache is invalidated when any of these change:
- OTP JAR SHA256 (if configured via `OTP_JAR_SHA256`)
- OSM `.pbf` file fingerprint (full file SHA256)
- GTFS content hash (from `otp_gtfs_artifacts.content_hash`)
- GTFS input zip SHA256 (the concrete zip file used)
- `GraphManifest.schema_version` (currently hardcoded to `1` — no migration path for manifest format changes)

**Station zip cache path:**  
```
<otp_artifacts_path>/<org_id>/<version_id>/station/<sha256(station_stop_id)>/station_gtfs.zip
```

---

## 6. Caching Strategy  

### 6.1 GTFS Artifact Caching  

**Storage:** DB record (`otp_gtfs_artifacts`) + disk file at deterministic path  

**Validity check:**  
- DB record exists for the `(org_id, version_id)` pair  
- Disk file exists at the path recorded in the DB  
- File size on disk matches `artifact.file_size_bytes`  

**Force rebuild:** Set `force_rebuild: true` in opts — skips cache check entirely  

**Post-build cleanup:** `Lifecycle.purge_artifact_on_success/2` deletes both the DB record and the disk zip file (called by `Runtime.cleanup_on_success/2`)  

### 6.2 Graph Caching  

**Storage:** Disk only — `Graph.obj` + `manifest.json` at deterministic scoped path  

**Validity check:**  
- `Graph.obj` and `manifest.json` exist  
- `manifest.schema_version == 1`  
- `manifest.gtfs_content_hash == artifact.content_hash` (GTFS data hasn't changed)  
- `manifest.gtfs_input_sha256 == expected_gtfs_input_sha256` (zip file hasn't changed)  
- `manifest.osm_fingerprint == file_sha256(current_osm_path)` (OSM hasn't changed)  
- `manifest.otp_jar_sha256 == configured_otp_jar_sha256` (JAR hasn't changed, if configured)  

**Force rebuild:** Set `force_rebuild: true` in opts  

**Post-build cleanup:** `GraphLifecycle.purge_graph_on_success/2` deletes entire workspace root directory (`File.rm_rf/1`)  

### 6.3 Station Zip Caching  

Station zips are **not separately cached** — they are always rebuilt from the source zip on each call to `StationMaterializer.get_or_build_gtfs_zip/4`. The source zip (from `Materializer`) *is* cached, so the DB+disk export is reused, but the station slicing is performed each time. The resulting station zip is written to disk but not tracked in any DB table.

---

## 7. Error Handling  

### 7.1 Issue Structure  

All error returns use a consistent list-of-maps pattern:  

```elixir
{:error, [%{code: atom(), severity: :blocking | :error | :warning, message: String.t(), details/context: map()}]}
```

- **`:blocking`** — prevents the operation entirely (e.g., missing required file, referential integrity violation in strict mode)
- **`:error`** — runtime operation failure (e.g., build command failed, readiness timeout)
- **`:warning`** — non-blocking issue, operation continues (e.g., duplicate calendar records, unknown extension files)

### 7.2 Environment Error Codes  

| Code category                     | Example codes                                                      |
|-----------------------------------|--------------------------------------------------------------------|
| Preflight checks                  | `missing_required_file_data`, `stop_times_trip_id_missing_trip`, `pathways_from_stop_id_missing_stop` |
| Graph preflight                   | `missing_java_path`, `java_not_found`, `invalid_otp_jar_path`, `otp_jar_not_found`, `invalid_otp_osm_path`, `missing_gtfs_artifact` |
| Graph build                       | `build_command_failed`, `graph_obj_missing` |
| Runtime                           | `otp_start_failed`, `otp_ready_timeout`, `otp_readiness_probe_failed`, `otp_process_crashed`, `otp_stop_failed`, `otp_runtime_already_running` |
| Station materialization           | `invalid_station_stop_id`, `station_stop_not_found`, `station_stop_invalid_type`, `station_stop_duplicated`, `station_zip_copy_failed`, `station_stop_lat_missing`, `boarding_area_parent_station_missing` |
| Station runtime boundary          | `station_runtime_input_missing_station_zip_path`, `station_runtime_input_missing_station_stop_id`, `station_runtime_precheck_stop_times_stop_id_missing_stop` |
| Zip reader                        | `gtfs_zip_not_found`, `gtfs_zip_unzip_failed`, `gtfs_duplicate_headers`, `gtfs_malformed_row` |
| Pathways validity scoring         | `query_failure`, `scoring_failure` (with sub-details: `:invalid_graphql_payload`, `:non_2xx_response`, `:transport_error`) |

### 7.3 Resilience Patterns  

- **Process crash handling**: `Runtime.run_with_otp/4` wraps the callback in try/after, ensuring `Server.stop/2` is always called even if the callback raises. If stop itself fails, it throws to an outer catch.
- **Distributed locking**: Non-blocking — returns immediately if another session is active for the same org
- **Graceful shutdown**: SIGTERM → timeout → SIGKILL fallback
- **Build timeout**: `SystemGraphCommandRunner` wraps `System.cmd/3` in a `Task.async/1` with a configurable timeout (default 600s)

---

## 8. Key Design Decisions & Conventions  

### 8.1 Deterministic Artifact Paths  

All file paths are derived from `(organization_id, gtfs_version_id, scope_key)` rather than using random filenames. This ensures:
- No stale artifacts accumulate from differently-keyed builds
- Cache invalidation is implicit: if the inputs change (SHA256 changes), the path changes, and the old workspace is effectively orphaned
- Post-success cleanup (`File.rm_rf`) removes the entire workspace, including orphaned scopes

### 8.2 Dependency Injection via Opts  

Virtually every function accepts `opts` keyword lists with injectable functions for:
- `:runner` / `:request_fun` / `:sleep_fun` / `:monotonic_time_fun` — for testing
- `:status_callback` — for progress reporting (allows LiveView pubsub integration)
- `:preflight_mode` — `:strict` (abort on issues) vs `:lenient` (continue with warnings)
- `:force_rebuild` — bypass cache
- `:gtfs_materializer_fun`, `:graph_materializer_fun`, `:acquire_lock_fun`, `:release_lock_fun`, etc. — full pipeline injection

This pattern allows every stage of the pipeline to be tested in isolation.

### 8.3 Runtime Scopes  

The graph materializer supports scoped workspaces via the `:runtime_scope` option (atom or string, normalized to lowercase slug). The default scope is `"default"`. The `:station_reachability` scope triggers special station-scoped prechecks that validate:
- `station_stop_id` is present in metadata
- `station_zip_path` is readable
- The runtime input GTFS zip matches `station_zip_path`
- A referential precheck is run on the station zip's `stop_times.txt → stops.txt`

### 8.4 Stable Output Ordering  

- `Packager.package_staging_dir/2` sorts `*.txt` basenames alphabetically for deterministic zip ordering
- `StationMaterializer` includes stable sort logic for each GTFS file type (e.g., `stop_times.txt` sorted by `(trip_id, stop_sequence, arrival_time, departure_time, stop_id)`)
- `Hasher.sha256_for_filenames/2` processes files in manifest order for deterministic content hashes

---

## 9. Assumptions  

1. **Single OSM file:** The system assumes exactly one `.osm.pbf` file path (`:otp_osm_path`) is used for all graph builds across all organizations/versions. There is no mechanism for per-organization or per-region OSM files.
2. **Java 21+:** The prerequisites module enforces Java ≥21. The OTP JAR is assumed to be compatible with Java 21+.
3. **Single node execution:** The `:global` distributed lock assumes all OTP runtime sessions run on the same Erlang node or a connected cluster. The `SystemCommandRunner` spawns local OS processes only.
4. **Port availability:** The server port (default 8080) is assumed available. No port conflict detection or dynamic port assignment exists.
5. **Disk space:** Graph builds can produce large `Graph.obj` files. No disk space checks are performed before building.
6. **Station zip not cached in DB:** Station-scoped zips exist only on disk. There's no DB record tracking them, so cleanup must be manual or file-system-level.
7. **Manifest schema version:** Hardcoded to `1` in `GraphManifest`. There's no migration path for manifest format changes — changing `schema_version` in the code would invalidate all existing caches.
8. **CSV encoding:** The `GtfsZipReader` and `StationMaterializer` CSV rendering assume UTF-8 content and do not handle BOM or other encodings.
9. **GTFS data must already be imported:** The pipeline assumes GTFS data is already in the Ecto-backed DB. It does not handle direct file-to-zip packaging.
10. **JAR SHA256 optional:** `otp_jar_sha256` config is optional (`nil` by default). When nil, the JAR fingerprint check is skipped during graph cache validation.

---

## 10. Risks & Ambiguities  

### 10.1 High Risk  

- **R-1: No station zip caching.** Station zips are rebuilt on every call. For a large feed, parsing the full source zip and performing the cascading filter on every station materialization could be expensive. No DB caching or manifest tracking exists for station zips.
- **R-2: Single OSM file per deployment.** All organizations and GTFS versions share the same OSM file. If different regions or OSM updates are needed, the entire deployment shares one state. The OSM fingerprint is embedded in graph manifests, so an OSM update invalidates all cached graphs globally.
- **R-3: No partial cache eviction.** Graph workspaces are only cleaned up on a successful OTP session via `GraphLifecycle.purge_graph_on_success/2`. If builds fail or sessions are never run, graph artifacts accumulate indefinitely on disk.
- **R-4: SIGKILL fallback on stop.** The `SystemCommandRunner.stop/2` sends SIGTERM with timeout → SIGKILL. If the OTP process takes longer than the shutdown timeout to flush data, data could be lost or corrupted. Additionally, `kill -KILL` is platform-specific and may fail silently on some systems.

### 10.2 Medium Risk  

- **R-5: No concurrent build gating.** The distributed lock only gates runtime sessions, not graph builds. Multiple concurrent builds for the same scope could race, with one overwriting the other's workspace.
- **R-6: Schema version handcuff.** `GraphManifest.schema_version` is hardcoded to `1`. If the manifest format needs to change, there's no migration or version negotiation — all existing graph caches would be silently invalid (manifest validation would fail on `schema_version` mismatch).
- **R-7: GraphQL endpoint polling sensitivity.** Readiness polling uses a simple `POST {__typename}` query. If OTP returns a 2xx but the GraphQL endpoint is not yet fully initialized, subsequent queries could fail. The current approach assumes any 2xx means "ready."
- **R-8: CSV field-level parsing in zip reader.** `GtfsZipReader` implements its own CSV parser in pure Elixir with manual character-level parsing. While rigorous about quote handling, it may differ from how OTP or other tools parse the same data.
- **R-9: Heap config parsing.** The `Prerequisites.parse_heap_bytes/1` regex requires exactly `\d+[unit]` with optional whitespace (e.g., `4G`). Values like `4096M` or `4g` work, but `4GB` or `4096` would fail.

### 10.3 Ambiguities  

- **A-1:** Station zip paths use `:sha256 |> :crypto.hash(station_stop_id)` as the directory name. This is not the same as `Base.encode16(:crypto.hash(:sha256, station_stop_id))` — the module atom `:sha256` is being hashed, not the SHA256 algorithm being applied to the stop_id. This appears to be a bug: `:crypto.hash(:sha256, station_stop_id)` would produce the intended result, but `:crypto.hash(Module, data)` where `Module` is `:sha256` (an atom) is being called as `:crypto.hash(:sha256, data)`. The Erlang `:crypto.hash/2` function expects the first argument to be an algorithm atom — since `:sha256` is the correct Erlang atom for SHA256, this actually works correctly. (The atom `:sha256` happens to be the correct algorithm specifier.)
- **A-2:** The pathways validity module calls `Req.post/1` as the default request function but also includes a `:retry` option in the `Readiness` default request (`retry: false`) while the pathways module's default does not. This inconsistency means pathways GraphQL calls use Req's default retry behavior while readiness probes do not.
- **A-3:** `StationClosure.derive_kept_stop_ids/2` includes boarding areas (`location_type == 4`) whose `parent_station` references a kept platform (`location_type == 0` direct child). It does not include entrance/exits (`location_type == 2`) or generic nodes (`location_type == 3`).
- **A-4:** The `StationMaterializer` cascading filter for `fare_rules.txt` passes a row if ANY of route_id, origin_id, destination_id, or contains_id matches — treating empty values as "matches everything." There's no validation that the original GTFS spec allows fare_rules to have empty route_id/zone_id fields.
- **A-5:** The `Materializer.build_specs/0` combines required + calendar alternatives + optional specs. There's no deduplication — if both `calendar.txt` and `calendar_dates.txt` are declared as alternatives, they are both explicitly included in the spec list. The `Export.export_specs_to_directory/5` handles which ones actually export based on data presence.

---

## 11. Evidence  

### 11.1 Source Files  

| File | Lines | Purpose |
|------|-------|---------|
| `lib/gtfs_planner/otp/otp.ex` | 67 | Public context boundary, artifact CRUD |
| `lib/gtfs_planner/otp/prerequisites.ex` | 274 | Local OTP environment checks (Java, JAR, OSM, heap) |
| `lib/gtfs_planner/otp/pathways_validity.ex` | 848 | Walkability test execution via OTP GraphQL |
| `lib/gtfs_planner/otp/station_materializer.ex` | 1507 | Station-scoped GTFS zip slicing pipeline |
| `lib/gtfs_planner/otp/station_materializer/station_closure.ex` | 141 | Derives transitive stop closure for a station |
| `lib/gtfs_planner/otp/station_materializer/gtfs_zip_reader.ex` | 243 | Custom CSV parser for GTFS zip files |
| `lib/gtfs_planner/otp/gtfs_artifact/artifact.ex` | 58 | Ecto schema for `otp_gtfs_artifacts` table |
| `lib/gtfs_planner/otp/gtfs_artifact/artifact_path.ex` | 30 | Deterministic path policy for GTFS artifacts |
| `lib/gtfs_planner/otp/gtfs_artifact/hasher.ex` | 51 | SHA256 hashing of staged GTFS files |
| `lib/gtfs_planner/otp/gtfs_artifact/lifecycle.ex` | 32 | Post-success artifact cleanup |
| `lib/gtfs_planner/otp/gtfs_artifact/manifest.ex` | 58 | Required/optional GTFS file policy |
| `lib/gtfs_planner/otp/gtfs_artifact/materializer.ex` | 413 | GTFS zip build-or-reuse orchestrator |
| `lib/gtfs_planner/otp/gtfs_artifact/packager.ex` | 46 | Deterministic zip packaging from staging dir |
| `lib/gtfs_planner/otp/gtfs_artifact/preflight.ex` | 224 | DB-level preflight checks (file presence, referential integrity) |
| `lib/gtfs_planner/otp/graph_cache/graph_builder.ex` | 103 | OTP JAR `--build --save` command execution |
| `lib/gtfs_planner/otp/graph_cache/graph_command_runner.ex` | 20 | Behaviour for graph build command execution |
| `lib/gtfs_planner/otp/graph_cache/graph_lifecycle.ex` | 27 | Post-success graph workspace cleanup |
| `lib/gtfs_planner/otp/graph_cache/graph_manifest.ex` | 68 | Graph cache manifest schema v1 |
| `lib/gtfs_planner/otp/graph_cache/graph_materializer.ex` | 505 | Graph build-or-reuse orchestrator |
| `lib/gtfs_planner/otp/graph_cache/graph_path.ex` | 104 | Deterministic path policy for graph workspaces |
| `lib/gtfs_planner/otp/graph_cache/graph_preflight.ex` | 220 | Pre-build dependency validation |
| `lib/gtfs_planner/otp/graph_cache/osm_path.ex` | 62 | OSM `.pbf` path resolution and validation |
| `lib/gtfs_planner/otp/graph_cache/system_graph_command_runner.ex` | 29 | System.cmd-based graph build runner |
| `lib/gtfs_planner/otp/runtime/runtime.ex` | 512 | Full lifecycle orchestrator (prepare + session) |
| `lib/gtfs_planner/otp/runtime/server.ex` | 170 | OTP server process start/stop |
| `lib/gtfs_planner/otp/runtime/session.ex` | 42 | Session metadata struct |
| `lib/gtfs_planner/otp/runtime/command_runner.ex` | 15 | Behaviour for runtime command execution |
| `lib/gtfs_planner/otp/runtime/system_command_runner.ex` | 133 | Port-based OS process lifecycle manager |
| `lib/gtfs_planner/otp/runtime/readiness.ex` | 124 | GraphQL readiness polling |

**Total:** 29 files, ~5,600 lines of Elixir code  

### 11.2 Database Migrations  

| Migration | Content |
|-----------|---------|
| `20260217001944_create_otp_gtfs_artifacts.exs` | Creates `otp_gtfs_artifacts` table with unique index on `(organization_id, gtfs_version_id)` |

### 11.3 Configuration Evidence  

| File | Lines | Content |
|------|-------|---------|
| `config/runtime.exs` | 40–110 | All 15 OTP config keys with env var overrides |
| `config/config.exs` | 59–76 | Logger metadata including OTP-specific fields |

### 11.4 External Dependencies (not in this directory)  

| Module | File | Purpose |
|--------|------|---------|
| `GtfsPlanner.Gtfs.Export` | `lib/gtfs_planner/gtfs/export.ex` | DB-to-file GTFS export |
| `GtfsPlanner.Gtfs.Export.FileSpec` | `lib/gtfs_planner/gtfs/export/file_spec.ex` | Per-file export specs |
| `GtfsPlanner.Validations.PathwaysPreflight` | `lib/gtfs_planner/validations/pathways_preflight.ex` | Pathways validity preflight |
| `GtfsPlanner.Validations.WalkabilitySuite` | `lib/gtfs_planner/validations/walkability_suite.ex` | Walkability test case selection |
| `GtfsPlanner.Gtfs.list_stops/2` | `lib/gtfs_planner/gtfs.ex` | Stop lookup |
| `GtfsPlanner.Gtfs.list_station_scope_stop_ids/3` | `lib/gtfs_planner/gtfs.ex` | Station scope derivation |
