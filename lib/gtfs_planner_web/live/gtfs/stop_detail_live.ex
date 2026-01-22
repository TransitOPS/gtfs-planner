defmodule GtfsPlannerWeb.Gtfs.StopDetailLive do
  @moduledoc """
  LiveView for viewing GTFS station (stop) details.
  Requires to pathways_studio_editor or pathways_studio_viewer role.
  """
  use GtfsPlannerWeb, :live_view

  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.{Stop, Pathway}
  alias GtfsPlanner.Versions

  on_mount {GtfsPlannerWeb.UserAuth, :ensure_authenticated}
  on_mount GtfsPlannerWeb.AssignOrganization
  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  @impl true
  def mount(_params, _session, socket) do
    # Check if version resolution is pending (versionless route)
    if socket.assigns[:gtfs_version_pending] do
      {:ok,
       socket
       |> assign(:page_title, "Station Details")
       |> assign(:pending_version_resolution, true)}
    else
      user_roles = get_user_roles(socket)

      {:ok,
       socket
       |> assign(:page_title, "Station Details")
       |> assign(:user_roles, user_roles)}
    end
  end

  @impl true
  def handle_params(%{"stop_id" => stop_id} = _params, _uri, socket) do
    # If version resolution is still pending, do not attempt to access
    # current_organization/current_gtfs_version yet.
    if socket.assigns[:pending_version_resolution] do
      {:noreply, socket}
    else
      # Fetch the stop data
      organization_id = socket.assigns.current_organization.id
      gtfs_version_id = socket.assigns.current_gtfs_version.id

      case GtfsPlanner.Gtfs.get_stop_by_stop_id(organization_id, gtfs_version_id, stop_id) do
        nil ->
          {:noreply,
           socket
           |> put_flash(:error, "Station not found")
           |> push_navigate(to: "/gtfs/#{gtfs_version_id}/stops")}

        stop ->
          child_stops = Gtfs.list_child_stops_for_parent(organization_id, gtfs_version_id, stop.id)
          levels = Gtfs.list_levels_for_station(organization_id, gtfs_version_id, stop.id)
          pathways = Gtfs.list_pathways_for_station(organization_id, gtfs_version_id, stop.id)

          # Group child stops by level
          child_stops_by_level = Enum.group_by(child_stops, fn s ->
            case s.level do
              nil -> "No Level"
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
           |> assign(:pathways, pathways)}
      end
    end
  end

  @impl true
  def handle_event("gtfs_version_loaded", %{"version_id" => version_id}, socket) do
    current_organization = socket.assigns.current_organization
    current_version_id = to_string(socket.assigns.current_gtfs_version.id)
    stop_id = socket.assigns[:stop_id]

    # Try to use the stored version_id from localStorage
    version_to_use =
      if version_id && valid_version_for_org?(version_id, current_organization.id) do
        version_id
      else
        # Fall back to latest version or current version
        case socket.assigns[:latest_gtfs_version] do
          {:ok, version} -> to_string(version.id)
          {:error, :no_versions} -> nil
          nil -> current_version_id  # Already on a valid route
        end
      end

    # Only navigate if switching to a different version
    if version_to_use && version_to_use != current_version_id do
      path = if stop_id, do: "/gtfs/#{version_to_use}/stops/#{stop_id}", else: "/gtfs/#{version_to_use}/stops"
      {:noreply, push_navigate(socket, to: path)}
    else
      # Already on correct version, do nothing
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("switch_gtfs_version", %{"version" => version_id}, socket) do
    stop_id = socket.assigns[:stop_id]

    # Push event to JS hook to update localStorage
    socket = push_event(socket, "gtfs_version_selected", %{version_id: version_id})

    # Navigate to new version
    path = if stop_id, do: "/gtfs/#{version_id}/stops/#{stop_id}", else: "/gtfs/#{version_id}/stops"
    {:noreply, push_navigate(socket, to: path)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <%= if assigns[:pending_version_resolution] do %>
      <%!-- Pending version resolution - mount the hook to trigger redirect --%>
      <div
        id="gtfs-version-resolver"
        phx-hook="GtfsVersionHook"
        data-organization-id={@current_organization.id}
      >
        <div class="flex items-center justify-center min-h-screen">
          <div class="text-center">
            <div class="loading loading-spinner loading-lg"></div>
            <p class="mt-4 text-base-content/60">Loading GTFS version...</p>
          </div>
        </div>
      </div>
    <% else %>
      <Layouts.app
        flash={@flash}
        current_user={@current_user}
        current_organization={@current_organization}
        user_roles={@user_roles}
        current_path={@current_path}
      >
        <.header>
          {@stop.stop_name || @stop_id}
          <:subtitle>Station ID: {@stop_id}</:subtitle>
          <:actions>
            <.link navigate={"/gtfs/#{@current_gtfs_version.id}/stops"} class="btn btn-ghost btn-sm">
              Back to Stations
            </.link>
            <%= if assigns[:current_gtfs_version] && assigns[:available_versions] do %>
              <.gtfs_version_switcher
                current_version={@current_gtfs_version}
                versions={@available_versions}
                organization_id={@current_organization.id}
              />
            <% end %>
          </:actions>
        </.header>

        <div class="mt-8 bg-base-100 border border-base-300 rounded-lg p-6">
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
                    <span>{level_name}</span>
                    <span class="badge badge-ghost">{length(stops)}</span>
                  </div>
                  <ul class="divide-y divide-base-300">
                    <%= for stop <- stops do %>
                      <li class="px-4 py-3 flex justify-between">
                        <div>
                          <span class="font-medium">{stop.stop_name || stop.stop_id}</span>
                          <span class="text-sm text-base-content/60 ml-2">{stop.stop_id}</span>
                        </div>
                        <span class="badge badge-outline">{Stop.location_type_label(stop.location_type)}</span>
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
                  </tr>
                </thead>
                <tbody>
                  <%= for %{level: level, stop_count: count} <- @levels do %>
                    <tr>
                      <td>{level.level_id}</td>
                      <td>{level.level_name || ""}</td>
                      <td>{level.level_index}</td>
                      <td><span class="badge badge-ghost">{count}</span></td>
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
                      <td>{pathway.from_stop.stop_name || pathway.from_stop.stop_id}</td>
                      <td>{pathway.to_stop.stop_name || pathway.to_stop.stop_id}</td>
                      <td><span class="badge badge-outline">{Pathway.mode_label(pathway.pathway_mode)}</span></td>
                      <td>{if pathway.traversal_time, do: "#{pathway.traversal_time}s", else: ""}</td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          <% end %>
        </div>
      </Layouts.app>
    <% end %>
    """
  end

  defp get_user_roles(socket) do
    user = socket.assigns[:current_user]
    organization = socket.assigns[:current_organization]

    case GtfsPlanner.Accounts.get_user_org_membership(user.id, organization.id) do
      %UserOrgMembership{roles: roles} when is_list(roles) -> roles
      _ -> []
    end
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