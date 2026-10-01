defmodule GtfsPlanner.Repo.Migrations.AddRosterOwnershipConstraints do
  use Ecto.Migration

  # The roster tables joined `GtfsPlanner.Integrity.OwnershipAudit`'s
  # version-owner catalog when `add_basic_rosters` created them, so they owe the
  # same scoped constraint every other version-owner table carries: a
  # `roster_lines` or `roster_line_days` row may only name a `gtfs_versions` row
  # of its own organization, and the database enforces it rather than trusting a
  # writer to have scoped the ids.
  #
  # This is the same shape `add_runs_ownership_constraints` and
  # `add_upstream_ownership_constraints` add, and it replaces nothing: their
  # single-column foreign keys stay as the cascade that removes a version's roster
  # rows with it. These are `NO ACTION`, so a version id from another
  # organization is refused at write time.
  #
  # Two more links carry the same promise between roster rows:
  #
  #   * `roster_line_days` names its line by `(roster_line_id, organization_id,
  #     gtfs_version_id)`, so a day cannot sit under a line of another version or
  #     organization. It cascades like the single-column `roster_line_id` key it
  #     sits beside, so deleting a line removes its days whichever key's trigger
  #     PostgreSQL fires first.
  #   * `roster_lines.operator_id` names its operator by `(operator_id,
  #     organization_id)`, so a line cannot hold another organization's operator.
  #     The single-column foreign key stays too, and it nulls the pick when the
  #     operator is deleted. A composite key that nulled every referencing column
  #     would also null the line's `organization_id`, so this one lists the column
  #     to null: `ON DELETE SET NULL (operator_id)` needs PostgreSQL 15 or later,
  #     and an older server refuses the statement rather than skipping it. The
  #     column-list form keeps the delete independent of the order PostgreSQL
  #     fires the two keys' triggers in; a `NO ACTION` composite next to a `SET
  #     NULL` single-column key would fail the delete whenever its trigger ran
  #     first.
  #
  # Added validated rather than `NOT VALID`: these tables are created by
  # `add_basic_rosters` in the same unreleased change, so there is no retained
  # data for `NOT VALID` to protect, and validating now is what makes the
  # guarantee real for the first write rather than after a later migration.
  #
  # Only the unique indexes a key above references are created.
  def up do
    for table <- ~w(roster_lines roster_line_days)a do
      execute("""
      ALTER TABLE #{qualified_table(table)}
      ADD CONSTRAINT #{table}_version_owner_fkey
      FOREIGN KEY (gtfs_version_id, organization_id)
      REFERENCES #{qualified_table(:gtfs_versions)} (id, organization_id)
      ON DELETE NO ACTION
      """)
    end

    create unique_index(:roster_lines, [:id, :organization_id, :gtfs_version_id],
             name: :roster_lines_id_organization_id_gtfs_version_id_owner_index,
             prefix: prefix()
           )

    create unique_index(:operators, [:id, :organization_id],
             name: :operators_id_organization_id_owner_index,
             prefix: prefix()
           )

    execute("""
    ALTER TABLE #{qualified_table(:roster_line_days)}
    ADD CONSTRAINT roster_line_days_roster_lines_owner_fkey
    FOREIGN KEY (roster_line_id, organization_id, gtfs_version_id)
    REFERENCES #{qualified_table(:roster_lines)} (id, organization_id, gtfs_version_id)
    ON DELETE CASCADE
    """)

    execute("""
    ALTER TABLE #{qualified_table(:roster_lines)}
    ADD CONSTRAINT roster_lines_operator_id_owner_fkey
    FOREIGN KEY (operator_id, organization_id)
    REFERENCES #{qualified_table(:operators)} (id, organization_id)
    ON DELETE SET NULL (operator_id)
    """)
  end

  def down do
    # Ownership constraints preserve retained data; a rollback that dropped them
    # would re-open a cross-organization hole the branch closes. Fix forward.
    raise "Ownership constraints preserve retained data; fix forward with a new migration"
  end

  defp qualified_table(table) do
    case prefix() do
      nil -> Atom.to_string(table)
      schema -> ~s("#{String.replace(schema, "\"", "\"\"")}".#{table})
    end
  end
end
