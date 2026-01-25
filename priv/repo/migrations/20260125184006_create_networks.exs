defmodule GtfsPlanner.Repo.Migrations.CreateNetworks do
  use Ecto.Migration

  def up do
    create table(:networks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
          null: false
      add :gtfs_version_id, :binary_id, null: false
      add :network_id, :string, null: false
      add :network_name, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:networks, [:organization_id, :gtfs_version_id, :network_id],
             name: :networks_organization_id_gtfs_version_id_network_id_index
           )

    create index(:networks, [:organization_id, :gtfs_version_id])
  end

  def down do
    drop table(:networks)
  end
end