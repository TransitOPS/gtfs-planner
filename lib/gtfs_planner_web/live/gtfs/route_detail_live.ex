defmodule GtfsPlannerWeb.Gtfs.RouteDetailLive do
  @moduledoc """
  LiveView for viewing GTFS route details.
  Requires pathways_studio_editor role.
  """
  use GtfsPlannerWeb, :live_view
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.Components.RouteIdentity
  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  @impl true
  def mount(_params, _session, socket) do
    user_roles = socket.assigns[:user_roles] || []

    {:ok,
     socket
     |> assign(:page_title, "Route Details")
     |> assign(:user_roles, user_roles)
     |> assign(:active_tab, :details)
     |> assign(:route_state, :loading)
     |> assign(:patterns_state, :ready)
     |> assign(:route_patterns_empty?, true)
     |> stream(:route_patterns, [])}
  end

  @impl true
  def handle_params(%{"route_id" => route_id} = _params, _uri, socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id
    active_tab = socket.assigns[:live_action] || :details

    socket =
      socket
      |> assign(:route_id, route_id)
      |> assign(:active_tab, active_tab)

    case Gtfs.fetch_catalog_route(organization_id, gtfs_version_id, route_id) do
      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "Route not found")
         |> push_navigate(to: "/gtfs/#{gtfs_version_id}/routes")}

      {:error, :unavailable} ->
        {:noreply, assign(socket, :route_state, :unavailable)}

      {:ok, route} ->
        socket =
          socket
          |> assign(:route, route)
          |> assign(:route_state, :ready)

        socket = load_patterns(socket, active_tab)

        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("retry", _params, socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id
    route_id = socket.assigns.route_id

    case Gtfs.fetch_catalog_route(organization_id, gtfs_version_id, route_id) do
      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "Route not found")
         |> push_navigate(to: "/gtfs/#{gtfs_version_id}/routes")}

      {:error, :unavailable} ->
        {:noreply, assign(socket, :route_state, :unavailable)}

      {:ok, route} ->
        socket =
          socket
          |> assign(:route, route)
          |> assign(:route_state, :ready)

        socket = load_patterns(socket, socket.assigns.active_tab)

        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("retry_patterns", _params, socket) do
    {:noreply, load_patterns(socket, socket.assigns.active_tab)}
  end

  @impl true
  def handle_event("gtfs_version_loaded", %{"version_id" => version_id}, socket) do
    current_organization = socket.assigns.current_organization
    current_version_id = to_string(socket.assigns.current_gtfs_version.id)
    route_id = socket.assigns[:route_id]

    if version_id && version_id != current_version_id &&
         Versions.published_gtfs_version_for_org?(current_organization.id, version_id) do
      path =
        if route_id,
          do: "/gtfs/#{version_id}/routes/#{route_id}",
          else: "/gtfs/#{version_id}/routes"

      {:noreply, push_navigate(socket, to: path)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("switch_gtfs_version", %{"version" => version_id}, socket) do
    current_organization = socket.assigns.current_organization
    route_id = socket.assigns[:route_id]

    if Versions.published_gtfs_version_for_org?(current_organization.id, version_id) do
      socket = push_event(socket, "gtfs_version_selected", %{version_id: version_id})

      path =
        if route_id,
          do: "/gtfs/#{version_id}/routes/#{route_id}",
          else: "/gtfs/#{version_id}/routes"

      {:noreply, push_navigate(socket, to: path)}
    else
      {:noreply, socket}
    end
  end

  defp load_patterns(socket, :patterns) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id
    route_id = socket.assigns.route_id

    case Gtfs.load_catalog_route_patterns(organization_id, gtfs_version_id, route_id) do
      {:ok, patterns} ->
        socket
        |> assign(:patterns_state, :ready)
        |> assign(:route_patterns_empty?, patterns == [])
        |> stream(:route_patterns, patterns, reset: true)

      {:error, :unavailable} ->
        assign(socket, :patterns_state, :unavailable)
    end
  end

  defp load_patterns(socket, _), do: socket

  defp valid_external_url?(url) when is_binary(url) and url != "" do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        true

      _ ->
        false
    end
  end

  defp valid_external_url?(_), do: false

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
      <:sub_header :if={@route_state == :ready && @active_tab != :schedules}>
        <.route_sub_nav
          route={@route}
          gtfs_version_id={@current_gtfs_version.id}
          active_tab={@active_tab}
        />
      </:sub_header>

      <%= case @route_state do %>
        <% :unavailable -> %>
          <div class="mt-8">
            <.callout kind="error" title="Route data unavailable" id="route-unavailable">
              We could not load this route. Please try again.
              <button
                id="route-retry"
                phx-click="retry"
                class="btn btn-sm btn-outline mt-2"
              >
                Retry
              </button>
            </.callout>
          </div>
        <% :ready -> %>
          <%= cond do %>
            <% @active_tab == :details -> %>
              <div class="bg-base-100 border border-base-300 rounded-lg p-6 mt-8">
                <div class="flex items-center gap-3 mb-6">
                  <RouteIdentity.route_badge route={@route} />
                  <span class="text-sm text-base-content/60 font-mono">
                    {@route.route_color} / {@route.route_text_color}
                  </span>
                </div>

                <dl class="grid grid-cols-1 md:grid-cols-2 gap-6">
                  <div>
                    <dt class="text-sm font-medium text-base-content/60">Route ID</dt>
                    <dd class="mt-1 text-base font-mono">{@route.route_id}</dd>
                  </div>

                  <div>
                    <dt class="text-sm font-medium text-base-content/60">Short Name</dt>
                    <dd class="mt-1 text-base">{@route.route_short_name || "—"}</dd>
                  </div>

                  <div>
                    <dt class="text-sm font-medium text-base-content/60">Long Name</dt>
                    <dd class="mt-1 text-base">{@route.route_long_name || "—"}</dd>
                  </div>

                  <div>
                    <dt class="text-sm font-medium text-base-content/60">Type</dt>
                    <dd class="mt-1 text-base">{Route.route_type_label(@route.route_type)}</dd>
                  </div>

                  <div>
                    <dt class="text-sm font-medium text-base-content/60">Agency ID</dt>
                    <dd class="mt-1 text-base">{@route.agency_id || "—"}</dd>
                  </div>

                  <div>
                    <dt class="text-sm font-medium text-base-content/60">Description</dt>
                    <dd class="mt-1 text-base">{@route.route_desc || "—"}</dd>
                  </div>

                  <div>
                    <dt class="text-sm font-medium text-base-content/60">URL</dt>
                    <dd class="mt-1 text-base">
                      <%= if valid_external_url?(@route.route_url) do %>
                        <a
                          href={@route.route_url}
                          target="_blank"
                          rel="noopener"
                          class="link link-primary break-all"
                        >
                          {@route.route_url}
                        </a>
                      <% else %>
                        {@route.route_url || "—"}
                      <% end %>
                    </dd>
                  </div>

                  <div>
                    <dt class="text-sm font-medium text-base-content/60">Sort Order</dt>
                    <dd class="mt-1 text-base">{@route.route_sort_order || "—"}</dd>
                  </div>

                  <div>
                    <dt class="text-sm font-medium text-base-content/60">Continuous Pickup</dt>
                    <dd class="mt-1 text-base">{@route.continuous_pickup}</dd>
                  </div>

                  <div>
                    <dt class="text-sm font-medium text-base-content/60">Continuous Drop Off</dt>
                    <dd class="mt-1 text-base">{@route.continuous_drop_off}</dd>
                  </div>

                  <div>
                    <dt class="text-sm font-medium text-base-content/60">Network ID</dt>
                    <dd class="mt-1 text-base">{@route.network_id || "—"}</dd>
                  </div>

                  <div>
                    <dt class="text-sm font-medium text-base-content/60">Active</dt>
                    <dd class="mt-1 text-base">{if @route.active, do: "Yes", else: "No"}</dd>
                  </div>
                </dl>
              </div>
            <% @active_tab == :patterns -> %>
              <div class="mt-8">
                <%= cond do %>
                  <% @patterns_state == :unavailable -> %>
                    <.callout kind="warning" title="Patterns unavailable" id="patterns-unavailable">
                      Route patterns could not be loaded. Please try again.
                      <button
                        id="patterns-retry"
                        phx-click="retry_patterns"
                        class="btn btn-sm btn-outline mt-2"
                      >
                        Retry
                      </button>
                    </.callout>
                  <% @route_patterns_empty? -> %>
                    <.empty_state
                      title="No route patterns"
                      id="patterns-empty"
                      class="bg-base-100"
                    >
                      This route has no patterns defined. Patterns appear after trip data is imported.
                    </.empty_state>
                  <% true -> %>
                    <.table
                      id="route-patterns-table"
                      rows={@streams.route_patterns}
                      row_item={fn {_id, item} -> item end}
                      responsive="stack"
                    >
                      <:col :let={pattern} label="Pattern ID">
                        <span class="font-mono">{pattern.route_pattern_id}</span>
                      </:col>
                      <:col :let={pattern} label="Name">
                        {pattern.route_pattern_name || "—"}
                      </:col>
                      <:col :let={pattern} label="Direction">
                        {RoutePattern.direction_label(pattern.direction_id)}
                      </:col>
                      <:col :let={pattern} label="Typicality">
                        <span class="badge badge-sm">
                          {RoutePattern.typicality_label(pattern.route_pattern_typicality)}
                        </span>
                      </:col>
                    </.table>
                <% end %>
              </div>
            <% @active_tab == :schedules -> %>
              <div class="mt-8" id="schedules-deferred">
                <.empty_state title="Schedules" class="bg-base-100">
                  Schedule data will be available in a future update.
                </.empty_state>
              </div>
            <% true -> %>
              <div></div>
          <% end %>
        <% _ -> %>
          <div></div>
      <% end %>
    </Layouts.app>
    """
  end
end
