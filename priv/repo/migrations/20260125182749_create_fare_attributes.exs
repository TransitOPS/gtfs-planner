defmodule GtfsPlanner.Repo.Migrations.CreateFareAttributes do
  use Ecto.Migration

  def up do
    create table(:fare_attributes, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :gtfs_version_id, :binary_id, null: false
      add :fare_id, :string, null: false
      add :price, :decimal, null: false
      add :currency_type, :string, null: false
      add :payment_method, :integer, null: false
      add :transfers, :integer
      add :agency_id, :string
      add :transfer_duration, :integer

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:fare_attributes, [:organization_id, :gtfs_version_id, :fare_id],
             name: :fare_attributes_organization_id_gtfs_version_id_fare_id_index
           )

    create index(:fare_attributes, [:organization_id, :gtfs_version_id])
  end

  def down do
    drop table(:fare_attributes)
  end
end
