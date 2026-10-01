defmodule GtfsPlanner.Repo.Migrations.AddUpstreamOwnershipConstraints do
  use Ecto.Migration

  # Fixed at migration time; the recorded ownership migrations stay unchanged.
  @version_owner_tables ~w(block_attributes route_operating_settings deadhead_times relief_points)a

  @organization_parents [
    {:block_attributes, :garage_id, :garages},
    {:block_attributes, :vehicle_type_id, :vehicle_types},
    {:route_operating_settings, :garage_id, :garages},
    {:route_operating_settings, :required_vehicle_type_id, :vehicle_types},
    {:blocking_settings, :default_garage_id, :garages},
    {:vehicles, :garage_id, :garages},
    {:vehicles, :vehicle_type_id, :vehicle_types}
  ]

  def up do
    create unique_index(:garages, [:id, :organization_id],
             name: :garages_id_organization_id_owner_index,
             prefix: prefix()
           )

    create unique_index(:vehicle_types, [:id, :organization_id],
             name: :vehicle_types_id_organization_id_owner_index,
             prefix: prefix()
           )

    for table <- @version_owner_tables do
      execute("""
      ALTER TABLE #{qualified_table(table)}
      ADD CONSTRAINT #{table}_version_owner_fkey
      FOREIGN KEY (gtfs_version_id, organization_id)
      REFERENCES #{qualified_table(:gtfs_versions)} (id, organization_id)
      ON DELETE NO ACTION NOT VALID
      """)
    end

    for {child, column, parent} <- @organization_parents do
      execute("""
      ALTER TABLE #{qualified_table(child)}
      ADD CONSTRAINT #{child}_#{column}_owner_fkey
      FOREIGN KEY (#{column}, organization_id)
      REFERENCES #{qualified_table(parent)} (id, organization_id)
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
