defmodule GtfsPlanner.Gtfs.ServiceQueries.Snapshot do
  @moduledoc """
  Boundary that establishes the read snapshot for one service query.

  Every part of one `GtfsPlanner.Gtfs.ServiceQueries` answer - rows, totals,
  exclusions and the content digest - is read inside one PostgreSQL
  `REPEATABLE READ READ ONLY` transaction, so a controlled writer that commits
  between two reads cannot make the parts describe different database states
  (AC-12). The production implementation sets that isolation before the query's
  first source read. The SQL sandbox already holds an open transaction and
  cannot change its isolation, so a test selects the no-op implementation; the
  interleaving case selects the production one.
  """

  @callback begin_read() :: :ok

  alias GtfsPlanner.Repo

  @doc """
  Returns the configured snapshot boundary, defaulting to the production
  repository adapter.

  A caller that opens its own read snapshot resolves it here rather than reading
  the application environment itself, so the default and the configured test
  variant cannot drift apart.
  """
  @spec module() :: module()
  def module,
    do: Application.get_env(:gtfs_planner, :gtfs_service_query_snapshot, __MODULE__.Repo)

  @doc """
  Runs `read` inside one read-only snapshot and returns its `{:ok, result}` or
  `{:error, reason}` answer unchanged.

  `begin_read/0` is called before `read` runs its first source read, so the whole
  answer — rows, totals and digest — describes one database state, and the
  transaction is closed before the value is returned, so a caller that then waits
  on a provider or a person holds no lock.
  """
  @spec read_snapshot((-> {:ok, term()} | {:error, term()})) :: {:ok, term()} | {:error, term()}
  def read_snapshot(read) when is_function(read, 0) do
    Repo.transaction(
      fn ->
        module().begin_read()
        read.()
      end,
      timeout: :infinity
    )
    |> case do
      {:ok, {:ok, result}} -> {:ok, result}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end
end
