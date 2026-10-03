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
  Deletes the organizations' members (see `delete_committed_members!/1`), every row
  the organizations hold, then the organizations. The active schedule of each is
  cleared first so its versions can go.

  An unboxed test commits its fixtures, so it removes them itself. Version ownership
  constraints refuse a version delete while any child row remains, so each
  organization-owned table is cleared in repeated passes until none is blocked by
  another. Call it from an unboxed process.
  """
  def delete_committed_scope!(organization_ids) when is_list(organization_ids) do
    delete_committed_members!(organization_ids)

    # The active schedule's key refuses a delete of the active version alone.
    Repo.query!(
      "UPDATE organizations SET active_gtfs_version_id = NULL WHERE id = ANY($1)",
      [Enum.map(organization_ids, &Ecto.UUID.dump!/1)]
    )

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

  @doc """
  Deletes the users whose memberships all belong to the organizations, with their
  memberships and tokens.

  Fixtures that need an actor, such as `garage_fixture/2` and `editor_audit_fixture/2`,
  create an editor for the organization when it has none, so an unboxed test commits a
  user it never names. Deleting the organization removes the membership but not the
  user. Call it from an unboxed process before the organizations' memberships go.
  """
  def delete_committed_members!(organization_ids) when is_list(organization_ids) do
    dumped = Enum.map(organization_ids, &Ecto.UUID.dump!/1)

    Repo.query!(
      """
      DELETE FROM users
      WHERE id IN (SELECT user_id FROM user_org_memberships WHERE organization_id = ANY($1))
        AND id NOT IN (SELECT user_id FROM user_org_memberships WHERE organization_id <> ALL($1))
      """,
      [dumped]
    )

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
