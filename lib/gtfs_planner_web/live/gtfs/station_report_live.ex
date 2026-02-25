defmodule GtfsPlannerWeb.Gtfs.StationReportLive do
  @moduledoc """
  LiveView for deterministic station report metrics.
  """
  use GtfsPlannerWeb, :live_view

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.StationReport
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

          <section
            :for={section <- @report.sections}
            id={"report-section-#{section.id}"}
            class="rounded-xl border border-base-300 bg-base-100"
          >
            <header class="border-b border-base-300 px-4 py-3">
              <h2 class="text-base font-semibold">{section.title}</h2>
            </header>

            <ul class="divide-y divide-base-300">
              <li :for={item <- section.items} id={"report-item-#{item.id}"} class="px-4 py-4">
                <div class="flex flex-wrap items-start justify-between gap-3">
                  <div>
                    <p class="font-medium">{item.label}</p>
                    <p class="text-sm text-base-content/70">Status: {status_text(item.status)}</p>
                  </div>
                  <div class="text-sm text-base-content/80">{format_value(item.value)}</div>
                </div>

                <div
                  :if={details_lines(item.details) != []}
                  id={"report-item-#{item.id}-details"}
                  class="mt-3"
                >
                  <ul class="list-disc pl-5 text-sm text-base-content/80">
                    <li
                      :for={{line, idx} <- Enum.with_index(details_lines(item.details), 1)}
                      id={"report-item-#{item.id}-detail-#{idx}"}
                    >
                      {line}
                    </li>
                  </ul>
                </div>
              </li>
            </ul>
          </section>
        <% end %>
      </div>
    </Layouts.app>
    """
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

  defp status_text(:pass), do: "pass"
  defp status_text(:fail), do: "fail"
  defp status_text(:warn), do: "warn"
  defp status_text(:info), do: "info"

  defp format_value(value) when is_map(value), do: inspect(sort_map(value), pretty: true)
  defp format_value(value) when is_list(value), do: inspect(value, pretty: true)
  defp format_value(value), do: to_string(value)

  defp details_lines(nil), do: []
  defp details_lines([]), do: []

  defp details_lines(details) when is_list(details) do
    Enum.map(details, &format_detail_line/1)
  end

  defp details_lines(details) when is_map(details) do
    details
    |> sort_map()
    |> Enum.map(fn {key, value} -> "#{key}: #{detail_value_to_string(value)}" end)
  end

  defp details_lines(details), do: [detail_value_to_string(details)]

  defp format_detail_line(value) when is_map(value) do
    value
    |> sort_map()
    |> Enum.map_join(", ", fn {key, map_value} ->
      "#{key}=#{detail_value_to_string(map_value)}"
    end)
  end

  defp format_detail_line(value), do: detail_value_to_string(value)

  defp detail_value_to_string(value) when is_map(value), do: inspect(sort_map(value))
  defp detail_value_to_string(value) when is_list(value), do: inspect(value)
  defp detail_value_to_string(value), do: to_string(value)

  defp sort_map(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
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
