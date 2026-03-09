defmodule GtfsPlanner.Repo.Migrations.AddGtfsVersionIdToWalkabilityTests do
  use Ecto.Migration

  def change do
    alter table(:walkability_tests) do
      add :gtfs_version_id, references(:gtfs_versions, type: :binary_id, on_delete: :delete_all),
        null: true
    end

    # New feature: remove legacy walkability test rows that cannot be backfilled with gtfs_version_id.
    execute("DELETE FROM walkability_tests WHERE gtfs_version_id IS NULL", "")

    alter table(:walkability_tests) do
      modify :gtfs_version_id, :binary_id, null: false
    end

    create index(
             :walkability_tests,
             [:organization_id, :gtfs_version_id, :stop_id, :address, :id],
             name: :walkability_tests_suite_selection_index
           )
  end
end
