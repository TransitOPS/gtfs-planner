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

  # The battery plans every pair in both modes, so the two entries for one
  # origin/destination belong on one row. Order matches the battery's own.
  @kinds [
    {"entry", "Entry", "Street to platform",
     "Can a rider coming in off the street reach each platform?"},
    {"egress", "Egress", "Platform to street",
     "Can a rider standing on each platform find a way out?"},
    {"transfer", "Transfer", "Platform to platform",
     "Can a rider change platforms without leaving the station?"}
  ]

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
     |> assign(:envelope, nil)
     |> assign(:sections, [])
     |> assign(:expanded_keys, MapSet.new())
     |> assign(:trips, %{})
     |> assign(:graph, nil)}
  end

  @impl Phoenix.LiveView
  def handle_params(%{"validation_id" => validation_id} = params, _uri, socket) do
    run = Validations.get_validation_run!(validation_id)
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    cond do
      run.organization_id != organization_id or run.gtfs_version_id != gtfs_version_id ->
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

    run = Validations.get_validation_run!(run.id)

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
      # A different run means different pairs; nothing cached still applies.
      |> assign(:expanded_keys, MapSet.new())
      |> assign(:trips, %{})
      |> assign(:graph, nil)

    if legacy? do
      assign(socket, :legacy_results, Legacy.list_run_results(run.id))
    else
      socket
      |> assign(:envelope, run.result_json)
      |> assign(:sections, build_sections(run.result_json))
    end
  end

  @impl Phoenix.LiveView
  def handle_info({:reachability_run_completed, run_id}, socket) do
    if socket.assigns[:validation_id] == run_id do
      run = Reachability.get_run(run_id)

      {:noreply,
       socket
       |> assign(:run, run)
       |> assign(:envelope, run.result_json)
       |> assign(:sections, build_sections(run.result_json))}
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
  def handle_event("toggle_pair", %{"from" => from_stop_id, "to" => to_stop_id}, socket) do
    key = pair_key(from_stop_id, to_stop_id)

    if MapSet.member?(socket.assigns.expanded_keys, key) do
      {:noreply, assign(socket, :expanded_keys, MapSet.delete(socket.assigns.expanded_keys, key))}
    else
      socket = assign(socket, :expanded_keys, MapSet.put(socket.assigns.expanded_keys, key))
      {:noreply, load_trip(socket, key, from_stop_id, to_stop_id)}
    end
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

  # The run stores totals, not itineraries, so an expanded pair is re-planned.
  # The graph is built once per session and reused by every later expansion.
  defp load_trip(socket, key, from_stop_id, to_stop_id) do
    if Map.has_key?(socket.assigns.trips, key) do
      socket
    else
      case ensure_graph(socket) do
        {:ok, graph, socket} ->
          trip = Reachability.plan_pair(graph, from_stop_id, to_stop_id)
          assign(socket, :trips, Map.put(socket.assigns.trips, key, {:ok, trip}))

        {:error, reason} ->
          assign(socket, :trips, Map.put(socket.assigns.trips, key, {:error, reason}))
      end
    end
  end

  defp ensure_graph(%{assigns: %{graph: nil}} = socket) do
    case Reachability.station_graph(
           socket.assigns.current_organization.id,
           socket.assigns.current_gtfs_version.id,
           socket.assigns.stop_id
         ) do
      {:ok, graph} -> {:ok, graph, assign(socket, :graph, graph)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_graph(socket), do: {:ok, socket.assigns.graph, socket}

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
            <.new_engine_results
              envelope={@envelope}
              diagnostics_expanded?={@diagnostics_expanded?}
              sections={@sections}
              expanded_keys={@expanded_keys}
              trips={@trips}
            />
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
            {result.walkability_test &&
              (result.walkability_test.description || result.walkability_test.address)}
          </:col>
          <:col :let={result} label="Origin">
            {result.walkability_test && result.walkability_test.stop_id}
          </:col>
          <:col :let={result} label="Destination">
            {result.walkability_test && result.walkability_test.address}
          </:col>
          <:col :let={result} label="Status">
            <.status_badge
              status={if(result.route_exists, do: "completed", else: "failed")}
              label={if(result.route_exists, do: "Reachable", else: "Unreachable")}
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
  attr :sections, :list, required: true
  attr :expanded_keys, :any, required: true
  attr :trips, :map, required: true

  defp new_engine_results(assigns) do
    ~H"""
    <div class="space-y-6">
      <.engine_note />

      <%= if @envelope && @envelope["diagnostics"] not in [nil, []] do %>
        <.diagnostics_section
          diagnostics={@envelope["diagnostics"]}
          expanded?={@diagnostics_expanded?}
        />
      <% end %>

      <%= if @envelope do %>
        <.topology_section envelope={@envelope} />

        <%= if @sections == [] do %>
          <.empty_state id="reachability-no-pairs" title="No pairs tested" class="bg-base-100">
            This run produced no origin/destination pairs. A station needs at least one
            entrance and one platform before reachability can be tested.
          </.empty_state>
        <% else %>
          <.results_section
            :for={section <- @sections}
            section={section}
            expanded_keys={@expanded_keys}
            trips={@trips}
          />
        <% end %>
      <% end %>
    </div>
    """
  end

  # Agencies read this page to find out what a trip planner will make of their
  # pathways data. Say so plainly: the numbers below mean nothing without it.
  defp engine_note(assigns) do
    ~H"""
    <div
      id="reachability-engine-note"
      class="bg-base-100 border border-base-300 rounded-box px-4 py-3 text-sm"
    >
      <p class="max-w-prose">
        Your pathways data, run through the routing model OpenTripPlanner uses.
        It shows what a trip planner will make of this station before you ship the feed.
      </p>
      <p class="mt-2 max-w-prose text-base-content/70">
        Every origin and destination is planned twice: once on foot, once step-free.
        Step-free planning drops all stairs and escalators, so a pair that walks but has
        no step-free route is an accessibility gap, not a missing pathway.
      </p>
    </div>
    """
  end

  attr :section, :map, required: true
  attr :expanded_keys, :any, required: true
  attr :trips, :map, required: true

  defp results_section(assigns) do
    ~H"""
    <section
      id={"reachability-section-#{@section.kind}"}
      class="bg-base-100 border border-base-300 rounded-box overflow-hidden"
    >
      <div class="border-b border-base-300 px-4 py-3">
        <div class="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
          <h2 class="text-lg font-semibold">
            {@section.title}
            <span class="font-normal text-base-content/70">· {@section.subtitle}</span>
          </h2>
          <p
            id={"reachability-section-#{@section.kind}-stats"}
            class="text-sm text-base-content/70 tabular-nums"
          >
            {@section.stats.walking_reachable}/{@section.stats.total} on foot · {@section.stats.wheelchair_reachable}/{@section.stats.total} step-free
          </p>
        </div>
        <p class="mt-1 max-w-prose text-sm text-base-content/70">{@section.description}</p>
      </div>

      <div class="divide-y divide-base-200">
        <.pair_row
          :for={row <- @section.rows}
          row={row}
          expanded={MapSet.member?(@expanded_keys, row.key)}
          trip={Map.get(@trips, row.key)}
        />
      </div>
    </section>
    """
  end

  attr :row, :map, required: true
  attr :expanded, :boolean, required: true
  attr :trip, :any, default: nil

  defp pair_row(assigns) do
    assigns = assign(assigns, :region_id, "trip-#{assigns.row.dom_id}")

    ~H"""
    <div>
      <button
        type="button"
        id={"pair-#{@row.dom_id}"}
        phx-click="toggle_pair"
        phx-value-from={@row.from_stop_id}
        phx-value-to={@row.to_stop_id}
        aria-expanded={to_string(@expanded)}
        aria-controls={@region_id}
        class="flex w-full min-h-11 cursor-pointer flex-col gap-2 px-4 py-3 text-left motion-safe:transition-colors hover:bg-base-200 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary focus-visible:ring-inset sm:flex-row sm:items-center sm:justify-between"
      >
        <span class="flex min-w-0 items-center gap-1">
          <.icon
            name={if @expanded, do: "hero-chevron-down", else: "hero-chevron-right"}
            class="size-4 shrink-0"
          />
          <span class="text-sm font-medium break-words">
            {@row.from_stop_name} → {@row.to_stop_name}
          </span>
        </span>

        <span class="flex flex-wrap items-center gap-x-4 gap-y-1 ps-5 sm:ps-0">
          <.mode_outcome label="On foot" pair={@row.walking} mode={:walking} />
          <.mode_outcome label="Step-free" pair={@row.wheelchair} mode={:wheelchair} />
        </span>
      </button>

      <div
        :if={@expanded}
        id={@region_id}
        role="region"
        aria-label={"Trip from #{@row.from_stop_name} to #{@row.to_stop_name}"}
        class="space-y-4 border-t border-base-300 bg-base-200/40 px-4 py-3"
      >
        <p
          :for={{label, text} <- explanations(@row)}
          class="flex max-w-prose items-start gap-2 text-sm"
        >
          <.icon name="hero-information-circle" class="size-4 shrink-0 text-base-content/70" />
          <span class="break-words"><span class="font-medium">{label}:</span> {text}</span>
        </p>

        <%= case @trip do %>
          <% {:ok, trip} -> %>
            <.trip_detail label="On foot" result={trip.walking} />
            <.trip_detail label="Step-free" result={trip.wheelchair} />
          <% {:error, _reason} -> %>
            <p class="text-sm">
              Trip detail is unavailable. The station could not be loaded for planning.
            </p>
          <% _ -> %>
            <p class="text-sm text-base-content/70" aria-live="polite">Planning trip…</p>
        <% end %>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :pair, :any, required: true
  attr :mode, :atom, required: true

  defp mode_outcome(assigns) do
    {status, word} = outcome_badge(assigns.pair, assigns.mode)

    assigns =
      assigns
      |> assign(:status, status)
      |> assign(:word, word)
      |> assign(:metrics, pair_metrics(assigns.pair))

    ~H"""
    <span class="inline-flex items-baseline gap-1.5">
      <span class="text-xs text-base-content/70">{@label}</span>
      <.status_badge status={@status} label={@word} data-mode={to_string(@mode)} />
      <span :if={@metrics} class="text-xs text-base-content/70 tabular-nums">{@metrics}</span>
    </span>
    """
  end

  attr :label, :string, required: true
  attr :result, :any, required: true

  defp trip_detail(%{result: {:ok, _route}} = assigns) do
    assigns = assign(assigns, :route, elem(assigns.result, 1))

    ~H"""
    <div>
      <div class="flex flex-wrap items-baseline gap-x-3 gap-y-1">
        <h3 class="text-sm font-semibold">{@label}</h3>
        <p class="text-sm text-base-content/70 tabular-nums">
          {@route.duration_seconds}s · {format_meters(@route.distance_meters)} · {@route.step_count} {if @route.step_count ==
                                                                                                           1,
                                                                                                         do:
                                                                                                           "step",
                                                                                                         else:
                                                                                                           "steps"}
        </p>
      </div>

      <ol class="mt-2 space-y-1">
        <li
          :for={{step, num} <- Enum.with_index(@route.steps, 1)}
          class="flex gap-2 text-sm"
        >
          <span class="w-5 shrink-0 text-right tabular-nums text-base-content/70">{num}</span>
          <span class="min-w-0 break-words">
            <span class="font-medium">{direction_label(step.direction)}</span>
            <span :if={present?(step.name)}>— {step.name}</span>
            <span
              :if={step.name_derived? and present?(step.name)}
              class="text-xs text-base-content/70"
            >
              (derived, not signposted)
            </span>
            <span :if={step.distance_meters > 0} class="text-base-content/70 tabular-nums">
              · {format_meters(step.distance_meters)}
            </span>
          </span>
        </li>
      </ol>
    </div>
    """
  end

  defp trip_detail(assigns), do: ~H""

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

  defp outcome_status("reachable"), do: "completed"
  defp outcome_status("unreachable"), do: "failed"
  defp outcome_status("invalid"), do: "warning"
  defp outcome_status(_outcome), do: "unknown"

  # ── Section building ───────────────────────────────────────────────────────

  defp build_sections(%{"pairs" => pairs}) when is_list(pairs) do
    by_kind = Enum.group_by(pairs, & &1["kind"])

    @kinds
    |> Enum.map(fn {kind, title, subtitle, description} ->
      rows = merge_mode_rows(Map.get(by_kind, kind, []))

      %{
        kind: kind,
        title: title,
        subtitle: subtitle,
        description: description,
        rows: rows,
        stats: section_stats(rows)
      }
    end)
    |> Enum.reject(&(&1.rows == []))
  end

  defp build_sections(_envelope), do: []

  # One origin/destination, both modes, so accessibility reads as a comparison
  # rather than two rows a screen apart.
  defp merge_mode_rows(pairs) do
    pairs
    |> Enum.group_by(&{&1["from_stop_id"], &1["to_stop_id"]})
    |> Enum.map(fn {{from_stop_id, to_stop_id}, entries} ->
      reference = List.first(entries)

      %{
        key: pair_key(from_stop_id, to_stop_id),
        dom_id: dom_id(from_stop_id, to_stop_id),
        index: entries |> Enum.map(& &1["index"]) |> Enum.min(),
        from_stop_id: from_stop_id,
        from_stop_name: reference["from_stop_name"] || from_stop_id,
        to_stop_id: to_stop_id,
        to_stop_name: reference["to_stop_name"] || to_stop_id,
        walking: Enum.find(entries, &(&1["mode"] == "walking")),
        wheelchair: Enum.find(entries, &(&1["mode"] == "wheelchair"))
      }
    end)
    |> Enum.sort_by(& &1.index)
  end

  defp section_stats(rows) do
    %{
      total: length(rows),
      walking_reachable: Enum.count(rows, &reachable?(&1.walking)),
      wheelchair_reachable: Enum.count(rows, &reachable?(&1.wheelchair))
    }
  end

  defp pair_key(from_stop_id, to_stop_id), do: "#{from_stop_id}|#{to_stop_id}"

  defp dom_id(from_stop_id, to_stop_id) do
    String.replace(pair_key(from_stop_id, to_stop_id), ~r/[^A-Za-z0-9_-]/, "-")
  end

  defp reachable?(%{"outcome" => "reachable"}), do: true
  defp reachable?(_pair), do: false

  defp invalid?(%{"outcome" => "invalid"}), do: true
  defp invalid?(_pair), do: false

  # ── Outcome presentation ───────────────────────────────────────────────────

  # Severity mirrors Scoring: a walking failure is an error, a step-free failure
  # is a warning. The colour has to mean the same thing here as in the totals.
  defp outcome_badge(nil, _mode), do: {"unknown", "Not tested"}
  defp outcome_badge(%{"outcome" => "reachable"}, _mode), do: {"pass", "Reachable"}
  defp outcome_badge(%{"outcome" => "invalid"}, _mode), do: {"warning", "Not planned"}
  defp outcome_badge(%{"outcome" => "unreachable"}, :walking), do: {"failed", "No route"}

  defp outcome_badge(%{"outcome" => "unreachable"}, :wheelchair),
    do: {"warning", "No step-free route"}

  defp outcome_badge(_pair, _mode), do: {"unknown", "Unknown"}

  defp pair_metrics(%{"outcome" => "reachable"} = pair) do
    [
      pair["duration_seconds"] && "#{pair["duration_seconds"]}s",
      pair["distance_meters"] && format_meters(pair["distance_meters"])
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      parts -> Enum.join(parts, " · ")
    end
  end

  defp pair_metrics(_pair), do: nil

  # ── Failure explanations ───────────────────────────────────────────────────

  # Both modes are planned, so each explains the other: a pair that walks but
  # does not roll is an accessibility gap, not a hole in the pathway graph.
  defp explanations(row) do
    [{"On foot", walking_explanation(row)}, {"Step-free", wheelchair_explanation(row)}]
    |> Enum.reject(fn {_label, text} -> is_nil(text) end)
  end

  defp walking_explanation(%{walking: nil}), do: nil

  defp walking_explanation(%{walking: pair}) do
    cond do
      reachable?(pair) -> nil
      invalid?(pair) -> invalid_explanation(pair)
      true -> "No pathway route connects these two elements in either direction of travel. \
They sit in separate parts of the pathway graph — look for a missing pathway record between them."
    end
  end

  defp wheelchair_explanation(%{wheelchair: nil}), do: nil

  defp wheelchair_explanation(%{wheelchair: pair} = row) do
    cond do
      reachable?(pair) ->
        nil

      invalid?(pair) ->
        invalid_explanation(pair)

      reachable?(row.walking) ->
        "Reachable on foot, but every connecting route uses stairs or an escalator. \
Step-free planning drops both, so no route survives. Adding an elevator or ramp pathway would close this."

      true ->
        "No route in either mode; see the walking explanation above."
    end
  end

  defp invalid_explanation(%{"reason" => "same_origin_and_destination"}),
    do: "Origin and destination are the same element, so there is nothing to plan."

  defp invalid_explanation(%{"reason" => "unknown_element: " <> element_id}) do
    "#{element_id} is not in the routing graph. A stop is left out when it has no coordinates \
and none can be inherited from its parent station."
  end

  defp invalid_explanation(_pair), do: "The router could not plan this pair."

  # ── Formatting ─────────────────────────────────────────────────────────────

  defp direction_label(:depart), do: "Depart"
  defp direction_label(:continue), do: "Continue"
  defp direction_label(:left), do: "Left"
  defp direction_label(:right), do: "Right"
  defp direction_label(:hard_left), do: "Hard left"
  defp direction_label(:hard_right), do: "Hard right"
  defp direction_label(:slightly_left), do: "Slight left"
  defp direction_label(:slightly_right), do: "Slight right"
  defp direction_label(:follow_signs), do: "Follow signs"
  defp direction_label(:elevator), do: "Elevator"
  defp direction_label(other), do: other |> to_string() |> String.replace("_", " ")

  defp format_meters(nil), do: "—"
  defp format_meters(meters) when is_integer(meters), do: "#{meters}m"
  defp format_meters(meters) when is_float(meters), do: "#{Float.round(meters, 1)}m"
  defp format_meters(meters), do: "#{meters}m"

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

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
