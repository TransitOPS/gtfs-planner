---
id: INV-001
title: Public sign-in and onboarding screens
type: inventory
status: draft
owner: gtfs-planner
last_reviewed: 2026-10-01
review_interval_days: 90
verified_against: 7c55d705
predicate: unverified — current_user is nil; `GtfsPlannerWeb.UserAuth` `on_mount(:redirect_if_user_is_authenticated)` halts an already-signed-in visitor
authentication: public
roles: []
layer: account and identity
parent: INV-000
derived_from: none
---

## 1. Audience

These screens are for a visitor with no session. They come here to sign in, to recover a
forgotten password, to confirm an email address, to finish an invitation they were sent, or —
once, on an empty instance — to name the first organization and create its administrator login.
Every one of them redirects away the moment a session exists, so a signed-in member never sees
them.

## 2. Access predicate

> **unverified** — No permission model exists for this repository, so the predicate is stated
> as the expression the router and mount hooks prove, not as a permission-model ID:
> `current_user` is nil, proven by the `:redirect_if_user_is_authenticated` pipeline's
> `GtfsPlannerWeb.UserAuth.on_mount(:redirect_if_user_is_authenticated)` in
> `lib/gtfs_planner_web/router.ex`.

Exceptions inside this inventory: `/first` is reachable only while the instance has no
organization, which narrows it to an empty installation; every other row is reachable by any
anonymous visitor.

## 3. Entry points

The sign-in form is the application's front door: an unauthenticated request to any protected
page lands on `/users/log_in`. `/users/reset_password` is reached from that form's "Forgot your
password?" link and from the rejected-credentials message. `/users/reset_password/:token` and
`/users/accept_invite/:token` are reached only from the link in the emailed message.
`/users/confirm/:token` is reached only from the confirmation email. `/first` is reached by
signing in as the first user on an instance with no organization.

## 4. Screens

| ID | Screen | Route | Reached by | Status | Purpose |
|---|---|---|---|---|---|
| SCRN-001 | First-admin setup | `/first` | any visitor on an instance with no organization | undocumented | Name the organization and create its administrator login |
| SCRN-002 | Log in | `/users/log_in` | any visitor | undocumented | Sign in with an email address and password |
| SCRN-003 | Reset your password | `/users/reset_password` | any visitor | undocumented | Request the emailed link that starts a password reset |
| SCRN-004 | Choose a new password | `/users/reset_password/:token` | any visitor holding a reset link | undocumented | Set the password a reset link authorizes, then sign in |
| SCRN-005 | Confirm email | `/users/confirm/:token` | any visitor holding a confirmation link | unverified | Confirm the address from the email, then redirect to log in |
| SCRN-006 | Set password | `/users/accept_invite/:token` | any visitor holding an invitation link | undocumented | Choose the password that finishes setting up an invited account |

## 5. Journeys

None yet: the journey registry is written after this inventory.

## 6. Seams

| To inventory | Where | What carries across |
|---|---|---|
| INV-002 | `POST /users/log_in` from SCRN-002 | The session only; the organization and version context are assigned fresh on mount, so nothing from a public screen is carried |
| INV-005 | Invitation link in an email to SCRN-006 | The invite token only; the new member arrives with no organization until they sign in and accept the membership |

The session actions themselves — `POST /users/log_in`, `POST /users/update_password`,
`DELETE /users/log_out` and `GET /users/settings/confirm_email/:token` — are controller-only
responses and are excluded from every inventory; the screens that host them are rows here and
in INV-002.

## 7. Coverage

| Measure | Count |
|---|---|
| Screens in this inventory | 6 |
| Documented (a screen page exists) | 0 |
| Undocumented | 5 |
| Unverified | 1 (SCRN-005) |
| IDs issued in this inventory | 6 (SCRN-001 to SCRN-006) |

Next unused ID for the next run: SCRN-058. IDs are issued across the whole corpus, never per
file, and never reused.

SCRN-005 renders no markup of its own: `GtfsPlannerWeb.UserConfirmationLive.mount/3` calls
`Accounts.confirm_user/1` and redirects to `/users/log_in` with a flash in both outcomes. It is
carried as a row because it is a registered page route with a distinct audience story, and it is
marked `unverified` rather than `undocumented` because the index has not yet decided whether it
is a screen or an excluded token action.

## Open questions

- OQ-001 — Is `/users/confirm/:token` a screen or an excluded token action, given it renders
  nothing and `/users/settings/confirm_email/:token` is excluded as one? Owner: product owner.
  Open since 2026-10-01.
- OQ-002 — Does first-admin bootstrap belong in the public inventory or in a configuration
  inventory of its own? The index places it here because it is reached without a session.
  Owner: product owner. Open since 2026-10-01.

## Changelog

| Date | Version | Change | Author |
|---|---|---|---|
| 2026-10-01 | 1 | Initial rows SCRN-001 to SCRN-006 from the router's `:redirect_if_user_is_authenticated` live_session; partition unverified without a permission model | spec step 29 |
