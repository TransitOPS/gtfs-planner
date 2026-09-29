defmodule GtfsPlanner.Repo.Migrations.AddHomepageReadIndexes do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    create index(:change_logs, [:organization_id, :gtfs_version_id, :actor_id, :inserted_at],
             concurrently: true,
             name: :change_logs_org_version_actor_inserted_index
           )

    execute("""
    CREATE INDEX CONCURRENTLY gtfs_validation_runs_reachability_station_index
    ON gtfs_validation_runs (
      organization_id,
      gtfs_version_id,
      ((result_json->'metadata'->>'station_stop_id')),
      inserted_at DESC
    )
    WHERE run_type = 'station_reachability' AND status = 'completed'
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS change_logs_org_version_actor_inserted_index")

    execute("DROP INDEX CONCURRENTLY IF EXISTS gtfs_validation_runs_reachability_station_index")
  end
end
