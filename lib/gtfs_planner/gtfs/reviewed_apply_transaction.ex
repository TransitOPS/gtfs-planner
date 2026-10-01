defmodule GtfsPlanner.Gtfs.ReviewedApplyTransaction do
  @moduledoc """
  Transaction boundary for fingerprint-checked coordinate application.

  The production implementation owns the serializable Repo transaction. Keeping
  this boundary explicit lets retry behavior be verified with real Postgrex
  exception values without replacing the application Repo.

  `run/2` carries trusted transaction options (currently only `:timeout`);
  adapters forward that timeout to `Repo.transaction/2` and drop every other
  option so callers cannot smuggle pool or logging controls through this seam.

  `run/2` also carries a trusted `:isolation` option, because one caller needs a
  level the default cannot provide. `:serializable` is the default and is what
  every existing caller gets. `:read_committed` exists for a writer whose safety
  argument rests on an exclusive row lock it takes itself rather than on
  snapshot isolation: `GtfsPlanner.Gtfs.Transfers.apply_reviewed_policy_change/2`
  locks the actor's membership and then the version `FOR UPDATE`, and must then
  re-read the dependency fingerprint under that fence. PostgreSQL fixes a
  SERIALIZABLE transaction's snapshot at its first statement, which is the
  membership lock, so a post-fence read there cannot observe a writer that
  committed while the fence waited for its share lock. At READ COMMITTED each
  statement takes a fresh snapshot, the fence holds every cooperating writer off
  until the apply commits, and the re-read therefore sees exactly the state the
  fingerprint describes.
  """

  @type transaction :: (-> term())
  @type options :: [{:timeout, timeout()} | {:isolation, isolation()}]

  @typedoc "The transaction isolation levels a caller may request."
  @type isolation :: :serializable | :read_committed

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
