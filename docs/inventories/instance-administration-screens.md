---
id: INV-006
title: Instance administration screens
type: inventory
status: draft
owner: gtfs-planner
last_reviewed: 2026-10-01
review_interval_days: 90
verified_against: 7c55d705
predicate: unverified — signed in and holding the `administrator` role in any membership; `GtfsPlannerWeb.EnsureRole.on_mount(:require_system_administrator)` in the `:administrator_only` live_session, with no organization context assigned
authentication: required
roles: [administrator]
layer: instance administration
parent: INV-000
derived_from: none
---

## 1. Audience

These screens are for the system administrator: the person who provisions organizations on the
instance, opens one to see its record and its members, edits its details, and invites somebody
into it. This audience is the rarest of the five and the only one that acts on tenants rather
than on feed data, so the visits are infrequent and administrative rather than editorial.

## 2. Access predicate

> **unverified** — No permission model exists for this repository, so the predicate is the
> expression the mount hook proves: signed in and holding `administrator` in any membership,
> enforced by `GtfsPlannerWeb.EnsureRole.on_mount(:require_system_administrator)` over
> `GtfsPlanner.Authorization.Roles`' `:system` scope in the `:administrator_only`
> live_session.

Exceptions inside this inventory: none. The organization context is deliberately not assigned on
this session, which is what separates it from INV-005.

## 3. Entry points

`/admin/organizations` is the instance administrator's entry, reached from the "Organizations"
item that `GtfsPlannerWeb.Navigation` renders after the divider for system administrators, and
from the dashboard's organization-administrator state. Every other row is reached from a link
inside the organization list or inside one organization.

## 4. Screens

| ID | Screen | Route | Reached by | Status | Purpose |
|---|---|---|---|---|---|
| SCRN-051 | Organizations | `/admin/organizations` | all | undocumented | The instance's organizations, each opening independently of the others |
| SCRN-052 | New organization | `/admin/organizations/new` | all | undocumented | Provision a new organization on the instance |
| SCRN-053 | Organization detail | `/admin/organizations/:org_id` | all | undocumented | One organization's record and its members |
| SCRN-054 | Edit organization | `/admin/organizations/:org_id/edit` | all | undocumented | Change one organization's details |
| SCRN-055 | Invite into organization | `/admin/organizations/:org_id/invite` | all | undocumented | Invite somebody into one named organization |

## 5. Journeys

None yet: the journey registry is written after this inventory.

## 6. Seams

| To inventory | Where | What carries across |
|---|---|---|
| INV-001 | The invitation email sent from SCRN-055 | The invite token only; the recipient arrives at `/users/accept_invite/:token` with no organization until they accept |
| INV-002 | The dashboard's system-administrator state | Nothing but the session; the dashboard reads organization context as optional while this session assigns none |
| INV-005 | Both audiences read the same member table | `GtfsPlannerWeb.Admin.Components.member_data_view/1`; one component, two surfaces, no shared row |

`GtfsPlannerWeb.Admin.OrganizationsLive` owns three independent read states — the organization
index, the requested organization and its members — so one failed read never hides the rest of
the page.

## 7. Coverage

| Measure | Count |
|---|---|
| Screens in this inventory | 5 |
| Documented (a screen page exists) | 0 |
| Undocumented | 5 |
| Unverified | 0 |
| IDs issued in this inventory | 5 (SCRN-051 to SCRN-055) |

Next unused ID for the next run: SCRN-058. IDs are issued across the whole corpus, never per
file, and never reused.

## Open questions

- OQ-011 — SCRN-053 shows one organization's members, and INV-005 manages an organization's
  members from the other side. Is the overlap between the two audiences intentional for a
  system administrator who is also an organization administrator? Owner: product owner. Open
  since 2026-10-01.
- OQ-012 — A system administrator passes the organization gate everywhere else, then halts at
  the GTFS surfaces for lack of an organization. Confirm the dashboard is the intended single
  landing surface for that person. Owner: product owner. Open since 2026-10-01.

## Changelog

| Date | Version | Change | Author |
|---|---|---|---|
| 2026-10-01 | 1 | Initial rows SCRN-051 to SCRN-055 from the `:administrator_only` live_session; partition unverified without a permission model | spec step 29 |
