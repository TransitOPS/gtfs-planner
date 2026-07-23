defmodule GtfsPlanner.Gtfs.ReviewedApplyTransaction do
  @moduledoc """
  Transaction boundary for fingerprint-checked coordinate application.

  The production implementation owns the serializable Repo transaction. Keeping
  this boundary explicit lets retry behavior be verified with real Postgrex
  exception values without replacing the application Repo.
  """

  @callback run((-> term())) :: {:ok, term()} | {:error, term()}
end
