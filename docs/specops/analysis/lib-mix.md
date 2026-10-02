# SpecOps Analysis: Mix Maintenance Tasks

**Target:** `lib/mix`
**Source Hash:** `sha256:f5727e12bd088ab3712abd8772f5fde2fa99c9273f98c99096bddecbb179672a`
**Generated:** 2026-06-26
**Origin:** derived from `lib/mix/**`

---

## 1. Purpose and Scope

This structural unit contains the operator-level OTP (OpenTripPlanner) CLI tooling:

| Namespace | Tasks | Purpose |
|---|---|---|
| `mix gtfs.otp.*` | `otp.install`, `otp.check` | Download, verify, and validate local OTP (OpenTripPlanner) jar and OSM extract artifacts required for graph builds |

Both tasks are `use Mix.Task` modules that live outside the Phoenix request/response pipeline and are invoked from the CLI. They share the patterns of:
- Argument parsing via `OptionParser.parse/2`
- Graceful error handling with `Mix.raise/1` on unrecoverable failures
- Starting the OTP application via `Mix.Task.run("app.start")` or `Mix.Task.run("app.config")`

### Evidence: Purpose and Scope

- `lib/mix/tasks/gtfs/otp/install.ex:1-4` — "Download local OTP artifacts used for export graph builds"
- `lib/mix/tasks/gtfs/otp/check.ex:1-4` — "Validate local OTP prerequisites for export graph builds"
- Both files use `use Mix.Task` (line 21 of install.ex, line 17 of check.ex)

---

## 2. Module Structure and Public Interface

### 2.1 CLI Interface

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

Both tasks expose a single public function: `run/1` (the `@impl Mix.Task` callback).

### Evidence: Module Structure and Public Interface

- `lib/mix/tasks/gtfs/otp/install.ex:30-91` — `run/1` parses options via `OptionParser`, handles `--dry-run`, downloads artifacts
- `lib/mix/tasks/gtfs/otp/check.ex:23-53` — `run/1` parses options, calls `Prerequisites.check/1`, prints report
- `lib/mix/tasks/gtfs/otp/install.ex:36-44` — OptionParser strict options and aliases
- `lib/mix/tasks/gtfs/otp/check.ex:28-31` — OptionParser strict options and aliases

---

## 3. Data Flow and Processing

### 3.1 OTP Install Flow

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

### 3.2 OTP Check Flow

```
CLI args → OptionParser.parse → Prerequisites.check(opts)
  → check_java → check_otp_dir → check_jar → check_osm → check_heap
  → prints each check result
  → System.halt(1) if errors > 0 and not warn_only
```

### Evidence: Data Flow

- `lib/mix/tasks/gtfs/otp/install.ex:93-105` — `fetch_env_path!/2` reads from Application config
- `lib/mix/tasks/gtfs/otp/install.ex:124-148` — `download!/4` with streaming download, .part temp file, rename
- `lib/mix/tasks/gtfs/otp/install.ex:150-171` — `maybe_verify_jar_checksum!/1` with streaming SHA256
- `lib/mix/tasks/gtfs/otp/check.ex:39-52` — delegates to `Prerequisites.check/1`

---

## 4. Dependencies and External Integration

### 4.1 Internal Dependencies

| Dependency | Used By | Purpose |
|---|---|---|
| `GtfsPlanner.Otp.Prerequisites.check/1` | `otp.install`, `otp.check` | Run OTP prerequisite checks |
| `Application.get_env/2` | `otp.install`, `otp.check` | Read OTP paths from config |
| `OptionParser.parse/2` | `otp.install`, `otp.check` | Parse CLI options |

### 4.2 External Dependencies

| Dependency | Used By | Purpose |
|---|---|---|
| `Req` (HTTP client) | `otp.install` | Download OTP jar and OSM extract |
| File system (`File`, `File.Stream`) | OTP tasks | Write downloaded artifacts, check existence |
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

- `lib/mix/tasks/gtfs/otp/install.ex:23` — `alias GtfsPlanner.Otp.Prerequisites`
- `lib/mix/tasks/gtfs/otp/install.ex:133` — `Req.get(url: url, into: File.stream!(...))`
- `lib/mix/tasks/gtfs/otp/check.ex:19` — `alias GtfsPlanner.Otp.Prerequisites`
- `config/runtime.exs:39-75` — configuration key definitions for OTP paths and heap

---

## 5. Configuration and Operability

### 5.1 Runtime Configuration

All OTP task configuration is read from `Application.get_env(:gtfs_planner, key)` at runtime, sourced from environment variables with platform-appropriate fallbacks (`config/runtime.exs:39-110`).

### 5.2 Task Invocation Requirements

**OTP check task requires:**
- Only configuration loaded (`Mix.Task.run("app.config")`) — lighter weight than `app.start`
- `java_path` configured in Application env
- `otp_jar_path` and `otp_osm_path` configured

**OTP install task requires:**
- Full application start (`Mix.Task.run("app.start")`)
- Same config as check, plus target directories writable
- Network access to download URLs

### 5.3 Error Handling Patterns

- Download failures: `Mix.raise/1` with HTTP status or error reason
- Checksum mismatch: `Mix.raise/1`
- Invalid options: Print invalid args, print usage, `System.halt(1)`

### Evidence: Configuration and Operability

- `lib/mix/tasks/gtfs/otp/install.ex:46-50` — invalid args handling
- `lib/mix/tasks/gtfs/otp/install.ex:93-105` — `fetch_env_path!/2` raises on missing config
- `lib/mix/tasks/gtfs/otp/install.ex:139-141` — `Mix.raise` on download failure
- `lib/mix/tasks/gtfs/otp/install.ex:164-166` — `Mix.raise` on checksum mismatch
- `lib/mix/tasks/gtfs/otp/check.ex:25` — `Mix.Task.run("app.config")` (lighter than `app.start`)

---

## 6. Business Rules

### 6.1 OTP Prerequisites Rules

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
| Download HTTP error | Delete .part file, `Mix.raise/1` | crash |
| Download network error | Delete .part file, `Mix.raise/1` | crash |
| Checksum mismatch | `Mix.raise/1` | crash |
| Missing required config | `Mix.raise/1` from `fetch_env_path!/2` | crash |
| Prerequisites check failures | Report summary, `System.halt(1)` unless `--warn-only` | 1 or 0 |

### 7.2 Key Differences Between Tasks

- `otp.install` uses `Mix.raise/1` for unrecoverable errors (download failure, checksum mismatch).
- `otp.check` uses `System.halt/1` for check failures (unless `--warn-only`).

### Evidence: Error Handling

- `lib/mix/tasks/gtfs/otp/install.ex:139-146` — download error handling with Mix.raise
- `lib/mix/tasks/gtfs/otp/install.ex:164-166` — checksum mismatch with Mix.raise
- `lib/mix/tasks/gtfs/otp/check.ex:50-52` — conditional halt based on warn_only

---

## 8. Data Models

### 8.1 OTP Prerequisites Report

```elixir
%{
  checks: [%{name: atom(), ok?: boolean(), message: String.t()}],
  errors: non_neg_integer()
}
```

Five named checks: `:java`, `:otp_dir`, `:otp_jar`, `:otp_osm`, `:heap`.

### Evidence: Data Models

- `lib/gtfs_planner/otp/prerequisites.ex:9-10` — check_result and result types
- `lib/gtfs_planner/otp/prerequisites.ex:16-24` — five named checks

---

## 9. Known Issues and Technical Debt

### 9.1 Config Validation is Bypassable

In `otp.check` and `otp.install`, the `fetch_env_path!/2` function requires config to be set and absolute. However, the task starts with `Mix.Task.run("app.config")` (check) or `Mix.Task.run("app.start")` (install), so runtime.exs must be loaded. If env vars are missing and fallbacks are used, the non-prod defaults may not reflect the actual environment intent.

### 9.2 No Test Coverage for Mix Tasks

The OTP install/check tasks have no direct test coverage — they are tested only through `Prerequisites` module tests and integration via OTP runtime/preflight tests.

---

## 10. Assumptions and Risks

### 10.1 Assumptions

1. **Network availability:** `otp.install` assumes the configured download URLs are reachable. No retry logic or proxy support.
2. **File permissions:** `otp.install` assumes write permissions in the target directories. `ensure_parent_dir!/1` uses `File.mkdir_p!` which raises on permission errors.
3. **Java binary:** `otp.check` assumes `java -version` outputs version info in a parseable format. Unusual JVM distributions may produce output that doesn't match the regex.
4. **System memory detection:** `otp.check` only supports Darwin (via `sysctl hw.memsize`) and Linux (via `/proc/meminfo`). Other platforms silently skip the "heap fits in RAM" check.

### 10.2 Risks

1. **Jar download integrity without checksum:** If `OTP_JAR_SHA256` is not configured, the downloaded jar is not verified. A corrupted or tampered download would go undetected.
2. **Download temp file leakage:** On certain failure paths (e.g., process kill during download), the `.part` temp file may not be cleaned up. The next run deletes it before downloading, but disk space may be wasted between runs.

### Evidence: Assumptions and Risks

- `lib/gtfs_planner/otp/prerequisites.ex:207-243` — system_memory_bytes only supports darwin/linux
- `lib/mix/tasks/gtfs/otp/install.ex:130-131` — temp file management with `File.rm` before download
- `lib/mix/tasks/gtfs/otp/install.ex:150-170` — checksum verification only if configured

---

## Summary

| Metric | Value |
|---|---|
| Files analyzed | 2 source + 1 support module |
| Mix tasks | 2 (OTP) |
| Total lines | ~350 (tasks) + ~274 (Prerequisites) |
| External HTTP calls | 2 (jar download, osm download via Req) |
| Database operations | 0 |
| Config keys read | 5 |
| Direct tests | 0 (none for Mix tasks specifically) |
| Indirect tests | Prerequisites via OTP integration tests |
| Hardcoded defaults | OTP jar URL, OSM extract URL (Philadelphia), min_heap 4G, min_java 21 |
