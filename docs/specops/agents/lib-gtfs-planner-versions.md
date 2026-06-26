# GTFS Versions Context Agent Doc

Source target: `lib-gtfs-planner-versions`
Scope: Manages named GTFS dataset versions within each organization and provides version lookup and dropdown data.
Deep analysis: [`docs/specops/analysis/lib-gtfs-planner-versions.md`](../analysis/lib-gtfs-planner-versions.md)
Freshness: `source_hash=sha256:56420ee93518cd639fa734067d990c4f518dfb4f447f3be993a4d9841c632db0`, `last_synthesized=2026-06-26`

## Use When
- Creating or updating GTFS version names for an organization
- Fetching versions for dropdown/select components
- Looking up the latest version (default version for session)
- Understanding how versions anchor imported GTFS data (stops, routes, pathways, etc.)
- Changing version-related validation or uniqueness rules

## Read First
- `lib/gtfs_planner/versions.ex` (64 lines) — public context API: all CRUD, list, dropdown, and lookup functions
- `lib/gtfs_planner/versions/gtfs_version.ex` (62 lines) — Ecto schema + changeset pipeline with all validation rules

## Interfaces

**Upstream callers**: `GtfsPlanner.Organizations` (org creation), `GtfsPlanner.Accounts` (bootstrap), web layer plugs/LiveViews (session version selection)

**Public functions** (all in `GtfsPlanner.Versions`):
- `create_gtfs_version(org_id, attrs)` → `{:ok, GtfsVersion} | {:error, Changeset}` — `org_id` set programmatically, NOT cast from attrs
- `create_default_version(org_id)` → `{:ok, GtfsVersion} | {:error, Changeset}` — creates version named `"First Version"`
- `update_gtfs_version(%GtfsVersion{}, attrs)` → `{:ok, GtfsVersion} | {:error, Changeset}` — requires struct, not ID
- `change_gtfs_version(%GtfsVersion{}, attrs \\ %{})` → `Changeset` — for form rendering
- `list_gtfs_versions(org_id)` → `[GtfsVersion]` — ordered `inserted_at ASC` (oldest first)
- `list_gtfs_versions_for_dropdown(org_id)` → `[{id, name}]` — ordered `inserted_at DESC` (most recent first), returns `[]` when empty
- `get_latest_gtfs_version(org_id)` → `{:ok, GtfsVersion} | {:error, :no_versions}` — uses ok/error tuple, NOT nil
- `get_gtfs_version(id)` → `GtfsVersion | nil` — global lookup by PK, NOT org-scoped
- `get_gtfs_version!(id)` → `GtfsVersion` — raises `Ecto.NoResultsError`

**No `delete_gtfs_version` function exists.** Versions are cascade-deleted only when org is deleted.

## Rules & Invariants
- Version names are unique **per organization** (not globally) — enforced by DB index `gtfs_versions_organization_id_name_index`
- Name validation pipeline (order matters): cast → trim → validate_required → validate_length(min: 1, max: 255) → unsafe_validate_unique → unique_constraint
- `organization_id` is NEVER in the cast list — always set programmatically on the struct before changeset
- Trimming runs BEFORE validate_required, so whitespace-only names become `""` and fail "can't be blank"
- `"First Version"` name is hardcoded, not configurable
- This context does NOT track "current" or "active" version state — version switching is web-layer responsibility
- No PubSub broadcasting from this context; upstream callers (Organizations, Accounts) handle their own broadcasts
- Organization creation wraps default version creation in a `Repo.transaction` — version failure rolls back org insert

## State, I/O & Side Effects
- **State**: Stateless context module — all state lives in the `gtfs_versions` DB table
- **DB writes**: `Repo.insert/1` (create), `Repo.update/1` (update) — no deletes
- **DB reads**: `Repo.all/1`, `Repo.one/1`, `Repo.exists?/1` — all scoped by `organization_id` except `get_gtfs_version/1` and `get_gtfs_version!/1`
- **Side effects**: None. No PubSub, no email, no HTTP calls
- **FK anchor**: `gtfs_version_id` is referenced by stops, routes, pathways, levels, validation_runs, walkability_tests, walkability_suites, station_editing_statuses
- **Organization FK**: `on_delete: :delete_all` — deleting an org cascades to delete all its versions and all downstream GTFS data
- **No environment-specific config** — behavior is uniform across dev/test/prod

## Failure Modes
- **Duplicate name in same org**: Returns `{:error, changeset}` with message "A version with this name already exists" (in-memory check via `unsafe_validate_unique` + DB-level `unique_constraint`)
- **Duplicate name race condition**: If in-memory check passes but DB catches it, `unique_constraint/3` converts DB error to changeset error (constraint name passed explicitly: `gtfs_versions_organization_id_name_index`)
- **Nil/blank/whitespace name**: Trim → `""` → "can't be blank" error
- **Name > 255 chars**: "should be at most 255 character(s)" error
- **No versions for org**: `get_latest_gtfs_version/1` returns `{:error, :no_versions}` (not nil)
- **Missing version by ID**: `get_gtfs_version/1` returns `nil`; `get_gtfs_version!/1` raises `Ecto.NoResultsError`
- **Calling `update_gtfs_version/2` with an ID instead of struct**: Function pattern-matches `%GtfsVersion{}`, so will raise `FunctionClauseError`

## Change Checklist
- [ ] If adding a field: update schema, changeset cast list, migration — `organization_id` stays out of cast
- [ ] If adding validation: mind the pipeline order — trim runs first, whitespace-only values are caught
- [ ] If adding a unique constraint: DB migration first, then `unique_constraint/3` with explicit constraint name in changeset
- [ ] If changing the default version name: it's hardcoded in `create_default_version/1` (`lib/gtfs_planner/versions.ex:68`); update Organizations and Accounts callers if they depend on the name
- [ ] If adding a delete function: assess cascade implications — versions anchor stops, routes, pathways, levels, validation_runs, and walkability_tests
- [ ] If changing `get_latest_gtfs_version/1` return shape: all web-layer callers expect `{:ok, _} | {:error, :no_versions}` tuple
- [ ] Test file: `test/gtfs_planner/versions_test.exs` (324 lines, ~22 tests, all scenarios covered)
- [ ] Test fixture: `test/support/fixtures/versions_fixtures.ex` — uses `System.unique_integer()` for unique names
- [ ] No PubSub to add unless upstream patterns change; current broadcasts come from Organizations context
- [ ] Run `mix test test/gtfs_planner/versions_test.exs` for unit tests

## Escalate To Deep Analysis
- Full migration history and dedup strategy: deep analysis §10 (Database Schema)
- Complete test inventory with assertions: deep analysis §11
- Dependency graph (upstream callers, downstream FK consumers): deep analysis §7
- Version switching web-layer patterns: deep analysis §4.2
- Data flow for version assignment to dependent entities during import: deep analysis §4.3
