defmodule GtfsPlanner.Repo.Migrations.AddUniqueIndexToGtfsVersionName do
  use Ecto.Migration

  require Logger

  # name column is varchar(255). Full UUID + " ()" = 39 chars, so the
  # original name must be truncated to 255 - 39 = 216 chars at most.
  @name_truncation 216

  def up do
    rename_duplicates()
    verify_no_remaining_duplicates()
    create unique_index(:gtfs_versions, [:organization_id, :name])
  end

  def down do
    drop unique_index(:gtfs_versions, [:organization_id, :name])
  end

  @doc false
  def rename_duplicates do
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
        SET name = left(v.name, $1) || ' (' || v.id::text || ')'
        FROM ranked r
        WHERE v.id = r.id AND r.rn > 1
        RETURNING v.id, v.organization_id, r.name, v.name
        """,
        [@name_truncation]
      )

    Enum.each(renamed, fn [id, organization_id, old_name, new_name] ->
      Logger.info(
        "Renamed duplicate gtfs_version id=#{inspect(id)} " <>
          "organization_id=#{inspect(organization_id)} " <>
          "old=#{inspect(old_name)} new=#{inspect(new_name)}"
      )
    end)
  end

  @doc false
  def verify_no_remaining_duplicates do
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
        Dedup did not eliminate all duplicates. This should be impossible: the
        rename appends the row's full UUID, which is unique per row. If you see
        this, the rename UPDATE did not run as expected.

          organization_id=#{inspect(organization_id)} name=#{inspect(name)} count=#{count}
        """
    end
  end
end
