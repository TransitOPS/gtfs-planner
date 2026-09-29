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

  Focus is a client concern with a server trigger: `agent:focus` events must be
  handled by a hook on a wrapper that survives the conditional panel, because the
  closing panel cannot own its own post-removal handler.
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

  @entries :agent_entries
  @composer "agent-composer-input"
  @open_button "agent-helper-open"

  @forbidden_notice "Your access changed."
  @unavailable_notice "The helper is unavailable right now."
  @busy_notice "The helper is still working on your last request."
  @capacity_notice "The helper is busy. Try again shortly."
  @too_long_error "Keep messages under 2,000 characters."

  @doc """
  Adds the panel's assigns, its entries stream and its two hooks to `socket`.

  `pack_id` must be a pack `GtfsPlanner.Agents.packs/0` ships; title, intro and
  examples come from that pack.
  """
  @spec mount(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def mount(socket, pack_id) do
    pack = Map.fetch!(Agents.packs(), pack_id)

    socket
    |> assign(:agent_pack_id, pack_id)
    |> assign(:agent_title, pack.title())
    |> assign(:agent_intro, pack.intro())
    |> assign(:agent_examples, pack.examples())
    |> assign(:agent_open?, false)
    |> assign(:agent_session, nil)
    |> assign(:agent_conversation_id, nil)
    |> assign(:agent_session_monitor, nil)
    |> assign(:agent_status, :idle)
    |> assign(:agent_notice, nil)
    |> assign(:agent_entries_empty?, true)
    |> assign(:agent_form, empty_form())
    |> assign(:agent_last_message, nil)
    |> stream_configure(@entries, dom_id: &"agent-entry-#{&1.id}")
    |> stream(@entries, [])
    |> attach_hook(:agent_panel_events, :handle_event, &handle_event/3)
    |> attach_hook(:agent_panel_info, :handle_info, &handle_info/2)
  end

  ## Events

  defp handle_event("agent_open", _params, socket) do
    case Agents.open(scope(socket)) do
      {:ok, pid, snapshot} ->
        {:halt,
         socket
         |> store_session(pid, snapshot)
         |> assign(:agent_open?, true)
         |> push_event("agent:focus", %{id: @composer})}

      {:error, status} ->
        {:halt, refuse(socket, status)}
    end
  end

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
         |> stream_insert(@entries, entry)
         |> assign(:agent_entries_empty?, false)}

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
    # status; its down must not replace that status with the ended copy.
    status = if socket.assigns.agent_status == :forbidden, do: :forbidden, else: :ended

    {:halt,
     socket
     |> assign(:agent_session, nil)
     |> assign(:agent_session_monitor, nil)
     |> assign(:agent_status, status)}
  end

  # The only monitors this socket holds are the panel's session monitors, and a
  # host consumes its async work through `handle_async/3`, not raw downs.
  defp handle_info({:DOWN, _ref, :process, _pid, _reason}, socket), do: {:halt, socket}
  defp handle_info(_message, socket), do: {:cont, socket}

  ## Session bookkeeping

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
    |> stream(@entries, snapshot.entries, reset: true)
  end

  defp reset_conversation(socket, conversation_id) do
    socket
    |> assign(:agent_conversation_id, conversation_id)
    |> assign(:agent_status, :idle)
    |> assign(:agent_notice, nil)
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
      version_name: socket.assigns.current_gtfs_version.name
    }
  end

  defp empty_form, do: to_form(%{"message" => ""}, as: :agent)
end
