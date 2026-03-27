defmodule GtfsPlannerWeb.Gtfs.StationReport2Live do
  @moduledoc """
  LiveView for the new station report dashboard with independent section components.
  """
  use GtfsPlannerWeb, :live_view

  import GtfsPlannerWeb.Gtfs.StationReport2Components
  import GtfsPlannerWeb.Gtfs.StationReportComponents, only: [entity_drawer: 1]

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StationReport2.{DataQuality, Gps}
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
     |> assign(:stop_id, nil)
     |> assign(:data_quality_items, [])
     |> assign(:gps_items, [])
     |> assign(:drawer_entity, nil)
     |> assign(:drawer_type, nil)
     |> assign(:drawer_form, nil)
     |> assign(:drawer_error, nil)}
  end

  @impl true
  def handle_params(%{"stop_id" => stop_id}, _uri, socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    case Gtfs.get_station_report_snapshot(organization_id, gtfs_version_id, stop_id) do
      {:ok, snapshot} ->
        data_quality_items = DataQuality.build(snapshot)
        gps_items = Gps.build(snapshot)

        {:noreply,
         socket
         |> assign(:stop_id, stop_id)
         |> assign(:station, snapshot.station)
         |> assign(:report, snapshot)
         |> assign(:data_quality_items, data_quality_items)
         |> assign(:gps_items, gps_items)
         |> reset_drawer()}

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
  def handle_event("select_entity", %{"entity_id" => entity_id, "entity_type" => "stop"}, socket) do
    org_id = socket.assigns.current_organization.id
    version_id = socket.assigns.current_gtfs_version.id

    case Gtfs.get_stop_by_stop_id(org_id, version_id, entity_id) do
      nil ->
        {:noreply, assign_drawer_error(socket, :stop, "Stop not found: #{entity_id}")}

      stop ->
        form =
          to_form(
            %{
              "stop_name" => stop.stop_name || "",
              "stop_lat" => to_optional_string(stop.stop_lat),
              "stop_lon" => to_optional_string(stop.stop_lon),
              "level_id" => stop.level_id || "",
              "wheelchair_boarding" => to_optional_string(stop.wheelchair_boarding),
              "platform_code" => stop.platform_code || ""
            },
            as: :stop
          )

        {:noreply,
         socket
         |> assign(:drawer_entity, stop)
         |> assign(:drawer_type, :stop)
         |> assign(:drawer_form, form)
         |> assign(:drawer_error, nil)}
    end
  end

  @impl true
  def handle_event("select_entity", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("close_entity_drawer", _params, socket) do
    {:noreply, reset_drawer(socket)}
  end

  @impl true
  def handle_event("save_entity", %{"stop" => stop_params}, socket) do
    case {socket.assigns.drawer_type, socket.assigns.drawer_entity} do
      {:stop, %Stop{} = stop} ->
        case Gtfs.update_stop(stop, stop_params) do
          {:ok, _updated} ->
            {:noreply,
             socket
             |> reset_drawer()
             |> rebuild_report()}

          {:error, changeset} ->
            {:noreply,
             socket
             |> assign(:drawer_form, to_form(changeset, as: :stop))
             |> assign(:drawer_error, nil)}
        end

      _ ->
        {:noreply, assign_drawer_error(socket, :stop, "Stop is no longer available for editing")}
    end
  end

  @impl true
  def handle_event("save_entity", _params, socket) do
    {:noreply, socket}
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
          <.data_quality_section items={@data_quality_items} />
          <.gps_checks_section items={@gps_items} />
          <.naming_conventions_section report={@report} />
          <.reachability_connectivity_section report={@report} />
          <.pathway_field_completeness_section report={@report} />
          <.accessibility_section report={@report} />
        <% end %>
      </div>

      <.entity_drawer
        drawer_entity={@drawer_entity}
        drawer_type={@drawer_type}
        drawer_form={@drawer_form}
        drawer_error={@drawer_error}
      />
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

  defp rebuild_report(socket) do
    org_id = socket.assigns.current_organization.id
    version_id = socket.assigns.current_gtfs_version.id
    stop_id = socket.assigns.stop_id

    case Gtfs.get_station_report_snapshot(org_id, version_id, stop_id) do
      {:ok, snapshot} ->
        socket
        |> assign(:station, snapshot.station)
        |> assign(:report, snapshot)
        |> assign(:data_quality_items, DataQuality.build(snapshot))
        |> assign(:gps_items, Gps.build(snapshot))

      {:error, _} ->
        socket
    end
  end

  defp reset_drawer(socket) do
    socket
    |> assign(:drawer_entity, nil)
    |> assign(:drawer_type, nil)
    |> assign(:drawer_form, nil)
    |> assign(:drawer_error, nil)
  end

  defp assign_drawer_error(socket, drawer_type, message) do
    socket
    |> assign(:drawer_entity, nil)
    |> assign(:drawer_type, drawer_type)
    |> assign(:drawer_form, nil)
    |> assign(:drawer_error, message)
  end

  defp to_optional_string(nil), do: ""
  defp to_optional_string(value), do: to_string(value)
end
