defmodule GtfsPlannerWeb.Gtfs.StationReport2Live do
  @moduledoc """
  LiveView for the new station report dashboard with independent section components.
  """
  use GtfsPlannerWeb, :live_view

  import GtfsPlannerWeb.Gtfs.StationReport2Components

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Versions

  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  @impl true
  def mount(_params, _session, socket) do
    user_roles = socket.assigns[:user_roles] || []

    {:ok,
     socket
     |> assign(:page_title, "Station Report")
     |> assign(:user_roles, user_roles)
     |> assign(:station, nil)
     |> assign(:report, nil)
     |> assign(:stop_id, nil)}
  end

  @impl true
  def handle_params(%{"stop_id" => stop_id}, _uri, socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    case Gtfs.get_station_report_snapshot(organization_id, gtfs_version_id, stop_id) do
      {:ok, snapshot} ->
        {:noreply,
         socket
         |> assign(:stop_id, stop_id)
         |> assign(:station, snapshot.station)
         |> assign(:report, snapshot)}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "Station not found")
         |> push_navigate(to: "/gtfs/#{gtfs_version_id}/stops")}
    end
  end

  @impl true
  def handle_event("gtfs_version_loaded", %{"version_id" => version_id}, socket) do
    current_organization = socket.assigns.current_organization
    current_version_id = to_string(socket.assigns.current_gtfs_version.id)
    stop_id = socket.assigns[:stop_id]

    if version_id && version_id != current_version_id &&
         valid_version_for_org?(version_id, current_organization.id) do
      path =
        if stop_id,
          do: "/gtfs/#{version_id}/stops/#{stop_id}/report_2",
          else: "/gtfs/#{version_id}/stops"

      {:noreply, push_navigate(socket, to: path)}
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
        <.station_sub_nav
          :if={@station}
          station={@station}
          gtfs_version_id={@current_gtfs_version.id}
          active_tab={:report_2}
        />
      </:sub_header>

      <div id="station-report-2" class="space-y-6">
        <%= if @report do %>
          <.station_inventory_section report={@report} />
          <.data_quality_section report={@report} />
          <.gps_checks_section report={@report} />
          <.naming_conventions_section report={@report} />
          <.reachability_connectivity_section report={@report} />
          <.pathway_field_completeness_section report={@report} />
          <.accessibility_section report={@report} />
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  defp valid_version_for_org?(version_id, organization_id) do
    try do
      case Versions.get_gtfs_version(version_id) do
        nil -> false
        version -> version.organization_id == organization_id
      end
    rescue
      Ecto.Query.CastError -> false
    end
  end
end
