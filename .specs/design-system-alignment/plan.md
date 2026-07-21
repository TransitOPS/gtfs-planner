# Design System Alignment Implementation Plan

## Purpose

This file is the execution tracker for the findings summarized in [index.md](index.md). The finding reports remain the source of truth for evidence, acceptance criteria, and required corrections.

Implementation is **dependency-ordered**. Packages that consume the same shared contract must coordinate ownership, but independent page-level packages may proceed in parallel according to the execution lanes below. Package 19 remains the governance/convergence gate and Package 20 remains the final closeout gate.

## Status

- Branch: `main`; implementation through PR [#672](https://github.com/TransitOPS/gtfs-planner/pull/672) is merged; Package 18 is complete on branch `018-dsa`
- Audit: complete
- Implementation: Packages 0–5, 7, 9, 10, 12, 14, and 18 are complete; Package 8's prototype retirement is complete. Packages 11, 13, 15, 16, 17, 19, and 20 remain. Package 6's implementation is merged, but its historical keyboard-at-200%-zoom evidence item remains open; Package 8's P0 gate remains tied to that evidence.
- Accessibility scope: decision 0.12 in [decisions.md](decisions.md) removes nonvisual/screen-reader work (VoiceOver gates, announcement contracts, nonvisual canvas summaries, screen-reader smoke tests) across all packages; keyboard operability remains required within reason
- Findings: 198 total — 2 P0 remaining (SHR-001/SHR-007 implementation resolved, keyboard-only browser check pending; AUTH-001 implementation resolved, keyboard-only `/first` browser check recorded as a separate zero-user release observation; EXC-001 closed by Package 8 retirement), 83 P1, 93 P2 (includes AUTH-013/AUTH-014 discovered during Package 10 browser evidence), 13 P3
- Current quality gate: `mix precommit` passed for merged Package 14 on 2026-07-20 — 2,746 Elixir tests (0 failures, 5 skipped), 220 JavaScript tests, and four station-diagram Playwright suites. This full gate includes the merged Package 12 changes. Package 18 has focused ErrorHTML, retirement-route, design-system, and real-browser evidence on branch `018-dsa`.

### Tracking convention

- `[ ]` Not started
- `[-]` In progress
- `[x]` Complete and verified
- `[!]` Blocked; record the reason directly beneath the item
- `[~]` Deliberately deferred; record the decision, owner, and revisit condition

For every completed package, add a short completion note containing:

- implementation commit or PR;
- finding IDs closed;
- tests and browser checks run;
- remaining limitations or deferred findings; and
- design-system documentation updated.

## Execution rules

1. Follow the dependency lanes below. Numeric order is a tracking convention, not a concurrency prohibition.
2. Do not start page-level visual alignment until the P0 correctness and accessibility gates are closed.
3. Correct shared components before migrating page-owned copies of the same pattern.
4. Update the design-system Components/Foundation documentation and regression tests in the same package as a shared-contract change.
5. Treat every `proposal-opportunity` as advisory. It requires an explicit accept/defer/reject decision before implementation.
6. Preserve organization, GTFS-version, audit-history, import-recovery, and authorization invariants while changing presentation code.
7. A package is not complete until its focused tests and applicable browser checks pass.
8. Do not mark a finding resolved solely because its appearance changed; verify its behavior, semantics, states, and responsive contract.

## Remaining execution lanes

First reconcile the two outstanding historical P0 evidence records so the P0 gate is truthful: Package 6's keyboard-at-200%-zoom overlay observation and the separate zero-user `/first` release observation attached to `AUTH-001`. Package 10's implementation remains complete. These evidence checks are independent of the page-alignment work below.

The recommended next implementation wave is:

- **Lane A — Package 11:** dashboard, settings, and retirement of the legacy API-key subsystem. This work is independent of the GTFS page packages.
- **Lane B — Package 13:** route/station catalogs and details. It consumes the Package 9 responsive data-view and route-identity contracts and can proceed independently of Lane A.
- **Lane C — Packages 15 and 16:** Package 14 now unblocks report/history work, and Packages 1–3 plus 14 provide the correctness and upload foundations for import/export. These packages may proceed concurrently on page-owned work, but one lane must own each shared version-diff and count-strip API; the other lane must consume that API after it lands rather than create a competing primitive.

Package 17 follows the clock-format decision required by decision 0.9 and should consume the tri-state/pathway work established by Packages 13/15 plus the count-strip work established by Packages 15/16. Package 19 begins only after Packages 11, 13, 15, 16, and 17 have recorded their graduation evidence. Package 20 remains strictly last.

## Work packages

### 0. Record product and proposal decisions

Resolve ambiguity before implementation so later packages do not invent product behavior.

- [x] **0.1 Route schedules:** deferred as unfinished product work; preserve and revisit when schedule development resumes (`CAT-001`).
- [x] **0.2 API keys:** remove the unused legacy API-key subsystem while preserving companion API user-session authentication (`ACCT-006`).
- [x] **0.3 Confirmation resend:** remove the unreachable tokenless resend branch; retain token confirmation (`AUTH-004`).
- [x] **0.4 Admin user detail:** remove the unused route and `:show` action (`ADM-001`).
- [x] **0.5 Station-resolution prototype:** remove its served route/controller/tests and retain the HTML/CSS files as advisory research (`EXC-003`).
- [x] **0.6 Report pathway form:** remove the unreachable report-owned branch; keep pathway editing in the station diagram (`REP-014`).
- [x] **0.7 User deactivation:** require user-specific explicit confirmation disclosing organization-access and global session revocation; do not offer a misleading Undo.
- [x] **0.8 Import recovery:** use a non-current staging version and atomic publication; failed imports leave the prior version untouched and expose cleanup/retry.
- [x] **0.9 Timezone:** use current-version agency timezone with explicit UTC fallback and zone disclosure where ambiguous; defer 12-hour versus 24-hour display format (`VAL-009`, `REP-023`).
- [x] **0.10 Proposal ledger:** all 21 proposal opportunities are accepted, deferred, or rejected in [decisions.md](decisions.md), with annotations in each owning report.
- [x] **0.11 Gate:** every accepted proposal has a package insertion point; the deferred clock format is an explicit gate only for packages 15 and 17.

Completion note: decisions and source evidence are recorded in [decisions.md](decisions.md). No production code or tests changed. Accepted proposals are mapped to packages 9 and 13–19; deferred proposals retain explicit revisit conditions. Packages 1, 2, and 3 were subsequently implemented in merged PRs [#659](https://github.com/TransitOPS/gtfs-planner/pull/659), [#660](https://github.com/TransitOPS/gtfs-planner/pull/660), and [#661](https://github.com/TransitOPS/gtfs-planner/pull/661), and are closed in [import-and-export.md](import-and-export.md).

### 1. Prevent import mis-targeting

- [x] Correct `IMP-001` so a failed create-version operation cannot silently import into the current version.
- [x] Add focused tests covering success, create failure, stale version context, and retry.
- [x] Verify that the interface names the actual target version before upload and apply.
- [x] Record completion evidence for merged PR [#659](https://github.com/TransitOPS/gtfs-planner/pull/659) in [import-and-export.md](import-and-export.md).

Completion note: merged PR [#659](https://github.com/TransitOPS/gtfs-planner/pull/659), commit `4393ca2`, binds full-feed imports to an unavailable staging version, removes fallback writes to the route version, adds atomic publication and published-only access, versions diagram assets, and renders the named destination and recovery states. Verification: 2,209 tests passed with 5 skipped; the focused lifecycle/storage/export/API set passed 93 tests; the concurrent publish/fail boundary passed 20 repeated runs. PR [#661](https://github.com/TransitOPS/gtfs-planner/pull/661) subsequently completed the durable cleanup and fresh-retry contract. `IMP-001` is resolved with evidence in [import-and-export.md](import-and-export.md). No design-system documentation changed because this package establishes the correctness boundary that later presentation alignment builds upon.

### 2. Prevent destructive incomplete-import decisions

- [x] Correct `IMP-002` so incomplete parsing cannot produce destructive removals.
- [x] Define and test the parse-completeness invariant before diff decisions are available.
- [x] Verify incomplete, malformed, interrupted, and valid imports.
- [x] Record completion evidence for merged PR [#660](https://github.com/TransitOPS/gtfs-planner/pull/660) in [import-and-export.md](import-and-export.md).

Completion note: merged PR [#660](https://github.com/TransitOPS/gtfs-planner/pull/660), commit `bf59dc0`, introduces strict row-event CSV parsing and explicit complete/failed reviewed entities, blocks absence-based removals for incomplete entities and their dependency closure, separates applicable decisions from read-only previews, and turns duplicate, unreadable, oversized, and nested-archive failures into recoverable blockers. Corrected-file recomputation restores legitimate removals only after a complete parse. Verification on 2026-07-17: the eight changed import and LiveView test files passed 179 tests with 0 failures and 1 skipped, covering valid input, malformed rows, parser interruption, archive failures, diagnostic bounds, crafted approval/apply events, dependency tainting, and corrected retry. `IMP-002` is resolved with evidence in [import-and-export.md](import-and-export.md). No design-system documentation changed because this package establishes a correctness boundary rather than a shared presentation contract.

### 3. Make partial import outcomes truthful and recoverable

- [x] Correct `IMP-019` so partially committed imports are not presented as total failure.
- [x] Implement the recovery decision selected in package 0.8.
- [x] Test retry, duplicate prevention, partial success, rollback/resume, and reconnect behavior as applicable.
- [x] Record completion evidence in [import-and-export.md](import-and-export.md).

Completion note: merged PR [#661](https://github.com/TransitOPS/gtfs-planner/pull/661), commit `c4fbfbf`, introduces durable `gtfs_import_runs` persistence with a coupled state machine, supervised Runner ownership with database-lease heartbeat, convergent cleanup via Recovery, and reconnect-safe import recovery UI with inline discard confirmation. The final `mix precommit` run completed 2,389 tests with 5 skipped and reached the existing Credo baseline with no new issues; the final focused suites passed 115 tests with 1 skipped. Recovery coverage includes disconnect and executor loss, lease reconciliation, discard and same-name re-upload, terminal PubSub consistency, duplicate prevention, and concurrent publish/cleanup races. `IMP-019` is resolved with evidence in [import-and-export.md](import-and-export.md); rollback-and-fresh-retry was selected instead of unsafe in-place resume. No design-system documentation changed because this package establishes a correctness boundary rather than a shared presentation contract.

### 4. Restore account-settings rendering and form contracts

- [x] Correct `ACCT-001` so initial settings render does not read a missing assign.
- [x] Correct `ACCT-002` so both forms use compatible parameter contracts and unique control IDs.
- [x] Add LiveView tests for initial render, validation, submission, error mapping, and both forms on one page.
- [x] Verify keyboard labels, error associations, pending states, and focus after submission.
- [x] Record completion evidence in [dashboard-settings-api-keys.md](dashboard-settings-api-keys.md).

Completion note: merged PR [#662](https://github.com/TransitOPS/gtfs-planner/pull/662), commit `064ab50`, rebuilds the authenticated account-settings LiveView as two isolated email and password forms with stable DOM contracts, truthful pending/error states, secret clearing, disabled reconnect recovery, and first-error focus recovery. Email changes complete through an authenticated one-time confirmation route; password mutation moves to an authenticated HTTP boundary that atomically updates the password, revokes prior credentials, disconnects expired LiveView sessions, clears remember-me state, and issues a fresh current-browser session. 2,454 tests pass with 0 failures and 5 skipped; coverage includes deterministic mail-failure, controller, form-contract, token-lifecycle, cross-session revocation, and structured parameter-filter tests. `ACCT-001` and `ACCT-002` are resolved. Remaining ACCT-003–ACCT-018 findings are deferred to Package 11, which will apply the repaired shared form, feedback, shell, and CTA contracts once those contracts are completed in Package 9.

### 5. Restore first-install error mapping

- [x] Correct `AUTH-001` so organization errors map to the rendered setup fields.
- [x] Test invalid organization data, invalid administrator data, combined errors, success, and retry.
- [-] Verify error summary/field associations and focus placement.
- [-] Record completion evidence in [authentication-and-setup.md](authentication-and-setup.md).

Note (2026-07-18): implementation and automated verification merged via PR [#664](https://github.com/TransitOPS/gtfs-planner/pull/664), commit `4f26b68`. The focused five-file Package 5 suite passed 264 tests with 0 failures (including 12 first-admin LiveView tests covering the existing-user redirect, valid first-submit destination, same-view invalid-then-corrected retry with exactly-once record deltas, and a real duplicate-alias transaction rollback retried to success), and `mix precommit` passed 2,493 tests with 0 failures and 5 skipped. Summary/field associations and the single submit-time focus event are pinned by automated tests; actual focus placement is not. Decision 0.12 removes the Safari + VoiceOver speech gate. Package 5 and `AUTH-001` remain in progress until a keyboard-only browser check on one combined-error submit is appended in [authentication-and-setup.md](authentication-and-setup.md): focus lands on `#first-admin-email`, summary links reach their controls, and keyboard-only correction works at 320 px and 200% zoom. `AUTH-002`, `AUTH-005`, and `AUTH-006` remain open; this package does not complete Package 10.

### 6. Make closed overlays inert and correctly focused

- [x] Correct `SHR-001` so closed drawers are not modal, exposed, or tabbable.
- [x] Complete the related drawer/dialog focus and destructive-pending contract (`SHR-007` and applicable overlay findings).
- [x] Add component semantic tests plus real-browser tests for open, close, Escape, focus trap, focus return, outside interaction, and pending actions.
- [x] Update the normative Overlays documentation in the same change.
- [x] Record completion evidence in [shared-shell-and-components.md](shared-shell-and-components.md).

  Completion note: merged to `main` via PR [#665](https://github.com/TransitOPS/gtfs-planner/pull/665) (branch `006-dsa-accessible-overlays`, 10 commits):
  - `e267b86` — Establish reproducible JavaScript unit tooling: Vitest, jsdom.
  - `0dca5e7` — OverlayDialog hook: native `<dialog>` element reconciliation.
  - `73968c9` — Migrate shared overlays to native `<dialog>` with `/design/overlays` normative demo.
  - `d92c8ef` — Authenticated Playwright/Chromium browser harness with browser seed user.
  - `7479719` — Native dialog CSS presentation and 22-case e2e suite.
  - `78e2c19` — Separate browser and unit JS CI gates.
  - `1c7926e` — Pin drawer consumer compatibility across 4 families (organizations, users, diagram, report).
  - `f0e34d6` — Resolve the first branch-review findings.
  - `93a08f3` — Make the browser readiness gate reproducible.
  - `127eb29` — Restore visible native drawer slide motion.
  
  Automated tests: 634 Elixir + JS pass (0 failures). The reproducible 24-case browser e2e suite is green; its Tab assertion permits Chromium's transient native `BODY` boundary in both directions without a prohibited custom focus trap. The Safari + VoiceOver manual gate (formerly 9 evidence fields) is removed by decision 0.12; closure still requires the keyboard/reduced-motion evidence, including a recorded keyboard-only 200% zoom observation. See [shared-shell-and-components.md](shared-shell-and-components.md) for the detailed evidence table.

### 7. Provide keyboard-equivalent spatial editing (scoped by decision 0.12)

- [x] Correct the `DIA-001` focus defect: focusable SVG items either activate with Enter/Space and show an always-visible focus indicator, or leave the tab order; no CSS rule removes a focus outline without replacement.
- [x] Confirm each essential spatial task (create/reposition stop, connect pathway endpoints, calibrate scale) is keyboard-completable through the non-canvas paths (coordinate fields, reposition search/table, endpoint selection, distance entry) and labeled pan/zoom buttons; close the gaps, not the full canvas keyboard model.
- [x] Test Enter/Space activation, Escape cancellation, focus visibility, save, and the non-canvas editing paths without a pointer.
- [x] Record completion evidence in [station-diagram-and-editing.md](station-diagram-and-editing.md).

Removed by decision 0.12: the complete canvas keyboard model (discovery/roving focus, keyboard placement/movement/pan/zoom emulation), coordinate/mode announcements, and the nonvisual status/instruction model (`DIA-022`). Canvas pointer interaction remains the primary spatial input.

### 8. Resolve click-only prototype navigation

- [x] Close `EXC-001` by retiring the prototype route and controller (Package 8).
- [x] Replace serving tests with a bounded route-retirement contract.
- [x] Preserve `priv/prototypes/` research files with advisory README and relative stylesheet reference.
- [x] Record completion evidence in [prototype-and-exceptional-surfaces.md](prototype-and-exceptional-surfaces.md).
- [ ] **P0 gate:** confirm all 9 P0 findings are closed or deliberately removed with evidence before continuing.

Completion note: merged to `main` via PR [#667](https://github.com/TransitOPS/gtfs-planner/pull/667), commit `9783ead`. The prototype route, controller, and serving tests
are removed; both former paths return 404 through the production endpoint/router for authenticated and
unauthenticated requests; the raw `/prototypes/` path is not statically published. Research files
remain under `priv/prototypes/` with an advisory README. `EXC-001`, `EXC-002`, `EXC-003`, `EXC-004`,
`EXC-006`, `EXC-007`, `EXC-008`, `EXC-009`, `EXC-011`, and the prototype-serving portion of
`EXC-012` are closed by retirement. `EXC-005` and the `ErrorHTML` test-coverage portion of `EXC-012`
remain open for Package 18. `EXC-010` is accepted/transferred to Packages 15/16/19. The P0 gate
remains open: `AUTH-001` and `SHR-001` each have implementation resolved but pending keyboard-only
browser checks; Package 7's recorded CI/browser checkpoint is the remaining evidence input. Package 9
is unauthorized until all nine P0 rows have evidence-backed closed or deliberately removed
dispositions.

### 9. Repair shared design-system contracts

Complete every remaining finding in [shared-shell-and-components.md](shared-shell-and-components.md), in the following internal order:

- [x] **9.1 Forms and errors:** `SHR-005`, `SHR-012`, `SHR-013`.
- [x] **9.2 Shell and navigation:** responsive app/auth shell, top navigation, sub-navigation, target sizing, route identity, and version switching.
- [x] **9.3 Data display:** responsive semantic tables/data views and pagination (`SHR-006`, `SHR-014`, and accepted proposal `GOV-009`).
- [x] **9.4 Tokens and hierarchy:** semantic color, typography, title scale, and status vocabulary.
- [x] **9.5 Feedback and motion:** flashes, callouts, empty states, loading/degraded states, and reduced motion (`SHR-015`, `SHR-017`; `SHR-016` closed by removal under decision 0.12).
- [x] **9.6 Remaining shared findings:** reconcile every `SHR-002`–`SHR-022` row not closed above; no finding may be orphaned by the grouping.
- [x] **9.7 Contract gate:** update real component APIs, Components/Foundation pages, semantic tests, and representative browser tests together.
- [x] **9.8 Verification:** run the focused component/design-system suites and the responsive/accessibility browser matrix.

Completion note: merged to `main` via PR [#668](https://github.com/TransitOPS/gtfs-planner/pull/668), commit `6e673fd` (2026-07-19). All SHR-002 through SHR-022 findings closed (SHR-016 remains closed by removal under decision 0.12). Focused test suites: 321 ExUnit tests across 10 files (form_components_test, data_view_components_test, navigation_components_test, feedback_components_test, route_identity_test, gtfs_version_switcher_test, header_test, design_system_live_test, organizations_live_test, routes_live_test), 19 Vitest tests (gtfs_version_hook_test.js), 41 Playwright tests (17 shared_design_contracts.spec.js + 24 overlay regression). GOV-009 trialed with Organizations and Routes as production consumers; GOV-010 and GOV-011 marked experimental. Package 6 findings SHR-001 and SHR-007 retain their Package 6 dispositions. Package 10 is eligible pending `mix precommit` gate.

### 10. Align authentication and setup

- [x] Implement all unresolved `AUTH-001`–`AUTH-012` findings in [authentication-and-setup.md](authentication-and-setup.md), honoring the decisions from package 0.
- [x] Migrate the pages to the repaired shared form, feedback, shell, and CTA contracts.
- [x] Verify first administrator, login, reset, confirmation, invitation acceptance, logout, invalid/expired tokens, loading, and recovery states.
- [x] Run focused LiveView/controller tests and browser checks.

Completion note: implemented on branch `010-dsa-align-authentication-setup` (steps 1–9 commits `7f69395`,
`79fd162`, `3fec497`, `f7d08bf`, `50050ed`, `4f77390`, `8fa74fd`, `c244a5e`, `e980d5d`; step 10 adds the
browser evidence and tracker reconciliation). `AUTH-001`–`AUTH-012` all have evidence-backed dispositions
in [authentication-and-setup.md](authentication-and-setup.md#package-10-implementation-evidence); AUTH-001
implementation is resolved with its keyboard-only `/first` check recorded as a separate zero-user release
observation (the seeded suite creates users and cannot render `/first`). Step-10 evidence:
`test/support/browser_seed.exs` adds isolated deterministic auth fixtures (fixed test-only raw values
stored as SHA-256 digests, one user/token per destructive case, expired rows backdated), and the new serial
`assets/e2e/authentication.spec.js` (30 cases) proves login recovery, reset request, isolated
valid/invalid/expired/replay reset/confirm/invite paths, keyboard focus/Tab order, reduced motion, target
size, and 320/768/desktop/200% reflow. Focused gates green before browser evidence: 151 ExUnit
(`MIX_TEST_PARTITION=step10`), 17 Vitest (form_error_focus_hook_test.js), 30 Playwright. Two new P2
findings recorded from browser evidence — `AUTH-013` (failed-submit auto-focus race) and `AUTH-014`
(shared default button 40px vs the 44px target) — both open and owned by follow-ups. The repository-wide
`mix precommit` gate passed on 2026-07-20 (2,795 tests, 0 failures, 5 skipped; Credo diff from
`origin/main` added no issues after a step-10 nesting refactor of `UserForgotPasswordLive.handle_event/2`),
run against a freshly reset test database. Package 10 is complete and Package 11 is authorized.

### 11. Align dashboard, settings, and API keys

- [ ] Implement all unresolved `ACCT-001`–`ACCT-018` findings in [dashboard-settings-api-keys.md](dashboard-settings-api-keys.md).
- [ ] Apply the package 0 API-key decision; do not style a retired surface.
- [ ] Verify empty, error, loading, success, destructive, narrow-screen, and keyboard states.
- [ ] Run focused LiveView tests and browser checks.

### 12. Align administration

- [x] Implement all unresolved `ADM-001`–`ADM-015` findings in [administration.md](administration.md).
- [x] Apply the user-detail and deactivation decisions from package 0.
- [x] Verify responsive data views, role/status actions, destructive recovery, errors, empty states, and focus behavior.
- [x] Run focused administration tests and browser checks.

Completion note: merged via PR [#670](https://github.com/TransitOPS/gtfs-planner/pull/670), commit
`42b5638`. `ADM-001`–`ADM-013` and `ADM-015` are resolved; `ADM-014` remains deliberately deferred
under decision 0.14. Verification recorded in
[administration.md](administration.md#package-12-automated-evidence-recorded-2026-07-20): 2,825
Elixir tests (0 failures, 5 skipped), 316 focused administration/component/access-control tests,
and 46 supported-Chromium scenarios covering keyboard workflows, focus, pending/destructive states,
recovery, responsive geometry, and reduced motion. Package 14's later full `mix precommit` run includes
these merged changes and satisfies Package 12's deferred integrator gate. `ADM-016` remains a shared
input-component follow-up for a later shared-contract/convergence package. The status vocabulary and
responsive table-action examples were updated with their production consumers.

### 13. Align GTFS catalogs and details

- [ ] Implement all unresolved `CAT-001`–`CAT-024` findings in [gtfs-catalog-and-details.md](gtfs-catalog-and-details.md).
- [ ] Apply the schedules decision from package 0.
- [ ] Verify route/station catalogs, version context, route tabs, station details, filters, pagination, empty states, and narrow layouts.
- [ ] Run focused catalog/detail tests and browser checks.

### 14. Align station diagram and editing

- [x] Implement all unresolved `DIA-001`–`DIA-022` findings in [station-diagram-and-editing.md](station-diagram-and-editing.md).
- [x] Apply the accepted upload and selection-control proposals through graduated contracts; do not presume the deferred spatial-workspace abstraction.
- [x] Preserve diagram transformations, version scope, layer degradation, replacement safety, and save semantics.
- [x] Verify pointer operation plus the keyboard-complete non-canvas paths (decision 0.12), uploads, drawers, modes, map alignment, reconnect/degraded states, 768px-and-up layout, zoom, and reduced motion.
- [x] Run focused Elixir tests and the JavaScript suite through the repository's proper DOM/browser harness.

Completion note: merged via PR [#671](https://github.com/TransitOPS/gtfs-planner/pull/671), commit
`d957359`. Package 14 dispositioned the remaining `DIA-001`–`DIA-022` work under decision 0.12,
graduated the upload and selection contracts through production consumers, added a governed diagram
palette, staged and validated diagram replacement, made map transforms previewable and keyboard
operable, bounded the workspace at 768px and above, and moved destructive actions to server-owned
confirmation. Verification: 2,746 Elixir tests (0 failures, 5 skipped), 220 JavaScript tests, four
Playwright suites (keyboard, workspace, upload, and map), and a passing `mix precommit`. Components and
Foundation examples were updated; formal maturity labels remain owned by Package 19. Follow-up PR
[#672](https://github.com/TransitOPS/gtfs-planner/pull/672), commit `14aa88b`, refined the Floorplans
header/editing controls and passed 1,183 focused LiveView/component tests.

### 15. Align station reports and history

- [ ] Implement all unresolved `REP-001`–`REP-024` findings in [station-reports-and-history.md](station-reports-and-history.md).
- [ ] Apply the pathway-form and timezone decisions from package 0.
- [ ] Preserve audit history, rollback safety, print behavior, validation truthfulness, and station/version identity.
- [ ] Verify all report sections, edit drawer, history, rollback, loading/stale/error states, print, and narrow layouts.
- [ ] Run focused report/history tests and browser checks.

### 16. Align import and export

- [ ] Implement every import/export finding that remains unresolved after Packages 1–3 in [import-and-export.md](import-and-export.md); do not reopen the closed `IMP-001`, `IMP-002`, or `IMP-019` correctness boundaries without contradictory evidence.
- [ ] Build on the correctness/recovery contracts completed in packages 1–3.
- [ ] Apply accepted upload and durable-task proposals only through graduated contracts.
- [ ] Verify upload, parsing, diff review, decision application, export generation/download, validation launch, partial states, retry, reconnect, and version identity.
- [ ] Run focused import/export tests and browser checks.

### 17. Align validation and reachability

- [ ] Implement all unresolved `VAL-001`–`VAL-015` findings in [validation-and-reachability.md](validation-and-reachability.md).
- [ ] Apply the timezone policy and any graduated durable-task/selection contracts.
- [ ] Verify polling, history, stale/partial/degraded states, reachability workspace/results, severity/status semantics, reconnect, keyboard use, and responsive layouts.
- [ ] Run focused validation/reachability tests and browser checks.

### 18. Resolve exceptional surfaces

- [x] Implement, quarantine, or remove all unresolved `EXC-001`–`EXC-012` findings in [prototype-and-exceptional-surfaces.md](prototype-and-exceptional-surfaces.md).
- [x] Ensure retained prototype material is clearly advisory and cannot be confused with a production contract.
- [x] Align 404/500 rendering without exposing unavailable actions or losing recovery navigation.
- [x] Run focused route/render tests and browser checks.

Completion note: complete on branch `018-dsa` through commits `0e9b052`, `5932504`, `9096eb0`, and
`1dcd7a7`. Package 8's prototype retirements remain intact; Package 18 closes `EXC-005` and the remaining
ErrorHTML portion of `EXC-012`, while `EXC-010` remains transferred to Packages 15, 16, and 19. The 404
and 500 templates use the anonymous application shell and native shared-button recovery actions without
authenticated controls or diagnostic leakage. Focused ErrorHTML/retirement tests, 129 design-system
LiveView tests, and `assets/e2e/error_pages.spec.js` verify the real 404 endpoint at 320/640/768/1280px,
keyboard reach, visible focus, 44px target height, and native recovery navigation. The 500 contract is
verified by direct render because no production route is intentionally made to crash. The exceptional-
surfaces audit records the retained prototype as advisory research.

### 19. Establish design-system governance

- [ ] Implement all accepted `GOV-001`–`GOV-013` work in [design-system-governance.md](design-system-governance.md).
- [ ] Make `/design` responsive and keyboard-operable at the documented breakpoints.
- [ ] Add a governed presentation-API inventory with owner, maturity, source, consumers, states, accessibility contract, review date, and deprecation status.
- [ ] Distinguish stable, experimental, proposal, legacy, and deprecated material visually and programmatically.
- [ ] Make normative examples deterministic, complete, and consistent with production APIs.
- [ ] Add registry/inventory drift, guide-copy drift, semantic component, and bounded real-browser checks.
- [ ] Record accepted proposal graduation evidence and leave deferred/rejected proposals explicitly advisory.
- [ ] Run the focused design-system/component tests and governance checks.

### 20. Full-system verification and closeout

- [ ] Reconcile every one of the 196 finding IDs against its owning report; each must be resolved, removed, or explicitly deferred with rationale and owner.
- [ ] Confirm there are no unresolved P0 findings.
- [ ] Confirm every unresolved P1 has an explicit approved deferral; otherwise continue implementation.
- [ ] Run focused tests for every module changed.
- [ ] Run the JavaScript tests through the supported DOM/browser harness.
- [ ] Run browser verification at 320px, 768px, and desktop widths plus 200% zoom (diagram/canvas workspaces at 768px and up per decision 0.12).
- [ ] Verify keyboard-only operation, focus trap/return, touch targets, reduced motion, long content, empty/error/partial/degraded states, reconnect behavior, and representative contrast/grayscale.
- [ ] Run `mix precommit` and resolve the existing baseline plus any new findings until it passes.
- [ ] Update [index.md](index.md) with final disposition counts, verification evidence, and any remaining approved debt.
- [ ] Confirm production documentation, tests, and the design-system kit describe the same contracts.

## Progress summary

Update this table only after the matching package gate is complete.

| Package | Scope | Status | Completion evidence |
|---:|---|---|---|
| 0 | Product and proposal decisions | Complete | [decisions.md](decisions.md); all 0.1–0.11 items resolved, including explicit deferrals |
| 1 | Import destination correctness | Complete | PR [#659](https://github.com/TransitOPS/gtfs-planner/pull/659), commit `4393ca2`; `IMP-001` closed in [import-and-export.md](import-and-export.md) |
| 2 | Import completeness safety | Complete | PR [#660](https://github.com/TransitOPS/gtfs-planner/pull/660), commit `bf59dc0`; `IMP-002` closed in [import-and-export.md](import-and-export.md) |
| 3 | Import outcome recovery | Complete | PR [#661](https://github.com/TransitOPS/gtfs-planner/pull/661), commit `c4fbfbf`; `IMP-019` closed in [import-and-export.md](import-and-export.md) |
| 4 | Account/setup P0s | Complete | PR [#662](https://github.com/TransitOPS/gtfs-planner/pull/662), commit `064ab50`; `ACCT-001`, `ACCT-002` closed in [dashboard-settings-api-keys.md](dashboard-settings-api-keys.md) |
| 5 | First-install P0 | Complete (impl.) | PR [#664](https://github.com/TransitOPS/gtfs-planner/pull/664), commit `4f26b68`; `AUTH-001` implementation resolved in [authentication-and-setup.md](authentication-and-setup.md); keyboard-only browser check pending (VoiceOver gate removed by decision 0.12) |
| 6 | Shared overlay P0 | Complete | PR [#665](https://github.com/TransitOPS/gtfs-planner/pull/665): native `<dialog>` migration, Vitest/jsdom tooling, Playwright harness, 24-case e2e suite, CI integration, 4-family consumer compat; 634 tests / 0 failures; keyboard-only 200% zoom observation pending (VoiceOver gate removed by decision 0.12) in [shared-shell-and-components.md](shared-shell-and-components.md) |
| 7 | Spatial keyboard P0 | Complete | PR [#666](https://github.com/TransitOPS/gtfs-planner/pull/666), commit `f88d1c8`; `DIA-001` closed in [station-diagram-and-editing.md](station-diagram-and-editing.md); scale-calibration and DIA-003 deferred to Package 14 (2026-07-19) |

Completion note: DIA-001 is closed and merged to `main` via PR [#666](https://github.com/TransitOPS/gtfs-planner/pull/666). CSS focus-suppression is replaced with paired dark/light `focus-visible` indicator; three SVG groups (stop, pathway, badge) have gated `tabindex` + `role="button"` + Enter/Space activation; coordinate fields and reposition table provide keyboard create/reposition paths; endpoint selects share `handle_stop_selection` state with canvas clicks; labeled pan/zoom/reset buttons are wired to the `DiagramCanvas` hook; Escape cancels placement with visible feedback. Focused suites: 321 Elixir diagram tests (0 failures), 41 Vitest diagram-canvas hook tests (0 failures), 452-line Playwright keyboard e2e spec. Two-point scale calibration keyboard path and DIA-003 map-alignment keyboard controls are recorded as dated, owned Package 14 debt (2026-07-19); the P0-closure claim is explicitly qualified for scale calibration (C-010). DIA-011 reposition-table visual token migration is also deferred to Package 14. No design-system documentation changed because Package 14 owns the broader station-diagram visual migration.
| 8 | Prototype P0 and P0 gate | Retirement merged; P0 gate open | PR [#667](https://github.com/TransitOPS/gtfs-planner/pull/667), commit `9783ead`; prototype route/controller retired; 10 findings closed by retirement; `EXC-005`/`EXC-012` ErrorHTML portion remain for Package 18; `EXC-010` transferred to Packages 15/16/19; P0 gate open pending `AUTH-001`/`SHR-001` browser checks |
| 9 | Shared design-system contracts | Complete | PR [#668](https://github.com/TransitOPS/gtfs-planner/pull/668), commit `6e673fd`; 321 ExUnit (10 files), 19 Vitest, 41 Playwright (17 shared + 24 overlay regression); SHR-002–SHR-022 closed (SHR-016 closed by removal); GOV-009 trialed, GOV-010/011 experimental |
| 10 | Authentication and setup | Complete | Branch `010-dsa-align-authentication-setup` (steps 1–9 + step 10); `AUTH-001`–`AUTH-012` dispositioned in [authentication-and-setup.md](authentication-and-setup.md#package-10-implementation-evidence); 151 ExUnit + 17 Vitest + 30 Playwright; new P2 `AUTH-013`/`AUTH-014` recorded; `mix precommit` passed (2,795 tests, 0 failures, 5 skipped) |
| 11 | Dashboard, settings, and API keys | Not started | — |
| 12 | Administration | Complete | PR [#670](https://github.com/TransitOPS/gtfs-planner/pull/670), commit `42b5638`; ADM dispositions and 46 browser scenarios recorded in [administration.md](administration.md#package-12-automated-evidence-recorded-2026-07-20); Package 14's later `mix precommit` satisfies the integrator gate |
| 13 | GTFS catalogs and details | Not started | — |
| 14 | Station diagram and editing | Complete | PR [#671](https://github.com/TransitOPS/gtfs-planner/pull/671), commit `d957359`; 2,746 Elixir + 220 JavaScript tests, four Playwright suites, and `mix precommit` pass |
| 15 | Station reports and history | Not started | — |
| 16 | Import and export | Not started | — |
| 17 | Validation and reachability | Not started | — |
| 18 | Exceptional surfaces | Complete | Branch `018-dsa`, commits `0e9b052`–`1dcd7a7`; `EXC-005` and remaining ErrorHTML portion of `EXC-012` closed with focused render/route and real-404 browser evidence; `EXC-010` remains transferred |
| 19 | Design-system governance | Not started | — |
| 20 | Full-system verification and closeout | Not started | — |

## Final completion definition

The design-system alignment effort is complete only when:

- every finding has a recorded disposition and evidence;
- all P0s and non-deferred P1s are closed;
- shared production APIs and `/design` documentation agree;
- page implementations no longer carry superseded local patterns;
- the required accessibility and responsive browser matrix, as scoped by decision 0.12, passes;
- focused Elixir and JavaScript suites pass; and
- `mix precommit` passes.
