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
  # single-column `gtfs_version_id` foreign keys stay as the cascade that
  # removes a version's roster rows with it. This one is `NO ACTION`, so a
  # version id from another organization is refused at write time.
  #
  # Added validated rather than `NOT VALID`: these tables are created by
  # `add_basic_rosters` in the same unreleased change, so there is no retained
  # data for `NOT VALID` to protect, and validating now is what makes the
  # guarantee real for the first write rather than after a later migration.
  def up do
    for table <- ~w(roster_lines roster_line_days)a do
      execute("""
      ALTER TABLE #{qualified_table(table)}
      ADD CONSTRAINT #{table}_version_owner_fkey
      FOREIGN KEY (gtfs_version_id, organization_id)
      REFERENCES #{qualified_table(:gtfs_versions)} (id, organization_id)
      ON DELETE NO ACTION
      """)

      create unique_index(table, [:id, :organization_id, :gtfs_version_id],
               name: :"#{table}_id_organization_id_gtfs_version_id_owner_index",
               prefix: prefix()
             )
    end
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
