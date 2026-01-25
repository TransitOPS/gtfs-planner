defmodule GtfsPlanner.Repo.Migrations.AddParentStationIdToLevels do
  use Ecto.Migration

  def change do
    alter table(:levels) do
      add :parent_station_id, references(:stops, type: :binary_id, on_delete: :delete_all)
    end

    create index(:levels, [:organization_id, :gtfs_version_id, :parent_station_id])
  end
end
