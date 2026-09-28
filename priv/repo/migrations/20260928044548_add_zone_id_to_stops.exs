defmodule GtfsPlanner.Repo.Migrations.AddZoneIdToStops do
  use Ecto.Migration

  def change do
    alter table(:stops) do
      add :zone_id, :string
    end

    create index(:stops, [:organization_id, :gtfs_version_id, :zone_id])
  end
end
