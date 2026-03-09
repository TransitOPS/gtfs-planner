defmodule GtfsPlanner.Repo.Migrations.ScopeWalkabilityTestUniquenessByGtfsVersion do
  use Ecto.Migration

  def change do
    drop_if_exists(
      unique_index(:walkability_tests, [:organization_id, :stop_id, :address],
        name: :walkability_tests_organization_id_stop_id_address_index
      )
    )

    create unique_index(
             :walkability_tests,
             [:organization_id, :gtfs_version_id, :stop_id, :address],
             name: :walkability_tests_organization_id_gtfs_version_id_stop_id_address_index
           )
  end
end
