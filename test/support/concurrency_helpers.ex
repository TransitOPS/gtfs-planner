defmodule GtfsPlanner.ConcurrencyHelpers do
  @moduledoc "Helpers for committed PostgreSQL interleaving tests."

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Repo

  def unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  def backend_pid do
    %Postgrex.Result{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
    backend
  end

  @doc """
  Deletes every row the organizations hold, then the organizations.

  An unboxed test commits its fixtures, so it removes them itself. Version ownership
  constraints refuse a version delete while any child row remains, so each
  organization-owned table is cleared in repeated passes until none is blocked by
  another. Call it from an unboxed process.
  """
  def delete_committed_scope!(organization_ids) when is_list(organization_ids) do
    %Postgrex.Result{rows: rows} =
      Repo.query!("""
      SELECT table_name FROM information_schema.columns
      WHERE table_schema = 'public' AND column_name = 'organization_id'
        AND table_name <> 'organizations'
      """)

    dumped = Enum.map(organization_ids, &Ecto.UUID.dump!/1)
    clear_tables(List.flatten(rows), dumped, 10)
    Repo.query!("DELETE FROM organizations WHERE id = ANY($1)", [dumped])
    :ok
  end

  defp clear_tables([], _organization_ids, _passes), do: :ok

  defp clear_tables(tables, _organization_ids, 0),
    do: raise("committed rows still block the delete of #{inspect(tables)}")

  defp clear_tables(tables, organization_ids, passes) do
    blocked =
      Enum.filter(tables, fn table ->
        match?(
          {:error, %Postgrex.Error{postgres: %{code: code}}}
          when code in [:foreign_key_violation, :restrict_violation],
          Repo.query("DELETE FROM #{table} WHERE organization_id = ANY($1)", [organization_ids])
        )
      end)

    clear_tables(blocked, organization_ids, passes - 1)
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
