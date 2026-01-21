defmodule GtfsPlanner.Repo.Migrations.CreateGtfsVersions do
  use Ecto.Migration

  def change do
    create table(:gtfs_versions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :name, :string, null: false, default: "First Version"

      timestamps(type: :utc_datetime_usec)
    end

    create index(:gtfs_versions, [:organization_id])
  end
end
