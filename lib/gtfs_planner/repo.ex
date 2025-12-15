defmodule GtfsPlanner.Repo do
  use Ecto.Repo,
    otp_app: :gtfs_planner,
    adapter: Ecto.Adapters.Postgres
end
