defmodule GtfsPlanner.ConcurrencyHelpers do
  @moduledoc "Helpers for committed PostgreSQL interleaving tests."

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Repo

  def unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  def backend_pid do
    %Postgrex.Result{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
    backend
  end

  def await_blocker(backend, holder_backend, deadline) do
    %Postgrex.Result{rows: [[blockers]]} = Repo.query!("SELECT pg_blocking_pids($1)", [backend])

    cond do
      holder_backend in List.wrap(blockers) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, List.wrap(blockers)}

      true ->
        receive do
        after
          10 -> await_blocker(backend, holder_backend, deadline)
        end
    end
  end
end
