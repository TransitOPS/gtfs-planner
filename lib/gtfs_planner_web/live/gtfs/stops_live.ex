defmodule GtfsPlannerWeb.Gtfs.StopsLive do
  @moduledoc """
  LiveView for managing GTFS stations (stops).
  Requires pathways_studio_editor or pathways_studio_viewer role.
  """
  use GtfsPlannerWeb, :live_view

  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Stop
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
       |> assign(:page_title, "Stations")
       |> assign(:pending_version_resolution, true)}
    else
      user_roles = get_user_roles(socket)

      {:ok,
       socket
       |> assign(:page_title, "Stations")
       |> assign(:user_roles, user_roles)
       |> assign(
         :filter_form,
         to_form(%{"wheelchair_boarding" => "", "route_id" => "", "direction_id" => ""})
       )
       |> assign(:search, "")
       |> assign(:sort_by, :stop_name)
       |> assign(:sort_dir, :asc)
       |> assign(:page, 1)
       |> assign(:per_page, 50)
       |> assign(:total_count, 0)
       |> assign(:stations_empty?, true)
       |> assign(:available_routes, [])
       |> assign(:route_id, nil)
       |> assign(:direction_id, nil)}
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    if socket.assigns[:pending_version_resolution] do
      {:noreply, socket}
    else
      organization_id = socket.assigns.current_organization.id
      gtfs_version_id = socket.assigns.current_gtfs_version.id

      wheelchair_boarding = parse_wheelchair(params["wheelchair_boarding"])
      route_id = params["route_id"] || ""
      direction_id = parse_direction(params["direction_id"])
      search = params["search"] || ""
      sort_by = parse_column_atom(params["sort_by"]) || :stop_name
      sort_dir = parse_atom(params["sort_dir"], :asc)
      page = parse_integer(params["page"], 1)
      per_page = 50

      opts = [
        wheelchair_boarding: wheelchair_boarding,
        route_id: route_id,
        direction_id: direction_id,
        search: search,
        sort_by: sort_by,
        sort_dir: sort_dir,
        page: page,
        per_page: per_page
      ]

      stations = Gtfs.list_stations(organization_id, gtfs_version_id, opts)
      total_count = Gtfs.count_stations(organization_id, gtfs_version_id, opts)

      available_routes = Gtfs.list_routes_serving_stations(organization_id, gtfs_version_id)

      stop_ids = Enum.map(stations, & &1.stop_id)
      routes_by_stop = Gtfs.get_routes_for_stops(organization_id, gtfs_version_id, stop_ids)

      stations_with_routes =
        Enum.map(stations, fn s ->
          Map.put(s, :routes, Map.get(routes_by_stop, s.stop_id, []))
        end)

      filter_form =
        to_form(%{
          "wheelchair_boarding" => wheelchair_boarding || "",
          "route_id" => route_id,
          "direction_id" => direction_id || ""
        })

      {:noreply,
       socket
       |> assign(:filter_form, filter_form)
       |> assign(:search, search)
       |> assign(:sort_by, sort_by)
       |> assign(:sort_dir, sort_dir)
       |> assign(:page, page)
       |> assign(:per_page, per_page)
       |> assign(:total_count, total_count)
       |> assign(:stations_empty?, stations == [])
       |> assign(:available_routes, available_routes)
       |> assign(:route_id, route_id)
       |> assign(:direction_id, direction_id)
       |> stream(:stations, stations_with_routes, reset: true)}
    end
  end

  @impl true
  def handle_event("gtfs_version_loaded", %{"version_id" => version_id}, socket) do
    # Guard clause: if pending version resolution, we need to redirect to a version
    if socket.assigns[:pending_version_resolution] do
      current_organization = socket.assigns.current_organization

      # Use the version from localStorage if valid, otherwise fetch latest
      version_to_use =
        if version_id && valid_version_for_org?(version_id, current_organization.id) do
          version_id
        else
          # Fetch latest version for the organization
          case Versions.get_latest_gtfs_version(current_organization.id) do
            {:ok, version} -> to_string(version.id)
            {:error, :no_versions} -> nil
          end
        end

      if version_to_use do
        {:noreply, push_navigate(socket, to: "/gtfs/#{version_to_use}/stops")}
      else
        # No versions available, stay on pending page
        {:noreply, socket}
      end
    else
      # Normal flow: we already have a current version
      current_organization = socket.assigns.current_organization
      current_version_id = to_string(socket.assigns.current_gtfs_version.id)

      # Try to use the stored version_id from localStorage
      version_to_use =
        if version_id && valid_version_for_org?(version_id, current_organization.id) do
          version_id
        else
          # Fall back to latest version or current version
          case socket.assigns[:latest_gtfs_version] do
            {:ok, version} -> to_string(version.id)
            {:error, :no_versions} -> nil
            # Already on a valid route
            nil -> current_version_id
          end
        end

      # Only navigate if switching to a different version
      if version_to_use && version_to_use != current_version_id do
        {:noreply, push_navigate(socket, to: "/gtfs/#{version_to_use}/stops")}
      else
        # Already on correct version, do nothing
        {:noreply, socket}
      end
    end
  end

  @impl true
  def handle_event("switch_gtfs_version", %{"version" => version_id}, socket) do
    # Push event to JS hook to update localStorage
    socket = push_event(socket, "gtfs_version_selected", %{version_id: version_id})

    # Navigate to new version
    {:noreply, push_navigate(socket, to: "/gtfs/#{version_id}/stops")}
  end

  @impl true
  def handle_event("filter", params, socket) do
    wheelchair_boarding = params["wheelchair_boarding"]
    route_id = params["route_id"]
    direction_id = params["direction_id"]

    params =
      %{}
      |> maybe_put("wheelchair_boarding", wheelchair_boarding)
      |> maybe_put("route_id", route_id)
      |> maybe_put("direction_id", direction_id)
      |> maybe_put("search", socket.assigns.search)
      |> maybe_put_sort(socket.assigns.sort_by, socket.assigns.sort_dir)

    {:noreply,
     push_patch(socket,
       to: ~p"/gtfs/#{socket.assigns.current_gtfs_version.id}/stops?#{params}"
     )}
  end

  @impl true
  def handle_event("search", %{"search" => search}, socket) do
    params =
      %{}
      |> maybe_put(
        "wheelchair_boarding",
        socket.assigns.filter_form.params["wheelchair_boarding"]
      )
      |> maybe_put("route_id", socket.assigns.filter_form.params["route_id"])
      |> maybe_put("direction_id", socket.assigns.filter_form.params["direction_id"])
      |> maybe_put("search", search)
      |> maybe_put_sort(socket.assigns.sort_by, socket.assigns.sort_dir)

    {:noreply,
     push_patch(socket,
       to: ~p"/gtfs/#{socket.assigns.current_gtfs_version.id}/stops?#{params}"
     )}
  end

  @impl true
  def handle_event("sort", %{"column" => column}, socket) do
    column_atom = parse_column_atom(column)

    # Toggle logic:
    # if same column and asc -> desc
    # if same column and desc -> default (stop_name, asc)
    # new column -> asc

    {new_sort_by, new_sort_dir} =
      cond do
        column_atom == socket.assigns.sort_by and socket.assigns.sort_dir == :asc ->
          {column_atom, :desc}

        column_atom == socket.assigns.sort_by and socket.assigns.sort_dir == :desc ->
          {:stop_name, :asc}

        true ->
          {column_atom, :asc}
      end

    params =
      %{}
      |> maybe_put(
        "wheelchair_boarding",
        socket.assigns.filter_form.params["wheelchair_boarding"]
      )
      |> maybe_put("route_id", socket.assigns.filter_form.params["route_id"])
      |> maybe_put("direction_id", socket.assigns.filter_form.params["direction_id"])
      |> maybe_put("search", socket.assigns.search)
      |> maybe_put_sort(new_sort_by, new_sort_dir)

    {:noreply,
     push_patch(socket,
       to: ~p"/gtfs/#{socket.assigns.current_gtfs_version.id}/stops?#{params}"
     )}
  end

  @impl true
  def handle_event("paginate", %{"page" => page}, socket) do
    page_int = parse_integer(page, 1)

    params =
      %{}
      |> maybe_put(
        "wheelchair_boarding",
        socket.assigns.filter_form.params["wheelchair_boarding"]
      )
      |> maybe_put("route_id", socket.assigns.filter_form.params["route_id"])
      |> maybe_put("direction_id", socket.assigns.filter_form.params["direction_id"])
      |> maybe_put("search", socket.assigns.search)
      |> maybe_put_sort(socket.assigns.sort_by, socket.assigns.sort_dir)
      |> Map.put("page", page_int)

    {:noreply,
     push_patch(socket,
       to: ~p"/gtfs/#{socket.assigns.current_gtfs_version.id}/stops?#{params}"
     )}
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
        current_gtfs_version={assigns[:current_gtfs_version]}
        available_versions={assigns[:available_versions] || []}
      >
        <.header>
          Stations
          <:subtitle>Top-level stops with no parent station.</:subtitle>
        </.header>

        <div class="mt-6 bg-base-100 border border-base-300 rounded-lg p-4">
          <.form
            for={@filter_form}
            id="station-filter-form"
            phx-change="filter"
            class="flex gap-4 items-end"
          >
            <div class="flex-1 max-w-[50%]">
              <.input
                field={@filter_form[:route_id]}
                type="select"
                label="Route"
                prompt="All routes"
                options={
                  Enum.map(@available_routes, fn r ->
                    display =
                      if r.route_short_name do
                        "#{r.route_short_name} (#{r.route_id})"
                      else
                        r.route_id
                      end

                    {display, r.route_id}
                  end)
                }
              />
            </div>
            <%= if @route_id && @route_id != "" do %>
              <div class="flex-1">
                <.input
                  field={@filter_form[:direction_id]}
                  type="select"
                  label="Direction"
                  prompt="All directions"
                  options={[{"Direction 0", 0}, {"Direction 1", 1}]}
                />
              </div>
            <% end %>
            <div class="flex-1">
              <.input
                field={@filter_form[:wheelchair_boarding]}
                type="select"
                label="Accessibility"
                prompt="All accessibility"
                options={[{"No info", 0}, {"Accessible", 1}, {"Not accessible", 2}]}
              />
            </div>
          </.form>
          <div class="mt-4">
            <.form for={%{}} id="station-search-form" phx-change="search">
              <.input
                name="search"
                type="search"
                value={@search}
                placeholder="Search stations..."
                phx-debounce="300"
                label="Search"
              />
            </.form>
          </div>
        </div>

        <div :if={@stations_empty?} class="text-center py-8 text-base-content/60">
          No stations found
        </div>

        <div :if={not @stations_empty?}>
          <div class="mt-6 bg-base-100 border border-base-300 rounded-lg overflow-hidden">
            <div class="overflow-x-auto">
              <table class="table">
                <thead>
                  <tr class="bg-base-300">
                    <th style="width: 15%">
                      <button
                        type="button"
                        class="flex items-center gap-1 cursor-pointer"
                        phx-click="sort"
                        phx-value-column="stop_id"
                      >
                        Stop ID
                        <span :if={@sort_by == :stop_id}>
                          {if @sort_dir == :asc, do: "▲", else: "▼"}
                        </span>
                      </button>
                    </th>
                    <th style="width: 25%">
                      <button
                        type="button"
                        class="flex items-center gap-1 cursor-pointer"
                        phx-click="sort"
                        phx-value-column="stop_name"
                      >
                        Station Name
                        <span :if={@sort_by == :stop_name}>
                          {if @sort_dir == :asc, do: "▲", else: "▼"}
                        </span>
                      </button>
                    </th>
                    <th style="width: 20%">
                      <button
                        type="button"
                        class="flex items-center gap-1 cursor-pointer"
                        phx-click="sort"
                        phx-value-column="location_type"
                      >
                        Location Type
                        <span :if={@sort_by == :location_type}>
                          {if @sort_dir == :asc, do: "▲", else: "▼"}
                        </span>
                      </button>
                    </th>
                    <th style="width: 15%">Accessibility</th>
                    <th style="width: 25%">Routes</th>
                  </tr>
                </thead>
                <tbody id="stations" phx-update="stream">
                  <tr :for={{id, station} <- @streams.stations} id={id}>
                    <td>
                      <.link
                        navigate={"/gtfs/#{@current_gtfs_version.id}/stops/#{station.stop_id}"}
                        class="link link-primary"
                      >
                        {station.stop_id}
                      </.link>
                    </td>
                    <td>{station.stop_name}</td>
                    <td>{Stop.location_type_label(station.location_type)}</td>
                    <td>
                      <%= case station.wheelchair_boarding do %>
                        <% 1 -> %>
                          Accessible
                        <% 2 -> %>
                          Not accessible
                        <% _ -> %>
                          No info
                      <% end %>
                    </td>
                    <td>
                      <%= if station.routes == [] do %>
                        <span class="text-base-content/40">No routes</span>
                      <% else %>
                        <div class="flex flex-wrap gap-1">
                          <%= for route <- Enum.take(station.routes, 5) do %>
                            <span
                              class="badge badge-sm"
                              style={"background-color:##{route.route_color};color:##{route.route_text_color}"}
                            >
                              {route.route_short_name || route.route_id}
                            </span>
                          <% end %>
                          <%= if length(station.routes) > 5 do %>
                            <span class="badge badge-sm badge-ghost">
                              +{length(station.routes) - 5}
                            </span>
                          <% end %>
                        </div>
                      <% end %>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>

          <div :if={@total_count > 0} class="mt-4 flex items-center justify-between">
            <div>
              Showing {max((@page - 1) * @per_page + 1, 1)}–{min(@page * @per_page, @total_count)} of {@total_count} stations
            </div>
            <div>
              <button
                class="btn btn-sm btn-ghost"
                phx-click="paginate"
                phx-value-page={@page - 1}
                disabled={@page <= 1}
              >
                Previous
              </button>
              <button
                class="btn btn-sm btn-ghost"
                phx-click="paginate"
                phx-value-page={@page + 1}
                disabled={@page * @per_page >= @total_count}
              >
                Next
              </button>
            </div>
          </div>
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

  defp parse_wheelchair(nil), do: nil
  defp parse_wheelchair(""), do: nil
  defp parse_wheelchair(val), do: String.to_integer(val)

  defp parse_direction(nil), do: nil
  defp parse_direction(""), do: nil
  defp parse_direction(val), do: String.to_integer(val)

  defp parse_atom(nil, default), do: default
  defp parse_atom("", default), do: default

  defp parse_atom(val, default) do
    try do
      String.to_existing_atom(val)
    rescue
      ArgumentError -> default
    end
  end

  defp parse_integer(nil, default), do: default
  defp parse_integer("", default), do: default

  defp parse_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> int
      _ -> default
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_sort(params, :stop_name, :asc), do: params

  defp maybe_put_sort(params, sort_by, sort_dir) do
    params
    |> Map.put(:sort_by, sort_by)
    |> Map.put(:sort_dir, sort_dir)
  end

  defp parse_column_atom(column)
       when column in ["stop_id", "stop_name", "location_type", "route_id"] do
    String.to_existing_atom(column)
  end

  defp parse_column_atom(_), do: nil
end
