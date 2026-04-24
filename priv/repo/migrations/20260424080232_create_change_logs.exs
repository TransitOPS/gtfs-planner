defmodule GtfsPlanner.Repo.Migrations.CreateChangeLogs do
  use Ecto.Migration

  def change do
    create table(:change_logs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :entity_type, :string, null: false
      add :entity_id, :binary_id
      add :entity_external_id, :string, null: false
      add :station_stop_id, :string, null: false
      add :actor_id, :binary_id, null: false
      add :actor_email, :string, null: false
      add :snapshot, :map
      add :changed_fields, :map
      add :action, :string, null: false
      add :rolled_back_to_log_id,
          references(:change_logs, type: :binary_id, on_delete: :nilify_all)

      add :organization_id,
          references(:organizations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :gtfs_version_id,
          references(:gtfs_versions, type: :binary_id, on_delete: :delete_all),
          null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create constraint(:change_logs, :action_must_be_known,
      check: "action IN ('created','updated','deleted','rolled_back')")

    create index(:change_logs, [
             :organization_id,
             :gtfs_version_id,
             :station_stop_id,
             :inserted_at
           ])

    create index(:change_logs, [:entity_type, :entity_id, :inserted_at])
  end
end
