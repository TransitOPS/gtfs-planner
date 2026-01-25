defmodule GtfsPlanner.Repo.Migrations.CreateLocations do
  use Ecto.Migration

  def up do
    create table(:locations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
          null: false
      add :gtfs_version_id, :binary_id, null: false
      add :location_id, :string, null: false
      add :location_name, :string
      add :location_lat, :decimal
      add :location_lon, :decimal

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:locations, [:organization_id, :gtfs_version_id, :location_id],
             name: :locations_organization_id_gtfs_version_id_location_id_index
           )

    create index(:locations, [:organization_id, :gtfs_version_id])
  end

  def down do
    drop table(:locations)
  end
end