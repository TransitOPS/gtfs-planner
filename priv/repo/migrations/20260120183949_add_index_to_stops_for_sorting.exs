defmodule GtfsPlanner.Repo.Migrations.AddIndexToStopsForSorting do
  use Ecto.Migration

  def change do
    create index(:stops, [:organization_id, :gtfs_version_id, :stop_name])
  end
end
