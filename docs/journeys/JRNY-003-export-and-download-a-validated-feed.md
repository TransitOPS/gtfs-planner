---
id: JRNY-003
title: Export and download a validated feed
type: journey
status: draft
owner: gtfs-planner
last_reviewed: 2026-10-01
review_interval_days: 90
verified_against:
  - gtfs-planner@a435f40f0481ac63b757df5e475de3863bc3cf6d
repos: [gtfs-planner]
actor: organization editor
roles: [] # no ROLE-## identities exist; the registry's actor column is read from the mount hooks (registry OQ-004)
jobs: [JOB-0005, JOB-0006]
screens: [SCRN-035, SCRN-036]
captures: [] # no capture of this journey exists yet; see section 9
scenarios: [export]
features: [] # docs/feature-list.md names capabilities but issues no FEAT-## IDs
rules: []
seams: [SEAM-001, SEAM-005, SEAM-010]
e2e_lanes: [import_export.spec.js, garages_fleet.spec.js]
context_keys: [activeVersion, exportType, exportRunId, validationSummary] # proposed; see OQ-002
tests:
  - assets/e2e/import_export.spec.js
  - assets/e2e/garages_fleet.spec.js
derived_from:
  - docs/journey-registry.md@5bac78aa
---

<a id="1-goal"></a>
## 1. The goal

Turn the version in view into a GTFS file the editor's riders can actually use, and know it is worth
sending. "Completed" is observable as one export run whose ZIP has been downloaded, with a feed
check completed against the same version. The journey is launched from the GTFS area's Export tab,
which the header's `GTFS` destination opens.

<a id="2-actor-and-situation"></a>
## 2. Actor and situation

An organization editor — a member holding the `pathways_studio_editor` role, the role
`GtfsPlannerWeb.Gtfs.ExportLive` requires in `on_mount {GtfsPlannerWeb.EnsureRole,
:require_gtfs_access}`. They start on a published version that already holds the agency's service,
either one they have just imported (JRNY-001's result card links here with `Check the new version for
problems`) or one they have been editing (JRNY-002 ends here). The page states the situation itself:
"Create a file of `<version>` for trip planners such as Google Maps and Transit app."

At the end the editor must believe three things, not one: that the file holds the service they think
it does, that nothing in it will make a trip planner reject the feed, and that the copy they hold is
the one the product built. The first is the file inventory; the second is the check's verdict; the
third is the run's own `Created … · Available until …` line, which states both when the bytes were
written and when the download ends.

<a id="3-job-stories"></a>
## 3. Job stories

JOB-0005  When my agency is ready to publish, I want one file of the version in view with its real
record counts in front of me, so I can tell what I am about to send before I send it.
Evidence: the `Create a feed file` card's "What goes in this file · Tables with no records are left
out." and its per-file `Records` column (`lib/gtfs_planner_web/live/gtfs/export_components.ex`,
`contents/1`); the feature registry rows "Export a version's feed" and "Download the latest export
file" in `docs/feature-list.md`.
Confidence: inferred — no persona or job-statement document names this actor (OQ-003)

JOB-0006  When I am about to hand a feed to trip planners, I want the standard checker to have run
against it and to read what it found, so I am not the first person to find a broken trip.
Evidence: the `Check for problems` card's lede, "Runs the MobilityData GTFS Validator, the standard
open-source checker for transit feeds, on this version's data.", and its `verdict/1` messages; the
registry's `SEAM-005` row, which names `lib/gtfs_planner/gtfs/validator.ex`.
Confidence: inferred (OQ-003)

<a id="4-stages"></a>
## 4. Stages

The eight-stage frame maps as: **locate** (4.1), **prepare** (4.2), **confirm** (4.3), **execute**
(4.4), **monitor** (4.5), **conclude** (4.6). **Define** is absent — the organization, its role and
its version exist before the journey starts. **Modify** is absent from this path by design: the
export writes bytes out of the version and changes nothing in it; edits belong to JRNY-001 and
JRNY-002, and the loop back into the version is the user's decision, not this page's.

Stages 4.4 and 4.5 are the only ones the editor waits on, and the page says so in both states:
"This page updates on its own, and you can leave and come back."

### 4.1 Locate — the GTFS area's Export tab

*Why this stage exists:* the export is a tab of the GTFS area rather than a navigation item of its
own, so the editor's first act is choosing GTFS, and the destination is already the Export page.

| Surface | Action and decision | Establishes | Requires | Exit |
|---|---|---|---|---|
| gtfs-planner: `/gtfs/:version/export` (SCRN-035) | Press `GTFS` in the header navigation, or the Export tab of a page already in the GTFS area; the decision is which version's feed to publish | `activeVersion` (proposed) | — | The same route, with the export workspace rendered |

`navigation.ex`'s `main_tasks/5` binds `gtfs: {"GTFS", ["export", "import", "validation",
"station-reachability"]}`, so the header's `GTFS` destination opens `/gtfs/:version/export` directly
and the page's own `gtfs_sub_nav` (`#gtfs-tab-export`, `#gtfs-tab-import`) carries the second hop.
The version travels in the path and the router resolves it, so a bookmark or a shared link still
lands on one version's export.

### 4.2 Prepare — choose what goes in the file, and read what will

*Why this stage exists:* three different artifacts come out of this one page for three different
consumers, and the decision is which consumer this export is for.

| Surface | Action and decision | Establishes | Requires | Exit |
|---|---|---|---|---|
| gtfs-planner: `/gtfs/:version/export` (SCRN-035) | Read the tiles and the per-file `Records` table, and confirm the selected radio; the decision is whether this file is for trip planners, for a station tool, or for an operations vendor | `exportType` (proposed), the file inventory | `activeVersion`, so the card's lede can name the version being written — visible on this surface | The same route, with the run band ready to act |

The radio group (`#gtfs-export-form`, legend `What are you exporting?`) offers whole-card targets,
each with a name, a description and a muted technical format: `Full feed` — "Routes, stops, trips,
calendars and fares. The file trip planners use." / `GTFS`; `Station pathways only` — "Stops, levels
and pathways. Not a complete feed on its own." / `GTFS pathways files`; and, for an organization
whose product shows it, `Feed with operations data` — "Full feed plus garages and vehicles, for
CAD/AVL vendors. Keep it private." / `GTFS + operations (TODS)`. The selection is not local state: the
form's `phx-change` patches `?type=`, `handle_params/3` re-resolves it, and any other value falls back
to the full export (`export_type_from_param/1`, `resolve_export_type/2`).

The `What goes in this file` block (`#export-contents`) states its own rule — "Tables with no
records are left out." — then gives four or five headline counts and a `See every file` disclosure
(`#export-files`) listing every GTFS table with its `Records` count; a table with no records says
`left out` instead of listing a file that will not exist. It closes: "Diagram, level and image data
is added to the ZIP as extra files when it exists, and isn't listed here."

Two notices sit on this surface because they change what the file will contain. `#export-missing-times`
states what the next export does with stops that have no time — `Missing stop times: left blank.`
with the count and "so each rider app will guess them its own way.", or `Missing stop times:
estimated.` with the method — and links to Export defaults. For a Pathways selection carrying
scheduled closures, `#export-pathways-closures-omitted` states "Pathways export leaves out `<n>`
scheduled closures" and offers `Choose Full export`, which patches the type and moves focus to the
Full option.

### 4.3 Confirm — what this run will produce, before the button

*Why this stage exists:* the export is asynchronous and its file expires, so the editor commits
once and needs the page to say what that commit means.

| Surface | Action and decision | Establishes | Requires | Exit |
|---|---|---|---|---|
| gtfs-planner: `/gtfs/:version/export` (SCRN-035) | Read the run band (`#export-run-status`) — `No full feed exported yet` with "Export to create a ZIP file. It stays available to download for a short time." — and press `Export feed` | the decision to write the file now | the chosen type and the counts from 4.2 | The same route with the run queued |

There is no confirm dialog on this path. The empty state's own sentence carries the retention
promise, and the band is `aria-live="polite"` with a focusable title, so a keyboard reader is moved
to the new state rather than left on a button that vanished.

### 4.4 Execute — the export run

*Why this stage exists:* packaging a version takes long enough that the editor will leave the page,
and the run must survive that.

| Surface | Action and decision | Establishes | Requires | Exit |
|---|---|---|---|---|
| gtfs-planner: `/gtfs/:version/export` (SCRN-035) | Watch the band move through `Queued` and `Building your file`; optionally press `Cancel export` | `exportRunId` (proposed) | `exportType`, `activeVersion` | The same route showing `Ready to download`, a failure, or `Download expired` |

`start_export/3` creates the durable run (`ExportRuns.create_pending/4`), subscribes the socket to the
run's topic and hands the build to the runner, so the state the editor sees is read back from the
database rather than held in the socket. While the run is live the primary control is disabled and
reads `Exporting…`, with `Cancel export` beside it; a cancel moves the band to `Cancelling export`
with "The export stops at the next safe point. No file will be saved." and then `Export cancelled`.

`handle_params/3` runs `ExportRuns.reconcile_expired/1` and `cleanup_expired/1` on every mount, so a
reload or a reconnect reconciles a build whose lease lapsed and deletes a ready run whose download
window has passed.

### 4.5 Monitor — the feed check

*Why this stage exists:* the file's usefulness to a trip planner depends on what the standard
checker finds, and the checker is a separate long-running act from the export.

| Surface | Action and decision | Establishes | Requires | Exit |
|---|---|---|---|---|
| gtfs-planner: `/gtfs/:version/export` (SCRN-035) | Press `Check feed` in `#export-check` and read the phase and the verdict | `validationSummary` (proposed) | `activeVersion` — the card says the check reads this version's data | The same route showing the three counts, or `/gtfs/:version/validation/:validation_id` (SCRN-036) |

The card (`Check for problems`) states what it runs — "Runs the MobilityData GTFS Validator, the
standard open-source checker for transit feeds, on this version's data." — and, once a result exists,
what it did not do: "Checks read this version's current data, not a downloaded file." That sentence
is the seam (`SEAM-005`): the check exports its own temporary copy of the version and hands those
bytes to `java -jar`; the bytes the editor downloads are never the bytes that were checked.

While it runs, `#check-phase` names the phase — `Getting ready…`, `Packaging your data…`,
`Running the checker…`, `Reading the results…` — over `#check-progress`. A second start while one is
running is refused with the flash "A check is already running." A finished check shows
`#mobility-summary-metrics` (Errors, Warnings, Information) and one `#check-verdict`: "Fix the
errors before you share this feed." when there are errors, "No errors." with the warning count when
there are only warnings, or "No errors or warnings." Then `View full results` and `Check again`.

`#recent-checks` lists the version's last five runs of any kind, newest first — `Feed check`,
`Flex file check`, `Pathways test`, `Station reachability` — each linking to that run's results page.
Its ledger line reads "`n` of the last `m` checks reported errors, and `k` reported warnings."; with a
single row it reads "The most recent check of this version."

### 4.6 Conclude — download the archive

*Why this stage exists:* the terminal outcome is a file on the editor's own disk, handed over by a
plain HTTP response that leaves the application for good (`SEAM-010`).

| Surface | Action and decision | Establishes | Requires | Exit |
|---|---|---|---|---|
| gtfs-planner: `/gtfs/:version/export` (SCRN-035) | Read the band — `Ready to download`, `<type> · <version>`, `Created … · Available until …` — and press `Download file` | the downloaded archive | `exportRunId`, `activeVersion` | The consumer's filesystem; nothing in the application observes this again |

The band's download control is a link, not a LiveView event: `#export-download-link` points at
`/gtfs/:version/export-runs/:run_id/download`. `GtfsExportDownloadController.show/2` casts both
UUIDs, re-checks that the version is published for the editor's organization, and claims the
download through `ExportRuns.claim_download/4`, which only answers for a row in state `ready`. A run
in any other state, a version from another organization, and a missing flex file are all
`404 Not Found`. `ExportArtifactResponse.send_claimed/5` then sends `application/zip` with
`cache-control: private, no-store`, `content-disposition: attachment; filename="…"` and the exact
recorded byte length, and releases the claim. The file name is recorded at build time as
`gtfs-<run id>.zip`, and `safe_filename/1` falls back to `export.zip` for any name outside
`[A-Za-z0-9._-]`.

Two other buttons sit beside it and neither is the terminal outcome. `Download flex file` appears
only when the run recorded a flex artifact (`?file=flex` on the same route). `Export again` starts a
new run against the version as it is now.

The card below the workspace (`After you download`) says what to do with the bytes: trip planners
fetch a feed from a permanent web address rather than from a file, so the full feed's three steps
are download, host the file somewhere permanent, and give that address to Google Maps' Transit
Partner Dashboard and to Transit's data team. For the operations file it says "Keep it private." and
points at Manage garages and Manage fleet.

<a id="5-entry-and-exit-points"></a>
## 5. Entry and exit points

**Entries.** One row per way the journey starts.

| Entry | Source | Notes |
|---|---|---|
| The header's `GTFS` destination | `lib/gtfs_planner_web/components/navigation.ex` `main_tasks/5` | It opens `/gtfs/:version/export` directly, so the destination is the journey's first screen |
| The GTFS sub-nav's `Export` tab | `lib/gtfs_planner_web/components/core_components.ex` `#gtfs-tab-export` | Reached from the Import tab and from the Export page itself |
| The import result card's `Check the new version for problems` | `lib/gtfs_planner_web/live/gtfs/import_live.ex` (`#gtfs-import-check-version`) | JRNY-001's terminal link; the version in the path is the newly published one |
| The dashboard's attention items | `GtfsPlannerWeb.Home.ChangeLinks` validation items | The registry maps `/gtfs/:version/validation/:validation_id` to this journey's area |
| A direct URL, `/gtfs/:version/export` | `lib/gtfs_planner_web/router.ex` line 205 | Guarded by `:require_gtfs_access`; a member without the role is redirected |
| A return visit after a reload or a reconnect | `handle_params/3` reconciles and cleans up, then re-reads the latest run | The editor did not choose this; they returned to a state that was already running |

**Exits and abandonment.** Most abandonment lives in prepare and execute, so both get rows.

| Exit | Where it happens | State left behind |
|---|---|---|
| The export type's file inventory is empty | 4.2, before any run | `#export-empty-inventory` reads "This export type has no GTFS tables to package yet."; no run exists |
| The server cannot write export files | 4.4, at start or at publish | `The export couldn’t start: this server can’t write export files. Ask an administrator to check the export storage location.`, or a finished run in state `failed` with `failure_code` `artifact_storage_unavailable` and a `Retry export` button |
| Garage IDs clash with stop IDs | 4.4, in preflight | The run fails with `Garage IDs clash with stop IDs`; the primary action becomes `Edit garages`, and no file is written |
| The build stopped for another reason | 4.4/4.5 | `Export failed` with "no file was saved", or `Export interrupted` with the same, each offering `Retry export` |
| The editor cancelled | 4.4 | `Export cancelled`; `Export again` restarts against the version as it is now |
| The editor left before the download window closed | After 4.6 | On the next mount the run reads `Download expired` — "The file was deleted when its download time ran out." — and `Export again` is the only action |
| The check could not finish | 4.5 | `The check couldn't finish.` with "Nothing in your data changed. Try again."; `Try again` re-runs it |
| The check belongs to another organization | 4.5 | `This check can't be shown.` with "It belongs to another organization."; no counts are shown |

<a id="6-seams"></a>
## 6. Seams

**SEAM-001** (identity, `/users/log_in` → any authenticated route) — the editor's session, plus the
organization and version the router resolves from the path. Consequence for this journey: the
header's `GTFS` destination and the import card's link both carry the version, so the export page
reconstructs the working context rather than inheriting it — but a version switched from the page's
own version menu navigates rather than patches, so an export already in flight keeps running against
the version it was started for while the editor reads a new one. Related finding: registry OQ-004.

**SEAM-005** (third-party, the Export tab → `java -jar` on the tracked MobilityData validator) — the
written feed's bytes go out; only notices and error counts come back. Consequence for this actor at
this moment of commitment: the check exports its own temporary copy of the version
(`GtfsPlanner.Gtfs.Validator.validate/3`), so the editor cannot treat a clean check as a statement
about the ZIP they hold. The page says as much — "Checks read this version's current data, not a
downloaded file." — and everything the validator does internally, including a crashed process, is
visible only as an error record or a `validation_error` panel.

**SEAM-010** (handoff, `/gtfs/:version/export-runs/:run_id/download` → the consumer's filesystem) —
the finished archive and its file name cross here and nothing returns. Consequence for this actor:
after the download the product has no record that the file was taken, and no later stage of the
journey reports back; the editor's only evidence that the file arrived is their own filesystem. The
controller's scoping is what protects the actor here — a claimed, `ready`, organization-scoped run
and a published version in the same organization, or `404`.

No provisional seam is added. Every crossing this page traces is already a registry row.

<a id="7-features-and-rules-per-stage"></a>
## 7. Features and rules per stage

None. `docs/feature-list.md` names the capabilities this journey uses — "Export a version's feed",
"Download the latest export file", "Choose export defaults" and "Check the feed with the standard
feed validator" — but issues no `FEAT-##` identifiers, and no rule registry with `BR-##` identifiers
exists in this repository. Naming a capability by its registry row would require inventing an ID, so
this section stays empty until a registry issues one.

<a id="8-end-to-end-examples"></a>
## 8. End-to-end examples

Row counts below are read from `test/fixtures/gtfs/ux_qa/sample-feed.zip`, the `sample-feed` seed's own
fixture: 1 agency, 5 routes, 9 stops, 11 trips, 28 stop times, 2 calendars and 1 calendar date. It is
imported into the QA organization's published "First Version", so this journey starts from data the
editor already sees on screen.

#### EX-0301 A checked feed is exported and downloaded
**Given** the QA seed's `sample-feed` organization "Demo Transit Authority" with the fixture imported
into its published version "First Version"
**And** the editor `qa-editor@gtfs-planner.test` is signed in on the dashboard
**When** the editor presses `GTFS`, presses `Export feed`, waits for `Ready to download`, presses
`Check feed`, waits for the check's verdict, and presses `Download file`
**Then** one zip lands on the editor's disk with a `content-disposition` attachment name ending in
`.zip`
**And** the run's file inventory matches the four counts the `What goes in this file` tiles showed
before the export started
**And** a completed validation run row exists for the working version
**And** the version in view is unchanged: no route, stop, trip, stop time or calendar is added or
edited by any of it
Test: `assets/e2e/import_export.spec.js` — `real diff compute reconnects, applies, exports,
reconnects, and downloads` proves the export, the reload mid-run and the attachment download, and
`check feed launches a persisted run and exposes its result and history` proves the check, its
counts, its verdict and its appearance in `Recent checks`. Neither runs against `sample-feed.zip` or
asserts the row counts, so the scenario's `export-feed` check is the gate that does.

#### EX-0302 The same export started twice (boundary)
**Given** the same organization, with one full-feed run already `Ready to download`
**When** the editor presses `Export again` and then presses `Export feed` repeatedly while the new
run is building
**Then** exactly one new run is created and the button stays disabled reading `Exporting…`
**And** the ready run from EX-0301 is still downloadable until its own `Available until` time
**And** no second artifact is written against the same run row
Test: `docs/manual-test-plan.md` EX-03 ("Double-click protection") states this expectation, but the
committed lane does not drive a repeated press; `import_export.spec.js` only reads the download
href before and after one start. The `export-feed` check observes the newest download rather than
the run count, so a duplicate run that still produces one valid file would not fail it.

#### EX-0303 The download window closes before the editor returns (failure and recovery)
**Given** a full-feed run that finished more than `gtfs_task_artifacts_ttl_seconds` ago — 24 hours
by default in both `config/runtime.exs` and `config/test.exs`
**When** the editor opens `/gtfs/:version/export` again
**Then** the band reads `Download expired` with "The file was deleted when its download time ran out.
Export again to get a new copy."
**And** `handle_params/3` has already run `ExportRuns.cleanup_expired/1`, so the artifact is deleted
from storage rather than left to fail at download time
**And** the only action offered is `Export again`, and the version itself is untouched
Test: none — no committed lane waits out an artifact TTL or asserts the expired state; the expired
branch is read from `export_components.ex` `status(%Run{state: :expired}, …)` and `export_runs.ex`
`cleanup_expired/1`.

<a id="9-visual-and-evidence-links"></a>
## 9. Visual and evidence links

| Stage | Kind | Reference | Notes |
|---|---|---|---|
| 4.1 Locate | product documentation | `docs/screen-inventory.md`, `docs/inventories/gtfs-operation-screens.md` | `SCRN-035` is the registered screen for `/gtfs/:version/export` and `SCRN-036` for one validation run; both read `undocumented` at the commit this page was written against |
| 4.2 Prepare, 4.6 Conclude | e2e lane | `assets/e2e/import_export.spec.js` | `import and export stay usable across responsive and zoomed layouts` measures the export form, the inventory disclosure, the type radios, the export button and the download link's target size at six viewports; screenshots go to `test-results/`, disposable |
| 4.2 Prepare, 4.6 Conclude | e2e lane | `assets/e2e/garages_fleet.spec.js` | Records garages and fleet and reads the operations archive; the operations export is this journey's variant (registry S-703) |
| 4.3 Confirm, 4.4 Execute, 4.6 Conclude | e2e lane | `assets/e2e/import_export.spec.js` | Proves the export start, the download href changing, survival of a reload mid-run, and the download response's status, `content-disposition` and `.zip` file name |
| 4.5 Monitor | e2e lane | `assets/e2e/import_export.spec.js` | `check feed launches a persisted run and exposes its result and history` proves the counts, the verdict, `Recent checks` and the run's results page |
| 4.4 Execute | product documentation | `docs/manual-test-plan.md` EX-01, EX-03 | The manual plan's full-export and double-click cases, merged into this journey as seeds S-307 and S-308's neighbours in the registry merge ledger |
| 4.5 Monitor | product documentation | `docs/manual-test-plan.md` MV-01 to MV-04, `docs/mobility-data-validator.md` | The manual plan's validation cases and the validator's own documentation |
| 4.6 Conclude | journey capture | Not captured — no run of `JRNY-003/export` exists yet, and the captures this page will cite are produced by the pilot steps. | Would be cited as `JRNY-003/export-s003` |

No capture ID is cited in this page because none exists. A capture that is later produced is cited by
its backticked ID, never by an image path.

<a id="10-test-scenario"></a>
## 10. Test scenario

### export

- **Persona:** Scheduler at a small transit agency with an organization editor account.
- **Goal:** Download your current feed as a GTFS zip that has been checked: start an export, check the feed and download the zip.
- **Account:** editor
- **Seed:** sample-feed
- **Start path:** /
- **Success check:** export-feed — a downloaded zip whose row counts equal the source feed, whose validator errors are a subset of the source's, and a completed feed check
- **Reference actions:** 4
- **Entry route:** /gtfs/:version/export

The four reference actions are the ones after sign-in, waits excluded: press `GTFS` in the header
navigation, which opens the export page directly and needs no second hop through the sub-nav; press
`Export feed`; press `Check feed`; press `Download file`. The export type is already `Full feed` on
arrival, so choosing a type is not an action for this goal. Reading the counts, the run band and the
verdict are observations, not actions.

This count is an estimate until the reference trail for `JRNY-003/export` runs, and the executed
trail's count replaces it (OQ-006).

## Open questions

- OQ-001 — The `export-feed` check this scenario names does not exist yet; `assets/qa/checks/` is
  empty in this checkout. It lands in a later step of this change, and until then the scenario cannot
  be executed. Owner: spec step 57.
- OQ-002 — `context_keys` and every `Establishes` / `Requires` value on this page are proposed. This
  repository has no E2E ledger or journey catalog to take key names from, and no documented
  `establishes` / `requires` contract exists to propose against. Owner: product owner.
- OQ-003 — Both job stories are `inferred`. No persona document, funnel doc or lane `intent` field
  names this actor's motivation; the stories are read from the shipped card copy and the feature
  registry rows. Owner: product owner.
- OQ-004 — `roles: []` is empty because no `ROLE-##` identity exists; the actor column comes from the
  registry's reading of `GtfsPlanner.Authorization.Roles` and the mount hooks. Registry OQ-004 asks
  for the same derivation through a permission model. Owner: product owner.
- OQ-005 — The goal says "download the zip", but the file the editor receives is named
  `gtfs-<run id>.zip`, where the run id is a generated UUID rather than the version name. A tester
  told to look for a version-named file will not find one. Owner: product owner.
- OQ-006 — `Reference actions: 4` is the estimate counted from the traced flow, not an executed
  count. The reference trail's count replaces it. Owner: the reference-trail step.
- OQ-007 — No capture of this journey exists, so section 9 cites none. Which states the pilot
  captures must cover — the export form with its inventory, the ready band, the check's verdict — is
  a decision for the pilot steps. Owner: product owner.
- OQ-008 — The check reads the version's current data, not the downloaded archive, so the page's
  "clean check" and the file in the editor's hands can disagree if the version changes between the
  two. The page states the boundary in the card's own sentence; whether the product should warn on
  that ordering is a product decision, not a documentation one. Owner: product owner.

## Changelog

| Date | Version | Change | Author |
|---|---|---|---|
| 2026-10-01 | 1 | Initial page: stages, seams, examples and the `export` scenario for JRNY-003 | spec step 39 |