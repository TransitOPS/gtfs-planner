defmodule GtfsPlanner.Repo.Migrations.AddUniqueIndexToGtfsVersionName do
  use Ecto.Migration

  def up do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        GtfsPlanner.Repo,
        """
        SELECT organization_id, name, COUNT(*) AS count
        FROM gtfs_versions
        GROUP BY organization_id, name
        HAVING COUNT(*) > 1
        LIMIT 1
        """,
        []
      )

    case rows do
      [] ->
        :ok

      [[organization_id, name, count]] ->
        raise """
        Cannot create unique index on gtfs_versions(organization_id, name): duplicate names exist.
        organization_id=#{inspect(organization_id)} name=#{inspect(name)} count=#{count}.
        Resolve duplicates (rename or delete) before re-running this migration.
        """
    end

    create unique_index(:gtfs_versions, [:organization_id, :name])
  end

  def down do
    drop unique_index(:gtfs_versions, [:organization_id, :name])
  end
end
