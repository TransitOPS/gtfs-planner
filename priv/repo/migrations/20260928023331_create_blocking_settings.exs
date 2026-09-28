defmodule GtfsPlanner.Repo.Migrations.CreateBlockingSettings do
  use Ecto.Migration

  def change do
    create table(:blocking_settings, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :gtfs_version_id, references(:gtfs_versions, type: :binary_id, on_delete: :delete_all),
        null: false

      add :min_layover_minutes, :integer, null: false, default: 5

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:blocking_settings, [:organization_id, :gtfs_version_id])

    create constraint(:blocking_settings, :min_layover_range,
             check: "min_layover_minutes BETWEEN 0 AND 120"
           )

    create index(:trips, [:organization_id, :gtfs_version_id, :service_id, :block_id])
  end
end
