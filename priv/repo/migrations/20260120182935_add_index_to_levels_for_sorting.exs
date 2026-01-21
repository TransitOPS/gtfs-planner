defmodule GtfsPlanner.Repo.Migrations.AddIndexToLevelsForSorting do
  use Ecto.Migration

  def change do
    create index(:levels, [:organization_id, :gtfs_version_id, :level_index])
  end
end
