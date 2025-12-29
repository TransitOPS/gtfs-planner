# Test Failures & Warnings Fix Specification

## Overview

This document outlines the engineering tasks required to resolve 6 compilation warnings and 24 test failures. The issues fall into four distinct categories.

---

## Issue Categories

### Category A: Missing `on_mount/4` in AssignOrganization Module

**Warnings Affected:** 4  
**Tests Affected:** 1–4, 6–10

The `GtfsPlannerWeb.AssignOrganization` module implements only the `Plug` behaviour (`init/1`, `call/2`) but is referenced as a LiveView `on_mount` hook in the router and individual LiveViews.

### Category B: Undefined `current_scope` Attribute in Layouts.app

**Warnings Affected:** 2  
**Tests Affected:** Indirectly via Category A failures

The `GtfsPlannerWeb.Layouts.app/1` component does not define a `current_scope` attribute, but `validate_live.ex` and `export_live.ex` pass `current_scope={@current_scope}`.

### Category C: Invalid Role Names in Test Fixtures

**Tests Affected:** 12–24

Tests use role strings like `"admin"`, `"member"`, `"editor"` which are rejected by `UserOrgMembership.changeset/2` validation. Valid roles are: `"administrator"`, `"pathways_studio_admin"`, `"pathways_studio_editor"`, `"pathways_studio_viewer"`.

### Category D: Administrator Role Check Requires Non-Existent Organization Context

**Tests Affected:** 5, 11

The `EnsureRole.on_mount(:require, ...)` hook requires both `current_user` and `current_organization` in socket assigns. The `/organizations` route is system-scoped and has no organization context, causing the administrator check to fail and redirect.

---

## Implementation Tasks

### Task 1: Add `on_mount/4` callback to AssignOrganization module

**File:** `lib/gtfs_planner_web/assign_organization.ex`

Add a public `on_mount/4` function that implements the LiveView mount hook behaviour. The function signature must be:

```elixir
def on_mount(:default, params, _session, socket)
```

**Implementation details:**

1. Extract `"org_alias"` from the `params` map
2. Call `GtfsPlanner.Organizations.get_organization_by_alias/1`
3. On `{:ok, organization}`: assign `:current_organization` to socket and return `{:cont, socket}`
4. On `{:error, :not_found}`: put flash error "Organization not found", redirect to `/`, return `{:halt, socket}`
5. When `org_alias` key is missing from params: return `{:cont, socket}` unchanged

---

### Task 2: Remove `current_scope` attribute from validate_live.ex template

**File:** `lib/gtfs_planner_web/live/gtfs/validate_live.ex`

In the `render/1` function, change:

```elixir
<Layouts.app flash={@flash} current_scope={@current_scope}>
```

to:

```elixir
<Layouts.app flash={@flash} current_user={@current_user} current_organization={@current_organization} user_roles={@user_roles}>
```

Also update `mount/3` to assign the required attributes:

1. Assign `user_roles` by fetching the membership roles from the socket's `current_user` and `current_organization` assigns using `Accounts.get_user_org_membership/2`

---

### Task 3: Remove `current_scope` attribute from export_live.ex template

**File:** `lib/gtfs_planner_web/live/gtfs/export_live.ex`

Apply identical changes as Task 2:

1. Replace `current_scope={@current_scope}` with `current_user={@current_user} current_organization={@current_organization} user_roles={@user_roles}`
2. Update `mount/3` to assign `user_roles` by fetching membership roles

---

### Task 4: Update accounts_test.exs to use valid role names

**File:** `test/gtfs_planner/accounts_test.exs`

Replace all occurrences of invalid role strings with canonical role names:

| Invalid Role | Replace With               |
| ------------ | -------------------------- |
| `"admin"`    | `"pathways_studio_admin"`  |
| `"member"`   | `"pathways_studio_viewer"` |
| `"editor"`   | `"pathways_studio_editor"` |

Affected test locations (line numbers approximate):

- Line 611: `roles: ["admin"]` → `roles: ["pathways_studio_admin"]`
- Line 617: `roles: ["member"]` → `roles: ["pathways_studio_viewer"]`
- Line 641: `roles: ["admin"]` → `roles: ["pathways_studio_admin"]`
- Line 671: `roles: ["admin", "editor"]` → `roles: ["pathways_studio_admin", "pathways_studio_editor"]`
- Line 688: `roles: ["admin"]` → `roles: ["pathways_studio_admin"]`
- Line 698: `roles: ["member"]` → `roles: ["pathways_studio_viewer"]`
- Line 717: `roles: ["admin"]` → `roles: ["pathways_studio_admin"]`
- Line 750: `roles: ["admin", "editor"]` → `roles: ["pathways_studio_admin", "pathways_studio_editor"]`

---

### Task 5: Update organizations_test.exs to use valid role names

**File:** `test/gtfs_planner/organizations_test.exs`

Replace all occurrences of invalid role strings with canonical role names using the same mapping as Task 4:

- Line 446: `["member"]` → `["pathways_studio_viewer"]`
- Line 487: `["admin"]` → `["pathways_studio_admin"]`
- Line 519: `["admin"]` → `["pathways_studio_admin"]`

---

### Task 6: Add system-scoped administrator check to EnsureRole module

**File:** `lib/gtfs_planner_web/ensure_role.ex`

Add a new `on_mount/4` clause to handle the administrator role check without requiring organization context:

```elixir
def on_mount(:require_system_administrator, _params, _session, socket) do
  user = socket.assigns[:current_user]

  if user && has_administrator_role?(user.id) do
    {:cont, socket}
  else
    socket =
      socket
      |> Phoenix.LiveView.put_flash(:error, "You must be an administrator to access this page.")
      |> Phoenix.LiveView.redirect(to: "/")

    {:halt, socket}
  end
end
```

Add a private helper function:

```elixir
defp has_administrator_role?(user_id) do
  user_id
  |> Accounts.list_user_org_memberships()
  |> Enum.any?(fn membership ->
    "administrator" in membership.roles
  end)
end
```

---

### Task 7: Update OrganizationsListLive to use system-scoped administrator check

**File:** `lib/gtfs_planner_web/live/organizations_list_live.ex`

Change:

```elixir
on_mount {GtfsPlannerWeb.EnsureRole, :require}
```

to:

```elixir
on_mount {GtfsPlannerWeb.EnsureRole, :require_system_administrator}
```

---

### Task 8: Fix access_control_test assertion for non-administrator redirect

**File:** `test/gtfs_planner_web/live/access_control_test.exs`

In the test "non-administrator cannot access /organizations" (line 65), update the assertion:

Change:

```elixir
assert redirect_path != "/organizations"
```

to:

```elixir
assert redirect_path == "/"
```

This matches the redirect destination specified in Task 6.

---

## Verification

After implementing all tasks, run the specific failing tests:

```bash
mix test test/gtfs_planner/accounts_test.exs test/gtfs_planner/organizations_test.exs test/gtfs_planner_web/live/access_control_test.exs
```

Verify zero warnings by running:

```bash
mix compile --warnings-as-errors
```
