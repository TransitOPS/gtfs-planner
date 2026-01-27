defmodule GtfsPlanner.Repo.Migrations.AddStopTimesCoveringIndex do
  use Ecto.Migration

  def change do
    # Add covering index to optimize route filtering EXISTS subquery
    # This index covers: organization_id, gtfs_version_id, stop_id (WHERE clause) + trip_id (JOIN)
    create index(:stop_times, [:organization_id, :gtfs_version_id, :stop_id, :trip_id],
      name: :stop_times_org_version_stop_trip_idx
    )
  end
end