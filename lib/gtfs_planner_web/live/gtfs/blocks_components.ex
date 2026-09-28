defmodule GtfsPlannerWeb.Gtfs.BlocksComponents do
  @moduledoc """
  Function components for Operations › Blocks.

  The page's day-type scope, whole-day summary, the paged timeline, the Service
  dates, Checks and Peak drawers and the page states live here so
  `GtfsPlannerWeb.Gtfs.BlocksLive` stays a small state owner. Every component
  takes the pieces of the loaded day it prints, never the whole day, so
  `render/1` in the LiveView never reaches into the server-only day assign
  (CR-6). Later steps render the list, pool and the trip, gap and block drawers
  inside the same page.

  Times are printed from parsed seconds with `clock/1`; nothing here re-reads a
  clock string from the database (CR-3). The timeline reads the block's trips
  and findings only, and takes the block's plot order from the pure
  `Checks.sequence/1` so its bars align with the block's own `gaps/1` pairs.
  """

  use GtfsPlannerWeb, :html

  alias GtfsPlanner.Gtfs.Blocking.Checks
  alias GtfsPlannerWeb.Components.RouteIdentity

  @doc """
  Renders the day-type scope: the day-type select, the route filter, “Problems
  only”, the Service dates button and the Checks button.

  The day select posts through its own form (`select_day`) so a day change is
  never mistaken for a route filter; the route and status controls post through
  the `filter` form. The scope describes the whole day type, so neither control
  changes the whole-day counts.
  """
  attr :day_types, :list, required: true
  attr :day_type, :map, required: true
  attr :routes, :map, required: true
  attr :state, :map, required: true

  def scope_header(assigns) do
    assigns = assign(assigns, :route_options, route_options(assigns.routes))

    ~H"""
    <div id="blocks-scope" class="flex flex-wrap items-end gap-x-6 gap-y-3">
      <form id="blocks-day-form" phx-change="select_day" class="min-w-0 max-w-full">
        <.day_select id="blocks-day" day_types={@day_types} selected={@day_type.key} />
      </form>

      <form
        id="blocks-filter-form"
        phx-change="filter"
        class="flex flex-wrap items-end gap-x-6 gap-y-3"
      >
        <.input
          type="select"
          id="blocks-route"
          name="route"
          label="Route"
          prompt="All routes"
          value={@state.route || ""}
          options={@route_options}
          class="select select-lg w-full sm:w-48"
        />
        <label class="label min-h-11 cursor-pointer gap-2">
          <input
            type="checkbox"
            id="blocks-problems-only"
            name="status"
            value="problems"
            checked={@state.status == :problems}
            class="checkbox"
          />
          <span class="label-text">Problems only</span>
        </label>
      </form>

      <div class="ml-auto">
        <button
          id="blocks-service-dates"
          type="button"
          phx-click="open_drawer"
          phx-value-key="service_dates"
          class="link link-primary min-h-11"
        >
          Service dates
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Renders the day-type select.

  Every day type prints as “<label> · <date_count> dates”; day types with one
  date sit in an optgroup labelled “Special days”. Passing a `nil` selection
  selects nothing, which is the unknown-day recovery state.
  """
  attr :id, :string, required: true
  attr :day_types, :list, required: true
  attr :selected, :string, default: nil

  def day_select(assigns) do
    assigns = assign(assigns, :options, day_type_options(assigns.day_types))

    ~H"""
    <.input
      type="select"
      id={@id}
      name="day"
      label="Day type"
      value={@selected}
      options={@options}
      class="select select-lg w-full sm:w-80"
    />
    """
  end

  @doc """
  Renders the whole-day count strip and the day-type note.

  Every figure is the whole day type's, so the route filter, “Problems only”
  and any paging leave them unchanged. Each item is a button: the unassigned
  figure opens the unassigned panel and the problems and peak figures open
  their drawer. The items whose key names no target (`blocks`, `notices`) are
  ignored by the handler.
  """
  attr :day_type, :map, required: true
  attr :counts, :map, required: true
  attr :peak, :map, required: true
  attr :open_drawer, :atom, default: nil

  def summary_strip(assigns) do
    assigns =
      assigns
      |> assign(:items, count_items(assigns.counts, assigns.peak))
      |> assign(:selected_key, assigns.open_drawer && Atom.to_string(assigns.open_drawer))

    ~H"""
    <section
      id="blocks-summary"
      aria-label="Whole day type summary"
      class="flex flex-wrap items-center gap-x-6 gap-y-2 border-y border-base-300 py-2"
    >
      <.count_strip
        id="blocks-summary-counts"
        items={@items}
        event="open_drawer"
        selected_key={@selected_key}
      />
      <span id="blocks-peak-detail" class="text-sm text-base-content/70">
        {peak_detail(@peak)}
      </span>
      <span id="blocks-summary-note" class="ml-auto text-sm text-base-content/70">
        Whole day type · {date_count_label(@day_type.date_count)}
      </span>
    </section>
    """
  end

  @doc """
  Renders the page's data states: the first-paint skeleton, the two calendar
  and trip empties, and the unknown-day recovery.

  The skeleton mirrors the header, the count strip and eight rows. The recovery
  state keeps the day select but applies no day type: a restored selection
  loads the day the user chose (INV-6).
  """
  attr :kind, :atom, required: true, values: [:loading, :no_dates, :empty, :unknown]
  attr :day_types, :list, default: []
  attr :version_id, :string, default: nil

  def page_state(%{kind: :loading} = assigns) do
    ~H"""
    <.skeleton id="blocks-skeleton" label="Loading blocks…">
      <div class="space-y-3">
        <div class="h-6 w-36 bg-base-300"></div>
        <div class="h-12 w-full bg-base-300"></div>
        <div :for={_row <- 1..8} class="h-9 w-full bg-base-300"></div>
      </div>
    </.skeleton>
    """
  end

  def page_state(%{kind: :no_dates} = assigns) do
    ~H"""
    <div id="blocks-no-dates">
      <.empty_state title="No calendar in this version has a service date.">
        Add the days a calendar runs, then group the trips on those dates into each
        vehicle's work.
        <:action>
          <.link
            id="blocks-no-dates-link"
            navigate={~p"/gtfs/#{@version_id}/calendars"}
            class="btn btn-primary"
          >
            Open Calendars
          </.link>
        </:action>
      </.empty_state>
    </div>
    """
  end

  def page_state(%{kind: :empty} = assigns) do
    ~H"""
    <div id="blocks-empty">
      <.empty_state title="Blocks need trips with calendars">
        Add scheduled trips and the days they run. Then group them into each vehicle's work.
        <:action>
          <.link
            id="blocks-empty-link"
            navigate={~p"/gtfs/#{@version_id}/routes"}
            class="btn btn-primary"
          >
            Open Routes
          </.link>
        </:action>
      </.empty_state>
    </div>
    """
  end

  def page_state(%{kind: :unknown} = assigns) do
    ~H"""
    <div id="blocks-unknown-day">
      <.empty_state title="Choose a day type">
        This day type no longer matches the calendars. No day type is applied for you and
        nothing has changed.
        <:action>
          <form id="blocks-unknown-day-form" phx-submit="select_day" class="mx-auto max-w-sm">
            <.day_select id="blocks-day" day_types={@day_types} />
            <button type="submit" class="btn btn-primary mt-3">Show selected day</button>
          </form>
        </:action>
      </.empty_state>
    </div>
    """
  end

  @doc """
  Renders the Service dates drawer: the day type's date count, its range and
  every date grouped by month.
  """
  attr :open, :boolean, required: true
  attr :day_type, :map, required: true

  def service_dates_drawer(assigns) do
    assigns = assign(assigns, :months, month_groups(assigns.day_type.dates))

    ~H"""
    <.drawer
      id="service-dates-drawer"
      open={@open}
      title="Service dates"
      return_focus_id="blocks-service-dates"
    >
      <h3 class="text-sm font-semibold">
        {@day_type.label} · {date_count_label(@day_type.date_count)}
      </h3>
      <p class="mt-1 text-sm text-base-content/70">{range_text(@day_type.dates)}</p>

      <div :for={{label, dates} <- @months} class="mt-4" data-role="service-dates-month">
        <h4 class="text-sm font-semibold">{label}</h4>
        <ul class="mt-1 space-y-0.5 text-sm">
          <li :for={date <- dates}>{format_date(date)}</li>
        </ul>
      </div>
    </.drawer>
    """
  end

  @doc """
  Renders the Checks drawer: the day type's problems first, then its notices.

  Each finding names its block, its trips and what the finding is; “Open block”
  and “Open trip” carry the reader to the drawer for that block or trip. A
  finding whose trip is outside the loaded day prints the stored ID without an
  action, because the day-type view does not hold the trips to open.
  """
  attr :open, :boolean, required: true
  attr :findings, :list, required: true
  attr :trip_labels, :map, required: true

  def checks_drawer(assigns) do
    problems = Enum.filter(assigns.findings, &(&1.severity in [:error, :warning]))
    notices = Enum.filter(assigns.findings, &(&1.severity == :notice))

    assigns = assign(assigns, problems: problems, notices: notices)

    ~H"""
    <.drawer
      id="checks-drawer"
      open={@open}
      title="Checks and notices"
      return_focus_id="blocks-review-checks"
    >
      <h3 class="text-sm font-semibold">Problems · {length(@problems)}</h3>
      <div id="checks-drawer-problems" class="mt-2 space-y-4">
        <.finding :for={finding <- @problems} finding={finding} trip_labels={@trip_labels} />
        <p :if={@problems == []} class="text-sm text-base-content/70">None in this day type.</p>
      </div>

      <h3 class="mt-6 border-t border-base-300 pt-4 text-sm font-semibold">
        Notices · {length(@notices)}
      </h3>
      <div id="checks-drawer-notices" class="mt-2 space-y-4">
        <.finding :for={finding <- @notices} finding={finding} trip_labels={@trip_labels} />
        <p :if={@notices == []} class="text-sm text-base-content/70">None in this day type.</p>
      </div>
    </.drawer>
    """
  end

  attr :finding, :map, required: true
  attr :trip_labels, :map, required: true

  defp finding(assigns) do
    ~H"""
    <div
      data-role="blocks-finding"
      data-code={@finding.code}
      data-severity={@finding.severity}
      class="border-l-4 border-base-300 pl-3"
    >
      <div class="flex flex-wrap items-center gap-2">
        <.status_badge status={severity_status(@finding.severity)} label={code_label(@finding.code)} />
        <button
          :if={@finding.block_id}
          data-role="blocks-finding-block"
          type="button"
          phx-click="open_block"
          phx-value-block={@finding.block_id}
          class="link link-primary min-h-11"
        >
          Open block {@finding.block_id}
        </button>
      </div>

      <p class="mt-1 text-sm">{finding_detail(@finding)}</p>

      <p :if={@finding.trip_ids != []} class="mt-1 text-sm">
        <span
          :for={uuid <- @finding.trip_ids}
          class="mr-3 inline-block"
          data-role="blocks-finding-trip"
        >
          <%= if label = @trip_labels[uuid] do %>
            <button
              type="button"
              phx-click="open_trip"
              phx-value-trip={label}
              class="link link-primary min-h-11"
            >
              Open trip {label}
            </button>
          <% else %>
            <span class="text-base-content/70">{uuid}</span>
          <% end %>
        </span>
      </p>
    </div>
    """
  end

  @doc """
  Renders the Peak drawer: the definition, a bar per 15-minute bin, the same
  bins as a table and the count of trips the figure leaves out.
  """
  attr :open, :boolean, required: true
  attr :peak, :map, required: true
  attr :bins, :list, required: true
  attr :axis, :map, default: nil

  def peak_drawer(assigns) do
    max = assigns.bins |> Enum.map(& &1.count) |> Enum.max(fn -> 0 end)

    assigns =
      assigns
      |> assign(:max, max)
      |> assign(:bars, Enum.map(assigns.bins, &Map.put(&1, :height, bar_height(&1.count, max))))

    ~H"""
    <.drawer
      id="peak-drawer"
      open={@open}
      title="Peak vehicles out"
      return_focus_id="blocks-summary-counts-item-peak"
    >
      <p class="text-sm font-semibold">{peak_headline(@peak)} · whole day type</p>
      <p class="mt-1 text-sm text-base-content/70">
        Blocks in progress, including time between trips. Excludes unassigned and frequency
        trips.
      </p>

      <div :if={@bins != []} class="mt-4">
        <div
          id="peak-chart"
          role="img"
          aria-label={peak_chart_label(@peak, @bins, @axis)}
          class="flex h-28 items-end gap-px border-b border-base-300"
        >
          <i
            :for={bar <- @bars}
            id={"peak-bin-bar-#{bar.start_secs}"}
            style={"height: #{bar.height}%"}
            class="min-w-0 flex-1 bg-base-content/40"
            title={"#{clock(bar.start_secs)} · #{bar.count}"}
          >
          </i>
        </div>
        <div class="mt-1 flex justify-between text-xs text-base-content/70">
          <span>{clock(List.first(@bins).start_secs)}</span>
          <span>{clock(List.last(@bins).start_secs + 900)}</span>
        </div>

        <table id="peak-bins" class="table table-sm mt-4">
          <caption class="sr-only">Vehicles out per 15-minute bin</caption>
          <thead>
            <tr>
              <th scope="col">From</th>
              <th scope="col" class="text-right">Vehicles out</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={bar <- @bars} id={"peak-bin-#{bar.start_secs}"} data-role="peak-bin">
              <td>{clock(bar.start_secs)}</td>
              <td class="text-right tabular-nums">{bar.count}</td>
            </tr>
          </tbody>
        </table>
      </div>

      <p :if={@bins == []} id="peak-bins-empty" class="mt-4 text-sm text-base-content/70">
        No block is timed in this day type, so there is no peak to show.
      </p>

      <p id="peak-exclusions" class="mt-4 text-sm text-base-content/70">
        Excludes {count_label(@peak.excluded_unassigned, "unassigned trip", "unassigned trips")} and {count_label(
          @peak.excluded_frequency,
          "frequency trip",
          "frequency trips"
        )}. Trips without
        usable timing are also left out, and this is not a fleet requirement.
      </p>
    </.drawer>
    """
  end

  @doc """
  Renders the Blocks workspace: the work-queue tabs, the Timeline/List and
  Whole day/Zoom in segmented controls, the hint line and the current panel.

  The Blocks tab holds the paged timeline; the Unassigned tab and the List view
  are step 22's, so until then they render no panel body. The paged timeline is
  the current page of the day type's blocks after the route and status filters
  and the sort, one 36px row per block, inside a container that scrolls in both
  axes so the header and the block columns stay put.

  The colocated hook exists because the URL decides the view: a phone-width
  reader who opens `/blocks` with no `view` gets the List view, which is the
  full-size alternative to the timeline. It pushes `set_view` once and never
  patches a URL that already carries a view.
  """
  attr :state, :map, required: true
  attr :counts, :map, required: true
  attr :visible_count, :integer, required: true
  attr :page_size, :integer, required: true
  attr :block_rows, :any, required: true
  attr :axis, :map, default: nil
  attr :routes, :map, required: true

  def workspace(assigns) do
    assigns = assign(assigns, :filtered?, filtered?(assigns.state))

    ~H"""
    <section
      id="blocks-workspace"
      phx-hook=".BlocksViewportDefault"
      class={[
        "overflow-hidden",
        @counts.blocks == 0 && "rounded-box border border-base-300 bg-base-100 p-6"
      ]}
    >
      <div class="flex flex-wrap items-center justify-between gap-x-6 gap-y-2 border-b border-base-300 bg-canvas px-4 py-2">
        <div class="flex flex-wrap items-center gap-3" role="group" aria-label="Work queue">
          <button
            id="panel-blocks"
            type="button"
            phx-click="set_panel"
            phx-value-panel="blocks"
            aria-pressed={to_string(@state.panel == :blocks)}
            class={["btn btn-sm min-h-11", @state.panel == :blocks && "btn-primary"]}
          >
            Blocks
          </button>
          <button
            id="panel-pool"
            type="button"
            phx-click="set_panel"
            phx-value-panel="pool"
            aria-pressed={to_string(@state.panel == :pool)}
            class={["btn btn-sm min-h-11", @state.panel == :pool && "btn-primary"]}
          >
            Unassigned · {@counts.unassigned}
          </button>
        </div>

        <div :if={@counts.blocks > 0} class="flex flex-wrap items-end gap-3">
          <.segmented_control
            id="blocks-view"
            name="view"
            legend="Plan view"
            legend_class="sr-only"
            options={[{"Timeline", "timeline"}, {"List", "list"}]}
            value={Atom.to_string(@state.view)}
            event="set_view"
            size={:sm}
            appearance={:joined}
          />
          <.segmented_control
            :if={@state.view == :timeline}
            id="blocks-scale"
            name="scale"
            legend="Timeline scale"
            legend_class="sr-only"
            options={[{"Whole day", "day"}, {"Zoom in", "zoom"}]}
            value={Atom.to_string(@state.scale)}
            event="set_scale"
            size={:sm}
            appearance={:joined}
            emphasis={:quiet}
          />
        </div>
      </div>

      <p class="border-b border-base-300 px-4 py-2 text-xs text-base-content/70">
        {workspace_note(@state, @filtered?)}
      </p>

      <%= cond do %>
        <% @counts.blocks == 0 -> %>
          <p id="blocks-workspace-guidance" class="text-sm text-base-content/70">
            Start by selecting trips and assigning them to a new block.
          </p>
        <% @filtered? and @visible_count == 0 -> %>
          <div id="blocks-filtered-empty" class="px-4 py-8 text-center">
            <p class="text-sm text-base-content/70">No blocks match these filters</p>
            <button
              id="blocks-clear-filters"
              type="button"
              phx-click="filter"
              phx-value-route=""
              phx-value-status="all"
              class="btn btn-sm min-h-11 mt-2"
            >
              Clear filters
            </button>
          </div>
        <% @state.panel == :blocks and @state.view == :timeline -> %>
          <.timeline
            state={@state}
            block_rows={@block_rows}
            axis={@axis}
            routes={@routes}
          />
        <% true -> %>
          <%!-- The List view and the Unassigned panel are step 22's. --%>
      <% end %>

      <div
        :if={@state.panel == :blocks and @visible_count > 0}
        id="blocks-pager"
        class="border-t border-base-300 px-4"
      >
        <.pagination
          page={@state.page}
          per_page={@page_size}
          total={@visible_count}
          entity="blocks"
          event="paginate"
        />
      </div>
    </section>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".BlocksViewportDefault">
      export default {
        mounted() {
          const url = new URL(window.location.href)
          if (url.searchParams.has("view")) return
          if (!window.matchMedia("(max-width: 767px)").matches) return
          if (this.pushedViewDefault) return
          this.pushedViewDefault = true
          this.pushEvent("set_view", {view: "list"})
        }
      };
    </script>
    """
  end

  @doc """
  Renders the paged timeline: the sticky sortable header, the whole-day axis with
  a tick every two hours, and one `block_row/1` per streamed block.

  The header buttons sort the whole day type, not the page, and carry the
  direction in `aria-sort` and an arrow (CR-8's `sort` event). The axis and every
  bar are positioned by percentage of the same span, so they stay aligned inside
  the one scroll container.
  """
  attr :state, :map, required: true
  attr :block_rows, :any, required: true
  attr :axis, :map, default: nil
  attr :routes, :map, required: true

  def timeline(assigns) do
    assigns =
      assigns
      |> assign(:columns, sort_columns())
      |> assign(:ticks, axis_ticks(assigns.axis))
      |> assign(:track_style, track_style(assigns.axis))

    ~H"""
    <div id="blocks-timeline-scroll">
      <table
        id="blocks-timeline"
        data-scale={@state.scale}
        aria-label="Blocks by service-day time"
      >
        <colgroup>
          <col class="blocks-col-block" />
          <col class="blocks-col-trips" />
          <col class="blocks-col-start" />
          <col class="blocks-col-end" />
          <col class="blocks-col-hours" />
          <col class="blocks-col-status" />
          <col />
        </colgroup>
        <thead>
          <tr>
            <th
              :for={column <- @columns}
              scope="col"
              aria-sort={aria_sort(@state, column.key)}
              class={["blocks-meta", "blocks-meta-#{column.key}"]}
            >
              <button
                type="button"
                phx-click="sort"
                phx-value-key={column.key}
                class="blocks-sort"
              >
                {column.label}
                <span :if={Atom.to_string(@state.sort) == column.key} aria-hidden="true">
                  {sort_arrow(@state.dir)}
                </span>
              </button>
            </th>
            <th scope="col" class="blocks-axis">
              <span class="blocks-axis-inner">
                <span
                  :for={tick <- @ticks}
                  class="blocks-axis-tick"
                  style={tick.style}
                >
                  {tick.label}
                </span>
              </span>
            </th>
          </tr>
        </thead>
        <tbody id="blocks-timeline-body" phx-update="stream">
          <.block_row
            :for={{dom_id, block} <- @block_rows}
            dom={dom_id}
            block={block}
            axis={@axis}
            routes={@routes}
            track_style={@track_style}
            route_filter={@state.route}
          />
        </tbody>
      </table>
    </div>
    """
  end

  @doc """
  Renders one 36px block row: the sticky Block, Trips, Start, End, Hours and
  Status cells and the track with the block's trip bars and gaps.

  The bars are the block's sequence (plottable, non-frequency trips) so they line
  up with `gaps/1`'s consecutive pairs; an unplottable or repeating trip appears
  in its block and in the Status cell's finding instead of as a bar. With a route
  filter applied, a trip of another route renders no bar and no gap, matching the
  filter that already excluded the block when it has no trip on the route.
  """
  attr :dom, :string, required: true
  attr :block, :map, required: true
  attr :axis, :map, default: nil
  attr :routes, :map, required: true
  attr :track_style, :string, default: nil
  attr :route_filter, :string, default: nil

  def block_row(assigns) do
    assigns =
      assigns
      |> assign(:summary, assigns.block.summary)
      |> assign(:plotted, plotted(assigns.block))
      |> assign(:status, status_label(assigns.block.summary))

    ~H"""
    <tr id={@dom} data-block={@summary.block_id} class="blocks-row">
      <td class={["blocks-meta", "blocks-meta-block"]}>
        <button
          type="button"
          phx-click="open_block"
          phx-value-block={@summary.block_id}
          class="blocks-block-button"
          title={"Block " <> @summary.block_id}
        >
          {@summary.block_id}
        </button>
      </td>
      <td class={["blocks-meta", "blocks-meta-trips"]}>{@summary.trip_count}</td>
      <td class={["blocks-meta", "blocks-meta-start"]}>{clock(@summary.start_secs)}</td>
      <td class={["blocks-meta", "blocks-meta-end"]}>{clock(@summary.end_secs)}</td>
      <td class={["blocks-meta", "blocks-meta-hours"]}>{hours(@summary.hours)}</td>
      <td class={["blocks-meta", "blocks-meta-status"]}>
        <span data-role="block-status" class="inline-flex items-center gap-1">
          <.icon name={@status.icon} class="size-3.5 shrink-0" /> {@status.label}
        </span>
      </td>
      <td class="blocks-track" style={@track_style}>
        <%= for row <- @plotted do %>
          <%= if visible?(row.trip, @route_filter) do %>
            <.gap
              :if={row.gap}
              gap={row.gap}
              from={row.previous}
              axis={@axis}
              short?={row.short?}
            />
            <.trip_bar
              trip={row.trip}
              axis={@axis}
              route={Map.get(@routes, row.trip.route_id)}
              overlap?={row.overlap?}
              shift?={row.shift?}
            />
          <% end %>
        <% end %>
      </td>
    </tr>
    """
  end

  @doc """
  Renders one trip as a 24px button positioned by the day type's axis.

  The bar carries the route's feed colours through `RouteIdentity.route_colors/1`
  (with its neutral fallback), the route's short name, and a title naming the trip,
  route, times and both endpoint stops. An overlapping trip adds the error icon
  and an outline, and every second overlapping bar in a run shifts up so the two
  are legible without relying on colour.
  """
  attr :trip, :map, required: true
  attr :axis, :map, default: nil
  attr :route, :map, default: nil
  attr :overlap?, :boolean, default: false
  attr :shift?, :boolean, default: false

  def trip_bar(assigns) do
    {colors, fallback_class} = RouteIdentity.route_colors(assigns.route || %{})

    assigns =
      assigns
      |> assign(:colors, colors)
      |> assign(:fallback_class, fallback_class)
      |> assign(:label, route_label(assigns.route))
      |> assign(:geometry, bar_geometry(assigns.trip, assigns.axis))
      |> assign(:bar_title, bar_title(assigns.trip, assigns.route))
      |> assign(:style, join_style([bar_geometry(assigns.trip, assigns.axis), colors]))

    ~H"""
    <button
      type="button"
      id={"trip-bar-" <> dom_token(@trip.trip_id)}
      data-role="trip-bar"
      data-trip={@trip.trip_id}
      data-route={@trip.route_id}
      data-overlap={to_string(@overlap?)}
      phx-click="open_trip"
      phx-value-trip={@trip.trip_id}
      style={@style}
      class={[
        "blocks-bar",
        @fallback_class,
        @overlap? && "blocks-bar-overlap",
        @shift? && "blocks-bar-shift"
      ]}
      title={@bar_title}
    >
      <span :if={@overlap?} data-role="trip-bar-overlap" class="blocks-bar-icon">
        <.icon name="hero-x-circle-mini" class="size-3" />
      </span>
      <span class="blocks-bar-label">{@label}</span>
    </button>
    """
  end

  @doc """
  Renders the gap before a trip as a button spanning the layover.

  The bar spans from the previous trip's last arrival to this trip's first
  departure, so `from` is the earlier trip of the pair. Its minutes print only
  when the bar is at least 32px wide, which the container query reads from the
  bar's own width. An empty move draws dashed with the move icon and a short
  layover draws the warning outline, so the two differ by more than colour.
  """
  attr :gap, :map, required: true
  attr :from, :map, required: true
  attr :axis, :map, default: nil
  attr :short?, :boolean, default: false

  def gap(assigns) do
    assigns =
      assigns
      |> assign(:move?, match?({:moves, _}, assigns.gap.handoff))
      |> assign(:style, gap_geometry(assigns.gap, assigns.from, assigns.axis))

    ~H"""
    <button
      type="button"
      data-role="blocks-gap"
      data-from={@from.id}
      data-to={@gap.to_id}
      data-minutes={div(@gap.gap_secs, 60)}
      data-handoff={handoff_key(@gap.handoff)}
      data-short={to_string(@short?)}
      phx-click="open_gap"
      phx-value-from={@from.id}
      phx-value-to={@gap.to_id}
      style={@style}
      class={[
        "blocks-gap",
        @short? && "blocks-gap-short",
        @move? && "blocks-gap-move"
      ]}
      title={gap_title(@gap)}
    >
      <span :if={@move?} data-role="gap-move-icon" class="blocks-gap-icon">
        <.icon name="hero-arrow-up-right-mini" class="size-3" />
      </span>
      <span class="blocks-gap-label">{div(@gap.gap_secs, 60)}</span>
    </button>
    """
  end

  @doc """
  Prints parsed seconds as `HH:MM`, with ` +1d`/` +2d` after midnight (Copy).
  """
  def clock(nil), do: "—"

  def clock(secs) when is_integer(secs) do
    days = div(secs, 86_400)
    within = rem(secs, 86_400)

    clock =
      String.pad_leading(Integer.to_string(div(within, 3600)), 2, "0") <>
        ":" <> String.pad_leading(Integer.to_string(div(rem(within, 3600), 60)), 2, "0")

    case days do
      0 -> clock
      days -> clock <> " +#{days}d"
    end
  end

  defp route_options(routes) do
    routes
    |> Enum.map(fn {route_id, route} -> {route_option_label(route_id, route), route_id} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp route_option_label(route_id, route) do
    route.short_name || route.long_name || route_id
  end

  defp day_type_options(day_types) do
    {special, regular} = Enum.split_with(day_types, & &1.special?)

    regular = Enum.map(regular, &{day_type_option_label(&1), &1.key})

    case special do
      [] ->
        regular

      special ->
        regular ++ [{"Special days", Enum.map(special, &{day_type_option_label(&1), &1.key})}]
    end
  end

  defp day_type_option_label(day_type) do
    "#{day_type.label} · #{date_count_label(day_type.date_count)}"
  end

  defp date_count_label(1), do: "1 date"
  defp date_count_label(count), do: "#{count} dates"

  defp count_items(counts, peak) do
    [
      %{key: "blocks", label: "Blocks", count: counts.blocks, tone: :neutral},
      %{key: "unassigned", label: "Unassigned trips", count: counts.unassigned, tone: :info},
      %{key: "problems", label: "Problems", count: counts.problems, tone: :error},
      %{key: "notices", label: "Notices", count: counts.notices, tone: :warning},
      %{key: "peak", label: "Peak vehicles out", count: peak.count, tone: :neutral}
    ]
  end

  defp peak_detail(%{at_secs: nil}), do: "No block is timed"

  defp peak_detail(peak) do
    "Peak at #{clock(peak.at_secs)} · excludes " <>
      count_label(peak.excluded_unassigned, "unassigned trip", "unassigned trips") <>
      " and " <> count_label(peak.excluded_frequency, "frequency trip", "frequency trips")
  end

  defp count_label(1, singular, _plural), do: "1 #{singular}"
  defp count_label(count, _singular, plural), do: "#{count} #{plural}"

  defp peak_headline(%{at_secs: nil} = peak), do: "#{peak.count} vehicles out"

  defp peak_headline(peak), do: "#{peak.count} at #{clock(peak.at_secs)}"

  defp peak_chart_label(peak, bins, axis) do
    "Vehicles out per 15-minute bin, #{peak.count} at the peak. " <>
      "Chart covers #{clock(List.first(bins).start_secs)} to " <>
      "#{clock(List.last(bins).start_secs + 900)} of the day type" <>
      if(axis,
        do: " (whole day type #{clock(axis.start_secs)}–#{clock(axis.end_secs)})",
        else: ""
      )
  end

  defp bar_height(_count, 0), do: 0
  defp bar_height(count, max), do: round(count / max * 100)

  defp month_groups(dates) do
    dates
    |> Enum.group_by(&{&1.year, &1.month})
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {{year, month}, dates} ->
      {Calendar.strftime(Date.new!(year, month, 1), "%B %Y"), sort_dates(dates)}
    end)
  end

  # `Date` structs compare by field name order (day before month and year), so
  # chronological order needs the Gregorian day count.
  defp sort_dates(dates), do: Enum.sort_by(dates, &Date.to_gregorian_days/1)

  defp range_text([]), do: "No dates"

  defp range_text(dates) do
    {first, last} = Enum.min_max_by(dates, &Date.to_gregorian_days/1)
    "#{format_date(first)} – #{format_date(last)}"
  end

  defp format_date(date), do: Calendar.strftime(date, "%d %b %Y")

  defp severity_status(:error), do: "error"
  defp severity_status(:warning), do: "warning"
  defp severity_status(:notice), do: "info"

  defp code_label(:overlap), do: "Overlap"
  defp code_label(:short_layover), do: "Short layover"
  defp code_label(:in_seat_stale), do: "In-seat row"
  defp code_label(:in_seat_unconfirmed), do: "Can't confirm"
  defp code_label(:repositions), do: "Empty move"
  defp code_label(:frequency_trip), do: "Frequency"
  defp code_label(:unplottable), do: "Time missing"

  defp finding_detail(%{code: :overlap, detail: %{overlap_secs: secs}}) do
    "Two trips in this block overlap by #{minutes(secs)}."
  end

  defp finding_detail(%{code: :short_layover, detail: %{gap_secs: secs}}) do
    "Only #{minutes(secs)} between two trips in this block."
  end

  defp finding_detail(%{code: :repositions, detail: detail}) do
    "The vehicle moves empty: #{minutes(detail.gap_secs)} available, " <>
      case detail.meters do
        nil -> "driving time unknown."
        meters -> "#{meters} m between the stops."
      end
  end

  defp finding_detail(%{code: :frequency_trip, detail: %{headway_secs: secs}}) do
    "Repeats every #{div(secs, 60)} min; individual vehicle work can't be checked here."
  end

  defp finding_detail(%{code: :unplottable}) do
    "An endpoint time is missing, so this trip can't be plotted or assigned."
  end

  defp finding_detail(%{code: code, detail: %{reason: reason}})
       when code in [:in_seat_stale, :in_seat_unconfirmed] do
    in_seat_reason(reason) <> "."
  end

  defp finding_detail(_finding), do: "Review this finding."

  defp in_seat_reason(:trip_missing), do: "A trip in this record isn't in this version"

  defp in_seat_reason(:no_shared_date), do: "The trips share no date"

  defp in_seat_reason(:no_block),
    do: "No block · Google ignores this record; riders see stay-on-board only from blocks"

  defp in_seat_reason(:stops_changed),
    do: "Stops changed · the record's stops are no longer these trips' end stops"

  defp in_seat_reason({:not_next, failures}) do
    "Not next on this vehicle on " <>
      Enum.map_join(failures, "; ", &"#{&1.label}, #{&1.date_count} dates")
  end

  defp in_seat_reason(:next_service_day),
    do: "Can't be confirmed in this view · next-service-day continuation"

  defp in_seat_reason(:untimed),
    do: "Can't be confirmed in this view · missing or repeating times"

  defp in_seat_reason(:coupling), do: "Can't be confirmed in this view · coupling record"

  defp in_seat_reason(reason) when is_atom(reason),
    do: "Can't be confirmed in this view · #{reason}"

  defp minutes(secs) when is_integer(secs), do: "#{div(secs, 60)} min"

  # ── Timeline helpers ──

  # The axis prints a tick every two hours, like the reference prototype: from
  # the axis start up to the last whole tick inside the span. A zero-length axis
  # (one instant) still yields its own start tick, and a tick so close to the end
  # that its label would run past the track (and widen the timeline's scroll area)
  # is left out.
  @tick_secs 7200
  @axis_label_max_percent 92.0
  @min_track_span_secs 60

  defp filtered?(state), do: state.route != nil or state.status == :problems

  defp workspace_note(%{panel: :pool}, _filtered?) do
    "Select trips using times and terminal connections. Frequency trips and missing times " <>
      "require separate attention."
  end

  defp workspace_note(%{view: :list}, filtered?) do
    "Select trips to move or remove their assignments. " <> whole_block_note(filtered?)
  end

  defp workspace_note(_state, filtered?) do
    "Select a trip, block ID, or gap to inspect. Use List for larger controls. " <>
      whole_block_note(filtered?)
  end

  defp whole_block_note(true), do: "Checks cover each whole block; other routes are hidden."
  defp whole_block_note(false), do: "Checks cover each whole block."

  defp sort_columns do
    [
      %{key: "block", label: "Block"},
      %{key: "trips", label: "Trips"},
      %{key: "start", label: "Start"},
      %{key: "end", label: "End"},
      %{key: "hours", label: "Hours"},
      %{key: "status", label: "Status"}
    ]
  end

  defp aria_sort(state, key) do
    cond do
      Atom.to_string(state.sort) != key -> "none"
      state.dir == :asc -> "ascending"
      true -> "descending"
    end
  end

  defp sort_arrow(:asc), do: "↑"
  defp sort_arrow(_dir), do: "↓"

  defp axis_ticks(nil), do: []

  defp axis_ticks(axis) do
    {start, span} = axis_geometry(axis)
    count = max(div(span + @tick_secs - 1, @tick_secs), 1)

    0..(count - 1)
    |> Enum.map(&{&1, &1 * @tick_secs * 100 / span})
    |> Enum.reject(fn {_index, left} -> left > @axis_label_max_percent end)
    |> Enum.map(fn {index, left} ->
      %{style: "left: #{percent_value(left)}%", label: clock(start + index * @tick_secs)}
    end)
  end

  # One faint rule every two hours, drawn as a repeating gradient so the track
  # and the axis share one spacing rule.
  defp track_style(nil), do: nil

  defp track_style(axis) do
    {_start, span} = axis_geometry(axis)
    "--blocks-grid: #{percent(@tick_secs, span)}%"
  end

  defp axis_geometry(%{start_secs: start, end_secs: end_secs}) do
    {start, max(end_secs - start, @min_track_span_secs)}
  end

  defp axis_geometry(_axis), do: {0, @min_track_span_secs}

  defp bar_geometry(trip, axis) do
    {start, span} = axis_geometry(axis)

    "left: #{percent(trip.first_departure - start, span)}%; " <>
      "width: #{percent(trip.last_arrival - trip.first_departure, span)}%"
  end

  defp gap_geometry(gap, previous, axis) do
    {start, span} = axis_geometry(axis)

    "left: #{percent(previous.last_arrival - start, span)}%; " <>
      "width: #{percent(gap.gap_secs, span)}%"
  end

  # Two decimals, so a test can read the geometry straight out of the style and
  # the bars line up with the axis ticks to the hundredth of a percent.
  defp percent(value, span), do: percent_value(value * 100 / span)

  defp percent_value(value), do: :erlang.float_to_binary(value * 1.0, decimals: 2)

  defp join_style(styles) do
    styles |> Enum.reject(&is_nil/1) |> Enum.join("; ")
  end

  defp plotted(block) do
    sequence = Checks.sequence(block.trips)
    overlap_ids = overlap_trip_ids(block.findings)
    short_pairs = short_layover_pairs(block.findings)

    sequence
    |> Enum.with_index()
    |> Enum.map(fn {trip, index} ->
      gap = if index == 0, do: nil, else: Enum.at(block.gaps, index - 1)
      overlap? = MapSet.member?(overlap_ids, trip.id)

      %{
        trip: trip,
        previous: if(index == 0, do: nil, else: Enum.at(sequence, index - 1)),
        gap: gap,
        overlap?: overlap?,
        shift?: overlap? and rem(overlapping_depth(sequence, index, trip), 2) == 1,
        short?: gap != nil and MapSet.member?(short_pairs, MapSet.new([gap.from_id, gap.to_id]))
      }
    end)
  end

  defp overlap_trip_ids(findings) do
    findings
    |> Enum.filter(&(&1.code == :overlap))
    |> Enum.flat_map(& &1.trip_ids)
    |> MapSet.new()
  end

  defp short_layover_pairs(findings) do
    findings
    |> Enum.filter(&(&1.code == :short_layover))
    |> MapSet.new(&MapSet.new(&1.trip_ids))
  end

  # How many earlier trips are still out when this one starts, which is what sets
  # an overlapping bar's vertical offset.
  defp overlapping_depth(sequence, index, trip) do
    sequence |> Enum.take(index) |> Enum.count(&(&1.last_arrival > trip.first_arrival))
  end

  defp visible?(_trip, nil), do: true
  defp visible?(trip, route_id), do: trip.route_id == route_id

  defp status_label(%{status: :ok}), do: %{icon: "hero-check-mini", label: "No problems"}

  defp status_label(%{status_code: code}) do
    %{icon: code_icon(code), label: code_label(code)}
  end

  # Copy: error, warning, empty move, other notices, none.
  defp code_icon(:overlap), do: "hero-x-circle-mini"
  defp code_icon(:short_layover), do: "hero-exclamation-triangle-mini"
  defp code_icon(:in_seat_stale), do: "hero-exclamation-triangle-mini"
  defp code_icon(:repositions), do: "hero-arrow-up-right-mini"
  defp code_icon(_code), do: "hero-information-circle-mini"

  defp hours(nil), do: "—"
  defp hours(hours), do: :erlang.float_to_binary(hours * 1.0, decimals: 1)

  defp route_label(nil), do: "Unknown route"

  defp route_label(route) do
    case route[:short_name] || route[:long_name] || route[:route_id] do
      nil -> "Unknown route"
      "" -> "Unknown route"
      label -> label
    end
  end

  defp bar_title(trip, route) do
    "Trip #{trip.trip_id} · Route #{route_label(route)} · " <>
      "#{clock(trip.first_departure)}–#{clock(trip.last_arrival)} · " <>
      "#{stop_name(trip.first_stop)} → #{stop_name(trip.last_stop)}"
  end

  defp stop_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp stop_name(%{stop_id: stop_id}) when is_binary(stop_id), do: stop_id
  defp stop_name(_stop), do: "unknown stop"

  defp gap_title(%{handoff: {:moves, _}} = gap),
    do: "#{minutes(gap.gap_secs)} gap · the vehicle moves empty"

  defp gap_title(%{handoff: :same_stop} = gap), do: "#{minutes(gap.gap_secs)} gap · same stop"

  defp gap_title(%{handoff: :same_station} = gap),
    do: "#{minutes(gap.gap_secs)} gap · same station"

  defp gap_title(%{handoff: {:nearby, meters}} = gap),
    do: "#{minutes(gap.gap_secs)} gap · nearby stop, #{meters} m"

  defp handoff_key(:same_stop), do: "same_stop"
  defp handoff_key(:same_station), do: "same_station"
  defp handoff_key({:nearby, meters}), do: "nearby-#{meters}"
  defp handoff_key({:moves, _meters}), do: "moves"

  # A DOM id token for a block or trip ID that may hold any Unicode: the same
  # URL-safe Base64 as the block rows, never the raw ID (Setup and hazards).
  defp dom_token(id), do: Base.url_encode64(id, padding: false)
end
