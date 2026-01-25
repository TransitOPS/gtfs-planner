defmodule GtfsPlanner.Repo.Migrations.CreateCalendars do
  use Ecto.Migration

  def change do
    create table(:calendars, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :gtfs_version_id, :binary_id, null: false
      add :service_id, :string, null: false
      add :monday, :integer, null: false
      add :tuesday, :integer, null: false
      add :wednesday, :integer, null: false
      add :thursday, :integer, null: false
      add :friday, :integer, null: false
      add :saturday, :integer, null: false
      add :sunday, :integer, null: false
      add :start_date, :date, null: false
      add :end_date, :date, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:calendars, [:organization_id, :gtfs_version_id, :service_id])
    create index(:calendars, [:organization_id, :gtfs_version_id])
  end
end
