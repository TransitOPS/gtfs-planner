defmodule GtfsPlanner.Repo.Migrations.CreateStationEditingStatuses do
  use Ecto.Migration

  def change do
    create table(:station_editing_statuses, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id,
          references(:organizations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :gtfs_version_id,
          references(:gtfs_versions, type: :binary_id, on_delete: :delete_all),
          null: false

      add :station_id,
          references(:stops, type: :binary_id, on_delete: :delete_all),
          null: false

      add :user_id,
          references(:users, type: :binary_id, on_delete: :delete_all),
          null: false

      add :started_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(
             :station_editing_statuses,
             [:organization_id, :gtfs_version_id, :station_id],
             name: :station_editing_statuses_station_scope_index
           )

    create index(:station_editing_statuses, [:user_id])
  end
end
