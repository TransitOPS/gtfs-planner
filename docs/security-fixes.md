# Security Audit Log

This document tracks potential security items identified during the application audit and their status.

## Identified Items

### 1. Potential 500 Error on Malformed API Key
**Severity:** Low  
**Description:** `GtfsPlanner.Organizations.ApiKey.verify_token/2` uses bang versions of `Base.decode32!` and `Ecto.UUID.cast!`. If an API key with malformed Base32 or an invalid UUID is provided in the `Authorization` header, the application will raise an exception and likely return a 500 error instead of a 401 Unauthorized.  
**Historical location:** `lib/gtfs_planner/organizations/api_key.ex:65` (legacy API-key subsystem retired in Package 11)
**Recommendation:** Use `Base.decode32/2` and `Ecto.UUID.cast/1` and handle the error cases gracefully within the `with` block.

### 2. Administrator Role Scope Check
**Severity:** Medium  
**Description:** `GtfsPlannerWeb.EnsureRole.has_administrator_role?/1` checks if a user has the "administrator" role in *any* organization membership. While currently the UI doesn't allow assigning this role, the logic implies that an administrator of one organization would gain system-wide administrator privileges if they had this role in their membership.  
**Location:** `lib/gtfs_planner_web/ensure_role.ex:196`  
**Recommendation:** System administrators should ideally be identified by a specific flag on the `User` schema or a special "System" organization, rather than checking all memberships for a role string.

### 3. Missing Scoped Check in `Gtfs.list_child_stops_for_parent/3`
**Severity:** Low  
**Description:** The function fetches the `parent_station` using `Repo.get!(Stop, parent_station_id)` without verifying that it belongs to the provided `organization_id` and `gtfs_version_id`. While the subsequent query for child stops *does* filter by these IDs, it's safer to ensure the parent itself is valid for the context.  
**Location:** `lib/gtfs_planner/gtfs.ex:441`  
**Recommendation:** Use a scoped query to fetch the `parent_station`.

### 4. Redundant `on_mount` Hooks in Router and LiveViews
**Severity:** Info / Maintenance  
**Description:** Many LiveViews (e.g., `RoutesLive`, `Admin.UsersLive`) have `on_mount` hooks that are also specified in the `live_session` in `router.ex`. While not a direct security risk, this redundancy can lead to confusion and maintenance overhead.  
**Location:** `lib/gtfs_planner_web/router.ex` and various LiveView modules.  
**Recommendation:** Consolidate authorization logic in the router's `live_session` blocks where possible to ensure consistent enforcement.

### 5. Privilege Escalation via Role Assignment
**Severity:** High  
**Description:** `Admin.UsersLive` (accessible by `pathways_studio_admin`) and `Admin.OrganizationsLive` (accessible by `administrator`) take roles from the `invite` parameters without validating them against a whitelist of allowed roles for the current user's privilege level. A `pathways_studio_admin` could potentially intercept the WebSocket traffic and add the `"administrator"` role to an invitation, granting themselves or others system-wide administrator privileges.  
**Location:** `lib/gtfs_planner_web/live/admin/users_live.ex:108` and `lib/gtfs_planner_web/live/admin/organizations_live.ex:189`  
**Recommendation:** Validate that the requested roles are a subset of the roles the current user is authorized to assign. Specifically, `pathways_studio_admin` should only be able to assign roles with `scope: :organization`.

### 6. Memory Exhaustion (DoS) during GTFS Import
**Severity:** High  
**Description:** The GTFS import process reads all uploaded files into memory as binaries (`File.read!/1`) and subsequently splits them into lists of lines (`String.split/2`). With a maximum file size of 200MB and up to 50 files allowed, a single import request could consume several gigabytes of memory, leading to node-wide memory exhaustion and potential crashes.  
**Location:** `lib/gtfs_planner_web/live/gtfs/import_live.ex:188` and `lib/gtfs_planner/gtfs/import.ex:345`  
**Recommendation:** Process uploaded files as streams directly from the temporary storage. Avoid `File.read!/1` for large files and use `File.stream!/3` or similar streaming approaches for CSV parsing.

### 7. Directory Traversal via Diagram Upload
**Severity:** Critical  
**Description:** `StationDiagramLive` uses the user-provided `entry.client_name` to construct the destination path for uploaded diagrams without sanitization. A malicious user could provide a filename with directory traversal components (e.g., `../../../foo`) to write or overwrite files anywhere the application has write permissions.  
**Location:** `lib/gtfs_planner_web/live/gtfs/station_diagram_live.ex:485`  
**Recommendation:** Sanitize filenames or, preferably, generate unique, random filenames (e.g., using UUIDs) and store the mapping in the database.

### 8. Insecure Direct Object Reference (IDOR) in Diagram Editor
**Severity:** High  
**Description:** Multiple event handlers in `StationDiagramLive` (e.g., `edit_child_stop`, `delete_child_stop`, `delete_pathway`, `edit_pathway`) fetch records using internal UUIDs via `get_stop!/1`, `get_pathway!/1`, etc., without verifying that the records belong to the current organization. A user could potentially modify or delete data belonging to other organizations if they obtain the internal UUIDs.  
**Location:** `lib/gtfs_planner_web/live/gtfs/station_diagram_live.ex:228`, `281`, `321`, `344`  
**Recommendation:** Always include `organization_id` and `gtfs_version_id` in database queries for record retrieval and modification.

### 9. Cross-Organization File Collision and Exposure
**Severity:** Medium  
**Description:** Station diagrams are stored in a public directory (`priv/static/uploads/diagrams`) using the GTFS `stop_id` as part of the path. Since GTFS IDs are not unique across organizations, different organizations using the same `stop_id` will overwrite each other's diagrams. Furthermore, since these files are in `priv/static`, they are likely served without any authorization checks.  
**Location:** `lib/gtfs_planner_web/live/gtfs/station_diagram_live.ex:482`  
**Recommendation:** Use organization-specific and version-specific paths for uploads, and use randomized filenames. If diagrams are sensitive, serve them through a controller that enforces authorization instead of `Plug.Static`.

### 10. Lack of Rate Limiting
**Severity:** Medium  
**Description:** The application does not implement rate limiting on sensitive routes such as login (`/users/log_in`), password reset, and user invitation. This makes the application vulnerable to brute-force and credential stuffing attacks.  
**Location:** `lib/gtfs_planner_web/router.ex`  
**Recommendation:** Implement rate limiting using a library like `Hammer` or `HammerPlug` for authentication-related endpoints.
