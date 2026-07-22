defmodule GtfsPlannerWeb.Gtfs.StopsLive do
  @moduledoc """
  LiveView for browsing GTFS stops and stations.
  Requires pathways_studio_editor role.
  """
  use GtfsPlannerWeb, :live_view
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.Components.RouteIdentity
  alias GtfsPlannerWeb.Components.TransitPresentation
  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  @impl true
  def mount(_params, _session, socket) do
    user_roles = socket.assigns[:user_roles] || []

    {:ok,
     socket
     |> assign(:page_title, "Stops & stations")
     |> assign(:user_roles, user_roles)
     |> assign(
       :filter_form,
       to_form(%{"wheelchair_boarding" => "", "route_id" => "", "direction_id" => ""})
     )
     |> assign(:search_form, to_form(%{"search" => ""}))
     |> assign(:search, "")
     |> assign(:sort_by, :stop_name)
     |> assign(:sort_dir, :asc)
     |> assign(:page, 1)
     |> assign(:per_page, 50)
     |> assign(:total_count, 0)
     |> assign(:stops_empty?, false)
     |> assign(:stops_state, :loading)
     |> assign(:available_routes, [])
     |> assign(:route_id, nil)
     |> assign(:direction_id, nil)
     |> assign(:canonical_patch_identity, nil)
     |> stream(:stops, [])}
  end

  @impl true
  def handle_params(params, _url, socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    wheelchair_boarding = parse_wheelchair(params["wheelchair_boarding"])
    route_id = params["route_id"] || ""
    direction_id = parse_direction(params["direction_id"])
    search = params["search"] || ""
    sort_by = parse_column_atom(params["sort_by"]) || :stop_name
    sort_dir = parse_atom(params["sort_dir"], :asc)
    page = parse_integer(params["page"], 1)
    per_page = socket.assigns.per_page

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

    filter_form =
      to_form(%{
        "wheelchair_boarding" => params["wheelchair_boarding"] || "",
        "route_id" => route_id,
        "direction_id" => params["direction_id"] || ""
      })

    socket =
      socket
      |> assign(:filter_form, filter_form)
      |> assign(:search_form, to_form(%{"search" => search}))
      |> assign(:search, search)
      |> assign(:sort_by, sort_by)
      |> assign(:sort_dir, sort_dir)
      |> assign(:page, page)
      |> assign(:route_id, route_id)
      |> assign(:direction_id, direction_id)

    canonical_patch_identity = {gtfs_version_id, opts}

    cond do
      not connected?(socket) ->
        {:noreply, socket}

      socket.assigns.canonical_patch_identity == canonical_patch_identity ->
        {:noreply, assign(socket, :canonical_patch_identity, nil)}

      true ->
        organization_id
        |> Gtfs.load_stop_catalog(gtfs_version_id, opts)
        |> apply_catalog_result(socket, opts)
    end
  end

  @impl true
  def handle_event("gtfs_version_loaded", %{"version_id" => version_id}, socket) do
    current_organization = socket.assigns.current_organization
    current_version_id = to_string(socket.assigns.current_gtfs_version.id)

    if version_id && version_id != current_version_id &&
         Versions.published_gtfs_version_for_org?(current_organization.id, version_id) do
      {:noreply, push_navigate(socket, to: "/gtfs/#{version_id}/stops")}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("switch_gtfs_version", %{"version" => version_id}, socket) do
    current_organization = socket.assigns.current_organization

    if Versions.published_gtfs_version_for_org?(current_organization.id, version_id) do
      socket = push_event(socket, "gtfs_version_selected", %{version_id: version_id})
      {:noreply, push_navigate(socket, to: "/gtfs/#{version_id}/stops")}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("filter", params, socket) do
    wheelchair_boarding = params["wheelchair_boarding"]
    route_id = params["route_id"]
    direction_id = params["direction_id"]

    query_params =
      %{}
      |> maybe_put("wheelchair_boarding", wheelchair_boarding)
      |> maybe_put("route_id", route_id)
      |> maybe_put("direction_id", direction_id)
      |> maybe_put("search", socket.assigns.search)
      |> maybe_put_sort(socket.assigns.sort_by, socket.assigns.sort_dir)

    {:noreply,
     push_patch(socket,
       to: ~p"/gtfs/#{socket.assigns.current_gtfs_version.id}/stops?#{query_params}"
     )}
  end

  @impl true
  def handle_event("search", %{"search" => term}, socket) do
    query_params =
      %{}
      |> maybe_put("search", term)
      |> maybe_put(
        "wheelchair_boarding",
        socket.assigns.filter_form.params["wheelchair_boarding"]
      )
      |> maybe_put("route_id", socket.assigns.filter_form.params["route_id"])
      |> maybe_put("direction_id", socket.assigns.filter_form.params["direction_id"])
      |> maybe_put_sort(socket.assigns.sort_by, socket.assigns.sort_dir)

    {:noreply,
     push_patch(socket,
       to: ~p"/gtfs/#{socket.assigns.current_gtfs_version.id}/stops?#{query_params}"
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
          :desc -> {:stop_name, :asc}
        end
      else
        {column_atom, :asc}
      end

    query_params =
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
       to: ~p"/gtfs/#{socket.assigns.current_gtfs_version.id}/stops?#{query_params}"
     )}
  end

  @impl true
  def handle_event("paginate", %{"page" => page}, socket) do
    page_num = parse_integer(page, 1)
    query_params = build_query_params(socket, page_num)

    {:noreply,
     push_patch(socket,
       to: ~p"/gtfs/#{socket.assigns.current_gtfs_version.id}/stops?#{query_params}"
     )}
  end

  @impl true
  def handle_event("retry", _params, socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    opts = [
      wheelchair_boarding:
        parse_wheelchair(socket.assigns.filter_form.params["wheelchair_boarding"]),
      route_id: socket.assigns.filter_form.params["route_id"] || "",
      direction_id: parse_direction(socket.assigns.filter_form.params["direction_id"]),
      search: socket.assigns.search,
      sort_by: socket.assigns.sort_by,
      sort_dir: socket.assigns.sort_dir,
      page: socket.assigns.page,
      per_page: socket.assigns.per_page
    ]

    case Gtfs.load_stop_catalog(organization_id, gtfs_version_id, opts) do
      {:ok,
       %{
         rows: stops,
         total_count: total_count,
         page: canonical_page,
         available_routes: available_routes,
         routes_by_stop: routes_by_stop
       }} ->
        stops_with_routes =
          Enum.map(stops, fn s ->
            Map.put(s, :routes, Map.get(routes_by_stop, s.stop_id, []))
          end)

        {:noreply,
         socket
         |> assign(:page, canonical_page)
         |> assign(:total_count, total_count)
         |> assign(:available_routes, available_routes)
         |> assign(:stops_empty?, stops == [])
         |> assign(:stops_state, :ready)
         |> stream(:stops, stops_with_routes, reset: true)}

      {:partial,
       %{
         rows: stops,
         total_count: total_count,
         page: canonical_page,
         available_routes: available_routes
       }, :route_enrichment_unavailable} ->
        stops_with_empty_routes =
          Enum.map(stops, fn s -> Map.put(s, :routes, []) end)

        {:noreply,
         socket
         |> assign(:page, canonical_page)
         |> assign(:total_count, total_count)
         |> assign(:available_routes, available_routes)
         |> assign(:stops_empty?, stops == [])
         |> assign(:stops_state, :route_enrichment_unavailable)
         |> stream(:stops, stops_with_empty_routes, reset: true)}

      {:error, :unavailable} ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("clear_filters", _params, socket) do
    {:noreply,
     push_patch(socket,
       to: ~p"/gtfs/#{socket.assigns.current_gtfs_version.id}/stops"
     )}
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
        Stops &amp; stations
        <:subtitle>All top-level stops and stations in the feed.</:subtitle>
      </.header>

      <div class="mt-6 bg-base-100 border border-base-300 rounded-box p-4">
        <.form
          for={@filter_form}
          id="stop-filter-form"
          phx-change="filter"
          class="flex flex-wrap gap-4 items-end"
        >
          <div class="flex-1 min-w-[200px]">
            <.input
              field={@filter_form[:route_id]}
              type="select"
              label="Route"
              prompt="All routes"
              disabled={@stops_state == :loading}
              options={route_options(@available_routes, @route_id)}
            />
          </div>
          <%= if @route_id && @route_id != "" do %>
            <div class="flex-1 min-w-[200px]">
              <.input
                field={@filter_form[:direction_id]}
                type="select"
                label="Direction"
                prompt="All directions"
                disabled={@stops_state == :loading}
                options={[{"Direction 0", 0}, {"Direction 1", 1}]}
              />
            </div>
          <% end %>
          <div class="flex-1 min-w-[200px]">
            <.input
              field={@filter_form[:wheelchair_boarding]}
              type="select"
              label="Accessibility"
              prompt="All accessibility"
              disabled={@stops_state == :loading}
              options={[{"Accessible", 1}, {"Not accessible", 2}, {"No data", 0}]}
            />
          </div>
        </.form>

        <div class="mt-4 max-w-md">
          <.form for={@search_form} id="stop-search-form" phx-change="search">
            <.input
              field={@search_form[:search]}
              type="search"
              placeholder="Search names and IDs"
              phx-debounce="300"
              label="Search"
              disabled={@stops_state == :loading}
            />
            <p class="mt-1 text-xs text-base-content/70">Search names and IDs</p>
          </.form>
        </div>
      </div>

      <div
        :if={@stops_state == :loading}
        id="stops-loading"
        role="status"
        aria-live="polite"
        aria-busy="true"
        class="mt-6"
      >
        <div class="flex items-center justify-center py-12">
          <span class="loading loading-spinner loading-lg text-primary"></span>
          <span class="ml-3 text-base-content/70">Loading stops...</span>
        </div>
      </div>

      <div
        :if={@stops_state == :unavailable}
        id="stops-unavailable"
        class="mt-6"
      >
        <.callout kind="error" title="Stop catalog unavailable">
          The stop catalog is temporarily unavailable. Please try again.
          <.button
            id="stops-retry"
            phx-click="retry"
            variant="secondary"
            size="sm"
            class="mt-2"
          >
            Retry
          </.button>
        </.callout>
      </div>

      <div
        :if={@stops_state == :route_enrichment_unavailable}
        id="stops-enrichment-warning"
        class="mt-6"
      >
        <.callout kind="warning" title="Route information unavailable">
          Route badges could not be loaded. Stops are shown without route information.
          <.button
            id="stops-enrichment-retry"
            phx-click="retry"
            variant="secondary"
            size="sm"
            class="mt-2"
          >
            Retry
          </.button>
        </.callout>
      </div>

      <div
        :if={
          @stops_state in [:ready, :route_enrichment_unavailable] and @stops_empty? and
            has_active_constraints?(assigns)
        }
        id="stops-constrained-empty"
        class="mt-6"
      >
        <.empty_state title="No stops match your filters">
          Try adjusting your search or filter criteria.
          <:action>
            <.button
              id="stops-clear-filters"
              phx-click="clear_filters"
              variant="secondary"
              size="sm"
            >
              {if @search != "" and no_filter_active?(assigns),
                do: "Clear search",
                else: "Clear filters"}
            </.button>
          </:action>
        </.empty_state>
      </div>

      <div
        :if={
          @stops_state in [:ready, :route_enrichment_unavailable] and @stops_empty? and
            not has_active_constraints?(assigns)
        }
        id="stops-first-use-empty"
        class="mt-6"
      >
        <.empty_state title="No stops yet">
          Stops appear here after you import a GTFS feed.
          <:action>
            <.link
              navigate={~p"/gtfs/#{@current_gtfs_version.id}/import"}
              class="btn btn-primary btn-sm"
            >
              Import feed
            </.link>
          </:action>
        </.empty_state>
      </div>

      <div
        :if={
          @stops_state == :loading or
            (@stops_state in [:ready, :route_enrichment_unavailable] and not @stops_empty?)
        }
        class="mt-6"
      >
        <div class="bg-base-100 border border-base-300 rounded-box overflow-hidden">
          <.table
            id="stops"
            rows={@streams.stops}
            responsive="stack"
            disabled={@stops_state == :loading}
          >
            <:col
              :let={{_id, stop}}
              label="Stop ID"
              sort_key="stop_id"
              sort_event="sort"
              sort={column_sort_state(@sort_by, @sort_dir, :stop_id)}
            >
              <.link
                navigate={"/gtfs/#{@current_gtfs_version.id}/stops/#{stop.stop_id}"}
                class="link link-primary font-semibold font-mono tabular-nums"
              >
                {stop.stop_id}
              </.link>
            </:col>
            <:col
              :let={{_id, stop}}
              label="Name"
              sort_key="stop_name"
              sort_event="sort"
              sort={column_sort_state(@sort_by, @sort_dir, :stop_name)}
            >
              {stop.stop_name}
            </:col>
            <:col
              :let={{_id, stop}}
              label="Type"
              sort_key="location_type"
              sort_event="sort"
              sort={column_sort_state(@sort_by, @sort_dir, :location_type)}
            >
              {Stop.location_type_label(stop.location_type)}
            </:col>
            <:col :let={{_id, stop}} label="Accessibility">
              <TransitPresentation.accessibility_status
                status={accessibility_status(stop)}
                source={accessibility_source(stop)}
              />
            </:col>
            <:col :let={{_id, stop}} label="Routes">
              <%= if stop.routes == [] do %>
                <span class="text-base-content/40">No routes</span>
              <% else %>
                <div class="flex flex-wrap gap-1">
                  <%= for route <- Enum.take(stop.routes, 5) do %>
                    <RouteIdentity.route_badge route={route} />
                  <% end %>
                  <%= if length(stop.routes) > 5 do %>
                    <span class="inline-flex items-center justify-center rounded px-2 py-0.5 text-xs font-medium bg-base-300 text-base-content">
                      +{length(stop.routes) - 5}
                    </span>
                  <% end %>
                </div>
              <% end %>
            </:col>
          </.table>
        </div>

        <.pagination
          :if={@stops_state == :loading or @total_count > 0}
          page={@page}
          per_page={@per_page}
          total={@total_count}
          entity="stops &amp; stations"
          disabled={@stops_state == :loading}
        />
      </div>
    </Layouts.app>
    """
  end

  defp apply_catalog_result(
         {:ok,
          %{
            rows: stops,
            total_count: total_count,
            page: canonical_page,
            available_routes: available_routes,
            routes_by_stop: routes_by_stop
          }},
         socket,
         opts
       ) do
    stops_with_routes =
      Enum.map(stops, fn s ->
        Map.put(s, :routes, Map.get(routes_by_stop, s.stop_id, []))
      end)

    socket =
      socket
      |> assign(:page, canonical_page)
      |> assign(:total_count, total_count)
      |> assign(:available_routes, available_routes)
      |> assign(:stops_empty?, stops == [])
      |> assign(:stops_state, :ready)
      |> stream(:stops, stops_with_routes, reset: true)

    maybe_patch_page(socket, canonical_page, opts)
  end

  defp apply_catalog_result(
         {:partial,
          %{
            rows: stops,
            total_count: total_count,
            page: canonical_page,
            available_routes: available_routes
          }, :route_enrichment_unavailable},
         socket,
         opts
       ) do
    stops_with_empty_routes =
      Enum.map(stops, fn s -> Map.put(s, :routes, []) end)

    socket =
      socket
      |> assign(:page, canonical_page)
      |> assign(:total_count, total_count)
      |> assign(:available_routes, available_routes)
      |> assign(:stops_empty?, stops == [])
      |> assign(:stops_state, :route_enrichment_unavailable)
      |> stream(:stops, stops_with_empty_routes, reset: true)

    maybe_patch_page(socket, canonical_page, opts)
  end

  defp apply_catalog_result({:error, :unavailable}, socket, _opts) do
    {:noreply,
     socket
     |> assign(:stops_empty?, true)
     |> assign(:stops_state, :unavailable)
     |> stream(:stops, [], reset: true)}
  end

  defp maybe_patch_page(socket, canonical_page, opts) do
    if canonical_page != Keyword.fetch!(opts, :page) do
      query_params = build_query_params(socket, canonical_page)

      canonical_patch_identity =
        {socket.assigns.current_gtfs_version.id, Keyword.replace!(opts, :page, canonical_page)}

      {:noreply,
       socket
       |> assign(:canonical_patch_identity, canonical_patch_identity)
       |> push_patch(
         to: ~p"/gtfs/#{socket.assigns.current_gtfs_version.id}/stops?#{query_params}"
       )}
    else
      {:noreply, socket}
    end
  end

  defp has_active_constraints?(assigns) do
    search_active = assigns.search != ""
    filter_active = not no_filter_active?(assigns)
    search_active or filter_active
  end

  defp no_filter_active?(assigns) do
    params = assigns.filter_form.params

    params["wheelchair_boarding"] in [nil, ""] and
      params["route_id"] in [nil, ""] and
      params["direction_id"] in [nil, ""]
  end

  defp build_query_params(socket, page) do
    %{}
    |> maybe_put("wheelchair_boarding", socket.assigns.filter_form.params["wheelchair_boarding"])
    |> maybe_put("route_id", socket.assigns.filter_form.params["route_id"])
    |> maybe_put("direction_id", socket.assigns.filter_form.params["direction_id"])
    |> maybe_put("search", socket.assigns.search)
    |> maybe_put("sort_by", socket.assigns.sort_by)
    |> maybe_put("sort_dir", socket.assigns.sort_dir)
    |> Map.put("page", page)
  end

  defp route_options(available_routes, selected_route_id) do
    options =
      Enum.map(available_routes, fn route ->
        display =
          if route.route_short_name do
            "#{route.route_short_name} (#{route.route_id})"
          else
            route.route_id
          end

        {display, route.route_id}
      end)

    if selected_route_id in [nil, ""] or
         Enum.any?(available_routes, &(&1.route_id == selected_route_id)) do
      options
    else
      [{selected_route_id, selected_route_id} | options]
    end
  end

  defp accessibility_status(%{wheelchair_boarding: 1}), do: :accessible
  defp accessibility_status(%{wheelchair_boarding: 2}), do: :not_accessible
  defp accessibility_status(_), do: :unknown

  defp accessibility_source(%{wheelchair_boarding: wb}) when wb in [1, 2], do: :direct
  defp accessibility_source(_), do: :missing

  defp parse_wheelchair(nil), do: nil
  defp parse_wheelchair(""), do: nil
  defp parse_wheelchair(val) when is_binary(val), do: String.to_integer(val)
  defp parse_wheelchair(val) when is_integer(val), do: val

  defp parse_direction(nil), do: nil
  defp parse_direction(""), do: nil
  defp parse_direction(val) when is_binary(val), do: String.to_integer(val)
  defp parse_direction(val) when is_integer(val), do: val

  defp parse_atom(nil, default), do: default
  defp parse_atom("", default), do: default

  defp parse_atom(val, default) when is_binary(val) do
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

  defp maybe_put_sort(map, :stop_name, :asc), do: map

  defp maybe_put_sort(map, sort_by, sort_dir) do
    map
    |> Map.put("sort_by", sort_by)
    |> Map.put("sort_dir", sort_dir)
  end

  defp parse_column_atom(column)
       when column in ["stop_id", "stop_name", "location_type", "route_id"] do
    String.to_existing_atom(column)
  end

  defp parse_column_atom(_), do: nil

  defp column_sort_state(sort_by, sort_dir, column) when column == sort_by do
    case sort_dir do
      :asc -> "asc"
      :desc -> "desc"
    end
  end

  defp column_sort_state(_sort_by, _sort_dir, _column), do: "none"
end
