defmodule GtfsPlanner.Repo.Migrations.CreateTimeframes do
  use Ecto.Migration

  def up do
    create table(:timeframes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
          null: false
      add :gtfs_version_id, :binary_id, null: false
      add :timeframe_group_id, :string, null: false
      add :start_time, :string
      add :end_time, :string
      add :service_id, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:timeframes, [:organization_id, :gtfs_version_id, :timeframe_group_id, :start_time, :end_time, :service_id],
             name: :timeframes_org_id_version_id_group_id_start_end_service_id_index
           )

    create index(:timeframes, [:organization_id, :gtfs_version_id])
  end

  def down do
    drop table(:timeframes)
  end
end