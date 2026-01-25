defmodule GtfsPlanner.Repo.Migrations.CreateFareRules do
  use Ecto.Migration

  def up do
    create table(:fare_rules, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
          null: false
      add :gtfs_version_id, :binary_id, null: false
      add :fare_id, :string, null: false
      add :route_id, :string
      add :origin_id, :string
      add :destination_id, :string
      add :contains_id, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:fare_rules, [:organization_id, :gtfs_version_id, :fare_id, :route_id, :origin_id, :destination_id, :contains_id],
             name: :fare_rules_org_version_fare_route_origin_dest_contains_index
           )

    create index(:fare_rules, [:organization_id, :gtfs_version_id])
  end

  def down do
    drop table(:fare_rules)
  end
end