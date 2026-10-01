---
id: INV-005
title: Organization administration screens
type: inventory
status: draft
owner: gtfs-planner
last_reviewed: 2026-10-01
review_interval_days: 90
verified_against: 7c55d705
predicate: unverified — signed in, organization context assigned, and holding `pathways_studio_admin`; `GtfsPlannerWeb.Admin.UsersLive` mounts `GtfsPlannerWeb.EnsureRole.on_mount(:require_pathways_studio_admin)` in the `:require_authenticated_user_and_org` live_session
authentication: required
roles: [pathways_studio_admin]
layer: instance administration
parent: INV-000
derived_from: none
---

## 1. Audience

These screens are for the administrator of one organization: the person who invites colleagues
into it, changes their roles or switches them off, and names the organization and its product.
They arrive on an occasional cadence, from the settings hint in the layout and from the account
menu, and they never act on another organization.

## 2. Access predicate

> **unverified** — No permission model exists for this repository, so the predicate is the
> expression the mount hook proves: signed in, organization context assigned
> (`GtfsPlannerWeb.AssignOrganization.on_mount(:default)`), and the `pathways_studio_admin`
> role, enforced by `GtfsPlannerWeb.EnsureRole.on_mount(:require_pathways_studio_admin)` in
> `GtfsPlannerWeb.Admin.UsersLive`.

Exceptions inside this inventory: none. Every row in this file is served by the same LiveView
session and the same role check.

## 3. Entry points

`/admin/users` is the organization's administration entry, linked from the settings hint in
`GtfsPlannerWeb.Navigation`. `/admin/users/invite` and `/admin/users/organization-settings` are
reached from links inside it. No path segment names an organization: the organization comes
from the assigned context, so one organization is administered at a time.

## 4. Screens

| ID | Screen | Route | Reached by | Status | Purpose |
|---|---|---|---|---|---|
| SCRN-048 | Members | `/admin/users` | all | undocumented | The organization's member collection, with status and role treatment per row |
| SCRN-049 | Invite a member | `/admin/users/invite` | all | undocumented | Send an invitation to a new member of this organization |
| SCRN-050 | Organization settings | `/admin/users/organization-settings` | all | undocumented | The organization's own name and product setting |

## 5. Journeys

None yet: the journey registry is written after this inventory.

## 6. Seams

| To inventory | Where | What carries across |
|---|---|---|
| INV-001 | The invitation email sent from SCRN-049 | The invite token only; the recipient arrives at `/users/accept_invite/:token` with no organization until they accept |
| INV-002 | The dashboard's administration link, and the layout's settings hint | The organization context, re-derived on the admin mount |
| INV-006 | The organization list a system administrator uses | The organization record; the two audiences share the same member table component but never the same screen |

`GtfsPlannerWeb.Admin.Components.member_data_view/1` is the single owner of member presentation
for this inventory and for INV-006, so the two surfaces render one table with one status
vocabulary. Sharing a component is not sharing a screen, and no row appears in both inventories.

## 7. Coverage

| Measure | Count |
|---|---|
| Screens in this inventory | 3 |
| Documented (a screen page exists) | 0 |
| Undocumented | 3 |
| Unverified | 0 |
| IDs issued in this inventory | 3 (SCRN-048 to SCRN-050) |

Next unused ID for the next run: SCRN-058. IDs are issued across the whole corpus, never per
file, and never reused.

## Open questions

- OQ-009 — `/admin/users/organization-settings` names "organization" but acts on the signed-in
  administrator's own organization, not on the tenant list. Confirm the configuration layer,
  rather than instance administration, is the right home for it. Owner: product owner. Open
  since 2026-10-01.
- OQ-010 — Two invite screens exist: SCRN-049 here and SCRN-055 in INV-006. Confirm both are
  reachable surfaces and that neither duplicates the other in practice. Owner: product owner.
  Open since 2026-10-01.

## Changelog

| Date | Version | Change | Author |
|---|---|---|---|
| 2026-10-01 | 1 | Initial rows SCRN-048 to SCRN-050 from the `:require_authenticated_user_and_org` live_session; partition unverified without a permission model | spec step 29 |
