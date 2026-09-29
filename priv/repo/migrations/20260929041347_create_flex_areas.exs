defmodule GtfsPlanner.Repo.Migrations.CreateFlexAreas do
  use Ecto.Migration

  def change do
    create table(:flex_areas, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :flex_service_id,
          references(:flex_services, type: :binary_id, on_delete: :delete_all),
          null: false

      add :organization_id,
          references(:organizations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :gtfs_version_id, :binary_id, null: false

      add :key, :string, null: false
      add :position, :integer, null: false
      add :name, :string, null: false
      add :source, :string, null: false
      add :census_geoid, :string
      add :census_layer, :string
      add :census_vintage, :string
      add :route_ids, {:array, :string}, null: false, default: []
      add :distance_m, :integer

      timestamps(type: :utc_datetime_usec)
    end

    execute(
      "ALTER TABLE #{qualified_table()} ADD COLUMN geom geometry(MultiPolygon, 4326)",
      ""
    )

    execute(
      "CREATE INDEX flex_areas_geom_idx ON #{qualified_table()} USING GIST (geom)",
      ""
    )

    create unique_index(:flex_areas, [:flex_service_id, :key])

    create constraint(:flex_areas, :source,
             check: "source IN ('census', 'route_distance', 'drawn', 'file')"
           )
  end

  defp qualified_table do
    case prefix() do
      nil -> "flex_areas"
      schema -> ~s("#{schema}".flex_areas)
    end
  end
end
