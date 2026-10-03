defmodule GtfsPlanner.FeedPublishing.Publisher do
  @moduledoc """
  Drives one frozen publication attempt to a truthfully confirmed manifest.

  An attempt is the durable work item: the channel command allocates its
  sequence and fresh generation, freezes the exact manifest bytes and its
  expected predecessor ETag, and records the immutable payload objects the
  manifest will name. `advance/3` is the only delivery step, and it never
  changes those frozen values. A new predecessor or a changed desired revision
  needs a new authorized attempt; a retry always replays this one.

  The step is deliberately conservative, because a database commit and an object
  store write are separate effects:

    1. Claim the attempt with a lease. Only the winner sends. Another node's
       live lease defers as `:pending`.
    2. Stage every immutable payload first and verify the existing object when a
       reserved key is already taken. No manifest is written while any payload
       is unconfirmed.
    3. Replace the one manifest with the frozen condition: `If-None-Match: *`
       for a first creation, `If-Match` of the frozen predecessor otherwise.
    4. A lost condition, a timeout or an unreadable outcome is not a failure and
       never rebases the attempt onto a freshly read ETag. The publisher reads
       the manifest back: if it equals this attempt the receipt is completed
       without resending, if a newer owned generation is current the attempt is
       retired as `:superseded`, and anything else is a visible `:blocked`
       conflict.
    5. The receipt is persisted only from the verified manifest, and only when
       the attempt still matches the channel's desired revision.

  A `:pending` result is normal progress: the frozen intent is kept and the next
  tick replays exactly it. Retired or blocked attempts remain rows until a later
  collection step fences them.

  ## Supervision

  `GtfsPlanner.Application` supervises this module only when publishing
  configuration is complete, so a disabled installation never starts a worker
  that could send HTTP. The supervised process scans the durable rows on an
  immediate first tick and then every 30 seconds; a tick needs no browser and no
  LiveView, and PubSub is only ever a wake signal.

  A tick keeps two independent kinds of work apart. Realtime work (composing and
  refreshing one organization's Alerts feed) runs on the tick caller and is
  bounded per tick. Static work (uploading a selected ZIP) is dispatched to a
  separate supervised task pool with its own finite capacity, so a long static
  upload never occupies the realtime slots; a pool at capacity defers that item
  to the next tick. Each channel is still serialized by the durable attempt
  lease, so two application nodes cannot both issue one attempt's PUT.
  """

  use GenServer

  import Ecto.Query, warn: false

  alias GtfsPlanner.Alerts.Feed, as: AlertsFeed
  alias GtfsPlanner.Alerts.Publication, as: AlertPublication
  alias GtfsPlanner.FeedPublishing
  alias GtfsPlanner.FeedPublishing.Attempt
  alias GtfsPlanner.FeedPublishing.Config
  alias GtfsPlanner.FeedPublishing.Manifest
  alias GtfsPlanner.FeedPublishing.Namespace
  alias GtfsPlanner.FeedPublishing.Publication
  alias GtfsPlanner.FeedPublishing.Storage
  alias GtfsPlanner.Repo
  alias GtfsPlanner.RunnerAdmission

  @lease_seconds 180
  @retry_seconds 30
  @tick_interval_ms 30_000
  @static_capacity 1
  @realtime_capacity 2
  @static_tasks GtfsPlanner.FeedPublishing.Publisher.StaticTasks
  @retirement_grace_seconds 24 * 60 * 60
  @collect_limit 100
  @collection_list_limit 100

  @type advance_result :: {:ok, :current | :pending | :superseded} | {:error, atom()}

  @doc """
  Advances one attempt through staging, the conditional manifest switch and
  receipt reconciliation.

  Returns `{:ok, :current}` when this attempt is the served manifest,
  `{:ok, :pending}` when work remains for a later retry, `{:ok, :superseded}`
  when a newer owned generation or intent has taken over, and `{:error, _}` for
  a definitive refusal such as a foreign object at a reserved key.
  """
  @spec advance(Config.t(), Publication.t(), Attempt.t()) :: advance_result()
  def advance(%Config{} = config, %Publication{} = publication, %Attempt{} = attempt) do
    case claim(publication, attempt) do
      {:claimed, claimed, mode} -> run(config, claimed, mode)
      {:done, result} -> result
      :busy -> {:ok, :pending}
      {:stale, stale} -> stale(config, stale)
      {:error, reason} -> {:error, reason}
    end
  end

  # -- Supervision and the periodic scan ------------------------------------

  @doc """
  Starts the periodic publisher.

  Ordinary application startup adds this child only when publishing
  configuration is complete. `opts` accepts `:interval_ms` and `:name`; the
  healthy interval is 30 seconds and the work capacities come from
  `:feed_publishing_static_capacity` / `:feed_publishing_realtime_capacity`
  (defaults one and two).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    {:ok, static_tasks} =
      Task.Supervisor.start_link(max_children: static_capacity(), name: @static_tasks)

    state = %{
      interval_ms: Keyword.get(opts, :interval_ms, @tick_interval_ms),
      static_tasks: static_tasks,
      inflight: %{},
      waiters: []
    }

    send(self(), :tick)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    state =
      state
      |> track(tick(DateTime.utc_now()))
      |> schedule_next()

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    state = %{state | inflight: Map.delete(state.inflight, ref)}
    {:noreply, release_waiters(state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def handle_call(:await_idle, from, state) do
    if map_size(state.inflight) == 0 do
      {:reply, :ok, state}
    else
      {:noreply, %{state | waiters: [from | state.waiters]}}
    end
  end

  @doc """
  Returns after every static task dispatched by an earlier tick has finished.

  This is the drain a test or an orderly shutdown uses. It starts no work and
  never bypasses the supervised pool.
  """
  @spec await_idle(timeout()) :: :ok
  def await_idle(timeout \\ 5_000), do: GenServer.call(__MODULE__, :await_idle, timeout)

  @doc """
  Runs one scan-and-deliver cycle at `now`.

  Returns `:disabled` when publishing is not configured, otherwise a map with
  the number of realtime channels refreshed and the pids of the static tasks
  started (empty when the static pool is not running and the work ran on the
  caller). The supervised process calls this on every tick; a test calls it
  directly to drive a deterministic clock.
  """
  @spec tick(DateTime.t()) :: :disabled | %{realtime: non_neg_integer(), static: [pid()]}
  def tick(now \\ DateTime.utc_now()) do
    case Config.current() do
      {:enabled, config} -> run_cycle(config, now)
      :disabled -> :disabled
    end
  end

  @doc """
  Collects safely retired payload objects for every channel.

  A disabled capability collects nothing and makes no request. Otherwise it
  confirms each channel's current manifest with a strong read, protects the
  current manifest's object keys and every unresolved (`pending`/`switching`)
  attempt's keys, deletes the objects of retired attempts whose 24-hour grace
  has passed, advances the channel's contiguous `retired_through_sequence`
  watermark before pruning those attempt rows, and finally does one bounded
  owned-prefix listing to remove late-upload orphans whose matching identity
  metadata and observation instant prove they are retired. At most `limit`
  objects are removed per call; unavailable storage deletes nothing and keeps
  every record.
  """
  @spec collect_retired(DateTime.t(), pos_integer()) ::
          {:ok, non_neg_integer()} | {:error, atom()}
  def collect_retired(now \\ DateTime.utc_now(), limit \\ @collect_limit) do
    case Config.current() do
      :disabled -> {:ok, 0}
      {:enabled, config} -> {:ok, collect_publications(config, now, min(limit, @collect_limit))}
    end
  end

  defp schedule_next(state) do
    Process.send_after(self(), :tick, state.interval_ms)
    state
  end

  defp track(state, %{static: pids}) do
    inflight =
      Enum.reduce(pids, state.inflight, fn pid, acc -> Map.put(acc, Process.monitor(pid), pid) end)

    %{state | inflight: inflight}
  end

  defp track(state, _result), do: state

  defp release_waiters(%{inflight: inflight} = state) when map_size(inflight) == 0 do
    Enum.each(state.waiters, &GenServer.reply(&1, :ok))
    %{state | waiters: []}
  end

  defp release_waiters(state), do: state

  # -- The scan -------------------------------------------------------------

  defp run_cycle(config, now) do
    channels =
      candidate_organizations()
      |> Enum.map(fn organization_id -> {organization_id, ensure_namespace(organization_id)} end)
      |> Enum.reject(fn {_id, namespace} -> is_nil(namespace) end)
      |> Enum.flat_map(fn {organization_id, namespace} ->
        ensure_channels(organization_id, namespace)
      end)

    {alerts, statics} = Enum.split_with(channels, &(&1.channel == :alerts))

    realtime =
      alerts
      |> Enum.take(realtime_capacity())
      |> Enum.count(fn publication -> service_alerts(config, publication, now) == :ok end)

    static =
      statics
      |> Enum.filter(&active_attempt?/1)
      |> Enum.take(static_capacity())
      |> Enum.flat_map(&dispatch_static(config, &1))

    %{
      realtime: realtime,
      static: static,
      retired: collect_publications(config, now, @collect_limit)
    }
  end

  defp candidate_organizations do
    publication_orgs = Repo.all(from p in Publication, select: p.organization_id, distinct: true)

    alert_orgs =
      Repo.all(
        from p in AlertPublication,
          where: p.withdrawal == :none and not is_nil(p.desired_snapshot),
          select: p.organization_id,
          distinct: true
      )

    Enum.uniq(publication_orgs ++ alert_orgs)
  end

  defp ensure_namespace(organization_id) do
    case FeedPublishing.ensure_namespace_for(organization_id) do
      {:ok, namespace} -> namespace
      _ -> nil
    end
  end

  # A channel row exists once the organization has a deliberate publication.
  # The Alerts channel may not have one yet: `Alerts.save_review/5` records the
  # intent in `alert_publications` and only dirties an existing channel, so the
  # first accepted alert claims its channel row here from that durable intent.
  defp ensure_channels(organization_id, namespace) do
    existing = Repo.all(from p in Publication, where: p.organization_id == ^organization_id)

    if Enum.any?(existing, &(&1.channel == :alerts)) or
         not accepted_alert_intent?(organization_id) do
      existing
    else
      %Publication{organization_id: organization_id, namespace_id: namespace.id, channel: :alerts}
      |> Ecto.Changeset.change()
      |> Repo.insert(on_conflict: :nothing)

      Repo.all(from p in Publication, where: p.organization_id == ^organization_id)
    end
  end

  defp accepted_alert_intent?(organization_id) do
    Repo.exists?(
      from p in AlertPublication,
        where:
          p.organization_id == ^organization_id and p.withdrawal == :none and
            not is_nil(p.desired_snapshot)
    )
  end

  defp active_attempt?(%Publication{active_attempt_id: nil}), do: false

  defp active_attempt?(%Publication{active_attempt_id: id}) do
    case Repo.get(Attempt, id) do
      %Attempt{state: state} -> state in ["pending", "switching"]
      nil -> false
    end
  end

  defp active_attempt(%Publication{active_attempt_id: nil}), do: nil
  defp active_attempt(%Publication{active_attempt_id: id}), do: Repo.get(Attempt, id)

  # Realtime: resume the exact frozen intent first and only compose the next
  # generation once it is resolved, so a sending attempt is never left behind a
  # newer one. The resolved attempt is retired when the newer manifest is
  # confirmed, which is the fence a later collection step waits behind.
  defp service_alerts(config, publication, now) do
    case active_attempt(publication) do
      %Attempt{state: state} when state in ["pending", "switching"] ->
        _ = FeedPublishing.advance(publication.id)
        :ok

      _ ->
        compose_and_install(config, publication, now)
    end
  end

  defp compose_and_install(config, publication, now) do
    namespace = Repo.get!(Namespace, publication.namespace_id)

    with {:ok, publication} <- reconcile(config, publication, namespace),
         {:ok, composition} <- compose_alerts(publication, namespace, now),
         {:ok, previous_id} <- queue_attempt(publication, namespace, composition) do
      case FeedPublishing.advance(publication.id) do
        {:ok, :current} -> retire(previous_id)
        _other -> :ok
      end

      :ok
    else
      _skip -> :ok
    end
  end

  # The remote manifest is the truth about what is served. Adopt it before
  # composing new work so the next attempt conditions on the ETag that is
  # actually current; a manifest that disappeared clears a stale local receipt
  # so the next attempt is a first creation again. An unavailable provider
  # defers the whole channel rather than generating work against an unknown.
  defp reconcile(config, publication, namespace) do
    case Storage.read_manifest(config, Manifest.key(namespace.prefix, publication.channel)) do
      :missing ->
        {:ok, clear_receipt(publication)}

      {:ok, body, etag, last_modified} ->
        if body == publication.manifest_bytes do
          {:ok, publication}
        else
          {:ok, adopt_receipt(publication, body, etag, last_modified)}
        end

      {:error, _reason} ->
        :skip
    end
  end

  defp clear_receipt(%Publication{manifest_bytes: nil} = publication), do: publication

  defp clear_receipt(publication) do
    publication
    |> Ecto.Changeset.change(%{
      manifest_bytes: nil,
      manifest_sha256: nil,
      manifest_etag: nil,
      manifest_generation: nil,
      manifest_sequence: nil,
      manifest_last_modified: nil,
      status: :pending
    })
    |> Repo.update!()
  end

  defp adopt_receipt(publication, body, etag, last_modified) do
    decoded =
      case Jason.decode(body) do
        {:ok, map} -> map
        _ -> %{}
      end

    sequence = decoded["sequence"]

    publication
    |> Ecto.Changeset.change(%{
      manifest_bytes: body,
      manifest_sha256: sha256_hex(body),
      manifest_etag: etag,
      manifest_generation: decoded["generation"],
      manifest_sequence: if(is_integer(sequence), do: sequence, else: nil),
      manifest_last_modified: parse_http_date(last_modified),
      status: :pending
    })
    |> Repo.update!()
  end

  # Compose the whole organization feed from the accepted snapshots at `now`.
  # A pending withdrawal is left out, so a removed alert cannot be resurrected
  # by a later tick; `Alerts.Feed.encode/2` owns notice and expiry eligibility.
  defp compose_alerts(publication, namespace, now) do
    case AlertsFeed.encode(accepted_snapshots(publication.organization_id), DateTime.to_unix(now)) do
      {:ok, %{pb: pb, json: json, included: included}} ->
        generation = Ecto.UUID.generate()
        base = "#{namespace.prefix}/realtime/objects/#{generation}"

        objects = %{
          "pb" => descriptor("#{base}/alerts.pb", pb, "application/x-protobuf"),
          "json" => descriptor("#{base}/alerts.json", json, "application/json")
        }

        private = %{
          "generation" => generation,
          "objects" => %{
            "pb" => %{"bytes_base64" => Base.encode64(pb)},
            "json" => %{"bytes_base64" => Base.encode64(json)}
          }
        }

        {:ok, %{generation: generation, objects: objects, private: private, included: included}}

      {:error, _reason} ->
        :skip
    end
  end

  defp accepted_snapshots(organization_id) do
    from(p in AlertPublication,
      where: p.organization_id == ^organization_id,
      where: p.withdrawal == :none,
      where: not is_nil(p.desired_snapshot),
      select: p.desired_snapshot
    )
    |> Repo.all()
    |> Enum.map(&AlertPublication.snapshot_from_stored/1)
  end

  defp descriptor(key, bytes, content_type) do
    %{
      "key" => key,
      "sha256" => sha256_hex(bytes),
      "bytes" => byte_size(bytes),
      "content_type" => content_type
    }
  end

  defp queue_attempt(publication, namespace, composition) do
    case Repo.transaction(fn -> queue_locked(publication.id, namespace, composition) end) do
      {:ok, previous_id} -> {:ok, previous_id}
      {:error, _reason} -> :skip
    end
  end

  defp queue_locked(publication_id, namespace, composition) do
    current = Repo.one!(from p in Publication, where: p.id == ^publication_id, lock: "FOR UPDATE")

    if blocking_attempt?(current) do
      Repo.rollback(:busy)
    else
      insert_refresh_attempt(current, namespace, composition)
    end
  end

  defp blocking_attempt?(%Publication{active_attempt_id: nil}), do: false

  defp blocking_attempt?(%Publication{active_attempt_id: id}) do
    case Repo.get(Attempt, id) do
      %Attempt{state: state} -> state in ["pending", "switching"]
      nil -> false
    end
  end

  defp insert_refresh_attempt(publication, namespace, composition) do
    sequence = publication.next_sequence

    attempt = %Attempt{
      publication_id: publication.id,
      organization_id: publication.organization_id,
      sequence: sequence,
      generation: composition.generation,
      desired_revision: publication.desired_revision,
      predecessor_etag: publication.manifest_etag,
      object_receipts: composition.objects,
      private_snapshot: composition.private,
      included_revisions: composition.included,
      state: "pending"
    }

    case Manifest.encode(%{attempt | publication: %{publication | namespace: namespace}}) do
      {:ok, body} ->
        attempt =
          Repo.insert!(%{attempt | manifest_body: body, manifest_sha256: sha256_hex(body)})

        publication
        |> Ecto.Changeset.change(%{
          next_sequence: sequence + 1,
          active_attempt_id: attempt.id,
          status: :pending,
          next_retry_at: nil,
          last_error: nil
        })
        |> Repo.update!()

        publication.active_attempt_id

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  # A resolved attempt whose manifest a newer verified generation replaced is
  # safe to retire: no predecessor-conditional request of its own can still win.
  defp retire(nil), do: :ok

  defp retire(attempt_id) do
    now = DateTime.utc_now()

    Repo.update_all(
      from(a in Attempt, where: a.id == ^attempt_id and a.state == "current"),
      set: [state: "superseded", retired_at: now, lease_token: nil, lease_expires_at: nil]
    )

    :ok
  end

  # Static: a long upload runs in its own bounded pool, so it never occupies the
  # realtime slot and a pool at capacity simply defers the item to the next tick.
  defp dispatch_static(_config, publication) do
    case Process.whereis(@static_tasks) do
      nil ->
        run_static(publication)
        []

      _name ->
        case RunnerAdmission.start_child(@static_tasks, {Task, fn -> run_static(publication) end}) do
          {:ok, pid} -> [pid]
          _refused -> []
        end
    end
  end

  defp run_static(publication) do
    _ = FeedPublishing.advance(publication.id)
    :ok
  end

  defp static_capacity do
    Application.get_env(:gtfs_planner, :feed_publishing_static_capacity, @static_capacity)
  end

  defp realtime_capacity do
    Application.get_env(:gtfs_planner, :feed_publishing_realtime_capacity, @realtime_capacity)
  end

  # -- Retired payload collection -------------------------------------------

  defp collect_publications(config, now, limit) do
    publications = Repo.all(from p in Publication, preload: [:namespace])

    Enum.reduce(publications, 0, fn publication, collected ->
      if collected >= limit do
        collected
      else
        collected + collect_publication(config, publication, now, limit - collected)
      end
    end)
  end

  # Only a confirmed current manifest permits collection: without a strong read
  # of what is served, an object that a consumer may still be reading could be
  # removed. An unavailable provider leaves every byte and record in place.
  defp collect_publication(config, publication, now, budget) do
    namespace = publication.namespace

    case Storage.read_manifest(config, Manifest.key(namespace.prefix, publication.channel)) do
      {:ok, body, _etag, _last_modified} ->
        protected = protected_keys(publication, body)

        {deleted, remaining} =
          collect_retired_attempts(config, publication, protected, now, budget)

        publication = advance_watermark(publication)

        deleted +
          collect_orphans(config, publication, namespace, protected, now, remaining)

      _unconfirmed ->
        0
    end
  end

  defp protected_keys(publication, manifest_body) do
    MapSet.union(manifest_object_keys(manifest_body), unresolved_keys(publication))
  end

  defp manifest_object_keys(body) do
    case Jason.decode(body) do
      {:ok, %{"objects" => objects}} when is_map(objects) ->
        objects
        |> Map.values()
        |> Enum.flat_map(fn
          %{"key" => key} when is_binary(key) -> [key]
          _other -> []
        end)
        |> MapSet.new()

      _other ->
        MapSet.new()
    end
  end

  defp unresolved_keys(publication) do
    from(a in Attempt,
      where: a.publication_id == ^publication.id and a.state in ["pending", "switching"]
    )
    |> Repo.all()
    |> Enum.flat_map(&Attempt.object_keys/1)
    |> MapSet.new()
  end

  defp collect_retired_attempts(config, publication, protected, now, budget) do
    attempts =
      from(a in Attempt,
        where: a.publication_id == ^publication.id and a.state == "superseded",
        where: not is_nil(a.retired_at),
        order_by: [asc: a.sequence],
        limit: ^budget
      )
      |> Repo.all()
      |> Enum.filter(&grace_passed_retirement?(&1, now))

    Enum.reduce_while(attempts, {0, budget}, fn attempt, acc ->
      collect_retired_attempt(config, attempt, protected, acc)
    end)
  end

  defp collect_retired_attempt(config, attempt, protected, {deleted, remaining}) do
    keys = Attempt.object_keys(attempt)

    cond do
      remaining <= 0 ->
        {:halt, {deleted, remaining}}

      Enum.any?(keys, &MapSet.member?(protected, &1)) ->
        {:cont, {deleted, remaining}}

      true ->
        delete_retired_attempt(config, attempt, keys, deleted, remaining)
    end
  end

  defp delete_retired_attempt(config, attempt, keys, deleted, remaining) do
    case delete_keys(config, keys) do
      :ok ->
        prune_attempt(attempt)
        {:cont, {deleted + length(keys), remaining - length(keys)}}

      {:error, _reason} ->
        {:halt, {deleted, remaining}}
    end
  end

  defp delete_keys(config, keys) do
    Enum.reduce_while(keys, :ok, fn key, :ok ->
      case Storage.delete_payload(config, key) do
        {:ok, :deleted} -> {:cont, :ok}
        {:error, :refused} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp prune_attempt(attempt) do
    Repo.delete_all(from a in Attempt, where: a.id == ^attempt.id and a.state == "superseded")

    :ok
  end

  defp grace_passed_retirement?(%Attempt{retired_at: %DateTime{} = retired_at}, now) do
    DateTime.diff(now, retired_at, :second) >= @retirement_grace_seconds
  end

  defp grace_passed_retirement?(_attempt, _now), do: false

  # The watermark may advance only across a contiguous run of individually
  # fenced attempts: the next sequence still has a row (current, unresolved or
  # not yet retired), so its proof is not compacted away. Every allocated
  # sequence below `next_sequence` is bounded, so the scan terminates.
  defp advance_watermark(publication) do
    max_sequence = publication.next_sequence - 1

    if publication.retired_through_sequence >= max_sequence do
      publication
    else
      watermark =
        contiguous_watermark(
          publication.id,
          publication.retired_through_sequence + 1,
          max_sequence
        )

      if watermark > publication.retired_through_sequence do
        publication
        |> Ecto.Changeset.change(retired_through_sequence: watermark)
        |> Repo.update!()
      else
        publication
      end
    end
  end

  defp contiguous_watermark(_publication_id, sequence, max_sequence)
       when sequence > max_sequence,
       do: max_sequence

  defp contiguous_watermark(publication_id, sequence, max_sequence) do
    if Repo.exists?(
         from a in Attempt,
           where: a.publication_id == ^publication_id and a.sequence == ^sequence
       ) do
      sequence - 1
    else
      contiguous_watermark(publication_id, sequence + 1, max_sequence)
    end
  end

  # One bounded listing of the owned payload prefix per call. An orphan is only
  # collected when its key is under this namespace/channel's objects folder, its
  # server-owned identity metadata matches, its sequence is covered by the
  # compact watermark, and its remote observation instant is past the grace.
  # Missing or conflicting metadata is left alone; a different prefix is never
  # listed, so another namespace and website assets are untouched.
  defp collect_orphans(config, publication, namespace, protected, now, budget) do
    if budget <= 0 do
      0
    else
      prefix = objects_prefix(namespace.prefix, publication.channel)

      case Storage.list_payloads(
             config,
             prefix,
             publication.cleanup_cursor,
             min(budget, @collection_list_limit)
           ) do
        {:ok, entries, cursor} ->
          publication =
            publication
            |> Ecto.Changeset.change(cleanup_cursor: cursor)
            |> Repo.update!()

          sweep_orphans(config, publication, namespace, protected, now, entries, budget)

        {:error, _reason} ->
          0
      end
    end
  end

  defp sweep_orphans(config, publication, namespace, protected, now, entries, budget) do
    {deleted, _remaining} =
      Enum.reduce_while(entries, {0, budget}, fn entry, acc ->
        sweep_orphan(config, publication, namespace, protected, entry, now, acc)
      end)

    deleted
  end

  defp sweep_orphan(config, publication, namespace, protected, entry, now, {deleted, remaining}) do
    cond do
      remaining <= 0 ->
        {:halt, {deleted, remaining}}

      MapSet.member?(protected, entry.key) ->
        {:cont, {deleted, remaining}}

      orphan_eligible?(config, publication, namespace, entry, now) ->
        delete_orphan(config, entry, deleted, remaining)

      true ->
        {:cont, {deleted, remaining}}
    end
  end

  defp delete_orphan(config, entry, deleted, remaining) do
    case Storage.delete_payload(config, entry.key) do
      {:ok, :deleted} -> {:cont, {deleted + 1, remaining - 1}}
      {:error, :refused} -> {:cont, {deleted, remaining}}
      {:error, _reason} -> {:halt, {deleted, remaining}}
    end
  end

  defp orphan_eligible?(config, publication, namespace, entry, now) do
    with true <-
           String.starts_with?(entry.key, objects_prefix(namespace.prefix, publication.channel)),
         {:ok, head} <- Storage.head_payload(config, entry.key),
         %{claim: claim, channel: channel, sequence: sequence} <- head.identity,
         true <- claim == namespace.public_claim,
         true <- channel == Atom.to_string(publication.channel),
         true <- is_integer(sequence) and sequence <= publication.retired_through_sequence,
         true <- grace_passed_object?(head.last_modified, now) do
      true
    else
      _other -> false
    end
  end

  defp grace_passed_object?(%DateTime{} = observed_at, now) do
    DateTime.diff(now, observed_at, :second) >= @retirement_grace_seconds
  end

  defp grace_passed_object?(_observed_at, _now), do: false

  defp objects_prefix(prefix, :alerts), do: "#{prefix}/realtime/objects/"
  defp objects_prefix(prefix, _channel), do: "#{prefix}/static/objects/"

  # -- Claiming -------------------------------------------------------------

  defp claim(publication, attempt) do
    case Repo.transaction(fn -> claim_locked(publication.id, attempt.id) end) do
      {:ok, outcome} -> outcome
      {:error, reason} -> {:error, reason}
    end
  end

  defp claim_locked(publication_id, attempt_id) do
    publication =
      Repo.one!(from p in Publication, where: p.id == ^publication_id, lock: "FOR UPDATE")

    attempt =
      Repo.one!(
        from a in Attempt,
          where: a.id == ^attempt_id,
          lock: "FOR UPDATE",
          preload: [publication: :namespace]
      )

    cond do
      attempt.state == "blocked" ->
        {:done, {:error, :blocked}}

      attempt.state == "superseded" ->
        {:done, {:ok, :superseded}}

      attempt.state == "current" and attempt.desired_revision == publication.desired_revision ->
        {:done, {:ok, :current}}

      attempt.desired_revision != publication.desired_revision ->
        {:stale, attempt}

      lease_live?(attempt) ->
        :busy

      true ->
        {:claimed, claim_lease(attempt),
         if(attempt.state == "switching", do: :retry, else: :fresh)}
    end
  end

  defp claim_lease(attempt) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

    Repo.update!(
      Ecto.Changeset.change(attempt, %{
        lease_token: token,
        lease_expires_at: DateTime.add(DateTime.utc_now(), @lease_seconds),
        state: "switching"
      })
    )
  end

  defp lease_live?(%Attempt{lease_token: token, lease_expires_at: %DateTime{} = expires})
       when is_binary(token) do
    DateTime.compare(expires, DateTime.utc_now()) == :gt
  end

  defp lease_live?(_attempt), do: false

  # -- Driving the attempt --------------------------------------------------

  defp run(config, attempt, :fresh), do: write_manifest(config, attempt)

  defp run(config, attempt, :retry) do
    case reconcile(config, attempt) do
      :install -> write_manifest(config, attempt)
      {:current, etag, last_modified} -> complete(attempt, etag, last_modified)
      :superseded -> supersede(attempt, attempt.lease_token)
      :blocked -> block(attempt, "the current manifest belongs to another owner")
      :pending -> mark_pending(attempt, nil)
    end
  end

  # Stage the payloads first; the manifest never switches while any object is
  # unconfirmed. Then replace the single manifest with the frozen condition.
  defp write_manifest(config, attempt) do
    case stage_payloads(config, attempt) do
      :ok -> switch_manifest(config, attempt)
      {:pending, reason} -> mark_pending(attempt, reason)
      {:error, reason} -> block(attempt, describe(reason))
    end
  end

  defp switch_manifest(config, attempt) do
    case Storage.put_manifest(
           config,
           manifest_key(attempt),
           attempt.manifest_body,
           condition(attempt)
         ) do
      {:ok, receipt} ->
        complete(attempt, receipt.etag, receipt.last_modified)

      {:error, :precondition_failed} ->
        after_uncertain(config, attempt)

      {:error, :unknown} ->
        after_uncertain(config, attempt)

      {:error, reason} ->
        mark_pending(attempt, describe(reason))
    end
  end

  # A lost condition or a timeout means the outcome is unknown, not a failure.
  # Read the manifest back and settle on what is actually served. The frozen
  # predecessor is never replaced with the freshly read ETag.
  defp after_uncertain(config, attempt) do
    case reconcile(config, attempt) do
      :install -> mark_pending(attempt, "the manifest write outcome is unconfirmed")
      {:current, etag, last_modified} -> complete(attempt, etag, last_modified)
      :superseded -> supersede(attempt, attempt.lease_token)
      :blocked -> block(attempt, "the current manifest belongs to another owner")
      :pending -> mark_pending(attempt, nil)
    end
  end

  defp reconcile(config, attempt) do
    case Storage.read_manifest(config, manifest_key(attempt)) do
      :missing ->
        if condition(attempt) == :absent, do: :install, else: :blocked

      {:ok, body, etag, last_modified} ->
        cond do
          body == attempt.manifest_body -> {:current, etag, last_modified}
          predecessor?(attempt, etag) -> :install
          owned_newer?(attempt, body) -> :superseded
          true -> :blocked
        end

      {:error, _reason} ->
        :pending
    end
  end

  defp predecessor?(%Attempt{predecessor_etag: etag}, etag) when is_binary(etag), do: true
  defp predecessor?(_attempt, _etag), do: false

  defp owned_newer?(attempt, body) do
    case Jason.decode(body) do
      {:ok, decoded} -> newer_owned?(decoded, attempt)
      _ -> false
    end
  end

  defp newer_owned?(
         %{
           "schema" => 1,
           "namespace" => prefix,
           "claim" => claim,
           "channel" => channel,
           "sequence" => sequence
         },
         attempt
       )
       when is_integer(sequence) do
    namespace = attempt.publication.namespace
    publication = attempt.publication

    prefix == namespace.prefix and claim == namespace.public_claim and
      channel == Atom.to_string(publication.channel) and sequence > attempt.sequence
  end

  defp newer_owned?(_decoded, _attempt), do: false

  # -- Payload staging ------------------------------------------------------

  defp stage_payloads(config, attempt) do
    Enum.reduce_while(attempt.object_receipts, :ok, fn {role, descriptor}, :ok ->
      case stage_payload(config, attempt, role, descriptor) do
        :ok -> {:cont, :ok}
        other -> {:halt, other}
      end
    end)
  end

  defp stage_payload(config, attempt, role, descriptor) do
    case object_source(attempt, role, descriptor) do
      {:ok, source} ->
        case Storage.put_payload(
               config,
               descriptor["key"],
               source,
               descriptor["sha256"],
               identity(attempt)
             ) do
          {:ok, _receipt} -> :ok
          {:error, :unknown} -> {:pending, "payload #{role} outcome is unknown"}
          {:error, :unavailable} -> {:pending, "the payload store is unavailable"}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The payload bytes are frozen on the attempt as base64 (realtime) or as a
  # private staging file (a static artifact). Bytes are re-hashed against the
  # frozen descriptor so a retry can only ever upload the same bytes.
  defp object_source(attempt, role, descriptor) do
    source = get_in(attempt.private_snapshot || %{}, ["objects", role]) || %{}

    cond do
      is_binary(source["file"]) -> file_source(source["file"], descriptor)
      is_binary(source["bytes_base64"]) -> bytes_source(source["bytes_base64"], descriptor)
      true -> {:error, :incomplete}
    end
  end

  defp file_source(path, descriptor) do
    size = descriptor["bytes"]

    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: ^size}} ->
        {:ok, {:file, path}}

      _ ->
        {:error, :incomplete}
    end
  end

  defp bytes_source(base64, descriptor) do
    with {:ok, bytes} <- Base.decode64(base64),
         true <- byte_size(bytes) == descriptor["bytes"],
         true <- sha256_hex(bytes) == descriptor["sha256"] do
      {:ok, {:bytes, bytes}}
    else
      _ -> {:error, :inconsistent}
    end
  end

  # -- Terminal transitions -------------------------------------------------

  defp complete(attempt, etag, last_modified) do
    token = attempt.lease_token

    case Repo.transaction(fn -> complete_locked(attempt.id, token, etag, last_modified) end) do
      {:ok, result} -> {:ok, result}
      {:error, :fenced} -> {:ok, :pending}
    end
  end

  defp complete_locked(attempt_id, token, etag, last_modified) do
    locked =
      Repo.one(
        from a in Attempt,
          where: a.id == ^attempt_id and a.lease_token == ^token,
          lock: "FOR UPDATE"
      )

    if locked == nil do
      Repo.rollback(:fenced)
    else
      publication =
        Repo.one!(
          from p in Publication, where: p.id == ^locked.publication_id, lock: "FOR UPDATE"
        )

      finish(locked, publication, etag, last_modified)
    end
  end

  defp finish(attempt, publication, etag, last_modified) do
    now = DateTime.utc_now()

    served = %{
      manifest_bytes: attempt.manifest_body,
      manifest_sha256: attempt.manifest_sha256,
      manifest_etag: etag,
      manifest_generation: attempt.generation,
      manifest_sequence: attempt.sequence,
      manifest_last_modified: parse_http_date(last_modified),
      last_refresh_at: now
    }

    if attempt.desired_revision == publication.desired_revision do
      publication
      |> Ecto.Changeset.change(
        Map.merge(served, %{
          status: :current,
          next_retry_at: nil,
          last_error: nil,
          active_attempt_id: attempt.id
        })
      )
      |> Repo.update!()

      attempt
      |> Ecto.Changeset.change(%{
        state: "current",
        retired_at: nil,
        lease_token: nil,
        lease_expires_at: nil
      })
      |> Repo.update!()

      :current
    else
      publication
      |> Ecto.Changeset.change(
        Map.merge(served, %{
          status: :pending,
          next_retry_at: DateTime.add(now, @retry_seconds),
          last_error: "newer accepted content is pending",
          active_attempt_id: nil
        })
      )
      |> Repo.update!()

      attempt
      |> Ecto.Changeset.change(%{
        state: "superseded",
        retired_at: now,
        lease_token: nil,
        lease_expires_at: nil
      })
      |> Repo.update!()

      :superseded
    end
  end

  # A stale attempt (its desired revision moved on) is retired. If it had
  # possibly sent, its served receipt is recorded first so the channel's
  # truth never regresses to an older manifest than the one actually served.
  defp stale(config, attempt) do
    if attempt.state == "switching" do
      case reconcile(config, attempt) do
        {:current, etag, last_modified} -> serve_then_supersede(attempt, etag, last_modified)
        _ -> supersede(attempt, nil)
      end
    else
      supersede(attempt, nil)
    end
  end

  defp serve_then_supersede(attempt, etag, last_modified) do
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      Repo.update_all(
        from(a in Attempt, where: a.id == ^attempt.id),
        set: [state: "superseded", retired_at: now, lease_token: nil, lease_expires_at: nil]
      )

      Repo.update_all(
        from(p in Publication, where: p.id == ^attempt.publication_id),
        set: [
          manifest_bytes: attempt.manifest_body,
          manifest_sha256: attempt.manifest_sha256,
          manifest_etag: etag,
          manifest_generation: attempt.generation,
          manifest_sequence: attempt.sequence,
          manifest_last_modified: parse_http_date(last_modified),
          last_refresh_at: now,
          status: :pending,
          active_attempt_id: nil,
          next_retry_at: DateTime.add(now, @retry_seconds),
          last_error: "newer accepted content is pending"
        ]
      )

      :superseded
    end)

    {:ok, :superseded}
  end

  defp supersede(attempt, token) do
    case Repo.transaction(fn -> supersede_locked(attempt.id, attempt.publication_id, token) end) do
      {:ok, :superseded} -> {:ok, :superseded}
      {:error, :fenced} -> {:ok, :pending}
    end
  end

  defp supersede_locked(attempt_id, publication_id, token) do
    now = DateTime.utc_now()

    {count, _} =
      if is_binary(token) do
        Repo.update_all(
          from(a in Attempt, where: a.id == ^attempt_id and a.lease_token == ^token),
          set: [state: "superseded", retired_at: now, lease_token: nil, lease_expires_at: nil]
        )
      else
        Repo.update_all(
          from(a in Attempt, where: a.id == ^attempt_id),
          set: [state: "superseded", retired_at: now, lease_token: nil, lease_expires_at: nil]
        )
      end

    if is_binary(token) and count == 0 do
      Repo.rollback(:fenced)
    else
      Repo.update_all(
        from(p in Publication,
          where: p.id == ^publication_id and p.active_attempt_id == ^attempt_id
        ),
        set: [
          active_attempt_id: nil,
          status: :pending,
          next_retry_at: DateTime.add(now, @retry_seconds),
          last_error: "newer accepted content is pending"
        ]
      )

      :superseded
    end
  end

  defp block(attempt, message) do
    Repo.transaction(fn ->
      Repo.update_all(
        from(a in Attempt, where: a.id == ^attempt.id and a.lease_token == ^attempt.lease_token),
        set: [state: "blocked", lease_token: nil, lease_expires_at: nil]
      )

      Repo.update_all(
        from(p in Publication, where: p.id == ^attempt.publication_id),
        set: [status: :blocked, last_error: message, next_retry_at: nil]
      )

      :blocked
    end)

    {:error, :blocked}
  end

  defp mark_pending(attempt, reason) do
    now = DateTime.utc_now()
    message = reason || "storage is unavailable"

    Repo.transaction(fn ->
      Repo.update_all(
        from(p in Publication, where: p.id == ^attempt.publication_id),
        set: [
          status: :pending,
          next_retry_at: DateTime.add(now, @retry_seconds),
          last_error: message
        ]
      )

      Repo.update_all(
        from(a in Attempt, where: a.id == ^attempt.id and a.lease_token == ^attempt.lease_token),
        set: [state: "switching", lease_token: nil, lease_expires_at: nil]
      )

      :pending
    end)

    {:ok, :pending}
  end

  # -- Helpers --------------------------------------------------------------

  defp manifest_key(attempt) do
    Manifest.key(attempt.publication.namespace.prefix, attempt.publication.channel)
  end

  defp condition(%Attempt{predecessor_etag: etag}) when is_binary(etag) and etag != "",
    do: {:etag, etag}

  defp condition(_attempt), do: :absent

  defp identity(attempt) do
    %{
      claim: attempt.publication.namespace.public_claim,
      channel: Atom.to_string(attempt.publication.channel),
      sequence: attempt.sequence,
      generation: attempt.generation
    }
  end

  defp sha256_hex(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp parse_http_date(value) when is_binary(value) do
    case :httpd_util.convert_request_date(String.to_charlist(value)) do
      {{year, month, day}, {hour, minute, second}} ->
        date = Date.new!(year, month, day)
        time = Time.new!(hour, minute, second)

        case DateTime.new(date, time, "Etc/UTC") do
          {:ok, datetime} -> %{datetime | microsecond: {0, 6}}
          _ -> nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp parse_http_date(_value), do: nil

  defp describe(reason) when is_atom(reason), do: "storage reported #{reason}"
  defp describe(_reason), do: "storage reported an error"
end
