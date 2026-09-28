-- Before applying allow_stopless_in_seat_transfers, run these SELECTs with
-- read-only credentials. Both must return zero rows. See
-- docs/transfer-integrity-release.md for interpretation and rollback limits.

-- Conflicting transfer keys. Exact duplicates are safe for the migration to
-- deduplicate; distinct data values are not. ROW preserves NULL versus -1.
SELECT organization_id, gtfs_version_id,
       from_stop_id, to_stop_id, from_route_id, to_route_id,
       from_trip_id, to_trip_id, COUNT(*) AS row_count
FROM transfers
GROUP BY organization_id, gtfs_version_id,
         from_stop_id, to_stop_id, from_route_id, to_route_id,
         from_trip_id, to_trip_id
HAVING COUNT(DISTINCT ROW(transfer_type, min_transfer_time)) > 1;

-- Linked-trip transfers require both trip IDs.
SELECT id, organization_id, gtfs_version_id, transfer_type
FROM transfers
WHERE transfer_type IN (4, 5)
  AND (from_trip_id IS NULL OR to_trip_id IS NULL);
