---
id: JRNY-001
title: Import a GTFS feed
type: journey
status: draft
owner: gtfs-planner
last_reviewed: 2026-10-01
review_interval_days: 90
verified_against:
  - gtfs-planner@baf909cd2bcace5cc8918b2ba2041260270bdde0
repos: [gtfs-planner]
actor: organization editor
roles: [] # no ROLE-## identities exist; the registry's actor column is read from the mount hooks (registry OQ-004)
jobs: [JOB-0001, JOB-0002]
screens: [SCRN-007, SCRN-034]
captures: [] # no capture of this journey exists yet; see section 9
scenarios: [import]
features: [] # docs/feature-list.md names capabilities but issues no FEAT-## IDs
rules: []
seams: [SEAM-001]
e2e_lanes: [import_export.spec.js, import_upload_visual.spec.js]
context_keys: [activeVersion, newVersionName, publishedVersion] # proposed; see OQ-002
tests:
  - assets/e2e/import_export.spec.js
  - assets/e2e/import_upload_visual.spec.js
derived_from:
  - docs/journey-registry.md@5bac78aa
---

<a id="1-goal"></a>
## 1. The goal

Load the GTFS feed the agency already publishes into the product as a **new version** and leave the
version already in view untouched. "Completed" is observable as one new published version whose
routes, stops, trips, stop times and calendar rows equal the uploaded zip's rows. The journey is
launched from the dashboard's first-use card, whose link reads `Import feed`.

<a id="2-actor-and-situation"></a>
## 2. Actor and situation

An organization editor — a member holding the `pathways_studio_editor` role, the role
`GtfsPlannerWeb.Gtfs.ImportLive` requires in `on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_editor}`.
They start on the dashboard with an organization and a version but no routes, stops or calendars,
which is the state `GtfsPlannerWeb.Home.PlannerComponents.first_use/1` renders for. The page's own
copy states the trigger: "Most agencies already have a GTFS feed, from a scheduling vendor or the
trip-planning apps they work with. Importing it is the fastest way to start."

At the end the editor must believe two things, not one: that their riders' current service is now
editable, and that the version they were looking at a moment ago has not changed underneath them.
The product states the second in the workspace subtitle — "Creates a new version. <version> isn’t
changed." — and again in the result card. The first is what the published version's own rows
prove.

<a id="3-job-stories"></a>
## 3. Job stories

JOB-0001  When my agency already has a GTFS feed, I want to load it as a new version, so I can start
editing the service riders actually run.
Evidence: `docs/feature-list.md` "Import a complete feed as a new version"; the first-use card
`lib/gtfs_planner_web/live/home/planner_components.ex`; the `@source_options` feed entry in
`lib/gtfs_planner_web/live/gtfs/import_live.ex`.
Confidence: inferred — no persona or job-statement document names this actor (OQ-003)

JOB-0002  When an import is running, I want to know whether it is still working and whether my
existing version is safe, so I can leave the page without losing work or double-importing.
Evidence: the importing card's "You can leave this page. The import keeps running, and it's listed
under Unfinished imports if it stops." and the "Keeps" row of the import summary.
Confidence: inferred (OQ-003)

<a id="4-stages"></a>
## 4. Stages

The eight-stage frame maps as: **locate** (4.1), **prepare** (4.2), **confirm** (4.3), **execute**
(4.4), **monitor** (4.5), **conclude** (4.6). **Define** is absent — the organization, its role and
its version exist before the journey starts, and nothing on this path creates one. **Modify** is
absent from the feed path by design: a complete feed creates a second version, and the version in
view is never edited. The station-changes workflow on the same screen does modify, and belongs to
its own registered journey; this page follows only the `feed` source.

All stages are pass-throughs: no stage is revisited except the recovery loop in 4.6, which returns
the editor to the same route on a later visit.

### 4.1 Locate — the dashboard's first-use card

*Why this stage exists:* for a version with no routes, stops or calendars the dashboard offers the
import as its single primary next step, so the journey's first screen names the goal before any
form does.

| Surface | Action and decision | Establishes | Requires | Exit |
|---|---|---|---|---|
| gtfs-planner: `/` (SCRN-007) | Read the card "Import your current feed" and press `Import feed`; the decision is that the agency's existing feed is the starting point rather than a hand-built service | `activeVersion` (proposed) | — | The version's `/gtfs/:version/import` (SCRN-034) |

The card's link is a plain anchor to `~p"/gtfs/#{@version_id}/import"`, so the version travels in
the path and the destination re-derives it in its mount. The first-use panel replaces the resume
and check regions entirely (`AC-12` in the component's docstring), so the editor never sees a
conflicting suggestion to build a route first.

### 4.2 Prepare — choose the workflow, the file and the name

*Why this stage exists:* the page holds two workflows with opposite consequences on one screen, and
this is where the editor commits to the feed one and names what it will create.

| Surface | Action and decision | Establishes | Requires | Exit |
|---|---|---|---|---|
| gtfs-planner: `/gtfs/:version/import` (SCRN-034) | Keep the "A complete feed" source card selected, press `Choose a .zip file` (or drag the file in), and type a version name; the decision is that the whole feed becomes a **new** version, not an edit to the current one | `newVersionName` (proposed), the upload's entries | `activeVersion`, so the subtitle can name the version that will not change — visible on this surface | The same route, with the form enabled |

Visible strings, quoted from `feed_form/1`: the dropzone's label `Feed files`, its help text "One
.zip, or up to 50 .txt or .csv files. Each file can be up to 200 MB. A .zip uploads faster.", its
action `Choose a .zip file` and hint `or drag it here`; the name field's label `Version name`,
placeholder "e.g., October 2026 service" and help "Appears in the version menu. It must differ from
your other versions." The submit button reads `Import feed` and is disabled until a file is chosen,
with the reason `Choose a feed file to import.`.

Files this import does not use are not silently read: `validate/3` names them and the page renders
`1 file will be skipped` (or the plural form) with the list, and — for an organization whose product
shows Fleet and Garages — points at those settings sections for TODS data instead.

### 4.3 Confirm — what the import will do, before the button

*Why this stage exists:* the editor's only irreversible-looking action is one click, and the page
states its four consequences in the surface itself rather than in a dialog.

| Surface | Action and decision | Establishes | Requires | Exit |
|---|---|---|---|---|
| gtfs-planner: `/gtfs/:version/import` (SCRN-034) | Read the summary's `Creates` / `Reads` / `Keeps` / `Then` rows and decide to go ahead | — | the chosen file and name from 4.2, both of which the summary restates | The same route with the import running |

The summary (`#gtfs-import-summary`, rendered only once at least one file is chosen) reads: "A new
version named “<name>”"; what will be read, by name and size; `<version> unchanged`; and
"Publishes the new version when the import finishes. If anything fails, nothing is published." The
aside states the same three steps as `How importing works` and adds "You can leave this page while an
import runs."

There is no confirm dialog on this path; the summary is the confirmation. The dialog on this screen
(`Delete failed version?`) belongs to the recovery loop in 4.6, not to a start.

### 4.4 Execute — press `Import feed`

*Why this stage exists:* this is the one user action the whole journey turns on, and the page makes
it single and irreversible.

| Surface | Action and decision | Establishes | Requires | Exit |
|---|---|---|---|---|
| gtfs-planner: `/gtfs/:version/import` (SCRN-034) | Press `Import feed`; the decision is irreversible and the page says so | an import run in `pending`/`running` | `newVersionName` and the chosen files | The same route showing the importing card |

The button carries the reason "You can't cancel an import once it starts." While it runs, its label
becomes `Importing…` with a spinner, and the form is replaced by the importing card. `import/3`
rejects a second submission while one is active and rejects a submission with no files, so a
replayed event cannot start a duplicate run.

### 4.5 Monitor — the import in progress

*Why this stage exists:* a feed takes long enough that the editor has to be able to leave the page
and come back to a truthful state.

| Surface | Action and decision | Establishes | Requires | Exit |
|---|---|---|---|---|
| gtfs-planner: `/gtfs/:version/import` (SCRN-034) | Optionally leave the page and return; the page reconstructs its state from PostgreSQL on mount | run progress (file and row count) | `activeVersion`, so the run's own version is named | The same route showing the result, or an `Unfinished imports` row |

The importing card is titled "Importing “<name>”" with the subtitle "Reading your files into a new
version.", an `In progress` badge, and a progressbar labelled by the file being read
(`<processed> of <total> rows`). It also states: "You can leave this page. The import keeps running,
and it's listed under Unfinished imports if it stops. An import can't be cancelled once it starts."

Reconnection is by design rather than by page state: `mount/3` adopts runless legacy failed targets
into durable, organization-scoped recoverable runs and reconciles expired leases before it renders,
so a reload or a reconnect shows the same run.

### 4.6 Conclude — the published version, or a recoverable run

*Why this stage exists:* the terminal outcome has two honest shapes — the new published version, or
an attempt that stopped and can still be published or deleted.

| Surface | Action and decision | Establishes | Requires | Exit |
|---|---|---|---|---|
| gtfs-planner: `/gtfs/:version/import` (SCRN-034) | Read the result card, then either press `Open new version` to start editing, press `Import another feed`, or follow `Check the new version for problems` | `publishedVersion` (proposed) | the name typed in 4.2, which the result card repeats | The new version's `/gtfs/:version/routes` (JRNY-002's area), or the same route with an empty form |

The result card (`#gtfs-import-result`, `aria-live="assertive"`) reads `Imported “<name>”` and "The
new version is published and ready to open. <version> is unchanged.", with figures for Levels, Stops
and Pathways, an optional skipped-files line, and conditional agency findings. `Open new version`
navigates to the published version's routes.

The other terminal shape is the `Unfinished imports` card, which appears above the form whenever a
run is running or stopped before publishing. Each row carries the version's name, a status word —
`Preparing`, `Running`, `Partly imported`, `Failed`, `Interrupted`, `Not published`, `Deleting` or
`Delete failed` — and, for a run in one of the stopped states `failed`, `partial`, `interrupted`,
`publication_failed` and `cleanup_failed`, a `Discard failed import` button. A run whose publication
alone failed (`publication_failed`) also offers `Publish version`. Discarding is confirmed in the
dialog titled `Delete failed version?`, and afterwards the form shows "Deleted the failed version
“<name>”." with the reason "Its name is back in the form. Choose the feed again to retry."

<a id="5-entry-and-exit-points"></a>
## 5. Entry and exit points

**Entries.** One row per way the journey starts.

| Entry | Source | Notes |
|---|---|---|
| The dashboard's first-use card, link `Import feed` | `lib/gtfs_planner_web/live/home/planner_components.ex` (`#firstuse-import`) | The version has no routes, stops or calendars, so the card is the page's primary action |
| The GTFS area's `Import` tab | `lib/gtfs_planner_web/components/core_components.ex` GTFS sub-nav; the tab is reached by pressing the header's `GTFS` destination, which opens `/gtfs/:version/export` | The import is a tab of the export page, not a separate navigation item |
| A direct URL, `/gtfs/:version/import` | `lib/gtfs_planner_web/router.ex` line 204 | Guarded by the `:require_gtfs_editor` mount hook; a viewer is denied |
| An unfinished run, after a reload or a reconnect | `mount/3` in `import_live.ex` reconstructs the run list | The editor did not choose this; they returned to a state that was already running |

**Exits and abandonment.** Most abandonment lives in prepare and execute, so both get rows.

| Exit | Where it happens | State left behind |
|---|---|---|
| No file chosen | The disabled submit, or a crafted empty submission | Nothing. `import/3` answers "Choose a file to import." and no run exists |
| No version name | 4.2, on blur or on submit | The chosen file stays in the upload; the name field takes focus with "Enter a name for the new version." |
| A name already in use | 4.2/4.3 | "You already have a version named “<name>”. Choose a different name."; no run is created and the chosen file is preserved |
| Closed the tab mid-import | 4.4/4.5 | A running import. It finishes or stops on its own and appears under `Unfinished imports` on the next visit |
| The import fails part-way | 4.5/4.6 | A stopped run holding an unpublished version. Nothing is published; the run can be published or deleted, and deleting frees the name |
| The zip contains only unrecognized files | 4.2 | A skip notice; the run, if started, publishes only what it read, and the result card lists the skipped files |

<a id="6-seams"></a>
## 6. Seams

**SEAM-001** (identity, `/users/log_in` → any authenticated route) — The editor's session is the
only thing that crosses here, and the organization and version context is re-derived on the
destination's mount rather than carried in the URL the editor clicked. Consequence for this journey:
the link on the dashboard carries the version in its path, so the destination does reconstruct the
editor's working context, but a page the editor reached from anywhere else (a stale bookmark, a
shared link) resolves against whatever version the router's `:version` assign picks, and nothing on
the import page tells the editor which organization it is writing into beyond the header. Related
finding: registry OQ-004 (actors are read from mount hooks because no permission model exists).

No crossing in this journey leaves the application: the feed is uploaded in, read server-side, and
published into the same database, and no third party is called on this path. The seam ledger's
`SEAM-005` (the MobilityData validator) is reached only when the editor presses `Check the new
version for problems`, which is the start of JRNY-003 rather than a stage here.

<a id="7-features-and-rules-per-stage"></a>
## 7. Features and rules per stage

None. `docs/feature-list.md` names the capabilities this journey uses — "Import a complete feed as a
new version" and its note that "The version in view is never touched" — but issues no `FEAT-##`
identifiers, and no rule registry with `BR-##` identifiers exists in this repository. Naming the
capability by its registry row would require inventing an ID, so this section stays empty until a
registry issues one.

<a id="8-end-to-end-examples"></a>
## 8. End-to-end examples

Row counts below are read from `test/fixtures/gtfs/ux_qa/sample-feed.zip`, the scenario's own
fixture: 1 agency, 5 routes, 9 stops, 11 trips, 28 stop times, 2 calendars, 1 calendar date.

#### EX-0101 A complete feed becomes a new published version
**Given** the QA seed's `blank` organization "Demo Transit Authority" with its published version
"First Version" and no routes, stops or calendars
**And** the editor `qa-editor@gtfs-planner.test` is signed in and reading the dashboard
**When** the editor presses `Import feed`, chooses `sample-feed.zip`, names the version
"QA Import" and presses `Import feed`
**Then** the result card reads "Imported “QA Import”" and "The new version is published and ready to
open. First Version is unchanged."
**And** the published version holds 5 routes, 9 stops, 11 trips, 28 stop times and 2 calendars, each
equal to the zip's rows
**And** "First Version" still holds none of those rows
Test: none — the two mapped lanes prove the upload's presentation and the station diff review, not a
feed publishing (`assets/e2e/import_export.spec.js`, `assets/e2e/import_upload_visual.spec.js`); the
scenario's `import-feed` check is the gate that proves the counts.

#### EX-0102 The version name is already taken (boundary)
**Given** the same organization after EX-0101, with a published version named "QA Import"
**When** the editor chooses another feed and types "QA Import" as the name
**Then** the page shows "You already have a version named “QA Import”. Choose a different name."
beside the name field
**And** no import run is created and no version is added
**And** the chosen file is still in the upload, so correcting the name does not mean choosing it again
Test: none — no committed lane drives a duplicate-name submission; the `import` scenario's harness
check asserts the count of new published versions and would fail on a spurious one.

#### EX-0103 The import fails part-way (failure and recovery)
**Given** the same organization and a zip whose `routes.txt` is missing
**When** the editor names the version "QA Import 2" and presses `Import feed`
**Then** nothing is published and the attempt is listed under `Unfinished imports`
**And** the row offers `Discard failed import`, which opens the dialog titled
`Delete failed version?`
**And** confirming the delete shows "Deleted the failed version “QA Import 2”." with the reason
"Its name is back in the form. Choose the feed again to retry."
**And** the version in view is unchanged
Test: none — the recovery card's presentation is exercised by no committed lane; the paused station
review in `import_export.spec.js` covers the other workflow's recovery, not this one.

<a id="9-visual-and-evidence-links"></a>
## 9. Visual and evidence links

| Stage | Kind | Reference | Notes |
|---|---|---|---|
| 4.1 Locate | e2e lane | `assets/e2e/home.spec.js` | Measures the dashboard's seven states; it records `firstuse` but proves no capture of the card's text |
| 4.2 Prepare, 4.3 Confirm | e2e lane | `assets/e2e/import_upload_visual.spec.js` | Upload presentation and diff readability at six viewports; screenshots to `test-results/`, disposable |
| 4.2 Prepare, 4.4 Execute | e2e lane | `assets/e2e/import_export.spec.js` | Upload entry, submit's disabled state, name field's keyboard access and the target-size condition on the dropzone |
| 4.6 Conclude | journey capture | Not captured — no run of `JRNY-001/import` exists yet, and the captures this page will cite are produced by the pilot steps. | Would be cited as `JRNY-001/import-s003` |
| All stages | product documentation | `docs/screen-inventory.md`, `docs/inventories/gtfs-operation-screens.md` | `SCRN-034` is the registered screen for `/gtfs/:version/import`; both mark it undocumented at the commit this page was written against |
| 4.6 Conclude | requirement input | `docs/manual-test-plan.md` | The manual plan's import path, merged into this journey as seed S-306 |

No capture ID is cited in this page because none exists. A capture that is later produced is cited by
its backticked ID, never by an image path.

<a id="10-test-scenario"></a>
## 10. Test scenario

### import

- **Persona:** Scheduler at a small transit agency with an organization editor account.
- **Goal:** Load the feed your scheduling system exported (sample-feed.zip) so you can start editing it.
- **Account:** editor
- **Seed:** blank
- **Start path:** /
- **Files:** sample-feed.zip
- **Success check:** import-feed — one new published version whose route, stop, trip, stop-time and calendar counts equal the zip's row counts
- **Reference actions:** 4
- **Entry route:** /gtfs/:version/import

The four reference actions are the ones after sign-in, waits excluded: press `Import feed` on the
dashboard's first-use card; choose `sample-feed.zip` at `Choose a .zip file`; type the version name;
press `Import feed`. Reading the result and leaving the page are not actions, and neither is the
`Open new version` link — the terminal outcome is the published version itself, which the check
observes outside the UI. This is the executed count, read from `proxies.actions` of the run that
recorded the reference trail for `JRNY-001/import`, not an estimate; the trail's commands and run
directory are in `.specs/31-ux-journey-qa/evidence/reference-import.md`.

## Open questions

- OQ-001 — The `import-feed` check this scenario names does not exist yet;
  `assets/qa/checks/` is empty in this checkout. It lands in a later step of this change, and until
  then the scenario cannot be executed. Owner: spec step 54.
- OQ-002 — `context_keys` and every `Establishes` / `Requires` value on this page are proposed. This
  repository has no E2E ledger or journey catalog to take key names from, and no documented
  `establishes` / `requires` contract exists to propose against. Owner: product owner.
- OQ-003 — Both job stories are `inferred`. No persona document, funnel doc or lane `intent` field
  names this actor's motivation; the stories are read from the shipped first-use copy and the feature
  registry row. Owner: product owner.
- OQ-004 — `roles: []` is empty because no `ROLE-##` identity exists; the actor column comes from
  the registry's reading of `GtfsPlanner.Authorization.Roles` and the mount hooks. Registry OQ-004
  asks for the same derivation through a permission model. Owner: product owner.
- OQ-005 — The scenario's `Goal` names the file the tester will see but not the version name the
  editor must invent, and the page offers no default. Whether the harness should type a name or
  whether the product should prefill one is a product decision, not a documentation one. Owner:
  product owner.
- OQ-006 — Resolved. `Reference actions: 4` is now the executed count from the run that recorded the
  reference trail for `JRNY-001/import`, not an estimate. Owner: the reference-trail step.
- OQ-007 — No capture of this journey exists, so section 9 cites none. Which states the pilot
  captures must cover — the first-use card, the import form, the result card — is a decision for the
  pilot steps. Owner: product owner.

## Changelog

| Date | Version | Change | Author |
|---|---|---|---|
| 2026-10-01 | 1 | Initial page: stages, seams, examples and the `import` scenario for JRNY-001 | spec step 37 |
| 2026-10-01 | 2 | Replaced the estimated `Reference actions: 4` with the count the recorded reference trail executed | spec step 62 |
