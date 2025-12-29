# Pathways Studio - Roles & Routes Specification

## Roles

### System-Level Role

| Role            | Description                                                | Scope       |
| --------------- | ---------------------------------------------------------- | ----------- |
| `administrator` | Manages organizations (tenants) in the multi-tenant system | System-wide |

- Has access to `/organizations` routes only
- Does **not** have inherent access to any GTFS or product routes
- Cannot see or interact with GTFS data unless also assigned a product role

---

### Organization-Level Roles

| Role                     | Description                              | Scope        |
| ------------------------ | ---------------------------------------- | ------------ |
| `pathways_studio_admin`  | Manages users within their organization  | Organization |
| `pathways_studio_editor` | Full access to view and modify GTFS data | Organization |
| `pathways_studio_viewer` | Read-only access to GTFS data            | Organization |

**Note:** A user can hold multiple roles. For example, a `pathways_studio_admin` who also needs to edit GTFS data would also need the `pathways_studio_editor` role.

---

## Routes

### System Administration Routes

| Route                    | Description                    | Access          |
| ------------------------ | ------------------------------ | --------------- |
| `/organizations`         | List all organizations         | `administrator` |
| `/organizations/new`     | Create new organization        | `administrator` |
| `/organizations/:org_id` | View/edit organization details | `administrator` |

---

### Organization Administration Routes

| Route                                      | Description                      | Access                  |
| ------------------------------------------ | -------------------------------- | ----------------------- |
| `/organizations/:org_alias/admin/users`          | List users in organization       | `pathways_studio_admin` |
| `/organizations/:org_alias/admin/users/new`      | Invite new user                  | `pathways_studio_admin` |
| `/organizations/:org_alias/admin/users/:user_id` | View/edit user details and roles | `pathways_studio_admin` |

---

### Account Routes

| Route      | Description                           | Access                 |
| ---------- | ------------------------------------- | ---------------------- |
| `/profile` | View/edit own profile, name, password | Any authenticated user |

---

### GTFS Routes

| Route                           | Description                                  | Access                                             |
| ------------------------------- | -------------------------------------------- | -------------------------------------------------- |
| `/gtfs/:version/stops`          | List parent stops                            | `pathways_studio_viewer`, `pathways_studio_editor` |
| `/gtfs/:version/stops/:stop_id` | View stop with levels, child-stops, pathways | `pathways_studio_viewer`, `pathways_studio_editor` |
| `/gtfs/:version/import`         | Import GTFS data                             | `pathways_studio_viewer`, `pathways_studio_editor` |
| `/gtfs/:version/export`         | Export GTFS data                             | `pathways_studio_viewer`, `pathways_studio_editor` |
| `/gtfs/:version/validate`       | Run validation on current version            | `pathways_studio_viewer`, `pathways_studio_editor` |
| `/gtfs/:version/switch`         | Switch between GTFS versions                 | `pathways_studio_viewer`, `pathways_studio_editor` |

---

## Action Permissions

Within the GTFS routes, the ability to perform actions differs by role:

| Action             | `pathways_studio_editor` | `pathways_studio_viewer` |
| ------------------ | :----------------------: | :----------------------: |
| View stops         |            ✅            |            ✅            |
| View levels        |            ✅            |            ✅            |
| View child-stops   |            ✅            |            ✅            |
| View pathways      |            ✅            |            ✅            |
| View versions      |            ✅            |            ✅            |
| Create stop        |            ✅            |            ❌            |
| Edit stop          |            ✅            |            ❌            |
| Delete stop        |            ✅            |            ❌            |
| Create level       |            ✅            |            ❌            |
| Edit level         |            ✅            |            ❌            |
| Delete level       |            ✅            |            ❌            |
| Create child-stop  |            ✅            |            ❌            |
| Edit child-stop    |            ✅            |            ❌            |
| Delete child-stop  |            ✅            |            ❌            |
| Create pathway     |            ✅            |            ❌            |
| Edit pathway       |            ✅            |            ❌            |
| Delete pathway     |            ✅            |            ❌            |
| Upload floorplan   |            ✅            |            ❌            |
| Import GTFS        |            ✅            |            ❌            |
| Export GTFS        |            ✅            |            ✅            |
| Create new version |            ✅            |            ❌            |

---

## Navigation

### Administrator View

```
┌────────────────────────────────────────────────────┐
│  [Logo]  System Admin              [User: Admin ▼] │
├────────────────────────────────────────────────────┤
│                                                    │
│   Organizations                                    │
│   ├── Acme Transit                                 │
│   ├── Metro Authority                              │
│   └── + Add Organization                           │
│                                                    │
└────────────────────────────────────────────────────┘

User Menu: Profile, Sign Out
```

---

### Pathways Studio Admin View

_Only sees admin routes; must also have viewer/editor role to see GTFS routes_

```
┌────────────────────────────────────────────────────┐
│  [Logo]  Pathways Studio           [User: Admin ▼] │
├────────────────────────────────────────────────────┤
│  ┌──────────┐                                      │
│  │   NAV    │   ┌────────────────────────────────┐ │
│  │          │   │                                │ │
│  │  Users   │   │       USER MANAGEMENT          │ │
│  │          │   │                                │ │
│  └──────────┘   └────────────────────────────────┘ │
└────────────────────────────────────────────────────┘

User Menu: Profile, Sign Out
```

---

### Pathways Studio Admin + Editor View

```
┌────────────────────────────────────────────────────────────┐
│  [Logo]  Pathways Studio    [Version: v1.2 ▼] [User: Jo ▼] │
├────────────────────────────────────────────────────────────┤
│  ┌────────────┐                                            │
│  │    NAV     │   ┌──────────────────────────────────────┐ │
│  │            │   │                                      │ │
│  │  Stations  │   │          MAIN CONTENT                │ │
│  │  Import    │   │                                      │ │
│  │  Export    │   │                                      │ │
│  │  Validate  │   │                                      │ │
│  │ ────────── │   │                                      │ │
│  │  Users     │   │                                      │ │
│  │            │   └──────────────────────────────────────┘ │
│  └────────────┘                                            │
└────────────────────────────────────────────────────────────┘

User Menu: Profile, Sign Out
```

---

### Pathways Studio Editor View

```
┌────────────────────────────────────────────────────────────┐
│  [Logo]  Pathways Studio    [Version: v1.2 ▼] [User: Jo ▼] │
├────────────────────────────────────────────────────────────┤
│  ┌────────────┐                                            │
│  │    NAV     │   ┌──────────────────────────────────────┐ │
│  │            │   │                                      │ │
│  │  Stations  │   │          MAIN CONTENT                │ │
│  │  Import    │   │                                      │ │
│  │  Export    │   │       (Full editing enabled)         │ │
│  │  Validate  │   │                                      │ │
│  │            │   └──────────────────────────────────────┘ │
│  └────────────┘                                            │
└────────────────────────────────────────────────────────────┘

User Menu: Profile, Sign Out
```

---

### Pathways Studio Viewer View

```
┌────────────────────────────────────────────────────────────┐
│  [Logo]  Pathways Studio    [Version: v1.2 ▼] [User: Jo ▼] │
├────────────────────────────────────────────────────────────┤
│  ┌────────────┐                                            │
│  │    NAV     │   ┌──────────────────────────────────────┐ │
│  │            │   │                                      │ │
│  │  Stations  │   │          MAIN CONTENT                │ │
│  │  Export    │   │                                      │ │
│  │  Validate  │   │        (Read-only mode)              │ │
│  │            │   │                                      │ │
│  │            │   └──────────────────────────────────────┘ │
│  └────────────┘                                            │
└────────────────────────────────────────────────────────────┘

User Menu: Profile, Sign Out
```

_Note: Import is hidden for viewers since they cannot use it_

---

## Common Role Combinations

| Roles                                              | Use Case                                           |
| -------------------------------------------------- | -------------------------------------------------- |
| `pathways_studio_viewer`                           | Staff who need to review data but not modify it    |
| `pathways_studio_editor`                           | Staff who actively maintain GTFS pathway data      |
| `pathways_studio_admin` + `pathways_studio_editor` | Team lead who manages users and edits data         |
| `pathways_studio_admin` + `pathways_studio_viewer` | Manager who oversees users but only reviews data   |
| `administrator`                                    | System operator managing multiple transit agencies |

---

## Summary

| Role                     | `/organizations` | `/admin/users` | GTFS Routes | Can Edit GTFS |
| ------------------------ | :--------------: | :------------: | :---------: | :-----------: |
| `administrator`          |        ✅        |       ❌       |     ❌      |      ❌       |
| `pathways_studio_admin`  |        ❌        |       ✅       |     ❌      |      ❌       |
| `pathways_studio_editor` |        ❌        |       ❌       |     ✅      |      ✅       |
| `pathways_studio_viewer` |        ❌        |       ❌       |     ✅      |      ❌       |
