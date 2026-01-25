defmodule GtfsPlanner.Repo.Migrations.CreateRoutes do
  use Ecto.Migration

  def up do
    create table(:routes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
          null: false
      add :gtfs_version_id, :binary_id, null: false
      add :route_id, :string, null: false
      add :route_type, :integer, null: false
      add :route_short_name, :string
      add :route_long_name, :string
      add :agency_id, :string
      add :route_desc, :string
      add :route_url, :string
      add :route_color, :string, default: "FFFFFF"
      add :route_text_color, :string, default: "000000"
      add :route_sort_order, :integer
      add :continuous_pickup, :integer, default: 1
      add :continuous_drop_off, :integer, default: 1
      add :network_id, :string
      add :active, :boolean, default: true

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:routes, [:organization_id, :gtfs_version_id, :route_id],
             name: :routes_organization_id_gtfs_version_id_route_id_index
           )

    create index(:routes, [:organization_id, :gtfs_version_id])
  end

  def down do
    drop table(:routes)
  end
end