defmodule GtfsPlanner.Gtfs.ReviewedApplyTransaction do
  @moduledoc """
  Transaction boundary for fingerprint-checked coordinate application.

  The production implementation owns the serializable Repo transaction. Keeping
  this boundary explicit lets retry behavior be verified with real Postgrex
  exception values without replacing the application Repo.

  `run/2` carries trusted transaction options (currently only `:timeout`);
  adapters forward that timeout to `Repo.transaction/2` and drop every other
  option so callers cannot smuggle pool or logging controls through this seam.
  """

  @type transaction :: (-> term())
  @type options :: [{:timeout, timeout()}]

  @callback run(transaction()) :: {:ok, term()} | {:error, term()}
  @callback run(transaction(), options()) :: {:ok, term()} | {:error, term()}

  @doc """
  Returns the configured transaction adapter.

  Defaults to the SERIALIZABLE `GtfsPlanner.Gtfs.ReviewedApplyTransaction.Repo` adapter;
  test environments configure their own adapter under `:reviewed_apply_transaction`.
  """
  @spec adapter() :: module()
  def adapter do
    Application.get_env(:gtfs_planner, :reviewed_apply_transaction, __MODULE__.Repo)
  end
end
