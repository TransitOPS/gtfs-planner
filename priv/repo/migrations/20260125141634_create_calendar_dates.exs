defmodule GtfsPlanner.Repo.Migrations.CreateCalendarDates do
  use Ecto.Migration

  def change do
    create table(:calendar_dates, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id), null: false
      add :gtfs_version_id, :binary_id, null: false
      add :service_id, :string, null: false
      add :date, :date, null: false
      add :exception_type, :integer, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:calendar_dates, [:organization_id, :gtfs_version_id, :service_id, :date])
    create index(:calendar_dates, [:organization_id, :gtfs_version_id])
    create index(:calendar_dates, [:organization_id, :gtfs_version_id, :service_id])
  end
end