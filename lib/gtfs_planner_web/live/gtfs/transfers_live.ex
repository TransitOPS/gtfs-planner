defmodule GtfsPlannerWeb.Gtfs.TransfersLive do
  @moduledoc """
  LiveView for managing the version's transfer rules.

  The page is the Routes area's second tab: a title bar over one bordered
  workspace, with the version's general rules on the left and the selected
  connection's context on the right. The catalog load runs synchronously through
  `Gtfs.load_transfer_catalog/3` on mount, so the states this shell renders are
  decided before the first paint. A lost database connection shows the list
  pane's load failure with a retry; a version without general rules shows the
  first-use state; an unavailable or empty load never leaves the workspace
  border as the only signal.

  Editing, filtering and the connection map arrive with their own steps, so this
  LiveView owns only the shell: the heading, the workspace, the retry event and
  version switching.

  Version switching keeps the action and accepts only a published version of the
  current organization. A foreign, staging or absent version leaves both the
  socket and the client's selection untouched, as on the other GTFS pages.
  """

  use GtfsPlannerWeb, :live_view

  import GtfsPlannerWeb.Gtfs.TransferComponents

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Versions

  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Transfers")
     |> assign(:catalog_state, :ready)
     |> assign(:catalog, nil)}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, load_catalog(socket)}

  @impl true
  def handle_event("retry_load", _params, socket), do: {:noreply, load_catalog(socket)}

  @impl true
  def handle_event("switch_gtfs_version", %{"version" => version_id}, socket) do
    if Versions.published_gtfs_version_for_org?(
         socket.assigns.current_organization.id,
         version_id
       ) do
      socket = push_event(socket, "gtfs_version_selected", %{version_id: version_id})
      {:noreply, push_navigate(socket, to: transfers_target(version_id))}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("gtfs_version_loaded", %{"version_id" => version_id}, socket) do
    current_version_id = to_string(socket.assigns.current_gtfs_version.id)

    if version_id && version_id != current_version_id &&
         Versions.published_gtfs_version_for_org?(
           socket.assigns.current_organization.id,
           version_id
         ) do
      {:noreply, push_navigate(socket, to: transfers_target(version_id))}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_organization={@current_organization}
      user_roles={@user_roles}
      current_path={@current_path}
      current_gtfs_version={assigns[:current_gtfs_version]}
      available_versions={assigns[:available_versions] || []}
    >
      <:sub_header>
        <.routes_tabs gtfs_version_id={@current_gtfs_version.id} active_tab={:transfers} />
      </:sub_header>

      <div id="transfers-page">
        <.header>
          Transfers
          <:subtitle>Help riders make the right connection.</:subtitle>
        </.header>

        <.workspace>
          <:list>
            <.load_failure :if={@catalog_state == :unavailable} />
            <.first_use :if={first_use?(@catalog_state, @catalog)} />
          </:list>
          <:context>
            <.context_empty />
          </:context>
        </.workspace>
      </div>
    </Layouts.app>
    """
  end

  defp load_catalog(socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    case Gtfs.load_transfer_catalog(organization_id, gtfs_version_id, []) do
      {:ok, catalog} ->
        socket |> assign(:catalog, catalog) |> assign(:catalog_state, :ready)

      {:error, :unavailable} ->
        socket |> assign(:catalog, nil) |> assign(:catalog_state, :unavailable)
    end
  end

  # First use is a version with no general rules at all, including one whose only
  # rows are in-seat records, whose mutations belong to Blocks. A later step adds
  # the filtered-empty state beside it.
  defp first_use?(:ready, %{counts: %{general: 0}}), do: true
  defp first_use?(_catalog_state, _catalog), do: false

  defp transfers_target(version_id), do: ~p"/gtfs/#{version_id}/transfers"
end
