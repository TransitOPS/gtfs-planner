# Authorization Roles — SpecOps Analysis

**Target:** `lib/gtfs_planner/authorization/`
**Source hash:** `7fb05bff818ee88831ea0d4506c0e26e3768c8f7d4e6be77d56cae22ef25abc0`
**Generated:** 2026-06-26

---

## 1. Purpose and Scope

Defines the canonical set of system and organization roles used for role-based access control (RBAC) in the Pathways Studio multi-tenant application. The module `GtfsPlanner.Authorization.Roles` is the single source of truth for what roles exist and what scope they operate at.

### Evidence

- `lib/gtfs_planner/authorization/roles.ex:1-9` — `@moduledoc` declares canonical role definitions for the Pathways Studio application
- `lib/gtfs_planner/accounts/user_org_membership.ex:11` — `alias GtfsPlanner.Authorization.Roles` for changeset validation
- `lib/gtfs_planner_web/ensure_role.ex:42-44` — Alias chain: `Accounts`, `UserOrgMembership`, `Organizations`

---

## 2. Role Hierarchy

Three roles are defined with exactly two scopes:

| Role Atom | Display Name | Scope | Description |
|---|---|---|---|
| `:administrator` | "Administrator" | `:system` | Manages organizations (tenants) in the multi-tenant system |
| `:pathways_studio_admin` | "Pathways Studio Admin" | `:organization` | Manages users within their organization |
| `:pathways_studio_editor` | "Pathways Studio Editor" | `:organization` | Full access to view and modify GTFS data |

There is no inheritance between roles. Each role is independently assigned and checked. The `:system` scope grants privileges that transcend any single organization; `:organization` scope privileges are always bounded by the current organization context.

### Evidence

- `lib/gtfs_planner/authorization/roles.ex:11-27` — `@roles` module attribute defines all three roles with `name`, `description`, `scope`
- `lib/gtfs_planner/authorization/roles.ex:116-119` — `list_by_scope/1` filters roles by `:system` or `:organization`
- `test/gtfs_planner/authorization/roles_test.exs:6-28` — Tests verify all three canonical keys and metadata fields exist

---

## 3. Role Storage and Assignment

### 3.1 Storage

Roles are stored as a **PostgreSQL array of strings** on the `user_org_memberships` join table (many-to-many between users and organizations). A single user can belong to multiple organizations with different roles in each. The `User` schema has **no role field** — roles are always contextual to an organization membership.

API keys also carry a `roles` array for machine-to-machine authorization.

### Evidence

- `priv/repo/migrations/20251223034106_create_user_org_memberships.exs:12` — `add :roles, {:array, :string}, default: []`
- `lib/gtfs_planner/accounts/user_org_membership.ex:26` — `field :roles, {:array, :string}, default: []`
- `lib/gtfs_planner/accounts/user.ex:30` — `has_many :memberships, GtfsPlanner.Accounts.UserOrgMembership` (User has no direct role field)
- `priv/repo/migrations/20251223034107_create_api_keys.exs:12` — `add :roles, {:array, :string}, default: "{}"`

### 3.2 Assignment Rules

| Scenario | Roles Assigned | Location |
|---|---|---|
| First user registration (bootstraps org + admin) | `["administrator"]` | `lib/gtfs_planner/accounts.ex:616-621` |
| Invite acceptance (normal user signup) | `["pathways_studio_editor"]` | `lib/gtfs_planner/accounts.ex:555-582` |
| Admin-created seed user | `["pathways_studio_admin", "pathways_studio_editor"]` | `priv/repo/create_admin_user.exs:31` |
| Runtime role update via admin UI | Variable (set by admin) | `lib/gtfs_planner/organizations.ex:324-339` |

### 3.3 Validation

The `UserOrgMembership` changeset validates that every role string in the array is a canonical role via `Roles.valid?/1`. Invalid roles are rejected with a descriptive error.

### Evidence

- `lib/gtfs_planner/accounts/user_org_membership.ex:46-63` — `validate_roles/1` calls `Roles.valid?/1` on each role string
- `test/gtfs_planner/authorization/roles_test.exs:52-72` — Tests for `valid?/1` with string input

---

## 4. Privilege Map

### 4.1 Administrator (`:system` scope)

| Privilege | Mechanism |
|---|---|
| Manage all organizations (CRUD) | `:require_system_administrator` hook on `/admin/organizations/*` routes |
| See "Organizations" nav tab | `is_administrator?(@current_user)` in navigation |
| No organization context required | Bypasses `AssignOrganization.on_mount` entirely |
| Post-login redirect to org management | `UserAuth.signed_in_path/2` returns `/admin/organizations` |
| Login allowed without org membership | `UserSessionController.create/2` gate `is_administrator?(user) \|\| fetch_user_organization(user)` |
| Can assign any role to any user in any org | Has full access to `OrganizationsLive` which can modify memberships |

### 4.2 Pathways Studio Admin (`:organization` scope)

| Privilege | Mechanism |
|---|---|
| Manage users within their organization | `:require_pathways_studio_admin` hook on `Admin.UsersLive` |
| See "Users" nav tab (with org context) | `has_role?(@user_roles, :pathways_studio_admin) && @current_organization` |
| Invite new users to organization | `/admin/users/invite` route under `UsersLive` |
| View and modify user roles within org | `UsersLive` exposes role assignment UI with org-scoped roles |
| Assignable roles restricted to org-scoped | `UsersLive.available_roles/0` returns only `pathways_studio_admin` and `pathways_studio_editor` |

### 4.3 Pathways Studio Editor (`:organization` scope)

| Privilege | Mechanism |
|---|---|
| View GTFS routes | `:require_gtfs_access` hook on `RoutesLive`, `RouteDetailLive` |
| View GTFS stations | `:require_gtfs_access` hook on `StopsLive`, `StopDetailLive` |
| View station diagrams, reports, reachability | `:require_gtfs_access` hook on diagram/report/reachability lives |
| View validation results | `:require_gtfs_access` hook on `ValidationResultLive` |
| Export GTFS data | `:require_gtfs_access` hook on `ExportLive` |
| Import GTFS data (write access) | `:require_gtfs_editor` hook on `ImportLive` (semantically identical to `:require_gtfs_access`) |
| See all GTFS nav tabs (Routes, Stations, Import, Export) | `has_role?(@user_roles, :pathways_studio_editor) && @current_organization && @current_gtfs_version` |
| See station diagram, report, reachability pages | Same role gating via navigation conditions |

### Evidence

- `lib/gtfs_planner_web/ensure_role.ex:67-87` — Named hook variants mapping hook names to role atoms
- `lib/gtfs_planner_web/ensure_role.ex:89-102` — `:require_system_administrator` cross-org check
- `lib/gtfs_planner_web/ensure_role.ex:104-135` — Generic `:require` hook with org context + role check
- `lib/gtfs_planner_web/components/navigation.ex:40-96` — Role-gated nav pill rendering
- `lib/gtfs_planner_web/live/admin/users_live.ex:11` — `on_mount {EnsureRole, :require_pathways_studio_admin}`
- `lib/gtfs_planner_web/live/admin/organizations_live.ex:13` — `on_mount {EnsureRole, :require_system_administrator}`
- `lib/gtfs_planner_web/live/gtfs/routes_live.ex:10` — `on_mount {EnsureRole, :require_gtfs_access}`
- `lib/gtfs_planner_web/live/gtfs/import_live.ex:13` — `on_mount {EnsureRole, :require_gtfs_editor}`

---

## 5. Authorization Enforcement Mechanisms

### 5.1 LiveView `on_mount` Hooks (Primary)

Authorization is enforced at the LiveView mount phase via named hooks on `GtfsPlannerWeb.EnsureRole`:

| Hook Name | Role Enforced | Special Behavior |
|---|---|---|
| `:require_system_administrator` | `"administrator"` in **any** membership | No org context required; queries all memberships |
| `:require_administrator` | `:administrator` in current org membership | Uses generic `:require` hook |
| `:require_pathways_studio_admin` | `:pathways_studio_admin` in current org | Uses generic `:require` hook |
| `:require_gtfs_access` | `:pathways_studio_editor` in current org | Uses generic `:require` hook |
| `:require_gtfs_editor` | `:pathways_studio_editor` in current org | Uses generic `:require` hook (identical to `:require_gtfs_access`) |

The generic `:require` hook (`ensure_role.ex:104-135`):
1. Reads `role_spec` from socket assigns (defaults to `:administrator`)
2. Extracts `user_id` from `@current_user` and `organization_id` from `@current_organization`
3. Fetches the membership via `Accounts.get_user_org_membership/2`
4. Calls `has_role?(membership.roles, role_spec)` for the role check
5. On failure: flashes "not authorized" and redirects to `/admin/organizations`

### 5.2 `is_administrator?/1` Helper

`GtfsPlannerWeb.UserAuth.is_administrator?/1` is a cross-cutting system-admin check:
- Accepts a `User` struct: scans all memberships for `"administrator"` string
- Accepts a `UserOrgMembership` struct: checks `"administrator" in user.roles`
- Used in: login gating, post-login redirect, `AssignOrganization` bypass, navigation, dashboard

### 5.3 `ensure_role/2` Plug (Unused)

A plug function exists at `ensure_role.ex:162-218` designed for API pipeline enforcement. It checks roles for either the current user or the current API key against the current organization. However, it is **not wired into any router pipeline**. The current API pipelines (`api_session`) only enforce authentication and organization assignment — no role checks.

### 5.4 `has_role?/2` Role Matching

The `roles_match_spec/2` private function supports four matching modes:
- **Single role atom**: `has_role?(["administrator"], :administrator)` → checks `"administrator" in roles`
- **Any of list**: `has_role?(roles, any: [:admin, :editor])` → `Enum.any?`
- **All of list**: `has_role?(roles, all: [:admin, :editor])` → `Enum.all?`
- **Nil spec**: `has_role?(any_roles, nil)` → `true` (membership-only gate, any role passes)

### Evidence

- `lib/gtfs_planner_web/ensure_role.ex:63-135` — All `on_mount` clauses
- `lib/gtfs_planner_web/ensure_role.ex:242-267` — `has_role?/2`, `roles_match_spec/2`, `has_administrator_role?/1`
- `lib/gtfs_planner_web/user_auth.ex:95-112` — `is_administrator?/1`
- `lib/gtfs_planner_web/user_auth.ex:325-329` — `signed_in_path/2` admin redirect
- `lib/gtfs_planner_web/router.ex:76-141` — `live_session` definitions with hook assignments
- `lib/gtfs_planner_web/router.ex:150-155` — `api_session` pipeline (no role plug)
- `lib/gtfs_planner_web/router.ex:173-183` — Protected API routes (authentication only, no role enforcement)

---

## 6. Navigation/UI Visibility Mapping

The navigation bar in `components/navigation.ex` is the primary UI mechanism for role-based visibility:

| Nav Pill | Visibility Condition | Icon |
|---|---|---|
| Organizations | `is_administrator?(@current_user)` | None |
| Users | `has_role?(@user_roles, :pathways_studio_admin) && @current_organization` | `hero-user-group` |
| Routes | `has_role?(@user_roles, :pathways_studio_editor) && @current_organization && @current_gtfs_version` | `hero-arrow-path` |
| Stations | Same as Routes | `hero-map-pin` |
| Import | Same as Routes | `hero-arrow-down-tray` |
| Export | Same as Routes | `hero-arrow-up-tray` |

**Key insight:** The GTFS nav tabs require three conditions simultaneously: editor role + organization context + a selected GTFS version. This means a user who is an editor but has no GTFS version loaded will see no GTFS nav tabs.

The dashboard (`dashboard_live.ex`) conditionally shows:
- "Manage Organizations" button → only if `@is_administrator`
- "Administrator" role badge → only if `@is_administrator`
- Organization name → for non-admin users with org context

### Evidence

- `lib/gtfs_planner_web/components/navigation.ex:37-98` — `top_nav/1` component template
- `lib/gtfs_planner_web/components/navigation.ex:127-130` — `has_role?/2` private helper
- `lib/gtfs_planner_web/live/dashboard_live.ex:103-126` — Conditional admin/org rendering
- `test/gtfs_planner_web/live/access_control_test.exs:181-205` — Tests for admin and editor nav visibility

---

## 7. Admin vs Organization-Role Distinction

The system draws a hard boundary between the `administrator` (system-scoped) role and the two `organization`-scoped roles:

| Aspect | `administrator` | Org-scoped roles |
|---|---|---|
| **Org context required** | No — bypasses `AssignOrganization` entirely | Yes — `AssignOrganization` must have set `@current_organization` |
| **`@user_roles` assign** | Empty list `[]` | Populated from membership record |
| **Post-login destination** | `/admin/organizations` | `/` (dashboard) |
| **Session org** | Not set in session | Set in session by `UserAuth` |
| **Role check method** | `is_administrator?/1` (cross-membership scan) | `has_role?(user_roles, spec)` (single-membership check) |
| **Hook used** | `:require_system_administrator` (dedicated) | `:require` (generic, with org context) |
| **Nav visibility** | "Organizations" pill (system-level) | "Users" (admin) or GTFS tabs (editor) |
| **DB query** | `list_user_org_memberships()` → `Enum.any?` | `get_user_org_membership(user_id, org_id)` → single lookup |

The `AssignOrganization.on_mount` hook (`assign_organization.ex:45-46`) short-circuits for administrators with `{:cont, socket}` — no organization is fetched, no `@user_roles` are assigned, no `@current_organization` is set. This means administrator pages cannot rely on organization-scoped assigns.

### Evidence

- `lib/gtfs_planner_web/assign_organization.ex:44-46` — Admin bypass
- `lib/gtfs_planner_web/assign_organization.ex:28-30` — Dashboard context extraction differs by admin status
- `lib/gtfs_planner_web/ensure_role.ex:89-102` — System admin hook (cross-org query)
- `lib/gtfs_planner_web/ensure_role.ex:104-135` — Org-scoped generic hook
- `lib/gtfs_planner_web/ensure_role.ex:261-266` — `has_administrator_role?/1` cross-org query
- `lib/gtfs_planner_web/user_auth.ex:114-122` — `maybe_set_organization_in_session` skips org for admins

---

## 8. Data Flow

```
User Login
  │
  ├── UserSessionController.create/2
  │     └── Gate: is_administrator?(user) || fetch_user_organization(user)
  │
  ├── UserAuth.log_in_user/2
  │     ├── maybe_set_organization_in_session/2 → admins skip, others get org_id
  │     └── signed_in_path/2 → admin→"/admin/organizations", other→"/"
  │
  ├── LiveView mount
  │     ├── UserAuth.ensure_authenticated → sets @current_user
  │     ├── AssignOrganization.on_mount
  │     │     ├── Admin? → {:cont, socket} (no org/roles set)
  │     │     └── Non-admin? → fetch org, fetch membership.roles → assign @current_organization, @user_roles
  │     ├── AssignGtfsVersion.on_mount (GTFS routes only)
  │     │     └── Sets @current_gtfs_version, @available_versions
  │     └── EnsureRole.on_mount (per-LiveView)
  │           ├── :require_system_administrator → has_administrator_role?(user_id)
  │           └── :require → get_user_org_membership(user_id, org_id) → has_role?(roles, spec)
  │
  └── Template render
        └── Layouts.app(user_roles={@user_roles})
              └── Navigation.top_nav(user_roles={@user_roles}, ...)
                    ├── is_administrator?(@current_user) → "Organizations" pill
                    ├── has_role?(@user_roles, :pathways_studio_admin) → "Users" pill
                    └── has_role?(@user_roles, :pathways_studio_editor) → GTFS pills
```

### Evidence

- `lib/gtfs_planner_web/controllers/user_session_controller.ex:7-24` — Login gating
- `lib/gtfs_planner_web/user_auth.ex:325-329` — `signed_in_path/2`
- `lib/gtfs_planner_web/user_auth.ex:114-122` — `maybe_set_organization_in_session`
- `lib/gtfs_planner_web/assign_organization.ex:41-50` — Admin bypass
- `lib/gtfs_planner_web/assign_organization.ex:52-108` — Org+roles assignment
- `lib/gtfs_planner_web/ensure_role.ex:89-135` — Role enforcement hooks
- `lib/gtfs_planner_web/components/navigation.ex:37-98` — Nav rendering
- `lib/gtfs_planner_web/components/layouts.ex:84-92` — Layout passes user_roles to nav

---

## 9. API Authorization (Current State)

API authentication is enforced via the `api_session` pipeline (`router.ex:150-155`), which runs:
1. `VerifyApiSession` — validates Bearer token, sets `@current_api_key` and optionally `@current_user`
2. `AssignApiOrganization` — sets `@current_organization` from the API key or user session

**No role-based authorization** is applied to any API endpoint. The `ensure_role/2` plug exists but is not wired. Every authenticated API caller with a valid session and organization membership can access all protected API endpoints regardless of their role.

### Evidence

- `lib/gtfs_planner_web/router.ex:150-155` — `api_session` pipeline definition (no role plug)
- `lib/gtfs_planner_web/router.ex:173-183` — All protected API routes in a single `api_session` scope
- `lib/gtfs_planner_web/ensure_role.ex:162-218` — `ensure_role/2` plug (exists but unused)

---

## 10. Edge Cases and Error Handling

| Scenario | Behavior |
|---|---|
| User with no memberships logs in | Rejected at login gate unless administrator |
| Admin logs in but has no org in session | Allowed — `AssignOrganization` short-circuits |
| User's membership has empty roles `[]` | `has_role?([], spec)` → `false` (line 248 handles `nil`, empty list falls through to single-atom check which fails) |
| User's membership is `nil` (no record) | `AssignOrganization` sets `@user_roles = []`; generic `:require` hook fails at membership fetch |
| `roles_match_spec(nil, _)` | Returns `false` (line 248) |
| `roles_match_spec(roles, nil)` when `is_list(roles)` | Returns `true` — membership-only gate |
| Deactivated user attempts access | `AssignOrganization` detects deactivation, deletes session token, redirects to login with error |
| Organization not found in session | `AssignOrganization` redirects to login with "Organization not found" |
| No organization in session (non-admin) | `AssignOrganization` redirects to login with "no organization assigned" |
| Invalid role string passed to `valid?/1` | Uses `String.to_existing_atom/1` (safe, no atom leakage); `ArgumentError` rescued, returns `false` |
| `:require_system_administrator` with no `@current_user` | Redirects to `/` with flash error |
| `:require` with missing `@current_user` or `@current_organization` | `with` block fails, redirects to `/admin/organizations` with flash error |

### Evidence

- `lib/gtfs_planner/authorization/roles.ex:59-71` — `valid?/1` with string input using `String.to_existing_atom/1`
- `lib/gtfs_planner_web/ensure_role.ex:248-258` — `roles_match_spec/2` clauses for nil, single atom, any:, all:
- `lib/gtfs_planner_web/assign_organization.ex:57-71` — Deactivation check redirects to login
- `lib/gtfs_planner_web/assign_organization.ex:100-117` — Missing org handling
- `lib/gtfs_planner_web/ensure_role.ex:89-102` — System admin error redirect
- `lib/gtfs_planner_web/ensure_role.ex:126-133` — Generic require error redirect
- `lib/gtfs_planner_web/controllers/user_session_controller.ex:7-31` — Login gate

---

## 11. Assumptions, Risks, and Ambiguities

### Assumptions

1. **No role inheritance.** Each role is independently checked. Having `pathways_studio_admin` does not imply `pathways_studio_editor` privileges. This is confirmed by the `available_roles/0` function in `UsersLive` which treats them as separate checkboxes.
2. **Admin is cross-org.** The `:require_system_administrator` hook scans all memberships, not just one. An administrator assigned in any organization has system-wide admin access.
3. **Roles are additive.** A user can hold multiple roles in the same organization (e.g., both `pathways_studio_admin` and `pathways_studio_editor`). The `has_role?` single-atom check is satisfied if any role matches.
4. **API routes do not need role enforcement.** The current design assumes API consumers are trusted clients authenticated via API keys or user tokens with valid organization membership. (See Risk #1.)

### Risks

1. **Unused `ensure_role/2` plug.** The plug function (`ensure_role.ex:162-218`) is fully implemented and supports the same rich matching as the LiveView hooks, but is **not wired into any API pipeline**. API endpoints accessible at `/api/v1/versions/:version/stations` etc. have no role enforcement — any authenticated user or API key with org membership can access them. This is a potential authorization gap if API consumers should be role-restricted.

2. **`require_gtfs_access` and `require_gtfs_editor` are semantically identical.** Both map to `:pathways_studio_editor`. One is named "access" (suggesting read) and the other "editor" (suggesting write), but they enforce the same role check. The `import_live.ex` uses `:require_gtfs_editor` while other GTFS lives use `:require_gtfs_access`, but they are interchangeable. If a write-specific role is needed, this is not implemented.

3. **Empty roles array edge case.** `roles_match_spec([], :administrator)` falls through to the single-atom clause `Atom.to_string(role) in roles` → `false`. This is correct behavior but implicit — there is no explicit guard for empty lists.

4. **No explicit role hierarchy test for admin+editor.** An administrator can hold the `administrator` role in one org and no roles in another. If an admin wants to view GTFS data, they need an org-scoped role too, which contradicts the idea of "system-wide" access. The admin bypass in `AssignOrganization` means admins never get `@user_roles` set, so they cannot see GTFS nav tabs even if they're meant to.

5. **String-based role checks throughout.** Authorization checks compare against the string `"administrator"` rather than the atom `:administrator`. A typo in a role string stored in the database (if validation is bypassed) would silently fail checks.

### Ambiguities

1. **Should system administrators have implicit access to all org-scoped features?** Currently, an administrator with no org-level membership cannot access any GTFS features or manage users within an organization. The admin bypass in `AssignOrganization` means no `@user_roles` or `@current_organization` is set, so no GTFS or user management nav pills appear. This may be intentional (admin manages tenants, not data) or a gap.

2. **Is the `ensure_role/2` plug dead code or planned future use?** The plug is documented with DSL-style examples in the router and module docs, suggesting it was designed for use, but no pipeline currently invokes it. The `api_session` pipeline lacks any role enforcement entirely.

3. **What is the intended difference between `:require_gtfs_access` and `:require_gtfs_editor`?** Both use the same role (`:pathways_studio_editor`). The naming suggests a read vs. write distinction that does not exist in the current implementation. Only `ImportLive` uses `:require_gtfs_editor`; all other GTFS LiveViews use `:require_gtfs_access`.

4. **Can a user be a system administrator in one org and a regular editor in another?** Yes, because roles are stored per-membership. The `is_administrator?/1` check scans all memberships, so the user would be treated as an admin system-wide. However, the org-scoped hooks (`:require`) check only the specific org's membership — creating a potential mismatch where the user has admin privileges but cannot access org-scoped features in a non-admin org.
