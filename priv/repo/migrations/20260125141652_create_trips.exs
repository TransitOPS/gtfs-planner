defmodule GtfsPlanner.Repo.Migrations.CreateTrips do
  use Ecto.Migration

  def change do
    create table(:trips, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id), null: false
      add :gtfs_version_id, :binary_id, null: false
      add :trip_id, :string, null: false
      add :route_id, :string, null: false
      add :service_id, :string, null: false
      add :trip_headsign, :string
      add :trip_short_name, :string
      add :direction_id, :integer
      add :block_id, :string
      add :shape_id, :string
      add :wheelchair_accessible, :integer
      add :bikes_allowed, :integer
      add :cars_allowed, :integer

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:trips, [:organization_id, :gtfs_version_id, :trip_id])
    create index(:trips, [:organization_id, :gtfs_version_id])
    create index(:trips, [:organization_id, :gtfs_version_id, :route_id])
    create index(:trips, [:organization_id, :gtfs_version_id, :service_id])
  end
end