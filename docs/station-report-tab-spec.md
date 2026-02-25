# Station Report Tab Specification

## Qualifications

### Required
- Elixir (pattern matching, immutable data transforms, tagged tuple error flow)
- Phoenix LiveView (stateful server-rendered pages, event handling, stream-friendly rendering)
- Ecto and SQL query design (joins, aggregates, query composition, preload strategy)
- GTFS and GTFS-Pathways domain modeling (stops, levels, pathways, location_type, pathway_mode)
- Data processing and graph algorithms (directed and undirected adjacency, reachability via BFS/DFS)
- ExUnit and Phoenix.LiveViewTest (unit and UI behavior tests driven by stable DOM IDs)

### Preferred
- Performance profiling for medium sized station graphs
- Accessibility semantics for route eligibility rules
- NodeJS and frontend data tooling (only for later visualization phases, not required for this list-first phase)

## Problem Statement

The single station experience currently has "Details" and "Diagram" tabs but no consolidated "Report" tab that computes and lists station quality signals from existing station data.

Today, data needed for station readiness decisions is scattered across records and cannot be reviewed in one place. We need deterministic station report outputs using only data we already store for the station parent stop, child stops, levels, and pathways.

## Goal

Add a new "Report" tab next to "Diagram" on the single station page that:

1. Collects and displays all metrics that are either directly determinable or computable from existing station data.
2. Renders those metrics as a structured list (not dashboard charts).
3. Uses pure calculation modules for metric logic and keeps LiveView thin.
4. Excludes metrics that require fields/tables we do not currently store.

## Architecture

### Standards Alignment
- Functional core, imperative shell:
  - Pure report calculation module(s) compute metrics from in-memory data.
  - LiveView and context modules handle IO/query boundaries.
- Explicit over implicit:
  - Every metric has a stable metric ID, defined inputs, and deterministic output shape.
- Let it crash for invalid internal assumptions:
  - Required input shape is pattern matched; unexpected shapes fail fast in calculation layer.

### UI and Route Surface
- Add route: `/gtfs/:version/stops/:stop_id/report`.
- Add "Report" tab in `station_sub_nav` next to "Diagram".
- Add new LiveView: `GtfsPlannerWeb.Gtfs.StationReportLive`.
- Keep existing tabs unchanged.
- Report page presents sections with list rows and optional detail lists.

### Data Flow
1. LiveView resolves station by `stop_id`, `organization_id`, `gtfs_version_id`.
2. Context fetches a station snapshot with:
   - parent station stop
   - child stops for parent station
   - levels for station
   - pathways touching station child stops (with endpoint stop records)
3. Pure report builder computes deterministic metrics from snapshot.
4. LiveView renders the report result.

### Proposed Modules
- `GtfsPlanner.Gtfs.StationReport` (pure):
  - `build/1` -> report map/struct
- `GtfsPlanner.Gtfs` (context boundary):
  - `get_station_report_snapshot/3`
- `GtfsPlannerWeb.Gtfs.StationReportLive`:
  - renders report sections and list items

### Report Output Contract
Use a stable output contract suitable for rendering and future API reuse.

- `report`
  - `station_stop_id`
  - `generated_at`
  - `sections :: [section]`
- `section`
  - `id`
  - `title`
  - `items :: [item]`
- `item`
  - `id`
  - `label`
  - `status :: :pass | :fail | :warn | :info`
  - `value` (count, boolean, ratio, or matrix summary)
  - `details` (list/map for drill-down values)

### Metric Scope

#### In Scope (Directly Determinable)
- Node inventory by `location_type`
- Edge inventory by `pathway_mode`
- Bidirectional vs unidirectional pathway counts
- Level count, names, indices
- Nodes per level (including unassigned bucket)
- GPS presence/missing counts by location type (required types: 0, 1, 2)
- Wheelchair boarding distribution by location type
- Pathway attribute completeness for existing fields only:
  - `traversal_time`, `length`, `min_width`, `max_slope`, `stair_count`, `signposted_as`, `reversed_signposted_as`
- Signage completeness based on existing signage fields

#### In Scope (Requires Calculation)
- Isolated node detection for location types 2, 3, 4
- Parent station consistency checks:
  - boarding area parent must be a platform
  - platform/entrance/generic parent must be station
  - orphaned platforms (no boarding area children)
  - minimum station children (at least one entrance and one platform)
- Entrance to boarding-area reachability (direction-aware)
- Boarding-area interconnection reachability
- Step-free route existence (entrance x platform), computed via eligible modes
- Elevator level coverage and level reachability via elevator-inclusive graph
- Escalator direction split inferred from edge direction and endpoint level index when available

### Graph Rules
- Build directed adjacency from pathways:
  - bidirectional pathway -> two directed edges
  - unidirectional pathway -> one edge `from_stop_id -> to_stop_id`
- Build undirected adjacency for isolation checks.
- Use station child stops as node set for core station graph metrics.
- Step-free traversal modes for v1:
  - include: walkway (1), moving sidewalk (3), elevator (5), fare gate (6), exit fare gate (7)
  - exclude: stairs (2), escalator (4)

### Out of Scope (Unavailable Data)
These are explicitly excluded from v1 because fields/tables are not present in current schema.

- `pathway_evolutions.txt` coverage/readiness metrics
- `wheelchair_assistance` and `wheelchair_assistance_phone`
- `mechanical_stair_count`
- `max_stair_flight`
- `surface_type`
- `handrail`
- `instructions` and `reversed_instructions`
- Generic-node semantic subcategories that require explicit tagging
- Pathways Equivalent (PE) complexity score until formula is formally defined

## Acceptance Criteria

- [ ] Station sub-navigation includes a "Report" tab next to "Diagram".
- [ ] Route `/gtfs/:version/stops/:stop_id/report` resolves and renders for a valid station.
- [ ] Report page renders list-based sections with stable DOM IDs for all section wrappers and metric rows.
- [ ] All in-scope direct metrics are present with deterministic values from current station data.
- [ ] All in-scope computed metrics are present and use direction-aware graph traversal where required.
- [ ] Parent-station consistency checks expose violation counts and offending IDs.
- [ ] Reachability outputs include per-entrance or per-platform detail lists (not only aggregate counts).
- [ ] Step-free route metric uses only v1 eligible pathway modes defined in this spec.
- [ ] Out-of-scope metrics are not computed and are shown as "not available in current schema" in a dedicated section.
- [ ] Pure report calculation tests cover nominal, edge, and failure-shape cases.
- [ ] LiveView tests assert tab navigation and presence of key report sections/rows by ID.

## Notes

- This phase prioritizes data collection and deterministic rendering, not final visual design.
- Keep output stable and machine-readable so a future dashboard visualization can reuse the same report contract.
- Existing schema uses `min_width` not `width`; all completeness logic must use real stored field names.
- No backward-compatibility shims are required for this feature.

## Implementation Steps

1. Add a new station report route in `lib/gtfs_planner_web/router.ex`: `live "/stops/:stop_id/report", Gtfs.StationReportLive, :index` within the existing GTFS live session.
2. Extend `station_sub_nav` in `lib/gtfs_planner_web/components/core_components.ex` to support `active_tab` value `:report`.
3. Add a new Report tab link in `station_sub_nav` that navigates to `/gtfs/#{@gtfs_version_id}/stops/#{@station.stop_id}/report` and applies active-tab styling/ARIA state identical to existing tabs.
4. Create `lib/gtfs_planner_web/live/gtfs/station_report_live.ex` with `use GtfsPlannerWeb, :live_view` and role guard `on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}`.
5. In `StationReportLive.mount/3`, assign `:page_title`, `:user_roles`, and initialize `:station`, `:report`, and `:stop_id` assigns.
6. Implement `StationReportLive.handle_params/3` to fetch station by `stop_id`; if not found, redirect to station list with flash.
7. Add context function `Gtfs.get_station_report_snapshot/3` in `lib/gtfs_planner/gtfs.ex` that returns `%{station: ..., child_stops: ..., levels: ..., pathways: ...}`.
8. Implement `get_station_report_snapshot/3` using existing context APIs (`get_stop_by_stop_id`, `list_child_stops_for_parent`, `list_levels_for_station`, `list_pathways_for_station`) and return tagged tuples (`{:ok, snapshot}` or `{:error, :not_found}`).
9. Create pure module `lib/gtfs_planner/gtfs/station_report.ex` with public API `build/1` pattern matching on snapshot map shape.
10. Define a deterministic report contract in `station_report.ex` with top-level keys `station_stop_id`, `generated_at`, and `sections`.
11. Implement snapshot normalization helpers in `station_report.ex`: child-stop index by `stop_id`, level index by `level_id`, and station node-set extraction.
12. Implement graph builder helpers in `station_report.ex` for directed and undirected adjacency from pathway records.
13. Implement Inventory section metrics in `station_report.ex`: node counts by location_type, edge counts by pathway_mode, directionality split, level summary, and nodes-per-level.
14. Implement GPS section metrics in `station_report.ex`: missing/present counts for required location types (0,1,2) and optional types.
15. Implement Data Integrity section metrics in `station_report.ex`: isolated nodes for types 2/3/4, parent-consistency checks, orphaned platform detection, and minimum station children check.
16. Implement reachability helpers in `station_report.ex` (BFS or DFS on directed graph) and expose reusable function(s) for entrance-to-boarding and boarding-to-boarding checks.
17. Implement Entrance-to-Boarding connectivity metric in `station_report.ex` with per-entrance reachable/unreachable outputs.
18. Implement Boarding-Area interconnection metric in `station_report.ex` with per-boarding-area pass/fail outputs.
19. Implement Step-Free route metric in `station_report.ex` using allowed modes 1,3,5,6,7 and per entrance x platform results.
20. Implement Elevator coverage metric in `station_report.ex` to compute level reachability using elevator-inclusive paths and expose unreachable levels.
21. Implement Escalator direction summary metric in `station_report.ex` using pathway direction plus endpoint level indices when present; include unknown bucket when inference is impossible.
22. Implement Attribute Completeness section in `station_report.ex` for existing pathway fields only and compute per-field populated/total and percentage.
23. Implement mode-specific completeness in `station_report.ex` for available fields only, keyed by pathway mode.
24. Implement an explicit "Not Available In Current Schema" section in `station_report.ex` listing excluded metrics from this spec.
25. Wire `StationReportLive.handle_params/3` to call `Gtfs.get_station_report_snapshot/3`, then `GtfsPlanner.Gtfs.StationReport.build/1`, and assign report output.
26. Implement `StationReportLive.render/1` with `<Layouts.app ...>` and `<.station_sub_nav active_tab={:report} ...>`.
27. Render report as sectioned lists with stable IDs: `station-report`, `report-section-<id>`, `report-item-<id>` and deterministic details containers.
28. Add an empty state in `StationReportLive` for stations with no child stops/pathways while still rendering section scaffolding.
29. Add pure unit tests in `test/gtfs_planner/gtfs/station_report_test.exs` covering all metric families, directed edge behavior, step-free filtering, and unavailable metrics list.
30. Add LiveView tests in `test/gtfs_planner_web/live/gtfs/station_report_live_test.exs` covering route access, tab highlight, and key report section/item IDs.
31. Add targeted component test coverage (or existing live test assertions) to verify the station sub-nav renders the new Report tab across station pages.
32. Ensure all new public functions include `@doc` and typespecs consistent with existing codebase style and output contracts.
