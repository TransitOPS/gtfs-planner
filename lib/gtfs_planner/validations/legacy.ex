defmodule GtfsPlanner.Validations.Legacy do
  @moduledoc """
  Read-only boundary for OTP-era station and pathways-test results.
  """

  import Ecto.Query

  alias GtfsPlanner.Repo
  alias GtfsPlanner.Validations.{ValidationRun, WalkabilityTest, WalkabilityTestRunResult}

  @spec legacy_station_run?(ValidationRun.t()) :: boolean()
  def legacy_station_run?(%ValidationRun{engine: engine}), do: is_nil(engine)

  @spec list_run_results(Ecto.UUID.t()) :: [WalkabilityTestRunResult.t()]
  def list_run_results(validation_run_id) do
    WalkabilityTestRunResult
    |> where([r], r.validation_run_id == ^validation_run_id)
    |> preload([:walkability_test])
    |> order_by([r], asc: r.order_index)
    |> Repo.all()
  end

  @spec list_tests_for_version(Ecto.UUID.t(), Ecto.UUID.t()) :: [WalkabilityTest.t()]
  def list_tests_for_version(organization_id, gtfs_version_id) do
    WalkabilityTest
    |> where(
      [t],
      t.organization_id == ^organization_id and t.gtfs_version_id == ^gtfs_version_id
    )
    |> order_by([t], asc: t.inserted_at)
    |> Repo.all()
  end
end
