# Mix Maintenance Tasks Agent Doc

Source target: `lib-mix`
Scope: Operator Mix tasks for importing GTFS tables and installing/checking local OTP assets.
Deep analysis: [`../analysis/lib-mix.md`](../analysis/lib-mix.md)
Freshness: `source_hash=null`, `last_synthesized=null`

## Use When
- Adding a new GTFS import task (e.g., `import_trips`).
- Modifying CSV parsing or row-processing logic shared by import tasks.
- Changing OTP artifact download, checksum verification, or prerequisite checks.
- Adjusting CLI argument parsing, error handling, or exit-code behavior for any Mix task in this target.
- Adding instrumentation, logging, or dry-run modes to operator tooling.

## Read First
- `lib/mix/tasks/gtfs/import_stops.ex` — canonical import task template (header-aware CSV, per-row inserts, rescue File.Error).
- `lib/mix/tasks/gtfs/otp/install.ex` — OTP artifact download with streaming Req, OptionParser, checksum, dry-run.
- `lib/gtfs_planner/otp/prerequisites.ex` — shared check logic (Java 21, jar/osm files, heap) consumed by both OTP tasks.

## Interfaces

### CLI
- `mix gtfs.import_stops <org_uuid> <path/to/stops.txt>` — exit 0 (>=1 row) / 1 (args / no version / 0 rows).
- `mix gtfs.import_levels <org_uuid> <path/to/levels.txt>` — same contract.
- `mix gtfs.import_pathways <org_uuid> <path/to/pathways.txt>` — same contract, but all-or-nothing `Ecto.Multi` transaction.
- `mix gtfs.otp.install [--jar-url] [--osm-url] [--force] [--skip-check] [--dry-run]`.
- `mix gtfs.otp.check [--create-dir] [--warn-only]`.

### Internal Dependencies
- `GtfsPlanner.Versions.get_latest_gtfs_version/1` — all import tasks.
- `GtfsPlanner.Gtfs.create_stop/1`, `create_level/1` — import_stops, import_levels.
- `GtfsPlanner.Gtfs` (via `Pathway.changeset/2` in `Ecto.Multi`) — import_pathways.
- `GtfsPlanner.Gtfs.get_level_by_level_id/3`, `get_stop_by_stop_id/3` — FK resolution.
- `GtfsPlanner.Otp.Prerequisites.check/1` — otp.install, otp.check.
- `Req` (HTTP client) — otp.install downloads.
- `:crypto` (Erlang) — streaming SHA256 for jar checksum.
- `Application.get_env(:gtfs_planner, :key)` — all OTP task config.

### Configuration Keys (runtime.exs)
| Key | Env Var | Default (non-prod) |
|---|---|---|
| `:java_path` | `JAVA_PATH` | `/opt/homebrew/opt/openjdk@21/bin/java` |
| `:otp_jar_path` | `OTP_JAR_PATH` | `priv/otp/opentripplanner.jar` |
| `:otp_osm_path` | `OTP_OSM_PATH` | `priv/otp/region.osm.pbf` |
| `:otp_graph_build_heap` | `OTP_GRAPH_BUILD_HEAP` | `"4G"` |
| `:otp_jar_sha256` | `OTP_JAR_SHA256` | `nil` (no check) |

## Rules & Invariants

### Import Tasks
- **R1:** `organization_id` must be a valid UUID. Invalid → `System.halt(1)`.
- **R2:** CSV file must exist on disk. Missing → `System.halt(1)`.
- **R3:** Org must have >=1 GTFS version. Missing → halt with guidance to use web UI.
- **R4:** Import always targets the most recently inserted GTFS version (`inserted_at DESC`).
- **R5:** Stops and Levels use per-row `Enum.reduce` insertion; partial success allowed (>=1 row). Any row failure is logged but does not abort.
- **R6:** Pathways use `Ecto.Multi` all-or-nothing transaction. Any row failure rolls back the entire batch.
- **R7:** Stop→Level FK resolution: `level_id` string not found in DB → log warning, set `level_id` nil (non-fatal).
- **R8:** Pathway→Stop FK resolution: `from_stop_id`/`to_stop_id` not found → fatal error.
- **R9:** Stops/Pathways use header-aware CSV (first row = column names). Levels use fixed-position (assumes `level_id, level_index, level_name` column order — fragile).
- **R10–R15:** Field defaults: `location_type`→0, `wheelchair_boarding`→nil, `is_bidirectional`→true, `parent_station`→nil, `level_name`→nil. Enum ranges: `pathway_mode` 1–7, `location_type` 0–4, `wheelchair_boarding` 0–2. Empty strings → nil via `empty_to_nil/1`. Level index must be a valid float.

### OTP Tasks
- **R16:** Java 21+ required. Parses `java -version` output with regex `/version\s+"(?<version>[^"]+)"/`.
- **R17–R20:** OTP dir must exist. Jar must be absolute `.jar`, readable. OSM must be absolute `.pbf`, readable. Heap must be >=4GB and <= detected system RAM.
- **R21:** Jar checksum verified only if `OTP_JAR_SHA256` is configured; mismatch → `Mix.raise`.
- **R22:** Downloads use `.part` temp file; deleted before download and on failure; renamed only on HTTP 2xx.
- **R23–R25:** `--dry-run` prints plan only. `--force` re-downloads. `--warn-only` exits 0 even if checks fail.

## State, I/O & Side Effects
- **Reads:** CSV files from local filesystem (UTF-8 assumed). Environment variables for OTP config. Application config via `Application.get_env/2`.
- **Writes:** Database rows via `create_stop/1`, `create_level/1`, `Pathway.changeset/2` (Ecto.Multi). Downloaded jar/osm files to `priv/otp/`.
- **Side effects:** `Mix.Task.run("app.start")` (imports, install) or `Mix.Task.run("app.config")` (check) boots OTP app. `System.halt/1` on failures. `Mix.raise/1` on unrecoverable OTP errors. ANSI-colored output (assumes ANSI terminal).
- **No global mutable state.** Tasks are single-run CLI invocations.

## Failure Modes
- **Import argument errors:** Print error + `@moduledoc` usage, `System.halt(1)`.
- **Missing GTFS versions:** Print guidance to use web UI, `System.halt(1)`.
- **Row processing failures (stops/levels):** Collected in `changeset.errors`, printed per-row, processing continues. `System.halt(1)` only if 0 successful rows.
- **Pathway batch failure:** `Ecto.Multi` rolls back all rows; `System.halt(1)`.
- **Download/network failures:** Delete `.part` temp file, `Mix.raise/1`.
- **Checksum mismatch:** `Mix.raise/1`.
- **Missing required config:** `Mix.raise/1` from `fetch_env_path!/2`.
- **CSV parse errors:** Malformed lines → warning + skip. Malformed header (stops/pathways) → zero rows → halt.
- **import_levels has no `try/rescue`:** `File.stream!` errors crash unhandled (known issue).

## Change Checklist
- Add a new import task? Copy the template from `import_stops.ex`. Decide per-row vs transactional. Add `try/rescue` for `File.Error`. Register the task in `mix.exs` if needed **(verify)**.
- Modify CSV parsing? The parser is duplicated in 3 Mix task files + `lib/gtfs_planner/gtfs/import.ex`. Update all 4 copies or extract to shared module first.
- Change FK resolution behavior? Check both soft-fail (R7, stop→level) and hard-fail (R8, pathway→stop) paths.
- Modify OTP prerequisites? Update `lib/gtfs_planner/otp/prerequisites.ex`; both `otp.install` and `otp.check` consume it.
- Add a new OTP config key? Add to `config/runtime.exs` and both `fetch_env_path!/2` callers in install.ex and check.ex.
- After changes, run `mix precommit`.

## Escalate To Deep Analysis
- Detailed file:line evidence for every rule, interface, and error handling category.
- Known issues and technical debt inventory (CSV parser duplication, inconsistent parsing, missing rescue, zero direct tests).
- Risks (partial-import data corruption, silent data loss from fixed-position parsing, unbounded memory, race condition on latest version, no rollback).
- Full System.cmd/3 calls and platform-specific memory detection (Darwin/Linux only).
