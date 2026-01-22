defmodule GtfsPlanner.Repo.Migrations.FixStopsParentStationIdForeignKeyMatch do
  use Ecto.Migration

  def up do
    # Drop the existing foreign key constraint with match: :full
    drop constraint(:stops, "stops_parent_station_id_fkey")

    # Recreate with match: :simple (default) to allow NULL parent_station_id
    # when organization_id and gtfs_version_id are set
    alter table(:stops) do
      modify :parent_station_id,
             references(:stops,
               column: :id,
               with: [organization_id: :organization_id, gtfs_version_id: :gtfs_version_id],
               match: :simple,
               type: :binary_id
             )
    end
  end

  def down do
    drop constraint(:stops, "stops_parent_station_id_fkey")

    alter table(:stops) do
      modify :parent_station_id,
             references(:stops,
               column: :id,
               with: [organization_id: :organization_id, gtfs_version_id: :gtfs_version_id],
               match: :full,
               type: :binary_id
             )
    end
  end
end
