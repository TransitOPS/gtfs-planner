defmodule GtfsPlanner.Gtfs.ExportRuns do
  @moduledoc """
  Durable, tenant-scoped export transitions and download claims.

  Workers own only a fenced generation/token. Artifact files remain private until
  `mark_ready/5` commits verified metadata to the matching run row.
  """

  import Ecto.Query, warn: false

  require Logger

  alias GtfsPlanner.Gtfs.Export.ArtifactStorage
  alias GtfsPlanner.Gtfs.Export.Run
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion

  @type actor :: %{required(:id) => Ecto.UUID.t(), required(:email) => String.t()}

  @lease_seconds Application.compile_env(:gtfs_planner, :export_run_lease_seconds, 300)
  @download_claim_seconds Application.compile_env(
                            :gtfs_planner,
                            :export_download_claim_seconds,
                            60
                          )
  @terminal_states [:ready, :failed, :interrupted, :cancelled, :expired]

  @spec create_pending(Ecto.UUID.t(), Ecto.UUID.t(), actor(), :full | :pathways) ::
          {:ok, Run.t()} | {:error, term()}
  def create_pending(organization_id, version_id, actor, export_type)
      when export_type in [:full, :pathways] do
    transaction_with_broadcast(fn ->
      create_pending_transition(organization_id, version_id, actor, export_type)
    end)
  end

  def create_pending(_, _, _, _), do: {:error, :invalid_export_type}

  @spec claim(Ecto.UUID.t(), Ecto.UUID.t(), :build) ::
          {:ok, Run.t(), pos_integer(), Ecto.UUID.t()} | {:error, term()}
  def claim(organization_id, run_id, :build) do
    transaction_with_broadcast(fn ->
      case lock_run(organization_id, run_id) do
        %Run{} = run ->
          claim_locked_run(organization_id, run, claimable?(run))

        nil ->
          {{:error, :not_found}, []}
      end
    end)
  end

  def claim(_, _, _), do: {:error, :invalid_operation}

  defp claim_locked_run(organization_id, run, true) do
    generation = run.lease_generation + 1
    token = Ecto.UUID.generate()

    {1, _} =
      from(r in Run,
        where: r.id == ^run.id and r.organization_id == ^organization_id,
        update: [
          set: [
            state: :building,
            phase: :preflight,
            lease_generation: ^generation,
            lease_token: ^token,
            lease_expires_at:
              fragment("CURRENT_TIMESTAMP + (? * interval '1 second')", ^@lease_seconds),
            started_at: fragment("COALESCE(?, CURRENT_TIMESTAMP)", r.started_at),
            updated_at: fragment("CURRENT_TIMESTAMP")
          ]
        ]
      )
      |> Repo.update_all([])

    claimed = Repo.get!(Run, run.id)
    {{:ok, claimed, generation, token}, [run.id]}
  end

  defp claim_locked_run(_organization_id, _run, false), do: {{:error, :invalid_transition}, []}

  @spec renew_lease(Ecto.UUID.t(), Ecto.UUID.t(), pos_integer(), Ecto.UUID.t()) ::
          :ok | {:error, :lease_lost}
  def renew_lease(organization_id, run_id, generation, token) do
    transaction_with_broadcast(fn ->
      case fenced_run(organization_id, run_id, generation, token) do
        {:ok, run} ->
          {1, _} =
            from(r in Run,
              where:
                r.id == ^run.id and r.organization_id == ^organization_id and
                  r.lease_generation == ^generation and r.lease_token == ^token and
                  is_nil(r.cancel_requested_at) and
                  r.lease_expires_at >= fragment("CURRENT_TIMESTAMP"),
              update: [
                set: [
                  lease_expires_at:
                    fragment("CURRENT_TIMESTAMP + (? * interval '1 second')", ^@lease_seconds),
                  updated_at: fragment("CURRENT_TIMESTAMP")
                ]
              ]
            )
            |> Repo.update_all([])

          {:ok, []}

        {:error, _} ->
          {{:error, :lease_lost}, []}
      end
    end)
  end

  @spec mark_ready(Ecto.UUID.t(), Ecto.UUID.t(), pos_integer(), Ecto.UUID.t(), map()) ::
          {:ok, Run.t()} | {:error, :lease_lost | term()}
  def mark_ready(organization_id, run_id, generation, token, artifact) when is_map(artifact) do
    with :ok <- requested_artifact?(organization_id, run_id, artifact),
         {:ok, _path} <- artifact_storage_module().verify(artifact) do
      commit_ready(organization_id, run_id, generation, token, artifact)
    end
  end

  def mark_ready(_, _, _, _, _), do: {:error, :invalid_artifact}

  @spec persist_warnings(Ecto.UUID.t(), Ecto.UUID.t(), pos_integer(), Ecto.UUID.t(), [map()]) ::
          {:ok, Run.t()} | {:error, :lease_lost | term()}
  def persist_warnings(organization_id, run_id, generation, token, warnings)
      when is_list(warnings) do
    transaction_with_broadcast(fn ->
      with {:ok, run} <- fenced_run(organization_id, run_id, generation, token),
           {:ok, updated} <-
             Repo.update(Run.system_changeset(run, %{warnings: warnings, phase: :packaging})) do
        {{:ok, updated}, [run.id]}
      else
        {:error, :lease_lost} -> {{:error, :lease_lost}, []}
        {:error, reason} -> {{:error, reason}, []}
      end
    end)
  end

  def persist_warnings(_, _, _, _, _), do: {:error, :invalid_warnings}

  @spec fail_build(Ecto.UUID.t(), Ecto.UUID.t(), pos_integer(), Ecto.UUID.t(), String.t()) ::
          {:ok, Run.t()} | {:error, :lease_lost}
  def fail_build(organization_id, run_id, generation, token, code) when is_binary(code) do
    transaction_with_broadcast(fn ->
      fail_locked_build(lock_run(organization_id, run_id), generation, token, code)
    end)
  end

  def fail_build(_, _, _, _, _), do: {:error, :lease_lost}

  @spec request_cancel(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, Run.t()} | {:error, term()}
  def request_cancel(organization_id, run_id) do
    transaction_with_broadcast(fn ->
      case lock_run(organization_id, run_id) do
        nil ->
          {{:error, :not_found}, []}

        %Run{state: :building, cancel_requested_at: nil} = run ->
          {1, _} =
            from(r in Run,
              where: r.id == ^run.id and r.organization_id == ^organization_id,
              update: [
                set: [
                  cancel_requested_at: fragment("CURRENT_TIMESTAMP"),
                  updated_at: fragment("CURRENT_TIMESTAMP")
                ]
              ]
            )
            |> Repo.update_all([])

          {{:ok, Repo.get!(Run, run.id)}, [run.id]}

        %Run{state: :pending} = run ->
          {1, _} =
            from(r in Run,
              where: r.id == ^run.id and r.organization_id == ^organization_id,
              update: [
                set: [
                  state: :cancelled,
                  phase: :cleanup,
                  cancel_requested_at: fragment("CURRENT_TIMESTAMP"),
                  started_at: fragment("CURRENT_TIMESTAMP"),
                  finished_at: fragment("CURRENT_TIMESTAMP"),
                  updated_at: fragment("CURRENT_TIMESTAMP")
                ]
              ]
            )
            |> Repo.update_all([])

          {{:ok, Repo.get!(Run, run.id)}, [run.id]}

        _ ->
          {{:error, :invalid_transition}, []}
      end
    end)
  end

  @spec retry(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, Run.t()} | {:error, term()}
  def retry(organization_id, run_id) do
    transaction_with_broadcast(fn ->
      retry_locked_run(lock_run(organization_id, run_id))
    end)
  end

  @spec claim_download(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok,
           %{path: String.t(), filename: String.t(), size: non_neg_integer(), sha256: String.t()}}
          | {:error, :not_found}
  def claim_download(organization_id, version_id, run_id) do
    transaction_with_broadcast(fn ->
      case lock_scoped_run(organization_id, version_id, run_id) do
        %Run{state: :ready} = run ->
          claim_ready_download(run)

        _ ->
          {{:error, :not_found}, []}
      end
    end)
  end

  @spec complete_download(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t(), DateTime.t()) :: :ok
  def complete_download(organization_id, version_id, run_id, claim_id) do
    transaction_with_broadcast(fn ->
      case lock_scoped_run(organization_id, version_id, run_id) do
        %Run{state: :ready} = run ->
          {_, _} =
            from(r in Run,
              where:
                r.id == ^run.id and r.download_claimed_until == ^claim_id and
                  r.download_claimed_until >= fragment("CURRENT_TIMESTAMP"),
              update: [
                set: [download_claimed_until: nil, updated_at: fragment("CURRENT_TIMESTAMP")]
              ]
            )
            |> Repo.update_all([])

          {:ok, []}

        _ ->
          {:ok, []}
      end
    end)
    |> case do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Could not release export download claim: #{inspect(reason)}")
        :ok
    end
  end

  @spec cleanup_expired(Ecto.UUID.t()) :: non_neg_integer()
  def cleanup_expired(organization_id) do
    transaction_with_broadcast(fn ->
      runs =
        from(r in Run,
          where: r.organization_id == ^organization_id and r.state == :ready,
          where: r.artifact_expires_at < fragment("CURRENT_TIMESTAMP"),
          where:
            is_nil(r.download_claimed_until) or
              r.download_claimed_until < fragment("CURRENT_TIMESTAMP"),
          lock: "FOR UPDATE"
        )
        |> Repo.all()

      ids = Enum.flat_map(runs, &expired_artifact_id/1)

      {length(ids), ids}
    end)
  end

  @spec reconcile_expired(Ecto.UUID.t()) :: non_neg_integer()
  def reconcile_expired(organization_id) do
    transaction_with_broadcast(fn ->
      runs =
        from(r in Run,
          where: r.organization_id == ^organization_id and r.state == :building,
          where: r.lease_expires_at < fragment("CURRENT_TIMESTAMP"),
          lock: "FOR UPDATE"
        )
        |> Repo.all()

      ids = Enum.flat_map(runs, &reconciled_run_id/1)

      {length(ids), ids}
    end)
  end

  @spec get_for_version(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t()) :: Run.t() | nil
  def get_for_version(organization_id, version_id, run_id) do
    from(r in Run,
      where:
        r.id == ^run_id and r.organization_id == ^organization_id and
          r.gtfs_version_id == ^version_id
    )
    |> Repo.one()
  end

  @spec latest_for_version(Ecto.UUID.t(), Ecto.UUID.t(), :full | :pathways) :: Run.t() | nil
  def latest_for_version(organization_id, version_id, export_type)
      when export_type in [:full, :pathways] do
    from(r in Run,
      where:
        r.organization_id == ^organization_id and r.gtfs_version_id == ^version_id and
          r.export_type == ^export_type,
      order_by: [desc: r.inserted_at],
      limit: 1
    )
    |> Repo.one()
  end

  @spec topic(Run.t() | Ecto.UUID.t()) :: String.t()
  def topic(%Run{id: id}), do: topic(id)
  def topic(run_id) when is_binary(run_id), do: "export-run:" <> run_id

  defp create_pending_transition(organization_id, version_id, actor, export_type) do
    with true <- version_in_scope?(organization_id, version_id),
         :ok <- ArtifactStorage.available?() do
      create_or_reuse_pending(organization_id, version_id, actor, export_type)
    else
      false -> {{:error, :not_found}, []}
      {:error, :artifact_storage_unavailable} -> {{:error, :artifact_storage_unavailable}, []}
    end
  end

  defp create_or_reuse_pending(organization_id, version_id, actor, export_type) do
    lock_scope(organization_id, version_id, export_type)

    case lock_active_run(organization_id, version_id, export_type) do
      %Run{} = run -> {{:ok, run}, []}
      nil -> insert_pending_run(organization_id, version_id, actor, export_type)
    end
  end

  defp insert_pending_run(organization_id, version_id, actor, export_type) do
    attrs = %{
      organization_id: organization_id,
      gtfs_version_id: version_id,
      actor_id: actor.id,
      actor_email: actor.email,
      export_type: export_type,
      state: :pending,
      phase: :preflight
    }

    case Repo.insert(Run.system_changeset(%Run{}, attrs)) do
      {:ok, run} -> {{:ok, run}, [run.id]}
      {:error, changeset} -> {{:error, changeset}, []}
    end
  end

  defp commit_ready(organization_id, run_id, generation, token, artifact) do
    transaction_with_broadcast(fn ->
      ready_transition(organization_id, run_id, generation, token, artifact)
    end)
  end

  defp ready_transition(organization_id, run_id, generation, token, artifact) do
    with {:ok, run} <- fenced_run(organization_id, run_id, generation, token),
         :ok <- matching_artifact?(run, artifact),
         {:ok, ready} <- ready_run(run, generation, token, artifact) do
      {{:ok, ready}, [run.id]}
    else
      {:error, :lease_lost} -> {{:error, :lease_lost}, []}
      {:error, reason} -> {{:error, reason}, []}
    end
  end

  defp fail_locked_build(
         %Run{state: :building, lease_generation: generation, lease_token: token} = run,
         generation,
         token,
         code
       ) do
    if lease_current?(run.id), do: close_failed_build(run, code), else: lease_lost_result()
  end

  defp fail_locked_build(_run, _generation, _token, _code), do: lease_lost_result()

  defp close_failed_build(run, code) do
    state = if is_nil(run.cancel_requested_at), do: :failed, else: :cancelled

    case close_build(run, state, String.slice(code, 0, 128)) do
      {:ok, closed} -> {{:ok, closed}, [run.id]}
      {:error, _reason} -> lease_lost_result()
    end
  end

  defp lease_lost_result, do: {{:error, :lease_lost}, []}

  defp retry_locked_run(%Run{state: state} = run)
       when state in [:failed, :interrupted, :cancelled, :expired] do
    lock_scope(run.organization_id, run.gtfs_version_id, run.export_type)

    case lock_active_run(run.organization_id, run.gtfs_version_id, run.export_type) do
      nil -> insert_retry_run(run)
      %Run{} -> {{:error, :invalid_transition}, []}
    end
  end

  defp retry_locked_run(nil), do: {{:error, :not_found}, []}
  defp retry_locked_run(_run), do: {{:error, :invalid_transition}, []}

  defp insert_retry_run(run) do
    attrs = %{
      organization_id: run.organization_id,
      gtfs_version_id: run.gtfs_version_id,
      actor_id: run.actor_id,
      actor_email: run.actor_email,
      version_name: run.version_name,
      export_type: run.export_type,
      state: :pending,
      phase: :preflight
    }

    case Repo.insert(Run.system_changeset(%Run{}, attrs)) do
      {:ok, retry_run} -> {{:ok, retry_run}, [retry_run.id]}
      {:error, changeset} -> {{:error, changeset}, []}
    end
  end

  defp expired_artifact_id(run) do
    case expire_artifact(run) do
      {:ok, _expired} -> [run.id]
      _error -> []
    end
  end

  defp reconciled_run_id(run) do
    state = if is_nil(run.cancel_requested_at), do: :interrupted, else: :cancelled

    case close_build(run, state, "lease_expired") do
      {:ok, _closed} -> [run.id]
      _error -> []
    end
  end

  defp ready_run(run, generation, token, artifact) do
    database_now = database_now()
    expires_at = DateTime.add(database_now, artifact_ttl_seconds())

    changeset =
      Run.system_changeset(run, %{
        state: :ready,
        phase: :cleanup,
        lease_token: nil,
        lease_expires_at: nil,
        artifact_key: artifact.key,
        artifact_filename: artifact.filename,
        artifact_sha256: artifact.sha256,
        artifact_size_bytes: artifact.size,
        artifact_expires_at: expires_at,
        finished_at: database_now
      })

    if changeset.valid? do
      {updated, _} =
        from(r in Run,
          where:
            r.id == ^run.id and r.organization_id == ^run.organization_id and
              r.state == :building and r.lease_generation == ^generation and
              r.lease_token == ^token and is_nil(r.cancel_requested_at) and
              r.lease_expires_at >= fragment("clock_timestamp()"),
          update: [
            set: [
              state: :ready,
              phase: :cleanup,
              lease_token: nil,
              lease_expires_at: nil,
              artifact_key: ^artifact.key,
              artifact_filename: ^artifact.filename,
              artifact_sha256: ^artifact.sha256,
              artifact_size_bytes: ^artifact.size,
              artifact_expires_at: ^expires_at,
              finished_at: ^database_now,
              updated_at: fragment("CURRENT_TIMESTAMP")
            ]
          ]
        )
        |> Repo.update_all([])

      if updated == 1, do: {:ok, Repo.get!(Run, run.id)}, else: {:error, :lease_lost}
    else
      {:error, changeset}
    end
  end

  defp claim_ready_download(run) do
    if artifact_current?(run) and download_claim_available?(run.id) do
      artifact = artifact_from_run(run)

      case ArtifactStorage.verify(artifact) do
        {:ok, path} ->
          {1, _} =
            from(r in Run,
              where:
                r.id == ^run.id and r.state == :ready and
                  r.artifact_expires_at >= fragment("CURRENT_TIMESTAMP"),
              update: [
                set: [
                  download_claimed_until:
                    fragment(
                      "clock_timestamp() + (? * interval '1 second')",
                      ^@download_claim_seconds
                    ),
                  download_count: r.download_count + 1,
                  last_downloaded_at: fragment("clock_timestamp()"),
                  updated_at: fragment("clock_timestamp()")
                ]
              ]
            )
            |> Repo.update_all([])

          claimed_run = Repo.get!(Run, run.id)

          {{:ok,
            %{
              path: path,
              filename: run.artifact_filename,
              size: run.artifact_size_bytes,
              sha256: run.artifact_sha256,
              claim_id: claimed_run.download_claimed_until
            }}, [run.id]}

        {:error, :missing_or_corrupt_artifact} ->
          _ = close_corrupt_artifact(run)
          {{:error, :not_found}, [run.id]}
      end
    else
      {{:error, :not_found}, []}
    end
  end

  defp expire_artifact(run) do
    artifact = artifact_from_run(run)
    _ = ArtifactStorage.remove(artifact)

    Repo.update(
      Run.system_changeset(run, %{
        state: :expired,
        phase: :cleanup,
        artifact_key: nil,
        artifact_filename: nil,
        artifact_sha256: nil,
        artifact_size_bytes: nil,
        artifact_expires_at: nil,
        download_claimed_until: nil,
        failure_code: "artifact_expired",
        finished_at: DateTime.utc_now()
      })
    )
  end

  defp close_corrupt_artifact(run) do
    _ = ArtifactStorage.remove(artifact_from_run(run))

    Repo.update(
      Run.system_changeset(run, %{
        state: :failed,
        phase: :cleanup,
        artifact_key: nil,
        artifact_filename: nil,
        artifact_sha256: nil,
        artifact_size_bytes: nil,
        artifact_expires_at: nil,
        download_claimed_until: nil,
        failure_code: "missing_or_corrupt_artifact",
        finished_at: DateTime.utc_now()
      })
    )
  end

  defp close_build(run, state, code) do
    Repo.update(
      Run.system_changeset(run, %{
        state: state,
        phase: :cleanup,
        lease_token: nil,
        lease_expires_at: nil,
        failure_code: code,
        finished_at: DateTime.utc_now()
      })
    )
  end

  defp matching_artifact?(run, artifact) do
    if artifact.organization_id == run.organization_id and
         artifact.gtfs_version_id == run.gtfs_version_id and artifact.run_id == run.id,
       do: :ok,
       else: {:error, :invalid_artifact}
  end

  defp requested_artifact?(organization_id, run_id, artifact) do
    if Map.get(artifact, :organization_id) == organization_id and
         Map.get(artifact, :run_id) == run_id,
       do: :ok,
       else: {:error, :invalid_artifact}
  end

  defp artifact_current?(run) do
    from(r in Run,
      where:
        r.id == ^run.id and r.state == :ready and
          r.artifact_expires_at >= fragment("CURRENT_TIMESTAMP")
    )
    |> Repo.exists?()
  end

  defp download_claim_available?(run_id) do
    from(r in Run,
      where:
        r.id == ^run_id and
          (is_nil(r.download_claimed_until) or
             r.download_claimed_until < fragment("CURRENT_TIMESTAMP"))
    )
    |> Repo.exists?()
  end

  defp artifact_from_run(run) do
    %{
      organization_id: run.organization_id,
      gtfs_version_id: run.gtfs_version_id,
      run_id: run.id,
      key: run.artifact_key,
      filename: run.artifact_filename,
      sha256: run.artifact_sha256,
      size: run.artifact_size_bytes
    }
  end

  defp artifact_ttl_seconds do
    Application.get_env(:gtfs_planner, :gtfs_task_artifacts_ttl_seconds, 86_400)
  end

  defp artifact_storage_module do
    Application.get_env(:gtfs_planner, :export_artifact_storage_module, ArtifactStorage)
  end

  defp database_now do
    %Postgrex.Result{rows: [[database_now]]} = Repo.query!("SELECT CURRENT_TIMESTAMP")
    database_now
  end

  defp transaction_with_broadcast(fun) do
    case Repo.transaction(fun) do
      {:ok, {result, run_ids}} ->
        Enum.uniq(run_ids)
        |> Enum.each(
          &Phoenix.PubSub.broadcast(GtfsPlanner.PubSub, topic(&1), {:export_run_changed, &1})
        )

        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp lock_scope(organization_id, version_id, export_type) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [
      organization_id <> version_id <> Atom.to_string(export_type)
    ])
  end

  defp version_in_scope?(organization_id, version_id) do
    from(v in GtfsVersion, where: v.id == ^version_id and v.organization_id == ^organization_id)
    |> Repo.exists?()
  end

  defp lock_active_run(organization_id, version_id, export_type) do
    from(r in Run,
      where:
        r.organization_id == ^organization_id and r.gtfs_version_id == ^version_id and
          r.export_type == ^export_type and r.state not in ^@terminal_states,
      lock: "FOR UPDATE"
    )
    |> Repo.one()
  end

  defp lock_run(organization_id, run_id) do
    from(r in Run,
      where: r.id == ^run_id and r.organization_id == ^organization_id,
      lock: "FOR UPDATE"
    )
    |> Repo.one()
  end

  defp lock_scoped_run(organization_id, version_id, run_id) do
    from(r in Run,
      where:
        r.id == ^run_id and r.organization_id == ^organization_id and
          r.gtfs_version_id == ^version_id,
      lock: "FOR UPDATE"
    )
    |> Repo.one()
  end

  defp claimable?(%Run{state: :pending, cancel_requested_at: nil}), do: true

  defp claimable?(%Run{state: :building, cancel_requested_at: nil} = run) do
    from(r in Run, where: r.id == ^run.id and r.lease_expires_at < fragment("CURRENT_TIMESTAMP"))
    |> Repo.exists?()
  end

  defp claimable?(_), do: false

  defp fenced_run(organization_id, run_id, generation, token) do
    case lock_run(organization_id, run_id) do
      %Run{} = run ->
        if run.state == :building and run.lease_generation == generation and
             run.lease_token == token and
             is_nil(run.cancel_requested_at) and lease_current?(run.id),
           do: {:ok, run},
           else: {:error, :lease_lost}

      nil ->
        {:error, :not_found}
    end
  end

  defp lease_current?(run_id) do
    from(r in Run, where: r.id == ^run_id and r.lease_expires_at >= fragment("CURRENT_TIMESTAMP"))
    |> Repo.exists?()
  end
end
