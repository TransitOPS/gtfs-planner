# Design System Alignment Audit Index

## Outcome

The audit covers every first-party browser route and meaningful user-facing LiveView action in GTFS Planner. It is an implementation-ready correction package, not an implementation: production code was not changed.

Across 11 finding reports, the audit records **198 findings**:

| Priority | Count | Meaning |
|---|---:|---|
| P0 | 9 | Blocks a task, risks destructive/incorrect behavior, or creates a severe accessibility failure |
| P1 | 83 | Materially impairs a core task or propagates broadly |
| P2 | 93 | Meaningful usability, consistency, state, or maintainability gap |
| P3 | 13 | Bounded polish or explicitly advisory improvement |

| Type | Count |
|---|---:|
| Violation | 139 |
| Consistency gap | 38 |
| Proposal opportunity | 21 |

Proposal opportunities are not current compliance failures. They remain advisory until accepted, implemented as a production contract, documented on a Components/Foundation page, and verified through the governance gate.

Package 0 decisions are complete. See the evidence-backed [decision ledger](decisions.md) and the sequential [implementation plan](plan.md).

## Package map

Start with [00-standards-and-rubric.md](00-standards-and-rubric.md), then use the report owning the workflow being corrected.

| Report | User-facing scope | Findings | P0 / P1 / P2 / P3 |
|---|---|---:|---:|
| [shared-shell-and-components.md](shared-shell-and-components.md) | Layouts, app/auth shell, navigation, version switcher, core components | 22 | 1 / 9 / 10 / 2 |
| [authentication-and-setup.md](authentication-and-setup.md) | First administrator, login, reset, confirmation, invite acceptance | 14 | 1 / 5 / 7 / 1 |
| [dashboard-settings-api-keys.md](dashboard-settings-api-keys.md) | Dashboard, account settings, latent API-key UI | 18 | 2 / 7 / 8 / 1 |
| [administration.md](administration.md) | User and organization administration | 15 | 0 / 3 / 10 / 2 |
| [gtfs-catalog-and-details.md](gtfs-catalog-and-details.md) | Route/station catalogs, route tabs, station details | 24 | 0 / 8 / 15 / 1 |
| [station-diagram-and-editing.md](station-diagram-and-editing.md) | Diagram modes, spatial editing, map alignment, uploads, drawers | 22 | 1 / 9 / 12 / 0 |
| [station-reports-and-history.md](station-reports-and-history.md) | Six report sections, print, edit drawer, history and rollback | 24 | 0 / 12 / 11 / 1 |
| [import-and-export.md](import-and-export.md) | Upload/import, diff decisions/apply, export/download, validation launch | 19 | 3 / 7 / 7 / 2 |
| [validation-and-reachability.md](validation-and-reachability.md) | Validation results, reachability workspace/results, history/polling | 15 | 0 / 7 / 6 / 2 |
| [prototype-and-exceptional-surfaces.md](prototype-and-exceptional-surfaces.md) | Station-resolution prototype and HTML error pages | 12 | 1 / 5 / 5 / 1 |
| [design-system-governance.md](design-system-governance.md) | `/design`, inventory, normative/advisory boundary, graduation and drift | 13 | 0 / 11 / 2 / 0 |

## Browser-route coverage

| Router surface | Owning report |
|---|---|
| `/first`, `/users/log_in`, password reset, confirmation, invitation acceptance, login POST | Authentication and setup |
| `DELETE /users/log_out` | Shared authenticated shell/auth boundary |
| `/` and `/users/settings` | Dashboard, settings, and API keys |
| `/design` and `/design/:page` | Design-system governance; these routes are also the normative reference used by every report |
| `/admin/users...` and `/admin/organizations...` | Administration |
| `/gtfs/:version/routes...` and `/stops`, `/stops/:stop_id` | GTFS catalog and details |
| `/stops/:stop_id/diagram`; map tile/building degraded states | Station diagram and editing |
| `/stops/:stop_id/report`; embedded change history | Station reports and history |
| `/import` and `/export` | Import and export |
| `/validation/:validation_id`, `/stops/:stop_id/reachability`, `/station-reachability/:validation_id` | Validation and reachability |
| HTML 404/500 rendering | Prototype and exceptional surfaces |

JSON companion APIs, `/health`, email templates, development LiveDashboard/mailbox routes, and raw map-data responses are not browser design-system pages. Map service failure/degradation as experienced by users is included in the diagram report.

## P0 release gates

These should be fixed or deliberately removed/quarantined before broad visual migration:

| Finding | Gate |
|---|---|
| `IMP-001` | A failed “create version” operation can silently import into the current version instead |
| `IMP-002` | Incomplete parsing can produce destructive removal decisions |
| `IMP-019` | Partially committed imports are presented as total failure, making retry unsafe |
| `ACCT-001` | `/users/settings` reads an assign that is never created and can fail on initial render |
| `ACCT-002` | Both settings forms have incompatible parameter contracts and duplicate control IDs |
| `AUTH-001` | First-install organization errors cannot map back to the rendered setup fields; **implementation resolved (Package 5 + Package 10 steps 1/4), keyboard-only `/first` browser check recorded as a separate zero-user release observation** |
| `SHR-001` | Closed drawers remain exposed as modal, tabbable content |
| `DIA-001` | Essential spatial editor tasks have no keyboard-operable equivalent or visible focus |
| `EXC-001` | Prototype station navigation uses click-only list items; **closed by Package 8 retirement** |

## Cross-cutting workstreams

Implement shared contracts once, then migrate consumers. Page reports retain domain-specific acceptance criteria but should not fork these fixes.

| Shared workstream | Authority | Primary consumers |
|---|---|---|
| Drawer/dialog inertness, focus, destructive pending behavior | `SHR-001`, `SHR-007` | Admin, API keys, diagram, report/history, validation history |
| Responsive shell/navigation, sub-navigation, target sizing | `SHR-002`, `SHR-010`, `SHR-020` | Every authenticated page; route/station destinations |
| Form/error/required/action contract | `SHR-005`, `SHR-012`, `SHR-013` | Auth, settings, admin, diagram, import/export, report drawers |
| Responsive semantic data views and pagination | `SHR-006`, `SHR-014`, `GOV-009` | Admin, catalogs, diagram tables, diff review, reports, validation |
| Semantic tokens, title scale, state vocabulary | `SHR-003`, `SHR-008`, `SHR-021` | Nearly every module |
| Flash/callout/empty announcements and reduced motion | `SHR-015`–`SHR-017` | Every asynchronous, error, empty, or overlay flow |
| Durable async-task lifecycle | `GOV-013` proposal backed by `IMP-003`, `IMP-005`, `IMP-006`, `VAL-002`, `VAL-003`, `REP-001` | Import, export, validation, report refresh |
| Upload field/task states | `GOV-010` proposal backed by `IMP-008`, `DIA-006`, `DIA-007` | Feed import and diagram replacement |
| Selection/composite semantics | `GOV-011` proposal; `SHR-020` for navigation | Diagram modes, diff filters, report/history controls, disclosures |
| Spatial workspace/status model | `GOV-012` proposal backed by diagram findings | Diagram and map alignment |

## Recommended implementation order

### 0. Contain correctness and data-loss risks

- Resolve `IMP-001`, `IMP-002`, and `IMP-019` before presentation-only import changes.
- Restore settings and first-install form contracts (`ACCT-001`, `ACCT-002`, `AUTH-001`).
- Make closed overlays inert (`SHR-001`) and provide a keyboard-equivalent editor path (`DIA-001`).
- Retire or quarantine the prototype unless promotion is explicitly chosen.

### 1. Record ambiguous product-surface decisions — complete

The schedules route, API-key UI, confirmation resend, admin user detail, station-resolution prototype, report pathway form, user-deactivation recovery, import atomicity/recovery, display timezone, clock-format deferral, and all proposal findings are resolved in [decisions.md](decisions.md). Removing a dead route/surface is a valid alignment correction; do not style an undefined feature.

### 2. Repair the shared platform

Implement the shared workstreams above in dependency order: overlays and focus; form/errors; shell/navigation/sub-navigation; tables/pagination; tokens/type/status; feedback/announcements/motion. Update Components pages and component tests in the same changes so the kit never documents a stale contract.

### 3. Align conventional pages

Migrate authentication, dashboard/settings, administration, and catalog/detail pages onto the repaired shared contracts. These surfaces provide lower-risk proving grounds for forms, empty states, responsive data views, status, and navigation before the spatial/async workflows consume them.

### 4. Align complex workflows

Implement station diagram, report/history, import/export, and validation/reachability corrections. Preserve domain invariants, audit history, version/organization scope, task continuity, and partial-state truthfulness while replacing page-local visual systems.

### 5. Graduate selected proposals

Evaluate each proposal independently. The audit identifies evidence for guarded route identity (`SHR-019`/`CAT-011`), version diff (`IMP-017`, `REP-019`, `EXC-010`), severity counts (`IMP-018`, `VAL-013`), tri-state accessibility/pathways (`DIA-020`, `VAL-014`), uploads, responsive data views, selection controls, spatial workspaces, and durable tasks. Acceptance of one does not accept the others.

### 6. Close with browser evidence and governance

Update the inventory/maturity metadata, migration status, documentation, semantic tests, and browser verification required by `design-system-governance.md`. Deprecate superseded local patterns and prevent new use before removing them.

## Resolved implementation decisions

The full rationale, evidence, proposal dispositions, and package insertion points are in [decisions.md](decisions.md). In summary:

1. Defer schedules as unfinished product work.
2. Remove the unused legacy API-key subsystem; preserve companion user-session authentication.
3. Remove the unreachable confirmation-resend branch.
4. Remove the unused admin user-detail route/action.
5. Stop serving the station-resolution prototype while retaining its files as advisory research.
6. Remove the unreachable report pathway form and keep pathway editing in the station diagram.
7. Require explicit, consequence-specific confirmation for user deactivation; do not offer Undo for invalidated sessions.
8. Import into a non-current staging version and publish atomically only after success.
9. Display in the current version's agency timezone with explicit UTC fallback; defer the 12-hour/24-hour format choice until report/validation implementation.
10. All 21 proposal findings have accepted, deferred, or rejected dispositions and sequential insertion points.

## Verification status

- All reports distinguish source inference from rendered evidence.
- P0/P1 evidence paths were normalized and checked: no unresolved or ambiguous high-priority path citations remain.
- Focused audit-time executions reported **611 passing Elixir tests and 1 skipped test** across administration, diagram, import, report/history, validation, and design-system/component suites.
- `mix precommit` was attempted after consolidation but stopped at the repository's existing Credo baseline: 55 readability issues and 173 refactoring opportunities, all outside this ignored documentation package. No production source was changed by the audit.
- The diagram audit found 66 JavaScript cases, but direct Bun execution lacked the repository's DOM harness; those results are recorded as a test-environment limitation, not a product failure.
- No browser screenshot, computed-style, screen-reader, touch-device, or automated contrast pass was performed. Every report includes the required implementation-time browser verification.

Required closeout checks include 320/768/desktop widths (diagram/canvas workspaces at 768 px and up per decision 0.12), 200% zoom, keyboard-only use, focus trap/return, reduced motion, long/empty/error/partial content, reconnect behavior, and representative contrast/grayscale checks. Screen-reader verification is removed by decision 0.12 in [decisions.md](decisions.md).

## Package 9 evidence summary

**Recorded:** 2026-07-19

- **321 focused ExUnit tests** passing across 10 test files (form_components_test, data_view_components_test, navigation_components_test, feedback_components_test, route_identity_test, gtfs_version_switcher_test, header_test, design_system_live_test, organizations_live_test, routes_live_test).
- **19 Vitest tests** passing for version hook (gtfs_version_hook_test.js).
- **41 Playwright tests** passing (17 shared_design_contracts.spec.js + 24 overlay regression tests).
- **SHR-002 through SHR-022** dispositions updated to Closed (SHR-016 remains closed by removal under decision 0.12).
- **GOV-009** trialed (two production consumers: Organizations and Routes). **GOV-010** and **GOV-011** experimental.
- **Package 10 eligibility:** authorized when `mix precommit` gate passes.

## Package 10 evidence summary

**Recorded:** 2026-07-20 (branch `010-dsa-align-authentication-setup`)

- **AUTH-001 through AUTH-012** all have evidence-backed dispositions in
  [authentication-and-setup.md](authentication-and-setup.md#package-10-implementation-evidence).
  AUTH-001 implementation is resolved; its keyboard-only `/first` browser check is recorded as a separate
  zero-user release observation (the seeded suite creates users and cannot render `/first`).
- **151 focused ExUnit tests** passing across the 11 auth test files (`MIX_TEST_PARTITION=step10`).
- **17 Vitest tests** passing for the form-error focus hook (form_error_focus_hook_test.js).
- **30 Playwright tests** passing (authentication.spec.js): login ideal + recovery states, reset request,
  isolated valid/invalid/expired/replay reset/confirm/invite paths, keyboard focus/Tab order, reduced
  motion, target size, and 320/768/desktop/200% reflow.
- **Two new P2 findings** discovered during browser evidence: `AUTH-013` (failed-submit auto-focus race —
  the submit button regains focus ~1ms after the hook focuses the invalid field) and `AUTH-014` (shared
  default button renders at 40px, below the 44px target; inputs render at 48px). Both are open, owned by
  follow-ups, and do not block Package 11.
- **Package 11 eligibility:** authorized when the focused gates and `mix precommit` pass (recorded in
  [plan.md](plan.md)).

## Repository note

`.specs/` is ignored by the current `.gitignore`. These artifacts are available locally for implementation agents but will not enter a normal commit unless the repository intentionally changes that policy or force-adds the package.
