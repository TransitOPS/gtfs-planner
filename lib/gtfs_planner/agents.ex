defmodule GtfsPlanner.Agents do
  @moduledoc """
  The LiveViews' entry point to the helper agent.

  A conversation is one session process, keyed by the person, organization,
  service version and pack (AC-24). Two panels opened by the same person on the
  same version share the conversation, while another person's or another
  version's panel never attaches to it (FH-3). `open/1` re-reads the membership
  before it starts or attaches anything (INV-2), so a deactivated or de-roled
  membership cannot join even an already-running conversation.

  Every call takes a session pid. A `nil` or non-pid handle, and a session that
  has ended, produce a documented error instead of raising into a LiveView:
  `{:error, :ended}`, `:error` from `prepared/3`, and `:ok` from `stop/1` and
  `detach/1`.

  The supervision components are started by `GtfsPlanner.Application`: the unique
  `GtfsPlanner.Agents.Registry`, `GtfsPlanner.Agents.SessionSupervisor`
  (`max_children: 200`, so `open/1` returns `{:error, :unavailable}` beyond the
  cap) and `GtfsPlanner.Agents.TurnSupervisor`, which bounds the eight active
  turns of AC-30. Session ids are
  `{user_id, organization_id, gtfs_version_id, pack_id, identity,
  approved_digest}`, so a second tab on the same route shares the conversation
  while the same user on another route never does (INV-1).

  `packs/0` is the only function here that names a concrete pack (INV-1).
  """

  alias GtfsPlanner.Agents.Pack
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Agents.Session

  @registry GtfsPlanner.Agents.Registry
  @session_supervisor GtfsPlanner.Agents.SessionSupervisor
  @call_timeout 5_000

  @packs %{
    "calendars" => GtfsPlanner.Agents.Packs.Calendars,
    "service_queries" => GtfsPlanner.Agents.Packs.ServiceQueries
  }

  @doc "Every shipped capability pack, keyed by `Pack.id/0`."
  @spec packs() :: %{optional(String.t()) => module()}
  def packs, do: @packs

  @doc """
  Attaches the caller to the conversation for `scope`, starting it when needed.

  Returns the session pid with the conversation snapshot `Session.attach/1`
  replies. A pack the application does not ship returns `{:error, :unknown_pack}`,
  a member without current access `{:error, :forbidden}`, a resource the current
  organization and version cannot resolve `{:error, :unavailable}`, the
  200-session cap `{:error, :unavailable}`, and a session that ended while
  attaching `{:error, :ended}`.
  """
  @spec open(Scope.t()) ::
          {:ok, pid(), Session.snapshot()}
          | {:error, :unknown_pack | :forbidden | :unavailable | :ended}
  def open(%Scope{pack_id: pack_id} = scope) do
    with {:ok, pack} <- fetch_pack(pack_id),
         :ok <- Scope.authorized_context(scope) do
      case Registry.lookup(@registry, key(scope)) do
        [{pid, _value}] -> attach(pid)
        [] -> start_session(scope, pack)
      end
    end
  end

  @doc """
  Sends one message to the session.

  The session's own admission decides the outcome: `:ok`, or `{:error, reason}`
  for a forbidden member, a running turn, blank or overlong text, the exhausted
  request allowance and the shared eight-turn capacity.
  """
  @spec send_message(pid() | nil, String.t()) ::
          :ok | {:error, atom()}
  def send_message(session, text) when is_pid(session),
    do: call(session, {:send_message, text})

  def send_message(_session, _text), do: {:error, :ended}

  @doc "Re-sends the original text of a failed entry in the current conversation."
  @spec retry(pid() | nil, String.t(), pos_integer()) :: :ok | {:error, atom()}
  def retry(session, conversation_id, entry_id) when is_pid(session),
    do: call(session, {:retry, conversation_id, entry_id})

  def retry(_session, _conversation_id, _entry_id), do: {:error, :ended}

  @doc "Stops the running turn; a no-op for an idle or ended session."
  @spec stop(pid() | nil) :: :ok
  def stop(session) when is_pid(session), do: call(session, :stop, :ok)
  def stop(_session), do: :ok

  @doc "Clears the conversation and issues a new conversation ID."
  @spec new_conversation(pid() | nil) :: :ok | {:error, atom()}
  def new_conversation(session) when is_pid(session), do: call(session, :new_conversation)
  def new_conversation(_session), do: {:error, :ended}

  @doc """
  Returns the proposal stored for the current conversation and entry.

  Applied and stale proposals return `:error`, as does an ended session.
  """
  @spec prepared(pid() | nil, String.t(), pos_integer()) :: {:ok, Pack.prepared()} | :error
  def prepared(session, conversation_id, entry_id) when is_pid(session),
    do: call(session, {:prepared, conversation_id, entry_id}, :error)

  def prepared(_session, _conversation_id, _entry_id), do: :error

  @doc """
  Records that the person applied the exact command this entry proposed.

  This never writes calendar data; it marks the entry applied.
  """
  @spec record_applied(pid() | nil, String.t(), pos_integer(), term()) :: :ok | {:error, atom()}
  def record_applied(session, conversation_id, entry_id, actual_command)
      when is_pid(session),
      do: call(session, {:record_applied, conversation_id, entry_id, actual_command})

  def record_applied(_session, _conversation_id, _entry_id, _actual_command),
    do: {:error, :ended}

  @doc "Removes the caller as a listener; a no-op for an ended session."
  @spec detach(pid() | nil) :: :ok
  def detach(session) when is_pid(session), do: call(session, :detach, :ok)
  def detach(_session), do: :ok

  ## Sessions

  defp fetch_pack(pack_id) do
    case Map.fetch(@packs, pack_id) do
      {:ok, pack} -> {:ok, pack}
      :error -> {:error, :unknown_pack}
    end
  end

  # The unique key is what keeps another person's, another version's or another
  # route's panel from reaching this conversation (FH-3, INV-1).
  defp key(%Scope{} = scope) do
    {scope.user_id, scope.organization_id, scope.gtfs_version_id, scope.pack_id,
     Scope.identity(scope), Scope.approved_digest(scope)}
  end

  defp start_session(scope, pack) do
    name = {:via, Registry, {@registry, key(scope)}}

    case DynamicSupervisor.start_child(
           @session_supervisor,
           {Session, scope: scope, pack: pack, name: name}
         ) do
      {:ok, pid} -> attach(pid)
      {:error, {:already_started, pid}} -> attach(pid)
      {:error, :max_children} -> {:error, :unavailable}
    end
  end

  defp attach(pid) do
    with {:ok, snapshot} <- Session.attach(pid), do: {:ok, pid, snapshot}
  catch
    # The session can end between the registry lookup and this call; the panel
    # must see the documented error rather than an exit (AC-4).
    :exit, _reason -> {:error, :ended}
  end

  defp call(session, message), do: call(session, message, {:error, :ended})

  defp call(session, message, on_ended) do
    GenServer.call(session, message, @call_timeout)
  catch
    :exit, _reason -> on_ended
  end
end
