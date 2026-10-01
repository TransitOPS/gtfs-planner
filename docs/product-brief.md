# Product brief — GTFS Planner

<a id="basis"></a>
## Basis

This brief describes the behavior the code and the committed documents had at `5bac78aa`, as read on
2026-10-01. It reports what was read, not what was verified. No one ran the product to produce it,
and a claim here is a reading of the code and the documents, not an observation of the running
system.

Exploration results — whether a first-time operator could complete a task, where they got stuck —
are not in this file. They belong to the local QA decks, which are written per run and stay out of
version control.

Inputs read:

| Input | Path | State |
|---|---|---|
| Feature list | `docs/feature-list.md` | Present. 109 capabilities in 13 groups, read at `afc5ad35`. |
| Screen inventory | `docs/screen-inventory.md`, `docs/inventories/*.md` | Present. 57 screens in seven audience inventories, `SCRN-001` to `SCRN-057`, reconciled at `afc5ad35`. No permission model exists, so the partition is unverified. |
| Journey registry | `docs/journey-registry.md`, `docs/journeys/` | Registry present, read at `5bac78aa`: 58 journeys, 14 seams, 47 E2E lanes mapped. The `docs/journeys/` directory does not exist yet; the pilot journey pages land in the steps after this one. |
| Job sources | `docs/requirements/*.md`, `docs/manual-test-plan.md`, `docs/information-architecture.md` | Present. Eight requirement documents carry 174 job stories between them; the manual test plan carries 41 test cases; the information-architecture document is dated 2026-09-27 against an earlier commit and marks its own planned and proposed placements. |

The requirement documents and the information-architecture document were written against earlier
commits. Where they disagree with the router, the router and the screen inventory decide; where
they mark work as planned, section 4 carries it.

<a id="1-what-it-is-and-who-uses-it"></a>
## 1. What it is and who uses it

GTFS Planner is a multi-tenant web application for producing, checking and publishing transit
feeds. An organization imports a GTFS feed into a version, edits routes, patterns, schedules,
calendars, stops, stations, transfers, fares and on-demand services, runs the feed through a
standard validator, and exports a publishable archive. A companion JSON API lets a station editor
application read stations, synchronize station data and request pathways exports. FEAT-001 to
FEAT-073 name the capabilities behind that sentence.

Five actors use it. An organization editor plans and edits a feed. An organization administrator
manages that organization's members and its name. A system administrator provisions organizations.
An integrator calls the companion JSON API. An operator runs the health probe and the command-line
import tasks, and scheduled housekeeping reconciles task leases and their artifacts.

<a id="2-what-you-can-do"></a>
## 2. What you can do

| ID | Feature | Description | Actor | Screens | Journeys |
|---|---|---|---|---|---|
| FEAT-001 | Sign in with an email address and password | A signed-out visitor submits an email address and password and reaches the dashboard. | signed-out visitor | SCRN-002 | JRNY-004 |
| FEAT-002 | Sign out | A signed-in member ends the session from the account menu. | signed-in member | SCRN-007 | none |
| FEAT-003 | Request a password reset email | A visitor asks for a reset link and the product hands back a notice that the request was accepted. | signed-out visitor | SCRN-003 | JRNY-005 |
| FEAT-004 | Choose a new password from a reset link | A visitor holding a reset link sets a password and is offered a sign-in. | signed-out visitor | SCRN-004 | JRNY-005 |
| FEAT-005 | Confirm an email address from a link | A member opening a confirmation link confirms the address and lands on account settings. | signed-in member | SCRN-005 | JRNY-006 |
| FEAT-006 | Join an organization from an invitation link | An invited person sets a password from the invitation token and a membership exists in the inviting organization. | invited person | SCRN-006 | JRNY-007 |
| FEAT-007 | Update own name, email address and password | A member edits their own account record; changing the address sends a confirmation message. | signed-in member | SCRN-008 | JRNY-008 |
| FEAT-008 | Bootstrap the first administrator and its organization | On an instance with no organization, a visitor names the organization and creates its administrator login. | system administrator | SCRN-001 | none |
| FEAT-009 | Browse the instance's organizations | A system administrator opens the organization list and enters one organization. | system administrator | SCRN-051 | JRNY-012 |
| FEAT-010 | Provision a new organization | A system administrator creates an organization, which receives a default version. | system administrator | SCRN-052 | JRNY-012 |
| FEAT-011 | Inspect and edit one organization | A system administrator reads an organization's record and its members, and changes its details. | system administrator | SCRN-053, SCRN-054 | JRNY-012 |
| FEAT-012 | Invite somebody into an organization | An administrator sends an invitation from the member list or from a named organization's page, and the invited person appears pending. | organization administrator | SCRN-049, SCRN-055 | JRNY-009 |
| FEAT-013 | List members and change their roles | An organization administrator reads the member collection and changes a member's roles per organization. | organization administrator | SCRN-048 | JRNY-010 |
| FEAT-014 | Deactivate and reactivate a member | An organization administrator removes a member's access while keeping their history, and restores it. | organization administrator | SCRN-048 | JRNY-010 |
| FEAT-015 | Rename the organization and choose its product | An organization administrator saves the organization's name and its product field. | organization administrator | SCRN-050 | JRNY-011 |
| FEAT-016 | Import a complete feed as a new version | An editor uploads GTFS files, reviews the computed change set, and publishes a new version without touching the version in view. | organization editor | SCRN-034 | JRNY-001 |
| FEAT-017 | Import station changes into the version in view | An editor applies approved station changes to the version they are viewing. | organization editor | SCRN-034 | JRNY-001 |
| FEAT-018 | Export a version's feed and download the archive | An editor runs an export, watches it progress, and downloads the finished archive. | organization editor | SCRN-035 | JRNY-003 |
| FEAT-019 | Choose how future exports are written | An editor sets export defaults, including whether a full export also writes the flex file. | organization editor | SCRN-041 | JRNY-055 |
| FEAT-020 | Check the feed with the standard feed validator | An editor runs the MobilityData validator against an export and reads one run's errors, warnings and notices. | organization editor | SCRN-035, SCRN-036 | JRNY-003 |
| FEAT-021 | Run and read station reachability validation | An editor runs reachability for one stop and reads the station-by-station outcome of the run. | organization editor | SCRN-025, SCRN-037 | JRNY-040 |
| FEAT-022 | Browse and filter a version's routes | An editor reads the version's route list, filtered and sorted, and opens one route. | organization editor | SCRN-009 | JRNY-015 |
| FEAT-023 | Create a route | An editor creates a route with its identifier and mode, and the product suggests a free short name. | organization editor | SCRN-009 | JRNY-013 |
| FEAT-024 | Edit a route's details | An editor changes a route's names, colors and mode. | organization editor | SCRN-014 | JRNY-014 |
| FEAT-025 | Activate and deactivate a route | An editor marks a route inactive so it stays out of the exported feed, and marks it active again. | organization editor | SCRN-014 | JRNY-016 |
| FEAT-026 | Delete a route after reviewing its dependents | An editor reviews the patterns and trips a route carries, then deletes it through a fingerprinted review. | organization editor | SCRN-014 | JRNY-017 |
| FEAT-027 | Order and edit a route's patterns | An editor reads a route's patterns, reorders them, adds one by placing stops on the map, and copies or deletes one. | organization editor | SCRN-015, SCRN-016 | JRNY-018 |
| FEAT-028 | Compare two patterns of one route | An editor opens two patterns side by side and reads the stops that differ. | organization editor | SCRN-017 | JRNY-019 |
| FEAT-029 | Set a pattern's stop times | An editor saves a pattern's arrival and departure times and previews the next-day clocks before saving. | organization editor | SCRN-018 | JRNY-020 |
| FEAT-030 | Draw or generate a pattern's alignment | An editor follows streets or draws a path segment by segment and saves the shape under a re-reviewed fingerprint. | organization editor | SCRN-018 | JRNY-021 |
| FEAT-031 | Set a pattern's headsign and service restrictions | An editor sets a pattern's headsign, its boarding overrides, and the trips that keep a different value. | organization editor | SCRN-018 | JRNY-022 |
| FEAT-032 | Read a route's trips and times | An editor reads one route's trips in a timeline or timetable, filtered by calendar, block or direction. | organization editor | SCRN-019 | JRNY-002 |
| FEAT-033 | Create, duplicate, edit and delete trips | An editor adds a trip, duplicates one with shifted times, edits times, and deletes one or many. | organization editor | SCRN-019 | JRNY-002 |
| FEAT-034 | Review a proposed trip change before applying it | An editor reads a computed trip change, and a stale review is refused rather than applied. | organization editor | SCRN-019 | JRNY-002 |
| FEAT-035 | Shift, copy and delete trips in bulk | An editor selects several trips and shifts, copies or deletes them, with the deletion's effect shown first. | organization editor | SCRN-019 | JRNY-047 |
| FEAT-036 | Paste a timetable from a spreadsheet | An editor pastes timetable text, reviews each row's decision, and applies the result to the route. | organization editor | SCRN-020 | JRNY-048 |
| FEAT-037 | Represent repeated service as frequencies and expand it back | An editor creates a trip's service as frequency windows, and expands a frequency service back into listed scheduled trips. | organization editor | SCRN-019 | JRNY-049 |
| FEAT-038 | Define a transfer at a stop | An editor writes a transfer rule with its scope, minimum time, route and trip sides. | organization editor | SCRN-010 | JRNY-041 |
| FEAT-039 | Review transfer coverage and conflicts | An editor reads the missing, conflicting and orphaned transfer rules a run reports. | organization editor | SCRN-010 | JRNY-042 |
| FEAT-040 | List a version's service calendars | An editor reads the version's calendars with their service dates, trip counts and status. | organization editor | SCRN-011 | JRNY-026 |
| FEAT-041 | Create a service calendar | An editor creates a calendar with its service days and date ranges. | organization editor | SCRN-012 | JRNY-023 |
| FEAT-042 | Edit a calendar's service periods | An editor adds, moves and separates a calendar's periods, and reads what else uses the calendar. | organization editor | SCRN-013 | JRNY-024 |
| FEAT-043 | Add a calendar exception | An editor suspends, swaps or adds service for a date or a set of dates. | organization editor | SCRN-013 | JRNY-025 |
| FEAT-044 | Duplicate a calendar for a changeover | An editor copies a calendar with its trips so the copy can start on a later date. | organization editor | SCRN-011 | JRNY-027 |
| FEAT-045 | Combine calendars into one | An editor merges the selected calendars' trips and dates into a single calendar. | organization editor | SCRN-011 | JRNY-028 |
| FEAT-046 | Ask the calendar helper about service dates | An editor asks the Calendars panel a question about service dates and applies the change it proposes. | organization editor | SCRN-011, SCRN-013 | JRNY-024 |
| FEAT-047 | Browse a version's stops and stations | An editor reads the version's stop and station list, filtered and sorted. | organization editor | SCRN-021 | JRNY-034 |
| FEAT-048 | Add a stop | An editor places a stop on the map, from a searched address, or from entered coordinates. | organization editor | SCRN-021 | JRNY-029 |
| FEAT-049 | Correct a stop's location, names and boarding characteristics | An editor moves a stop's coordinates and edits its names, code, pickup, drop-off and accessibility flags. | organization editor | SCRN-022 | JRNY-030 |
| FEAT-050 | Deactivate and delete a stop | An editor marks a stop inactive, or deletes it after reading the patterns that use it. | organization editor | SCRN-022 | JRNY-033 |
| FEAT-051 | Upload and align a station floor plan | An editor uploads a level's image and aligns it to its coordinates. | organization editor | SCRN-023 | JRNY-035 |
| FEAT-052 | Place bays, platforms and pathways on a floor plan | An editor places child stops on a level, gives them platform codes, and connects them with pathways. | organization editor | SCRN-023 | JRNY-036 |
| FEAT-053 | Record a station journal entry and attach a photograph | An editor writes a journal entry, attaches a photograph, pins it to a level, and closes or reopens the entry. | organization editor | SCRN-022, SCRN-023 | JRNY-037 |
| FEAT-054 | Read a station report and revert an audited edit | An editor reads the station's report sections and reverts an audited change. | organization editor | SCRN-024 | JRNY-038 |
| FEAT-055 | Schedule a station closure and preview pathway access | An editor records a scheduled pathway closure for a date range and previews access at a service moment. | organization editor | SCRN-026, SCRN-027 | JRNY-039 |
| FEAT-056 | Assign trips to blocks for a service day | An editor assigns trips to blocks for one day type and reads the plan figures and checks. | organization editor | SCRN-028 | JRNY-043 |
| FEAT-057 | Read a block's daily work and resolve its overlaps | An editor reads a block's trips in timeline and timetable, asks for suggested blocks, and resolves a reported overlap. | organization editor | SCRN-028 | JRNY-044, JRNY-045 |
| FEAT-058 | Cut blocks into operator runs | An editor applies a run over blocks for a day type and reads the work left uncovered. | organization editor | SCRN-029 | JRNY-046 |
| FEAT-059 | Manage the organization's garages | An editor records garages and reads the stop identifiers each one conflicts with. | organization editor | SCRN-042 | JRNY-054 |
| FEAT-060 | Manage vehicles and vehicle types | An editor records vehicle types and vehicles, previews a vehicle import, and applies it. | organization editor | SCRN-043 | JRNY-054 |
| FEAT-061 | Define an on-demand flex service | An editor creates a flex service with its hours, bookings, covered routes and candidate area, and reads its readiness checks. | organization editor | SCRN-031, SCRN-032, SCRN-033 | JRNY-050 |
| FEAT-062 | Group stops into fare zones and set fare rules | An editor names fare zones, assigns stops to them, and writes fare rules. | organization editor | SCRN-044, SCRN-045 | JRNY-053 |
| FEAT-063 | Run fare consistency checks | An editor runs the checks over the fares workspace and reads what they report. | organization editor | SCRN-046 | JRNY-053 |
| FEAT-064 | Set the feed's publisher details and service dates | An editor saves the publisher, agencies' feed dates, feed version and data contact. | organization editor | SCRN-039 | JRNY-051 |
| FEAT-065 | Manage the agencies that operate the routes | An editor adds, edits and deletes the agencies in the version and reads their route counts and timezone agreement. | organization editor | SCRN-040 | JRNY-052 |
| FEAT-066 | Land on a dashboard shaped by role and context | A signed-in member lands on the state their organization, version and role produce, and reloads a failing region on its own. | signed-in member | SCRN-007 | JRNY-058 |
| FEAT-067 | Read the station board and resume where you left off | A member reads the station summaries, who else is editing, and the next task for the feed. | signed-in member | SCRN-007 | JRNY-058 |
| FEAT-068 | Fetch map tiles and building outlines | The screens that draw a map fetch raster tiles through the server and building geometry for the station overlay, so the tiles need a credential. | organization editor | SCRN-023 | none |
| FEAT-069 | Read a version's stations and one station's bundle over the API | An integrator opens a session, lists the versions a member may read, lists a version's stations, and fetches one station's bundle, the same station data the station screen reads. | integrator | SCRN-022 | none |
| FEAT-070 | Synchronize a station and upload a journal photograph over the API | An integrator writes station data and journal photographs to the records the station screens read; writes require the editor role. | integrator | SCRN-022, SCRN-023 | none |
| FEAT-071 | Request and poll a pathways export over the API | An integrator requests a pathways export from route identifiers, polls it, and downloads the archive beside the archives the export screen produces. | integrator | SCRN-035 | none |
| FEAT-072 | Import raw stops, levels and pathways files from the command line | An operator runs a mix task that loads one raw file into an organization, and the loaded rows appear on the stops and station screens. | operator | SCRN-021, SCRN-023 | none |
| FEAT-073 | Browse the design system reference | A signed-in user with no organization opens the design system's section shell and its registered pages. | signed-in member | SCRN-056, SCRN-057 | none |

Every row cites at least one `SCRN-###` and either `JRNY-###` IDs or `none`. `FEAT-001` to
`FEAT-073` were issued for this brief after searching the corpus, are permanent, and are never
reused or renumbered.

<a id="3-jobs-coverage"></a>
## 3. Jobs coverage

Rows are jobs from outside the code. The source column names the committed document and, where the
source states one, its job story or test case ID.

| Job | Source | Supporting screens | Supporting journeys | Status |
|---|---|---|---|---|
| Launch a new bus line as a route with its public identifier and colors, so patterns and schedules can be built for it | `docs/requirements/routes-requirements.md` JS-ROUTE-001 | SCRN-009 | JRNY-013 | served |
| Set route colors from printed materials and see whether the text color meets contrast | `docs/requirements/routes-requirements.md` JS-ROUTE-004, JS-ROUTE-005 | SCRN-014 | JRNY-014 | served |
| Filter and sort a large route inventory by mode, agency or status | `docs/requirements/routes-requirements.md` JS-ROUTE-011, JS-ROUTE-012 | SCRN-009 | JRNY-015 | served |
| Mark a seasonal route inactive without deleting it, and reactivate it next season | `docs/requirements/routes-requirements.md` JS-ROUTE-014 | SCRN-014 | JRNY-016 | served |
| See the patterns and trips that use a route before deleting it | `docs/requirements/routes-requirements.md` JS-ROUTE-015 | SCRN-014 | JRNY-017 | served |
| Document a route that runs several service variations as separate stop patterns | `docs/requirements/patterns-and-alignments-requirements.md` JS-PAT-001, JS-PAT-002 | SCRN-015, SCRN-016 | JRNY-018 | served |
| Compare a route's patterns side by side to find the one matching a service variation | `docs/requirements/patterns-and-alignments-requirements.md` JS-PAT-007 | SCRN-017 | JRNY-019 | served |
| Mark timepoints and interpolate estimated times for the stops between them | `docs/requirements/patterns-and-alignments-requirements.md` JS-PAT-010, JS-PAT-011 | SCRN-018 | JRNY-020 | served |
| Generate a pattern's alignment from street routing, or correct a generated segment by hand | `docs/requirements/patterns-and-alignments-requirements.md` JS-PAT-015, JS-PAT-016 | SCRN-018 | JRNY-021 | served |
| See which segments of a pattern have an alignment, need one, or hold unsaved changes | `docs/requirements/patterns-and-alignments-requirements.md` JS-PAT-020 | SCRN-018 | JRNY-021 | served |
| Set a headsign on a pattern, change it mid-trip, or override it on one timed pattern | `docs/requirements/patterns-and-alignments-requirements.md` JS-PAT-021, JS-PAT-022, JS-PAT-023 | SCRN-018 | JRNY-022 | served |
| Create a calendar for year-round, seasonal or academic service | `docs/requirements/calendars-and-service-periods-requirements.md` JS-CAL-001, JS-CAL-002, JS-CAL-003 | SCRN-012 | JRNY-023 | served |
| Add and move a calendar's service periods, and keep them from overlapping | `docs/requirements/calendars-and-service-periods-requirements.md` JS-CAL-005, JS-CAL-006, JS-CAL-008 | SCRN-013 | JRNY-024 | served |
| Suspend, swap or add service for a holiday, an event, or a set of dates | `docs/requirements/calendars-and-service-periods-requirements.md` JS-CAL-009, JS-CAL-010, JS-CAL-013 | SCRN-013 | JRNY-025 | served |
| Read calendar coverage, expiring periods and service gaps before an export | `docs/requirements/calendars-and-service-periods-requirements.md` JS-CAL-014, JS-CAL-016, JS-CAL-020 | SCRN-011 | JRNY-026 | served |
| Duplicate a calendar for a changeover, preserving the current schedule | `docs/requirements/calendars-and-service-periods-requirements.md` JS-CAL-017 | SCRN-011 | JRNY-027 | served |
| Merge redundant calendars into one | `docs/requirements/calendars-and-service-periods-requirements.md` JS-CAL-018 | SCRN-011 | JRNY-028 | served |
| Review a route's whole schedule by calendar and service day, in timeline or timetable form | `docs/requirements/schedules-and-blocks-requirements.md` JS-SCHED-001, JS-SCHED-002 | SCRN-019 | JRNY-002 | served |
| Create a trip from the timeline, from the timetable, or from a headway | `docs/requirements/schedules-and-blocks-requirements.md` JS-SCHED-006, JS-SCHED-007, JS-SCHED-009 | SCRN-019 | JRNY-002 | served |
| Change a trip's start time and have the rest of the stop times recalculate | `docs/requirements/schedules-and-blocks-requirements.md` JS-SCHED-010 | SCRN-019 | JRNY-002 | served |
| See whether a trip belongs to a block before deleting it | `docs/requirements/schedules-and-blocks-requirements.md` JS-SCHED-015 | SCRN-019 | JRNY-002 | served |
| Create, rename, recolour and delete blocks, and read a block's daily work | `docs/requirements/schedules-and-blocks-requirements.md` JS-SCHED-016, JS-SCHED-017, JS-SCHED-021 | SCRN-028 | JRNY-043, JRNY-044 | served |
| Resolve a reported block overlap on the trip it names | `docs/requirements/schedules-and-blocks-requirements.md` JS-SCHED-019 | SCRN-028 | JRNY-045 | served |
| Shift several trips at once and see what a bulk deletion removes | `docs/requirements/trips-requirements.md` JS-TRIP-010 | SCRN-019 | JRNY-047 | served |
| Shift trip times with the arrow keys | `docs/requirements/trips-requirements.md` JS-TRIP-007 | SCRN-019 | JRNY-002 | served |
| Represent repeated service as frequencies rather than individual trips | `docs/requirements/trips-requirements.md` JS-TRIP-004 | SCRN-019 | JRNY-049 | served |
| Set a trip's headsign, short name, accessibility and bicycle allowance | `docs/requirements/trips-requirements.md` JS-TRIP-014, JS-TRIP-015, JS-TRIP-017, JS-TRIP-018 | SCRN-019 | JRNY-002 | served |
| Define a timed transfer at a pulse point, or block an unsuitable connection | `docs/requirements/transfers-requirements.md` JS-XFER-001, JS-XFER-003 | SCRN-010 | JRNY-041 | served |
| Define in-seat transfers, and transfers that require riders to re-board | `docs/requirements/transfers-requirements.md` JS-XFER-016, JS-XFER-017 | SCRN-010, SCRN-028 | JRNY-041 | partial |
| Read the transfer rules at a stop or on a route, and the conflicts among them | `docs/requirements/transfers-requirements.md` JS-XFER-010, JS-XFER-013 | SCRN-010 | JRNY-042 | served |
| Place a stop where riders wait, or find one from an address or a survey coordinate | `docs/requirements/stops-and-stations-requirements.md` JS-STOP-001, JS-STOP-002, JS-STOP-003 | SCRN-021 | JRNY-029 | served |
| Move a stop that was placed on the roadway onto the sidewalk | `docs/requirements/stops-and-stations-requirements.md` JS-STOP-004 | SCRN-022 | JRNY-030 | served |
| See which stops no active pattern uses, and which are flagged for issues | `docs/requirements/stops-and-stations-requirements.md` JS-STOP-008, JS-STOP-009 | — | — | none |
| Group bays under a parent station and give platforms their codes | `docs/requirements/stops-and-stations-requirements.md` JS-STOP-010, JS-STOP-012 | SCRN-023 | JRNY-036 | served |
| Group stops into named fare zones and assign stops to them | `docs/requirements/stops-and-stations-requirements.md` JS-STOP-013, JS-STOP-014 | SCRN-044 | JRNY-053 | served |
| Mark a stop out of service without deleting it | `docs/requirements/stops-and-stations-requirements.md` JS-STOP-015 | SCRN-022 | JRNY-033 | served |
| Enter the agency's public details and update them | `docs/requirements/system-configuration-requirements.md` JS-CONFIG-001, JS-CONFIG-002 | SCRN-040 | JRNY-052 | served |
| Add a partner agency and keep every agency on one timezone | `docs/requirements/system-configuration-requirements.md` JS-CONFIG-005, JS-CONFIG-007 | SCRN-040 | JRNY-052 | served |
| Put publisher contact information and the service period in the feed | `docs/requirements/system-configuration-requirements.md` JS-CONFIG-008, JS-CONFIG-009 | SCRN-039 | JRNY-051 | served |
| Export stop codes as stop_id, block names as block_id, and interpolated stop times | `docs/requirements/system-configuration-requirements.md` JS-CONFIG-012, JS-CONFIG-013, JS-CONFIG-014 | SCRN-041 | JRNY-055 | served |
| Keep the feed URL permanent so consumers' registrations survive a schedule update | `docs/requirements/system-configuration-requirements.md` JS-CONFIG-016 | — | — | none |
| Review the feed's configuration before publishing a new dataset | `docs/requirements/system-configuration-requirements.md` JS-CONFIG-017 | SCRN-039 | JRNY-051 | served |
| Import a valid GTFS file set and create a new version from it | `docs/manual-test-plan.md` IM-01, IM-03 | SCRN-034 | JRNY-001 | served |
| Run a full export, read the file inventory, and download the ZIP | `docs/manual-test-plan.md` EX-01 | SCRN-035 | JRNY-003 | served |
| Run a pathways-only export and download the pathways subset | `docs/manual-test-plan.md` EX-02 | SCRN-035 | JRNY-057 | served |
| Click export twice and have one export run | `docs/manual-test-plan.md` EX-03 | SCRN-035 | JRNY-003 | served |
| Run the MobilityData validator, watch its phases, and read errors, warnings and infos | `docs/manual-test-plan.md` MV-01, MV-02, MV-03 | SCRN-035, SCRN-036 | JRNY-003 | served |
| Read a previous validation run from the run history | `docs/manual-test-plan.md` MV-04 | SCRN-036 | JRNY-003 | served |
| Switch versions and keep the equivalent view on every screen | `docs/manual-test-plan.md` RG-01 | SCRN-007, SCRN-021 | JRNY-058 | served |
| Upload a floor plan, replace it, and have an invalid upload refused | `docs/manual-test-plan.md` SD-05, SD-06, SD-07 | SCRN-023 | JRNY-035 | served |
| Connect child stops with same-level and cross-level pathways, and delete a pathway | `docs/manual-test-plan.md` SD-12, SD-13, SD-17 | SCRN-023 | JRNY-036 | served |
| Filter the stations list by route, direction, accessibility, search, sort and page | `docs/manual-test-plan.md` ST-01 to ST-07 | SCRN-021 | JRNY-034 | partial |

`Status` is `served`, `partial`, `planned` or `none`.

### Jobs with no screen

Each of these jobs is stated in a committed document and no screen in the product serves it.

| Job | Source |
|---|---|
| Keep the feed URL at a permanent address so a consumer's registration survives a schedule update | `docs/requirements/system-configuration-requirements.md` JS-CONFIG-016. The settings section for it renders a Coming soon page, so no terminal outcome is reachable. |
| Author an operator run; the Runs screen reads runs and no surface creates one | `docs/feature-list.md`, section 5, ambiguities |
| Enter a block's deadhead times, relief points and interlining settings as their own settings | `docs/requirements/schedules-and-blocks-requirements.md`, drawers reachable from Blocks without a screen of their own (`docs/feature-list.md`, section 5) |
| Build weekly roster lines with operator assignment and a crew export | `docs/information-architecture.md`, Operations area, marked Planned |
| See which stops no active pattern uses, and which are flagged for issues | `docs/requirements/stops-and-stations-requirements.md` JS-STOP-008, JS-STOP-009. The stops list filters by route, direction, accessibility and search, and carries no unused or flagged view. |

### Screens with no job

Each of these surfaces is reachable and no committed job story accounts for it.

| Screen | Why no job accounts for it |
|---|---|
| SCRN-001 | The one-time first-administrator setup. No job story in `docs/requirements/*.md` states it, and the journey registry records no journey for it. |
| SCRN-030 | The Rosters tab renders a Coming soon body with no implementation behind it. |
| SCRN-038 | The Settings overview is a landing surface over the sections that do have jobs; no job story describes opening it. |
| SCRN-047 | The settings section slug is a catch-all route for sections that have no literal path; the sections it renders are covered elsewhere. |
| SCRN-056, SCRN-057 | The design system reference is an internal surface for the product's own UI work, not a job in the requirement documents. |

<a id="4-planned"></a>
## 4. Planned

| Item | Status | Source |
|---|---|---|
| A roster surface with weekly lines, open work, operators and assignments | Planned | `docs/information-architecture.md`, Operations area |
| A stable published feed URL, and publishing a finished export to it | Proposed | `docs/information-architecture.md`, Settings and GTFS areas |
| Splitting the GTFS Planner and Pathways Studio views into separate roles | Proposed | `docs/information-architecture.md`, Access |
| Moving the organization's Users pill under Settings › Organization | Proposed | `docs/information-architecture.md`, proposed nav changes |
| Coverage bars on a shared time axis for the Calendars list | Proposed | `docs/information-architecture.md`, Calendars area |
| The empty-version agency prompt before the first route | Proposed | `docs/information-architecture.md`, Routes list |
| Riders-stay-on-board choice on a block connection, in place of the trip form's in-seat checkbox | Proposed | `docs/information-architecture.md`, differences from the written requirements |
| Keeping the source calendars when trips are combined into a destination calendar | Proposed | `docs/information-architecture.md`, differences from the written requirements |

No `SCRN-###` or `JRNY-###` ID appears here: nothing shipped supports a claim about work that
has not shipped.

<a id="5-environment-limits"></a>
## 5. Environment limits

- **Geocoding and street routing need a credential.** Address autocomplete and street-following
  routing both call Geoapify. With no `GEOAPIFY_API_KEY` configured, the geocoder returns
  `api_key_missing` and the screens surface an inline notice; production refuses to boot without
  the key.
- **Map imagery is proxied, not bundled.** Raster tiles are fetched per `{style, z, x, y}` from
  `/map/tiles/:style/:z/:x/:y` with the key held server-side, and building footprints come from the
  public Overpass API at `/map/buildings`. With no key the tile endpoint answers 500 and the map
  shows a tile-failure notice; a failed Overpass request leaves the station map without building
  outlines, and the zoom and pan a reader had chosen are not restored.
- **Validation shells out to a tracked jar.** Feed validation runs `java -jar` against
  `priv/gtfs_validator/gtfs-validator-cli.jar` and parses the report it writes. It needs a Java 21
  runtime at the configured `JAVA_PATH`; without one the run records a failure rather than findings.
  The browser journey harness substitutes a deterministic validator adapter, so a browser run's
  notices are not the jar's notices.
- **The calendar helper needs a model.** The Calendars panel can only answer once an OpenRouter key
  and model are configured. Without them the panel reports itself unavailable; production refuses to
  boot without both.
- **Export artifacts expire.** A finished export is retained for a day and reconciled by a periodic
  maintenance job, so a download link older than that no longer resolves. The maintenance job can be
  disabled by configuration.
- **Two organizations, two brands, one set of routes.** The organization product field changes
  navigation and branding and hides areas from one organization's menu. It never denies a route: a
  Pathways Studio member who follows a link reaches the same screens.
- **The health endpoint has no screen.** `/health` answers a liveness probe an orchestrator polls.
  It renders nothing, so no screen in section 2 cites it.
- **Placeholders are reachable.** The Rosters tab and the feed-URL settings section are registered
  routes that render a Coming soon body. Following either link promises nothing today.
- **Roles are coarse.** Three roles exist: system administrator, Pathways Studio administrator and
  Pathways Studio editor. There is no permission model document, so the actor a screen is for is
  read from the mount hooks the screen inventory names.
- **The organization setting is a naming choice.** Choosing the Pathways Studio product changes what
  the menu shows and how the product is branded. It is not a second application.
