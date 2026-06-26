# GTFS Data Context — SpecOps Analysis

- **Target slug**: `lib-gtfs-planner-gtfs`
- **Structural unit**: `lib/gtfs_planner/gtfs`
- **Source hash**: `sha256:9b70aac58b9eba14b656e2a8dcb55c03aaac2ea40eb5add068500b47467568a5`
- **Analysed at**: 2026-06-26
- **Coverage**: 65 source files (35 schemas, 1 main context, 29 submodules)

---

## 1. Target Overview

`GtfsPlanner.Gtfs` is the central context module for all GTFS data within the application. It owns the organization/version-scoped Ecto schemas for every GTFS-compliant table (stops, routes, trips, stop_times, calendars, shapes, pathways, levels, fares, transfers, etc.) plus application-specific schemas (route_patterns, stop_levels, station_editing_statuses, change_logs, stop_areas), along with pure-logic modules for graph traversal, coordinate transforms, alignment inference, pathway length calculations, station naming conventions, station report generation, and import/export pipelines.

The module is scoped per `(organization_id, gtfs_version_id)` tuple throughout — every schema carries these two foreign keys and all queries filter on both, enforcing multi-tenant isolation via the `GtfsVersion` abstraction derived from `GtfsPlanner.Versions.GtfsVersion`.

---

## 2. Boundary & Dependencies

### 2.1 Inbound dependencies (what calls into this target)

- LiveView modules in `lib/gtfs_planner_web/live/` — station edit forms, route lists, pathway edit forms, station reports, import/export UI, validation UI
- `GtfsPlanner.Validations` — validation run lifecycle (column `gtfs_version_id` on validation tables)
- `GtfsPlanner.Otp.Lifecycle` — OTP materialization (calls `Export.export_specs_to_directory/4`)
- `GtfsPlanner.Import` — presumably orchestrates imports (may alias `Gtfs.Import`)
- `GtfsPlanner.Export` — orchestrates exports
- `GtfsPlanner.Walkability` tests — references stop_id with `gtfs_version_id`

### 2.2 Outbound dependencies (what this target calls)

- `GtfsPlanner.Repo` — primary Ecto repository (used pervasively)
- `GtfsPlanner.PubSub` — Phoenix PubSub for real-time broadcasts
- `GtfsPlanner.Organizations.Organization` — belongs_to association on every schema
- `GtfsPlanner.Versions.GtfsVersion` — belongs_to association on most schemas
- `GtfsPlanner.Accounts.User` — `StationEditingStatus` belongs_to and actor_id on `ChangeLog`
- `GtfsPlanner.Validations.WalkabilityTest` — referenced in stop_id reference cascade counts
- `GtfsPlanner.ChangesetHelpers` — `trim_string_fields/2` used in every schema changeset
- `GtfsPlanner.Otp.Lifecycle` — artifact purge after successful validation

### 2.3 External dependencies (libraries)

- `Ecto`, `Ecto.Query`, `Ecto.Changeset`, `Ecto.Multi`
- `Phoenix.PubSub`
- `Req` (HTTP client — available, though not directly used here)
- `Jason` — JSON encoding in extensions manifest
- `:zip` (Erlang) — ZIP archive read/write in import/export
- `:math` (Erlang) — trigonometry in floorplan transform, alignment inference, haversine
- `Decimal` — coordinate precision, price, distance calculations
- Logger — `require Logger` in context, import, export, extensions

---

## 3. Data Models (Ecto Schemas)

All schemas use `@primary_key {:id, :binary_id, autogenerate: true}` and `@foreign_key_type :binary_id` (UUID v7). Every schema belongs to `GtfsPlanner.Organizations.Organization` (via `:organization_id`) and is scoped by `:gtfs_version_id` (either as a proper `belongs_to` association or a bare `:binary_id` field).

### 3.1 Core GTFS Schemas

| Schema | Table | Natural Key | Key Validation |
|--------|-------|-------------|----------------|
| `Gtfs.Agency` | `agencies` | `agency_id` | `unique_constraint [:organization_id, :gtfs_version_id, :agency_id]` |
| `Gtfs.Route` | `routes` | `route_id` | `unique_constraint [:organization_id, :gtfs_version_id, :route_id]` |
| `Gtfs.Trip` | `trips` | `trip_id` | `unique_constraint [:organization_id, :gtfs_version_id, :trip_id]` |
| `Gtfs.StopTime` | `stop_times` | `trip_id + stop_sequence` | `unique_constraint [:org, :version, :trip_id, :stop_sequence]` |
| `Gtfs.Calendar` | `calendars` | `service_id` | `unique_constraint [:org, :version, :service_id]` |
| `Gtfs.CalendarDate` | `calendar_dates` | `service_id + date` | `unique_constraint [:org, :version, :service_id, :date]` |
| `Gtfs.Shape` | `shapes` | `shape_id + shape_pt_sequence` | `unique_constraint [:org, :version, :shape_id, :shape_pt_sequence]` |
| `Gtfs.Frequency` | `frequencies` | `trip_id + start_time` | `unique_constraint [:org, :version, :trip_id, :start_time]` |
| `Gtfs.Transfer` | `transfers` | composite 8 fields | `unique_constraint` on `[:org, :version, :from_stop_id, :to_stop_id, :from_route_id, :to_route_id, :from_trip_id, :to_trip_id]` |
| `Gtfs.FeedInfo` | `feed_info` | singleton per org+version | `unique_constraint [:org, :version]` |

### 3.2 Fare Schemas

| Schema | Table | Natural Key |
|--------|-------|-------------|
| `Gtfs.FareAttribute` | `fare_attributes` | `fare_id` |
| `Gtfs.FareRule` | `fare_rules` | composite `[fare_id, route_id, origin_id, destination_id, contains_id]` |
| `Gtfs.FareMedia` | `fare_media` | `fare_media_id` |
| `Gtfs.FareProduct` | `fare_products` | `fare_product_id + fare_media_id` |
| `Gtfs.FareLegRule` | `fare_leg_rules` | composite `[network_id, from_area_id, to_area_id, fare_product_id]` |
| `Gtfs.FareLegJoinRule` | `fare_leg_join_rules` | composite `[from_network_id, to_network_id, from_stop_id, to_stop_id]` |
| `Gtfs.FareTransferRule` | `fare_transfer_rules` | composite `[from_leg_group_id, to_leg_group_id, fare_product_id, transfer_count]` |

### 3.3 Station & Pathway Schemas

| Schema | Table | Natural Key | Notes |
|--------|-------|-------------|-------|
| `Gtfs.Stop` | `stops` | `stop_id` | `location_type` validates 0-4. Has `parent_station` (string ref), `level_id` (string ref), `diagram_coordinate` (map `%{x, y}`). Virtual field `:level` for preloaded level data via `select_merge`. `stop_id + stop_name + stop_desc + platform_code` are validated and may be cascaded on rename. |
| `Gtfs.Level` | `levels` | `level_id` | `level_index` is float. Has unique index named `levels_organization_id_gtfs_version_id_level_id_index`. |
| `Gtfs.Pathway` | `pathways` | `pathway_id` | Has `from_stop_id` and `to_stop_id` (string refs to stops, NOT UUID). `pathway_mode` validates 1-7. Virtual fields `from_stop` and `to_stop` (populated via `select_merge`). Has module attribute `@pathway_modes` mapping atoms to ints. |
| `Gtfs.StopLevel` | `stop_levels` | `stop_id + level_id` | Join table linking stops to levels with diagram calibration (scale points, distance, ratio) and floorplan alignment fields (`floorplan_center_lat/lon`, `floorplan_scale_mpp`, `floorplan_rotation_deg`). Has `alignment_transform/1`, `invert_alignment_transform/1`, `compose_alignment_transforms/2`, `active_alignment_delta/2` pure functions. Two changesets: `changeset/2`, `scale_changeset/2`, `alignment_changeset/2`. |
| `Gtfs.StopArea` | `stop_areas` | `area_id + stop_id` | Maps areas to stops. |

### 3.4 MBTA-Extension Schemas

| Schema | Table | Natural Key | Notes |
|--------|-------|-------------|-------|
| `Gtfs.RoutePattern` | `route_patterns` | `route_pattern_id` | `route_pattern_typicality` validates 0-5, `canonical_route_pattern` validates 0-2, `direction_id` validates 0-1. Has `representative_trip_id` string. |
| `Gtfs.RouteNetwork` | `route_networks` | `network_id + route_id` | Maps networks to routes. |

### 3.5 Supplementary Schemas

| Schema | Table | Natural Key |
|--------|-------|-------------|
| `Gtfs.Area` | `areas` | `area_id` |
| `Gtfs.Attribution` | `attributions` | `attribution_id` (optional, can be nil) |
| `Gtfs.BookingRule` | `booking_rules` | `booking_rule_id` |
| `Gtfs.Location` | `locations` | `location_id` |
| `Gtfs.Network` | `networks` | `network_id` |
| `Gtfs.RiderCategory` | `rider_categories` | `rider_category_id` |
| `Gtfs.Timeframe` | `timeframes` | composite `[timeframe_group_id, start_time, end_time, service_id]` |
| `Gtfs.Translation` | `translations` | composite `[table_name, field_name, language, record_id, record_sub_id, field_value]` |

### 3.6 Application Schemas

| Schema | Table | Purpose |
|--------|-------|---------|
| `Gtfs.ChangeLog` | `change_logs` | Immutable audit trail. Fields: `entity_type` ("stop"/"pathway"/"level"), `entity_id` (UUID), `entity_external_id` (string), `station_stop_id`, `actor_id`, `actor_email`, `snapshot` (map), `changed_fields` (map), `action` ("created"/"updated"/"deleted"/"rolled_back"), `rolled_back_to_log_id` (self-referential). No `updated_at` timestamps (insert-only). |
| `Gtfs.StationEditingStatus` | `station_editing_statuses` | Pessimistic lock for single-user station editing. Fields: `station_id`, `user_id`, `started_at`. Unique on `[:org, :version, :station_id]`. No `updated_at` timestamp. Uses advisory transaction lock (`pg_advisory_xact_lock`). |
| `Gtfs.AuditContext` | (struct, not a schema) | Bundles audit parameters: `organization_id`, `gtfs_version_id`, `station_stop_id`, `actor_id`, `actor_email`. Used as single argument to `record_change/5`. |

### 3.7 Validation Schemas

| Module | Purpose |
|--------|---------|
| `Gtfs.ValidatorBehaviour` | Behaviour defining the `validate/3` callback contract. |
| `Gtfs.Validator` | Concrete implementation: exports GTFS to temp ZIP, runs Java-based MobilityData GTFS Validator CLI, parses `report.json`, broadcasts progress. Implements `ValidatorBehaviour`. |
| `Gtfs.Validator.Result` | Struct with `:summary` (errors/warnings/infos count), `:notices` (grouped by code+severity), `:duration_ms`, `:validated_at`. |

---

## 4. Public API (Context Functions — `GtfsPlanner.Gtfs`)

### 4.1 Routes

- `list_routes/3` — List routes with optional filters (route_type, agency_id, active, search), sort, pagination
- `count_routes/3` — Count with same filters
- `get_route!/1` — By UUID
- `get_route_by_route_id/3` — By natural key within org+version
- `create_route/1` — Insert with changeset validation
- `list_distinct_route_types/2` — For filter dropdowns
- `list_distinct_agencies/2` — From route.agency_id
- `list_route_patterns_for_route/4` — For a specific route
- `list_routes_serving_stations/2` — Routes that serve at least one station (stop with null parent_station)

### 4.2 Stops & Stations

- `count_stops/2`, `list_stops/2` — All stops
- `get_stop/1`, `get_stop!/1` — By UUID
- `get_stop_by_stop_id/3` — By natural key
- `list_stations/3` — Stations (stops with null parent_station) with optional route_id, direction_id, wheelchair_boarding, search, sort, pagination filters
- `count_stations/3` — Count with same filters
- `create_stop/1` — With changeset (validates level_id required when parent_station is set)
- `import_create_stop/1` — Permissive import changeset (no level_id requirement)
- `update_stop/2` — Standard update
- `update_stop_with_cascade/2` — When stop_id changes, cascades to all referencing tables (pathways, stop_times, transfers, stop_areas, fare_leg_join_rules, parent_stations, translations, walkability_tests)
- `import_update_stop/2` — Permissive import update
- `delete_stop/1` — Standard delete
- `delete_child_stop/5` — Deletes a child stop AND its connected pathways in a transaction, scoped to the station descendants
- `remove_child_stop_from_diagram/5` — Clears diagram_coordinate and level_id, deletes pathways
- `update_stop_diagram_coordinate/2` — Sets diagram_coordinate map
- `list_child_stops_for_parent/3` — Preloads level data via select_merge
- `list_child_stops_for_level/2` — With :on_active_level virtual field
- `list_station_scope_stop_ids/3` — Deterministic set of stop_ids including station + direct children + boarding-area grandchildren
- `get_routes_for_stops/4` — Map of stop_id to list of routes
- `unique_stop_id/4` — Generate unique stop_id with _2, _3 suffixes
- `generate_kebab_stop_id/4` — Kebab-case stop_id with -01, -02 suffixes
- `change_stop/2` — Changeset for forms

### 4.3 Levels

- `count_levels/2`, `list_levels/2`, `list_all_levels/2` — All levels
- `get_level/1`, `get_level!/1` — By UUID
- `get_level_by_level_id/3` — By natural key
- `create_level/1` — With broadcast
- `update_level/2`, `update_level_with_cascade/2` — Level rename cascades to stops.level_id and translations.record_id
- `delete_level/1` — With broadcast
- `change_level/2` — Changeset for forms
- `list_levels_for_station/3` — Hybrid approach: combines levels from child stops (stop_count) with levels from stop_levels table. Returns maps with `:level`, `:stop_count`, `:diagram_filename`, `:stop_level`.
- `remove_level_from_station/5` — Clears level_id and diagram_coordinate on child stops, deletes stop_level association

### 4.4 Stop Levels

- `list_stop_levels_for_station/3` — Ordered by level_index, then stop_levels.id
- `get_stop_level/4` — By stop_id and level_id
- `create_stop_level/1` — With broadcast
- `delete_stop_level/1` — With broadcast
- `update_stop_level_diagram/2` — Sets diagram_filename, clears calibration
- `update_stop_level_scale/2` — Updates calibration
- `update_stop_level_alignment/2`, `save_stop_level_alignment/2` — Updates floorplan alignment
- `clear_stop_level_alignment/1` — Nils out all alignment fields
- `save_and_apply_stop_level_alignment/4` — Saves alignment AND persists derived lat/lon to eligible child stops in a single transaction. Uses `FOR UPDATE` lock on the stop_level row.
- `apply_alignment_to_child_stops/3` — Derives coordinates and persists in transaction
- `derive_child_stop_coords/3` — Returns lat/lon for eligible child stops using the floorplan alignment
- `infer_level_alignment/3` — Pure inference from anchored stops + cross-level elevator pathways, no persistence
- `save_inferred_level_alignment/3` — Infers then persists
- `calculate_pathway_length/3` — SVG distance * scale_meters_per_unit for same-level pathways
- `recalculate_pathway_lengths_for_level/5` — Recalculates all same-level pathway lengths
- `save_scale_and_recalculate/5` — Saves calibration and recalculates atomically
- `clear_stop_level_scale/1` — Nils out all scale fields
- `level_used_by_other_stations?/4` — Check if level is shared across stations

### 4.5 Pathways

- `count_pathways/2`, `list_pathways/2` — All pathways
- `get_pathway/1`, `get_pathway!/1` — By UUID
- `get_pathway_by_pathway_id/3` — By natural key
- `get_pathway_with_stops!/1` — Populates from_stop and to_stop virtual fields
- `create_pathway/1` — With broadcast
- `update_pathway/2`, `delete_pathway/1` — With broadcast
- `list_pathways_for_station/3` — For a station's descendants
- `list_pathways_for_level/4` — With is_cross_level, from_on_active_level, to_on_active_level flags
- `list_pathways_for_stop/3` — Pathways touching a specific stop

### 4.6 Station Naming

- `preview_station_naming/5` — Builds naming map (structured or kebab style), computes reference counts, detects collisions. Optional `selected_ids` parameter limits preview to a subset.
- `apply_station_naming/5` — Four-phase rename in transaction: old→temp, refs→temp, temp→final, refs→final. Handles cascade to pathways, stop_times, transfers, stop_areas, fare_leg_join_rules, parent_stations, translations, walkability_tests.

### 4.7 Change Log & Audit

- `record_change/5` — Records snapshot + changed_fields for stop/pathway/level mutations. Failures are logged (not raised) — mutations proceed regardless.
- `list_change_logs_for_entity/4` — History for an entity
- `get_change_log!/1`, `get_change_log/1` — By UUID
- `rollback_entity/2` — Restores entity to snapshot state, creates "rolled_back" log entry. Validates organization+version match. Identity fields (stop_id, pathway_id, from_stop_id, to_stop_id, level_id) preserved across rollback.
- `rollback_target_snapshot/1` — Computes target state from stored snapshot + changed_fields
- `rollback_previewable_fields/1` — Returns field names that can be previewed and applied
- `identity_fields_for/1`, `reversible_fields_for/1` — Metadata about what can be rolled back
- `entity_snapshot/2` — Builds normalized snapshot for current entity

### 4.8 Station Editing Status

- `get_station_editing_status/3` — Current editing lock for a station
- `subscribe_station_editing_status/3` — PubSub subscription
- `set_station_editing_status/4` — Create or replace (upsert via on_conflict) with advisory transaction lock
- `clear_station_editing_status/3` — Remove lock with advisory transaction lock

### 4.9 Station Reports

- `get_station_report_snapshot/3` — Returns `%{station, child_stops, levels, pathways}` used as input to all report builders

### 4.10 Other CRUD

- Agencies: `count_agencies/2`, `list_agencies/2`, `get_agency!/1`, `get_agency_by_agency_id/3`, `create_agency/1`
- Areas: `list_areas/2`, `get_area!/1`, `get_area_by_area_id/3`
- Attributions: `count_attributions/2`, `list_attributions/2`, `get_attribution!/1`
- BookingRules: `list_booking_rules/2`, `get_booking_rule!/1`, `get_booking_rule_by_booking_rule_id/3`
- FareAttributes: `count_fare_attributes/2`, `list_fare_attributes/2`, `get_fare_attribute!/1`, `get_fare_attribute_by_fare_id/3`
- FareLegJoinRules: `list_fare_leg_join_rules/2`, `get_fare_leg_join_rule!/1`
- FareLegRules: `list_fare_leg_rules/2`, `get_fare_leg_rule!/1`
- FareMedia: `list_fare_media/2`, `get_fare_media!/1`, `get_fare_media_by_fare_media_id/3`
- FareProducts: `list_fare_products/2`, `get_fare_product!/1`
- FareRules: `count_fare_rules/2`, `list_fare_rules/2`, `get_fare_rule!/1`
- FareTransferRules: `list_fare_transfer_rules/2`, `get_fare_transfer_rule!/1`
- FeedInfo: `count_feed_info/2`, `get_feed_info/2`, `get_feed_info!/1`
- Frequencies: `count_frequencies/2`, `list_frequencies/2`, `get_frequency!/1`
- Locations: `list_locations/2`, `get_location!/1`, `get_location_by_location_id/3`
- Networks: `list_networks/2`, `get_network!/1`, `get_network_by_network_id/3`
- RiderCategories: `list_rider_categories/2`, `get_rider_category!/1`, `get_rider_category_by_rider_category_id/3`
- RouteNetworks: `list_route_networks/2`, `get_route_network!/1`
- Shapes: `count_shapes/2`, `list_shapes/2`, `get_shape!/1`
- StopAreas: `list_stop_areas/2`, `get_stop_area!/1`
- Timeframes: `list_timeframes/2`, `get_timeframe!/1`
- Transfers: `count_transfers/2`, `list_transfers/2`, `get_transfer!/1`
- Translations: `list_translations/2`, `get_translation!/1`
- Trips: `count_trips/2`, `create_trip/1`
- StopTimes: `count_stop_times/2`, `create_stop_time/1`
- Calendars: `count_calendars/2`
- CalendarDates: `count_calendar_dates/2`

### 4.11 File Inventory

- `get_file_inventory/3` — Returns list of `{filename, count}` for `:full` or `:pathways` export types

---

## 5. Import Contract

### 5.1 Entry Point

`GtfsPlanner.Gtfs.Import.import_files/4` is the main entry point:
```
import_files(organization_id, gtfs_version_id, files, topic \\ nil) ::
  {:ok, {counts, unrecognized_files, topic, archive_warnings}} | {:error, reason}
```

### 5.2 ZIP Archive Handling

- `expand_archives/1` expands `.zip` uploads into individual `%{filename, content}` entries
- Safety: max 10,000 entries, 500MB total uncompressed limit (configurable), 500MB per-entry limit
- Ignores: `__MACOSX/`, `._*`, `.DS_Store`, `Thumbs.db`, empty filenames, directory entries
- Rejects nested `.zip` files inside archives
- Produces `archive_warnings` list when expansion fails (never passes raw archive through)

### 5.3 File Categorization

`categorize_files/1` maps uploaded filenames (case-insensitive) to import specs:
- Standard GTFS files mapped via `@filename_to_spec` (30+ file types)
- `_pathways_extensions.json` → extensions JSON
- `_pathways_extensions/*.png` → extensions images (keyed by zip_path)
- Everything else → `unrecognized_files`
- Filename normalization strips `./`, `/` prefixes, converts backslashes

### 5.4 Two-Phase Import

**Phase 1** (single transaction):
- Processes: agencies, feed_info, levels, areas, networks, fare_media, rider_categories, booking_rules, locations, routes, calendars, calendar_dates, route_patterns, route_networks, fare_attributes, fare_rules, fare_products, timeframes, trips, stops, pathways, transfers, stop_areas, frequencies, attributions, fare_leg_rules, fare_leg_join_rules, fare_transfer_rules, translations
- Uses `BatchProcessor.insert_batched/5` — within the single transaction, batches of `@batch_size` (default 1000)
- On any error → full rollback

**Phase 2** (batch-level transactions):
- Processes: stop_times, shapes (potentially millions of rows)
- Uses `BatchProcessor.insert_batched_with_transactions/5` — each batch committed independently
- Partial data may remain on error

**Extensions Phase** (separate, after both phases):
- If `_pathways_extensions.json` is present, calls `Extensions.Import.import_extensions/4`
- On failure: logs warning, returns counts unchanged (non-fatal)

### 5.5 Batch Processing

`BatchProcessor`:
- `insert_batched/5` — chunks stream by batch_size, maps rows to attrs via parser function, inserts via `Repo.insert_all` (bypassing changesets), broadcasts progress via PubSub
- `insert_batched_with_transactions/5` — wraps each batch in its own `Repo.transaction`
- Error format: `%{file: filename, row: 1-indexed_row, reason: error_message}` for parse errors; `%{file: filename, constraint: name, message: msg}` for constraint errors
- Row index tracking: `batch_start + row_index_in_batch + 1`

### 5.6 CSV Parsing

`RowParser`:
- Custom recursive CSV parser handling quoted fields, escaped quotes (doubled), commas in quoted fields
- `parse_csv_content/1` returns a Stream of `%{"header" => "value"}` maps (lazy)
- `parse_csv_content_with_count/1` returns `{stream, total_rows}` for progress tracking
- Rows with mismatched field counts are silently skipped
- Malformed lines are silently skipped

### 5.7 Row-to-Attribute Mapping

Each `*_row_to_attrs/3` function in `RowParser`:
1. Extracts required fields via `extract_required/2`
2. Parses typed values (integers, decimals, dates, times, booleans, enums)
3. Applies defaults (e.g., route_color defaults to "FFFFFF", continuous_pickup to 1)
4. Returns `{:ok, %{attrs}}` or `{:error, reason}`

Supported parsers: `parse_float/1`, `parse_decimal/1`, `parse_integer/1`, `parse_gtfs_date/1`, `parse_gtfs_time/1`, `parse_location_type/1`, `parse_wheelchair_boarding/1`, `parse_fare_media_type/1`, `parse_fare_transfer_type/1`, `parse_duration_limit_type/1`, `parse_headway_secs/1`, `parse_exact_times/1`, `parse_transfer_type/1`, `parse_pathway_mode/1`, `parse_is_bidirectional/1`, `parse_direction_id/1`, `parse_typicality/1`, `parse_canonical_route_pattern/1`, `parse_route_type/1`, `parse_continuous_value/1`, `parse_day_flag/1`, `parse_exception_type/1`

### 5.8 Diff Engine (Station-Data)

`GtfsPlanner.Gtfs.Import.Diff`:
- Compares uploaded station data (levels, stops, pathways) against current DB records
- Uses natural keys (level_id, stop_id, pathway_id) to compute: adds, removes, modifies, conflicts
- Conflict detection: if a record has `updated_at > inserted_at` (user-edited) AND the uploaded data differs from the current DB, it is flagged as `:conflict`
- `DiffDecision` struct with `:id`, `:action`, `:entity_type`, `:natural_key`, `:current_record`, `:uploaded_attrs`, `:changed_fields`, `:user_edited`, `:status`, `:dependency_keys`, `:first_of_group`
- Dependency tracking: stops depend on levels (level_id) and parents (parent_station); pathways depend on stops (from_stop_id, to_stop_id)
- `summary/1` returns `%{add, modify, remove, conflict}` counts
- Managed per-entity-type field lists (e.g., `@stop_fields` = 10 fields, `@pathway_fields` = 11 fields)

---

## 6. Export Contract

### 6.1 Entry Points

- `Export.export_to_zip/4` → `{:ok, zip_binary}` or `{:error, reason}`
  - Creates temp directory, builds lookup maps, gets file specs for `:full` or `:pathways` export type
  - Runs within database transaction for consistent snapshot (timeout: infinity)
  - Creates ZIP from written files
  - Always cleans up temp directory
- `Export.export_specs_to_directory/4` → `{:ok, file_paths}` or `{:error, reason}`
  - Used by OTP materialization workflows
  - Disk-targeted, not ZIP

### 6.2 File Specifications

`FileSpec` defines field mappings for 16 GTFS file types:
- agency, stops, routes, trips, stop_times, calendar, calendar_dates, fare_attributes, fare_rules, shapes, frequencies, transfers, pathways, levels, feed_info, attributions
- Each spec: `%{filename, schema, fields: [{csv_name, source_atom}]}`
- `get_specs(:full)` returns all 16 specs
- `get_specs(:pathways)` returns [stops, levels, pathways]

### 6.3 CSV Writing

`CsvWriter`:
- `write_header/2` — writes CSV header from field spec
- `write_row/4` — extracts values, formats (nil→"", true→"1", false→"0", Decimal→string, Date→YYYYMMDD), escapes (quoting fields with commas/quotes/newlines, doubling internal quotes)
- Supports foreign key lookups via `lookup_maps` (UUID→GTFS string ID resolution, though current `build_lookup_maps/2` returns `%{}` — placeholder)

### 6.4 Stream Building

`StreamBuilder`:
- `stream_records/4` — Ecto streaming query with `max_rows: 1000` per batch
- Deterministic ordering: StopTime by (trip_id, stop_sequence), Shape by (shape_id, shape_pt_sequence), others by primary GTFS ID field or fallback to inserted_at/id
- `build_stop_lookup/3`, `build_level_lookup/3` — UUID→string ID maps (unused by current CSV writer)

### 6.5 ZIP Creation

- `:zip.create` with `:memory` option — builds ZIP in memory from file paths
- Extensions entries appended: `_pathways_extensions.json` manifest + diagram images from `Extensions.Export`
- Extensions export failure is non-fatal (logged, ZIP created without extensions)

---

## 7. Station Management

### 7.1 Station Hierarchy

Stations are modeled as rows in the `stops` table with `location_type = 1` and `parent_station IS NULL`. Child stops (platforms, entrances, nodes, boarding areas) reference their parent via the `parent_station` string field (not UUID — references the parent's `stop_id`).

The descendant query pattern recurs throughout the codebase:
```elixir
descendant_stop_ids_query(org, version, station_stop_id)
```
Returns: direct children (parent_station = station_stop_id) + boarding-area grandchildren (location_type=4, parent_station in direct_child_ids).

### 7.2 Stop ID Cascade

When a stop's `stop_id` is renamed via `update_stop_with_cascade/2`, the cascade updates:
1. `stops.parent_station` — other stops referencing this as parent
2. `pathways.from_stop_id` + `pathways.to_stop_id`
3. `stop_times.stop_id`
4. `transfers.from_stop_id` + `transfers.to_stop_id`
5. `stop_areas.stop_id`
6. `fare_leg_join_rules.from_stop_id` + `fare_leg_join_rules.to_stop_id`
7. `translations.record_id` (where table_name="stops")
8. `walkability_tests.stop_id`

All in a single `Ecto.Multi` transaction.

### 7.3 Level ID Cascade

When a level's `level_id` is renamed via `update_level_with_cascade/2`:
1. `stops.level_id`
2. `translations.record_id` (where table_name="levels")

### 7.4 Station Naming Convention

`StationNaming` provides two styles:

**Structured** pattern: `{station}_{type}_{feature}_{level}_{seq}`
- Station slug = slugify(station_stop_id)
- Type = location_type_slug (platform/station/entrance/node/boarding)
- Feature = highest-priority pathway mode touching the stop (priority: elevator > escalator > stairs > exit_gate > fare_gate > moving_sidewalk > walkway > "general")
- Level = slugify(level_id) or "nolvl"
- Seq = zero-padded 2-digit index within partition

**Kebab** pattern: `{kebab-name}-{seq}`
- Kebab-name = kebabify(stop_name) or kebabify(stop_id) or "stop"
- Seq = zero-padded 2-digit index

Application uses a four-phase transactional rename (old→temp, refs→temp, temp→final, refs→final) to avoid transient ID collisions.

### 7.5 Station Editing Status (Collaborative Lock)

- Pessimistic lock via `pg_advisory_xact_lock(hashtext(topic))` for the composite key
- `set_station_editing_status/4` uses `on_conflict: [set: ...]` with `conflict_target: [:org, :version, :station_id]` for upsert
- `clear_station_editing_status/3` deletes the row and broadcasts `nil` status
- PubSub topic: `"station_editing_status:#{org}:#{version}:#{station}"`

---

## 8. Floorplan & Diagram Model

### 8.1 Diagram Coordinates

Stops have a `diagram_coordinate` field (PostgreSQL `jsonb`, Elixir `:map`) storing `%{x: float, y: float}` in width-normalized SVG viewBox coordinates (0-100 range on X axis, proportional Y).

### 8.2 Stop Level Scale Calibration

`StopLevel` stores:
- `scale_point_a`, `scale_point_b` — map `%{x, y}` (0-100 range, validated)
- `scale_distance_meters` — real-world distance between the two points
- `scale_meters_per_unit` — computed ratio (meters per SVG diagram unit)
- `diagram_filename` — associated diagram image filename

`all-or-none` validation: all four scale fields must be set together or all nil.

### 8.3 Floorplan Alignment

`StopLevel` stores:
- `floorplan_center_lat` / `floorplan_center_lon` — geographic anchor
- `floorplan_scale_mpp` — meters per image pixel
- `floorplan_rotation_deg` — clockwise rotation

All four must be set together. Functions in `StopLevel`:
- `alignment_complete?/1` — guard check
- `alignment_transform/1` — extracts `%{center_lat, center_lon, scale_mpp, rotation_deg}` or `{:error, :alignment_missing/:invalid_alignment}`
- `invert_alignment_transform/1` — negates center, inverts scale, negates rotation
- `compose_alignment_transforms/2` — adds centers, multiplies scales, adds rotations
- `active_alignment_delta/2` — `T_new ∘ inverse(T_old)` for computing alignment change

### 8.4 Floorplan Transform

`FloorplanTransform.svg_to_lat_lon/4` converts SVG diagram coordinates to geographic lat/lon:
- Width-normalized units: 1 unit = `image_w/100` pixels (both axes, top-left anchored)
- Anchor = painted image center (`image_w/2`, `image_h/2`)
- Applies rotation (clockwise) about center
- Converts screen-space meters to lat/lon using `@meters_per_degree_lat` (111,111 m/deg) with cosine latitude correction
- Error conditions: `:invalid_alignment`, `:invalid_image_dims`, `:invalid_point`

### 8.5 Alignment Inference

`AlignmentInference`:
- Solves a 2D similarity transform from anchored stops
- Minimum 3 anchors required
- Sources: direct (stops with diagram_coordinate AND GPS coords) + cross-level (elevator pathways to stops on other levels with GPS coords)
- Anchor selection rules (`select_anchors/2`):
  - Direct candidates excluded if: nil coordinate, nil lat/lon
  - Cross-level candidates excluded if: non-elevator mode, nil coordinate, nil lat/lon, shadowed by direct candidate for same stop_id, lost tie-break (within-group tie-break selects lowest `|level_index_delta|` then alphabetically by pathway_id)
- Rejects: `:insufficient_anchors` (<3), `:degenerate_geometry` (spread < 1e-6), `:high_residual` (RMSE > 2.0m)
- Returns: `%{center_lat, center_lon, scale_mpp, rotation_deg, rmse_meters, anchor_count}`

### 8.6 Save-and-Apply Flow

`save_and_apply_stop_level_alignment/4`:
1. Validates image dimensions
2. In transaction: loads stop_level with `FOR UPDATE` lock, saves new alignment, derives child coordinates, persists to stop_lat/stop_lon
3. Broadcasts stop_levels:updated and stops:updated events

---

## 9. Graph & Traversal Model

### 9.1 Graph Primitives (`GtfsPlanner.Gtfs.Graph`)

Pure graph functions, no Repo/DB dependencies:
- `build_directed_adjacency/1` — Bidirectional pathways produce edges in both directions
- `build_step_free_directed_adjacency/1` — Filtered to walkway, moving_sidewalk, elevator, fare_gate, exit_gate (modes 1,3,5,6,7)
- `build_undirected_adjacency/1` — All edges bidirectional
- `build_path_traversal_adjacency/1` — Enriched edges with pathway_id and pathway_mode
- `build_step_free_path_traversal_adjacency/1` — Step-free variant
- `build_platform_target_index/1` — Maps platform stop_ids to sets of {platform_id, boarding_area_ids}
- `bfs/2` — BFS returning reachable stop_ids set
- `reachable?/3` — Boolean reachability check
- `shortest_directed_path_to_any/3` — BFS shortest path to any member of target set, returns `{:found, [hop]}` or `:not_found`

### 9.2 Traversal Calculator (`GtfsPlanner.Gtfs.TraversalCalculator`)

Estimates traversal time for a pathway segment based on mode and available metadata:
- Default modes: uses traversal_time if set, else length / walking_speed (1.33 m/s), else stair_count * 0.4m / walking_speed, else 0
- Escalators (mode 4): traversal_time or length / escalator_speed (0.45 m/s)
- Elevators (mode 5): traversal_time or (board_slack(90s) + level_diff * hop_time(20s)) or (board_slack + single_hop_time)
- Accepts Decimal, integer, float inputs; normalizes internally

---

## 10. Station Report 2 Modules

### 10.1 Connectivity (`StationReport2.Connectivity`)

Three-dimension reachability analysis on a station snapshot:
- **Step 3** (`build_summaries/1`): Lightweight boolean reachability per source stop for Entrance→Platform, Platform→Exit, Platform→Platform dimensions. Returns status (:passed/:warning/:fail) + alert texts.
- **Step 4** (`build_route_detail/2`): Enriched route detail for one dimension. Computes shortest paths via Graph, enrichments (time, distance, level_changes), step-free path comparison, time thresholds (>300s = :long).
- **Step 5** (`build_expanded_route/3`): Full step-by-step path between a source and target. Includes step warnings (>120s for elevator steps, >180s for walkway steps), level path ("Ground → Mezzanine → Platform"), signage direction.

Constants: `@long_route_threshold` = 300s, `@elevator_step_threshold` = 120s, `@walkway_step_threshold` = 180s.

### 10.2 Data Quality (`StationReport2.DataQuality`)

11 checks on a station snapshot:
1. **Isolated nodes** — Entrances/nodes/boarding areas with no pathway edges (undirected)
2. **Boarding area parent consistency** — parent_station must be a platform (location_type 0)
3. **Parent station assignment** — All platforms/entrances/nodes belong to correct parent
4. **Orphaned platforms** — Platforms with no boarding-area children (info only)
5. **Minimum station children** — At least 1 entrance + 1 platform
6. **Entrance-to-platform connectivity** — Every entrance must reach at least one platform (directed)
7. **Platform interconnection** — Every platform reachable from every other (directed)
8. **Wheelchair boarding consistency** — If station is accessible (wheelchair_boarding=1), check for step-free path entrance→platform
9. **Wheelchair contradicts context** — Stops marked not-accessible where >50% of level siblings are accessible
10. **Wheelchair inferrable** — Stops with nil/0 wheelchair_boarding where elevator→suggest 1, stairs-only→suggest 2
11. **Duplicate stop IDs** — No duplicate stop_id within station scope

Each check returns `%{id, label, description, status, value, value_format, detail_label, detail_layout, details}`.

### 10.3 GPS Checks (`StationReport2.Gps` + `GpsChecks`)

4 checks:
1. **GPS presence by type** — Table of present/missing per location_type. Required types: 0 (Stop), 1 (Station), 2 (Entrance). Optional: 3 (Node), 4 (Boarding Area).
2. **Longitude sign consistency** — Child stops whose longitude sign differs from the station
3. **Entrance GPS distance** — Entrances >500m from station (haversine)
4. **Node GPS clustering** — Optional-type stops >200m from station

### 10.4 Naming Conventions (`StationReport2.NamingConventions` + `NamingChecks`)

12 checks from `NamingChecks.validate/2`, whitelisted to 6 in `NamingConventions.build/1`:
1. **Title case** — Stop name follows title case rules
2. **Node ID prefix** — Generic nodes use `node_` prefix
3. **Boarding area ID prefix** — Boarding areas use `boarding_` prefix
4. **Entrance ID prefix** — Entrances use `entrance_` prefix
5. **Prefix-type mismatch** — Stop ID prefix matches location_type
6. **Autogenerated names** — Stop name ≠ stop_id (not auto-generated)

Additional checks in `NamingChecks` (not surfaced in NamingConventions but available): jargon terms, test/placeholder tokens, direction mismatch, duplicate ID tokens, parent name consistency, stop ID typos (Levenshtein distance ≤2).

### 10.5 Pathway Field Completeness (`StationReport2.PathwayFieldCompleteness`)

Per-mode field completeness statistics:
- Mode 1 (Walkway): length
- Mode 2 (Stairs): stair_count
- Mode 3 (Moving Sidewalk): traversal_time, length, min_width
- Mode 4 (Escalator): traversal_time
- Mode 5 (Elevator): min_width, traversal_time
- Mode 6 (Fare Gate): min_width
- Mode 7 (Exit Gate): min_width

Status per field: :pass (100% present), :fail (0% present), :warn (partial).

---

## 11. Change Log & Audit (Detailed)

### 11.1 AuditContext

A plain struct (not a schema) carrying:
```elixir
%AuditContext{
  organization_id: Ecto.UUID.t(),
  gtfs_version_id: Ecto.UUID.t(),
  station_stop_id: String.t(),
  actor_id: Ecto.UUID.t(),
  actor_email: String.t()
}
```
No Repo, no Ecto — pure data carrier extracted from the LiveView socket.

### 11.2 ChangeLog Schema

Immutable (insert-only, no updated_at):
- `entity_type`: "stop" | "pathway" | "level"
- `entity_id`: Ecto.UUID (nullable for creates)
- `entity_external_id`: String (stop_id / pathway_id / level_id)
- `station_stop_id`: String (scoping to which station the change belongs)
- `actor_id`, `actor_email`: Who made the change
- `snapshot`: Map of entity state before mutation
- `changed_fields`: Map of `%{field_name => %{"from" => old_value, "to" => new_value}}`
- `action`: "created" | "updated" | "deleted" | "rolled_back"
- `rolled_back_to_log_id`: Self-referential FK (only set for "rolled_back" actions)
- `organization_id`, `gtfs_version_id`: Scoping

Validation rules:
- `entity_type` must be "stop", "pathway", or "level"
- `action` must be "created", "updated", "deleted", or "rolled_back"
- `entity_id` required for all actions except "created"
- `rolled_back_to_log_id` must be set when action=="rolled_back" and must NOT be set otherwise
- `entity_external_id`, `station_stop_id`, `actor_id`, `actor_email` are always required

### 11.3 Recording Changes

`record_change/5`:
- Builds snapshot from pre-mutation entity via type-specific snapshot functions
- Computes changed_fields by diffing snapshot vs attrs (for "updated" actions)
- Filters attrs to only reversible_fields for change log purposes
- Inserts asynchronously (failure logged, mutation continues — best-effort audit)

### 11.4 Rollback

`rollback_entity/2`:
- Validates organization+version match (returns `:unauthorized` if mismatch)
- Only works for "updated" and "rolled_back" log entries with snapshots
- Computes target snapshot from stored snapshot + changed_fields
- Creates a new "rolled_back" ChangeLog entry in the same transaction
- Identity fields preserved: stop_id (for stops), pathway_id/from_stop_id/to_stop_id (for pathways), level_id (for levels)
- Broadcasts the entity-type-specific update event

### 11.5 Reversible Fields

Per entity type:
- **stop**: stop_name, stop_desc, stop_lat, stop_lon, location_type, wheelchair_boarding, platform_code, diagram_coordinate, parent_station, level_id
- **pathway**: pathway_mode, is_bidirectional, traversal_time, length, stair_count, max_slope, min_width, signposted_as, reversed_signposted_as, field_notes, field_completed_at
- **level**: level_name, level_index

Identity fields (excluded from rollback diffs):
- **stop**: stop_id
- **pathway**: pathway_id, from_stop_id, to_stop_id
- **level**: level_id

---

## 12. Business Rules Summary

### 12.1 Multi-Tenant Scoping

Every query filters on `organization_id` AND `gtfs_version_id`. No cross-tenant or cross-version data access is possible through the context API.

### 12.2 Uniqueness Constraints

All natural keys are unique within `(organization_id, gtfs_version_id)` scope. Key patterns:
- Single-field keys: route_id, stop_id, trip_id, service_id, pathway_id, level_id, agency_id, area_id, etc.
- Composite keys: stop_times(trip_id+stop_sequence), shapes(shape_id+shape_pt_sequence), transfers(8-field composite), stop_levels(stop_id+level_id)
- Singleton: feed_info (one per org+version)

### 12.3 Validation Ranges

| Field | Range |
|-------|-------|
| stop_lat | [-90, 90] |
| stop_lon | [-180, 180] |
| location_type | [0, 4] |
| wheelchair_boarding | [0, 2] |
| route_type | {0,1,2,3,4,5,6,7,11,12} |
| direction_id | {0, 1} |
| pathway_mode | [1, 7] |
| transfer_type | [0, 5] |
| route_pattern_typicality | [0, 5] |
| canonical_route_pattern | [0, 2] |
| continuous_pickup/drop_off | [0, 3] |
| pickup_type, drop_off_type | [0, 3] |
| timepoint | [0, 1] |
| payment_method | [0, 1] |
| transfers (fare attribute) | {0, 1, 2} |
| fare_media_type | [0, 4] |
| fare_transfer_type | [0, 2] |
| duration_limit_type | [0, 3] |
| bikes_allowed, cars_allowed | [0, 2] |
| exception_type | [1, 2] |
| headway_secs | >0 |
| price (fare_attribute) | >0 |
| amount (fare_product) | >=0 |
| stop_sequence, shape_pt_sequence, route_sort_order | >=0 |
| shape_dist_traveled | >=0 |

### 12.4 Conditional Validation

- Route: at least one of route_short_name or route_long_name must be present
- Route: route_color and route_text_color must be 6-char hex if set
- Stop: when parent_station is set (non-nil, non-empty), level_id becomes required (this is relaxed in `import_changeset`)
- StopLevel: scale fields are all-or-none; alignment fields are all-or-none
- ChangeLog: entity_id required for all actions except "created"; rolled_back_to_log_id required only for "rolled_back" actions

### 12.5 Reference Cascades

Both stop_id renames and level_id renames use the same pattern via `update_schema_field_values` and `update_stop_field_values`:
- For each `{old_id, new_id}` pair, runs `Repo.update_all` with `set: [{field, new_id}]`
- Scoped to organization_id + gtfs_version_id
- All in a single Ecto.Multi transaction

### 12.6 Broadcasting

Mutations to stops, levels, pathways, and stop_levels broadcast via `Phoenix.PubSub`:
- Topics: "stops", "levels", "pathways", "stop_levels"
- Messages: `{[:stops, :created], result}`, `{[:stops, :updated], result}`, etc.
- Broadcast failures are logged but do not fail the mutation

### 12.7 Import Safety

- CSV parsing: silently skips malformed lines and lines with wrong field counts
- ZIP safety: entry count cap (10,000), size caps (500MB total, 500MB per entry), no nested archives, hidden files ignored
- Batch processing: avoids atom table exhaustion by using `Repo.insert_all` instead of individual changeset inserts
- Phase separation: small files in single transaction; large files (stop_times, shapes) in batch-level transactions
- Extensions import is best-effort (non-fatal if it fails after core GTFS import)

### 12.8 Export Safety

- Runs within a single database transaction for consistent snapshot
- Streams records in 1000-row batches to avoid memory exhaustion
- Temp directory always cleaned up (in `after` block)
- Extensions append failure is non-fatal

### 12.9 Validation Flow

- Exports full GTFS data to temp ZIP
- Runs Java-based MobilityData GTFS Validator CLI
- Parses report.json, groups notices by code
- DB operations (mark running/completed/failed) are best-effort (failures logged, validation proceeds)
- OTP artifacts purged on successful validation

---

## 13. Assumptions

1. **String foreign keys**: Stops, pathways, levels reference each other via GTFS string IDs (`stop_id`, `level_id`, `pathway_id`) rather than database UUIDs (`id`). This mirrors the GTFS specification's key structure.
2. **Organization+version scope**: Every query assumes `(organization_id, gtfs_version_id)` pair as mandatory filter. Functions do not validate that these IDs are valid UUIDs.
3. **Java validator available**: The `Validator` module assumes a Java runtime and the MobilityData GTFS validator JAR are on the system. The `:gtfs_validator_path` app env must be configured.
4. **File system for uploads**: The extensions module reads/writes diagram images from a configured `uploads_path`. Path safety checks prevent traversal attacks.
5. **PubSub available**: Broadcasting assumes `GtfsPlanner.PubSub` is configured. Failures are logged but not raised.
6. **Station scope**: Station operations assume the station stop exists; `Repo.get!` is used in helper queries and will raise if the stop is missing.
7. **ChangesetHelpers.tim_string_fields**: Every schema's changeset calls `trim_string_fields()` which auto-trims all `:string` type fields. This is applied uniformly.

## 14. Risks & Ambiguities

1. **String-keyed foreign keys prevent DB-level referential integrity**: Pathways reference stops by `from_stop_id`/`to_stop_id` strings, not UUID `id` columns. No foreign key constraints exist between pathways and stops at the database level. Cascade operations (stop ID rename) must explicitly update all dependent tables.
2. **`build_lookup_maps/2` returns empty map**: The export module's foreign key resolution infrastructure is stubbed out. If UUID-to-string resolution is needed for export, it is not implemented.
3. **No post-import validation of referential integrity**: After import, pathways may reference stops that don't exist (the pathway parser validates against a stop_map, but that map depends on the calling context).
4. **Import phase 2 partial data**: `insert_batched_with_transactions` commits each batch independently. If a later batch fails, earlier batches' data remains committed (no rollback across batches).
5. **Advisory lock topic uses string interpolation**: `station_editing_status_topic` builds a string from UUIDs. The `hashtext()` function is PostgreSQL-specific.
6. **`derive_child_stop_coords` silently skips stops without diagram_coordinates**: Only stops with valid normalized coordinates get GPS derived. Stops with nil or malformed coordinates are silently omitted.
7. **`save_and_apply_stop_level_alignment` does not handle all stop_levels**: It only processes the active stop_level. Other levels' child stops are not updated.
8. **Floorplan alignment inference assumes two-pass convergence**: The two-pass solve uses the initial center estimate then refines using the cosine of the refined latitude. This may not converge for extreme latitudes.
9. **Change log snapshot serialization**: Decimal values are serialized via `Decimal.to_string/1`, but rehydration on rollback doesn't parse them back to Decimal — rollback attrs pass string values directly to changesets which may or may not handle them correctly.
10. **Broadcast topics are not namespaced by organization/version**: The PubSub topics "stops", "levels", "pathways", "stop_levels" are global — all connected clients receive all mutations regardless of organization/version scope.
11. **No transaction isolation for station-level query/update patterns**: Functions like `list_levels_for_station` run multiple queries without a transaction, so concurrent modifications could produce inconsistent results.
12. **Station report connectivity uses directed graph**: The reachability analysis uses directed edges (pathways may be unidirectional). Step-free path analysis uses only step-free modes. If a pathway is bidirectional but has stairs, it appears in the directed graph but not the step-free graph — this is by design but may confuse report consumers.
