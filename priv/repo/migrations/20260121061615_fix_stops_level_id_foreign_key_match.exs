defmodule GtfsPlanner.Repo.Migrations.FixStopsLevelIdForeignKeyMatch do
  use Ecto.Migration

  def up do
    # Drop the existing foreign key constraint with match: :full
    drop constraint(:stops, "stops_level_id_fkey")

    # Recreate with match: :simple (default) to allow NULL level_id
    # when organization_id and gtfs_version_id are set
    alter table(:stops) do
      modify :level_id,
             references(:levels,
               column: :id,
               with: [organization_id: :organization_id, gtfs_version_id: :gtfs_version_id],
               match: :simple,
               type: :binary_id
             )
    end
  end

  def down do
    drop constraint(:stops, "stops_level_id_fkey")

    alter table(:stops) do
      modify :level_id,
             references(:levels,
               column: :id,
               with: [organization_id: :organization_id, gtfs_version_id: :gtfs_version_id],
               match: :full,
               type: :binary_id
             )
    end
  end
end
