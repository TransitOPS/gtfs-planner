---
id: JREG-001
title: Journey registry
type: journey-registry
status: draft
owner: gtfs-planner
last_reviewed: 2026-10-01
review_interval_days: 90
verified_against:
  - gtfs-planner@63d2aa8012b59349aadc618b05449cb2d6437b51
repos:
  - name: gtfs-planner
    path: /Users/ryanmahoney/.worktrees/gtfs-planner/31-ux-journey-qa
    role: product monolith — multi-tenant GTFS authoring, validation and export; a companion JSON API for station editor integrations
    hosts: [localhost in local runs]
derived_from:
  - docs/screen-inventory.md@b18c9df3
  - docs/inventories/public-authentication-screens.md@b18c9df3
  - docs/inventories/shared-account-screens.md@b18c9df3
  - docs/inventories/gtfs-operation-screens.md@b18c9df3
  - docs/inventories/gtfs-configuration-screens.md@b18c9df3
  - docs/inventories/organization-administration-screens.md@b18c9df3
  - docs/inventories/instance-administration-screens.md@b18c9df3
  - docs/inventories/design-system-screens.md@b18c9df3
  - docs/feature-list.md@b18c9df3
  - docs/requirements/@b18c9df3
  - docs/manual-test-plan.md@b18c9df3
  - docs/information-architecture.md@b18c9df3
  - assets/e2e/@63d2aa8
  - lib/gtfs_planner_web/components/navigation.ex@63d2aa8
  - lib/gtfs_planner_web/live/gtfs/settings_live.ex@63d2aa8
  - lib/gtfs_planner_web/router.ex@63d2aa8
  - docs/routes-and-access.md@63d2aa8
journeys: [JRNY-001, JRNY-002, JRNY-003, JRNY-004, JRNY-005, JRNY-006, JRNY-007, JRNY-008, JRNY-009, JRNY-010, JRNY-011, JRNY-012, JRNY-013, JRNY-014, JRNY-015, JRNY-016, JRNY-017, JRNY-018, JRNY-019, JRNY-020, JRNY-021, JRNY-022, JRNY-023, JRNY-024, JRNY-025, JRNY-026, JRNY-027, JRNY-028, JRNY-029, JRNY-030, JRNY-031, JRNY-032, JRNY-033, JRNY-034, JRNY-035, JRNY-036, JRNY-037, JRNY-038, JRNY-039, JRNY-040, JRNY-041, JRNY-042, JRNY-043, JRNY-044, JRNY-045, JRNY-046, JRNY-047, JRNY-048, JRNY-049, JRNY-050, JRNY-051, JRNY-052, JRNY-053, JRNY-054, JRNY-055, JRNY-056, JRNY-057, JRNY-058]
---

<a id="scope"></a>
## 1. Scope of this run

One repository: gtfs-planner, read at commit `b18c9df3` for the seeds and journeys and re-read
at `63d2aa8` for the E2E lanes and navigation destinations in sections 5 and 6. Every journey
registered here is completed by a person inside this application, in this application, on one
host. The run
followed the `build-journey-map` single-repository mode: the primary navigation's task
destinations, the home task board, the settings sections, the export and download endpoints,
the email templates, the background job runners and the committed requirement documents and
manual test plan were read as journey starts, and the screen inventory was read for the
`SCRN-###` and `INV-###` identities behind each start.

268 journey seeds were collected in the discovery run that preceded this registry. Every seed
was merged into a row below, split into rows, marked an internal lane, or carried to section 6
as a navigation destination; the merge and split ledger in section 3.2 records every decision
with its reason.

**What this run did not map.** Absence below means absence, not coverage.

| Not mapped | Why |
|---|---|
| The eleven `/api/v1` companion API routes | An integration surface with no page. Its flows are machine-client goals, not a person's journey through a screen. They appear in the External parties table as a consumer of the product. |
| The LiveView socket transports under `/live` | Framework transports that render no screen. |
| `/health` | A liveness probe for an orchestrator, not a person. |
| The design-system reference pages (`SCRN-056`, `SCRN-057`) | A design reference that holds no organization and no product role. Their seeds are internal lanes in section 3.2, not journeys. |
| Planned destinations in the information architecture | Rosters (`SCRN-030`) is a registered placeholder with no implementation, and feed-URL publishing is a Coming soon section. Where a placeholder still states a real user goal the journey is registered and marked, rather than dropped. |
| Real-time vehicle positions, in-seat transfer data and vehicle tracking | Not shipped in this repository. |

<a id="boundaries"></a>
## 2. Repositories and boundaries

| Field | gtfs-planner |
|---|---|
| Path | `/Users/ryanmahoney/.worktrees/gtfs-planner/31-ux-journey-qa` |
| Role | product monolith — authentication, tenancy, GTFS authoring, validation, export, station diagrams and a companion JSON API |
| Hostnames users see | one host; the application serves every path above it |
| What it owns | every route in the router, every database table, every background runner and every emitted file |
| Instruction file | `AGENTS.md` |

**The handoff URLs users follow.** One export download, `/gtfs/:version/export-runs/:run_id/download`,
carries a finished archive out of the application, and the token URLs the mailer sends —
`/users/confirm/:token`, `/users/reset_password/:token`, `/users/accept_invite/:token` — carry
a user back into it. Those are the only crossings that move a person or an artifact between
systems in this product.

**The hostname rewrites and content fetches.** None. One application serves its own hostnames,
and no content authored in another system is fetched into a build. The organization product
field (`planner` or `pathways`) hides areas from one organization's navigation and changes its
branding, but it never denies a route and moves nothing between systems, so it is a visibility
boundary recorded in section 7 rather than a content or host seam.

<a id="external-parties"></a>
## External parties

Who this product depends on and cannot see into. One row per party the run found.

| Party | Direction | What crosses | How the product observes the far side | Evidence file |
|---|---|---|---|---|
| Consumer of an exported feed | out | the export request; the resulting file leaves the product's control and no later step of the journey returns | the export run row and the download itself are the only observation; the product never learns what the consumer did with the file | `lib/gtfs_planner_web/controllers/gtfs_export_download_controller.ex`, the export run record |
| MobilityData GTFS Validator | out | the written feed; the notices come back | `GtfsPlanner.Gtfs.Validator.validate/3` invokes `java -jar` through `System.cmd/3` and records the notices on the validation run; nothing else of the far side is observable | `lib/gtfs_planner/gtfs/validator.ex` |
| Geoapify geocoding | out | an address or a stop pair; coordinates come back | the geocoding behaviour resolves coordinates and surfaces failures as inline notices | `lib/gtfs_planner/geocoding/geoapify.ex` |
| Geoapify street routing | out | an ordered pair of stops; a street-following path comes back | the street-routing behaviour resolves a path per pattern segment and surfaces failures as inline notices | `lib/gtfs_planner/street_routing/geoapify.ex` |
| Geoapify map tiles | out | a `{style, z, x, y}` tile request; a raster PNG comes back | `GtfsPlannerWeb.MapTilesController` proxies the tile so the key stays server-side and caches the response for 24 hours; a failure renders the tile-failure notice | `lib/gtfs_planner_web/controllers/map_tiles_controller.ex` |
| Map buildings service | out | the bounding box behind the station map overlay; building geometry comes back | `GtfsPlannerWeb.MapBuildingsController` serves `/map/buildings` and the client renders what it returns | `lib/gtfs_planner_web/controllers/map_buildings_controller.ex` |
| Email delivery (SMTP) | out | the rendered invitation, confirmation, reset and membership notices | `GtfsPlanner.Mailer` (`use Swoosh.Mailer`) returns `{:ok, metadata}`; the product learns only that delivery was accepted and never that a link was followed | `lib/gtfs_planner/mailer.ex`, `lib/gtfs_planner/accounts/user_notifier.ex` |
| Companion API client (station editor integration) | in | credentials, station and journal-photo payloads and pathways-export requests; JSON comes back | the product sees authenticated requests and recorded export rows; it has no page and never learns the client's purpose | `lib/gtfs_planner_web/api/v1/` |
| OpenTripPlanner | reference only | nothing at runtime; its walk-test role is retired | the product models pathway traversal itself and labels legacy OpenTripPlanner walk-test results as retired | `lib/gtfs_planner/routing/pathway_traversal.ex`, `lib/gtfs_planner_web/live/gtfs/validation_result_live.ex` |

<a id="journeys"></a>
## 3. Journey table

One row per journey, named by the actor's goal. Actor names follow the roles in
`GtfsPlanner.Authorization.Roles` (`administrator`, `pathways_studio_admin`,
`pathways_studio_editor`) and the audiences in the screen inventory.

| ID | Goal (actor's words) | Actor | Trigger | Terminal outcome | Status |
|---|---|---|---|---|---|
| JRNY-001 | Import a GTFS feed | organization editor | Lands on the home page with no published version yet, or opens Import from the GTFS area | The imported files are published as a new version the organization can edit | documented — `docs/journeys/JRNY-001-import-a-gtfs-feed.md` |
| JRNY-002 | Edit a route's timetable | organization editor | Opens a route's Schedules, or a trip in it | The route's exported stop times match the editor's change | documented — `docs/journeys/JRNY-002-edit-a-routes-timetable.md` |
| JRNY-003 | Export and download a validated feed | organization editor | Opens the GTFS area's Export tab and runs an export | A validated export run's ZIP is downloaded | registered |
| JRNY-004 | Sign in to GTFS Planner | signed-out visitor | Follows a link to the sign-in page or types the application's address | An authenticated session on the dashboard | registered |
| JRNY-005 | Reset a forgotten password | signed-out visitor | Opens the reset link in the password-reset email | A new password is saved and a sign-in is offered | registered |
| JRNY-006 | Confirm my email address | signed-in member or new registrant | Opens the confirmation link in the registration or update-email message | The address is confirmed and the account is usable | registered |
| JRNY-007 | Accept an invitation and join an organization | invited person | Opens the invitation link in the invitation email | A membership exists in the inviting organization | registered |
| JRNY-008 | Manage my own account settings | signed-in member | Opens account settings from the account menu on any screen | The change to name, email or password is saved | registered |
| JRNY-009 | Invite a member to my organization | organization administrator | Opens Invite from the member list | An invitation is sent and the invited person appears pending | registered |
| JRNY-010 | Change a member's role or turn off their access | organization administrator | Opens a member's row in the member list | The member's role is changed or their access is turned off | registered |
| JRNY-011 | Rename my organization | organization administrator | Opens organization settings | The organization's name is saved | registered |
| JRNY-012 | Provision and manage organizations | system administrator | Opens the organization list from the system-administrator link | The created or edited organization is saved | registered |
| JRNY-013 | Create a route | organization editor | Opens the new-route drawer from the Routes list | The route exists in the version with its identifier and mode | registered |
| JRNY-014 | Edit a route's details | organization editor | Opens a route's Details | The route's public details are saved | registered |
| JRNY-015 | Browse and filter the routes list | organization editor | Opens the Routes area | The filtered, sorted list of routes is shown | registered |
| JRNY-016 | Deactivate and reactivate a route | organization editor | Opens a route's status and removal section | The route is inactive, or active again | registered |
| JRNY-017 | Delete a route after reviewing what uses it | organization editor | Opens a route's status and removal section after reading its dependents | The route is deleted through the audited removal | registered |
| JRNY-018 | Create a stop pattern | organization editor | Opens the pattern list of a route | The pattern is saved with its ordered stops | registered |
| JRNY-019 | Compare two stop patterns | organization editor | Opens Compare patterns from a route's pattern list | The two patterns are shown side by side with their differences marked | registered |
| JRNY-020 | Set a pattern's stop times | organization editor | Opens a pattern's Timings | The pattern's arrival and departure times are saved | registered |
| JRNY-021 | Draw or generate a pattern's alignment | organization editor | Opens a pattern's Alignment | The alignment is saved for the pattern's segments | registered |
| JRNY-022 | Set a pattern's headsigns and service restrictions | organization editor | Opens a pattern's Details | The pattern's headsign and restriction are saved | registered |
| JRNY-023 | Create a service calendar | organization editor | Opens the new-calendar form | The calendar exists with its service days and date ranges | registered |
| JRNY-024 | Edit a calendar's service periods | organization editor | Opens a calendar in the editor | The period's dates are saved | registered |
| JRNY-025 | Add a calendar exception | organization editor | Opens a calendar's exceptions | The exception is saved for its date | registered |
| JRNY-026 | Review calendar coverage and staleness | organization editor | Opens the calendar list or its coverage view | The coverage, gaps and expiring periods are read | registered |
| JRNY-027 | Duplicate a calendar for a future changeover | organization editor | Duplicates a calendar from the calendar list | The copy exists with its trips and a later start date | registered |
| JRNY-028 | Combine calendars into one | organization editor | Opens the combine drawer from the calendar list | The selected calendars' trips and dates are merged into one calendar | registered |
| JRNY-029 | Add a stop | organization editor | Creates a stop from the stops list or the map | The stop exists with its coordinates | registered |
| JRNY-030 | Correct a stop's location | organization editor | Opens a stop's detail | The stop's coordinates are saved | registered |
| JRNY-031 | Edit a stop's names and codes | organization editor | Opens a stop's detail | The stop's names and code are saved | registered |
| JRNY-032 | Record a stop's boarding characteristics | organization editor | Opens a stop's detail | The stop's pickup, drop-off and accessibility flags are saved | registered |
| JRNY-033 | Deactivate and delete a stop | organization editor | Opens a stop's detail after reading the patterns that use it | The stop is inactive, or deleted | registered |
| JRNY-034 | Browse and filter the station list | organization editor | Opens the Stops & stations area | The filtered list of stops is shown | registered |
| JRNY-035 | Upload and align a station floorplan | organization editor | Opens a station's Floorplans | The floorplan image is uploaded, previewed and aligned to its coordinates | registered |
| JRNY-036 | Place bays, platforms and pathways on a floorplan | organization editor | Opens a level of a station's Floorplans | The child stop and its pathways are saved | registered |
| JRNY-037 | Keep a floorplan's construction journal current | organization editor | Opens the journal panel on a floorplan | The journal entry is added and shown on the floorplan | registered |
| JRNY-038 | Read a station report and roll back an edit | organization editor | Opens a station's report | The report is read, or an audited edit is reverted | registered |
| JRNY-039 | Schedule a station closure and check step-free access | organization editor | Opens a station's evolutions | The closure is saved for its date range | registered |
| JRNY-040 | Check a station's reachability | organization editor | Runs reachability from a station | The run's station-by-station result is readable | registered |
| JRNY-041 | Define a transfer at a stop | organization editor | Opens the Transfers tab of the Routes area | The transfer rule is saved | registered |
| JRNY-042 | Review transfer coverage and conflicts | organization editor | Opens the Transfers tab | The missing, conflicting or orphaned rules are read | registered |
| JRNY-043 | Create and label a block | organization editor | Opens the Blocks area | The block exists with its label and colour | registered |
| JRNY-044 | Read a block's daily work | organization editor | Opens a block's schedule view | The block's trips for the chosen day are read | registered |
| JRNY-045 | Resolve a block's overlaps | organization editor | Opens the block overlaps panel | The reported overlap is resolved on the trip it names | registered |
| JRNY-046 | Cut blocks into operator runs | organization editor | Opens the Runs area | The run is applied and the uncovered work is read | registered |
| JRNY-047 | Shift, copy and delete trips in bulk | organization editor | Selects several trips in a route's Schedules | The bulk change is applied, with the deletion's effect shown first | registered |
| JRNY-048 | Paste a timetable from a spreadsheet | organization editor | Opens Paste timetable from a route's Schedules | The pasted timetable is applied to the route | registered |
| JRNY-049 | Represent trips as frequencies | organization editor | Converts trips to frequencies in a route's Schedules | The route's trips exist as a frequency-based representation | registered |
| JRNY-050 | Define an on-demand flex service | organization editor | Opens the Flex area | The flex service is saved with its hours and area | registered |
| JRNY-051 | Set the feed's publisher details and service dates | organization editor | Opens Feed details in settings | The publisher details, agencies and service dates are saved | registered |
| JRNY-052 | Manage the agencies that operate the routes | organization editor | Opens Agencies in settings | The agency is saved | registered |
| JRNY-053 | Group stops into fare zones and set fare rules | organization editor | Opens Fares in settings | The zone assignment or fare rule is saved | registered |
| JRNY-054 | Record garages and fleet vehicles | organization editor | Opens Garages or Fleet in settings | The garage, vehicle type or vehicle group is saved | registered |
| JRNY-055 | Choose how future exports are written | organization editor | Opens Export defaults in settings | The export defaults are saved | registered |
| JRNY-056 | Keep the published feed URL stable | organization editor | Opens Feed URL in settings | The feed URL is published at a stable address — unreachable at this commit; see section 7 | registered |
| JRNY-057 | Export a pathways feed | organization editor | Runs a pathways export from the Export tab | The pathways ZIP is downloaded | registered |
| JRNY-058 | See what this organization needs to do next | signed-in member | Lands on the dashboard | The organization's task board is shown for the filter chosen | registered |

### 3.1 Reach and evidence

| ID | Repos touched | Entry point (repo:route) | E2E lane | Document |
|---|---|---|---|---|
| JRNY-001 | gtfs-planner | gtfs-planner:`/` then `/gtfs/:version/import` (SCRN-034) | mapped in section 5 | None yet |
| JRNY-002 | gtfs-planner | gtfs-planner:`/gtfs/:version/routes/:route_id/schedules` (SCRN-019) | mapped in section 5 | `docs/journeys/JRNY-002-edit-a-routes-timetable.md` |
| JRNY-003 | gtfs-planner | gtfs-planner:`/gtfs/:version/export` (SCRN-035) | mapped in section 5 | None yet |
| JRNY-004 | gtfs-planner | gtfs-planner:`/users/log_in` (SCRN-002) | mapped in section 5 | None yet |
| JRNY-005 | gtfs-planner | gtfs-planner:`/users/reset_password/:token` (SCRN-004) | mapped in section 5 | None yet |
| JRNY-006 | gtfs-planner | gtfs-planner:`/users/confirm/:token` (SCRN-005) | mapped in section 5 | None yet |
| JRNY-007 | gtfs-planner | gtfs-planner:`/users/accept_invite/:token` (SCRN-006) | mapped in section 5 | None yet |
| JRNY-008 | gtfs-planner | gtfs-planner:`/users/settings` (SCRN-008) | mapped in section 5 | None yet |
| JRNY-009 | gtfs-planner | gtfs-planner:`/admin/users/invite` (SCRN-049) | mapped in section 5 | None yet |
| JRNY-010 | gtfs-planner | gtfs-planner:`/admin/users` (SCRN-048) | mapped in section 5 | None yet |
| JRNY-011 | gtfs-planner | gtfs-planner:`/admin/users/organization-settings` (SCRN-050) | mapped in section 5 | None yet |
| JRNY-012 | gtfs-planner | gtfs-planner:`/admin/organizations` (SCRN-051) | mapped in section 5 | None yet |
| JRNY-013 | gtfs-planner | gtfs-planner:`/gtfs/:version/routes` (SCRN-009) | mapped in section 5 | None yet |
| JRNY-014 | gtfs-planner | gtfs-planner:`/gtfs/:version/routes/:route_id` (SCRN-014) | mapped in section 5 | None yet |
| JRNY-015 | gtfs-planner | gtfs-planner:`/gtfs/:version/routes` (SCRN-009) | mapped in section 5 | None yet |
| JRNY-016 | gtfs-planner | gtfs-planner:`/gtfs/:version/routes/:route_id` (SCRN-014) | mapped in section 5 | None yet |
| JRNY-017 | gtfs-planner | gtfs-planner:`/gtfs/:version/routes/:route_id` (SCRN-014) | mapped in section 5 | None yet |
| JRNY-018 | gtfs-planner | gtfs-planner:`/gtfs/:version/routes/:route_id/patterns` (SCRN-015) | mapped in section 5 | None yet |
| JRNY-019 | gtfs-planner | gtfs-planner:`/gtfs/:version/routes/:route_id/patterns/compare` (SCRN-017) | mapped in section 5 | None yet |
| JRNY-020 | gtfs-planner | gtfs-planner:`/gtfs/:version/routes/:route_id/patterns/:route_pattern_id` (SCRN-018) | mapped in section 5 | None yet |
| JRNY-021 | gtfs-planner | gtfs-planner:`/gtfs/:version/routes/:route_id/patterns/:route_pattern_id` (SCRN-018) | mapped in section 5 | None yet |
| JRNY-022 | gtfs-planner | gtfs-planner:`/gtfs/:version/routes/:route_id/patterns/:route_pattern_id` (SCRN-018) | mapped in section 5 | None yet |
| JRNY-023 | gtfs-planner | gtfs-planner:`/gtfs/:version/calendars/new` (SCRN-012) | mapped in section 5 | None yet |
| JRNY-024 | gtfs-planner | gtfs-planner:`/gtfs/:version/calendars/show` (SCRN-013) | mapped in section 5 | None yet |
| JRNY-025 | gtfs-planner | gtfs-planner:`/gtfs/:version/calendars/show` (SCRN-013) | mapped in section 5 | None yet |
| JRNY-026 | gtfs-planner | gtfs-planner:`/gtfs/:version/calendars` (SCRN-011) | mapped in section 5 | None yet |
| JRNY-027 | gtfs-planner | gtfs-planner:`/gtfs/:version/calendars` (SCRN-011) | mapped in section 5 | None yet |
| JRNY-028 | gtfs-planner | gtfs-planner:`/gtfs/:version/calendars` (SCRN-011) | mapped in section 5 | None yet |
| JRNY-029 | gtfs-planner | gtfs-planner:`/gtfs/:version/stops` (SCRN-021) | mapped in section 5 | None yet |
| JRNY-030 | gtfs-planner | gtfs-planner:`/gtfs/:version/stops/:stop_id` (SCRN-022) | mapped in section 5 | None yet |
| JRNY-031 | gtfs-planner | gtfs-planner:`/gtfs/:version/stops/:stop_id` (SCRN-022) | mapped in section 5 | None yet |
| JRNY-032 | gtfs-planner | gtfs-planner:`/gtfs/:version/stops/:stop_id` (SCRN-022) | mapped in section 5 | None yet |
| JRNY-033 | gtfs-planner | gtfs-planner:`/gtfs/:version/stops/:stop_id` (SCRN-022) | mapped in section 5 | None yet |
| JRNY-034 | gtfs-planner | gtfs-planner:`/gtfs/:version/stops` (SCRN-021) | mapped in section 5 | None yet |
| JRNY-035 | gtfs-planner | gtfs-planner:`/gtfs/:version/stops/:stop_id/diagram` (SCRN-023) | mapped in section 5 | None yet |
| JRNY-036 | gtfs-planner | gtfs-planner:`/gtfs/:version/stops/:stop_id/diagram` (SCRN-023) | mapped in section 5 | None yet |
| JRNY-037 | gtfs-planner | gtfs-planner:`/gtfs/:version/stops/:stop_id/diagram` (SCRN-023) | mapped in section 5 | None yet |
| JRNY-038 | gtfs-planner | gtfs-planner:`/gtfs/:version/stops/:stop_id/report` (SCRN-024) | mapped in section 5 | None yet |
| JRNY-039 | gtfs-planner | gtfs-planner:`/gtfs/:version/stops/:stop_id/evolutions` (SCRN-026) | mapped in section 5 | None yet |
| JRNY-040 | gtfs-planner | gtfs-planner:`/gtfs/:version/stops/:stop_id/reachability` (SCRN-025) | mapped in section 5 | None yet |
| JRNY-041 | gtfs-planner | gtfs-planner:`/gtfs/:version/transfers` (SCRN-010) | mapped in section 5 | None yet |
| JRNY-042 | gtfs-planner | gtfs-planner:`/gtfs/:version/transfers` (SCRN-010) | mapped in section 5 | None yet |
| JRNY-043 | gtfs-planner | gtfs-planner:`/gtfs/:version/blocks` (SCRN-028) | mapped in section 5 | None yet |
| JRNY-044 | gtfs-planner | gtfs-planner:`/gtfs/:version/blocks` (SCRN-028) | mapped in section 5 | None yet |
| JRNY-045 | gtfs-planner | gtfs-planner:`/gtfs/:version/blocks` (SCRN-028) | mapped in section 5 | None yet |
| JRNY-046 | gtfs-planner | gtfs-planner:`/gtfs/:version/runs` (SCRN-029) | mapped in section 5 | None yet |
| JRNY-047 | gtfs-planner | gtfs-planner:`/gtfs/:version/routes/:route_id/schedules` (SCRN-019) | mapped in section 5 | None yet |
| JRNY-048 | gtfs-planner | gtfs-planner:`/gtfs/:version/routes/:route_id/schedules/paste` (SCRN-020) | mapped in section 5 | None yet |
| JRNY-049 | gtfs-planner | gtfs-planner:`/gtfs/:version/routes/:route_id/schedules` (SCRN-019) | mapped in section 5 | None yet |
| JRNY-050 | gtfs-planner | gtfs-planner:`/gtfs/:version/flex` (SCRN-031) | mapped in section 5 | None yet |
| JRNY-051 | gtfs-planner | gtfs-planner:`/gtfs/:version/settings/feed-details` (SCRN-039) | mapped in section 5 | None yet |
| JRNY-052 | gtfs-planner | gtfs-planner:`/gtfs/:version/settings/agencies` (SCRN-040) | mapped in section 5 | None yet |
| JRNY-053 | gtfs-planner | gtfs-planner:`/gtfs/:version/settings/fares` (SCRN-044) | mapped in section 5 | None yet |
| JRNY-054 | gtfs-planner | gtfs-planner:`/gtfs/:version/settings/garages` (SCRN-042) | mapped in section 5 | None yet |
| JRNY-055 | gtfs-planner | gtfs-planner:`/gtfs/:version/settings/export-defaults` (SCRN-041) | mapped in section 5 | None yet |
| JRNY-056 | gtfs-planner | gtfs-planner:`/gtfs/:version/settings/feed-url` (SCRN-047) | mapped in section 5 | None yet |
| JRNY-057 | gtfs-planner | gtfs-planner:`/gtfs/:version/export` (SCRN-035) | mapped in section 5 | None yet |
| JRNY-058 | gtfs-planner | gtfs-planner:`/` (SCRN-007) | mapped in section 5 | None yet |

<a id="merge-ledger"></a>
### 3.2 Merge and split ledger

Every one of the 268 discovery seeds is accounted for below. Seed IDs are the discovery run's
own identifiers and exist here as provenance only; the seed record itself is not a committed
artifact. Dispositions are `merge` (the seed became a stage of the named journey), `split` (the
seed named more than one terminal outcome and became several rows), `internal-lane` (a contract
probe that is not one actor's one goal) and `destination` (a navigation start carried to
section 6 for coverage reconciliation).

| Seed | Disposition | Journey | Reason |
|---|---|---|---|
| S-001 | merge | JRNY-008 | The account-settings lane is the account journey. |
| S-002 | split | JRNY-010, JRNY-012 | One lane covers two audiences: an organization administrator's member work and a system administrator's organizations. The actor changes, so it is two journeys. |
| S-003 | merge | JRNY-004 | The authentication lane is the sign-in journey. |
| S-004 | merge | JRNY-045 | Planning a day's blocks and acting on the problems the plan reports end in a resolved overlap. |
| S-005 | merge | JRNY-045 | The advanced plan the lane exercises is the same overlap work. |
| S-006 | merge | JRNY-028 | The combine drawer and the merge stories are one journey. |
| S-007 | merge | JRNY-026 | Reading a large version's calendar coverage within a budget is the coverage reading. |
| S-008 | merge | JRNY-024 | The calendar helper prepares and applies a service-date change to a period. Recorded in section 7 because a reasonable reading puts it with exceptions. |
| S-009 | merge | JRNY-023 | A lane spanning create, inspect and repair across three calendar journeys, anchored on creation; section 5 re-reads it. |
| S-010 | internal-lane | — | A responsive contract probe over the catalogs. It proves a product guarantee, not one actor's goal. |
| S-011 | merge | JRNY-036 | Keyboard-only floorplan editing is the same placement work reached without a pointer. |
| S-012 | merge | JRNY-053 | Grouping stops into zones is a stage of the fare journey. |
| S-013 | merge | JRNY-050 | The flex lane is the flex journey. |
| S-014 | merge | JRNY-054 | The seed names recording garages and vehicles and then exporting; the record is the outcome and the export is a stage that ends in JRNY-003. |
| S-015 | merge | JRNY-022 | The headsign lane is the headsign journey. |
| S-016 | merge | JRNY-058 | The dashboard lane names the same board as the home destination. |
| S-017 | destination | — | A navigation lane proving the header moves between areas. An affordance, not a goal. |
| S-018 | split | JRNY-001, JRNY-003 | One lane covers import and export. Two terminal outcomes: a new version exists, an archive is downloaded. |
| S-019 | merge | JRNY-001 | The upload and the diff review are stages of the import; the responsive clause is an acceptance condition on the same journey. |
| S-020 | internal-lane | — | A contract probe over drawers, confirmations and focus. |
| S-021 | merge | JRNY-039 | The evolutions lane is the closure journey. |
| S-022 | merge | JRNY-021 | Drawing a missing alignment by hand is one route to the saved alignment. |
| S-023 | merge | JRNY-021 | Generating a street-following alignment is the other route. |
| S-024 | merge | JRNY-019 | The compare lane is the compare journey. |
| S-025 | internal-lane | — | A branding contract probe over the sign-in surface. |
| S-026 | merge | JRNY-040 | The reachability lane is the reachability journey. |
| S-027 | split | JRNY-013, JRNY-014, JRNY-016, JRNY-017 | One lane covers a route's whole life. Creating, editing, deactivating and deleting end in different promises. |
| S-028 | internal-lane | — | A rendering-cost probe on a busy route map. |
| S-029 | merge | JRNY-020 | Editing a pattern's stops and timings and confirming them in the export is the timing journey with an export cross-check. |
| S-030 | merge | JRNY-002 | The trip-edit lane is the timetable journey. |
| S-031 | merge | JRNY-047 | Bulk shift, copy, paste and convert is the bulk journey. |
| S-032 | merge | JRNY-002 | The keyboard time-edit lane is the timetable journey. |
| S-033 | merge | JRNY-046 | The runs lane is the runs journey. |
| S-034 | merge | JRNY-046 | Moving along a run's pieces from the keyboard is navigation inside the run, not a separate goal. |
| S-035 | merge | JRNY-051 | The feed-details lane is the feed-details journey. |
| S-036 | internal-lane | — | A responsive and zoom contract probe over the shell and the administration surfaces. |
| S-037 | merge | JRNY-037 | The journal entry opened from the station summary is the same journal as the one added on the floorplan. |
| S-038 | internal-lane | — | A zoom legibility probe over floorplan labels. |
| S-039 | merge | JRNY-035 | The image-alignment lane is the floorplan journey. |
| S-040 | merge | JRNY-035 | Replacing a floorplan image is a stage of uploading and aligning one floorplan. |
| S-041 | internal-lane | — | A viewport and focus contract probe over the floorplans workspace. |
| S-042 | merge | JRNY-037 | Journal entries, photos and markers kept in step with the canvas are one goal with several surfaces. |
| S-043 | merge | JRNY-038 | The station-report lane is the report journey. |
| S-044 | merge | JRNY-020 | Estimating missing stop times is the timing journey. |
| S-045 | merge | JRNY-048 | The paste lane is the paste journey. |
| S-046 | merge | JRNY-041 | The lane's transfer rules are the transfer journey. |
| S-047 | internal-lane | — | A responsive contract probe over the version diff row. |
| S-101 | merge | JRNY-023 | Creating a recurring calendar is the calendar-creation journey. |
| S-102 | merge | JRNY-023 | A seasonal calendar is a variant of the same creation goal, not a journey of its own. |
| S-103 | merge | JRNY-023 | A school-year calendar is the same creation goal with different dates. |
| S-104 | merge | JRNY-023 | An exception-only calendar is created through the same form. |
| S-105 | merge | JRNY-024 | Adding a service period is the period journey. |
| S-106 | merge | JRNY-024 | Moving a period's dates is the period journey. |
| S-107 | merge | JRNY-024 | Gaps between periods on one calendar are set in the same editor. |
| S-108 | merge | JRNY-024 | Preventing period overlaps is a rule on the same editor. |
| S-109 | merge | JRNY-025 | Removing service for a date is a calendar exception. |
| S-110 | merge | JRNY-025 | Swapping one day of service for another is a calendar exception. |
| S-111 | merge | JRNY-025 | Adding trips on an exception date is the same goal from a different entry. |
| S-112 | merge | JRNY-025 | Replicating the previous year's exceptions is the same goal. |
| S-113 | merge | JRNY-025 | Applying one exception to several dates is the same goal. |
| S-114 | merge | JRNY-026 | The sortable, filterable calendar list is the coverage reading. |
| S-115 | merge | JRNY-026 | Seeing what uses a calendar is part of the same reading. |
| S-116 | merge | JRNY-026 | Periods ending soon are the same staleness question. |
| S-117 | merge | JRNY-027 | Duplicating a calendar for a changeover has its own outcome: a copy that exists alongside the original. |
| S-118 | merge | JRNY-028 | Merging calendars into one is the combine journey. |
| S-119 | merge | JRNY-028 | Moving trips to a dedicated calendar is the other half of the same drawer. |
| S-120 | merge | JRNY-026 | Warnings about date ranges with no active periods are the coverage reading. |
| S-121 | merge | JRNY-026 | The chronological exception view is the same reading of upcoming service. |
| S-122 | merge | JRNY-018 | A pattern matching one stop sequence is pattern creation. |
| S-123 | merge | JRNY-018 | Separate patterns per direction are pattern creation. |
| S-124 | merge | JRNY-018 | A shortened pattern is pattern creation. |
| S-125 | merge | JRNY-018 | A pattern with an extra stop is pattern creation. |
| S-126 | merge | JRNY-018 | A pattern that includes deviation stops is pattern creation. |
| S-127 | merge | JRNY-018 | Copying a pattern in order to modify it later is creation of a new pattern. |
| S-128 | merge | JRNY-019 | The side-by-side comparison is the compare journey. |
| S-129 | merge | JRNY-020 | Arrival times at each stop are the timing journey. |
| S-130 | merge | JRNY-020 | Peak and off-peak timed patterns are the same goal with different times. |
| S-131 | merge | JRNY-020 | Marking timepoints is a property of the same timed pattern. |
| S-132 | merge | JRNY-020 | Enabling interpolation is a property of the same timed pattern. |
| S-133 | merge | JRNY-020 | A departure that differs from the arrival is the scheduled dwell. |
| S-134 | merge | JRNY-020 | Previewing from a sample start time is a stage of the same editor. |
| S-135 | merge | JRNY-020 | No-pickup stops are a property of the same timed pattern. |
| S-136 | merge | JRNY-021 | Generating a shape from street routing is one route to the saved alignment. |
| S-137 | merge | JRNY-021 | Adjusting segment points is the other route. |
| S-138 | merge | JRNY-021 | Generating every missing alignment at once is the same goal over a set of patterns. |
| S-139 | merge | JRNY-021 | An express-only alignment is the same goal on one pattern. |
| S-140 | merge | JRNY-021 | Simplifying an alignment is a stage of the same edit. |
| S-141 | merge | JRNY-021 | The per-segment status colours are a reading aid inside the same editor. |
| S-142 | merge | JRNY-022 | A pattern-level headsign is the headsign journey. |
| S-143 | merge | JRNY-022 | Mid-trip headsign changes are the same goal at a stop. |
| S-144 | merge | JRNY-022 | A restriction headsign on one timed pattern is the same goal. |
| S-145 | merge | JRNY-018 | A loop pattern is pattern creation. |
| S-146 | merge | JRNY-018 | A stop repeated in the sequence is pattern creation. |
| S-147 | merge | JRNY-013 | Creating a route with its public identifier and colours is route creation. |
| S-148 | merge | JRNY-013 | Creating a route to migrate patterns into it is route creation. |
| S-149 | merge | JRNY-013 | Choosing a route's mode is part of creating it. |
| S-150 | merge | JRNY-014 | Setting route colours is a route detail. |
| S-151 | merge | JRNY-014 | Checking a colour pair for contrast is a reading aid inside the detail editor. |
| S-152 | merge | JRNY-014 | Setting display order is a route detail. |
| S-153 | merge | JRNY-014 | Associating URLs with a route is a route detail. |
| S-154 | merge | JRNY-014 | Renaming a route is a route detail. |
| S-155 | merge | JRNY-014 | Correcting colour values is the same detail. |
| S-156 | merge | JRNY-014 | Changing the route type is the same detail. |
| S-157 | merge | JRNY-015 | Filtering the route list is the browse goal. |
| S-158 | merge | JRNY-015 | Sorting the route list is the browse goal. |
| S-159 | merge | JRNY-015 | Flagged routes are read on the same list. |
| S-160 | merge | JRNY-016 | Marking a route inactive without deleting it is the deactivate outcome. |
| S-161 | merge | JRNY-016 | Seeing what uses a route before removal is the pre-step of the same decision. |
| S-162 | merge | JRNY-016 | Keeping a route active year-round while controlling which calendars have service is the same status decision. |
| S-163 | merge | JRNY-014 | Designating a loop route is a route detail. |
| S-164 | merge | JRNY-014 | Continuous pickup and drop-off is a route detail. |
| S-165 | merge | JRNY-014 | A school-service route type is a route detail. |
| S-166 | merge | JRNY-002 | Trips organised by calendar and service day is a reading of the same schedule. |
| S-167 | merge | JRNY-002 | The timetable view is another view of the same schedule. |
| S-168 | merge | JRNY-002 | Filtering to one calendar is the same reading. |
| S-169 | merge | JRNY-002 | Filtering by block is the same reading. |
| S-170 | merge | JRNY-002 | Filtering by direction is the same reading. |
| S-171 | merge | JRNY-002 | Creating a trip by clicking a time is the add-trip scenario of the timetable journey. |
| S-172 | merge | JRNY-002 | Inserting a pre-populated trip between existing ones is the same scenario. |
| S-173 | merge | JRNY-002 | Creating a trip from its components is the same scenario. |
| S-174 | merge | JRNY-002 | Generating trips from a headway is the same scenario by another route. |
| S-175 | merge | JRNY-002 | Moving a start time and recalculating the rest is the change-times scenario. |
| S-176 | merge | JRNY-002 | Moving a trip to another calendar is the same goal on one trip. |
| S-177 | merge | JRNY-002 | Assigning a block to a trip is the same goal on one trip. |
| S-178 | merge | JRNY-002 | Re-pointing a trip at another pattern is the same goal on one trip. |
| S-179 | merge | JRNY-002 | Deleting a trip is the same goal on one trip. |
| S-180 | merge | JRNY-002 | Reading whether a trip belongs to a block is the pre-step of the same edit. |
| S-181 | merge | JRNY-043 | Creating a labelled block is the block journey. |
| S-182 | merge | JRNY-043 | Renaming a block is the same journey. |
| S-183 | merge | JRNY-043 | Recolouring a block is the same journey. |
| S-184 | merge | JRNY-043 | Reading a block's trips is the same journey's first stage. |
| S-185 | merge | JRNY-043 | Deleting a block is the same journey. |
| S-186 | merge | JRNY-044 | Reading a block's trips in timeline and timetable is the read goal. |
| S-187 | merge | JRNY-044 | Colour by route inside a block is the same reading. |
| S-188 | merge | JRNY-044 | Filtering a block schedule to a date is the same reading. |
| S-189 | merge | JRNY-044 | Combining calendars in the block view is the same reading. |
| S-190 | merge | JRNY-045 | Flagged overlapping blocks are the overlap problem. |
| S-191 | merge | JRNY-045 | The trips and dates of an overlap are the same problem, read in detail. |
| S-192 | merge | JRNY-045 | Jumping to the offending trip is how the same problem is fixed. |
| S-193 | merge | JRNY-002 | In-seat transfer flags are properties of the same trips. |
| S-194 | merge | JRNY-002 | Wheelchair accessibility is a property of the same trips. |
| S-195 | merge | JRNY-002 | Trip short names are properties of the same trips. |
| S-196 | merge | JRNY-029 | Placing a stop by clicking is one route to creating it. |
| S-197 | merge | JRNY-029 | Creating a stop from a geocoded address is the same goal. |
| S-198 | merge | JRNY-029 | Entering coordinates directly is the same goal. |
| S-199 | merge | JRNY-030 | Dragging the pin corrects a stop's location. |
| S-200 | merge | JRNY-030 | Pasting a coordinate pair corrects the same location. |
| S-201 | merge | JRNY-031 | Editing a stop's names is the naming goal. |
| S-202 | merge | JRNY-034 | Filtering the stop list is the browse goal. |
| S-203 | merge | JRNY-034 | Unused stops are read on the same list. |
| S-204 | merge | JRNY-034 | Stops flagged for issues are read on the same list. |
| S-205 | merge | JRNY-036 | Grouping bays under a parent station is placement on the floorplan. |
| S-206 | merge | JRNY-036 | Choosing the parent station is the same placement work. |
| S-207 | merge | JRNY-036 | Platform codes are a property of the placed child stop. |
| S-208 | merge | JRNY-053 | Naming a fare zone is the fare journey. |
| S-209 | merge | JRNY-053 | Assigning many stops to a zone is the same journey. |
| S-210 | merge | JRNY-033 | Marking a stop inactive without deleting it is the deactivate outcome. |
| S-211 | merge | JRNY-033 | Seeing what uses a stop is the pre-step of the same decision. |
| S-212 | merge | JRNY-032 | Designating a stop is a boarding characteristic. |
| S-213 | merge | JRNY-032 | Requesting service by reservation is the same characteristic. |
| S-214 | merge | JRNY-052 | Entering an agency's public details is the agencies journey. |
| S-215 | merge | JRNY-052 | Updating those details is the same journey. |
| S-216 | merge | JRNY-052 | Linking a fare page to an agency is the same journey. |
| S-217 | merge | JRNY-052 | The agency language is the same journey. |
| S-218 | merge | JRNY-052 | Adding an agency to the shared feed is the same journey. |
| S-219 | merge | JRNY-052 | Agency branding is the same journey. |
| S-220 | merge | JRNY-052 | Timezone consistency is the same journey. |
| S-221 | merge | JRNY-051 | Identifying the feed publisher is feed details. |
| S-222 | merge | JRNY-051 | The feed's service period is feed details. |
| S-223 | merge | JRNY-051 | The feed version is feed details. |
| S-224 | merge | JRNY-051 | The feed language is feed details. |
| S-225 | merge | JRNY-055 | Exporting stop codes as stop_id is an export default. |
| S-226 | merge | JRNY-055 | Exporting block names as block_id is an export default. |
| S-227 | merge | JRNY-055 | Interpolated stop times are an export default. |
| S-228 | merge | JRNY-055 | GTFS-flex export is an export default. |
| S-229 | merge | JRNY-056 | Keeping the feed URL stable is the publishing goal, currently a Coming soon section. |
| S-230 | merge | JRNY-056 | Reviewing feed configuration before distribution is a stage of the same publishing goal. |
| S-231 | merge | JRNY-041 | A timed transfer between two routes is the transfer journey. |
| S-232 | merge | JRNY-041 | A recommended transfer point is the same journey. |
| S-233 | merge | JRNY-041 | Marking a transfer as not possible is the same journey. |
| S-234 | merge | JRNY-041 | A minimum transfer time is a property of the same rule. |
| S-235 | merge | JRNY-041 | A route-level rule is the same journey at a wider scope. |
| S-236 | merge | JRNY-041 | A trip-level rule is the same journey at a narrower scope. |
| S-237 | merge | JRNY-041 | Changing a rule's type is the same journey. |
| S-238 | merge | JRNY-041 | Updating a minimum transfer time is the same journey. |
| S-239 | merge | JRNY-042 | Consolidating rules into route-level ones is part of reviewing them. |
| S-240 | merge | JRNY-042 | Rules at one stop are read in the same review. |
| S-241 | merge | JRNY-042 | Rules on one route are read in the same review. |
| S-242 | merge | JRNY-042 | Intersections with no rules are the same review's gap list. |
| S-243 | merge | JRNY-042 | Conflicting rules are the same review's problem list. |
| S-244 | merge | JRNY-042 | Orphan rules are the same review's problem list. |
| S-245 | merge | JRNY-042 | Rules left by a removed route are the same review. |
| S-246 | merge | JRNY-041 | An in-seat transfer is a transfer rule. |
| S-247 | merge | JRNY-041 | A type-5 transfer is a transfer rule. |
| S-248 | merge | JRNY-002 | Creating a trip by clicking a time is the add-trip scenario. |
| S-249 | merge | JRNY-002 | Inserting a trip between two others is the same scenario. |
| S-250 | merge | JRNY-002 | Creating a trip from its components is the same scenario. |
| S-251 | merge | JRNY-002 | Generating trips from a headway is the same scenario. |
| S-252 | merge | JRNY-002 | Copying trips onto a new calendar is the same scenario. |
| S-253 | merge | JRNY-002 | Changing only a start time is the change-times scenario. |
| S-254 | merge | JRNY-002 | Shifting times with the arrow keys is the change-times scenario by the keyboard. |
| S-255 | merge | JRNY-002 | Moving a trip to another calendar is the same goal on one trip. |
| S-256 | merge | JRNY-002 | Re-pointing a trip at another pattern is the same goal on one trip. |
| S-257 | merge | JRNY-047 | Selecting several trips and editing them together ends in a bulk outcome, not a single-trip one. |
| S-258 | merge | JRNY-002 | Choosing the days a trip runs is a property of the same trip. |
| S-259 | merge | JRNY-002 | Scheduling a trip on specific dates is a property of the same trip. |
| S-260 | merge | JRNY-002 | In-seat transfers for those trips are properties of the same trips. |
| S-261 | merge | JRNY-002 | A trip headsign is a property of the same trip. |
| S-262 | merge | JRNY-002 | A trip short name is a property of the same trip. |
| S-263 | merge | JRNY-002 | Assigning trips to a block is a property of the same trips. |
| S-264 | merge | JRNY-002 | Wheelchair accessibility is a property of the same trip. |
| S-265 | merge | JRNY-002 | Bikes allowed is a property of the same trip. |
| S-266 | merge | JRNY-002 | The timeline view is another view of the same schedule. |
| S-267 | merge | JRNY-002 | The timetable grid is another view of the same schedule. |
| S-268 | merge | JRNY-002 | Filtering to one calendar is the same reading. |
| S-269 | merge | JRNY-002 | Filtering by direction is the same reading. |
| S-270 | merge | JRNY-002 | Deleting one trip is the same goal on one trip. |
| S-271 | merge | JRNY-047 | Deleting several trips at once is a bulk outcome. |
| S-272 | merge | JRNY-047 | Seeing what a bulk deletion affects is the pre-step of the same action. |
| S-273 | merge | JRNY-049 | Aggregating trips into frequencies is one direction of the same goal. |
| S-274 | merge | JRNY-049 | Expanding frequencies back into trips is the other direction. |
| S-301 | merge | JRNY-034 | The manual test plan's station list is the station list journey. |
| S-302 | merge | JRNY-035 | Adding a level to a floorplan is a stage of the floorplan journey. |
| S-303 | merge | JRNY-035 | Uploading or replacing the level's image is the same journey. |
| S-304 | merge | JRNY-036 | Placing and editing child stops is the floorplan placement journey. |
| S-305 | merge | JRNY-036 | Connecting child stops with pathways is the same journey. |
| S-306 | merge | JRNY-001 | The manual test plan's import path is the import journey. |
| S-307 | merge | JRNY-003 | The manual test plan's export and download path is the export journey. |
| S-308 | merge | JRNY-003 | The manual test plan's validation run is the same journey's second half. |
| S-309 | destination | — | Switching versions re-reads a list. It is a navigation start carried to section 6, not a goal. |
| S-401 | merge | JRNY-058 | The home task board is the dashboard journey. |
| S-402 | destination | — | The Routes area destination; a start for JRNY-013 to JRNY-022 rather than a goal. |
| S-403 | destination | — | The Calendars area destination; a start for JRNY-023 to JRNY-028. |
| S-404 | destination | — | The Operations area destination; a start for JRNY-043 to JRNY-046. |
| S-405 | destination | — | The Stops and stations destination; a start for JRNY-029 to JRNY-040. |
| S-406 | merge | JRNY-050 | Layering an on-demand service over fixed routes is the flex journey. |
| S-407 | merge | JRNY-001, JRNY-003 | The GTFS area destination names both the export and the import; the journey rows carry it. |
| S-408 | destination | — | The settings overview is a start for JRNY-051 to JRNY-056, not a goal. |
| S-409 | merge | JRNY-012 | Managing the organizations that use the product is the provisioning journey. |
| S-410 | merge | JRNY-008 | The account settings destination is the account journey. |
| S-501 | destination | — | A navigation destination for the Routes area; counted in section 6. |
| S-502 | destination | — | A navigation destination for the Calendars area; counted in section 6. |
| S-503 | destination | — | A navigation destination for the Operations area; counted in section 6. |
| S-504 | destination | — | A navigation destination for the Stops and stations area; counted in section 6. |
| S-505 | destination | — | A navigation destination for the Flex area; counted in section 6. |
| S-506 | destination | — | A navigation destination for the GTFS area, whose default tab is Export; counted in section 6. |
| S-507 | destination | — | A navigation destination for Organizations in the system-administrator link; counted in section 6. |
| S-601 | merge | JRNY-051 | The feed-details settings section is the feed-details journey. |
| S-602 | merge | JRNY-052 | The agencies settings section is the agencies journey. |
| S-603 | merge | JRNY-053 | The fares settings section is the fare journey. |
| S-604 | merge | JRNY-054 | The garages settings section is the fleet journey. |
| S-605 | merge | JRNY-054 | The fleet settings section is the same journey. |
| S-606 | merge | JRNY-055 | The export-defaults settings section is the export-defaults journey. |
| S-607 | merge | JRNY-056 | The feed-url settings section is the publishing goal, currently a Coming soon placeholder. |
| S-608 | merge | JRNY-011 | The organization-settings section is the rename journey. |
| S-609 | split | JRNY-009, JRNY-010 | Inviting sends an artifact to another person; changing a role changes this organization's record. Different outcomes, two journeys. |
| S-701 | merge | JRNY-003 | The download endpoint is the export journey's last stage. |
| S-702 | merge | JRNY-057 | The pathways archive has a different artifact and a different consumer, so it is its own row. |
| S-703 | merge | JRNY-003 | The operations archive is the same goal with a different archive type, so it is a variant rather than a row of its own. |
| S-801 | merge | JRNY-006 | The confirmation link is the confirm journey's entry. |
| S-802 | merge | JRNY-006 | Confirming a new address is the same goal from a different message. |
| S-803 | merge | JRNY-005 | The reset link is the reset journey's entry. |
| S-804 | merge | JRNY-007 | The invitation link is the invitation journey's entry. |
| S-805 | merge | JRNY-007 | The membership notice's login link is an alternate entry to the same joined organization. |
| S-901 | merge | JRNY-001 | The background importer is a stage of the import; the user reads its result, not the runner. |
| S-902 | merge | JRNY-003 | The export runner ends in the downloaded archive. |
| S-903 | merge | JRNY-003 | The validation runner ends in the same validated archive. |
| S-904 | merge | JRNY-040 | The reachability runner ends in the result screen the reader opens. |

<a id="seams"></a>
## 4. Seam ledger

The shared truth the journey pages reference. One row per seam, permanent `SEAM-###` IDs.
Content-sync and host-rewrite do not arise in a single-application registry and are recorded as
not applicable rather than left to be invented.

| ID | Journey | Type | Crossing | Carries | Lost at the crossing | Evidence |
|---|---|---|---|---|---|---|
| SEAM-001 | JRNY-004 and every authenticated journey | identity | `/users/log_in` → any authenticated route | the session; the organization and version context is re-derived on the destination's mount | the page the user was on, any filter or selection held in it, and the scroll position; the destination mounts from scratch | `lib/gtfs_planner_web/router.ex` live_session hooks, `GtfsPlannerWeb.AssignOrganization`, `GtfsPlannerWeb.AssignGtfsVersion` |
| SEAM-002 | JRNY-006 | identity | the confirmation email's `/users/confirm/:token` → `/users/settings` | the single-use token and the account it identifies | which address was being confirmed and from which page; the token cannot be replayed once spent | `GtfsPlannerWeb.UserSettingsLive`, `GtfsPlanner.Accounts` confirmation functions |
| SEAM-003 | JRNY-005 | identity | the reset email's `/users/reset_password/:token` → the reset form | the single-use reset token | the reason the reset was requested; nothing about the previous password state travels | `GtfsPlannerWeb.UserAuthController.reset_password`, `GtfsPlanner.Accounts` reset functions |
| SEAM-004 | JRNY-007 | identity | the invitation email's `/users/accept_invite/:token` → the signed-in dashboard | the invitation token, which carries the organization and the role | the inviter's context and any message they typed; after acceptance the token is spent | `GtfsPlannerWeb.UserAuthController.accept_invite`, `GtfsPlanner.Accounts` invitation functions |
| SEAM-005 | JRNY-003 | third-party | the Export tab → `java -jar` on the tracked MobilityData validator | the written feed's bytes and the notices that come back | everything the validator does internally: only its notices and error counts are observable, and a crashed process is visible only as an error record | `lib/gtfs_planner/gtfs/validator.ex` |
| SEAM-006 | JRNY-029, JRNY-030, JRNY-054 | third-party | the stop or garage form → the Geoapify geocoding API | an address or a name; resolved coordinates come back | the address's original wording is not restated after resolution, and the product never learns the match's provenance beyond the coordinates | `lib/gtfs_planner/geocoding/geoapify.ex` |
| SEAM-007 | JRNY-021 | third-party | the pattern's Alignment task → the Geoapify street-routing API | an ordered pair of stops; a street-following path comes back | nothing about the requested routing profile or the provider's confidence survives into the saved shape; a failure leaves the segment unaligned with an inline notice | `lib/gtfs_planner/street_routing/geoapify.ex` |
| SEAM-008 | JRNY-029, JRNY-030, JRNY-034, JRNY-036 | third-party | the browser's map tile request → `GtfsPlannerWeb.MapTilesController` → the tile service | the `{style, z, x, y}` request; a raster PNG comes back | the map's state on failure: the tile is simply absent and the failure is a notice, so the user's zoom and pan are not restored | `lib/gtfs_planner_web/controllers/map_tiles_controller.ex` |
| SEAM-009 | JRNY-035 | third-party | the station map's bounding box → `/map/buildings` | the bounding box; building geometry comes back | which buildings the product decided were relevant; the client renders whatever the service returned and no selection is recorded | `lib/gtfs_planner_web/controllers/map_buildings_controller.ex` |
| SEAM-010 | JRNY-003, JRNY-057 | handoff | `/gtfs/:version/export-runs/:run_id/download` → the consumer's filesystem | the finished archive and its file name | everything downstream: no later step of the journey returns, and the product never learns who downloaded it or what they did with the file | `lib/gtfs_planner_web/controllers/gtfs_export_download_controller.ex`, the export run row |
| SEAM-011 | JRNY-005, JRNY-006, JRNY-007, JRNY-009 | handoff | the application's mailer → the recipient's mailbox → a token URL back into the product | the rendered notice and the token inside it | delivery itself: the product learns only that the message was accepted, never that it arrived, was opened, or that the link was followed | `lib/gtfs_planner/mailer.ex`, `lib/gtfs_planner/accounts/user_notifier.ex` |
| SEAM-012 | JRNY-007 | handoff | the membership notice's login link → sign-in → the new organization's dashboard | the login link and, after sign-in, the organization the membership binds the user to | which organization was invited; the notice names it, but the sign-in screen does not, so a user with two memberships chooses unaided | `GtfsPlanner.Accounts.Notifier` membership notice, `GtfsPlannerWeb.AssignOrganization` |
| SEAM-013 | all journeys | content-sync | not applicable | — | nothing is authored or stored in another system and rendered here; the requirement documents are inputs to this documentation set, not a runtime fetch | `docs/requirements/`, `docs/information-architecture.md` |
| SEAM-014 | all journeys | host-rewrite | not applicable | — | one application serves every hostname it answers on, and no registered route is rewritten behind a hostname that does not match it | `lib/gtfs_planner_web/router.ex` |

<a id="e2e-mapping"></a>
## 5. E2E lane mapping

Every `assets/e2e/*.spec.js` file read at `63d2aa80` appears exactly once below, keyed by spec
file name. The **E2E ID** column carries the path relative to `assets/e2e/`; the **title** column
carries the file's own `test.describe` title, or its file-header comment when the file has no
describe block. A row whose **Journey** column holds a `JRNY-###` names the one registered row
that lane proves; a row marked `internal-lane` is a contract probe rather than one actor's goal,
and the **Reason** column says which.

| E2E ID | Title | Journey | Reason |
|---|---|---|---|
| `account_design_contracts.spec.js` | account navigation, dashboard, account settings, account motion and reconnect, account password mutation | internal-lane | A contract probe across four surfaces at three viewports. Its one password-mutation case reaches JRNY-008's form but proves session replacement, not the settings journey. |
| `admin_design_contracts.spec.js` | Administration routing and authorization, Shared member presentation, Organization-admin invitation workflow, Organization-admin member mutations, System-admin organization workflows, Administration layout constraints, Administration reduced motion | internal-lane | A layout, motion and authorization probe over the administration surfaces. The invitation and member cases stage JRNY-009 and JRNY-010, and the organization cases stage JRNY-012. |
| `authentication.spec.js` | Public auth flows (serial), Public auth accessibility contracts | JRNY-004 | Signs in, recovers from every failure state, and opens each token URL. The reset, confirm and invite token cases are the entries to JRNY-005, JRNY-006 and JRNY-007. |
| `blocks.spec.js` | Blocks workspace 1440x1000, Blocks page at 375x812, reference prototype captures, qa tour, theme scope against a Routes page | JRNY-043 | Creates, labels, recolours, reads and deletes blocks against the seeded plan. |
| `blocks_advanced.spec.js` | advanced Blocks page at 1440x1000, advanced Blocks timeline track at 1440x1000, advanced Blocks List view at 375x812, reference prototype captures, qa tour | JRNY-045 | Drives the plan's two seeded problems to resolution through the relief and preview-selected states. |
| `calendar_combination.spec.js` | calendar combination | JRNY-028 | Combines calendars and reads the merge results. |
| `calendar_coverage_resources.spec.js` | calendar coverage resources | JRNY-026 | Reads coverage at the sourced 100-calendar scale and asserts the projection's bin and day-cell bounds. |
| `calendar_helper.spec.js` | helper journey, helper panel layout, drawer review | JRNY-024 | Prepares and applies a service-date change to a period through the helper. |
| `calendars.spec.js` | calendar list, calendar coverage, calendar coverage details, calendar editor, cross-calendar date change drawer | JRNY-026 | The list, coverage and coverage-detail reading is the bulk of the file; its editor and cross-calendar drawer cases are the period and exception work of JRNY-024 and JRNY-025. |
| `catalog_design_contracts.spec.js` | Route catalog responsive contracts, Stop catalog responsive contracts, Route detail responsive contracts, Station detail responsive contracts, Route pattern editor responsive contracts, Route schedules contracts, Empty and partial catalog states, Stable ID contracts, Reduced motion contracts | internal-lane | A responsive, motion and empty-state probe over six catalogs at four widths. It proves guarantees that hold for many journeys rather than one goal. |
| `diagram_keyboard.spec.js` | Diagram keyboard navigation, Diagram mode switching via keyboard, Diagram pan and zoom keyboard accessibility, Diagram focus indicator, Diagram reduced-motion accessibility | JRNY-036 | Adds and connects child stops, switches modes and pans from the keyboard alone. |
| `fare_zones.spec.js` | fare zones journey | JRNY-053 | Names zones, assigns stops and reads the resulting workspace. |
| `flex.spec.js` | list, list-map, create, service, service-sections, export-flex, area-editor, area-edit-points, export-defaults, flex journey | JRNY-050 | Defines an on-demand service and its area, then exports it. |
| `garages_fleet.spec.js` | Garages, Fleet and operations export | JRNY-054 | Records garages and fleet and reads the operations archive; the archive itself ends in JRNY-003. |
| `headsign_propagation.spec.js` | usage line on details, edit save and undo on details, review drawer renders, exceptions drawer fixes a typo, timing headsign disclosure, riders see column, patterns list headsign column, schedules headsign facts | JRNY-022 | Reads and edits a pattern's headsign and the surfaces that repeat it. |
| `home.spec.js` | homepage states | JRNY-058 | Measures all seven task-board states an organization can land on. |
| `ia_navigation.spec.js` | integrated header and destinations at each viewport, header presentation, organization administrator fallback | internal-lane | A navigation probe that opens the two header menus and composes each destination at two viewports. It proves the header moves between areas, not a goal. |
| `import_export.spec.js` | durable import and export browser journeys | JRNY-001 | Uploads, reviews the diff, applies, exports and downloads. The download case is JRNY-003's terminal stage. |
| `import_upload_visual.spec.js` | import upload presentation stays usable at desktop and mobile widths, durable diff review remains readable at desktop and mobile widths | JRNY-001 | The presentation and readability conditions on the same upload and diff stages. |
| `overlays.spec.js` | Closed overlay semantics, Open overlay modality, Dismissal and nesting, Focus behavior, Pending and recovery, Presentation and motion, confirmation dialog defaults, review dialog | internal-lane | A contract probe over drawers, dialogs and focus across every surface that opens one. |
| `pathway_evolutions.spec.js` | journey, the closure editor, the closure timeline, the station closure list, the range check, the moment access page, authoring, calendars, delete, exchange, floorplan, floorplan deletions, guards, merge-results, preview, range, rendered result | JRNY-039 | Schedules a station closure for a date range and reads the access page it produces. |
| `pattern_alignment.spec.js` | alignment shell, alignment map, manual editing journeys, point editing, point list, section actions, save dialogs, draft guards, imported shapes | JRNY-021 | Draws, edits and saves a pattern's alignment by hand. |
| `pattern_alignment_generation.spec.js` | generation journeys, generation, follow streets, bulk generation, patterns list | JRNY-021 | Generates the same alignment from street routing, singly and in bulk. |
| `pattern_compare.spec.js` | compare shell, compare picker, compare slots, compare relation, compare summary, compare stop table, compare overview, compare map, compare entry, compare journey | JRNY-019 | Compares two patterns and marks their differences. |
| `product_branding.spec.js` | editor header at each viewport, signed-out login shows both brands at each width | internal-lane | A branding probe over the header and the sign-in frame. It proves two brands render, not a goal. |
| `reachability_results.spec.js` | Reachability result routes | JRNY-040 | Reads a completed run's station-by-station result and the legacy results behind the read-only boundary. |
| `route_lifecycle.spec.js` | Complete route lifecycle journey, Create route drawer, Route details workspace, Route details save and merge, Route details dirty navigation, Route details draft preview, Route identity controls, Route color field, Route status actions, Reviewed route deletion, Lifecycle denial and stale review, Other routes context, Route connectivity recovery, Saved route map | JRNY-013 | Creates the route. Its details, status and deletion cases are JRNY-014, JRNY-016 and JRNY-017. |
| `route_lifecycle_map.spec.js` | Route map workload | internal-lane | A rendering-cost and latency probe on the 500-route workload version. It records measurements for a report and asserts only the local colour-picker bound. |
| `route_patterns.spec.js` | pattern list, empty and unlinked states, and details navigation, keyboard stop search adds a stop that must be reviewed and acknowledged, a timing save previews next-day clocks and updates only its trips, copy reorder and delete dialogs behave truthfully, a second session's stale review keeps the edits and offers Refresh review, a terminal stop addition collects explicit values before it can be applied, dirty navigation asks before discarding staged edits, a lost connection disables committing and reconnection announces recovery, the downloaded export carries the mutated pattern's exact stop times | JRNY-018 | Creates a pattern with its ordered stops. Its timing-save case is JRNY-020. |
| `route_schedules.spec.js` | Schedules editing journeys, Schedules read view at each viewport | JRNY-002 | The `change-times` and `add-trip` scenarios: editing one trip's times and creating trips, with an export cross-check. |
| `route_schedules_bulk.spec.js` | Schedules bulk journeys, Schedules bulk surface captures at each viewport | JRNY-047 | Shifts, copies and deletes several trips in one action, with the deletion's effect shown first. |
| `route_schedules_grid.spec.js` | Schedules grid geometry at each viewport, Schedules grid keyboard journeys, Schedules grid latency observation | JRNY-002 | Edits times from the grid and by keyboard, and records the grid's render latency. |
| `runs.spec.js` | Runs page at 1440x1000, reference prototype captures, qa tour | JRNY-046 | Cuts blocks into operator runs and reads the uncovered work. |
| `runs_keyboard.spec.js` | Runs duty chart roving row | JRNY-046 | Moves along a run's pieces from the keyboard inside the same runs surface. |
| `settings_agencies_feed.spec.js` | Agencies at each viewport, Feed details at each viewport, `@agencies-list`, `@agencies-create`, `@agencies-edit`, `@agencies-delete`, `@agencies-timezone`, `@feed-page`, `@feed-editor`, `@feed-drafts`, `@import-findings`, `@routes-new-route`, `@routes-onboarding`, mixed timezones, sorting and count links | JRNY-052 | Manages agencies across list, create, edit, delete and timezone. Its feed-details cases are JRNY-051. |
| `shared_design_contracts.spec.js` | Shell and navigation responsive behavior, Version switcher behavior, Routes list responsive behavior, Organizations trial responsive behavior, Reduced motion behavior, Focus and target sizes, Data view one-representation contract | internal-lane | A shell-wide contract probe over navigation, version switching, target sizes and motion. |
| `station_details_journal.spec.js` | Station Details Journal Summary | JRNY-037 | Reads the same journal as the floorplan's, opened from the station summary. |
| `station_diagram_legibility.spec.js` | Station diagram legibility | JRNY-036 | Proves label legibility while zooming. It is a reading condition on the placement surface rather than a separate goal. |
| `station_diagram_map.spec.js` | Station diagram map alignment, align workspace layout and interaction, assisted alignment, coordinate review | JRNY-035 | Uploads the floorplan and aligns it to its coordinates. |
| `station_diagram_upload.spec.js` | Station diagram replacement | JRNY-035 | Replaces a level's image, the same alignment journey. |
| `station_diagram_workspace.spec.js` | Station diagram workspace | JRNY-036 | Proves focus, context and target boundaries at three viewports on the placement workspace. |
| `station_journal_panel.spec.js` | the production journal shell, marker palette and legend, entries with no status controls, the note carried into the edit drawer, photos in an in-app viewer, focus after Escape, scrolled rows and pending entries, panel scrolling in Add and Connect | JRNY-037 | Adds a journal entry, keeps it with the canvas and reads it back. |
| `station_reports_and_history.spec.js` | Change history and rollback, Station report stop drawer, Station report keyboard and motion contracts, Station report responsive contracts, Station report print evidence, History tab keyboard contracts | JRNY-038 | Reads the report and reverts an audited edit. |
| `stop_time_estimates.spec.js` | running times fill stages fills and saves estimates, export defaults explain and persist the estimate choice, export names the missing-times handling with counts, schedules preview the imported trip's estimates | JRNY-020 | Estimates missing stop times and persists the choice as an export default. |
| `timetable_paste.spec.js` | Paste timetable shell, entry from Schedules, columns step, timetable step, review header, review matrix, row decisions, apply outcomes, Change schedule drawer, leave and version guards, browser journey at 1440px, browser journey at 390px | JRNY-048 | Pastes a spreadsheet timetable, reviews each row's decision and applies it. |
| `transfers.spec.js` | Transfers | JRNY-041 | Defines transfer rules and reads the conflicts the inspector names. |
| `version_diff_row_visual.spec.js` | version-diff row remains readable and operable at desktop and mobile widths | internal-lane | A responsive readability probe over one row. It proves a condition on JRNY-001's diff stage, not a goal. |

Forty-seven spec files, fifty-eight registered journeys: thirty-eight files map to a journey row
and nine are internal lanes. Twenty-nine journeys hold no lane of their own — they are listed in
finding 7 and ranked in section 9.

<a id="coverage"></a>
## 6. Coverage

| Measure | Count |
|---|---|
| Seeds collected | 268 |
| Journeys registered | 58 |
| Seams recorded | 14 |
| E2E spec files mapped to a journey | 38 of 47 |
| E2E spec files internal-lane | 9 of 47 |
| Navigation destinations owned | 29 |
| Navigation destinations unowned | 4 — listed below |
| Journeys documented (page exists) | 2 of 58 — `docs/journeys/JRNY-001-import-a-gtfs-feed.md`, `docs/journeys/JRNY-002-edit-a-routes-timetable.md`; the other pilot pages land in the steps after them |

**Navigation destination reconciliation.** A destination is owned when a registered journey
starts or passes through it. The primary bar in `lib/gtfs_planner_web/components/navigation.ex`
declares six task areas and each one's first path family, plus Organizations for system
administrators, and the account menu declares Settings, Profile settings and Log out.

| Destination | Source | Owner |
|---|---|---|
| `/gtfs/:version/routes` | `navigation.ex` `main_tasks/0`; `core_components.ex` route sub-nav | JRNY-015 |
| `/gtfs/:version/transfers` | `core_components.ex` route sub-nav | JRNY-042 |
| `/gtfs/:version/calendars` | `navigation.ex` `main_tasks/1` | JRNY-026 |
| `/gtfs/:version/blocks` | `navigation.ex` `main_tasks/2`; `core_components.ex` operations sub-nav | JRNY-043 |
| `/gtfs/:version/runs` | `core_components.ex` operations sub-nav | JRNY-046 |
| `/gtfs/:version/stops` | `navigation.ex` `main_tasks/3` | JRNY-034 |
| `/gtfs/:version/stops/:stop_id` | `core_components.ex` station sub-nav | JRNY-030 |
| `/gtfs/:version/stops/:stop_id/diagram` | `core_components.ex` station sub-nav | JRNY-035 |
| `/gtfs/:version/stops/:stop_id/report` | `core_components.ex` station sub-nav | JRNY-038 |
| `/gtfs/:version/stops/:stop_id/reachability` | `core_components.ex` station sub-nav | JRNY-040 |
| `/gtfs/:version/stops/:stop_id/evolutions` | `core_components.ex` station sub-nav | JRNY-039 |
| `/gtfs/:version/flex` | `navigation.ex` `main_tasks/4` | JRNY-050 |
| `/gtfs/:version/export` | `navigation.ex` `main_tasks/5`; `core_components.ex` GTFS sub-nav | JRNY-003 |
| `/gtfs/:version/import` | `core_components.ex` GTFS sub-nav | JRNY-001 |
| `/admin/organizations` | `navigation.ex` system-administrator link | JRNY-012 |
| `/admin/users` | `navigation.ex` account menu fallback | JRNY-010 |
| `/admin/users/invite` | `GtfsPlannerWeb.Admin.Components` `invite_path` | JRNY-009 |
| `/admin/users/organization-settings` | `GtfsPlannerWeb.SettingsLive` organization entry | JRNY-011 |
| `/gtfs/:version/settings` | `navigation.ex` account menu, editor branch | JRNY-051 |
| `/gtfs/:version/settings/feed-details` | `GtfsPlannerWeb.SettingsLive` `@version_pages` | JRNY-051 |
| `/gtfs/:version/settings/agencies` | `GtfsPlannerWeb.SettingsLive` `@version_pages` | JRNY-052 |
| `/gtfs/:version/settings/fares` | `GtfsPlannerWeb.SettingsLive` `@version_pages` | JRNY-053 |
| `/gtfs/:version/settings/garages` | `GtfsPlannerWeb.SettingsLive` `@all_version_pages` | JRNY-054 |
| `/gtfs/:version/settings/fleet` | `GtfsPlannerWeb.SettingsLive` `@all_version_pages` | JRNY-054 |
| `/gtfs/:version/settings/export-defaults` | `GtfsPlannerWeb.SettingsLive` `@all_version_pages` | JRNY-055 |
| `/gtfs/:version/settings/feed-url` | `GtfsPlannerWeb.SettingsLive` `@all_version_sections` | JRNY-056 (Coming soon; see section 7) |
| `/gtfs/:version/validation/:validation_id` | `GtfsPlannerWeb.Home.ChangeLinks` attention items | JRNY-003 |
| `/` | `lib/gtfs_planner_web/router.ex` line 84, the signed-in redirect target | JRNY-058 |
| `/users/settings` | `navigation.ex` account menu | JRNY-008 |

**Unowned destinations.** Each one is reachable and lands on no registered journey's start or
stage, so no journey row claims it.

| Destination | Source file | Why it is unowned |
|---|---|---|
| `/first` | `lib/gtfs_planner_web/router.ex` line 61, `GtfsPlannerWeb.FirstAdminLive` | A first-administrator setup form that names the organization and creates the administrator login. It runs once on an instance with no organization, before any account exists, and the merge ledger carries no seed to it. `SCRN-001` records the screen; no journey owns the outcome. |
| `/design` and `/design/:page` | `lib/gtfs_planner_web/router.ex` lines 90-91, `GtfsPlannerWeb.Design.DesignSystemLive` | The design-system reference pages (`SCRN-056`, `SCRN-057`). They hold no organization and no product role, so their seeds are internal lanes in section 3.2 rather than journeys. |
| `/gtfs/:version/rosters` | `lib/gtfs_planner_web/components/core_components.ex` line 1413; `lib/gtfs_planner_web/router.ex` line 174 | The Operations area's third tab. `GtfsPlannerWeb.Gtfs.ComingSoonLive` renders a Coming soon body and no journey row names a goal it reaches, so clicking it ends in a promise the product has not made. `docs/screen-inventory.md` records it as a registered placeholder (`SCRN-030`). |
| `/admin/organizations/:org_id/invite` | `lib/gtfs_planner_web/router.ex` line 123; `lib/gtfs_planner_web/live/admin/organizations_live.ex` line 970 passes it as `invite_path` | JRNY-009 covers an organization administrator inviting from `/admin/users/invite`. This entry point belongs to a different actor — the system administrator inviting into one organization's member list from that organization's detail page — and ends in a membership in an organization the inviter does not administer. No registered journey starts or passes through it. |

The dashboard task board's resume items are destinations too, and section 3's `JRNY-058` row owns
the board itself. `GtfsPlannerWeb.Home.ChangeLinks.path/2` resolves each item kind to a route that
a registered journey owns — schedules to JRNY-002, a calendar to JRNY-024, a route pattern to
JRNY-020, a station to JRNY-035, a stop to JRNY-030 and transfers to JRNY-042 — and returns `nil`
for `:none` items, which render their text without a link.

**Validation of this run's rows.** Every journey row in section 3 names one actor and one terminal
outcome; every seam in section 4 names what crosses and what is lost; and every `SCRN-###` this
registry cites appears in `docs/screen-inventory.md` or one of the seven audience inventories.

<a id="ambiguous"></a>
## 7. Ambiguous boundaries

| Journey or seam | Reading A | Reading B | Placed as | Owner to rule |
|---|---|---|---|---|
| JRNY-002 | One journey, "Edit a route's timetable", with two scenarios: `change-times` and `add-trip`. One actor, one goal, one outcome — the route's exported times match the schedule. | Two journeys: "Change a trip's times" and "Add a trip". They share the schedule screen but end in different promises: one changes a departure, the other creates service that did not exist. | One journey with two scenarios, because the goal and the terminal outcome are one and the pilot scenarios must stay addressable as `JRNY-002/change-times` and `JRNY-002/add-trip`. | product owner |
| JRNY-024 | The calendar helper prepares and applies a service-date change to a service period, so it is the period editor. | The helper's changes are date exceptions, so it belongs with JRNY-025. | JRNY-024; the helper reaches periods and exceptions in one panel, and the period is where the change lands. | product owner |
| JRNY-013, JRNY-014, JRNY-016, JRNY-017 | One journey, "Take a route from creation to removal". | Four journeys, one per terminal outcome: the route exists, its details changed, it is inactive, it is deleted. | Four rows, per the different-outcomes rule. | product owner |
| JRNY-003 | The operations archive is an export variant of the same journey. | It is a different artifact for a different consumer — the vehicle and block systems rather than a trip planner — so it is its own row beside JRNY-057. | JRNY-003 as a variant, so one row covers every archive the Export tab produces. | product owner |
| JRNY-047, JRNY-049 | Bulk editing and frequency conversion are stages of the timetable journey, so JRNY-002 stays the only schedules row. | Each ends in a different promise — a bulk change that is undoable, and a different data representation — so each is its own row. | Three rows; a scenario ID must name one goal's path, and a frequency conversion is not a timetable edit. | product owner |
| JRNY-056 | A journey: the user goal is real and is stated in the settings section. | Not a journey yet, because the section is a Coming soon placeholder and no terminal outcome is reachable at this commit. | Registered, with the outcome marked unreachable in row JRNY-056. | product owner |
| JRNY-058 | The dashboard's task board is a journey: one actor opens it and reads what is next. | It is a navigation surface, not a goal — the user always goes on to a task board item. | A row, because the board has its own terminal state (the filter chosen) and the home page is the destination most journeys start from. | product owner |
| The organization product field | The planner and Pathways Studio organizations are two products with their own journeys and deserve separate rows. | They are one product with areas hidden from one organization's navigation: nothing denies a route, so a hidden screen is still the same journey. | One set of rows, with the field recorded as a visibility boundary in section 2 rather than as a partition. | product owner |
| SEAM-012 | The membership notice's login link returns the user to the organization that invited them. | It returns them to a sign-in screen that carries no organization context, so the user with two memberships chooses unaided. | Recorded as lost context on SEAM-012; the seam states what is lost so a journey page can test it. | product owner |

<a id="findings"></a>
## 8. Findings from this run

| # | Finding | Consequence |
|---|---|---|
| 1 | `docs/routes-and-access.md` describes a left sidebar with `Stations`, `Import`, `Export`, `Validate` and `Users` entries for the Pathways Studio editor and administrator views, and an account menu of `Profile, Sign Out`. The shipped header is a horizontal task bar of six areas — Routes, Calendars, Operations, Stops & stations, Flex, GTFS — with Settings, Profile settings and Log out in the account menu and Organizations after a divider for system administrators (`lib/gtfs_planner_web/components/navigation.ex`). | The committed access document is stale against the shipped navigation. Its four editor destinations map to registered journeys only by inference, so a reader following it looks for a Validate entry that does not exist and misses Flex and Calendars. Sections 5 and 6 above are read from the code; the access document needs a re-read against `navigation.ex`. |
| 2 | The same document's Summary table grants `administrator` neither `/admin/users` nor GTFS routes, and grants `pathways_studio_admin` no GTFS routes. The router admits `/admin/users` on the same scope as `/admin/organizations` and enforces the role inside `GtfsPlannerWeb.Admin.UsersLive`'s `on_mount` (`GtfsPlannerWeb.EnsureRole.require_pathways_studio_admin`), while GTFS routes carry the `:require_gtfs_editor` plug only on the mutating paths. | The document's role matrix cannot be used to predict what a screen does, which is the same reason `OQ-004` holds: no permission model exists to read actors from. Actors in section 3 are read from the mount hooks. |
| 3 | Four journeys end in email silence: JRNY-005, JRNY-006, JRNY-007 and JRNY-009. Each one's terminal outcome depends on a message the product cannot observe — `GtfsPlanner.Mailer` returns `{:ok, metadata}` and nothing more, as SEAM-011 records. | A journey page for any of the four can only observe that the request was accepted and the token was minted. It must not assert that a message arrived, was opened, or that its link was followed; the honest assertion is the pending row the product does keep. |
| 4 | `/gtfs/:version/rosters` is a live destination no journey owns. `GtfsPlannerWeb.Gtfs.ComingSoonLive` renders a Coming soon body for it and the operations sub-nav links to it (`lib/gtfs_planner_web/components/core_components.ex` line 1413); `docs/screen-inventory.md` records it as a registered placeholder with no implementation (`SCRN-030`). | A person can click Rosters in the Operations area and reach a page that promises nothing. It is counted as unowned in section 6, and the Operations area's third tab has no terminal outcome. |
| 5 | `/gtfs/:version/settings/feed-url` is reachable from the settings overview and renders Coming soon, so JRNY-056's registered terminal outcome — a published feed URL at a stable address — is unreachable at this commit. | JRNY-056 has no documentation page until the section ships. `OQ-002` already asks whether the row is kept; until it is answered the page must not be written as if the outcome were observable. |
| 6 | `/first` names the first organization and creates its administrator login, and no registered journey starts there. The merge ledger carries no seed to it, so it appears in section 6 as unowned. | The one-time setup a new instance depends on has no journey, no lane and therefore no documentation queue entry. Either a journey is registered for it or the screen stays documented as a `SCRN-001` inventory row only. |
| 7 | Twenty-nine of the 58 registered journeys hold no lane of their own: JRNY-003, JRNY-005, JRNY-006, JRNY-007, JRNY-008, JRNY-009, JRNY-010, JRNY-011, JRNY-012, JRNY-014, JRNY-015, JRNY-016, JRNY-017, JRNY-023, JRNY-025, JRNY-027, JRNY-029, JRNY-030, JRNY-031, JRNY-032, JRNY-033, JRNY-034, JRNY-042, JRNY-044, JRNY-049, JRNY-051, JRNY-055, JRNY-056 and JRNY-057. JRNY-003 is the one case where the work is genuinely exercised: its download case runs inside `assets/e2e/import_export.spec.js`, which section 5 maps to JRNY-001 because that lane's dominant outcome is the published version. The rest are staged only. | These journeys have no lane to draw a page's expectations from, so section 9 ranks them after every journey that has one. Their pages must be written from the merge ledger's reasons and the router rather than from a run, and JRNY-003's page must say which of its cases the shared lane actually proves. |
| 8 | Nine of the 47 spec files are internal lanes: `account_design_contracts.spec.js`, `admin_design_contracts.spec.js`, `catalog_design_contracts.spec.js`, `ia_navigation.spec.js`, `overlays.spec.js`, `product_branding.spec.js`, `route_lifecycle_map.spec.js`, `shared_design_contracts.spec.js` and `version_diff_row_visual.spec.js`. Each proves a guarantee that holds across many journeys. | No journey page can cite an internal lane as its journey evidence. The guarantees they prove are recorded per journey in section 5's reason column, where a lane stages that journey's work. |

<a id="handoff"></a>
## 9. Handoff order

The queue for `document-journey`, ordered: the four pilots first, then every journey with an E2E
lane, then the journeys that have none. Each line names the evidence already in the repository.

| Order | Journey | Scenario | Existing evidence |
|---|---|---|---|
| 1 | JRNY-001 | `import` | `assets/e2e/import_export.spec.js`, `assets/e2e/import_upload_visual.spec.js`, the sample feed fixture and step 32's seed |
| 2 | JRNY-002 | `change-times` | `assets/e2e/route_schedules.spec.js`, `assets/e2e/route_schedules_grid.spec.js` |
| 3 | JRNY-002 | `add-trip` | `assets/e2e/route_schedules.spec.js` |
| 4 | JRNY-003 | `export` | `assets/e2e/import_export.spec.js`, `assets/e2e/garages_fleet.spec.js` for the operations archive |
| 5 | JRNY-018 | — | `assets/e2e/route_patterns.spec.js` |
| 6 | JRNY-019 | — | `assets/e2e/pattern_compare.spec.js` |
| 7 | JRNY-020 | — | `assets/e2e/route_patterns.spec.js`, `assets/e2e/stop_time_estimates.spec.js` |
| 8 | JRNY-021 | — | `assets/e2e/pattern_alignment.spec.js`, `assets/e2e/pattern_alignment_generation.spec.js` |
| 9 | JRNY-022 | — | `assets/e2e/headsign_propagation.spec.js` |
| 10 | JRNY-024 | — | `assets/e2e/calendar_helper.spec.js` |
| 11 | JRNY-026 | — | `assets/e2e/calendars.spec.js`, `assets/e2e/calendar_coverage_resources.spec.js` |
| 12 | JRNY-028 | — | `assets/e2e/calendar_combination.spec.js` |
| 13 | JRNY-035 | — | `assets/e2e/station_diagram_map.spec.js`, `assets/e2e/station_diagram_upload.spec.js` |
| 14 | JRNY-036 | — | `assets/e2e/diagram_keyboard.spec.js`, `assets/e2e/station_diagram_workspace.spec.js` |
| 15 | JRNY-037 | — | `assets/e2e/station_journal_panel.spec.js`, `assets/e2e/station_details_journal.spec.js` |
| 16 | JRNY-038 | — | `assets/e2e/station_reports_and_history.spec.js` |
| 17 | JRNY-039 | — | `assets/e2e/pathway_evolutions.spec.js` |
| 18 | JRNY-040 | — | `assets/e2e/reachability_results.spec.js` |
| 19 | JRNY-041 | — | `assets/e2e/transfers.spec.js` |
| 20 | JRNY-043 | — | `assets/e2e/blocks.spec.js` |
| 21 | JRNY-045 | — | `assets/e2e/blocks_advanced.spec.js` |
| 22 | JRNY-046 | — | `assets/e2e/runs.spec.js`, `assets/e2e/runs_keyboard.spec.js` |
| 23 | JRNY-047 | — | `assets/e2e/route_schedules_bulk.spec.js` |
| 24 | JRNY-048 | — | `assets/e2e/timetable_paste.spec.js` |
| 25 | JRNY-050 | — | `assets/e2e/flex.spec.js` |
| 26 | JRNY-052 | — | `assets/e2e/settings_agencies_feed.spec.js` |
| 27 | JRNY-053 | — | `assets/e2e/fare_zones.spec.js` |
| 28 | JRNY-054 | — | `assets/e2e/garages_fleet.spec.js` |
| 29 | JRNY-058 | — | `assets/e2e/home.spec.js` |
| 30 | JRNY-013 | — | `assets/e2e/route_lifecycle.spec.js` |
| 31 | JRNY-004 | — | `assets/e2e/authentication.spec.js` |
| 32 | JRNY-023 | — | none; the `calendars` lane's editor cases stage it |
| 33 | JRNY-042 | — | none; the `transfers` lane's overlap and coverage cases stage it |
| 34 | JRNY-044 | — | none; the `blocks` lane's timeline cases stage it |
| 35 | JRNY-005 | — | none; write from the seam ledger and `GtfsPlannerWeb.UserAuthController` |
| 36 | JRNY-006 | — | none; write from the seam ledger and `GtfsPlanner.Accounts` confirmation functions |
| 37 | JRNY-007 | — | none; write from the seam ledger and `GtfsPlannerWeb.UserAuthController.accept_invite` |
| 38 | JRNY-008 | — | none beyond the internal lane's password-mutation case |
| 39 | JRNY-009 | — | none; the invitation is a mail handoff, so assert only the pending member row |
| 40 | JRNY-010 | — | none; the `admin_design_contracts` internal lane stages both role changes and access removal |
| 41 | JRNY-011 | — | none |
| 42 | JRNY-012 | — | none; the `admin_design_contracts` internal lane stages organization create, edit and invite |
| 43 | JRNY-014 | — | none; the `route_lifecycle` lane's details cases stage it |
| 44 | JRNY-015 | — | none; the `catalog_design_contracts` internal lane covers the list's responsive states |
| 45 | JRNY-016 | — | none; the `route_lifecycle` lane's status cases stage it |
| 46 | JRNY-017 | — | none; the `route_lifecycle` lane's reviewed-deletion cases stage it |
| 47 | JRNY-025 | — | none; the `calendars` lane's cross-calendar drawer cases stage it |
| 48 | JRNY-027 | — | none |
| 49 | JRNY-029 | — | none; the `station_diagram` lanes stage placement, not creation from the list |
| 50 | JRNY-030 | — | none |
| 51 | JRNY-031 | — | none |
| 52 | JRNY-032 | — | none |
| 53 | JRNY-033 | — | none |
| 54 | JRNY-034 | — | none; the `catalog_design_contracts` internal lane covers the stop catalog's responsive states |
| 55 | JRNY-049 | — | none |
| 56 | JRNY-051 | — | none; the `settings_agencies_feed` lane's `@feed-*` cases stage it |
| 57 | JRNY-055 | — | none; the `stop_time_estimates` lane stages the export-defaults write |
| 58 | JRNY-056 | — | blocked by finding 5 until the section ships |
| 59 | JRNY-057 | — | none; the pathways archive has no lane |

Every one of the 58 registered journeys appears in the queue, and JRNY-002 appears twice because
its two pilot scenarios are separately addressable.

`JRNY-014` through `JRNY-017` and `JRNY-029` through `JRNY-034` share a lane with the journey
that created the record rather than holding one of their own. Writing a page for them from that
lane alone would overstate the evidence, so each line above names the lane as staging rather than
as proof.

## Open questions

- OQ-001 — `JRNY-002/change-times` and `JRNY-002/add-trip` are one journey's two scenarios under
  this reading. If the owner rules that they are two journeys, `add-trip` must be re-issued as a
  new `JRNY-###` and never reuses `JRNY-002`. Owner: product owner. Open since 2026-10-01.
- OQ-002 — `JRNY-056` is registered against a Coming soon section. Keep the row and the ID
  reserved, or withdraw the row until the section ships? The ID is permanent either way once
  issued. Owner: product owner. Open since 2026-10-01.
- OQ-003 — The dashboard board (`JRNY-058`) is registered from an inferred reading; the
  requirement documents never state it as a job. Confirm it stays a journey rather than a
  navigation destination. Owner: product owner. Open since 2026-10-01.
- OQ-004 — No permission model exists, so the actors in this registry are read from the mount
  hooks the screen inventory names. Run `build-permission-model` and re-derive the actor column
  if the two drift. Owner: product owner. Open since 2026-10-01.
- OQ-005 — The seed records that produced this registry were grouped by source rather than one
  ascending run, so seed IDs are not contiguous across the whole set. The `JRNY-###` IDs they
  produced are contiguous and are what later steps cite. Owner: none; recorded for readers of
  the merge ledger. Open since 2026-10-01.
- OQ-006 — `/first` names the first organization and creates its administrator login, and no
  registered journey starts there (section 8, finding 6). Register a journey for the one-time
  instance setup, or keep `SCRN-001` as an inventory row with no journey? Owner: product owner.
  Open since 2026-10-01.
- OQ-007 — `/admin/organizations/:org_id/invite` is a system administrator inviting into one
  organization's member list, a different actor and destination from JRNY-009's
  `/admin/users/invite` (section 6, unowned destinations). Fold it into JRNY-009 as a second
  entry, or register it as its own journey? Owner: product owner. Open since 2026-10-01.

## Changelog

| Date | Version | Change | Author |
|---|---|---|---|
| 2026-10-01 | 4 | `JRNY-002` documented at `docs/journeys/JRNY-002-edit-a-routes-timetable.md` with both pilot scenarios; its row now reads `documented` and the coverage count reads 2 of 58 | spec step 38 |
| 2026-10-01 | 3 | `JRNY-001` documented at `docs/journeys/JRNY-001-import-a-gtfs-feed.md`; its row now reads `documented` and the coverage count reads 1 of 58 | spec step 37 |
| 2026-10-01 | 2 | Reconciled the registry with the E2E suite and the shipped navigation: all 47 `assets/e2e/*.spec.js` files mapped to a journey row or an internal lane, 29 navigation destinations owned and 4 unowned with their source files, 8 findings and a 59-row documentation queue covering all 58 journeys | spec step 34 |
| 2026-10-01 | 1 | Initial registry: 268 seeds merged, split and dispositioned into 58 journeys with the three pilots issued first, 14 seams and the external parties table | spec step 33 |