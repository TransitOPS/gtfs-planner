defmodule GtfsPlanner.Repo.Migrations.CreateRouteNetworks do
  use Ecto.Migration

  def up do
    create table(:route_networks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
          null: false
      add :gtfs_version_id, :binary_id, null: false
      add :network_id, :string, null: false
      add :route_id, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:route_networks, [:organization_id, :gtfs_version_id, :network_id, :route_id],
             name: :route_networks_organization_id_gtfs_version_id_network_id_route_id_index
           )

    create index(:route_networks, [:organization_id, :gtfs_version_id])
  end

  def down do
    drop table(:route_networks)
  end
end