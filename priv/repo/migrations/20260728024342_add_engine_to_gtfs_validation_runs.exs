defmodule GtfsPlanner.Repo.Migrations.AddEngineToGtfsValidationRuns do
  use Ecto.Migration

  def change do
    alter table(:gtfs_validation_runs) do
      add :engine, :string
      add :result_schema_version, :integer
    end

    create unique_index(
             :gtfs_validation_runs,
             [:organization_id, :gtfs_version_id, "(result_json -> 'metadata' ->> 'station_stop_id')"],
             name: :gtfs_validation_runs_active_station_reachability_index,
             where: "run_type = 'station_reachability' AND status IN ('pending', 'started', 'running')"
           )
  end
end
