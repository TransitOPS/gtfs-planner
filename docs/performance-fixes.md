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

1.  **Heavy Joins for Stop Routes**:
    *   `StopsLive` calls `Gtfs.get_routes_for_stops/3` which joins `StopTime`, `Trip`, and `Route`. `StopTime` is often the largest table in a GTFS dataset.
    *   *Optimization*: Ensure proper indexing on `stop_times(organization_id, gtfs_version_id, stop_id)`. Consider a denormalized mapping if performance degrades. (Note: A covering index was added in `20260127004418_add_stop_times_covering_index.exs`, which is good).

### Database Indexing Recommendations

1.  **Distinct Route Types/Agencies**:
    *   Frequent queries for distinct values in `routes`.
    *   *Recommendation*: If route counts are very high, consider adding `route_type` and `agency_id` to the versioned index or as standalone indexes.

## Conclusion
The remaining opportunities are in hook-level query consolidation (combining the 3 `AssignOrganization` queries and caching `AssignGtfsVersion` dropdown data) and monitoring heavy joins in `get_routes_for_stops/3` as dataset sizes grow.
