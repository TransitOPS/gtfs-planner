# Authorization Roles Agent Doc

Source target: `lib-gtfs-planner-authorization`
Scope: Defines the canonical system and organization roles used for administration and GTFS editing access control.
Deep analysis: [`lib-gtfs-planner-authorization.md`](../analysis/lib-gtfs-planner-authorization.md)
Freshness: `source_hash=7fb05bff818ee88831ea0d4506c0e26e3768c8f7d4e6be77d56cae22ef25abc0`, `last_synthesized=null`

## Use When
- Adding, renaming, or removing a system/organization role
- Changing the admin-vs-org authorization boundary
- Modifying LiveView route protection (`on_mount` hooks)
- Changing navigation visibility rules (nav pills, dashboard)
- Working with user registration, invite acceptance, or role assignment flows
- Adding or modifying API route authorization
- Changing login gating, post-login redirect, or organization assignment logic

## Read First
- `lib/gtfs_planner/authorization/roles.ex` — canonical `@roles` module attribute defines all three roles with name, description, and scope
- `lib/gtfs_planner_web/ensure_role.ex` — all LiveView `on_mount` hooks (`:require_system_administrator`, `:require`, `:require_pathways_studio_admin`, `:require_gtfs_access`, `:require_gtfs_editor`) plus `has_role?/2` matcher and the unused `ensure_role/2` plug
- `lib/gtfs_planner_web/assign_organization.ex` — assigns `@current_organization` and `@user_roles`; short-circuits for administrators
- `lib/gtfs_planner_web/components/navigation.ex` — role-gated nav pill visibility

## Interfaces
- `Roles.valid?/1` (string arg) — validates a role string against canonical atoms via `String.to_existing_atom/1`
- `Roles.list_by_scope/1` — returns roles filtered by `:system` or `:organization`
- `EnsureRole` LiveView `on_mount` hooks: `:require_system_administrator`, `:require_administrator`, `:require_pathways_studio_admin`, `:require_gtfs_access`, `:require_gtfs_editor`
- `UserAuth.is_administrator?/1` — accepts `User` (scans all memberships) or `UserOrgMembership` (checks `.roles`); returns boolean
- `has_role?/2` — supports single atom, `any: [...]`, `all: [...]`, and nil spec (pass-through)
- `UserOrgMembership.changeset` → `validate_roles/1` — calls `Roles.valid?/1` on each role string
- `UpdateUserOrgMembership` changeset in `organizations.ex:324-339` — admin runtime role update
- `UserAuth.maybe_set_organization_in_session/2` — skips org session for admins
- `UserAuth.signed_in_path/2` — admin → `/admin/organizations`, others → `/`

## Rules & Invariants

### Role Definitions
- Three canonical roles: `:administrator` (system), `:pathways_studio_admin` (org), `:pathways_studio_editor` (org)
- **No role inheritance.** Having `:pathways_studio_admin` does not imply `:pathways_studio_editor`. Each is independently checked.
- **Roles are additive.** A user can hold multiple roles in the same org membership.

### Admin vs Org Boundary (hard wall)
- `:administrator` bypasses `AssignOrganization` entirely — **no** `@current_organization`, **no** `@user_roles` set
- `:administrator` is checked via `is_administrator?/1` which scans **all** memberships (cross-org)
- Org-scoped roles require `@current_organization` + `@user_roles` (single-membership check)
- Admin pages cannot depend on organization-scoped assigns

### Authorization Enforcement
- Primary: LiveView `on_mount` hooks on `EnsureRole`
- Secondary: navigation visibility gating in `navigation.ex` and `dashboard_live.ex`
- `:require_gtfs_access` and `:require_gtfs_editor` are **semantically identical** — both check `:pathways_studio_editor`
- API has **no role enforcement** — `ensure_role/2` plug exists but is not wired into any router pipeline

### Data Ownership
- Roles stored as `{:array, :string}` on `user_org_memberships` table (PostgreSQL array of strings)
- API keys also carry a `roles` array
- `User` schema has **no** direct role field — `has_many :memberships` only
- Role assignment during registration: first user → `["administrator"]`; invitee → `["pathways_studio_editor"]`; seed → `["pathways_studio_admin", "pathways_studio_editor"]`

## State, I/O & Side Effects

- Post-login redirect depends on admin status: admin → `/admin/organizations`, others → `/`
- `AssignOrganization` sets `@current_organization` and `@user_roles`; for admins it short-circuits with `{:cont, socket}`
- GTFS nav tabs require three simultaneous conditions: editor role + org context + selected GTFS version
- Login gate: `is_administrator?(user) || fetch_user_organization(user)` — users with no memberships rejected unless admin
- Role validation uses `String.to_existing_atom/1` (safe, no atom leakage)

## Failure Modes
- **API authorization gap**: `ensure_role/2` plug is unimplemented in routes. Any authenticated caller with org membership can access all `/api/v1/*` endpoints regardless of role.
- **`require_gtfs_access` vs `require_gtfs_editor`**: Identical enforcement; naming suggests a read/write distinction that does not exist. Only `ImportLive` uses the "editor" variant.
- **Admins can't access GTFS**: Admin bypass in `AssignOrganization` means no `@user_roles` or `@current_organization` → no GTFS nav pills appear. Admin-only users cannot view GTFS data.
- **Empty roles array**: `has_role?([], spec)` → `false` implicitly (falls through to single-atom check, no explicit empty-list guard)
- **String-based checks**: Role comparisons use the string `"administrator"`; a typo in a DB role string (if validation is bypassed) would silently fail checks.
- **Cross-org admin mismatch**: A user with `:administrator` in one org and editor in another gets admin privileges system-wide but org-scoped hooks check only the specific org's membership.

## Change Checklist
- [ ] When adding/removing a role: update `@roles` in `roles.ex`, all assignment locations (registration, invite, seed, admin UI), `valid?/1` tests, and any hook that references the role
- [ ] When changing enforcement: check all `on_mount` hooks in `ensure_role.ex`, navigation visibility in `navigation.ex`, dashboard conditions in `dashboard_live.ex`, and login gating in `user_session_controller.ex`
- [ ] When modifying the admin boundary: check `AssignOrganization` bypass, `is_administrator?/1` usage, `maybe_set_organization_in_session`, `signed_in_path`, and every LiveView that depends on `@current_organization` or `@user_roles`
- [ ] When wiring the `ensure_role/2` plug: add to `api_session` pipeline in `router.ex`, ensure `@current_user`/`@current_api_key` and `@current_organization` are set before the plug runs
- [ ] After role changes: run `mix test test/gtfs_planner/authorization/` and `mix test test/gtfs_planner_web/live/access_control_test.exs`
- [ ] If a new role creates a write-specific gate distinct from read access, split `:require_gtfs_access` and `:require_gtfs_editor` into separate role checks

## Escalate To Deep Analysis
- For detailed privilege-to-mechanism mapping tables (sections 4, 5, 6)
- For the full data-flow diagram from login through template render (section 8)
- For the admin-vs-org boundary comparison table (section 7)
- For edge case and error handling catalog with specific line references (section 10)
- For risk analysis and ambiguity discussion (section 11 — unused plug, admin GTFS access gap, naming collision)
- For all evidence file:line citations linking claims to source code
