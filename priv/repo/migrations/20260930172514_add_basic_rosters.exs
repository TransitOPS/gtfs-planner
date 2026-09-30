defmodule GtfsPlanner.Repo.Migrations.AddBasicRosters do
  use Ecto.Migration

  # Every call here is reversible, so `change/0` down drops the three
  # `blocking_settings` columns, the two settings constraints and the three
  # roster tables in reverse order.
  def change do
    create table(:operators, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :employee_id, :string, null: false
      add :display_name, :string, null: false
      add :seniority_number, :integer

      # The picker is the acting user, not a foreign key: an accounts row is
      # removed independently of operator data.
      add :updated_by_id, :binary_id

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:operators, [:organization_id, :employee_id])

    create constraint(:operators, :seniority_number_range,
             check: "seniority_number IS NULL OR seniority_number BETWEEN 1 AND 99999"
           )

    create table(:roster_lines, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :gtfs_version_id, references(:gtfs_versions, type: :binary_id, on_delete: :delete_all),
        null: false

      add :line_number, :integer, null: false

      # Deleting an operator empties their lines instead of deleting them, so
      # the line shows Open.
      add :operator_id, references(:operators, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:roster_lines, [:organization_id, :gtfs_version_id, :line_number])

    # One line per operator per version; a line with no operator holds none.
    create unique_index(:roster_lines, [:organization_id, :gtfs_version_id, :operator_id],
             where: "operator_id IS NOT NULL",
             name: :roster_lines_one_line_per_operator
           )

    create index(:roster_lines, [:operator_id])

    create constraint(:roster_lines, :line_number_positive, check: "line_number >= 1")

    create table(:roster_line_days, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :roster_line_id, references(:roster_lines, type: :binary_id, on_delete: :delete_all),
        null: false

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :gtfs_version_id, references(:gtfs_versions, type: :binary_id, on_delete: :delete_all),
        null: false

      add :weekday, :integer, null: false
      add :day_type_key, :string, null: false
      add :run_id, :string, null: false

      # The run's sign-on and sign-off when the slot was set; a mismatch with the
      # current derived run makes the slot stale.
      add :run_sign_on_secs, :integer, null: false
      add :run_sign_off_secs, :integer, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:roster_line_days, [:roster_line_id, :weekday])

    # A run is on at most one line per weekday.
    create unique_index(
             :roster_line_days,
             [:organization_id, :gtfs_version_id, :weekday, :day_type_key, :run_id],
             name: :roster_line_days_run_once_per_weekday
           )

    create constraint(:roster_line_days, :weekday_range, check: "weekday BETWEEN 1 AND 7")

    create constraint(:roster_line_days, :run_id_format, check: "run_id ~ '^[A-Za-z0-9-]{1,8}$'")

    alter table(:blocking_settings) do
      add :min_rest_minutes, :integer, null: false, default: 600
      add :weekly_hours_warn_above, :integer, null: false, default: 48
      add :roster_day_types, :map, null: false, default: %{}
    end

    # One named constraint per column, as `add_basic_runs` does, so the roster
    # settings changeset maps each rejection to its own field.
    create constraint(:blocking_settings, :min_rest_range,
             check: "min_rest_minutes BETWEEN 480 AND 720"
           )

    create constraint(:blocking_settings, :weekly_hours_warn_range,
             check: "weekly_hours_warn_above BETWEEN 40 AND 60"
           )
  end
end
