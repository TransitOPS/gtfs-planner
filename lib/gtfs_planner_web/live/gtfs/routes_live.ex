defmodule GtfsPlannerWeb.Gtfs.RoutesLive do
  @moduledoc """
  LiveView for viewing GTFS routes.
  Requires pathways_studio_editor or pathways_studio_viewer role.
  """
  use GtfsPlannerWeb, :live_view

  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Versions

  on_mount {GtfsPlannerWeb.UserAuth, :ensure_authenticated}
  on_mount GtfsPlannerWeb.AssignOrganization
  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  @impl true
  def mount(_params, _session, socket) do
    if socket.assigns[:gtfs_version_pending] do
      {:ok,
       socket
       |> assign(:page_title, "Routes")
       |> assign(:pending_version_resolution, true)}
    else
      user_roles = get_user_roles(socket)

      {:ok,
       socket
       |> assign(:page_title, "Routes")
       |> assign(:user_roles, user_roles)
       |> assign(:filter_form, to_form(%{"route_type" => "", "agency_id" => "", "active" => ""}))
       |> assign(:search, "")
       |> assign(:sort_by, :route_id)
       |> assign(:sort_dir, :asc)
       |> assign(:page, 1)
       |> assign(:per_page, 50)
       |> assign(:total_count, 0)
       |> assign(:routes_empty?, true)}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    if socket.assigns[:pending_version_resolution] do
      {:noreply, socket}
    else
      organization_id = socket.assigns.current_organization.id
      gtfs_version_id = socket.assigns.current_gtfs_version.id

      route_type = parse_route_type(params["route_type"])
      agency_id = parse_string(params["agency_id"])
      active = params["active"]
      search = params["search"] || ""
      sort_by = parse_atom(params["sort_by"], :route_id)
      sort_dir = parse_atom(params["sort_dir"], :asc)
      page = parse_integer(params["page"], 1)
      per_page = socket.assigns.per_page

      opts = [
        route_type: route_type,
        agency_id: agency_id,
        active: active,
        search: search,
        sort_by: sort_by,
        sort_dir: sort_dir,
        page: page,
        per_page: per_page
      ]

      routes = Gtfs.list_routes(organization_id, gtfs_version_id, opts)
      total_count = Gtfs.count_routes(organization_id, gtfs_version_id, opts)
      available_route_types = Gtfs.list_distinct_route_types(organization_id, gtfs_version_id)
      available_agencies = Gtfs.list_distinct_agencies(organization_id, gtfs_version_id)

      filter_form_data = %{
        "route_type" => params["route_type"] || "",
        "agency_id" => params["agency_id"] || "",
        "active" => params["active"] || ""
      }

      {:noreply,
       socket
       |> assign(:filter_form, to_form(filter_form_data))
       |> assign(:search, search)
       |> assign(:sort_by, sort_by)
       |> assign(:sort_dir, sort_dir)
       |> assign(:page, page)
       |> assign(:total_count, total_count)
       |> assign(:available_route_types, available_route_types)
       |> assign(:available_agencies, available_agencies)
       |> assign(:routes_empty?, routes == [])
       |> stream(:routes, routes, reset: true)}
    end
  end

  @impl true
  def handle_event("filter", params, socket) do
    route_type = params["route_type"]
    agency_id = params["agency_id"]
    active = params["active"]

    query_params =
      %{}
      |> maybe_put("route_type", route_type)
      |> maybe_put("agency_id", agency_id)
      |> maybe_put("active", active)
      |> maybe_put("search", socket.assigns.search)
      |> maybe_put_sort(socket.assigns.sort_by, socket.assigns.sort_dir)

    {:noreply, push_patch(socket, to: ~p"/gtfs/#{socket.assigns.current_gtfs_version.id}/routes?#{query_params}")}
  end

  @impl true
  def handle_event("search", %{"search" => term}, socket) do
    query_params =
      %{}
      |> maybe_put("search", term)
      |> maybe_put("route_type", socket.assigns.filter_form.params["route_type"])
      |> maybe_put("agency_id", socket.assigns.filter_form.params["agency_id"])
      |> maybe_put("active", socket.assigns.filter_form.params["active"])
      |> maybe_put("sort_by", socket.assigns.sort_by)
      |> maybe_put("sort_dir", socket.assigns.sort_dir)

    {:noreply, push_patch(socket, to: ~p"/gtfs/#{socket.assigns.current_gtfs_version.id}/routes?#{query_params}")}
  end

  @impl true
  def handle_event("sort", %{"column" => column}, socket) do
    column_atom = parse_column_atom(column)
    current_sort_by = socket.assigns.sort_by
    current_sort_dir = socket.assigns.sort_dir

    {new_sort_by, new_sort_dir} =
      if column_atom == current_sort_by do
        case current_sort_dir do
          :asc -> {current_sort_by, :desc}
          :desc -> {:route_id, :asc}
        end
      else
        {column_atom, :asc}
      end

    query_params =
      %{}
      |> maybe_put("route_type", socket.assigns.filter_form.params["route_type"])
      |> maybe_put("agency_id", socket.assigns.filter_form.params["agency_id"])
      |> maybe_put("active", socket.assigns.filter_form.params["active"])
      |> maybe_put("search", socket.assigns.search)
      |> maybe_put_sort(new_sort_by, new_sort_dir)

    {:noreply, push_patch(socket, to: ~p"/gtfs/#{socket.assigns.current_gtfs_version.id}/routes?#{query_params}")}
  end

  @impl true
  def handle_event("paginate", %{"page" => page}, socket) do
    page_num = parse_integer(page, 1)

    query_params =
      %{}
      |> maybe_put("route_type", socket.assigns.filter_form.params["route_type"])
      |> maybe_put("agency_id", socket.assigns.filter_form.params["agency_id"])
      |> maybe_put("active", socket.assigns.filter_form.params["active"])
      |> maybe_put("search", socket.assigns.search)
      |> maybe_put("sort_by", socket.assigns.sort_by)
      |> maybe_put("sort_dir", socket.assigns.sort_dir)
      |> Map.put("page", page_num)

    {:noreply, push_patch(socket, to: ~p"/gtfs/#{socket.assigns.current_gtfs_version.id}/routes?#{query_params}")}
  end

  @impl true
  def handle_event("gtfs_version_loaded", %{"version_id" => version_id}, socket) do
    if socket.assigns[:pending_version_resolution] do
      current_organization = socket.assigns.current_organization

      version_to_use =
        if version_id && valid_version_for_org?(version_id, current_organization.id) do
          version_id
        else
          case Versions.get_latest_gtfs_version(current_organization.id) do
            {:ok, version} -> to_string(version.id)
            {:error, :no_versions} -> nil
          end
        end

      if version_to_use do
        {:noreply, push_navigate(socket, to: "/gtfs/#{version_to_use}/routes")}
      else
        {:noreply, socket}
      end
    else
      current_organization = socket.assigns.current_organization
      current_version_id = to_string(socket.assigns.current_gtfs_version.id)

      version_to_use =
        if version_id && valid_version_for_org?(version_id, current_organization.id) do
          version_id
        else
          case socket.assigns[:latest_gtfs_version] do
            {:ok, version} -> to_string(version.id)
            {:error, :no_versions} -> nil
            nil -> current_version_id
          end
        end

      if version_to_use && version_to_use != current_version_id do
        {:noreply, push_navigate(socket, to: "/gtfs/#{version_to_use}/routes")}
      else
        {:noreply, socket}
      end
    end
  end

  @impl true
  def handle_event("switch_gtfs_version", %{"version" => version_id}, socket) do
    socket = push_event(socket, "gtfs_version_selected", %{version_id: version_id})
    {:noreply, push_navigate(socket, to: "/gtfs/#{version_id}/routes")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <%= if assigns[:pending_version_resolution] do %>
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
          Routes
          <:subtitle>GTFS routes for the current version</:subtitle>
        </.header>

        <%!-- Filter bar --%>
        <div class="mt-6 bg-base-100 border border-base-300 rounded-lg p-4">
          <.form for={@filter_form} id="route-filter-form" phx-change="filter" class="flex flex-wrap gap-4 items-end">
            <div class="flex-1 min-w-[200px]">
              <.input
                field={@filter_form[:route_type]}
                type="select"
                label="Mode"
                prompt="All modes"
                options={Enum.map(@available_route_types || [], fn type -> {Route.route_type_label(type), type} end)}
              />
            </div>
            <div class="flex-1 min-w-[200px]">
              <.input
                field={@filter_form[:agency_id]}
                type="select"
                label="Agency"
                prompt="All agencies"
                options={Enum.map(@available_agencies || [], fn agency -> {agency, agency} end)}
              />
            </div>
            <div class="flex-1 min-w-[200px]">
              <.input
                field={@filter_form[:active]}
                type="select"
                label="Status"
                options={[{"All statuses", ""}, {"Active", "true"}, {"Inactive", "false"}]}
              />
            </div>
          </.form>

          <div class="mt-4">
            <.form for={%{}} id="search-form" phx-change="search">
              <.input
                name="search"
                type="search"
                value={@search}
                placeholder="Search routes..."
                phx-debounce="300"
                label="Search"
              />
            </.form>
          </div>
        </div>

        <div :if={@routes_empty?} class="text-center py-8 text-base-content/60">
          No routes found
        </div>

        <div :if={not @routes_empty?} class="mt-6">
          <div class="bg-base-100 border border-base-300 rounded-lg overflow-hidden">
            <div class="overflow-x-auto">
              <table class="table">
                <thead>
                  <tr class="bg-base-200">
                    <th class="w-[15%]">
                      <div
                        class="flex items-center gap-1 cursor-pointer"
                        phx-click="sort"
                        phx-value-column="route_id"
                      >
                        Route ID
                        <span :if={@sort_by == :route_id}>
                          {if @sort_dir == :asc, do: "▲", else: "▼"}
                        </span>
                      </div>
                    </th>
                    <th class="w-[15%]">
                      <div
                        class="flex items-center gap-1 cursor-pointer"
                        phx-click="sort"
                        phx-value-column="route_short_name"
                      >
                        Short Name
                        <span :if={@sort_by == :route_short_name}>
                          {if @sort_dir == :asc, do: "▲", else: "▼"}
                        </span>
                      </div>
                    </th>
                    <th class="w-[40%]">
                      <div
                        class="flex items-center gap-1 cursor-pointer"
                        phx-click="sort"
                        phx-value-column="route_long_name"
                      >
                        Long Name
                        <span :if={@sort_by == :route_long_name}>
                          {if @sort_dir == :asc, do: "▲", else: "▼"}
                        </span>
                      </div>
                    </th>
                    <th class="w-[15%]">
                      <div
                        class="flex items-center gap-1 cursor-pointer"
                        phx-click="sort"
                        phx-value-column="route_type"
                      >
                        Type
                        <span :if={@sort_by == :route_type}>
                          {if @sort_dir == :asc, do: "▲", else: "▼"}
                        </span>
                      </div>
                    </th>
                    <th class="w-[15%]">Preview</th>
                  </tr>
                </thead>
                <tbody id="routes" phx-update="stream">
                  <tr :for={{id, route} <- @streams.routes} id={id}>
                    <td>
                      <.link
                        navigate={"/gtfs/#{@current_gtfs_version.id}/routes/#{route.route_id}"}
                        class="link link-primary"
                      >
                        {route.route_id}
                      </.link>
                    </td>
                    <td>{route.route_short_name || "—"}</td>
                    <td>{route.route_long_name || "—"}</td>
                    <td>{Route.route_type_label(route.route_type)}</td>
                    <td>
                      <.route_badge route={route} />
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>

          <%!-- Pagination --%>
          <div :if={@total_count > 0} class="mt-4 flex items-center justify-between">
            <div class="text-sm text-base-content/60">
              Showing {max((@page - 1) * @per_page + 1, 1)}–{min(@page * @per_page, @total_count)} of {@total_count} routes
            </div>
            <div class="flex gap-2">
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

  defp parse_route_type(nil), do: nil
  defp parse_route_type(""), do: nil
  defp parse_route_type(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_string(nil), do: nil
  defp parse_string(""), do: nil
  defp parse_string(value) when is_binary(value), do: value

  defp parse_atom(nil, default), do: default
  defp parse_atom("", default), do: default
  defp parse_atom(value, _default) when is_binary(value) do
    try do
      String.to_existing_atom(value)
    rescue
      ArgumentError -> :route_id
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

  defp maybe_put_sort(map, :route_id, :asc), do: map
  defp maybe_put_sort(map, sort_by, sort_dir) do
    map
    |> Map.put("sort_by", sort_by)
    |> Map.put("sort_dir", sort_dir)
  end

  defp parse_column_atom(column) when is_binary(column) do
    valid_columns = [:route_id, :route_short_name, :route_long_name, :route_type, :active]

    try do
      column_atom = String.to_existing_atom(column)
      if column_atom in valid_columns, do: column_atom, else: :route_id
    rescue
      ArgumentError -> :route_id
    end
  end
end
