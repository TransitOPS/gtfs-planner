defmodule GtfsPlanner.Gtfs.ValidatorBehaviour do
  @moduledoc """
  Behaviour for GTFS validation modules.

  This behaviour defines the contract for validating GTFS data. It allows
  for different implementations (e.g., real validator vs mocked validator
  in tests).
  """

  @doc """
  Validates GTFS data for a specific organization and version.

  ## Parameters
    - `organization_id` - The organization ID
    - `gtfs_version_id` - The GTFS version ID to validate
    - `opts` - Options keyword list, must include `:validation_id` for PubSub topic

  ## Returns
    - `{:ok, %GtfsPlanner.Gtfs.Validator.Result{}}` on successful validation
    - `{:error, reason}` on failure
  """
  @callback validate(
              organization_id :: integer(),
              gtfs_version_id :: integer(),
              opts :: keyword()
            ) ::
              {:ok, GtfsPlanner.Gtfs.Validator.Result.t()} | {:error, term()}
end