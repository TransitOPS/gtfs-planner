defmodule GtfsPlannerWeb.Gtfs.RoutesLive do
  @moduledoc """
  LiveView for viewing GTFS routes.
  Requires pathways_studio_editor role.
  """
  use GtfsPlannerWeb, :live_view
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.Components.RouteIdentity
  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  @impl true
  def mount(_params, _session, socket) do
    user_roles = socket.assigns[:user_roles] || []
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id
    available_route_types = Gtfs.list_distinct_route_types(organization_id, gtfs_version_id)
    available_agencies = Gtfs.list_distinct_agencies(organization_id, gtfs_version_id)

    {:ok,
     socket
     |> assign(:page_title, "Routes")
     |> assign(:user_roles, user_roles)
     |> assign(:available_route_types, available_route_types)
     |> assign(:available_agencies, available_agencies)
     |> assign(:filter_form, to_form(%{"route_type" => "", "agency_id" => "", "active" => ""}))
     |> assign(:search, "")
     |> assign(:sort_by, :route_id)
     |> assign(:sort_dir, :asc)
     |> assign(:page, 1)
     |> assign(:per_page, 50)
     |> assign(:total_count, 0)
     |> assign(:routes_empty?, true)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
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
     |> assign(:routes_empty?, routes == [])
     |> stream(:routes, routes, reset: true)}
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

    {:noreply,
     push_patch(socket,
       to: ~p"/gtfs/#{socket.assigns.current_gtfs_version.id}/routes?#{query_params}"
     )}
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

    {:noreply,
     push_patch(socket,
       to: ~p"/gtfs/#{socket.assigns.current_gtfs_version.id}/routes?#{query_params}"
     )}
  end

  @impl true
  def handle_event("sort", %{"key" => column}, socket) do
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

    {:noreply,
     push_patch(socket,
       to: ~p"/gtfs/#{socket.assigns.current_gtfs_version.id}/routes?#{query_params}"
     )}
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

    {:noreply,
     push_patch(socket,
       to: ~p"/gtfs/#{socket.assigns.current_gtfs_version.id}/routes?#{query_params}"
     )}
  end

  @impl true
  def handle_event("gtfs_version_loaded", %{"version_id" => version_id}, socket) do
    current_organization = socket.assigns.current_organization
    current_version_id = to_string(socket.assigns.current_gtfs_version.id)

    if version_id && version_id != current_version_id &&
         Versions.published_gtfs_version_for_org?(current_organization.id, version_id) do
      {:noreply, push_navigate(socket, to: "/gtfs/#{version_id}/routes")}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("switch_gtfs_version", %{"version" => version_id}, socket) do
    current_organization = socket.assigns.current_organization

    if Versions.published_gtfs_version_for_org?(current_organization.id, version_id) do
      socket = push_event(socket, "gtfs_version_selected", %{version_id: version_id})
      {:noreply, push_navigate(socket, to: "/gtfs/#{version_id}/routes")}
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
      <.header>
        Routes
        <:subtitle>GTFS routes for the current version</:subtitle>
      </.header>

      <%!-- Filter bar --%>
      <div class="mt-6 bg-base-100 border border-base-300 rounded-lg p-4">
        <.form
          for={@filter_form}
          id="route-filter-form"
          phx-change="filter"
          class="flex flex-wrap gap-4 items-end"
        >
          <div class="flex-1 min-w-[200px]">
            <.input
              field={@filter_form[:route_type]}
              type="select"
              label="Mode"
              prompt="All modes"
              options={
                Enum.map(@available_route_types || [], fn type ->
                  {Route.route_type_label(type), type}
                end)
              }
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
          <.table id="routes" rows={@streams.routes}>
            <:col
              :let={{_id, route}}
              label="Route ID"
              sort_key="route_id"
              sort_event="sort"
              sort={column_sort_state(@sort_by, @sort_dir, :route_id)}
            >
              <.link
                navigate={"/gtfs/#{@current_gtfs_version.id}/routes/#{route.route_id}"}
                class="link link-primary font-semibold"
              >
                {route.route_id}
              </.link>
            </:col>
            <:col
              :let={{_id, route}}
              label="Short Name"
              sort_key="route_short_name"
              sort_event="sort"
              sort={column_sort_state(@sort_by, @sort_dir, :route_short_name)}
            >
              {route.route_short_name || "—"}
            </:col>
            <:col
              :let={{_id, route}}
              label="Long Name"
              sort_key="route_long_name"
              sort_event="sort"
              sort={column_sort_state(@sort_by, @sort_dir, :route_long_name)}
            >
              {route.route_long_name || "—"}
            </:col>
            <:col
              :let={{_id, route}}
              label="Type"
              sort_key="route_type"
              sort_event="sort"
              sort={column_sort_state(@sort_by, @sort_dir, :route_type)}
            >
              {Route.route_type_label(route.route_type)}
            </:col>
            <:col :let={{_id, route}} label="Badge">
              <RouteIdentity.route_badge route={route} />
            </:col>
          </.table>
        </div>

        <.pagination
          :if={@total_count > 0}
          page={@page}
          per_page={@per_page}
          total={@total_count}
          entity="routes"
        />
      </div>
    </Layouts.app>
    """
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

  defp column_sort_state(sort_by, sort_dir, column) when column == sort_by do
    case sort_dir do
      :asc -> "asc"
      :desc -> "desc"
    end
  end

  defp column_sort_state(_sort_by, _sort_dir, _column), do: "none"
end
