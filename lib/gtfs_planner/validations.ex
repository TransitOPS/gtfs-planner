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
  """

  import Ecto.Query

  alias GtfsPlanner.Gtfs.Validator.Result
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Validations.{ValidationRun, WalkabilityTest}

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
  """
  @spec list_recent_validation_runs(Ecto.UUID.t(), Ecto.UUID.t(), pos_integer()) :: [
          ValidationRun.t()
        ]
  def list_recent_validation_runs(organization_id, gtfs_version_id, limit \\ 5) do
    ValidationRun
    |> where([run], run.organization_id == ^organization_id)
    |> where([run], run.gtfs_version_id == ^gtfs_version_id)
    |> where([run], run.status in ["completed", "failed"])
    |> order_by([run], desc: run.started_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Returns the newest completed or failed MobilityData validation run for an
  organization and GTFS version, or `nil` when none has finished.

  Reachability and pathways runs are ignored.
  """
  @spec latest_feed_check(Ecto.UUID.t(), Ecto.UUID.t()) :: ValidationRun.t() | nil
  def latest_feed_check(organization_id, gtfs_version_id) do
    ValidationRun
    |> where([run], run.organization_id == ^organization_id)
    |> where([run], run.gtfs_version_id == ^gtfs_version_id)
    |> where([run], run.run_type == "mobility_data")
    |> where([run], run.status in ["completed", "failed"])
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
