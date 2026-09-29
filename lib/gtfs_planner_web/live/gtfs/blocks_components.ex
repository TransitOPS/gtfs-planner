defmodule GtfsPlannerWeb.Gtfs.BlocksComponents do
  @moduledoc """
  Function components for Operations › Blocks.

  The page's service-day scope, whole-day summary, the paged timeline, the List
  view, the unassigned pool, the Service dates, Checks, Peak and Minimum layover
  drawers, the “not shown on the timeline” list and the page states live here so
  `GtfsPlannerWeb.Gtfs.BlocksLive` stays a small state owner. Every component
  takes the pieces of the loaded day it prints, never the whole day, so
  `render/1` in the LiveView never reaches into the server-only day assign
  (CR-6). The trip, gap and block drawers render inside the same page.

  The components are drawn in the TransitOps application design system: the
  page carries the shared `.ds-page` scope, drawers and dialogs use the planner
  chrome, states are messages and first-use panels, and a finding is a tinted
  badge in drawers and cards but icon plus words in a dense table cell. What is
  local to this page is the timeline table and the gap markers, styled by the
  `blocks (design system)` section of `assets/css/app.css`.

  Times are printed from parsed seconds with `clock/1`; nothing here re-reads a
  clock string from the database (CR-3). The timeline reads the block's trips
  and findings only, and takes the block's plot order from the pure
  `Checks.sequence/1` so its bars align with the block's own `gaps/1` pairs. The
  List view and the pool take a trip's findings from the day's own finding list,
  grouped by trip once per load, and print them as badges.
  """

  use GtfsPlannerWeb, :html

  import GtfsPlannerWeb.PlannerComponents,
    only: [drawer_footer: 1, drawer_scroll: 1, first_use: 1, message: 1]

  alias GtfsPlanner.Gtfs.Blocking.Checks
  alias GtfsPlanner.Gtfs.GtfsTime
  alias GtfsPlannerWeb.Components.RouteIdentity

  @doc """
  Renders the service-day scope: the service-day select, the route filter,
  “Problems only”, the Service dates link and the Minimum layover link.

  The day select posts through its own form (`select_day`) so a day change is
  never mistaken for a route filter; the route and status controls post through
  the `filter` form. The scope describes the whole service day, so neither control
  changes the whole-day counts. Service dates and Minimum layover are set rarely,
  so they are quiet links at the far end. The Minimum layover link prints the
  stored value the day load read, so a save shows the new one on the next render.
  """
  attr :day_types, :list, required: true
  attr :day_type, :map, required: true
  attr :routes, :map, required: true
  attr :state, :map, required: true
  attr :min_layover_minutes, :integer, required: true

  def scope_header(assigns) do
    assigns = assign(assigns, :route_options, route_options(assigns.routes))

    ~H"""
    <div id="blocks-scope" class="flex flex-wrap items-end gap-x-5 gap-y-3 p-4">
      <form id="blocks-day-form" phx-change="select_day" class="w-full min-w-0 sm:w-[360px]">
        <.day_select id="blocks-day" day_types={@day_types} selected={@day_type.key} />
      </form>

      <form
        id="blocks-filter-form"
        phx-change="filter"
        class="flex min-w-0 flex-wrap items-end gap-x-5 gap-y-3 max-sm:w-full"
      >
        <div class="w-full min-w-0 sm:w-[230px]">
          <.input
            type="select"
            id="blocks-route"
            name="route"
            label="Route"
            prompt="All routes"
            value={@state.route || ""}
            options={@route_options}
          />
        </div>
        <label class="flex min-h-11 cursor-pointer items-center gap-2.5 text-sm font-[650] text-strong">
          <input
            type="checkbox"
            id="blocks-problems-only"
            name="status"
            value="problems"
            checked={@state.status == :problems}
            class="size-5 accent-action"
          /> Problems only
        </label>
      </form>

      <div class="ml-auto flex flex-wrap items-center gap-x-4">
        <button
          id="blocks-service-dates"
          type="button"
          phx-click="open_drawer"
          phx-value-key="service_dates"
          class={link_class()}
        >
          Service dates
        </button>
        <button
          id="blocks-min-layover"
          type="button"
          phx-click="open_drawer"
          phx-value-key="layover"
          class={link_class()}
        >
          Minimum layover · {@min_layover_minutes} min
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Renders the service-day select.

  Every service day prints as “<label> · <N> days”; service days with one date
  sit in an optgroup labelled “Special days”. Passing a `nil` selection selects
  nothing, which is the unknown-day recovery state.
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
      label="Service day"
      value={@selected}
      options={@options}
    />
    """
  end

  @doc """
  Renders the whole-day summary tiles and the service-day note.

  Every figure is the whole service day's, so the route filter, “Problems only”
  and any paging leave them unchanged. A tile that leads somewhere is a button:
  Unassigned trips opens the unassigned panel while there are any, Problems
  opens Checks and Peak vehicles out opens its drawer. Blocks and Notices lead
  nowhere today, so they are plain tiles. A tile is neutral until its count
  needs the operator: Unassigned trips and Problems take a state colour above
  zero and read as done, with a check, at zero.
  """
  attr :day_type, :map, required: true
  attr :counts, :map, required: true
  attr :peak, :map, required: true
  attr :open_drawer, :atom, default: nil

  def summary_strip(assigns) do
    assigns = assign(assigns, :tiles, summary_tiles(assigns.counts, assigns.peak))

    ~H"""
    <section
      id="blocks-summary"
      aria-label="Whole service day summary"
      class="flex flex-wrap items-center gap-x-4 gap-y-2 border-t border-subtle px-4 py-3"
    >
      <div
        id="blocks-summary-counts"
        data-role="count-strip"
        class="grid min-w-0 grow grid-cols-2 gap-2 sm:flex sm:grow-0 sm:flex-wrap"
      >
        <.summary_tile :for={tile <- @tiles} tile={tile} />
      </div>
      <span id="blocks-summary-note" class="ml-auto text-[13px] text-muted">
        Whole service day · {day_count_label(@day_type.date_count)}
      </span>
    </section>
    """
  end

  attr :tile, :map, required: true

  defp summary_tile(assigns) do
    ~H"""
    <.dynamic_tag
      tag_name={if @tile.action?, do: "button", else: "div"}
      id={"blocks-summary-counts-item-" <> @tile.key}
      data-role="count-strip-item"
      data-key={@tile.key}
      type={@tile.action? && "button"}
      phx-click={@tile.action? && "open_drawer"}
      phx-value-key={@tile.action? && @tile.key}
      class={[
        "flex min-h-11 items-center gap-2 rounded-control border px-3.5 py-1.5 text-left",
        summary_tile_tone(@tile.tone),
        @tile.wide? && "max-sm:col-span-2",
        @tile.action? && "hover:shadow-card"
      ]}
    >
      <.icon name={@tile.icon} class="size-[18px] shrink-0" />
      <span class={["text-sm", @tile.tone == :neutral && "text-muted"]}>{@tile.label}</span>
      <strong
        data-role="count-strip-value"
        class="font-display text-[22px] font-semibold leading-none tabular-nums"
      >
        {@tile.count}
      </strong>
      <span
        :if={@tile.detail}
        id={@tile.key == "peak" && "blocks-peak-detail"}
        class={["text-[13px]", @tile.tone == :neutral && "text-muted"]}
      >
        {@tile.detail}
      </span>
    </.dynamic_tag>
    """
  end

  defp summary_tile_tone(:neutral), do: "border-subtle bg-white text-strong"
  defp summary_tile_tone(:error), do: "border-error-line bg-error-bg text-error-fg"
  defp summary_tile_tone(:info), do: "border-info-line bg-info-bg text-info-fg"
  defp summary_tile_tone(:success), do: "border-success-line bg-success-bg text-success-fg"

  @doc """
  Renders the page's data states: the first-paint skeleton, the two calendar
  and trip empties, and the unknown-day recovery.

  The skeleton mirrors the scope card, the summary tiles and eight rows. The
  recovery state keeps the service-day select but applies no day: a restored
  selection loads the day the user chose (INV-6).
  """
  attr :kind, :atom, required: true, values: [:loading, :no_dates, :empty, :unknown]
  attr :day_types, :list, default: []
  attr :version_id, :string, default: nil

  def page_state(%{kind: :loading} = assigns) do
    ~H"""
    <div
      id="blocks-skeleton"
      class="overflow-hidden rounded-card border border-subtle bg-white"
    >
      <div class="motion-safe:animate-pulse" aria-hidden="true">
        <div class="flex flex-wrap gap-4 p-4">
          <div :for={width <- ["w-[340px]", "w-[190px]", "w-[120px]"]} class={["max-w-full", width]}>
            <div class="h-4 w-20 rounded-badge bg-canvas"></div>
            <div class="mt-2 h-11 rounded-control bg-canvas"></div>
          </div>
        </div>
        <div class="flex flex-wrap gap-2 border-t border-subtle p-4">
          <div :for={_tile <- 1..5} class="h-11 w-[150px] rounded-control bg-canvas"></div>
        </div>
        <div class="space-y-2 border-t border-subtle p-4">
          <div class="h-9 w-64 rounded-control bg-canvas"></div>
          <div :for={_row <- 1..8} class="h-9 w-full rounded-badge bg-canvas"></div>
        </div>
      </div>
      <p class="px-4 pb-4 text-sm text-muted">Loading blocks…</p>
    </div>
    """
  end

  def page_state(%{kind: :no_dates} = assigns) do
    ~H"""
    <.first_use
      id="blocks-no-dates"
      icon="hero-calendar"
      title="No calendar in this version has a service date"
    >
      Add the days a calendar runs, then group the trips on those days into each vehicle's work.
      <:action>
        <.button
          id="blocks-no-dates-link"
          navigate={~p"/gtfs/#{@version_id}/calendars"}
          class="min-h-11"
        >
          Open Calendars
        </.button>
      </:action>
    </.first_use>
    """
  end

  def page_state(%{kind: :empty} = assigns) do
    ~H"""
    <.first_use id="blocks-empty" icon="hero-inbox" title="Blocks need trips with calendars">
      Add scheduled trips and the days they run. Then group them into each vehicle's work.
      <:action>
        <.button id="blocks-empty-link" navigate={~p"/gtfs/#{@version_id}/routes"} class="min-h-11">
          Open Routes
        </.button>
      </:action>
    </.first_use>
    """
  end

  def page_state(%{kind: :unknown} = assigns) do
    ~H"""
    <.first_use id="blocks-unknown-day" icon="hero-calendar" title="Choose a service day">
      The service day in this link no longer matches your calendars. Nothing has changed, and no
      day is picked for you.
      <:action>
        <form
          id="blocks-unknown-day-form"
          phx-submit="select_day"
          class="mx-auto max-w-sm text-left"
        >
          <.day_select id="blocks-day" day_types={@day_types} />
          <.button type="submit" class="mt-3 min-h-11 w-full">Show blocks</.button>
        </form>
      </:action>
    </.first_use>
    """
  end

  @doc """
  Renders the Service dates drawer: the service day's date count, its range and
  every date grouped by month.
  """
  attr :open, :boolean, required: true
  attr :day_type, :map, required: true

  def service_dates_drawer(assigns) do
    assigns = assign(assigns, :months, month_groups(assigns.day_type.dates))

    ~H"""
    <.drawer
      id="service-dates-drawer"
      chrome="planner"
      open={@open}
      title="Service dates"
      return_focus_id="blocks-service-dates"
      class="max-w-[520px]"
    >
      <:lede>{@day_type.label} · {day_count_label(@day_type.date_count)}</:lede>

      <.drawer_scroll>
        <p class="text-sm text-muted">
          {range_text(@day_type.dates)}. Blocks on this service day apply to every date below.
        </p>

        <section :for={{label, dates} <- @months} data-role="service-dates-month">
          <h3 class="text-[15px] font-bold text-strong">
            {label} <span class="font-normal text-muted">· {day_count_label(length(dates))}</span>
          </h3>
          <ul class="mt-2 flex flex-wrap gap-1.5">
            <li
              :for={date <- dates}
              class="rounded-badge bg-canvas px-2 py-1 text-[13px] tabular-nums text-default"
            >
              {short_date(date)}
            </li>
          </ul>
        </section>
      </.drawer_scroll>
    </.drawer>
    """
  end

  @doc """
  Renders the Checks drawer: the service day's problems first, then its notices.

  Each finding names its block, its trips and what the finding is; “Open block”
  and “Open trip” carry the reader to the drawer for that block or trip. A
  finding whose trip is outside the loaded day prints the stored ID without an
  action, because the service-day view does not hold the trips to open.
  """
  attr :open, :boolean, required: true
  attr :day_type, :map, required: true
  attr :findings, :list, required: true
  attr :trip_labels, :map, required: true

  def checks_drawer(assigns) do
    problems = Enum.filter(assigns.findings, &(&1.severity in [:error, :warning]))
    notices = Enum.filter(assigns.findings, &(&1.severity == :notice))

    assigns = assign(assigns, problems: problems, notices: notices)

    ~H"""
    <.drawer
      id="checks-drawer"
      chrome="planner"
      open={@open}
      title="Checks and notices"
      return_focus_id="blocks-review-checks"
      class="max-w-[520px]"
    >
      <:lede>{@day_type.label} · every block</:lede>

      <.drawer_scroll>
        <p class="text-sm text-muted">
          Problems need a decision before this schedule is ready. Notices are things to know.
        </p>

        <section>
          <h3 class="text-[15px] font-bold text-strong">Problems · {length(@problems)}</h3>
          <div id="checks-drawer-problems" class="mt-3 space-y-4">
            <.finding :for={finding <- @problems} finding={finding} trip_labels={@trip_labels} />
            <p :if={@problems == []} class="text-sm text-muted">None on this service day.</p>
          </div>
        </section>

        <section class="border-t border-subtle pt-5">
          <h3 class="text-[15px] font-bold text-strong">Notices · {length(@notices)}</h3>
          <div id="checks-drawer-notices" class="mt-3 space-y-4">
            <.finding :for={finding <- @notices} finding={finding} trip_labels={@trip_labels} />
            <p :if={@notices == []} class="text-sm text-muted">None on this service day.</p>
          </div>
        </section>
      </.drawer_scroll>
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
      class={["rounded-card border-l-4 bg-white py-1 pl-3", severity_border(@finding.severity)]}
    >
      <div class="flex flex-wrap items-center gap-x-3 gap-y-0">
        <.code_badge code={@finding.code} />
        <button
          :if={@finding.block_id}
          data-role="blocks-finding-block"
          type="button"
          phx-click="open_block"
          phx-value-block={@finding.block_id}
          class={link_class()}
        >
          Open block {@finding.block_id}
        </button>
      </div>

      <p class="mt-1 text-sm">{finding_detail(@finding)}</p>

      <p :if={@finding.trip_ids != []} class="mt-0.5 flex flex-wrap gap-x-3 text-sm">
        <span :for={uuid <- @finding.trip_ids} data-role="blocks-finding-trip">
          <%= if label = @trip_labels[uuid] do %>
            <button
              type="button"
              phx-click="open_trip"
              phx-value-trip={label}
              class={[link_class(), "-ml-1"]}
            >
              Open trip {label}
            </button>
          <% else %>
            <span class="text-muted">{uuid}</span>
          <% end %>
        </span>
      </p>
    </div>
    """
  end

  @doc """
  Renders the Peak drawer: the figure, the definition, a bar per 15-minute bin,
  the same bins as a table and the count of trips the figure leaves out.
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
      chrome="planner"
      open={@open}
      title="Peak vehicles out"
      return_focus_id="blocks-summary-counts-item-peak"
      class="max-w-[520px]"
    >
      <:lede>Whole service day</:lede>

      <.drawer_scroll>
        <div>
          <p class="font-display text-[32px] font-semibold leading-none text-strong">
            {@peak.count}
            <span :if={@peak.at_secs} class="text-base font-normal text-muted">
              at {clock(@peak.at_secs)}
            </span>
          </p>
          <p class="mt-2 text-sm text-muted">
            Blocks in progress, including the time they wait between trips. It leaves out
            unassigned and repeating trips, and it isn't a fleet requirement.
          </p>
        </div>

        <div :if={@bins != []}>
          <div
            id="peak-chart"
            role="img"
            aria-label={peak_chart_label(@peak, @bins, @axis)}
            class="flex h-32 items-end gap-px border-b border-control"
          >
            <i
              :for={bar <- @bars}
              id={"peak-bin-bar-#{bar.start_secs}"}
              style={"height: #{bar.height}%"}
              class={[
                "block min-w-0 flex-1",
                if(bar.count == @peak.count, do: "bg-default", else: "bg-navy-300")
              ]}
              title={"#{clock(bar.start_secs)} · #{bar.count}"}
            >
            </i>
          </div>
          <div class="mt-1 flex justify-between text-xs tabular-nums text-muted">
            <span>{clock(List.first(@bins).start_secs)}</span>
            <span>{clock(List.last(@bins).start_secs + 900)}</span>
          </div>

          <details class="mt-4">
            <summary class="flex min-h-11 cursor-pointer items-center text-sm font-[650] text-action">
              Show the numbers by 15 minutes
            </summary>
            <table id="peak-bins" class="mt-1 w-full text-sm">
              <caption class="sr-only">Vehicles out per 15-minute bin</caption>
              <thead>
                <tr class="bg-canvas text-left text-[13px] text-muted">
                  <th scope="col" class="px-3 py-2 font-semibold">From</th>
                  <th scope="col" class="px-3 py-2 text-right font-semibold">Vehicles out</th>
                </tr>
              </thead>
              <tbody class="divide-y divide-subtle/60">
                <tr :for={bar <- @bars} id={"peak-bin-#{bar.start_secs}"} data-role="peak-bin">
                  <td class="px-3 py-1.5 tabular-nums">{clock(bar.start_secs)}</td>
                  <td class="px-3 py-1.5 text-right tabular-nums">{bar.count}</td>
                </tr>
              </tbody>
            </table>
          </details>
        </div>

        <p :if={@bins == []} id="peak-bins-empty" class="text-sm text-muted">
          No block has timed trips on this service day, so there is no peak to show.
        </p>

        <p id="peak-exclusions" class="rounded-card bg-canvas p-3 text-sm text-muted">
          Left out: {count_label(@peak.excluded_unassigned, "unassigned trip", "unassigned trips")} and {count_label(
            @peak.excluded_frequency,
            "repeating trip",
            "repeating trips"
          )}. Trips with missing times are left out too.
        </p>
      </.drawer_scroll>
    </.drawer>
    """
  end

  @doc """
  Renders the Minimum layover drawer (AC-28, D5): the one value every short
  layover warning on this version is measured against.

  The field is the context's own changeset, so the label, the sentence the value
  applies to and the field error all sit together and the error text is the
  context's (the page never re-derives the 0–120 rule). The form validates as the
  reader types — the fixed event list names no separate validation event, so its
  `phx-change` is the drawer's own `open_drawer` event, which re-derives this
  drawer's state from the payload (CR-8) — and the submit saves through
  `Gtfs.update_blocking_settings/3`. Closing the drawer returns focus to the
  link that opened it.
  """
  attr :open, :boolean, required: true
  attr :form, :any, required: true
  attr :error, :string, default: nil

  def layover_drawer(assigns) do
    ~H"""
    <.drawer
      id="layover-drawer"
      chrome="planner"
      open={@open}
      title="Minimum layover"
      initial_focus={:first_field}
      initial_focus_id="layover-minutes"
      return_focus_id="blocks-min-layover"
      class="max-w-[520px]"
    >
      <:lede>Applies to every service day in this version</:lede>

      <.form
        for={@form}
        id="layover-form"
        novalidate
        phx-change="open_drawer"
        phx-debounce="200"
        phx-submit="save_layover"
        class="flex min-h-0 flex-1 flex-col"
      >
        <.drawer_scroll>
          <.input
            id="layover-minutes"
            field={@form[:min_layover_minutes]}
            type="number"
            min={0}
            max={120}
            step={1}
            label="Minimum layover (minutes)"
            help="Flag connections shorter than this. A short connection between two trips shows as a warning in Checks. Changing it re-checks every block."
            class="w-full input input-lg max-w-40"
          />

          <p :if={@error} id="layover-error" role="alert" class="text-sm font-semibold text-error-fg">
            {@error}
          </p>
        </.drawer_scroll>

        <.drawer_footer>
          <.button
            type="button"
            id="layover-cancel"
            variant="secondary"
            class="min-h-11"
            phx-click="close_drawer"
          >
            Cancel
          </.button>
          <.button type="submit" id="layover-submit" class="min-h-11" phx-disable-with="Saving…">
            Save minimum
          </.button>
        </.drawer_footer>
      </.form>
    </.drawer>
    """
  end

  @doc """
  Renders the read-only trip drawer: the trip's identity, its stored times and
  block, every service day it runs in with the all-dates scope sentence, its own
  findings and every type 4/5 record naming it.

  The service-day links patch `day` and `trip`, so one link follows the trip to
  another day's page with the drawer open again (AC-29). The record list is
  read-only and holds every record that names the trip, including one whose pair
  has no hosting gap (AC-25, INV-3). A repeating trip carries the repeat text and
  one with missing times its warning; neither can be plotted.

  A trip opened from the block drawer keeps that block in the URL and prints
  “Back to block <id>”, which returns to the block drawer (step 24).
  """
  attr :open, :boolean, required: true
  attr :trip, :map, required: true
  attr :routes, :map, required: true
  attr :version_id, :string, required: true
  attr :calendar_label, :string, required: true
  attr :day_types, :list, required: true
  attr :findings, :list, required: true
  attr :in_seat, :list, required: true
  attr :back_block, :string, default: nil
  attr :assign, :map, default: nil
  attr :assign_form, :any, default: nil
  attr :destination_options, :list, default: []
  attr :destination_total, :integer, default: 0

  def trip_drawer(assigns) do
    assigns =
      assigns
      |> assign(:total_dates, Enum.sum(Enum.map(assigns.day_types, & &1.date_count)))
      |> assign(:title, trip_title(assigns.trip))

    ~H"""
    <.drawer
      id="trip-drawer"
      chrome="planner"
      open={@open}
      title={@title}
      return_focus_id={"trip-bar-" <> dom_token(@trip.trip_id)}
      class="max-w-[520px]"
    >
      <:lede>Trip {@trip.trip_id}{if not @trip.plottable?, do: " · time missing"}</:lede>

      <.drawer_scroll>
        <div class="flex flex-wrap items-center gap-2">
          <.route_badge_for route_id={@trip.route_id} routes={@routes} />
          <strong class="text-strong">{route_name(@routes, @trip.route_id)}</strong>
          <.finding_badge
            :if={@trip.frequency?}
            tone={:info}
            icon="hero-arrow-path"
            label="Repeating service"
          />
        </div>

        <dl class="divide-y divide-subtle/70 border-y border-subtle/70 text-sm">
          <.trip_field label="Departs">
            <strong>{clock(@trip.first_departure)}</strong> · {stop_name(@trip.first_stop)}
          </.trip_field>
          <.trip_field label="Arrives">
            <strong>{clock(@trip.last_arrival)}</strong> · {stop_name(@trip.last_stop)}
          </.trip_field>
          <.trip_field label="Headsign">{blank_dash(@trip.trip_headsign)}</.trip_field>
          <.trip_field label="Pattern">{blank_dash(@trip.route_pattern_id)}</.trip_field>
          <.trip_field label="Calendar">{@calendar_label}</.trip_field>
          <.trip_field label="Block">{@trip.block_id || "Unassigned"}</.trip_field>
          <.trip_field label="GTFS trip ID">
            <span class="font-mono text-[13px]">{@trip.trip_id}</span>
          </.trip_field>
          <.trip_field label="GTFS time">
            <span class="font-mono text-[13px]">
              {gtfs_time(@trip.first_departure)} → {gtfs_time(@trip.last_arrival)}
            </span>
          </.trip_field>
        </dl>

        <.message
          :if={@trip.frequency?}
          id="trip-frequency"
          kind="info"
          title={frequency_title(@trip)}
        >
          This view can't check the vehicle work of a repeating trip. An imported block can still
          be removed.
        </.message>

        <.message
          :if={not @trip.plottable?}
          id="trip-unplottable"
          kind="warning"
          title="A time is missing."
        >
          This trip stays in your data, but it can't be drawn or assigned until its times are
          restored.
          <.link
            id="trip-schedules-link"
            navigate={schedules_path(@version_id, @trip)}
            class="font-[650] underline underline-offset-4"
          >
            Fix times in Schedules
          </.link>
        </.message>

        <.drawer_section id="trip-day-types" title="Service days">
          <p class="text-sm">
            This trip runs on {@total_dates} days, in {if length(@day_types) == 1,
              do: "this service day",
              else: "these service days"}:
          </p>
          <div class="mt-2 divide-y divide-subtle/70 border-y border-subtle/70">
            <.link
              :for={day_type <- @day_types}
              patch={day_type_trip_path(@version_id, day_type.key, @trip.trip_id)}
              data-role="trip-day-type"
              data-day={day_type.key}
              class={[link_class(), "w-full justify-between font-medium"]}
            >
              {day_type_option_label(day_type)}
              <.icon name="hero-chevron-right" class="size-4 shrink-0" />
            </.link>
          </div>
          <p :if={@day_types == []} class="mt-2 text-sm text-muted">
            This trip has no active service dates.
          </p>
          <p class="mt-2 text-[13px] text-muted">
            A block assignment belongs to the trip, so a change applies on all {@total_dates} days it runs.
          </p>
        </.drawer_section>

        <.drawer_section :if={@findings != []} title="Checks">
          <div class="space-y-2">
            <p
              :for={finding <- @findings}
              data-role="trip-finding"
              data-code={finding.code}
              class="flex flex-wrap items-center gap-2 text-sm"
            >
              <.code_badge code={finding.code} />
              <span>{finding_detail(finding)}</span>
            </p>
          </div>
        </.drawer_section>

        <.drawer_section id="trip-transfers" title={"Stay-on-board records · #{length(@in_seat)}"}>
          <div class="space-y-3">
            <div
              :for={entry <- @in_seat}
              data-role="trip-transfer"
              data-transfer-type={entry.row.transfer_type}
              class="border-l-4 border-subtle pl-3"
            >
              <div class="flex flex-wrap items-center gap-2">
                <strong class="text-sm">{transfer_type_label(entry.row.transfer_type)}</strong>
                <.finding_badge
                  tone={transfer_state_tone(entry.state)}
                  label={transfer_state_label(entry.state)}
                />
              </div>
              <p class="text-sm">Trip {entry.row.from_trip_id} → {entry.row.to_trip_id}</p>
              <p data-role="trip-transfer-state" class="text-[13px] text-muted">
                {in_seat_state_text(entry.state)}
              </p>
            </div>
          </div>
          <p :if={@in_seat == []} class="text-sm text-muted">
            No stay-on-board records mention this trip.
          </p>
        </.drawer_section>

        <%!-- The trip's own assign controls: a blocked trip can be removed from its
        block, and any eligible trip can open the destination picker in this drawer
        (step 25). An ineligible trip keeps “Remove from block” only, because an
        assignment needs usable times and a single trip (R10). Opening the picker
        hands the drawer's one primary to its Save assignment. --%>
        <div
          :if={@trip.block_id || eligible?(@trip)}
          class="flex flex-wrap justify-end gap-2 border-t border-subtle pt-5"
        >
          <.button
            :if={@trip.block_id}
            id="trip-unassign"
            type="button"
            variant="secondary"
            class="min-h-11"
            phx-click="unassign"
            phx-value-scope="trip"
            phx-value-trip={@trip.trip_id}
          >
            Remove from block
          </.button>
          <.button
            :if={eligible?(@trip)}
            id="trip-change-assignment"
            type="button"
            variant={if @assign != nil, do: "secondary", else: "primary"}
            class="min-h-11"
            phx-click="open_assign"
            phx-value-scope="trip"
            phx-value-trip={@trip.trip_id}
            aria-expanded={to_string(@assign != nil)}
          >
            {if @trip.block_id, do: "Change assignment", else: "Assign trip"}
          </.button>
        </div>

        <div
          :if={@assign && @assign.scope == :trip && @trip.id in @assign.trip_ids}
          class="rounded-card border border-subtle p-4"
        >
          <.assign_form
            assign={@assign}
            form={@assign_form}
            options={@destination_options}
            total={@destination_total}
            total_dates={@total_dates}
          />
        </div>

        <%!-- “Back to block” is what a trip opened from the block drawer gets; a trip
        opened from a bar or a marker has no block context and no back link. --%>
        <div :if={@back_block} class="border-t border-subtle pt-5">
          <.back_to_block id="trip-back-to-block" block={@back_block} />
        </div>
      </.drawer_scroll>
    </.drawer>
    """
  end

  attr :id, :string, required: true
  attr :block, :string, required: true

  defp back_to_block(assigns) do
    ~H"""
    <.button
      id={@id}
      type="button"
      variant="secondary"
      class="min-h-11"
      phx-click="open_block"
      phx-value-block={@block}
    >
      <.icon name="hero-arrow-left" class="size-4" /> Back to block {@block}
    </.button>
    """
  end

  # A titled section of a drawer body, divided from the one above by a hairline.
  attr :title, :string, required: true
  attr :id, :string, default: nil
  slot :inner_block, required: true

  defp drawer_section(assigns) do
    ~H"""
    <section id={@id} class="border-t border-subtle pt-5">
      <h3 class="text-[15px] font-bold text-strong">{@title}</h3>
      <div class="mt-2">{render_slot(@inner_block)}</div>
    </section>
    """
  end

  @doc """
  Renders the single-trip assignment form: the scope sentence, the “Find a
  block” search, the destination radio list and “Save assignment”.

  The form posts one `submit_assign` after the search has been narrowed by the
  debounced `search_destination` event, so the reader chooses one of at most 25
  matching block IDs instead of scanning the service day (AC-26). “New block” is
  always first because a new ID is resolved under the lock before the review; an
  exact match leads the results; a blocked trip also offers “No block”, which
  removes it. A failed save keeps the chosen radio checked and prints the
  sentence in `#assign-error`, and an ineligible trip is named instead of being
  silently dropped (FH-18).

  A trip's form carries its own Save assignment. The selection's form sits in a
  dialog whose footer submits it (`confirm_form`), so it renders none.
  """
  attr :assign, :map, required: true
  attr :form, :any, required: true
  attr :options, :list, required: true
  attr :total, :integer, required: true
  attr :total_dates, :integer, required: true

  def assign_form(assigns) do
    assigns =
      assign(assigns,
        trip_count: length(assigns.assign.trip_ids),
        ineligible: ineligible_trips(assigns.assign),
        search_summary: destination_summary(assigns.options, assigns.total)
      )

    ~H"""
    <%!-- The change event belongs to the form, not to the search input: LiveView
    serialises an input-level change with only that input's own name, so a
    re-render after a search would reset the chosen radio. A form-level event
    carries the destination and the narrowed search together (AC-26). --%>
    <.form
      for={@form}
      id="assign-form"
      phx-change="search_destination"
      phx-debounce="200"
      phx-submit="submit_assign"
      class="grid gap-4 text-default"
    >
      <p class="text-sm text-muted">
        {count_label(@trip_count, "trip", "trips")} · applies on {@total_dates} days
      </p>

      <.input
        id="destination-search"
        field={@form[:search]}
        type="search"
        label="Find a block"
        placeholder="Search block ID"
        autocomplete="off"
        help="Choose an existing block or start a new one. We don't check that trips suit the same vehicle."
      />

      <%!-- An ineligible trip is named with its own reason, never skipped
      silently (FH-18). A selection gets its own message: the reason per trip
      and “Use eligible trips”, which drops the ineligible trips and keeps the
      dialog open on what remains (AC-24). --%>
      <.message
        :if={@ineligible != []}
        id={ineligible_callout_id(@assign)}
        kind="warning"
        title={ineligible_title(@assign, @ineligible)}
      >
        <ul :if={@assign.scope == :selection} class="list-disc pl-5">
          <li :for={trip <- @ineligible} data-role="ineligible-trip" data-trip={trip.trip_id}>
            {trip.trip_id} · {bulk_ineligibility_reason(trip)}
          </li>
        </ul>
        <p>No trips will change until every selected trip can be assigned.</p>
        <button
          :if={@assign.scope == :selection}
          id="bulk-use-eligible"
          type="button"
          phx-click="open_assign"
          phx-value-scope="selection"
          phx-value-eligible="true"
          class="mt-1 inline-flex min-h-11 items-center font-[650] underline underline-offset-4"
        >
          Use eligible trips
        </button>
      </.message>

      <fieldset>
        <legend class="mb-2 text-[13px] font-[650] text-strong">Destination block</legend>
        <div class={["grid gap-2", @assign.scope == :selection && "sm:grid-cols-2"]}>
          <label class={destination_card_class()}>
            <input
              type="radio"
              id="destination-new"
              name={@form[:destination].name}
              value="new"
              checked={@assign.target in [nil, :new]}
              class="size-4 accent-action"
            />
            <span>
              <span class="text-sm font-[650] text-strong">New block</span>
              <span class="block text-[13px] text-muted">
                We pick the next free number. The review shows it.
              </span>
            </span>
          </label>

          <label
            :for={option <- @options}
            data-role="destination-option"
            data-block={option.block_id}
            class={destination_card_class()}
          >
            <input
              type="radio"
              id={"destination-block-" <> dom_token(option.block_id)}
              name={@form[:destination].name}
              value={option.block_id}
              checked={@assign.target == option.block_id}
              class="size-4 accent-action"
            />
            <span>
              <span class="text-sm font-[650] text-strong">Block {option.block_id}</span>
              <span class="block text-[13px] text-muted">{option.detail}</span>
            </span>
          </label>

          <label
            :if={@assign.blocked?}
            data-role="destination-option"
            data-block="none"
            class={destination_card_class()}
          >
            <input
              type="radio"
              id="destination-none"
              name={@form[:destination].name}
              value="none"
              checked={@assign.target == :none}
              class="size-4 accent-action"
            />
            <span>
              <span class="text-sm font-[650] text-strong">No block</span>
              <span class="block text-[13px] text-muted">Take the trips off their block.</span>
            </span>
          </label>
        </div>
        <p id="destination-summary" class="mt-2 text-[13px] text-muted" role="status">
          {@search_summary}
        </p>
      </fieldset>

      <p id="assign-error" class="text-sm font-semibold text-error-fg" role="alert">
        {@assign.error}
      </p>

      <p class="text-[13px] text-muted">
        The assignment follows the trips across all their days. You'll review anything that adds
        problems before it saves.
      </p>

      <div :if={@assign.scope == :trip} class="flex justify-end">
        <.button type="submit" class="min-h-11" phx-disable-with="Saving…">Save assignment</.button>
      </div>
    </.form>
    """
  end

  # A whole-card radio target, selected with the design system's selection ground.
  defp destination_card_class do
    "flex min-h-11 cursor-pointer items-center gap-3 rounded-control border border-subtle px-3 py-2 has-[:checked]:border-action has-[:checked]:bg-selection"
  end

  @doc """
  Renders the selection-scoped assignment form in a dialog.

  A selection of trips has no single trip drawer to hold the form, so the bulk
  bar opens it here: the same `assign_form/1` with the selection's trip count and
  affected days. The dialog's footer submits the form (`confirm_form`), and
  closing it through “Cancel” or the backdrop fires `close_drawer`, which drops
  the selection-scoped form and leaves the selection untouched.
  """
  attr :assign, :map, required: true
  attr :form, :any, required: true
  attr :options, :list, required: true
  attr :total, :integer, required: true
  attr :total_dates, :integer, required: true

  def assign_dialog(assigns) do
    ~H"""
    <.confirm_dialog
      id="bulk-assign-dialog"
      chrome="planner"
      open={true}
      title="Assign selected trips"
      confirm_label="Save assignment"
      pending_label="Saving…"
      on_confirm="submit_assign"
      on_cancel="close_drawer"
      confirm_form="assign-form"
      cancel_label="Cancel"
      size="xl"
      return_focus_id="bulk-assign"
    >
      <.assign_form
        assign={@assign}
        form={@form}
        options={@options}
        total={@total}
        total_dates={@total_dates}
      />
    </.confirm_dialog>
    """
  end

  @doc """
  Renders the block-change review: the service day and version, the preview
  counts, the assignment changes table and one effect card per affected service
  day with its added problems, plus the existing problems and new notices.

  The dialog is the `confirm_dialog` review surface, so the confirm label repeats
  the verb and its object (“Assign 1 trip”) and the cancel action names the way
  back (“Change block”, “Change name”, “Keep trips”), which returns to the form
  with its target. A stale confirmation prints “Trips changed since you
  reviewed.” above the refreshed review and never saves; a failed save prints its
  own sentence above the unchanged review, so a retry repeats exactly the
  reviewed command (AC-12, AC-26).
  """
  attr :review, :map, default: nil
  attr :stale?, :boolean, default: false
  attr :error, :string, default: nil
  attr :day_type, :map, default: nil
  attr :version_name, :string, default: nil
  attr :return_focus_id, :string, default: "trip-change-assignment"

  def review_dialog(assigns) do
    assigns =
      assign(assigns,
        confirm_label: confirm_label(assigns.review),
        cancel_label: cancel_label(assigns.review),
        notices: added_notices(assigns.review),
        existing: existing_problem_count(assigns.review)
      )

    ~H"""
    <.confirm_dialog
      id="block-review"
      chrome="planner"
      open={@review != nil}
      title="Review before saving"
      confirm_label={@confirm_label}
      pending_label="Saving…"
      on_confirm="confirm_review"
      on_cancel="cancel_review"
      cancel_label={@cancel_label}
      described_by="block-review-body"
      size="xl"
      return_focus_id={@return_focus_id}
      data-initial-focus-id="block-review-changes"
    >
      <div :if={@review} class="grid gap-4 text-default">
        <.message
          :if={@stale?}
          id="block-review-stale"
          kind="warning"
          title="Trips changed since you reviewed."
        >
          Check the changes again. Nothing was saved.
        </.message>

        <.message :if={@error} id="block-review-error" kind="error" title={@error}>
          Your choices are kept. Try again.
        </.message>

        <div class="flex flex-wrap items-center justify-between gap-2">
          <p class="text-sm text-muted">
            {(@day_type && @day_type.label) || "Service day"} · {@version_name}
          </p>
          <.finding_badge tone={:warning} label="Preview · not saved" />
        </div>

        <div class="grid grid-cols-3 gap-3 rounded-card bg-canvas p-3">
          <.review_metric value={length(@review.changes)} label="trips change block" />
          <.review_metric value={@review.affected_date_count} label="service days affected" />
          <.review_metric
            value={@review.added_problem_count}
            label="new problems"
            tone={if @review.added_problem_count > 0, do: "text-error-fg", else: "text-strong"}
          />
        </div>

        <div>
          <h3
            id="block-review-changes"
            tabindex="-1"
            class="text-[15px] font-bold text-strong focus-visible:outline-none"
          >
            Assignment changes
          </h3>
          <div class="mt-2 max-h-56 overflow-auto rounded-card border border-subtle">
            <table id="block-review-changes-table" class="w-full text-sm">
              <thead class="sticky top-0 bg-canvas text-left text-[13px] text-muted">
                <tr>
                  <th scope="col" class="px-3 py-2 font-semibold">Trip</th>
                  <th scope="col" class="px-3 py-2 font-semibold">Current block</th>
                  <th scope="col" class="px-3 py-2 font-semibold">New block</th>
                </tr>
              </thead>
              <tbody class="divide-y divide-subtle/60">
                <tr :for={change <- @review.changes}>
                  <td class="px-3 py-1.5">{change.trip.trip_id}</td>
                  <td class="px-3 py-1.5">{change.from || "Unassigned"}</td>
                  <td class="px-3 py-1.5 font-bold text-strong" data-role="review-proposed">
                    {change.to || "Unassigned"}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>

        <div>
          <h3 class="text-[15px] font-bold text-strong">Service days affected</h3>

          <div class="mt-2 space-y-3">
            <div
              :for={effect <- @review.effects}
              id={"review-effect-" <> effect.day_type.key}
              data-role="review-effect"
              data-selected={to_string(effect.selected?)}
              class="rounded-card border border-subtle px-3.5 py-3 text-sm"
            >
              <p class="font-bold text-strong">
                {if effect.selected?, do: "This service day", else: "Also changes"} · {effect.day_type.label} · {day_count_label(
                  effect.day_type.date_count
                )}
              </p>
              <p class="mt-1">{effect_sentence(effect, @review)}</p>
              <p :for={split <- effect.splits} class="mt-1">
                Block {split.block_id} splits: {split.remaining} {if split.remaining == 1,
                  do: "trip stays",
                  else: "trips stay"} on {split.block_id}.
              </p>
              <p
                :for={finding <- added_problems(effect)}
                data-role="review-added"
                class="mt-1.5 flex flex-wrap items-center gap-2"
              >
                <span class="font-semibold">Added</span>
                <.code_badge code={finding.code} />
                <span>{finding_detail(finding)}</span>
              </p>
              <p :if={added_problems(effect) == []} class="mt-1 text-muted">
                No new timing or transfer problems on these days.
              </p>
            </div>
          </div>
        </div>

        <details class="border-t border-subtle pt-1">
          <summary class="flex min-h-11 cursor-pointer items-center text-sm font-[650] text-action">
            Existing problems and new notices
          </summary>
          <p class="text-sm text-muted">
            {@existing} existing {if @existing == 1, do: "problem stays", else: "problems stay"} on the blocks involved.
          </p>
          <p :for={{label, notice} <- @notices} class="mt-1 text-sm">{label} · {notice}</p>
          <p :if={@notices == []} class="mt-1 text-sm text-muted">No new notices.</p>
        </details>

        <p class="text-[13px] text-muted">
          Trip times, stop order and stay-on-board records don't change.
        </p>
      </div>
    </.confirm_dialog>
    """
  end

  attr :value, :integer, required: true
  attr :label, :string, required: true
  attr :tone, :string, default: "text-strong"

  defp review_metric(assigns) do
    ~H"""
    <div>
      <strong class={["font-display text-[26px] font-semibold leading-none tabular-nums", @tone]}>
        {@value}
      </strong>
      <span class="mt-1 block text-[13px] text-muted">{@label}</span>
    </div>
    """
  end

  @doc """
  Renders the read-only gap drawer: both trips with their times, the layover or
  handoff sentence, the rider note for a handoff a rider can make on foot, and
  any type 4/5 record for the pair.

  The sentence and the note come from the block's own gap and handoff (R5), so the
  drawer re-derives neither a distance nor a handoff kind: a deadhead is the
  only kind that never prints the rider note, and it is the only one that says the
  driving time is not recorded. A negative gap is an overlap, and its drawer prints the
  overlap minutes; the timeline deliberately draws no bar for one, so this drawer
  and the block drawer's own gap note are how an overlapping pair is read (AC-4).

  Anything the pair's record list leaves open is stated rather than left blank,
  and the two “Inspect” buttons open each trip's own drawer with this block kept,
  so the trip drawer can return here through the block.
  """
  attr :open, :boolean, required: true
  attr :from, :map, required: true
  attr :to, :map, required: true
  attr :gap, :map, required: true
  attr :block_id, :string, required: true
  attr :records, :list, required: true
  attr :short?, :boolean, default: false
  attr :back_block, :string, default: nil

  def gap_drawer(assigns) do
    assigns =
      assigns
      |> assign(:text, gap_text(assigns.gap, assigns.from, assigns.to))
      |> assign(:title, gap_title(assigns.gap, assigns.short?))
      |> assign(:note, gap_note(assigns.gap))

    ~H"""
    <.drawer
      id="gap-drawer"
      chrome="planner"
      open={@open}
      title={@title}
      class="max-w-[520px]"
    >
      <:lede>Block {@block_id} · {@from.trip_id} → {@to.trip_id}</:lede>

      <.drawer_scroll>
        <%!-- A layover below the minimum is the block's own :short_layover finding,
        which is also what marks the timeline's gap. --%>
        <.message
          :if={@note}
          id="gap-text"
          data-short={to_string(@short?)}
          kind={gap_kind(@gap, @short?)}
          title={@text}
        >
          {@note}
        </.message>
        <.message
          :if={!@note}
          id="gap-text"
          data-short={to_string(@short?)}
          kind={gap_kind(@gap, @short?)}
          title={@text}
        />

        <dl class="divide-y divide-subtle/70 border-y border-subtle/70 text-sm">
          <.trip_field label="Arrives">
            <strong>{clock(@from.last_arrival)}</strong> · {stop_name(@from.last_stop)}
          </.trip_field>
          <.trip_field label="Next trip departs">
            <strong>{clock(@to.first_departure)}</strong> · {stop_name(@to.first_stop)}
          </.trip_field>
          <.trip_field label="Time between">{gap_between(@gap)}</.trip_field>
        </dl>

        <p :if={rider_note?(@gap)} id="gap-rider-note" class="text-sm">
          Trip planners such as Google Maps may tell riders they can stay on board.
        </p>

        <.drawer_section id="gap-transfers" title={"Stay-on-board records · #{length(@records)}"}>
          <div class="space-y-3">
            <div
              :for={entry <- @records}
              data-role="gap-transfer"
              data-transfer-type={entry.row.transfer_type}
              class="border-l-4 border-subtle pl-3"
            >
              <div class="flex flex-wrap items-center gap-2">
                <strong class="text-sm">{transfer_type_label(entry.row.transfer_type)}</strong>
                <.finding_badge
                  tone={transfer_state_tone(entry.state)}
                  label={transfer_state_label(entry.state)}
                />
              </div>
              <p class="text-sm">Trip {entry.row.from_trip_id} → {entry.row.to_trip_id}</p>
              <p data-role="gap-transfer-state" class="text-[13px] text-muted">
                {in_seat_state_text(entry.state)}
              </p>
            </div>
          </div>
          <p :if={@records == []} class="text-sm text-muted">
            No record for this pair. Whether riders can stay on board depends on the trip planner.
          </p>
        </.drawer_section>

        <div class="flex flex-wrap gap-2 border-t border-subtle pt-5">
          <.button
            :for={trip <- [@from, @to]}
            type="button"
            variant="secondary"
            class="min-h-11"
            data-role="gap-inspect"
            phx-click="open_trip"
            phx-value-trip={trip.trip_id}
            phx-value-block={@back_block}
          >
            Inspect {trip.trip_id}
          </.button>
          <.back_to_block :if={@back_block} id="gap-back-to-block" block={@back_block} />
        </div>
      </.drawer_scroll>
    </.drawer>
    """
  end

  @doc """
  Renders the block drawer: the block's identity, its trip count and span, each
  trip of the block in the block's own order with the gap text between
  consecutive trips and the trip's own findings, then the block's three actions.

  The gap note prints the same sentence as the gap drawer from the block's own
  `gaps/1` pairs, and it is the only way to open that drawer for an overlapping
  pair, whose timeline bar is suppressed; every gap note keeps the block in the
  URL, so both drawers offer “Back to block <id>”. “Inspect” opens the trip drawer
  with the block kept, which is what gives that drawer its back link (AC-25).

  The actions are the reference's “Rename block”, “Merge into…” and “Remove all
  trips” (AC-27). A rename renames this block's trips on the selected service day, a
  merge joins them to another block of the day (the picker offers no “New
  block” and no “No block”, because a merge always lands on an existing ID), and
  remove-all takes this block's trips on the selected service day back to the pool.
  Each one submits the same `submit_block_action` event, so all three run through
  the reviewed command and show the same review dialog with its split, its
  affected service days and its added problems.

  A refusal prints under the control that caused it — the rename field's own
  error sits inside the form, so the input keeps what the reader typed (AC-27) —
  and the rename field starts on the block's own ID, so resubmitting it unchanged
  is the “Enter a different block ID.” case rather than a silent no-op.
  """
  attr :open, :boolean, required: true
  attr :block, :map, required: true
  attr :routes, :map, required: true
  attr :findings_by_trip, :map, required: true

  attr :action, :map,
    default: nil,
    doc: "the drawer's action state, nil while the drawer is closed"

  attr :form, :any, default: nil, doc: "the rename field's and merge search's form"

  attr :merge_options, :list,
    default: [],
    doc: "the other blocks of the service day the picker offers"

  attr :merge_total, :integer, default: 0, doc: "the merge search's match count before the cap"

  def block_drawer(assigns) do
    assigns =
      assigns
      |> assign(:summary, assigns.block.summary)
      |> assign(:rows, block_trip_rows(assigns.block))

    ~H"""
    <.drawer
      id="block-drawer"
      chrome="planner"
      open={@open}
      title={"Block " <> @summary.block_id}
      class="max-w-[520px]"
    >
      <:lede>
        {count_label(@summary.trip_count, "trip", "trips")} · {clock(@summary.start_secs)}–{clock(
          @summary.end_secs
        )}{if @summary.hours, do: " · #{hours(@summary.hours)} h"}
      </:lede>

      <.drawer_scroll>
        <section>
          <h3 class="text-[15px] font-bold text-strong">Trips in order</h3>
          <div class="mt-1 divide-y divide-subtle/70">
            <div :for={row <- @rows} class="py-3">
              <button
                :if={row.gap}
                type="button"
                data-role="block-gap"
                data-minutes={div(row.gap.gap_secs, 60)}
                phx-click="open_gap"
                phx-value-from={row.gap.from_id}
                phx-value-to={row.gap.to_id}
                phx-value-block={@summary.block_id}
                class={[
                  "mb-2 flex min-h-11 w-full items-center gap-2 rounded-control border border-subtle bg-canvas px-3 text-left text-sm hover:bg-white",
                  gap_note_tone(row.gap, row.short?)
                ]}
              >
                <.icon name={gap_note_icon(row.gap)} class="size-4 shrink-0" />
                <span class="min-w-0">{gap_text(row.gap, row.from, row.trip)}</span>
              </button>

              <div class="flex flex-wrap items-center gap-2">
                <.route_badge_for route_id={row.trip.route_id} routes={@routes} />
                <strong class="text-sm tabular-nums text-strong">
                  {trip_span(row.trip)}
                </strong>
                <button
                  type="button"
                  data-role="block-inspect"
                  phx-click="open_trip"
                  phx-value-trip={row.trip.trip_id}
                  phx-value-block={@summary.block_id}
                  class={link_class()}
                >
                  Inspect {row.trip.trip_id}
                </button>
              </div>

              <p class="text-sm text-muted">
                {stop_name(row.trip.first_stop)} → {stop_name(row.trip.last_stop)}
              </p>

              <div class="mt-1.5">
                <.issue_badges findings={Map.get(@findings_by_trip, row.trip.id, [])} />
              </div>
            </div>
          </div>
        </section>

        <section class="border-t border-subtle pt-5">
          <h3 class="text-[15px] font-bold text-strong">Change this block</h3>

          <.form
            for={@form}
            id="block-rename-form"
            phx-submit="submit_block_action"
            class="mt-3 grid gap-2"
          >
            <input type="hidden" name="block_action[action]" value="rename" />
            <.input
              id="block-rename-id"
              field={@form[:block_id]}
              label="Block ID"
              errors={rename_errors(@action)}
              help="The ID stored in your feed (GTFS block_id). Blocks on different service days can share an ID."
              class="w-full input input-lg max-w-56"
            />
            <div>
              <.button
                type="submit"
                id="block-rename-submit"
                variant="secondary"
                class="min-h-11"
              >
                Rename block
              </.button>
            </div>
          </.form>

          <.form
            for={@form}
            id="block-merge-form"
            phx-change="search_destination"
            phx-debounce="200"
            phx-submit="submit_block_action"
            class="mt-5 grid gap-2 border-t border-subtle pt-5"
          >
            <input type="hidden" name="block_action[action]" value="merge" />
            <.input
              id="block-merge-search"
              field={@form[:search]}
              type="search"
              label="Merge into another block"
              placeholder="Search block ID"
              autocomplete="off"
              help={"All #{count_label(@summary.trip_count, "trip", "trips")} join the block you choose. A merge never creates an ID."}
            />

            <fieldset>
              <legend class="sr-only">Merge into</legend>
              <div class="space-y-2">
                <label
                  :for={option <- @merge_options}
                  data-role="merge-option"
                  data-block={option.block_id}
                  class={destination_card_class()}
                >
                  <input
                    type="radio"
                    id={"block-merge-" <> dom_token(option.block_id)}
                    name="block_action[destination]"
                    value={option.block_id}
                    checked={@action.merge == option.block_id}
                    class="size-4 accent-action"
                  />
                  <span>
                    <span class="text-sm font-[650] text-strong">Block {option.block_id}</span>
                    <span class="block text-[13px] text-muted">{option.detail}</span>
                  </span>
                </label>
              </div>
              <p id="block-merge-summary" class="pt-2 text-[13px] text-muted" role="status">
                {destination_summary(@merge_options, @merge_total)}
              </p>
            </fieldset>

            <p
              :if={@action.kind == :merge}
              id="block-merge-error"
              class="text-sm font-semibold text-error-fg"
              role="alert"
            >
              {@action.error}
            </p>

            <div>
              <.button type="submit" id="block-merge-submit" variant="secondary" class="min-h-11">
                Merge blocks
              </.button>
            </div>
          </.form>

          <div class="mt-5 border-t border-subtle pt-5">
            <.button
              type="button"
              id="block-remove-all"
              variant="secondary"
              class="min-h-11"
              phx-click="submit_block_action"
              phx-value-action="remove_all"
            >
              Remove all trips
            </.button>
            <p class="mt-2 text-[13px] text-muted">
              Puts {count_label(@summary.trip_count, "trip", "trips")} back in Unassigned trips.
              You'll review the effect first.
            </p>
            <p
              :if={@action.kind == :remove_all}
              id="block-remove-error"
              class="mt-1 text-sm font-semibold text-error-fg"
              role="alert"
            >
              {@action.error}
            </p>
          </div>
        </section>
      </.drawer_scroll>
    </.drawer>
    """
  end

  # The rename field's own error: the sentence the context's refusal maps to, so
  # it sits under the input it belongs to (AC-27). The merge's own error has no
  # field of its own and prints under the picker instead.
  defp rename_errors(%{kind: :rename, error: error}) when is_binary(error), do: [error]
  defp rename_errors(_action), do: []

  # The block drawer's rows: the block's own trip order with the gap that precedes
  # each trip, taken from the block's `gaps/1` pairs by the later trip's UUID and
  # kept only when the two trips are adjacent in that order, so a gap note always
  # sits between the two trips it joins (and the first trip has none). A gap the
  # block's own finding calls short reads in the warning colour.
  defp block_trip_rows(block) do
    gaps = Map.new(block.gaps, &{&1.to_id, &1})
    short_pairs = short_layover_pairs(block.findings)
    trips = block.trips

    trips
    |> Enum.with_index()
    |> Enum.map(fn {trip, index} ->
      previous = if index == 0, do: nil, else: Enum.at(trips, index - 1)
      gap = if previous, do: Map.get(gaps, trip.id)
      gap = if gap && gap.from_id == previous.id, do: gap

      %{
        trip: trip,
        from: if(gap, do: previous),
        gap: gap,
        short?: gap != nil and MapSet.member?(short_pairs, MapSet.new([gap.from_id, gap.to_id]))
      }
    end)
  end

  # A trip's times in the block drawer, or the reason it has none.
  defp trip_span(%{plottable?: true} = trip),
    do: "#{clock(trip.first_departure)}–#{clock(trip.last_arrival)}"

  defp trip_span(_trip), do: "Time missing"

  defp gap_note_tone(%{gap_secs: secs}, _short?) when secs < 0, do: "font-semibold text-error-fg"
  defp gap_note_tone(_gap, true), do: "font-semibold text-warning-fg"
  defp gap_note_tone(_gap, false), do: "text-default"

  defp gap_note_icon(%{gap_secs: secs}) when secs < 0, do: "hero-x-circle"
  defp gap_note_icon(%{handoff: {:moves, _meters}}), do: "hero-arrow-up-right"
  defp gap_note_icon(_gap), do: "hero-clock"

  # Copy: the layover at one stop, the same station, a nearby stop with its
  # distance and the time available, or the deadhead, which alone says the
  # driving time is not recorded (and, without coordinates, that there are none).
  defp gap_text(%{gap_secs: secs}, _from, _to) when secs < 0,
    do: "#{minutes(-secs)} overlap"

  defp gap_text(%{handoff: :same_stop, gap_secs: secs}, _from, to),
    do: "#{minutes(secs)} layover at #{stop_name(to.first_stop)}"

  defp gap_text(%{handoff: :same_station, gap_secs: secs}, from, _to),
    do: "Same station · #{minutes(secs)} at #{station_name(from.last_stop)}"

  defp gap_text(%{handoff: {:nearby, meters}, gap_secs: secs}, _from, _to),
    do: "Nearby stop · #{meters} m · #{minutes(secs)} available"

  defp gap_text(%{handoff: {:moves, nil}}, from, to),
    do: move_text(from, to, " (no coordinates)")

  defp gap_text(%{handoff: {:moves, _meters}}, from, to), do: move_text(from, to, "")

  defp move_text(from, to, qualifier) do
    "Deadhead from #{stop_name(from.last_stop)} to #{stop_name(to.first_stop)}. " <>
      "Driving time isn't recorded#{qualifier}."
  end

  # The gap drawer's title names what the gap is, then the message under it says
  # what that means.
  defp gap_title(%{gap_secs: secs}, _short?) when secs < 0, do: "#{minutes(-secs)} overlap"
  defp gap_title(%{gap_secs: secs}, true), do: "Short layover · #{minutes(secs)}"
  defp gap_title(%{handoff: {:moves, _meters}}, _short?), do: "Deadhead between trips"
  defp gap_title(%{gap_secs: secs}, _short?), do: "#{minutes(secs)} between trips"

  defp gap_kind(%{gap_secs: secs}, _short?) when secs < 0, do: "error"
  defp gap_kind(_gap, true), do: "warning"
  defp gap_kind(_gap, false), do: "info"

  defp gap_note(%{gap_secs: secs}) when secs < 0 do
    "The vehicle can't be on both trips at once. Move one of them to another block, or change its times in Schedules."
  end

  defp gap_note(%{handoff: {:moves, _meters}, gap_secs: secs}) do
    "#{minutes(secs)} are available. Driving time isn't recorded, so this view can't say whether the move fits."
  end

  defp gap_note(_gap), do: nil

  defp gap_between(%{gap_secs: secs}) when secs < 0, do: "#{minutes(-secs)} overlap"
  defp gap_between(%{gap_secs: secs}), do: minutes(secs)

  # The station a same-station handoff shares is the stops' parent station; a stop
  # reference carries the parent's ID rather than its name, so the ID stands for
  # the station here.
  defp station_name(%{parent_station: parent})
       when is_binary(parent) and parent != "",
       do: parent

  defp station_name(stop), do: stop_name(stop)

  # The rider note is for a handoff a rider could make on foot: the same stop, the
  # same station or a nearby one. A deadhead never shows it, however short the
  # gap (Copy, FH-19).
  defp rider_note?(%{handoff: :same_stop}), do: true
  defp rider_note?(%{handoff: :same_station}), do: true
  defp rider_note?(%{handoff: {:nearby, _meters}}), do: true
  defp rider_note?(_gap), do: false

  @doc """
  Renders the notice a `trip=` deep link shows when the trip is not in the loaded
  service day: one link per service day the trip runs in, or the unavailable
  sentence when the version holds no such trip (AC-29).
  """
  attr :open, :boolean, required: true
  attr :trip_id, :string, required: true
  attr :day_types, :list, default: nil
  attr :version_id, :string, required: true

  def trip_elsewhere(%{day_types: nil} = assigns) do
    ~H"""
    <.drawer
      id="trip-elsewhere"
      chrome="planner"
      open={@open}
      title={"Trip " <> @trip_id <> " isn't in this version"}
      class="max-w-[520px]"
    >
      <.drawer_scroll>
        <div id="blocks-trip-elsewhere">
          <.message kind="warning" title={"We couldn't find trip #{@trip_id} in this version."}>
            The link may be from another version, or the trip was deleted. Pick a trip from the
            timeline or the unassigned list.
          </.message>
        </div>
      </.drawer_scroll>
    </.drawer>
    """
  end

  def trip_elsewhere(%{day_types: []} = assigns) do
    ~H"""
    <.drawer
      id="trip-elsewhere"
      chrome="planner"
      open={@open}
      title="Trip has no active service dates"
      class="max-w-[520px]"
    >
      <:lede>Trip {@trip_id}</:lede>

      <.drawer_scroll>
        <div id="blocks-trip-elsewhere">
          <.message
            kind="warning"
            title={"Trip #{@trip_id} has no active service dates in this version."}
          >
            Its calendar doesn't run on any day, so it can't be part of a block. Check the
            calendar's dates.
          </.message>
          <.link
            id="trip-elsewhere-calendars"
            navigate={~p"/gtfs/#{@version_id}/calendars"}
            class={[link_class(), "mt-3"]}
          >
            Open Calendars
          </.link>
        </div>
      </.drawer_scroll>
    </.drawer>
    """
  end

  def trip_elsewhere(assigns) do
    ~H"""
    <.drawer
      id="trip-elsewhere"
      chrome="planner"
      open={@open}
      title="Trip runs on another service day"
      class="max-w-[520px]"
    >
      <:lede>Trip {@trip_id}</:lede>

      <.drawer_scroll>
        <div id="blocks-trip-elsewhere">
          <p class="text-sm">
            Trip {@trip_id} isn't part of this service day. Open the service day where it runs to
            see its block.
          </p>
          <div class="mt-3 divide-y divide-subtle/70 border-y border-subtle/70">
            <.link
              :for={day_type <- @day_types}
              patch={day_type_trip_path(@version_id, day_type.key, @trip_id)}
              data-role="trip-day-type"
              data-day={day_type.key}
              class={[link_class(), "w-full justify-between"]}
            >
              {day_type_option_label(day_type)}
              <.icon name="hero-chevron-right" class="size-4 shrink-0" />
            </.link>
          </div>
        </div>
      </.drawer_scroll>
    </.drawer>
    """
  end

  # One definition-list row of the trip drawer, so every field shares the same
  # two-column shape and a long value wraps inside its own column.
  attr :label, :string, required: true
  slot :inner_block, required: true

  defp trip_field(assigns) do
    ~H"""
    <div class="grid grid-cols-[minmax(6.5rem,auto)_1fr] gap-x-4 py-2.5">
      <dt class="text-muted">{@label}</dt>
      <dd class="min-w-0">{render_slot(@inner_block)}</dd>
    </div>
    """
  end

  @doc """
  Renders the Blocks workspace: the work-queue tabs, the Timeline/List and
  Whole day/Zoom in segmented controls, the chart key and the current panel.

  The All blocks tab holds the paged timeline or the paged List view, both over
  the same streamed page of blocks: the timeline is one 44px row per block inside
  a container that scrolls in both axes, and the List view is one stacked trip
  table per block. The Unassigned trips tab holds the paged pool and its “Select
  this page” control. A service day with no blocks shows the first-use panel in
  the All blocks tab and still lists its unassigned trips in the pool.

  A phone-width reader gets the List view rather than the timeline: the two are
  the same page in two densities, and the List view is the full-size control
  surface (Accessibility posture). The colocated hook pushes `set_view` once when
  the URL carries no view; it never patches a URL that already does.

  The page keeps one primary action. `primary` names who holds it: the header's
  Review action, the selection bar's Assign, or, on a day with no blocks, this
  panel's “Choose trips for a block”.
  """
  attr :state, :map, required: true
  attr :counts, :map, required: true
  attr :visible_count, :integer, required: true
  attr :pool_visible_count, :integer, required: true
  attr :page_size, :integer, required: true
  attr :block_rows, :any, required: true
  attr :list_rows, :any, required: true
  attr :pool_rows, :any, required: true
  attr :untimed_trips, :list, required: true
  attr :findings_by_trip, :map, required: true
  attr :axis, :map, default: nil
  attr :routes, :map, required: true
  attr :selected_ids, :any, required: true
  attr :bulk, :map, required: true
  attr :primary, :atom, values: [:head, :bulk, :empty], default: :head

  def workspace(assigns) do
    assigns = assign(assigns, :filtered?, filtered?(assigns.state))

    ~H"""
    <section
      id="blocks-workspace"
      phx-hook=".BlocksViewportDefault"
      class="overflow-hidden rounded-card border border-subtle bg-white"
    >
      <div class="flex flex-wrap items-end justify-between gap-x-6 border-b border-subtle px-2 sm:px-4">
        <div
          id="blocks-tabs"
          role="tablist"
          aria-label="Work queue"
          phx-hook="TablistHook"
          class="flex"
        >
          <.work_tab
            id="panel-blocks"
            panel="blocks"
            label="All blocks"
            count={@counts.blocks}
            current?={@state.panel == :blocks}
          />
          <.work_tab
            id="panel-pool"
            panel="pool"
            label="Unassigned trips"
            count={@counts.unassigned}
            current?={@state.panel == :pool}
          />
        </div>

        <div class="flex flex-wrap items-center gap-3 py-2">
          <.segmented_control
            :if={@state.panel == :blocks and @counts.blocks > 0}
            id="blocks-view"
            name="view"
            legend="Plan view"
            legend_class="sr-only"
            options={[{"Timeline", "timeline"}, {"List", "list"}]}
            value={Atom.to_string(@state.view)}
            event="set_view"
            appearance={:joined}
            emphasis={:strong}
          />
          <.segmented_control
            :if={@state.panel == :blocks and @counts.blocks > 0 and @state.view == :timeline}
            id="blocks-scale"
            name="scale"
            legend="Timeline scale"
            legend_class="sr-only"
            options={[{"Whole day", "day"}, {"Zoom in", "zoom"}]}
            value={Atom.to_string(@state.scale)}
            event="set_scale"
            appearance={:joined}
            emphasis={:strong}
          />

          <%!-- The reference puts “Select this page” beside the pool's tabs and
          in the List view's head, where the controls are large. --%>
          <.button
            :if={select_page?(@state, @counts, @pool_visible_count, @visible_count)}
            id="blocks-select-page"
            type="button"
            variant="secondary"
            class="min-h-11"
            phx-click="select_page"
          >
            Select this page
          </.button>
        </div>
      </div>

      <.chart_key :if={show_chart_key?(@state, @counts, @filtered?, @visible_count)} />

      <%!-- The bar sits between the toolbar and the records, so it stays in view
      while the reader pages through the selection (AC-24, UX obligations). --%>
      <.bulk_bar
        :if={@bulk.count > 0}
        count={@bulk.count}
        elsewhere={@bulk.elsewhere}
        removable?={@bulk.removable?}
      />

      <div
        id="blocks-panel-body"
        role="tabpanel"
        aria-labelledby={"panel-" <> Atom.to_string(@state.panel)}
      >
        <%= cond do %>
          <% @state.panel == :pool -> %>
            <p
              :if={@counts.blocks == 0}
              id="blocks-workspace-guidance"
              class="border-b border-subtle px-4 py-3 text-sm text-muted"
            >
              Start by selecting trips and placing them on a new block.
            </p>

            <.pool
              pool_rows={@pool_rows}
              routes={@routes}
              findings_by_trip={@findings_by_trip}
              route_filter={@state.route}
              total={@pool_visible_count}
              page={@state.pool_page}
              page_size={@page_size}
              version_id={@state.version_id}
              selected_ids={@selected_ids}
            />
          <% @counts.blocks == 0 -> %>
            <.state_panel
              id="blocks-workspace-guidance"
              icon="hero-truck"
              title="No blocks on this service day yet"
            >
              A block is the trips one vehicle works in order. This day has {count_label(
                @counts.unassigned,
                "trip",
                "trips"
              )} with no vehicle. Select trips and place them on a new block.
              <:action>
                <.button
                  id="blocks-choose-trips"
                  type="button"
                  variant={if @primary == :empty, do: "primary", else: "secondary"}
                  class="min-h-11"
                  phx-click="set_panel"
                  phx-value-panel="pool"
                >
                  Choose trips for a block
                </.button>
              </:action>
            </.state_panel>
          <% @filtered? and @visible_count == 0 -> %>
            <.state_panel
              id="blocks-filtered-empty"
              icon="hero-magnifying-glass"
              title="No blocks match these filters"
            >
              {filtered_empty_text(@state)}
              <:action>
                <.button
                  id="blocks-clear-filters"
                  type="button"
                  variant="secondary"
                  class="min-h-11"
                  phx-click="filter"
                  phx-value-route=""
                  phx-value-status="all"
                >
                  Clear filters
                </.button>
              </:action>
            </.state_panel>
          <% @state.view == :timeline -> %>
            <.timeline
              state={@state}
              block_rows={@block_rows}
              axis={@axis}
              routes={@routes}
            />
          <% true -> %>
            <.block_list
              block_rows={@list_rows}
              routes={@routes}
              findings_by_trip={@findings_by_trip}
              route_filter={@state.route}
              selected_ids={@selected_ids}
            />
        <% end %>
      </div>

      <.untimed_list
        :if={@state.panel == :blocks}
        trips={@untimed_trips}
        routes={@routes}
        version_id={@state.version_id}
      />

      <div
        :if={@state.panel == :blocks and @visible_count > 0}
        id="blocks-pager"
        class="border-t border-subtle px-4"
      >
        <.pagination
          page={@state.page}
          per_page={@page_size}
          total={@visible_count}
          entity="blocks"
          event="paginate"
        />
        <p class="max-w-3xl pb-3 text-[13px] text-muted">{workspace_note(@state, @filtered?)}</p>
      </div>

      <div
        :if={@state.panel == :pool and @pool_visible_count > 0}
        id="blocks-pool-pager"
        class="border-t border-subtle px-4"
      >
        <.pagination
          page={@state.pool_page}
          per_page={@page_size}
          total={@pool_visible_count}
          entity="trips"
          event="paginate_pool"
        />
        <p class="max-w-3xl pb-3 text-[13px] text-muted">{workspace_note(@state, @filtered?)}</p>
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

  # A work-queue tab: the design system's local tab, an underline in the action
  # colour with the queue's size beside its name. `TablistHook` supplies the
  # arrow-key behavior and keeps only the current tab in the tab order.
  attr :id, :string, required: true
  attr :panel, :string, required: true
  attr :label, :string, required: true
  attr :count, :integer, required: true
  attr :current?, :boolean, required: true

  defp work_tab(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      role="tab"
      phx-click="set_panel"
      phx-value-panel={@panel}
      aria-selected={to_string(@current?)}
      aria-controls="blocks-panel-body"
      tabindex={if @current?, do: "0", else: "-1"}
      class={[
        "-mb-px flex min-h-12 items-center gap-2 whitespace-nowrap border-b-[3px] px-3.5 text-sm",
        @current? && "border-action font-bold text-action",
        !@current? && "border-transparent font-semibold text-muted hover:text-strong"
      ]}
    >
      {@label}
      <span class={[
        "rounded-badge px-1.5 py-0.5 text-[13px] font-bold tabular-nums",
        if(@current?, do: "bg-selection", else: "bg-canvas")
      ]}>
        {@count}
      </span>
    </button>
    """
  end

  # A panel state inside the workspace card: what belongs here, and the one next
  # step.
  attr :id, :string, required: true
  attr :icon, :string, required: true
  attr :title, :string, required: true
  slot :inner_block, required: true
  slot :action

  defp state_panel(assigns) do
    ~H"""
    <div id={@id} class="px-4 py-14 text-center">
      <span class="mx-auto flex size-12 items-center justify-center rounded-full bg-canvas text-muted">
        <.icon name={@icon} class="size-6" />
      </span>
      <h2 class="mt-4 font-display text-[22px] font-semibold tracking-[-0.025em] text-strong">
        {@title}
      </h2>
      <p class="mx-auto mt-2 max-w-lg text-sm text-muted">{render_slot(@inner_block)}</p>
      <div :if={@action != []} class="mt-6 flex justify-center">{render_slot(@action)}</div>
    </div>
    """
  end

  # The chart key names every mark between trips in words, at its real size: a
  # gap's four states differ by more than colour, and the key is the one place
  # that says so.
  defp chart_key(assigns) do
    ~H"""
    <div
      id="blocks-chart-key"
      class="flex flex-wrap items-center gap-x-5 gap-y-1 border-b border-subtle bg-canvas px-4 py-1.5 text-[13px] text-muted"
    >
      <span class="font-semibold text-strong">Between trips</span>
      <span class="inline-flex items-center gap-1.5">
        <span class="inline-block h-3 w-6 border-b-[3px] border-control"></span> minutes waiting
      </span>
      <span class="inline-flex items-center gap-1.5">
        <span class="inline-flex h-4 w-6 items-center justify-center border-b-[3px] border-warning-line bg-warning-bg text-[11px] font-extrabold text-warning-fg">
          !
        </span>
        short layover
      </span>
      <span class="inline-flex items-center gap-1.5">
        <span class="inline-flex h-3 w-6 items-center justify-center border-b-[3px] border-dashed border-info-line text-info-fg">
          <.icon name="hero-arrow-up-right-mini" class="size-3" />
        </span>
        deadhead (drives empty)
      </span>
      <span class="inline-flex items-center gap-1.5">
        <span class="inline-flex size-4 items-center justify-center rounded-badge bg-white text-error-fg outline outline-2 outline-error-line">
          <.icon name="hero-x-circle-mini" class="size-3" />
        </span>
        overlap
      </span>
      <span class="ml-auto hidden lg:inline">
        Bars are colored by route and labeled with the route number.
      </span>
    </div>
    """
  end

  defp show_chart_key?(state, counts, filtered?, visible_count) do
    state.panel == :blocks and state.view == :timeline and counts.blocks > 0 and
      not (filtered? and visible_count == 0)
  end

  defp filtered_empty_text(%{status: :problems, route: route}) when not is_nil(route),
    do: "No block on this route has a problem on this service day."

  defp filtered_empty_text(%{status: :problems}),
    do: "No block has a problem on this service day."

  defp filtered_empty_text(_state),
    do:
      "No block runs this route on this service day. Try a different route, or show every block."

  @doc """
  Renders the selection bar: the count, how many of the selected trips are on
  another page, and the three bulk actions.

  The count is the whole selection, so a selection that spans pages reports how
  many of its trips the current page does not hold (“2 selected · 1 on other
  pages”) and keeps saying so while the reader pages (AC-24). “Clear selection”
  empties the set; “Assign N trips” opens the selection-scoped assignment form;
  “Remove from block” is offered only when a selected trip has a block, because
  the others are already in the pool (the reference hides it the same way).

  While the bar shows, its Assign is the page's one primary: the header's Review
  action drops to secondary.
  """
  attr :count, :integer, required: true
  attr :elsewhere, :integer, required: true
  attr :removable?, :boolean, required: true

  def bulk_bar(assigns) do
    ~H"""
    <div
      id="blocks-bulk-bar"
      role="region"
      aria-label="Selected trips"
      class="mx-4 my-3 flex flex-wrap items-center justify-between gap-x-4 gap-y-2 rounded-card border border-action/30 bg-selection px-4 py-2"
    >
      <strong id="bulk-count" class="text-sm text-strong">
        {bulk_count_label(@count, @elsewhere)}
      </strong>

      <div class="flex flex-wrap items-center gap-2">
        <.button
          id="bulk-clear"
          type="button"
          variant="secondary"
          class="min-h-11"
          phx-click="clear_selection"
        >
          Clear selection
        </.button>
        <.button
          :if={@removable?}
          id="bulk-remove"
          type="button"
          variant="secondary"
          class="min-h-11"
          phx-click="unassign"
          phx-value-scope="selection"
        >
          Remove from block
        </.button>
        <.button
          id="bulk-assign"
          type="button"
          class="min-h-11"
          phx-click="open_assign"
          phx-value-scope="selection"
        >
          Assign {count_label(@count, "trip", "trips")}
        </.button>
      </div>
    </div>
    """
  end

  # “2 selected · 1 on other pages”; a selection the page holds entirely says
  # only its count.
  defp bulk_count_label(count, 0), do: "#{count} selected"

  defp bulk_count_label(count, elsewhere),
    do: "#{count} selected · #{elsewhere} on other pages"

  # The pool and the List view carry the reference's “Select this page” control
  # where their records are; the timeline has no selection column, so it does
  # not offer it. An empty page has nothing to select, so neither empty state
  # shows the control.
  defp select_page?(%{panel: :pool}, _counts, pool_visible_count, _visible_count),
    do: pool_visible_count > 0

  defp select_page?(%{panel: :blocks, view: :list}, _counts, _pool_visible_count, visible_count),
    do: visible_count > 0

  defp select_page?(_state, _counts, _pool_visible_count, _visible_count), do: false

  @doc """
  Renders the List view: one trip table per streamed block.

  Each table is the block's own trips in the block's order (its plottable,
  non-frequency sequence first, then the trips that cannot be plotted) and names
  itself with the block ID, its trip count and its streamed DOM id, so the List
  view carries the same page of blocks as the timeline (CR-6). It has its own
  stream because a stream renders in one container: the timeline's rows and these
  tables are two densities of one page, and the LiveView fills both together. The
  columns are the reference's Select, Trip, Route, Start, End, From → To, Gap and
  Issues; the route's long name is the trip's secondary line, and the terminal is
  the destination line of the From → To cell.

  The gap is the layover before the trip, from the block's own `gaps/1` pairs, so
  it agrees with the timeline's gap bars; the first trip and every trip outside
  the plottable sequence have none. The Issues cell prints the trip's findings as
  badges, worst first, or “No problems”. Below the `md` breakpoint each row is a
  card: the trip and its select box first, then short values beside their labels.
  """
  attr :block_rows, :any, required: true, doc: "the List view's own stream of the block page"
  attr :routes, :map, required: true
  attr :findings_by_trip, :map, required: true
  attr :route_filter, :string, default: nil
  attr :selected_ids, :any, required: true, doc: "the UUIDs the page has selected"

  def block_list(assigns) do
    ~H"""
    <div id="blocks-lists" phx-update="stream">
      <.block_list_table
        :for={{dom, block} <- @block_rows}
        dom={dom}
        block={block}
        routes={@routes}
        findings_by_trip={@findings_by_trip}
        route_filter={@route_filter}
        selected_ids={@selected_ids}
      />
    </div>
    """
  end

  # One block's own table, with the page's block order and the block's gaps kept
  # in the same DOM id the timeline uses, so both views carry the one stream.
  attr :dom, :string, required: true
  attr :block, :map, required: true
  attr :routes, :map, required: true
  attr :findings_by_trip, :map, required: true
  attr :route_filter, :string, default: nil
  attr :selected_ids, :any, required: true

  defp block_list_table(assigns) do
    assigns =
      assign(assigns,
        summary: assigns.block.summary,
        rows: list_rows(assigns.block, assigns.route_filter),
        gaps: Map.new(assigns.block.gaps, &{&1.to_id, &1}),
        status: status_label(assigns.block.summary)
      )

    ~H"""
    <section id={@dom} class="border-t border-subtle first:border-t-0">
      <div class="flex flex-wrap items-center gap-x-4 gap-y-1 bg-canvas px-4 py-1">
        <h3 class="flex items-center gap-1 text-[15px]">
          Block
          <button
            type="button"
            data-role="list-block"
            phx-click="open_block"
            phx-value-block={@summary.block_id}
            class={[link_class(), "font-bold"]}
          >
            {@summary.block_id}
          </button>
        </h3>
        <span class="text-[13px] text-muted">
          {count_label(@summary.trip_count, "trip", "trips")}{block_span(@summary)}
        </span>
        <span class="ml-auto text-[13px]"><.status_text status={@status} /></span>
      </div>

      <div id={"block-list-" <> @dom <> "-container"} class="overflow-x-auto">
        <table class="w-full min-w-[860px] text-sm max-md:min-w-0 max-md:[&_thead]:hidden max-md:[&_tr]:relative max-md:[&_tr]:grid max-md:[&_tr]:grid-cols-2 max-md:[&_tr]:gap-x-3 max-md:[&_tr]:gap-y-1 max-md:[&_tr]:px-4 max-md:[&_tr]:py-3 max-md:[&_td]:block max-md:[&_td]:px-0 max-md:[&_td]:py-0">
          <thead>
            <tr class="text-left text-[13px] text-muted">
              <th scope="col" class="w-14 px-3 py-2 font-semibold">
                <span class="sr-only">Select</span>
              </th>
              <th scope="col" class="px-3 py-2 font-semibold">Trip</th>
              <th scope="col" class="px-3 py-2 font-semibold">Route</th>
              <th scope="col" class="whitespace-nowrap px-3 py-2 font-semibold">Start</th>
              <th scope="col" class="whitespace-nowrap px-3 py-2 font-semibold">End</th>
              <th scope="col" class="px-3 py-2 font-semibold">From → To</th>
              <th scope="col" class="whitespace-nowrap px-3 py-2 font-semibold">Gap</th>
              <th scope="col" class="px-3 py-2 font-semibold">Issues</th>
            </tr>
          </thead>
          <tbody id={"block-list-" <> @dom} class="divide-y divide-subtle/60">
            <tr :for={trip <- @rows} class="hover:bg-canvas">
              <td class="px-3 max-md:absolute max-md:right-1 max-md:top-0">
                <.select_trip trip={trip} checked={MapSet.member?(@selected_ids, trip.id)} />
              </td>
              <td class="px-3 py-1.5 max-md:col-span-2 max-md:pr-12" data-label="Trip">
                <strong>{trip.trip_id}</strong>
                <small class="block text-[13px] text-muted">
                  {route_name(@routes, trip.route_id)}
                </small>
              </td>
              <td class="px-3 max-md:col-span-2" data-label="Route">
                <.route_badge_for route_id={trip.route_id} routes={@routes} />
              </td>
              <td
                class="px-3 tabular-nums max-md:before:mr-1.5 max-md:before:text-[13px] max-md:before:text-muted max-md:before:content-[attr(data-label)]"
                data-label="Start"
              >
                {clock(trip.first_departure)}
              </td>
              <td
                class="px-3 tabular-nums max-md:before:mr-1.5 max-md:before:text-[13px] max-md:before:text-muted max-md:before:content-[attr(data-label)]"
                data-label="End"
              >
                {clock(trip.last_arrival)}
              </td>
              <td class="px-3 py-1.5 max-md:col-span-2" data-label="From → To">
                <.endpoints trip={trip} />
              </td>
              <td
                class={[
                  "px-3 tabular-nums max-md:before:mr-1.5 max-md:before:text-[13px] max-md:before:text-muted max-md:before:content-[attr(data-label)]",
                  !Map.has_key?(@gaps, trip.id) && "max-md:hidden"
                ]}
                data-label="Gap"
              >
                <%= if gap = Map.get(@gaps, trip.id) do %>
                  <span
                    data-role="list-gap"
                    data-minutes={div(gap.gap_secs, 60)}
                    class={gap.gap_secs < 0 && "font-semibold text-error-fg"}
                  >
                    {gap_label(gap)}
                  </span>
                <% else %>
                  <span class="text-muted">—</span>
                <% end %>
              </td>
              <td class="px-3 py-1.5 max-md:col-span-2" data-label="Issues">
                <.issue_badges findings={Map.get(@findings_by_trip, trip.id, [])} />
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
    """
  end

  # “ · 06:00–15:50 · 9.8 h” after a block's trip count, when it has timed trips.
  defp block_span(%{start_secs: nil}), do: ""

  defp block_span(summary) do
    " · #{clock(summary.start_secs)}–#{clock(summary.end_secs)} · #{hours(summary.hours)} h"
  end

  @doc """
  Renders the paged Unassigned panel: the pool page, its eligibility text and
  its own empty states.

  The columns are the reference's Select, Route / trip, Start → end, From → to,
  Checks and Action. A repeating trip prints “Repeats every N min · not a single
  trip”; a trip whose endpoint time is missing prints “Time missing” with a link
  to its route's Schedules for its calendar; an eligible trip offers “Assign
  trip” (`open_assign`, scope `trip`) where the other two offer “View trip”.

  The two empty states are distinct: a route filter that matches no pool trip
  offers to clear it, while an empty pool without a filter says every trip has a
  block.
  """
  attr :pool_rows, :any, required: true
  attr :routes, :map, required: true
  attr :findings_by_trip, :map, required: true
  attr :route_filter, :string, default: nil
  attr :total, :integer, required: true
  attr :page, :integer, required: true
  attr :page_size, :integer, required: true
  attr :version_id, :string, required: true
  attr :selected_ids, :any, required: true

  def pool(%{total: 0} = assigns) do
    ~H"""
    <.state_panel
      :if={@route_filter}
      id="blocks-pool-filtered-empty"
      icon="hero-magnifying-glass"
      title="No unassigned trips match"
    >
      No trips on this route are waiting for a vehicle on this service day.
      <:action>
        <.button
          id="blocks-pool-clear-filters"
          type="button"
          variant="secondary"
          class="min-h-11"
          phx-click="filter"
          phx-value-route=""
          phx-value-status="all"
        >
          Clear filters
        </.button>
      </:action>
    </.state_panel>

    <div :if={is_nil(@route_filter)} id="blocks-pool-empty" class="px-4 py-14 text-center">
      <span class="mx-auto flex size-12 items-center justify-center rounded-full bg-success-bg text-success-fg">
        <.icon name="hero-check-circle" class="size-6" />
      </span>
      <h2 class="mt-4 font-display text-[22px] font-semibold tracking-[-0.025em] text-strong">
        Every trip has a block
      </h2>
      <p class="mx-auto mt-2 max-w-lg text-sm text-muted">
        Nothing is waiting for a vehicle on this service day.
      </p>
    </div>
    """
  end

  def pool(assigns) do
    ~H"""
    <div class="overflow-x-auto">
      <table class="w-full min-w-[820px] text-sm max-md:min-w-0 max-md:[&_thead]:hidden max-md:[&_tr]:relative max-md:[&_tr]:grid max-md:[&_tr]:grid-cols-2 max-md:[&_tr]:gap-x-3 max-md:[&_tr]:gap-y-1 max-md:[&_tr]:px-4 max-md:[&_tr]:py-3 max-md:[&_td]:block max-md:[&_td]:px-0 max-md:[&_td]:py-0">
        <thead>
          <tr class="bg-canvas text-left text-[13px] text-muted">
            <th scope="col" class="w-14 px-3 py-2.5 font-semibold">
              <span class="sr-only">Select</span>
            </th>
            <th scope="col" class="px-3 py-2.5 font-semibold">Route / trip</th>
            <th scope="col" class="px-3 py-2.5 font-semibold">Start → end</th>
            <th scope="col" class="px-3 py-2.5 font-semibold">From → to</th>
            <th scope="col" class="px-3 py-2.5 font-semibold">Checks</th>
            <th scope="col" class="px-3 py-2.5 font-semibold">Action</th>
          </tr>
        </thead>
        <tbody id="blocks-pool-table" phx-update="stream" class="divide-y divide-subtle/60">
          <tr :for={{dom_id, trip} <- @pool_rows} id={dom_id} class="hover:bg-canvas">
            <td class="px-3 max-md:absolute max-md:right-1 max-md:top-0">
              <.select_trip trip={trip} checked={MapSet.member?(@selected_ids, trip.id)} />
            </td>
            <td class="px-3 py-1.5 max-md:col-span-2 max-md:pr-12" data-label="Route / trip">
              <div class="flex items-center gap-2">
                <.route_badge_for route_id={trip.route_id} routes={@routes} />
                <div>
                  <strong>{trip.trip_id}</strong>
                  <small class="block text-[13px] text-muted">
                    {route_name(@routes, trip.route_id)}
                  </small>
                </div>
              </div>
            </td>
            <td class="px-3 py-1.5 max-md:col-span-2" data-label="Start → end">
              <span class="tabular-nums">
                {clock(trip.first_departure)} → {clock(trip.last_arrival)}
              </span>
              <span
                :if={text = eligibility_text(trip)}
                data-role="pool-eligibility"
                class="block text-[13px] text-muted"
              >
                <%= if trip.plottable? do %>
                  {text}
                <% else %>
                  {text} ·
                  <.link
                    id={"pool-schedules-" <> dom_token(trip.trip_id)}
                    navigate={schedules_path(@version_id, trip)}
                    class="font-[650] text-action underline underline-offset-4"
                  >
                    Fix times in Schedules
                  </.link>
                <% end %>
              </span>
            </td>
            <td class="px-3 py-1.5 max-md:col-span-2" data-label="From → to">
              <.endpoints trip={trip} />
            </td>
            <td class="px-3 py-1.5 max-md:col-span-2" data-label="Checks">
              <.issue_badges findings={Map.get(@findings_by_trip, trip.id, [])} none="—" />
            </td>
            <td class="whitespace-nowrap px-3 max-md:col-span-2" data-label="Action">
              <button
                :if={eligible?(trip)}
                type="button"
                data-role="assign-trip"
                phx-click="open_assign"
                phx-value-scope="trip"
                phx-value-trip={trip.trip_id}
                class={link_class()}
              >
                Assign trip
              </button>
              <button
                :if={not eligible?(trip)}
                type="button"
                data-role="view-trip"
                phx-click="open_trip"
                phx-value-trip={trip.trip_id}
                class={link_class()}
              >
                View trip
              </button>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  @doc """
  Renders the “not shown on the timeline” disclosure of the All blocks panel:
  every trip that has a block but no usable endpoint time, with its reason and a
  link to its route's Schedules for its calendar.

  The timeline cannot draw these trips and the pool does not hold them, so this
  list is where a blocked trip with missing timing stays visible (AC-23).
  """
  attr :trips, :list, required: true
  attr :routes, :map, required: true
  attr :version_id, :string, required: true

  def untimed_list(assigns) do
    ~H"""
    <details :if={@trips != []} id="blocks-untimed" class="border-t border-subtle px-4 py-1 text-sm">
      <summary class="flex min-h-11 cursor-pointer items-center font-semibold text-strong">
        Not shown on the timeline · {length(@trips)}
      </summary>

      <ul class="pb-3">
        <li
          :for={trip <- @trips}
          data-role="untimed-trip"
          data-trip={trip.trip_id}
          class="flex flex-wrap items-center gap-x-3 gap-y-1 py-1.5"
        >
          <.route_badge_for route_id={trip.route_id} routes={@routes} />
          <strong>{trip.trip_id}</strong>
          <span data-role="untimed-reason" class="text-muted">
            Block {trip.block_id} · {eligibility_text(trip)}
          </span>
          <.link
            id={"untimed-schedules-" <> dom_token(trip.trip_id)}
            navigate={schedules_path(@version_id, trip)}
            class={link_class()}
          >
            Fix times in Schedules
          </.link>
        </li>
      </ul>
    </details>
    """
  end

  # The row's selection control: a 44px target around the checkbox, and the
  # trip's natural ID in the event. The checked state is the page's own
  # selection, so a re-streamed row shows the state the reader last set (AC-24).
  attr :trip, :map, required: true
  attr :checked, :boolean, required: true

  defp select_trip(assigns) do
    ~H"""
    <label
      class="grid min-h-11 min-w-11 place-items-center max-md:min-h-12 max-md:min-w-12"
      for={"select-" <> dom_token(@trip.trip_id)}
    >
      <input
        type="checkbox"
        id={"select-" <> dom_token(@trip.trip_id)}
        data-role="select-trip"
        data-trip={@trip.trip_id}
        checked={@checked}
        phx-click="toggle_trip"
        phx-value-trip={@trip.trip_id}
        aria-label={"Select trip " <> @trip.trip_id}
        class="size-5 accent-action"
      />
    </label>
    """
  end

  # The trip's endpoint stops: the origin, then the destination on its own line
  # as “→ <terminal>”, which is the reference's From → To cell.
  attr :trip, :map, required: true

  defp endpoints(assigns) do
    ~H"""
    <div>
      <span>{stop_name(@trip.first_stop)}</span>
      <span class="block text-muted">→ {stop_name(@trip.last_stop)}</span>
    </div>
    """
  end

  # The findings that name this trip, worst first, as badges; a trip without one
  # says so in text rather than leaving the cell blank.
  attr :findings, :list, required: true
  attr :none, :string, default: "No problems"

  defp issue_badges(assigns) do
    assigns =
      assign(assigns,
        issues:
          assigns.findings
          |> Enum.uniq_by(& &1.code)
          |> Enum.sort_by(&issue_rank/1)
      )

    ~H"""
    <div data-role="trip-issues" class="flex flex-wrap gap-1">
      <span :if={@issues == []} class="text-muted">{@none}</span>
      <.code_badge
        :for={finding <- @issues}
        code={finding.code}
        data-role="trip-issue"
        data-code={finding.code}
      />
    </div>
    """
  end

  # A finding as a tinted badge: an icon and the operator's word for it. Drawers
  # and cards carry badges; a dense table cell carries `status_text/1`.
  attr :tone, :atom, required: true, values: [:error, :warning, :info, :success, :neutral]
  attr :icon, :string, default: nil
  attr :label, :string, required: true
  attr :rest, :global

  defp finding_badge(assigns) do
    ~H"""
    <span
      class={[
        "inline-flex max-w-full items-center gap-1.5 rounded-badge px-2 py-1 text-[13px] font-semibold leading-tight",
        tone_badge(@tone)
      ]}
      {@rest}
    >
      <.icon :if={@icon} name={@icon} class="size-[15px] shrink-0" />{@label}
    </span>
    """
  end

  attr :code, :atom, required: true
  attr :rest, :global

  defp code_badge(assigns) do
    assigns = assign(assigns, :meta, code_meta(assigns.code))

    ~H"""
    <.finding_badge tone={@meta.tone} icon={@meta.icon} label={@meta.label} {@rest} />
    """
  end

  # Status in a dense table cell: an icon and words in the state's ink on a white
  # row, never a filled badge.
  attr :status, :map, required: true

  defp status_text(assigns) do
    ~H"""
    <span
      data-role="block-status"
      class={["inline-flex items-center gap-1.5 font-[650]", tone_text(@status.tone)]}
    >
      <.icon name={@status.icon} class="size-4 shrink-0" /> {@status.label}
    </span>
    """
  end

  defp tone_badge(:error), do: "bg-error-bg text-error-fg"
  defp tone_badge(:warning), do: "bg-warning-bg text-warning-fg"
  defp tone_badge(:info), do: "bg-info-bg text-info-fg"
  defp tone_badge(:success), do: "bg-success-bg text-success-fg"
  defp tone_badge(:neutral), do: "bg-canvas text-muted"

  defp tone_text(:error), do: "text-error-fg"
  defp tone_text(:warning), do: "text-warning-fg"
  defp tone_text(:info), do: "text-info-fg"
  defp tone_text(:success), do: "text-success-fg"

  defp severity_border(:error), do: "border-error-line"
  defp severity_border(:warning), do: "border-warning-line"
  defp severity_border(:notice), do: "border-info-line"

  # A link-styled button or link: the action colour, underlined, on a 44px target.
  defp link_class do
    "inline-flex min-h-11 items-center gap-1.5 rounded-control px-1 text-sm font-[650] text-action underline underline-offset-4 hover:text-action-hover"
  end

  # The route's feed identity for a bare route ID: the badge reads
  # `route_short_name`, which the day's route map names `short_name`.
  attr :route_id, :string, required: true
  attr :routes, :map, required: true

  defp route_badge_for(assigns) do
    route = Map.get(assigns.routes, assigns.route_id) || %{route_id: assigns.route_id}
    assigns = assign(assigns, :route, Map.put(route, :route_short_name, route[:short_name]))

    ~H"""
    <RouteIdentity.route_badge route={@route} />
    """
  end

  defp issue_rank(%{severity: :error}), do: 0
  defp issue_rank(%{severity: :warning}), do: 1
  defp issue_rank(_finding), do: 2

  # The route's long name, which the reference prints under the trip ID; a route
  # without one falls back to its short name and then its stored ID.
  defp route_name(routes, route_id) do
    route = Map.get(routes, route_id) || %{}
    route[:long_name] || route[:short_name] || route_id
  end

  # The pool's single eligibility reason per trip (Checks), with the waiting
  # time already in minutes; a nil headway can only mean a non-frequency trip.
  defp eligibility_text(%{frequency?: true} = trip) do
    "Repeats every #{div(trip.headway_secs, 60)} min · not a single trip"
  end

  defp eligibility_text(%{plottable?: false}), do: "Time missing"
  defp eligibility_text(_trip), do: nil

  @doc """
  Whether a trip can be assigned to a block: it needs usable endpoint times and
  a single trip, not a repeating one (README, R10).

  The pool's actionable rows, the bulk bar's assignment form and the LiveView's
  eligibility preview of a selection all read this one rule, so the page never
  offers an assignment the `Blocking` context would refuse.
  """
  def eligible?(trip), do: trip.plottable? and not trip.frequency?

  # A List view row is one of the block's trips the route filter keeps, in the
  # block's own order, so the table reads top to bottom like the block's work.
  defp list_rows(block, route_filter) do
    Enum.filter(block.trips, &visible?(&1, route_filter))
  end

  defp gap_label(%{gap_secs: secs}) when secs >= 0, do: minutes(secs)
  defp gap_label(%{gap_secs: secs}), do: "Overlap #{div(-secs, 60)} min"

  # The Schedules page for a trip's route, narrowed to the trip's own calendar
  # (the `service_id` filter Schedules already reads).
  defp schedules_path(version_id, trip) do
    ~p"/gtfs/#{version_id}/routes/#{trip.route_id}/schedules?#{[service_id: trip.service_id]}"
  end

  # A service-day link's URL state: the two parameters the page reads, so following
  # it opens the trip's drawer again on the day it names.
  defp day_type_trip_path(version_id, day_key, trip_id) do
    "/gtfs/#{version_id}/blocks?" <> URI.encode_query([{"day", day_key}, {"trip", trip_id}])
  end

  @doc """
  Renders the paged timeline: the sticky sortable header, the whole-day axis with
  a tick every two hours, and one `block_row/1` per streamed block.

  The header buttons sort the whole service day, not the page, and carry the
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
      <table id="blocks-timeline" data-scale={@state.scale} aria-label="Blocks by service-day time">
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
              <button type="button" phx-click="sort" phx-value-key={column.key} class="blocks-sort">
                {column.label}
                <span
                  :if={Atom.to_string(@state.sort) == column.key}
                  aria-hidden="true"
                  class="text-action"
                >
                  {sort_arrow(@state.dir)}
                </span>
                <.icon
                  :if={Atom.to_string(@state.sort) != column.key}
                  name="hero-chevron-up-down-micro"
                  class="size-3.5 text-muted"
                />
              </button>
            </th>
            <th scope="col" class="blocks-axis">
              <span class="blocks-axis-inner">
                <span
                  :for={tick <- @ticks}
                  class={["blocks-axis-tick", tick.first? && "blocks-axis-tick-first"]}
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
  Renders one 44px block row: the sticky Block, Trips, Start, End, Hours and
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
        <.status_text status={@status} />
      </td>
      <td class="blocks-track" style={@track_style}>
        <%= for row <- @plotted do %>
          <%= if visible?(row.trip, @route_filter) do %>
            <%!-- A negative gap_secs is an overlap, whose bars already carry the mark. --%>
            <.gap
              :if={row.gap && row.gap.gap_secs >= 0}
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
  Renders one trip as a 28px button positioned by the service day's axis.

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
  when the bar is at least 26px wide, which the container query reads from the
  bar's own width. A deadhead draws dashed with the move icon, and a short layover
  is an 18px warning chip with its “!” always drawn, centred on the gap and above
  the bars, so the states differ by more than colour.
  """
  attr :gap, :map, required: true
  attr :from, :map, required: true
  attr :axis, :map, default: nil
  attr :short?, :boolean, default: false

  def gap(assigns) do
    assigns =
      assigns
      |> assign(:move?, match?({:moves, _}, assigns.gap.handoff))
      |> assign(:style, gap_geometry(assigns.gap, assigns.from, assigns.axis, assigns.short?))

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
      title={gap_hover(@gap)}
    >
      <span :if={@short?} aria-hidden="true">!</span>
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

  # “1 · Coast Highway” when the route has both names, so the picker says what
  # each number is.
  defp route_option_label(route_id, route) do
    case {present(route.short_name), present(route.long_name)} do
      {nil, nil} -> route_id
      {short, nil} -> short
      {nil, long} -> long
      {short, long} -> "#{short} · #{long}"
    end
  end

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      _trimmed -> value
    end
  end

  defp present(_value), do: nil

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
    "#{day_type.label} · #{day_count_label(day_type.date_count)}"
  end

  defp day_count_label(1), do: "1 day"
  defp day_count_label(count), do: "#{count} days"

  # The whole-day tiles. A tile that leads somewhere is an action; the rest are
  # figures. Unassigned trips and Problems take a state colour while there is
  # something to do and read as done, with a check, at zero.
  defp summary_tiles(counts, peak) do
    [
      %{
        key: "blocks",
        label: "Blocks",
        count: counts.blocks,
        tone: :neutral,
        icon: "hero-rectangle-stack",
        action?: false,
        wide?: false,
        detail: nil
      },
      unassigned_tile(counts.unassigned),
      problems_tile(counts.problems),
      %{
        key: "notices",
        label: "Notices",
        count: counts.notices,
        tone: :neutral,
        icon: "hero-information-circle",
        action?: false,
        wide?: false,
        detail: nil
      },
      %{
        key: "peak",
        label: "Peak vehicles out",
        count: peak.count,
        tone: :neutral,
        icon: "hero-truck",
        action?: true,
        wide?: true,
        detail: peak_detail(peak)
      }
    ]
  end

  defp unassigned_tile(0) do
    %{
      key: "unassigned",
      label: "Unassigned trips",
      count: 0,
      tone: :success,
      icon: "hero-check-circle",
      action?: false,
      wide?: false,
      detail: nil
    }
  end

  defp unassigned_tile(count) do
    %{
      key: "unassigned",
      label: "Unassigned trips",
      count: count,
      tone: :info,
      icon: "hero-inbox",
      action?: true,
      wide?: false,
      detail: nil
    }
  end

  defp problems_tile(0) do
    %{
      key: "problems",
      label: "Problems",
      count: 0,
      tone: :success,
      icon: "hero-check-circle",
      action?: true,
      wide?: false,
      detail: nil
    }
  end

  defp problems_tile(count) do
    %{
      key: "problems",
      label: "Problems",
      count: count,
      tone: :error,
      icon: "hero-exclamation-triangle",
      action?: true,
      wide?: false,
      detail: nil
    }
  end

  defp peak_detail(%{at_secs: nil}), do: "none timed"
  defp peak_detail(peak), do: "at #{clock(peak.at_secs)}"

  defp count_label(1, singular, _plural), do: "1 #{singular}"
  defp count_label(count, _singular, plural), do: "#{count} #{plural}"

  defp peak_chart_label(peak, bins, axis) do
    "Vehicles out per 15-minute bin, #{peak.count} at the peak. " <>
      "Chart covers #{clock(List.first(bins).start_secs)} to " <>
      "#{clock(List.last(bins).start_secs + 900)} of the service day" <>
      if(axis,
        do: " (whole service day #{clock(axis.start_secs)}–#{clock(axis.end_secs)})",
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

  # A date inside its month's group: the weekday and the day of the month.
  defp short_date(date), do: Calendar.strftime(date, "%a %-d")

  # One finding code's operator word, tone and icon. The GTFS names stay in the
  # drawers' muted detail.
  defp code_meta(:overlap), do: %{label: "Overlap", tone: :error, icon: "hero-x-circle"}

  defp code_meta(:short_layover),
    do: %{label: "Short layover", tone: :warning, icon: "hero-exclamation-triangle"}

  defp code_meta(:in_seat_stale),
    do: %{label: "Stay-on-board mismatch", tone: :warning, icon: "hero-exclamation-triangle"}

  defp code_meta(:in_seat_unconfirmed),
    do: %{label: "Can't confirm", tone: :info, icon: "hero-information-circle"}

  defp code_meta(:repositions),
    do: %{label: "Deadhead", tone: :info, icon: "hero-arrow-up-right"}

  defp code_meta(:frequency_trip),
    do: %{label: "Repeating trip", tone: :info, icon: "hero-arrow-path"}

  defp code_meta(:unplottable),
    do: %{label: "Missing times", tone: :info, icon: "hero-question-mark-circle"}

  defp code_label(code), do: code_meta(code).label

  defp finding_detail(%{code: :overlap, detail: %{overlap_secs: secs}}) do
    "Two trips in this block overlap by #{minutes(secs)}."
  end

  defp finding_detail(%{code: :short_layover, detail: %{gap_secs: secs}}) do
    "Only #{minutes(secs)} between two trips in this block."
  end

  defp finding_detail(%{code: :repositions, detail: detail}) do
    distance =
      case detail.meters do
        nil -> ""
        meters -> " about " <> distance_label(meters)
      end

    "The vehicle drives empty#{distance} with #{minutes(detail.gap_secs)} available. " <>
      "Driving time isn't recorded."
  end

  defp finding_detail(%{code: :frequency_trip, detail: %{headway_secs: secs}}) do
    "Repeats every #{div(secs, 60)} min, so this view can't check the individual vehicle's work."
  end

  defp finding_detail(%{code: :unplottable}) do
    "A time is missing, so this trip can't be drawn or assigned."
  end

  defp finding_detail(%{code: code, detail: %{reason: reason}})
       when code in [:in_seat_stale, :in_seat_unconfirmed] do
    in_seat_reason(reason)
  end

  defp finding_detail(_finding), do: "Review this finding."

  defp distance_label(meters) when meters >= 1000,
    do: :erlang.float_to_binary(meters / 1000, decimals: 1) <> " km"

  defp distance_label(meters), do: "#{meters} m"

  defp in_seat_reason(:trip_missing), do: "A trip in this record isn't in this version."

  defp in_seat_reason(:no_shared_date), do: "The two trips never run on the same day."

  defp in_seat_reason(:no_block),
    do:
      "A trip has no block. Google ignores the record; riders only see stay-on-board from blocks."

  defp in_seat_reason(:stops_changed),
    do: "The record's stops no longer match where these trips end and start."

  defp in_seat_reason({:not_next, failures}) do
    "Riders are told they can stay on board, but the second trip isn't next on this vehicle on " <>
      Enum.map_join(failures, " or ", &"#{&1.label} (#{day_count_label(&1.date_count)})") <> "."
  end

  defp in_seat_reason(:next_service_day),
    do: "Can't be confirmed here: the second trip continues on the next service day."

  defp in_seat_reason(:untimed),
    do: "Can't be confirmed here: a trip has missing or repeating times."

  defp in_seat_reason(:coupling),
    do: "Can't be confirmed here: the trips are coupled, not consecutive."

  defp in_seat_reason(reason) when is_atom(reason), do: "Can't be confirmed here: #{reason}."

  # The trip drawer's record list: every state's copy from the page's vocabulary,
  # with the match that has no warning and the two severities the badge tints.
  defp in_seat_state_text(:matches), do: "Matches the block on every shared day."
  defp in_seat_state_text({_state, reason}), do: in_seat_reason(reason)

  defp transfer_type_label(4), do: "Riders stay on board"
  defp transfer_type_label(_type), do: "Riders must get off and board again"

  defp transfer_state_tone(:matches), do: :success
  defp transfer_state_tone({:stale, _reason}), do: :warning
  defp transfer_state_tone({:unconfirmed, _reason}), do: :info

  defp transfer_state_label(:matches), do: "Matches block"
  defp transfer_state_label({:stale, _reason}), do: "Needs review"
  defp transfer_state_label({:unconfirmed, _reason}), do: "Can't confirm"

  defp frequency_title(%{headway_secs: secs}), do: "Repeats every #{div(secs, 60)} min."

  defp minutes(secs) when is_integer(secs), do: "#{div(secs, 60)} min"

  # The trip drawer's title: when the trip leaves and where it is headed, which is
  # what an operator calls it; a trip with no departure time falls back to its
  # headsign or its ID.
  defp trip_title(trip) do
    case {is_integer(trip.first_departure), present(trip.trip_headsign)} do
      {true, nil} -> clock(trip.first_departure)
      {true, headsign} -> clock(trip.first_departure) <> " to " <> headsign
      {false, nil} -> "Trip " <> trip.trip_id
      {false, headsign} -> "Trip to " <> headsign
    end
  end

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
    "Select trips to place them on one block, or assign them one at a time."
  end

  defp workspace_note(%{view: :list}, filtered?) do
    "Select trips to move them or take them off a block. " <> whole_block_note(filtered?)
  end

  defp workspace_note(_state, filtered?) do
    "Select a bar, a block number or a gap for details. Use List for larger controls. " <>
      whole_block_note(filtered?)
  end

  defp whole_block_note(true),
    do: "Checks cover each whole block, even when the route filter hides some of its trips."

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
      %{
        first?: index == 0,
        style: if(index == 0, do: nil, else: "left: #{percent_value(left)}%"),
        label: clock(start + index * @tick_secs)
      }
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

  # A short layover is a fixed-width chip centred on its gap, so it stays legible
  # however brief the gap; every other gap spans its own layover.
  defp gap_geometry(gap, previous, axis, true) do
    {start, span} = axis_geometry(axis)
    center = previous.last_arrival - start + div(gap.gap_secs, 2)

    "left: #{percent(center, span)}%; width: 18px; transform: translateX(-50%)"
  end

  defp gap_geometry(gap, previous, axis, false) do
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

  # A block's status in the timeline's Status cell: its worst finding's word, tone
  # and icon, or “No problems”.
  defp status_label(%{status: :ok}),
    do: %{icon: "hero-check-circle", label: "No problems", tone: :success}

  defp status_label(%{status_code: code}) do
    meta = code_meta(code)
    %{icon: meta.icon, label: meta.label, tone: meta.tone}
  end

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

  defp blank_dash(value) when is_binary(value) do
    case String.trim(value) do
      "" -> "—"
      _value -> value
    end
  end

  defp blank_dash(_value), do: "—"

  # The stored GTFS clock of a parsed endpoint; a missing time has none.
  defp gtfs_time(nil), do: "—"
  defp gtfs_time(secs), do: GtfsTime.format(secs)

  # A gap's hover text: how long it is and what kind of handoff it is.
  defp gap_hover(%{handoff: {:moves, _}} = gap),
    do: "#{minutes(gap.gap_secs)} gap · deadhead, the vehicle drives empty"

  defp gap_hover(%{handoff: :same_stop} = gap), do: "#{minutes(gap.gap_secs)} gap · same stop"

  defp gap_hover(%{handoff: :same_station} = gap),
    do: "#{minutes(gap.gap_secs)} gap · same station"

  defp gap_hover(%{handoff: {:nearby, meters}} = gap),
    do: "#{minutes(gap.gap_secs)} gap · nearby stop, #{meters} m"

  defp handoff_key(:same_stop), do: "same_stop"
  defp handoff_key(:same_station), do: "same_station"
  defp handoff_key({:nearby, meters}), do: "nearby-#{meters}"
  defp handoff_key({:moves, _meters}), do: "moves"

  # --- the assignment form and the review (step 25) --------------------------

  # The picker's status line: how many of the service day's block IDs the search
  # matched, and whether the 25-entry cap cut the list (AC-26).
  defp destination_summary(options, total) do
    count = length(options)

    if count < total do
      "#{count} of #{total} matching blocks · refine your search"
    else
      "#{count} matching blocks"
    end
  end

  # An ineligible trip is named with its own reason rather than silently dropped
  # (FH-18). The selection scope gets its own message and one line per trip,
  # because a bulk selection can hold several reasons at once (AC-24).
  defp ineligible_trips(%{ineligible: ids, trips: trips}),
    do: Enum.filter(trips, &(&1.id in ids))

  defp ineligible_callout_id(%{scope: :selection}), do: "bulk-ineligible"
  defp ineligible_callout_id(_assign), do: "assign-ineligible"

  defp ineligible_title(%{scope: :selection}, ineligible),
    do: "#{count_label(length(ineligible), "selected trip", "selected trips")} can't be assigned."

  defp ineligible_title(_assign, ineligible) do
    case ineligible |> Enum.map(&eligibility_text/1) |> Enum.reject(&is_nil/1) |> Enum.uniq() do
      [] -> "This trip can't be assigned to a block."
      reasons -> "This trip can't be assigned to a block · " <> Enum.join(reasons, ", ")
    end
  end

  # The bulk message's per-trip reason: the rule that refused it, in the pool's
  # own words (“repeats” for a repeating trip, “time missing” for one whose
  # endpoint time is missing).
  defp bulk_ineligibility_reason(%{frequency?: true} = trip),
    do: "repeats every #{div(trip.headway_secs, 60)} min"

  defp bulk_ineligibility_reason(_trip), do: "time missing"

  # The confirm button repeats the verb and its object (AC-26).
  defp confirm_label(%{command: {:rename, _source, _target}}), do: "Rename block"
  defp confirm_label(%{command: {:merge, _source, _target}}), do: "Merge blocks"

  defp confirm_label(%{command: {:unassign, _ids}, changes: changes}),
    do: "Remove " <> count_label(length(changes), "trip", "trips")

  defp confirm_label(%{changes: changes}),
    do: "Assign " <> count_label(length(changes), "trip", "trips")

  defp confirm_label(_review), do: "Save changes"

  # The cancel action names the way back to the form the review came from.
  defp cancel_label(%{command: {:rename, _source, _target}}), do: "Change name"
  defp cancel_label(%{command: {:unassign, _ids}}), do: "Keep trips"
  defp cancel_label(_review), do: "Change block"

  defp effect_sentence(effect, review) do
    count = length(effect.changed_trip_ids)
    noun = if count == 1, do: "trip assignment changes", else: "trip assignments change"
    target = if review.target, do: "block " <> review.target, else: "unassigned"
    "#{count} #{noun} to #{target}."
  end

  # “Added” problems are the errors and warnings a command introduces; a new
  # notice alone never needs confirmation, so it belongs in the disclosure.
  defp added_problems(effect), do: Enum.reject(effect.added, &(&1.severity == :notice))

  defp added_notices(nil), do: []

  defp added_notices(review) do
    Enum.flat_map(review.effects, fn effect ->
      effect.added
      |> Enum.filter(&(&1.severity == :notice))
      |> Enum.map(&{effect.day_type.label, notice_text(&1)})
    end)
  end

  defp notice_text(finding), do: "#{code_label(finding.code)} · #{finding_detail(finding)}"

  defp existing_problem_count(nil), do: 0

  defp existing_problem_count(review) do
    review.effects
    |> Enum.flat_map(& &1.existing)
    |> Enum.count(&(&1.severity in [:error, :warning]))
  end

  # A DOM id token for a block or trip ID that may hold any Unicode: the same
  # URL-safe Base64 as the block rows, never the raw ID (Setup and hazards).
  defp dom_token(id), do: Base.url_encode64(id, padding: false)
end
