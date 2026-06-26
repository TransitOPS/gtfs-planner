# SpecOps Analysis: LiveView Interfaces

**Target Slug:** `lib-gtfs-planner-web-live`
**Name:** LiveView Interfaces
**Analyzed source_hash:** `916acbad0ea9ba0685d94730830114532c5c266c7d12d719e692e6de4af0ff7f`
**Date:** 2026-06-26
**Lines of Code:** ~83,512 total across 29 files

---

## 1. System Overview

The `lib/gtfs_planner_web/live/` target contains 29 Phoenix LiveView modules implementing the entire authenticated web UI for the GTFS Planner application (branded as "Pathways Studio"). These modules cover user authentication flows, admin organization/user management, GTFS data browsing, bulk import/export with async progress, station diagram editing with floorplan overlays, validation result review, station reporting, and reachability testing.

All LiveViews follow Phoenix 1.8 conventions: using `<Layouts.app>` or `<Layouts.auth>` as root wrappers, `on_mount` hooks for authorization, `stream/3` for collections, `to_form/2` for form assigns, and `push_patch`/`push_navigate` for URL-based navigation.

### Directory Structure

```
lib/gtfs_planner_web/live/
├── dashboard_live.ex           # Landing page after login
├── components_live.ex          # UI component demo (address autocomplete)
├── api_key_live.ex             # Organization API key management
├── first_admin_live.ex         # First-time admin setup wizard
├── manage_users_live.ex        # Organization-level user management
├── user_settings_live.ex       # User email/password settings
├── user_login_live.ex          # Login form
├── user_accept_invite_live.ex  # Invite acceptance + password set
├── user_confirmation_live.ex   # Email confirmation
├── user_forgot_password_live.ex # Password reset request
├── user_reset_password_live.ex  # Password reset form
├── admin/
│   ├── organizations_live.ex   # System admin: org CRUD + member invite
│   └── users_live.ex           # Org admin: user management + org settings
└── gtfs/
    ├── import_live.ex           # GTFS import with diff review system
    ├── export_live.ex           # GTFS export + validation triggering
    ├── routes_live.ex           # Filterable/sortable route list
    ├── route_detail_live.ex     # Route details + route patterns
    ├── stops_live.ex            # Filterable/sortable station list
    ├── stop_detail_live.ex      # Station details + child stops + levels + pathways
    ├── change_history_components.ex  # Shared change-log timeline component
    ├── validation_result_live.ex     # Validation result review (MobilityData + Pathways)
    ├── station_diagram_live.ex       # Diagram editor (stops, pathways, levels, floorplans)
    ├── station_diagram_components.ex # SVG/Map components for diagram editor
    ├── station_report_2_live.ex      # Station report dashboard
    ├── station_report_2_components.ex    # Report section components
    ├── station_report_2_connectivity_components.ex  # Connectivity detail views
    ├── station_report_drawer_components.ex  # Entity edit drawer for reports
    ├── station_reachability_live.ex       # Station-scoped reachability validation
    └── station_reachability_result_live.ex  # Station reachability result detail
```

### Evidence

- `lib/gtfs_planner_web/live/dashboard_live.ex:1-131` - Dashboard mount, org context, version context
- `lib/gtfs_planner_web/live/components_live.ex:1-332` - Geocoding autocomplete demo
- `lib/gtfs_planner_web/live/first_admin_live.ex:1-120` - First admin setup flow
- All files use `use GtfsPlannerWeb, :live_view` and follow Phoenix 1.8 patterns

---

## 2. Authentication & Session Flows

### 2.1 Login Flow

`UserLoginLive` (`user_login_live.ex:1-50`) renders a simple login form pointing to `POST /users/log_in`. It uses `phx-update="ignore"` because the form submits via standard HTTP POST (handled by `UserSessionController`), not via LiveView events. The mount pre-fills the email field from flash if available.

### 2.2 Account Creation / First Admin

`FirstAdminLive` (`first_admin_live.ex:1-120`) handles the zero-user bootstrap scenario. On mount, if `Accounts.count_users() > 0`, it redirects to `/`. Otherwise it presents a form collecting email, password, password confirmation, organization name, and optional organization alias.

- **Validation** (`first_admin_live.ex:96-110`): Uses `Accounts.change_user_registration/2` changeset for inline validation without persistence. Preserves all raw params in the form.
- **Submission** (`first_admin_live.ex:71-93`): Calls `Accounts.register_first_admin/2` which creates the user with `:administrator` role and the organization. On success, redirects to login.

### 2.3 Account Confirmation

`UserConfirmationLive` (`user_confirmation_live.ex:1-81`) handles two scenarios:
- **With token** (`mount/3` line 7): Confirms the user via `Accounts.confirm_user/1`. On success, redirects to login. On error, flashes error and redirects to `/`.
- **Without token** (`mount/3` line 23): Renders a form to resend confirmation instructions. The `handle_event("send_instructions")` follows the "don't reveal whether email exists" pattern, always showing the same success message.

### 2.4 Password Reset

- **Request** (`user_forgot_password_live.ex:1-76`): Collects email, sends reset instructions. Uses the same anti-enumeration pattern as confirmation.
- **Reset** (`user_reset_password_live.ex:1-86`): Validates the reset token in mount, presents new password form. On submission calls `Accounts.reset_user_password/2`.

### 2.5 Invite Acceptance

`UserAcceptInviteLive` (`user_accept_invite_live.ex:1-92`) handles the invite token flow. On mount it looks up the user by invite token; if found, shows a password creation form. On submission it calls `Accounts.accept_invite_set_password/2` and redirects to login.

### Evidence

- `lib/gtfs_planner_web/live/user_login_live.ex:1-50`
- `lib/gtfs_planner_web/live/first_admin_live.ex:58-69` - mount with `Accounts.count_users()` guard
- `lib/gtfs_planner_web/live/user_confirmation_live.ex:7-30` - dual mount clauses
- `lib/gtfs_planner_web/live/user_accept_invite_live.ex:51-69` - token validation in mount
- `lib/gtfs_planner_web/live/user_reset_password_live.ex:50-63` - token validation

---

## 3. Authorization & Access Control

### 3.1 `on_mount` Guards

The application uses `on_mount` hooks for authorization, defined in the router's `live_session` scopes:

| Guard Module | Function | Used By |
|---|---|---|
| `GtfsPlannerWeb.UserAuth` | `:ensure_authenticated` | Admin organizations (double-guarded) |
| `GtfsPlannerWeb.EnsureRole` | `:require_system_administrator` | `Admin.OrganizationsLive` |
| `GtfsPlannerWeb.EnsureRole` | `:require_pathways_studio_admin` | `Admin.UsersLive` |
| `GtfsPlannerWeb.EnsureRole` | `:require_gtfs_editor` | `Gtfs.ImportLive` |
| `GtfsPlannerWeb.EnsureRole` | `:require_gtfs_access` | All remaining GTFS views, reports, diagram |

### 3.2 Role Hierarchy

- **System Administrator** (`is_administrator?`): Can manage all organizations (`Admin.OrganizationsLive`). Gets `<Layouts.app>` without org-scoped roles.
- **Pathways Studio Admin** (`require_pathways_studio_admin`): Can manage users within their own organization (`Admin.UsersLive`). Includes org settings editing.
- **Pathways Studio Editor** (`require_gtfs_editor`): Can import GTFS data (`ImportLive`).
- **Pathways Studio Access** (`require_gtfs_access`): Can view GTFS data, run validations, use the diagram editor.

### 3.3 Organization-Level Isolation

The `DashboardLive` (`dashboard_live.ex:28-49`) demonstrates how organization and role context is established:
- Administrators bypass org-scoped data (`get_user_org_context/3` returns `{nil, []}`).
- Regular users get their organization from the `session["organization_id"]` and their roles from `Accounts.get_user_org_membership/2`.

Many GTFS LiveViews perform additional authorization checks at the data level:
- `ImportLive` checks `valid_version_for_org?/2` before navigating to a different version.
- `StationDiagramLive` validates stop ownership (`stop.organization_id`, `stop.gtfs_version_id`, `stop_belongs_to_station?/3`) before any mutation.
- `ValidationResultLive` and `StationReachabilityResultLive` verify `run.organization_id` matches before displaying results.

### Evidence

- `lib/gtfs_planner_web/live/admin/organizations_live.ex:12-13` - `on_mount` declarations
- `lib/gtfs_planner_web/live/dashboard_live.ex:10-26` - org/role context computation
- `lib/gtfs_planner_web/live/gtfs/import_live.ex:13` - `require_gtfs_editor`
- `lib/gtfs_planner_web/live/gtfs/validation_result_live.ex:71-76` - org verification
- `lib/gtfs_planner_web/live/gtfs/station_diagram_live.ex:1198-1218` - drag permission checks

---

## 4. Data Browsing & Navigation

### 4.1 Routes Browsing

`RoutesLive` (`routes_live.ex:1-471`) provides a filterable, sortable, paginated table of GTFS routes. Key patterns:
- **URL-driven state** (`handle_params`: lines 37-80): All filter/sort/search/page state is encoded in URL query params, enabling bookmarking and back-button support.
- **`push_patch` navigation**: Every interaction filters/sorts/searches/paginates by building query params and calling `push_patch`, which re-invokes `handle_params`.
- **Stream-based rendering** (`stream(:routes, ...)`: lines 79, 352): Routes are streamed into a `phx-update="stream"` container.
- **Whitelisted sort columns** (`parse_column_atom/1`: lines 461-470): Only allows sorting by predefined columns (`route_id`, `route_short_name`, `route_long_name`, `route_type`, `active`), using `String.to_existing_atom` to prevent atom exhaustion.
- **Empty state** (`routes_empty?` assign: lines 33, 78, 259): Used to show/hide "No routes found" message.

### 4.2 Stops Browsing

`StopsLive` (`stops_live.ex:1-485`) follows the identical URL-driven, stream-based pattern as Routes. Additionally:
- Fetches routes serving each station via `Gtfs.get_routes_for_stops/3` (line 68).
- Shows route badges with color coding (lines 376-388).
- Shows direction filter only when a route is selected (lines 262-272).

### 4.3 Route Details

`RouteDetailLive` (`route_detail_live.ex:1-240`) shows a detail grid for a single route, with a tab strip (Details/Patterns). Route patterns are loaded on demand when the Patterns tab is active (lines 48-57), and streamed.

### 4.4 Stop Details

`StopDetailLive` (`stop_detail_live.ex:1-434`) shows comprehensive station information:
- Child stops grouped by level (lines 50-56).
- Station editing status with real-time PubSub updates (lines 41-44, 71-73).
- "I'm editing this Station" / "I'm done" workflow using `Gtfs.set_station_editing_status/4` and `Gtfs.clear_station_editing_status/4`.
- Lists levels with diagram presence indicators and pathway tables.

### 4.5 Cross-Cutting: Version Switching

Nearly every GTFS LiveView implements `handle_event("gtfs_version_loaded", ...)` and `handle_event("switch_gtfs_version", ...)` to support a global version selector. The pattern:
1. JS hook reads selected version from localStorage and pushes `gtfs_version_loaded` event.
2. Server validates `valid_version_for_org?/2` (version exists and belongs to current org).
3. If valid, navigates to the same page but for the new version.

This pattern is duplicated verbatim across `ImportLive`, `ExportLive`, `RoutesLive`, `RouteDetailLive`, `StopsLive`, `StopDetailLive`, `ValidationResultLive`, `StationDiagramLive`, `StationReport2Live`, `StationReachabilityLive`, and `StationReachabilityResultLive`.

### Evidence

- `lib/gtfs_planner_web/live/gtfs/routes_live.ex:37-80` - URL-driven handle_params
- `lib/gtfs_planner_web/live/gtfs/stops_live.ex:40-95` - handle_params with route enrichment
- `lib/gtfs_planner_web/live/gtfs/route_detail_live.ex:27-61` - tab-based loading
- `lib/gtfs_planner_web/live/gtfs/stop_detail_live.ex:76-92` - editing status workflow
- `lib/gtfs_planner_web/live/gtfs/import_live.ex:75-85` - version switch pattern

---

## 5. Import/Export Workflows

### 5.1 GTFS Import

`ImportLive` (`import_live.ex:1-1369+`) is the most complex LiveView. It handles:

**Primary Import Flow:**
- File upload via `allow_upload(:gtfs_files, ...)` (lines 45-49): Accepts `.txt`, `.csv`, `.zip`; max 50 entries, 200MB each.
- Version creation toggle (lines 158-191): Can create a new GTFS version during import.
- Async import via `Task.async` (lines 204-212): Runs `Import.import_files/4` in a separate process to avoid blocking. Progress is communicated through `Phoenix.PubSub` on a unique topic (line 200-201).
- Progress display (lines 640-661): Shows file name, processed/total rows, progress bar.
- Result display (lines 663-764): Shows success with all entity counts (agencies, stops, routes, pathways, etc.), archive warnings, and unrecognized files.
- Task crash handling (`handle_info({:DOWN, ...})`: lines 433-443).

**Diff Review System:**
A secondary feature within ImportLive allows uploading `levels.txt`, `stops.txt`, and `pathways.txt` to compute diffs against the database:
- Diff computation (`compute_diff`: lines 225-302): Parses uploaded files, compares to DB state, generates `DiffDecision` structs.
- Filterable review (lines 867-1061): Tabs for All/Add/Modify/Conflict/Remove with counts. Individual approve/reject per decision. Bulk approve per action.
- Apply phase (`apply-decisions`: lines 355-372): Orders decisions by phase (add→modify→remove) and entity type (levels→stops→pathways or reverse for removes), then applies each via the appropriate Gtfs module function.
- Parse error display (lines 924-931). Deduplication detection (lines 1116-1165).

### 5.2 GTFS Export

`ExportLive` (`export_live.ex:1-1299+`) handles:
- **File inventory** (lines 84-88, 130-134): Shows record counts per file, switchable between Full and Pathways export types.
- **Async export** via `Task.Supervisor.async_nolink` (lines 231-233): Exports GTFS zip and pushes a download event to the browser via a colocated JS hook (`.DownloadHook`, lines 1120-1133).
- **Validation triggering** (lines 170-195): Supports MobilityData GTFS Validator and Pathways Trip Tests. When Pathways tests are selected, it runs a multi-phase prep (export → OTP graph build → OTP runtime start → test suite).
- **Validation progress** via PubSub (lines 246-248, 251-261): Phases include cache check, preflight, exporting, packaging, persisting, OTP start/wait/ready/stop, suite running/finishing.
- **Error handling**: Extensive pathways failure classification (`@pathways_failure_messages`, lines 17-36) with blocking issues, recommended checks, and technical diagnostics displayed in an error panel.

### Evidence

- `lib/gtfs_planner_web/live/gtfs/import_live.ex:38-71` - mount with upload config
- `lib/gtfs_planner_web/live/gtfs/import_live.ex:196-221` - async import task
- `lib/gtfs_planner_web/live/gtfs/import_live.ex:224-302` - diff computation
- `lib/gtfs_planner_web/live/gtfs/import_live.ex:1220-1369+` - decision sort/apply logic
- `lib/gtfs_planner_web/live/gtfs/export_live.ex:48-76` - mount with validation state
- `lib/gtfs_planner_web/live/gtfs/export_live.ex:170-195` - validation run branching
- `lib/gtfs_planner_web/live/gtfs/export_live.ex:1120-1133` - DownloadHook

---

## 6. Station Diagram Editor

`StationDiagramLive` (`station_diagram_live.ex:1-3025+`) is the most feature-rich LiveView. It provides a visual floorplan editor for adding, editing, and repositioning child stops; creating and editing pathways; managing levels; and aligning floorplans to real-world coordinates.

### 6.1 Modes

The editor operates in four modes (`switch_mode`, line 937):
- **View** (`:view`): Select stops, drag to reposition, measure distances, set scale.
- **Add** (`:add`): Click on the canvas to place a new child stop. Opens a form sidebar for stop_id (auto or manual), stop_name, location_type, level, wheelchair_boarding, platform_code, lat/lon.
- **Connect** (`:connect`): Select a source stop, then click a target stop to create a pathway between them.
- **Map** (`:map`): Overlay the floorplan image on a Leaflet map for geo-alignment.

### 6.2 Stop Management

- **Creating** (`save_child_stop`: lines 1463-1591): Handles both auto and manual stop_id generation (`Stop.generate_stop_id/2`), platform stop parenting (location_type=4), unique ID resolution, and audit trail via `Gtfs.record_change/5`.
- **Editing**: Opens sidebar on click (`edit_child_stop`, line 1283). Supports form validation, stop_id mode toggle (auto↔manual), level selection.
- **Dragging** (`drag_start`/`drag_end`: lines 1143-1273): Full drag-and-drop repositioning with comprehensive permission checks (org, version, station membership). Coordinates validated as floats.
- **Deleting** (`delete_child_stop`: lines 1621-1652): Removes stop from station, records audit trail.

### 6.3 Pathway Management

- **Creating** (via Connect mode: `create_pathway`, line 1656): Creates pathway with auto-generated ID, bidirectional by default, with optional length calculation from scale.
- **Editing** (`edit_pathway`: lines 1747-1777): Opens drawer with form for pathway_mode, is_bidirectional, traversal_time, length, stair_count, min_width, signposted_as, reversed_signposted_as. Supports pathway pairs (two pathways between same stops) with tab switching.
- **Flipping** (`flip_pathway`: lines 2760-2877): Swaps from/to stops, preserves pending form edits.
- **Length calculation** (`calculate_pathway_length`: lines 2594-2637): Computes length from stop diagram coordinates using the level's scale.
- **Deleting** (`delete_pathway`: lines 1664-1743): With org/version/station authorization checks.

### 6.4 Level Management

- **Adding** (`open_add_level`: lines 2892-2908): Can add existing level or create new. Auto-generates level_id from station stop_id + snakecased name.
- **Editing** (`open_edit_level`: lines 2917-2941): Shows level form, detects if level is shared with other stations.
- **Removing** (`remove_level_from_station`: lines 2952-2988): Unlinks level from station, refreshes available levels list.

### 6.5 Floorplan & Alignment

- **Diagram upload** (`allow_upload(:diagram, ...)`: lines 106-112): PNG/JPG/SVG, 10MB max, auto-upload with progress callback.
- **Scale calibration** (`save_ruler`: lines 1910-1971): Two-point measurement with real-world distance input. Saves scale to StopLevel and recalculates pathway lengths.
- **Map alignment** (Map mode): Uses `MapAlignment` JS hook (referenced in `map_canvas`, station_diagram_components.ex:413-417). Supports:
  - Drag-to-position floorplan overlay on Leaflet map
  - Rotation handle, resize handle
  - Center lat/lon inputs
  - Floorplan opacity slider
  - Save alignment / Apply Image Position (sets lat/lon for all child stops)
  - Reference overlay (view another level's floorplan as reference)
  - Infer alignment from anchor stops with RMSE display

### 6.6 Change History

The diagram editor integrates a full change history system (`ChangeHistoryComponents`, `change_history_components.ex:1-721`):
- Tabs: Details / History per entity (stop, pathway, level).
- Timeline view grouped by date with relative time labels.
- Each entry shows: actor avatar/name, action (created/edited/deleted), field-level diffs with old→new values.
- **Rollback**: Preview and confirm rollback to a previous state.
- Field filters: "All fields", "Position only", "Accessibility only", "Name & description" (for stops); "Mode only", "Geometry only", "Signage" (for pathways); "Name only", "Index only" (for levels).
- **Audit trail**: All mutations record changes via `Gtfs.record_change/5` with `AuditContext`.

### 6.7 Walkability Tests

Within the diagram editor, users can create walkability test cases for individual child stops:
- Address autocomplete via `LiveSelect.Component` and `Geocoding.autocomplete/1`.
- Configure expected traversable, wheelchair accessible, duration/distance min/max.
- View existing tests, edit, delete.
- Save/delete triggers OTP artifact purge.

### 6.8 Naming Conventions

A naming drawer (`open_naming_drawer`/`apply_naming_convention`: lines 2281-2403) provides bulk rename of child stops:
- Two styles: kebab (auto-generated from stop_name) or structured.
- Preview with selectable rows.
- Apply renames child stops and updates pathway references.

### Evidence

- `lib/gtfs_planner_web/live/gtfs/station_diagram_live.ex:26-112` - mount with 100+ assigns
- `lib/gtfs_planner_web/live/gtfs/station_diagram_live.ex:937-966` - mode switching
- `lib/gtfs_planner_web/live/gtfs/station_diagram_live.ex:1463-1591` - stop creation/update
- `lib/gtfs_planner_web/live/gtfs/station_diagram_components.ex:38-89` - toolbar
- `lib/gtfs_planner_web/live/gtfs/station_diagram_components.ex:413-642` - map_canvas with alignment
- `lib/gtfs_planner_web/live/gtfs/change_history_components.ex:101-351` - change_log_list
- `lib/gtfs_planner_web/live/gtfs/change_history_components.ex:511-551` - field_groups

---

## 7. Validation Results

### 7.1 ValidationResultLive

`ValidationResultLive` (`validation_result_live.ex:1-1152+`) renders validation run details for both MobilityData GTFS Validator and Pathways Trip Tests.

**Status states:**
- **Failed** (lines 200-361): Shows pathways failure panel with blocking issues, recommended checks, technical diagnostics, and OTP data requirements.
- **Started/Running** (lines 363-376): Loading spinner with contextual message.
- **Completed with pathways results** (lines 377-575): Shows Trip Reachability Summary (total/pass/warning/fail), Criteria Comparison Overview, and Per-Test Results table with expandable criteria checks and step-by-step itinerary.
- **Completed with standard results** (lines 576-724): Shows Errors/Warnings/Infos summary stats and collapsible notice groups sorted by severity, with sample notices showing file/line/column/message.

**History drawer:** A slide-out panel (`drawer-end`) shows a streamed list of past validation runs for the current GTFS version.

**Polling:** For in-progress pathways tests, the LiveView schedules `:poll_pathways_trip_test_status` messages at 250ms intervals to track status changes.

### 7.2 StationReachabilityResultLive

`StationReachabilityResultLive` (`station_reachability_result_live.ex:1-1094+`) is structurally nearly identical to `ValidationResultLive` but is scoped to station reachability runs (`run_type == "station_reachability"`). Key differences:
- Shows a "Back to Reachability" link (lines 191-205) if `stop_id` is present.
- Routes `station_reachability` type runs here, redirects other types to `ValidationResultLive`.
- The per-test results table includes Origin/Destination/Start Time/End Time columns.

### 7.3 Significant Code Duplication

Both validation result LiveViews contain ~200+ lines of near-identical code:
- `@pathways_failure_messages` constant (also duplicated in `ExportLive` and `StationReachabilityLive`)
- `@otp_data_requirements_summary` constant
- `sorted_notices/1`, `get_sample_notices/1`, `get_total_notices/1`, `extract_filename/1`, `extract_sample_context/1`, `format_count/1`
- Pathways trip overview rendering components (`pathways_trip_visualization_overview_section`, `pathways_criteria_comparison_section`)

This duplication is also present in `ExportLive` and `StationReachabilityLive`.

### Evidence

- `lib/gtfs_planner_web/live/gtfs/validation_result_live.ex:9-39` - pathway failure constants
- `lib/gtfs_planner_web/live/gtfs/validation_result_live.ex:160-775` - render with all status states
- `lib/gtfs_planner_web/live/gtfs/station_reachability_result_live.ex:10-39` - duplicated constants
- `lib/gtfs_planner_web/live/gtfs/export_live.ex:17-36` - third copy of constants

---

## 8. Station Report

`StationReport2Live` (`station_report_2_live.ex:1-486`) renders a comprehensive station audit dashboard.

### 8.1 Report Sections

The report (`station_report_2_components.ex:12-46`) has six sections navigable via table of contents:

1. **Station Inventory** - Node counts by location type (0-4), edge counts by pathway mode (1-7), directionality stats (bidirectional/unidirectional), level table with name/index/node counts.

2. **Data Quality** - Structural checks: orphaned nodes, duplicate IDs, missing parents, required children. Each check has pass/warn/fail status with detail layouts (tables, stop ID lists with reasons).

3. **GPS Checks** - Coordinate presence, longitude sign consistency, entrance distance, clustering.

4. **Naming & ID Conventions** - Title case check, prefix convention checks (`node_`, `boarding_`, `entrance_`), prefix/type alignment, auto-generated name detection. Expandable violation panels with affected stop IDs.

5. **Reachability & Connectivity** - Three dimensions: entrance→platform, platform→platform, platform→exit. Each shows:
   - Summary rows with reachable/unreachable target stops per source
   - Expandable route details (View 2) with time/distance/accessibility per target
   - Further expandable step-by-step itineraries (View 3) with mode, stop name, instruction, time, distance, grouped by level

6. **Pathway Field Completeness** - Fill rate progress bars for optional pathway fields (traversal time, stair count, slope, min width, signage) grouped by pathway mode.

### 8.2 Entity Editing

The report includes a drawer (`entity_drawer`, `station_report_drawer_components.ex:1-148`) for inline editing of stops and pathways directly from the report:
- Stop edit: stop_name, stop_lat, stop_lon, level_id, wheelchair_boarding, platform_code.
- Pathway edit: traversal_time, length, min_width, stair_count, max_slope, is_bidirectional, signposted_as, reversed_signposted_as.
- After save, the report rebuilds from a fresh snapshot.

### Evidence

- `lib/gtfs_planner_web/live/gtfs/station_report_2_live.ex:51-100` - handle_params with snapshot
- `lib/gtfs_planner_web/live/gtfs/station_report_2_components.ex:12-46` - TOC sections
- `lib/gtfs_planner_web/live/gtfs/station_report_2_components.ex:83-186` - station inventory
- `lib/gtfs_planner_web/live/gtfs/station_report_2_components.ex:598-625` - connectivity section
- `lib/gtfs_planner_web/live/gtfs/station_report_2_connectivity_components.ex:75-115` - source group card
- `lib/gtfs_planner_web/live/gtfs/station_report_drawer_components.ex:53-96` - stop edit form

---

## 9. Station Reachability

`StationReachabilityLive` (`station_reachability_live.ex:1-1247+`) provides station-scoped pathways validation.

### 9.1 Workflow

1. **Load station** (handle_params, lines 98-144): Validates station exists, loads walkability test cases, recent runs.
2. **Run reachability** (lines 834-863): Checks for existing active run (resumes if found), otherwise starts new run.
3. **Poll for status** (lines 904-1044): Polls `get_pathways_trip_test_status/1` at 250ms intervals. Handles "pending", "started", "running", "completed", "failed" statuses.
4. **Retry results** (lines 950-982): When completed but results aren't available yet, retries up to 40 times (10 seconds total).
5. **Display results** (lines 323-448): Trip overview (total/pass/warning/fail), per-test case results table, link to full result page.
6. **Recent runs** (lines 450-517): Table of past reachability runs for this station.

### 9.2 Test Case Management

- Lists walkability tests for the station with stop, address, expected traversable/wheelchair, description, updated_at.
- Edit test case via drawer with same form as diagram editor.
- Delete test case with OTP artifact purge.

### 9.3 Shared Infrastructure

Heavily reuses components from `ExportLive` and `StationDiagramLive`:
- Import of `StationDiagramComponents` for `walkability_test_drawer`.
- `ExportLive.classify_pathways_failure_category/1` and `ExportLive.present_pathways_failure/1` for error display.
- Same `@pathways_failure_messages` constant (4th copy across the codebase).
- Same OTP data requirements summary.

### Evidence

- `lib/gtfs_planner_web/live/gtfs/station_reachability_live.ex:57-95` - mount
- `lib/gtfs_planner_web/live/gtfs/station_reachability_live.ex:98-144` - handle_params
- `lib/gtfs_planner_web/live/gtfs/station_reachability_live.ex:834-863` - run_reachability
- `lib/gtfs_planner_web/live/gtfs/station_reachability_live.ex:904-1044` - polling loop
- `lib/gtfs_planner_web/live/gtfs/station_reachability_live.ex:1127-1152` - error panel assignment

---

## 10. Administrative Interfaces

### 10.1 Dashboard

`DashboardLive` (`dashboard_live.ex:1-131`) is the landing page after authentication. It:
- Computes organization and version context from session and `current_user`.
- Responds to `:gtfs_version_renamed` PubSub message to keep version dropdowns fresh.
- Shows admin link for system administrators.
- Shows organization name for regular users.

### 10.2 System Administrator: Organizations

`Admin.OrganizationsLive` (`admin/organizations_live.ex:1-549`) manages all organizations:
- **Index**: Streamed table of organizations with Edit/View actions.
- **New/Edit**: Drawer-based forms with name and alias fields. Alias has auto-formatting hint.
- **Show**: Organization details with member list. Members show email, roles (badges), status (Active/Deactivated), and actions (Resend Invite, Activate/Deactivate).
- **Invite**: Drawer-based form with email and role checkboxes. Validates email format client-side and requires at least one role.
- Uses `push_patch` for drawer open/close navigation.

### 10.3 Organization Admin: Users

`Admin.UsersLive` (`admin/users_live.ex:1-488`) manages users within the current organization:
- **Index**: Table of members with email, roles, status, actions (Resend Invite, Activate/Deactivate).
- **Invite**: Drawer with email and role checkboxes. Uses `checkbox_group` component.
- **Organization Settings**: Drawer with organization name edit form.
- **Role management**: Same two roles as admin orgs (`pathways_studio_admin`, `pathways_studio_editor`).

### 10.4 Organization Users

`ManageUsersLive` (`manage_users_live.ex:1-277`) is similar to `Admin.UsersLive` but appears to be an alternative/organization-scoped user management interface with invite, resend, role update, remove user. Uses streams.

### 10.5 API Keys

`ApiKeyLive` (`api_key_live.ex:1-247`) manages API keys for an organization:
- **Create**: Form with description and roles (Administrator/Read Only), shows one-time token display with copy-to-clipboard via `push_event`.
- **List**: Streamed list of existing keys with description, version, roles, created date, and delete button with confirmation.
- **Delete**: Validates key belongs to organization before deleting.

### 10.6 User Settings

`UserSettingsLive` (`user_settings_live.ex:1-247`) handles email and password changes:
- Two separate forms with live validation.
- Email change requires current password, sends confirmation to new address.
- Password change follows standard current + new + confirm pattern.
- Shows email change history (pending/confirmed tokens).

### Evidence

- `lib/gtfs_planner_web/live/dashboard_live.ex:10-26` - mount
- `lib/gtfs_planner_web/live/admin/organizations_live.ex:395-548` - full render
- `lib/gtfs_planner_web/live/admin/users_live.ex:365-487` - full render with drawers
- `lib/gtfs_planner_web/live/api_key_live.ex:132-155` - mount
- `lib/gtfs_planner_web/live/user_settings_live.ex:117-129` - mount with form state

---

## 11. Risk Assessment & Ambiguities

### 11.1 Identified Risks

| # | Risk | Severity | Location | Details |
|---|------|----------|----------|---------|
| 1 | **Code duplication in validation results** | Medium | `validation_result_live.ex`, `station_reachability_result_live.ex`, `export_live.ex`, `station_reachability_live.ex` | `@pathways_failure_messages` (33 entries) and `@otp_data_requirements_summary` duplicated 4 times. `sorted_notices/1`, `get_sample_notices/1`, `extract_filename/1`, `format_count/1` duplicated in 2 files. Changes must be synchronized manually. |
| 2 | **Version-switching pattern duplication** | Medium | 11 files | The `handle_event("gtfs_version_loaded", ...)` and `valid_version_for_org?/2` patterns are repeated verbatim across all GTFS LiveViews. The `valid_version_for_org?/2` function with `try/rescue` for `Ecto.Query.CastError` appears in 7+ files. |
| 3 | **Large mount assigns** | Low | `station_diagram_live.ex:26-112` | Mount initializes 100+ assigns. Many are reset to default values. The sheer number of state variables increases cognitive load and risk of stale state. |
| 4 | **Walkability test duplication** | Medium | `station_diagram_live.ex`, `station_reachability_live.ex` | Walkability test CRUD (save/edit/delete, form validation, geocoding autocomplete) is duplicated between the diagram editor and reachability page with minor differences. |
| 5 | **Async task lifecycle** | Medium | `import_live.ex:196-221`, `export_live.ex` | `Task.async` and `Task.Supervisor.async_nolink` are used for long-running operations. If the LiveView process dies during import/export, the task may become orphaned. Progress is communicated via PubSub subscription that must be set up before the task starts. |
| 6 | **Atom creation from user input** | Low | Multiple files | `parse_atom/2` in routes/stops uses `String.to_existing_atom` (safe). `parse_mode/1` uses whitelisting. `select_export_type` uses whitelist. `toggle_validation` uses whitelist. All known atom creation points are properly guarded. |
| 7 | **Station report snapshot staleness** | Low | `station_report_2_live.ex` | After editing a stop in the report drawer, the entire report is rebuilt from a fresh snapshot. While the rebuild is synchronous, no optimistic UI update is provided. |
| 8 | **Missing `mount` guard for unauthenticated access to GTFS pages** | Low | All GTFS LiveViews | GTFS LiveViews rely on `on_mount` hooks from the router's `live_session` scope. If a route is misconfigured, there is no in-mount fallback check. |

### 11.2 Ambiguities

| # | Ambiguity | Location | Question |
|---|-----------|----------|----------|
| 1 | **`ManageUsersLive` vs `Admin.UsersLive`** | `manage_users_live.ex`, `admin/users_live.ex` | Both manage users within an organization but have different UIs, role options, and event handler patterns. It's unclear whether `ManageUsersLive` is a legacy view being replaced or an alternative path. |
| 2 | **`ComponentsLive` purpose** | `components_live.ex` | Appears to be a developer-facing UI component demo page for the address autocomplete. It is unclear whether this is intended for end users or is a development-only page that should be conditionally mounted. |
| 3 | **Station diagram `audit_ctx` build** | `station_diagram_live.ex:348-363` | `AuditContext` requires `actor_id` and `actor_email` from `current_user`. If `current_user` is somehow nil (should not happen due to auth guards), this would crash. |
| 4 | **Unified pathways failure handling** | 4 files | The `@pathways_failure_messages` map has subtle differences between files (e.g., `StationReachabilityLive` adds `pathways_stale_active_run` which others lack). It's unclear which is canonical. |

### Evidence

- Duplication across `lib/gtfs_planner_web/live/gtfs/validation_result_live.ex:9-39`, `lib/gtfs_planner_web/live/gtfs/station_reachability_result_live.ex:10-30`, `lib/gtfs_planner_web/live/gtfs/export_live.ex:17-36`, `lib/gtfs_planner_web/live/gtfs/station_reachability_live.ex:25-46`
- `valid_version_for_org?` duplication in `import_live.ex:1101-1110`, `export_live.ex:1138-1147`, `routes_live.ex:403-412`, `stops_live.ex:427-436`, `stop_detail_live.ex:376-385`, `route_detail_live.ex:230-239`, `station_reachability_live.ex` (similar pattern), `station_report_2_live.ex:426-435`
- `lib/gtfs_planner_web/live/manage_users_live.ex:1-277` vs `lib/gtfs_planner_web/live/admin/users_live.ex:1-488`
