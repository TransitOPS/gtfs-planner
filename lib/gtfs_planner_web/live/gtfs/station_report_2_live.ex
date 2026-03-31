defmodule GtfsPlannerWeb.Gtfs.StationReport2Live do
  @moduledoc """
  LiveView for the new station report dashboard with independent section components.
  """
  use GtfsPlannerWeb, :live_view

  import GtfsPlannerWeb.Gtfs.StationReport2Components
  import GtfsPlannerWeb.Gtfs.StationReportComponents, only: [entity_drawer: 1]

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StationReport2.{Connectivity, DataQuality, Gps, NamingConventions, PathwayFieldCompleteness}
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
     |> assign(:naming_convention_checks, [])
     |> assign(:pathway_field_completeness_groups, [])
     |> assign(:connectivity_summaries, nil)
     |> assign(:connectivity_view, :summary)
     |> assign(:connectivity_dimension, :entrance_to_platform)
     |> assign(:route_detail_groups, [])
     |> assign(:expanded_routes, %{})
     |> assign(:drawer_entity, nil)
     |> assign(:drawer_type, nil)
     |> assign(:drawer_form, nil)
     |> assign(:drawer_error, nil)}
  end

  @impl true
  def handle_params(%{"stop_id" => stop_id} = params, _uri, socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    case Gtfs.get_station_report_snapshot(organization_id, gtfs_version_id, stop_id) do
      {:ok, snapshot} ->
        connectivity_summaries = Connectivity.build_summaries(snapshot)
        dimension = parse_dimension(params["dimension"])

        {connectivity_view, route_detail_groups} =
          if params["connectivity"] == "detail" do
            {:detail, Connectivity.build_route_detail(snapshot, dimension)}
          else
            {:summary, []}
          end

        {:noreply,
         socket
         |> assign(:stop_id, stop_id)
         |> assign(:station, snapshot.station)
         |> assign(:report, snapshot)
         |> assign(:data_quality_items, DataQuality.build(snapshot))
         |> assign(:gps_items, Gps.build(snapshot))
         |> assign(:naming_convention_checks, NamingConventions.build(snapshot))
         |> assign(:pathway_field_completeness_groups, PathwayFieldCompleteness.build(snapshot))
         |> assign(:connectivity_summaries, connectivity_summaries)
         |> assign(:connectivity_view, connectivity_view)
         |> assign(:connectivity_dimension, dimension)
         |> assign(:route_detail_groups, route_detail_groups)
         |> assign(:expanded_routes, %{})
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
  def handle_event("navigate_connectivity_detail", %{"dimension" => dimension}, socket) do
    version_id = socket.assigns.current_gtfs_version.id
    stop_id = socket.assigns.stop_id

    {:noreply,
     push_patch(socket,
       to: "/gtfs/#{version_id}/stops/#{stop_id}/report_2?connectivity=detail&dimension=#{dimension}"
     )}
  end

  @impl true
  def handle_event("navigate_connectivity_summary", _params, socket) do
    version_id = socket.assigns.current_gtfs_version.id
    stop_id = socket.assigns.stop_id

    {:noreply,
     push_patch(socket, to: "/gtfs/#{version_id}/stops/#{stop_id}/report_2")}
  end

  @impl true
  def handle_event(
        "toggle_route_expand",
        %{"source_id" => source_id, "target_id" => target_id},
        socket
      ) do
    key = {source_id, target_id}
    expanded_routes = socket.assigns.expanded_routes

    if Map.has_key?(expanded_routes, key) do
      {:noreply, assign(socket, :expanded_routes, Map.delete(expanded_routes, key))}
    else
      snapshot = socket.assigns.report
      route = Connectivity.build_expanded_route(snapshot, source_id, target_id)

      {:noreply, assign(socket, :expanded_routes, Map.put(expanded_routes, key, route))}
    end
  end

  @impl true
  def handle_event("expand_all_routes", _params, socket) do
    snapshot = socket.assigns.report
    groups = socket.assigns.route_detail_groups

    expanded_routes =
      for group <- groups,
          target <- group.targets,
          reduce: socket.assigns.expanded_routes do
        acc ->
          key = {group.source.stop_id, target.stop_id}

          if Map.has_key?(acc, key) do
            acc
          else
            route = Connectivity.build_expanded_route(snapshot, group.source.stop_id, target.stop_id)
            Map.put(acc, key, route)
          end
      end

    {:noreply, assign(socket, :expanded_routes, expanded_routes)}
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

      <div class="hidden print:block print:font-bold print:text-2xl print:leading-[1.3] print:text-gray-900 print:mb-8 print:font-[Inter,ui-sans-serif,system-ui,sans-serif]">
        <div>Pathways Report:</div>
        <div :if={@station}>{@station.stop_name || @station.stop_id}</div>
      </div>

      <div id="station-report-2" class="space-y-6">
        <%= if @report do %>
          <.report_toc station_name={@station.stop_name || @station.stop_id}>
            <button
              id="expand-all-btn"
              type="button"
              class="print:hidden inline-flex items-center gap-1.5 px-3 py-1.5 text-xs font-medium text-gray-600 bg-white border border-gray-300 rounded hover:bg-gray-50 transition-colors cursor-pointer"
              phx-hook=".ExpandAll"
            >
              <svg class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
                <path d="M4 8V4m0 0h4M4 4l5 5M20 8V4m0 0h-4m4 0l-5 5M4 16v4m0 0h4m-4 0l5-5M20 16v4m0 0h-4m4 0l-5-5" />
              </svg>
              Expand all
            </button>
            <script :type={Phoenix.LiveView.ColocatedHook} name=".ExpandAll">
              export default {
                mounted() {
                  this.el.addEventListener("click", () => {
                    const container = document.getElementById("station-report-2")
                    if (!container) return
                    container.querySelectorAll("details:not([open])").forEach(d => d.open = true)
                    this.pushEvent("expand_all_routes", {})
                  })
                }
              }
            </script>
          </.report_toc>
          <.station_inventory_section report={@report} />
          <.data_quality_section items={@data_quality_items} />
          <.gps_checks_section items={@gps_items} />
          <.naming_conventions_section checks={@naming_convention_checks} />
          <.reachability_connectivity_section
            report={@report}
            connectivity_summaries={@connectivity_summaries}
            connectivity_view={@connectivity_view}
            connectivity_dimension={@connectivity_dimension}
            route_detail_groups={@route_detail_groups}
            expanded_routes={@expanded_routes}
          />
          <.pathway_field_completeness_section groups={@pathway_field_completeness_groups} />
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
        |> assign(:naming_convention_checks, NamingConventions.build(snapshot))
        |> assign(:pathway_field_completeness_groups, PathwayFieldCompleteness.build(snapshot))
        |> assign(:connectivity_summaries, Connectivity.build_summaries(snapshot))

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

  defp parse_dimension("entrance_to_platform"), do: :entrance_to_platform
  defp parse_dimension("platform_to_exit"), do: :platform_to_exit
  defp parse_dimension("platform_to_platform"), do: :platform_to_platform
  defp parse_dimension(_), do: :entrance_to_platform
end
