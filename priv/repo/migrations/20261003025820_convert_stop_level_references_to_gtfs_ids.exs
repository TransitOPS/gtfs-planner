defmodule GtfsPlanner.Repo.Migrations.ConvertStopLevelReferencesToGtfsIds do
  use Ecto.Migration

  @moduledoc """
  Stores scoped GTFS stop and level identifiers in `stop_levels` instead of the
  `stops.id`/`levels.id` row UUIDs. Floorplan row IDs, diagram filenames,
  geometry, scale data and journal attachments are untouched; only the two
  reference columns are rebuilt around natural identifiers.

  Every check runs as a `DO` block so it shares the migration's own connection
  and transaction: a check that read through another connection would not see
  this migration's uncommitted columns.

  The conversion refuses to run when a floorplan cannot be resolved to a parent
  inside its own organization and version, because blanking the reference would
  detach a retained diagram from its station. `down` resolves the same way in
  reverse and refuses when a scoped parent is missing, since a row UUID cannot
  be reconstructed without guessing another scope's row.

  The natural foreign keys carry organization and version, delete as the former
  `ON DELETE CASCADE` reference did, and `ON UPDATE CASCADE` so a stop or level
  ID rename reaches the floorplan row in the same statement.
  """

  def up do
    lock_tables()

    refuse!(
      "stop_levels rows could not be resolved to a scoped stop or level",
      """
      SELECT sl.* FROM #{qualified(:stop_levels)} sl
      LEFT JOIN #{qualified(:stops)} s
        ON s.id = sl.stop_id
       AND s.organization_id = sl.organization_id AND s.gtfs_version_id = sl.gtfs_version_id
      LEFT JOIN #{qualified(:levels)} l
        ON l.id = sl.level_id
       AND l.organization_id = sl.organization_id AND l.gtfs_version_id = sl.gtfs_version_id
      WHERE s.id IS NULL OR l.id IS NULL
      """
    )

    alter table(:stop_levels) do
      add :stop_gtfs_id, :string
      add :level_gtfs_id, :string
    end

    flush()

    execute("""
    UPDATE #{qualified(:stop_levels)} sl
    SET stop_gtfs_id = s.stop_id, level_gtfs_id = l.level_id
    FROM #{qualified(:stops)} s, #{qualified(:levels)} l
    WHERE s.id = sl.stop_id
      AND s.organization_id = sl.organization_id AND s.gtfs_version_id = sl.gtfs_version_id
      AND l.id = sl.level_id
      AND l.organization_id = sl.organization_id AND l.gtfs_version_id = sl.gtfs_version_id
    """)

    refuse!(
      "stop_levels rows were not populated with scoped GTFS identifiers",
      """
      SELECT sl.* FROM #{qualified(:stop_levels)} sl
      WHERE sl.stop_gtfs_id IS NULL OR sl.level_gtfs_id IS NULL
      """
    )

    # Dropping a column also drops the indexes and foreign keys that name it.
    swap_columns("stop_id", "stop_gtfs_id")
    swap_columns("level_id", "level_gtfs_id")

    recreate_indexes()

    execute("""
    ALTER TABLE #{qualified(:stop_levels)}
      ADD CONSTRAINT stop_levels_stops_owner_fkey
      FOREIGN KEY (organization_id, gtfs_version_id, stop_id)
      REFERENCES #{qualified(:stops)} (organization_id, gtfs_version_id, stop_id)
      ON DELETE CASCADE ON UPDATE CASCADE,
      ADD CONSTRAINT stop_levels_levels_owner_fkey
      FOREIGN KEY (organization_id, gtfs_version_id, level_id)
      REFERENCES #{qualified(:levels)} (organization_id, gtfs_version_id, level_id)
      ON DELETE CASCADE ON UPDATE CASCADE
    """)
  end

  def down do
    lock_tables()

    refuse!(
      "stop_levels rows cannot be restored to row UUIDs because their scoped stop or level is missing",
      """
      SELECT sl.* FROM #{qualified(:stop_levels)} sl
      LEFT JOIN #{qualified(:stops)} s
        ON s.stop_id = sl.stop_id
       AND s.organization_id = sl.organization_id AND s.gtfs_version_id = sl.gtfs_version_id
      LEFT JOIN #{qualified(:levels)} l
        ON l.level_id = sl.level_id
       AND l.organization_id = sl.organization_id AND l.gtfs_version_id = sl.gtfs_version_id
      WHERE s.id IS NULL OR l.id IS NULL
      """
    )

    alter table(:stop_levels) do
      add :stop_row_id, :uuid
      add :level_row_id, :uuid
    end

    flush()

    execute("""
    UPDATE #{qualified(:stop_levels)} sl
    SET stop_row_id = s.id, level_row_id = l.id
    FROM #{qualified(:stops)} s, #{qualified(:levels)} l
    WHERE s.stop_id = sl.stop_id
      AND s.organization_id = sl.organization_id AND s.gtfs_version_id = sl.gtfs_version_id
      AND l.level_id = sl.level_id
      AND l.organization_id = sl.organization_id AND l.gtfs_version_id = sl.gtfs_version_id
    """)

    swap_columns("stop_id", "stop_row_id")
    swap_columns("level_id", "level_row_id")

    recreate_indexes()

    execute("""
    ALTER TABLE #{qualified(:stop_levels)}
      ADD CONSTRAINT stop_levels_stop_id_fkey
      FOREIGN KEY (stop_id) REFERENCES #{qualified(:stops)} (id) ON DELETE CASCADE,
      ADD CONSTRAINT stop_levels_level_id_fkey
      FOREIGN KEY (level_id) REFERENCES #{qualified(:levels)} (id) ON DELETE CASCADE,
      ADD CONSTRAINT stop_levels_stops_owner_fkey
      FOREIGN KEY (stop_id, organization_id, gtfs_version_id)
      REFERENCES #{qualified(:stops)} (id, organization_id, gtfs_version_id),
      ADD CONSTRAINT stop_levels_levels_owner_fkey
      FOREIGN KEY (level_id, organization_id, gtfs_version_id)
      REFERENCES #{qualified(:levels)} (id, organization_id, gtfs_version_id)
    """)
  end

  # Writers are held out until the new columns and keys exist. Parent renames and
  # deletes are held out too, so no parent can change between check and swap.
  defp lock_tables do
    execute("""
    LOCK TABLE #{qualified(:stop_levels)}, #{qualified(:stops)}, #{qualified(:levels)}
    IN SHARE ROW EXCLUSIVE MODE
    """)
  end

  defp swap_columns(column, replacement) do
    execute("ALTER TABLE #{qualified(:stop_levels)} DROP COLUMN #{column}")
    execute("ALTER TABLE #{qualified(:stop_levels)} RENAME COLUMN #{replacement} TO #{column}")
    execute("ALTER TABLE #{qualified(:stop_levels)} ALTER COLUMN #{column} SET NOT NULL")
  end

  defp recreate_indexes do
    create index(:stop_levels, [:stop_id])
    create index(:stop_levels, [:level_id])
    create unique_index(:stop_levels, [:organization_id, :gtfs_version_id, :stop_id, :level_id])
  end

  # `offenders` selects the offending `stop_levels` rows. Raising from inside the
  # database aborts the migration transaction and reports table, row and fields.
  defp refuse!(message, offenders) do
    execute("""
    DO $gtfs_stop_levels$
    DECLARE
      listing text;
    BEGIN
      SELECT string_agg(
               format(
                 '  stop_levels id=%s organization_id=%s gtfs_version_id=%s stop_id=%s level_id=%s',
                 o.id, o.organization_id, o.gtfs_version_id, o.stop_id, o.level_id
               ),
               E'\\n' ORDER BY o.id
             )
        INTO listing
        FROM (#{offenders}) AS o;

      IF listing IS NOT NULL THEN
        RAISE EXCEPTION '%', '#{message}:' || E'\\n' || listing;
      END IF;
    END
    $gtfs_stop_levels$
    """)
  end

  defp qualified(name) do
    case prefix() do
      nil -> Atom.to_string(name)
      schema -> ~s("#{schema}".#{name})
    end
  end
end
