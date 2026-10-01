defmodule GtfsPlanner.Repo.Migrations.AddRunsOwnershipConstraints do
  use Ecto.Migration

  def up do
    create unique_index(:trips, [:id, :organization_id, :gtfs_version_id],
             name: :trips_id_organization_id_gtfs_version_id_owner_index,
             prefix: prefix()
           )

    execute("""
    ALTER TABLE #{qualified_table(:trip_runs)}
    ADD CONSTRAINT trip_runs_version_owner_fkey
    FOREIGN KEY (gtfs_version_id, organization_id)
    REFERENCES #{qualified_table(:gtfs_versions)} (id, organization_id)
    ON DELETE NO ACTION NOT VALID
    """)

    execute("""
    ALTER TABLE #{qualified_table(:trip_runs)}
    ADD CONSTRAINT trip_runs_trips_owner_fkey
    FOREIGN KEY (trip_id, organization_id, gtfs_version_id)
    REFERENCES #{qualified_table(:trips)} (id, organization_id, gtfs_version_id)
    ON DELETE NO ACTION NOT VALID
    """)
  end

  def down do
    raise "Ownership constraints preserve retained data; fix forward with a new migration"
  end

  defp qualified_table(table) do
    case prefix() do
      nil -> Atom.to_string(table)
      schema -> ~s("#{String.replace(schema, "\"", "\"\"")}".#{table})
    end
  end
end
