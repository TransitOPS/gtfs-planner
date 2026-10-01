defmodule GtfsPlanner.Agents.Session do
  @moduledoc """
  One helper conversation, held only in this process (INV-6).

  The session owns the conversation: the ordered entries the panel renders, the
  model history, one authorized turn at a time in a monitored task, its
  listeners, and the conversation-bound proposals and application receipts. Every
  call re-reads the membership through `GtfsPlanner.Agents.Scope.authorize/1`, and
  a revoked membership makes the session discard a pending result, settle the
  entry as `:forbidden` and end the conversation (AC-12).

  A turn is bounded by code constants: at most 20 admitted requests per
  conversation, 2,000 characters per message, five minutes of wall time and 30
  minutes without activity. The eight-turn limit across conversations belongs to
  `GtfsPlanner.Agents.TurnSupervisor`; a send refused at that capacity changes
  nothing here (AC-30). Only tests may override the two timeouts.

  Stop, wall-clock timeout, a model failure and a task kill each settle the
  person's message exactly once with a synthetic terminal reply, and no partial
  assistant/tool sequence is kept (AC-27). The task boundary also sanitizes every
  exception: operators get one fixed `agent turn task crashed` diagnostic and the
  terminal `agent turn finished` line, and neither carries the person's text,
  tool arguments or exception text (AC-23, AC-33).

  ## Call protocol

  `GenServer.call/3`, also exposed as functions here:

    * `:attach` — authorize, monitor the caller once, reply `{:ok, snapshot()}`;
    * `:detach` — remove and demonitor the caller;
    * `{:send_message, text}` — admit one turn, reply `:ok` or an error;
    * `{:retry, conversation_id, entry_id}` — resend a failed entry's original text;
    * `:stop` — stop the running turn;
    * `:new_conversation` — clear the conversation and issue a new ID;
    * `{:prepared, conversation_id, entry_id}` — reply `{:ok, prepared} | :error`;
    * `{:record_applied, conversation_id, entry_id, command}` — record one receipt.

  Every listener receives `{:agent_event, session_pid, event}` where the event is
  `{:entry, entry}`, `{:status, status}` or `{:reset, conversation_id}`.

  A session also re-checks its own resource identity (`Scope.authorized_context/1`)
  and the pack's optional `authorize_context/1` at admission, on delivery and on a
  prepared lookup, so a deleted route or version ends the conversation the same way
  a revoked membership does, with the single `:unavailable` result (INV-1). That
  check covers the admitted source snapshot too: an oversized context or a forged
  snapshot digest is refused at the same boundary as a foreign resource, so no
  snapshot content outlives the admission that measured it. The
  server evidence a turn produced settles with its entry and is discarded with it,
  so an answer outlives neither an authorization change nor its turn (INV-2).
  """

  use GenServer, restart: :temporary

  require Logger

  alias GtfsPlanner.Agents.Pack
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Agents.Turn

  @turn_supervisor GtfsPlanner.Agents.TurnSupervisor

  # Bounds and terminal copy are code constants, not configuration (AC-16, AC-18, AC-30).
  @max_requests 20
  @max_message_length 2_000
  @turn_timeout_ms 300_000
  @idle_timeout_ms 1_800_000

  @stopped_text "Request stopped. No changes were saved."
  @incomplete_text "The helper couldn't finish this request. No changes were saved."
  @unavailable_text "The helper is unavailable right now. Try again, or make the change yourself on this page."
  @context_limit_text "This conversation is too large. Start a new conversation or narrow the request."
  @forbidden_text "Your access changed. The helper stopped."
  @allowance_exhausted_text "Daily assistant limit reached. It resets at 00:00 UTC."
  @unavailable_context_text "This route or calendar is no longer available, so the helper stopped."

  @typedoc "Session status the panel renders alongside the entries."
  @type status ::
          :idle | :working | :ended | :forbidden | :unavailable | :limit | :allowance_exhausted

  @typedoc "One visible turn in the transcript."
  @type entry :: %{
          id: pos_integer(),
          role: :user | :assistant,
          text: String.t(),
          activity: [String.t()],
          prepared: Pack.prepared() | nil,
          evidence: [Pack.evidence()],
          applied?: boolean(),
          status:
            :done
            | :working
            | :stopped
            | :failed
            | :incomplete
            | :forbidden
            | :unavailable
            | :allowance_exhausted
        }

  @typedoc "What `attach/1` returns and what `Agents.open/1` exposes."
  @type snapshot :: %{conversation_id: String.t(), entries: [entry()], status: status()}

  @doc """
  Starts a conversation session.

  Options are the server-held `:scope` and `:pack`, an optional `:name`, and the
  test-only `:turn_timeout_ms` and `:idle_timeout_ms` overrides.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, init_opts} = Keyword.pop(opts, :name)
    server_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, init_opts, server_opts)
  end

  @doc """
  Authorizes, monitors `pid` as a listener once and returns the conversation snapshot.
  """
  @spec attach(GenServer.server()) ::
          {:ok, snapshot()} | {:error, :forbidden | :unavailable | :ended}
  def attach(session), do: GenServer.call(session, :attach)

  @doc "Removes `pid` as a listener and flushes its monitor."
  @spec detach(GenServer.server()) :: :ok
  def detach(session), do: GenServer.call(session, :detach)

  @doc """
  Admits one turn for `text`.

  Returns `:ok` once the turn starts, or `{:error, reason}` for a forbidden
  member, an unavailable resource context, a running turn, blank or overlong
  text, the exhausted request allowance, or the shared eight-turn capacity.
  """
  @spec send_message(GenServer.server(), String.t()) ::
          :ok
          | {:error, :forbidden | :unavailable | :busy | :empty | :too_long | :limit | :capacity}
  def send_message(session, text), do: GenServer.call(session, {:send_message, text})

  @doc """
  Re-sends the original text of a failed entry in the current conversation.
  """
  @spec retry(GenServer.server(), String.t(), pos_integer()) :: :ok | {:error, atom()}
  def retry(session, conversation_id, entry_id) do
    GenServer.call(session, {:retry, conversation_id, entry_id})
  end

  @doc "Stops the running turn and settles it as stopped. A no-op when idle."
  @spec stop(GenServer.server()) :: :ok
  def stop(session), do: GenServer.call(session, :stop)

  @doc "Clears the conversation and issues a new conversation ID."
  @spec new_conversation(GenServer.server()) :: :ok | {:error, :busy | :forbidden}
  def new_conversation(session), do: GenServer.call(session, :new_conversation)

  @doc """
  Returns the proposal of `entry_id`, which must belong to the current conversation.

  A stale conversation, an entry without a proposal and a proposal already
  recorded as applied all return `:error` (INV-7).
  """
  @spec prepared(GenServer.server(), String.t(), pos_integer()) :: {:ok, Pack.prepared()} | :error
  def prepared(session, conversation_id, entry_id) do
    GenServer.call(session, {:prepared, conversation_id, entry_id})
  end

  @doc """
  Records that the exact prepared command was applied in this conversation.

  Any other origin or command returns an error and leaves every entry untouched.
  """
  @spec record_applied(GenServer.server(), String.t(), pos_integer(), term()) ::
          :ok | {:error, :stale_origin | :command_changed}
  def record_applied(session, conversation_id, entry_id, actual_command) do
    GenServer.call(session, {:record_applied, conversation_id, entry_id, actual_command})
  end

  @impl true
  def init(opts) do
    # A supervisor shutdown otherwise kills this process before `terminate/2`
    # runs, leaving its turn task alive in `Agents.TurnSupervisor`; trapping
    # exits is what makes the session's death release its capacity (AC-30).
    Process.flag(:trap_exit, true)

    state = %{
      scope: Keyword.fetch!(opts, :scope),
      pack: Keyword.fetch!(opts, :pack),
      conversation_id: Ecto.UUID.generate(),
      next_id: 1,
      entries: [],
      messages: [],
      requests: 0,
      listeners: %{},
      status: :idle,
      idle_timer: nil,
      idle_token: nil,
      retry_sources: %{},
      turn: nil,
      turn_timeout_ms: Keyword.get(opts, :turn_timeout_ms, @turn_timeout_ms),
      idle_timeout_ms: Keyword.get(opts, :idle_timeout_ms, @idle_timeout_ms)
    }

    {:ok, arm_idle(state)}
  end

  @impl true
  def handle_call(:attach, {pid, _tag}, state) do
    authorized(state, fn state ->
      state = state |> put_listener(pid) |> touch()
      {:reply, {:ok, snapshot(state)}, state}
    end)
  end

  def handle_call(:detach, {pid, _tag}, state) do
    {:reply, :ok, remove_listener(state, pid)}
  end

  def handle_call({:send_message, text}, _from, state) do
    authorized(state, &start_turn(&1, text))
  end

  def handle_call({:retry, conversation_id, entry_id}, _from, state) do
    authorized(state, fn state ->
      case retry_text(state, conversation_id, entry_id) do
        {:ok, text} -> start_turn(state, text)
        {:error, :stale_origin} -> {:reply, {:error, :stale_origin}, touch(state)}
      end
    end)
  end

  def handle_call(:stop, _from, state) do
    case state.turn do
      nil -> {:reply, :ok, touch(state)}
      _turn -> {:reply, :ok, stop_turn(state)}
    end
  end

  def handle_call(:new_conversation, _from, state) do
    authorized(state, fn state ->
      if state.turn do
        {:reply, {:error, :busy}, touch(state)}
      else
        {:reply, :ok, reset_conversation(state)}
      end
    end)
  end

  def handle_call({:prepared, conversation_id, entry_id}, _from, state) do
    authorized(state, fn state ->
      case proposal(state, conversation_id, entry_id) do
        {:ok, prepared} -> {:reply, {:ok, prepared}, touch(state)}
        :error -> {:reply, :error, touch(state)}
      end
    end)
  end

  def handle_call({:record_applied, conversation_id, entry_id, actual_command}, _from, state) do
    case record_receipt(state, conversation_id, entry_id, actual_command) do
      {:ok, state} -> {:reply, :ok, touch(state)}
      {:error, reason} -> {:reply, {:error, reason}, touch(state)}
    end
  end

  @impl true
  def handle_info({task_ref, value}, %{turn: %{task_ref: task_ref}} = state) do
    case settle_task_result(state, value) do
      {:cont, state} -> {:noreply, state}
      {:stop, state} -> {:stop, :normal, state}
    end
  end

  def handle_info({task_ref, _value}, state) when is_reference(task_ref), do: {:noreply, state}

  def handle_info({:turn_event, turn_id, event}, %{turn: %{turn_id: turn_id}} = state) do
    {:noreply, accumulate(state, event)}
  end

  def handle_info({:turn_event, _turn_id, _event}, state), do: {:noreply, state}

  def handle_info({:turn_timeout, turn_id}, %{turn: %{turn_id: turn_id}} = state) do
    {:noreply, timeout_turn(state)}
  end

  def handle_info({:turn_timeout, _turn_id}, state), do: {:noreply, state}

  def handle_info({:idle_timeout, token}, %{idle_token: token} = state) do
    {:stop, :normal, broadcast(state, {:status, :ended})}
  end

  def handle_info({:idle_timeout, _token}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    cond do
      state.turn && state.turn.task_ref == ref ->
        {:noreply, down_turn(state)}

      Map.get(state.listeners, pid) == ref ->
        {:noreply, %{state | listeners: Map.delete(state.listeners, pid)}}

      true ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # A session's death also ends its owned turn; dropping a listener never does.
    if state.turn, do: Task.Supervisor.terminate_child(@turn_supervisor, state.turn.task_pid)
    :ok
  end

  ## Admission

  # Membership, then the server-owned resource context, then the pack's own
  # precondition: all three are re-read here, on delivery and on a prepared
  # lookup, so no provider request, tool read or proposal outlives the page that
  # owns this conversation (INV-1).
  defp authorized(state, fun) do
    case check_context(state) do
      :ok -> fun.(state)
      {:error, :forbidden} -> revoke(state)
      {:error, :unavailable} -> stop_unavailable(state)
    end
  end

  defp check_context(state) do
    with :ok <- Scope.authorized_context(state.scope) do
      Pack.authorize_context(state.pack, state.scope)
    end
  end

  defp start_turn(state, text) do
    case admission(state, text) do
      {:error, reason} -> {:reply, {:error, reason}, touch(state)}
      :ok -> launch(state, text, make_ref())
    end
  end

  # The order is the card's: forbidden first (above), then a running turn, blank
  # text, an overlong message and the 20-request allowance.
  defp admission(state, text) do
    cond do
      state.turn -> {:error, :busy}
      String.trim(text) == "" -> {:error, :empty}
      String.length(text) > @max_message_length -> {:error, :too_long}
      state.requests >= @max_requests -> {:error, :limit}
      true -> :ok
    end
  end

  # The task starts before any transcript or count changes, so the supervisor's
  # documented capacity refusal leaves the message, entries and allowance intact.
  defp launch(state, text, turn_id) do
    session = self()
    pack = state.pack
    scope = state.scope
    messages = state.messages ++ [user_message(text)]

    task =
      try do
        Task.Supervisor.async_nolink(@turn_supervisor, fn ->
          run_turn(session, turn_id, pack, scope, messages)
        end)
      rescue
        # `Task.Supervisor.async_nolink/2` raises only for the dedicated
        # supervisor's `:max_children` refusal (AC-30).
        RuntimeError -> nil
      end

    if task do
      {user_entry, working_entry, state} = append_turn_entries(state, text)

      turn = %{
        turn_id: turn_id,
        task_ref: task.ref,
        task_pid: task.pid,
        entry_id: working_entry.id,
        user_entry_id: user_entry.id,
        pending_user_message: user_message(text),
        started_ms: System.monotonic_time(:millisecond),
        timer: Process.send_after(self(), {:turn_timeout, turn_id}, state.turn_timeout_ms),
        activity: [],
        tools: [],
        cost: 0.0,
        cost_complete: true,
        model: nil
      }

      state =
        state
        |> cancel_idle()
        |> Map.merge(%{turn: turn, requests: state.requests + 1, status: :working})
        |> broadcast({:entry, user_entry})
        |> broadcast({:entry, working_entry})
        |> broadcast({:status, :working})

      {:reply, :ok, state}
    else
      {:reply, {:error, :capacity}, touch(state)}
    end
  end

  defp retry_text(state, conversation_id, entry_id) do
    with true <- conversation_id == state.conversation_id,
         %{status: :failed} <- find_entry(state, entry_id),
         user_entry_id when is_integer(user_entry_id) <- Map.get(state.retry_sources, entry_id),
         %{text: text} <- find_entry(state, user_entry_id) do
      {:ok, text}
    else
      _other -> {:error, :stale_origin}
    end
  end

  defp record_receipt(state, conversation_id, entry_id, actual_command) do
    with true <- conversation_id == state.conversation_id,
         %{prepared: %{command: command}} = entry <- find_entry(state, entry_id) do
      if command == actual_command do
        state = put_entry(state, entry.id, %{applied?: true})
        {:ok, broadcast(state, {:entry, find_entry(state, entry.id)})}
      else
        {:error, :command_changed}
      end
    else
      _other -> {:error, :stale_origin}
    end
  end

  defp proposal(state, conversation_id, entry_id) do
    if conversation_id == state.conversation_id do
      case find_entry(state, entry_id) do
        %{prepared: %{} = prepared, applied?: false} -> {:ok, prepared}
        _other -> :error
      end
    else
      :error
    end
  end

  ## The task

  defp run_turn(session, turn_id, pack, scope, messages) do
    notify = fn event -> send(session, {:turn_event, turn_id, event}) end

    try do
      Turn.run(pack, scope, messages, notify)
    rescue
      _exception ->
        log_crash()
        :crashed
    catch
      _kind, _reason ->
        log_crash()
        :crashed
    end
  end

  # One fixed diagnostic for operators. The exception, the person's text, the
  # tool arguments and the closure state never reach the log (AC-33).
  defp log_crash do
    Logger.error("agent turn task crashed",
      event: "agent_turn_task_crashed",
      failure_class: :task_exception
    )
  end

  defp settle_task_result(state, {:ok, result}) do
    case check_context(state) do
      :ok ->
        {:cont, complete_turn(state, result)}

      {:error, :forbidden} ->
        # The membership changed while the answer was in flight: discard the
        # answer and its proposal (AC-12).
        {:stop, settle_forbidden(state, progress_of(result))}

      {:error, :unavailable} ->
        # The route or version this conversation answers about is gone: the
        # in-flight answer and its proposal are discarded too (INV-1).
        {:stop, settle_unavailable(state, progress_of(result))}
    end
  end

  defp settle_task_result(state, {:error, {:context, reason}, progress})
       when reason in [:forbidden, :unavailable] do
    case reason do
      :forbidden -> {:stop, settle_forbidden(state, progress)}
      :unavailable -> {:stop, settle_unavailable(state, progress)}
    end
  end

  defp settle_task_result(state, {:error, reason, progress}) do
    {:cont, failed_turn(state, reason, progress)}
  end

  defp settle_task_result(state, :crashed) do
    {:cont, crashed_turn(state)}
  end

  defp complete_turn(state, result) do
    settle_turn(
      state,
      result.text,
      :done,
      result.prepared,
      result.evidence,
      progress_of(result),
      "done",
      result.messages
    )
  end

  defp failed_turn(state, reason, progress) do
    {status, text, outcome} = failure_outcome(reason)
    settle_turn(state, text, status, nil, [], progress, outcome, nil)
  end

  defp failure_outcome(:step_limit), do: {:incomplete, @incomplete_text, "step_limit"}
  defp failure_outcome(:incomplete_response), do: {:incomplete, @incomplete_text, "incomplete"}
  defp failure_outcome(:context_limit), do: {:incomplete, @context_limit_text, "context_limit"}

  defp failure_outcome(:allowance_exhausted),
    do: {:allowance_exhausted, @allowance_exhausted_text, "allowance_exhausted"}

  defp failure_outcome(_reason), do: {:failed, @unavailable_text, "failed"}

  defp timeout_turn(state) do
    state = kill_task(state)

    settle_turn(
      state,
      @incomplete_text,
      :incomplete,
      nil,
      [],
      interrupted_progress(state),
      "timeout",
      nil
    )
  end

  defp stop_turn(state) do
    state = kill_task(state)

    settle_turn(
      state,
      @stopped_text,
      :stopped,
      nil,
      [],
      interrupted_progress(state),
      "stopped",
      nil
    )
  end

  defp crashed_turn(state) do
    settle_turn(
      state,
      @unavailable_text,
      :failed,
      nil,
      [],
      interrupted_progress(state),
      "crashed",
      nil
    )
  end

  # A task killed from outside (a stopped supervisor, another owner) must not
  # leave the panel working forever.
  defp down_turn(state) do
    settle_turn(
      state,
      @unavailable_text,
      :failed,
      nil,
      [],
      interrupted_progress(state),
      "killed",
      nil
    )
  end

  # Settles the running turn exactly once: the person's message and either the
  # generated sequence or one synthetic terminal reply join the history, the
  # entry records the outcome and no partial tool sequence survives (AC-27). An
  # interrupted or failed turn keeps no evidence either: a server answer that
  # never arrived whole must not reach the panel as a card (INV-2).
  defp settle_turn(state, text, status, prepared, evidence, progress, outcome, generated) do
    turn = state.turn

    extra =
      case generated do
        nil -> [turn.pending_user_message, synthetic_message(text)]
        generated -> [turn.pending_user_message | generated]
      end

    state =
      state
      |> commit_messages(extra)
      |> put_entry(turn.entry_id, %{
        text: text,
        activity: progress.activity,
        prepared: prepared,
        evidence: evidence,
        status: status
      })
      |> put_retry_source(turn)
      |> clear_turn()

    log_turn(state, turn, outcome, progress)
    state = broadcast(state, {:entry, find_entry(state, turn.entry_id)})
    state = %{state | status: final_status(state, status)}
    broadcast(state, {:status, state.status}) |> arm_idle()
  end

  # Every call from a revoked member ends the conversation: the running task is
  # terminated, the entry settles as forbidden without a proposal, and the panel
  # receives the access-changed status (AC-12).
  defp revoke(state), do: stop_context(state, :forbidden)

  defp settle_forbidden(state, progress), do: settle_context(state, progress, :forbidden)

  defp settle_unavailable(state, progress), do: settle_context(state, progress, :unavailable)

  # A call refused because the conversation's own resource context is gone ends
  # it the same way a revoked membership does, with the one `:unavailable`
  # result: the running task is terminated and the entry settles without a
  # proposal. Only an idle conversation needs no entry at all.
  defp stop_context(state, status) do
    {progress, state} =
      if state.turn do
        {interrupted_progress(state), kill_task(state)}
      else
        {nil, state}
      end

    {:stop, :normal, {:error, status}, settle_context(state, progress, status)}
  end

  defp stop_unavailable(state), do: stop_context(state, :unavailable)

  defp settle_context(state, progress, status) do
    text = context_text(status)

    state =
      case state.turn do
        nil ->
          state

        turn ->
          state =
            state
            |> commit_messages([turn.pending_user_message, synthetic_message(text)])
            |> put_entry(turn.entry_id, %{
              text: text,
              activity: progress.activity,
              prepared: nil,
              evidence: [],
              status: status
            })
            |> put_retry_source(turn)
            |> clear_turn()

          log_turn(state, turn, Atom.to_string(status), progress)
          broadcast(state, {:entry, find_entry(state, turn.entry_id)})
      end

    state |> Map.put(:status, status) |> broadcast({:status, status})
  end

  defp context_text(:forbidden), do: @forbidden_text
  defp context_text(:unavailable), do: @unavailable_context_text

  defp reset_conversation(state) do
    state = %{
      state
      | conversation_id: Ecto.UUID.generate(),
        next_id: 1,
        entries: [],
        messages: [],
        requests: 0,
        retry_sources: %{},
        status: :idle
    }

    state
    |> broadcast({:reset, state.conversation_id})
    |> broadcast({:status, :idle})
    |> arm_idle()
  end

  defp final_status(_state, :allowance_exhausted), do: :allowance_exhausted
  defp final_status(state, _entry_status) when state.requests >= @max_requests, do: :limit
  defp final_status(_state, _entry_status), do: :idle

  ## Turn bookkeeping

  defp append_turn_entries(state, text) do
    user_entry = new_entry(state.next_id, :user, text, :done)
    working_entry = new_entry(state.next_id + 1, :assistant, "", :working)

    state = %{
      state
      | entries: state.entries ++ [user_entry, working_entry],
        next_id: state.next_id + 2
    }

    {user_entry, working_entry, state}
  end

  defp accumulate(state, {:usage, model, cost}) do
    turn = state.turn
    turn = %{turn | model: model || turn.model, cost: turn.cost + (cost || 0)}
    %{state | turn: %{turn | cost_complete: turn.cost_complete and is_number(cost)}}
  end

  defp accumulate(state, {:activity, label}) do
    turn = state.turn
    %{state | turn: %{turn | activity: turn.activity ++ [label]}}
  end

  defp accumulate(state, {:tool, name}) do
    turn = state.turn
    %{state | turn: %{turn | tools: turn.tools ++ [name]}}
  end

  defp commit_messages(state, extra), do: %{state | messages: state.messages ++ extra}

  defp clear_turn(state) do
    turn = state.turn
    Process.demonitor(turn.task_ref, [:flush])
    if turn.timer, do: Process.cancel_timer(turn.timer)
    %{state | turn: nil}
  end

  defp kill_task(state) do
    turn = state.turn
    Task.Supervisor.terminate_child(@turn_supervisor, turn.task_pid)
    if turn.timer, do: Process.cancel_timer(turn.timer)
    Process.demonitor(turn.task_ref, [:flush])
    state
  end

  defp progress_of(result) do
    %{
      activity: result.activity,
      tools: result.tools,
      cost: result.cost,
      cost_complete: result.cost_complete
    }
  end

  # An interrupt (Stop, wall time, an external kill, a crash) leaves an in-flight
  # attempt's billing unknown, so `cost_complete` is false (AC-33).
  defp interrupted_progress(state) do
    turn = state.turn

    %{
      activity: turn.activity,
      tools: turn.tools,
      cost: turn.cost,
      cost_complete: false
    }
  end

  defp log_turn(state, turn, outcome, progress) do
    # The logger drops metadata whose value is `false`, so the completeness flag
    # is logged as text and the incomplete case stays visible (AC-33).
    Logger.info("agent turn finished",
      pack: state.pack.id(),
      model: turn.model || "unknown",
      organization_id: state.scope.organization_id,
      outcome: outcome,
      tools: Enum.join(progress.tools, ","),
      duration_ms: System.monotonic_time(:millisecond) - turn.started_ms,
      cost: progress.cost,
      cost_complete: to_string(progress.cost_complete)
    )
  end

  ## Idle handling

  # Idle expiry is suspended while a turn runs: the turn cancels the timer and
  # completion re-arms it. Stale tokens never match after a cancellation.
  defp arm_idle(state) do
    state = cancel_idle(state)
    token = make_ref()

    %{
      state
      | idle_timer: Process.send_after(self(), {:idle_timeout, token}, state.idle_timeout_ms),
        idle_token: token
    }
  end

  defp cancel_idle(state) do
    if state.idle_timer, do: Process.cancel_timer(state.idle_timer)
    %{state | idle_timer: nil, idle_token: nil}
  end

  defp touch(state) do
    if state.turn, do: cancel_idle(state), else: arm_idle(state)
  end

  ## Listeners

  defp put_listener(state, pid) do
    case Map.fetch(state.listeners, pid) do
      {:ok, _ref} ->
        state

      :error ->
        %{state | listeners: Map.put(state.listeners, pid, Process.monitor(pid))}
    end
  end

  defp remove_listener(state, pid) do
    case Map.pop(state.listeners, pid) do
      {nil, _listeners} ->
        state

      {ref, listeners} ->
        Process.demonitor(ref, [:flush])
        %{state | listeners: listeners}
    end
  end

  defp broadcast(state, event) do
    Enum.each(state.listeners, fn {pid, _ref} -> send(pid, {:agent_event, self(), event}) end)
    state
  end

  ## State helpers

  defp snapshot(state) do
    %{conversation_id: state.conversation_id, entries: state.entries, status: state.status}
  end

  defp new_entry(id, role, text, status) do
    %{
      id: id,
      role: role,
      text: text,
      activity: [],
      prepared: nil,
      evidence: [],
      applied?: false,
      status: status
    }
  end

  defp put_entry(state, entry_id, attrs) do
    entries =
      Enum.map(state.entries, fn
        %{id: ^entry_id} = entry -> Map.merge(entry, attrs)
        entry -> entry
      end)

    %{state | entries: entries}
  end

  defp find_entry(state, entry_id), do: Enum.find(state.entries, &(&1.id == entry_id))

  defp put_retry_source(state, turn) do
    %{state | retry_sources: Map.put(state.retry_sources, turn.entry_id, turn.user_entry_id)}
  end

  defp user_message(text), do: %{"role" => "user", "content" => text}

  defp synthetic_message(text), do: %{"role" => "assistant", "content" => text}
end
