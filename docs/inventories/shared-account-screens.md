---
id: INV-002
title: Shared account and identity screens
type: inventory
status: draft
owner: gtfs-planner
last_reviewed: 2026-10-01
review_interval_days: 90
verified_against: 7c55d705
predicate: unverified — signed in and holding at least one membership; `GtfsPlannerWeb.UserAuth` `on_mount(:ensure_authenticated)` with `GtfsPlannerWeb.AssignOrganization` `on_mount(:optional)`
authentication: required
roles: [administrator, pathways_studio_admin, pathways_studio_editor]
layer: shared
parent: INV-000
derived_from: none
---

## 1. Audience

These two screens are for any signed-in member, whatever their role and whichever organization
product they belong to. The dashboard is the landing page after sign-in and the place that says
what this member can work on next; user settings is where the person changes their own name,
email address and password. Both are reached occasionally rather than as part of the daily feed
work.

## 2. Access predicate

> **unverified** — No permission model exists for this repository, so the predicate is the
> expression the mount hooks prove: signed in
> (`GtfsPlannerWeb.UserAuth.on_mount(:ensure_authenticated)`), organization context optional
> (`GtfsPlannerWeb.AssignOrganization.on_mount(:optional)`), no role requirement.

The optional organization hook is what puts a system administrator, a member with no
organization, and a member whose organization has no published version on the same page as a
working editor; `GtfsPlannerWeb.DashboardLive` renders one state per combination instead of
splitting into separate screens.

## 3. Entry points

Both rows are the post-sign-in destination: the session controller redirects a successful
`POST /users/log_in` to `/`, and the dashboard is what the browser lands on. `/users/settings` is
reached from the account menu in the top bar, which every layout renders.

## 4. Screens

| ID | Screen | Route | Reached by | Status | Purpose |
|---|---|---|---|---|---|
| SCRN-007 | Dashboard | `/` | all | undocumented | Pick one landing state from the member's organization, version and role and point at the next task |
| SCRN-008 | User settings | `/users/settings` | all | undocumented | The signed-in person's own name, email address and password |

## 5. Journeys

None yet: the journey registry is written after this inventory.

## 6. Seams

| To inventory | Where | What carries across |
|---|---|---|
| INV-001 | Sign-out and email-confirmation links from SCRN-008 | Nothing but the session; the controllers answer and redirect back here |
| INV-003 | Dashboard links into Routes, Stops and the GTFS area | The current GTFS version and the organization context, both assigned by `GtfsPlannerWeb.AssignGtfsVersion` on the destination mount rather than carried in the URL |
| INV-004 | Dashboard and Settings links into `/gtfs/:version/settings*` | The same version context |
| INV-005 | Dashboard link to `/admin/users` for a `pathways_studio_admin` | The organization context, which the admin mount re-derives |
| INV-006 | Dashboard's organization-administrator state for a system administrator | The organization context, absent by design on the `:administrator_only` session |
| INV-007 | Dashboard link to the design-system section | The session only |

Both rows are the shared surfaces named in section 4 of the index: they appear here exactly once
and are cross-referenced from every other inventory.

## 7. Coverage

| Measure | Count |
|---|---|
| Screens in this inventory | 2 |
| Documented (a screen page exists) | 0 |
| Undocumented | 2 |
| Unverified | 0 |
| IDs issued in this inventory | 2 (SCRN-007 and SCRN-008) |

Next unused ID for the next run: SCRN-058. IDs are issued across the whole corpus, never per
file, and never reused.

## Open questions

- OQ-003 — Can a member change the email address on SCRN-008, and if so through which route,
  given that `GET /users/settings/confirm_email/:token` is excluded from every inventory as a
  token action? Owner: product owner. Open since 2026-10-01.

## Changelog

| Date | Version | Change | Author |
|---|---|---|---|
| 2026-10-01 | 1 | Initial rows SCRN-007 and SCRN-008 from the `:require_authenticated_user_account` live_session; partition unverified without a permission model | spec step 29 |
