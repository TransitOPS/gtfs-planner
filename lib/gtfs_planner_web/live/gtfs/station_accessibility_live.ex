defmodule GtfsPlannerWeb.Gtfs.StationAccessibilityLive do
  @moduledoc """
  Strictly read-only LiveView for station step-free accessibility validation.

  Renders two scale-adaptive surfaces backed by `StationReport2.Accessibility`,
  `AccessibilityGrouping`, and `AccessibilitySchematic`:

    * `Network` (`Rider routes` and `Validation` tabs with a cross-level SVG
      swimlane schematic) for stations within the readability threshold
      (`network_available? == true`).
    * `Impact & routes` (4-tile KPI strip, on-demand collapsed route stepper,
      impact-ranked issues, grouped access matrix with inline drill-down, and
      3-column elevator dependency table) for all stations, and exclusively for
      stations above the schematic threshold (`CR-S4`).

  Remediation links navigate to Floorplans (`?level=&edit_pathway_id=`) for
  pathway edits and to Station Report (`?edit_stop_id=`) for stop edits
  (`CR-S1`). This LiveView owns no write operations or edit drawers.
  """
  use GtfsPlannerWeb, :live_view

  import GtfsPlannerWeb.Gtfs.StationAccessibilityComponents
  import GtfsPlannerWeb.StationWorkspace, only: [station_header: 1]

  alias GtfsPlanner.Gtfs

  alias GtfsPlanner.Gtfs.StationReport2.{
    Accessibility,
    AccessibilityGrouping,
    AccessibilitySchematic
  }

  alias GtfsPlanner.Versions
  alias GtfsPlanner.Wording

  on_mount({GtfsPlannerWeb.EnsureRole, :require_gtfs_access})

  @load_key :accessibility_load

  @default_highlights %{
    barriers: false,
    unknown_data: true,
    near_threshold: true,
    single_elevator: true
  }

  @highlight_keys %{
    "barriers" => :barriers,
    "unknown_data" => :unknown_data,
    "near_threshold" => :near_threshold,
    "single_elevator" => :single_elevator
  }

  @impl true
  def mount(_params, _session, socket) do
    user_roles = socket.assigns[:user_roles] || []

    {:ok,
     socket
     |> assign(:page_title, "Step-free accessibility")
     |> assign(:user_roles, user_roles)
     |> assign(:stop_id, nil)
     |> assign(:generation, 0)
     |> assign(:load_scope, nil)
     |> assign(:view_state, :initial_loading)
     |> assign(:report_error, nil)
     |> assign(:url_params, default_url_params())
     |> clear_model()
     |> put_derived_state()}
  end

  @impl true
  def handle_params(%{"stop_id" => stop_id} = params, _uri, socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id
    url_params = parse_url_params(params)

    if active_scope?(socket, organization_id, gtfs_version_id, stop_id) do
      socket = assign(socket, :url_params, url_params)

      socket =
        if socket.assigns.analysis do
          apply_url_params(socket, url_params)
        else
          socket
        end

      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(:stop_id, stop_id)
       |> assign(:url_params, url_params)
       |> clear_model()
       |> start_accessibility_load(:initial_loading)}
    end
  end

  # -- Asynchronous loading with generation-scoped cancellation --------------

  @impl true
  def handle_async(@load_key, {:ok, {:loaded, scope, loaded}}, socket) do
    if scope == socket.assigns.load_scope do
      {:noreply, apply_loaded_model(socket, loaded)}
    else
      {:noreply, socket}
    end
  end

  def handle_async(@load_key, {:ok, {:load_failed, scope, :not_found}}, socket) do
    if scope == socket.assigns.load_scope do
      {_organization_id, gtfs_version_id, _stop_id, _generation} = scope

      {:noreply,
       socket
       |> cancel_async(@load_key)
       |> put_flash(:error, "Station not found")
       |> push_navigate(to: "/gtfs/#{gtfs_version_id}/stops")}
    else
      {:noreply, socket}
    end
  end

  def handle_async(@load_key, {:ok, {:load_failed, scope, _reason}}, socket) do
    if scope == socket.assigns.load_scope do
      {:noreply, assign_load_error(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_async(@load_key, {:exit, {:shutdown, :cancel}}, socket), do: {:noreply, socket}

  def handle_async(@load_key, {:exit, _reason}, socket) do
    if socket.assigns.view_state in [:initial_loading, :refreshing] do
      {:noreply, assign_load_error(socket)}
    else
      {:noreply, socket}
    end
  end

  # -- Read-only interaction events ------------------------------------------

  @impl true
  def handle_event("switch_view", %{"view" => view_str}, socket) do
    case socket.assigns.analysis do
      nil ->
        {:noreply, socket}

      analysis ->
        next_view = normalize_view(view_str, analysis.network_available?)

        socket =
          socket
          |> assign(:active_view, next_view)
          |> maybe_ensure_selected_route()
          |> maybe_rebuild_schematic()

        {:noreply, socket}
    end
  end

  def handle_event("switch_view", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("switch_tab", %{"tab" => tab_str}, socket) do
    next_tab = parse_tab(tab_str)

    socket =
      socket
      |> assign(:active_tab, next_tab)
      |> maybe_rebuild_schematic()

    {:noreply, socket}
  end

  def handle_event("switch_tab", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("toggle_highlight", %{"key" => key_str}, socket) do
    case Map.get(@highlight_keys, key_str) do
      nil ->
        {:noreply, socket}

      key ->
        highlights = Map.update!(socket.assigns.highlights, key, &(not &1))

        socket =
          socket
          |> assign(:highlights, highlights)
          |> maybe_rebuild_schematic()

        {:noreply, socket}
    end
  end

  def handle_event("toggle_highlight", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("inspect_barriers", _params, socket) do
    case socket.assigns.analysis do
      %{network_available?: true} ->
        highlights = Map.put(socket.assigns.highlights, :barriers, true)

        socket =
          socket
          |> assign(:active_view, :network)
          |> assign(:active_tab, :validation)
          |> assign(:highlights, highlights)
          |> maybe_rebuild_schematic()

        {:noreply, socket}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("select_route", %{"from" => from_id, "to" => to_id} = params, socket) do
    direction = parse_direction(params["direction"], socket.assigns.route_direction)
    {:noreply, handle_select_route(socket, from_id, to_id, direction)}
  end

  def handle_event("select_route", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("toggle_direction", %{"direction" => dir_str}, socket) do
    direction = parse_direction(dir_str, socket.assigns.route_direction)

    {:noreply,
     handle_select_route(
       socket,
       socket.assigns.selected_from,
       socket.assigns.selected_to,
       direction
     )}
  end

  def handle_event("toggle_direction", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("toggle_corridor", %{"corridor_id" => corridor_id}, socket)
      when is_binary(corridor_id) do
    expanded = toggle_member(socket.assigns.expanded_corridors, corridor_id)
    {:noreply, assign(socket, :expanded_corridors, expanded)}
  end

  def handle_event("toggle_corridor", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event(
        "select_cell",
        %{"entrance_group_id" => eg_id, "platform_group_id" => pg_id},
        socket
      ) do
    case socket.assigns.groups do
      %{cells: cells} ->
        key = {eg_id, pg_id}

        next_cell =
          cond do
            not Map.has_key?(cells, key) -> socket.assigns.selected_cell
            socket.assigns.selected_cell == key -> nil
            true -> key
          end

        {:noreply, assign(socket, :selected_cell, next_cell)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("select_cell", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("close_cell_drilldown", _params, socket) do
    {:noreply, assign(socket, :selected_cell, nil)}
  end

  @impl true
  def handle_event("toggle_issue_edges", %{"issue_id" => issue_id}, socket)
      when is_binary(issue_id) do
    expanded = toggle_member(socket.assigns.expanded_issue_ids, issue_id)
    {:noreply, assign(socket, :expanded_issue_ids, expanded)}
  end

  def handle_event("toggle_issue_edges", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("retry_load", _params, socket) do
    if socket.assigns.view_state in [:initial_loading, :refreshing] do
      {:noreply, socket}
    else
      next_state = if(socket.assigns.analysis, do: :refreshing, else: :initial_loading)
      {:noreply, start_accessibility_load(socket, next_state)}
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
        if stop_id,
          do: ~p"/gtfs/#{version_id}/stops/#{stop_id}/report/accessibility",
          else: "/gtfs/#{version_id}/stops"

      {:noreply,
       socket
       |> cancel_async(@load_key)
       |> push_navigate(to: path)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("gtfs_version_loaded", _params, socket), do: {:noreply, socket}

  # -- Render ----------------------------------------------------------------

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
        <.station_header
          title={station_title(@station, @stop_id)}
          stop_id={@stop_id}
          gtfs_version_id={@current_gtfs_version.id}
          active_tab={:report}
        >
          <:meta :if={@snapshot}>Station · {station_facts(@snapshot)}</:meta>
        </.station_header>
      </:sub_header>

      <div
        id="station-accessibility-page"
        class="ds-page pb-16 pt-2"
        data-derived-state={@derived_state}
      >
        <.page_header
          gtfs_version_id={@current_gtfs_version.id}
          stop_id={@stop_id}
          analysis={@analysis}
          snapshot={@snapshot}
          derived_state={@derived_state}
          active_view={@active_view}
        />

        <.refreshing_banner refreshing?={@view_state == :refreshing} />

        <.incomplete_notice :if={@analysis} analysis={@analysis} />

        <%= case @derived_state do %>
          <% :loading -> %>
            <.loading_state />
          <% :error -> %>
            <.error_state />
          <% :empty_topology -> %>
            <.empty_topology_state
              gtfs_version_id={@current_gtfs_version.id}
              stop_id={@stop_id}
              analysis={@analysis}
            />
          <% :no_step_free_access -> %>
            <.no_step_free_state
              gtfs_version_id={@current_gtfs_version.id}
              stop_id={@stop_id}
              analysis={@analysis}
              active_view={@active_view}
              active_tab={@active_tab}
              highlights={@highlights}
              schematic_layout={@schematic_layout}
              edges_by_pathway_id={@edges_by_pathway_id}
              expanded_issue_ids={@expanded_issue_ids}
            />
          <% :ready -> %>
            <%= if @active_view == :network && @analysis.network_available? && @schematic_layout do %>
              <.network_view
                gtfs_version_id={@current_gtfs_version.id}
                stop_id={@stop_id}
                analysis={@analysis}
                active_tab={@active_tab}
                highlights={@highlights}
                schematic_layout={@schematic_layout}
                edges_by_pathway_id={@edges_by_pathway_id}
                expanded_issue_ids={@expanded_issue_ids}
              />
            <% else %>
              <.impact_view
                gtfs_version_id={@current_gtfs_version.id}
                stop_id={@stop_id}
                analysis={@analysis}
                groups={@groups}
                curated_pairs={@curated_pairs}
                selected_from={@selected_from}
                selected_to={@selected_to}
                route_direction={@route_direction}
                selected_route={@selected_route}
                collapsed_route_items={@collapsed_route_items}
                expanded_corridors={@expanded_corridors}
                selected_cell={@selected_cell}
                edges_by_pathway_id={@edges_by_pathway_id}
                expanded_issue_ids={@expanded_issue_ids}
              />
            <% end %>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  # -- Private: Async load orchestration -------------------------------------

  defp start_accessibility_load(socket, view_state) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id
    stop_id = socket.assigns.stop_id
    generation = socket.assigns.generation + 1
    scope = {organization_id, gtfs_version_id, stop_id, generation}

    socket
    |> assign(:generation, generation)
    |> assign(:load_scope, scope)
    |> assign(:view_state, view_state)
    |> assign(:report_error, nil)
    |> put_derived_state()
    |> cancel_async(@load_key)
    |> start_async(@load_key, fn -> load_accessibility(scope) end)
  end

  defp load_accessibility({organization_id, gtfs_version_id, stop_id, _generation} = scope) do
    case snapshot_source().get_station_report_snapshot(
           organization_id,
           gtfs_version_id,
           stop_id
         ) do
      {:ok, %{station: %{location_type: 1}} = snapshot} ->
        platform_stop_ids =
          snapshot.child_stops
          |> Enum.filter(&(Map.get(&1, :location_type) in [0, 4]))
          |> Enum.map(& &1.stop_id)

        routes_by_stop =
          if platform_stop_ids == [] do
            %{}
          else
            Gtfs.get_routes_for_stops(organization_id, gtfs_version_id, platform_stop_ids)
          end

        analysis = Accessibility.build(snapshot, routes_by_stop)
        fare_zones = AccessibilityGrouping.partition_fare_zones(snapshot)
        groups = AccessibilityGrouping.build_groups(snapshot, analysis)

        {:loaded, scope,
         %{
           snapshot: snapshot,
           station: snapshot.station,
           analysis: analysis,
           fare_zones: fare_zones,
           groups: groups
         }}

      {:ok, _non_station_snapshot} ->
        {:load_failed, scope, :not_found}

      {:error, reason} ->
        {:load_failed, scope, reason}
    end
  rescue
    exception -> {:load_failed, scope, exception}
  catch
    kind, reason -> {:load_failed, scope, {kind, reason}}
  end

  defp snapshot_source do
    Application.get_env(:gtfs_planner, :station_report_snapshot_source, Gtfs)
  end

  defp active_scope?(socket, organization_id, gtfs_version_id, stop_id) do
    case socket.assigns.load_scope do
      {^organization_id, ^gtfs_version_id, ^stop_id, _generation} -> true
      _ -> false
    end
  end

  # -- Private: State transitions --------------------------------------------

  defp clear_model(socket) do
    socket
    |> assign(:snapshot, nil)
    |> assign(:station, nil)
    |> assign(:analysis, nil)
    |> assign(:fare_zones, nil)
    |> assign(:groups, nil)
    |> assign(:edges_by_pathway_id, %{})
    |> assign(:active_view, :network)
    |> assign(:active_tab, :rider_routes)
    |> assign(:highlights, @default_highlights)
    |> assign(:schematic_layout, nil)
    |> assign(:curated_pairs, [])
    |> assign(:selected_from, nil)
    |> assign(:selected_to, nil)
    |> assign(:route_direction, :to_platform)
    |> assign(:selected_route, nil)
    |> assign(:collapsed_route_items, [])
    |> assign(:expanded_corridors, MapSet.new())
    |> assign(:selected_cell, nil)
    |> assign(:expanded_issue_ids, MapSet.new())
  end

  defp assign_load_error(socket) do
    socket
    |> assign(:view_state, :error)
    |> assign(:report_error, :load)
    |> put_derived_state()
  end

  defp put_derived_state(socket) do
    derived =
      Accessibility.derive_view_state(%{
        view_state: socket.assigns.view_state,
        report_error: socket.assigns.report_error,
        model: socket.assigns.analysis
      })

    assign(socket, :derived_state, derived)
  end

  defp apply_loaded_model(socket, loaded) do
    edges_by_pathway_id = Map.new(loaded.analysis.edges, &{&1.pathway_id, &1})

    socket
    |> assign(:snapshot, loaded.snapshot)
    |> assign(:station, loaded.station)
    |> assign(:analysis, loaded.analysis)
    |> assign(:fare_zones, loaded.fare_zones)
    |> assign(:groups, loaded.groups)
    |> assign(:edges_by_pathway_id, edges_by_pathway_id)
    |> assign(:view_state, :ready)
    |> assign(:report_error, nil)
    |> assign(
      :page_title,
      "#{station_title(loaded.station, socket.assigns.stop_id)} · Step-free accessibility"
    )
    |> put_derived_state()
    |> apply_url_params(socket.assigns.url_params)
  end

  defp apply_url_params(socket, url_params) do
    analysis = socket.assigns.analysis
    groups = socket.assigns.groups

    valid_pair = resolve_valid_pair(analysis, url_params.from, url_params.to)
    has_url_pair? = not is_nil(valid_pair)

    active_view = resolve_initial_view(url_params.view, has_url_pair?, analysis)
    active_tab = url_params.tab
    selected_cell = resolve_valid_cell(groups, url_params.cell)

    {selected_from, selected_to} =
      case valid_pair do
        {from_id, to_id} -> {from_id, to_id}
        nil -> default_route_pair(analysis)
      end

    curated_pairs = build_curated_pairs(analysis, selected_from, selected_to)

    socket
    |> assign(:active_view, active_view)
    |> assign(:active_tab, active_tab)
    |> assign(:selected_cell, selected_cell)
    |> assign(:curated_pairs, curated_pairs)
    |> assign(:selected_from, selected_from)
    |> assign(:selected_to, selected_to)
    |> assign(:route_direction, :to_platform)
    |> assign(:selected_route, nil)
    |> assign(:collapsed_route_items, [])
    |> assign(:expanded_corridors, MapSet.new())
    |> maybe_ensure_selected_route()
    |> maybe_rebuild_schematic()
  end

  defp handle_select_route(socket, from_id, to_id, direction) do
    case socket.assigns.analysis do
      nil ->
        socket

      analysis ->
        case resolve_valid_pair(analysis, from_id, to_id) do
          nil ->
            socket

          {valid_from, valid_to} ->
            curated = build_curated_pairs(analysis, valid_from, valid_to)

            socket
            |> assign(:active_view, :impact)
            |> assign(:selected_from, valid_from)
            |> assign(:selected_to, valid_to)
            |> assign(:route_direction, direction)
            |> assign(:curated_pairs, curated)
            |> assign(:expanded_corridors, MapSet.new())
            |> build_selected_route(valid_from, valid_to, direction)
        end
    end
  end

  defp maybe_ensure_selected_route(socket) do
    if socket.assigns.active_view == :impact and
         is_nil(socket.assigns.selected_route) and
         is_binary(socket.assigns.selected_from) and
         is_binary(socket.assigns.selected_to) do
      build_selected_route(
        socket,
        socket.assigns.selected_from,
        socket.assigns.selected_to,
        socket.assigns.route_direction
      )
    else
      socket
    end
  end

  defp build_selected_route(socket, from_id, to_id, direction) do
    case Accessibility.build_route(socket.assigns.snapshot, from_id, to_id, direction: direction) do
      :no_route ->
        socket
        |> assign(:selected_route, :no_route)
        |> assign(:collapsed_route_items, [])

      route when is_map(route) ->
        collapsed =
          AccessibilityGrouping.collapse_corridors(route.steps, socket.assigns.fare_zones)

        socket
        |> assign(:selected_route, route)
        |> assign(:collapsed_route_items, collapsed)
    end
  end

  defp maybe_rebuild_schematic(socket) do
    analysis = socket.assigns.analysis

    if analysis && analysis.network_available? do
      mode = if(socket.assigns.active_tab == :validation, do: :validation, else: :rider)

      layout =
        AccessibilitySchematic.build_layout(socket.assigns.snapshot, analysis,
          mode: mode,
          highlights: socket.assigns.highlights,
          fare_zones: socket.assigns.fare_zones
        )

      assign(socket, :schematic_layout, layout)
    else
      assign(socket, :schematic_layout, nil)
    end
  end

  # -- Private: URL & route selection helpers --------------------------------

  defp default_url_params do
    %{view: nil, tab: :rider_routes, from: nil, to: nil, cell: nil}
  end

  defp parse_url_params(params) do
    %{
      view: parse_view(params["view"]),
      tab: parse_tab(params["tab"]),
      from: presence(params["from"]),
      to: presence(params["to"]),
      cell: parse_cell_param(params["cell"])
    }
  end

  defp parse_view("network"), do: :network
  defp parse_view("impact"), do: :impact
  defp parse_view(_), do: nil

  defp parse_tab("validation"), do: :validation
  defp parse_tab(_), do: :rider_routes

  defp parse_direction("to_exit", _fallback), do: :to_exit
  defp parse_direction("to_platform", _fallback), do: :to_platform
  defp parse_direction(_, fallback), do: fallback

  defp parse_cell_param(value) when is_binary(value) do
    case String.split(value, "|", parts: 2) do
      [eg, pg] when eg != "" and pg != "" -> {eg, pg}
      _ -> nil
    end
  end

  defp parse_cell_param(_), do: nil

  defp normalize_view("network", true), do: :network
  defp normalize_view("impact", _available?), do: :impact
  defp normalize_view(_other, true), do: :network
  defp normalize_view(_other, false), do: :impact

  defp resolve_initial_view(_url_view, _has_url_pair?, %{network_available?: false}), do: :impact
  defp resolve_initial_view(:impact, _has_url_pair?, _analysis), do: :impact
  defp resolve_initial_view(:network, _has_url_pair?, _analysis), do: :network
  defp resolve_initial_view(nil, true, _analysis), do: :impact
  defp resolve_initial_view(nil, false, analysis), do: analysis.default_view

  defp resolve_valid_pair(analysis, from_id, to_id)
       when is_binary(from_id) and is_binary(to_id) do
    has_entrance? = Enum.any?(analysis.entrances, &(&1.stop_id == from_id))
    has_platform? = Enum.any?(analysis.platforms, &(&1.stop_id == to_id))
    if has_entrance? and has_platform?, do: {from_id, to_id}, else: nil
  end

  defp resolve_valid_pair(_analysis, _from_id, _to_id), do: nil

  defp resolve_valid_cell(%{cells: cells}, {eg_id, pg_id}) do
    if Map.has_key?(cells, {eg_id, pg_id}), do: {eg_id, pg_id}, else: nil
  end

  defp resolve_valid_cell(_groups, _cell), do: nil

  defp default_route_pair(analysis) do
    reachable = Enum.find(analysis.pairs, &(&1.status in [:confirmed, :unverified]))
    first = reachable || List.first(analysis.pairs)

    case first do
      nil -> {nil, nil}
      pair -> {pair.entrance_stop_id, pair.platform_stop_id}
    end
  end

  defp build_curated_pairs(analysis, selected_from, selected_to) do
    reachable = Enum.filter(analysis.pairs, &(&1.status in [:confirmed, :unverified]))

    confirmed = Enum.filter(reachable, &(&1.status == :confirmed))
    unverified = Enum.filter(reachable, &(&1.status == :unverified))

    diverse =
      [List.first(confirmed), List.first(unverified)]
      |> Enum.reject(&is_nil/1)
      |> Kernel.++(reachable)
      |> Enum.uniq_by(&{&1.entrance_stop_id, &1.platform_stop_id})

    selected_pair =
      if selected_from && selected_to do
        Enum.find(
          analysis.pairs,
          &(&1.entrance_stop_id == selected_from and &1.platform_stop_id == selected_to)
        )
      end

    [selected_pair | diverse]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(&{&1.entrance_stop_id, &1.platform_stop_id})
    |> Enum.take(4)
  end

  defp toggle_member(set, key) do
    if MapSet.member?(set, key), do: MapSet.delete(set, key), else: MapSet.put(set, key)
  end

  defp presence(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp presence(_), do: nil

  defp station_title(nil, stop_id), do: stop_id
  defp station_title(station, stop_id), do: station.stop_name || stop_id

  defp station_facts(%{levels: levels, child_stops: child_stops}) do
    "#{Wording.count_noun(length(levels), "level", "levels")} · " <>
      "#{Wording.count_noun(length(child_stops), "stop or node", "stops and nodes")} inside"
  end
end
