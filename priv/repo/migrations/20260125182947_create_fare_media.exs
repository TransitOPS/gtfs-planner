defmodule GtfsPlanner.Repo.Migrations.CreateFareMedia do
  use Ecto.Migration

  def up do
    create table(:fare_media, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
          null: false
      add :gtfs_version_id, :binary_id, null: false
      add :fare_media_id, :string, null: false
      add :fare_media_name, :string
      add :fare_media_type, :integer, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:fare_media, [:organization_id, :gtfs_version_id, :fare_media_id],
             name: :fare_media_organization_id_gtfs_version_id_fare_media_id_index
           )

    create index(:fare_media, [:organization_id, :gtfs_version_id])
  end

  def down do
    drop table(:fare_media)
  end
end