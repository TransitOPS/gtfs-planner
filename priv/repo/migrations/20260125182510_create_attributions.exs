defmodule GtfsPlanner.Repo.Migrations.CreateAttributions do
  use Ecto.Migration

  def up do
    create table(:attributions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
          null: false
      add :gtfs_version_id, :binary_id, null: false
      add :attribution_id, :string
      add :agency_id, :string
      add :route_id, :string
      add :trip_id, :string
      add :organization_name, :string, null: false
      add :is_producer, :integer
      add :is_operator, :integer
      add :is_authority, :integer
      add :attribution_url, :string
      add :attribution_email, :string
      add :attribution_phone, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:attributions, [:organization_id, :gtfs_version_id, :attribution_id],
             name: :attributions_organization_id_gtfs_version_id_attribution_id_index
           )

    create index(:attributions, [:organization_id, :gtfs_version_id])
  end

  def down do
    drop table(:attributions)
  end
end