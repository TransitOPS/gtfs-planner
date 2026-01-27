defmodule GtfsPlanner.Repo.Migrations.RemoveLevelStationAssociation do
  use Ecto.Migration

  def change do
    drop index(:levels, [:organization_id, :gtfs_version_id, :parent_station_id])

    alter table(:levels) do
      remove :parent_station_id
      remove :diagram_filename, :string
    end
  end
end
