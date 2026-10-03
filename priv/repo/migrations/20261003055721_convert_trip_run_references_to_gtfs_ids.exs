defmodule GtfsPlanner.Repo.Migrations.ConvertTripRunReferencesToGtfsIds do
  use Ecto.Migration

  @moduledoc """
  Stores the scoped GTFS `trip_id` in `trip_runs` instead of the `trips.id` row
  UUID. Assignment rows keep their own IDs, day-type keys and run IDs, so a run
  keeps the same trips on the same day type.

  Every check runs as a `DO` block so it shares the migration's own connection
  and transaction: a check that read through another connection would not see
  this migration's uncommitted columns.

  The conversion refuses to run when an assignment cannot be resolved to a trip
  inside its own organization and version, because blanking the reference would
  detach a retained run from its trip. `down` resolves the same way in reverse
  and refuses when a scoped trip is missing, since a row UUID cannot be
  reconstructed without guessing another scope's row.

  The natural foreign key carries organization and version, deletes as the
  former `ON DELETE CASCADE` reference did (the owner key beside it was
  `NO ACTION`, which the cascade satisfies first), and follows a trip ID rename
  with `ON UPDATE CASCADE`. Day-type uniqueness is rebuilt over the natural ID
  under the same index name.
  """

  @trip_scope "organization_id, gtfs_version_id, trip_id"

  def up do
    lock_tables()

    refuse!("trip_runs rows could not be resolved to a scoped trip", """
    SELECT tr.* FROM #{qualified(:trip_runs)} tr
    LEFT JOIN #{qualified(:trips)} t
      ON t.id = tr.trip_id
     AND t.organization_id = tr.organization_id AND t.gtfs_version_id = tr.gtfs_version_id
    WHERE t.id IS NULL
    """)

    alter table(:trip_runs) do
      add :trip_gtfs_id, :string
    end

    flush()

    execute("""
    UPDATE #{qualified(:trip_runs)} tr
    SET trip_gtfs_id = t.trip_id
    FROM #{qualified(:trips)} t
    WHERE t.id = tr.trip_id
      AND t.organization_id = tr.organization_id AND t.gtfs_version_id = tr.gtfs_version_id
    """)

    refuse!("trip_runs rows were not populated with scoped GTFS trip identifiers", """
    SELECT tr.* FROM #{qualified(:trip_runs)} tr WHERE tr.trip_gtfs_id IS NULL
    """)

    # Dropping the column also drops the indexes and foreign keys that name it.
    swap_columns("trip_gtfs_id")

    create unique_index(:trip_runs, [:organization_id, :gtfs_version_id, :day_type_key, :trip_id])

    # Parent deletes and renames find their assignments through this index.
    create index(:trip_runs, [:organization_id, :gtfs_version_id, :trip_id])

    execute("""
    ALTER TABLE #{qualified(:trip_runs)}
      ADD CONSTRAINT trip_runs_trips_owner_fkey
      FOREIGN KEY (#{@trip_scope})
      REFERENCES #{qualified(:trips)} (#{@trip_scope})
      ON DELETE CASCADE ON UPDATE CASCADE
    """)
  end

  def down do
    lock_tables()

    refuse!(
      "trip_runs rows cannot be restored to row UUIDs because their scoped trip is missing",
      """
      SELECT tr.* FROM #{qualified(:trip_runs)} tr
      LEFT JOIN #{qualified(:trips)} t
        ON t.trip_id = tr.trip_id
       AND t.organization_id = tr.organization_id AND t.gtfs_version_id = tr.gtfs_version_id
      WHERE t.id IS NULL
      """
    )

    alter table(:trip_runs) do
      add :trip_row_id, :uuid
    end

    flush()

    execute("""
    UPDATE #{qualified(:trip_runs)} tr
    SET trip_row_id = t.id
    FROM #{qualified(:trips)} t
    WHERE t.trip_id = tr.trip_id
      AND t.organization_id = tr.organization_id AND t.gtfs_version_id = tr.gtfs_version_id
    """)

    swap_columns("trip_row_id")

    create unique_index(:trip_runs, [:organization_id, :gtfs_version_id, :day_type_key, :trip_id])
    create index(:trip_runs, [:trip_id])

    execute("""
    ALTER TABLE #{qualified(:trip_runs)}
      ADD CONSTRAINT trip_runs_trip_id_fkey
      FOREIGN KEY (trip_id) REFERENCES #{qualified(:trips)} (id) ON DELETE CASCADE,
      ADD CONSTRAINT trip_runs_trips_owner_fkey
      FOREIGN KEY (trip_id, organization_id, gtfs_version_id)
      REFERENCES #{qualified(:trips)} (id, organization_id, gtfs_version_id)
    """)
  end

  # Writers are held out until the new column and keys exist. Trip renames and
  # deletes are held out too, so no trip can change between check and swap.
  defp lock_tables do
    execute("""
    LOCK TABLE #{qualified(:trip_runs)}, #{qualified(:trips)}
    IN SHARE ROW EXCLUSIVE MODE
    """)
  end

  defp swap_columns(replacement) do
    execute("ALTER TABLE #{qualified(:trip_runs)} DROP COLUMN trip_id")
    execute("ALTER TABLE #{qualified(:trip_runs)} RENAME COLUMN #{replacement} TO trip_id")
    execute("ALTER TABLE #{qualified(:trip_runs)} ALTER COLUMN trip_id SET NOT NULL")
  end

  # `offenders` selects the offending rows of `trip_runs`. Raising from inside the
  # database aborts the migration transaction and reports table, row and fields.
  defp refuse!(message, offenders) do
    execute("""
    DO $gtfs_trip_run_references$
    DECLARE
      listing text;
    BEGIN
      SELECT string_agg(
               format(
                 '  trip_runs id=%s organization_id=%s gtfs_version_id=%s trip_id=%s',
                 o.id, o.organization_id, o.gtfs_version_id, o.trip_id
               ),
               E'\\n' ORDER BY o.id
             )
        INTO listing
        FROM (#{offenders}) AS o;

      IF listing IS NOT NULL THEN
        RAISE EXCEPTION '%', '#{message}:' || E'\\n' || listing;
      END IF;
    END
    $gtfs_trip_run_references$
    """)
  end

  defp qualified(name) do
    case prefix() do
      nil -> Atom.to_string(name)
      schema -> ~s("#{schema}".#{name})
    end
  end
end
