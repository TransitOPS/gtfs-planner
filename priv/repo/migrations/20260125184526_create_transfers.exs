defmodule GtfsPlanner.Repo.Migrations.CreateTransfers do
  use Ecto.Migration

  def up do
    create table(:transfers, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
          null: false
      add :gtfs_version_id, :binary_id, null: false
      add :from_stop_id, :string, null: false
      add :to_stop_id, :string, null: false
      add :from_route_id, :string
      add :to_route_id, :string
      add :from_trip_id, :string
      add :to_trip_id, :string
      add :transfer_type, :integer, null: false
      add :min_transfer_time, :integer

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:transfers, [:organization_id, :gtfs_version_id, :from_stop_id, :to_stop_id, :from_route_id, :to_route_id, :from_trip_id, :to_trip_id],
             name: :transfers_org_id_version_id_from_to_stop_route_trip_index
           )

    create index(:transfers, [:organization_id, :gtfs_version_id])
  end

  def down do
    drop table(:transfers)
  end
end