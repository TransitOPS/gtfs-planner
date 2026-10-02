ExUnit.start(
  exclude: [
    :validator_cli,
    :blocking_scale,
    :transfer_scale,
    :home_perf,
    :agent_scenarios,
    :stops_map_budget
  ]
)

File.mkdir_p!(Application.fetch_env!(:gtfs_planner, :gtfs_task_artifacts_path))

Ecto.Adapters.SQL.Sandbox.mode(GtfsPlanner.Repo, :manual)
