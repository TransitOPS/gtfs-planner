defmodule GtfsPlanner.Repo.Migrations.CreateFareLegRules do
  use Ecto.Migration

  def up do
    create table(:fare_leg_rules, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
          null: false
      add :gtfs_version_id, :binary_id, null: false
      add :leg_group_id, :string
      add :network_id, :string
      add :from_area_id, :string
      add :to_area_id, :string
      add :from_timeframe_group_id, :string
      add :to_timeframe_group_id, :string
      add :fare_product_id, :string
      add :rule_priority, :integer

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:fare_leg_rules, [:organization_id, :gtfs_version_id, :network_id, :from_area_id, :to_area_id, :fare_product_id],
             name: :fare_leg_rules_org_version_network_areas_product_index
           )

    create index(:fare_leg_rules, [:organization_id, :gtfs_version_id])
  end

  def down do
    drop table(:fare_leg_rules)
  end
end