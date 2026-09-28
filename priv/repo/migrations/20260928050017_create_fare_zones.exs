defmodule GtfsPlanner.Repo.Migrations.CreateFareZones do
  use Ecto.Migration

  def change do
    create table(:fare_zones, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id,
          references(:organizations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :gtfs_version_id, :binary_id, null: false
      add :zone_id, :string, null: false
      add :name, :string, null: false
      add :color, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:fare_zones, [:organization_id, :gtfs_version_id, :zone_id])
  end
end
