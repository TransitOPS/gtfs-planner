defmodule GtfsPlanner.Gtfs.ExportRuns do
  @moduledoc """
  Durable, tenant-scoped export transitions and download claims.

  Workers own only a fenced generation/token. Artifact files remain private until
  `mark_ready/5` commits verified metadata for the run's artifacts to the matching
  run row. A run holds at most one main artifact and one flex artifact, both
  published from one export snapshot and both removed by one expiry or corruption
  transition.
  """

  import Ecto.Query, warn: false

  require Logger

  alias GtfsPlanner.Gtfs.Export.ArtifactStorage
  alias GtfsPlanner.Gtfs.Export.PublicationPin
  alias GtfsPlanner.Gtfs.Export.Run
  alias GtfsPlanner.Gtfs.ExportDefaults
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion

  @type actor :: %{required(:id) => Ecto.UUID.t(), required(:email) => String.t()}

  @export_types Run.export_types()
  @lease_seconds Application.compile_env(:gtfs_planner, :export_run_lease_seconds, 300)
  @download_claim_seconds Application.compile_env(
                            :gtfs_planner,
                            :export_download_claim_seconds,
                            60
                          )
  @pin_lease_seconds Application.compile_env(
                       :gtfs_planner,
                       :export_publication_pin_seconds,
                       180
                     )
  @terminal_states [:ready, :failed, :interrupted, :cancelled, :expired]

  @spec create_pending(Ecto.UUID.t(), Ecto.UUID.t(), actor(), :full | :pathways | :operations) ::
          {:ok, Run.t()} | {:error, term()}
  def create_pending(organization_id, version_id, actor, export_type)
      when export_type in @export_types do
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

  @typedoc """
  The verified artifacts of one build: `:main` is required and `:flex` is the
  RUN15-only extra feed, absent or nil when the build produced no flex zip.
  """
  @type artifacts :: %{required(:main) => map(), optional(:flex) => map() | nil}

  @spec mark_ready(Ecto.UUID.t(), Ecto.UUID.t(), pos_integer(), Ecto.UUID.t(), artifacts()) ::
          {:ok, Run.t()} | {:error, :lease_lost | term()}
  def mark_ready(organization_id, run_id, generation, token, %{main: main} = artifacts)
      when is_map(main) do
    flex = Map.get(artifacts, :flex)

    with :ok <- requested_artifacts?(organization_id, run_id, main, flex),
         :ok <- verified_artifacts(main, flex) do
      commit_ready(organization_id, run_id, generation, token, %{main: main, flex: flex})
    end
  end

  def mark_ready(_, _, _, _, _), do: {:error, :invalid_artifact}

  defp requested_artifacts?(organization_id, run_id, main, flex) do
    with :ok <- requested_artifact?(organization_id, run_id, main) do
      if is_nil(flex), do: :ok, else: requested_artifact?(organization_id, run_id, flex)
    end
  end

  defp verified_artifacts(main, flex) do
    with {:ok, _main_path} <- artifact_storage_module().verify(main),
         {:ok, _flex_path} <- verify_flex_artifact(flex) do
      :ok
    end
  end

  defp verify_flex_artifact(nil), do: {:ok, nil}
  defp verify_flex_artifact(flex), do: artifact_storage_module().verify(flex)

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

  @doc """
  Closes a pending run whose runner was refused because the supervisor was at
  capacity (`Export.Runner.start_build/4` returned `{:error, :busy}`).

  `generation` is the run's `lease_generation` when the caller started it. A
  `pending` run still at that generation was never claimed; it becomes `failed`
  with `failure_code` `busy`, so a new request can create a fresh run. A run that
  was claimed, closed or cancelled in the meantime returns
  `{:error, :invalid_transition}` and nothing changes.
  """
  @spec fail_unstarted(Ecto.UUID.t(), Ecto.UUID.t(), non_neg_integer()) ::
          {:ok, Run.t()} | {:error, :not_found | :invalid_transition}
  def fail_unstarted(organization_id, run_id, generation) do
    transaction_with_broadcast(fn ->
      case lock_run(organization_id, run_id) do
        nil -> {{:error, :not_found}, []}
        run -> close_unstarted(run, generation)
      end
    end)
  end

  defp close_unstarted(
         %Run{state: :pending, lease_generation: generation, cancel_requested_at: nil} = run,
         generation
       ) do
    now = DateTime.utc_now()

    attrs = %{
      state: :failed,
      phase: :cleanup,
      failure_code: "busy",
      started_at: now,
      finished_at: now
    }

    {:ok, failed} = Repo.update(Run.system_changeset(run, attrs))
    {{:ok, failed}, [run.id]}
  end

  defp close_unstarted(_run, _generation), do: {{:error, :invalid_transition}, []}

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
  def claim_download(organization_id, version_id, run_id),
    do: claim_download(organization_id, version_id, run_id, :main)

  @spec claim_download(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t(), :main | :flex) ::
          {:ok,
           %{path: String.t(), filename: String.t(), size: non_neg_integer(), sha256: String.t()}}
          | {:error, :not_found}
  def claim_download(organization_id, version_id, run_id, file) when file in [:main, :flex] do
    transaction_with_broadcast(fn ->
      case lock_scoped_run(organization_id, version_id, run_id) do
        %Run{state: :ready} = run ->
          claim_ready_download(run, file)

        _ ->
          {{:error, :not_found}, []}
      end
    end)
  end

  def claim_download(_, _, _, _), do: {:error, :not_found}

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

  @doc """
  Leases the private bytes of one ready run's artifact for a public generation.

  This is the same verified ready-artifact owner as `claim_download/4`, minus the
  download bookkeeping: no `download_count` increment, no download claim, and a
  renewable lease instead of a single request. A live pin also makes
  `cleanup_expired/1` skip the run, so the reviewed bytes survive the private
  artifact TTL while a public generation is still being validated and uploaded.

  `slot` is a trusted server value naming the `main` or `flex` artifact of the
  run; no client may choose a file key. One run carries one pin: a second owner
  receives `{:error, :artifact_busy}` rather than replacing the live claim, and
  the run's `ON DELETE CASCADE` from its GTFS version cannot remove a pinned run.
  """
  @spec pin_publication(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t(), :main | :flex, String.t()) ::
          {:ok,
           %{
             path: String.t(),
             filename: String.t(),
             size: non_neg_integer(),
             sha256: String.t(),
             pin_token: Ecto.UUID.t()
           }}
          | {:error, :not_found | :artifact_busy}
  def pin_publication(organization_id, version_id, run_id, slot, owner_id)
      when slot in [:main, :flex] and is_binary(owner_id) and byte_size(owner_id) > 0 do
    transaction_with_broadcast(fn ->
      case lock_scoped_run(organization_id, version_id, run_id) do
        %Run{state: :ready} = run -> pin_ready_artifact(run, slot, owner_id)
        _ -> {{:error, :not_found}, []}
      end
    end)
  end

  def pin_publication(_, _, _, _, _), do: {:error, :not_found}

  @doc """
  Extends a live pin and rotates its token.

  The rotation is the fence: a worker that still holds the previous token can no
  longer renew or release the renewed claim, so a delayed completion cannot clear
  a claim it no longer owns.
  """
  @spec renew_publication_pin(Ecto.UUID.t(), Ecto.UUID.t(), map()) ::
          {:ok, %{pin_token: Ecto.UUID.t(), expires_at: DateTime.t()}}
          | {:error, :lease_lost | :not_found}
  def renew_publication_pin(
        organization_id,
        run_id,
        %{owner_id: owner_id, pin_token: token} = claim
      )
      when is_binary(owner_id) and is_binary(token) do
    transaction_with_broadcast(fn ->
      case lock_scoped_pin(organization_id, run_id, claim) do
        %PublicationPin{export_run_id: export_run_id, pin_token: current} = pin ->
          token = Ecto.UUID.generate()
          expires_at = DateTime.add(database_now(), @pin_lease_seconds)

          {1, _} =
            from(p in PublicationPin,
              where: p.id == ^pin.id and p.pin_token == ^current,
              update: [
                set: [
                  pin_token: ^token,
                  expires_at: ^expires_at,
                  updated_at: fragment("CURRENT_TIMESTAMP")
                ]
              ]
            )
            |> Repo.update_all([])

          {{:ok, %{pin_token: token, expires_at: expires_at}}, [export_run_id]}

        nil ->
          {{:error, :lease_lost}, []}
      end
    end)
  end

  def renew_publication_pin(_, _, _), do: {:error, :not_found}

  @doc """
  Drops a pin the caller still owns, allowing cleanup to proceed.

  Release requires the same owner and token that created the claim, so a stale
  completion cannot remove a claim another worker has since renewed.
  """
  @spec release_publication_pin(Ecto.UUID.t(), Ecto.UUID.t(), map()) ::
          :ok | {:error, :lease_lost}
  def release_publication_pin(
        organization_id,
        run_id,
        %{owner_id: owner_id, pin_token: token} = claim
      )
      when is_binary(owner_id) and is_binary(token) do
    transaction_with_broadcast(fn ->
      case lock_scoped_pin(organization_id, run_id, claim) do
        %PublicationPin{id: pin_id, export_run_id: export_run_id} ->
          {1, _} = Repo.delete_all(from(p in PublicationPin, where: p.id == ^pin_id))
          {:ok, [export_run_id]}

        nil ->
          {{:error, :lease_lost}, []}
      end
    end)
    |> case do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Could not release export publication pin: #{inspect(reason)}")
        :ok
    end
  end

  def release_publication_pin(_, _, _), do: :ok

  @doc """
  Removes the pins whose lease has passed, so their runs can be cleaned up.

  This runs from the existing lifecycle maintenance before
  `cleanup_expired/1`; an expired pin is no protection, and the run's own
  `artifact_expires_at` decides when its bytes are removed.
  """
  @spec purge_expired_publication_pins(Ecto.UUID.t()) :: non_neg_integer()
  def purge_expired_publication_pins(organization_id) do
    {count, _} =
      Repo.delete_all(
        from(p in PublicationPin,
          where: p.organization_id == ^organization_id,
          where: p.expires_at < fragment("CURRENT_TIMESTAMP")
        )
      )

    count
  end

  @doc """
  Returns one run the organization owns, or `nil`.
  """
  @spec get_scoped_run(Ecto.UUID.t(), Ecto.UUID.t()) :: Run.t() | nil
  def get_scoped_run(organization_id, run_id) do
    from(r in Run,
      where: r.id == ^run_id and r.organization_id == ^organization_id
    )
    |> Repo.one()
  end

  @doc """
  Returns the verified bytes a live pin holds, without renewing or releasing it.

  This is the reader a validation run uses to feed the selected artifact to the
  validator CLI: the pin row is still locked and owned by `claim`, the run is
  still `ready`, and `ArtifactStorage.verify/1` re-hashes the file so the bytes
  the caller reads are the bytes the run row recorded. It reuses the same
  ready-artifact verification `claim_download/4` and `pin_publication/5` use and
  records no download.

  A pin that was released, rotated to another token, or moved to another slot is
  `{:error, :pin_lost}`; expired or corrupt bytes are
  `{:error, :missing_or_corrupt_artifact}` and normalize the run exactly as a
  download claim normalizes them.
  """
  @spec pinned_artifact(Ecto.UUID.t(), Ecto.UUID.t(), :main | :flex, map()) ::
          {:ok,
           %{
             path: String.t(),
             filename: String.t(),
             size: non_neg_integer(),
             sha256: String.t()
           }}
          | {:error, :not_found | :pin_lost | :missing_or_corrupt_artifact}
  def pinned_artifact(organization_id, run_id, slot, claim)
      when slot in [:main, :flex] and is_map(claim) do
    transaction_with_broadcast(fn ->
      with %Run{state: :ready} = run <- lock_run(organization_id, run_id),
           %PublicationPin{slot: ^slot} <- lock_scoped_pin(organization_id, run_id, claim) do
        read_verified_artifact(run, slot)
      else
        %PublicationPin{} -> {{:error, :pin_lost}, []}
        nil -> {{:error, :pin_lost}, []}
        %Run{} -> {{:error, :not_found}, []}
      end
    end)
  end

  def pinned_artifact(_, _, _, _), do: {:error, :not_found}

  # The same ready-artifact check `pin_ready_artifact/3` applies, without
  # claiming a lease: corrupt or expired bytes are normalized the same way.
  defp read_verified_artifact(%Run{} = run, slot) do
    artifact = artifact_from_run(run, slot)

    if is_binary(artifact.key) and artifact_current?(run) do
      case ArtifactStorage.verify(artifact) do
        {:ok, path} ->
          {{:ok, pinned_artifact(artifact, path, nil)}, [run.id]}

        {:error, :missing_or_corrupt_artifact} ->
          _ = close_corrupt_artifact(run)
          {{:error, :missing_or_corrupt_artifact}, [run.id]}
      end
    else
      {{:error, :not_found}, []}
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
          where: r.id not in subquery(pinned_run()),
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

  # A run closed by `fail_unstarted/3` built nothing, so it does not replace the
  # export the page was showing.
  @spec latest_for_version(Ecto.UUID.t(), Ecto.UUID.t(), :full | :pathways | :operations) ::
          Run.t() | nil | {:error, :invalid_export_type}
  def latest_for_version(organization_id, version_id, export_type)
      when export_type in @export_types do
    from(r in Run,
      where:
        r.organization_id == ^organization_id and r.gtfs_version_id == ^version_id and
          r.export_type == ^export_type,
      where: r.state != :failed or coalesce(r.failure_code, "") != "busy",
      order_by: [desc: r.inserted_at],
      limit: 1
    )
    |> Repo.one()
  end

  def latest_for_version(_, _, _), do: {:error, :invalid_export_type}

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
    attrs =
      %{
        organization_id: organization_id,
        gtfs_version_id: version_id,
        actor_id: actor.id,
        actor_email: actor.email,
        export_type: export_type,
        state: :pending,
        phase: :preflight,
        include_flex: include_flex_for(organization_id, export_type)
      }
      |> Map.merge(estimate_for(organization_id, export_type))

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
    attrs =
      %{
        organization_id: run.organization_id,
        gtfs_version_id: run.gtfs_version_id,
        actor_id: run.actor_id,
        actor_email: run.actor_email,
        version_name: run.version_name,
        export_type: run.export_type,
        state: :pending,
        phase: :preflight,
        include_flex: include_flex_for(run.organization_id, run.export_type)
      }
      |> Map.merge(estimate_for(run.organization_id, run.export_type))

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

  # Both artifact sets land in the same fenced `update_all`, so a lease loss
  # leaves the row without either set and the files unreferenced.
  defp ready_run(run, generation, token, %{main: main, flex: flex}) do
    database_now = database_now()
    expires_at = DateTime.add(database_now, artifact_ttl_seconds())
    flex_fields = flex_artifact_fields(flex)

    attrs =
      Map.merge(
        %{
          state: :ready,
          phase: :cleanup,
          lease_token: nil,
          lease_expires_at: nil,
          artifact_key: main.key,
          artifact_filename: main.filename,
          artifact_sha256: main.sha256,
          artifact_size_bytes: main.size,
          artifact_expires_at: expires_at,
          finished_at: database_now
        },
        flex_fields
      )

    changeset = Run.system_changeset(run, attrs)

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
              artifact_key: ^main.key,
              artifact_filename: ^main.filename,
              artifact_sha256: ^main.sha256,
              artifact_size_bytes: ^main.size,
              artifact_expires_at: ^expires_at,
              flex_artifact_key: ^flex_fields.flex_artifact_key,
              flex_artifact_filename: ^flex_fields.flex_artifact_filename,
              flex_artifact_sha256: ^flex_fields.flex_artifact_sha256,
              flex_artifact_size_bytes: ^flex_fields.flex_artifact_size_bytes,
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

  defp flex_artifact_fields(nil) do
    %{
      flex_artifact_key: nil,
      flex_artifact_filename: nil,
      flex_artifact_sha256: nil,
      flex_artifact_size_bytes: nil
    }
  end

  defp flex_artifact_fields(artifact) do
    %{
      flex_artifact_key: artifact.key,
      flex_artifact_filename: artifact.filename,
      flex_artifact_sha256: artifact.sha256,
      flex_artifact_size_bytes: artifact.size
    }
  end

  # A run without the requested file is a plain 404: only a file that exists but
  # no longer verifies fails the run and removes both artifacts.
  defp claim_ready_download(run, file) do
    artifact = artifact_from_run(run, file)

    if is_binary(artifact.key) and artifact_current?(run) and download_claim_available?(run.id) do
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
              filename: artifact.filename,
              size: artifact.size,
              sha256: artifact.sha256,
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

  # A live pin reuses the ready-artifact verification `claim_ready_download/2`
  # already owns, and only then writes a lease row. The run row stays locked for
  # the whole transaction, so a pin, a renewal and a release cannot interleave.
  defp pin_ready_artifact(run, slot, owner_id) do
    artifact = artifact_from_run(run, slot)

    if is_binary(artifact.key) and artifact_current?(run) do
      verify_then_pin(run, slot, owner_id, artifact)
    else
      {{:error, :not_found}, []}
    end
  end

  defp verify_then_pin(run, slot, owner_id, artifact) do
    case ArtifactStorage.verify(artifact) do
      {:ok, path} ->
        case claim_pin(run, slot, owner_id) do
          {:ok, token} -> {{:ok, pinned_artifact(artifact, path, token)}, [run.id]}
          {:error, reason} -> {{:error, reason}, [run.id]}
        end

      {:error, :missing_or_corrupt_artifact} ->
        _ = close_corrupt_artifact(run)
        {{:error, :not_found}, [run.id]}
    end
  end

  defp pinned_artifact(artifact, path, token) do
    %{
      path: path,
      filename: artifact.filename,
      size: artifact.size,
      sha256: artifact.sha256,
      pin_token: token
    }
  end

  # Replacing the expired row of the same owner is a renewal of that owner's
  # claim; a different owner never inherits it. The unique index on
  # `export_run_id` decides the winner, so two racers cannot both hold the run.
  defp claim_pin(run, slot, owner_id) do
    _ = delete_expired_pin(run.id)

    case lock_run_pin(run.id) do
      nil ->
        insert_pin(run, slot, owner_id)

      %PublicationPin{owner_id: ^owner_id} = pin ->
        replace_pin(pin, slot, owner_id)

      %PublicationPin{} ->
        {:error, :artifact_busy}
    end
  end

  defp insert_pin(run, slot, owner_id) do
    attrs = %{
      export_run_id: run.id,
      organization_id: run.organization_id,
      slot: slot,
      owner_id: owner_id,
      pin_token: Ecto.UUID.generate(),
      expires_at: DateTime.add(database_now(), @pin_lease_seconds)
    }

    case Repo.insert(PublicationPin.system_changeset(%PublicationPin{}, attrs)) do
      {:ok, pin} -> {:ok, pin.pin_token}
      {:error, _changeset} -> {:error, :artifact_busy}
    end
  end

  defp replace_pin(pin, slot, owner_id) do
    token = Ecto.UUID.generate()
    expires_at = DateTime.add(database_now(), @pin_lease_seconds)

    {1, _} =
      from(p in PublicationPin,
        where: p.id == ^pin.id and p.owner_id == ^owner_id,
        update: [
          set: [
            slot: ^slot,
            pin_token: ^token,
            expires_at: ^expires_at,
            updated_at: fragment("CURRENT_TIMESTAMP")
          ]
        ]
      )
      |> Repo.update_all([])

    {:ok, token}
  end

  defp lock_scoped_pin(organization_id, run_id, %{owner_id: owner_id, pin_token: token}) do
    from(p in PublicationPin,
      where:
        p.export_run_id == ^run_id and p.organization_id == ^organization_id and
          p.owner_id == ^owner_id and p.pin_token == ^token and
          p.expires_at >= fragment("CURRENT_TIMESTAMP"),
      lock: "FOR UPDATE"
    )
    |> Repo.one()
  end

  defp lock_run_pin(run_id) do
    from(p in PublicationPin, where: p.export_run_id == ^run_id, lock: "FOR UPDATE")
    |> Repo.one()
  end

  defp delete_expired_pin(run_id) do
    Repo.delete_all(
      from(p in PublicationPin,
        where: p.export_run_id == ^run_id,
        where: p.expires_at < fragment("CURRENT_TIMESTAMP")
      )
    )
  end

  # A pin protects the artifact only while its own lease is live; `purge_/1`
  # removes the row afterwards, so this predicate is the whole exclusion.
  defp pinned_run do
    from(p in PublicationPin,
      select: p.export_run_id,
      where: p.expires_at >= fragment("CURRENT_TIMESTAMP")
    )
  end

  defp expire_artifact(run) do
    _ = remove_artifacts(run)

    Repo.update(
      Run.system_changeset(
        run,
        Map.merge(
          %{
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
          },
          flex_artifact_fields(nil)
        )
      )
    )
  end

  defp close_corrupt_artifact(run) do
    _ = remove_artifacts(run)

    Repo.update(
      Run.system_changeset(
        run,
        Map.merge(
          %{
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
          },
          flex_artifact_fields(nil)
        )
      )
    )
  end

  # Both files of a run live in its directory, so one removal covers either
  # transition; a run with no flex artifact removes only the main file.
  defp remove_artifacts(run) do
    _ = ArtifactStorage.remove(artifact_from_run(run, :main))

    if is_binary(run.flex_artifact_key) do
      _ = ArtifactStorage.remove(artifact_from_run(run, :flex))
    end

    :ok
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

  defp matching_artifact?(run, %{main: main, flex: flex}) do
    if artifact_in_scope?(run, main) and (is_nil(flex) or artifact_in_scope?(run, flex)),
      do: :ok,
      else: {:error, :invalid_artifact}
  end

  defp artifact_in_scope?(run, artifact) do
    artifact.organization_id == run.organization_id and
      artifact.gtfs_version_id == run.gtfs_version_id and artifact.run_id == run.id
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

  defp artifact_from_run(run, :main) do
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

  defp artifact_from_run(run, :flex) do
    %{
      organization_id: run.organization_id,
      gtfs_version_id: run.gtfs_version_id,
      run_id: run.id,
      key: run.flex_artifact_key,
      filename: run.flex_artifact_filename,
      sha256: run.flex_artifact_sha256,
      size: run.flex_artifact_size_bytes
    }
  end

  defp artifact_ttl_seconds do
    Application.get_env(:gtfs_planner, :gtfs_task_artifacts_ttl_seconds, 86_400)
  end

  # The flex file is an extra artifact on full and operations runs only, and it is
  # recorded when the run row is created, so a later switch change cannot alter a
  # run that already exists. A pathways run never carries flex (AC-15).
  defp include_flex_for(organization_id, export_type) do
    export_type in [:full, :operations] and ExportDefaults.get(organization_id).include_flex
  end

  # The missing-time estimate a new run builds with, recorded at creation beside
  # `include_flex`, so a later defaults change cannot alter a run that already
  # exists. A pathways run never carries estimates (no `stop_times.txt`), and the
  # method is nil whenever the run does not estimate.
  defp estimate_for(organization_id, export_type) do
    if export_type in [:full, :operations] do
      defaults = ExportDefaults.get(organization_id)

      if defaults.estimate_missing_times do
        %{estimate_missing_times: true, estimate_method: defaults.estimate_method}
      else
        %{estimate_missing_times: false, estimate_method: nil}
      end
    else
      %{estimate_missing_times: false, estimate_method: nil}
    end
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
