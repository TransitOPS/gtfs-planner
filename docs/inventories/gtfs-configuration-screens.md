---
id: INV-004
title: GTFS Planner — configuration screens
type: inventory
status: draft
owner: gtfs-planner
last_reviewed: 2026-10-01
review_interval_days: 90
verified_against: 7c55d705
predicate: unverified — the same expression as INV-003: signed in, organization context assigned, a published version resolved, and membership holding `pathways_studio_editor`
authentication: required
roles: [pathways_studio_editor]
layer: configuration
parent: INV-000
derived_from: none
---

## 1. Audience

These screens are for the same member as INV-003, but on a different cadence: they are the
occasional visits where the feed's shape is changed rather than its records. Feed details,
agencies, export defaults, garages, fleet and the fares workspace live here, and a reader
arrives from the Settings entry or from a link inside a daily-work screen rather than from the
navigation bar.

## 2. Access predicate

> **unverified** — No permission model exists for this repository, so the predicate is the
> expression the mount hooks prove, identical to INV-003: signed in, organization context
> assigned, a published version resolved, and the `pathways_studio_editor` role.

Exceptions inside this inventory: SCRN-041, SCRN-042 and SCRN-043 hold organization-wide
settings rather than version settings, so the version in their URL is navigation context only
and those pages ignore it. SCRN-047 is the catch-all section slug, marked `unverified`.

## 3. Entry points

`GtfsPlannerWeb.Navigation` reaches `/gtfs/:version/settings` from its "GTFS" area settings
entry, and the layout's settings hint links the same destination. Every other row here is
reached from a link inside SCRN-038 or from a tab within a neighbouring row; no row outside
SCRN-038 has its own navigation link.

## 4. Screens

### This version

| ID | Screen | Route | Reached by | Status | Purpose |
|---|---|---|---|---|---|
| SCRN-038 | Settings | `/gtfs/:version/settings` | all | undocumented | Version-scoped Settings, the landing surface for every row below |
| SCRN-039 | Feed details | `/gtfs/:version/settings/feed-details` | all | undocumented | Read and edit the publisher, dates, version and data contact of the feed |
| SCRN-040 | Agencies | `/gtfs/:version/settings/agencies` | all | undocumented | One version's agencies, their route counts and their timezone agreement |
| SCRN-044 | Fare zones | `/gtfs/:version/settings/fares` | all | undocumented | The Fare zones workspace, with zone, rule and check tabs |
| SCRN-045 | Fare rules | `/gtfs/:version/settings/fares/rules` | all | undocumented | The fare rules of the fares workspace |
| SCRN-046 | Fare checks | `/gtfs/:version/settings/fares/checks` | all | undocumented | The consistency checks run over the fares workspace |
| SCRN-047 | Settings section | `/gtfs/:version/settings/:section` | all | unverified | The catch-all section slug; renders the named sections that have no literal route |

### All versions (organization-wide settings)

| ID | Screen | Route | Reached by | Status | Purpose |
|---|---|---|---|---|---|
| SCRN-041 | Export defaults | `/gtfs/:version/settings/export-defaults` | all | undocumented | Whether a full export also writes the flex file, and which file the realtime vendor reads |
| SCRN-042 | Garages | `/gtfs/:version/settings/garages` | all | undocumented | The organization's garages and the stop IDs each one conflicts with |
| SCRN-043 | Fleet | `/gtfs/:version/settings/fleet` | all | undocumented | The organization's vehicles as a type-by-garage matrix and a bounded list |

## 5. Journeys

None yet: the journey registry is written after this inventory.

## 6. Seams

| To inventory | Where | What carries across |
|---|---|---|
| INV-003 | Settings links inside the daily-work screens, and the settings entry in the navigation | The version ID in the path, the only state these screens share |
| INV-002 | The dashboard's settings link | The organization and version context, re-derived on mount |

The GTFS area of the main navigation hides these screens from a Pathways Studio member's
navigation while never denying the route, so INV-003 and INV-004 are one product pair rather
than two audiences. The seams table in the index owns that statement.

Within this inventory, SCRN-044, SCRN-045 and SCRN-046 are one LiveView
(`GtfsPlannerWeb.Gtfs.FaresLive`) with three actions: the tab links patch between literal paths
that the router declares ahead of the `:section` catch-all, and the Zones tab's query state
survives a tab change.

## 7. Coverage

| Measure | Count |
|---|---|
| Screens in this inventory | 10 |
| Documented (a screen page exists) | 0 |
| Undocumented | 9 |
| Unverified | 1 (SCRN-047) |
| IDs issued in this inventory | 10 (SCRN-038 to SCRN-047) |

Next unused ID for the next run: SCRN-058. IDs are issued across the whole corpus, never per
file, and never reused.

## Open questions

- OQ-007 — Which section slugs reach SCRN-047, now that `feed-details`, `agencies`,
  `export-defaults`, `garages`, `fleet` and `fares` all have literal routes? Until the app is
  walked, the set of slugs that fall through to the catch-all is unverified. Owner: product
  owner. Open since 2026-10-01.
- OQ-008 — SCRN-041, SCRN-042 and SCRN-043 are organization-wide settings filed under
  `/gtfs/:version/settings*`, where the version is navigation context the pages ignore. Confirm
  the configuration layer is the right home, rather than a separate organization inventory.
  Owner: product owner. Open since 2026-10-01.

## Changelog

| Date | Version | Change | Author |
|---|---|---|---|
| 2026-10-01 | 1 | Initial rows SCRN-038 to SCRN-047 from the `:gtfs_routes` live_session settings routes; partition unverified without a permission model | spec step 29 |
