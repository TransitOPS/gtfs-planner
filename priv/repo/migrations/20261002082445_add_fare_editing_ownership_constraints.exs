defmodule GtfsPlanner.Repo.Migrations.AddFareEditingOwnershipConstraints do
  use Ecto.Migration

  @tables ~w(fare_product_details fare_saved_journeys fare_time_periods fare_version_settings)a

  # Reject new cross-organization version ownership without rewriting or
  # validating retained rows. Existing anomalies remain visible to OwnershipAudit.
  def up do
    for table <- @tables do
      execute("""
      ALTER TABLE #{qualified_table(table)}
      ADD CONSTRAINT #{table}_version_owner_fkey
      FOREIGN KEY (gtfs_version_id, organization_id)
      REFERENCES #{qualified_table(:gtfs_versions)} (id, organization_id)
      ON DELETE NO ACTION NOT VALID
      """)
    end
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
