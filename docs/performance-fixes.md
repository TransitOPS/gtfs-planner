# Performance Audit Log

## Initial Router Audit (lib/gtfs_planner_web/router.ex)

| Item | Description | Potential Impact | Priority |
| :--- | :--- | :--- | :--- |
| Redundant Plugs | `redirect_if_user_is_authenticated` and `require_authenticated_user` pipelines repeat all plugs from `:browser`. | Minimal (Standard Phoenix plugs) | Low |
| `on_mount` Hooks | `GtfsPlannerWeb.AssignOrganization` and `GtfsPlannerWeb.AssignGtfsVersion` are used extensively in `live_session`. Both hooks perform multiple DB queries (3 and 2-3 respectively) on every mount. | High (Executed on every LiveView mount/navigation within session) | Medium |
| Redundant Version Lists | `AssignGtfsVersion` fetches `available_versions` on every mount for the dropdown. | Medium | Low |

## Detailed Findings

### Hook Efficiency (lib/gtfs_planner_web/assign_*.ex)

1.  **`AssignOrganization`**:
    *   `Organizations.get_organization/1`: Fetches organization.
    *   `Organizations.user_deactivated_in_organization?/2`: Checks status.
    *   `Accounts.get_user_org_membership/2`: Fetches roles.
    *   *Optimization*: These could be combined into a single query or cached if the user/org context hasn't changed.

2.  **`AssignGtfsVersion`**:
    *   `Versions.get_gtfs_version!/1`: Fetches version.
    *   `Versions.list_gtfs_versions_for_dropdown/1`: Fetches all versions for the org.
    *   *Optimization*: `list_gtfs_versions_for_dropdown` is likely static enough to be cached or handled more efficiently during navigation.

### LiveView Data Fetching (lib/gtfs_planner_web/live/gtfs/*)

1.  **Redundant Dropdown Data**:
    *   `RoutesLive`: `list_distinct_route_types` and `list_distinct_agencies` are called on every `handle_params` (search, sort, paginate).
    *   `StopsLive`: `list_routes_serving_stations` is called on every `handle_params`.
    *   *Optimization*: These should be fetched once on `mount` or when the version changes.

2.  **Redundant Role Checks**:
    *   Both `RoutesLive` and `StopsLive` have a `get_user_roles/1` function called in `mount`. However, `AssignOrganization` already assigns `:user_roles` to the socket.
    *   *Optimization*: Use `socket.assigns.user_roles` instead of re-querying the DB.

3.  **Heavy Joins for Stop Routes**:
    *   `StopsLive` calls `Gtfs.get_routes_for_stops/3` which joins `StopTime`, `Trip`, and `Route`. `StopTime` is often the largest table in a GTFS dataset.
    *   *Optimization*: Ensure proper indexing on `stop_times(organization_id, gtfs_version_id, stop_id)`. Consider a denormalized mapping if performance degrades. (Note: A covering index was added in `20260127004418_add_stop_times_covering_index.exs`, which is good).

4.  **N+1 Query in `Gtfs.list_levels_for_station/3`**:
    *   This function performs `Repo.get!(Level, level_id)` inside an `Enum.map` over `all_level_ids`.
    *   *Optimization*: Fetch all required levels in a single query using `where l.id in ^all_level_ids`.

### Database Indexing Recommendations

1.  **Route Pattern Filtering**:
    *   `maybe_filter_route` in `Gtfs` context queries `route_patterns` by `route_id`.
    *   *Current Index*: `[:organization_id, :gtfs_version_id]`
    *   *Recommendation*: Add index on `[:organization_id, :gtfs_version_id, :route_id]` to `route_patterns`.

2.  **Distinct Route Types/Agencies**:
    *   Frequent queries for distinct values in `routes`.
    *   *Recommendation*: If route counts are very high, consider adding `route_type` and `agency_id` to the versioned index or as standalone indexes.

## Conclusion
The application follows good patterns (LiveView streams, pagination), but has several opportunities for optimization through query consolidation, caching of semi-static data (like dropdown lists), and fixing N+1 queries in detail views.
