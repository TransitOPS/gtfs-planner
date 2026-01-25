defmodule GtfsPlanner.Repo.Migrations.CreateStopTimes do
  use Ecto.Migration

  def change do
    create table(:stop_times, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id), null: false
      add :gtfs_version_id, :binary_id, null: false
      add :trip_id, :string, null: false
      add :stop_id, :string, null: false
      add :stop_sequence, :integer, null: false
      add :arrival_time, :string
      add :departure_time, :string
      add :stop_headsign, :string
      add :pickup_type, :integer
      add :drop_off_type, :integer
      add :continuous_pickup, :integer
      add :continuous_drop_off, :integer
      add :shape_dist_traveled, :decimal
      add :timepoint, :integer

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:stop_times, [:organization_id, :gtfs_version_id, :trip_id, :stop_sequence])
    create index(:stop_times, [:organization_id, :gtfs_version_id])
    create index(:stop_times, [:organization_id, :gtfs_version_id, :trip_id])
    create index(:stop_times, [:organization_id, :gtfs_version_id, :stop_id])
  end
end