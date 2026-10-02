---
id: INV-003
title: GTFS Planner — operation screens
type: inventory
status: draft
owner: gtfs-planner
last_reviewed: 2026-10-01
review_interval_days: 90
verified_against: 7c55d705
predicate: unverified — signed in, organization context assigned, a published version resolved, and membership in an organization holding `pathways_studio_editor`; `GtfsPlannerWeb.UserAuth` `on_mount(:ensure_authenticated)`, `GtfsPlannerWeb.AssignOrganization` `on_mount(:default)`, `GtfsPlannerWeb.AssignGtfsVersion`, and `GtfsPlannerWeb.EnsureRole.on_mount(:require_gtfs_access)` on each `Gtfs.*Live`
authentication: required
roles: [pathways_studio_editor]
layer: operation
parent: INV-000
derived_from: none
---

## 1. Audience

These screens are for the member doing the daily feed work: the person who edits a published
version's routes, calendars, patterns, schedules, stops and stations, plans blocks and runs,
defines flex services, imports a new feed, exports one and reads the validation results. They
are reached many times a day, from the six task areas of the main navigation bar and from each
other. The reader is expected to know the feed already.

## 2. Access predicate

> **unverified** — No permission model exists for this repository, so the predicate is the
> expression the mount hooks prove: signed in, organization context assigned
> (`GtfsPlannerWeb.AssignOrganization.on_mount(:default)`), a published version resolved
> (`GtfsPlannerWeb.AssignGtfsVersion`), and the `pathways_studio_editor` role
> (`GtfsPlannerWeb.EnsureRole.on_mount(:require_gtfs_access)` on every `Gtfs.*Live` in this
> inventory).

Exceptions inside this inventory: SCRN-030 (`/gtfs/:version/rosters`) is a registered
placeholder with no implementation behind it, so its status is `unverified`. The organization
product field (`planner` or `pathways`) narrows nothing: `GtfsPlannerWeb.ProductSurfaces.visible?/2`
hides areas from navigation and branding and never denies a route, so a Pathways Studio member
who deep-links reaches every row here.

## 3. Entry points

The main navigation bar carries one link per task area — Routes, Stops, Calendars, Alerts,
Flex, Operations and GTFS — and each link's destination is the first route in its family
(`GtfsPlannerWeb.Navigation.main_tasks/0` in
`lib/gtfs_planner_web/components/navigation.ex`). Every row is also reachable by deep link once
the reader holds the version ID in the URL; the version in the path is the only state these
screens take from their caller.

## 4. Screens

### Routes area

| ID | Screen | Route | Reached by | Status | Purpose |
|---|---|---|---|---|---|
| SCRN-009 | Routes | `/gtfs/:version/routes` | all | undocumented | Browse the version's routes and open one |
| SCRN-010 | Transfers | `/gtfs/:version/transfers` | all | undocumented | Manage the version's transfer rules, the Routes area's second tab |

### Calendars area

| ID | Screen | Route | Reached by | Status | Purpose |
|---|---|---|---|---|---|
| SCRN-011 | Calendars | `/gtfs/:version/calendars` | all | undocumented | List the version's editable service calendars over the scoped union read model |
| SCRN-012 | New calendar | `/gtfs/:version/calendars/new` | all | undocumented | Create one editable service calendar |
| SCRN-013 | Calendar detail | `/gtfs/:version/calendars/show` | all | undocumented | Read and edit one calendar's dates, and see what else uses it |

### One route and its patterns and schedules

| ID | Screen | Route | Reached by | Status | Purpose |
|---|---|---|---|---|---|
| SCRN-014 | Route details | `/gtfs/:version/routes/:route_id` | all | undocumented | Everything recorded about one route, short of its patterns and times |
| SCRN-015 | Route patterns | `/gtfs/:version/routes/:route_id/patterns` | all | undocumented | The ordered patterns of one route and the editor for them |
| SCRN-016 | New route pattern | `/gtfs/:version/routes/:route_id/patterns/new` | all | undocumented | Add a pattern to one route |
| SCRN-017 | Compare patterns | `/gtfs/:version/routes/:route_id/patterns/compare` | all | undocumented | Compare two patterns of one route side by side |
| SCRN-018 | Route pattern detail | `/gtfs/:version/routes/:route_id/patterns/:route_pattern_id` | all | undocumented | One pattern's stops, ordering and properties |
| SCRN-019 | Route schedules | `/gtfs/:version/routes/:route_id/schedules` | all | undocumented | One route's Schedules view of its trips and times |
| SCRN-020 | Paste timetable | `/gtfs/:version/routes/:route_id/schedules/paste` | all | undocumented | Paste a block of timetable text onto one route's schedules |

### Stops & stations area

| ID | Screen | Route | Reached by | Status | Purpose |
|---|---|---|---|---|---|
| SCRN-021 | Stops and stations | `/gtfs/:version/stops` | all | undocumented | Browse the version's stops and stations |
| SCRN-022 | Stop or station detail | `/gtfs/:version/stops/:stop_id` | all | undocumented | One stop's or station's identifiers, location and serving trips |
| SCRN-023 | Station diagram | `/gtfs/:version/stops/:stop_id/diagram` | all | undocumented | Edit one station's levels, pathways and child stops as a diagram |
| SCRN-024 | Station report | `/gtfs/:version/stops/:stop_id/report` | all | undocumented | One station's report dashboard, its sections loading independently |
| SCRN-025 | Station reachability | `/gtfs/:version/stops/:stop_id/reachability` | all | undocumented | Run and read station-level reachability validation for one stop |
| SCRN-026 | Pathway evolutions | `/gtfs/:version/stops/:stop_id/evolutions` | all | undocumented | One station's scheduled pathway closures over the service calendar |
| SCRN-027 | Pathway access preview | `/gtfs/:version/stops/:stop_id/evolutions/access` | all | undocumented | Preview pathway access at a chosen service moment on the same mounted station |

### Operations area

| ID | Screen | Route | Reached by | Status | Purpose |
|---|---|---|---|---|---|
| SCRN-028 | Blocks | `/gtfs/:version/blocks` | all | undocumented | Which trips one vehicle works in sequence for a service day, and the only place a block is edited |
| SCRN-029 | Runs | `/gtfs/:version/runs` | all | undocumented | The Runs page, next to Blocks in the Operations bar |
| SCRN-030 | Rosters | `/gtfs/:version/rosters` | all | unverified | Registered placeholder for Rosters, with no implementation behind it yet |

### Flex area

| ID | Screen | Route | Reached by | Status | Purpose |
|---|---|---|---|---|---|
| SCRN-031 | Flex services | `/gtfs/:version/flex` | all | undocumented | The version's flex services with their hours, booking summary and readiness |
| SCRN-032 | Flex service | `/gtfs/:version/flex/:service` | all | undocumented | One flex service and its area, bookings and stop rules |
| SCRN-033 | Flex service area editor | `/gtfs/:version/flex/:service/area` | all | undocumented | Edit the candidate area of one flex service, an action on that service's page |

### GTFS area — import, export and results

| ID | Screen | Route | Reached by | Status | Purpose |
|---|---|---|---|---|---|
| SCRN-034 | Import | `/gtfs/:version/import` | all | undocumented | Import GTFS data into a version |
| SCRN-035 | Export | `/gtfs/:version/export` | all | undocumented | Choose what to export, see what the file contains and act on the latest run |
| SCRN-036 | Validation run | `/gtfs/:version/validation/:validation_id` | all | undocumented | One validation run's errors, warnings and notices |
| SCRN-037 | Station reachability results | `/gtfs/:version/station-reachability/:validation_id` | all | undocumented | The station-by-station outcome of one reachability validation run |

## 5. Journeys

None yet: the journey registry is written after this inventory.

## 6. Seams

| To inventory | Where | What carries across |
|---|---|---|
| INV-004 | The Settings entry in the navigation, and the settings links inside these screens | The version ID in the path; nothing else crosses, and the settings pages read the same version |
| INV-002 | The dashboard's task links, and the account menu on every screen here | The organization and version context, re-derived on the destination mount |

Within this inventory the following rows are one component tree reached at more than one route,
not duplicates:

| Routes | Rows | Shared implementation | Notes |
|---|---|---|---|
| `/gtfs/:version/calendars/new`, `/gtfs/:version/calendars/show` | SCRN-012, SCRN-013 | `GtfsPlannerWeb.Gtfs.CalendarLive` | The service ID travels as a query parameter, so an imported ID can never collide with a path segment |
| `/gtfs/:version/routes/:route_id/patterns`, `/new`, `/:route_pattern_id` | SCRN-015, SCRN-016, SCRN-018 | `GtfsPlannerWeb.Gtfs.RoutePatternLive` | One editor, three actions |
| `/gtfs/:version/stops/:stop_id/evolutions`, `/evolutions/access` | SCRN-026, SCRN-027 | `GtfsPlannerWeb.Gtfs.PathwayEvolutionsLive` | One mounted station and one socket; `?date` and `?time` name the service moment |
| `/gtfs/:version/flex/:service`, `/flex/:service/area` | SCRN-032, SCRN-033 | `GtfsPlannerWeb.Gtfs.FlexServiceLive` | The area editor is the service page's own action, so its draft survives the patch |
| `/gtfs/:version/stops/:stop_id/reachability`, `/gtfs/:version/station-reachability/:validation_id` | SCRN-025, SCRN-037 | `GtfsPlannerWeb.Gtfs.StationReachabilityLive`, `GtfsPlannerWeb.Gtfs.StationReachabilityResultLive` | The launch screen for one stop and the run-wide results screen; two surfaces of one feature |

`/gtfs/:version/export-runs/:run_id/download` is a file download behind the
`:require_gtfs_editor` pipeline, not a page: it is excluded from every inventory and reached
from SCRN-035.

## 7. Coverage

| Measure | Count |
|---|---|
| Screens in this inventory | 29 |
| Documented (a screen page exists) | 0 |
| Undocumented | 28 |
| Unverified | 1 (SCRN-030) |
| IDs issued in this inventory | 29 (SCRN-009 to SCRN-037) |

Next unused ID for the next run: SCRN-058. IDs are issued across the whole corpus, never per
file, and never reused.

Every row above is a page route registered in the `:gtfs_routes` live_session and rendered by
the named LiveView action. The organization product field hides Routes, Flex, feed settings,
fares, garages, fleet and export from a Pathways Studio member's navigation without denying the
route, which is why hiding is recorded here as a note and not as a partition.

## Open questions

- OQ-004 — `/gtfs/:version/rosters` (SCRN-030) is a registered placeholder with no
  implementation. Keep it in operation beside Blocks and Runs, or exclude it like the
  controller-only endpoints? The index keeps it, marked unverified. Owner: product owner. Open
  since 2026-10-01.
- OQ-005 — Reachability has two surfaces (SCRN-025 per stop and SCRN-037 per run). Are these one
  screen with two states, or two screens? Owner: product owner. Open since 2026-10-01.
- OQ-006 — SCRN-024 (`/stops/:stop_id/report`) is a second reporting surface beside SCRN-022's
  detail page, and neither is listed in the main navigation. Confirm both are reached from the
  station diagram rather than being standalone entries. Owner: product owner. Open since
  2026-10-01.

## Changelog

| Date | Version | Change | Author |
|---|---|---|---|
| 2026-10-01 | 1 | Initial rows SCRN-009 to SCRN-037 from the `:gtfs_routes` live_session, grouped by task area; partition unverified without a permission model | spec step 29 |
