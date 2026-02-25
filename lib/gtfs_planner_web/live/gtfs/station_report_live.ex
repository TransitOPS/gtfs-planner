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
  @methodology_sections ["data_integrity", "accessibility", "attribute_completeness"]

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
     |> assign(:methodology_by_section, default_methodology_by_section())}
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
         |> assign(:report, report)}

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
      "accessibility" => false,
      "attribute_completeness" => false
    }
  end
end
