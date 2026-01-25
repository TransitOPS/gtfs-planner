defmodule GtfsPlanner.Repo.Migrations.CreateFareLegJoinRules do
  use Ecto.Migration

  def up do
    create table(:fare_leg_join_rules, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :gtfs_version_id, :binary_id, null: false
      add :from_network_id, :string
      add :to_network_id, :string
      add :from_stop_id, :string
      add :to_stop_id, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(
             :fare_leg_join_rules,
             [
               :organization_id,
               :gtfs_version_id,
               :from_network_id,
               :to_network_id,
               :from_stop_id,
               :to_stop_id
             ], name: :fare_leg_join_rules_org_version_networks_stops_index)

    create index(:fare_leg_join_rules, [:organization_id, :gtfs_version_id])
  end

  def down do
    drop table(:fare_leg_join_rules)
  end
end
