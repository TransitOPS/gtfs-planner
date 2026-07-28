defmodule GtfsPlannerWeb.Gtfs.StationReachabilityResultLive do
  use GtfsPlannerWeb, :live_view

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Reachability
  alias GtfsPlanner.Validations
  alias GtfsPlanner.Validations.Legacy
  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.Layouts

  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  # A diagnostics list can run long. Show a readable head plus a severity
  # summary; the rest is one click away.
  @diagnostics_preview_count 5

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Validation Results")
     |> assign(:stop_id, nil)
     |> assign(:station, nil)
     |> assign(:run, nil)
     |> assign(:legacy?, false)
     |> assign(:legacy_results, [])
     |> assign(:diagnostics_expanded?, false)
     |> assign(:envelope, nil)}
  end

  @impl Phoenix.LiveView
  def handle_params(%{"validation_id" => validation_id} = params, _uri, socket) do
    run = Validations.get_validation_run!(validation_id)
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    cond do
      run.organization_id != organization_id ->
        {:noreply,
         socket
         |> put_flash(:error, "Unauthorized access to validation run")
         |> push_navigate(to: ~p"/gtfs/#{gtfs_version_id}/export")}

      run.run_type != "station_reachability" ->
        {:noreply, push_navigate(socket, to: ~p"/gtfs/#{gtfs_version_id}/validation/#{run.id}")}

      true ->
        {:noreply, assign_run(socket, run, Map.get(params, "stop_id"))}
    end
  end

  defp assign_run(socket, run, param_stop_id) do
    if connected?(socket) and run.status in ["pending", "started", "running"] do
      Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, Reachability.topic(run.id))
    end

    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id
    legacy? = Legacy.legacy_station_run?(run)
    stop_id = station_stop_id(run) || param_stop_id

    socket =
      socket
      |> assign(:stop_id, stop_id)
      |> assign(:station, fetch_station(organization_id, gtfs_version_id, stop_id))
      |> assign(:validation_id, run.id)
      |> assign(:run, run)
      |> assign(:legacy?, legacy?)
      |> assign(:diagnostics_expanded?, false)

    if legacy? do
      assign(socket, :legacy_results, Legacy.list_run_results(run.id))
    else
      assign(socket, :envelope, run.result_json)
    end
  end

  @impl Phoenix.LiveView
  def handle_info({:reachability_run_completed, run_id}, socket) do
    if socket.assigns[:validation_id] == run_id do
      run = Reachability.get_run(run_id)

      {:noreply,
       socket
       |> assign(:run, run)
       |> assign(:envelope, run.result_json)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:reachability_run_failed, run_id, _reason}, socket) do
    if socket.assigns[:validation_id] == run_id do
      run = Reachability.get_run(run_id)
      {:noreply, assign(socket, :run, run)}
    else
      {:noreply, socket}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("toggle_diagnostics", _params, socket) do
    {:noreply, assign(socket, :diagnostics_expanded?, not socket.assigns.diagnostics_expanded?)}
  end

  @impl Phoenix.LiveView
  def handle_event("gtfs_version_loaded", %{"version_id" => version_id}, socket) do
    current_organization = socket.assigns.current_organization
    current_version_id = to_string(socket.assigns.current_gtfs_version.id)

    if version_id && version_id != current_version_id &&
         Versions.published_gtfs_version_for_org?(current_organization.id, version_id) do
      validation_id = socket.assigns[:validation_id]

      if validation_id do
        {:noreply,
         push_navigate(socket, to: "/gtfs/#{version_id}/station-reachability/#{validation_id}")}
      else
        {:noreply, push_navigate(socket, to: "/gtfs/#{version_id}/export")}
      end
    else
      {:noreply, socket}
    end
  end

  @impl Phoenix.LiveView
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
      <:sub_header :if={@station}>
        <.station_sub_nav
          station={@station}
          gtfs_version_id={@current_gtfs_version.id}
          active_tab={:reachability}
        />
      </:sub_header>

      <section id="station-reachability-results" class="space-y-6">
        <.header>
          Reachability results
          <:subtitle>
            {run_subtitle(@run)}
          </:subtitle>
          <:actions>
            <.status_badge status={@run.status} />
          </:actions>
        </.header>

        <%= cond do %>
          <% @run.status == "failed" -> %>
            <.failed_state run={@run} />
          <% @run.status in ["pending", "started", "running"] -> %>
            <.running_state />
          <% @legacy? -> %>
            <.legacy_results run={@run} results={@legacy_results} />
          <% true -> %>
            <.new_engine_results envelope={@envelope} diagnostics_expanded?={@diagnostics_expanded?} />
        <% end %>
      </section>
    </Layouts.app>
    """
  end

  attr :run, :map, required: true

  defp failed_state(assigns) do
    ~H"""
    <.callout kind="error" title="Reachability run failed" id="reachability-failed" role="alert">
      {@run.error_details || "The reachability run failed unexpectedly."} Run it again from the Reachability tab.
    </.callout>
    """
  end

  defp running_state(assigns) do
    ~H"""
    <.callout
      kind="info"
      title="Reachability analysis is running"
      id="reachability-running"
      role="status"
      aria-live="polite"
    >
      Results appear here automatically when the run finishes.
    </.callout>
    """
  end

  attr :run, :map, required: true
  attr :results, :list, required: true

  defp legacy_results(assigns) do
    ~H"""
    <div class="space-y-4">
      <.callout kind="warning" title="Retired engine">
        This run used the retired street-address engine and is not directly comparable
        to in-station structural reachability results.
      </.callout>

      <div class="bg-base-100 border border-base-300 rounded-box overflow-hidden">
        <.table id="legacy-reachability-results" rows={@results}>
          <:col :let={result} label="Test">
            {result.walkability_test && result.walkability_test.name}
          </:col>
          <:col :let={result} label="Origin">{result.origin_description}</:col>
          <:col :let={result} label="Destination">{result.destination_description}</:col>
          <:col :let={result} label="Status">
            <.status_badge
              status={if(result.reachable, do: "completed", else: "failed")}
              label={if(result.reachable, do: "Reachable", else: "Unreachable")}
            />
          </:col>
          <:col :let={result} label="Duration">
            {result.duration_seconds && "#{result.duration_seconds}s"}
          </:col>
        </.table>
      </div>
    </div>
    """
  end

  attr :envelope, :map, required: true
  attr :diagnostics_expanded?, :boolean, required: true

  defp new_engine_results(assigns) do
    ~H"""
    <div class="space-y-6">
      <%= if @envelope && @envelope["diagnostics"] not in [nil, []] do %>
        <.diagnostics_section
          diagnostics={@envelope["diagnostics"]}
          expanded?={@diagnostics_expanded?}
        />
      <% end %>

      <%= if @envelope do %>
        <.topology_section envelope={@envelope} />
        <.pair_matrix pairs={@envelope["pairs"]} />
      <% end %>
    </div>
    """
  end

  attr :diagnostics, :list, required: true
  attr :expanded?, :boolean, required: true

  defp diagnostics_section(assigns) do
    total = length(assigns.diagnostics)
    collapsible? = total > @diagnostics_preview_count

    visible =
      if assigns.expanded? or not collapsible?,
        do: assigns.diagnostics,
        else: Enum.take(assigns.diagnostics, @diagnostics_preview_count)

    assigns =
      assigns
      |> assign(:total, total)
      |> assign(:collapsible?, collapsible?)
      |> assign(:visible, visible)
      |> assign(:preview_count, @diagnostics_preview_count)
      |> assign(:summary, diagnostics_summary(assigns.diagnostics))

    ~H"""
    <section
      id="graph-diagnostics"
      class="bg-base-100 border border-base-300 rounded-box overflow-hidden"
    >
      <div class="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1 border-b border-base-300 px-4 py-3">
        <h2 class="text-lg font-semibold">Graph diagnostics</h2>
        <p id="graph-diagnostics-summary" class="text-sm text-base-content/70 tabular-nums">
          {@summary}
        </p>
      </div>

      <ul id="graph-diagnostics-list" class="divide-y divide-base-200">
        <li
          :for={diag <- @visible}
          class="flex flex-wrap items-baseline gap-x-2 gap-y-0.5 px-4 py-2 text-sm"
        >
          <span class={[
            "font-medium",
            diag["severity"] == "error" && "text-error",
            diag["severity"] != "error" && "text-warning"
          ]}>
            {diagnostic_severity_label(diag["severity"])}
          </span>
          <span class="min-w-0 flex-1 break-words text-base-content">{diag["message"]}</span>
          <span :if={diag["entity_id"]} class="font-mono text-xs text-base-content/70 break-all">
            {diag["entity_id"]}
          </span>
        </li>
      </ul>

      <div :if={@collapsible?} class="border-t border-base-300 px-4 py-2">
        <button
          type="button"
          id="graph-diagnostics-toggle"
          phx-click="toggle_diagnostics"
          aria-expanded={to_string(@expanded?)}
          aria-controls="graph-diagnostics-list"
          class="inline-flex min-h-11 items-center gap-1 text-sm font-medium text-primary hover:underline"
        >
          <.icon
            name={if @expanded?, do: "hero-chevron-up", else: "hero-chevron-down"}
            class="size-4 shrink-0"
          />
          {if @expanded?, do: "Show first #{@preview_count}", else: "Show all #{@total}"}
        </button>
      </div>
    </section>
    """
  end

  attr :envelope, :map, required: true

  defp topology_section(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="grid grid-cols-2 gap-4 sm:grid-cols-4">
        <.stat_card label="Entrances" value={@envelope["topology"]["entrance_count"]} />
        <.stat_card label="Platforms" value={@envelope["topology"]["platform_count"]} />
        <.stat_card label="Pathways" value={@envelope["topology"]["pathway_count"]} />
        <.stat_card label="Levels" value={@envelope["topology"]["level_count"]} />
      </div>
      <div class="flex flex-wrap items-center gap-4">
        <.status_badge
          status={outcome_status(@envelope["outcome"])}
          label={String.capitalize(@envelope["outcome"])}
        />
        <span class="text-sm text-base-content/70 tabular-nums">
          {@envelope["totals"]["reachable"]} reachable / {@envelope["totals"]["pair_count"]} pairs
          ({@envelope["duration_ms"]}ms)
        </span>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true

  defp stat_card(assigns) do
    ~H"""
    <div class="bg-base-100 border border-base-300 rounded-box p-3 text-center">
      <div class="text-2xl font-bold tabular-nums">{@value}</div>
      <div class="text-xs text-base-content/70">{@label}</div>
    </div>
    """
  end

  attr :pairs, :list, required: true

  defp pair_matrix(assigns) do
    ~H"""
    <div class="bg-base-100 border border-base-300 rounded-box overflow-hidden">
      <.table id="pair-matrix" rows={@pairs} row_id={fn pair -> "pair-#{pair["index"]}" end}>
        <:col :let={pair} label="#" align="right">{pair["index"]}</:col>
        <:col :let={pair} label="Kind">{pair["kind"]}</:col>
        <:col :let={pair} label="Mode">{pair["mode"]}</:col>
        <:col :let={pair} label="From">
          <span title={pair["from_stop_id"]}>{pair["from_stop_name"] || pair["from_stop_id"]}</span>
        </:col>
        <:col :let={pair} label="To">
          <span title={pair["to_stop_id"]}>{pair["to_stop_name"] || pair["to_stop_id"]}</span>
        </:col>
        <:col :let={pair} label="Outcome">
          <.status_badge
            status={outcome_status(pair["outcome"])}
            label={String.capitalize(pair["outcome"])}
          />
        </:col>
        <:col :let={pair} label="Duration" align="right">
          {pair["duration_seconds"] && "#{pair["duration_seconds"]}s"}
        </:col>
        <:col :let={pair} label="Distance" align="right">
          {pair["distance_meters"] && "#{Float.round(pair["distance_meters"], 1)}m"}
        </:col>
        <:col :let={pair} label="Steps" align="right">{pair["step_count"]}</:col>
      </.table>
    </div>
    """
  end

  defp outcome_status("reachable"), do: "completed"
  defp outcome_status("unreachable"), do: "failed"
  defp outcome_status("invalid"), do: "warning"
  defp outcome_status(_outcome), do: "unknown"

  defp diagnostic_severity_label("error"), do: "Error"
  defp diagnostic_severity_label("warning"), do: "Warning"
  defp diagnostic_severity_label(severity), do: String.capitalize(to_string(severity || "notice"))

  defp diagnostics_summary(diagnostics) do
    errors = Enum.count(diagnostics, &(&1["severity"] == "error"))
    warnings = Enum.count(diagnostics, &(&1["severity"] == "warning"))
    other = length(diagnostics) - errors - warnings

    [{errors, "error"}, {warnings, "warning"}, {other, "other"}]
    |> Enum.filter(fn {count, _label} -> count > 0 end)
    |> Enum.map_join(" · ", fn {count, label} ->
      "#{count} #{label}#{if count == 1, do: "", else: "s"}"
    end)
  end

  defp station_stop_id(%{result_json: result_json}) when is_map(result_json) do
    get_in(result_json, ["metadata", "station_stop_id"])
  end

  defp station_stop_id(_run), do: nil

  defp fetch_station(_organization_id, _gtfs_version_id, nil), do: nil

  defp fetch_station(organization_id, gtfs_version_id, stop_id) do
    Gtfs.get_stop_by_stop_id(organization_id, gtfs_version_id, stop_id)
  end

  defp run_subtitle(run) do
    case run.status do
      "completed" -> "Completed #{Calendar.strftime(run.completed_at, "%b %d, %Y at %H:%M")}"
      "failed" -> "Failed"
      _ -> "In progress"
    end
  end
end
