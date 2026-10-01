---
id: INV-000
title: Screen inventory
type: inventory-index
status: draft
owner: gtfs-planner
last_reviewed: 2026-10-01
review_interval_days: 90
verified_against: 7c55d705
inventories: [INV-001, INV-002, INV-003, INV-004, INV-005, INV-006, INV-007]
---

## 1. How this is partitioned

GTFS Planner has five audiences that can never see each other's screens: an anonymous
visitor signing in or accepting an invitation, a signed-in member working a feed, the
same member occasionally changing how the feed behaves, an organization administrator
managing the organization's members, and a system administrator managing organizations
themselves. One further group — the design-system reference pages — is signed in but
carries no organization and no product role, so it stands apart from every product
audience. The partition rule applied is the access predicate, in the order the router
and the LiveView mount hooks prove it: session gate first (`GtfsPlannerWeb.UserAuth`),
then organization context (`GtfsPlannerWeb.AssignOrganization`), then role
(`GtfsPlannerWeb.EnsureRole`), then layer by cadence. Every registered route appears in
exactly one inventory, in the shared inventory, or in the excluded list with a reason.

The organization product field (`planner` or `pathways`) does **not** partition anything.
`GtfsPlannerWeb.ProductSurfaces` hides areas from navigation and branding as a usability
matter and never denies access, so a Pathways Studio member who deep-links reaches the
same screens a planner member does. It is recorded as a seam, not an axis.

**No permission model exists.** `docs/permissions/permission-model.md` is absent, so the
axes below were derived directly from the router and the mount hooks, and this partition
is **unverified** against a permission model. Re-run `build-permission-model` and
re-derive if the two drift.

## 2. Axes

| Axis | Values | Proof | Boundary |
|---|---|---|---|
| Authentication | public / authenticated | `GtfsPlannerWeb.UserAuth` `on_mount(:redirect_if_user_is_authenticated)` on the `:redirect_if_user_is_authenticated` live_session in `lib/gtfs_planner_web/router.ex`; `on_mount(:ensure_authenticated)` on every other live_session | hard |
| Organization context | required / optional / none | `GtfsPlannerWeb.AssignOrganization` `on_mount(:default)` (required, redirects on missing context, bypassed for system administrators) vs `on_mount(:optional)` on `DashboardLive` and `UserSettingsLive`; `:design` mounts no organization hook at all | hard |
| Role family | system administrator / pathways studio admin / pathways studio editor | `GtfsPlanner.Authorization.Roles` `@roles` (three atoms, scopes `:system` and `:organization`); `GtfsPlannerWeb.EnsureRole.on_mount(:require_system_administrator)` checks the `administrator` role across any membership and halts; `Admin.UsersLive` uses `on_mount {GtfsPlannerWeb.EnsureRole, :require_pathways_studio_admin}`; every `Gtfs.*Live` uses `:require_gtfs_access` (`:pathways_studio_editor`) | hard / firm |
| Layer | operation / configuration / instance administration / account and identity | `live_session :gtfs_routes` mixes both layers, so the split is by area inside one route family: `/gtfs/:version/settings*` pages mutate reference data and are visited occasionally (`Gtfs.SettingsLive`, `Gtfs.FaresLive`, `Gtfs.GaragesLive`, `Gtfs.FleetLive`), while the rest act on feed records daily; `/admin/organizations*` acts on tenants themselves | firm |
| Organization product | `planner` / `pathways` | `GtfsPlannerWeb.ProductSurfaces.visible?/2` and `@pathways_hidden` — "Hiding only; never an access check" | soft, not a partition; recorded as a seam |

## 3. The inventories

| ID | Inventory | Audience | Access predicate | Screens | File |
|---|---|---|---|---|---|
| INV-001 | Public sign-in and onboarding | A visitor with no session: signs in, resets a password, confirms an email address, accepts an invitation, or completes first-admin bootstrap | `current_user` is nil (`UserAuth` `on_mount(:redirect_if_user_is_authenticated)` halts an already-signed-in visitor) | 6 | `docs/inventories/public-authentication-screens.md` |
| INV-002 | Shared account and identity | Any signed-in member, of any role and either organization product: the landing page and the user's own settings | signed in; organization context optional (`AssignOrganization` `on_mount(:optional)`) | 2 | `docs/inventories/shared-account-screens.md` |
| INV-003 | GTFS Planner — operation | A signed-in organization member doing the daily feed work: routes, calendars, patterns, schedules, stops and stations, blocks, runs, flex, import, export, validation results | signed in; organization context required; membership exists; role `pathways_studio_editor` (`EnsureRole.on_mount(:require_gtfs_access)` on each `Gtfs.*Live`) | 29 | `docs/inventories/gtfs-operation-screens.md` |
| INV-004 | GTFS Planner — configuration | The same member, occasionally, changing how the feed behaves: feed details, agencies, fares, garages, fleet, export defaults, section settings | signed in; organization context required; membership exists; role `pathways_studio_editor` | 10 | `docs/inventories/gtfs-configuration-screens.md` |
| INV-005 | Organization administration | A `pathways_studio_admin` managing the organization's members and its organization-level settings | signed in; organization context required; role `pathways_studio_admin` (`Admin.UsersLive` `on_mount`) | 3 | `docs/inventories/organization-administration-screens.md` |
| INV-006 | Instance administration | A system administrator provisioning and inspecting organizations | signed in; holds `administrator` in any membership (`EnsureRole.on_mount(:require_system_administrator)`); no organization context required | 5 | `docs/inventories/instance-administration-screens.md` |
| INV-007 | Design system reference | The design system pages themselves, reachable by any signed-in user with no organization and no product role | signed in only (`:require_authenticated_user_design` live_session) | 2 | `docs/inventories/design-system-screens.md` |

No layer is absent except onboarding-as-configuration: first-admin bootstrap is small
enough to sit in the public inventory rather than standing alone.

## 4. Shared surfaces

| Screen | Route | Owned by | Cross-referenced from |
|---|---|---|---|
| Dashboard | `/` | INV-002 | INV-001 (post-sign-in landing), INV-003, INV-004, INV-005, INV-006, INV-007 |
| User settings | `/users/settings` | INV-002 | INV-001 (password and email confirmation), INV-003, INV-004, INV-005, INV-006, INV-007 |

These two screens are reachable from every inventory and appear in exactly one of them.
A screen that appears twice without explanation would be a partition error.

## 5. Seams

| Route or crossing | Inventories | Mechanism | Notes |
|---|---|---|---|
| `/gtfs/:version/*` | INV-003, INV-004 | `GtfsPlannerWeb.ProductSurfaces.visible?/2` with `@pathways_hidden` in `lib/gtfs_planner_web/product_surfaces.ex`; `GtfsPlannerWeb.Components.Navigation` and `GtfsPlannerWeb.Layouts` read it for branding | The organization product field hides Operations, Flex, feed settings, fares, garages, fleet and export from Pathways Studio members' navigation and swaps the logo and product name. It never denies a route: a Pathways Studio member who deep-links reaches every INV-003 and INV-004 screen. Not a partition; record the same route once, in both inventories' navigation notes. |
| `/gtfs/:version/settings/fares`, `/rules`, `/checks` | INV-004 | One LiveView (`Gtfs.FaresLive`) with three actions; the tab links patch between literal paths declared ahead of `/gtfs/:version/settings/:section` | One component tree, three screens. `settings/:section` is a catch-all slug route, so the literals must stay declared first. |
| `/gtfs/:version/stops/:stop_id/evolutions` and `/evolutions/access` | INV-003 | One LiveView (`Gtfs.PathwayEvolutionsLive`) at two routes | Shared mounted station and socket; the `?date`/`?time` params name the service moment. |
| `/gtfs/:version/calendars/new` and `/calendars/show` | INV-003 | One LiveView (`Gtfs.CalendarLive`); the service ID travels in a query parameter rather than a path segment | Imported IDs containing slashes, percent signs, spaces or the words `new`/`show` cannot collide with a path segment. |
| `/gtfs/:version/flex/:service` and `/flex/:service/area` | INV-003 | One LiveView (`Gtfs.FlexServiceLive`); the area editor is an action on the service page, not its own route | The draft survives the patch. |
| `/gtfs/:version/routes/:route_id/patterns/compare` | INV-003 | Its own LiveView (`Gtfs.RoutePatternCompareLive`), declared before `/patterns/:route_pattern_id` | Ordering is load-bearing; `compare` would otherwise be read as a pattern ID. |
| `/gtfs/:version/settings/:section` | INV-004 | `Gtfs.SettingsLive` section action on one path | A section slug, not a screen of its own; the named sections have literal routes. |
| `/gtfs/:version/rosters` | INV-003 | `Gtfs.ComingSoonLive` placeholder | A registered placeholder with no implementation. Kept in the operation inventory and marked unverified. |

## 6. Coverage

| Measure | Count |
|---|---|
| Routes registered | 79 |
| Screens inventoried | 57 |
| IDs issued | 0 (issued per row when the inventories are written) |
| Shared | 2 |
| Excluded (with reason) | 22 |
| **Unassigned** | 0 |

Every unassigned route: none. The 79 registered routes account for as 57 LiveView page
routes, 11 `/api/v1` companion API routes, 3 LiveView socket transports under `/live`, and
8 controller-only endpoints. Reasons are in section 8.

Regenerate the route list with:

```txt
MIX_ENV=test mix phx.routes > <route-list-file>
```

Keep the route list outside the committed documentation; commit the totals above, not the
generated listing.

## 7. Ambiguous boundaries

| Screen or group | Reading A | Reading B | Placed in | Owner |
|---|---|---|---|---|
| `/design` and `/design/:page` | An internal design reference, not a product surface: any signed-in user reaches it and it holds no organization context | A signed-in member's account surface, sitting next to `/users/settings` in the same router scope | INV-007 | product owner |
| `/gtfs/:version/rosters` | A placeholder that belongs in operation with its Blocks and Runs neighbours, per the navigation grouping | An abandoned route that should be excluded like the controller-only endpoints | INV-003, marked unverified | product owner |
| `/admin/users/organization-settings` | Configuration for the organization's members and product, reached by an organization admin | Instance administration, because it names "organization" | INV-005 | product owner |
| `/gtfs/:version/export-runs/:run_id/download` | A screen an editor reaches from the export runs table | A download endpoint, excluded with the other non-LiveView responses | Excluded (section 8) | product owner |
| Product field `planner` vs `pathways` | Two products with their own journeys, deserving their own operation inventories | One product with hidden areas, since nothing denies the hidden routes | One INV-003/INV-004 pair, recorded as a seam | product owner |

## 8. Excluded

| Route or group | Reason |
|---|---|
| `/api/v1/*` (11 routes) | Companion JSON API for materialization and pathway exports; no HTML, no screen, and documented separately in `docs/api-authentication.md` and `docs/api-pathways-export.md`. |
| `/health` | Liveness probe consumed by the orchestrator, not by a person. |
| `/live/websocket`, `/live/longpoll` (3 routes) | LiveView framework transports injected by `Phoenix.LiveView.Socket`; they render no screen. |
| `POST /users/log_in`, `DELETE /users/log_out`, `POST /users/update_password` | Session and credential actions that respond to a form and redirect; the screens that host them are `/users/log_in` (INV-001) and `/users/settings` (INV-002). |
| `GET /users/settings/confirm_email/:token` | Token confirmation landing that confirms and redirects to `/users/settings` (INV-002); the token URL is state, not a screen. |
| `/map/tiles/:style/:z/:x/:y`, `/map/buildings` | Map raster and building geometry fetched by the screens that render a map; no standalone page. |
| `GET /gtfs/:version/export-runs/:run_id/download` | File download behind the `:require_gtfs_editor` pipeline; reached from the export surface (INV-003). |
| Redirect-only and dev-only routes | None registered in this environment: the `:dev_routes` LiveDashboard and mailbox scopes compile out when `Application.compile_env(:gtfs_planner, :dev_routes)` is false, which is the case in test and production. |

## Findings against existing documentation

- `docs/routes-and-access.md` disagrees with the router and is not copied here. It
  documents `/organizations`, `/organizations/new`, `/organizations/:org_id`,
  `/organizations/:org_alias/admin/users`, `/organizations/:org_alias/admin/users/new`,
  `/organizations/:org_alias/admin/users/:user_id` and `/profile`. The router registers
  `/admin/organizations*`, `/admin/users`, `/admin/users/invite`,
  `/admin/users/organization-settings` and `/users/settings`. None of the paths that
  document names is registered.
- That document also states the system `administrator` "has access to `/organizations`
  routes only" and cannot reach GTFS surfaces. In code `AssignOrganization.on_mount(:default)`
  lets a system administrator past the organization gate while `AssignGtfsVersion` halts
  them for lack of an organization, so the outcome matches while the named paths do not.
- `docs/routes-and-access.md` does not mention the design-system pages or the
  `pathways_studio_editor` role requirement that every `Gtfs.*Live` enforces through its
  own `on_mount`, rather than through the router pipeline.

## Changelog

| Date | Version | Change | Author |
|---|---|---|---|
| 2026-10-01 | 1 | Initial index: axes derived from the router and mount hooks, partition unverified without a permission model | spec step 28 |