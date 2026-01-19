defmodule GtfsPlanner.Repo.Migrations.BackfillGtfsVersionsForExistingOrganizations do
  use Ecto.Migration

  def up do
    execute """
    INSERT INTO gtfs_versions (id, organization_id, name, inserted_at, updated_at)
    SELECT gen_random_uuid(), id, 'First Version', NOW(), NOW()
    FROM organizations
    WHERE id NOT IN (SELECT organization_id FROM gtfs_versions)
    """
  end

  def down do
    execute "DELETE FROM gtfs_versions WHERE name = 'First Version'"
  end
end