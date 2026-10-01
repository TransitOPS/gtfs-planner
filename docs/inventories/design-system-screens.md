---
id: INV-007
title: Design system reference screens
type: inventory
status: draft
owner: gtfs-planner
last_reviewed: 2026-10-01
review_interval_days: 90
verified_against: 7c55d705
predicate: unverified — signed in only; `GtfsPlannerWeb.UserAuth` `on_mount(:ensure_authenticated)` in the `:require_authenticated_user_design` live_session, which assigns no organization context and requires no role
authentication: required
roles: [administrator, pathways_studio_admin, pathways_studio_editor]
layer: shared
parent: INV-000
derived_from: none
---

## 1. Audience

These screens are not a product audience at all. They are the in-app design-system reference:
the foundations, component, pattern and proposal pages a designer or a reviewer reads to see
what the application's surfaces look like and what has been proposed for them. They are
reached directly by URL, not through the main navigation, and no organization's work depends on
them.

## 2. Access predicate

> **unverified** — No permission model exists for this repository, so the predicate is the
> expression the mount hook proves: signed in
> (`GtfsPlannerWeb.UserAuth.on_mount(:ensure_authenticated)`), no organization context, no role
> requirement.

Exceptions inside this inventory: none. Any signed-in user reaches every row.

## 3. Entry points

`/design` is the section entry and is linked from the design-system task item in
`GtfsPlannerWeb.Navigation`. `/design/:page` is reached from the sidebar, which the section
shell renders from the ordered page registry `GtfsPlannerWeb.Design.DesignSystemLive.pages/0`.

## 4. Screens

| ID | Screen | Route | Reached by | Status | Purpose |
|---|---|---|---|---|---|
| SCRN-056 | Design system | `/design` | all | undocumented | The section shell, its ordered sidebar and the dispatch to the first registered page |
| SCRN-057 | Design system page | `/design/:page` | all | undocumented | One registered page body, addressed by its registry slug and patched without a reload |

## 5. Journeys

None yet: the journey registry is written after this inventory.

## 6. Seams

| To inventory | Where | What carries across |
|---|---|---|
| INV-002 | The dashboard's design-system link | The session only; the section assigns no organization and needs no version |

The registry is the single source of page slugs, titles, grouping and order, so the sidebar,
the dispatch clauses and the tests all derive from it. That is why this inventory has two rows
for what a reader experiences as many pages.

## 7. Coverage

| Measure | Count |
|---|---|
| Screens in this inventory | 2 |
| Documented (a screen page exists) | 0 |
| Undocumented | 2 |
| Unverified | 0 |
| IDs issued in this inventory | 2 (SCRN-056 and SCRN-057) |

Next unused ID for the next run: SCRN-058. IDs are issued across the whole corpus, never per
file, and never reused.

## Open questions

- OQ-013 — `/design/:page` is one catch-all route serving every registered page. Should each
  registry page earn its own row, as every other multi-page LiveView in the corpus does, or is
  one row the honest count for a route-addressed section? Owner: product owner. Open since
  2026-10-01.

## Changelog

| Date | Version | Change | Author |
|---|---|---|---|
| 2026-10-01 | 1 | Initial rows SCRN-056 and SCRN-057 from the `:require_authenticated_user_design` live_session; partition unverified without a permission model | spec step 29 |
