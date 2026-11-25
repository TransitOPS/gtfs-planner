defmodule GtfsPlannerWeb.Gtfs.StationAccessibilityComponents do
  @moduledoc """
  Function components for the read-only Station Accessibility validation page.

  Renders both the small-station `Network` surface (`Rider routes` and
  `Validation` cross-level SVG schematics, matrix, confidence summary, and
  issues) and the large-station `Impact & routes` surface (4-tile KPI strip,
  on-demand collapsed route stepper, impact-ranked issues, grouped access matrix
  with inline pair drill-down, and 3-column elevator dependency table).

  Strictly read-only: every remediation action links either to Floorplans
  (`?level=&edit_pathway_id=`) or to Station Report (`?edit_stop_id=`).
  """
  use Phoenix.Component
  use GtfsPlannerWeb, :verified_routes

  import GtfsPlannerWeb.CoreComponents, only: [button: 1, icon: 1]
  import GtfsPlannerWeb.PlannerComponents, only: [back_link: 1, first_use: 1, message: 1]
  import GtfsPlannerWeb.ResultComponents, only: [tone_badge: 1]

  alias GtfsPlanner.Gtfs.StationReport2.Helpers
  alias GtfsPlannerWeb.Components.DiagramPalette

  @highlight_specs [
    %{
      key: :barriers,
      id: "highlight-barriers",
      param: "barriers",
      label: "Barriers",
      dot_color: "#B91C1C"
    },
    %{
      key: :unknown_data,
      id: "highlight-unknown-data",
      param: "unknown_data",
      label: "Unknown data",
      dot_color: "#7C3AED"
    },
    %{
      key: :near_threshold,
      id: "highlight-near-threshold",
      param: "near_threshold",
      label: "Near threshold",
      dot_color: "#8A5A0E"
    },
    %{
      key: :single_elevator,
      id: "highlight-single-elevator",
      param: "single_elevator",
      label: "Single-elevator routes",
      dot_color: "#C81870"
    }
  ]

  # -- Page header & view switcher -------------------------------------------

  attr :gtfs_version_id, :any, required: true
  attr :stop_id, :string, required: true
  attr :analysis, :map, default: nil
  attr :snapshot, :map, default: nil
  attr :derived_state, :atom, required: true
  attr :active_view, :atom, required: true

  def page_header(assigns) do
    ~H"""
    <div>
      <.back_link
        id="accessibility-back-to-report"
        navigate={~p"/gtfs/#{@gtfs_version_id}/stops/#{@stop_id}/report"}
      >
        Station report
      </.back_link>

      <div class="flex flex-wrap items-start justify-between gap-4 pb-5 pt-1">
        <div class="min-w-0">
          <h2
            id="accessibility-heading"
            class="font-display text-[26px] font-semibold leading-tight tracking-[-0.025em] text-strong sm:text-[30px]"
          >
            Step-free accessibility
          </h2>
          <p class="mt-1.5 flex flex-wrap items-center gap-x-2 gap-y-0.5 text-sm text-muted">
            <span>Routes checked in both directions</span>
            <span :if={@analysis && @snapshot} aria-hidden="true">·</span>
            <span :if={@analysis && @snapshot} class="tabular-nums">
              {header_counts(@snapshot, @analysis)}
            </span>
          </p>
        </div>

        <div
          :if={@derived_state == :ready && @analysis && @analysis.network_available?}
          id="accessibility-view-switcher"
          role="group"
          aria-label="Accessibility view"
          class="inline-flex rounded-control border border-subtle bg-canvas p-1"
        >
          <button
            id="view-switch-network"
            type="button"
            phx-click="switch_view"
            phx-value-view="network"
            aria-pressed={to_string(@active_view == :network)}
            class={[
              "inline-flex min-h-11 items-center gap-1.5 rounded-[5px] px-3.5 text-sm font-semibold transition-colors",
              "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus",
              if(@active_view == :network,
                do: "bg-white text-strong shadow-xs",
                else: "text-muted hover:text-strong"
              )
            ]}
          >
            <.icon name="hero-squares-2x2" class="size-4 shrink-0" /> Network
          </button>
          <button
            id="view-switch-impact"
            type="button"
            phx-click="switch_view"
            phx-value-view="impact"
            aria-pressed={to_string(@active_view == :impact)}
            class={[
              "inline-flex min-h-11 items-center gap-1.5 rounded-[5px] px-3.5 text-sm font-semibold transition-colors",
              "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus",
              if(@active_view == :impact,
                do: "bg-white text-strong shadow-xs",
                else: "text-muted hover:text-strong"
              )
            ]}
          >
            <.icon name="hero-queue-list" class="size-4 shrink-0" /> Impact &amp; routes
          </button>
        </div>
      </div>
    </div>
    """
  end

  # -- Cross-station incomplete banner (CR-C3) -------------------------------

  attr :analysis, :map, required: true

  def incomplete_notice(assigns) do
    cross_ids = cross_station_pathway_ids(assigns.analysis)
    assigns = assign(assigns, :cross_ids, cross_ids)

    ~H"""
    <.message
      :if={@analysis.completeness == :incomplete && @cross_ids != []}
      id="accessibility-incomplete-banner"
      kind="warning"
      role="status"
      title="Cross-station pathways detected"
      class="mb-6"
    >
      <p>
        {length(@cross_ids)} {pluralize(length(@cross_ids), "pathway connects", "pathways connect")} to
        stops outside this station ({Enum.take(@cross_ids, 5) |> Enum.join(", ")}{if(
          length(@cross_ids) > 5,
          do: " +#{length(@cross_ids) - 5} more",
          else: ""
        )}). Step-free reachability and impact counts reflect intra-station pathways only and may be
        incomplete.
      </p>
    </.message>
    """
  end

  # -- Non-ready states (loading, error, empty_topology, no_step_free) -------

  def loading_state(assigns) do
    ~H"""
    <div id="accessibility-loading" role="status" class="space-y-4">
      <p class="text-sm text-muted">Loading step-free accessibility analysis…</p>
      <div aria-hidden="true" class="space-y-6 motion-safe:animate-pulse">
        <div class="grid grid-cols-1 gap-3 sm:grid-cols-2 xl:grid-cols-4">
          <div
            :for={_i <- 1..4}
            class="space-y-2 rounded-card border border-subtle bg-white p-5"
          >
            <div class="h-7 w-20 rounded-control bg-navy-100"></div>
            <div class="h-4 w-40 max-w-full rounded-control bg-navy-100"></div>
          </div>
        </div>
        <div class="h-72 rounded-card border border-subtle bg-white p-6">
          <div class="h-5 w-48 rounded-control bg-navy-100"></div>
          <div class="mt-4 h-48 rounded-control bg-canvas"></div>
        </div>
      </div>
    </div>
    """
  end

  attr :refreshing?, :boolean, default: false

  def refreshing_banner(assigns) do
    ~H"""
    <div
      :if={@refreshing?}
      id="accessibility-refreshing"
      role="status"
      class="mb-4 flex items-center gap-3 rounded-control bg-soft px-4 py-3 text-sm font-bold text-cyan-800"
    >
      <.icon name="hero-arrow-path" class="size-5 shrink-0 text-cyan-700 motion-safe:animate-spin" />
      <span>Refreshing step-free accessibility analysis…</span>
    </div>
    """
  end

  def error_state(assigns) do
    ~H"""
    <.message
      id="accessibility-error"
      kind="error"
      title="Accessibility analysis could not load"
    >
      Nothing was changed. Retry to build the station accessibility analysis.
      <:action>
        <.button id="accessibility-retry" type="button" phx-click="retry_load" class="min-h-11">
          Retry
        </.button>
      </:action>
    </.message>
    """
  end

  attr :gtfs_version_id, :any, required: true
  attr :stop_id, :string, required: true
  attr :analysis, :map, required: true

  def empty_topology_state(assigns) do
    missing =
      []
      |> maybe_append(assigns.analysis.entrances == [], "entrances")
      |> maybe_append(assigns.analysis.platforms == [], "platforms")
      |> maybe_append(assigns.analysis.edges == [], "pathways")

    assigns = assign(assigns, :missing_text, Enum.join(missing, ", "))

    ~H"""
    <.first_use
      id="accessibility-empty-topology"
      title="Add station topology to check step-free access"
      icon="hero-map"
    >
      This station is missing {@missing_text}. Add entrances, platforms, and connecting pathways in
      Floorplans before checking step-free round trips.
      <:action>
        <.button
          id="empty-open-floorplans"
          navigate={~p"/gtfs/#{@gtfs_version_id}/stops/#{@stop_id}/diagram"}
          class="min-h-11"
        >
          Open Floorplans
        </.button>
      </:action>
    </.first_use>
    """
  end

  attr :gtfs_version_id, :any, required: true
  attr :stop_id, :string, required: true
  attr :analysis, :map, required: true
  attr :active_view, :atom, required: true
  attr :active_tab, :atom, required: true
  attr :highlights, :map, required: true
  attr :schematic_layout, :map, default: nil
  attr :edges_by_pathway_id, :map, required: true
  attr :expanded_issue_ids, :any, required: true

  def no_step_free_state(assigns) do
    showing_barriers? =
      assigns.analysis.network_available? and
        assigns.active_view == :network and
        assigns.active_tab == :validation

    assigns = assign(assigns, :showing_barriers?, showing_barriers?)

    ~H"""
    <div id="accessibility-no-step-free" class="space-y-6">
      <.message
        id="no-step-free-summary"
        kind="warning"
        title="No entrance has a step-free round-trip route"
      >
        <p>
          Checked {length(@analysis.entrances)} {pluralize(
            length(@analysis.entrances),
            "entrance",
            "entrances"
          )} and {length(@analysis.platforms)} {pluralize(
            length(@analysis.platforms),
            "platform",
            "platforms"
          )} in both directions. Stairs, escalators, missing connections, or measured ADA barriers
          currently block step-free access.
        </p>
        <:action :if={@analysis.network_available? && !(@showing_barriers? && @highlights.barriers)}>
          <.button
            id="no-step-free-inspect-barriers"
            type="button"
            variant="secondary"
            phx-click="inspect_barriers"
            class="min-h-11 bg-white"
          >
            Inspect barriers in Validation
          </.button>
        </:action>
      </.message>

      <%= if @showing_barriers? && @schematic_layout do %>
        <.network_view
          gtfs_version_id={@gtfs_version_id}
          stop_id={@stop_id}
          analysis={@analysis}
          active_tab={@active_tab}
          highlights={@highlights}
          schematic_layout={@schematic_layout}
          edges_by_pathway_id={@edges_by_pathway_id}
          expanded_issue_ids={@expanded_issue_ids}
          no_step_free_mode?={true}
        />
      <% else %>
        <div class="grid grid-cols-1 gap-6 xl:grid-cols-[minmax(0,1fr)_24rem]">
          <section
            id="no-step-free-rider-placeholder"
            class="rounded-card border border-subtle bg-white p-6"
          >
            <h3 class="text-base font-bold text-strong">Rider routes unavailable</h3>
            <p class="mt-2 text-sm text-muted">
              Rider routes only show entrances with a barrier-free step-free round trip. Review the
              barriers and flag mismatches below, or open Floorplans to add an elevator or fix
              measured limits.
            </p>
            <div class="mt-4 flex flex-wrap gap-3">
              <.button
                id="no-step-free-open-floorplans"
                navigate={~p"/gtfs/#{@gtfs_version_id}/stops/#{@stop_id}/diagram"}
                variant="secondary"
                class="min-h-11"
              >
                Open Floorplans
              </.button>
            </div>
          </section>

          <.issues_card
            id="no-step-free-issues-card"
            title="Issues to review"
            issues={@analysis.issues}
            gtfs_version_id={@gtfs_version_id}
            stop_id={@stop_id}
            edges_by_pathway_id={@edges_by_pathway_id}
            expanded_issue_ids={@expanded_issue_ids}
          />
        </div>
      <% end %>
    </div>
    """
  end

  # -- Small-station Network view (Rider routes & Validation) ----------------

  attr :gtfs_version_id, :any, required: true
  attr :stop_id, :string, required: true
  attr :analysis, :map, required: true
  attr :active_tab, :atom, required: true
  attr :highlights, :map, required: true
  attr :schematic_layout, :map, required: true
  attr :edges_by_pathway_id, :map, required: true
  attr :expanded_issue_ids, :any, required: true
  attr :no_step_free_mode?, :boolean, default: false

  def network_view(assigns) do
    assigns =
      assigns
      |> assign(:highlight_specs, @highlight_specs)
      |> assign(:highlight_counts, compute_highlight_counts(assigns.analysis))

    ~H"""
    <div id="accessibility-network-view" class="space-y-5">
      <div class="flex flex-wrap items-center justify-between gap-4">
        <div
          id="network-tab-bar"
          role="tablist"
          aria-label="Network view mode"
          class="inline-flex rounded-control border border-subtle bg-canvas p-1"
        >
          <button
            id="tab-rider-routes"
            type="button"
            role="tab"
            aria-selected={to_string(@active_tab == :rider_routes)}
            phx-click="switch_tab"
            phx-value-tab="rider_routes"
            class={[
              "inline-flex min-h-11 items-center rounded-[5px] px-4 text-sm font-semibold transition-colors",
              "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus",
              if(@active_tab == :rider_routes,
                do: "bg-white text-strong shadow-xs",
                else: "text-muted hover:text-strong"
              )
            ]}
          >
            Rider routes
          </button>
          <button
            id="tab-validation"
            type="button"
            role="tab"
            aria-selected={to_string(@active_tab == :validation)}
            phx-click="switch_tab"
            phx-value-tab="validation"
            class={[
              "inline-flex min-h-11 items-center rounded-[5px] px-4 text-sm font-semibold transition-colors",
              "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus",
              if(@active_tab == :validation,
                do: "bg-white text-strong shadow-xs",
                else: "text-muted hover:text-strong"
              )
            ]}
          >
            Validation
          </button>
        </div>

        <fieldset
          :if={@active_tab == :validation}
          id="validation-highlight-filters"
          class="flex flex-wrap items-center gap-x-4 gap-y-2"
        >
          <legend class="sr-only">Highlight schematic layers</legend>
          <span class="text-sm font-semibold text-muted" aria-hidden="true">Highlight:</span>
          <label
            :for={spec <- @highlight_specs}
            class="inline-flex min-h-11 cursor-pointer items-center gap-2 rounded-control border border-subtle bg-white px-3 text-sm font-medium text-default hover:bg-canvas has-[:focus-visible]:outline-2 has-[:focus-visible]:outline-offset-2 has-[:focus-visible]:outline-focus"
          >
            <input
              id={spec.id}
              type="checkbox"
              checked={Map.get(@highlights, spec.key, false)}
              phx-click="toggle_highlight"
              phx-value-key={spec.param}
              class="size-4 rounded accent-action"
            />
            <span
              class="inline-block size-2.5 shrink-0 rounded-full"
              style={"background-color: #{spec.dot_color};"}
              aria-hidden="true"
            >
            </span>
            <span>{spec.label}</span>
            <span class="rounded-badge bg-canvas px-1.5 py-0.5 text-xs font-semibold text-muted tabular-nums">
              {Map.get(@highlight_counts, spec.key, 0)}
            </span>
          </label>
        </fieldset>
      </div>

      <div class="grid grid-cols-1 items-start gap-6 xl:grid-cols-[minmax(0,1fr)_23rem]">
        <.schematic_card
          layout={@schematic_layout}
          active_tab={@active_tab}
          highlights={@highlights}
          gtfs_version_id={@gtfs_version_id}
          stop_id={@stop_id}
          no_step_free_mode?={@no_step_free_mode?}
        />

        <div class="min-w-0 space-y-5">
          <%= if @active_tab == :rider_routes do %>
            <.network_access_matrix_card analysis={@analysis} />
            <.network_elevator_dependency_card
              analysis={@analysis}
              gtfs_version_id={@gtfs_version_id}
              stop_id={@stop_id}
              edges_by_pathway_id={@edges_by_pathway_id}
            />
          <% else %>
            <.station_confidence_card analysis={@analysis} />
            <.issues_card
              id="validation-issues-card"
              title="Issues to review"
              issues={@analysis.issues}
              gtfs_version_id={@gtfs_version_id}
              stop_id={@stop_id}
              edges_by_pathway_id={@edges_by_pathway_id}
              expanded_issue_ids={@expanded_issue_ids}
            />
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  # -- Cross-level SVG swimlane schematic ------------------------------------

  attr :layout, :map, required: true
  attr :active_tab, :atom, required: true
  attr :highlights, :map, required: true
  attr :gtfs_version_id, :any, required: true
  attr :stop_id, :string, required: true
  attr :no_step_free_mode?, :boolean, default: false

  defp schematic_card(assigns) do
    title =
      if assigns.active_tab == :validation,
        do: "Barriers and data gaps",
        else: "Step-free network"

    helper =
      cond do
        assigns.active_tab == :rider_routes ->
          "Step-free routes only. Inaccessible entrances and barriers are hidden."

        assigns.highlights.barriers ->
          "Showing step-free pathways alongside measured barriers and stairs or escalators."

        true ->
          "Inaccessible paths hidden. Check Barriers to show them."
      end

    any_highlight? =
      assigns.active_tab == :validation and Enum.any?(Map.values(assigns.highlights))

    assigns =
      assigns
      |> assign(:title, title)
      |> assign(:helper, helper)
      |> assign(:any_highlight?, any_highlight?)

    ~H"""
    <section
      id="accessibility-schematic-card"
      aria-labelledby="accessibility-schematic-title"
      class="min-w-0 overflow-hidden rounded-card border border-subtle bg-white"
    >
      <div class="flex flex-wrap items-baseline justify-between gap-2 border-b border-subtle bg-canvas px-5 py-4">
        <h3 id="accessibility-schematic-title" class="text-base font-bold text-strong">
          {@title}
        </h3>
        <p class="text-[13px] text-muted">{@helper}</p>
      </div>

      <%= if @layout.lanes == [] do %>
        <div class="p-8 text-center text-sm text-muted">
          <%= if @no_step_free_mode? do %>
            No step-free pathways are visible. Enable the Barriers layer in Validation to inspect
            blocked or stairs-only connections.
          <% else %>
            No visible stops or pathways in this view.
          <% end %>
        </div>
      <% else %>
        <p class="border-b border-subtle bg-canvas/50 px-4 py-1.5 text-xs font-medium text-muted sm:hidden">
          Swipe horizontally to view the full diagram.
        </p>
        <div
          id="accessibility-schematic-scroll"
          tabindex="0"
          aria-label="Scrollable cross-level accessibility schematic"
          class="w-full max-w-full overflow-x-auto bg-white p-4 focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-focus"
        >
          <svg
            id="accessibility-schematic-svg"
            viewBox={@layout.view_box}
            width={@layout.width}
            height={@layout.height}
            role="img"
            aria-label="Cross-level station accessibility schematic"
            class="mx-auto block h-auto max-w-full min-w-[640px]"
            style={DiagramPalette.css_custom_properties()}
          >
            <%!-- Horizontal level swimlane bands --%>
            <g :for={lane <- @layout.lanes} id={"schematic-lane-#{dom_safe(lane.id)}"}>
              <rect
                x="12"
                y={lane.y}
                width={max(@layout.width - 24, 100)}
                height={lane.height}
                rx="8"
                fill="#f4f6f9"
                stroke="#d6dae8"
                stroke-width="1"
              />
              <text
                x="24"
                y={lane.y + 22}
                fill="#3d4758"
                font-size="11"
                font-weight="700"
                letter-spacing="0.06em"
              >
                <title>{lane.level_name || ""}</title>
                {(lane.level_name || "") |> String.upcase() |> truncate_label(14)}
              </text>

              <%= if lane.split_fare_zones? do %>
                <%= for {sub, idx} <- Enum.with_index(lane.sub_bands) do %>
                  <line
                    :if={idx > 0}
                    x1="136"
                    y1={sub.y}
                    x2={max(@layout.width - 20, 140)}
                    y2={sub.y}
                    stroke="#b5c0cc"
                    stroke-width="1"
                    stroke-dasharray="4 4"
                  />
                  <text
                    :if={sub.label}
                    x={max(@layout.width - 24, 150)}
                    y={sub.y + 18}
                    text-anchor="end"
                    fill="#3d4758"
                    font-size="11"
                    font-weight="600"
                  >
                    {sub.label}
                  </text>
                <% end %>
              <% end %>
            </g>

            <%!-- Layer 1: Pathway edge strokes & hit targets --%>
            <g :for={edge <- @layout.edges}>
              <%= if edge.pathway_uuid do %>
                <a
                  id={"schematic-edge-#{dom_safe(edge.pathway_id)}"}
                  href={
                    pathway_diagram_href(@gtfs_version_id, @stop_id, edge.level_id, edge.pathway_uuid)
                  }
                  tabindex="0"
                  aria-label={edge_aria_label(edge)}
                  class="cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
                >
                  <.schematic_edge_graphics edge={edge} />
                </a>
              <% else %>
                <g id={"schematic-edge-#{dom_safe(edge.pathway_id)}"}>
                  <.schematic_edge_graphics edge={edge} />
                </g>
              <% end %>
            </g>

            <%!-- Layer 2: Stop nodes --%>
            <g :for={node <- @layout.nodes}>
              <%= if node.stop_uuid do %>
                <a
                  id={"schematic-node-#{dom_safe(node.stop_id)}"}
                  href={stop_report_href(@gtfs_version_id, @stop_id, node.stop_uuid)}
                  tabindex="0"
                  aria-label={node_aria_label(node)}
                  class="cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
                >
                  <.schematic_node_graphics node={node} />
                </a>
              <% else %>
                <g id={"schematic-node-#{dom_safe(node.stop_id)}"}>
                  <.schematic_node_graphics node={node} />
                </g>
              <% end %>
            </g>

            <%!-- Layer 3: Edge callout pills rendered above nodes & lines --%>
            <g pointer-events="none">
              <.schematic_edge_callout :for={edge <- @layout.edges} edge={edge} />
            </g>
          </svg>
        </div>
      <% end %>

      <div class="flex flex-wrap items-center justify-between gap-x-5 gap-y-2 border-t border-subtle bg-canvas/60 px-5 py-3 text-[13px] text-muted">
        <div class="flex flex-wrap items-center gap-x-5 gap-y-2">
          <span class="inline-flex items-center gap-2">
            <span class="inline-block h-[3px] w-7 rounded-full bg-[#0F766E]" aria-hidden="true">
            </span>
            <span>Confirmed step-free</span>
          </span>
          <span class="inline-flex items-center gap-2">
            <span
              class="inline-block h-0 w-7 border-b-[3px] border-dotted border-unverified-line"
              aria-hidden="true"
            >
            </span>
            <span>Unverified (missing data)</span>
          </span>
          <span
            :if={@active_tab == :validation && @highlights.near_threshold}
            class="inline-flex items-center gap-2"
          >
            <span
              class="inline-block h-[4px] w-7 rounded-full border border-[#8A5A0E] bg-[#fbbf5a]/60"
              aria-hidden="true"
            >
            </span>
            <span>Near threshold</span>
          </span>
          <span
            :if={@active_tab == :validation && @highlights.single_elevator}
            class="inline-flex items-center gap-2"
          >
            <span class="inline-block h-[4px] w-7 rounded-full bg-[#C81870]" aria-hidden="true">
            </span>
            <span>Single elevator</span>
          </span>
          <span
            :if={@active_tab == :validation && @highlights.barriers}
            class="inline-flex items-center gap-2"
          >
            <span
              class="inline-block h-0 w-7 border-b-[3px] border-dashed border-[#B91C1C]"
              aria-hidden="true"
            >
            </span>
            <span>Barrier</span>
          </span>
          <span :if={@any_highlight?} class="inline-flex items-center gap-2">
            <span class="inline-block h-[2px] w-7 rounded-full bg-[#0F766E]/30" aria-hidden="true">
            </span>
            <span>Other pathways (dimmed)</span>
          </span>
        </div>
        <span class="text-xs text-muted">
          Select a pathway to edit in Floorplans, or a stop to edit in Station Report.
        </span>
      </div>
    </section>
    """
  end

  attr :edge, :map, required: true

  defp schematic_edge_graphics(assigns) do
    stroke = edge_stroke_color(assigns.edge)
    width = edge_stroke_width(assigns.edge)
    dasharray = edge_stroke_dasharray(assigns.edge)
    opacity = if(assigns.edge.dimmed?, do: "0.28", else: "1")
    near_halo? = :near_threshold in assigns.edge.active_highlights

    assigns =
      assigns
      |> assign(:stroke, stroke)
      |> assign(:width, width)
      |> assign(:dasharray, dasharray)
      |> assign(:opacity, opacity)
      |> assign(:near_halo?, near_halo?)

    ~H"""
    <title>{edge_aria_label(@edge)}</title>
    <path d={@edge.path_d} fill="none" stroke="transparent" stroke-width="16" />
    <path
      :if={@near_halo?}
      d={@edge.path_d}
      fill="none"
      stroke="#fbbf5a"
      stroke-opacity="0.55"
      stroke-width="10"
      stroke-linecap="round"
    />
    <path
      d={@edge.path_d}
      fill="none"
      stroke={@stroke}
      stroke-width={@width}
      stroke-dasharray={@dasharray}
      stroke-linecap="round"
      opacity={@opacity}
    />
    """
  end

  attr :edge, :map, required: true

  defp schematic_edge_callout(assigns) do
    callout = assigns.edge.callout
    show_callout? = is_binary(callout) and callout != "" and not assigns.edge.dimmed?
    pill_w = if(show_callout?, do: max(String.length(callout) * 6.4 + 16.0, 52.0), else: 0.0)
    stroke = edge_stroke_color(assigns.edge)

    assigns =
      assigns
      |> assign(:show_callout?, show_callout?)
      |> assign(:pill_w, Float.round(pill_w, 1))
      |> assign(:stroke, stroke)

    ~H"""
    <g :if={@show_callout?}>
      <rect
        x={Float.round(@edge.label_x - @pill_w / 2.0, 1)}
        y={Float.round(@edge.label_y - 10.0, 1)}
        width={@pill_w}
        height="20"
        rx="4"
        fill="#ffffff"
        stroke={@stroke}
        stroke-width="1.2"
      />
      <text
        x={@edge.label_x}
        y={Float.round(@edge.label_y + 4.0, 1)}
        text-anchor="middle"
        fill={callout_text_color(@edge)}
        font-size="11"
        font-weight="600"
      >
        {@edge.callout}
      </text>
    </g>
    """
  end

  attr :node, :map, required: true

  defp schematic_node_graphics(assigns) do
    left = Float.round(assigns.node.x - assigns.node.width / 2.0, 1)
    top = Float.round(assigns.node.y - assigns.node.height / 2.0, 1)
    {fill, stroke, text_fill, rx} = node_visual_tokens(assigns.node)

    assigns =
      assigns
      |> assign(:left, left)
      |> assign(:top, top)
      |> assign(:fill, fill)
      |> assign(:stroke, stroke)
      |> assign(:text_fill, text_fill)
      |> assign(:rx, rx)

    ~H"""
    <title>{@node.name} ({@node.stop_id})</title>
    <rect
      x={@left}
      y={@top}
      width={@node.width}
      height={@node.height}
      rx={@rx}
      fill={@fill}
      stroke={@stroke}
      stroke-width="1.5"
    />
    <text
      x={@node.x}
      y={Float.round(@node.y + 4.0, 1)}
      text-anchor="middle"
      fill={@text_fill}
      font-size="12"
      font-weight="600"
    >
      {truncate_label(@node.name, 20)}
    </text>
    """
  end

  # -- Network right-column cards (Rider routes) -----------------------------

  attr :analysis, :map, required: true

  defp network_access_matrix_card(assigns) do
    pair_by_key =
      Map.new(assigns.analysis.pairs, &{{&1.entrance_stop_id, &1.platform_stop_id}, &1})

    assigns = assign(assigns, :pair_by_key, pair_by_key)

    ~H"""
    <section
      id="network-access-matrix-card"
      aria-labelledby="network-access-matrix-title"
      class="min-w-0 overflow-hidden rounded-card border border-subtle bg-white"
    >
      <div class="border-b border-subtle bg-canvas px-5 py-4">
        <h3 id="network-access-matrix-title" class="text-base font-bold text-strong">
          Step-free access
        </h3>
        <p class="mt-0.5 text-[13px] text-muted">
          Checked in both directions. Select a pair to inspect its route.
        </p>
      </div>

      <div
        tabindex="0"
        aria-label="Step-free entrance to platform access matrix"
        class="overflow-x-auto p-4 focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-focus"
      >
        <table
          id="network-access-matrix-table"
          class="w-full border-separate border-spacing-1.5 text-left text-sm"
        >
          <thead>
            <tr>
              <th
                scope="col"
                class="px-2 py-1 text-xs font-semibold uppercase tracking-wide text-muted"
              >
                Entrance
              </th>
              <th
                :for={platform <- @analysis.platforms}
                scope="col"
                class="px-2 py-1 text-center text-xs font-semibold text-strong"
              >
                {platform.name}
              </th>
            </tr>
          </thead>
          <tbody>
            <tr :for={entrance <- @analysis.step_free_entrances}>
              <th scope="row" class="px-2 py-1.5 text-sm font-semibold text-strong">
                {entrance.name}
              </th>
              <td :for={platform <- @analysis.platforms} class="p-0.5 text-center">
                <% pair = Map.get(@pair_by_key, {entrance.stop_id, platform.stop_id}) %>
                <button
                  :if={pair}
                  id={"matrix-cell-#{dom_safe(entrance.stop_id)}-#{dom_safe(platform.stop_id)}"}
                  type="button"
                  phx-click="select_route"
                  phx-value-from={entrance.stop_id}
                  phx-value-to={platform.stop_id}
                  class={[
                    "inline-flex min-h-11 w-full items-center justify-center rounded-control px-2.5 py-1.5 text-xs font-semibold transition-colors",
                    "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus",
                    pair_cell_class(pair)
                  ]}
                >
                  <.icon name={pair_icon(pair)} class="mr-1 size-3.5 shrink-0" />
                  {pair_short_label(pair)}
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <p
        :if={@analysis.inaccessible_entrances != []}
        id="network-hidden-entrances-note"
        class="border-t border-subtle bg-canvas/50 px-5 py-3 text-[13px] text-muted"
      >
        {inaccessible_entrances_note(@analysis.inaccessible_entrances)}
      </p>
    </section>
    """
  end

  attr :analysis, :map, required: true
  attr :gtfs_version_id, :any, required: true
  attr :stop_id, :string, required: true
  attr :edges_by_pathway_id, :map, required: true

  defp network_elevator_dependency_card(assigns) do
    sorted = Enum.sort_by(assigns.analysis.elevators, &{-&1.sole_link_pairs, &1.id})
    assigns = assign(assigns, :elevators, sorted)

    ~H"""
    <section
      id="network-elevator-dependency-card"
      aria-labelledby="network-elevator-dependency-title"
      class="min-w-0 overflow-hidden rounded-card border border-subtle bg-white"
    >
      <div class="border-b border-subtle bg-canvas px-5 py-4">
        <h3 id="network-elevator-dependency-title" class="text-base font-bold text-strong">
          What riders depend on
        </h3>
        <p class="mt-0.5 text-[13px] text-muted">
          Whole elevators ranked by pairs with no backup step-free route.
        </p>
      </div>

      <%= if @elevators == [] do %>
        <p class="px-5 py-4 text-sm text-muted">
          No elevators are used by step-free routes in this station.
        </p>
      <% else %>
        <ul class="divide-y divide-subtle">
          <li
            :for={elevator <- @elevators}
            id={"network-elevator-#{dom_safe(elevator.id)}"}
            class="flex items-start justify-between gap-3 px-5 py-3.5"
          >
            <div class="min-w-0">
              <p class="text-sm font-bold text-strong">{elevator.label}</p>
              <p class="mt-0.5 text-[13px] text-muted">{elevator.connects}</p>
              <p class="mt-1 text-xs font-semibold text-default tabular-nums">
                <%= if elevator.sole_link_pairs > 0 do %>
                  Sole link for {elevator.sole_link_pairs} {pluralize(
                    elevator.sole_link_pairs,
                    "pair",
                    "pairs"
                  )}
                <% else %>
                  Backup step-free route available
                <% end %>
              </p>
            </div>
            <% href =
              elevator_diagram_href(@gtfs_version_id, @stop_id, elevator, @edges_by_pathway_id) %>
            <.link
              :if={href}
              id={"network-elevator-link-#{dom_safe(elevator.id)}"}
              navigate={href}
              class="inline-flex min-h-11 shrink-0 items-center gap-1 rounded-control px-2.5 text-xs font-semibold text-action no-underline hover:bg-canvas hover:underline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
            >
              Floorplans <.icon name="hero-arrow-right" class="size-3.5" />
            </.link>
          </li>
        </ul>
      <% end %>
    </section>
    """
  end

  # -- Network right-column card (Validation confidence) ---------------------

  attr :analysis, :map, required: true

  defp station_confidence_card(assigns) do
    total = max(assigns.analysis.edge_completeness.total, 0)
    complete = assigns.analysis.edge_completeness.complete
    pct = if(total > 0, do: round(complete / total * 100), else: 0)
    assigns = assign(assigns, :completeness_pct, pct)

    ~H"""
    <section
      id="validation-confidence-card"
      aria-labelledby="validation-confidence-title"
      class="min-w-0 overflow-hidden rounded-card border border-subtle bg-white"
    >
      <div class="border-b border-subtle bg-canvas px-5 py-4">
        <h3 id="validation-confidence-title" class="text-base font-bold text-strong">
          Station confidence
        </h3>
      </div>

      <div class="space-y-4 p-5">
        <dl class="grid grid-cols-3 gap-2">
          <div id="confidence-confirmed" class="rounded-control bg-info-bg p-3 text-info-fg">
            <dd class="font-display text-2xl font-semibold leading-none tabular-nums">
              {@analysis.confidence_counts.confirmed}
            </dd>
            <dt class="mt-1.5 text-xs font-semibold">Confirmed</dt>
          </div>

          <div
            id="confidence-unverified"
            class="rounded-control bg-unverified-bg p-3 text-unverified-fg"
          >
            <dd class="font-display text-2xl font-semibold leading-none tabular-nums">
              {@analysis.confidence_counts.unverified}
            </dd>
            <dt class="mt-1.5 text-xs font-semibold">Unverified</dt>
          </div>

          <div
            id="confidence-no-route"
            class="rounded-control border border-subtle bg-canvas p-3 text-default"
          >
            <dd class="font-display text-2xl font-semibold leading-none tabular-nums">
              {@analysis.confidence_counts.no_route}
            </dd>
            <dt class="mt-1.5 text-xs font-semibold">No route</dt>
          </div>
        </dl>

        <div class="space-y-1.5">
          <p id="confidence-edge-completeness" class="text-[13px] text-muted tabular-nums">
            {@analysis.edge_completeness.complete} of {@analysis.edge_completeness.total} step-free
            pathways have complete accessibility data.
          </p>
          <div
            class="h-2 w-full overflow-hidden rounded-full bg-canvas"
            role="progressbar"
            aria-valuenow={@completeness_pct}
            aria-valuemin="0"
            aria-valuemax="100"
            aria-label="Step-free pathway data completeness"
          >
            <div class="h-full rounded-full bg-[#0F766E]" style={"width: #{@completeness_pct}%;"}>
            </div>
          </div>
        </div>
      </div>
    </section>
    """
  end

  # -- Large-station Impact & routes view ------------------------------------

  attr :gtfs_version_id, :any, required: true
  attr :stop_id, :string, required: true
  attr :analysis, :map, required: true
  attr :groups, :map, required: true
  attr :curated_pairs, :list, required: true
  attr :selected_from, :string, default: nil
  attr :selected_to, :string, default: nil
  attr :route_direction, :atom, required: true
  attr :selected_route, :any, default: nil
  attr :collapsed_route_items, :list, required: true
  attr :expanded_corridors, :any, required: true
  attr :selected_cell, :any, default: nil
  attr :edges_by_pathway_id, :map, required: true
  attr :expanded_issue_ids, :any, required: true

  def impact_view(assigns) do
    sole_elevator_count = Enum.count(assigns.analysis.elevators, &(&1.sole_link_pairs > 0))

    sole_elevator_ids =
      assigns.analysis.elevators
      |> Enum.filter(&(&1.sole_link_pairs > 0))
      |> MapSet.new(& &1.id)

    assigns =
      assigns
      |> assign(:sole_elevator_count, sole_elevator_count)
      |> assign(:sole_elevator_ids, sole_elevator_ids)

    ~H"""
    <div id="accessibility-impact-view" class="space-y-6">
      <%!-- 4-tile KPI strip --%>
      <dl
        id="impact-kpi-strip"
        class="grid grid-cols-1 gap-3 sm:grid-cols-2 xl:grid-cols-4"
      >
        <div id="kpi-step-free-entrances" class="rounded-card border border-subtle bg-white p-5">
          <dd class="font-display text-[28px] font-semibold leading-none tracking-[-0.02em] text-strong tabular-nums">
            {length(@analysis.step_free_entrances)} of {length(@analysis.entrances)}
          </dd>
          <dt class="mt-2 text-sm font-semibold text-strong">Entrances with step-free access</dt>
          <p class="mt-1 text-xs text-muted">
            <%= if @analysis.inaccessible_entrances == [] do %>
              All entrances have a step-free route.
            <% else %>
              {length(@analysis.inaccessible_entrances)} {pluralize(
                length(@analysis.inaccessible_entrances),
                "other entrance is",
                "other entrances are"
              )} hidden with no step-free route.
            <% end %>
          </p>
        </div>

        <div id="kpi-confirmed-pairs" class="rounded-card border border-info-line/40 bg-info-bg p-5">
          <dd class="font-display text-[28px] font-semibold leading-none tracking-[-0.02em] text-info-fg tabular-nums">
            {@analysis.confidence_counts.confirmed} of {length(@analysis.pairs)}
          </dd>
          <dt class="mt-2 text-sm font-semibold text-info-fg">Confirmed round trips</dt>
          <p class="mt-1 text-xs text-info-fg tabular-nums">
            {@analysis.edge_completeness.complete} of {@analysis.edge_completeness.total} step-free
            pathways have complete data.
          </p>
        </div>

        <div
          id="kpi-unverified-pairs"
          class="rounded-card border border-unverified-line/40 bg-unverified-bg p-5"
        >
          <dd class="font-display text-[28px] font-semibold leading-none tracking-[-0.02em] text-unverified-fg tabular-nums">
            {@analysis.confidence_counts.unverified}
          </dd>
          <dt class="mt-2 text-sm font-semibold text-unverified-fg">Unverified round trips</dt>
          <p class="mt-1 text-xs text-unverified-fg">
            Missing width, slope, traversal time, or level data.
          </p>
        </div>

        <div id="kpi-sole-elevators" class="rounded-card border border-subtle bg-white p-5">
          <dd class="font-display text-[28px] font-semibold leading-none tracking-[-0.02em] text-strong tabular-nums">
            {@sole_elevator_count}
          </dd>
          <dt class="mt-2 text-sm font-semibold text-strong">Sole-link elevators</dt>
          <p class="mt-1 text-xs text-muted tabular-nums">
            {@analysis.confidence_counts.no_route} {pluralize(
              @analysis.confidence_counts.no_route,
              "pair has",
              "pairs have"
            )} no step-free route.
          </p>
        </div>
      </dl>

      <%!-- Main 2-column row: One route at a time + Issues ranked by rider impact --%>
      <div class="grid grid-cols-1 items-start gap-6 xl:grid-cols-[minmax(0,1.45fr)_minmax(0,1fr)]">
        <.route_stepper_card
          gtfs_version_id={@gtfs_version_id}
          stop_id={@stop_id}
          analysis={@analysis}
          curated_pairs={@curated_pairs}
          selected_from={@selected_from}
          selected_to={@selected_to}
          route_direction={@route_direction}
          selected_route={@selected_route}
          collapsed_route_items={@collapsed_route_items}
          expanded_corridors={@expanded_corridors}
          sole_elevator_ids={@sole_elevator_ids}
        />

        <.issues_card
          id="impact-issues-card"
          title="Issues ranked by rider impact"
          issues={@analysis.issues}
          gtfs_version_id={@gtfs_version_id}
          stop_id={@stop_id}
          edges_by_pathway_id={@edges_by_pathway_id}
          expanded_issue_ids={@expanded_issue_ids}
        />
      </div>

      <%!-- Bottom 2-column row: Grouped matrix + 3-column Elevator dependency table --%>
      <div class="grid grid-cols-1 items-start gap-6 xl:grid-cols-[minmax(0,1.1fr)_minmax(0,1fr)]">
        <.grouped_matrix_card
          groups={@groups}
          selected_cell={@selected_cell}
        />

        <.elevator_dependency_table_card
          analysis={@analysis}
          gtfs_version_id={@gtfs_version_id}
          stop_id={@stop_id}
          edges_by_pathway_id={@edges_by_pathway_id}
        />
      </div>
    </div>
    """
  end

  # -- One route at a time stepper card --------------------------------------

  attr :gtfs_version_id, :any, required: true
  attr :stop_id, :string, required: true
  attr :analysis, :map, required: true
  attr :curated_pairs, :list, required: true
  attr :selected_from, :string, default: nil
  attr :selected_to, :string, default: nil
  attr :route_direction, :atom, required: true
  attr :selected_route, :any, default: nil
  attr :collapsed_route_items, :list, required: true
  attr :expanded_corridors, :any, required: true
  attr :sole_elevator_ids, :any, required: true

  defp route_stepper_card(assigns) do
    selected_pair =
      Enum.find(assigns.analysis.pairs, fn pair ->
        pair.entrance_stop_id == assigns.selected_from and
          pair.platform_stop_id == assigns.selected_to
      end)

    grouped_levels = group_stepper_items_by_level(assigns.collapsed_route_items)

    assigns =
      assigns
      |> assign(:selected_pair, selected_pair)
      |> assign(:grouped_levels, grouped_levels)

    ~H"""
    <section
      id="impact-route-card"
      aria-labelledby="impact-route-title"
      class="min-w-0 overflow-hidden rounded-card border border-subtle bg-white"
    >
      <div class="flex flex-wrap items-baseline justify-between gap-2 border-b border-subtle bg-canvas px-5 py-4">
        <h3 id="impact-route-title" class="text-base font-bold text-strong">
          One route at a time
        </h3>
        <p class="text-[13px] text-muted">
          Verified corridors are collapsed. Select a step to edit in Floorplans.
        </p>
      </div>

      <div class="space-y-4 p-5">
        <%!-- Quick route selector pills --%>
        <div
          :if={@curated_pairs != []}
          id="route-selector-pills"
          class="flex flex-wrap gap-2"
          role="group"
          aria-label="Quick route selection"
        >
          <button
            :for={pair <- @curated_pairs}
            id={"route-pill-#{dom_safe(pair.entrance_stop_id)}-#{dom_safe(pair.platform_stop_id)}"}
            type="button"
            phx-click="select_route"
            phx-value-from={pair.entrance_stop_id}
            phx-value-to={pair.platform_stop_id}
            aria-pressed={
              to_string(
                pair.entrance_stop_id == @selected_from && pair.platform_stop_id == @selected_to
              )
            }
            class={[
              "inline-flex min-h-11 items-center gap-1.5 rounded-full border px-4 text-sm font-semibold transition-colors",
              "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus",
              if(pair.entrance_stop_id == @selected_from && pair.platform_stop_id == @selected_to,
                do: "border-navy-700 bg-navy-700 text-white",
                else: "border-subtle bg-white text-strong hover:bg-canvas"
              )
            ]}
          >
            <span>{pair.entrance_name}</span>
            <span aria-hidden="true">→</span>
            <span>{pair.platform_name}</span>
          </button>
        </div>

        <%!-- Full pair selector + direction toggle --%>
        <div class="flex flex-wrap items-end justify-between gap-3 border-t border-subtle pt-4">
          <form
            id="route-pair-form"
            phx-change="select_route"
            class="flex flex-wrap items-end gap-3"
          >
            <div class="min-w-[11rem]">
              <label for="route-from-select" class="block text-xs font-semibold text-muted">
                Entrance
              </label>
              <select
                id="route-from-select"
                name="from"
                class="mt-1 block min-h-11 w-full rounded-control border border-control bg-white px-3 text-sm text-strong focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
              >
                <option
                  :for={entrance <- @analysis.entrances}
                  value={entrance.stop_id}
                  selected={entrance.stop_id == @selected_from}
                >
                  {entrance.name}
                </option>
              </select>
            </div>

            <div class="min-w-[11rem]">
              <label for="route-to-select" class="block text-xs font-semibold text-muted">
                Platform
              </label>
              <select
                id="route-to-select"
                name="to"
                class="mt-1 block min-h-11 w-full rounded-control border border-control bg-white px-3 text-sm text-strong focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
              >
                <option
                  :for={platform <- @analysis.platforms}
                  value={platform.stop_id}
                  selected={platform.stop_id == @selected_to}
                >
                  {platform.name}
                </option>
              </select>
            </div>
          </form>

          <div
            id="route-direction-toggle"
            role="group"
            aria-label="Route direction"
            class="inline-flex rounded-control border border-subtle bg-canvas p-0.5"
          >
            <button
              id="direction-to-platform"
              type="button"
              phx-click="toggle_direction"
              phx-value-direction="to_platform"
              aria-pressed={to_string(@route_direction == :to_platform)}
              class={[
                "inline-flex min-h-11 items-center rounded-[5px] px-3 text-xs font-semibold transition-colors",
                "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus",
                if(@route_direction == :to_platform,
                  do: "bg-white text-strong shadow-xs",
                  else: "text-muted hover:text-strong"
                )
              ]}
            >
              To platform
            </button>
            <button
              id="direction-to-exit"
              type="button"
              phx-click="toggle_direction"
              phx-value-direction="to_exit"
              aria-pressed={to_string(@route_direction == :to_exit)}
              class={[
                "inline-flex min-h-11 items-center rounded-[5px] px-3 text-xs font-semibold transition-colors",
                "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus",
                if(@route_direction == :to_exit,
                  do: "bg-white text-strong shadow-xs",
                  else: "text-muted hover:text-strong"
                )
              ]}
            >
              To exit
            </button>
          </div>
        </div>

        <%!-- Route summary banner & stepper --%>
        <%= case @selected_route do %>
          <% %{status: status} = route -> %>
            <div
              id="selected-route-summary"
              data-route-status={status}
              class={[
                "flex flex-wrap items-center justify-between gap-3 rounded-control px-4 py-3 text-sm",
                if(status == :confirmed,
                  do: "bg-info-bg text-info-fg",
                  else: "bg-unverified-bg text-unverified-fg"
                )
              ]}
            >
              <div class="flex flex-wrap items-center gap-2.5">
                <.tone_badge tone={if(status == :confirmed, do: "info", else: "unverified")}>
                  {if(status == :confirmed, do: "Confirmed step-free", else: "Unverified")}
                </.tone_badge>
                <span class="font-semibold tabular-nums">
                  {route_metrics_summary(route)}
                </span>
              </div>
              <span class="text-xs font-medium">
                {if(@route_direction == :to_platform,
                  do: "Entrance → Platform",
                  else: "Platform → Exit"
                )}
              </span>
            </div>

            <div id="route-stepper" class="space-y-4 pt-2">
              <%!-- Start endpoint --%>
              <div class="flex items-center gap-3 pl-2 sm:pl-32">
                <span class="size-3 shrink-0 rounded-[2px] bg-navy-700" aria-hidden="true"></span>
                <div class="min-w-0">
                  <p class="text-sm font-bold text-strong">
                    {if(@route_direction == :to_platform,
                      do: route.entrance_name,
                      else: route.platform_name
                    )}
                  </p>
                  <p class="text-xs text-muted">
                    {if(@route_direction == :to_platform,
                      do: "Origin entrance",
                      else: "Origin platform"
                    )}
                  </p>
                </div>
              </div>

              <%!-- Level-grouped vertical rail --%>
              <div
                :for={level_group <- @grouped_levels}
                class="grid grid-cols-1 gap-2 sm:grid-cols-[7.5rem_minmax(0,1fr)] sm:gap-4"
              >
                <div class="pt-2 text-[11px] font-bold uppercase tracking-wider text-muted sm:text-right">
                  {level_group.level_label}
                </div>

                <ol class="relative space-y-3 border-l-2 border-[#0F766E]/40 pl-5">
                  <li :for={item <- level_group.items} class="relative">
                    <%= if item.type == :corridor do %>
                      <% expanded? = MapSet.member?(@expanded_corridors, item.id) %>
                      <span
                        class="absolute -left-[27px] top-3.5 size-3 rounded-full border-2 border-[#0F766E] bg-white"
                        aria-hidden="true"
                      >
                      </span>
                      <div class="rounded-control border border-subtle bg-canvas/50">
                        <button
                          id={"corridor-toggle-#{dom_safe(item.id)}"}
                          type="button"
                          phx-click="toggle_corridor"
                          phx-value-corridor_id={item.id}
                          aria-expanded={to_string(expanded?)}
                          aria-controls={"corridor-steps-#{dom_safe(item.id)}"}
                          class="flex min-h-11 w-full items-center justify-between gap-3 px-3.5 py-2 text-left text-sm transition-colors hover:bg-canvas focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
                        >
                          <div class="min-w-0">
                            <p class="font-semibold text-strong">
                              {corridor_zone_title(item.fare_zone)}
                            </p>
                            <p class="text-xs text-muted tabular-nums">{item.summary}</p>
                          </div>
                          <span class="inline-flex shrink-0 items-center gap-1 text-xs font-semibold text-action">
                            {if(expanded?, do: "Collapse", else: "Expand")}
                            <.icon
                              name={if(expanded?, do: "hero-chevron-up", else: "hero-chevron-down")}
                              class="size-4"
                            />
                          </span>
                        </button>

                        <ul
                          :if={expanded?}
                          id={"corridor-steps-#{dom_safe(item.id)}"}
                          class="divide-y divide-subtle border-t border-subtle bg-white px-3.5"
                        >
                          <li
                            :for={step <- item.steps}
                            class="flex flex-wrap items-center justify-between gap-2 py-2.5 text-xs"
                          >
                            <div class="min-w-0">
                              <p class="font-semibold text-strong">
                                {step.pathway_mode_label} · {step.from_stop_name} → {step.to_stop_name}
                              </p>
                              <p class="text-muted tabular-nums">{step_detail_line(step)}</p>
                            </div>
                            <% href =
                              pathway_diagram_href(
                                @gtfs_version_id,
                                @stop_id,
                                step.level_id,
                                step.pathway_uuid
                              ) %>
                            <.link
                              :if={href}
                              id={"stepper-edit-#{dom_safe(step.pathway_id)}"}
                              navigate={href}
                              class="inline-flex min-h-11 items-center gap-1 rounded-control font-semibold text-action no-underline hover:underline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
                            >
                              Floorplans <.icon name="hero-arrow-right" class="size-3.5" />
                            </.link>
                          </li>
                        </ul>
                      </div>
                    <% else %>
                      <% step = item.step %>
                      <% sole_link? =
                        not is_nil(step.elevator_id) &&
                          MapSet.member?(@sole_elevator_ids, step.elevator_id) %>
                      <span
                        class={[
                          "absolute -left-[27px] top-3.5 size-3.5 rounded-full border-2 bg-white",
                          step_dot_border(step)
                        ]}
                        aria-hidden="true"
                      >
                      </span>
                      <div class="flex flex-wrap items-start justify-between gap-3 rounded-control border border-subtle bg-white px-3.5 py-2.5">
                        <div class="min-w-0 flex-1 space-y-1">
                          <div class="flex flex-wrap items-center gap-2">
                            <p class="text-sm font-semibold text-strong">
                              {step_headline(step)}
                            </p>
                            <.tone_badge :if={sole_link?} tone="info">
                              Only step-free link
                            </.tone_badge>
                            <.tone_badge :if={step.near_threshold_fields != []} tone="warning">
                              Near threshold
                            </.tone_badge>
                            <.tone_badge :if={step.classification == :unverified} tone="unverified">
                              Unverified
                            </.tone_badge>
                          </div>
                          <p class="text-xs text-muted">
                            {step.from_stop_name} → {step.to_stop_name}
                          </p>
                          <p class="text-xs text-muted tabular-nums">
                            {step_detail_line(step)}
                          </p>
                          <p :if={step.signposted_as} class="text-xs text-default">
                            Signposted: <span class="font-medium">"{step.signposted_as}"</span>
                          </p>
                        </div>

                        <% href =
                          pathway_diagram_href(
                            @gtfs_version_id,
                            @stop_id,
                            step.level_id,
                            step.pathway_uuid
                          ) %>
                        <.link
                          :if={href}
                          id={"stepper-edit-#{dom_safe(step.pathway_id)}"}
                          navigate={href}
                          class="inline-flex min-h-11 shrink-0 items-center gap-1 rounded-control px-2 text-xs font-semibold text-action no-underline hover:bg-canvas hover:underline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
                        >
                          Edit in Floorplans <.icon name="hero-arrow-right" class="size-3.5" />
                        </.link>
                      </div>
                    <% end %>
                  </li>
                </ol>
              </div>

              <%!-- Destination endpoint --%>
              <div class="flex items-center gap-3 pl-2 sm:pl-32">
                <span class="size-3 shrink-0 rounded-[2px] bg-navy-700" aria-hidden="true"></span>
                <div class="min-w-0">
                  <p class="text-sm font-bold text-strong">
                    {if(@route_direction == :to_platform,
                      do: route.platform_name,
                      else: route.entrance_name
                    )}
                  </p>
                  <p class="text-xs text-muted">
                    {if(@route_direction == :to_platform,
                      do: "Destination platform",
                      else: "Destination exit"
                    )}
                  </p>
                </div>
              </div>
            </div>
          <% _no_route -> %>
            <div
              id="selected-route-summary"
              data-route-status="no_route"
              class="rounded-control border border-subtle bg-canvas px-4 py-4 text-sm text-default"
            >
              <div class="flex items-center gap-2">
                <.tone_badge tone={
                  if(@selected_pair && @selected_pair.one_way_only?, do: "warning", else: "muted")
                }>
                  {if(@selected_pair && @selected_pair.one_way_only?,
                    do: "One-way only",
                    else: "No step-free route"
                  )}
                </.tone_badge>
              </div>
              <p class="mt-2 text-sm text-muted">
                <%= if @selected_pair && @selected_pair.one_way_only? do %>
                  This pair has a barrier-free route in only one direction and cannot complete a
                  step-free round trip.
                <% else %>
                  No barrier-free step-free round trip connects this entrance and platform. Check
                  the ranked issues for blocking barriers or missing connections.
                <% end %>
              </p>
            </div>
        <% end %>
      </div>
    </section>
    """
  end

  # -- Step-free access by group matrix + inline drill-down ------------------

  attr :groups, :map, required: true
  attr :selected_cell, :any, default: nil

  defp grouped_matrix_card(assigns) do
    selected_cell_data =
      case assigns.selected_cell do
        {eg_id, pg_id} -> Map.get(assigns.groups.cells, {eg_id, pg_id})
        _ -> nil
      end

    selected_eg =
      selected_cell_data &&
        Enum.find(
          assigns.groups.entrance_groups,
          &(&1.id == selected_cell_data.entrance_group_id)
        )

    selected_pg =
      selected_cell_data &&
        Enum.find(
          assigns.groups.platform_groups,
          &(&1.id == selected_cell_data.platform_group_id)
        )

    assigns =
      assigns
      |> assign(:selected_cell_data, selected_cell_data)
      |> assign(:selected_eg, selected_eg)
      |> assign(:selected_pg, selected_pg)

    ~H"""
    <section
      id="impact-grouped-matrix-card"
      aria-labelledby="impact-grouped-matrix-title"
      class="min-w-0 overflow-hidden rounded-card border border-subtle bg-white"
    >
      <div class="border-b border-subtle bg-canvas px-5 py-4">
        <h3 id="impact-grouped-matrix-title" class="text-base font-bold text-strong">
          Step-free access by group
        </h3>
        <p class="mt-0.5 text-[13px] text-muted">
          Step-free entrances only, grouped by topology and transit lines. Select a cell to inspect
          its pairs.
        </p>
      </div>

      <%= if @groups.entrance_groups == [] || @groups.platform_groups == [] do %>
        <p class="px-5 py-4 text-sm text-muted">
          No step-free entrance and platform groups to display.
        </p>
      <% else %>
        <div
          tabindex="0"
          aria-label="Grouped step-free access matrix"
          class="overflow-x-auto p-4 focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-focus"
        >
          <table
            id="grouped-access-matrix-table"
            class="w-full border-separate border-spacing-1.5 text-left text-sm"
          >
            <thead>
              <tr>
                <th
                  scope="col"
                  class="px-2 py-1 text-xs font-semibold uppercase tracking-wide text-muted"
                >
                  Entrance group
                </th>
                <th
                  :for={pg <- @groups.platform_groups}
                  scope="col"
                  class="px-2 py-1 text-center align-bottom"
                >
                  <div class="inline-flex flex-wrap items-center justify-center gap-1">
                    <span
                      :for={route <- Enum.take(pg.routes, 3)}
                      :if={valid_hex_color?(route.route_color)}
                      class="inline-block size-2.5 shrink-0 rounded-full"
                      style={"background-color: ##{route.route_color};"}
                      aria-hidden="true"
                    >
                    </span>
                    <span class="text-xs font-bold text-strong">{pg.title}</span>
                  </div>
                  <div class="mt-0.5 text-[11px] font-normal text-muted tabular-nums">
                    {pg.platform_count} {pluralize(pg.platform_count, "platform", "platforms")}
                  </div>
                </th>
              </tr>
            </thead>
            <tbody>
              <tr :for={eg <- @groups.entrance_groups}>
                <th
                  scope="row"
                  class="max-w-[14rem] px-2 py-1.5 text-left text-xs font-semibold text-strong"
                >
                  <span class="block break-words">{eg.title}</span>
                  <span class="font-normal text-muted tabular-nums">
                    ({eg.entrance_count} {pluralize(eg.entrance_count, "entrance", "entrances")})
                  </span>
                </th>
                <td :for={pg <- @groups.platform_groups} class="p-0.5 text-center">
                  <% cell = Map.get(@groups.cells, {eg.id, pg.id}) %>
                  <% is_selected? = @selected_cell == {eg.id, pg.id} %>
                  <button
                    :if={cell}
                    id={"group-cell-#{dom_safe(eg.id)}-#{dom_safe(pg.id)}"}
                    type="button"
                    phx-click="select_cell"
                    phx-value-entrance_group_id={eg.id}
                    phx-value-platform_group_id={pg.id}
                    aria-expanded={to_string(is_selected?)}
                    aria-controls="grouped-matrix-drilldown"
                    class={[
                      "inline-flex min-h-11 w-full items-center justify-center rounded-control px-2.5 py-1.5 text-xs font-semibold tabular-nums transition-all",
                      "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus",
                      group_cell_class(cell.status),
                      is_selected? && "ring-2 ring-action ring-offset-1"
                    ]}
                  >
                    {group_cell_label(cell)}
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <%!-- Inline cell drill-down panel --%>
        <div
          :if={@selected_cell_data && @selected_eg && @selected_pg}
          id="grouped-matrix-drilldown"
          class="border-t border-subtle bg-canvas/60 px-5 py-4"
        >
          <div class="flex flex-wrap items-center justify-between gap-2 pb-3">
            <div>
              <h4 class="text-sm font-bold text-strong">
                {@selected_eg.title} → {@selected_pg.title}
              </h4>
              <p class="text-xs text-muted tabular-nums">
                {@selected_cell_data.total} {pluralize(@selected_cell_data.total, "pair", "pairs")}
              </p>
            </div>
            <button
              id="close-cell-drilldown"
              type="button"
              phx-click="close_cell_drilldown"
              class="inline-flex min-h-11 items-center gap-1 rounded-control px-2.5 text-xs font-semibold text-muted hover:bg-white hover:text-strong focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
            >
              <.icon name="hero-x-mark" class="size-4" /> Close
            </button>
          </div>

          <ul class="divide-y divide-subtle rounded-control border border-subtle bg-white">
            <li
              :for={pair <- @selected_cell_data.pairs}
              class="flex flex-wrap items-center justify-between gap-3 px-3.5 py-2.5 text-sm"
            >
              <div class="min-w-0 flex-1">
                <p class="font-semibold text-strong">
                  {pair.entrance_name} → {pair.platform_name}
                </p>
              </div>
              <div class="flex items-center gap-2">
                <.tone_badge tone={pair_tone(pair)}>{pair_short_label(pair)}</.tone_badge>
                <button
                  id={"drilldown-inspect-#{dom_safe(pair.entrance_stop_id)}-#{dom_safe(pair.platform_stop_id)}"}
                  type="button"
                  phx-click="select_route"
                  phx-value-from={pair.entrance_stop_id}
                  phx-value-to={pair.platform_stop_id}
                  class="inline-flex min-h-11 items-center gap-1 rounded-control border border-subtle bg-white px-3 text-xs font-semibold text-action hover:bg-canvas focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
                >
                  Inspect route
                </button>
              </div>
            </li>
          </ul>
        </div>
      <% end %>
    </section>
    """
  end

  # -- 3-column Elevator dependency table ------------------------------------

  attr :analysis, :map, required: true
  attr :gtfs_version_id, :any, required: true
  attr :stop_id, :string, required: true
  attr :edges_by_pathway_id, :map, required: true

  defp elevator_dependency_table_card(assigns) do
    sorted = Enum.sort_by(assigns.analysis.elevators, &{-&1.sole_link_pairs, &1.id})
    assigns = assign(assigns, :elevators, sorted)

    ~H"""
    <section
      id="impact-elevator-table-card"
      aria-labelledby="impact-elevator-table-title"
      class="min-w-0 overflow-hidden rounded-card border border-subtle bg-white"
    >
      <div class="border-b border-subtle bg-canvas px-5 py-4">
        <h3 id="impact-elevator-table-title" class="text-base font-bold text-strong">
          Elevator dependency
        </h3>
        <p class="mt-0.5 text-[13px] text-muted">
          Sorted by pairs that rely on this elevator alone.
        </p>
      </div>

      <%= if @elevators == [] do %>
        <p class="px-5 py-4 text-sm text-muted">
          No elevators are present in this station's step-free network.
        </p>
      <% else %>
        <div
          tabindex="0"
          aria-label="Elevator dependency table"
          class="overflow-x-auto focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-focus"
        >
          <table id="elevator-dependency-table" class="w-full text-left text-sm">
            <thead class="border-b border-subtle bg-canvas/60 text-xs font-semibold text-muted">
              <tr>
                <th scope="col" class="px-5 py-3">Elevator</th>
                <th scope="col" class="px-4 py-3">Connects</th>
                <th scope="col" class="whitespace-nowrap px-5 py-3 text-right">Sole link for</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-subtle">
              <tr
                :for={elevator <- @elevators}
                id={"elevator-row-#{dom_safe(elevator.id)}"}
                class="hover:bg-canvas/40"
              >
                <td class="px-5 py-3 font-semibold text-strong">
                  <% href =
                    elevator_diagram_href(@gtfs_version_id, @stop_id, elevator, @edges_by_pathway_id) %>
                  <%= if href do %>
                    <.link
                      id={"elevator-link-#{dom_safe(elevator.id)}"}
                      navigate={href}
                      class="inline-flex min-h-11 items-center gap-1 rounded-control text-action no-underline hover:underline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
                    >
                      {elevator.label}
                    </.link>
                  <% else %>
                    {elevator.label}
                  <% end %>
                </td>
                <td class="px-4 py-3 text-default">{elevator.connects}</td>
                <td class="whitespace-nowrap px-5 py-3 text-right font-semibold text-strong tabular-nums">
                  {elevator.sole_link_pairs} {pluralize(elevator.sole_link_pairs, "pair", "pairs")}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      <% end %>
    </section>
    """
  end

  # -- Shared impact-ranked Issues list --------------------------------------

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :issues, :list, required: true
  attr :gtfs_version_id, :any, required: true
  attr :stop_id, :string, required: true
  attr :edges_by_pathway_id, :map, required: true
  attr :expanded_issue_ids, :any, required: true

  defp issues_card(assigns) do
    ~H"""
    <section
      id={@id}
      aria-labelledby={"#{@id}-title"}
      class="min-w-0 overflow-hidden rounded-card border border-subtle bg-white"
    >
      <div class="flex flex-wrap items-baseline justify-between gap-2 border-b border-subtle bg-canvas px-5 py-4">
        <h3 id={"#{@id}-title"} class="text-base font-bold text-strong">{@title}</h3>
        <span class="text-[13px] font-medium text-muted tabular-nums">
          {length(@issues)} shown
        </span>
      </div>

      <%= if @issues == [] do %>
        <div class="flex items-center gap-2.5 px-5 py-5 text-sm text-success-fg">
          <.icon name="hero-check-circle" class="size-5 shrink-0" />
          <span>No accessibility issues found for this station.</span>
        </div>
      <% else %>
        <ul class="divide-y divide-subtle">
          <li
            :for={issue <- @issues}
            id={"issue-card-#{dom_safe(issue.id)}"}
            data-issue-kind={issue.kind}
            class="space-y-2.5 px-5 py-4"
          >
            <div class="flex items-start justify-between gap-3">
              <div class="min-w-0 flex-1 space-y-1.5">
                <.tone_badge tone={issue_tone(issue.kind)}>
                  {issue_kind_label(issue.kind)}
                </.tone_badge>
                <p class="text-sm font-bold text-strong">{issue.title}</p>
                <p class="text-[13px] leading-relaxed text-muted">{issue.description}</p>
              </div>

              <div class="shrink-0 text-right tabular-nums">
                <p class="font-display text-xl font-semibold leading-none text-strong">
                  {issue.affected_pairs}
                </p>
                <p class="mt-0.5 text-[11px] font-medium text-muted">
                  {pluralize(issue.affected_pairs, "pair", "pairs")}
                </p>
              </div>
            </div>

            <div class="flex flex-wrap items-center gap-x-4 gap-y-1">
              <%= if issue.target_type == :stop do %>
                <% href = stop_report_href(@gtfs_version_id, @stop_id, issue.stop_uuid) %>
                <.link
                  :if={href}
                  id={"issue-action-#{dom_safe(issue.id)}"}
                  navigate={href}
                  class="inline-flex min-h-11 items-center gap-1.5 text-xs font-semibold text-action no-underline hover:text-action-hover hover:underline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
                >
                  Edit stop in Station Report <.icon name="hero-arrow-right" class="size-3.5" />
                </.link>
              <% else %>
                <% grouped? = issue.kind == :unknown_data && Map.get(issue, :grouped?, false) %>
                <% expanded? = grouped? && MapSet.member?(@expanded_issue_ids, issue.id) %>
                <% primary_href =
                  pathway_diagram_href(
                    @gtfs_version_id,
                    @stop_id,
                    issue.level_id,
                    issue.primary_pathway_uuid
                  ) %>

                <button
                  :if={grouped?}
                  id={"issue-toggle-edges-#{dom_safe(issue.id)}"}
                  type="button"
                  phx-click="toggle_issue_edges"
                  phx-value-issue_id={issue.id}
                  aria-expanded={to_string(expanded?)}
                  aria-controls={"issue-edges-#{dom_safe(issue.id)}"}
                  class="inline-flex min-h-11 items-center gap-1.5 text-xs font-semibold text-strong hover:text-action focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
                >
                  <.icon
                    name={if(expanded?, do: "hero-chevron-up", else: "hero-chevron-down")}
                    class="size-3.5"
                  />
                  {if(expanded?, do: "Hide pathways", else: "Show all #{issue.edge_count} pathways")}
                </button>

                <.link
                  :if={primary_href}
                  id={"issue-action-#{dom_safe(issue.id)}"}
                  navigate={primary_href}
                  class="inline-flex min-h-11 items-center gap-1.5 text-xs font-semibold text-action no-underline hover:text-action-hover hover:underline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
                >
                  {if(grouped?, do: "Edit first in Floorplans", else: "Edit pathway in Floorplans")}
                  <.icon name="hero-arrow-right" class="size-3.5" />
                </.link>

                <ul
                  :if={expanded?}
                  id={"issue-edges-#{dom_safe(issue.id)}"}
                  class="mt-1 w-full divide-y divide-subtle rounded-control border border-subtle bg-canvas/50 px-3"
                >
                  <li
                    :for={pathway_id <- issue.pathway_ids}
                    class="flex items-center justify-between gap-2 py-1.5 text-xs"
                  >
                    <% edge = Map.get(@edges_by_pathway_id, pathway_id) %>
                    <span class="font-mono text-default">{pathway_id}</span>
                    <% edge_href =
                      edge &&
                        pathway_diagram_href(
                          @gtfs_version_id,
                          @stop_id,
                          edge.from_level_id || edge.to_level_id,
                          edge.id
                        ) %>
                    <.link
                      :if={edge_href}
                      id={"issue-edge-link-#{dom_safe(pathway_id)}"}
                      navigate={edge_href}
                      class="inline-flex min-h-11 items-center gap-1 rounded-control font-semibold text-action no-underline hover:underline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
                    >
                      Floorplans <.icon name="hero-arrow-right" class="size-3" />
                    </.link>
                  </li>
                </ul>
              <% end %>
            </div>
          </li>
        </ul>
      <% end %>
    </section>
    """
  end

  # -- Deep-link URL builders ------------------------------------------------

  @doc false
  def pathway_diagram_href(_gtfs_version_id, _station_stop_id, _level_id, nil), do: nil

  def pathway_diagram_href(gtfs_version_id, station_stop_id, level_id, pathway_uuid) do
    params =
      if is_binary(level_id) and level_id != "" do
        [level: level_id, edit_pathway_id: pathway_uuid]
      else
        [edit_pathway_id: pathway_uuid]
      end

    ~p"/gtfs/#{gtfs_version_id}/stops/#{station_stop_id}/diagram?#{params}"
  end

  @doc false
  def stop_report_href(_gtfs_version_id, _station_stop_id, nil), do: nil

  def stop_report_href(gtfs_version_id, station_stop_id, stop_uuid) do
    ~p"/gtfs/#{gtfs_version_id}/stops/#{station_stop_id}/report?#{[edit_stop_id: stop_uuid]}"
  end

  defp elevator_diagram_href(gtfs_version_id, station_stop_id, elevator, edges_by_pathway_id) do
    primary = elevator.primary_pathway
    edge = primary && Map.get(edges_by_pathway_id, primary.pathway_id)
    level_id = edge && (edge.from_level_id || edge.to_level_id)
    pathway_uuid = primary && Map.get(primary, :id)
    pathway_diagram_href(gtfs_version_id, station_stop_id, level_id, pathway_uuid)
  end

  # -- Presentation helpers --------------------------------------------------

  defp header_counts(snapshot, analysis) do
    levels = length(Map.get(snapshot, :levels, []))
    step_free_edges = analysis.edge_completeness.total

    "#{levels} #{pluralize(levels, "level", "levels")} · " <>
      "#{step_free_edges} step-free #{pluralize(step_free_edges, "pathway", "pathways")}"
  end

  defp cross_station_pathway_ids(analysis) do
    analysis
    |> Map.get(:incomplete_reasons, [])
    |> Enum.find_value([], fn
      {:cross_station_pathways, ids} when is_list(ids) -> ids
      _ -> nil
    end)
  end

  defp compute_highlight_counts(analysis) do
    edges = Map.get(analysis, :edges, [])

    %{
      barriers: Enum.count(edges, &(&1.classification in [:barrier, :not_step_free])),
      unknown_data: Enum.count(edges, &(&1.classification == :unverified)),
      near_threshold:
        Enum.count(
          edges,
          &(&1.classification in [:confirmed, :unverified] and &1.near_threshold_fields != [])
        ),
      single_elevator: Enum.count(edges, & &1.sole_link_elevator?)
    }
  end

  defp edge_stroke_color(edge) do
    case Map.get(DiagramPalette.roles(), edge.style_role) do
      %{color: color} -> color
      _ -> "#0F766E"
    end
  end

  defp edge_stroke_width(%{style_role: :schematic_sole_elevator}), do: "4.5"
  defp edge_stroke_width(%{classification: :not_step_free}), do: "2.2"
  defp edge_stroke_width(_edge), do: "3.5"

  defp edge_stroke_dasharray(%{stroke_style: :dotted}), do: "2 6"
  defp edge_stroke_dasharray(%{stroke_style: :dashed}), do: "6 4"
  defp edge_stroke_dasharray(_edge), do: nil

  defp callout_text_color(%{classification: :unverified}), do: "#5b21b6"
  defp callout_text_color(%{classification: :barrier}), do: "#9b1c1c"
  defp callout_text_color(%{style_role: :schematic_near_threshold}), do: "#8a5a0e"
  defp callout_text_color(%{style_role: :schematic_sole_elevator}), do: "#9f0f5c"
  defp callout_text_color(_edge), do: "#0a1330"

  defp node_visual_tokens(%{role: :entrance, step_free?: false}),
    do: {"#fbe3e3", "#b91c1c", "#9b1c1c", "6"}

  defp node_visual_tokens(%{role: :entrance}),
    do: {"#0f1a3d", "#0f1a3d", "#ffffff", "6"}

  defp node_visual_tokens(%{role: role}) when role in [:platform, :boarding_area],
    do: {"#eef0f7", "#7a8698", "#0a1330", "6"}

  defp node_visual_tokens(_node),
    do: {"#ffffff", "#586479", "#0a1330", "14"}

  defp edge_aria_label(edge) do
    "#{edge.pathway_mode_label} #{edge.pathway_id} (#{edge.classification}) — open in Floorplans"
  end

  defp node_aria_label(node) do
    "#{node.name} (#{node.role}) — edit stop in Station Report"
  end

  defp pair_cell_class(%{status: :confirmed}), do: "bg-info-bg text-info-fg hover:bg-info-bg/80"

  defp pair_cell_class(%{status: :unverified}),
    do: "bg-unverified-bg text-unverified-fg hover:bg-unverified-bg/80"

  defp pair_cell_class(%{one_way_only?: true}),
    do: "bg-warning-bg text-warning-fg hover:bg-warning-bg/80"

  defp pair_cell_class(_pair), do: "bg-canvas text-muted hover:bg-canvas/80"

  defp pair_tone(%{status: :confirmed}), do: "info"
  defp pair_tone(%{status: :unverified}), do: "unverified"
  defp pair_tone(%{one_way_only?: true}), do: "warning"
  defp pair_tone(_pair), do: "muted"

  defp pair_icon(%{status: :confirmed}), do: "hero-check-circle"
  defp pair_icon(%{status: :unverified}), do: "hero-question-mark-circle"
  defp pair_icon(%{one_way_only?: true}), do: "hero-exclamation-triangle"
  defp pair_icon(_pair), do: "hero-x-circle"

  defp pair_short_label(%{status: :confirmed}), do: "Confirmed"
  defp pair_short_label(%{status: :unverified}), do: "Unverified"
  defp pair_short_label(%{one_way_only?: true}), do: "One-way"
  defp pair_short_label(_pair), do: "No route"

  defp inaccessible_entrances_note([single]) do
    "#{single.name} has no step-free route and is hidden from this view."
  end

  defp inaccessible_entrances_note(entrances) do
    names = Enum.map_join(entrances, ", ", & &1.name)
    "Entrances with no step-free route are hidden from this view: #{names}."
  end

  defp group_cell_class(:confirmed), do: "bg-info-bg text-info-fg hover:bg-info-bg/80"

  defp group_cell_class(:unverified),
    do: "bg-unverified-bg text-unverified-fg hover:bg-unverified-bg/80"

  defp group_cell_class(:partial), do: "bg-warning-bg text-warning-fg hover:bg-warning-bg/80"
  defp group_cell_class(:no_route), do: "bg-canvas text-muted hover:bg-canvas/80"

  defp group_cell_label(%{status: :confirmed, confirmed: c}), do: "#{c} confirmed"

  defp group_cell_label(%{status: :unverified, confirmed: 0, unverified: u}),
    do: "#{u} unverified"

  defp group_cell_label(%{status: :unverified, confirmed: c, unverified: u}),
    do: "#{c} yes · #{u} unverified"

  defp group_cell_label(%{status: :partial, confirmed: c, unverified: u, no_route: n}) do
    reachable = c + u
    "#{reachable} reach · #{n} no"
  end

  defp group_cell_label(%{no_route: n}), do: "#{n} no route"

  defp route_metrics_summary(route) do
    dist =
      if(is_number(route.distance_meters) and route.distance_meters > 0,
        do: ["#{round(route.distance_meters)} m"],
        else: []
      )

    dur =
      if(is_number(route.duration_seconds) and route.duration_seconds > 0,
        do: [Helpers.format_duration(route.duration_seconds)],
        else: []
      )

    elev_count = length(route.elevator_ids)

    elev =
      case elev_count do
        0 -> ["no elevators"]
        1 -> ["1 elevator"]
        n -> ["#{n} elevators"]
      end

    Enum.join(dist ++ dur ++ elev, " · ")
  end

  defp group_stepper_items_by_level(items) do
    items
    |> Enum.chunk_by(fn item -> item.level_name || item.level_id || "Station" end)
    |> Enum.map(fn chunk ->
      first = hd(chunk)

      %{
        level_label: first.level_name || first.level_id || "Station",
        items: chunk
      }
    end)
  end

  defp corridor_zone_title(:unpaid), do: "Unpaid concourse"
  defp corridor_zone_title(:paid), do: "Paid concourse"
  defp corridor_zone_title(_zone), do: "Verified walkways"

  defp step_dot_border(%{classification: :unverified}), do: "border-unverified-line"
  defp step_dot_border(%{near_threshold_fields: [_ | _]}), do: "border-warning-line"
  defp step_dot_border(_step), do: "border-[#0F766E]"

  defp step_headline(%{pathway_mode: 5, elevator_label: label}) when is_binary(label),
    do: "Elevator #{label}"

  defp step_headline(%{is_ramp: true, pathway_id: pid}), do: "Ramp · #{pid}"
  defp step_headline(%{pathway_mode_label: label, pathway_id: pid}), do: "#{label} · #{pid}"

  defp step_detail_line(step) do
    parts =
      []
      |> maybe_append_lazy(
        is_number(step.distance_meters) && step.distance_meters > 0,
        fn -> "#{round(step.distance_meters)} m" end
      )
      |> maybe_append_lazy(
        is_number(step.duration_seconds) && step.duration_seconds > 0,
        fn -> Helpers.format_duration(step.duration_seconds) end
      )
      |> maybe_append_lazy(
        not is_nil(step.min_width),
        fn -> "min_width #{format_decimal(step.min_width)} m" end
      )
      |> maybe_append_lazy(
        not is_nil(step.max_slope),
        fn -> "max_slope #{format_decimal(step.max_slope)}" end
      )

    case parts do
      [] -> "No measurements recorded"
      list -> Enum.join(list, " · ")
    end
  end

  defp format_decimal(%Decimal{} = value), do: Decimal.to_string(value)
  defp format_decimal(value), do: to_string(value)

  defp issue_tone(:barrier), do: "error"
  defp issue_tone(:single_elevator), do: "info"
  defp issue_tone(:flag_mismatch), do: "error"
  defp issue_tone(:unknown_data), do: "unverified"
  defp issue_tone(:near_threshold), do: "warning"

  defp issue_kind_label(:barrier), do: "Barrier"
  defp issue_kind_label(:single_elevator), do: "Single elevator"
  defp issue_kind_label(:flag_mismatch), do: "Flag mismatch"
  defp issue_kind_label(:unknown_data), do: "Unknown data"
  defp issue_kind_label(:near_threshold), do: "Near threshold"

  defp valid_hex_color?(color) when is_binary(color),
    do: Regex.match?(~r/\A[0-9A-Fa-f]{6}\z/, color)

  defp valid_hex_color?(_), do: false

  defp truncate_label(text, max_len) when is_binary(text) do
    if String.length(text) > max_len do
      String.slice(text, 0, max_len - 1) <> "…"
    else
      text
    end
  end

  defp truncate_label(_, _), do: ""

  @doc false
  def dom_safe(value) when is_binary(value) do
    String.replace(value, ~r/[^a-zA-Z0-9_-]/, "-")
  end

  def dom_safe(value), do: value |> to_string() |> dom_safe()

  defp maybe_append(list, true, item), do: list ++ [item]
  defp maybe_append(list, false, _item), do: list

  defp maybe_append_lazy(list, true, fun), do: list ++ [fun.()]
  defp maybe_append_lazy(list, false, _fun), do: list

  defp pluralize(1, singular, _plural), do: singular
  defp pluralize(_count, _singular, plural), do: plural
end
