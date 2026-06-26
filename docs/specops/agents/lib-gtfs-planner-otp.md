# OTP Integration Context Agent Doc

Source target: `lib-gtfs-planner-otp`
Scope: Builds and caches OTP-ready GTFS artifacts and graphs, checks local OTP prerequisites, runs OTP runtime sessions, and materializes station-scoped feeds.
Deep analysis: [`../analysis/lib-gtfs-planner-otp.md`](../analysis/lib-gtfs-planner-otp.md)
Freshness: `source_hash=sha256:20130303a556b16e3665498f69532fe7ade79befe21bdadb1a7f6fbdc112872c`, `last_synthesized=2026-06-26`

## Use When
- Modifying OTP pipeline orchestration (phases 1–3)
- Changing artifact/graph caching logic or paths
- Adding/removing OTP config keys
- Changing the runtime session lifecycle (start/ready/stop)
- Modifying station-scoped GTFS zip materialization
- Changing prerequisite checks (Java, JAR, OSM, heap)
- Adjusting pathways validity scoring

## Read First
- `lib/gtfs_planner/otp/runtime/runtime.ex` — top-level orchestrator; `run_with_otp/4` is the main external API
- `lib/gtfs_planner/otp/otp.ex` — public context boundary, artifact CRUD
- `lib/gtfs_planner/otp/runtime/server.ex` — OTP OS process lifecycle (start/stop)
- `lib/gtfs_planner/otp/gtfs_artifact/materializer.ex` — Phase 1: GTFS zip build-or-reuse
- `lib/gtfs_planner/otp/graph_cache/graph_materializer.ex` — Phase 2: graph build-or-reuse
- `config/runtime.exs` lines ~40–110 — all config keys with env var overrides

## Interfaces

**Inbound:** `GtfsPlannerWeb` LiveViews (Runtime, PathwaysValidity, Prerequisites), `GtfsPlanner.Validations` (PathwaysValidity), test suites

**Outbound:** `GtfsPlanner.Repo`, `GtfsPlanner.Gtfs.Export`/`.FileSpec`, `GtfsPlanner.Validations.PathwaysPreflight`/`.WalkabilitySuite`, `GtfsPlanner.Gtfs`, `Req` (HTTP), `Jason`, `:zip`, `:crypto`, `:global` (distributed lock per org)

### File Structure (29 files, ~5,600 lines)
```
lib/gtfs_planner/otp/
├── otp.ex                              # Public boundary, artifact CRUD
├── prerequisites.ex                    # Java/JAR/OSM/heap checks
├── pathways_validity.ex                # Walkability test execution via GraphQL
├── station_materializer.ex             # Station-scoped zip slicing
│   ├── station_closure.ex              # Transitive stop closure
│   └── gtfs_zip_reader.ex              # Custom CSV parser for zip files
├── gtfs_artifact/                      # Phase 1: GTFS zip materialization
│   ├── artifact.ex                     # Ecto schema for otp_gtfs_artifacts
│   ├── artifact_path.ex / lifecycle.ex # Path policy + post-success cleanup
│   ├── hasher.ex / packager.ex         # SHA256 hashing + deterministic zip packaging
│   ├── manifest.ex                     # Required/optional GTFS file policy
│   ├── materializer.ex                 # Build-or-reuse orchestrator
│   └── preflight.ex                    # DB referential integrity checks
├── graph_cache/                        # Phase 2: graph building
│   ├── graph_builder.ex                # OTP --build --save via System.cmd
│   ├── graph_command_runner.ex         # Behaviour (System runner: Task.async + 600s timeout)
│   ├── graph_lifecycle.ex / graph_path.ex  # Cleanup + deterministic workspace paths
│   ├── graph_manifest.ex               # Cache manifest schema v1
│   ├── graph_materializer.ex           # Build-or-reuse orchestrator
│   ├── graph_preflight.ex              # Pre-build dependency validation
│   └── osm_path.ex                     # OSM .pbf resolution
└── runtime/                            # Phase 3: server lifecycle
    ├── runtime.ex                      # Full lifecycle orchestrator (prepare + session)
    ├── server.ex / session.ex          # Port-based start/stop + metadata struct
    ├── readiness.ex                    # GraphQL polling (250ms/30s)
    └── command_runner.ex / system_command_runner.ex  # Behaviour + Port lifecycle (SIGTERM→SIGKILL)
```
DB migration: `priv/repo/migrations/20260217001944_create_otp_gtfs_artifacts.exs`

## Rules & Invariants

### Execution Phases (strict ordering)
1. **GTFS zip materialization:** DB export → CSV files → deterministic zip (preflight checks, content hashing, DB persist)
2. **Graph build:** resolve GTFS hash → stage zip + OSM .pbf → invoke OTP JAR `--build --save` → persist manifest
3. **Runtime session:** acquire lock → start OTP server as Port → poll GraphQL readiness → execute callback → stop server (SIGTERM→SIGKILL) → release lock

### Caching
- GTFS artifacts: DB (`otp_gtfs_artifacts`) + disk; cache key = `(org_id, version_id)`
- Graphs: disk only (`Graph.obj` + `manifest.json`); cache key = `(org_id, version_id, scope_key, gtfs_input_sha256)`
- Station zips: **not cached in DB**; rebuilt per call from source zip
- Graph cache invalidates on: GTFS content change, GTFS zip change, OSM change, OTP JAR change (if `otp_jar_sha256` configured), manifest schema version change
- All paths are deterministic (derived from IDs/hashes, never random)

### Other Invariants
- All errors: `{:error, [%{code: atom(), severity: :blocking | :error | :warning, message: String.t()}]}`
- Every function accepts `opts` with injectable fns for testing (`:runner`, `:request_fun`, `:sleep_fun`, `:status_callback`, `:force_rebuild`, materializer/lock fns)
- Distributed locking: per-organization, non-blocking (`:global.set_lock` with 0 retries); only gates runtime sessions, not graph builds
- `GraphManifest.schema_version` is hardcoded to `1` — no migration path exists
- Station materializer: cascading 16-table filter pipeline, referential integrity re-checked on filtered rows, stable sort per file

### Config Keys (all env-overridable in `runtime.exs`)
`java_path`, `otp_jar_path`, `otp_osm_path`, `otp_runtime_path`, `otp_artifacts_path`, `otp_graph_build_heap` (≥4GB), `otp_graph_build_timeout_ms` (600s), `otp_server_host` (127.0.0.1), `otp_server_port` (8080), `otp_server_heap` (4G), `otp_server_ready_timeout_ms` (30s), `otp_server_ready_poll_interval_ms` (250ms), `otp_server_shutdown_timeout_ms` (5s), `otp_graphql_path`, `otp_jar_sha256` (optional, nil by default)

## State, I/O & Side Effects

**Database:** `otp_gtfs_artifacts` table (UUID PK, FKs to organizations + gtfs_versions, `zip_path`, `content_hash`, `file_size_bytes`, `manifest_json` jsonb)

**Disk paths:**
- GTFS zips: `<otp_artifacts_path>/<org_id>/<version_id>/gtfs.zip`
- Graph workspaces: `<otp_runtime_path>/<org_id>/<version_id>/graph/<scope>/<gtfs_input_sha256>/`
- Station zips: `<otp_artifacts_path>/<org_id>/<version_id>/station/<sha256(station_stop_id)>/station_gtfs.zip`

**OS process:** OTP JAR spawned as Erlang `Port`; stop via SIGTERM (5s) → SIGKILL (1s)

**Cleanup:** artifact: deletes DB record + disk zip on session success; graph: `File.rm_rf` workspace root on session success. Failed builds leave orphaned disk artifacts.

## Failure Modes

| Risk | Severity | Description |
|---|---|---|
| No station zip caching | High | Station zips rebuilt every call; no DB tracking |
| Single OSM file per deployment | High | All orgs/versions share one OSM; OSM update invalidates all graphs |
| Orphaned graph workspaces | High | Only cleaned on successful session; failed builds accumulate |
| Concurrent graph builds unguarded | Medium | Lock gates sessions only, not builds; possible race |
| Manifest schema v1 handcuff | Medium | No migration path for manifest format changes |
| Heap config regex strict | Medium | Requires `\d+[unit]` format (e.g. `4G`); `4GB` or bare `4096` fail |
| SIGKILL fallback platform-specific | Low | `kill -KILL` may fail silently on some systems |

## Change Checklist
- [ ] Run `mix precommit` after changes
- [ ] If adding/removing config keys, update `config/runtime.exs` and `config/config.exs`
- [ ] If changing artifact/graph paths, verify `ArtifactPath`/`GraphPath` determinism
- [ ] If changing error codes, follow `[%{code: atom(), severity: ..., message: ...}]` convention
- [ ] If changing manifest schema, create a migration strategy (currently hardcoded to v1)
- [ ] Inject new dependencies through `opts` to preserve testability
- [ ] Test with `force_rebuild: true` to verify build pipelines
- [ ] Verify `:global` lock scope matches organization isolation expectations

## Escalate To Deep Analysis
- Full module behavior detail and pseudo-code flows for all sub-contexts
- Complete config key table with per-environment defaults
- Station materializer: 16-table cascading filter pipeline, referential integrity logic
- Pathways validity: GraphQL query structure, scoring rules, test case classification
- Prerequisites: Java version parsing, heap parsing regex, platform-specific RAM detection
- All risk/ambiguity details (R-1 through R-9, A-1 through A-5)
- Evidence file listing with line counts
