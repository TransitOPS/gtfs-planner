defmodule GtfsPlanner.Repo.Migrations.CreateStopLevels do
  use Ecto.Migration

  def change do
    create table(:stop_levels, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :stop_id, references(:stops, type: :binary_id, on_delete: :delete_all), null: false
      add :level_id, references(:levels, type: :binary_id, on_delete: :delete_all), null: false
      add :diagram_filename, :string
      add :organization_id, references(:organizations, type: :binary_id), null: false
      add :gtfs_version_id, references(:gtfs_versions, type: :binary_id), null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:stop_levels, [:stop_id])
    create index(:stop_levels, [:level_id])
    create unique_index(:stop_levels, [:organization_id, :gtfs_version_id, :stop_id, :level_id])
    create index(:stop_levels, [:organization_id, :gtfs_version_id])
  end
end
