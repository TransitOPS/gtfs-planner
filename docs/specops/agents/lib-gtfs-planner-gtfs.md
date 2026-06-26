# GTFS Data Context Agent Doc

Source target: `lib-gtfs-planner-gtfs`
Scope: Owns the organization/version-scoped GTFS schemas, queries, edits, imports, exports, station modeling, pathways, diagrams, and change-log behavior.
Deep analysis: [`docs/specops/analysis/lib-gtfs-planner-gtfs.md`](../analysis/lib-gtfs-planner-gtfs.md)
Freshness: `source_hash=sha256:db91a4a831875e9079833eace0076c27fed55b72907a60230c212f41e977b9dc`, `last_synthesized=null`

## Use When
- Adding/modifying any GTFS schema, changeset, or query
- Changing import (CSV/ZIP parsing, batch insert, diff engine) or export (CSV writer, stream builder, ZIP creation)
- Modifying station management: stop/level/pathway CRUD, cascade renames, station naming, editing-status locks
- Changing floorplan/diagram logic: diagram coordinates, stop-level scale/alignment, coordinate transforms, alignment inference
- Changing station report modules (connectivity, data quality, GPS, naming, pathway completeness)
- Modifying the change log, audit context, or rollback machinery
- Changing graph primitives or traversal calculation
- Working on the GTFS validator integration

## Read First
- `lib/gtfs_planner/gtfs.ex` — central context module with all public API functions (routes, stops, levels, pathways, naming, change log, etc.)
- `lib/gtfs_planner/gtfs/stop.ex` — most complex schema: diagram_coordinate map, parent_station string ref, cascade logic for ID renames
- `lib/gtfs_planner/gtfs/stop_level.ex` — alignment/scale/calibration schema with all-or-none validations and pure transform functions
- `lib/gtfs_planner/gtfs/import.ex` — import orchestration: archive expansion, file categorization, two-phase insert
- `lib/gtfs_planner/gtfs/import/batch_processor.ex` — batch insert engine shared by import (Repo.insert_all, no changesets)
- `lib/gtfs_planner/gtfs/import/row_parser.ex` — custom CSV parser + 30+ per-file `*_row_to_attrs` functions
- `lib/gtfs_planner/gtfs/export.ex` — export to ZIP/directory, file specs, stream builder, CSV writer
- `lib/gtfs_planner/gtfs/station_report2/` — connectivity, data quality, GPS, naming, and pathway field completeness checks

## Interfaces
**Inbound** (who calls this target):
- LiveView modules — station edits, route lists, pathway edits, station reports, import/export UI, validation UI
- `GtfsPlanner.Validations` — validation run lifecycle (column `gtfs_version_id`)
- `GtfsPlanner.Otp.Lifecycle` — OTP materialization (calls `Export.export_specs_to_directory/4`)
- `GtfsPlanner.Import` / `GtfsPlanner.Export` — orchestrating modules

**Outbound** (what this target calls):
- `GtfsPlanner.Repo` — primary Ecto repository (pervasive)
- `GtfsPlanner.PubSub` — broadcasts for stops, levels, pathways, stop_levels mutations
- `GtfsPlanner.Organizations.Organization` — belongs_to on every schema
- `GtfsPlanner.Versions.GtfsVersion` — belongs_to on most schemas
- `GtfsPlanner.Accounts.User` — actor_id on ChangeLog, user_id on StationEditingStatus
- `GtfsPlanner.ChangesetHelpers` — `trim_string_fields/2` used in every schema changeset
- External: `Ecto`, `Jason`, `:zip`, `:math`, `Decimal`, `Logger`

## Rules & Invariants
- **Multi-tenant**: every query filters on `organization_id` AND `gtfs_version_id`; no cross-tenant access
- **Natural key uniqueness**: all within `(organization_id, gtfs_version_id)` scope; composite keys for stop_times, shapes, transfers, stop_levels, etc.
- **String foreign keys**: stops/pathways/levels reference each other by GTFS string IDs (`stop_id`, `level_id`, `pathway_id`), NOT database UUIDs; no DB-level FK constraints between these tables
- **UUID primary keys**: all schemas use `@primary_key {:id, :binary_id, autogenerate: true}`, `@foreign_key_type :binary_id`
- **Validation ranges**: stop_lat [-90,90], stop_lon [-180,180], location_type [0,4], wheelchair_boarding [0,2], pathway_mode [1,7], transfer_type [0,5], direction_id {0,1}, etc.
- **Conditional**: route must have short_name or long_name; stop.level_id required when parent_station is set (except imports); StopLevel scale fields all-or-none; alignment fields all-or-none
- **Reference cascades**: stop_id rename cascades to 8 dependent tables; level_id rename cascades to 2; all in single Ecto.Multi transaction
- **Import phases**: Phase 1 (single transaction, small files); Phase 2 (batch-level transactions, stop_times/shapes); extensions best-effort
- **Import safety caps**: max 10,000 ZIP entries, 500MB total/500MB per entry; no nested archives; hidden files ignored
- **Export**: runs within single DB transaction for consistent snapshot; streams 1000-row batches; temp dir always cleaned up
- **Change log**: insert-only (no updated_at); failures logged, mutations proceed regardless; entity_type ∈ {stop, pathway, level}; action ∈ {created, updated, deleted, rolled_back}
- **Rollback**: identity fields preserved; only "updated"/"rolled_back" actions rollbackable; organization+version guard
- **Station editing**: pessimistic `pg_advisory_xact_lock`; upsert via `on_conflict`; broadcast on set/clear
- **Alignment inference**: minimum 3 anchors; RMSE >2.0m → rejected; uses 2-pass solve with cosine latitude correction
- **Diagram coordinates**: width-normalized SVG viewBox (0-100 X, proportional Y); stored as `jsonb` map `%{x, y}`

## State, I/O & Side Effects
- **Database**: 35 Ecto schemas across 29+ tables; all scoped to org+version; foreign-key string refs (not UUID FKs) for GTFS inter-table references
- **PubSub broadcasts**: global topics ("stops", "levels", "pathways", "stop_levels") — NOT namespaced by org/version. All connected clients receive all mutations. Broadcast failures logged, never raised.
- **File system**: import reads ZIP/CSV uploads; export writes temp files + ZIP; extensions reads/writes diagram images via configured `uploads_path` with path traversal guards
- **Java validator**: spawns external CLI process; reads `report.json` output; requires configured `:gtfs_validator_path`
- **Advisory locks**: PostgreSQL `pg_advisory_xact_lock(hashtext(topic))` for station editing status
- **Logging**: Logger used in context, import, export, extensions; change log failures logged silently

## Failure Modes
- **No DB-level referential integrity** between stops/pathways/levels — cascade must explicitly update all dependent tables; missing a table = stale references
- **Import Phase 2 partial commits** — batch-level transactions mean earlier batches persist when later ones fail; no cross-batch rollback
- **Global PubSub topics** — mutation events leak across org/version boundaries; all connected clients notified
- **No transaction isolation** for station-level read patterns — `list_levels_for_station` runs multiple un-wrapped queries; concurrent writes produce inconsistent results
- **Change log rollback serialization** — Decimal values stored as strings via `Decimal.to_string/1` but rollback passes strings directly to changesets without re-parsing to Decimal
- **Export lookup maps stub** — `build_lookup_maps/2` returns `%{}`; UUID-to-string resolution for export is not implemented
- **Floorplan convergence** — 2-pass alignment solve may not converge at extreme latitudes
- **Silent coordinate skips** — `derive_child_stop_coords` silently omits stops with nil or malformed diagram_coordinates
- **CSV parser silently skips** malformed lines and wrong-field-count rows; no error reporting for these

## Change Checklist
When modifying this target:
- [ ] Does the new query filter on both `organization_id` AND `gtfs_version_id`?
- [ ] Does a stop_id/level_id rename cascade need a new dependent table added to `update_schema_field_values`?
- [ ] Are PubSub broadcasts appropriate (global topics vs. org/version-scoped)?
- [ ] Does a new schema require `trim_string_fields` in its changeset?
- [ ] Does import need a new `*_row_to_attrs` parser in RowParser? Is the file in Phase 1 or Phase 2?
- [ ] Does export need a new FileSpec entry?
- [ ] Does a new stop/pathway/level mutation need a `record_change/5` call?
- [ ] Are change log identity_fields and reversible_fields updated for new entity types?
- [ ] For floorplan work: are alignment/scale all-or-none constraints maintained?
- [ ] For batch insert: are row indices correctly tracked for error reporting?
- [ ] Are natural key uniqueness constraints in place (DB-level unique_index)?

## Escalate To Deep Analysis
- When adding a new schema or entity type not covered here
- When modifying the import diff engine or changing dependency tracking behavior
- When changing the station report check inventory or thresholds
- When the full list of 30+ import file types or 16 export file specs is needed
- When detailed validation ranges for all GTFS fields are required
- When the anchor selection rules for alignment inference need modification
- When changing the two-phase phase boundary (which tables go in which phase)
