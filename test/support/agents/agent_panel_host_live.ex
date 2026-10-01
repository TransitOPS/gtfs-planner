defmodule GtfsPlannerWeb.AgentPanelHostLive do
  @moduledoc """
  Test-only host LiveView for the panel's handoff to its host (EV-24).

  No production host opts into `auto_apply` yet — the alerts editor does in the
  editor step — so this module plays that host: it mounts `AgentPanel` with the
  options the host passes, opens it through `AgentPanel.open/1` rather than the
  open button, and forwards every `{:agent_prepared, conversation_id, entry_id}`
  it receives to the process registered as
  `:agent_panel_handoff_test_pid`.

  It names no domain code and no pack of its own: the pack, the session and the
  prepared change all come from production, and the host only decides what to do
  with the handoff message, which here is to hand it to the test.
  """

  use Phoenix.LiveView

  import Phoenix.Component

  import GtfsPlannerWeb.AgentComponents, only: [agent_panel: 1]

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion
  alias GtfsPlannerWeb.AgentPanel

  @test_pid_key :agent_panel_handoff_test_pid

  @impl true
  def mount(_params, session, socket) do
    socket =
      socket
      |> assign(:current_organization, Repo.get!(Organization, session["organization_id"]))
      |> assign(:current_gtfs_version, Repo.get!(GtfsVersion, session["gtfs_version_id"]))
      |> assign(:current_user, Accounts.get_user!(session["user_id"]))
      |> assign(:received_prepared, [])

    {:ok,
     AgentPanel.mount(socket, "calendars",
       auto_apply: session["auto_apply"] == "true",
       subject_id: session["subject_id"]
     )}
  end

  @impl true
  def handle_event("host_open", _params, socket), do: {:noreply, AgentPanel.open(socket)}

  @impl true
  def handle_info({:agent_prepared, conversation_id, entry_id}, socket) do
    notify({:host_received_prepared, conversation_id, entry_id})

    {:noreply, assign(socket, :received_prepared, socket.assigns.received_prepared ++ [entry_id])}
  end

  @impl true
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <button id="host-open" type="button" phx-click="host_open">Open helper</button>
      <button id="host-open-button" type="button" phx-click="agent_open">Open helper panel</button>

      <.agent_panel
        :if={@agent_open?}
        id="agent-panel"
        title={@agent_title}
        intro={@agent_intro}
        examples={@agent_examples}
        scope_line={"Handoff host · " <> @current_gtfs_version.name}
        status={@agent_status}
        entries={@streams.agent_entries}
        form={@agent_form}
        notice={@agent_notice}
        entries_empty?={@agent_entries_empty?}
      />
    </div>
    """
  end

  defp notify(message) do
    case Application.get_env(:gtfs_planner, @test_pid_key) do
      pid when is_pid(pid) ->
        send(pid, message)
        :ok

      _unset ->
        :ok
    end
  end
end
