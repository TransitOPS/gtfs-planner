defmodule GtfsPlanner.Validations do
  @moduledoc """
  The Validations context for managing GTFS validation runs.

  Historical pathways and OTP results are read through `Validations.Legacy`.

  A MobilityData run is executed under a lease. `claim_run/2` moves a `started`
  run to `running` and issues a lease token; `renew_lease/3`, `complete_run/4` and
  `fail_run/4` write only when the run is still `running`, the token matches and
  the lease has not expired, all checked under a row lock in the same transaction.
  A superseded owner therefore writes nothing. Lease expiry compares against
  PostgreSQL time (`CURRENT_TIMESTAMP`), never the application clock.

  `start_mobility_data_run/4` creates a run and hands it to a
  `Validations.Runner` under `Validations.RunnerSupervisor`, which owns the
  lease from claim to terminal write.

  `start_artifact_run/3` validates one already-exported artifact instead of the
  version's current rows. It takes the actor's current editor membership first,
  pins the selected export run's artifact through `ExportRuns` (the owner of
  acquisition) and records the verified SHA-256, export run, slot and pin token
  on the run, so the runner's later read can only see those exact bytes. The
  report stays bound to the artifact: a fresh run is never a feed check of the
  version, and source edits after the export cannot change what was reviewed.
  """

  import Ecto.Query

  alias GtfsPlanner.Authorization
  alias GtfsPlanner.Gtfs.Export
  alias GtfsPlanner.Gtfs.ExportRuns
  alias GtfsPlanner.Gtfs.Validator.Result
  alias GtfsPlanner.Repo
  alias GtfsPlanner.RunnerAdmission
  alias GtfsPlanner.Validations.{Runner, ValidationRun, WalkabilityTest}

  require Logger

  @mobility_run_types ["mobility_data", "mobility_data_flex"]

  # A validation run owns the pin it acquired under this owner id, so it can
  # renew and release it without ever seeing another owner's claim.
  @artifact_pin_owner_prefix "validation-run:"

  @lease_seconds Application.compile_env(:gtfs_planner, :validation_lease_seconds, 300)

  @doc """
  Creates a new validation run with status "started".
  """
  @spec create_validation_run(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, ValidationRun.t()} | {:error, Ecto.Changeset.t()}
  def create_validation_run(organization_id, gtfs_version_id, run_type) do
    %ValidationRun{
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id,
      started_at: DateTime.utc_now()
    }
    |> ValidationRun.changeset(%{run_type: run_type, status: "started"})
    |> Repo.insert()
  end

  @doc """
  Creates a MobilityData validation run for the actor and starts its runner.

  `run_type` is `"mobility_data"` or `"mobility_data_flex"`. The actor must
  currently be an editor of the organization (`{:error, :forbidden}` otherwise,
  and no run is created). The run's messages arrive on `topic/1`.

  When the runner supervisor is at its `:runner_limits` cap the run never starts:
  it is failed with `error_details` `"busy"` and the result is `{:error, :busy}`.
  Any other start failure fails the run as `"not_started"` and returns
  `{:error, :not_started}`.
  """
  @spec start_mobility_data_run(Ecto.UUID.t(), Ecto.UUID.t(), String.t(), map()) ::
          {:ok, ValidationRun.t()}
          | {:error, :forbidden | :invalid_run_type | :busy | :not_started | Ecto.Changeset.t()}
  def start_mobility_data_run(organization_id, version_id, run_type, actor)
      when run_type in @mobility_run_types do
    with :ok <-
           Authorization.authorize_editor(%{
             actor_id: actor_id(actor),
             organization_id: organization_id
           }),
         {:ok, run} <- create_validation_run(organization_id, version_id, run_type) do
      start_runner(run)
    end
  end

  def start_mobility_data_run(_organization_id, _version_id, _run_type, _actor),
    do: {:error, :invalid_run_type}

  @doc """
  Validates one selected export artifact and starts its runner.

  `run_id` is an export run the organization owns and `slot` is the trusted
  `main` or `flex` artifact of that run. The actor must currently be an editor
  (`{:error, :forbidden}` otherwise, and no run is created).

  The run is created only after `ExportRuns.pin_publication/5` has verified the
  bytes and leased them, so a run never exists whose artifact it cannot read. A
  run that is not ready, has no such slot, or whose artifact is already pinned by
  another owner is refused with the pin's own reason and creates nothing.

  When the runner supervisor is at its `:runner_limits` cap the run never starts:
  it is failed with `error_details` `"busy"` and the result is `{:error, :busy}`.
  Any other start failure fails the run as `"not_started"` and returns
  `{:error, :not_started}`. Either way the pin this function acquired is
  released, so a refused review never holds the artifact.
  """
  @spec start_artifact_run(map(), Ecto.UUID.t(), :main | :flex) ::
          {:ok, ValidationRun.t()}
          | {:error,
             :forbidden
             | :not_found
             | :artifact_busy
             | :invalid_slot
             | :busy
             | :not_started
             | Ecto.Changeset.t()}
  def start_artifact_run(scope, export_run_id, slot) when slot in [:main, :flex] do
    # The owner id is derived from the validation run's own id, so the run can
    # rebuild its claim after a restart without a second stored credential.
    run_id = Ecto.UUID.generate()

    case pin_and_create(scope, export_run_id, slot, run_id) do
      {:ok, run} ->
        start_artifact_runner(run)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def start_artifact_run(_scope, _export_run_id, _slot), do: {:error, :invalid_slot}

  defp pin_and_create(scope, export_run_id, slot, run_id) do
    Repo.transaction(fn ->
      # INV-1/CR-2: current membership is locked before the export run the pin
      # locks, so a permission revoked after the page loaded refuses the write.
      Authorization.lock_editor!(scope)
      create_pinned_artifact_run(scope, export_run_id, slot, run_id)
    end)
  end

  # `Repo.transaction/1` wraps the function's own result once more, so the
  # inserted run is unwrapped here.
  defp create_pinned_artifact_run(scope, export_run_id, slot, run_id) do
    with {:ok, organization_id} <- cast_organization_id(scope),
         {:ok, run} <- open_artifact_run(organization_id, export_run_id, slot, run_id) do
      run
    else
      :error -> Repo.rollback(:forbidden)
    end
  end

  # A run that never starts is failed by `start_runner/1`; the pin this function
  # acquired goes with it, so a refused review never holds the artifact.
  defp start_artifact_runner(run) do
    case start_runner(run) do
      {:ok, started} ->
        {:ok, started}

      {:error, reason} ->
        _ = release_artifact_pin(run)
        {:error, reason}
    end
  end

  defp open_artifact_run(organization_id, export_run_id, slot, run_id) do
    with %Export.Run{} = export_run <- ExportRuns.get_scoped_run(organization_id, export_run_id),
         {:ok, pin} <-
           ExportRuns.pin_publication(
             organization_id,
             export_run.gtfs_version_id,
             export_run_id,
             slot,
             @artifact_pin_owner_prefix <> run_id
           ) do
      create_artifact_run(run_id, organization_id, export_run, pin, slot)
    else
      nil -> Repo.rollback(:not_found)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  @doc """
  The pin claim this run holds on its artifact, for `ExportRuns` readers that
  accept one. Returns a claim that matches nothing for a run that is not
  artifact-bound, so it is never a usable credential by accident.
  """
  @spec artifact_pin_claim(ValidationRun.t()) :: map()
  def artifact_pin_claim(%ValidationRun{id: id, artifact_pin_token: token})
      when not is_nil(token) do
    %{owner_id: @artifact_pin_owner_prefix <> id, pin_token: token}
  end

  def artifact_pin_claim(%ValidationRun{}),
    do: %{owner_id: @artifact_pin_owner_prefix, pin_token: Ecto.UUID.generate()}

  @doc """
  Releases the artifact pin this run acquired, if it still owns it.

  `Validations.Runner` calls this after the terminal row is written, so a review
  that finished, failed or was refused never keeps the private artifact from being
  cleaned up. A run that is not artifact-bound releases nothing, and a claim
  that was already fenced logs rather than fails.
  """
  @spec release_artifact_pin(ValidationRun.t()) :: :ok | {:error, :lease_lost}
  def release_artifact_pin(%ValidationRun{artifact_export_run_id: run_id} = run)
      when not is_nil(run_id) do
    ExportRuns.release_publication_pin(
      run.organization_id,
      run_id,
      artifact_pin_claim(run)
    )
  end

  def release_artifact_pin(%ValidationRun{}), do: :ok

  defp create_artifact_run(run_id, organization_id, export_run, pin, slot) do
    %ValidationRun{
      id: run_id,
      organization_id: organization_id,
      gtfs_version_id: export_run.gtfs_version_id,
      started_at: DateTime.utc_now()
    }
    |> ValidationRun.system_changeset(%{
      run_type: "mobility_data_artifact",
      status: "started",
      artifact_sha256: pin.sha256,
      artifact_slot: slot,
      artifact_export_run_id: export_run.id,
      artifact_pin_token: pin.pin_token
    })
    |> Repo.insert()
  end

  defp cast_organization_id(%{organization_id: organization_id}),
    do: Ecto.UUID.cast(organization_id)

  defp cast_organization_id(_), do: :error

  defp actor_id(%{id: id}), do: id
  defp actor_id(_actor), do: nil

  # The supervisor refuses a start at its cap before the runner's `init/1` runs,
  # so a refused run was never claimed and is still `started`: close it here.
  defp start_runner(run) do
    child = {Runner, organization_id: run.organization_id, run_id: run.id}

    case RunnerAdmission.start_child(GtfsPlanner.Validations.RunnerSupervisor, child) do
      {:ok, _pid} ->
        {:ok, run}

      {:error, :busy} ->
        _ = fail_unstarted(run.organization_id, run.id, "busy")
        {:error, :busy}

      {:error, reason} ->
        Logger.error("Validation run #{run.id} did not start: #{inspect(reason)}")
        _ = fail_unstarted(run.organization_id, run.id, "not_started")
        {:error, :not_started}
    end
  end

  @doc """
  Gets a single validation run, raising if not found.
  """
  @spec get_validation_run!(Ecto.UUID.t()) :: ValidationRun.t()
  def get_validation_run!(id), do: Repo.get!(ValidationRun, id)

  @doc """
  Gets a single validation run, returning nil if not found.
  """
  @spec get_validation_run(Ecto.UUID.t()) :: ValidationRun.t() | nil
  def get_validation_run(id), do: Repo.get(ValidationRun, id)

  @doc """
  Lists validation runs for a given organization and GTFS version.

  Results are ordered by started_at descending and limited to 20.
  """
  @spec list_validation_runs(Ecto.UUID.t(), Ecto.UUID.t()) :: [ValidationRun.t()]
  def list_validation_runs(organization_id, gtfs_version_id) do
    ValidationRun
    |> where([run], run.organization_id == ^organization_id)
    |> where([run], run.gtfs_version_id == ^gtfs_version_id)
    |> order_by([run], desc: run.started_at)
    |> limit(20)
    |> Repo.all()
  end

  @doc """
  Lists recent completed or failed validation runs for an organization and GTFS version.

  A run refused for lack of capacity (`"busy"`) never ran and is not listed.
  """
  @spec list_recent_validation_runs(Ecto.UUID.t(), Ecto.UUID.t(), pos_integer()) :: [
          ValidationRun.t()
        ]
  def list_recent_validation_runs(organization_id, gtfs_version_id, limit \\ 5) do
    ValidationRun
    |> where([run], run.organization_id == ^organization_id)
    |> where([run], run.gtfs_version_id == ^gtfs_version_id)
    |> where([run], run.status in ["completed", "failed"])
    |> ran()
    |> order_by([run], desc: run.started_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Returns the newest completed or failed MobilityData validation run for an
  organization and GTFS version, or `nil` when none has finished.

  Reachability and pathways runs are ignored, and so is a run refused for lack
  of capacity (`"busy"`), which never ran.
  """
  @spec latest_feed_check(Ecto.UUID.t(), Ecto.UUID.t()) :: ValidationRun.t() | nil
  def latest_feed_check(organization_id, gtfs_version_id) do
    ValidationRun
    |> where([run], run.organization_id == ^organization_id)
    |> where([run], run.gtfs_version_id == ^gtfs_version_id)
    |> where([run], run.run_type == "mobility_data")
    |> where([run], run.status in ["completed", "failed"])
    |> ran()
    |> order_by([run], desc: run.started_at, asc: run.id)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Returns the PubSub topic that carries a validation run's messages.
  """
  @spec topic(Ecto.UUID.t()) :: String.t()
  def topic(run_id), do: "validation:#{run_id}"

  @doc """
  Claims a `started` run: moves it to `running` and issues a fresh lease token
  with a database-time expiry. The caller presents the returned token on every
  later write.

  A run that is not `started` returns `{:error, :invalid_transition}`; a run that
  does not exist in the organization returns `{:error, :not_found}`. Neither
  writes anything.
  """
  @spec claim_run(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, ValidationRun.t(), Ecto.UUID.t()} | {:error, :not_found | :invalid_transition}
  def claim_run(organization_id, run_id) do
    transaction_with_broadcast(fn ->
      case lock_run(organization_id, run_id) do
        %ValidationRun{status: "started"} = run ->
          token = Ecto.UUID.generate()

          {:ok, claimed} =
            run
            |> ValidationRun.system_changeset(%{
              status: "running",
              lease_token: token,
              lease_expires_at: lease_expiry()
            })
            |> Repo.update()

          {{:ok, claimed, token}, []}

        %ValidationRun{} ->
          {{:error, :invalid_transition}, []}

        nil ->
          {{:error, :not_found}, []}
      end
    end)
  end

  @doc """
  Extends the lease of a `running` run by the configured lease length.

  Returns `{:error, :lease_lost}` and writes nothing when the token is stale, the
  lease already expired, the run is no longer `running`, or it does not exist in
  the organization.
  """
  @spec renew_lease(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t()) :: :ok | {:error, :lease_lost}
  def renew_lease(organization_id, run_id, token) do
    transaction_with_broadcast(fn ->
      case lock_owned_run(organization_id, run_id, token) do
        %ValidationRun{} = run ->
          {:ok, _renewed} =
            run
            |> ValidationRun.system_changeset(%{lease_expires_at: lease_expiry()})
            |> Repo.update()

          {:ok, []}

        nil ->
          {{:error, :lease_lost}, []}
      end
    end)
  end

  @doc """
  Completes the run the token owns and stores the validator result.

  Returns `{:error, :lease_lost}` and writes nothing when the token is stale, the
  lease expired, the run is no longer `running`, or it does not exist in the
  organization. After the transaction commits, broadcasts
  `{:validation_completed, run_id}` on `topic/1`.
  """
  @spec complete_run(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t(), Result.t()) ::
          {:ok, ValidationRun.t()} | {:error, :lease_lost}
  def complete_run(organization_id, run_id, token, %Result{} = result) do
    finish_owned_run(organization_id, run_id, token, :validation_completed, %{
      status: "completed",
      errors_count: result.summary.errors,
      warnings_count: result.summary.warnings,
      infos_count: result.summary.infos,
      duration_ms: result.duration_ms,
      result_json: %{"notices" => result.notices}
    })
  end

  @doc """
  Fails the run the token owns and stores the reason in `error_details`.

  A string reason is stored as given, an atom by name, and any other term with
  `inspect/1`. Returns `{:error, :lease_lost}` and writes nothing under the same
  conditions as `complete_run/4`. After the transaction commits, broadcasts
  `{:validation_failed, run_id}` on `topic/1`.
  """
  @spec fail_run(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t(), term()) ::
          {:ok, ValidationRun.t()} | {:error, :lease_lost}
  def fail_run(organization_id, run_id, token, reason) do
    finish_owned_run(organization_id, run_id, token, :validation_failed, failure_attrs(reason))
  end

  @doc """
  Fails a run that no runner claimed (`started` to `failed`), storing the reason.

  A run in any other state returns `{:error, :invalid_transition}`; a run that
  does not exist in the organization returns `{:error, :not_found}`. Neither
  writes anything. After the transaction commits, broadcasts
  `{:validation_failed, run_id}` on `topic/1`.
  """
  @spec fail_unstarted(Ecto.UUID.t(), Ecto.UUID.t(), term()) ::
          {:ok, ValidationRun.t()} | {:error, :not_found | :invalid_transition}
  def fail_unstarted(organization_id, run_id, reason) do
    transaction_with_broadcast(fn ->
      case lock_run(organization_id, run_id) do
        %ValidationRun{status: "started"} = run ->
          {failed, message} = terminate(run, :validation_failed, failure_attrs(reason))
          {{:ok, failed}, [message]}

        %ValidationRun{} ->
          {{:error, :invalid_transition}, []}

        nil ->
          {{:error, :not_found}, []}
      end
    end)
  end

  @doc """
  Fails every `running` run of the organization whose lease expired, with
  `error_details` `"lease_expired"`. Returns the runs it failed.

  A `running` run without a lease (a station reachability run) has no expiry and
  is never reconciled. After the transaction commits, broadcasts
  `{:validation_failed, run_id}` for each failed run on `topic/1`.
  """
  @spec reconcile_expired(Ecto.UUID.t()) :: [ValidationRun.t()]
  def reconcile_expired(organization_id) do
    transaction_with_broadcast(fn ->
      # A NULL lease_expires_at makes the comparison NULL, so lease-less runs drop out.
      ValidationRun
      |> where([run], run.organization_id == ^organization_id and run.status == "running")
      |> where([run], run.lease_expires_at < fragment("CURRENT_TIMESTAMP"))
      |> lock("FOR UPDATE")
      |> Repo.all()
      |> Enum.map(&terminate(&1, :validation_failed, failure_attrs("lease_expired")))
      |> Enum.unzip()
    end)
  end

  @doc """
  Marks a validation run as running.
  """
  @spec mark_running(ValidationRun.t()) ::
          {:ok, ValidationRun.t()} | {:error, Ecto.Changeset.t()}
  def mark_running(run) do
    run
    |> ValidationRun.changeset(%{status: "running"})
    |> Repo.update()
  end

  @doc """
  Marks a validation run as completed and stores the validator result.
  """
  @spec mark_completed(ValidationRun.t(), %{
          summary: map(),
          notices: list(),
          duration_ms: integer()
        }) ::
          {:ok, ValidationRun.t()} | {:error, Ecto.Changeset.t() | Ecto.StaleEntryError.t()}
  def mark_completed(run, result) do
    run
    |> ValidationRun.changeset(%{
      status: "completed",
      errors_count: result.summary.errors,
      warnings_count: result.summary.warnings,
      infos_count: result.summary.infos,
      duration_ms: result.duration_ms,
      result_json: %{"notices" => result.notices},
      completed_at: DateTime.utc_now()
    })
    |> Repo.update(stale_error_field: :id)
  end

  @doc """
  Marks a validation run as failed and stores the error details.
  """
  @spec mark_failed(ValidationRun.t(), term()) ::
          {:ok, ValidationRun.t()} | {:error, Ecto.Changeset.t() | Ecto.StaleEntryError.t()}
  def mark_failed(run, reason) do
    run
    |> ValidationRun.changeset(%{
      status: "failed",
      error_details: inspect(reason),
      completed_at: DateTime.utc_now()
    })
    |> Repo.update(stale_error_field: :id)
  end

  @doc """
  Lists walkability tests for an organization and GTFS version in deterministic order.
  """
  @spec list_walkability_tests(Ecto.UUID.t(), Ecto.UUID.t()) :: [WalkabilityTest.t()]
  def list_walkability_tests(organization_id, gtfs_version_id) do
    WalkabilityTest
    |> where([test], test.organization_id == ^organization_id)
    |> where([test], test.gtfs_version_id == ^gtfs_version_id)
    |> order_by([test], asc: test.stop_id, asc: test.address, asc: test.id)
    |> Repo.all()
  end

  @doc """
  Lists walkability tests for an organization, GTFS version, and stop ids.
  """
  @spec list_walkability_tests_for_stop_ids(Ecto.UUID.t(), Ecto.UUID.t(), [String.t()]) :: [
          WalkabilityTest.t()
        ]
  def list_walkability_tests_for_stop_ids(_organization_id, _gtfs_version_id, []), do: []

  def list_walkability_tests_for_stop_ids(organization_id, gtfs_version_id, stop_ids) do
    WalkabilityTest
    |> where(
      [test],
      test.organization_id == ^organization_id and test.gtfs_version_id == ^gtfs_version_id and
        test.stop_id in ^stop_ids
    )
    |> order_by([test], desc: test.inserted_at)
    |> Repo.all()
  end

  @doc """
  Gets a single walkability test, raising if not found.
  """
  @spec get_walkability_test!(Ecto.UUID.t()) :: WalkabilityTest.t()
  def get_walkability_test!(id), do: Repo.get!(WalkabilityTest, id)

  @doc """
  Gets a single walkability test, returning nil if not found.
  """
  @spec get_walkability_test(Ecto.UUID.t()) :: WalkabilityTest.t() | nil
  def get_walkability_test(id), do: Repo.get(WalkabilityTest, id)

  # `fail_unstarted(…, "busy")` closes a run that no runner ever claimed; it is
  # not a check result, so it must not replace the last real one.
  defp ran(query),
    do: where(query, [run], is_nil(run.error_details) or run.error_details != "busy")

  # Runs `fun`, which returns `{result, messages}`, and publishes each message on
  # its run's topic only after the transaction has committed, so a subscriber that
  # reads the row on receipt sees the committed state. Callers must not wrap these
  # functions in their own transaction: the broadcast would precede the outer commit.
  defp transaction_with_broadcast(fun) do
    {:ok, {result, messages}} = Repo.transaction(fun)

    Enum.each(messages, fn {_event, run_id} = message ->
      Phoenix.PubSub.broadcast(GtfsPlanner.PubSub, topic(run_id), message)
    end)

    result
  end

  defp lock_run(organization_id, run_id) do
    ValidationRun
    |> where([run], run.id == ^run_id and run.organization_id == ^organization_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  # Locks the run only while the token owns it: state, token and unexpired lease
  # are all part of the locked row's predicate, which PostgreSQL re-evaluates
  # after waiting for a competing writer.
  defp lock_owned_run(organization_id, run_id, token) do
    ValidationRun
    |> where([run], run.id == ^run_id and run.organization_id == ^organization_id)
    |> where([run], run.status == "running" and run.lease_token == ^token)
    |> where([run], run.lease_expires_at >= fragment("CURRENT_TIMESTAMP"))
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp finish_owned_run(organization_id, run_id, token, event, attrs) do
    transaction_with_broadcast(fn ->
      case lock_owned_run(organization_id, run_id, token) do
        %ValidationRun{} = run ->
          {finished, message} = terminate(run, event, attrs)
          {{:ok, finished}, [message]}

        nil ->
          {{:error, :lease_lost}, []}
      end
    end)
  end

  # Writes a terminal state and releases the lease; returns the row and the
  # message to publish once the transaction commits.
  defp terminate(run, event, attrs) do
    {:ok, finished} =
      run
      |> ValidationRun.system_changeset(
        Map.merge(attrs, %{
          completed_at: DateTime.utc_now(),
          lease_token: nil,
          lease_expires_at: nil
        })
      )
      |> Repo.update()

    {finished, {event, finished.id}}
  end

  defp failure_attrs(reason), do: %{status: "failed", error_details: error_details(reason)}

  defp error_details(reason) when is_binary(reason), do: reason
  defp error_details(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_details(reason), do: inspect(reason)

  # CURRENT_TIMESTAMP is the transaction's start time in PostgreSQL. A lock wait
  # lags it by milliseconds, which is immaterial against a lease of minutes.
  defp lease_expiry do
    %Postgrex.Result{rows: [[expiry]]} =
      Repo.query!("SELECT CURRENT_TIMESTAMP + ($1::integer * interval '1 second')", [
        @lease_seconds
      ])

    expiry
  end
end
