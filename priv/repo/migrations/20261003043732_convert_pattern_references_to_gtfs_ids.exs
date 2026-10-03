defmodule GtfsPlanner.Repo.Migrations.ConvertPatternReferencesToGtfsIds do
  use Ecto.Migration

  @moduledoc """
  Stores the scoped GTFS `route_pattern_id` in `route_pattern_stops`,
  `timed_patterns` and the `route_patterns.label_pattern_id` label reference
  instead of the parent's `route_patterns.id` row UUID. Occurrence rows, timing
  rows and the patterns themselves keep their row UUIDs, so alignment anchors,
  timed-pattern stops and trips stay attached to the same visit and timing.

  Every check runs as a `DO` block so it shares the migration's own connection
  and transaction: a check that read through another connection would not see
  this migration's uncommitted columns.

  The conversion refuses to run when a row cannot be resolved to a parent inside
  its own organization and version, because blanking the reference would detach
  a retained occurrence or timing from its pattern. `down` resolves the same way
  in reverse and refuses when a scoped parent is missing, since a row UUID
  cannot be reconstructed without guessing another scope's row.

  The natural foreign keys carry organization and version and follow a parent
  `route_pattern_id` rename (`ON UPDATE CASCADE`). Occurrences and timings still
  delete with their pattern; a label child still blocks deleting its owner.
  Position, timing name and timing derivation uniqueness are scoped by
  organization and version, and the label not-self check compares natural IDs.
  """

  @pattern_scope "organization_id, gtfs_version_id, route_pattern_id"

  def up do
    lock_tables()

    for {table, column, message} <- families() do
      refuse!(table, column, "#{message} could not be resolved to a scoped route pattern", """
      SELECT c.* FROM #{qualified(table)} c
      LEFT JOIN #{qualified(:route_patterns)} p
        ON p.id = c.#{column}
       AND p.organization_id = c.organization_id AND p.gtfs_version_id = c.gtfs_version_id
      WHERE c.#{column} IS NOT NULL AND p.id IS NULL
      """)
    end

    for {table, column, _message} <- families() do
      alter table(table) do
        add :"#{column}_gtfs_id", :string
      end
    end

    flush()

    for {table, column, _message} <- families() do
      execute("""
      UPDATE #{qualified(table)} c
      SET #{column}_gtfs_id = p.route_pattern_id
      FROM #{qualified(:route_patterns)} p
      WHERE p.id = c.#{column}
        AND p.organization_id = c.organization_id AND p.gtfs_version_id = c.gtfs_version_id
      """)

      refuse!(
        table,
        column,
        "#{table} rows were not populated with scoped GTFS route pattern identifiers",
        """
        SELECT c.* FROM #{qualified(table)} c
        WHERE c.#{column} IS NOT NULL AND c.#{column}_gtfs_id IS NULL
        """
      )
    end

    # Dropping a column also drops the indexes, foreign keys and checks that
    # name it.
    swap_columns(:route_pattern_stops, "route_pattern_id", "route_pattern_id_gtfs_id", true)
    swap_columns(:timed_patterns, "route_pattern_id", "route_pattern_id_gtfs_id", true)
    swap_columns(:route_patterns, "label_pattern_id", "label_pattern_id_gtfs_id", false)

    create unique_index(
             :route_pattern_stops,
             [:organization_id, :gtfs_version_id, :route_pattern_id, :position],
             name: :route_pattern_stops_route_pattern_id_position_index
           )

    create unique_index(
             :timed_patterns,
             [:organization_id, :gtfs_version_id, :route_pattern_id, "lower(name)"],
             name: :timed_patterns_route_pattern_id_lower_name_index
           )

    create unique_index(
             :timed_patterns,
             [:organization_id, :gtfs_version_id, :route_pattern_id, :derivation_key],
             name: :timed_patterns_route_pattern_id_derivation_key_index,
             where: "derivation_key IS NOT NULL"
           )

    create index(:route_patterns, [:organization_id, :gtfs_version_id, :label_pattern_id],
             name: :route_patterns_label_pattern_id_index
           )

    create constraint(:route_patterns, :route_patterns_label_not_self,
             check: "label_pattern_id IS NULL OR label_pattern_id <> route_pattern_id"
           )

    execute("""
    ALTER TABLE #{qualified(:route_pattern_stops)}
      ADD CONSTRAINT route_pattern_stops_route_patterns_owner_fkey
      FOREIGN KEY (#{@pattern_scope})
      REFERENCES #{qualified(:route_patterns)} (#{@pattern_scope})
      ON DELETE CASCADE ON UPDATE CASCADE
    """)

    execute("""
    ALTER TABLE #{qualified(:timed_patterns)}
      ADD CONSTRAINT timed_patterns_route_patterns_owner_fkey
      FOREIGN KEY (#{@pattern_scope})
      REFERENCES #{qualified(:route_patterns)} (#{@pattern_scope})
      ON DELETE CASCADE ON UPDATE CASCADE
    """)

    # A null label skips the check (MATCH SIMPLE), so an unlabelled pattern needs
    # no owner.
    execute("""
    ALTER TABLE #{qualified(:route_patterns)}
      ADD CONSTRAINT route_patterns_label_pattern_id_fkey
      FOREIGN KEY (organization_id, gtfs_version_id, label_pattern_id)
      REFERENCES #{qualified(:route_patterns)} (#{@pattern_scope})
      ON DELETE RESTRICT ON UPDATE CASCADE
    """)
  end

  def down do
    lock_tables()

    for {table, column, message} <- families() do
      refuse!(
        table,
        column,
        "#{message} cannot be restored to row UUIDs because their scoped route pattern is missing",
        """
        SELECT c.* FROM #{qualified(table)} c
        LEFT JOIN #{qualified(:route_patterns)} p
          ON p.route_pattern_id = c.#{column}
         AND p.organization_id = c.organization_id AND p.gtfs_version_id = c.gtfs_version_id
        WHERE c.#{column} IS NOT NULL AND p.id IS NULL
        """
      )
    end

    for {table, column, _message} <- families() do
      alter table(table) do
        add :"#{column}_row_id", :uuid
      end
    end

    flush()

    for {table, column, _message} <- families() do
      execute("""
      UPDATE #{qualified(table)} c
      SET #{column}_row_id = p.id
      FROM #{qualified(:route_patterns)} p
      WHERE p.route_pattern_id = c.#{column}
        AND p.organization_id = c.organization_id AND p.gtfs_version_id = c.gtfs_version_id
      """)
    end

    # The natural foreign keys and the indexes over the text columns go with
    # the columns they name.
    swap_columns(:route_pattern_stops, "route_pattern_id", "route_pattern_id_row_id", true)
    swap_columns(:timed_patterns, "route_pattern_id", "route_pattern_id_row_id", true)
    swap_columns(:route_patterns, "label_pattern_id", "label_pattern_id_row_id", false)

    create unique_index(:route_pattern_stops, [:route_pattern_id, :position],
             name: :route_pattern_stops_route_pattern_id_position_index
           )

    create index(:route_pattern_stops, [:organization_id, :gtfs_version_id, :route_pattern_id])

    create unique_index(:timed_patterns, [:route_pattern_id, "lower(name)"],
             name: :timed_patterns_route_pattern_id_lower_name_index
           )

    create unique_index(:timed_patterns, [:route_pattern_id, :derivation_key],
             name: :timed_patterns_route_pattern_id_derivation_key_index,
             where: "derivation_key IS NOT NULL"
           )

    create index(:timed_patterns, [:organization_id, :gtfs_version_id, :route_pattern_id])
    create index(:route_patterns, [:label_pattern_id])

    create constraint(:route_patterns, :route_patterns_label_not_self,
             check: "label_pattern_id IS NULL OR label_pattern_id <> id"
           )

    execute("""
    ALTER TABLE #{qualified(:route_pattern_stops)}
      ADD CONSTRAINT route_pattern_stops_route_pattern_id_fkey
      FOREIGN KEY (route_pattern_id) REFERENCES #{qualified(:route_patterns)} (id)
      ON DELETE CASCADE,
      ADD CONSTRAINT route_pattern_stops_route_patterns_owner_fkey
      FOREIGN KEY (route_pattern_id, organization_id, gtfs_version_id)
      REFERENCES #{qualified(:route_patterns)} (id, organization_id, gtfs_version_id)
    """)

    execute("""
    ALTER TABLE #{qualified(:timed_patterns)}
      ADD CONSTRAINT timed_patterns_route_pattern_id_fkey
      FOREIGN KEY (route_pattern_id) REFERENCES #{qualified(:route_patterns)} (id)
      ON DELETE CASCADE,
      ADD CONSTRAINT timed_patterns_route_patterns_owner_fkey
      FOREIGN KEY (route_pattern_id, organization_id, gtfs_version_id)
      REFERENCES #{qualified(:route_patterns)} (id, organization_id, gtfs_version_id)
    """)

    execute("""
    ALTER TABLE #{qualified(:route_patterns)}
      ADD CONSTRAINT route_patterns_label_pattern_id_fkey
      FOREIGN KEY (label_pattern_id) REFERENCES #{qualified(:route_patterns)} (id)
      ON DELETE RESTRICT
    """)
  end

  defp families do
    [
      {:route_pattern_stops, "route_pattern_id", "route_pattern_stops rows"},
      {:timed_patterns, "route_pattern_id", "timed_patterns rows"},
      {:route_patterns, "label_pattern_id", "route_patterns label references"}
    ]
  end

  # Writers are held out until the new columns and keys exist. Parent renames and
  # deletes are held out too, so no parent can change between check and swap.
  defp lock_tables do
    execute("""
    LOCK TABLE #{qualified(:route_patterns)}, #{qualified(:route_pattern_stops)},
      #{qualified(:timed_patterns)}
    IN SHARE ROW EXCLUSIVE MODE
    """)
  end

  defp swap_columns(table, column, replacement, not_null?) do
    execute("ALTER TABLE #{qualified(table)} DROP COLUMN #{column}")
    execute("ALTER TABLE #{qualified(table)} RENAME COLUMN #{replacement} TO #{column}")

    if not_null? do
      execute("ALTER TABLE #{qualified(table)} ALTER COLUMN #{column} SET NOT NULL")
    end
  end

  # `offenders` selects the offending rows of `table`. Raising from inside the
  # database aborts the migration transaction and reports table, row and fields.
  defp refuse!(table, column, message, offenders) do
    execute("""
    DO $gtfs_pattern_references$
    DECLARE
      listing text;
    BEGIN
      SELECT string_agg(
               format(
                 '  #{table} id=%s organization_id=%s gtfs_version_id=%s #{column}=%s',
                 o.id, o.organization_id, o.gtfs_version_id, o.#{column}
               ),
               E'\\n' ORDER BY o.id
             )
        INTO listing
        FROM (#{offenders}) AS o;

      IF listing IS NOT NULL THEN
        RAISE EXCEPTION '%', '#{message}:' || E'\\n' || listing;
      END IF;
    END
    $gtfs_pattern_references$
    """)
  end

  defp qualified(name) do
    case prefix() do
      nil -> Atom.to_string(name)
      schema -> ~s("#{schema}".#{name})
    end
  end
end
