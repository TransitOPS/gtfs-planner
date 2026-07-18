defmodule GtfsPlanner.Gtfs.Import.Publication do
  @moduledoc """
  Orchestrates exact-target publication for a full-feed import.

  The workflow is:

    1. The caller (Runner, step 5; a temporary bridge in ImportLive for now)
       has already created a pending target and claimed it into a running run
       owning the importing version. `Publication.run/4` receives that claimed
       `%Run{}` plus its execution lease token.
    2. Import only into the run's exact target version id via
       `Import.import_files/4`. The run is the only write destination; there is
       no fallback version.
    3. Import result handling closes the run exclusively through `ImportRuns`:
       - publishable result -> `ImportRuns.publish_import/4`
       - non-publishable result or import error -> `ImportRuns.fail_import/4`
       - database publication failure -> `ImportRuns.record_publication_failure/5`
    4. A lost or renewed-away lease during closure yields a non-publishable
       closure error and never retries inserts.

  `Publication` never calls generic version claim/publish/fail functions
  directly; `ImportRuns` is the sole owner of every coupled run + version
  transition.
  """

  alias GtfsPlanner.Gtfs.Import
  alias GtfsPlanner.Gtfs.Import.{Result, Failure}
  alias GtfsPlanner.Gtfs.Import.Run
  alias GtfsPlanner.Gtfs.ImportRuns
  alias GtfsPlanner.Versions.GtfsVersion

  alias Postgrex.Error, as: PostgrexError

  require Logger

  @telemetry_event [:gtfs_planner, :import_publication, :transition]
  @importing_status "importing"

  @spec run(Run.t(), Ecto.UUID.t(), [map()], String.t()) ::
          {:ok, GtfsVersion.t(), Result.t()}
          | {:error, GtfsVersion.t() | nil, term()}
  def run(%Run{} = run, lease_token, files, topic) when is_binary(topic) do
    organization_id = run.organization_id
    run_id = run.id
    version_id = run.gtfs_version_id

    # 1. Import only into the claimed version id. Never a fallback id.
    case Import.import_files(organization_id, version_id, files, topic) do
      {:ok, %Result{} = result} ->
        if Result.publishable?(result) do
          publish_or_fail(run, organization_id, run_id, version_id, lease_token, result)
        else
          # Non-publishable result: close the run failed, never publish.
          fail_target(
            run,
            organization_id,
            run_id,
            version_id,
            lease_token,
            {:import_not_publishable, result}
          )
        end

      {:error, %Failure{} = failure} ->
        # Import error: close the run failed, never publish. The import
        # returned a fully-formed Failure carrying sanitized file/row.
        fail_target(run, organization_id, run_id, version_id, lease_token, failure)
    end
  end

  defp publish_or_fail(run, organization_id, run_id, version_id, lease_token, result) do
    case ImportRuns.publish_import(organization_id, run_id, lease_token, result) do
      {:ok, _run, version} ->
        emit_failure(run, organization_id, run_id, version_id, "published", nil)
        {:ok, version, result}

      {:error, :invalid_transition} ->
        # Lease/token was not the active execution owner: treat as a
        # non-publishable closure error and never retry inserts.
        emit_failure(run, organization_id, run_id, version_id, @importing_status, :lease_lost)
        {:error, read_version(organization_id, version_id), :lease_lost}

      {:error, reason} ->
        # A real database publication failure AFTER all asset writes: record the
        # run as publication_failed (version stays importing, externally
        # unavailable) and return a distinct error for Package 3 reconciliation.
        # Do NOT mark it failed.
        record_publication_failure_or_lease_lost(
          run,
          organization_id,
          run_id,
          version_id,
          lease_token,
          result,
          reason
        )
    end
  rescue
    # A Postgres publication failure (e.g. check-constraint violation) raises
    # rather than returning {:error, :invalid_status_transition}. Leave the
    # version importing and record publication_failed for reconciliation. Do NOT
    # mark it failed.
    e in PostgrexError ->
      record_publication_failure_or_lease_lost(
        run,
        organization_id,
        run_id,
        version_id,
        lease_token,
        result,
        e
      )
  end

  defp record_publication_failure_or_lease_lost(
         run,
         organization_id,
         run_id,
         version_id,
         lease_token,
         result,
         reason
       ) do
    case ImportRuns.record_publication_failure(
           organization_id,
           run_id,
           lease_token,
           result,
           :publication_failed
         ) do
      {:ok, _run} ->
        emit_failure(
          run,
          organization_id,
          run_id,
          version_id,
          @importing_status,
          :publication_failed,
          reason
        )

        {:error, read_version(organization_id, version_id), {:publication_failed, reason}}

      {:error, :invalid_transition} ->
        emit_failure(run, organization_id, run_id, version_id, @importing_status, :lease_lost)
        {:error, read_version(organization_id, version_id), :lease_lost}

      {:error, reason} ->
        {:error, read_version(organization_id, version_id), reason}
    end
  end

  defp fail_target(run, organization_id, run_id, version_id, lease_token, %Failure{} = failure) do
    fail_target_via_import_runs(run, organization_id, run_id, version_id, lease_token, failure)
  end

  defp fail_target(run, organization_id, run_id, version_id, lease_token, reason) do
    failure = Failure.from_error(reason, phase: :phase_2, outcome: :failed)

    fail_target_via_import_runs(run, organization_id, run_id, version_id, lease_token, failure)
  end

  defp fail_target_via_import_runs(
         run,
         organization_id,
         run_id,
         version_id,
         lease_token,
         failure
       ) do
    case ImportRuns.fail_import(organization_id, run_id, lease_token, failure) do
      {:ok, _run, version} ->
        emit_failure(
          run,
          organization_id,
          run_id,
          version_id,
          version.publication_status,
          :import_failed,
          failure
        )

        {:error, version, failure}

      {:error, :invalid_transition} ->
        # Lost/renewed-away lease: non-publishable closure error, no insert retry.
        emit_failure(run, organization_id, run_id, version_id, @importing_status, :lease_lost)
        {:error, read_version(organization_id, version_id), :lease_lost}

      {:error, reason} ->
        {:error, read_version(organization_id, version_id), reason}
    end
  end

  defp read_version(organization_id, version_id) do
    case GtfsPlanner.Versions.get_gtfs_version_for_lifecycle(organization_id, version_id) do
      nil -> nil
      version -> version
    end
  end

  defp emit_failure(
         _run,
         organization_id,
         _run_id,
         version_id,
         new_state,
         failure_class,
         inner_reason \\ nil
       ) do
    # `prior_state`/`new_state` track the target version publication_status
    # across the closure: the run is running and its version is importing until
    # the closure transition resolves it.
    prior_state = @importing_status

    emit_failure_metadata(
      organization_id,
      version_id,
      prior_state,
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
         inner_reason
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
