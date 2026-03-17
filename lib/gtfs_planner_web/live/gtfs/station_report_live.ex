defmodule GtfsPlannerWeb.Gtfs.StationReportLive do
  @moduledoc """
  LiveView for deterministic station report metrics.
  """
  use GtfsPlannerWeb, :live_view

  import GtfsPlannerWeb.Gtfs.StationReportComponents

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.StationReport
  alias GtfsPlanner.Versions

  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  @methodology_sections [
    "data_integrity",
    "naming_conventions",
    "accessibility",
    "entrance_platform_connectivity",
    "pathway_validation",
    "levels_validation",
    "attribute_completeness"
  ]

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
     |> assign(:reversed_pairs, MapSet.new())
     |> assign(:expanded_entrances, MapSet.new())
     |> assign(:methodology_by_section, default_methodology_by_section())
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
        report = StationReport.build(snapshot)

        {:noreply,
         socket
         |> assign(:stop_id, stop_id)
         |> assign(:station, snapshot.station)
         |> assign(:report, report)
         |> assign(:reversed_pairs, MapSet.new())
         |> assign(:expanded_entrances, MapSet.new())}

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
          do: "/gtfs/#{version_id}/stops/#{stop_id}/report",
          else: "/gtfs/#{version_id}/stops"

      {:noreply, push_navigate(socket, to: path)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("toggle_methodology", %{"section_id" => section_id}, socket)
      when section_id in @methodology_sections do
    methodology_by_section =
      Map.update!(
        socket.assigns.methodology_by_section,
        section_id,
        fn methodology_mode? -> not methodology_mode? end
      )

    {:noreply, assign(socket, :methodology_by_section, methodology_by_section)}
  end

  def handle_event("toggle_methodology", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("toggle_path_direction", %{"pair_id" => pair_id}, socket) do
    reversed_pairs = socket.assigns.reversed_pairs

    next_reversed_pairs =
      if MapSet.member?(reversed_pairs, pair_id) do
        MapSet.delete(reversed_pairs, pair_id)
      else
        MapSet.put(reversed_pairs, pair_id)
      end

    {:noreply, assign(socket, :reversed_pairs, next_reversed_pairs)}
  end

  def handle_event("toggle_path_direction", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("toggle_connectivity_entrance", %{"entrance_id" => entrance_id}, socket) do
    {:noreply, toggle_mapset_assign(socket, :expanded_entrances, entrance_id)}
  end

  def handle_event("toggle_connectivity_entrance", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("select_entity", %{"entity_id" => entity_id, "entity_type" => "stop"}, socket) do
    org_id = socket.assigns.current_organization.id
    version_id = socket.assigns.current_gtfs_version.id

    case Gtfs.get_stop_by_stop_id(org_id, version_id, entity_id) do
      nil ->
        {:noreply, assign(socket, :drawer_error, "Stop not found: #{entity_id}")}

      stop ->
        form =
          to_form(%{
            "stop_name" => stop.stop_name || "",
            "stop_lat" => to_optional_string(stop.stop_lat),
            "stop_lon" => to_optional_string(stop.stop_lon),
            "level_id" => stop.level_id || "",
            "wheelchair_boarding" => to_optional_string(stop.wheelchair_boarding),
            "platform_code" => stop.platform_code || ""
          })

        {:noreply,
         socket
         |> assign(:drawer_entity, stop)
         |> assign(:drawer_type, :stop)
         |> assign(:drawer_form, form)
         |> assign(:drawer_error, nil)}
    end
  end

  def handle_event(
        "select_entity",
        %{"entity_id" => entity_id, "entity_type" => "pathway"},
        socket
      ) do
    org_id = socket.assigns.current_organization.id
    version_id = socket.assigns.current_gtfs_version.id

    case Gtfs.get_pathway_by_pathway_id(org_id, version_id, entity_id) do
      nil ->
        {:noreply, assign(socket, :drawer_error, "Pathway not found: #{entity_id}")}

      pathway ->
        form =
          to_form(%{
            "traversal_time" => to_optional_string(pathway.traversal_time),
            "length" => to_optional_string(pathway.length),
            "stair_count" => to_optional_string(pathway.stair_count),
            "max_slope" => to_optional_string(pathway.max_slope),
            "min_width" => to_optional_string(pathway.min_width),
            "is_bidirectional" => to_string(pathway.is_bidirectional),
            "signposted_as" => pathway.signposted_as || "",
            "reversed_signposted_as" => pathway.reversed_signposted_as || ""
          })

        {:noreply,
         socket
         |> assign(:drawer_entity, pathway)
         |> assign(:drawer_type, :pathway)
         |> assign(:drawer_form, form)
         |> assign(:drawer_error, nil)}
    end
  end

  def handle_event("select_entity", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("close_entity_drawer", _params, socket) do
    {:noreply,
     socket
     |> assign(:drawer_entity, nil)
     |> assign(:drawer_type, nil)
     |> assign(:drawer_form, nil)
     |> assign(:drawer_error, nil)}
  end

  @impl true
  def handle_event("save_entity", %{"stop" => stop_params}, socket) do
    stop = socket.assigns.drawer_entity

    case Gtfs.update_stop(stop, stop_params) do
      {:ok, _updated} ->
        {:noreply,
         socket
         |> assign(:drawer_entity, nil)
         |> assign(:drawer_type, nil)
         |> assign(:drawer_form, nil)
         |> assign(:drawer_error, nil)
         |> rebuild_report()}

      {:error, changeset} ->
        {:noreply, assign(socket, :drawer_form, to_form(changeset, as: :stop))}
    end
  end

  def handle_event("save_entity", %{"pathway" => pathway_params}, socket) do
    pathway = socket.assigns.drawer_entity

    case Gtfs.update_pathway(pathway, pathway_params) do
      {:ok, _updated} ->
        {:noreply,
         socket
         |> assign(:drawer_entity, nil)
         |> assign(:drawer_type, nil)
         |> assign(:drawer_form, nil)
         |> assign(:drawer_error, nil)
         |> rebuild_report()}

      {:error, changeset} ->
        {:noreply, assign(socket, :drawer_form, to_form(changeset, as: :pathway))}
    end
  end

  def handle_event("save_entity", _params, socket), do: {:noreply, socket}

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
          active_tab={:report}
        />
      </:sub_header>

      <div id="station-report" class="space-y-6">
        <%= if @report do %>
          <div
            :if={empty_station?(@report)}
            id="station-report-empty"
            class="rounded-lg border border-base-300 bg-base-100 p-4 text-base-content/70"
          >
            Station has no child stops or pathways yet. Report sections remain available for readiness tracking.
          </div>

          <.summary_strip report={@report} />

          <.integrity_section
            section={find_section(@report, "data_integrity")}
            gps_section={find_section(@report, "gps")}
            methodology_mode={Map.get(@methodology_by_section, "data_integrity", false)}
            gtfs_version_id={to_string(@current_gtfs_version.id)}
            station_stop_id={@stop_id}
          />

          <.naming_conventions_section
            section={find_section(@report, "naming_conventions")}
            gtfs_version_id={to_string(@current_gtfs_version.id)}
            station_stop_id={@stop_id}
          />

          <.entrance_platform_connectivity_section
            section={find_section(@report, "entrance_platform_connectivity")}
            methodology_mode={
              Map.get(@methodology_by_section, "entrance_platform_connectivity", false)
            }
            reversed_pairs={@reversed_pairs}
            expanded_entrances={@expanded_entrances}
          />

          <.pathway_validation_section
            section={find_section(@report, "pathway_validation")}
            gtfs_version_id={to_string(@current_gtfs_version.id)}
            station_stop_id={@stop_id}
          />

          <.levels_validation_section
            section={find_section(@report, "levels_validation")}
            gtfs_version_id={to_string(@current_gtfs_version.id)}
            station_stop_id={@stop_id}
          />

          <.accessibility_section
            section={find_section(@report, "accessibility")}
            methodology_mode={Map.get(@methodology_by_section, "accessibility", false)}
          />

          <.inventory_section section={find_section(@report, "inventory")} />

          <.completeness_section
            section={find_section(@report, "attribute_completeness")}
            methodology_mode={Map.get(@methodology_by_section, "attribute_completeness", false)}
          />

          <.unavailable_section section={find_section(@report, "not_available")} />
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

  defp find_section(report, id) do
    Enum.find(report.sections, &(&1.id == id))
  end

  defp empty_station?(%{sections: sections}) do
    inventory = Enum.find(sections, &(&1.id == "inventory"))

    case inventory do
      nil ->
        false

      %{items: items} ->
        nodes_item = Enum.find(items, &(&1.id == "node_inventory"))
        edges_item = Enum.find(items, &(&1.id == "edge_inventory"))

        node_total = map_values_sum(nodes_item && nodes_item.value)
        edge_total = map_values_sum(edges_item && edges_item.value)

        node_total <= 1 and edge_total == 0
    end
  end

  defp map_values_sum(map) when is_map(map),
    do: map |> Map.values() |> Enum.filter(&is_integer/1) |> Enum.sum()

  defp map_values_sum(_), do: 0

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

  defp default_methodology_by_section do
    %{
      "data_integrity" => false,
      "naming_conventions" => false,
      "accessibility" => false,
      "entrance_platform_connectivity" => false,
      "pathway_validation" => false,
      "levels_validation" => false,
      "attribute_completeness" => false
    }
  end

  defp toggle_mapset_assign(socket, key, value) do
    current = Map.get(socket.assigns, key, MapSet.new())

    next =
      if MapSet.member?(current, value) do
        MapSet.delete(current, value)
      else
        MapSet.put(current, value)
      end

    assign(socket, key, next)
  end

  defp rebuild_report(socket) do
    org_id = socket.assigns.current_organization.id
    version_id = socket.assigns.current_gtfs_version.id
    stop_id = socket.assigns.stop_id

    case Gtfs.get_station_report_snapshot(org_id, version_id, stop_id) do
      {:ok, snapshot} ->
        socket
        |> assign(:station, snapshot.station)
        |> assign(:report, StationReport.build(snapshot))

      {:error, _} ->
        socket
    end
  end

  defp to_optional_string(nil), do: ""
  defp to_optional_string(value), do: to_string(value)
end
