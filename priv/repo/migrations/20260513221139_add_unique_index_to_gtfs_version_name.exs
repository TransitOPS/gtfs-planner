defmodule GtfsPlanner.Repo.Migrations.AddUniqueIndexToGtfsVersionName do
  use Ecto.Migration

  require Logger

  def up do
    rename_duplicates()
    create unique_index(:gtfs_versions, [:organization_id, :name])
  end

  def down do
    drop unique_index(:gtfs_versions, [:organization_id, :name])
  end

  defp rename_duplicates do
    %{rows: renamed} =
      Ecto.Adapters.SQL.query!(
        GtfsPlanner.Repo,
        """
        WITH ranked AS (
          SELECT
            id,
            organization_id,
            name,
            ROW_NUMBER() OVER (
              PARTITION BY organization_id, name
              ORDER BY updated_at DESC, inserted_at DESC, id DESC
            ) AS rn
          FROM gtfs_versions
        )
        UPDATE gtfs_versions v
        SET name = left(v.name, 247) || ' (' || left(v.id::text, 8) || ')'
        FROM ranked r
        WHERE v.id = r.id AND r.rn > 1
        RETURNING v.id, v.organization_id, r.name, v.name
        """,
        []
      )

    Enum.each(renamed, fn [id, organization_id, old_name, new_name] ->
      Logger.info(
        "Renamed duplicate gtfs_version id=#{inspect(id)} " <>
          "organization_id=#{inspect(organization_id)} " <>
          "old=#{inspect(old_name)} new=#{inspect(new_name)}"
      )
    end)
  end
end
