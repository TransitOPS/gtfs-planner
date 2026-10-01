defmodule GtfsPlanner.Gtfs.Import.Recovery do
  @moduledoc """
  Claimed convergent cleanup for a failed import target.

  Given a run/version/token produced by `ImportRuns.claim_cleanup/3` (or the
  organization id, run id, and lease token held by the supervisor-owned `Runner`),
  this module detaches trip pattern links, deletes every manifest schema in
  bounded UUID batches, deletes the owned target's diagram namespace, verifies
  emptiness, then deletes the failed `gtfs_versions` row and closes the run
  through `ImportRuns`.

  Every database write is fenced (INV-4): the run read and each write
  transaction start with `ImportRuns.assert_owner!/4`, which share-locks the run
  and requires it to be `cleaning` under this lease token with an unexpired
  lease. A cleanup that was superseded (reconciled, closed or re-claimed) stops
  with `{:error, :lease_lost}`, writes nothing further and does not try to close
  the run. The namespace deletion comes after the last fenced batch so a
  superseded owner that fails its first fence never deletes files; the
  filesystem step is ordered after the fence but is not itself fenced.

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
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Versions.GtfsVersion

  @default_batch_size 5_000
  @cleaning_states ~w(cleaning)

  @doc """
  Runs claimed cleanup for a run already claimed by the `Runner`.

  `organization_id`, `run_id`, and `lease_token` are the values the supervised
  runner holds after `ImportRuns.claim_cleanup/3`. This function does NOT
  re-claim; it performs the batched cleanup flow and closes the run via
  `ImportRuns.finish_cleanup/3` (or `ImportRuns.fail_cleanup/4` on error). When
  the lease is no longer held it returns `{:error, :lease_lost}` without closing
  the run.
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
  @spec discard_claimed(Run.t(), GtfsVersion.t(), Ecto.UUID.t()) ::
          {:ok, nil} | {:error, atom()}
  def discard_claimed(%Run{organization_id: org_id, id: run_id}, _version, lease_token) do
    cleanup_claimed(org_id, run_id, lease_token)
  end

  # --- shared cleanup flow --------------------------------------------------

  # `fence` is `{organization_id, run_id, lease_token}`. A superseded owner leaves
  # the flow through `throw(:lease_lost)` from `fenced_transaction/2`, so nothing
  # after the failed fence runs and the run is not closed by the stale token.
  defp cleanup_claimed(organization_id, run_id, lease_token) do
    fence = {organization_id, run_id, lease_token}

    try do
      version_id = fenced_version_id(fence)

      # 1. Detach trip pattern links before deleting the pattern tables: the
      #    `trips.timed_pattern_id` foreign key is RESTRICT while `trips` is
      #    deleted later in the manifest. Resetting the classification to pending
      #    is the only combination the trips check constraint accepts.
      detach_trip_pattern_links(fence, version_id)

      # 2. Delete every manifest schema in bounded, fenced batches.
      for schema <- Import.cleanup_schemas() do
        delete_schema_batched(fence, schema, version_id)
      end

      # 3. Remove the diagram namespace after the last fenced batch (idempotent
      #    on absence). Filesystem deletion cannot be rolled back or fenced, so it
      #    follows every fenced database write.
      maybe_inject_failure(:filesystem, :before_namespace)
      :ok = delete_namespace(organization_id, version_id)

      # 4. Verify every owned resource is absent.
      verify_empty(organization_id, version_id)

      # 5. Atomically delete the failed version row and mark the run cleaned.
      #    The run retains its target/actor snapshots (set at claim time).
      finish(organization_id, run_id, lease_token)

      {:ok, nil}
    rescue
      e ->
        reason = failure_reason(e)
        fail(organization_id, run_id, lease_token, reason)
        {:error, reason}
    catch
      :throw, :lease_lost -> {:error, :lease_lost}
    end
  end

  # Runs `fun` with the locked run in a transaction whose first statement is the
  # owner fence (INV-4), and leaves the cleanup flow when the fence fails.
  defp fenced_transaction({organization_id, run_id, lease_token}, fun) do
    transaction =
      Repo.transaction(fn ->
        run = ImportRuns.assert_owner!(organization_id, run_id, lease_token, @cleaning_states)
        fun.(run)
      end)

    case transaction do
      {:ok, result} -> result
      {:error, :lease_lost} -> throw(:lease_lost)
    end
  end

  # Resolves the target version id without re-claiming, under the fence. A
  # superseded owner or a wrong token leaves the flow before any delete.
  defp fenced_version_id(fence), do: fenced_transaction(fence, & &1.gtfs_version_id)

  defp detach_trip_pattern_links(_fence, nil), do: :ok

  defp detach_trip_pattern_links({organization_id, _run_id, _lease_token} = fence, version_id) do
    fenced_transaction(fence, fn _run ->
      from(t in Trip,
        where:
          t.organization_id == ^organization_id and t.gtfs_version_id == ^version_id and
            not is_nil(t.timed_pattern_id)
      )
      |> Repo.update_all(
        set: [
          timed_pattern_id: nil,
          pattern_derivation_state: "pending",
          pattern_derivation_reason: nil
        ]
      )

      :ok
    end)
  end

  defp delete_namespace(organization_id, version_id) do
    case version_id do
      nil ->
        :ok

      version_id ->
        case DiagramStorage.delete_version_namespace(organization_id, version_id) do
          :ok -> :ok
          {:error, _reason} -> raise RuntimeError, "filesystem_error"
        end
    end
  end

  defp delete_schema_batched(fence, schema, version_id) do
    case version_id do
      nil ->
        :ok

      version_id ->
        delete_schema_batched_for_version(fence, schema, version_id)
    end
  end

  defp delete_schema_batched_for_version(
         {organization_id, _run_id, _lease_token} = fence,
         schema,
         version_id
       ) do
    batch_size =
      Application.get_env(:gtfs_planner, :import_cleanup_batch_size, @default_batch_size)

    maybe_inject_failure(:database, schema)

    query =
      organization_id
      |> scoped_query(schema, version_id)
      |> order_by([r], asc: r.id)
      |> limit(^batch_size)
      |> select([r], r.id)

    case delete_batch(fence, query, schema) do
      0 ->
        :ok

      _count ->
        # This batch is committed; the next slice takes its own fence.
        maybe_pause_after_batch(schema)
        delete_schema_batched(fence, schema, version_id)
    end
  end

  defp delete_batch(fence, query, schema) do
    fenced_transaction(fence, fn _run ->
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

  # Scopes one owned schema to the target version. `timed_pattern_stops` has no
  # organization column, so its rows are scoped through their timed-pattern
  # parent (INV-5).
  defp scoped_query(organization_id, schema, version_id)
       when schema == GtfsPlanner.Gtfs.TimedPatternStop do
    from(row in schema,
      join: timing in GtfsPlanner.Gtfs.TimedPattern,
      on: timing.id == row.timed_pattern_id,
      where: timing.organization_id == ^organization_id and timing.gtfs_version_id == ^version_id
    )
  end

  defp scoped_query(organization_id, schema, version_id) do
    from(r in schema,
      where: r.organization_id == ^organization_id and r.gtfs_version_id == ^version_id
    )
  end

  defp verify_empty(organization_id, version_id) do
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
            organization_id
            |> scoped_query(schema, version_id)
            |> Repo.aggregate(:count)

          count != 0
        end)
      end

    if not is_nil(nonempty) do
      raise RuntimeError, "verification_failed"
    end

    :ok
  end

  # `finish_cleanup/3` is the closing fence: it locks the run `FOR UPDATE` and checks
  # state, token and lease before it deletes the version.
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

  # --- failure injection (tests only) ---------------------------------------

  # Reads the optional `:import_cleanup_inject_failure` env. When the injection
  # matches the requested phase, raises so cleanup branches to `fail_cleanup`
  # and retains the version. The value `{:pause_after_batch, fun}` instead makes
  # `maybe_pause_after_batch/1` call `fun.(schema)` between two committed
  # batches, so a test can block the worker there. Absent in production (default
  # nil), where both functions do nothing.
  defp maybe_inject_failure(phase, schema) do
    case Application.get_env(:gtfs_planner, :import_cleanup_inject_failure) do
      {^phase, ^schema} -> raise RuntimeError, Atom.to_string(phase) <> "_error"
      {^phase, :any} -> raise RuntimeError, Atom.to_string(phase) <> "_error"
      _ -> :ok
    end
  end

  defp maybe_pause_after_batch(schema) do
    case Application.get_env(:gtfs_planner, :import_cleanup_inject_failure) do
      {:pause_after_batch, fun} when is_function(fun, 1) -> fun.(schema)
      _ -> :ok
    end

    :ok
  end

  defp failure_reason(%RuntimeError{message: "filesystem_error"}), do: :filesystem_error
  defp failure_reason(%RuntimeError{message: "database_error"}), do: :database_error
  defp failure_reason(%RuntimeError{message: "verification_failed"}), do: :verification_failed
  defp failure_reason(%File.Error{}), do: :filesystem_error
  defp failure_reason(%Ecto.QueryError{}), do: :database_error
  defp failure_reason(%Ecto.Query.CastError{}), do: :database_error
  defp failure_reason(%Postgrex.Error{}), do: :database_error
  defp failure_reason(%DBConnection.ConnectionError{}), do: :database_error
  defp failure_reason(_other), do: :unknown_error
end
