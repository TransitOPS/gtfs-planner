defmodule GtfsPlannerWeb.Gtfs.FleetLive do
  @moduledoc """
  LiveView shell for the organization's fleet.

  Vehicles belong to the organization and ignore GTFS versions. This step
  establishes the route, the mount-time authorization and the version handlers so
  the Blocks sub-navigation resolves on both pages and Fleet keeps its query
  string across a version switch; the list, filters and summary are the next
  Fleet step's work.
  """

  use GtfsPlannerWeb, :live_view

  import GtfsPlannerWeb.Gtfs.OperationsComponents, only: [scope_note: 1]

  alias GtfsPlanner.Versions

  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Fleet")
     |> assign(:user_roles, socket.assigns[:user_roles] || [])
     |> assign(:fleet_query, nil)}
  end

  @impl true
  def handle_params(_params, uri, socket) do
    {:noreply, assign(socket, :fleet_query, URI.parse(uri).query)}
  end

  @impl true
  def handle_event("gtfs_version_loaded", %{"version_id" => version_id}, socket) do
    current_organization = socket.assigns.current_organization
    current_version_id = to_string(socket.assigns.current_gtfs_version.id)

    if version_id && version_id != current_version_id &&
         Versions.published_gtfs_version_for_org?(current_organization.id, version_id) do
      {:noreply, push_navigate(socket, to: fleet_path(version_id, socket.assigns.fleet_query))}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("switch_gtfs_version", %{"version" => version_id}, socket) do
    current_organization = socket.assigns.current_organization

    if Versions.published_gtfs_version_for_org?(current_organization.id, version_id) do
      socket = push_event(socket, "gtfs_version_selected", %{version_id: version_id})
      {:noreply, push_navigate(socket, to: fleet_path(version_id, socket.assigns.fleet_query))}
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
      <.header>Fleet</.header>

      <.scope_note organization_name={@current_organization.name} class="mt-2" />

      <.blocks_sub_nav gtfs_version_id={@current_gtfs_version.id} active_tab={:fleet} />
    </Layouts.app>
    """
  end

  # The Fleet query string carries its filters, so a version switch keeps it in
  # the URL instead of dropping the operator's current view.
  defp fleet_path(version_id, query) when query in [nil, ""] do
    "/gtfs/#{version_id}/blocks/fleet"
  end

  defp fleet_path(version_id, query) do
    "/gtfs/#{version_id}/blocks/fleet?#{query}"
  end
end
