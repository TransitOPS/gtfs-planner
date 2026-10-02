# Feature list — GTFS Planner

## 1. Overview

GTFS Planner is a multi-tenant web application for producing, checking and publishing transit
feeds. An organization imports a GTFS feed into a version, edits routes, patterns, schedules,
calendars, stops, stations, transfers, fares and flex services, validates the result against a
standard feed checker, and exports a publishable archive. A companion JSON API lets a station
editor application read stations, synchronize station data and request pathways exports.
Primary actors served: an end user who plans and edits a feed, an organization administrator
who manages members and settings, a system administrator who provisions organizations, an
integrator that consumes the companion API, and scheduled or operator tooling that runs
imports and housekeeping on the instance. Scope of this inventory: the whole repository at
commit `afc5ad3588c3`, describing shipped behavior only — planned or unbuilt destinations are
listed under ambiguities instead of as features. Inventory date: 2026-10-01.

## 2. Feature groups (summary)

| Group | Description | Feature count |
|---|---|---|
| Identity and account access | Signing in, recovering access, confirming an address, accepting an invitation, first-run bootstrap and self-service account settings | 10 |
| Organizations and membership | Provisioning organizations, managing their members, roles and organization-level settings | 10 |
| Feed versions | Creating, publishing, switching and failing feed versions | 5 |
| Routes, patterns and alignment | Browsing, creating and editing routes, their patterns, and street-following pattern alignment | 9 |
| Schedules, trips and transfers | Reading and editing trip times, pasting a timetable, reviewing and applying trip changes, managing transfers | 9 |
| Calendars | Service calendars and the calendar helper panel that answers and proposes date changes | 5 |
| Stops, stations and station reports | Stops and stations, floor-plan diagrams, the station report, the station journal and scheduled pathway closures | 11 |
| Blocking, runs and fleet | Assigning trips to blocks, reading runs, managing garages, vehicles and vehicle types, importing and exporting vehicle data | 10 |
| Flex and fares | Flex services with hours, area and booking readiness; fare zones, fare rules and fare checks | 8 |
| Import, export and validation | Importing a whole feed or station changes, exporting a feed, choosing export defaults, validating the feed and checking station reachability | 10 |
| Companion JSON API | Session, version, station, synchronization, journal photo and pathways export endpoints | 8 |
| Home, maps and reference surfaces | The landing page's states and regions, map imagery endpoints, address lookup and the design system reference | 9 |
| Operator tooling | Health probe, command-line feed imports and periodic task-artifact housekeeping | 5 |

## 3. Features by group

### Identity and account access

| Feature | Actor | Entry points | Confidence | Notes |
|---|---|---|---|---|
| Sign in with an email address and password | end user | `/users/log_in`, `POST /users/log_in` | high | |
| Sign out | end user | `DELETE /users/log_out` | high | |
| Request a password reset email | end user | `/users/reset_password` | high | |
| Choose a new password from a reset link | end user | `/users/reset_password/:token` | high | |
| Confirm an email address from a link | end user | `/users/confirm/:token`, `GET /users/settings/confirm_email/:token` | high | The in-session confirmation confirms and redirects rather than showing a screen |
| Set a password from an invitation link | end user | `/users/accept_invite/:token` | high | |
| Update own name, email address and password | end user | `/users/settings`, `POST /users/update_password` | high | Changing the address sends a confirmation email |
| Bootstrap the first administrator and its organization | admin | `/first` | high | Reachable only on an instance with no organization |
| Open a companion API session | integrator | `POST /api/v1/auth/login` | high | Returns a long-lived API session token; see the Companion JSON API group |
| Close a companion API session | integrator | `DELETE /api/v1/auth/session` | high | |

These are the only capabilities a visitor has before holding a membership. Everything else in
the product is gated behind a session, so this group is where an unauthenticated actor meets
the system. Invitation, confirmation and reset links are all time-limited tokens delivered by
email rather than screens of their own.

### Organizations and membership

| Feature | Actor | Entry points | Confidence | Notes |
|---|---|---|---|---|
| Browse the instance's organizations | admin | `/admin/organizations` | high | System administrator role |
| Provision a new organization | admin | `/admin/organizations/new` | high | |
| Inspect one organization and its members | admin | `/admin/organizations/:org_id` | high | |
| Edit an organization's details | admin | `/admin/organizations/:org_id/edit` | high | |
| Invite somebody into an organization | admin | `/admin/organizations/:org_id/invite`, `/admin/users/invite` | high | Two URLs for one invitation journey, one per administrator audience |
| List an organization's members with their roles | admin | `/admin/users` | high | |
| Change a member's roles | admin | `/admin/users` | high | Roles are organization administrator, editor and instance administrator |
| Deactivate and reactivate a member | admin | `/admin/users` | high | Deactivation keeps history and removes access |
| Resend a pending invitation | admin | `/admin/users`, `/admin/users/invite` | medium | Reachable from the invitation form; no separate route |
| Rename the organization and choose its product | admin | `/admin/users/organization-settings` | high | The product choice changes navigation and branding only |

Membership, not the user record, carries access: a person's roles are held per organization, so
the same account can administer one organization and edit feeds in another.

### Feed versions

| Feature | Actor | Entry points | Confidence | Notes |
|---|---|---|---|---|
| Create a staging version for an incoming feed | end user | `/gtfs/:version/import` | high | The staging version is not editable while the import runs |
| Publish an imported version | end user | `/gtfs/:version/import` | high | Publication swaps the organization's published version |
| Fail an import and release its staging version | system | `/gtfs/:version/import` | medium | Invoked when the import cannot complete; no direct screen |
| List and switch between published versions | end user | `/gtfs/:version/*` | high | The version is a path segment, so every link carries it |
| Seed a default version for a new organization | system | `/admin/organizations/new` | medium | Created with the organization, not from a screen of its own |

A version is the unit of isolation: every edit, import, export and validation is scoped to one
version, and only published versions are reachable from the product's URLs.

### Routes, patterns and alignment

| Feature | Actor | Entry points | Confidence | Notes |
|---|---|---|---|---|
| Browse a version's routes | end user | `/gtfs/:version/routes` | high | Filterable list |
| Create a route | end user | `/gtfs/:version/routes` | high | Suggests a free route short name |
| Edit a route's colors, names and mode | end user | `/gtfs/:version/routes/:route_id` | high | |
| Activate and deactivate a route | end user | `/gtfs/:version/routes/:route_id` | high | Deactivation keeps the route out of the exported feed |
| Delete a route after reviewing what depends on it | end user | `/gtfs/:version/routes/:route_id` | high | The review is fingerprinted, so a stale review is refused |
| Order and edit a route's patterns | end user | `/gtfs/:version/routes/:route_id/patterns` | high | One editor at three actions |
| Add a pattern by placing stops on the map | end user | `/gtfs/:version/routes/:route_id/patterns/new` | high | |
| Compare two patterns of one route side by side | end user | `/gtfs/:version/routes/:route_id/patterns/compare` | high | Selection travels in query parameters |
| Draw and save street-following alignment for a pattern | end user | `/gtfs/:version/routes/:route_id/patterns/:route_pattern_id` | high | Saved under a re-reviewed fingerprint; segments without points stay missing rather than straight |

### Schedules, trips and transfers

| Feature | Actor | Entry points | Confidence | Notes |
|---|---|---|---|---|
| Read a route's trips and times | end user | `/gtfs/:version/routes/:route_id/schedules` | high | |
| Paste a block of timetable text onto a route | end user | `/gtfs/:version/routes/:route_id/schedules/paste` | high | Parsed into a preview before anything is written |
| Create a trip with its times | end user | `/gtfs/:version/routes/:route_id/schedules` | high | |
| Duplicate a trip with shifted times | end user | `/gtfs/:version/routes/:route_id/schedules` | high | |
| Edit and delete trips, one or many | end user | `/gtfs/:version/routes/:route_id/schedules` | high | Bulk delete reports the transfers that would be lost |
| Review a proposed trip change before applying it | end user | `/gtfs/:version/routes/:route_id/schedules` | high | A stale review is rejected rather than applied |
| Restore trips from a snapshot | end user | `/gtfs/:version/routes/:route_id/schedules` | medium | Restoration is reachable from the same schedules surface |
| Manage transfers between stops | end user | `/gtfs/:version/transfers` | high | The Routes area's second tab |
| Add, edit and delete a transfer rule | end user | `/gtfs/:version/transfers` | high | Includes both arrival and departure sides, with route and trip pickers |

### Calendars

| Feature | Actor | Entry points | Confidence | Notes |
|---|---|---|---|---|
| List a version's service calendars | end user | `/gtfs/:version/calendars` | high | |
| Create a service calendar | end user | `/gtfs/:version/calendars/new` | high | |
| Edit a calendar's dates and see what else uses it | end user | `/gtfs/:version/calendars/show` | high | The service identifier travels as a query parameter |
| Ask the calendar helper a question about service dates | end user | `/gtfs/:version/calendars` | medium | A conversation panel on the Calendars screen; it can only answer once a model is configured |
| Preview a proposed date change before applying it | end user | `/gtfs/:version/calendars` | medium | The panel proposes a change and the operator applies it on the calendar page |

The calendar helper is the only conversational surface in the product, and it is scoped to the
Calendars screen; no other screen carries one.

### Stops, stations and station reports

| Feature | Actor | Entry points | Confidence | Notes |
|---|---|---|---|---|
| Browse a version's stops and stations | end user | `/gtfs/:version/stops` | high | |
| Inspect a stop's identifiers, location and serving trips | end user | `/gtfs/:version/stops/:stop_id` | high | |
| Edit a station's levels, pathways and child stops on a diagram | end user | `/gtfs/:version/stops/:stop_id/diagram` | high | |
| Upload a floor plan image for a station | end user | `/gtfs/:version/stops/:stop_id/diagram` | high | The upload is validated before it is stored |
| Read a station report dashboard | end user | `/gtfs/:version/stops/:stop_id/report` | high | Sections load independently and one load supersedes the previous |
| Record a station journal entry | end user | `/gtfs/:version/stops/:stop_id` | high | Also shown on the station diagram |
| Attach a photograph to a journal entry | end user | `/gtfs/:version/stops/:stop_id`, `POST /api/v1/versions/:version_id/stations/:station_id/journal-photos` | high | The same photo can arrive from the companion API |
| Pin a photograph to a place on a station level | end user | `/gtfs/:version/stops/:stop_id/diagram` | high | Pin coordinates are stored in level coordinates |
| Close and reopen a journal entry | end user | `/gtfs/:version/stops/:stop_id` | high | |
| Review a station's scheduled pathway closures | end user | `/gtfs/:version/stops/:stop_id/evolutions` | high | |
| Preview pathway access at a chosen service moment | end user | `/gtfs/:version/stops/:stop_id/evolutions/access` | high | One mounted station shared with the evolutions screen |

### Blocking, runs and fleet

| Feature | Actor | Entry points | Confidence | Notes |
|---|---|---|---|---|
| Assign trips to blocks for a service day | end user | `/gtfs/:version/blocks` | high | The only place a block is edited |
| Read a service day's plan figures and blocking checks | end user | `/gtfs/:version/blocks` | high | Checks and driving times open in drawers |
| Get suggested blocks for a service day | end user | `/gtfs/:version/blocks` | high | Suggestions are a preview, not an applied plan |
| Record deadhead times between trips | end user | `/gtfs/:version/blocks` | high | Stored per day type |
| Choose relief points and relief settings | end user | `/gtfs/:version/blocks` | medium | Reachable from the Blocks drawers |
| Read a version's runs | end user | `/gtfs/:version/runs` | medium | Present beside Blocks; the run record itself is read rather than authored here |
| Manage the organization's garages | end user | `/gtfs/:version/settings/garages` | high | Flags garages whose stop identifiers conflict |
| Manage vehicles and vehicle types | end user | `/gtfs/:version/settings/fleet` | high | Bulk assignment by garage and type |
| Preview and apply a vehicle import | end user | `/gtfs/:version/settings/fleet` | high | Nothing is written until the preview is applied |
| Export vehicle and vehicle-type rows | operator | `/gtfs/:version/settings/fleet` | medium | Produces the vehicle inventory rows and a file inventory |

### Flex and fares

| Feature | Actor | Entry points | Confidence | Notes |
|---|---|---|---|---|
| List a version's flex services | end user | `/gtfs/:version/flex` | high | With hours, booking summary and readiness |
| Edit one flex service's hours, bookings and stop rules | end user | `/gtfs/:version/flex/:service` | high | |
| Edit a flex service's candidate area | end user | `/gtfs/:version/flex/:service/area` | high | An action on the service page, so the draft survives the patch |
| Read a flex service's readiness checks | end user | `/gtfs/:version/flex/:service` | high | Checks run over the service and its peers |
| Manage fare zones | end user | `/gtfs/:version/settings/fares` | high | |
| Manage fare rules | end user | `/gtfs/:version/settings/fares/rules` | high | Rule groups and combined fares |
| Run fare consistency checks | end user | `/gtfs/:version/settings/fares/checks` | high | |
| Include or exclude the flex file from a full export | end user | `/gtfs/:version/settings/export-defaults` | high | An export default rather than a fares capability |

### Import, export and validation

| Feature | Actor | Entry points | Confidence | Notes |
|---|---|---|---|---|
| Import a complete feed as a new version | end user | `/gtfs/:version/import` | high | The version in view is never touched |
| Import station changes into the version in view | end user | `/gtfs/:version/import` | high | Each change is applied only after approval |
| Review a computed station change set before applying it | end user | `/gtfs/:version/import` | high | The run computes first, so the preview and the apply are separate |
| Export a version's feed | end user | `/gtfs/:version/export` | high | Runs asynchronously with live progress |
| Download the latest export file | end user | `GET /gtfs/:version/export-runs/:run_id/download` | high | Requires the editor role |
| Choose export defaults | end user | `/gtfs/:version/settings/export-defaults` | high | Flex file inclusion and the realtime feed file |
| Check the feed with the standard feed validator | end user | `/gtfs/:version/export`, `/gtfs/:version/validation/:validation_id` | high | Errors, warnings and notices are grouped |
| Read one validation run's findings | end user | `/gtfs/:version/validation/:validation_id` | high | |
| Run station-level reachability validation for one stop | end user | `/gtfs/:version/stops/:stop_id/reachability` | high | Includes the stop's pathway topology |
| Read station-by-station reachability results | end user | `/gtfs/:version/station-reachability/:validation_id` | high | The run-wide companion of the single-stop screen |

### Companion JSON API

| Feature | Actor | Entry points | Confidence | Notes |
|---|---|---|---|---|
| Authenticate an API client | integrator | `POST /api/v1/auth/login` | high | Public; CORS preflight is served for every path |
| List the versions a member may read | integrator | `GET /api/v1/versions` | high | |
| List a version's stations | integrator | `GET /api/v1/versions/:version_id/stations` | high | |
| Fetch one station's full bundle | integrator | `GET /api/v1/versions/:version_id/stations/:station_id/bundle` | high | |
| Synchronize a station's data | integrator | `POST /api/v1/versions/:version_id/stations/:station_id/sync` | high | Writes require the editor role |
| Upload a station journal photograph | integrator | `POST /api/v1/versions/:version_id/stations/:station_id/journal-photos` | high | Writes require the editor role |
| Request a pathways export | integrator | `POST /api/v1/versions/:version_id/pathways-exports` | high | Only route identifiers are accepted from the request |
| Poll and download a pathways export | integrator | `GET /api/v1/versions/:version_id/pathways-exports/:export_id`, `.../download` | high | |

The API is the mobile and station-editor integration surface: reads are open to any member of
the organization, writes to members holding the editor role, and every response derives the
organization and actor from the authenticated session rather than from request parameters.

### Home, maps and reference surfaces

| Feature | Actor | Entry points | Confidence | Notes |
|---|---|---|---|---|
| Land on a dashboard shaped by role and context | end user, admin | `/` | high | One state per context: administrator, no organization, no published version, no task access, or the working page |
| See the next task for the feed | end user | `/` | high | |
| Continue where you left off | end user | `/` | high | A resume list per person |
| Read the station board for a station-first product | end user | `/` | high | Station summaries, statuses and who else is editing |
| Reload one failing dashboard region | end user | `/` | high | Each region retries on its own |
| Fetch map raster tiles | system | `GET /map/tiles/:style/:z/:x/:y` | high | Fetched by the screens that draw a map |
| Fetch building outlines for the map | system | `GET /map/buildings` | high | |
| Look up an address while placing a garage | end user | `/gtfs/:version/settings/garages`, `/design` | high | Address autocomplete backed by the configured geocoding service |
| Browse the design system reference | end user | `/design`, `/design/:page` | high | Internal reference, reachable by any signed-in user |

### Operator tooling

| Feature | Actor | Entry points | Confidence | Notes |
|---|---|---|---|---|
| Probe the instance for liveness | operator | `GET /health` | high | Consumed by the orchestrator |
| Reconcile task leases and their artifacts on a timer | system | `GtfsPlanner.Gtfs.TaskArtifactMaintenance` | medium | Database rows stay the authority; it runs on a configured interval and can be disabled |

## 4. Cross-cutting capabilities

| Capability | Groups it touches | What it carries |
|---|---|---|
| Session and organization scoping | Identity, Organizations, Feed versions, every editing group | Session, organization and version come from mount hooks, never from a request parameter |
| Role enforcement | Identity, Organizations, Home, Operator tooling | Instance administrator, organization administrator and editor are checked per area |
| Reviewed writes and audit context | Routes, Schedules, Calendars, Flex, Fares, Fleet | Destructive or wide edits compute a review fingerprint and refuse a stale one |
| Change history | Routes, Stops, Schedules | Recent changes and per-station change history are described in the same vocabulary |
| Task runs and artifact lifecycle | Import, Export, Operator tooling | Long work is a run with a lease, progress and a retained artifact, reconciled by a periodic job |
| Live progress updates | Import, Export, Validation, Stops | Runs and station journal changes are broadcast to open screens |
| Map and location services | Routes, Stops, Garages, Calendar helper | Tiles, buildings, address lookup and street routing are shared infrastructure |

## 5. Ambiguities & gaps

| Item | Why it is uncertain | What would raise confidence |
|---|---|---|
| `/gtfs/:version/rosters` | A registered route serving a placeholder with no implementation behind it | A product decision to build or remove it |
| Runs | The screen authors a run from an uncovered segment or a suggested plan, but never from a hand-drawn boundary between two trips | A product statement of whether a reader should be able to place a run boundary by hand |
| Calendar helper | The panel ships, but answering needs a configured model; without one the surface degrades to an error notice | A configuration and deployment check |
| Relief points and vehicle export | Reachable from existing surfaces but with no dedicated screen of their own | An operator walkthrough of the drawers |
| Command-line imports | Cover only stops, levels and pathways; the in-product importer covers the whole feed | A statement of whether the remaining files are intended as CLI tasks |
| Design system pages | Internal reference rather than product capability | A product decision to keep them behind the sign-in gate |
| `/dev/dashboard` and `/dev/mailbox` | Developer surfaces compiled out of test and production | Nothing; they are excluded from this inventory by design |
| `docs/routes-and-access.md` | Documents routes the application does not register | The document has already been superseded by the screen inventory; no product change needed |

## 6. Evidence index

- Sign in with an email address and password → `lib/gtfs_planner_web/router.ex:62`
- Sign out → `lib/gtfs_planner_web/router.ex:73`
- Request a password reset email → `lib/gtfs_planner/accounts.ex:470`
- Choose a new password from a reset link → `lib/gtfs_planner/accounts.ex:538`
- Confirm an email address from a link → `lib/gtfs_planner/accounts.ex:412`
- Set a password from an invitation link → `lib/gtfs_planner/accounts.ex:812`
- Update own name, email address and password → `lib/gtfs_planner_web/router.ex:85`
- Bootstrap the first administrator and its organization → `lib/gtfs_planner/accounts.ex:884`
- Open a companion API session → `lib/gtfs_planner/accounts.ex:343`
- Close a companion API session → `lib/gtfs_planner_web/router.ex:260`
- Browse the instance's organizations → `lib/gtfs_planner/organizations.ex:380`
- Provision a new organization → `lib/gtfs_planner/organizations.ex:97`
- Inspect one organization and its members → `lib/gtfs_planner/organizations.ex:419`
- Edit an organization's details → `lib/gtfs_planner/organizations.ex:120`
- Invite somebody into an organization → `lib/gtfs_planner/accounts.ex:602`
- List an organization's members with their roles → `lib/gtfs_planner/organizations.ex:261`
- Change a member's roles → `lib/gtfs_planner/organizations.ex:214`
- Deactivate and reactivate a member → `lib/gtfs_planner/organizations.ex:295`
- Resend a pending invitation → `lib/gtfs_planner/accounts.ex:757`
- Rename the organization and choose its product → `lib/gtfs_planner_web/router.ex:106`
- Create a staging version for an incoming feed → `lib/gtfs_planner/versions.ex:66`
- Publish an imported version → `lib/gtfs_planner/versions.ex:113`
- Fail an import and release its staging version → `lib/gtfs_planner/versions.ex:132`
- List and switch between published versions → `lib/gtfs_planner/versions.ex:183`
- Seed a default version for a new organization → `lib/gtfs_planner/versions.ex:76`
- Browse a version's routes → `lib/gtfs_planner/gtfs.ex:1186`
- Create a route → `lib/gtfs_planner/gtfs.ex:1271`
- Edit a route's colors, names and mode → `lib/gtfs_planner/gtfs.ex:1394`
- Activate and deactivate a route → `lib/gtfs_planner/gtfs.ex:1409`
- Delete a route after reviewing what depends on it → `lib/gtfs_planner/gtfs.ex:1447`
- Order and edit a route's patterns → `lib/gtfs_planner/gtfs.ex:190`
- Add a pattern by placing stops on the map → `lib/gtfs_planner_web/router.ex:148`
- Compare two patterns of one route side by side → `lib/gtfs_planner/gtfs.ex:226`
- Draw and save street-following alignment for a pattern → `lib/gtfs_planner/gtfs/alignments.ex:2665`
- Read a route's trips and times → `lib/gtfs_planner/gtfs.ex:658`
- Paste a block of timetable text onto a route → `lib/gtfs_planner/gtfs.ex:686`
- Create a trip with its times → `lib/gtfs_planner/gtfs.ex:879`
- Duplicate a trip with shifted times → `lib/gtfs_planner/gtfs.ex:1001`
- Edit and delete trips, one or many → `lib/gtfs_planner/gtfs.ex:982`
- Review a proposed trip change before applying it → `lib/gtfs_planner/gtfs.ex:902`
- Restore trips from a snapshot → `lib/gtfs_planner/gtfs.ex:954`
- Manage transfers between stops → `lib/gtfs_planner/gtfs.ex:394`
- Add, edit and delete a transfer rule → `lib/gtfs_planner/gtfs.ex:537`
- List a version's service calendars → `lib/gtfs_planner/gtfs.ex:378`
- Create a service calendar → `lib/gtfs_planner_web/router.ex:144`
- Edit a calendar's dates and see what else uses it → `lib/gtfs_planner/gtfs.ex:642`
- Ask the calendar helper a question about service dates → `lib/gtfs_planner_web/live/gtfs/calendars_live.ex:2686`
- Preview a proposed date change before applying it → `lib/gtfs_planner/agents/packs/calendars.ex:134`
- Browse a version's stops and stations → `lib/gtfs_planner/gtfs.ex:157`
- Inspect a stop's identifiers, location and serving trips → `lib/gtfs_planner/gtfs.ex:362`
- Edit a station's levels, pathways and child stops on a diagram → `lib/gtfs_planner_web/router.ex:159`
- Upload a floor plan image for a station → `lib/gtfs_planner_web/live/gtfs/station_diagram_live.ex:211`
- Read a station report dashboard → `lib/gtfs_planner_web/live/gtfs/station_report_2_live.ex:1`
- Record a station journal entry → `lib/gtfs_planner/gtfs.ex:1121`
- Attach a photograph to a journal entry → `lib/gtfs_planner/gtfs.ex:1143`
- Pin a photograph to a place on a station level → `lib/gtfs_planner/gtfs.ex:1148`
- Close and reopen a journal entry → `lib/gtfs_planner/gtfs.ex:1126`
- Review a station's scheduled pathway closures → `lib/gtfs_planner_web/router.ex:162`
- Preview pathway access at a chosen service moment → `lib/gtfs_planner_web/router.ex:166`
- Assign trips to blocks for a service day → `lib/gtfs_planner/gtfs/blocking.ex:1440`
- Read a service day's plan figures and blocking checks → `lib/gtfs_planner_web/live/gtfs/blocks_live.ex:1`
- Get suggested blocks for a service day → `lib/gtfs_planner/gtfs/blocking.ex:1655`
- Record deadhead times between trips → `lib/gtfs_planner/gtfs/blocking.ex:827`
- Choose relief points and relief settings → `lib/gtfs_planner/gtfs/blocking.ex:1149`
- Read a version's runs → `lib/gtfs_planner_web/router.ex:170`
- Manage the organization's garages → `lib/gtfs_planner/operations.ex:90`
- Manage vehicles and vehicle types → `lib/gtfs_planner/operations.ex:467`
- Preview and apply a vehicle import → `lib/gtfs_planner/operations.ex:754`
- Export vehicle and vehicle-type rows → `lib/gtfs_planner/operations.ex:833`
- List a version's flex services → `lib/gtfs_planner/gtfs.ex:1091`
- Edit one flex service's hours, bookings and stop rules → `lib/gtfs_planner_web/router.ex:180`
- Edit a flex service's candidate area → `lib/gtfs_planner_web/router.ex:181`
- Read a flex service's readiness checks → `lib/gtfs_planner/gtfs/flex/checks.ex:168`
- Manage fare zones → `lib/gtfs_planner/gtfs/fare_zones.ex:340`
- Manage fare rules → `lib/gtfs_planner/gtfs/fare_zones.ex:247`
- Run fare consistency checks → `lib/gtfs_planner/gtfs/fare_zones.ex:364`
- Include or exclude the flex file from a full export → `lib/gtfs_planner/gtfs/export_defaults.ex:1`
- Import a complete feed as a new version → `lib/gtfs_planner_web/live/gtfs/import_live.ex:1`
- Import station changes into the version in view → `lib/gtfs_planner/gtfs/import/change_runner.ex:16`
- Review a computed station change set before applying it → `lib/gtfs_planner/gtfs/import/change_runner.ex:22`
- Export a version's feed → `lib/gtfs_planner_web/live/gtfs/export_live.ex:1`
- Download the latest export file → `lib/gtfs_planner_web/controllers/gtfs_export_download_controller.ex:19`
- Choose export defaults → `lib/gtfs_planner_web/router.ex:192`
- Check the feed with the standard feed validator → `lib/gtfs_planner/gtfs/validator.ex:47`
- Read one validation run's findings → `lib/gtfs_planner/validations.ex:18`
- Run station-level reachability validation for one stop → `lib/gtfs_planner/reachability.ex:29`
- Read station-by-station reachability results → `lib/gtfs_planner_web/router.ex:207`
- Authenticate an API client → `lib/gtfs_planner_web/router.ex:253`
- List the versions a member may read → `lib/gtfs_planner_web/router.ex:262`
- List a version's stations → `lib/gtfs_planner_web/router.ex:263`
- Fetch one station's full bundle → `lib/gtfs_planner_web/router.ex:264`
- Synchronize a station's data → `lib/gtfs_planner_web/router.ex:280`
- Upload a station journal photograph → `lib/gtfs_planner_web/router.ex:282`
- Request a pathways export → `lib/gtfs_planner_web/router.ex:266`
- Poll and download a pathways export → `lib/gtfs_planner_web/router.ex:268`
- Land on a dashboard shaped by role and context → `lib/gtfs_planner_web/live/dashboard_live.ex:1`
- See the next task for the feed → `lib/gtfs_planner/home.ex:1`
- Continue where you left off → `lib/gtfs_planner/home.ex:1`
- Read the station board for a station-first product → `lib/gtfs_planner_web/live/dashboard_live.ex:1`
- Reload one failing dashboard region → `lib/gtfs_planner/home.ex:1`
- Fetch map raster tiles → `lib/gtfs_planner_web/controllers/map_tiles_controller.ex:14`
- Fetch building outlines for the map → `lib/gtfs_planner_web/controllers/map_buildings_controller.ex:14`
- Look up an address while placing a garage → `lib/gtfs_planner_web/live/gtfs/garages_live.ex:268`
- Browse the design system reference → `lib/gtfs_planner_web/router.ex:90`
- Probe the instance for liveness → `lib/gtfs_planner_web/controllers/health_controller.ex:4`
- Reconcile task leases and their artifacts on a timer → `lib/gtfs_planner/gtfs/task_artifact_maintenance.ex:50`