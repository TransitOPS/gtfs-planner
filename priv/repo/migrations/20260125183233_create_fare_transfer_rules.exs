defmodule GtfsPlanner.Repo.Migrations.CreateFareTransferRules do
  use Ecto.Migration

  def up do
    create table(:fare_transfer_rules, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
          null: false
      add :gtfs_version_id, :binary_id, null: false
      add :from_leg_group_id, :string
      add :to_leg_group_id, :string
      add :transfer_count, :integer
      add :duration_limit, :integer
      add :duration_limit_type, :integer
      add :fare_transfer_type, :integer, null: false
      add :fare_product_id, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:fare_transfer_rules, [:organization_id, :gtfs_version_id, :from_leg_group_id, :to_leg_group_id, :fare_product_id, :transfer_count],
             name: :fare_transfer_rules_org_version_groups_product_count_index
           )

    create index(:fare_transfer_rules, [:organization_id, :gtfs_version_id])
  end

  def down do
    drop table(:fare_transfer_rules)
  end
end