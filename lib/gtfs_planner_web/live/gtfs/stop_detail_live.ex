defmodule GtfsPlannerWeb.Gtfs.StopDetailLive do
  @moduledoc """
  LiveView for viewing GTFS station (stop) details.
  Requires pathways_studio_editor role.
  """
  use GtfsPlannerWeb, :live_view
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.Components.TransitPresentation
  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  @impl true
  def mount(_params, _session, socket) do
    user_roles = socket.assigns[:user_roles] || []

    {:ok,
     socket
     |> assign(:page_title, "Station Details")
     |> assign(:user_roles, user_roles)
     |> assign(:stop_state, :loading)
     |> assign(:child_stops_state, :ready)
     |> assign(:levels_state, :ready)
     |> assign(:pathways_state, :ready)
     |> assign(:editing_status_state, :ready)
     |> assign(:editing_error, nil)
     |> assign(:child_stops_empty?, true)
     |> assign(:levels_empty?, true)
     |> assign(:pathways_empty?, true)
     |> stream(:child_stops, [])
     |> stream_configure(:levels, dom_id: fn %{level: level} -> "level-#{level.level_id}" end)
     |> stream(:levels, [])
     |> stream(:pathways, [])}
  end

  @impl true
  def handle_params(%{"stop_id" => stop_id} = _params, _uri, socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    socket = assign(socket, :stop_id, stop_id)

    case Gtfs.fetch_catalog_stop(organization_id, gtfs_version_id, stop_id) do
      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "Station not found")
         |> push_navigate(to: "/gtfs/#{gtfs_version_id}/stops")}

      {:error, :unavailable} ->
        {:noreply, assign(socket, :stop_state, :unavailable)}

      {:ok, stop} ->
        socket =
          socket
          |> assign(:stop, stop)
          |> assign(:stop_state, :ready)

        socket = load_regions(socket)

        {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:station_editing_status_updated, status}, socket) do
    {:noreply,
     socket
     |> assign(:station_editing_status, status)
     |> assign(:editing_status_state, :ready)
     |> assign(:editing_error, nil)}
  end

  @impl true
  def handle_event("retry", _params, socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id
    stop_id = socket.assigns.stop_id

    case Gtfs.fetch_catalog_stop(organization_id, gtfs_version_id, stop_id) do
      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "Station not found")
         |> push_navigate(to: "/gtfs/#{gtfs_version_id}/stops")}

      {:error, :unavailable} ->
        {:noreply, assign(socket, :stop_state, :unavailable)}

      {:ok, stop} ->
        socket =
          socket
          |> assign(:stop, stop)
          |> assign(:stop_state, :ready)

        socket = load_regions(socket)

        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("retry_child_stops", _params, socket) do
    {:noreply, load_child_stops_region(socket)}
  end

  @impl true
  def handle_event("retry_levels", _params, socket) do
    {:noreply, load_levels_region(socket)}
  end

  @impl true
  def handle_event("retry_pathways", _params, socket) do
    {:noreply, load_pathways_region(socket)}
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
        {:noreply,
         socket
         |> assign(:station_editing_status, status)
         |> assign(:editing_error, nil)}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> assign(:editing_error, "Failed to set station editing status")}
    end
  end

  @impl true
  def handle_event("clear_station_editing_status", _params, socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    case Gtfs.clear_station_editing_status(
           organization_id,
           gtfs_version_id,
           socket.assigns.stop.id
         ) do
      :ok ->
        {:noreply,
         socket
         |> assign(:station_editing_status, nil)
         |> assign(:editing_error, nil)}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:editing_error, "Failed to clear station editing status")}
    end
  end

  @impl true
  def handle_event("gtfs_version_loaded", %{"version_id" => version_id}, socket) do
    current_organization = socket.assigns.current_organization
    current_version_id = to_string(socket.assigns.current_gtfs_version.id)
    stop_id = socket.assigns[:stop_id]

    if version_id && version_id != current_version_id &&
         Versions.published_gtfs_version_for_org?(current_organization.id, version_id) do
      path =
        if stop_id, do: "/gtfs/#{version_id}/stops/#{stop_id}", else: "/gtfs/#{version_id}/stops"

      {:noreply, push_navigate(socket, to: path)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("switch_gtfs_version", %{"version" => version_id}, socket) do
    current_organization = socket.assigns.current_organization
    stop_id = socket.assigns[:stop_id]

    if Versions.published_gtfs_version_for_org?(current_organization.id, version_id) do
      socket = push_event(socket, "gtfs_version_selected", %{version_id: version_id})

      path =
        if stop_id, do: "/gtfs/#{version_id}/stops/#{stop_id}", else: "/gtfs/#{version_id}/stops"

      {:noreply, push_navigate(socket, to: path)}
    else
      {:noreply, socket}
    end
  end

  defp load_regions(socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id
    stop = socket.assigns.stop

    if connected?(socket) do
      :ok = Gtfs.subscribe_station_editing_status(organization_id, gtfs_version_id, stop.id)
    end

    regions = Gtfs.load_catalog_stop_regions(organization_id, gtfs_version_id, stop)

    socket
    |> apply_child_stops_region(regions.child_stops)
    |> apply_levels_region(regions.levels)
    |> apply_pathways_region(regions.pathways)
    |> apply_editing_status_region(regions.editing_status)
  end

  defp load_child_stops_region(socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id
    stop = socket.assigns.stop

    regions = Gtfs.load_catalog_stop_regions(organization_id, gtfs_version_id, stop)
    apply_child_stops_region(socket, regions.child_stops)
  end

  defp load_levels_region(socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id
    stop = socket.assigns.stop

    regions = Gtfs.load_catalog_stop_regions(organization_id, gtfs_version_id, stop)
    apply_levels_region(socket, regions.levels)
  end

  defp load_pathways_region(socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id
    stop = socket.assigns.stop

    regions = Gtfs.load_catalog_stop_regions(organization_id, gtfs_version_id, stop)
    apply_pathways_region(socket, regions.pathways)
  end

  defp apply_child_stops_region(socket, {:ok, child_stops}) do
    child_stops_by_level =
      Enum.group_by(child_stops, fn s ->
        case s.level do
          nil -> nil
          level -> level.level_name || level.level_id
        end
      end)

    socket
    |> assign(:child_stops_state, :ready)
    |> assign(:child_stops_by_level, child_stops_by_level)
    |> assign(:child_stops_empty?, child_stops == [])
    |> stream(:child_stops, child_stops, reset: true)
  end

  defp apply_child_stops_region(socket, {:error, :unavailable}) do
    assign(socket, :child_stops_state, :unavailable)
  end

  defp apply_levels_region(socket, {:ok, levels}) do
    socket
    |> assign(:levels_state, :ready)
    |> assign(:levels_empty?, levels == [])
    |> stream(:levels, levels, reset: true)
  end

  defp apply_levels_region(socket, {:error, :unavailable}) do
    assign(socket, :levels_state, :unavailable)
  end

  defp apply_pathways_region(socket, {:ok, pathways}) do
    socket
    |> assign(:pathways_state, :ready)
    |> assign(:pathways_empty?, pathways == [])
    |> stream(:pathways, pathways, reset: true)
  end

  defp apply_pathways_region(socket, {:error, :unavailable}) do
    assign(socket, :pathways_state, :unavailable)
  end

  defp apply_editing_status_region(socket, {:ok, status}) do
    socket
    |> assign(:editing_status_state, :ready)
    |> assign(:station_editing_status, status)
  end

  defp apply_editing_status_region(socket, {:error, :unavailable}) do
    assign(socket, :editing_status_state, :unavailable)
  end

  defp editing_status_owner?(nil, _current_user), do: false

  defp editing_status_owner?(editing_status, current_user) do
    editing_status.user_id == current_user.id
  end

  defp editing_status_button_label(nil, _current_user), do: "Start editing"

  defp editing_status_button_label(editing_status, current_user) do
    if editing_status_owner?(editing_status, current_user) do
      "Finish editing"
    else
      "Clear editing status"
    end
  end

  defp editing_status_button_event(nil, _current_user), do: "set_station_editing_status"

  defp editing_status_button_event(editing_status, current_user) do
    if editing_status_owner?(editing_status, current_user) do
      "clear_station_editing_status"
    else
      "clear_station_editing_status"
    end
  end

  defp editing_status_button_disable_with(nil, _current_user), do: "Starting..."

  defp editing_status_button_disable_with(editing_status, current_user) do
    if editing_status_owner?(editing_status, current_user) do
      "Finishing..."
    else
      "Clearing..."
    end
  end

  defp editing_status_tooltip(nil, _current_user),
    do: "Let others know you're editing this Station."

  defp editing_status_tooltip(editing_status, current_user) do
    if editing_status_owner?(editing_status, current_user) do
      "Let others know you're done editing this Station."
    else
      "Clear this editing status for everyone."
    end
  end

  defp relative_started_at(%DateTime{} = started_at) do
    minutes =
      DateTime.utc_now()
      |> DateTime.diff(started_at, :second)
      |> max(0)
      |> div(60)

    cond do
      minutes == 0 -> "just now"
      minutes == 1 -> "1 minute ago"
      minutes < 60 -> "#{minutes} minutes ago"
      minutes < 120 -> "1 hour ago"
      true -> "#{div(minutes, 60)} hours ago"
    end
  end

  defp diagram_status_text(nil), do: "No diagram"
  defp diagram_status_text(_), do: "Available"

  defp accessibility_resolution(stop) do
    Stop.resolve_wheelchair_boarding(stop, nil)
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
      <:sub_header :if={@stop_state == :ready}>
        <%= if @station_editing_status do %>
          <div class="w-full px-4 sm:px-6 lg:px-8 pt-3">
            <.callout
              kind="info"
              id="station-editing-status-banner"
              role="status"
              title={
                if editing_status_owner?(@station_editing_status, @current_user),
                  do: "You're editing this Station.",
                  else: "#{@station_editing_status.user.email} is editing this Station."
              }
            >
              <p>
                <%= if editing_status_owner?(@station_editing_status, @current_user) do %>
                  Others have been notified. Remember to clear this when you're done.
                <% else %>
                  You can view it, but it's best to wait before making changes.
                <% end %>
              </p>
              <p class="mt-1 text-xs font-medium text-base-content/60">
                Started {relative_started_at(@station_editing_status.started_at)}
              </p>
            </.callout>
          </div>
        <% end %>

        <.station_sub_nav
          station={@stop}
          gtfs_version_id={@current_gtfs_version.id}
          active_tab={:details}
        >
          <:actions>
            <.button
              id="station-editing-status-button"
              phx-click={editing_status_button_event(@station_editing_status, @current_user)}
              phx-disable-with={
                editing_status_button_disable_with(@station_editing_status, @current_user)
              }
              title={editing_status_tooltip(@station_editing_status, @current_user)}
              variant="secondary"
              size="sm"
              class="min-h-11"
            >
              {editing_status_button_label(@station_editing_status, @current_user)}
            </.button>
          </:actions>
        </.station_sub_nav>
      </:sub_header>

      <%= case @stop_state do %>
        <% :unavailable -> %>
          <div class="mt-8">
            <.callout kind="error" title="Station data unavailable" id="stop-unavailable">
              We could not load this station. Please try again.
              <button
                id="stop-retry"
                phx-click="retry"
                class="btn btn-sm btn-outline mt-2"
              >
                Retry
              </button>
            </.callout>
          </div>
        <% :ready -> %>
          <%= if @editing_error do %>
            <div class="mt-4">
              <.callout kind="error" title={@editing_error} id="editing-error">
                Please try again.
                <button
                  id="editing-error-retry"
                  phx-click={editing_status_button_event(@station_editing_status, @current_user)}
                  class="btn btn-sm btn-outline mt-2"
                >
                  Retry
                </button>
              </.callout>
            </div>
          <% end %>

          <div class="bg-base-100 border border-base-300 rounded-lg p-6 mt-8">
            <dl class="grid grid-cols-1 md:grid-cols-2 gap-6">
              <div>
                <dt class="text-sm font-medium text-base-content/60">Station ID</dt>
                <dd class="mt-1 text-base font-mono">{@stop.stop_id}</dd>
              </div>

              <div>
                <dt class="text-sm font-medium text-base-content/60">Station Name</dt>
                <dd class="mt-1 text-base">{@stop.stop_name || "—"}</dd>
              </div>

              <div>
                <dt class="text-sm font-medium text-base-content/60">Location Type</dt>
                <dd class="mt-1 text-base">{Stop.location_type_label(@stop.location_type)}</dd>
              </div>

              <div>
                <dt class="text-sm font-medium text-base-content/60">Description</dt>
                <dd class="mt-1 text-base">{@stop.stop_desc || "—"}</dd>
              </div>

              <div>
                <dt class="text-sm font-medium text-base-content/60">Latitude</dt>
                <dd class="mt-1 text-base">{@stop.stop_lat || "—"}</dd>
              </div>

              <div>
                <dt class="text-sm font-medium text-base-content/60">Longitude</dt>
                <dd class="mt-1 text-base">{@stop.stop_lon || "—"}</dd>
              </div>

              <div>
                <dt class="text-sm font-medium text-base-content/60">Level ID</dt>
                <dd class="mt-1 text-base">{@stop.level_id || "—"}</dd>
              </div>

              <div>
                <dt class="text-sm font-medium text-base-content/60">Platform Code</dt>
                <dd class="mt-1 text-base">{@stop.platform_code || "—"}</dd>
              </div>

              <div>
                <dt class="text-sm font-medium text-base-content/60">Accessibility</dt>
                <dd class="mt-1 text-base">
                  <TransitPresentation.accessibility_status
                    status={accessibility_resolution(@stop).status}
                    source={accessibility_resolution(@stop).source}
                  />
                </dd>
              </div>

              <div>
                <dt class="text-sm font-medium text-base-content/60">Diagram</dt>
                <dd class="mt-1 text-base" id="diagram-status">
                  {diagram_status_text(@stop.diagram_coordinate)}
                </dd>
              </div>
            </dl>
          </div>

          <div class="mt-8">
            <h2 class="text-lg font-semibold mb-4">Child Stops</h2>
            <%= cond do %>
              <% @child_stops_state == :unavailable -> %>
                <.callout kind="warning" title="Child stops unavailable" id="child-stops-unavailable">
                  Child stops could not be loaded. Please try again.
                  <button
                    id="child-stops-retry"
                    phx-click="retry_child_stops"
                    class="btn btn-sm btn-outline mt-2"
                  >
                    Retry
                  </button>
                </.callout>
              <% @child_stops_empty? -> %>
                <.empty_state
                  title="No child stops"
                  id="child-stops-empty"
                  class="bg-base-100"
                >
                  This station has no child stops. Child stops appear after they are linked to this station.
                </.empty_state>
              <% true -> %>
                <div class="space-y-4">
                  <%= for {level_name, stops} <- @child_stops_by_level do %>
                    <div class="bg-base-100 border border-base-300 rounded-lg overflow-hidden">
                      <div class="bg-base-200 px-4 py-2 font-medium flex justify-between">
                        <span>{level_name || "No Level"}</span>
                        <span class="badge badge-ghost">{length(stops)}</span>
                      </div>
                      <.table
                        id={"child-stops-level-#{level_name || "none"}"}
                        rows={stops}
                        row_id={fn stop -> "child-stop-row-#{stop.id}" end}
                        responsive="stack"
                      >
                        <:col :let={stop} label="Name">
                          <span class="font-medium">{stop.stop_name || stop.stop_id}</span>
                          <span class="text-sm text-base-content/60 ml-2">{stop.stop_id}</span>
                        </:col>
                        <:col :let={stop} label="Type">
                          <span class="badge badge-outline">
                            {Stop.location_type_label(stop.location_type)}
                          </span>
                        </:col>
                        <:col :let={stop} label="Accessibility">
                          <TransitPresentation.accessibility_status
                            status={Stop.resolve_wheelchair_boarding(stop, @stop).status}
                            source={Stop.resolve_wheelchair_boarding(stop, @stop).source}
                          />
                        </:col>
                        <:action :let={stop}>
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
                        </:action>
                      </.table>
                    </div>
                  <% end %>
                </div>
            <% end %>
          </div>

          <div class="mt-8">
            <h2 class="text-lg font-semibold mb-4">Levels</h2>
            <%= cond do %>
              <% @levels_state == :unavailable -> %>
                <.callout kind="warning" title="Levels unavailable" id="levels-unavailable">
                  Levels could not be loaded. Please try again.
                  <button
                    id="levels-retry"
                    phx-click="retry_levels"
                    class="btn btn-sm btn-outline mt-2"
                  >
                    Retry
                  </button>
                </.callout>
              <% @levels_empty? -> %>
                <.empty_state
                  title="No levels"
                  id="levels-empty"
                  class="bg-base-100"
                >
                  This station has no levels defined.
                </.empty_state>
              <% true -> %>
                <.table
                  id="levels-table"
                  rows={@streams.levels}
                  row_id={fn {id, _item} -> id end}
                  row_item={fn {_id, item} -> item end}
                  responsive="stack"
                >
                  <:col :let={%{level: level}} label="Level ID">
                    <span class="font-mono">{level.level_id}</span>
                  </:col>
                  <:col :let={%{level: level}} label="Name">
                    {level.level_name || "—"}
                  </:col>
                  <:col :let={%{level: level}} label="Index">
                    {level.level_index}
                  </:col>
                  <:col :let={%{stop_count: count}} label="Stops">
                    <span class="badge badge-ghost">{count}</span>
                  </:col>
                  <:col :let={%{level: level, diagram_filename: filename}} label="Diagram">
                    <span id={"diagram-status-#{level.level_id}"}>
                      {diagram_status_text(filename)}
                    </span>
                  </:col>
                </.table>
            <% end %>
          </div>

          <div class="mt-8">
            <h2 class="text-lg font-semibold mb-4">Pathways</h2>
            <%= cond do %>
              <% @pathways_state == :unavailable -> %>
                <.callout kind="warning" title="Pathways unavailable" id="pathways-unavailable">
                  Pathways could not be loaded. Please try again.
                  <button
                    id="pathways-retry"
                    phx-click="retry_pathways"
                    class="btn btn-sm btn-outline mt-2"
                  >
                    Retry
                  </button>
                </.callout>
              <% @pathways_empty? -> %>
                <.empty_state
                  title="No pathways"
                  id="pathways-empty"
                  class="bg-base-100"
                >
                  This station has no pathways defined.
                </.empty_state>
              <% true -> %>
                <.table
                  id="pathways-table"
                  rows={@streams.pathways}
                  row_id={fn {id, _item} -> id end}
                  row_item={fn {_id, item} -> item end}
                  responsive="stack"
                >
                  <:col :let={pathway} label="Pathway ID">
                    <span class="font-mono">{pathway.pathway_id}</span>
                  </:col>
                  <:col :let={pathway} label="From">
                    {pathway.from_stop_id}
                  </:col>
                  <:col :let={pathway} label="To">
                    {pathway.to_stop_id}
                  </:col>
                  <:col :let={pathway} label="Mode & Direction">
                    <TransitPresentation.pathway_summary pathway={pathway} />
                  </:col>
                </.table>
            <% end %>
          </div>
        <% _ -> %>
          <div></div>
      <% end %>
    </Layouts.app>
    """
  end
end
