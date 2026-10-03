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

  @doc """
  Validates the exact bytes one artifact-bound validation run selected.

  Unlike `validate/3`, which exports current database state, this reads the
  artifact the run recorded (`artifact_sha256`, export run and slot) and reports
  on exactly those bytes.

  ## Parameters
    - `organization_id` - The organization ID
    - `validation_run_id` - The artifact-bound validation run
    - `opts` - Options keyword list

  ## Returns
    - `{:ok, %GtfsPlanner.Gtfs.Validator.Result{}}` on successful validation
    - `{:error, reason}` on failure
  """
  @callback validate_artifact(
              organization_id :: integer(),
              validation_run_id :: integer(),
              opts :: keyword()
            ) ::
              {:ok, GtfsPlanner.Gtfs.Validator.Result.t()} | {:error, term()}
end
