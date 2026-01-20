defmodule GtfsPlanner.Repo.Migrations.AddUniqueConstraintToGtfsVersions do
  use Ecto.Migration

  def change do
    create unique_index(:gtfs_versions, [:id, :organization_id])
  end
end
