defmodule GtfsPlannerWeb.AgentPanel do
  @moduledoc """
  The helper panel's LiveView glue for one section page.

  The host LiveView pipes its socket through `mount/2`, renders
  `GtfsPlannerWeb.AgentComponents.agent_panel/1` while `agent_open?` is true, and
  keeps the panel's events out of its own handlers: the two attached hooks own
  every `agent_*` event and the session's messages and return `{:cont, socket}`
  for everything else, so the host's own handlers keep working. The module names
  no pack and no domain code (INV-1); its copy arrives from
  `GtfsPlanner.Agents.packs/0`.

  The conversation is server-held. `Agents.open/1` receives a `%Scope{}` built
  from the host's current organization, service version and user assigns, and the
  panel keeps only the session pid, one session monitor and the conversation ID
  (INV-6). Admission, tool calls and delivered results are authorized inside the
  session and the turn (INV-2), so the panel never decides access itself.

  The panel also holds the conversation's server-owned resource context. `mount/2`
  binds the whole-version identity of the page it was mounted on, and a host that
  shows one resource of that version calls `set_context/2` when ordinary
  navigation changes it. The context may also carry an admitted source snapshot
  (`Scope.with_source_snapshot/2`), which is part of what this panel holds and
  part of what it releases: replacing the context drops the source with the
  transcript, and a person whose source is gone re-pastes it rather than the
  helper answering from a copy this page no longer owns. `set_context/2` affects
  this panel alone: it detaches the prior session, clears this panel's
  transcript, draft and origin, and returns a socket whose `agent_session` is
  nil, so a late event or down from the replaced session can no longer reach the
  new state (INV-1, AC-1). No other tab, session or native form input is
  touched.

  ## Which helper a page may offer

  A host that offers more than one helper names the whole set once, at mount:
  `mount(socket, default_pack, allowed_packs: [...])`. `mount/2` remains the
  single-helper delegate, so a page that offers one helper passes one pack and
  nothing else. The set is compile-owned configuration: it is validated against
  `GtfsPlanner.Agents.packs/0` when the page mounts and a default or an entry the
  application does not ship fails the mount instead of becoming a dead control.
  The panel keeps the set in its own assigns and reads nothing about it from a
  client event, so a forged selection can only name a pack the host already
  allowed.

  Switching is `select_pack/3`, and it changes this panel alone (CR-5, INV-3).
  A selection outside the host's set is refused with a visible notice and changes
  nothing else: the running conversation, the transcript and the person's draft
  stay exactly as they were. The same pack and the same context is a no-op, so a
  control that re-posts the current choice cannot restart a conversation. Any
  other selection detaches this panel from the session it held, drops that
  session's monitor, clears this panel's transcript, draft and origin, binds the
  supplied server context, takes its title, intro and examples from the newly
  selected pack and attaches to that pack's conversation when the panel is open.
  Nothing is stopped: a second tab holding the same conversation and every
  native form and job on the page are untouched, the hooks and the entries
  stream stay the ones `mount` attached, and a late event or down from the
  session this panel left is ignored rather than applied to the new one. Hosts
  alone render the selection controls, so no panel offers a helper the host did
  not name.

  Focus is a client concern with a server trigger: `agent:focus` events must be
  handled by a hook on a wrapper that survives the conditional panel, because the
  closing panel cannot own its own post-removal handler.

  ## Evidence links

  Server evidence may name typed resources. This module, not the component and
  never the model, decides what those names mean: an allowlisted kind whose
  identifier the current scope actually owns resolves to one application path
  built from this panel's own version, and anything else resolves to no link at
  all, which the card states rather than hides (AC-4, AC-17). Evidence read
  under another organization, version or resource identity than this panel now
  holds is dropped whole, so no foreign answer can reach the screen even as an
  unlinked card (AC-2).

  Ownership is verified before a path is built, not after: a calendar and a
  route are looked up in this panel's own organization and version, so a deleted
  identity, one belonging to another organization or version, and a kind this
  panel does not name all render as plain text. A calendar identity is owned
  when a weekly row, a metadata anchor or an exception date carries it, which is
  the rule the calendar editor itself applies, so a dates-only service resolves
  and a deleted one does not. No model text and no `url` on a resource is ever
  read: a path is only ever built here, from a verified kind and identifier.

  `resolve_resource_link/2` is that same resolution as a public seam, so a host
  that renders its own report navigates by exactly the rule the panel applies
  rather than by a second copy of it.

  A route reference resolves to that route's own Schedules page, which is the
  page the Schedule helper is bound to; it is the same page the panel already
  shows, so following it never leaves the scope this panel holds.

  A host that applies the assistant's own changes opts in with `auto_apply: true`
  and names the record in `subject_id`. Each settled, unapplied prepared entry is
  then handed to the host exactly once as `{:agent_prepared, conversation_id,
  entry_id}`; the panel still prepares nothing and writes nothing (CR-6) — the
  host applies it. `open/1` lets a host open the panel the way the open button
  does.

  `agent_unavailable?` is the one thing a host cannot work out for itself: the
  transcript is a stream it does not enumerate, so a turn that failed at the
  provider is reported here instead. It is true once a turn settles as `:failed`
  or `:incomplete` and false again when a new or replaced conversation opens.
  """

  import Phoenix.Component, only: [assign: 3, to_form: 2]

  import Phoenix.LiveView,
    only: [
      attach_hook: 4,
      push_event: 3,
      stream: 3,
      stream: 4,
      stream_configure: 3,
      stream_insert: 3
    ]

  alias GtfsPlanner.Agents
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs

  use GtfsPlannerWeb, :verified_routes

  @entries :agent_entries
  @composer "agent-composer-input"
  @open_button "agent-helper-open"

  @forbidden_notice "Your access changed."
  @unavailable_notice "The helper is unavailable right now."
  @unavailable_pack_notice "This helper is not available on this page."
  @unavailable_context_notice "This route or calendar is no longer available, so the helper stopped."
  @busy_notice "The helper is still working on your last request."
  @capacity_notice "The helper is busy. Try again shortly."
  @too_long_error "Keep messages under 2,000 characters."

  @doc """
  Adds the panel's assigns, its entries stream and its two hooks to `socket`.

  `pack_id` must be a pack `GtfsPlanner.Agents.packs/0` ships; title, intro and
  examples come from that pack.

  Options:

    * `:auto_apply` - hand each settled, unapplied prepared entry to the host as
      `{:agent_prepared, conversation_id, entry_id}`. Defaults to false,
      so a host that reviews changes itself — Calendar's — receives nothing.
    * `:subject_id` - the record this conversation is about, carried into the
      session `Scope` so two records get two conversations.
  """
  @spec mount(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def mount(socket, pack_id), do: mount(socket, pack_id, allowed_packs: [pack_id])

  @doc """
  Mounts the panel with `default_pack` and the whole set of helpers this host
  offers as `allowed_packs`.

  The set is compile-owned configuration: every id, the default included, must
  be a pack `GtfsPlanner.Agents.packs/0` ships and the default must be one of
  the allowed ids, or the mount raises rather than shipping a panel whose
  selector offers a helper this application cannot open. The set is stored once
  here and is never read from a client event; `select_pack/3` decides against
  this stored copy.

  A host that offers one helper omits the option and gets exactly that helper,
  which is what a single-helper host has always mounted. Other options — an
  `auto_apply` flag or a `subject_id` — are read from the same keyword list.
  """
  @spec mount(Phoenix.LiveView.Socket.t(), String.t(), keyword()) :: Phoenix.LiveView.Socket.t()
  def mount(socket, pack_id, opts) do
    packs = Agents.packs()
    allowed_packs = validate_hosts!(packs, pack_id, Keyword.get(opts, :allowed_packs, [pack_id]))
    pack = Map.fetch!(packs, pack_id)

    socket
    |> assign(:agent_pack_id, pack_id)
    |> assign(:agent_allowed_packs, allowed_packs)
    |> assign(:agent_context, Scope.context({:version, socket.assigns.current_gtfs_version.id}))
    |> assign(:agent_title, pack.title())
    |> assign(:agent_intro, pack.intro())
    |> assign(:agent_examples, pack.examples())
    |> assign(:agent_auto_apply?, Keyword.get(opts, :auto_apply, false) == true)
    |> assign(:agent_subject_id, Keyword.get(opts, :subject_id))
    |> assign(:agent_forwarded, MapSet.new())
    |> assign(:agent_open?, false)
    |> assign(:agent_session, nil)
    |> assign(:agent_conversation_id, nil)
    |> assign(:agent_session_monitor, nil)
    |> assign(:agent_status, :idle)
    |> assign(:agent_notice, nil)
    |> assign(:agent_unavailable?, false)
    |> assign(:agent_entries_empty?, true)
    |> assign(:agent_form, empty_form())
    |> assign(:agent_last_message, nil)
    |> stream_configure(@entries, dom_id: &"agent-entry-#{&1.id}")
    |> stream(@entries, [])
    |> attach_hook(:agent_panel_events, :handle_event, &handle_event/3)
    |> attach_hook(:agent_panel_info, :handle_info, &handle_info/2)
  end

  @doc """
  Replaces this panel's resource context on ordinary host navigation.

  The panel detaches from the session it held, drops that session's monitor and
  clears its own transcript, draft, notice and origin, so nothing from the old
  route remains on screen. An unchanged context is a no-op, which keeps a patch
  that did not move the resource from restarting the conversation. An open panel
  attaches to the new context's session immediately; a refused one keeps its
  notice, and the panel's own `agent_*` events stay attached either way.
  """
  @spec set_context(Phoenix.LiveView.Socket.t(), Scope.resource_context()) ::
          Phoenix.LiveView.Socket.t()
  def set_context(socket, context) do
    if context == socket.assigns[:agent_context] do
      socket
    else
      socket
      |> detach_session()
      |> reset_panel()
      |> assign(:agent_context, context)
      |> maybe_reopen()
    end
  end

  @doc """
  Switches this panel to the helper `pack_id` for the server-owned `context`.

  A pack this host did not allow is refused: the notice says the helper is not
  available here and the running conversation, its transcript and the person's
  draft are left exactly as they were. Selecting the pack and context the panel
  already holds is a no-op, so a control that re-posts the current choice cannot
  restart a conversation. Any other selection detaches this panel from its
  current session — releasing the listener without stopping the session, so a
  second tab on the same conversation and every native form on the page are
  untouched (CR-5, INV-3) — clears this panel's transcript, draft and origin,
  binds the supplied context and reattaches if the panel is open. The hooks and
  the entries stream are the ones `mount` attached; switching never remounts.

  Returns the socket with whether this panel moved to `pack_id`, so a host acts
  on the switch itself rather than inferring it: a refused or already-current
  selection reports `false`, and a host that invalidates state of its own when
  the conversation moves leaves that state alone for a refusal.
  """
  @spec select_pack(Phoenix.LiveView.Socket.t(), String.t(), Scope.resource_context()) ::
          {Phoenix.LiveView.Socket.t(), boolean()}
  def select_pack(socket, pack_id, context) do
    cond do
      not allowed?(socket, pack_id) ->
        {assign(socket, :agent_notice, @unavailable_pack_notice), false}

      pack_id == socket.assigns.agent_pack_id and context == socket.assigns.agent_context ->
        {socket, false}

      true ->
        pack = Map.fetch!(Agents.packs(), pack_id)

        switched =
          socket
          |> detach_session()
          |> reset_panel()
          |> assign(:agent_pack_id, pack_id)
          |> assign(:agent_title, pack.title())
          |> assign(:agent_intro, pack.intro())
          |> assign(:agent_examples, pack.examples())
          |> assign(:agent_context, context)
          |> maybe_reopen()

        {switched, true}
    end
  end

  ## Opening

  @doc """
  Opens the panel and attaches this process to the conversation, as the open
  button's `"agent_open"` event does.

  A host that opens the panel itself — a route that arrives in assistant mode —
  calls this from its own handler and assigns the returned socket. A refused open
  still opens the panel, because the panel is what carries the notice (AC-12).
  """
  @spec open(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def open(socket) do
    case Agents.open(scope(socket)) do
      {:ok, pid, snapshot} ->
        socket
        |> store_session(pid, snapshot)
        |> assign(:agent_open?, true)
        |> push_event("agent:focus", %{id: @composer})

      {:error, status} ->
        refuse(socket, status)
    end
  end

  ## Events

  defp handle_event("agent_open", _params, socket), do: {:halt, open(socket)}

  defp handle_event("agent_close", _params, socket) do
    {:halt,
     socket
     |> assign(:agent_open?, false)
     |> push_event("agent:focus", %{id: @open_button})}
  end

  defp handle_event("agent_send", %{"agent" => %{"message" => text}}, socket) do
    case Agents.send_message(socket.assigns.agent_session, text) do
      :ok ->
        {:halt,
         socket
         |> assign(:agent_form, empty_form())
         |> assign(:agent_last_message, text)}

      {:error, :too_long} ->
        {:halt,
         assign(
           socket,
           :agent_form,
           to_form(%{"message" => text}, as: :agent, errors: [message: @too_long_error])
         )}

      {:error, :busy} ->
        {:halt, notice(socket, text, @busy_notice)}

      {:error, :capacity} ->
        {:halt, notice(socket, text, @capacity_notice)}

      {:error, :empty} ->
        {:halt, socket}

      {:error, :unavailable} ->
        {:halt,
         socket
         |> notice(text, @unavailable_context_notice)
         |> assign(:agent_status, :unavailable)}

      {:error, status} ->
        {:halt, assign(socket, :agent_status, status)}
    end
  end

  defp handle_event("agent_stop", _params, socket) do
    Agents.stop(socket.assigns.agent_session)
    {:halt, socket}
  end

  defp handle_event("agent_new", _params, socket) do
    case Agents.new_conversation(socket.assigns.agent_session) do
      :ok ->
        # The session's reset event clears the transcript and focuses the composer.
        {:halt, socket}

      {:error, :busy} ->
        {:halt, assign(socket, :agent_notice, @busy_notice)}

      {:error, :forbidden} ->
        {:halt, assign(socket, :agent_status, :forbidden)}

      {:error, :ended} ->
        # The held session is gone (an idle expiry or a server restart): attach a
        # fresh authorized one, which re-reads the membership before it starts
        # anything (AC-4).
        {:halt, open_fresh(socket)}
    end
  end

  defp handle_event("agent_retry", %{"entry" => id}, socket) do
    case Integer.parse(id) do
      {entry_id, ""} ->
        {:halt, retry(socket, entry_id)}

      _other ->
        {:halt, socket}
    end
  end

  defp handle_event("agent_example", %{"text" => text}, socket) do
    {:halt, assign(socket, :agent_form, to_form(%{"message" => text}, as: :agent))}
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  defp retry(socket, entry_id) do
    case Agents.retry(
           socket.assigns.agent_session,
           socket.assigns.agent_conversation_id,
           entry_id
         ) do
      :ok -> socket
      # A reset or a replaced conversation left no such failed entry to retry.
      {:error, :stale_origin} -> socket
      {:error, :busy} -> assign(socket, :agent_notice, @busy_notice)
      {:error, :capacity} -> assign(socket, :agent_notice, @capacity_notice)
      {:error, status} -> assign(socket, :agent_status, status)
    end
  end

  ## Session messages

  defp handle_info({:agent_event, pid, event}, %{assigns: %{agent_session: pid}} = socket) do
    case event do
      {:entry, entry} ->
        {:halt,
         socket
         |> stream_insert(@entries, resolve_entry_evidence(entry, socket))
         |> assign(:agent_entries_empty?, false)
         |> track_unavailable(entry)
         |> forward_prepared(entry)}

      {:status, status} ->
        {:halt, assign(socket, :agent_status, status)}

      {:reset, conversation_id} ->
        {:halt, reset_conversation(socket, conversation_id)}
    end
  end

  # Events and downs from a session this panel no longer owns (a replaced or
  # ended one) must not overwrite the active conversation (FH-23). They are still
  # the panel's messages, so they are halted instead of reaching a host that
  # never asked for them.
  defp handle_info({:agent_event, _pid, _event}, socket), do: {:halt, socket}

  defp handle_info(
         {:DOWN, ref, :process, _pid, _reason},
         %{assigns: %{agent_session_monitor: ref}} = socket
       ) do
    # A forbidden session stops itself after broadcasting the access-changed
    # status; its down must not replace that status with the ended copy. The same
    # holds for a session that stopped because its resource context is gone.
    status =
      cond do
        socket.assigns.agent_status == :forbidden -> :forbidden
        socket.assigns.agent_status == :unavailable -> :unavailable
        true -> :ended
      end

    {:halt,
     socket
     |> assign(:agent_session, nil)
     |> assign(:agent_session_monitor, nil)
     |> assign(:agent_status, status)}
  end

  # A down for a session this panel released never arrives: the release
  # demonitors with `[:flush]`, so a stale session's down is discarded at the
  # moment it stops being this panel's business. Every remaining down therefore
  # belongs to somebody else -- typically a host monitoring its own async work
  # (AC-15, AC-16) -- so it is passed through rather than swallowed. Swallowing
  # it here would leave the host waiting forever for a result it was told could
  # fail. An unknown message is the host's for the same reason: the handoff below
  # has no handler here, so it reaches the host's own `handle_info/2` unchanged.
  defp handle_info({:DOWN, _ref, :process, _pid, _reason}, socket), do: {:cont, socket}
  defp handle_info(_message, socket), do: {:cont, socket}

  ## Evidence resolution

  # Entries arrive from the session, which authorized the turn that produced
  # them. The panel re-checks the evidence against its own current context before
  # it becomes a card: an answer read under a scope this panel no longer holds is
  # dropped, not merely unlinked (AC-2, AC-4).
  defp resolve_entry_evidence(%{evidence: evidence} = entry, socket) when is_list(evidence) do
    resolved =
      evidence
      |> Enum.map(&resolve_evidence(&1, socket))
      |> Enum.reject(&is_nil/1)

    Map.put(entry, :evidence, resolved)
  end

  defp resolve_entry_evidence(entry, _socket), do: entry

  defp resolve_evidence(%{scope: scope} = evidence, socket) do
    if scoped_here?(scope, socket) do
      Map.update!(evidence, :resources, fn resources ->
        Enum.map(resources, &resolve_resource(&1, socket))
      end)
    else
      nil
    end
  end

  defp resolve_evidence(_evidence, _socket), do: nil

  defp scoped_here?(
         %{organization_id: organization_id, gtfs_version_id: version_id, identity: identity},
         socket
       ) do
    organization_id == socket.assigns.current_organization.id and
      version_id == socket.assigns.current_gtfs_version.id and
      identity == identity_label(socket.assigns.agent_context)
  end

  defp scoped_here?(_scope, _socket), do: false

  defp identity_label(%{identity: {kind, id}}), do: "#{kind}:#{id}"
  defp identity_label(_context), do: nil

  defp resolve_resource(resource, socket),
    do: Map.put(resource, :link, resolve_resource_link(socket, resource))

  @doc """
  Resolves one typed resource to a native path in this panel's current scope.

  This is the panel's whole link rule as a public function, so a host rendering
  its own report navigates by exactly the same resolution the panel applies to
  evidence, and the two cannot drift. It returns the path for an allowlisted
  kind whose identifier the panel's own organization and version still own, and
  `nil` for everything else: an unlisted kind, a non-binary identifier, an
  unknown, deleted, foreign or cross-version resource, and any `url` a resource
  happens to carry (no resource field but `kind` and `id` is ever read).

  It writes nothing, and a path it returns is an ordinary editor URL: following
  it opens the native editor and confers no authority this panel does not hold
  (AC-17, INV-1).
  """
  @spec resolve_resource_link(Phoenix.LiveView.Socket.t(), map() | term()) :: String.t() | nil
  def resolve_resource_link(socket, %{kind: kind, id: id}) when is_binary(id),
    do: evidence_link(kind, id, socket)

  def resolve_resource_link(_socket, _resource), do: nil

  # The only resource kinds this panel may turn into a link. A kind absent from
  # these clauses renders as plain text, which keeps a new pack's reference from
  # becoming a path this panel has not reviewed. Each clause checks ownership
  # before it builds anything.
  defp evidence_link("calendar", id, socket) do
    if owned_calendar?(id, socket), do: calendar_path(socket, id)
  end

  defp evidence_link("calendars_index", _id, socket), do: calendars_path(socket)

  defp evidence_link("route", id, socket) do
    if owned_route?(id, socket), do: route_schedules_path(socket, id)
  end

  defp evidence_link(_kind, _id, _socket), do: nil

  # A calendar identity is taken by a weekly row, a metadata anchor or an
  # exception date. That is the rule the calendar list, the editor and the
  # reference lock already apply, so a dates-only service resolves here exactly
  # as it does there, and a service of another organization, another version or
  # no calendar at all does not resolve at all.
  defp owned_calendar?(service_id, socket) do
    case Gtfs.calendar_usage(
           socket.assigns.current_organization.id,
           socket.assigns.current_gtfs_version.id,
           service_id
         ) do
      {:ok, _usage} -> true
      {:error, :not_found} -> false
    end
  end

  defp owned_route?(route_id, socket) do
    not is_nil(
      Gtfs.get_route_by_route_id(
        socket.assigns.current_organization.id,
        socket.assigns.current_gtfs_version.id,
        route_id
      )
    )
  end

  # The paths are built the way the calendar components build them: the version
  # comes from this panel's own assigns and the service ID is percent-encoded, so
  # an imported ID can never escape the query parameter.
  defp calendar_path(socket, service_id) do
    calendar_base(socket) <> "/show?service_id=" <> URI.encode_www_form(service_id)
  end

  defp calendars_path(socket), do: calendar_base(socket)

  # A route reference is the route's own Schedules page in this version, built the
  # way the route components build it: the version comes from this panel's own
  # assigns and the route ID is percent-encoded, so an imported ID cannot escape
  # the path.
  defp route_schedules_path(socket, route_id) do
    ~p"/gtfs/#{socket.assigns.current_gtfs_version.id}/routes/#{route_id}/schedules"
  end

  defp calendar_base(socket),
    do: "/gtfs/" <> socket.assigns.current_gtfs_version.id <> "/calendars"

  ## Handoff to the host

  # The transcript is a stream, so a host watching the panel cannot see an entry
  # settle at `:failed` or `:incomplete` — the two statuses a provider failure
  # produces. The flag is what lets that host say the helper is unavailable
  # without reading entries it does not own.
  defp track_unavailable(socket, %{role: :assistant, status: status})
       when status in [:failed, :incomplete],
       do: assign(socket, :agent_unavailable?, true)

  defp track_unavailable(socket, _entry), do: socket

  # A settled assistant entry carrying a prepared change is offered to the host
  # once per conversation. The session re-broadcasts an entry whenever its state
  # changes — a working state, a retry, the applied mark — so the forwarded set is
  # what keeps one change from being applied twice.
  defp forward_prepared(socket, entry) do
    if socket.assigns.agent_auto_apply? and forwardable?(entry) and
         not MapSet.member?(socket.assigns.agent_forwarded, entry.id) do
      send(self(), {:agent_prepared, socket.assigns.agent_conversation_id, entry.id})

      assign(socket, :agent_forwarded, MapSet.put(socket.assigns.agent_forwarded, entry.id))
    else
      socket
    end
  end

  defp forwardable?(entry) do
    entry.role == :assistant and entry.status == :done and
      not is_nil(entry.prepared) and entry.applied? == false
  end

  ## Session bookkeeping

  # Releasing the held session first is what keeps a second tab attached: the
  # session keeps running with its other listener.
  defp detach_session(socket) do
    case socket.assigns[:agent_session] do
      pid when is_pid(pid) -> Agents.detach(pid)
      _other -> :ok
    end

    case socket.assigns[:agent_session_monitor] do
      ref when is_reference(ref) -> Process.demonitor(ref, [:flush])
      _other -> :ok
    end

    socket
    |> assign(:agent_session, nil)
    |> assign(:agent_session_monitor, nil)
  end

  # The cleared state is this panel's alone: its transcript, draft, origin and
  # notice, with the composer ready for the new context.
  defp reset_panel(socket) do
    socket
    |> assign(:agent_conversation_id, nil)
    |> assign(:agent_status, :idle)
    |> assign(:agent_notice, nil)
    |> assign(:agent_entries_empty?, true)
    |> assign(:agent_form, empty_form())
    |> assign(:agent_last_message, nil)
    |> stream(@entries, [], reset: true)
  end

  defp maybe_reopen(%{assigns: %{agent_open?: true}} = socket) do
    case Agents.open(scope(socket)) do
      {:ok, pid, snapshot} ->
        store_session(socket, pid, snapshot)

      {:error, status} ->
        refuse(socket, status)
    end
  end

  defp maybe_reopen(socket), do: socket

  # The allowlist is this panel's own stored copy, so no client value can widen
  # it: the only ids that pass are the ones the host named when it mounted.
  defp allowed?(socket, pack_id) do
    is_binary(pack_id) and pack_id in socket.assigns[:agent_allowed_packs]
  end

  defp validate_hosts!(packs, pack_id, allowed_packs) do
    allowed_packs =
      case allowed_packs do
        ids when is_list(ids) ->
          ids

        other ->
          raise ArgumentError, "allowed_packs must be a list of pack ids, got: #{inspect(other)}"
      end

    unknown =
      Enum.reject(Enum.uniq([pack_id | allowed_packs]), fn id ->
        is_binary(id) and Map.has_key?(packs, id)
      end)

    if unknown == [] do
      if pack_id in allowed_packs do
        allowed_packs
      else
        raise ArgumentError,
              "the default helper #{inspect(pack_id)} must be one of the packs this host allows"
      end
    else
      raise ArgumentError,
            "this host names helpers GtfsPlanner.Agents.packs/0 does not ship: #{inspect(unknown)}"
    end
  end

  defp store_session(socket, pid, snapshot) do
    previous = socket.assigns[:agent_session]
    # `open/1` attaches this process, so releasing the session we are attaching
    # to would immediately drop the listener it just added.
    if is_pid(previous) and previous != pid, do: Agents.detach(previous)

    case socket.assigns[:agent_session_monitor] do
      ref when is_reference(ref) -> Process.demonitor(ref, [:flush])
      _other -> :ok
    end

    socket
    |> assign(:agent_session, pid)
    |> assign(:agent_session_monitor, Process.monitor(pid))
    |> assign(:agent_conversation_id, snapshot.conversation_id)
    |> assign(:agent_status, snapshot.status)
    |> assign(:agent_entries_empty?, snapshot.entries == [])
    |> assign(:agent_notice, nil)
    |> assign(:agent_unavailable?, false)
    # A new or replaced conversation numbers its entries from one, so ids from the
    # previous conversation must not suppress this one's first handoff.
    |> assign(:agent_forwarded, MapSet.new())
    |> stream(@entries, Enum.map(snapshot.entries, &resolve_entry_evidence(&1, socket)),
      reset: true
    )
  end

  defp reset_conversation(socket, conversation_id) do
    socket
    |> assign(:agent_conversation_id, conversation_id)
    |> assign(:agent_status, :idle)
    |> assign(:agent_notice, nil)
    |> assign(:agent_unavailable?, false)
    |> assign(:agent_forwarded, MapSet.new())
    |> assign(:agent_entries_empty?, true)
    |> assign(:agent_form, empty_form())
    |> assign(:agent_last_message, nil)
    |> stream(@entries, [], reset: true)
    |> push_event("agent:focus", %{id: @composer})
  end

  defp open_fresh(socket) do
    case Agents.open(scope(socket)) do
      {:ok, pid, snapshot} ->
        socket
        |> store_session(pid, snapshot)
        |> assign(:agent_open?, true)
        |> assign(:agent_form, empty_form())
        |> assign(:agent_last_message, nil)
        |> push_event("agent:focus", %{id: @composer})

      {:error, status} ->
        refuse(socket, status)
    end
  end

  # A refused open is visible: the panel is the surface that carries the notice
  # and the status region, so it opens on a forbidden or unavailable result
  # instead of leaving the click with no visible outcome (AC-12).
  defp refuse(socket, :forbidden) do
    socket
    |> assign(:agent_open?, true)
    |> assign(:agent_status, :forbidden)
    |> assign(:agent_notice, @forbidden_notice)
  end

  defp refuse(socket, _status) do
    socket
    |> assign(:agent_open?, true)
    |> assign(:agent_status, :idle)
    |> assign(:agent_notice, @unavailable_notice)
  end

  # A refused send keeps the person's draft: the form is rebuilt with the
  # submitted text rather than left to the client's DOM state.
  defp notice(socket, text, message) do
    socket
    |> assign(:agent_form, to_form(%{"message" => text}, as: :agent))
    |> assign(:agent_notice, message)
  end

  defp scope(socket) do
    %Scope{
      organization_id: socket.assigns.current_organization.id,
      gtfs_version_id: socket.assigns.current_gtfs_version.id,
      user_id: socket.assigns.current_user.id,
      user_email: socket.assigns.current_user.email,
      pack_id: socket.assigns.agent_pack_id,
      version_name: socket.assigns.current_gtfs_version.name,
      subject_id: socket.assigns.agent_subject_id,
      resource_context: socket.assigns.agent_context
    }
  end

  defp empty_form, do: to_form(%{"message" => ""}, as: :agent)
end
