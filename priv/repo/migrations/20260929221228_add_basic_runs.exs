defmodule GtfsPlanner.Repo.Migrations.AddBasicRuns do
  use Ecto.Migration

  def change do
    create table(:trip_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :gtfs_version_id, references(:gtfs_versions, type: :binary_id, on_delete: :delete_all),
        null: false

      add :trip_id, references(:trips, type: :binary_id, on_delete: :delete_all), null: false
      add :day_type_key, :string, null: false
      add :run_id, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:trip_runs, [:organization_id, :gtfs_version_id, :day_type_key, :trip_id])
    create index(:trip_runs, [:organization_id, :gtfs_version_id, :day_type_key, :run_id])
    create index(:trip_runs, [:trip_id])

    create constraint(:trip_runs, :run_id_format, check: "run_id ~ '^[A-Za-z0-9-]{1,8}$'")

    alter table(:blocking_settings) do
      add :report_pull_out_minutes, :integer, null: false, default: 15
      add :report_relief_minutes, :integer, null: false, default: 5
      add :sign_off_minutes, :integer, null: false, default: 5
      add :paid_break_max_minutes, :integer, null: false, default: 30
      add :max_spread_minutes, :integer, null: false, default: 720
    end

    # One named constraint per column, as spec 07 does, so `crew_changeset/2` maps
    # each rejection to its own field.
    create constraint(:blocking_settings, :report_pull_out_range,
             check: "report_pull_out_minutes BETWEEN 0 AND 30"
           )

    create constraint(:blocking_settings, :report_relief_range,
             check: "report_relief_minutes BETWEEN 0 AND 15"
           )

    create constraint(:blocking_settings, :sign_off_range,
             check: "sign_off_minutes BETWEEN 0 AND 15"
           )

    create constraint(:blocking_settings, :paid_break_max_range,
             check: "paid_break_max_minutes BETWEEN 0 AND 90"
           )

    create constraint(:blocking_settings, :max_spread_range,
             check: "max_spread_minutes BETWEEN 240 AND 1080"
           )
  end
end
