defmodule GtfsPlanner.Repo.Migrations.AddItineraryFieldsToWalkabilityTestRunResults do
  use Ecto.Migration

  def change do
    alter table(:walkability_test_run_results) do
      add :itinerary_start_time, :utc_datetime_usec
      add :itinerary_end_time, :utc_datetime_usec
      add :leg_count, :integer
      add :step_count, :integer
      add :itinerary_steps_json, :map
    end

    create constraint(
             :walkability_test_run_results,
             :walkability_test_run_results_leg_count_non_negative_check,
             check: "leg_count IS NULL OR leg_count >= 0"
           )

    create constraint(
             :walkability_test_run_results,
             :walkability_test_run_results_step_count_non_negative_check,
             check: "step_count IS NULL OR step_count >= 0"
           )
  end
end
