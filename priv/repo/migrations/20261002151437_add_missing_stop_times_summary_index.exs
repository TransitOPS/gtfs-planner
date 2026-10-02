defmodule GtfsPlanner.Repo.Migrations.AddMissingStopTimesSummaryIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create index(:stop_times, [:organization_id, :gtfs_version_id, :trip_id],
             name: :stop_times_missing_times_trip_index,
             concurrently: true,
             where:
               "arrival_time IS NULL OR arrival_time = '' OR departure_time IS NULL OR departure_time = ''"
           )
  end
end
