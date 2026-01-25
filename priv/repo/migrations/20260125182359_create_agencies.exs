defmodule GtfsPlanner.Repo.Migrations.CreateAgencies do
  use Ecto.Migration

  def up do
    create table(:agencies, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
          null: false
      add :gtfs_version_id, :binary_id, null: false
      add :agency_id, :string
      add :agency_name, :string, null: false
      add :agency_url, :string, null: false
      add :agency_timezone, :string, null: false
      add :agency_lang, :string
      add :agency_phone, :string
      add :agency_fare_url, :string
      add :agency_email, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:agencies, [:organization_id, :gtfs_version_id, :agency_id],
             name: :agencies_organization_id_gtfs_version_id_agency_id_index
           )

    create index(:agencies, [:organization_id, :gtfs_version_id])
  end

  def down do
    drop table(:agencies)
  end
end