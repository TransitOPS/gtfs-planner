defmodule GtfsPlanner.Repo.Migrations.CreateWalkabilityTests do
  use Ecto.Migration

  def change do
    create table(:walkability_tests, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :stop_id, :string, null: false
      add :address, :string, null: false
      add :address_lat, :decimal, null: false
      add :address_lon, :decimal, null: false
      add :description, :string
      add :expected_traversable, :boolean
      add :expected_wheelchair_accessible, :boolean
      add :expected_min_duration_seconds, :integer
      add :expected_max_duration_seconds, :integer
      add :expected_min_distance_meters, :integer
      add :expected_max_distance_meters, :integer

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:walkability_tests, [:organization_id, :stop_id, :address],
             name: :walkability_tests_organization_id_stop_id_address_index
           )

    create index(:walkability_tests, [:organization_id])
  end
end
