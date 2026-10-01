---
id: JRNY-002
title: Edit a route's timetable
type: journey
status: draft
owner: gtfs-planner
last_reviewed: 2026-10-01
review_interval_days: 90
verified_against:
  - gtfs-planner@3190fda703186b2c3ed810e878215ea29b738747
repos: [gtfs-planner]
actor: organization editor
roles: [] # no ROLE-## identities exist; the registry's actor column is read from the mount hooks (registry OQ-004)
jobs: [JOB-0003, JOB-0004]
screens: [SCRN-007, SCRN-009, SCRN-019]
captures: [] # no capture of this journey exists yet; see section 9
scenarios: [change-times, add-trip]
features: [] # docs/feature-list.md names capabilities but issues no FEAT-## IDs
rules: []
seams: [SEAM-001]
e2e_lanes: [route_schedules.spec.js, route_schedules_grid.spec.js]
context_keys: [activeVersion, routeId, serviceId, directionId, patternId] # proposed; see OQ-002
tests:
  - assets/e2e/route_schedules.spec.js
  - assets/e2e/route_schedules_grid.spec.js
derived_from:
  - docs/journey-registry.md@37da13b0
---

<a id="1-goal"></a>
## 1. The goal

Change one route's timetable so the version riders receive carries the editor's times. "Completed"
is observable as one route whose stored stop times equal what the editor typed: the moved trip
leaves and arrives at the new clocks, and a new trip exists with the times it was given. The
journey is launched from the route's Schedules tab, which the route header carries beside Details
and Patterns.

<a id="2-actor-and-situation"></a>
## 2. Actor and situation

An organization editor — a member holding the `pathways_studio_editor` role, which
`GtfsPlannerWeb.Gtfs.RouteSchedulesLive` requires in
`on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}`. They start in a version that already
holds the route, its patterns, its calendars and its trips, either because a feed was imported or
because they built the service by hand. That is the state the page assumes: a version with no
calendar or no pattern renders a first-use panel instead of a timetable, and those states belong to
JRNY-018 and JRNY-023 rather than here.

At the end the editor must believe two things, not one: that the change they made is the change
their riders will get, and that nothing else on the route moved with it. The first is what the
reloaded timetable and the exported file prove; the second is what the untouched rows around the
edited one prove, and neither is asserted by the page's own success message.

<a id="3-job-stories"></a>
## 3. Job stories

JOB-0003  When a trip runs at the wrong time, I want to move that one trip's departure and let the
rest of its stops follow, so I can correct the schedule without retyping the trip.
Evidence: `docs/feature-list.md` "Edit and delete trips, one or many"; the Edit drawer's `Departure`
field in `lib/gtfs_planner_web/live/gtfs/schedule_components.ex`, whose help states "Use 24-hour
time, like 06:00. After midnight, keep counting: 25:10 is 1:10 AM the next day."
Confidence: inferred — no persona or job-statement document names this actor (OQ-003)

JOB-0004  When a route needs service it does not have, I want to add a trip on an existing pattern
for the days it runs, so I can extend the timetable without rebuilding the pattern.
Evidence: `docs/feature-list.md` "Create a trip with its times"; the Add trips drawer
(`#schedules-add-trips` → `#trip-drawer`) with its `Service days` and `Pattern` selects.
Confidence: inferred (OQ-003)

<a id="4-stages"></a>
## 4. Stages

The eight-stage frame maps as: **locate** (4.1), **prepare** (4.2), **confirm** (4.3), **execute**
(4.4), **monitor** (4.5), **modify** (4.6), **conclude** (4.7). **Define** is absent — the
organization, its role, its version, the route, its patterns and its calendars all exist before the
journey starts, and nothing on this path creates any of them. This is the journey's own modify
stage: the route's times are the record being changed, and nothing on the page is a draft.

All stages are pass-throughs: no stage is revisited except 4.5's undo, which returns the trip to
the time it had before the change in the same sitting.

### 4.1 Locate — the route's Schedules tab

*Why this stage exists:* the timetable is one tab of a route workspace, so the editor has to name
the route before any time is in reach.

| Surface | Action and decision | Establishes | Requires | Exit |
|---|---|---|---|---|
| gtfs-planner: `/gtfs/:version/routes` (SCRN-009), or `/` (SCRN-007) | Press the route's row, then press `Schedules` in the route navigation; the decision is that this route's schedule is the one to correct | `routeId` (proposed) | `activeVersion`, so the header's version is the one being edited | The same route's `/gtfs/:version/routes/:route_id/schedules` (SCRN-019) |

The route header (`GtfsPlannerWeb.RouteWorkspace.route_header/1`) renders the route's long name as
the page title, its short name as the badge, and the three tabs `Details`, `Patterns` and
`Schedules` in a `nav aria-label="Route navigation"`, with `aria-current="page"` on the active tab.
A back link labelled `Routes` returns to the list. On this route the title reads
`Airport - Amargosa Valley` and the badge `50`, from the feed's `route_long_name` and
`route_short_name`.

The dashboard is a second door to the same place: a schedules item on the task board resolves
through `GtfsPlannerWeb.Home.ChangeLinks.path/2` to
`/gtfs/:version/routes/:route_id/schedules?service_id=…`, so the editor who arrives from an
attention item lands already filtered to the service that needs work.

### 4.2 Prepare — choose which service the timetable shows

*Why this stage exists:* one route's trips are split by service days, direction and pattern, and
an edit written against the wrong scope lands on the wrong trip.

| Surface | Action and decision | Establishes | Requires | Exit |
|---|---|---|---|---|
| gtfs-planner: `/gtfs/:version/routes/:route_id/schedules` (SCRN-019) | Choose the service days, direction, and — if the route has more than one pattern — the pattern the tables cover; the decision is that this is the service and direction the editor is correcting | `serviceId`, `directionId`, `patternId` (proposed) | `routeId`, which the page's own URL and header already show | The same route with the chosen scope in the URL and in the tables |

The scope bar (`#schedules-controls`) carries `Service days` with a `Manage calendars` link beside
it, a `Direction` toggle, and the two write verbs `Add trips` and `Paste timetable`. Below it the
filter bar (`#schedules-toolbar`) carries `Stops shown` (`Timepoints` or `All stops`), a `Pattern`
select, a `Custom times` chip when any trip has custom times, `Keyboard shortcuts`, and a status
line `#schedules-view-counts` that reads the trip count, the calendar label and the direction label
together.

Every one of these is a URL parameter — `service_id`, `direction`, `pattern`, `stops`, `custom` —
so a reload, a back and a forward restore the same view, and a missing or unknown value is
canonicalized with a replace patch rather than an error. With no parameter the read resolves the
calendar with the most trips on this route and direction `0` when any trip runs that way, which on
the demo feed is already the weekend service: route `50` has four trips on `WE` and none on `FULLW`.

The `Service days` control names a calendar by its description when the feed supplies one
(`calendar_attributes.txt`). The demo feed supplies none, so the toggle reads the service ID `WE`
and the status line repeats `WE`. An editor who needs a name to read will not find one on this
feed; the calendar's own page is where a name is set.

`Add trips` is not always available. It is enabled only when the version has at least one calendar
and at least one pattern with a timing; otherwise it renders disabled with the reason beneath it —
`Create a calendar before adding trips.`, `Create a pattern before adding trips.` or `Add a timing
to a pattern before adding trips.`

### 4.3 Confirm — what the save will create, before the button

*Why this stage exists:* a timetable edit writes straight into the published version, so the page
states the consequence of the save in the surface itself rather than in a confirmation dialog.

| Surface | Action and decision | Establishes | Requires | Exit |
|---|---|---|---|---|
| gtfs-planner: `/gtfs/:version/routes/:route_id/schedules` (SCRN-019), drawer `#trip-drawer` | Read the result card under the fields and decide to go ahead; for a new trip, read the exact departures and the service days and pattern it will use | — | the departure, and for a new trip the service days and pattern, all of which the card restates | The same route with the drawer closed and the change written |

The Add drawer's card is `#add-result-card` and the Edit and Duplicate drawers' is `#trip-preview`.
Both are `aria-live="polite"` and carry the same shape: a preview line, a departure range in the
display face, the total minutes from first to last stop, and a bold sentence. The Add drawer's
sentence reads `Adds 1 trip.` for a single departure and `Adds 2 trips, 06:00 → 06:30 every 30 min.`
for a repeated one, which is the same count the primary button carries in its own label.

The drawer's footer states the consequence in one line: "Changes save to {version} right away."
There is no confirm dialog on this path.

### 4.4 Execute — write one trip's change

*Why this stage exists:* this is the one action the journey turns on, and it saves without a
review step.

| Surface | Action and decision | Establishes | Requires | Exit |
|---|---|---|---|---|
| gtfs-planner: `/gtfs/:version/routes/:route_id/schedules` (SCRN-019) | To move a trip, press `Edit` on its row (`#trip-{trip_id}-edit`), type the new `Departure`, and press `Save trip`. To create one, press `Add trips`, type the `First departure`, and press `Add 1 trip` | the edited trip's new `start_time`, or the new trip | the drawer values from 4.3 | The same route with the drawer closed and the timetable reloaded |

The Edit drawer (`open_edit_drawer`, title `Edit trip`) leads with `Departure`, then the `Timing`
select, then `Service days`, then a `Trip details` section holding `Headsign (optional)`, `Trip
number (optional)` and a read-only `Block` row with a `Change on Blocks` link. The block is not
editable here by design; the drawer says "Trips with the same block use the same vehicle." and
links to the Blocks workspace. `Accessibility and trip ID` sits behind a disclosure with `Wheelchair
access`, `Bikes allowed` and the trip's stable ID and the sentence "This ID stays the same when you
edit the trip."

A trip whose stop times differ from its pattern carries the warning "This trip has custom stop
times" with the instruction to choose `Use timing` before its departure or stop times can change; a
frequency trip's departure is disabled with the reason "Frequency service has no single departure to
edit. Its windows are shown below."

The Add drawer (`open_add_drawer`, title `Add trips`) opens on `How the trips run` —
`Scheduled trips` ("Each trip has its own departure time. Repeat one at a regular interval.") or
`Every N minutes` — then `First departure` with `Repeat departures`, `Every (minutes)` and
`Last departure by`, then the result card, then `Where these trips run` with the `Service days` and
`Pattern` selects.

The trip's menu beside each row (`#trip-{trip_id}-menu`) offers `Duplicate trip`, `Convert to
scheduled trips…` and `Delete trip`. Duplicate opens the same drawer with the source start advanced
by 30 minutes; delete opens the dialog of 5. Both are this journey's other terminal states, not
stages of it.

### 4.5 Monitor — what the page says it saved

*Why this stage exists:* a save writes immediately and the page reloads, so the editor needs a
truthful account of what changed and a way back.

| Surface | Action and decision | Establishes | Requires | Exit |
|---|---|---|---|---|
| gtfs-planner: `/gtfs/:version/routes/:route_id/schedules` (SCRN-019) | Read the flash and, where the write came from the grid, the outcome line; optionally press `Undo` | the saved change, restated | the values typed in 4.4 | The same route with the change written, or with it restored |

A drawer save reports through the flash: "Saved the {HH:MM} trip." for an edit and "Added 1 trip to
{calendar}." for a new one. A save that moved the trip to another service adds "Moved to
{calendar}; it is no longer in this view." so the editor is not left looking for a row that left
the current filter.

A grid write reports through the sticky bar (`#grid-bar`): `#grid-bar-message` carries the
sentence, and `#undo-action` reads `Undo` whenever the outcome is undoable and the server's stack
holds an entry. Undo restores the captured rows and repeats the restored action's own sentence;
it refuses, with the reason on screen, when a trip from that change was deleted afterwards or
another editor changed one of them first. There is no undo for a drawer save — the flash is the
whole report.

### 4.6 Modify — the same change made from the timetable itself

*Why this stage exists:* the timetable is editable in place, and an editor correcting one time
often reaches for the cell rather than the drawer.

| Surface | Action and decision | Establishes | Requires | Exit |
|---|---|---|---|---|
| gtfs-planner: `/gtfs/:version/routes/:route_id/schedules` (SCRN-019), `#schedules-grid` | Click the cell, type a clock or a `+n` / `−n` offset, read the reading the editor offers, and commit with `Enter`, `Alt+Enter` or `⌘Enter` | the cell's new time, and the stops the chosen commit moves | the row's existing times, which the editor reads | The same route with the changed cell and, for a whole-trip commit, every later stop moved with it |

The grid is a `phx-hook="TimetableGrid"` region holding `#cell-editor`, and every editable cell is a
`td` with `id="cell-{trip_id}-{position}"`. The reading appears as `Reads as {HH:MM}` before
anything is written, and nothing is written until the editor commits. The three commits mean three
different things, and the sheet states them: `Enter` saves and moves later stops, `Alt+Enter` saves
only the edited stop, and `⌘Enter` saves by moving the whole trip.

With the cursor in the timetable the arrow keys move between cells and `]` / `[` shift the cursor
row's trip (or the selection) by one minute, `}` / `{` by five. `Space` selects a trip, `⌘A` selects
every trip in view, and `⌘Z` undoes the last change. The `Keyboard shortcuts` button opens the same
list as a dialog, headed `Move around`, `Change times`, `Trips` and `Copy and undo`, and states that
these work while the cursor is in the timetable and that typing in a field, a drawer or a menu works
as usual.

Rows the change touched take a just-changed tint for one load. Selecting trips replaces the bar's
idle line — "Select trips to shift, copy or change them. Press ? for keyboard shortcuts." — with
`Shift times`, `Change timing`, `Copy to calendar` and a `More` menu; each opens a reviewed command
whose preview lands in the grid before anything is written, and whose apply is fenced on a review
fingerprint so a trip another editor changed in between is never overwritten.

### 4.7 Conclude — the timetable as it now reads

*Why this stage exists:* the terminal outcome is the route's own record, and the editor's last
check is that the row they touched reads what they typed.

| Surface | Action and decision | Establishes | Requires | Exit |
|---|---|---|---|---|
| gtfs-planner: `/gtfs/:version/routes/:route_id/schedules` (SCRN-019) | Read the reloaded section — the departure and every later stop — and, when the change has to reach riders now, follow the export through the GTFS area's Export tab | the route's saved stop times | the values typed in 4.4 | The same route, changed; or the exported archive, which is JRNY-003's terminal stage |

A successful write reloads the whole read through the adapter and re-streams the sections, so the
row's `#trip-{trip_id}-start` cell and its stop columns show the saved values. The planning summary
above the tables re-counts and shows the change marker — `N → M` — beside the vehicles-needed
figure when the count moved.

<a id="5-entry-and-exit-points"></a>
## 5. Entry and exit points

**Entries.** One row per way the journey starts.

| Entry | Source | Notes |
|---|---|---|
| The Routes list, a route's row, then the `Schedules` tab | `lib/gtfs_planner_web/live/gtfs/routes_live.ex` links each row to `/gtfs/:version/routes/:route_id`; `GtfsPlannerWeb.RouteWorkspace.route_header/1` renders the tabs | The route is the scope; the pattern filter still defaults to all patterns |
| The dashboard's task board, a schedules item | `GtfsPlannerWeb.Home.ChangeLinks.path/2` (`kind: :schedules`) builds `/gtfs/:version/routes/:route_id/schedules?service_id=…` | Arrives already filtered to the service that needed attention |
| A direct URL, `/gtfs/:version/routes/:route_id/schedules` | `lib/gtfs_planner_web/router.ex` line 155, in the `:gtfs_routes` live_session | Guarded by the `:require_gtfs_access` mount hook; a member without GTFS access is denied |
| The route's own page, by switching the version in the header | `GtfsPlannerWeb.Gtfs.RouteSchedulesLive` handles `switch_gtfs_version` and re-reads under the new version | The route ID travels in the path; the version does not, so the same route in another version is a different record |

**Exits and abandonment.** Most abandonment lives in prepare and execute, so both get rows.

| Exit | Where it happens | State left behind |
|---|---|---|
| No calendar on the version | 4.1 | The page renders its `Create a calendar` first-use panel; `Add trips` is disabled with `Create a calendar before adding trips.` |
| No pattern, or a pattern with no timing | 4.1 | The page renders `Create a pattern` or `Add a timing`; `Add trips` is disabled with the matching reason |
| A trip is not linked to a pattern | 4.2 | The `#schedules-unlinked` warning counts them — "N trips aren't linked to a pattern" — and leaves them out of the tables, so an editor who cannot see a trip cannot edit it from here |
| A departure typed in a shape the field does not accept | 4.4 | The field's own error, focused by the `FormErrorFocus` hook; nothing is written |
| A trip changed by someone else between opening the drawer and saving | 4.4 | "This trip changed since you opened it. Reload it to see the current values." with a `Reload trip` button; nothing is written |
| The connection drops with the drawer open | 4.4 | `Add` and `Save` disable themselves while the socket is down and return when it returns; nothing is written |
| A whole-trip move before 00:00 | 4.6 | "Nothing was shifted. A trip can't start before 00:00."; nothing is written |

<a id="6-seams"></a>
## 6. Seams

**SEAM-001** (identity, `/users/log_in` → any authenticated route) — The editor's session is the
only thing that crosses here, and the organization and version context is re-derived on the
destination's mount rather than carried in the URL the editor clicked. Consequence for this journey:
the route ID travels in the path but the version does not, so the editor who switches versions in
the header while editing a trip lands on the same route ID under a different version and must
re-check that the trip they were looking at is the trip they are now editing. Nothing in the drawer
carries the version it was opened against beyond the footer's "Changes save to {version} right away."
Related finding: registry OQ-004 (actors are read from mount hooks because no permission model
exists).

No crossing in this journey leaves the application: the edit is written into the same version the
editor is reading, and the timetable opens no external service. The export that carries the change
to riders is JRNY-003's terminal stage and its `SEAM-005` validator run and `SEAM-010` handoff.

<a id="7-features-and-rules-per-stage"></a>
## 7. Features and rules per stage

None. `docs/feature-list.md` names the capabilities this journey uses — "Create a trip with its
times", "Duplicate a trip with shifted times", "Edit and delete trips, one or many" and "Review a
proposed trip change before applying it" — but issues no `FEAT-##` identifiers, and no rule
registry with `BR-##` identifiers exists in this repository. Naming the capability by its registry
row would require inventing an ID, so this section stays empty until a registry issues one.

<a id="8-end-to-end-examples"></a>
## 8. End-to-end examples

#### EX-0201 One trip leaves 45 minutes later (normal path)
**Given** the QA seed's `sample-feed` organization "Demo Transit Authority" with route `50`
`Airport - Amargosa Valley`, patterns derived from its imported stop-time sequences, and calendar
`WE` running Saturday and Sunday
**And** the editor `qa-editor@gtfs-planner.test` is signed in and has opened the route's `Schedules`
tab
**When** the editor presses `Edit` on the trip that departs Nye County Airport (Demo) at 13:00,
types `13:45` into `Departure` and presses `Save trip`
**Then** the flash reads "Saved the 13:45 trip." and the row's departure cell reads `13:45`
**And** that trip's stop time at Amargosa Valley (Demo) reads `14:45`, moved by the same 45 minutes
**And** the other three weekend trips on the route read `08:00`, `10:00` and `15:00` exactly as the
feed's `stop_times.txt` records them
**And** the returned trip still carries its own trip ID
Test: `assets/e2e/route_schedules.spec.js` "keyboard add series, edit, duplicate and focus return"
proves the Edit drawer's save and its focus return on the seed's own mutation route; the literal
stop times are the `timetable-change-times` check's gate, not this lane's.

#### EX-0202 A new weekend trip is added at 17:00 (normal path, second scenario)
**Given** the same organization and route after EX-0201
**When** the editor presses `Add trips`, leaves `Scheduled trips` selected, types `17:00` into
`First departure`, leaves `Service days` on `WE` and the pattern on the one that departs Nye County
Airport (Demo), and presses `Add 1 trip`
**Then** the flash reads "Added 1 trip to WE." and the table gains exactly one row
**And** that row departs Nye County Airport (Demo) at `17:00` and reaches Amargosa Valley (Demo) at
`18:00`, an hour later, the hour the imported trip takes
**And** the three pre-existing weekend trips are unchanged
Test: `assets/e2e/route_schedules.spec.js` proves the Add drawer's series save and its preview
sentence on the seed's mutation route; the `timetable-add-trip` check is the gate for the count and
the literal times.

#### EX-0203 A whole-trip move before 00:00 is refused (boundary)
**Given** the same organization and route, with the editor's cursor in the timetable on the trip
that departs Amargosa Valley (Demo) at `00:05`
**When** the editor presses `[` nine times, or types a whole-trip commit that lands before `00:00`
**Then** the page reads "Nothing was shifted. A trip can't start before 00:00."
**And** the trip's departure cell is unchanged and no other row moved
Test: `assets/e2e/route_schedules_grid.spec.js` "] nudges and Ctrl+Z restores the original time"
proves the nudge write and its undo on the grid's own fixture; the refusal copy above `00:00` is
`ScheduleComponents.error_message(:negative_time)`'s own wording and no committed lane asserts it.

<a id="9-visual-and-evidence-links"></a>
## 9. Visual and evidence links

| Stage | Kind | Reference | Notes |
|---|---|---|---|
| 4.1 Locate | e2e lane | `assets/e2e/route_schedules.spec.js` | Asserts the route tab bar and that `Schedules` carries `aria-current="page"` |
| 4.2 Prepare | e2e lane | `assets/e2e/route_schedules.spec.js`, `assets/e2e/route_schedules_grid.spec.js` | The URL canonicalization and restore case, the stops-view parameter, the pinned-columns cases at 1440 and 1280 |
| 4.2 Prepare | e2e lane | `assets/e2e/route_schedules_grid.spec.js` | Grid geometry at two viewports, the sticky-bar clearance case and the cursor-cell focus chain |
| 4.3 Confirm, 4.4 Execute | e2e lane | `assets/e2e/route_schedules.spec.js` | The Add drawer's preview sentence and primary label, the keyboard-only series save, the Edit and Duplicate drawers, and the return of focus to the control that opened the drawer |
| 4.5 Monitor | e2e lane | `assets/e2e/route_schedules_grid.spec.js` | The nudge outcome and `#undo-action`, and `Control+z` restoring the original time |
| 4.6 Modify | e2e lane | `assets/e2e/route_schedules_grid.spec.js` | The `Reads as` preview, `Enter` moving later stops, `Alt+Enter` moving only the edited stop, and the bracket key leaving the Add drawer's field alone |
| 4.7 Conclude | e2e lane | `assets/e2e/route_schedules.spec.js` | The export after a mutation carries the fixture-authored stop times, which is the only committed lane that reads the change back out of the product |
| 4.1–4.7 | journey capture | Not captured — no run of `JRNY-002/change-times` or `JRNY-002/add-trip` exists yet, and the captures this page will cite are produced by the pilot steps. | Would be cited as `JRNY-002/change-times-s004` |
| All stages | product documentation | `docs/screen-inventory.md`, `docs/inventories/gtfs-operation-screens.md` | `SCRN-019` is the registered screen for this route; `SCRN-009` and `SCRN-007` are the two entries. All three read undocumented at the commit this page was written against |

No capture ID is cited in this page because none exists. A capture that is later produced is cited
by its backticked ID, never by an image path.

<a id="10-test-scenario"></a>
## 10. Test scenario

### change-times

- **Persona:** Scheduler at a small transit agency with an organization editor account.
- **Goal:** On route 50, Airport - Amargosa Valley, the weekend trip that leaves Nye County Airport (Demo) at 1:00 p.m. must leave 45 minutes later, at 1:45 p.m., and arrive at Amargosa Valley (Demo) at 2:45 p.m.
- **Account:** editor
- **Seed:** sample-feed
- **Start path:** /
- **Success check:** timetable-change-times — that trip's stop times move 45 minutes and no other trip changes
- **Reference actions:** 6
- **Entry route:** /gtfs/:version/routes/:route_id/schedules

The six reference actions are the ones after sign-in, waits excluded: press the route in the Routes
list; press `Schedules` in the route navigation; press `Edit` on the trip that leaves Nye County
Airport (Demo) at 1:00 p.m.; select the `Departure` field's value; type the new time; press
`Save trip`. Reading the flash and the reloaded row are not actions. On the demo feed the timetable
displays 24-hour clocks, so the field the tester types into shows `13:00` where the goal says
1:00 p.m.; the same offset applies to every other time in this goal.

This count is an estimate until the reference trail for `JRNY-002/change-times` runs, and the
executed trail's count replaces it (OQ-006).

### add-trip

- **Persona:** Scheduler at a small transit agency with an organization editor account.
- **Goal:** On route 50, Airport - Amargosa Valley, add a weekend trip that leaves Nye County Airport (Demo) at 5:00 p.m. and takes the same hour as the 1:00 p.m. trip, arriving at Amargosa Valley (Demo) at 6:00 p.m.
- **Account:** editor
- **Seed:** sample-feed
- **Start path:** /
- **Success check:** timetable-add-trip — exactly one new weekend trip with those stop times and no other trip changes
- **Reference actions:** 8
- **Entry route:** /gtfs/:version/routes/:route_id/schedules

The eight reference actions are the ones after sign-in, waits excluded: press the route in the
Routes list; press `Schedules` in the route navigation; press `Add trips`; choose `Service days`;
choose `Pattern`; select the `First departure` field's value; type the new time; press
`Add 1 trip`. `Scheduled trips` is already the selected radio and needs no action, and reading the
flash is not an action. As in `change-times`, the field shows 24-hour clocks where the goal reads
5:00 p.m.

This count is an estimate until the reference trail for `JRNY-002/add-trip` runs, and the executed
trail's count replaces it (OQ-006).

## Open questions

- OQ-001 — Neither check this section names exists yet; `assets/qa/checks/` is empty in this
  checkout. Until `timetable-change-times` and `timetable-add-trip` land, neither scenario can be
  executed. Owner: spec step 54.
- OQ-002 — `context_keys` and every `Establishes` / `Requires` value on this page are proposed. This
  repository has no E2E ledger or journey catalog to take key names from, and no documented
  `establishes` / `requires` contract exists to propose against. Owner: product owner.
- OQ-003 — Both job stories are `inferred`. No persona document, funnel doc or lane `intent` field
  names this actor's motivation; the stories are read from the shipped drawer copy and the feature
  registry rows. Owner: product owner.
- OQ-004 — `roles: []` is empty because no `ROLE-##` identity exists; the actor column comes from
  the registry's reading of `GtfsPlanner.Authorization.Roles` and the mount hooks. Registry OQ-004
  asks for the same derivation through a permission model. Owner: product owner.
- OQ-005 — The demo feed's `Service days` control reads `WE` because the feed carries no
  `calendar_attributes.txt` and therefore no calendar description. Whether a tester should be sent
  to a feed that names its calendars is a seeding decision, not a documentation one. Owner: product
  owner.
- OQ-006 — `Reference actions: 6` and `8` are counted from the traced flow, not executed. Each
  reference trail's count replaces its own estimate. Owner: the reference-trail step.
- OQ-007 — No capture of this journey exists, so section 9 cites none. Which states the pilot
  captures must cover — the timetable, the Add drawer's result card, the Edit drawer, the undo bar —
  is a decision for the pilot steps. Owner: product owner.

## Changelog

| Date | Version | Change | Author |
|---|---|---|---|
| 2026-10-01 | 1 | Initial page: stages, seams, examples and the `change-times` and `add-trip` scenarios for JRNY-002 | spec step 38 |