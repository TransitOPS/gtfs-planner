defmodule GtfsPlanner.Gtfs.Import.Recovery do
  @moduledoc """
  Claimed convergent cleanup for a failed import target.

  Given a run/version/token produced by `ImportRuns.claim_cleanup/3` (or the
  organization id, run id, and lease token held by the supervisor-owned `Runner`),
  this module deletes the owned target's diagram namespace and every manifest
  schema in bounded UUID batches, verifies emptiness, then deletes the failed
  `gtfs_versions` row and closes the run through `ImportRuns`.

  Deletes are idempotent: already-absent rows and a missing namespace are
  successes, so a mid-cleanup failure followed by a later cleanup converges over
  the remaining work (AC-13). Exactly one cleanup owner is enforced upstream by
  `ImportRuns.claim_cleanup/3`; this module never re-claims.

  ## Entry points

    * `run/3` — the contract the supervised `Runner` invokes after claiming
      cleanup on behalf of an actor. It receives the organization id, run id, and
      held lease token (no re-claim).
    * `discard_claimed/3` — the public interface named by the spec; consumes a
      `%Run{}`, its `%GtfsVersion{}`, and the cleanup lease token (e.g. for the
      step-8 LiveView flow that claims then discards).

  Both delegate to the shared `cleanup_claimed/3` flow.
  """

  import Ecto.Query, warn: false

  alias GtfsPlanner.Repo
  alias GtfsPlanner.Gtfs.Import
  alias GtfsPlanner.Gtfs.ImportRuns
  alias GtfsPlanner.Gtfs.Import.Run
  alias GtfsPlanner.Gtfs.DiagramStorage
  alias GtfsPlanner.Versions.GtfsVersion

  @default_batch_size 5_000

  @doc """
  Runs claimed cleanup for a run already claimed by the `Runner`.

  `organization_id`, `run_id`, and `lease_token` are the values the supervised
  runner holds after `ImportRuns.claim_cleanup/3`. This function does NOT
  re-claim; it performs the batched cleanup flow and closes the run via
  `ImportRuns.finish_cleanup/3` (or `ImportRuns.fail_cleanup/4` on error).
  """
  @spec run(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, GtfsVersion.t() | nil} | {:error, atom()}
  def run(organization_id, run_id, lease_token) do
    cleanup_claimed(organization_id, run_id, lease_token)
  end

  @doc """
  Public interface: discard an already-claimed failed target.

  Consumes the `%Run{}` returned by `ImportRuns.claim_cleanup/3` (together with
  its `%GtfsVersion{}` and the cleanup lease token) and performs the shared
  batched cleanup flow. Returns `{:ok, nil}` (the version row is removed) or
  `{:error, atom()}` when cleanup failed and the version is retained (AC-13).
  """
  @spec discard_claimed(ImportRuns.Run.t(), GtfsVersion.t(), Ecto.UUID.t()) ::
          {:ok, nil} | {:error, atom()}
  def discard_claimed(%Run{organization_id: org_id, id: run_id}, _version, lease_token) do
    cleanup_claimed(org_id, run_id, lease_token)
  end

  # --- shared cleanup flow --------------------------------------------------

  defp cleanup_claimed(organization_id, run_id, lease_token) do
    try do
      # 1. Remove the diagram namespace first (idempotent on absence).
      maybe_inject_failure(:filesystem, :before_namespace)
      :ok = delete_namespace(organization_id, run_id, lease_token)

      # 2. Delete every manifest schema in bounded batches.
      for schema <- Import.cleanup_schemas() do
        delete_schema_batched(organization_id, run_id, lease_token, schema)
      end

      # 3. Verify every owned resource is absent.
      verify_empty(organization_id, run_id, lease_token)

      # 4. Atomically delete the failed version row and mark the run cleaned.
      #    The run retains its target/actor snapshots (set at claim time).
      finish(organization_id, run_id, lease_token)

      {:ok, nil}
    rescue
      e in RuntimeError ->
        reason = failure_reason(e)
        fail(organization_id, run_id, lease_token, reason)
        {:error, reason}
    end
  end

  defp delete_namespace(organization_id, run_id, lease_token) do
    case version_id_for(organization_id, run_id, lease_token) do
      nil ->
        :ok

      version_id ->
        case DiagramStorage.delete_version_namespace(organization_id, version_id) do
          :ok -> :ok
          {:error, _reason} -> raise RuntimeError, "filesystem_error"
        end
    end
  end

  defp delete_schema_batched(organization_id, run_id, lease_token, schema) do
    case version_id_for(organization_id, run_id, lease_token) do
      nil ->
        :ok

      version_id ->
        delete_schema_batched_for_version(
          organization_id,
          run_id,
          lease_token,
          schema,
          version_id
        )
    end
  end

  defp delete_schema_batched_for_version(
         organization_id,
         run_id,
         lease_token,
         schema,
         version_id
       ) do
    batch_size =
      Application.get_env(:gtfs_planner, :import_cleanup_batch_size, @default_batch_size)

    maybe_inject_failure(:database, schema)

    query =
      from(r in schema,
        where: r.organization_id == ^organization_id and r.gtfs_version_id == ^version_id,
        order_by: [asc: r.id],
        limit: ^batch_size,
        select: r.id
      )

    case delete_batch(query, schema) do
      {:ok, 0} ->
        :ok

      {:ok, _count} ->
        # Commit this batch separately, then continue with the next slice.
        delete_schema_batched(organization_id, run_id, lease_token, schema)

      {:error, _reason} ->
        raise RuntimeError, "database_error"
    end
  end

  defp delete_batch(query, schema) do
    Repo.transaction(fn ->
      ids = Repo.all(query)

      if ids == [] do
        0
      else
        {count, nil} =
          from(r in schema, where: r.id in ^ids)
          |> Repo.delete_all()

        count
      end
    end)
  end

  defp verify_empty(organization_id, run_id, lease_token) do
    version_id = version_id_for(organization_id, run_id, lease_token)

    namespace_absent? =
      case version_id do
        nil ->
          true

        version_id ->
          case DiagramStorage.version_namespace_exists?(organization_id, version_id) do
            {:ok, exists?} -> not exists?
            {:error, _reason} -> false
          end
      end

    if not namespace_absent? do
      raise RuntimeError, "verification_failed"
    end

    nonempty =
      if is_nil(version_id) do
        nil
      else
        Enum.find(Import.cleanup_schemas(), fn schema ->
          count =
            from(r in schema,
              where: r.organization_id == ^organization_id and r.gtfs_version_id == ^version_id
            )
            |> Repo.aggregate(:count)

          count != 0
        end)
      end

    if not is_nil(nonempty) do
      raise RuntimeError, "verification_failed"
    end

    :ok
  end

  defp finish(organization_id, run_id, lease_token) do
    case ImportRuns.finish_cleanup(organization_id, run_id, lease_token) do
      {:ok, _run} -> :ok
      {:error, _reason} -> raise RuntimeError, "database_error"
    end
  end

  defp fail(organization_id, run_id, lease_token, reason) do
    ImportRuns.fail_cleanup(organization_id, run_id, lease_token, reason)
    :ok
  end

  # Resolves the locked target version id without re-claiming. The run is in
  # `cleaning` with the matching lease token; read it (no row lock needed for
  # the scoped org+id read) to obtain the gtfs_version_id used by every scoped
  # delete. A wrong token returns nil and forces a verification failure.
  defp version_id_for(organization_id, run_id, lease_token) do
    from(r in Run,
      where:
        r.id == ^run_id and r.organization_id == ^organization_id and
          r.lease_token == ^lease_token,
      select: r.gtfs_version_id
    )
    |> Repo.one()
  end

  # --- failure injection (tests only) ---------------------------------------

  # Reads the optional `:import_cleanup_inject_failure` env. When the injection
  # matches the requested phase, raises so cleanup branches to `fail_cleanup`
  # and retains the version. Absent in production (default nil).
  defp maybe_inject_failure(phase, schema) do
    case Application.get_env(:gtfs_planner, :import_cleanup_inject_failure) do
      {^phase, ^schema} -> raise RuntimeError, Atom.to_string(phase) <> "_error"
      {^phase, :any} -> raise RuntimeError, Atom.to_string(phase) <> "_error"
      _ -> :ok
    end
  end

  defp failure_reason(%RuntimeError{message: "filesystem_error"}), do: :filesystem_error
  defp failure_reason(%RuntimeError{message: "database_error"}), do: :database_error
  defp failure_reason(%RuntimeError{message: "verification_failed"}), do: :verification_failed
  defp failure_reason(_other), do: :unknown_error
end
