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
  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  @impl true
  def mount(_params, _session, socket) do
    user_roles = socket.assigns[:user_roles] || []

    {:ok,
     socket
     |> assign(:page_title, "Route Details")
     |> assign(:user_roles, user_roles)
     |> assign(:active_tab, :details)
     |> assign(:route_patterns_empty?, true)
     |> stream(:route_patterns, [])}
  end

  @impl true
  def handle_params(%{"route_id" => route_id} = _params, _uri, socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    case Gtfs.get_route_by_route_id(organization_id, gtfs_version_id, route_id) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "Route not found")
         |> push_navigate(to: "/gtfs/#{gtfs_version_id}/routes")}

      route ->
        active_tab = socket.assigns[:live_action] || :details

        socket =
          socket
          |> assign(:route_id, route_id)
          |> assign(:route, route)
          |> assign(:active_tab, active_tab)

        socket =
          if active_tab == :patterns do
            patterns =
              Gtfs.list_route_patterns_for_route(organization_id, gtfs_version_id, route_id)

            socket
            |> assign(:route_patterns_empty?, patterns == [])
            |> stream(:route_patterns, patterns, reset: true)
          else
            socket
          end

        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("gtfs_version_loaded", %{"version_id" => version_id}, socket) do
    current_organization = socket.assigns.current_organization
    current_version_id = to_string(socket.assigns.current_gtfs_version.id)
    route_id = socket.assigns[:route_id]

    if version_id && version_id != current_version_id &&
         valid_version_for_org?(version_id, current_organization.id) do
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
    route_id = socket.assigns[:route_id]

    socket = push_event(socket, "gtfs_version_selected", %{version_id: version_id})

    path =
      if route_id,
        do: "/gtfs/#{version_id}/routes/#{route_id}",
        else: "/gtfs/#{version_id}/routes"

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
        <.route_sub_nav
          route={@route}
          gtfs_version_id={@current_gtfs_version.id}
          active_tab={@active_tab}
        />
      </:sub_header>

      <%= if @active_tab == :details do %>
        <div class="bg-base-100 border border-base-300 rounded-lg p-6 mt-8">
          <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
            <div>
              <h3 class="text-sm font-medium text-base-content/60">Route ID</h3>
              <p class="mt-1 text-base">{@route.route_id}</p>
            </div>

            <div>
              <h3 class="text-sm font-medium text-base-content/60">Short Name</h3>
              <p class="mt-1 text-base">{@route.route_short_name || "—"}</p>
            </div>

            <div>
              <h3 class="text-sm font-medium text-base-content/60">Long Name</h3>
              <p class="mt-1 text-base">{@route.route_long_name || "—"}</p>
            </div>

            <div>
              <h3 class="text-sm font-medium text-base-content/60">Type</h3>
              <p class="mt-1 text-base">{Route.route_type_label(@route.route_type)}</p>
            </div>

            <div>
              <h3 class="text-sm font-medium text-base-content/60">Agency ID</h3>
              <p class="mt-1 text-base">{@route.agency_id || "—"}</p>
            </div>

            <div>
              <h3 class="text-sm font-medium text-base-content/60">Description</h3>
              <p class="mt-1 text-base">{@route.route_desc || "—"}</p>
            </div>

            <div>
              <h3 class="text-sm font-medium text-base-content/60">URL</h3>
              <p class="mt-1 text-base">{@route.route_url || "—"}</p>
            </div>

            <div>
              <h3 class="text-sm font-medium text-base-content/60">Color</h3>
              <p class="mt-1 text-base">#{@route.route_color}</p>
            </div>

            <div>
              <h3 class="text-sm font-medium text-base-content/60">Text Color</h3>
              <p class="mt-1 text-base">#{@route.route_text_color}</p>
            </div>

            <div>
              <h3 class="text-sm font-medium text-base-content/60">Sort Order</h3>
              <p class="mt-1 text-base">{@route.route_sort_order || "—"}</p>
            </div>

            <div>
              <h3 class="text-sm font-medium text-base-content/60">Continuous Pickup</h3>
              <p class="mt-1 text-base">{@route.continuous_pickup}</p>
            </div>

            <div>
              <h3 class="text-sm font-medium text-base-content/60">Continuous Drop Off</h3>
              <p class="mt-1 text-base">{@route.continuous_drop_off}</p>
            </div>

            <div>
              <h3 class="text-sm font-medium text-base-content/60">Network ID</h3>
              <p class="mt-1 text-base">{@route.network_id || "—"}</p>
            </div>

            <div>
              <h3 class="text-sm font-medium text-base-content/60">Active</h3>
              <p class="mt-1 text-base">{if @route.active, do: "Yes", else: "No"}</p>
            </div>
          </div>
        </div>
      <% end %>

      <%= if @active_tab == :patterns do %>
        <div class="mt-8">
          <%= if @route_patterns_empty? do %>
            <div class="bg-base-100 border border-base-300 rounded-lg p-6 text-center text-base-content/60">
              No route patterns found
            </div>
          <% else %>
            <div class="bg-base-100 border border-base-300 rounded-lg overflow-hidden">
              <table class="table w-full">
                <thead>
                  <tr>
                    <th>Pattern ID</th>
                    <th>Name</th>
                    <th>Direction</th>
                    <th>Typicality</th>
                  </tr>
                </thead>
                <tbody id="route-patterns" phx-update="stream">
                  <tr :for={{id, pattern} <- @streams.route_patterns} id={id}>
                    <td>{pattern.route_pattern_id}</td>
                    <td>{pattern.route_pattern_name || "—"}</td>
                    <td>{RoutePattern.direction_label(pattern.direction_id)}</td>
                    <td>
                      <span class="badge badge-sm">
                        {RoutePattern.typicality_label(pattern.route_pattern_typicality)}
                      </span>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </div>
      <% end %>
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
end
