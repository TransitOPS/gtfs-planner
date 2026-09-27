defmodule GtfsPlanner.Repo.Migrations.CreateCalendarAttributes do
  use Ecto.Migration

  def change do
    create table(:calendar_attributes, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id,
          references(:organizations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :gtfs_version_id, :binary_id, null: false
      add :service_id, :string, null: false
      add :service_description, :string
      add :service_schedule_name, :string
      add :service_schedule_type, :string
      add :service_schedule_typicality, :integer, default: 0
      add :rating_start_date, :date
      add :rating_end_date, :date
      add :rating_description, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:calendar_attributes, [:organization_id, :gtfs_version_id, :service_id])
  end
end
