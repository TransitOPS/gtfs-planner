defmodule GtfsPlanner.Repo.Migrations.CreateGtfsValidationRuns do
  use Ecto.Migration

  def up do
    create table(:gtfs_validation_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :gtfs_version_id, references(:gtfs_versions, type: :binary_id, on_delete: :delete_all),
        null: false

      add :run_type, :string, null: false
      add :status, :string, null: false, default: "started"
      add :errors_count, :integer, default: 0
      add :warnings_count, :integer, default: 0
      add :infos_count, :integer, default: 0
      add :duration_ms, :integer
      add :result_json, :map
      add :error_details, :text
      add :started_at, :utc_datetime_usec, null: false
      add :completed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:gtfs_validation_runs, [:organization_id])
    create index(:gtfs_validation_runs, [:gtfs_version_id])
    create index(:gtfs_validation_runs, [:organization_id, :gtfs_version_id])
  end

  def down do
    drop table(:gtfs_validation_runs)
  end
end
