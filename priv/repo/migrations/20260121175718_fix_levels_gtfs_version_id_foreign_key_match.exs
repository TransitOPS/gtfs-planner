defmodule GtfsPlanner.Repo.Migrations.FixLevelsGtfsVersionIdForeignKeyMatch do
  use Ecto.Migration

  def up do
    # First, ensure the gtfs_versions table has a unique constraint (not just index)
    # for the composite key (id, organization_id) that foreign keys can reference
    # This is required for match: :simple foreign keys
    execute """
      ALTER TABLE gtfs_versions
      ADD CONSTRAINT gtfs_versions_id_organization_id_unique
      UNIQUE (id, organization_id)
    """

    # Drop the existing foreign key constraint
    drop constraint(:levels, "levels_gtfs_version_id_fkey")

    # Recreate with match: :simple (default) to allow proper foreign key references
    alter table(:levels) do
      modify :gtfs_version_id,
        references(:gtfs_versions,
          column: :id,
          with: [organization_id: :organization_id],
          match: :simple,
          type: :binary_id
        )
    end
  end

  def down do
    # Drop the foreign key constraint
    drop constraint(:levels, "levels_gtfs_version_id_fkey")

    # Recreate with match: :full (original)
    alter table(:levels) do
      modify :gtfs_version_id,
        references(:gtfs_versions,
          column: :id,
          with: [organization_id: :organization_id],
          match: :full,
          type: :binary_id
        )
    end

    # Drop the unique constraint we added
    execute """
      ALTER TABLE gtfs_versions
      DROP CONSTRAINT IF EXISTS gtfs_versions_id_organization_id_unique
    """
  end
end
