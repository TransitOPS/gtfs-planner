defmodule GtfsPlannerWeb.Gtfs.StationReport2Live do
  @moduledoc """
  LiveView for the station report dashboard with independent section components.

  ## Lifecycle

  The report is built by one stable `:report_load` async task. Starting a load
  cancels the previous one, bumps a generation counter, and records the full
  scope `{organization_id, gtfs_version_id, stop_id, generation}`. The task
  closure captures that scope — plain ids, never the socket — and returns it
  with its result, so `handle_async/3` can apply a result only while it still
  describes the active route. A navigation, station change, or replacement load
  therefore cannot be overwritten by work started for a previous scope, and a
  cancelled task's exit is not an error.

  ## One report truth

  The async result is a single normalized model: every section list plus every
  connectivity route group, route, and step, all built once from the same
  scoped snapshot. Screen disclosure state is server-owned and only decides
  what is *visible*; the evidence itself is always in the document, so printing
  a freshly loaded report is complete without any prior click.
  """
  use GtfsPlannerWeb, :live_view

  import GtfsPlannerWeb.Gtfs.StationReportDrawerComponents
  import GtfsPlannerWeb.Gtfs.StationReport2Components

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Stop

  alias GtfsPlanner.Gtfs.StationReport2.{
    Connectivity,
    DataQuality,
    Gps,
    NamingConventions,
    PathwayFieldCompleteness
  }

  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.Gtfs.StationReport2Components
  alias GtfsPlannerWeb.Gtfs.StationReportDrawerComponents

  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  @report_key :report_load
  @dimensions [:entrance_to_platform, :platform_to_platform, :platform_to_exit]
  @editable_stop_fields ~w(stop_name stop_lat stop_lon level_id wheelchair_boarding platform_code)

  @impl true
  def mount(_params, _session, socket) do
    user_roles = socket.assigns[:user_roles] || []

    {:ok,
     socket
     |> assign(:page_title, "Station Report")
     |> assign(:user_roles, user_roles)
     |> assign(:stop_id, nil)
     |> assign(:generation, 0)
     |> assign(:report_scope, nil)
     |> assign(:view_state, :initial_loading)
     |> assign(:refresh_reason, nil)
     |> assign(:report_error, nil)
     |> assign(:url_dimensions, [])
     |> clear_model()
     |> reset_expansion()
     |> clear_drawer()}
  end

  @impl true
  def handle_params(%{"stop_id" => stop_id} = params, _uri, socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    if active_scope?(socket, organization_id, gtfs_version_id, stop_id) do
      # A patch that does not move the report scope (for example a `dimensions`
      # query change) must not restart work or discard disclosure state.
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(:stop_id, stop_id)
       |> assign(:url_dimensions, parse_url_dimensions(params))
       |> clear_model()
       |> reset_expansion()
       |> clear_drawer()
       |> start_report_load(:initial_loading, nil)}
    end
  end

  # -- Asynchronous report loading -------------------------------------------

  @impl true
  def handle_async(@report_key, {:ok, {:loaded, scope, model}}, socket) do
    if scope == socket.assigns.report_scope do
      {:noreply, apply_model(socket, model)}
    else
      {:noreply, socket}
    end
  end

  def handle_async(@report_key, {:ok, {:load_failed, scope, :not_found}}, socket) do
    if scope == socket.assigns.report_scope do
      {_organization_id, gtfs_version_id, _stop_id, _generation} = scope

      {:noreply,
       socket
       |> cancel_async(@report_key)
       |> put_flash(:error, "Station not found")
       |> push_navigate(to: "/gtfs/#{gtfs_version_id}/stops")}
    else
      {:noreply, socket}
    end
  end

  def handle_async(@report_key, {:ok, {:load_failed, scope, _reason}}, socket) do
    if scope == socket.assigns.report_scope do
      {:noreply, assign_report_error(socket)}
    else
      {:noreply, socket}
    end
  end

  # A cancelled task is expected: it was superseded on purpose and must never
  # be presented as a failure.
  def handle_async(@report_key, {:exit, {:shutdown, :cancel}}, socket), do: {:noreply, socket}

  def handle_async(@report_key, {:exit, _reason}, socket) do
    if socket.assigns.view_state in [:initial_loading, :refreshing] do
      {:noreply, assign_report_error(socket)}
    else
      {:noreply, socket}
    end
  end

  defp start_report_load(socket, view_state, refresh_reason) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id
    stop_id = socket.assigns.stop_id
    generation = socket.assigns.generation + 1
    scope = {organization_id, gtfs_version_id, stop_id, generation}

    socket
    |> assign(:generation, generation)
    |> assign(:report_scope, scope)
    |> assign(:view_state, view_state)
    |> assign(:refresh_reason, refresh_reason)
    |> assign(:report_error, nil)
    |> cancel_async(@report_key)
    |> start_async(@report_key, fn -> load_report(scope) end)
  end

  # Runs in the task process. It receives ids only and returns its own scope so
  # the LiveView can decide whether the answer is still wanted.
  defp load_report({organization_id, gtfs_version_id, stop_id, _generation} = scope) do
    case snapshot_source().get_station_report_snapshot(
           organization_id,
           gtfs_version_id,
           stop_id
         ) do
      {:ok, snapshot} -> {:loaded, scope, build_model(snapshot)}
      {:error, reason} -> {:load_failed, scope, reason}
    end
  end

  # Resolved per call so the report boundary can be exercised deterministically
  # in tests without recompiling this module. Production always uses the context.
  defp snapshot_source do
    Application.get_env(:gtfs_planner, :station_report_snapshot_source, Gtfs)
  end

  defp active_scope?(socket, organization_id, gtfs_version_id, stop_id) do
    case socket.assigns.report_scope do
      {^organization_id, ^gtfs_version_id, ^stop_id, _generation} -> true
      _ -> false
    end
  end

  defp apply_model(socket, model) do
    first_model? = is_nil(socket.assigns.model)

    socket
    |> assign(:model, model)
    |> assign(:station, model.station)
    |> assign(:view_state, :ready)
    |> assign(:refresh_reason, nil)
    |> assign(:report_error, nil)
    |> then(fn socket ->
      if first_model?, do: seed_expansion(socket, model), else: put_expansion(socket, [])
    end)
  end

  defp assign_report_error(socket) do
    kind =
      case {socket.assigns.view_state, socket.assigns.refresh_reason} do
        {:refreshing, :saved} -> :refresh_after_save
        {:refreshing, _} -> :refresh
        _ -> :load
      end

    socket
    |> assign(:view_state, :error)
    |> assign(:report_error, kind)
  end

  defp clear_model(socket) do
    socket
    |> assign(:model, nil)
    |> assign(:station, nil)
  end

  # -- Normalized report model -----------------------------------------------

  # Builds every screen section and every connectivity detail exactly once, in
  # the task process. Screen and print read this one model; nothing downstream
  # recalculates. Calculation itself still belongs to the StationReport2
  # builders — this function only composes their results.
  defp build_model(snapshot) do
    summaries = Connectivity.build_summaries(snapshot)

    route_details =
      Map.new(@dimensions, fn dimension ->
        {dimension, Connectivity.build_route_detail(snapshot, dimension)}
      end)

    routes =
      for {_dimension, groups} <- route_details,
          group <- groups,
          target <- group.targets,
          into: %{} do
        {{group.source.stop_id, target.stop_id},
         Connectivity.build_expanded_route(snapshot, group.source.stop_id, target.stop_id)}
      end

    %{
      snapshot: snapshot,
      station: snapshot.station,
      data_quality_items: DataQuality.build(snapshot),
      gps_items: Gps.build(snapshot),
      naming_convention_checks: NamingConventions.build(snapshot),
      pathway_field_completeness_groups: PathwayFieldCompleteness.build(snapshot),
      connectivity_summaries: summaries,
      connectivity_route_details: route_details,
      connectivity_routes: routes
    }
  end

  # -- Server-owned disclosure ----------------------------------------------

  @impl true
  def handle_event("toggle_check_detail", %{"key" => key}, socket) do
    {:noreply,
     put_expansion(socket, expanded_checks: toggle_member(socket.assigns.expanded_checks, key))}
  end

  @impl true
  def handle_event("toggle_expand_all", _params, socket) do
    case socket.assigns.model do
      nil ->
        {:noreply, socket}

      model ->
        if all_expanded?(socket, model) do
          {:noreply, reset_expansion(socket)}
        else
          {:noreply,
           put_expansion(socket,
             expanded_sources: all_source_keys(model),
             expanded_route_keys: all_route_keys(model),
             expanded_checks: StationReport2Components.collapsible_check_keys(model)
           )}
        end
    end
  end

  @impl true
  def handle_event("toggle_connectivity_dimension", %{"dimension" => dimension_str}, socket) do
    case socket.assigns.model do
      nil ->
        {:noreply, socket}

      model ->
        dimension = parse_dimension(dimension_str)
        keys = dimension_source_keys(model, dimension)
        expanded = socket.assigns.expanded_sources

        expanded =
          if MapSet.size(keys) > 0 and MapSet.subset?(keys, expanded) do
            MapSet.difference(expanded, keys)
          else
            MapSet.union(expanded, keys)
          end

        {:noreply, put_expansion(socket, expanded_sources: expanded)}
    end
  end

  @impl true
  def handle_event(
        "toggle_connectivity_source",
        %{"dimension" => dimension_str, "source_stop_id" => source_stop_id},
        socket
      ) do
    key = {parse_dimension(dimension_str), source_stop_id}

    {:noreply,
     put_expansion(socket, expanded_sources: toggle_member(socket.assigns.expanded_sources, key))}
  end

  @impl true
  def handle_event(
        "toggle_route_expand",
        %{"source_id" => source_id, "target_id" => target_id},
        socket
      ) do
    {:noreply,
     put_expansion(socket,
       expanded_route_keys:
         toggle_member(socket.assigns.expanded_route_keys, {source_id, target_id})
     )}
  end

  # -- Lifecycle events ------------------------------------------------------

  @impl true
  def handle_event("retry_report", _params, socket) do
    cond do
      socket.assigns.view_state in [:initial_loading, :refreshing] ->
        {:noreply, socket}

      socket.assigns.report_error == :refresh_after_save ->
        {:noreply, start_report_load(socket, refresh_state(socket), :saved)}

      true ->
        {:noreply, start_report_load(socket, refresh_state(socket), :retry)}
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
          do: "/gtfs/#{version_id}/stops/#{stop_id}/report",
          else: "/gtfs/#{version_id}/stops"

      {:noreply,
       socket
       |> cancel_async(@report_key)
       |> push_navigate(to: path)}
    else
      {:noreply, socket}
    end
  end

  # -- Drawer events ---------------------------------------------------------

  @impl true
  def handle_event(
        "select_entity",
        %{"entity_id" => entity_id, "entity_type" => "stop"} = params,
        socket
      ) do
    {:noreply,
     socket
     |> assign(:drawer_return_focus_id, params["opener_id"])
     |> open_stop_drawer(entity_id)}
  end

  @impl true
  def handle_event("select_entity", _params, socket), do: {:noreply, socket}

  # Recovery from a failed lookup retries the id the report already asked for.
  # The client supplies nothing here, and the retry still goes through the same
  # scoped context query.
  @impl true
  def handle_event("retry_entity_lookup", _params, socket) do
    case socket.assigns.drawer_entity_id do
      nil -> {:noreply, socket}
      entity_id -> {:noreply, open_stop_drawer(socket, entity_id)}
    end
  end

  @impl true
  def handle_event("close_entity_drawer", _params, socket) do
    # The opener id survives the close so the shipped OverlayDialog hook can
    # still read it while returning focus.
    {:noreply, reset_drawer(socket)}
  end

  @impl true
  def handle_event("validate_entity", %{"stop" => stop_params}, socket) do
    case socket.assigns.drawer_entity do
      %Stop{} = stop ->
        changeset =
          stop
          |> Gtfs.change_stop(editable_stop_params(stop_params))
          |> Map.put(:action, :validate)

        {:noreply, assign(socket, :drawer_form, to_form(changeset, as: :stop))}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("validate_entity", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("save_entity", %{"stop" => stop_params}, socket) do
    case socket.assigns.drawer_entity do
      %Stop{} = stop ->
        save_stop(socket, stop, stop_params)

      _ ->
        # No open stop: a repeated or replayed submit must not save again and
        # must not queue a second rebuild.
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("save_entity", _params, socket) do
    {:noreply, socket}
  end

  defp save_stop(socket, stop, stop_params) do
    case Gtfs.update_stop(stop, editable_stop_params(stop_params)) do
      {:ok, _updated} ->
        {:noreply,
         socket
         |> reset_drawer()
         |> start_report_load(refresh_state(socket), :saved)}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:drawer_form, to_form(changeset, as: :stop))
         |> assign(:drawer_error, nil)
         |> push_event("focus_form_error", %{
           form_id: StationReportDrawerComponents.form_id(),
           fallback_id: StationReportDrawerComponents.error_summary_id()
         })}
    end
  end

  # The drawer edits six fields. `Stop.changeset/2` also casts identity and
  # scope columns, so anything else in the submitted params is dropped here:
  # a crafted submit cannot rename, reparent, or move a stop into another
  # organization or GTFS version.
  defp editable_stop_params(stop_params) when is_map(stop_params),
    do: Map.take(stop_params, @editable_stop_fields)

  defp editable_stop_params(_stop_params), do: %{}

  defp open_stop_drawer(socket, entity_id) do
    org_id = socket.assigns.current_organization.id
    version_id = socket.assigns.current_gtfs_version.id

    case Gtfs.get_stop_by_stop_id(org_id, version_id, entity_id) do
      nil ->
        assign_drawer_error(socket, entity_id)

      stop ->
        socket
        |> assign(:drawer_entity, stop)
        |> assign(:drawer_entity_id, entity_id)
        |> assign(:drawer_form, stop_form(stop))
        |> assign(:drawer_error, nil)
    end
  end

  defp stop_form(stop) do
    to_form(
      %{
        "stop_name" => stop.stop_name || "",
        "stop_lat" => to_optional_string(stop.stop_lat),
        "stop_lon" => to_optional_string(stop.stop_lon),
        "level_id" => stop.level_id || "",
        "wheelchair_boarding" => to_optional_string(stop.wheelchair_boarding),
        "platform_code" => stop.platform_code || ""
      },
      as: :stop
    )
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
          :if={@station}
          station={@station}
          gtfs_version_id={@current_gtfs_version.id}
          active_tab={:report}
        />
      </:sub_header>

      <div id="station-report-2" class="space-y-6">
        <.report_status state={@view_state} reason={@refresh_reason} error={@report_error} />

        <%= if @model do %>
          <.report_toc station_name={@station.stop_name || @station.stop_id} model={@model}>
            <button
              id="report-expand-all"
              type="button"
              data-report-control
              phx-click="toggle_expand_all"
              aria-expanded={to_string(@all_expanded)}
              aria-controls="station-report-2"
              class="print:hidden inline-flex min-h-11 items-center gap-1.5 border border-base-300 bg-base-100 px-3 py-1.5 text-sm font-medium motion-safe:transition-colors hover:border-primary focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary focus-visible:ring-offset-2"
            >
              <.icon
                name={
                  if @all_expanded, do: "hero-arrows-pointing-in", else: "hero-arrows-pointing-out"
                }
                class="size-3.5"
              />
              {if @all_expanded, do: "Collapse all", else: "Expand all"}
            </button>
          </.report_toc>
          <.station_inventory_section report={@model.snapshot} />
          <.data_quality_section
            items={@model.data_quality_items}
            section="data-quality"
            expanded={@expanded_checks}
          />
          <.gps_checks_section items={@model.gps_items} section="gps" expanded={@expanded_checks} />
          <.naming_conventions_section
            checks={@model.naming_convention_checks}
            expanded={@expanded_checks}
          />
          <.reachability_connectivity_section
            connectivity_summaries={@model.connectivity_summaries}
            connectivity_route_details={@model.connectivity_route_details}
            connectivity_routes={@model.connectivity_routes}
            expanded_sources={@expanded_sources}
            expanded_route_keys={@expanded_route_keys}
          />
          <.pathway_field_completeness_section groups={@model.pathway_field_completeness_groups} />
        <% end %>
      </div>

      <.entity_drawer
        drawer_entity={@drawer_entity}
        drawer_entity_id={@drawer_entity_id}
        drawer_form={@drawer_form}
        drawer_error={@drawer_error}
        drawer_return_focus_id={@drawer_return_focus_id}
      />
    </Layouts.app>
    """
  end

  attr :state, :atom, required: true
  attr :reason, :atom, default: nil
  attr :error, :atom, default: nil

  defp report_status(%{state: :ready} = assigns) do
    ~H""
  end

  defp report_status(assigns) do
    ~H"""
    <div id="report-status" data-role="report-status" data-state={@state} class="print:hidden">
      <.skeleton :if={@state == :initial_loading} rows={6} label="Loading report…" />

      <div
        :if={@state == :refreshing}
        class="flex items-center gap-2 border border-base-300 px-4 py-3 text-sm"
      >
        <.icon name="hero-arrow-path" class="size-4 motion-safe:animate-spin" />
        <span>{refresh_label(@reason)}</span>
      </div>

      <.callout :if={@state == :error} kind="error" title={error_title(@error)}>
        {error_body(@error)}
        <div class="mt-3">
          <.button id="report-retry" type="button" phx-click="retry_report" size="sm">
            Retry report
          </.button>
        </div>
      </.callout>
    </div>
    """
  end

  defp refresh_label(:saved), do: "Stop saved. Refreshing report…"
  defp refresh_label(_reason), do: "Refreshing report…"

  defp error_title(:refresh_after_save), do: "Stop saved, but the report could not refresh"
  defp error_title(:refresh), do: "Report could not refresh"
  defp error_title(_kind), do: "Report could not load"

  defp error_body(:refresh_after_save),
    do: "Your change was saved. The report below is from before that change until it rebuilds."

  defp error_body(:refresh), do: "The report below is from the last successful build."
  defp error_body(_kind), do: "Nothing was changed. Retry to build the station report."

  # -- Expansion state -------------------------------------------------------

  defp reset_expansion(socket) do
    socket
    |> assign(:expanded_sources, MapSet.new())
    |> assign(:expanded_route_keys, MapSet.new())
    |> assign(:expanded_checks, MapSet.new())
    |> assign(:all_expanded, false)
  end

  defp seed_expansion(socket, model) do
    seeded =
      socket.assigns.url_dimensions
      |> Enum.flat_map(&MapSet.to_list(dimension_source_keys(model, &1)))
      |> MapSet.new()

    put_expansion(socket, expanded_sources: seeded)
  end

  # Every expansion change recomputes the derived "everything is open" flag that
  # the Expand all / Collapse all control reports.
  defp put_expansion(socket, changes) do
    socket = assign(socket, changes)
    assign(socket, :all_expanded, model_all_expanded?(socket))
  end

  defp model_all_expanded?(%{assigns: %{model: nil}}), do: false
  defp model_all_expanded?(socket), do: all_expanded?(socket, socket.assigns.model)

  defp toggle_member(set, key) do
    if MapSet.member?(set, key), do: MapSet.delete(set, key), else: MapSet.put(set, key)
  end

  defp dimension_source_keys(model, dimension) do
    case Map.get(model.connectivity_summaries, dimension) do
      nil -> MapSet.new()
      summary -> MapSet.new(summary.summary_rows, &{dimension, &1.source_stop_id})
    end
  end

  defp all_source_keys(model) do
    @dimensions
    |> Enum.flat_map(&MapSet.to_list(dimension_source_keys(model, &1)))
    |> MapSet.new()
  end

  defp all_route_keys(model), do: model.connectivity_routes |> Map.keys() |> MapSet.new()

  defp all_expanded?(socket, model) do
    sources = all_source_keys(model)
    routes = all_route_keys(model)
    checks = StationReport2Components.collapsible_check_keys(model)

    nonempty?(sources, routes, checks) and
      MapSet.subset?(sources, socket.assigns.expanded_sources) and
      MapSet.subset?(routes, socket.assigns.expanded_route_keys) and
      MapSet.subset?(checks, socket.assigns.expanded_checks)
  end

  defp nonempty?(sources, routes, checks) do
    MapSet.size(sources) + MapSet.size(routes) + MapSet.size(checks) > 0
  end

  # -- Drawer helpers --------------------------------------------------------

  defp refresh_state(socket),
    do: if(socket.assigns.model, do: :refreshing, else: :initial_loading)

  # Closes the drawer but keeps the opener id: the OverlayDialog hook reads
  # `data-return-focus-id` on the patch that closes the dialog, so clearing it
  # here would drop focus to the document body.
  defp reset_drawer(socket) do
    socket
    |> assign(:drawer_entity, nil)
    |> assign(:drawer_entity_id, nil)
    |> assign(:drawer_form, nil)
    |> assign(:drawer_error, nil)
  end

  # A route change retires the opener with the report that owned it.
  defp clear_drawer(socket) do
    socket
    |> reset_drawer()
    |> assign(:drawer_return_focus_id, nil)
  end

  defp assign_drawer_error(socket, entity_id) do
    socket
    |> assign(:drawer_entity, nil)
    |> assign(:drawer_entity_id, entity_id)
    |> assign(:drawer_form, nil)
    |> assign(
      :drawer_error,
      "#{entity_id} is not in this report's GTFS version. It may have been renamed or removed " <>
        "since the report was built. Retry the lookup, or close this panel and rebuild the report."
    )
  end

  defp to_optional_string(nil), do: ""
  defp to_optional_string(value), do: to_string(value)

  defp parse_url_dimensions(params) do
    case params["dimensions"] do
      nil -> []
      str -> str |> String.split(",") |> Enum.map(&parse_dimension/1)
    end
  end

  defp parse_dimension("entrance_to_platform"), do: :entrance_to_platform
  defp parse_dimension("platform_to_exit"), do: :platform_to_exit
  defp parse_dimension("platform_to_platform"), do: :platform_to_platform
  defp parse_dimension(_), do: :entrance_to_platform
end
