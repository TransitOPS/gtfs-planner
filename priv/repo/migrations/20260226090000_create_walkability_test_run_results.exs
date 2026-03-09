defmodule GtfsPlanner.Repo.Migrations.CreateWalkabilityTestRunResults do
  use Ecto.Migration

  def change do
    create table(:walkability_test_run_results, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :validation_run_id,
          references(:gtfs_validation_runs, type: :binary_id, on_delete: :delete_all),
          null: false

      add :walkability_test_id,
          references(:walkability_tests, type: :binary_id, on_delete: :delete_all),
          null: false

      add :order_index, :integer, null: false
      add :status, :string, null: false
      add :failure_category, :string

      add :route_exists, :boolean
      add :duration_seconds, :float
      add :distance_meters, :float

      add :wheelchair_route_exists, :boolean
      add :wheelchair_duration_seconds, :float
      add :wheelchair_distance_meters, :float

      add :details_json, :map

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(
             :walkability_test_run_results,
             :walkability_test_run_results_status_check,
             check: "status IN ('passed', 'failed')"
           )

    create constraint(
             :walkability_test_run_results,
             :walkability_test_run_results_failure_category_check,
             check:
               "failure_category IS NULL OR failure_category IN ('query_failure', 'scoring_failure')"
           )

    create constraint(
             :walkability_test_run_results,
             :walkability_test_run_results_order_index_non_negative_check,
             check: "order_index >= 0"
           )

    create index(:walkability_test_run_results, [:validation_run_id])
    create index(:walkability_test_run_results, [:walkability_test_id])

    create unique_index(
             :walkability_test_run_results,
             [:validation_run_id, :walkability_test_id],
             name: :walkability_test_run_results_run_case_unique_index
           )

    create unique_index(
             :walkability_test_run_results,
             [:validation_run_id, :order_index],
             name: :walkability_test_run_results_run_order_unique_index
           )
  end
end
