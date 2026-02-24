defmodule GtfsPlanner.Repo.Migrations.AddGtfsVersionIdToWalkabilityTests do
  use Ecto.Migration

  def change do
    alter table(:walkability_tests) do
      add :gtfs_version_id, references(:gtfs_versions, type: :binary_id, on_delete: :delete_all),
        null: false
    end

    create index(
             :walkability_tests,
             [:organization_id, :gtfs_version_id, :stop_id, :address, :id],
             name: :walkability_tests_suite_selection_index
           )
  end
end
