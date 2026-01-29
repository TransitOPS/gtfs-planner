defmodule GtfsPlanner.Repo.Migrations.RemoveGtfsForeignKeyConstraints do
  use Ecto.Migration

  def up do
    # Remove GTFS FK constraints from stops table
    drop_if_exists constraint(:stops, :stops_level_id_fkey)
    drop_if_exists constraint(:stops, :stops_parent_station_id_fkey)
    drop_if_exists constraint(:stops, :stops_gtfs_version_id_fkey)

    # Remove GTFS FK constraints from levels table
    drop_if_exists constraint(:levels, :levels_gtfs_version_id_fkey)
    drop_if_exists constraint(:levels, :levels_parent_station_id_fkey)

    # Remove GTFS FK constraints from pathways table
    drop_if_exists constraint(:pathways, :pathways_gtfs_version_id_fkey)
    drop_if_exists constraint(:pathways, :pathways_from_stop_id_fkey)
    drop_if_exists constraint(:pathways, :pathways_to_stop_id_fkey)
  end

  def down do
    # Restore GTFS FK constraints to pathways table
    alter table(:pathways) do
      modify :gtfs_version_id,
             references(:gtfs_versions,
               column: :id,
               with: [organization_id: :organization_id],
               match: :full,
               type: :binary_id
             )

      modify :from_stop_id,
             references(:stops,
               column: :id,
               with: [organization_id: :organization_id, gtfs_version_id: :gtfs_version_id],
               match: :full,
               type: :binary_id
             )

      modify :to_stop_id,
             references(:stops,
               column: :id,
               with: [organization_id: :organization_id, gtfs_version_id: :gtfs_version_id],
               match: :full,
               type: :binary_id
             )
    end

    # Restore GTFS FK constraints to levels table
    alter table(:levels) do
      modify :gtfs_version_id,
             references(:gtfs_versions,
               column: :id,
               with: [organization_id: :organization_id],
               match: :full,
               type: :binary_id
             )

      modify :parent_station_id,
             references(:stops,
               column: :id,
               with: [organization_id: :organization_id, gtfs_version_id: :gtfs_version_id],
               match: :full,
               type: :binary_id
             )
    end

    # Restore GTFS FK constraints to stops table
    alter table(:stops) do
      modify :gtfs_version_id,
             references(:gtfs_versions,
               column: :id,
               with: [organization_id: :organization_id],
               match: :full,
               type: :binary_id
             )

      modify :level_id,
             references(:levels,
               column: :id,
               with: [organization_id: :organization_id, gtfs_version_id: :gtfs_version_id],
               match: :full,
               type: :binary_id
             )

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
