defmodule GtfsPlanner.Repo.Migrations.CreateFareProducts do
  use Ecto.Migration

  def up do
    create table(:fare_products, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
          null: false
      add :gtfs_version_id, :binary_id, null: false
      add :fare_product_id, :string, null: false
      add :fare_product_name, :string, null: false
      add :fare_media_id, :string
      add :amount, :decimal, null: false
      add :currency, :string, null: false
      add :rider_category_id, :string
      add :bundle_amount, :integer
      add :duration_start, :integer
      add :duration_amount, :integer
      add :duration_unit, :integer

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:fare_products, [:organization_id, :gtfs_version_id, :fare_product_id, :fare_media_id],
             name: :fare_products_org_version_product_id_media_id_index
           )

    create index(:fare_products, [:organization_id, :gtfs_version_id])
  end

  def down do
    drop table(:fare_products)
  end
end