defmodule GtfsPlanner.Gtfs.Import.Publication do
  @moduledoc """
  Orchestrates exact-target publication for a full-feed import.

  The workflow is:

    1. Re-read the target through the organization-scoped lifecycle getter so
       every decision is made against the current persisted state.
    2. Atomically claim `staging -> importing`. A losing claim returns before
       any import write — the module never falls back to another version.
    3. Import only into the claimed version id via `Import.import_files/4`.
    4. Reject any result that is not publishable; mark the target failed.
    5. Any import error marks the exact target failed before publication.
    6. Conditionally publish `importing -> published`.
    7. A database publication failure after all asset writes leaves the target
       `importing` (externally unavailable) and returns a distinct
       `{:publication_failed, reason}` for reconciliation.

  The module never accepts a fallback version id: the passed target is the
  only write destination, and the route/current version is context only.
  """

  alias GtfsPlanner.Gtfs.Import
  alias GtfsPlanner.Gtfs.Import.Result
  alias GtfsPlanner.Versions
  alias GtfsPlanner.Versions.GtfsVersion

  alias Postgrex.Error, as: PostgrexError

  require Logger

  @telemetry_event [:gtfs_planner, :import_publication, :transition]
  @importing_status "importing"

  @spec run(GtfsVersion.t(), [map()], String.t()) ::
          {:ok, GtfsVersion.t(), Result.t()}
          | {:error, GtfsVersion.t() | nil, term()}
  def run(%GtfsVersion{} = target, files, topic) when is_binary(topic) do
    organization_id = target.organization_id
    version_id = target.id

    # 1. Re-read the target through the organization-scoped lifecycle getter.
    case Versions.get_gtfs_version_for_lifecycle(organization_id, version_id) do
      nil ->
        emit_failure(nil, organization_id, version_id, "unknown", :not_found)
        {:error, nil, :not_found}

      target ->
        run_for_target(target, organization_id, version_id, files, topic)
    end
  end

  defp run_for_target(target, organization_id, version_id, files, topic) do
    # 2. Atomically claim staging -> importing.
    case Versions.claim_staging_gtfs_version(organization_id, version_id) do
      {:ok, claimed} ->
        # 3. Import only into the claimed version id. Never a fallback id.
        import_and_close(claimed, organization_id, version_id, files, topic)

      {:error, :invalid_status_transition} ->
        # Losing claim returns before any import write.
        emit_failure(
          target,
          organization_id,
          version_id,
          target.publication_status,
          :invalid_status_transition
        )

        {:error, target, :invalid_status_transition}

      {:error, :not_found} ->
        emit_failure(nil, organization_id, version_id, "unknown", :not_found)
        {:error, nil, :not_found}
    end
  end

  defp import_and_close(claimed, organization_id, version_id, files, topic) do
    case Import.import_files(organization_id, version_id, files, topic) do
      {:ok, %Result{} = result} ->
        if Import.Result.publishable?(result) do
          publish_or_fail(claimed, organization_id, version_id, result)
        else
          # Non-publishable result: mark the exact target failed, never publish.
          fail_target(claimed, organization_id, version_id, {:import_not_publishable, result})
        end

      {:error, reason} ->
        # Import error: mark the exact target failed, never publish.
        fail_target(claimed, organization_id, version_id, reason)
    end
  end

  defp publish_or_fail(claimed, organization_id, version_id, result) do
    try do
      case Versions.publish_importing_gtfs_version(organization_id, version_id) do
        {:ok, published} ->
          {:ok, published, result}

        {:error, reason} ->
          # Database publication failure AFTER all asset writes: leave the target
          # importing (externally unavailable) and return a distinct error for
          # Package 3 reconciliation. Do NOT mark it failed.
          emit_failure(
            claimed,
            organization_id,
            version_id,
            @importing_status,
            :publication_failed,
            reason
          )

          {:error, claimed, {:publication_failed, reason}}
      end
    rescue
      # A real database publication failure (e.g. check constraint violation on
      # the importing -> published transition) raises rather than returning
      # {:error, :invalid_status_transition}. Leave the target importing and
      # return a distinct error for reconciliation. Do NOT mark it failed.
      e in PostgrexError ->
        emit_failure(
          claimed,
          organization_id,
          version_id,
          @importing_status,
          :publication_failed,
          e
        )

        {:error, claimed, {:publication_failed, e}}
    end
  end

  defp fail_target(claimed, organization_id, version_id, reason) do
    case Versions.fail_unpublished_gtfs_version(organization_id, version_id) do
      {:ok, failed} ->
        emit_failure(
          claimed,
          organization_id,
          version_id,
          failed.publication_status,
          :import_failed,
          reason
        )

        {:error, failed, reason}

      {:error, fail_reason} ->
        emit_failure(
          claimed,
          organization_id,
          version_id,
          claimed.publication_status,
          :failed_transition,
          {reason, fail_reason}
        )

        {:error, claimed, {:failed_transition, reason, fail_reason}}
    end
  end

  defp emit_failure(
         target,
         organization_id,
         version_id,
         new_state,
         failure_class,
         inner_reason \\ nil
       )

  defp emit_failure(
         nil,
         organization_id,
         version_id,
         new_state,
         failure_class,
         _inner_reason
       ) do
    emit_failure_metadata(organization_id, version_id, "unknown", new_state, failure_class)
  end

  defp emit_failure(
         %GtfsVersion{} = target,
         organization_id,
         version_id,
         new_state,
         failure_class,
         inner_reason
       ) do
    emit_failure_metadata(
      organization_id,
      version_id,
      target.publication_status,
      new_state,
      failure_class,
      inner_reason
    )
  end

  defp emit_failure_metadata(
         organization_id,
         version_id,
         prior_state,
         new_state,
         failure_class,
         inner_reason \\ nil
       ) do
    metadata = %{
      organization_id: organization_id,
      version_id: version_id,
      prior_state: prior_state,
      new_state: new_state,
      failure_class: failure_class,
      inner_reason: inner_reason
    }

    Logger.metadata(
      version_id: version_id,
      organization_id: organization_id,
      transition: new_state,
      failure_class: failure_class
    )

    :telemetry.execute(@telemetry_event, %{}, metadata)
  end
end
