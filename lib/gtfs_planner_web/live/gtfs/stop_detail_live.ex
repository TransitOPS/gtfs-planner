defmodule GtfsPlannerWeb.Gtfs.StopDetailLive do
  @moduledoc """
  LiveView for viewing GTFS station (stop) details.
  Requires pathways_studio_editor role.
  """
  use GtfsPlannerWeb, :live_view
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.{Stop, Pathway}
  alias GtfsPlanner.Versions
  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  @impl true
  def mount(_params, _session, socket) do
    user_roles = socket.assigns[:user_roles] || []

    {:ok,
     socket
     |> assign(:page_title, "Station Details")
     |> assign(:user_roles, user_roles)}
  end

  @impl true
  def handle_params(%{"stop_id" => stop_id} = _params, _uri, socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    case GtfsPlanner.Gtfs.get_stop_by_stop_id(organization_id, gtfs_version_id, stop_id) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "Station not found")
         |> push_navigate(to: "/gtfs/#{gtfs_version_id}/stops")}

      stop ->
        child_stops =
          Gtfs.list_child_stops_for_parent(organization_id, gtfs_version_id, stop.id)

        levels = Gtfs.list_levels_for_station(organization_id, gtfs_version_id, stop.id)
        pathways = Gtfs.list_pathways_for_station(organization_id, gtfs_version_id, stop.id)

        station_editing_status =
          Gtfs.get_station_editing_status(organization_id, gtfs_version_id, stop.id)

        if connected?(socket) do
          :ok =
            Gtfs.subscribe_station_editing_status(organization_id, gtfs_version_id, stop.id)
        end

        # Group child stops by level. nil key means "No Level".
        child_stops_by_level =
          Enum.group_by(child_stops, fn s ->
            case s.level do
              nil -> nil
              level -> level.level_name || level.level_id
            end
          end)

        {:noreply,
         socket
         |> assign(:stop_id, stop_id)
         |> assign(:stop, stop)
         |> assign(:child_stops, child_stops)
         |> assign(:child_stops_by_level, child_stops_by_level)
         |> assign(:levels, levels)
         |> assign(:pathways, pathways)
         |> assign(:station_editing_status, station_editing_status)}
    end
  end

  @impl true
  def handle_info({:station_editing_status_updated, status}, socket) do
    {:noreply, assign(socket, :station_editing_status, status)}
  end

  @impl true
  def handle_event("set_station_editing_status", _params, socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    case Gtfs.set_station_editing_status(
           organization_id,
           gtfs_version_id,
           socket.assigns.stop,
           socket.assigns.current_user
         ) do
      {:ok, status} ->
        {:noreply, assign(socket, :station_editing_status, status)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to set station editing status")}
    end
  end

  @impl true
  def handle_event("clear_station_editing_status", _params, socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    :ok =
      Gtfs.clear_station_editing_status(
        organization_id,
        gtfs_version_id,
        socket.assigns.stop.id
      )

    {:noreply, assign(socket, :station_editing_status, nil)}
  end

  @impl true
  def handle_event("gtfs_version_loaded", %{"version_id" => version_id}, socket) do
    current_organization = socket.assigns.current_organization
    current_version_id = to_string(socket.assigns.current_gtfs_version.id)
    stop_id = socket.assigns[:stop_id]

    if version_id && version_id != current_version_id &&
         valid_version_for_org?(version_id, current_organization.id) do
      path =
        if stop_id, do: "/gtfs/#{version_id}/stops/#{stop_id}", else: "/gtfs/#{version_id}/stops"

      {:noreply, push_navigate(socket, to: path)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("switch_gtfs_version", %{"version" => version_id}, socket) do
    stop_id = socket.assigns[:stop_id]

    # Push event to JS hook to update localStorage
    socket = push_event(socket, "gtfs_version_selected", %{version_id: version_id})

    # Navigate to new version
    path =
      if stop_id, do: "/gtfs/#{version_id}/stops/#{stop_id}", else: "/gtfs/#{version_id}/stops"

    {:noreply, push_navigate(socket, to: path)}
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
          station={@stop}
          gtfs_version_id={@current_gtfs_version.id}
          active_tab={:details}
        >
          <:actions>
            <.button
              id="station-editing-status-button"
              phx-click={editing_status_button_event(@station_editing_status, @current_user)}
              title={editing_status_tooltip(@station_editing_status, @current_user)}
              variant="secondary"
              size="sm"
            >
              {editing_status_button_label(@station_editing_status, @current_user)}
            </.button>
          </:actions>
        </.station_sub_nav>
      </:sub_header>

      <div class="bg-base-100 border border-base-300 rounded-lg p-6">
        <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
          <div>
            <h3 class="text-sm font-medium text-base-content/60">Station ID</h3>
            <p class="mt-1 text-base">{@stop.stop_id}</p>
          </div>

          <div>
            <h3 class="text-sm font-medium text-base-content/60">Station Name</h3>
            <p class="mt-1 text-base">{@stop.stop_name || ""}</p>
          </div>

          <div>
            <h3 class="text-sm font-medium text-base-content/60">Location Type</h3>
            <p class="mt-1 text-base">{@stop.location_type || ""}</p>
          </div>

          <div>
            <h3 class="text-sm font-medium text-base-content/60">Description</h3>
            <p class="mt-1 text-base">{@stop.stop_desc || ""}</p>
          </div>

          <div>
            <h3 class="text-sm font-medium text-base-content/60">Latitude</h3>
            <p class="mt-1 text-base">{@stop.stop_lat || ""}</p>
          </div>

          <div>
            <h3 class="text-sm font-medium text-base-content/60">Longitude</h3>
            <p class="mt-1 text-base">{@stop.stop_lon || ""}</p>
          </div>

          <div>
            <h3 class="text-sm font-medium text-base-content/60">Level ID</h3>
            <p class="mt-1 text-base">{@stop.level_id || ""}</p>
          </div>

          <div>
            <h3 class="text-sm font-medium text-base-content/60">Platform Code</h3>
            <p class="mt-1 text-base">{@stop.platform_code || ""}</p>
          </div>
        </div>
      </div>

      <div class="mt-8">
        <h2 class="text-lg font-semibold mb-4">Child Stops</h2>
        <%= if @child_stops == [] do %>
          <div class="bg-base-100 border border-base-300 rounded-lg p-6 text-center text-base-content/60">
            No child stops
          </div>
        <% else %>
          <div class="space-y-4">
            <%= for {level_name, stops} <- @child_stops_by_level do %>
              <div class="bg-base-100 border border-base-300 rounded-lg overflow-hidden">
                <div class="bg-base-200 px-4 py-2 font-medium flex justify-between">
                  <span>{level_name || "No Level"}</span>
                  <span class="badge badge-ghost">{length(stops)}</span>
                </div>
                <ul class="divide-y divide-base-300">
                  <%= for stop <- stops do %>
                    <li id={"child-stop-row-#{stop.id}"} class="px-4 py-3 flex justify-between">
                      <div>
                        <span class="font-medium">{stop.stop_name || stop.stop_id}</span>
                        <span class="text-sm text-base-content/60 ml-2">{stop.stop_id}</span>
                      </div>
                      <div class="flex items-center gap-3">
                        <%= if is_nil(level_name) do %>
                          <.link
                            navigate={
                              "/gtfs/#{@current_gtfs_version.id}/stops/#{@stop.stop_id}/diagram?edit_child_stop_id=#{stop.id}"
                            }
                            class="link link-primary text-sm"
                          >
                            Edit in Diagram
                          </.link>
                        <% end %>
                        <span class="badge badge-outline">
                          {Stop.location_type_label(stop.location_type)}
                        </span>
                      </div>
                    </li>
                  <% end %>
                </ul>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>

      <div class="mt-8">
        <h2 class="text-lg font-semibold mb-4">Levels</h2>
        <%= if @levels == [] do %>
          <div class="bg-base-100 border border-base-300 rounded-lg p-6 text-center text-base-content/60">
            No levels
          </div>
        <% else %>
          <div class="bg-base-100 border border-base-300 rounded-lg overflow-hidden">
            <table class="table">
              <thead>
                <tr>
                  <th>Level ID</th>
                  <th>Name</th>
                  <th>Index</th>
                  <th>Stops</th>
                  <th>Diagram</th>
                </tr>
              </thead>
              <tbody>
                <%= for %{level: level, stop_count: count, diagram_filename: filename} <- @levels do %>
                  <tr>
                    <td>{level.level_id}</td>
                    <td>{level.level_name || ""}</td>
                    <td>{level.level_index}</td>
                    <td><span class="badge badge-ghost">{count}</span></td>
                    <td>
                      <%= if filename do %>
                        <span class="text-success">
                          <.icon name="hero-check-circle" class="w-5 h-5" />
                        </span>
                      <% else %>
                        <span class="text-base-content/30">-</span>
                      <% end %>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        <% end %>
      </div>

      <div class="mt-8">
        <h2 class="text-lg font-semibold mb-4">Pathways</h2>
        <%= if @pathways == [] do %>
          <div class="bg-base-100 border border-base-300 rounded-lg p-6 text-center text-base-content/60">
            No pathways
          </div>
        <% else %>
          <div class="bg-base-100 border border-base-300 rounded-lg overflow-hidden">
            <table class="table">
              <thead>
                <tr>
                  <th>Pathway ID</th>
                  <th>From</th>
                  <th>To</th>
                  <th>Mode</th>
                  <th>Time</th>
                </tr>
              </thead>
              <tbody>
                <%= for pathway <- @pathways do %>
                  <tr>
                    <td>{pathway.pathway_id}</td>
                    <td>{pathway.from_stop_id}</td>
                    <td>{pathway.to_stop_id}</td>
                    <td>
                      <span class="badge badge-outline">
                        {Pathway.mode_label(pathway.pathway_mode)}
                      </span>
                    </td>
                    <td>
                      {if pathway.traversal_time, do: "#{pathway.traversal_time}s", else: "-"}
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
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
      _ -> false
    end
  end

  defp editing_status_owner?(nil, _current_user), do: false

  defp editing_status_owner?(editing_status, current_user) do
    editing_status.user_id == current_user.id
  end

  defp editing_status_button_label(nil, _current_user), do: "I'm editing this Station"

  defp editing_status_button_label(editing_status, current_user) do
    if editing_status_owner?(editing_status, current_user) do
      "I'm done"
    else
      "Clear editing status"
    end
  end

  defp editing_status_button_event(nil, _current_user), do: "set_station_editing_status"

  defp editing_status_button_event(_editing_status, _current_user),
    do: "clear_station_editing_status"

  defp editing_status_tooltip(nil, _current_user),
    do: "Let others know you're editing this Station."

  defp editing_status_tooltip(editing_status, current_user) do
    if editing_status_owner?(editing_status, current_user) do
      "Let others know you're done editing this Station."
    else
      "Clear this editing status for everyone."
    end
  end
end
