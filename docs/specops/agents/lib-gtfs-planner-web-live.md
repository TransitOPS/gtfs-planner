# LiveView Interfaces Agent Doc

Source target: `lib-gtfs-planner-web-live`
Scope: Implements the authenticated web workflows for dashboards, admin screens, user settings, GTFS browsing, import/export, validation results, station diagrams, and reports.
Deep analysis: [`../analysis/lib-gtfs-planner-web-live.md`](../analysis/lib-gtfs-planner-web-live.md)
Freshness: `source_hash=916acbad0ea9ba0685d94730830114532c5c266c7d12d719e692e6de4af0ff7f`, `last_synthesized=2026-06-26`

## Use When
- Working on any of the 29 LiveView modules in `lib/gtfs_planner_web/live/`
- Adding/modifying authenticated web workflows, admin screens, user settings
- Working on GTFS browsing, import/export, station diagram editing, validation results, station reports or reachability testing

## Read First
- `lib/gtfs_planner_web/live/dashboard_live.ex:10-26` — mount pattern establishing org/role/version context
- The router's `live_session` scopes defining `on_mount` guards (not in this target, but essential)
- The specific `.ex` file you're modifying, as each LiveView is largely self-contained

## Interfaces

All LiveViews use `use GtfsPlannerWeb, :live_view`. Root wrappers: `<Layouts.app flash={@flash} current_scope={...}>` (authenticated) or `<Layouts.auth>` (auth flows).

| Context Module | Used For |
|---|---|
| `Accounts` | User auth, registration, roles, org membership, API keys |
| `Gtfs` | GTFS data queries, CRUD for stops/routes/pathways/levels, validation runs, change recording, editing status |
| `Import` | File parsing, diff computation, bulk import |
| `Geocoding` | Address autocomplete |
| `LiveSelect` | Address selection component |

**PubSub topics:** `"gtfs_version:#{id}"` (rename broadcasts), `"import:#{topic}"` (import progress), `"station:#{id}"` (editing status), export/validation custom topics.

**JS hooks:** `.DownloadHook` (export download), `MapAlignment` (diagram Leaflet overlay), unnamed version-selector hook.

## Rules & Invariants

### Authorization & Access Control
- All GTFS views require `require_gtfs_access` `on_mount` or higher role.
- `Admin.OrganizationsLive` → `require_system_administrator`; `Admin.UsersLive` → `require_pathways_studio_admin`; `ImportLive` → `require_gtfs_editor`.
- Data-level checks required: `valid_version_for_org?/2` before switching versions; stop `organization_id`/`gtfs_version_id`/`stop_belongs_to_station?/3` before mutations in diagram/report.

### Navigation & State
- **Always** use `push_patch` (URL-driven state) and `push_navigate` (page transitions). Never use deprecated `live_patch`/`live_redirect`.
- GTFS browsing views (`RoutesLive`, `StopsLive`, etc.): all filter/sort/search/page state encoded in URL query params via `handle_params`. Bookmarkable, back-button-safe.
- Whitelist sort columns with `String.to_existing_atom` to prevent atom exhaustion.

### Collections & Streams
- **Always** use `stream/3` for collections (never plain list assigns).
- Use `stream(socket, :name, items, reset: true)` when filtering/refreshing.
- Track empty states with separate boolean assigns (e.g., `routes_empty?`).

### Forms
- **Always** use `to_form/2` with a changeset; never pass changeset directly to templates.
- Form fields accessed as `@form[:field]` in templates. Give every form a unique DOM id.

### Version Switching (must be in every GTFS LiveView)
- Implement `handle_event("gtfs_version_loaded", ...)` and `handle_event("switch_gtfs_version", ...)`.
- Always guard with `valid_version_for_org?/2` wrapped in `try/rescue` for `Ecto.Query.CastError`.

### Async Operations
- Import: `Task.async` → PubSub progress → `handle_info({:DOWN, ref, :process, pid, reason})` for crash handling. Subscribe to PubSub **before** starting the task.
- Export/validation: `Task.Supervisor.async_nolink`. Validation polling at 250ms intervals via `:poll_pathways_trip_test_status`.
- Station reachability: polls `get_pathways_trip_test_status/1`, retries up to 40 times (10s) when results not yet available.

### Diagram Editor
- Four modes: `:view`, `:add`, `:connect`, `:map`. Switch via `switch_mode`.
- All mutations must record `Gtfs.record_change/5` with `AuditContext` (actor_id, actor_email from `current_user`).
- Stop creation: auto or manual `Stop.generate_stop_id/2`. Dragging: check org/version/station ownership.
- Pathway creation: auto-generated ID, bidirectional by default, optional length from scale.

### Security
- **Never** create atoms from user input. Use `String.to_existing_atom` or explicit whitelists.
- Anti-enumeration pattern for email-based auth flows: always show identical success message.
- API key display: one-time copy-to-clipboard via `push_event`; never re-displayed.

## State, I/O & Side Effects

### State Management
- `DashboardLive`: org context + version context from session and `current_user`.
- `StationDiagramLive`: 100+ assigns at mount — modes, selections, forms, uploads, scale, active level, change history state.
- GTFS browsing: URL params (`version_id`, `sort_by`, `sort_dir`, `search`, `page`, filter fields).
- Import/Export: upload config, task refs, PubSub topic, progress state, diff decisions, validation results.

### File Uploads
- Import: `allow_upload(:gtfs_files, ...)` — `.txt`/`.csv`/`.zip`, max 50 entries, 200MB each.
- Diagram: `allow_upload(:diagram, ...)` — PNG/JPG/SVG, 10MB max, auto-upload with progress.

### Shared Patterns
- **Diff review** (ImportLive): parse uploaded files → compute diff against DB → filterable review (All/Add/Modify/Conflict/Remove tabs with counts) → ordered apply (add → modify → remove, then levels → stops → pathways).
- **Station report** (6 sections): Station Inventory, Data Quality, GPS Checks, Naming & ID Conventions, Reachability & Connectivity, Pathway Field Completeness. Entity edit drawer rebuilds entire report from fresh snapshot.
- **Change history** (ChangeHistoryComponents): timeline grouped by date, field-level diffs, rollback with preview, field-group filters per entity type, audit trail via `Gtfs.record_change/5`.
- **Station reachability** (StationReachabilityLive): load station → run reachability → poll status → display per-test results with expandable criteria and itineraries → recent runs table.

## Failure Modes
- **Async task orphaned**: if LiveView dies during import/export, task continues without consumer.
- **Stale report**: after inline edit in Station Report, report rebuilds from fresh snapshot synchronously — no optimistic UI.
- **Nil current_user crash**: StationDiagramLive builds AuditContext from `current_user`; nil would crash (should not happen due to auth guards).
- **Version ID cast error**: non-integer version IDs cause `Ecto.Query.CastError` — must use `try/rescue`.
- **Duplicate constants drift**: `@pathways_failure_messages` (33 entries) duplicated 4 times across `validation_result_live.ex`, `station_reachability_result_live.ex`, `export_live.ex`, `station_reachability_live.ex` with subtle differences. Changes must be manually synchronized.
- **Walkability test duplication**: CRUD logic duplicated between StationDiagramLive and StationReachabilityLive.

## Change Checklist
- [ ] New GTFS LiveView → include version-switching handlers + `valid_version_for_org?/2`.
- [ ] New route → add proper `on_mount` guard in router's `live_session`.
- [ ] StationDiagramLive changes → be aware of 100+ existing assigns in mount.
- [ ] Async operations → subscribe to PubSub **before** starting task; handle DOWN messages.
- [ ] Pathways failure constants → update **all 4 copies** across the 4 files.
- [ ] Walkability test logic → check for duplication in `station_diagram_live.ex` and `station_reachability_live.ex`.
- [ ] Never create atoms from unsanitized user input. Use `String.to_existing_atom` or whitelist.
- [ ] Follow anti-enumeration pattern for email-based auth flows.
- [ ] Use `push_patch`/`push_navigate` (never deprecated variants).
- [ ] Use `stream/3` for all collections with empty-state tracking.
- [ ] Use `to_form/2` for all forms with explicit DOM ids.
- [ ] Run `mix precommit` after changes.

## Escalate To Deep Analysis
- Authorization boundaries between roles or `on_mount` guards need clarification.
- Overlap between `ManageUsersLive` and `Admin.UsersLive` is unclear.
- SVG/Leaflet map integration details in diagram editor.
- Refactoring shared validation result display code across 4 duplicated files.
- `ComponentsLive` page purpose/routing needs clarification.
- Full file:line evidence for any claim — see deep analysis for all citations.
