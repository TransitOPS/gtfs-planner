# Information Architecture Decisions

This records how each placement in [Information Architecture](information-architecture.md) was chosen:
- the question
- the options considered
- the choice, and why the other options lost
- the product owner's corrections
- the layout they selected

The review took place on 2026-09-27. It covered the requirement gaps left after the planned work,
plus the planned pages that had not merged.

Read this before re-proposing a rejected option. Each rejection states the condition that would
have to change for it to become a reasonable choice again.

## 1. Alignments (shapes)

**Question.** Where are stop-to-stop alignments drawn, generated and edited?

**Decision.** Add an **Alignment** tab to the pattern. Today's tabs for an existing pattern are
Stops · Timings · Details, so the new order is Stops · Timings · Alignment · Details.

- Segments are shown as saved, missing or unsaved.
- Segments are stored by stop pair and shared. Editing a shared segment asks "This pattern only"
  or "All N patterns".
- "Generate missing alignments" is a bulk action on Route › Patterns, and each pattern row shows
  its count of missing segments.

**Why.** The pattern owns the stop sequence that segments connect. After someone edits Stops, the
affected segments are one tab away.

| Rejected | Reason | Would change if |
|---|---|---|
| Route › Map tab showing every pattern | Stops and geometry would be edited on different pages | Planners mainly edited overlapping branches together |
| Top-level Alignments library | Alignment work happens when a pattern is created or its stops change; a pill is too prominent | Agencies maintained shared corridors apart from routes |

```
Route › Patterns                         Pattern › Alignment
  [Generate missing alignments]            A ━━━ B ┅┅┅ C ━━━ D
  Outbound main   12 stops  2 missing        saved  missing  saved
  Inbound main    12 stops  —              Segment B→C · used by 3 patterns
```

## 2. System configuration: agencies, feed info, export settings, feed URL

**Question.** Where do rarely changed, feed-level settings live?

**Decision.** One **Settings** entry. Its sections are grouped by scope. The entry was first placed
right-aligned next to the account menu; the header review (item 19) moved it into that menu.

| Scope | Sections |
|---|---|
| This version | Feed details · Agencies · Fares (item 10) |
| All versions | Export defaults · Published feed URL · Garages · Fleet (item 16) |
| Organization | Name · Users (item 18) |

Import and Export kept their pills here; the header review (item 19) later put them under one
GTFS pill.

**Product owner's input.**
- "It is rarely touched", so it belongs under Settings rather than in a task pill.
- They also suggested setting the agency when a version is created. That turned out to apply only
  to the blank version created with a new organization. Imported versions already take their
  agency from `agency.txt`. So:
  - a version without an agency asks for one on the Routes empty state and in the New route
    drawer, before the first route;
  - the import review flags a missing `agency.txt` and agencies whose timezones disagree.

| Rejected | Reason |
|---|---|
| A Feed pill grouping Details · Agencies · Import · Export | The product owner preferred Settings for rare tasks |
| A separate Feed pill | An eighth pill for a rare task |
| Feed settings in the version switcher menu | Hidden; nothing in the nav says where agencies are edited |
| Export settings as their own Settings tab, apart from Export | Superseded: all rare configuration moved to Settings |

```
Settings
  This version (Spring 2026)        All versions                 Organization
    Feed details                      Export defaults              Name
    Agencies                          Published feed URL           Users

Routes (version with no agency)
  ┌ No agency yet ──────────────────────┐
  │ Routes need an operating agency.    │
  │ Agency name  [                   ]  │
  │ Website      [                   ]  │
  │ Timezone     [America/Chicago  ▾]   │
  │ [Add agency]                        │
  └─────────────────────────────────────┘
```

## 3. Transfers

**Question.** Where are transfers listed, created and edited?

**Decision.** A **Transfers** tab on the Routes list page, next to Routes.
- It lists every transfer in the version, with filters for type, stop and route, and search.
- "New transfer" asks for the scope first (stop pair, route pair or trip pair), then shows only
  that scope's fields.
- Route Details and Station Details each link to the filtered list: "Transfers here (N)".

**Why.** The three scopes are anchored differently:
- stop pairs belong to a place;
- timed route pairs are schedule coordination;
- in-seat trip pairs need a shared block.

`transfers.txt` is only in the full GTFS export, so the list sits with the route data. In-seat
transfers created on Blocks (item 6) also appear here.

| Rejected | Reason |
|---|---|
| Stops & stations › Transfers | Under the product-role split, GTFS Planner-only users could not reach it. That split is now deferred (item 18), which weakens this reason. |
| A Transfers pill | Many small agencies leave `transfers.txt` empty |

```
Routes · [Transfers]
  [New transfer]   Type [All ▾]  Stop [▾]  Route [▾]  Search
  From               To                 Type       Min
  Central Stn P1     Central Stn P2     Min time   3:00
  Route 10           Route 22 @ Hub     Timed       —
  Trip 1041          Trip 2203          In-seat     —
```

## 4. Route editing, deactivation and deletion

**Starting point.** The routes list already has search, filters (type, agency, status), sorting,
badges and the New route drawer. What's missing is editing, deactivation, deletion, a badge
preview and a duplicate-name warning.

**Decision.** Route › Details becomes an **editable form in place**, like Pattern › Details.
- The page header's route name and badge act as the live preview.
- A duplicate short name gets an inline warning that doesn't block saving.
- Rarely used fields go under "Additional details".
- A "Status and removal" section holds:
  - **Deactivate route:** reversible, hides the route from export, keeps its data;
  - **Delete route:** its confirmation names the patterns and trips removed with it.

| Rejected | Reason |
|---|---|
| Reuse the New route drawer for editing | Crowded once the rarely used fields are added; would work differently from the pattern editor |
| Row actions on the routes list | A second editing surface. Could return later for bulk deactivation. |

```
‹ [10] 10 - Downtown / Airport          Active
Details · Patterns · Schedules
  Short name  [10     ]  ⚠ Route 10X already uses "10"
  Long name   [Downtown / Airport ]
  Type [Bus ▾]   Agency [Metro Transit ▾]
  Color [#0055A4]  Text [#FFFFFF]
  ▸ Additional details
  [Save changes]
  ── Status and removal ──
  [Deactivate route]  hides from export, keeps data
  [Delete route]      removes 4 patterns, 212 trips
```

## 5. Calendar coverage and combining calendars

**Starting point.** The calendar editing work already delivered:
- counts for calendars, run today and ending soon;
- a status filter;
- a version-wide service-gap callout;
- a three-month preview for each calendar;
- a drawer that changes dates across several calendars.

**Decisions.**
- **Coverage:** the list's Service dates column becomes a bar on a shared time axis, with a today
  marker and shaded service gaps.
- **Combining:** select calendars on the list, then **Combine calendars**, which opens a review
  drawer. AC-CAL-031 moves trips from a source calendar to a destination and keeps the source
  with zero trips, so the drawer asks for the destination and does not delete the sources.

The planned basic-blocking work groups calendars into *day types* without merging them. That meets
the blocks-view requirement to combine calendars (AC-SCHED-046) on its own.

| Rejected | Reason |
|---|---|
| A List / Timeline toggle | A second view of the same rows; you'd have to switch to compare |
| One aggregate coverage strip | Can't show which calendar causes a gap |
| "Combine with…" on the calendar page | Awkward for three or more calendars |

```
Calendars          3 calendars · 2 run today · 1 ending soon
                    Sep      Dec      Mar      Jun
Weekday             ████████████│██████░░░░     612  Active
Saturday            ████████████│██████         104  Ends soon
School days           ████ █████│███ ██           88  Active
                          today │
```

## 6. Advanced trip editing

**Starting point.** The planned route-schedules work adds:
- calendar, direction and pattern filters;
- row selection with bulk delete;
- series creation, duplicate and single-trip editing.

Frequency trips are read-only there. The planned basic-blocking work makes `block_id` read-only on
Schedules and edits it on Blocks.

**Added to Schedules** (no competing place):
- keyboard navigation in the grid;
- bulk actions: Shift times, Change timing, Change calendar, Copy to calendar;
- a "Custom times only" filter.

Filtering by block belongs on Blocks.

**Service days beyond the calendar.** GTFS expresses service days only through `service_id`, so the
answer is to create a calendar. AC-TRIP-038 to AC-TRIP-040 ask for weekday checkboxes on each trip;
that difference is still open.

**Frequencies decision.** In the Schedules add/edit drawer, choose "Scheduled trips" or "Every N
minutes". A frequency row opens a windows editor.
- *Rejected:* a frequency mode on the pattern, as in datatools. Switching modes deletes trips, and
  it hides the service type from the page where service is shown.

**In-seat transfers decision.** The Blocks › block drawer lists each trip-to-trip connection with
a **Riders stay on board** toggle, which writes a type 4 transfer.
- *Rejected:* a "Continues as trip…" picker in the Schedules drawer, because it can't show
  whether the two trips share a vehicle.
- AC-TRIP-041 asks for a checkbox on the trip form; that difference is still open.

```
Add trips                              Blocks › Block 101
  ( ) Scheduled trips                    06:02  10 Outbound  → 06:48
  (•) Every N minutes                        ↳ layover 6 min at Hub  [☑ Riders stay on board]
    09:00–12:00 every [20] min           06:54  22 Crosstown  → 07:40
    12:00–15:00 every [30] min               ↳ layover 12 min        [☐ Riders stay on board]
    [Add window]                         07:52  10 Inbound   → 08:38
```

## 7. Pattern comparison

**Decision.** Select two patterns on Route › Patterns, then **Compare patterns**. This opens a
full-width page under the route (`/routes/:route_id/patterns/compare?a=…&b=…`), and the Patterns
tab stays current. The page shows:
- stops side by side, with added, removed and moved stops marked by symbol and text;
- trip counts for the selected calendar;
- running-time differences for each shared segment.

The picker can include another route's pattern, for example 10 against 10X.

**Open difference.** AC-PAT-004 describes a matrix of *all* patterns, grouped by direction. It's
undecided whether the compare page opens as that matrix.

| Rejected | Reason |
|---|---|
| A comparison drawer | Two stop lists and their timing differences need full width |
| "Compare with…" in the pattern header | Not chosen for now; could be added later as a second entry point |

```
Route › Patterns › Compare
  [Outbound main ▾]        vs  [Outbound via Mall ▾]
  48 trips (Weekday)            12 trips (Weekday)
  1  Downtown TC    0:00         1  Downtown TC    0:00
  2  5th & Main     0:04         2  5th & Main     0:04
                             +   3  Eastgate Mall  0:11
  3  Hospital       0:09   → moved 4 Hospital      0:16  +7:00
```

## 8. Headsigns

**First proposal.** A version-wide Headsigns tab on the Routes list. It was withdrawn.

**Product owner's correction.** "Aren't headsigns really part of trips — which we might manage via
route patterns? A single route has many headsigns." A headsign belongs to a trip. It defaults
from the trip's timing, then from its pattern.

**Decision.** Headsigns are managed **at the pattern level only**. The editing fields already
existed:
- the pattern's and each timing's "Headsign for new trips";
- a stop headsign for each stop, inside a timing.

The additions:
- Next to each headsign field: "Used by N trips · M use a different headsign", with **Review
  trips**.
- Changing a headsign asks whether to update the trips that use the old one.
- The review drawer resets differing trips or keeps them, for example a short-turn trip.

**Rejected.** A version-wide headsign index. It would catch the same destination spelled
differently across patterns, but the product owner chose pattern level only.

```
Pattern › Details
  Headsign for new trips  [Downtown TC      ]
  Used by 45 trips · 3 use a different headsign [Review trips]
```

## 9. Loop routes

**Starting point.** Already supported.
- Each stop visit is its own row, so A → B → C → A is valid.
- Only the same stop twice in a row is rejected.
- Schedules shows each repeat visit as its own column.

**Decisions.**
- Distance along a loop's shape comes from the Alignment tab, whose segments follow stop-visit
  order.
- The route-level continuous pickup/drop-off default lives in Route › Details.
- The per-stop override lives in Pattern › Timings, in the "Boarding & headsign" disclosure next to
  pickup and drop-off type, with "Same for all timings".

**Rejected.** Setting it for each stop in Pattern › Stops, because that would split boarding rules
across two tabs.

## 10. Fare zones

**First proposal.** A Fares pill with Zones · Fare rules. It was withdrawn.

**Product owner's input.** "Fares should also be under settings — rarely touched."

**Decision.** **Settings › This version › Fares**, with two parts:
- **Zones:** a list with stop counts, and a map of stops colored by zone. You assign stops by
  selecting them.
- **Fare rules:** set by origin, destination and "contains" zones.

Stop details shows the zone read-only and links to Settings.

**Open difference.** AC-STOP-023 to AC-STOP-026 place the zone list in a Stops sub-section and a
zone dropdown on the stop edit form.

**Found during review.** `stops` has no `zone_id`, so zones are lost on import. Meanwhile
`fare_rules.txt` exports zone references that no stop carries.

## 11. GTFS-flex

**First proposal.** Round-trip only, with an export switch and no authoring UI.

**Product owner's input.** They pointed to [`generate-gtfs-flex`](https://github.com/derhuerst/generate-gtfs-flex)
and asked for a top-level Flex item.

**How that tool models flex.** A flex service is a *rule* applied to fixed routes:
- which routes it covers;
- a radius around each stop those routes serve;
- pickup and drop-off types;
- one booking rule.

From that rule it derives:
- `locations.geojson` areas;
- `booking_rules.txt`;
- route type 715;
- a flex copy of each trip;
- `stop_times` with pickup and drop-off windows.

**Decision.** A **Flex** pill, placed before Import and Export (now GTFS, item 19).
- **The list** shows each service's name, routes, area, booking type and notice.
- **A flex service** is one sectioned page with a single Save: Routes · Area (radius and map
  preview) · Boarding · Booking · Export preview.
- **Storage:** the app stores the services, the routes each covers, and booking rules. Areas and
  flex trips are derived at export.
- **The export switch** stays in Settings › Export defaults. The Flex list header shows its state
  and links there.
- **Route Details** shows "On-demand: <service>".

| Rejected | Reason |
|---|---|
| Flex pill after Calendars, or after Routes | The product owner chose the lower-weight position before Import |
| The export switch on the Flex page | The product owner kept all export switches together |
| Tabs for each section of a flex service | One page with one Save covers the few fields |

```
Flex                                        [New flex service]
  Service              Routes   Area     Booking     Notice
  Citybus door-to-door   4      300 m    Same day    60 min

‹ Citybus door-to-door
  Routes   [RT779 ×] [RT780 ×] [+ Add route]
  Area     Radius [300] m    [map preview]
  Boarding Pickup [Phone agency ▾] Drop-off [Coordinate ▾]
  Booking  [Same day ▾]  Notice [60] min  Phone [...]
  Export   Adds 38 areas · 412 flex trips
  [Save changes]
```

## 12. Interpolated stop times

**Starting point.**
- A timing requires an arrival and departure time at every stop, so trips built from timings
  already export every time.
- Blank times appear only on imported trips and on custom-times trips.
- The typing burden is in authoring: people know the timepoint times, not the in-between times.

**Decision.**
- A **Fill times between timepoints** action in Pattern › Timings.
- **Interpolate blank stop times** in Settings › Export defaults.
- After a follow-up from the product owner, the **estimate method** (by distance along the
  alignment, or even spacing) also moved into Settings › Export defaults. Both the action and the
  export use it, and the button stays in Timings.

**Rejected.**
- Export setting only: it meets the requirement's wording but misses the authoring burden.
- The Timings action only: imported blank times would be left as they are.
- One setting driving both, with no button: the product owner kept the explicit action.

## 13. Feed URL and publishing

**Starting point.** Nothing serves a permanent URL. Export files are private and expire after 24
hours.

**Decision.**
- **Settings › Published feed URL** shows:
  - the URL, with a Copy URL button;
  - what is live, for example "Serving Spring 2026 · exported Sep 20 · 0 errors";
  - a note that the URL never changes.
- **Publish to feed URL** sits next to Download on a finished full export, after validation.
  Publishing an export with errors needs a confirmation that names the count.

| Rejected | Reason |
|---|---|
| Publish from Settings by choosing a version | You'd decide without the validation results in view |
| Publish every full export automatically | Exports with errors or in progress would reach data consumers |

## 14. Multiple agencies

**Decision.** **Settings › Agencies.**
- The list shows name, URL, timezone and route count. The route count links to the Routes list
  filtered by agency.
- A version with one agency opens straight to its detail.
- A new agency must use the version's timezone. Changing the timezone changes it for every agency.
- The last agency cannot be deleted.
- Deleting an agency that has routes asks where to move them, then moves the routes and deletes
  the agency in one step.

**Rejected.**
- Block the delete and send the user to the Routes list: that needs a separate bulk "Change
  agency" feature.
- Both approaches together: not needed yet.

```
Delete Metro Transit?
  Metro Transit runs 14 routes.
  Move them to [County Connector ▾]
  [Move routes and delete agency]
```

## 15. Route schedules and timetable paste

Route schedules shipped in #698 during the review; timetable paste is still planned. Both are
placed as designed:
- Route › Schedules tab, with "Paste timetable" as an action on it;
- the additions from item 6.

## 16. Blocks, runs, garages, fleet and rosters (planned)

**As designed.** Garages and fleet shipped in #697 during the review, with the Blocks pill and
`/blocks/garages` and `/blocks/fleet`.
- A Blocks pill with sub-navigation Blocks · Runs · Garages · Fleet.

**Problems.**
- Garages and fleet belong to the organization, but they sat under version URLs.
- "Blocks" was the label on a section that included operator runs.
- The nav would reach eight pills.

**Decision.**
- An **Operations** pill with Blocks · Runs · Rosters.
- Garages and Fleet move to **Settings › All versions**. The Blocks empty state links there.
- The deadhead, relief and interlining drawers stay on Blocks, where changing them redraws the
  blocks.

| Rejected | Reason |
|---|---|
| Keep Blocks and Rosters pills, move Garages and Fleet | Still eight pills, and "Blocks" still holds runs |
| Keep the planned design | Organization data stays under version URLs |

## 17. Scheduled pathway closures (planned)

Placed as designed: an **Evolutions** tab on the station, after Reachability. Its calendar picker
is read-only.

## 18. Access

**Proposed.** A mapping of each destination to a product role: GTFS Planner, Pathways Studio,
and organization admin.

**Product owner's decision.** "Let's just fully combine everything for now."
- Every editor sees every destination.
- The product-role split is deferred.
- The mapping is kept in [Information Architecture › Access](information-architecture.md#access)
  for when they return.

**Also moved.** The organization admin's **Users** pill moved into Settings › Organization, next
to the organization name. It's an occasional task, so the Settings rule applies to it too.

## 19. Header: GTFS pill, Settings in the account menu, initials avatar

**Question.** The header wrapped to two rows well above laptop widths, and it was restyled to the
TransitOps application design system's Top navigation pattern. How should Import, Export and
Settings sit in it?

**Measurements.** Measured in a header prototype that uses the design system's type and spacing.
The width is the narrowest viewport at which the header stays on one 73 px row:

| Header | One row down to |
|---|---|
| Import and Export pills, Settings link in the bar | 1268 px |
| The same, for a system administrator (adds Organizations) | wraps even at 1440 px |
| Import in the version menu, Export pill, Settings link in the bar | 1200 px |
| One "Import and export" pill, Settings link in the bar | 1272 px |
| **GTFS pill, Settings in the account menu** | **1112 px** (system administrator: 1248 px) |
| Today's header | 1360 px |

A combined "Import and export" pill is as wide as the two separate pills (588 px against 586 px of
nav links), so combining under that label saves no space.

**First proposal.** Keep Import and Export apart and move Import into the version menu as "Import
new version", because Import creates a version and Export works on the current one.

**Product owner's input.** "Maybe Import/Export should be: GTFS; Settings could be under the
avatar, the avatar could be more styled (using user initials)."

**Decision.**
- **GTFS pill.** Import and Export share it. Export is the default tab because it is used after
  every round of edits; Import is the second tab. Each tab states what it acts on: Export works on
  the current version, Import creates a new version. The pill is current on both pages and on the
  validation and station reachability result pages opened from an export run.
- **Settings in the account menu.** It is the first item, under the organization name, with a hint
  line naming what is inside. Account settings and Log out follow the "Signed in as" identity. The
  trigger is marked current on Settings and account pages, since no pill is.
- **Initials avatar.** The trigger shows initials from the part of the email before the @, split on
  `.`, `_`, `-` and `+`: `dana@` shows D and `alex.kim@` shows AK. Users have no name field, and
  adding one is a separate change. The circle is a neutral navy tint; color in the header still
  marks only the current area.
- **Header only.** The header takes the design system's fonts, tokens and focus outline. Pages keep
  their current styles. The header's pink selection tint then sits beside the pages' purple
  buttons and links. Whether to switch the app-wide font and primary color is a separate decision;
  that switch changes about 200 uses of the primary color, including focus rings.
- **Wrapping on phones.** Below the medium breakpoint the header wraps, as it does today. The design
  system's single Menu for phones is not adopted yet, because the version switcher would need a
  second, menu-based form.

| Rejected | Reason | Would change if |
|---|---|---|
| Import and Export pills | Gives Import, a rare task, the same weight as Export and makes the header wrap below 1268 px | Customers re-imported feeds weekly, making Import a daily task |
| Import in the version menu | Hidden two clicks deep; the product owner preferred one visible GTFS area | The GTFS page gained enough tabs to crowd Import out |
| One "Import and export" pill | Saves no width | — |
| Settings as a link in the bar | Permanent space for a rarely used destination | Settings became a daily task |
| A colored avatar per user | Adds a color that encodes nothing | The header showed several people at once, as in presence indicators |

```
Pathways Studio   Routes  Calendars  Operations  Stops & stations  Flex  GTFS   [Version  Spring 2026 ▾] (D ▾)
North Coast Transit                                                             ┌──────────────────────────────┐
                                                                                │ North Coast Transit           │
GTFS                                                                            │ Settings                      │
  Export · Import                                                               │   Agencies, fares, exports…   │
                                                                                │ ───────────────────────────── │
                                                                                │ (D) Signed in as dana@…       │
                                                                                │ Account settings              │
                                                                                │ Log out                       │
                                                                                └──────────────────────────────┘
```
