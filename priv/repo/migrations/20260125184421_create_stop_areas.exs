defmodule GtfsPlanner.Repo.Migrations.CreateStopAreas do
  use Ecto.Migration

  def up do
    create table(:stop_areas, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
          null: false
      add :gtfs_version_id, :binary_id, null: false
      add :area_id, :string, null: false
      add :stop_id, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:stop_areas, [:organization_id, :gtfs_version_id, :area_id, :stop_id],
             name: :stop_areas_organization_id_gtfs_version_id_area_id_stop_id_index
           )

    create index(:stop_areas, [:organization_id, :gtfs_version_id])
  end

  def down do
    drop table(:stop_areas)
  end
end