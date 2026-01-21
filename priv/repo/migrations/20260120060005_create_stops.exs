defmodule GtfsPlanner.Repo.Migrations.CreateStops do
  use Ecto.Migration

  def up do
    create table(:stops, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, references(:organizations, type: :binary_id), null: false
      add :gtfs_version_id, :binary_id, null: false
      add :stop_id, :string, null: false
      add :stop_name, :string
      add :stop_lat, :decimal
      add :stop_lon, :decimal
      add :location_type, :integer, default: 0
      add :wheelchair_boarding, :integer
      add :parent_station_id, :binary_id
      add :level_id, :binary_id
      timestamps()
    end

    create unique_index(:stops, [:organization_id, :gtfs_version_id, :stop_id], name: :stops_organization_id_gtfs_version_id_stop_id_index)
    create unique_index(:stops, [:id, :organization_id, :gtfs_version_id])

    alter table(:stops) do
      modify :gtfs_version_id,
        references(:gtfs_versions,
          column: :id,
          with: [organization_id: :organization_id],
          match: :full,
          type: :binary_id
        )

      modify :level_id,
        references(:levels,
          column: :id,
          with: [organization_id: :organization_id, gtfs_version_id: :gtfs_version_id],
          match: :full,
          type: :binary_id
        )

      modify :parent_station_id,
        references(:stops,
          column: :id,
          with: [organization_id: :organization_id, gtfs_version_id: :gtfs_version_id],
          match: :full,
          type: :binary_id
        )
    end
  end

  def down do
    drop table(:stops)
  end
end
