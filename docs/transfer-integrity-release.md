# Transfer integrity release check

Before applying `20260927224315_allow_stopless_in_seat_transfers`, run
[the read-only census](../priv/repo/checks/transfer_integrity.sql) against the
release database with read-only credentials. Both queries must return zero rows.

The first query finds transfer keys whose rows differ in transfer type or minimum
transfer time. It preserves the difference between NULL and every integer,
including -1; replacing NULL with an integer sentinel could hide a conflict.
Exact duplicates are excluded because the migration can safely deduplicate them.
The second query finds type 4/5 transfers missing either required trip ID.

If either query returns rows, resolve the reported data before migrating. The
migration refuses these cases atomically; it does not choose between conflicting
values. A clean census describes that snapshot only. The migration checks again
under an exclusive table lock before changing constraints.

The conflict query was verified locally with exact NULL duplicates, exact -1
duplicates, NULL versus -1, differences in either data column, and separate
versions. This does not establish the state of production data.

Rollback restores the former stop requirements only while every transfer has
both stop IDs. Once stopless transfers exist, rollback refuses; keep the migration
and fix forward. Removed transfers require backups for recovery.
