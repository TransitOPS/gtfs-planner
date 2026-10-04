defmodule GtfsPlanner.Gtfs.ReleaseComparison.Runner do
  @moduledoc """
  Temporary supervised coordinator that owns every download claim of one native
  comparison and finalizes it exactly once.

  The coordinator is a temporary child of the existing
  `GtfsPlanner.TaskSupervisor` (`restart: :temporary`), so a comparison is
  bounded work with its own process lifetime rather than a new supervised job
  kind. It owns the claims and nothing else: the compute child started under the
  same supervisor owns the bytes, and no cleanup ever depends on that child
  surviving.

  The sequence is deliberate and narrow:

    1. Step 1's `resolve_selection/2` resolves the two authorized source runs
       without reading anything.
    2. Each distinct run id, in sorted order, is claimed inside its own
       `Repo.transaction/1` that re-authorizes the scope and resolves both
       source versions *before* `ExportRuns.claim_download/4` takes the run's
       entity lock. Every successful claim is recorded in coordinator state
       immediately, including its `claim_id`.
    3. Only then is one monitored compute child started under
       `GtfsPlanner.TaskSupervisor` with a 128MiB heap ceiling, so a
       pathological artifact is killed rather than allowed to exhaust the node.
    4. Cancellation, a caller that went down, a crashed or heap-killed child, a
       reader refusal and the deadline all reach the same finalizer: the compute
       child is killed and awaited, every tracked receipt is released once
       through `ExportRuns.complete_download/4`, and only then is the tagged
       terminal message delivered.

  That ordering is the whole point. A killed child cannot release a claim, so
  the coordinator does; a partially acquired comparison releases the claims it
  already took before it reports the refusal; and a late result from an earlier
  attempt can never win, because the finalizer runs once and the process exits
  through it.

  The deadline is `min(45_000ms, earliest claim expiry - now - 5_000ms)`, and no
  claim is ever renewed. A claim that already has five seconds or less left
  refuses computation rather than starting work it cannot finish before its own
  receipt expires. Node or database loss still falls back to the existing finite
  60s claim expiry; nothing here promises recovery from that.

  Cancellation is cooperative and scoped: `cancel/2` only acts on a message from
  the owning pid with the matching request reference, and it never touches export
  cancellation, retry or any durable export run.
  """

  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs.ExportRuns
  alias GtfsPlanner.Gtfs.ReleaseComparison
  alias GtfsPlanner.Gtfs.ReleaseComparison.Compute
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions

  @default_deadline_ms 45_000
  @claim_margin_ms 5_000
  @max_heap_bytes 128 * 1024 * 1024
  # Bounded wait for the compute child to be gone after it is killed, so a
  # release never runs while the killed child could still be reading bytes.
  @stop_timeout_ms 5_000

  @typedoc "A claim exactly as `GtfsPlanner.Gtfs.ExportRuns.claim_download/4` returned it."
  @type claim :: %{required(:path) => String.t(), required(:claim_id) => DateTime.t()}

  @doc """
  Starts one comparison coordinator for `owner_pid` and returns its pid.

  Returns `{:error, :unavailable}` when the arguments cannot name a comparison
  at all - an unusable scope, non-map parameters or a caller that is not a
  live process. Every other refusal, including an invalid window, an
  unsupported profile, a refused claim and a deadline, is delivered to the owner
  as `{:release_comparison, request_ref, {:error, reason}}` once the coordinator
  is running.
  """
  @spec start(Scope.t(), map(), pid(), term()) :: {:ok, pid()} | {:error, :unavailable}
  def start(%Scope{} = scope, params, owner_pid, request_ref)
      when is_map(params) and is_pid(owner_pid) do
    if Process.alive?(owner_pid) do
      start_coordinator(%{
        scope: scope,
        params: params,
        owner_pid: owner_pid,
        owner_ref: nil,
        request_ref: request_ref,
        selection: nil,
        claims: %{},
        task: nil,
        timer: nil
      })
    else
      {:error, :unavailable}
    end
  end

  def start(_scope, _params, _owner_pid, _request_ref), do: {:error, :unavailable}

  defp start_coordinator(state) do
    case Task.Supervisor.start_child(
           GtfsPlanner.TaskSupervisor,
           fn -> run(state) end,
           restart: :temporary
         ) do
      {:ok, pid} -> {:ok, pid}
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  @doc """
  Asks `pid` to cancel the comparison identified by `request_ref`.

  The message is only acted on when it arrives from the owning pid with the
  matching request reference, so a stale or foreign cancellation is ignored.
  Returns `:ok` whether or not the coordinator is still running.
  """
  @spec cancel(pid(), term()) :: :ok
  def cancel(pid, request_ref) when is_pid(pid) do
    send(pid, {:release_comparison_cancel, self(), request_ref})
    :ok
  end

  def cancel(_pid, _request_ref), do: :ok

  @doc """
  The comparison's whole time budget in milliseconds for a set of claims.

  It is `min(45_000, earliest receipt expiry - 5_000)` and is never renewed, so a
  shorter configured receipt is respected rather than raced. A non-positive
  result means the coordinator must refuse computation instead of starting work
  its own receipts cannot cover.
  """
  @spec deadline_ms([claim()]) :: integer()
  def deadline_ms(claims) when is_list(claims) do
    Enum.min([
      @default_deadline_ms,
      claims |> Enum.map(&claim_margin/1) |> Enum.min()
    ])
  end

  # The owner is monitored here, in the coordinator: a monitor belongs to the
  # process that created it, so one taken in `start/4` would deliver the owner's
  # exit to the caller and never reach the `:DOWN` clauses below.
  @doc false
  def run(state) do
    state = %{state | owner_ref: Process.monitor(state.owner_pid)}
    await_start(acquire(state))
  end

  # -- acquisition ------------------------------------------------------------

  defp acquire(state) do
    case ReleaseComparison.resolve_selection(state.scope, state.params) do
      {:ok, selection} ->
        claim_each(%{state | selection: selection}, run_ids(selection))

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  # One run claimed once. Comparing an artifact with itself is one receipt and
  # one read, not two.
  defp run_ids(selection) do
    Enum.sort(Enum.uniq([selection.left.run_id, selection.right.run_id]))
  end

  defp claim_each(state, [run_id | rest]) do
    case claim(state, run_id) do
      {:ok, claim} ->
        claim_each(%{state | claims: Map.put(state.claims, run_id, claim)}, rest)

      {:error, reason} ->
        # Anything already claimed is released by the finalizer below, so a
        # refused second artifact never leaks the first one's claim.
        {:error, reason, state}
    end
  end

  defp claim_each(state, []), do: {:ok, state}

  # Authorization and both version identities are re-checked inside the same
  # transaction that takes the entity lock, so a membership withdrawn between
  # selection and claim refuses here rather than claiming.
  defp claim(state, run_id) do
    identity = identity(state.selection, run_id)

    outcome =
      Repo.transaction(fn ->
        with :ok <- Scope.authorized_context(state.scope),
             :ok <- versions_resolved(state.scope, state.selection) do
          ExportRuns.claim_download(
            state.scope.organization_id,
            identity.version_id,
            run_id,
            :main
          )
        else
          {:error, _reason} -> Repo.rollback(:refused)
        end
      end)

    case outcome do
      # The bytes the reader consumes come from this claim's verified path.
      {:ok, {:ok, claim}} -> {:ok, claim}
      {:ok, {:error, _refused}} -> {:error, :unavailable}
      # A membership or version that stopped resolving refuses exactly like an
      # absent selection, never as a database error.
      {:error, :refused} -> {:error, :unavailable}
    end
  end

  defp versions_resolved(scope, selection) do
    if Versions.get_gtfs_version_for_lifecycle(
         scope.organization_id,
         selection.left.version_id
       ) &&
         Versions.get_gtfs_version_for_lifecycle(
           scope.organization_id,
           selection.right.version_id
         ),
       do: :ok,
       else: {:error, :unavailable}
  end

  defp identity(selection, run_id) do
    cond do
      selection.left.run_id == run_id -> selection.left
      selection.right.run_id == run_id -> selection.right
    end
  end

  # -- computation ------------------------------------------------------------

  # A cancellation or a caller that has already gone down is answered before
  # any child exists, so cancelling a queued comparison performs zero compute
  # work and still releases whatever was claimed.
  defp await_start({:ok, state}) do
    receive do
      {:release_comparison_cancel, owner, request_ref} ->
        if owner == state.owner_pid and request_ref == state.request_ref do
          finish(state, {:error, :cancelled})
        else
          await_start({:ok, state})
        end

      {:DOWN, ref, :process, _pid, _reason} when ref == state.owner_ref ->
        finish(state, :silent)
    after
      0 -> start_compute(state)
    end
  end

  defp await_start({:error, reason, state}), do: finish(state, {:error, reason})

  defp start_compute(state) do
    case deadline_ms(Map.values(state.claims)) do
      milliseconds when milliseconds > 0 ->
        task = Task.Supervisor.async_nolink(GtfsPlanner.TaskSupervisor, fn -> compute(state) end)

        await_result(%{
          state
          | task: task,
            timer: Process.send_after(self(), :deadline, milliseconds)
        })

      _no_room ->
        finish(state, {:error, :timeout})
    end
  end

  defp compute(state) do
    # 128MiB expressed in system words, killed rather than reported, so a
    # pathological artifact cannot grow the node. The reader's compressed and
    # selected-byte caps already bound off-heap retention separately.
    Process.flag(
      :max_heap_size,
      %{
        size: div(@max_heap_bytes, :erlang.system_info(:wordsize)),
        kill: true,
        error_logger: false
      }
    )

    Compute.run(state.selection, state.claims)
  end

  defp await_result(state) do
    task_ref = state.task.ref

    receive do
      {^task_ref, {:ok, comparison}} ->
        finish(state, {:ok, comparison})

      {^task_ref, {:error, reason}} ->
        finish(state, {:error, reason})

      # A crash, a heap kill and an abrupt VM-level failure all arrive here.
      {:DOWN, ^task_ref, :process, _pid, _reason} ->
        finish(state, {:error, :worker_exit})

      {:DOWN, ref, :process, _pid, _reason} when ref == state.owner_ref ->
        finish(state, :silent)

      {:release_comparison_cancel, owner, request_ref} ->
        if owner == state.owner_pid and request_ref == state.request_ref do
          finish(state, {:error, :cancelled})
        else
          await_result(state)
        end

      :deadline ->
        finish(state, {:error, :timeout})
    end
  end

  defp claim_margin(%{claim_id: claim_id}) do
    DateTime.diff(claim_id, DateTime.utc_now(), :millisecond) - @claim_margin_ms
  end

  # -- finalization -----------------------------------------------------------

  defp finish(state, outcome) do
    :ok = stop_task(state)
    :ok = release_claims(state)
    deliver(state, outcome)
  end

  # The child is killed and awaited before any receipt is released, so no killed
  # reader can still be consuming bytes a released claim has given away.
  defp stop_task(%{task: nil} = _state), do: :ok

  defp stop_task(%{task: task} = state) do
    if is_reference(state.timer), do: Process.cancel_timer(state.timer)
    Process.demonitor(task.ref, [:flush])
    stop_pid(task.pid)
  end

  defp stop_pid(pid) do
    if Process.alive?(pid) do
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      after
        @stop_timeout_ms ->
          Process.demonitor(ref, [:flush])
          :ok
      end
    else
      :ok
    end
  end

  defp release_claims(state) do
    Enum.each(state.claims, fn {run_id, claim} ->
      identity = identity(state.selection, run_id)

      :ok =
        ExportRuns.complete_download(
          state.scope.organization_id,
          identity.version_id,
          run_id,
          claim.claim_id
        )
    end)

    :ok
  end

  defp deliver(_state, :silent), do: :ok

  defp deliver(state, {:error, reason}) do
    send(state.owner_pid, {:release_comparison, state.request_ref, {:error, reason}})
    :ok
  end

  # Authority is rechecked before the result is handed over: a membership
  # withdrawn while the comparison ran delivers the same opaque refusal as one
  # withdrawn before it started.
  defp deliver(state, {:ok, comparison}) do
    case Scope.authorized_context(state.scope) do
      :ok ->
        send(
          state.owner_pid,
          {:release_comparison, state.request_ref, {:ok, deliverable(state, comparison)}}
        )

      {:error, _reason} ->
        send(state.owner_pid, {:release_comparison, state.request_ref, {:error, :unavailable}})
    end
  end

  # The delivered result states which bytes it describes, so a caller can tell a
  # later comparison of the same runs from this one.
  defp deliverable(state, comparison) do
    selection = state.selection

    %{
      fingerprint: fingerprint(selection),
      window: %{from: selection.from, to: selection.to},
      left: selection.left,
      right: selection.right,
      comparison: comparison
    }
  end

  defp fingerprint(selection) do
    [
      {:left_run_id, selection.left.run_id},
      {:left_sha256, selection.left.sha256},
      {:right_run_id, selection.right.run_id},
      {:right_sha256, selection.right.sha256},
      {:from, selection.from},
      {:to, selection.to}
    ]
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
