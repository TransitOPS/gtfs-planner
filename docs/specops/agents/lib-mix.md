# Mix Maintenance Tasks Agent Doc

Source target: `lib-mix`
Scope: Operator Mix tasks for installing and checking local OTP assets.
Deep analysis: [`../analysis/lib-mix.md`](../analysis/lib-mix.md)
Freshness: `source_hash=null`, `last_synthesized=null`

## Use When
- Changing OTP artifact download, checksum verification, or prerequisite checks.
- Adjusting CLI argument parsing, error handling, or exit-code behavior for any Mix task in this target.
- Adding instrumentation, logging, or dry-run modes to operator tooling.

## Read First
- `lib/mix/tasks/gtfs/otp/install.ex` — OTP artifact download with streaming Req, OptionParser, checksum, dry-run.
- `lib/gtfs_planner/otp/prerequisites.ex` — shared check logic (Java 21, jar/osm files, heap) consumed by both OTP tasks.

## Interfaces

### CLI
- `mix gtfs.otp.install [--jar-url] [--osm-url] [--force] [--skip-check] [--dry-run]`.
- `mix gtfs.otp.check [--create-dir] [--warn-only]`.

### Internal Dependencies
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

### OTP Tasks
- **R16:** Java 21+ required. Parses `java -version` output with regex `/version\s+"(?<version>[^"]+)"/`.
- **R17–R20:** OTP dir must exist. Jar must be absolute `.jar`, readable. OSM must be absolute `.pbf`, readable. Heap must be >=4GB and <= detected system RAM.
- **R21:** Jar checksum verified only if `OTP_JAR_SHA256` is configured; mismatch → `Mix.raise`.
- **R22:** Downloads use `.part` temp file; deleted before download and on failure; renamed only on HTTP 2xx.
- **R23–R25:** `--dry-run` prints plan only. `--force` re-downloads. `--warn-only` exits 0 even if checks fail.

## State, I/O & Side Effects
- **Reads:** Environment variables for OTP config. Application config via `Application.get_env/2`.
- **Writes:** Downloaded jar/osm files to `priv/otp/`.
- **Side effects:** `Mix.Task.run("app.start")` (install) or `Mix.Task.run("app.config")` (check) boots OTP app. `Mix.raise/1` on unrecoverable OTP errors. ANSI-colored output (assumes ANSI terminal).
- **No global mutable state.** Tasks are single-run CLI invocations.

## Failure Modes
- **Download/network failures:** Delete `.part` temp file, `Mix.raise/1`.
- **Checksum mismatch:** `Mix.raise/1`.
- **Missing required config:** `Mix.raise/1` from `fetch_env_path!/2`.

## Change Checklist
- Modify OTP prerequisites? Update `lib/gtfs_planner/otp/prerequisites.ex`; both `otp.install` and `otp.check` consume it.
- Add a new OTP config key? Add to `config/runtime.exs` and both `fetch_env_path!/2` callers in install.ex and check.ex.
- After changes, run `mix precommit`.

## Escalate To Deep Analysis
- Detailed file:line evidence for every rule, interface, and error handling category.
- Known issues and technical debt inventory (zero direct tests for the OTP tasks).
- Risks (checksum bypass, temp file leakage, unreachable download URLs).
- Full System.cmd/3 calls and platform-specific memory detection (Darwin/Linux only).
