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
  import GtfsPlannerWeb.AgentComponents, only: [agent_panel: 1]
  import GtfsPlannerWeb.PlannerComponents, only: [message: 1]
  import GtfsPlannerWeb.StationWorkspace, only: [station_header: 1]

  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Stations
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Reachability

  alias GtfsPlanner.Gtfs.StationReport2.{
    Connectivity,
    DataQuality,
    Gps,
    NamingConventions,
    PathwayFieldCompleteness
  }

  alias GtfsPlanner.Versions
  alias GtfsPlanner.Wording
  alias GtfsPlannerWeb.AgentPanel
  alias GtfsPlannerWeb.Gtfs.StationReport2Components
  alias GtfsPlannerWeb.Gtfs.StationReportDrawerComponents

  on_mount({GtfsPlannerWeb.EnsureRole, :require_gtfs_access})

  @report_key :report_load
  @dimensions [:entrance_to_platform, :platform_to_platform, :platform_to_exit]
  @editable_stop_fields ~w(stop_name stop_lat stop_lon level_id wheelchair_boarding platform_code)

  @impl true
  def mount(_params, _session, socket) do
    user_roles = socket.assigns[:user_roles] || []

    {:ok,
     socket
     |> assign(:page_title, "Station report")
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
     |> clear_drawer()
     |> assign(:station_result_runs, [])
     |> assign(:selected_result_run, nil)
     |> assign(:station_helper_notice, nil)
     |> assign(:station_run_form, to_form(%{"run_id" => nil}))
     |> AgentPanel.mount("station_results", open_button: "station-helper-open")}
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
       |> assign(:station_result_runs, [])
       |> assign(:selected_result_run, nil)
       |> bind_station_helper()
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

  # An exit carries no scope, so it can only be trusted once `load_report/1`
  # isolates every failure it can observe into a scoped `{:load_failed, ...}`.
  # What is left here is an external kill of the task the view is waiting on.
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
  # the LiveView can decide whether the answer is still wanted. Failures are
  # isolated here and reported as a scoped result: an unhandled raise or exit
  # would otherwise arrive as an unscoped `{:exit, reason}` and let a superseded
  # task error the station that replaced it.
  defp load_report({organization_id, gtfs_version_id, stop_id, _generation} = scope) do
    case snapshot_source().get_station_report_snapshot(
           organization_id,
           gtfs_version_id,
           stop_id
         ) do
      {:ok, snapshot} -> {:loaded, scope, build_model(snapshot)}
      {:error, reason} -> {:load_failed, scope, reason}
    end
  rescue
    exception -> {:load_failed, scope, exception}
  catch
    kind, reason -> {:load_failed, scope, {kind, reason}}
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
    # The helper's conversation belongs to the station and the recorded check
    # this page resolved. `apply_model/2` runs only for the scope `handle_async`
    # still holds, so a superseded load can never rebind it.
    |> bind_station_helper()
    |> then(fn socket ->
      if first_model?, do: seed_expansion(socket, model), else: put_expansion(socket, [])
    end)
  end

  # -- Station result helper ---------------------------------------------------

  # The conversation is bound to the station this report resolved and to the
  # recorded check the editor selected, never to a guessed latest: the selector
  # starts empty, so a helper read starts with the current report facts and only
  # gains a recorded result when a person asks for that one.
  defp bind_station_helper(socket) do
    organization_id = socket.assigns.current_organization.id
    version_id = socket.assigns.current_gtfs_version.id
    context = Scope.context({:version, version_id})

    case socket.assigns[:station] do
      %Stop{location_type: 1} = station ->
        runs = recent_result_runs(organization_id, version_id, station.stop_id)
        selected = select_listed_run(runs, socket.assigns[:selected_result_run])

        socket =
          assign(socket,
            station_result_runs: runs,
            selected_result_run: selected,
            station_run_form: to_form(%{"run_id" => selected && selected.id})
          )

        snapshot = %{
          kind: "station_results",
          payload: %{
            "station_id" => station.id,
            "station_stop_id" => station.stop_id,
            "run_id" => selected && selected.id
          }
        }

        case Scope.with_source_snapshot(context, snapshot) do
          {:ok, source_context} ->
            socket
            |> assign(:station_helper_notice, nil)
            |> AgentPanel.set_context(source_context)

          {:error, reason} ->
            # An over-large or malformed source is refused visibly and the panel
            # keeps the plain version context, which the pack also refuses.
            socket
            |> assign(:station_helper_notice, helper_notice(reason))
            |> AgentPanel.set_context(context)
        end

      _other ->
        socket
        |> assign(:station_result_runs, [])
        |> assign(:selected_result_run, nil)
        |> assign(:station_helper_notice, nil)
        |> AgentPanel.set_context(context)
    end
  end

  # Only the recent finished checks of this station are offered, and only
  # completed ones carry a recorded result worth explaining.
  defp recent_result_runs(organization_id, version_id, stop_id) do
    Reachability.list_recent_runs(organization_id, version_id, stop_id, 5)
    |> Enum.filter(&(&1.status == "completed"))
  end

  # A selection that is no longer one of the offered runs - because it was
  # replaced or the station moved on - is dropped rather than kept as a name the
  # page no longer shows.
  defp select_listed_run(_runs, nil), do: nil
  defp select_listed_run(runs, %{id: id}), do: Enum.find(runs, &(&1.id == id))
  defp select_listed_run(_runs, _other), do: nil

  # A run id the server never offered is ignored rather than honoured: the
  # selector's own list is the only way to choose a recorded check.
  defp listed_run(runs, run_id) when is_binary(run_id), do: Enum.find(runs, &(&1.id == run_id))
  defp listed_run(_runs, _other), do: nil

  defp helper_notice(:too_large),
    do:
      "This station's helper context is too large to send, so the helper is unavailable here. The report below is complete and unchanged."

  defp helper_notice(_reason),
    do:
      "This station's helper context could not be built, so the helper is unavailable here. The report below is complete and unchanged."

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
  def handle_event("select_result_run", %{"run_id" => run_id}, socket) do
    {:noreply,
     socket
     |> assign(:selected_result_run, listed_run(socket.assigns.station_result_runs, run_id))
     |> bind_station_helper()}
  end

  def handle_event("select_result_run", _params, socket), do: {:noreply, socket}

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
          do: ~p"/gtfs/#{version_id}/stops/#{stop_id}/report",
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
          |> stop_changeset(editable_stop_params(stop_params), socket.assigns.drawer_levels)
          |> Map.put(:action, :validate)

        {:noreply,
         socket
         |> assign(:drawer_form, to_form(changeset, as: :stop))
         |> assign(:drawer_save_error, nil)}

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
    attrs = editable_stop_params(stop_params)
    changeset = stop_changeset(stop, attrs, socket.assigns.drawer_levels)

    # Keep the report's no-change save behavior. The scoped command records
    # history for an update, so only changed fields enter that command.
    result =
      cond do
        not changeset.valid? ->
          {:error, Map.put(changeset, :action, :update)}

        changeset.changes == %{} ->
          {:ok, stop}

        true ->
          Stations.update_child_stop(
            AuditContext.from_assigns(socket.assigns),
            stop.id,
            attrs,
            stop.lock_version
          )
      end

    case result do
      {:ok, _updated} ->
        {:noreply,
         socket
         |> reset_drawer()
         |> start_report_load(refresh_state(socket), :saved)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(:drawer_form, to_form(changeset, as: :stop))
         |> assign(:drawer_error, nil)
         |> assign(:drawer_save_error, nil)
         |> push_event("focus_form_error", %{
           form_id: StationReportDrawerComponents.form_id(),
           fallback_id: StationReportDrawerComponents.error_summary_id()
         })}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:drawer_form, to_form(Map.put(changeset, :action, :update), as: :stop))
         |> assign(:drawer_save_error, save_error(reason))
         |> push_event("focus_form_error", %{
           form_id: StationReportDrawerComponents.form_id(),
           fallback_id: "report-stop-save-error"
         })}
    end
  end

  defp save_error({:stale, _}),
    do:
      "This stop changed since you opened it. Close and reopen the drawer to review the latest values before saving."

  defp save_error(:forbidden),
    do: "Your editing access changed. Your draft remains here, but it was not saved."

  defp save_error(:not_found),
    do: "This stop is no longer in the selected station. Your draft was not saved."

  defp save_error(_), do: "The stop could not be saved. Your draft remains here; try again."

  # `Stop.child_stop_changeset/2` is the station diagram's own rule, and this
  # drawer only ever holds a stop inside the selected station, so its pre-check
  # asks the same question the save will: a child stop must name a level. Using
  # the general `Stop.changeset/2` here made the drawer and the command it writes
  # through disagree, and a rejected save showed only the pre-check's errors.
  #
  # Neither changeset can look levels up. The level select only offers this
  # version's levels, but a crafted submit can name any text, and a stop pointing
  # at a level missing from `levels.txt` disappears from every floorplan and
  # breaks the export.
  defp stop_changeset(stop, attrs, levels) do
    changeset = Stop.child_stop_changeset(stop, attrs)
    level_id = Ecto.Changeset.get_field(changeset, :level_id)

    if level_id in [nil, ""] or Enum.any?(levels, &(&1.level_id == level_id)) do
      changeset
    else
      Ecto.Changeset.add_error(
        changeset,
        :level_id,
        "Choose a level that exists in this version."
      )
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

    audit = AuditContext.from_assigns(socket.assigns)

    case Gtfs.get_stop_by_stop_id(org_id, version_id, entity_id) do
      nil ->
        assign_drawer_error(socket, entity_id)

      stop ->
        if Stations.station_member?(audit, "stop", stop.id) do
          socket
          |> assign(:drawer_entity, stop)
          |> assign(:drawer_entity_id, entity_id)
          |> assign(:drawer_form, stop_form(stop))
          |> assign(:drawer_levels, Gtfs.list_all_levels(org_id, version_id))
          |> assign(:drawer_error, nil)
          |> assign(:drawer_save_error, nil)
        else
          assign_drawer_error(socket, entity_id)
        end
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
        <%!-- The header needs only the version and the stop id, so it renders while
              the report loads or fails and the station tabs stay reachable. --%>
        <.station_header
          title={station_title(@station, @stop_id)}
          stop_id={@stop_id}
          gtfs_version_id={@current_gtfs_version.id}
          active_tab={:report}
        >
          <:meta :if={@model}>Station · {station_facts(@model)}</:meta>
        </.station_header>
      </:sub_header>

      <div class="ds-page">
        <%!--
        The helper wrapper survives the panel, so the close and open focus events still reach a
        listener after the panel itself is gone. It holds the report and the panel side by side,
        and the helper bar sits above the report: explaining a recorded check is a question about
        this station, so it is offered where the report begins. The bar is print-hidden; it
        explains the recorded check beside the report rather than becoming part of the printed
        evidence. --%>
        <div
          id="station-helper"
          phx-hook=".StationHelperFocus"
          class={[@agent_open? && "lg:grid lg:gap-6 lg:grid-cols-[minmax(0,1fr)_24rem]"]}
        >
          <div class={["min-w-0 space-y-6", @agent_open? && "hidden lg:block"]}>
            <.station_helper_bar
              :if={@model}
              runs={@station_result_runs}
              selected={@selected_result_run}
              form={@station_run_form}
              notice={@station_helper_notice}
              open?={@agent_open?}
            />

            <div id="station-report-2" class="space-y-6">
              <.report_status state={@view_state} reason={@refresh_reason} error={@report_error} />

              <%= if @model do %>
                <.report_summary station_name={@station.stop_name || @station.stop_id} model={@model}>
                  <.button
                    id="report-expand-all"
                    variant="secondary"
                    data-report-control
                    phx-click="toggle_expand_all"
                    aria-expanded={to_string(@all_expanded)}
                    aria-controls="station-report-2"
                    class="print:hidden min-h-11"
                  >
                    <.icon
                      name={
                        if @all_expanded,
                          do: "hero-arrows-pointing-in",
                          else: "hero-arrows-pointing-out"
                      }
                      class="size-4"
                    />
                    {if @all_expanded, do: "Collapse all", else: "Expand all"}
                  </.button>
                </.report_summary>
                <.data_quality_section
                  items={@model.data_quality_items}
                  section="data-quality"
                  expanded={@expanded_checks}
                />
                <.reachability_connectivity_section
                  connectivity_summaries={@model.connectivity_summaries}
                  connectivity_route_details={@model.connectivity_route_details}
                  connectivity_routes={@model.connectivity_routes}
                  expanded_sources={@expanded_sources}
                  expanded_route_keys={@expanded_route_keys}
                />
                <.gps_checks_section
                  items={@model.gps_items}
                  section="gps"
                  expanded={@expanded_checks}
                />
                <.pathway_field_completeness_section groups={@model.pathway_field_completeness_groups} />
                <.naming_conventions_section
                  checks={@model.naming_convention_checks}
                  expanded={@expanded_checks}
                />
                <.station_inventory_section report={@model.snapshot} />
              <% end %>
            </div>
          </div>

          <div
            :if={@agent_open? and @model}
            class="flex min-w-0 lg:sticky lg:top-4 lg:max-h-[calc(100vh-2rem)]"
          >
            <.agent_panel
              id="agent-panel"
              title={@agent_title}
              intro={@agent_intro}
              examples={@agent_examples}
              scope_line={"Station report · " <> @current_gtfs_version.name}
              status={@agent_status}
              entries={@streams.agent_entries}
              form={@agent_form}
              notice={@agent_notice}
              entries_empty?={@agent_entries_empty?}
              composer_hint="This helper only reads recorded results and current report facts. It can't run a check or change data."
            />
          </div>
        </div>

        <.entity_drawer
          drawer_entity={@drawer_entity}
          drawer_entity_id={@drawer_entity_id}
          drawer_form={@drawer_form}
          drawer_error={@drawer_error}
          drawer_save_error={@drawer_save_error}
          drawer_levels={@drawer_levels}
          drawer_return_focus_id={@drawer_return_focus_id}
        />
      </div>
    </Layouts.app>

    <%!--
    The panel's focus events belong to the wrapper above, which survives the
    panel's own removal. This hook only moves focus; it never decides focus for
    the server. --%>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".StationHelperFocus">
      export default {
        mounted() {
          this.handleEvent("agent:focus", ({id}) => document.getElementById(id)?.focus())
        }
      }
    </script>
    """
  end

  ## -- Station result helper bar -----------------------------------------------

  attr :runs, :list, required: true
  attr :selected, :map, default: nil
  attr :form, Phoenix.HTML.Form, required: true
  attr :notice, :string, default: nil
  attr :open?, :boolean, required: true

  defp station_helper_bar(assigns) do
    ~H"""
    <section
      id="station-helper-bar"
      aria-labelledby="station-helper-bar-title"
      class="overflow-clip rounded-card border border-subtle bg-white"
    >
      <div class="flex flex-wrap items-start justify-between gap-3 border-b border-subtle bg-canvas px-5 py-4">
        <div class="max-w-[60ch]">
          <h2
            id="station-helper-bar-title"
            class="text-[13px] font-bold uppercase tracking-wide text-muted"
          >
            Explain this station
          </h2>
          <p class="mt-1 text-sm text-default">
            Ask about a recorded reachability check or the station's current report facts. The helper
            reads; it never runs a check or changes data.
          </p>
        </div>
        <.button
          id="station-helper-open"
          type="button"
          phx-click="agent_open"
          variant="secondary"
          aria-expanded={to_string(@open?)}
          aria-controls="agent-panel"
          class="min-h-11"
        >
          <.icon name="hero-sparkles" class="size-4" /> Open helper
        </.button>
      </div>

      <div class="grid gap-4 px-5 py-4 sm:grid-cols-[minmax(0,20rem)_minmax(0,1fr)] sm:items-end">
        <.form
          for={@form}
          id="station-result-run-select"
          phx-change="select_result_run"
          class="min-w-0"
        >
          <.input
            field={@form[:run_id]}
            type="select"
            label="Recorded check"
            id="station-result-run-select-input"
            prompt="No recorded check selected"
            options={Enum.map(@runs, &{run_label(&1), &1.id})}
          />
        </.form>

        <p id="station-helper-freshness" class="text-[13px] text-muted tabular-nums">
          {freshness_text(@selected)}
        </p>
      </div>

      <p
        :if={@notice}
        id="station-helper-notice"
        role="status"
        class="border-t border-subtle px-5 py-3 text-[13px] text-default"
      >
        {@notice}
      </p>
    </section>
    """
  end

  # The freshness line states what the stored run itself records and nothing
  # more: whether today's station input still equals that recorded input is the
  # projection's equality verdict, reported in the helper's server evidence
  # rather than asserted here.
  defp freshness_text(nil) do
    "No recorded check is selected. The helper can still explain this station's current report facts."
  end

  defp freshness_text(%{result_json: %{"input_provenance" => %{"digest" => digest}}})
       when is_binary(digest) do
    "This check recorded its input (digest #{short_digest(digest)}). Whether today's station still matches it is reported in the helper's server evidence."
  end

  defp freshness_text(%{}) do
    "This check recorded no input digest, so how current its input is, is unknown."
  end

  defp short_digest(digest), do: binary_part(digest, 0, 12)

  # Two checks of the same station can finish in the same minute, so the label
  # names what this one can explain: when it ran, what it recorded, and whether
  # it recorded the input it routed on. The station and the version are the page
  # this selector is on, so repeating them would only widen the control.
  defp run_label(run) do
    checked = Calendar.strftime(run.completed_at || run.inserted_at, "%b %-d %Y %H:%M")
    "#{checked} · #{recorded_outcome(run)} · #{input_state(run)}"
  end

  defp recorded_outcome(%{result_json: %{"outcome" => outcome}}) when is_binary(outcome),
    do: outcome

  defp recorded_outcome(%{status: status}), do: status

  defp input_state(%{result_json: %{"input_provenance" => %{"digest" => digest}}})
       when is_binary(digest),
       do: "input recorded"

  defp input_state(%{}), do: "no recorded input"

  # The station's name once its record is known, its stop id before that.
  defp station_title(nil, stop_id), do: stop_id
  defp station_title(station, stop_id), do: station.stop_name || stop_id

  # The facts the workspace header adds once the report has loaded.
  defp station_facts(%{snapshot: %{levels: levels, child_stops: child_stops}}) do
    "#{Wording.count_noun(length(levels), "level", "levels")} · " <>
      "#{Wording.count_noun(length(child_stops), "stop or node", "stops and nodes")} inside"
  end

  attr(:state, :atom, required: true)
  attr(:reason, :atom, default: nil)
  attr(:error, :atom, default: nil)

  defp report_status(%{state: :ready} = assigns) do
    ~H""
  end

  defp report_status(assigns) do
    ~H"""
    <div id="report-status" data-role="report-status" data-state={@state} class="print:hidden">
      <.report_skeleton :if={@state == :initial_loading} />

      <div
        :if={@state == :refreshing}
        role="status"
        class="flex items-center gap-3 rounded-control bg-soft px-4 py-3 text-sm font-bold text-cyan-800"
      >
        <.icon name="hero-arrow-path" class="size-5 shrink-0 text-cyan-700 motion-safe:animate-spin" />
        <span>{refresh_label(@reason)}</span>
      </div>

      <.message :if={@state == :error} kind="error" title={error_title(@error)}>
        {error_body(@error)}
        <:action>
          <.button id="report-retry" type="button" phx-click="retry_report" class="min-h-11">
            Retry report
          </.button>
        </:action>
      </.message>
    </div>
    """
  end

  # First paint only: it mirrors the summary card and the first two section
  # cards, so the page does not jump when the report arrives.
  defp report_skeleton(assigns) do
    ~H"""
    <div role="status">
      <p class="text-sm text-muted">Loading report…</p>
      <div aria-hidden="true" class="mt-4 space-y-6 motion-safe:animate-pulse">
        <div class="space-y-3 rounded-card border border-subtle bg-white px-6 py-6">
          <div class="h-6 w-56 rounded-control bg-navy-100"></div>
          <div class="h-4 w-80 max-w-full rounded-control bg-navy-100"></div>
          <div class="h-4 w-64 max-w-full rounded-control bg-navy-100"></div>
        </div>
        <div
          :for={_section <- 1..2}
          class="overflow-clip rounded-card border border-subtle bg-white"
        >
          <div class="space-y-2 border-b border-subtle bg-canvas px-6 py-4">
            <div class="h-5 w-48 rounded-control bg-navy-100"></div>
            <div class="h-4 w-72 max-w-full rounded-control bg-navy-100"></div>
          </div>
          <div :for={_row <- 1..3} class="flex gap-5 border-b border-subtle px-6 py-4 last:border-b-0">
            <div class="h-6 w-24 shrink-0 rounded-badge bg-navy-100"></div>
            <div class="flex-1 space-y-2">
              <div class="h-4 w-2/3 rounded-control bg-navy-100"></div>
              <div class="h-4 w-1/2 rounded-control bg-navy-100"></div>
            </div>
          </div>
        </div>
      </div>
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
    |> assign(:drawer_levels, [])
    |> assign(:drawer_error, nil)
    |> assign(:drawer_save_error, nil)
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
    |> assign(:drawer_save_error, nil)
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
      str -> str |> String.split(",") |> Enum.map(&parse_dimension/1) |> Enum.reject(&is_nil/1)
    end
  end

  # An unknown dimension is rejected rather than coerced: expanding an
  # unrequested dimension would make the URL-controlled disclosure state lie.
  defp parse_dimension("entrance_to_platform"), do: :entrance_to_platform
  defp parse_dimension("platform_to_exit"), do: :platform_to_exit
  defp parse_dimension("platform_to_platform"), do: :platform_to_platform
  defp parse_dimension(_), do: nil
end
