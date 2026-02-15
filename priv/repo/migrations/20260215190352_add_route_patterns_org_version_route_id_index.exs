defmodule GtfsPlanner.Repo.Migrations.AddRoutePatternsOrgVersionRouteIdIndex do
  use Ecto.Migration

  def change do
    create index(:route_patterns, [:organization_id, :gtfs_version_id, :route_id])
  end
end
