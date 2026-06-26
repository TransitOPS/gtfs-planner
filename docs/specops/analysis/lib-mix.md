# SpecOps Analysis: Mix Maintenance Tasks

**Target:** `lib/mix`
**Source Hash:** `sha256:f5727e12bd088ab3712abd8772f5fde2fa99c9273f98c99096bddecbb179672a`
**Generated:** 2026-06-26
**Origin:** derived from `lib/mix/**`

---

## 1. Purpose and Scope

This structural unit contains five Mix tasks under two namespaces that serve as operator-level CLI tooling:

| Namespace | Tasks | Purpose |
|---|---|---|
| `mix gtfs.import_*` | `import_stops`, `import_levels`, `import_pathways` | Import individual GTFS CSV tables from flat files into the database for a given organization and GTFS version |
| `mix gtfs.otp.*` | `otp.install`, `otp.check` | Download, verify, and validate local OTP (OpenTripPlanner) jar and OSM extract artifacts required for graph builds |

All tasks are `use Mix.Task` modules that live outside the Phoenix request/response pipeline and are invoked from the CLI. They share the patterns of:
- Argument parsing via `OptionParser.parse/2` (OTP tasks) or positional argument matching (GTFS import tasks)
- UUID validation via `Ecto.UUID.cast/1`
- File existence checking via `File.exists?/1`
- Graceful error handling with `System.halt/1` on unrecoverable failures
- Starting the OTP application via `Mix.Task.run("app.start")` or `Mix.Task.run("app.config")`

### Evidence: Purpose and Scope

- `lib/mix/tasks/gtfs/import_stops.ex:1-4` — `@moduledoc` describes "Import GTFS stops.txt data into the database"
- `lib/mix/tasks/gtfs/import_levels.ex:1-4` — "Import GTFS levels.txt data into the database"
- `lib/mix/tasks/gtfs/import_pathways.ex:1-4` — "Import GTFS pathways.txt data into the database"
- `lib/mix/tasks/gtfs/otp/install.ex:1-4` — "Download local OTP artifacts used for export graph builds"
- `lib/mix/tasks/gtfs/otp/check.ex:1-4` — "Validate local OTP prerequisites for export graph builds"
- All five files use `use Mix.Task` (line 25-27 of each import file, line 21 of install.ex, line 17 of check.ex)

---

## 2. Module Structure and Public Interface

### 2.1 CLI Interface

#### GTFS Import Tasks (shared pattern)

All three import tasks (`import_stops`, `import_levels`, `import_pathways`) share an identical CLI interface:

```
mix gtfs.import_stops <organization_id> <path/to/stops.txt>
mix gtfs.import_levels <organization_id> <path/to/levels.txt>
mix gtfs.import_pathways <organization_id> <path/to/pathways.txt>
```

Arguments:
- `organization_id` — UUID string, validated by `Ecto.UUID.cast/1`
- `file_path` — Path to the GTFS CSV file, validated by `File.exists?/1`

Exit codes:
- `0` on success or partial success (at least one row imported)
- `1` on argument errors, missing versions, or zero successful rows

#### OTP Tasks

```
mix gtfs.otp.install [--jar-url <url>] [--osm-url <url>] [--force] [--skip-check] [--dry-run]
mix gtfs.otp.check [--create-dir] [--warn-only]
```

Options for `gtfs.otp.install`:
- `--jar-url` — Override OTP jar download URL
- `--osm-url` — Override OSM extract download URL
- `--force` / `-f` — Re-download even if files exist
- `--skip-check` — Skip post-download prerequisite check
- `--dry-run` — Print planned actions without downloading

Options for `gtfs.otp.check`:
- `--create-dir` / `-c` — Create `priv/otp` directory if missing
- `--warn-only` / `-w` — Exit 0 even if checks fail

### 2.2 Public Functions

All tasks expose a single public function: `run/1` (the `@impl Mix.Task` callback).

### Evidence: Module Structure and Public Interface

- `lib/mix/tasks/gtfs/import_stops.ex:30-41` — `run/1` with `Mix.Task.run("app.start")` then `parse_args` + `import_stops`
- `lib/mix/tasks/gtfs/import_levels.ex:30-41` — identical pattern
- `lib/mix/tasks/gtfs/import_pathways.ex:30-41` — identical pattern
- `lib/mix/tasks/gtfs/otp/install.ex:30-91` — `run/1` parses options via `OptionParser`, handles `--dry-run`, downloads artifacts
- `lib/mix/tasks/gtfs/otp/check.ex:23-53` — `run/1` parses options, calls `Prerequisites.check/1`, prints report
- `lib/mix/tasks/gtfs/otp/install.ex:36-44` — OptionParser strict options and aliases
- `lib/mix/tasks/gtfs/otp/check.ex:28-31` — OptionParser strict options and aliases

---

## 3. Data Flow and Processing

### 3.1 GTFS Import Task Flow

```
CLI args → parse_args/1 → validate_uuid + validate_file
  → import_*(organization_id, file_path)
    → GtfsPlanner.Versions.get_latest_gtfs_version(organization_id)
      → [:ok, gtfs_version] | [:error, :no_versions]
    → do_import_*(organization_id, gtfs_version_id, file_path)
      → parse_csv_file(file_path) → Stream of row_maps
      → Enum.reduce → {total, success, failure}
      → per-row: process_row → GtfsPlanner.Gtfs.create_* → {:ok, record} | {:error, changeset}
      → System.halt(1) if success == 0
```

### 3.2 CSV Parsing

Two distinct CSV parsing approaches exist across the tasks:

**Header-aware parsing** (stops, pathways): Uses `Stream.transform/3` with `{:no_header, nil}` state. The first line becomes the header; subsequent lines are zipped with header keys to produce `Map.new()`. Rows whose field count doesn't match the header are skipped with a warning.

**Fixed-position parsing** (levels): Uses `Stream.drop(1)` to skip the header, then `parse_csv_line/1` to get fields, then positionally extracts `level_id`, `level_index`, `level_name`. This is more fragile — it assumes a fixed column order rather than using column names.

Both approaches share the same `parse_csv_fields/1` UTF-8 character-level CSV parser that handles quoted fields, escaped quotes (`""`), and commas within quotes.

### 3.3 OTP Install Flow

```
CLI args → OptionParser.parse → fetch_env_path! (from Application config)
  → print_plan (jar_url, osm_url, jar_path, osm_path, force?, dry_run?)
  → [dry_run?] exit
  → ensure_parent_dir! for jar_path and osm_path
  → download!(:otp_jar, jar_url, jar_path, force?)
    → uses Req.get to stream download to .part temp file
    → renames .part to final path on success
    → validates HTTP status 200-299
  → maybe_verify_jar_checksum! (if OTP_JAR_SHA256 configured)
  → download!(:otp_osm, osm_url, osm_path, force?)
  → [unless skip_check?] Prerequisites.check(create_dir: true)
    → prints each check result
    → System.halt(1) if errors > 0
```

### 3.4 OTP Check Flow

```
CLI args → OptionParser.parse → Prerequisites.check(opts)
  → check_java → check_otp_dir → check_jar → check_osm → check_heap
  → prints each check result
  → System.halt(1) if errors > 0 and not warn_only
```

### 3.5 Row Processing — Import Stop

`process_row/3` in `import_stops.ex:217-244`:
1. `extract_required(map, "stop_id")` — fails if nil or empty
2. `parse_decimal("stop_lat")`, `parse_decimal("stop_lon")` — optional, nil if missing
3. `parse_location_type("location_type")` — defaults to 0 (stop/platform), range 0-4
4. `parse_wheelchair_boarding("wheelchair_boarding")` — optional, range 0-2
5. `resolve_level_id("level_id")` — looks up level by `level_id` string; if not found, logs warning and sets to nil (non-fatal)
6. Strings like `stop_name`, `stop_desc`, `platform_code`, `parent_station` pass through `empty_to_nil`
7. Calls `GtfsPlanner.Gtfs.create_stop(attrs)`

### 3.6 Row Processing — Import Level

`process_row/3` in `import_levels.ex:209-227`:
1. Extracts `level_id`, `level_index_str`, `level_name` from fixed-position CSV parsing
2. `parse_float(level_index_str)` — must be a valid float
3. Calls `GtfsPlanner.Gtfs.create_level(attrs)`

### 3.7 Row Processing — Import Pathway

`row_to_attrs/3` in `import_pathways.ex:211-245`:
1. `extract_required` for `pathway_id`, `from_stop_id`, `to_stop_id`
2. `parse_pathway_mode` — integer 1-7 (GTFS pathway modes)
3. `parse_is_bidirectional` — defaults to `true` if nil/empty; accepts "0"/"1"/"true"/"false"
4. `resolve_stop_id(from_stop_id)` and `resolve_stop_id(to_stop_id)` — must find the stop in DB, fatal error if not found
5. `parse_integer` for `traversal_time`, `stair_count` — optional
6. `parse_decimal` for `length`, `max_slope`, `min_width` — optional
7. `signposted_as`, `reversed_signposted_as` pass through `empty_to_nil`
8. Uses `Ecto.Multi` for batch insert (all-or-nothing transaction)

### Evidence: Data Flow

- `lib/mix/tasks/gtfs/import_stops.ex:74-89` — `import_stops` calls `get_latest_gtfs_version` then `do_import_stops`
- `lib/mix/tasks/gtfs/import_stops.ex:133-176` — header-aware CSV parsing with `Stream.transform/3`
- `lib/mix/tasks/gtfs/import_levels.ex:127-135` — fixed-position CSV parsing with `Stream.drop(1)`
- `lib/mix/tasks/gtfs/import_levels.ex:137-167` — `parse_csv_line/1` with fixed-field extraction
- `lib/mix/tasks/gtfs/import_pathways.ex:92-104` — `Ecto.Multi` batch insert approach
- `lib/mix/tasks/gtfs/import_pathways.ex:211-245` — `row_to_attrs/3` with comprehensive field validation
- `lib/mix/tasks/gtfs/otp/install.ex:93-105` — `fetch_env_path!/2` reads from Application config
- `lib/mix/tasks/gtfs/otp/install.ex:124-148` — `download!/4` with streaming download, .part temp file, rename
- `lib/mix/tasks/gtfs/otp/install.ex:150-171` — `maybe_verify_jar_checksum!/1` with streaming SHA256
- `lib/mix/tasks/gtfs/otp/check.ex:39-52` — delegates to `Prerequisites.check/1`

---

## 4. Dependencies and External Integration

### 4.1 Internal Dependencies

| Dependency | Used By | Purpose |
|---|---|---|
| `GtfsPlanner.Versions.get_latest_gtfs_version/1` | All import tasks | Look up latest GTFS version for organization |
| `GtfsPlanner.Gtfs.create_stop/1` | `import_stops` | Insert stop record |
| `GtfsPlanner.Gtfs.create_level/1` | `import_levels` | Insert level record |
| `GtfsPlanner.Gtfs.create_pathway/1` | indirectly via `Pathway.changeset` in `import_pathways` | Insert pathway record (via `Ecto.Multi`) |
| `GtfsPlanner.Gtfs.get_level_by_level_id/3` | `import_stops` | Resolve level_id foreign key |
| `GtfsPlanner.Gtfs.get_stop_by_stop_id/3` | `import_pathways` | Resolve from_stop_id/to_stop_id foreign keys |
| `GtfsPlanner.Otp.Prerequisites.check/1` | `otp.install`, `otp.check` | Run OTP prerequisite checks |
| `Ecto.Multi` | `import_pathways` | Transactional batch insert |
| `Application.get_env/2` | `otp.install`, `otp.check` | Read OTP paths from config |
| `OptionParser.parse/2` | `otp.install`, `otp.check` | Parse CLI options |

### 4.2 External Dependencies

| Dependency | Used By | Purpose |
|---|---|---|
| `Req` (HTTP client) | `otp.install` | Download OTP jar and OSM extract |
| File system (`File`, `File.Stream`) | All tasks | Read CSV files, write downloaded artifacts, check existence |
| `:crypto` (Erlang) | `otp.install` | Streaming SHA256 checksum verification |
| System shell (`System.cmd/3`) | `Prerequisites` (called by otp tasks) | Run `java -version`, `sysctl`, read `/proc/meminfo` |

### 4.3 Configuration Keys

| Key | Env Var | Default (non-prod) | Used By |
|---|---|---|---|
| `:java_path` | `JAVA_PATH` | `/opt/homebrew/opt/openjdk@21/bin/java` | `otp.check` |
| `:otp_jar_path` | `OTP_JAR_PATH` | `priv/otp/opentripplanner.jar` | `otp.install`, `otp.check` |
| `:otp_osm_path` | `OTP_OSM_PATH` | `priv/otp/region.osm.pbf` | `otp.install`, `otp.check` |
| `:otp_graph_build_heap` | `OTP_GRAPH_BUILD_HEAP` | `"4G"` | `otp.check` |
| `:otp_jar_sha256` | `OTP_JAR_SHA256` | `nil` (no check) | `otp.install` |

### Evidence: Dependencies

- `lib/mix/tasks/gtfs/import_stops.ex:77-78` — `GtfsPlanner.Versions.get_latest_gtfs_version(organization_id)`
- `lib/mix/tasks/gtfs/import_stops.ex:240` — `GtfsPlanner.Gtfs.create_stop(attrs)`
- `lib/mix/tasks/gtfs/import_stops.ex:307` — `GtfsPlanner.Gtfs.get_level_by_level_id(...)`
- `lib/mix/tasks/gtfs/import_levels.ex:77-78` — same version lookup pattern
- `lib/mix/tasks/gtfs/import_levels.ex:223` — `GtfsPlanner.Gtfs.create_level(attrs)`
- `lib/mix/tasks/gtfs/import_pathways.ex:76-78` — same version lookup pattern
- `lib/mix/tasks/gtfs/import_pathways.ex:98-99` — `Pathway.changeset` and `Ecto.Multi.insert`
- `lib/mix/tasks/gtfs/import_pathways.ex:313` — `GtfsPlanner.Gtfs.get_stop_by_stop_id(...)`
- `lib/mix/tasks/gtfs/otp/install.ex:23` — `alias GtfsPlanner.Otp.Prerequisites`
- `lib/mix/tasks/gtfs/otp/install.ex:133` — `Req.get(url: url, into: File.stream!(...))`
- `lib/mix/tasks/gtfs/otp/check.ex:19` — `alias GtfsPlanner.Otp.Prerequisites`
- `config/runtime.exs:39-75` — configuration key definitions for OTP paths and heap

---

## 5. Configuration and Operability

### 5.1 Runtime Configuration

All OTP task configuration is read from `Application.get_env(:gtfs_planner, key)` at runtime, sourced from environment variables with platform-appropriate fallbacks (`config/runtime.exs:39-110`).

### 5.2 Task Invocation Requirements

**GTFS import tasks require:**
- The Phoenix application to be started (`Mix.Task.run("app.start")`)
- Existing organization with matching UUID
- At least one GTFS version for the organization (created via web UI or API)
- Readable CSV file at the specified path

**OTP check task requires:**
- Only configuration loaded (`Mix.Task.run("app.config")`) — lighter weight than `app.start`
- `java_path` configured in Application env
- `otp_jar_path` and `otp_osm_path` configured

**OTP install task requires:**
- Full application start (`Mix.Task.run("app.start")`)
- Same config as check, plus target directories writable
- Network access to download URLs

### 5.3 Error Handling Patterns

- Argument errors: Print error, print usage (`@moduledoc`), `System.halt(1)`
- Missing GTFS versions: Print helpful message suggesting web UI, `System.halt(1)`
- File not found: Return `{:error, reason}` from validation, printed by caller
- Row processing failures: Collect errors, print per-row, continue processing
- Zero successful rows: `System.halt(1)`
- Download failures: `Mix.raise/1` with HTTP status or error reason
- Checksum mismatch: `Mix.raise/1`
- Invalid options: Print invalid args, print usage, `System.halt(1)`

### Evidence: Configuration and Operability

- `lib/mix/tasks/gtfs/import_stops.ex:39-41` — prints error, usage, halts on arg errors
- `lib/mix/tasks/gtfs/import_stops.ex:82-87` — halts with message on missing versions
- `lib/mix/tasks/gtfs/import_stops.ex:119-123` — halts if zero successful rows
- `lib/mix/tasks/gtfs/otp/install.ex:46-50` — invalid args handling
- `lib/mix/tasks/gtfs/otp/install.ex:93-105` — `fetch_env_path!/2` raises on missing config
- `lib/mix/tasks/gtfs/otp/install.ex:139-141` — `Mix.raise` on download failure
- `lib/mix/tasks/gtfs/otp/install.ex:164-166` — `Mix.raise` on checksum mismatch
- `lib/mix/tasks/gtfs/otp/check.ex:25` — `Mix.Task.run("app.config")` (lighter than `app.start`)

---

## 6. Business Rules

### 6.1 GTFS Import Rules

**R1 — UUID Validation:** The organization_id argument must be a valid UUID string. Invalid UUIDs cause immediate halt.

**R2 — File Existence:** The CSV file must exist on disk. Missing files cause immediate halt.

**R3 — Version Requirement:** An organization must have at least one GTFS version before importing. Missing versions cause halt with guidance to use the web UI.

**R4 — Latest Version Selection:** Imports always target the most recently inserted GTFS version (ordered by `inserted_at DESC`).

**R5 — Row-Level Persistence (Stops, Levels):** Each row is individually inserted. Failures are collected and reported but do not abort the import (`Enum.reduce` approach). At least one successful row is required.

**R6 — Transactional Batch (Pathways):** All pathway rows are inserted in a single `Ecto.Multi` transaction. Any row failure rolls back the entire batch.

**R7 — Foreign Key Resolution — level_id (Stops):** If a stop references a `level_id` that doesn't exist in the database, the import logs a warning and sets `level_id` to `nil`. This is non-fatal.

**R8 — Foreign Key Resolution — from_stop_id/to_stop_id (Pathways):** If a pathway references a `from_stop_id` or `to_stop_id` that doesn't exist, the import fails with an error. This is fatal.

**R9 — Header Handling:** Stops and pathways parsers use the first row as a header to map columns by name. Levels parser discards the first row and assumes fixed column order.

**R10 — Field Defaults:**
- `location_type` defaults to `0` (stop/platform) if nil or empty
- `wheelchair_boarding` defaults to `nil` if nil or empty
- `is_bidirectional` defaults to `true` if nil or empty
- `parent_station` defaults to `nil` if nil or empty
- `level_name` defaults to `nil` if nil or empty

**R11 — Empty String to Nil:** All optional string fields are converted from empty strings to nil via `empty_to_nil/1`.

**R12 — Level Index:** Must be a valid float. Non-parseable values cause row failure.

**R13 — pathway_mode:** Must be an integer in range 1-7 per GTFS spec.

**R14 — location_type:** Must be an integer in range 0-4 per GTFS spec.

**R15 — wheelchair_boarding:** Must be an integer in range 0-2 per GTFS spec.

### 6.2 OTP Prerequisites Rules

**R16 — Java Version:** Java 21+ is required. The check runs `java -version`, parses the output with regex `/version\s+"(?<version>[^"]+)"/`, and handles both legacy (`1.8.0`) and modern (`21.0.1`) version formats.

**R17 — OTP Directory:** Must exist (or be creatable with `--create-dir`). Derived from `otp_jar_path`'s parent directory, or defaults to `priv/otp`.

**R18 — Jar File:** Must be an absolute path ending in `.jar`, exist as a regular file, and be readable.

**R19 — OSM File:** Must be an absolute path ending in `.pbf`, exist as a regular file, and be readable.

**R20 — Heap Configuration:** Must be at least 4GB (`@min_heap_bytes = 4 * 1024 * 1024 * 1024`). Must not exceed detected system RAM. Parses formats like `4G`, `4096M`, `4194304K`.

**R21 — Jar Checksum (Optional):** If `OTP_JAR_SHA256` env var is set, the downloaded jar's SHA256 is verified against it. Mismatch raises `Mix.raise`.

**R22 — Download Resume Safety:** Downloads use a `.part` temp file; the temp file is deleted before download and on failure. The final rename is only performed on HTTP 2xx success.

**R23 — Dry Run Mode:** `--dry-run` prints the plan (URLs, paths, force flag) without downloading or modifying files.

**R24 — Force Re-download:** `--force` causes re-download even if the target file already exists.

**R25 — Warn-Only Mode:** `--warn-only` on `otp.check` exits 0 even if checks fail.

### Evidence: Business Rules

- `lib/mix/tasks/gtfs/import_stops.ex:58-62` — R1 UUID validation
- `lib/mix/tasks/gtfs/import_stops.ex:65-70` — R2 file existence
- `lib/mix/tasks/gtfs/import_stops.ex:82-87` — R3 version requirement
- `lib/mix/tasks/gtfs/import_stops.ex:120-123` — R5 at least one successful row
- `lib/mix/tasks/gtfs/import_pathways.ex:92-104` — R6 transactional batch
- `lib/mix/tasks/gtfs/import_stops.ex:303-314` — R7 non-fatal level_id resolution
- `lib/mix/tasks/gtfs/import_pathways.ex:312-316` — R8 fatal stop_id resolution
- `lib/mix/tasks/gtfs/import_levels.ex:128-134` — R9 fixed-position parsing
- `lib/mix/tasks/gtfs/import_stops.ex:276-277` — R10 location_type default
- `lib/mix/tasks/gtfs/import_stops.ex:289-290` — R10 wheelchair_boarding default
- `lib/mix/tasks/gtfs/import_pathways.ex:272-273` — R10 is_bidirectional default
- `lib/mix/tasks/gtfs/import_stops.ex:255-257` — R11 empty_to_nil
- `lib/mix/tasks/gtfs/import_levels.ex:230-234` — R12 float parsing
- `lib/mix/tasks/gtfs/import_pathways.ex:259-270` — R13 pathway_mode range 1-7
- `lib/mix/tasks/gtfs/import_stops.ex:279-287` — R14 location_type range 0-4
- `lib/mix/tasks/gtfs/import_stops.ex:292-300` — R15 wheelchair_boarding range 0-2
- `lib/gtfs_planner/otp/prerequisites.ex:6-7` — R16 min_java_major 21, R20 min_heap_bytes
- `lib/gtfs_planner/otp/prerequisites.ex:73-101` — R16 java version parsing
- `lib/gtfs_planner/otp/prerequisites.ex:103-123` — R17 OTP directory check
- `lib/gtfs_planner/otp/prerequisites.ex:125-156` — R18/R19 jar and osm file checks
- `lib/gtfs_planner/otp/prerequisites.ex:158-205` — R20 heap configuration checks
- `lib/mix/tasks/gtfs/otp/install.ex:150-171` — R21 jar checksum verification
- `lib/mix/tasks/gtfs/otp/install.ex:130-147` — R22 download temp file safety
- `lib/mix/tasks/gtfs/otp/install.ex:64-66` — R23 dry run mode
- `lib/mix/tasks/gtfs/otp/install.ex:125` — R24 force re-download
- `lib/mix/tasks/gtfs/otp/check.ex:50` — R25 warn-only mode

---

## 7. Error Handling

### 7.1 Error Categories

| Category | Mechanism | Exit Code |
|---|---|---|
| Invalid arguments | Print error + usage, `System.halt(1)` | 1 |
| Invalid UUID | Return `{:error, reason}` from `validate_uuid/1` | 1 |
| File not found | Return `{:error, reason}` from `validate_file/1` | 1 |
| No GTFS version | Print error, `System.halt(1)` | 1 |
| Row processing failure | Collect in `changeset.errors`, print per-row, continue | 0 (if any success) |
| Zero successful rows | `System.halt(1)` after summary | 1 |
| Download HTTP error | Delete .part file, `Mix.raise/1` | crash |
| Download network error | Delete .part file, `Mix.raise/1` | crash |
| Checksum mismatch | `Mix.raise/1` | crash |
| Missing required config | `Mix.raise/1` from `fetch_env_path!/2` | crash |
| CSV parse error (Malformed line) | Print warning, skip row | 0 (if any success) |
| CSV parse error (Malformed header) | Skip all rows | 1 (zero success) |
| File.Error (import) | `rescue` in `import_pathways`, `import_stops`; prints message, `System.halt(1)` | 1 |
| RuntimeError (import_pathways) | `rescue` in `do_import_pathways`, prints message, `System.halt(1)` | 1 |
| Prerequisites check failures | Report summary, `System.halt(1)` unless `--warn-only` | 1 or 0 |

### 7.2 Key Differences Between Tasks

- `import_stops` and `import_levels` use `Enum.reduce` for row-by-row insertion with error collection; partial success is allowed.
- `import_pathways` uses `Ecto.Multi` for all-or-nothing transactional batch insert; any row error rolls back the entire import.
- `import_stops` has `try/rescue` for `File.Error` only.
- `import_pathways` has `try/rescue` for both `RuntimeError` and `File.Error`.
- `import_levels` has no `try/rescue` block — file stream errors would crash unhandled.
- `otp.install` uses `Mix.raise/1` for unrecoverable errors (download failure, checksum mismatch).
- `otp.check` uses `System.halt/1` for check failures (unless `--warn-only`).

### Evidence: Error Handling

- `lib/mix/tasks/gtfs/import_stops.ex:38-41` — arg error handling
- `lib/mix/tasks/gtfs/import_stops.ex:95-111` — per-row error collection
- `lib/mix/tasks/gtfs/import_stops.ex:119-123` — zero success halt
- `lib/mix/tasks/gtfs/import_stops.ex:125-129` — rescue File.Error
- `lib/mix/tasks/gtfs/import_pathways.ex:106-118` — Ecto.Multi transaction error handling
- `lib/mix/tasks/gtfs/import_pathways.ex:120-128` — rescue RuntimeError and File.Error
- `lib/mix/tasks/gtfs/import_pathways.ex:101-102` — raise on row conversion failure
- `lib/mix/tasks/gtfs/otp/install.ex:139-146` — download error handling with Mix.raise
- `lib/mix/tasks/gtfs/otp/install.ex:164-166` — checksum mismatch with Mix.raise
- `lib/mix/tasks/gtfs/otp/check.ex:50-52` — conditional halt based on warn_only

---

## 8. Data Models

### 8.1 Intermediate Row Representations

**Levels (fixed-position):**
```elixir
%{
  level_id: String.t(),
  level_index_str: String.t(),   # parsed to float
  level_name: String.t() | nil
}
```

**Stops (header-mapped):**
Maps with string keys matching CSV header fields. Key fields:
- `stop_id` (required), `stop_name`, `stop_desc`, `platform_code`
- `stop_lat`, `stop_lon` (parsed to Decimal)
- `location_type` (parsed to integer 0-4), `wheelchair_boarding` (parsed to integer 0-2)
- `level_id` (resolved to DB level ID), `parent_station`

**Pathways (header-mapped):**
Maps with string keys matching CSV header fields. Key fields:
- `pathway_id` (required), `from_stop_id` (required), `to_stop_id` (required)
- `pathway_mode` (integer 1-7), `is_bidirectional` (boolean)
- `traversal_time`, `stair_count` (optional integers)
- `length`, `max_slope`, `min_width` (optional decimals)
- `signposted_as`, `reversed_signposted_as` (optional strings)

### 8.2 Target Database Records

All insertions go through the standard context functions in `GtfsPlanner.Gtfs`:
- `create_stop/1` → `%Stop{}` via `Stop.changeset/2`
- `create_level/1` → `%Level{}` via `Level.changeset/2`
- Pathway insert → `%Pathway{}` via `Pathway.changeset/2` (through `Ecto.Multi`)

### 8.3 OTP Prerequisites Report

```elixir
%{
  checks: [%{name: atom(), ok?: boolean(), message: String.t()}],
  errors: non_neg_integer()
}
```

Five named checks: `:java`, `:otp_dir`, `:otp_jar`, `:otp_osm`, `:heap`.

### Evidence: Data Models

- `lib/mix/tasks/gtfs/import_levels.ex:149-153` — level row map structure
- `lib/mix/tasks/gtfs/import_stops.ex:225-238` — stop attrs map structure
- `lib/mix/tasks/gtfs/import_pathways.ex:224-239` — pathway attrs map structure
- `lib/gtfs_planner/otp/prerequisites.ex:9-10` — check_result and result types
- `lib/gtfs_planner/otp/prerequisites.ex:16-24` — five named checks

---

## 9. CSV Parser Implementation Detail

All three import tasks contain a complete, hand-written state-machine CSV parser (`parse_csv_fields/5`) that operates on UTF-8 binary input. The parser handles:

- **Quoted fields:** Fields wrapped in `"` double quotes
- **Embedded commas:** Commas within quoted fields are preserved as part of the field value
- **Escaped quotes:** Double-double-quotes (`""`) within quoted fields are unescaped to a single `"`
- **Empty fields:** Consecutive commas produce empty string fields
- **Trailing commas:** Produce an empty final field

The parser uses a recursive function with five accumulators: `rest` (remaining binary), `fields` (completed fields), `current` (current field being built), `in_quotes` (boolean), and `pos` (byte position for tracking).

This code is **duplicated across all three import task files** (same logic in `import_stops.ex`, `import_levels.ex`, `import_pathways.ex`) and also separately exists in the web-side `Import` module (`lib/gtfs_planner/gtfs/import.ex`).

### Evidence: CSV Parser

- `lib/mix/tasks/gtfs/import_levels.ex:169-207` — full `parse_csv_fields/5` implementation
- `lib/mix/tasks/gtfs/import_stops.ex:183-214` — identical `parse_csv_fields/5` implementation
- `lib/mix/tasks/gtfs/import_pathways.ex:178-209` — identical `parse_csv_fields/5` implementation
- `lib/gtfs_planner/gtfs/import.ex:499-501` — `parse_csv_line/1` and `parse_csv_fields` in web module

---

## 10. Known Issues and Technical Debt

### 10.1 CSV Parser Duplication

The `parse_csv_fields/5` stateless UTF-8 CSV parser is duplicated in four locations (three Mix tasks + web Import module). This is a DRY violation. Any bug fix or enhancement to CSV parsing requires updates in all four locations.

### 10.2 Inconsistent CSV Parsing Approaches

- **Levels task:** Uses fixed-position parsing (assumes column order: `level_id, level_index, level_name`). This is fragile — if a GTFS file has extra columns or different column ordering, the import will silently use wrong values.
- **Stops and pathways tasks:** Use header-aware parsing with column name mapping. This is robust to column reordering and extra columns.

### 10.3 Inconsistent Transaction Strategies

- **Stops/Levels:** Individual inserts, partial success allowed. If the process crashes mid-import, partially imported data remains.
- **Pathways:** `Ecto.Multi` all-or-nothing transaction. Consistent but different behavior.

### 10.4 Missing Rescue in import_levels

`import_levels.ex` has no `try/rescue` block for `File.Error` or other exceptions from `File.stream!`. If the file is inaccessible or malformed, the task will crash with an unhandled exception rather than a clean error message.

### 10.5 No Dry-Run for Import Tasks

The import tasks have no dry-run mode. Users cannot preview what would happen before executing an import. This contrasts with `otp.install` which has `--dry-run`.

### 10.6 No Test Coverage for Mix Tasks

There are no dedicated test files for any of the five Mix tasks. The CSV parsing logic is tested indirectly through `test/gtfs_planner/gtfs/import_test.exs` (which tests the web `Import` module, not the Mix task code). The OTP install/check tasks have no direct test coverage — they are tested only through `Prerequisites` module tests and integration via OTP runtime/preflight tests.

### 10.7 Config Validation is Bypassable

In `otp.check` and `otp.install`, the `fetch_env_path!/2` function requires config to be set and absolute. However, the task starts with `Mix.Task.run("app.config")` (check) or `Mix.Task.run("app.start")` (install), so runtime.exs must be loaded. If env vars are missing and fallbacks are used, the non-prod defaults may not reflect the actual environment intent.

### 10.8 ANSI Escape Code Assumption

`import_pathways.ex:320-325` uses `IO.ANSI.green()` and `IO.ANSI.red()` for colored output. This assumes the terminal supports ANSI. No fallback for non-ANSI terminals.

### 10.9 Integer.parse vs Float.parse Guard Gaps

- `import_stops.ex` uses `Integer.parse/1` for `location_type` and `wheelchair_boarding` with a fallback `rescue` for non-string inputs.
- `import_pathways.ex` uses the same `Integer.parse/1` pattern for `pathway_mode`, `traversal_time`, and `stair_count`.
- `import_levels.ex` uses `Float.parse/1` for `level_index`.

These all handle the `""` case through separate function clauses before reaching `Integer.parse`, but if a map key is missing (nil) and the nil guard clause isn't reached, behavior depends on function clause ordering.

### Evidence: Known Issues

- `lib/mix/tasks/gtfs/import_levels.ex:169-207` (and corresponding in stops, pathways) — duplicated CSV parser
- `lib/mix/tasks/gtfs/import_levels.ex:128-134` — fixed-position parsing vs header-aware in stops and pathways
- `lib/mix/tasks/gtfs/import_stops.ex:91-130` — `do_import_stops` with `try/rescue` for `File.Error` only
- `lib/mix/tasks/gtfs/import_levels.ex:89-124` — `do_import_levels` with no `try/rescue`
- `lib/mix/tasks/gtfs/import_pathways.ex:320-325` — ANSI escape codes
- No test files matching `test/**/mix/**` or `test/**/*task*` — confirmed zero direct tests

---

## 11. Assumptions and Risks

### 11.1 Assumptions

1. **Latest version selection:** The import tasks assume the most recently inserted GTFS version is the correct target. There is no way to specify a particular version ID or name from the CLI.
2. **CSV encoding is UTF-8:** The parser uses `<<char::utf8, rest::binary>>` pattern matching, which assumes UTF-8 encoding. Non-UTF-8 GTFS files (e.g., Latin-1) will cause match errors.
3. **Header format:** Stops/pathways tasks assume the first non-empty line is a valid CSV header. If the header row is malformed, the entire import is silently skipped (no rows processed).
4. **Ordering dependency:** Pathways depend on stops (via `from_stop_id`/`to_stop_id` resolution) and stops depend on levels (via `level_id` resolution). The Mix tasks don't enforce import ordering; users must run tasks in the correct sequence manually.
5. **Network availability:** `otp.install` assumes the configured download URLs are reachable. No retry logic or proxy support.
6. **File permissions:** `otp.install` assumes write permissions in the target directories. `ensure_parent_dir!/1` uses `File.mkdir_p!` which raises on permission errors.
7. **Java binary:** `otp.check` assumes `java -version` outputs version info in a parseable format. Unusual JVM distributions may produce output that doesn't match the regex.
8. **System memory detection:** `otp.check` only supports Darwin (via `sysctl hw.memsize`) and Linux (via `/proc/meminfo`). Other platforms silently skip the "heap fits in RAM" check.

### 11.2 Risks

1. **Data corruption from partial imports:** The stops and levels tasks use per-row insertion without wrapping in a transaction. If the Elixir process is killed mid-import, the database has incomplete data with no way to determine what was imported.
2. **Silent data loss from fixed-position parsing:** If a GTFS `levels.txt` file has columns in a different order than expected (`level_id, level_name, level_index` instead of `level_id, level_index, level_name`), the levels import will silently swap `level_index` and `level_name` values.
3. **Unbounded memory usage:** The `Enum.reduce` in stops and levels tasks, and `Ecto.Multi` aggregation in pathways, both accumulate all rows in memory. Very large GTFS files (>100k rows) may cause memory pressure.
4. **No rollback on import failure:** Even if `System.halt(1)` is called on zero success, any partially inserted rows from a prior successful run remain. There is no way to clean up or revert previous imports.
5. **Race condition on latest version:** `get_latest_gtfs_version` fetches the version once at the start. If someone creates a new version between task invocations of different import subtasks, different tables could be imported against different GTFS versions.
6. **Jar download integrity without checksum:** If `OTP_JAR_SHA256` is not configured, the downloaded jar is not verified. A corrupted or tampered download would go undetected.
7. **Download temp file leakage:** On certain failure paths (e.g., process kill during download), the `.part` temp file may not be cleaned up. The next run deletes it before downloading, but disk space may be wasted between runs.

### Evidence: Assumptions and Risks

- `lib/gtfs_planner/versions.ex:122-135` — R4 latest version selection
- `lib/mix/tasks/gtfs/import_levels.ex:128` — R9 fixed-position parsing (assumes column order)
- `lib/mix/tasks/gtfs/import_levels.ex:177` — `<<char::utf8, rest::binary>>` UTF-8 assumption
- `lib/mix/tasks/gtfs/import_stops.ex:153-175` — header-as-state, skipped if malformed
- `lib/gtfs_planner/otp/prerequisites.ex:207-243` — system_memory_bytes only supports darwin/linux
- `lib/mix/tasks/gtfs/otp/install.ex:130-131` — temp file management with `File.rm` before download
- `lib/mix/tasks/gtfs/otp/install.ex:150-170` — checksum verification only if configured

---

## Summary

| Metric | Value |
|---|---|
| Files analyzed | 5 source + 2 support modules |
| Mix tasks | 5 (3 import, 2 OTP) |
| Total lines | ~1,000 (tasks) + ~274 (Prerequisites) |
| External HTTP calls | 2 (jar download, osm download via Req) |
| Database operations | 3 (create_stop, create_level, Pathway.changeset via Ecto.Multi) |
| Config keys read | 5 |
| Direct tests | 0 (none for Mix tasks specifically) |
| Indirect tests | CSV parsing via Import module; Prerequisites via OTP integration tests |
| Duplicated code | CSV parser (4 copies), argument parsing (3 copies), UUID/file validation (3 copies) |
| Hardcoded defaults | OTP jar URL, OSM extract URL (Philadelphia), min_heap 4G, min_java 21 |
