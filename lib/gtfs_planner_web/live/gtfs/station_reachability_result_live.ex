defmodule GtfsPlannerWeb.Gtfs.StationReachabilityResultLive do
  use GtfsPlannerWeb, :live_view

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Reachability
  alias GtfsPlanner.Validations
  alias GtfsPlanner.Validations.Legacy
  alias GtfsPlanner.Values
  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.Layouts
  alias GtfsPlannerWeb.StationWorkspace

  import GtfsPlannerWeb.Gtfs.StationReachabilityComponents
  import GtfsPlannerWeb.ResultComponents, only: [tone_badge: 1]
  import GtfsPlannerWeb.PlannerComponents, only: [back_link: 1, message: 1]

  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  # A diagnostics list can run long. Show a readable head plus a severity
  # summary; the rest is one click away.
  @diagnostics_preview_count 5

  # The battery plans every pair in both modes, so the two entries for one
  # origin/destination belong on one row. Order matches the battery's own.
  @kinds [
    {"entry", "Getting in", "Street to platform"},
    {"egress", "Getting out", "Platform to street"},
    {"transfer", "Changing platforms", "Platform to platform"}
  ]

  # Plain-language wording for the router's diagnostic codes. The stored result
  # carries the code; a code missing here falls back to the router's own message.
  @diagnostic_text %{
    "missing_coordinate" =>
      "This stop has no location on the map, so it's left out of the check.",
    "missing_endpoint" => "This pathway points to a stop that isn't in the station.",
    "unresolvable_level" => "This stop refers to a level that doesn't exist.",
    "unknown_pathway_mode" =>
      "This pathway's mode isn't walkway, stairs, moving walkway, escalator, elevator, fare gate or exit gate.",
    "invalid_wheelchair_boarding" =>
      "This stop's wheelchair boarding value isn't one of the allowed values (0, 1 or 2).",
    "blank_pathway_id" => "A pathway has no ID, so it can't be told apart from others.",
    "orphan_boarding_area" => "This boarding area doesn't belong to a station.",
    "invalid_endpoint_location_type" =>
      "This pathway connects to the wrong kind of place, such as the station itself.",
    "ill_formed_id" => "This ID uses characters the check can't read."
  }

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
    version_id = assigns.current_gtfs_version.id

    assigns =
      assigns
      |> assign(:stations_path, ~p"/gtfs/#{version_id}/stops")
      |> assign(
        :reachability_path,
        assigns.station && ~p"/gtfs/#{version_id}/stops/#{assigns.station.stop_id}/reachability"
      )

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
        <StationWorkspace.station_header
          title={@station.stop_name || @station.stop_id}
          stop_id={@station.stop_id}
          gtfs_version_id={@current_gtfs_version.id}
          active_tab={:reachability}
        >
          <:meta>Station</:meta>
        </StationWorkspace.station_header>
      </:sub_header>

      <div id="station-reachability-results" class="ds-page pb-16 pt-2">
        <.back_link :if={@reachability_path} id="reachability-back" navigate={@reachability_path}>
          Reachability
        </.back_link>
        <.back_link :if={!@reachability_path} id="stops-back" navigate={@stations_path}>
          Stops &amp; stations
        </.back_link>

        <section
          aria-labelledby="reachability-results-title"
          class="flex flex-wrap items-start justify-between gap-x-10 gap-y-4 pb-6 pt-1"
        >
          <div class="max-w-[64ch]">
            <h2
              id="reachability-results-title"
              class="font-display text-[30px] font-semibold leading-[1.1] tracking-[-0.025em] text-strong sm:text-[36px]"
            >
              Reachability results
            </h2>
            <p class="mt-2 text-base text-muted tabular-nums">
              {run_subtitle(@run, @current_gtfs_version)}
            </p>
          </div>
          <.link
            :if={is_nil(@station)}
            id="open-stations"
            navigate={@stations_path}
            class="inline-flex min-h-11 items-center justify-center rounded-control bg-action px-5 text-sm font-[650] text-white no-underline hover:bg-action-hover max-sm:w-full"
          >
            Open stations
          </.link>
        </section>

        <p
          :if={is_nil(@stop_id)}
          id="reachability-station-unknown"
          class="mb-6 rounded-card bg-canvas px-4 py-3 text-sm text-default"
        >
          We can't tell which station this check was for. Open the station from Stops &amp; stations
          to run a new check.
        </p>

        <%= cond do %>
          <% @run.status == "failed" -> %>
            <.failed_state run={@run} reachability_path={@reachability_path} />
          <% @run.status in ["pending", "started", "running"] -> %>
            <.running_state />
          <% @legacy? -> %>
            <.legacy_results results={@legacy_results} />
          <% true -> %>
            <.new_engine_results
              run={@run}
              envelope={@envelope}
              station={@station}
              stop_id={@stop_id}
              gtfs_version={@current_gtfs_version}
              diagnostics_expanded?={@diagnostics_expanded?}
              sections={@sections}
              expanded_keys={@expanded_keys}
              trips={@trips}
            />
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  attr :run, :map, required: true
  attr :reachability_path, :string, default: nil

  defp failed_state(assigns) do
    ~H"""
    <section
      id="reachability-failed"
      role="alert"
      aria-labelledby="reachability-failed-title"
      class="rounded-card border border-error-line bg-error-bg p-5 text-error-fg sm:p-6"
    >
      <div class="flex items-start gap-3">
        <.icon name="hero-x-circle" class="mt-0.5 size-5 shrink-0" />
        <div class="min-w-0 flex-1">
          <h3 id="reachability-failed-title" class="text-lg font-bold">
            The check stopped before it finished.
          </h3>
          <p class="mt-1 text-sm">
            No walks were scored, and nothing in the station was changed. Run the check again from
            Reachability. If it fails again, contact support.
          </p>
          <details :if={Values.present?(@run.error_details)} class="mt-2">
            <summary class="flex min-h-11 cursor-pointer items-center font-semibold hover:underline">
              Technical details
            </summary>
            <p class="break-words rounded-control bg-white px-3 py-2 font-mono text-[13px] text-strong">
              {@run.error_details}
            </p>
          </details>
          <.link
            :if={@reachability_path}
            id="go-to-reachability"
            navigate={@reachability_path}
            class="mt-2 inline-flex min-h-11 items-center justify-center rounded-control border border-error-line bg-white px-4 text-sm font-[650] text-strong no-underline hover:bg-canvas"
          >
            Go to Reachability
          </.link>
        </div>
      </div>
    </section>
    """
  end

  defp running_state(assigns) do
    ~H"""
    <.progress_card title="Checking this station">
      Testing each walk on foot and step-free. Results appear here when the check finishes. You
      don't need to refresh.
    </.progress_card>
    """
  end

  attr :results, :list, required: true

  defp legacy_results(assigns) do
    assigns =
      assign(assigns, :reachable_count, Enum.count(assigns.results, & &1.route_exists))

    ~H"""
    <div class="grid gap-6">
      <.message id="legacy-note" kind="warning" title="This check used a method we've retired.">
        It tested walks from a stop to a street address, so its results can't be compared with
        in-station results, and it has no step-free result. Run a new check to see how riders get
        around inside the station.
      </.message>

      <section
        id="legacy-reachability-results"
        aria-labelledby="legacy-reachability-results-title"
        class="overflow-clip rounded-card border border-subtle bg-white"
      >
        <div class="border-b border-subtle bg-canvas px-5 py-4 sm:px-6">
          <h3 id="legacy-reachability-results-title" class="text-lg font-bold text-strong">
            Results from the older check
          </h3>
          <p class="mt-0.5 text-[13px] text-muted tabular-nums">
            {count_label(length(@results), "walk", "walks")} from stops to street addresses · {@reachable_count} reachable · {length(
              @results
            ) - @reachable_count} unreachable
          </p>
        </div>
        <table class="w-full border-collapse text-sm max-md:block">
          <caption class="sr-only">
            Walks from the older street-address check
          </caption>
          <thead class="max-md:hidden">
            <tr>
              <.column_head class="sm:px-6">Walk tested</.column_head>
              <.column_head>From stop</.column_head>
              <.column_head>To address</.column_head>
              <.column_head>Result</.column_head>
              <.column_head class="text-right sm:px-6">Time</.column_head>
            </tr>
          </thead>
          <tbody class="max-md:block">
            <tr :for={result <- @results} class="border-t border-subtle max-md:block">
              <th
                scope="row"
                class="px-4 py-3 text-left font-semibold text-strong max-md:block max-md:pb-1 sm:px-6"
              >
                {result.walkability_test &&
                  (result.walkability_test.description || result.walkability_test.address)}
              </th>
              <td class="px-4 py-3 font-mono text-[13px] text-muted max-md:inline-block max-md:py-1">
                {result.walkability_test && result.walkability_test.stop_id}
              </td>
              <td class="px-4 py-3 text-default max-md:block max-md:py-1">
                {result.walkability_test && result.walkability_test.address}
              </td>
              <td class="px-4 py-3 max-md:inline-block max-md:py-1">
                <%= if result.route_exists do %>
                  <.tone_badge tone="success">Reachable</.tone_badge>
                <% else %>
                  <.tone_badge tone="error">Unreachable</.tone_badge>
                <% end %>
              </td>
              <td class="px-4 py-3 text-right tabular-nums text-muted max-md:inline-block max-md:py-1 sm:px-6">
                {result.duration_seconds && "#{result.duration_seconds}s"}
              </td>
            </tr>
          </tbody>
        </table>
      </section>
    </div>
    """
  end

  attr :class, :string, default: nil
  slot :inner_block, required: true

  defp column_head(assigns) do
    ~H"""
    <th
      scope="col"
      class={[
        "border-b border-subtle bg-white px-4 py-2.5 text-left text-[13px] font-[650] text-strong",
        @class
      ]}
    >
      {render_slot(@inner_block)}
    </th>
    """
  end

  attr :run, :map, required: true
  attr :envelope, :map, default: nil
  attr :station, :map, default: nil
  attr :stop_id, :string, default: nil
  attr :gtfs_version, :map, required: true
  attr :diagnostics_expanded?, :boolean, required: true
  attr :sections, :list, required: true
  attr :expanded_keys, :any, required: true
  attr :trips, :map, required: true

  defp new_engine_results(assigns) do
    assigns =
      assigns
      |> assign(:summary, summarize(assigns.sections))
      |> assign(:diagnostics, (assigns.envelope && assigns.envelope["diagnostics"]) || [])

    ~H"""
    <div class="grid gap-6">
      <.no_pairs
        :if={@sections == []}
        envelope={@envelope}
        station={@station}
        gtfs_version={@gtfs_version}
      />

      <.verdict
        :if={@sections != []}
        envelope={@envelope}
        summary={@summary}
        diagnostics={@diagnostics}
      />

      <.diagnostics_section
        :if={@diagnostics != []}
        diagnostics={@diagnostics}
        expanded?={@diagnostics_expanded?}
      />

      <.walks_table
        :if={@sections != []}
        sections={@sections}
        expanded_keys={@expanded_keys}
        trips={@trips}
      />

      <.reading_guide :if={@sections != []} run={@run} envelope={@envelope} stop_id={@stop_id} />
    </div>
    """
  end

  attr :envelope, :map, default: nil
  attr :summary, :map, required: true
  attr :diagnostics, :list, required: true

  # The answer comes first: one badge, one sentence, and the counts behind it.
  # The colour follows the run's own scoring (`Scoring.run_outcome`): a step-free
  # failure alone is a warning, an on-foot or unplannable walk fails the run.
  defp verdict(assigns) do
    outcome = run_outcome(assigns.envelope)
    {tone, word, headline, lede} = verdict_copy(outcome, assigns.summary, assigns.diagnostics)

    assigns =
      assigns
      |> assign(:outcome, outcome)
      |> assign(:tone, tone)
      |> assign(:word, word)
      |> assign(:headline, headline)
      |> assign(:lede, lede)
      |> assign(:data_caption, data_caption(assigns.diagnostics))
      |> assign(:footer, verdict_footer(assigns.envelope))

    ~H"""
    <section
      id="reachability-verdict"
      data-outcome={@outcome}
      aria-labelledby="reachability-verdict-title"
      class="overflow-clip rounded-card border border-subtle bg-white"
    >
      <div class={["border-l-4 px-5 py-6 sm:px-7", verdict_edge(@outcome)]}>
        <.tone_badge tone={@tone}>{@word}</.tone_badge>
        <h3
          id="reachability-verdict-title"
          class="mt-3 max-w-[40rem] text-balance font-display text-[26px] font-semibold leading-[1.12] tracking-[-0.02em] text-strong sm:text-[30px]"
        >
          {@headline}
        </h3>
        <p :if={@lede} class="mt-3 max-w-[44rem] text-[15px] text-default">{@lede}</p>
      </div>
      <dl class="grid border-t border-subtle sm:grid-cols-3">
        <.figure
          id="reachability-verdict-on-foot"
          label="On foot"
          value={"#{@summary.foot_ok} of #{@summary.total}"}
          caption="walks work"
          class="border-b border-subtle sm:border-b-0 sm:border-r"
        />
        <.figure
          id="reachability-verdict-step-free"
          label="Step-free"
          value={"#{@summary.chair_ok} of #{@summary.total}"}
          caption="walks work"
          class="border-b border-subtle sm:border-b-0 sm:border-r"
        />
        <.figure
          id="reachability-verdict-station-data"
          label="Station data"
          value={length(@diagnostics)}
          caption={@data_caption}
        />
      </dl>
      <p
        :if={@footer}
        class="border-t border-subtle bg-canvas px-6 py-3 text-[13px] text-muted sm:px-8"
      >
        {@footer}
      </p>
    </section>
    """
  end

  attr :id, :string, default: nil
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :caption, :string, default: nil
  attr :class, :string, default: nil

  defp figure(assigns) do
    ~H"""
    <div id={@id} class={["px-6 py-4 sm:px-8", @class]}>
      <dt class="text-[13px] font-bold text-muted">{@label}</dt>
      <dd class="mt-1 font-display text-[30px] font-semibold leading-tight text-strong tabular-nums">
        {@value}
      </dd>
      <dd :if={@caption} class="text-[13px] text-muted">{@caption}</dd>
    </div>
    """
  end

  attr :envelope, :map, default: nil
  attr :station, :map, default: nil
  attr :gtfs_version, :map, required: true

  defp no_pairs(assigns) do
    assigns =
      assign(assigns, :topology, (assigns.envelope && assigns.envelope["topology"]) || %{})

    ~H"""
    <section
      id="reachability-no-pairs"
      aria-labelledby="reachability-no-pairs-title"
      class="overflow-clip rounded-card border border-subtle bg-white"
    >
      <div class="p-5 sm:p-6">
        <div class="flex flex-wrap items-center gap-x-3 gap-y-2">
          <h3 class="text-[13px] font-bold text-muted">Result</h3>
          <.tone_badge tone="neutral">Nothing to check</.tone_badge>
        </div>
        <p
          id="reachability-no-pairs-title"
          class="mt-3 max-w-[40ch] font-display text-[28px] font-semibold leading-[1.12] tracking-[-0.02em] text-strong sm:text-[32px]"
        >
          This check didn't test any walks.
        </p>
        <p class="mt-2 max-w-[62ch] text-sm text-default">
          A walk needs a place to start and a place to end. This station needs at least one
          entrance and one platform before the check can test anything. Add them in Floorplans,
          then run the check again.
        </p>
        <div :if={@station} class="mt-4">
          <.link
            id="open-floorplans"
            navigate={~p"/gtfs/#{@gtfs_version.id}/stops/#{@station.stop_id}/diagram"}
            class="inline-flex min-h-11 items-center justify-center rounded-control border border-control bg-white px-4 text-sm font-[650] text-strong no-underline hover:bg-canvas"
          >
            Open floorplans
          </.link>
        </div>
      </div>
      <dl
        :if={@topology != %{}}
        class="grid grid-cols-2 border-t border-subtle sm:grid-cols-4"
      >
        <.figure
          label="Entrances"
          value={@topology["entrance_count"]}
          class="border-b border-r border-subtle sm:border-b-0"
        />
        <.figure
          label="Platforms"
          value={@topology["platform_count"]}
          class="border-b border-subtle sm:border-b-0 sm:border-r"
        />
        <.figure
          label="Pathways"
          value={@topology["pathway_count"]}
          class="border-r border-subtle"
        />
        <.figure label="Levels" value={@topology["level_count"]} />
      </dl>
    </section>
    """
  end

  attr :sections, :list, required: true
  attr :expanded_keys, :any, required: true
  attr :trips, :map, required: true

  defp walks_table(assigns) do
    ~H"""
    <section
      id="reachability-walks"
      aria-labelledby="reachability-walks-title"
      class="overflow-clip rounded-card border border-subtle bg-white"
    >
      <div class="border-b border-subtle bg-canvas px-5 py-4 sm:px-6">
        <h3 id="reachability-walks-title" class="text-lg font-bold text-strong">Every walk</h3>
        <p class="mt-0.5 text-[13px] text-muted">
          Each walk is tested on foot and step-free. Select a walk to see its route.
        </p>
      </div>
      <table class="w-full border-collapse text-sm max-md:block">
        <caption class="sr-only">
          Walks in the station and how each one tests on foot and step-free
        </caption>
        <thead class="max-md:hidden">
          <tr>
            <%!-- An inset shadow, not a border: a collapsed border stays behind when a sticky cell moves. --%>
            <th
              :for={
                {label, class} <- [
                  {"Walk", "px-4 sm:px-6"},
                  {"On foot", "w-[26%] px-4"},
                  {"Step-free", "w-[26%] px-4"}
                ]
              }
              scope="col"
              class={[
                "sticky top-0 z-10 bg-white py-2.5 text-left text-[13px] font-[650] text-strong shadow-[inset_0_-1px_0_var(--color-subtle)]",
                class
              ]}
            >
              {label}
            </th>
          </tr>
        </thead>
        <.walk_group
          :for={section <- @sections}
          section={section}
          expanded_keys={@expanded_keys}
          trips={@trips}
        />
      </table>
    </section>
    """
  end

  attr :section, :map, required: true
  attr :expanded_keys, :any, required: true
  attr :trips, :map, required: true

  defp walk_group(assigns) do
    ~H"""
    <tbody id={"reachability-section-#{@section.kind}"} class="max-md:block">
      <tr class="border-t border-subtle bg-white max-md:block">
        <th scope="rowgroup" colspan="3" class="px-4 pb-1.5 pt-5 text-left max-md:block sm:px-6">
          <span class="font-bold text-strong">{@section.title}</span>
          <span class="text-muted">· {@section.subtitle}</span>
          <span
            id={"reachability-section-#{@section.kind}-stats"}
            class="ml-3 text-[13px] font-normal tabular-nums text-muted"
          >
            {@section.stats.walking_reachable} of {@section.stats.total} on foot · {@section.stats.wheelchair_reachable} of {@section.stats.total} step-free
          </span>
        </th>
      </tr>
      <.walk_row
        :for={row <- @section.rows}
        row={row}
        expanded={MapSet.member?(@expanded_keys, row.key)}
        trip={Map.get(@trips, row.key)}
      />
    </tbody>
    """
  end

  attr :row, :map, required: true
  attr :expanded, :boolean, required: true
  attr :trip, :any, default: nil

  defp walk_row(assigns) do
    assigns = assign(assigns, :region_id, "trip-#{assigns.row.dom_id}")

    ~H"""
    <tr id={"walk-#{@row.dom_id}"} class="border-t border-subtle hover:bg-canvas max-md:block">
      <th scope="row" class="p-0 text-left font-normal max-md:block">
        <button
          type="button"
          id={"pair-#{@row.dom_id}"}
          phx-click="toggle_pair"
          phx-value-from={@row.from_stop_id}
          phx-value-to={@row.to_stop_id}
          aria-expanded={to_string(@expanded)}
          aria-controls={@region_id}
          class="flex min-h-12 w-full cursor-pointer items-center gap-2 px-4 py-2.5 text-left focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-focus sm:px-6"
        >
          <.icon
            name={if @expanded, do: "hero-chevron-down", else: "hero-chevron-right"}
            class="size-4 shrink-0 text-muted"
          />
          <span class="flex min-w-0 flex-wrap items-center gap-x-2 font-semibold text-strong">
            {@row.from_stop_name}
            <.icon name="hero-arrow-right" class="size-4 shrink-0 text-muted" />
            {@row.to_stop_name}
          </span>
        </button>
      </th>
      <.mode_cell label="On foot" row={@row} mode={:walking} />
      <.mode_cell label="Step-free" row={@row} mode={:wheelchair} />
    </tr>
    <tr :if={@expanded} class="max-md:block">
      <td colspan="3" class="border-t border-subtle bg-canvas px-5 py-4 max-md:block sm:px-6">
        <div
          id={@region_id}
          role="region"
          aria-label={"Route from #{@row.from_stop_name} to #{@row.to_stop_name}"}
          class="grid gap-x-10 gap-y-5 md:grid-cols-2 md:pl-6"
        >
          <.mode_panel label="On foot" mode={:walking} row={@row} trip={@trip} />
          <.mode_panel label="Step-free" mode={:wheelchair} row={@row} trip={@trip} />
        </div>
      </td>
    </tr>
    """
  end

  attr :label, :string, required: true
  attr :row, :map, required: true
  attr :mode, :atom, required: true

  defp mode_cell(assigns) do
    pair = mode_pair(assigns.row, assigns.mode)
    {tone, word, icon} = mode_badge(pair, assigns.mode, assigns.row)

    assigns =
      assigns
      |> assign(:tone, tone)
      |> assign(:word, word)
      |> assign(:icon, icon)
      |> assign(:metrics, pair_metrics(pair))

    ~H"""
    <td class="px-4 py-2.5 align-top max-md:flex max-md:items-start max-md:gap-3 max-md:py-1 max-md:pl-[52px]">
      <span class="w-[68px] shrink-0 pt-1 text-[13px] text-muted md:hidden">{@label}</span>
      <span class="block">
        <.tone_badge tone={@tone} icon={@icon} data-mode={to_string(@mode)}>{@word}</.tone_badge>
        <span :if={@metrics} class="mt-1 block text-[13px] tabular-nums text-muted">
          {@metrics}
        </span>
      </span>
    </td>
    """
  end

  attr :label, :string, required: true
  attr :row, :map, required: true
  attr :mode, :atom, required: true
  attr :trip, :any, default: nil

  # What one way of travelling did on this walk: the route when it works, the
  # reason when it does not.
  defp mode_panel(assigns) do
    pair = mode_pair(assigns.row, assigns.mode)

    assigns =
      assigns
      |> assign(:pair, pair)
      |> assign(:why, explanation(assigns.row, assigns.mode))

    ~H"""
    <div :if={@pair}>
      <h4 class="flex items-center gap-2 text-sm font-bold text-strong">
        <.mode_icon mode={@mode} class="size-[18px]" />{@label}
      </h4>
      <%= if reachable?(@pair) do %>
        <.route_detail trip={@trip} mode={@mode} />
      <% else %>
        <p class="mt-2 max-w-[56ch] break-words text-sm text-default">{@why}</p>
      <% end %>
    </div>
    """
  end

  attr :trip, :any, default: nil
  attr :mode, :atom, required: true

  # The run stores totals, not itineraries, so the route is planned when the
  # walk is opened.
  defp route_detail(%{trip: {:ok, trip}} = assigns) do
    assigns = assign(assigns, :result, Map.fetch!(trip, assigns.mode))

    ~H"""
    <%= case @result do %>
      <% {:ok, route} -> %>
        <p class="mt-1 text-[13px] tabular-nums text-muted">
          {route.duration_seconds}s · {format_meters(route.distance_meters)} · {step_label(
            route.step_count
          )}
        </p>
        <ol class="mt-3 grid gap-1.5">
          <li
            :for={{step, num} <- Enum.with_index(route.steps, 1)}
            class="flex gap-3 text-sm"
          >
            <span class="w-5 shrink-0 text-right tabular-nums text-muted">{num}</span>
            <span class="min-w-0 break-words">
              <span class="font-semibold text-strong">{direction_label(step.direction)}</span>
              <span :if={Values.present?(step.name)}>
                <span class="text-muted">·</span> {step.name}
              </span>
              <span
                :if={step.name_derived? and Values.present?(step.name)}
                class="text-[13px] text-muted"
              >
                (name inferred)
              </span>
              <span :if={step.distance_meters > 0} class="tabular-nums text-muted">
                · {format_meters(step.distance_meters)}
              </span>
            </span>
          </li>
        </ol>
      <% _ -> %>
        <p class="mt-2 text-sm text-muted">Route detail isn't available.</p>
    <% end %>
    """
  end

  defp route_detail(%{trip: {:error, _reason}} = assigns) do
    ~H"""
    <p class="mt-3 rounded-control bg-warning-bg px-3 py-2 text-sm text-warning-fg">
      Trip detail is unavailable. The station could not be loaded for planning. The result above
      is still correct.
    </p>
    """
  end

  defp route_detail(assigns) do
    ~H"""
    <p class="mt-3 text-sm text-muted" aria-live="polite">Planning trip…</p>
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
      aria-labelledby="graph-diagnostics-title"
      class="overflow-clip rounded-card border border-subtle bg-white"
    >
      <div class="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1 border-b border-subtle bg-canvas px-5 py-4 sm:px-6">
        <div>
          <h3 id="graph-diagnostics-title" class="text-lg font-bold text-strong">
            Station data problems
          </h3>
          <p class="mt-0.5 text-[13px] text-muted">
            Found while reading the station. Problems can stop a walk from being checked.
          </p>
        </div>
        <p
          id="graph-diagnostics-summary"
          class="text-sm font-semibold tabular-nums text-strong"
        >
          {@summary}
        </p>
      </div>

      <table class="w-full border-collapse text-sm max-md:block">
        <caption class="sr-only">
          Problems found in the station data
        </caption>
        <thead class="max-md:hidden">
          <tr>
            <.column_head class="w-[132px] sm:px-6">Type</.column_head>
            <.column_head>What's wrong</.column_head>
            <.column_head class="w-[28%] sm:px-6">Where</.column_head>
          </tr>
        </thead>
        <tbody id="graph-diagnostics-list" class="max-md:block">
          <tr :for={diag <- @visible} class="border-t border-subtle align-top max-md:block">
            <td class="px-4 py-3 max-md:block max-md:pb-1 sm:px-6">
              <%= if diag["severity"] == "error" do %>
                <.tone_badge tone="error">Problem</.tone_badge>
              <% else %>
                <.tone_badge tone="warning">Suggestion</.tone_badge>
              <% end %>
            </td>
            <th
              scope="row"
              class="break-words px-4 py-3 text-left font-normal text-default max-md:block max-md:py-1"
            >
              {diagnostic_text(diag)}
            </th>
            <td class="px-4 py-3 text-strong max-md:block max-md:pt-1 sm:px-6">
              <%= if Values.present?(diag["entity_id"]) do %>
                {entity_label(diag["entity_type"])}
                <span class="break-all font-mono text-[13px] text-muted">{diag["entity_id"]}</span>
              <% else %>
                <span class="text-muted">No ID</span>
              <% end %>
            </td>
          </tr>
        </tbody>
      </table>

      <div :if={@collapsible?} class="border-t border-subtle px-5 py-1 sm:px-6">
        <button
          type="button"
          id="graph-diagnostics-toggle"
          phx-click="toggle_diagnostics"
          aria-expanded={to_string(@expanded?)}
          aria-controls="graph-diagnostics-list"
          class="inline-flex min-h-11 items-center gap-1 text-sm font-semibold text-action hover:underline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
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

  attr :run, :map, required: true
  attr :envelope, :map, default: nil
  attr :stop_id, :string, default: nil

  defp reading_guide(assigns) do
    assigns = assign(assigns, :details, technical_details(assigns))

    ~H"""
    <section
      id="reachability-guide"
      aria-labelledby="reachability-guide-title"
      class="rounded-card bg-canvas p-5 sm:p-6"
    >
      <h3 id="reachability-guide-title" class="text-lg font-bold text-strong">
        How to read these results
      </h3>
      <div class="mt-4 grid gap-8 lg:grid-cols-2">
        <dl class="grid content-start gap-3 text-sm">
          <div class="grid gap-1 sm:grid-cols-[168px_1fr] sm:gap-4">
            <dt>
              <.tone_badge tone="success">Works</.tone_badge>
            </dt>
            <dd>A route exists. Select a walk to see the directions and how long it takes.</dd>
          </div>
          <div class="grid gap-1 sm:grid-cols-[168px_1fr] sm:gap-4">
            <dt>
              <.tone_badge tone="warning">No step-free route</.tone_badge>
            </dt>
            <dd>Riders can walk it, but only by using stairs or an escalator.</dd>
          </div>
          <div class="grid gap-1 sm:grid-cols-[168px_1fr] sm:gap-4">
            <dt>
              <.tone_badge tone="error">No route</.tone_badge>
            </dt>
            <dd>Nothing in your pathway data leads from the start to the end.</dd>
          </div>
          <div class="grid gap-1 sm:grid-cols-[168px_1fr] sm:gap-4">
            <dt>
              <.tone_badge tone="error" icon="hero-question-mark-circle">
                Couldn't check
              </.tone_badge>
            </dt>
            <dd>
              A place in the walk is missing from the check, usually because it has no location.
            </dd>
          </div>
        </dl>

        <div id="reachability-engine-note" class="text-sm">
          <p>
            <strong class="font-bold text-strong">On foot</strong>
            uses any pathway. <strong class="font-bold text-strong">Step-free</strong>
            takes out stairs and escalators, the way riders who use wheelchairs, push strollers or
            can't manage stairs would travel. A walk that works on foot but not step-free is an
            accessibility gap.
          </p>
          <p class="mt-3 text-muted">
            The check reads your pathway data, following the rules trip planners such as
            OpenTripPlanner use inside stations. It can't see elevator outages, ramp steepness or
            door width.
          </p>
          <details :if={@details != []} class="mt-2">
            <summary class="flex min-h-11 cursor-pointer items-center font-semibold text-action hover:underline">
              Technical details
            </summary>
            <dl class="grid grid-cols-[auto_1fr] gap-x-6 gap-y-1 pb-2 text-[13px]">
              <%= for {label, value} <- @details do %>
                <dt class="text-muted">{label}</dt>
                <dd class="break-all font-mono text-strong tabular-nums">{value}</dd>
              <% end %>
            </dl>
          </details>
        </div>
      </div>
    </section>
    """
  end

  # ── Verdict ────────────────────────────────────────────────────────────────

  defp run_outcome(%{"outcome" => outcome}) when outcome in ["passed", "warning", "failed"],
    do: outcome

  defp run_outcome(_envelope), do: nil

  defp verdict_edge("passed"), do: "border-success-line"
  defp verdict_edge("warning"), do: "border-warning-line"
  defp verdict_edge("failed"), do: "border-error-line"
  defp verdict_edge(_outcome), do: "border-subtle"

  defp verdict_copy("passed", _summary, diagnostics) do
    lede =
      "Riders can get from every entrance to every platform, back out, and between platforms, with or without stairs."

    lede =
      if diagnostics == [],
        do: lede,
        else:
          lede <>
            " The station data has #{count_label(length(diagnostics), "item", "items")} to review below."

    {"success", "Passed", "Every walk works, including step-free.", lede}
  end

  defp verdict_copy("warning", summary, _diagnostics) do
    {"warning", "Step-free gaps",
     "Riders can walk everywhere, but #{gap_phrase(summary.gap, "no step-free route")}.",
     "On foot, every walk works. The gaps are step-free only, so riders who use wheelchairs or strollers, or can't manage stairs, can't make these walks."}
  end

  defp verdict_copy("failed", summary, _diagnostics) do
    needs = summary.unchecked + summary.disconnected + summary.gap

    parts =
      [
        {summary.unchecked, "couldn't be checked"},
        {summary.disconnected, "has no route"},
        {summary.gap, "has no step-free route"}
      ]
      |> Enum.filter(fn {count, _label} -> count > 0 end)
      |> Enum.map(fn {count, label} -> "#{count} #{agree(count, label)}" end)

    headline =
      if needs == 0,
        do: "The check found problems.",
        else: "#{needs} of #{summary.total} walks need fixing: #{join_and(parts)}."

    {"error", "Needs fixing", headline,
     "Fix the walks marked below, then run the check again. A walk that couldn't be checked counts as a failure until it's fixed."}
  end

  defp verdict_copy(nil, summary, _diagnostics) do
    {"neutral", "Result", "#{count_label(summary.total, "walk", "walks")} tested.", nil}
  end

  defp gap_phrase(1, label), do: "1 walk has #{label}"
  defp gap_phrase(count, label), do: "#{count} walks have #{label}"

  # "1 has no route", "6 have no route"; "couldn't be checked" reads the same either way.
  defp agree(1, label), do: label
  defp agree(_count, "has " <> rest), do: "have " <> rest
  defp agree(_count, label), do: label

  defp join_and([one]), do: one
  defp join_and(parts), do: "#{Enum.join(Enum.drop(parts, -1), ", ")} and #{List.last(parts)}"

  defp data_caption([]), do: "No problems found"

  defp data_caption(diagnostics) do
    {problems, suggestions} = count_diagnostics(diagnostics)

    [{problems, "problem", "problems"}, {suggestions, "suggestion", "suggestions"}]
    |> Enum.filter(fn {count, _one, _many} -> count > 0 end)
    |> Enum.map_join(" · ", fn {count, one, many} -> count_label(count, one, many) end)
  end

  defp verdict_footer(nil), do: nil

  defp verdict_footer(envelope) do
    topology = envelope["topology"] || %{}

    [
      counted(topology["entrance_count"], "entrance", "entrances"),
      counted(topology["platform_count"], "platform", "platforms"),
      counted(topology["pathway_count"], "pathway", "pathways"),
      counted(topology["level_count"], "level", "levels"),
      duration_label(envelope["duration_ms"])
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      parts -> Enum.join(parts, " · ")
    end
  end

  defp counted(count, one, many) when is_integer(count), do: count_label(count, one, many)
  defp counted(_count, _one, _many), do: nil

  defp duration_label(ms) when is_integer(ms) and ms < 1000, do: "checked in #{ms} ms"
  defp duration_label(ms) when is_number(ms), do: "checked in #{Float.round(ms / 1000, 1)} s"
  defp duration_label(_ms), do: nil

  defp technical_details(%{run: run, envelope: envelope, stop_id: stop_id}) do
    envelope = envelope || %{}

    [
      {"Station ID", stop_id},
      {"Engine", envelope["engine"] || run.engine},
      {"Routing preferences", envelope["preferences"]},
      {"Result format",
       envelope["result_schema_version"] && "version #{envelope["result_schema_version"]}"},
      {"Run time", envelope["duration_ms"] && "#{envelope["duration_ms"]} ms"}
    ]
    |> Enum.filter(fn {_label, value} -> Values.present?(value) end)
  end

  # ── Section building ───────────────────────────────────────────────────────

  defp build_sections(%{"pairs" => pairs}) when is_list(pairs) do
    by_kind = Enum.group_by(pairs, & &1["kind"])

    # A pair's opposite direction sits in another section (entry <-> egress),
    # so it is looked up across every pair, not within one kind.
    walking_by_direction =
      for %{"mode" => "walking"} = pair <- pairs,
          into: %{},
          do: {{pair["from_stop_id"], pair["to_stop_id"]}, pair}

    @kinds
    |> Enum.map(fn {kind, title, subtitle} ->
      rows = merge_mode_rows(Map.get(by_kind, kind, []), walking_by_direction)

      %{
        kind: kind,
        title: title,
        subtitle: subtitle,
        rows: rows,
        stats: section_stats(rows)
      }
    end)
    |> Enum.reject(&(&1.rows == []))
  end

  defp build_sections(_envelope), do: []

  # One origin/destination, both modes, so accessibility reads as a comparison
  # rather than two rows a screen apart.
  defp merge_mode_rows(pairs, walking_by_direction) do
    pairs
    |> Enum.group_by(&{&1["from_stop_id"], &1["to_stop_id"]})
    |> Enum.map(fn {{from_stop_id, to_stop_id}, entries} ->
      reference = List.first(entries)

      row = %{
        key: pair_key(from_stop_id, to_stop_id),
        dom_id: dom_id(from_stop_id, to_stop_id),
        index: entries |> Enum.map(& &1["index"]) |> Enum.min(),
        from_stop_id: from_stop_id,
        from_stop_name: reference["from_stop_name"] || from_stop_id,
        to_stop_id: to_stop_id,
        to_stop_name: reference["to_stop_name"] || to_stop_id,
        walking: Enum.find(entries, &(&1["mode"] == "walking")),
        reverse_walking: Map.get(walking_by_direction, {to_stop_id, from_stop_id}),
        wheelchair: Enum.find(entries, &(&1["mode"] == "wheelchair"))
      }

      Map.put(row, :category, category(row))
    end)
    |> Enum.sort_by(& &1.index)
  end

  # What is wrong with a walk, most serious first: a place the router could not
  # find, then no route on foot, then no step-free route.
  defp category(%{walking: walking, wheelchair: wheelchair}) do
    cond do
      invalid?(walking) or invalid?(wheelchair) -> :unchecked
      unreachable?(walking) -> :disconnected
      unreachable?(wheelchair) -> :gap
      true -> :ok
    end
  end

  defp section_stats(rows) do
    %{
      total: length(rows),
      walking_reachable: Enum.count(rows, &reachable?(&1.walking)),
      wheelchair_reachable: Enum.count(rows, &reachable?(&1.wheelchair))
    }
  end

  defp summarize(sections) do
    rows = Enum.flat_map(sections, & &1.rows)
    categories = Enum.frequencies_by(rows, & &1.category)

    %{
      total: length(rows),
      foot_ok: Enum.count(rows, &reachable?(&1.walking)),
      chair_ok: Enum.count(rows, &reachable?(&1.wheelchair)),
      unchecked: Map.get(categories, :unchecked, 0),
      disconnected: Map.get(categories, :disconnected, 0),
      gap: Map.get(categories, :gap, 0)
    }
  end

  defp pair_key(from_stop_id, to_stop_id), do: "#{from_stop_id}|#{to_stop_id}"

  defp dom_id(from_stop_id, to_stop_id) do
    String.replace(pair_key(from_stop_id, to_stop_id), ~r/[^A-Za-z0-9_-]/, "-")
  end

  defp mode_pair(row, :walking), do: row.walking
  defp mode_pair(row, :wheelchair), do: row.wheelchair

  defp reachable?(%{"outcome" => "reachable"}), do: true
  defp reachable?(_pair), do: false

  defp unreachable?(%{"outcome" => "unreachable"}), do: true
  defp unreachable?(_pair), do: false

  defp invalid?(%{"outcome" => "invalid"}), do: true
  defp invalid?(_pair), do: false

  # ── Outcome presentation ───────────────────────────────────────────────────

  # Severity mirrors Scoring: a walking failure is an error, a step-free failure
  # is a warning, and a walk the router could not plan is an error too, so the
  # badge, the totals and the run's outcome agree. When a walk fails on foot its
  # step-free result is a consequence, not a second problem, so it goes muted.
  defp mode_badge(nil, _mode, _row), do: {"neutral", "Not tested", nil}
  defp mode_badge(%{"outcome" => "reachable"}, _mode, _row), do: {"success", "Works", nil}

  defp mode_badge(%{"outcome" => "invalid"}, mode, row) do
    {consequence_tone(mode, row, "error"), "Couldn't check", "hero-question-mark-circle"}
  end

  defp mode_badge(%{"outcome" => "unreachable"}, :walking, _row), do: {"error", "No route", nil}

  defp mode_badge(%{"outcome" => "unreachable"}, :wheelchair, row) do
    if walking_failed?(row),
      do: {"muted", "No route", nil},
      else: {"warning", "No step-free route", nil}
  end

  defp mode_badge(_pair, _mode, _row), do: {"neutral", "Unknown", nil}

  defp consequence_tone(:wheelchair, row, tone),
    do: if(walking_failed?(row), do: "muted", else: tone)

  defp consequence_tone(_mode, _row, tone), do: tone

  defp walking_failed?(%{walking: nil}), do: false
  defp walking_failed?(%{walking: walking}), do: not reachable?(walking)

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

  # Both modes are planned, so each explains the other: a walk that works on foot
  # but not step-free is an accessibility gap, not a hole in the pathway graph.
  defp explanation(row, :walking) do
    cond do
      is_nil(row.walking) or reachable?(row.walking) ->
        nil

      invalid?(row.walking) ->
        invalid_explanation(row, row.walking)

      reachable?(row.reverse_walking) ->
        "Riders can travel the other way, from #{row.to_stop_name} to #{row.from_stop_name}, but not in this direction. Check whether a pathway on the route is one-way (is_bidirectional = 0) and should allow travel in both directions."

      unreachable?(row.reverse_walking) ->
        "No route connects #{row.from_stop_name} and #{row.to_stop_name} in either direction of travel. Look for a missing pathway record between them."

      true ->
        "No route leads from #{row.from_stop_name} to #{row.to_stop_name}. Check that a pathway connects them and that riders can use it in this direction."
    end
  end

  defp explanation(row, :wheelchair) do
    cond do
      is_nil(row.wheelchair) or reachable?(row.wheelchair) ->
        nil

      invalid?(row.wheelchair) ->
        invalid_explanation(row, row.wheelchair)

      reachable?(row.walking) ->
        "Riders can walk this, but every route uses stairs or an escalator. Step-free planning takes both out, so no route is left. Add an elevator, ramp or level walkway between these places."

      is_nil(row.walking) ->
        "No step-free route was found for this walk."

      true ->
        "There's no route in either mode. See the on foot result."
    end
  end

  defp invalid_explanation(_row, %{"reason" => "same_origin_and_destination"}),
    do: "The start and the end are the same place, so there's no walk to check."

  defp invalid_explanation(row, %{"reason" => "unknown_element: " <> element_id}) do
    "#{element_name(row, element_id)} isn't part of the check because it has no location. Give it coordinates, or place it in a station that has them."
  end

  defp invalid_explanation(_row, _pair), do: "This walk couldn't be checked."

  defp element_name(%{from_stop_id: id, from_stop_name: name}, id), do: name
  defp element_name(%{to_stop_id: id, to_stop_name: name}, id), do: name
  defp element_name(_row, element_id), do: element_id

  # ── Formatting ─────────────────────────────────────────────────────────────

  defp direction_label(:depart), do: "Start"
  defp direction_label(:continue), do: "Continue"
  defp direction_label(:left), do: "Turn left"
  defp direction_label(:right), do: "Turn right"
  defp direction_label(:hard_left), do: "Turn sharply left"
  defp direction_label(:hard_right), do: "Turn sharply right"
  defp direction_label(:slightly_left), do: "Bear left"
  defp direction_label(:slightly_right), do: "Bear right"
  defp direction_label(:follow_signs), do: "Follow signs"
  defp direction_label(:elevator), do: "Take the elevator"
  defp direction_label(other), do: other |> to_string() |> String.replace("_", " ")

  defp step_label(1), do: "1 step"
  defp step_label(count), do: "#{count} steps"

  defp format_meters(nil), do: "—"
  defp format_meters(meters) when is_integer(meters), do: "#{meters}m"
  defp format_meters(meters) when is_float(meters), do: "#{Float.round(meters, 1)}m"
  defp format_meters(meters), do: "#{meters}m"

  # The router's own message covers a code this page has no sentence for.
  defp diagnostic_text(%{"code" => code} = diagnostic) do
    Map.get(@diagnostic_text, code) || diagnostic["message"]
  end

  defp diagnostic_text(diagnostic), do: diagnostic["message"]

  defp entity_label("stop"), do: "Stop"
  defp entity_label("pathway"), do: "Pathway"
  defp entity_label(nil), do: "Item"
  defp entity_label(type), do: type |> to_string() |> String.capitalize()

  # An error is a problem that can stop a walk being checked; anything else is a
  # suggestion.
  defp count_diagnostics(diagnostics) do
    problems = Enum.count(diagnostics, &(&1["severity"] == "error"))
    {problems, length(diagnostics) - problems}
  end

  defp diagnostics_summary(diagnostics), do: data_caption(diagnostics)

  defp station_stop_id(%{result_json: result_json}) when is_map(result_json) do
    get_in(result_json, ["metadata", "station_stop_id"])
  end

  defp station_stop_id(_run), do: nil

  defp fetch_station(_organization_id, _gtfs_version_id, nil), do: nil

  defp fetch_station(organization_id, gtfs_version_id, stop_id) do
    Gtfs.get_stop_by_stop_id(organization_id, gtfs_version_id, stop_id)
  end

  defp run_subtitle(run, version) do
    case run.status do
      "completed" ->
        "Checked #{format_time(run.completed_at || run.inserted_at)} · #{version.name}"

      "failed" ->
        "Started #{format_time(run.started_at || run.inserted_at)} · didn't finish"

      _ ->
        "Started #{format_time(run.started_at || run.inserted_at)} · in progress"
    end
  end
end
