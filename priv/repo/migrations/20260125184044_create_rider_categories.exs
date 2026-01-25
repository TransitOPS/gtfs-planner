defmodule GtfsPlanner.Repo.Migrations.CreateRiderCategories do
  use Ecto.Migration

  def up do
    create table(:rider_categories, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :gtfs_version_id, :binary_id, null: false
      add :rider_category_id, :string, null: false
      add :rider_category_name, :string, null: false
      add :min_age, :integer
      add :max_age, :integer
      add :eligibility_url, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(
             :rider_categories,
             [:organization_id, :gtfs_version_id, :rider_category_id],
             name: :rider_categories_organization_id_gtfs_version_id_rider_category_id_index
           )

    create index(:rider_categories, [:organization_id, :gtfs_version_id])
  end

  def down do
    drop table(:rider_categories)
  end
end
