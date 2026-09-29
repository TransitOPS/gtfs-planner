defmodule GtfsPlannerWeb.Gtfs.BlocksComponents do
  @moduledoc """
  Function components for Operations › Blocks.

  The page's day-type scope, whole-day summary, the paged timeline, the List
  view, the unassigned pool, the Service dates, Checks, Peak and Minimum layover
  drawers, the “not plotted” list and the page states live here so
  `GtfsPlannerWeb.Gtfs.BlocksLive` stays a small state owner. Every component
  takes the pieces of the loaded day it prints, never the whole day, so
  `render/1` in the LiveView never reaches into the server-only day assign
  (CR-6). The trip, gap and block drawers render inside the same page.

  Times are printed from parsed seconds with `clock/1`; nothing here re-reads a
  clock string from the database (CR-3). The timeline reads the block's trips
  and findings only, and takes the block's plot order from the pure
  `Checks.sequence/1` so its bars align with the block's own `gaps/1` pairs. The
  List view and the pool take a trip's findings from the day's own finding list,
  grouped by trip once per load, and print them through `status_badge`.
  """

  use GtfsPlannerWeb, :html

  alias GtfsPlanner.Gtfs.Blocking.Checks
  alias GtfsPlanner.Gtfs.GtfsTime
  alias GtfsPlannerWeb.Components.RouteIdentity

  @doc """
  Renders the day-type scope: the day-type select, the route filter, “Problems
  only”, the Service dates link and the Minimum layover button.

  The day select posts through its own form (`select_day`) so a day change is
  never mistaken for a route filter; the route and status controls post through
  the `filter` form. The scope describes the whole day type, so neither control
  changes the whole-day counts. The Minimum layover button prints the stored
  value the day load read, so a save shows the new one on the next render.
  """
  attr :day_types, :list, required: true
  attr :day_type, :map, required: true
  attr :routes, :map, required: true
  attr :state, :map, required: true
  attr :min_layover_minutes, :integer, required: true

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

      <div class="ml-auto flex flex-wrap items-center gap-x-4 gap-y-2">
        <button
          id="blocks-service-dates"
          type="button"
          phx-click="open_drawer"
          phx-value-key="service_dates"
          class="link link-primary min-h-11"
        >
          Service dates
        </button>
        <button
          id="blocks-min-layover"
          type="button"
          phx-click="open_drawer"
          phx-value-key="layover"
          class="btn btn-sm min-h-11"
        >
          Minimum layover · {@min_layover_minutes} min
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
  Renders the whole-day count strip, the plan figures beside it and the day-type
  note.

  Every figure is the whole day type's, so the route filter, “Problems only”
  and any paging leave them unchanged. Each item is a button: the unassigned
  figure opens the unassigned panel, the problems figure opens its drawer and
  the three plan figures after the divider all open the Plan summary — the
  drawer step 36 names `plan_summary`, which is why they send that one value
  rather than their own keys. The items whose key names no target (`blocks`,
  `notices`) are ignored by the handler.
  """
  attr :day_type, :map, required: true
  attr :counts, :map, required: true
  attr :figures, :map, required: true
  attr :peak, :map, required: true
  attr :open_drawer, :atom, default: nil

  def summary_strip(assigns) do
    assigns =
      assigns
      |> assign(:items, count_items(assigns.counts))
      |> assign(:figure_items, figure_items(assigns.figures, assigns.peak))
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
      <span
        id="blocks-summary-divider"
        class="w-px shrink-0 self-stretch bg-base-300"
        aria-hidden="true"
      >
      </span>
      <.count_strip
        id="blocks-summary-figures"
        items={@figure_items}
        event="open_drawer"
        event_value="plan_summary"
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
  Renders the page-level notices above the workbench: the fleet shortfall, the
  two fleet-setup notices, and nothing at all when the version has what the
  plan needs.

  The order is the one a planner acts in: a garage is needed before a vehicle
  can be listed against it, so a version with no garage is told that and not
  also about a fleet it cannot check yet. A shortfall is the plan's own
  `:fleet_shortfall` finding rendered as a sentence per short row, so the
  numbers are `Fleet.rows/2`'s and the garage and type names are the ones the
  day load resolved. The notice offers the Plan summary and the Fleet settings;
  it never covers the workbench, and each notice is a real anchor or button.
  """
  attr :fleet_shortfalls, :list, required: true
  attr :garages?, :boolean, required: true
  attr :vehicles?, :boolean, required: true
  attr :version_id, :string, required: true

  def plan_notices(assigns) do
    ~H"""
    <div id="blocks-notices" class="space-y-3">
      <.callout
        :if={!@garages?}
        id="blocks-no-garages"
        kind="info"
        title="Add a garage to plan travel to and from the garage."
      >
        Driving between stops still shows. Suggestions need at least one garage.
        <div class="mt-2 flex flex-wrap items-center gap-2">
          <.link
            id="blocks-no-garages-link"
            navigate={"/gtfs/#{@version_id}/settings/garages"}
            class="link link-primary inline-flex min-h-11 items-center"
          >
            Go to Settings › Garages
          </.link>
        </div>
      </.callout>
      <.callout
        :if={@garages? and not @vehicles?}
        id="blocks-no-vehicles"
        kind="info"
        title="Fleet limits aren’t checked."
      >
        No vehicles are listed, so the page can’t tell whether each garage has enough.
        <div class="mt-2 flex flex-wrap items-center gap-2">
          <.link
            id="blocks-no-vehicles-link"
            navigate={"/gtfs/#{@version_id}/settings/fleet"}
            class="link link-primary inline-flex min-h-11 items-center"
          >
            Go to Settings › Fleet
          </.link>
        </div>
      </.callout>
      <.callout
        :if={@fleet_shortfalls != []}
        id="blocks-fleet-shortfall"
        kind="error"
        title="Not enough vehicles."
      >
        <span data-role="blocks-shortfall-summary">{shortfall_summary(@fleet_shortfalls)}</span>
        Rebuilding blocks can’t fix this; add vehicles or move blocks to another garage.
        <div class="mt-2 flex flex-wrap items-center gap-2">
          <button
            id="blocks-fleet-shortfall-summary"
            type="button"
            phx-click="open_drawer"
            phx-value-key="plan_summary"
            class="btn btn-sm min-h-11"
          >
            Open plan summary
          </button>
          <.link
            id="blocks-fleet-shortfall-fleet-link"
            navigate={"/gtfs/#{@version_id}/settings/fleet"}
            class="link link-primary inline-flex min-h-11 items-center"
          >
            Go to Settings › Fleet
          </.link>
        </div>
      </.callout>
    </div>
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
  Renders the Plan summary drawer (AC-35): what the day's blocks cost in
  vehicles, minutes and kilometres, and how far the fleet is from carrying them.

  The four sections are the reference's, in its order and wording: the headline
  number with the minimum and the riders share and the sentence that explains
  them, the fleet table at the busiest time with its chart, the time and distance
  totals, and the operator changes. Every number is `day.figures`, `day.fleet`
  or `day.longest_stretch` read once per load into render assigns (CR-6), so the
  drawer prints derived answers and re-derives none of its own.

  The chart is the built peak chart's markup with the capacity line the reference
  adds: the focused row — the first short row, else the first typed row, never a
  garage total — is drawn per 15-minute bin against its own listing, and a bin
  above that listing is an error bar rather than a demand bar. The sentence under
  the chart is the chart's text equivalent, so the encoding is readable without
  the pixels.

  The two Operator changes links are step 42's: this step renders the section's
  own answers and leaves the drawer they open to that step.
  """
  attr :open, :boolean, required: true
  attr :figures, :map, required: true
  attr :fleet_rows, :list, required: true
  attr :chart, :map, default: nil
  attr :day_type, :map, default: nil
  attr :min_layover_minutes, :integer, default: nil
  attr :longest_stretch, :map, default: nil
  attr :max_piece_minutes, :integer, default: nil
  attr :relief_stop_count, :integer, default: 0
  attr :estimated?, :boolean, default: false
  attr :repeating?, :boolean, default: false
  attr :errors?, :boolean, default: false
  attr :garages?, :boolean, default: false
  attr :vehicles?, :boolean, default: false
  attr :version_id, :string, required: true

  def plan_summary_drawer(assigns) do
    ~H"""
    <.drawer
      id="plan-summary-drawer"
      open={@open}
      title="Plan summary"
      return_focus_id="blocks-summary-figures-item-vehicles"
    >
      <p :if={@day_type} class="text-sm font-semibold">
        {@day_type.label} · {date_count_label(@day_type.date_count)}
      </p>

      <section id="plan-summary-plan">
        <p id="plan-summary-vehicles" class="mt-2 text-4xl font-semibold leading-none">
          {@figures.vehicles}
          <span class="text-base font-normal text-base-content/70">vehicles used</span>
        </p>

        <dl id="plan-summary-figures" class="mt-4 grid grid-cols-[1fr_auto] gap-x-4 gap-y-2 text-sm">
          <dt class="text-base-content/70">Minimum possible</dt>
          <dd id="plan-summary-minimum" class="text-right font-semibold tabular-nums">
            {@figures.minimum}
          </dd>
          <dt class="text-base-content/70">Time with riders</dt>
          <dd id="plan-summary-riders" class="text-right font-semibold tabular-nums">
            {@figures.riders}%
          </dd>
        </dl>

        <p id="plan-summary-minimum-help" class="mt-2 text-sm text-base-content/70">
          The minimum is the fewest vehicles these trip times allow with a {min_layover_label(
            @min_layover_minutes
          )} layover. Driving between stops and operator
          changes can mean a good plan uses more.{repeating_note(@repeating?)} Time with riders is
          the share of time out of the garage spent carrying riders.
        </p>
      </section>

      <section id="plan-summary-fleet" class="mt-6 border-t border-base-300 pt-5">
        <h3 class="text-base font-bold">Fleet at the busiest time</h3>

        <p
          :if={not @garages?}
          id="plan-summary-fleet-no-garage"
          class="mt-2 text-sm text-base-content/70"
        >
          Add a garage to count vehicles out of the garage.
        </p>

        <p
          :if={@garages? and not @vehicles?}
          id="plan-summary-fleet-no-vehicles"
          class="mt-2 text-sm text-base-content/70"
        >
          No vehicles are listed.
          <.link navigate={"/gtfs/#{@version_id}/settings/fleet"} class="link link-primary">
            Go to Settings › Fleet
          </.link>
        </p>

        <table
          :if={@garages? and @vehicles?}
          id="plan-summary-fleet-table"
          class="table table-sm mt-2"
        >
          <caption class="sr-only">
            Vehicles needed and listed per garage and type at the busiest time
          </caption>
          <thead>
            <tr>
              <th scope="col">Garage · type</th>
              <th scope="col" class="text-right">Needed</th>
              <th scope="col" class="text-right">Listed</th>
              <th scope="col">When</th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={row <- @fleet_rows}
              id={"plan-summary-fleet-#{row.index}"}
              data-role="plan-summary-fleet-row"
              data-total={to_string(row.total?)}
            >
              <td class={["whitespace-nowrap", row.total? && "text-base-content/70"]}>
                {row.garage} · {row.type}
              </td>
              <td class={["text-right tabular-nums font-semibold", row.short? && "text-error"]}>
                {row.needed}{if row.short?, do: " !"}
              </td>
              <td class="text-right tabular-nums">{row.listed}</td>
              <td class="tabular-nums">{fleet_when(row.at_secs, row.needed)}</td>
            </tr>
          </tbody>
        </table>

        <p
          :if={@garages? and @vehicles?}
          id="plan-summary-fleet-note"
          class="mt-2 text-sm text-base-content/70"
        >
          Blocks without a type count against their garage’s total. Garage travel counts as time
          out.
        </p>

        <div :if={@chart} id="plan-summary-chart-block" class="mt-4">
          <div
            id="plan-summary-chart"
            role="img"
            aria-label={plan_chart_label(@chart)}
            data-role="plan-summary-chart"
            class="relative flex h-28 items-end gap-px border-b border-base-300"
          >
            <i
              :for={bar <- @chart.bars}
              id={"plan-summary-bar-#{bar.start_secs}"}
              data-role="plan-summary-bar"
              data-over-listed={to_string(bar.over_listed?)}
              style={"height: #{bar.height}%"}
              class={["min-w-0 flex-1", (bar.over_listed? && "bg-error") || "bg-base-content/40"]}
              title={"#{clock(bar.start_secs)} · #{bar.count}"}
            >
            </i>
            <span
              id="plan-summary-listed-line"
              data-role="plan-summary-listed-line"
              data-listed={to_string(@chart.row.listed)}
              style={"bottom: #{@chart.listed_height}%"}
              class="pointer-events-none absolute inset-x-0 border-t-2 border-dashed border-warning"
            >
            </span>
            <span
              id="plan-summary-listed-label"
              class="pointer-events-none absolute right-0 -translate-y-full bg-base-100 px-1 text-xs font-semibold text-warning"
              style={"bottom: #{@chart.listed_height}%"}
            >
              {@chart.row.listed} listed
            </span>
          </div>
          <div class="mt-1 flex justify-between text-xs text-base-content/70">
            <span>{clock(List.first(@chart.bins).start_secs)}</span>
            <span>{clock(List.last(@chart.bins).start_secs + 900)}</span>
          </div>
          <p id="plan-summary-chart-summary" class="mt-2 text-sm">
            {chart_summary(@chart.row)}
          </p>
        </div>
      </section>

      <section id="plan-summary-time" class="mt-6 border-t border-base-300 pt-5">
        <h3 class="text-base font-bold">Time and distance</h3>
        <dl
          id="plan-summary-totals"
          class="mt-2 grid grid-cols-[1fr_auto] items-baseline gap-x-4 gap-y-2 text-sm"
        >
          <.plan_summary_total
            :for={{key, label, value, estimated} <- total_rows(@figures, @estimated?)}
            key={key}
            label={label}
            value={value}
            estimated={estimated}
          />
        </dl>
        <p id="plan-summary-time-note" class="mt-2 text-sm text-base-content/70">
          Includes travel to and from the garage.{provisional_note(@errors?)}
        </p>
      </section>

      <section id="plan-summary-relief" class="mt-6 border-t border-base-300 pt-5">
        <h3 class="text-base font-bold">Operator changes</h3>

        <p
          :if={is_nil(@max_piece_minutes)}
          id="plan-summary-relief-off"
          class="mt-2 text-sm text-base-content/70"
        >
          Not checked. Mark the stops where operators can change and set the limit to check each
          block.
        </p>

        <div :if={@max_piece_minutes} id="plan-summary-relief-limit" class="mt-2">
          <dl class="grid grid-cols-[1fr_auto] gap-x-4 gap-y-2 text-sm">
            <dt class="text-base-content/70">Longest time before a change</dt>
            <dd
              data-role="plan-summary-relief-longest"
              class={[
                "text-right font-semibold tabular-nums",
                too_long?(@longest_stretch, @max_piece_minutes) && "text-warning"
              ]}
            >
              {stretch_label(@longest_stretch)}
            </dd>
          </dl>
          <p id="plan-summary-relief-note" class="mt-2 text-sm text-base-content/70">
            Limit {duration(@max_piece_minutes)} · {count_label(@relief_stop_count, "stop", "stops")} marked.{too_long_note(
              @longest_stretch,
              @max_piece_minutes
            )}
          </p>
        </div>
      </section>
    </.drawer>
    """
  end

  # One figure row of the Time and distance block. A `dl` may only hold `dt` and
  # `dd`, so the row is a component rather than a bare fragment: the value is one
  # slot and the `est.` mark stays in it, quiet, where the reference puts it.
  attr :key, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :estimated, :boolean, required: true

  defp plan_summary_total(assigns) do
    ~H"""
    <dt class="text-base-content/70">{@label}</dt>
    <dd data-role={"plan-summary-total-#{@key}"} class="text-right font-semibold tabular-nums">
      {@value}<span
        :if={@estimated}
        data-role="plan-summary-est"
        class="font-normal text-base-content/70"
      >
        est.
      </span>
    </dd>
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
  header button that opened it.
  """
  attr :open, :boolean, required: true
  attr :form, :any, required: true
  attr :error, :string, default: nil

  def layover_drawer(assigns) do
    ~H"""
    <.drawer
      id="layover-drawer"
      open={@open}
      title="Minimum layover"
      initial_focus={:first_field}
      initial_focus_id="layover-minutes"
      return_focus_id="blocks-min-layover"
    >
      <.form
        for={@form}
        id="layover-form"
        novalidate
        phx-change="open_drawer"
        phx-debounce="200"
        phx-submit="save_layover"
        class="space-y-2"
      >
        <.input
          id="layover-minutes"
          field={@form[:min_layover_minutes]}
          type="number"
          min={0}
          max={120}
          step={1}
          label="Minimum layover (minutes)"
          help="Flag connections shorter than this value. It applies to every day type in this version."
          class="input input-lg w-full max-w-40 block"
        />

        <p :if={@error} id="layover-error" role="alert" class="text-sm text-error">{@error}</p>

        <div class="flex flex-wrap items-center gap-3 pt-2">
          <button type="submit" id="layover-submit" class="btn btn-primary min-h-11">
            Save minimum
          </button>
          <button type="button" id="layover-cancel" phx-click="close_drawer" class="btn min-h-11">
            Cancel
          </button>
        </div>
      </.form>
    </.drawer>
    """
  end

  @doc """
  Renders the read-only trip drawer: the trip's identity, its stored times and
  block, every day type it runs in with the all-dates scope sentence, its own
  findings and every type 4/5 record naming it.

  The day-type links patch `day` and `trip`, so one link follows the trip to
  another day type's page with the drawer open again (AC-29). The record list is
  read-only and holds every record that names the trip, including one whose pair
  has no hosting gap (AC-25, INV-3). A frequency trip carries the repeat text and
  an unplottable one its missing-time warning; neither can be plotted.

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
      assign(assigns, :total_dates, Enum.sum(Enum.map(assigns.day_types, & &1.date_count)))

    ~H"""
    <.drawer
      id="trip-drawer"
      open={@open}
      title={"Trip " <> @trip.trip_id}
      return_focus_id={"trip-bar-" <> dom_token(@trip.trip_id)}
    >
      <div class="flex flex-wrap items-center gap-2">
        <.route_badge_for route_id={@trip.route_id} routes={@routes} />
        <strong>{route_name(@routes, @trip.route_id)}</strong>
        <.status_badge :if={@trip.frequency?} status="info" label="Frequency service" />
      </div>

      <dl class="mt-4 divide-y divide-base-300 border-y border-base-300 text-sm">
        <.trip_field label="Headsign">{blank_dash(@trip.trip_headsign)}</.trip_field>
        <.trip_field label="Pattern">{blank_dash(@trip.route_pattern_id)}</.trip_field>
        <.trip_field label="Calendar">{@calendar_label}</.trip_field>
        <.trip_field label="Departure">
          <strong>{clock(@trip.first_departure)}</strong> · {stop_name(@trip.first_stop)}
        </.trip_field>
        <.trip_field label="Arrival">
          <strong>{clock(@trip.last_arrival)}</strong> · {stop_name(@trip.last_stop)}
        </.trip_field>
        <.trip_field label="GTFS time">
          {gtfs_time(@trip.first_departure)} → {gtfs_time(@trip.last_arrival)}
        </.trip_field>
        <.trip_field label="Block ID">{@trip.block_id || "Unassigned"}</.trip_field>
      </dl>

      <.callout
        :if={@trip.frequency?}
        id="trip-frequency"
        kind="info"
        title={frequency_text(@trip)}
      />

      <.callout
        :if={not @trip.plottable?}
        id="trip-unplottable"
        kind="warning"
        title="An endpoint time is missing."
      >
        This trip remains in the data and cannot be plotted or assigned until its timing
        is restored.
      </.callout>

      <section id="trip-day-types" class="mt-6 border-t border-base-300 pt-4">
        <h3 class="text-sm font-semibold">Runs on {@total_dates} dates in:</h3>
        <div class="mt-2 space-y-1">
          <.link
            :for={day_type <- @day_types}
            patch={day_type_trip_path(@version_id, day_type.key, @trip.trip_id)}
            data-role="trip-day-type"
            data-day={day_type.key}
            class="link link-primary block min-h-11 content-center"
          >
            {day_type_option_label(day_type)}
          </.link>
        </div>
        <p :if={@day_types == []} class="mt-2 text-sm text-base-content/70">
          This trip has no active service dates.
        </p>
        <p class="mt-2 text-sm text-base-content/70">
          Changes apply to all {@total_dates} dates this trip runs.
        </p>
      </section>

      <section :if={@findings != []} class="mt-6 border-t border-base-300 pt-4">
        <h3 class="text-sm font-semibold">Checks</h3>
        <p
          :for={finding <- @findings}
          data-role="trip-finding"
          data-code={finding.code}
          class="mt-2 flex flex-wrap items-center gap-2 text-sm"
        >
          <.status_badge
            status={severity_status(finding.severity)}
            label={code_label(finding.code)}
          />
          <span>{finding_detail(finding)}</span>
        </p>
      </section>

      <section id="trip-transfers" class="mt-6 border-t border-base-300 pt-4">
        <h3 class="text-sm font-semibold">Transfer records · {length(@in_seat)}</h3>
        <div class="mt-2 space-y-3">
          <div
            :for={entry <- @in_seat}
            data-role="trip-transfer"
            data-transfer-type={entry.row.transfer_type}
            class="border-l-4 border-base-300 pl-3"
          >
            <div class="flex flex-wrap items-center gap-2">
              <strong>{transfer_type_label(entry.row.transfer_type)}</strong>
              <.status_badge
                status={transfer_state_status(entry.state)}
                label={transfer_state_label(entry.state)}
              />
            </div>
            <p class="text-sm">Trip {entry.row.from_trip_id} → {entry.row.to_trip_id}</p>
            <p data-role="trip-transfer-state" class="text-sm text-base-content/70">
              {in_seat_state_text(entry.state)}
            </p>
          </div>
        </div>
        <p :if={@in_seat == []} class="mt-2 text-sm text-base-content/70">
          No type 4/5 records reference this trip.
        </p>
      </section>

      <%!-- The trip's own assign controls: a blocked trip can be removed from its
      block, and any eligible trip can open the destination picker in this drawer
      (step 25). An ineligible trip keeps “Remove from block” only, because an
      assignment needs usable times and a single trip (R10). --%>
      <div
        :if={@trip.block_id || eligible?(@trip)}
        class="mt-6 flex flex-wrap gap-2 border-t border-base-300 pt-4"
      >
        <button
          :if={@trip.block_id}
          id="trip-unassign"
          type="button"
          phx-click="unassign"
          phx-value-scope="trip"
          phx-value-trip={@trip.trip_id}
          class="btn btn-sm min-h-11"
        >
          Remove from block
        </button>
        <button
          :if={eligible?(@trip)}
          id="trip-change-assignment"
          type="button"
          phx-click="open_assign"
          phx-value-scope="trip"
          phx-value-trip={@trip.trip_id}
          aria-expanded={to_string(@assign != nil)}
          class="btn btn-sm btn-primary min-h-11"
        >
          {if @trip.block_id, do: "Change assignment", else: "Assign trip"}
        </button>
      </div>

      <.assign_form
        :if={@assign && @assign.scope == :trip && @trip.id in @assign.trip_ids}
        assign={@assign}
        form={@assign_form}
        options={@destination_options}
        total={@destination_total}
        total_dates={@total_dates}
      />

      <%!-- “Back to block” is what a trip opened from the block drawer gets; a trip
      opened from a bar or a marker has no block context and no back link. --%>
      <div :if={@back_block} class="mt-6 border-t border-base-300 pt-4">
        <button
          id="trip-back-to-block"
          type="button"
          phx-click="open_block"
          phx-value-block={@back_block}
          class="btn btn-sm min-h-11"
        >
          Back to block {@back_block}
        </button>
      </div>
    </.drawer>
    """
  end

  @doc """
  Renders the single-trip assignment form: the scope sentence, the “Find a
  block” search, the destination radio list and “Save assignment”.

  The form posts one `submit_assign` after the search has been narrowed by the
  debounced `search_destination` event, so the reader chooses one of at most 25
  matching block IDs instead of scanning the day type (AC-26). “New block” is
  always first because a new ID is resolved under the lock before the review; an
  exact match leads the results; a blocked trip also offers “No block”, which
  removes it. A failed save keeps the chosen radio checked and prints the
  sentence in `#assign-error`, and an ineligible trip is named instead of being
  silently dropped (FH-18).
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
      class="mt-3 space-y-3"
    >
      <p class="text-sm text-base-content/70">
        {count_label(@trip_count, "trip", "trips")} · {@total_dates} affected dates
      </p>

      <div class="field">
        <.input
          id="destination-search"
          field={@form[:search]}
          type="search"
          label="Find a block"
          placeholder="Search block ID"
          autocomplete="off"
          help="Choose an existing ID or create a new block. This does not suggest operational compatibility."
        />
      </div>

      <%!-- An ineligible trip is named with its own reason, never skipped
      silently (FH-18). A selection gets its own callout: the reason per trip
      and “Use eligible trips”, which drops the ineligible trips and keeps the
      dialog open on what remains (AC-24). --%>
      <.callout
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
        <p>No trips will be changed until the selection is eligible.</p>
        <button
          :if={@assign.scope == :selection}
          id="bulk-use-eligible"
          type="button"
          phx-click="open_assign"
          phx-value-scope="selection"
          phx-value-eligible="true"
          class="link link-primary mt-1 inline-flex min-h-11 items-center"
        >
          Use eligible trips
        </button>
      </.callout>

      <fieldset>
        <legend class="text-sm font-medium">Destination block</legend>
        <div class="mt-2 space-y-2">
          <label class="flex min-h-11 cursor-pointer items-center gap-2 border border-base-300 px-3 py-2 has-[:checked]:border-primary has-[:checked]:bg-primary/5">
            <input
              type="radio"
              id="destination-new"
              name={@form[:destination].name}
              value="new"
              checked={@assign.target in [nil, :new]}
              class="radio radio-sm"
            />
            <span>
              <span class="text-sm font-medium">New block</span>
              <small class="block text-base-content/70">
                A new ID is resolved before the review.
              </small>
            </span>
          </label>

          <label
            :for={option <- @options}
            data-role="destination-option"
            data-block={option.block_id}
            class="flex min-h-11 cursor-pointer items-center gap-2 border border-base-300 px-3 py-2 has-[:checked]:border-primary has-[:checked]:bg-primary/5"
          >
            <input
              type="radio"
              id={"destination-block-" <> dom_token(option.block_id)}
              name={@form[:destination].name}
              value={option.block_id}
              checked={@assign.target == option.block_id}
              class="radio radio-sm"
            />
            <span>
              <span class="text-sm font-medium">Block {option.block_id}</span>
              <small class="block text-base-content/70">{option.detail}</small>
            </span>
          </label>

          <label
            :if={@assign.blocked?}
            data-role="destination-option"
            data-block="none"
            class="flex min-h-11 cursor-pointer items-center gap-2 border border-base-300 px-3 py-2 has-[:checked]:border-primary has-[:checked]:bg-primary/5"
          >
            <input
              type="radio"
              id="destination-none"
              name={@form[:destination].name}
              value="none"
              checked={@assign.target == :none}
              class="radio radio-sm"
            />
            <span>
              <span class="text-sm font-medium">No block</span>
              <small class="block text-base-content/70">Remove this trip from its block.</small>
            </span>
          </label>
        </div>
        <p id="destination-summary" class="mt-2 text-sm text-base-content/70" role="status">
          {@search_summary}
        </p>
      </fieldset>

      <p id="assign-error" class="text-sm text-error" role="alert">{@assign.error}</p>

      <p class="text-sm text-base-content/70">
        Assignment follows the selected trips across all their dates. Changes with
        additional consequences require confirmation.
      </p>

      <div class="flex justify-end">
        <button type="submit" class="btn btn-primary min-h-11" phx-disable-with="Saving…">
          Save assignment
        </button>
      </div>
    </.form>
    """
  end

  @doc """
  Renders the selection-scoped assignment form in a dialog.

  A selection of trips has no single trip drawer to hold the form, so the bulk
  bar opens it here: the same `assign_form/1` with the selection's trip count and
  affected dates, and one dismiss control that leaves the selection untouched.
  The form is its own submit surface, so the dialog renders a single action
  (`single_action`); closing it through “Cancel” or the backdrop fires
  `close_drawer`, which drops the selection-scoped form.
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
      open={true}
      title="Assign selected trips"
      confirm_label="Save assignment"
      pending_label="Saving…"
      on_confirm="submit_assign"
      on_cancel="close_drawer"
      cancel_label="Cancel"
      size="lg"
      return_focus_id="bulk-assign"
      single_action
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
  Renders the block-change review: the day type and version, the preview counts,
  the assignment changes table and one effect card per affected day type with its
  added problems, plus the existing problems and new notices.

  The dialog is the `confirm_dialog` review surface, so the confirm label repeats
  the verb and its object (“Assign 1 trip”) and the cancel action is “Change
  selection”, which returns to the form with its target. A stale confirmation
  prints “Trips changed since you reviewed. Check the changes again.” above the
  refreshed review and never saves; a failed save prints its own sentence above
  the unchanged review, so a retry repeats exactly the reviewed command (AC-12,
  AC-26).
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
        notices: added_notices(assigns.review),
        existing: existing_problem_count(assigns.review),
        attributes?: attributes?(assigns.review)
      )

    ~H"""
    <.confirm_dialog
      id="block-review"
      open={@review != nil}
      title="Review block changes"
      confirm_label={@confirm_label}
      pending_label="Saving…"
      on_confirm="confirm_review"
      on_cancel="cancel_review"
      cancel_label="Change selection"
      described_by="block-review-body"
      size="lg"
      confirm_variant="primary"
      return_focus_id={@return_focus_id}
      data-initial-focus-id="block-review-changes"
    >
      <div :if={@review}>
        <.callout
          :if={@stale?}
          id="block-review-stale"
          kind="warning"
          title="Trips changed since you reviewed. Check the changes again."
        />

        <.callout :if={@error} id="block-review-error" kind="error" title={@error} />

        <div class="flex flex-wrap items-center justify-between gap-2">
          <p class="text-sm text-base-content/70">
            {(@day_type && @day_type.label) || "Day type"} · {@version_name}
          </p>
          <.status_badge status="warning" label="Preview · not saved" />
        </div>

        <div class={["mt-3 grid gap-2", (@attributes? && "grid-cols-2") || "grid-cols-3"]}>
          <div :if={not @attributes?}>
            <strong>{length(@review.changes)}</strong>
            <span class="block text-base-content/70">trips changing block</span>
          </div>
          <div>
            <strong>{@review.affected_date_count}</strong>
            <span class="block text-base-content/70">affected service dates</span>
          </div>
          <div>
            <strong>{@review.added_problem_count}</strong>
            <span class="block text-base-content/70">new problems across day types</span>
          </div>
        </div>

        <h3 id="block-review-changes" tabindex="-1" class="mt-4 text-sm font-semibold">
          {if @attributes?, do: "Garage and type", else: "Assignment changes"}
        </h3>

        <p :if={@attributes?} id="block-review-attributes" class="text-sm">
          No trip changes block. The block's garage and type are saved for every calendar it runs
          on, and the dates below are the ones that changes.
        </p>

        <.table :if={not @attributes?} id="block-review-changes-table" rows={@review.changes}>
          <:col :let={change} label="Trip">{change.trip.trip_id}</:col>
          <:col :let={change} label="Current block">{change.from || "Unassigned"}</:col>
          <:col :let={change} label="Proposed block">
            <strong data-role="review-proposed">{change.to || "Unassigned"}</strong>
          </:col>
        </.table>

        <h3 class="mt-4 text-sm font-semibold">
          {if @attributes?, do: "Affected calendars", else: "Affected dates"}
        </h3>

        <div class="mt-2 space-y-3">
          <div
            :for={effect <- @review.effects}
            id={"review-effect-" <> effect.day_type.key}
            data-role="review-effect"
            data-selected={to_string(effect.selected?)}
            class="border border-base-300 px-3 py-2"
          >
            <strong>
              {if effect.selected?, do: "Current view", else: "Also changes"} · {effect.day_type.label} · {date_count_label(
                effect.day_type.date_count
              )}
            </strong>
            <p class="mt-1">{effect_sentence(effect, @review)}</p>
            <p :for={split <- effect.splits}>
              Block {split.block_id} splits: {split.remaining} {if split.remaining == 1,
                do: "trip stays",
                else: "trips stay"} on {split.block_id}.
            </p>
            <p
              :for={finding <- added_problems(effect)}
              data-role="review-added"
              class="mt-1 flex flex-wrap items-center gap-2"
            >
              <span class="font-medium">Added</span>
              <.status_badge
                status={severity_status(finding.severity)}
                label={code_label(finding.code)}
              />
              <span>{finding_detail(finding)}</span>
            </p>
            <p :if={added_problems(effect) == []} class="mt-1 text-base-content/70">
              No new timing or transfer problems on these dates.
            </p>
          </div>
        </div>

        <details class="mt-4 border-t border-base-300 pt-2">
          <summary class="min-h-11 cursor-pointer content-center">
            Existing problems and new notices
          </summary>
          <p class="mt-2 text-sm text-base-content/70">
            {@existing} existing problem occurrences remain across affected day types.
          </p>
          <p :for={{label, notice} <- @notices} class="mt-1 text-sm">{label} · {notice}</p>
          <p :if={@notices == []} class="mt-1 text-sm text-base-content/70">
            No additional notices.
          </p>
        </details>

        <p class="mt-3 text-sm text-base-content/70">
          {if @attributes?,
            do:
              "Trip times, stop order, block IDs, and transfer records stay unchanged by this save.",
            else: "Trip times, stop order, and transfer records stay unchanged by this assignment."}
        </p>
      </div>
    </.confirm_dialog>
    """
  end

  @doc """
  Renders the read-only gap drawer: both trips with their times, the layover or
  handoff sentence, the rider note for a handoff a rider can make on foot, and
  any type 4/5 record for the pair.

  The sentence and the note come from the block's own gap and handoff (R5), so the
  drawer re-derives neither a distance nor a handoff kind: an empty move is the
  only kind that never prints the rider note, and it is the only one that says the
  driving time is unknown. A negative gap is an overlap, and its drawer prints the
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
    assigns = assign(assigns, :text, gap_text(assigns.gap, assigns.from, assigns.to))

    ~H"""
    <.drawer id="gap-drawer" open={@open} title="Time between trips">
      <p class="text-sm text-base-content/70">
        Block {@block_id} · {@from.trip_id} → {@to.trip_id}
      </p>

      <dl class="mt-4 divide-y divide-base-300 border-y border-base-300 text-sm">
        <.trip_field label="Arrival">
          <strong>{clock(@from.last_arrival)}</strong> · {stop_name(@from.last_stop)}
        </.trip_field>
        <.trip_field label="Departure">
          <strong>{clock(@to.first_departure)}</strong> · {stop_name(@to.first_stop)}
        </.trip_field>
      </dl>

      <%!-- A layover below the minimum is the block's own :short_layover finding,
      which is also what outlines the timeline's gap bar. --%>
      <.callout
        id="gap-text"
        data-short={to_string(@short?)}
        kind={if @short?, do: "warning", else: "info"}
        title={@text}
      />

      <p :if={rider_note?(@gap)} id="gap-rider-note" class="mt-3 text-sm">
        Trip planners such as Google Maps may tell riders they can stay on board.
      </p>

      <section id="gap-transfers" class="mt-6 border-t border-base-300 pt-4">
        <h3 class="text-sm font-semibold">Transfer records · {length(@records)}</h3>
        <div class="mt-2 space-y-3">
          <div
            :for={entry <- @records}
            data-role="gap-transfer"
            data-transfer-type={entry.row.transfer_type}
            class="border-l-4 border-base-300 pl-3"
          >
            <div class="flex flex-wrap items-center gap-2">
              <strong>{transfer_type_label(entry.row.transfer_type)}</strong>
              <.status_badge
                status={transfer_state_status(entry.state)}
                label={transfer_state_label(entry.state)}
              />
            </div>
            <p class="text-sm">Trip {entry.row.from_trip_id} → {entry.row.to_trip_id}</p>
            <p data-role="gap-transfer-state" class="text-sm text-base-content/70">
              {in_seat_state_text(entry.state)}
            </p>
          </div>
        </div>
        <p :if={@records == []} class="mt-2 text-sm text-base-content/70">
          No explicit record for this pair. Inferred rider connections vary by consumer.
        </p>
      </section>

      <div class="mt-6 flex flex-wrap gap-2 border-t border-base-300 pt-4">
        <button
          :for={trip <- [@from, @to]}
          type="button"
          data-role="gap-inspect"
          phx-click="open_trip"
          phx-value-trip={trip.trip_id}
          phx-value-block={@back_block}
          class="btn btn-sm min-h-11"
        >
          Inspect {trip.trip_id}
        </button>
        <button
          :if={@back_block}
          id="gap-back-to-block"
          type="button"
          phx-click="open_block"
          phx-value-block={@back_block}
          class="btn btn-sm min-h-11"
        >
          Back to block {@back_block}
        </button>
      </div>
    </.drawer>
    """
  end

  @doc """
  Renders the block drawer as the vehicle's day: the day's summary line, the
  block's problems as callouts, a Time · Activity · Details table of the vehicle's
  whole day, then the block's three actions (AC-36).

  The summary line is the day's own figures — the trip count, the *platform* span
  from `Movements.build/3` (so a pull-out before midnight and a pull-back after it
  are inside the range), the hours out of the garage and the day's two kilometre
  totals. The `(est.)` mark follows the block's own legs rather than the day's: an
  entered driving time is a human's real route, so a block whose every leg is
  entered carries no mark (AC-7).

  The table's rows come from the block's `Movements.build/3` result (R2, R3,
  INV-8) in the order the vehicle does them: the pull-out from the resolved
  garage, each trip of the `Checks.sequence/1` order, the drive and the wait
  between two trips, and the pull-back. A block with no resolvable garage has no
  pull rows at all, and an empty move, a drive the vehicle cannot make in time
  and an overlap each say so rather than rounding away.

  “Inspect” opens the trip drawer with the block kept, which is what gives that
  drawer its back link (AC-25), and every drive, wait and overlap opens the gap
  drawer with the block kept, so that drawer offers “Back to block <id>”. The
  overlap row is the only way to open that drawer for an overlapping pair, whose
  timeline bar is deliberately suppressed.

  The problems are callouts, worst first, and a problem about one connection
  carries “Open this connection” for the same gap drawer the row opens.
  In-seat records stay read-only: the drawer adds no editing control and no
  command for them (INV-3).

  The actions are the reference's “Rename block”, “Merge into…” and “Remove all
  trips” (AC-27). A rename renames this block's trips on the selected day type, a
  merge joins them to another block of the day type (the picker offers no “New
  block” and no “No block”, because a merge always lands on an existing ID), and
  remove-all takes this block's trips on the selected day type back to the pool.
  Each one submits the same `submit_block_action` event, so all three run through
  the reviewed command and show the same review dialog with its split, its
  affected day types and its added problems.

  A refusal prints under the control that caused it — the rename field's own
  error sits inside the form, so the input keeps what the reader typed (AC-27) —
  and the rename field starts on the block's own ID, so resubmitting it unchanged
  is the “Enter a different block ID.” case rather than a silent no-op.
  """
  attr :open, :boolean, required: true
  attr :block, :map, required: true
  attr :routes, :map, required: true

  attr :movements, :map,
    required: true,
    doc: "the block's `Movements.build/3` result (R2, R3), which the day load already derived"

  attr :max_piece_minutes, :integer,
    default: nil,
    doc: "the operator-change limit; with none set no wait can carry the change mark"

  attr :action, :map,
    default: nil,
    doc: "the drawer's action state, nil while the drawer is closed"

  attr :form, :any, default: nil, doc: "the rename field's and merge search's form"

  attr :merge_options, :list,
    default: [],
    doc: "the other blocks of the day type the picker offers"

  attr :merge_total, :integer, default: 0, doc: "the merge search's match count before the cap"

  attr :attributes, :map,
    default: nil,
    doc: "the garage and type form's state, nil while the drawer is closed"

  attr :attributes_form, :any, default: nil, doc: "the two pickers' form"

  attr :garages, :list, default: [], doc: "the organization's garages, by name"

  attr :vehicle_types, :list, default: [], doc: "the organization's vehicle types, by name"

  attr :route_settings, :map,
    default: %{},
    doc: "per-route home garage and required type, read only to explain a value (R4)"

  attr :day_types, :list,
    default: [],
    doc:
      "every day type the version derives, so the preview can name the other ones the save reaches"

  attr :selected_day_type, :map,
    default: nil,
    doc: "the day type the page is showing; the preview never names it as “also”"

  def block_drawer(assigns) do
    assigns =
      assigns
      |> assign(:summary, assigns.block.summary)
      |> assign(:problems, block_problems(assigns.block))
      |> assign(
        :rows,
        vehicle_day_rows(
          assigns.block,
          assigns.movements,
          assigns.routes,
          assigns.max_piece_minutes
        )
      )
      |> assign(:estimated?, estimated_leg?(assigns.movements))
      |> assign(
        :also_changes,
        also_changes(
          assigns.attributes,
          assigns.block,
          assigns.day_types,
          assigns.garages,
          assigns.vehicle_types,
          assigns.selected_day_type
        )
      )

    ~H"""
    <.drawer id="block-drawer" open={@open} title={"Block " <> @summary.block_id}>
      <p id="block-day-summary" class="text-sm text-base-content/70">
        {count_label(@summary.trip_count, "trip", "trips")} · {time_out(
          @summary.start_secs,
          @summary.end_secs
        )} · {hours(@summary.hours)} h out of the garage · {km(@movements.service_km)} km with
        riders, {km(@movements.deadhead_km)} km without{if @estimated?, do: " (est.)", else: ""}
      </p>

      <div :if={@problems != []} id="block-problems" class="mt-4 grid gap-2">
        <.callout
          :for={problem <- @problems}
          kind={severity_status(problem.severity)}
          title={code_label(problem.code)}
          data-role="block-problem"
          data-code={problem.code}
        >
          {finding_detail(problem)}
          <button
            :if={connection = connection_gap(problem, @block)}
            type="button"
            data-role="block-open-connection"
            phx-click="open_gap"
            phx-value-from={connection.from_id}
            phx-value-to={connection.to_id}
            phx-value-block={@summary.block_id}
            class="link link-primary min-h-11"
          >
            Open this connection
          </button>
        </.callout>
      </div>

      <%!-- The hook is the page's existing scoped `FormErrorFocus` hook, and it
      is scoped to this form on purpose: a refusal here pushes a focus target
      that only the form's own hook can reach, so the reader's focus never
      crosses into the timeline behind the drawer. --%>
      <div
        :if={@attributes}
        id="block-attributes"
        phx-hook="FormErrorFocus"
        class="mt-5 border-t border-base-300 pt-4"
      >
        <.form
          for={@attributes_form}
          id="block-attributes-form"
          phx-change="block_attributes_change"
          phx-submit="save_block_attributes"
          class="grid gap-4"
        >
          <.input
            id="block-garage"
            field={@attributes_form[:garage_id]}
            type="select"
            label="Garage"
            options={Enum.map(@garages, &{&1.name, &1.id})}
            prompt={garage_prompt(@block)}
            errors={attribute_errors(@attributes)}
            help={garage_help(@block, @garages, @route_settings, @routes, @day_types)}
          />

          <.input
            id="block-vehicle-type"
            field={@attributes_form[:vehicle_type_id]}
            type="select"
            label="Vehicle type (optional)"
            options={Enum.map(@vehicle_types, &{&1.name, &1.id})}
            prompt="Any type"
            help={vehicle_type_help(@block, @route_settings, @vehicle_types, @routes)}
          />

          <div :if={@also_changes != []} id="block-also-changes" class="grid gap-2">
            <p class="text-sm font-semibold">Also changes</p>
            <div
              :for={change <- @also_changes}
              data-role="block-also-changes"
              data-day-type={change.key}
              class="rounded-box border border-base-300 bg-base-200/40 px-4 py-3 text-sm"
            >
              <p class="font-semibold">
                {change.label} · {date_count_label(change.date_count)}
              </p>
              <p class="mt-1">{change.sentence}</p>
            </div>
          </div>

          <p
            :if={@also_changes != []}
            id="block-attributes-note"
            role="status"
            class="text-sm text-base-content/70"
          >
            Also changes {Enum.map_join(@also_changes, ", ", & &1.label)}
          </p>

          <div class="flex flex-wrap gap-3">
            <button
              type="button"
              id="block-attributes-cancel"
              phx-click="close_drawer"
              class="btn min-h-11"
            >
              Cancel
            </button>
            <button
              type="submit"
              id="block-attributes-submit"
              phx-disable-with="Saving…"
              class="btn btn-primary min-h-11"
            >
              Save block settings
            </button>
          </div>
        </.form>
      </div>

      <h3 class="mt-6 border-t border-base-300 pt-4 text-sm font-semibold">Vehicle’s day</h3>

      <table id="block-day" class="table table-sm mt-2 w-full">
        <thead>
          <tr>
            <th scope="col">Time</th>
            <th scope="col">Activity</th>
            <th scope="col">Details</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={row <- @rows} data-role="block-day-row" data-kind={row.kind}>
            <td class="whitespace-nowrap tabular-nums text-sm">{row.time}</td>
            <td class="text-sm font-medium">{row.activity}</td>
            <td class={(row.error? && "text-sm font-semibold text-error") || "text-sm"}>
              <%= if gap = row.gap do %>
                <button
                  type="button"
                  data-role="block-gap"
                  data-kind={row.kind}
                  data-minutes={gap_minutes(gap)}
                  phx-click="open_gap"
                  phx-value-from={gap.from_id}
                  phx-value-to={gap.to_id}
                  phx-value-block={@summary.block_id}
                  class="link min-h-11 text-left"
                >
                  {row.detail}
                </button>
              <% else %>
                <span>{row.detail}</span>
                <button
                  :if={row.trip}
                  type="button"
                  data-role="block-inspect"
                  phx-click="open_trip"
                  phx-value-trip={row.trip.trip_id}
                  phx-value-block={@summary.block_id}
                  class="link link-primary ml-2 min-h-11"
                >
                  Inspect
                </button>
              <% end %>
            </td>
          </tr>
        </tbody>
      </table>

      <div class="mt-4 space-y-3 border-t border-base-300 pt-3">
        <h3 class="text-sm font-semibold">Block actions</h3>

        <.form
          for={@form}
          id="block-rename-form"
          phx-submit="submit_block_action"
          class="space-y-2"
        >
          <input type="hidden" name="block_action[action]" value="rename" />
          <.input
            id="block-rename-id"
            field={@form[:block_id]}
            label="Block ID"
            errors={rename_errors(@action)}
            help="The ID stored in GTFS. IDs on disjoint service dates may be reused."
          />
          <button type="submit" id="block-rename-submit" class="btn btn-sm min-h-11">
            Rename block
          </button>
        </.form>

        <.form
          for={@form}
          id="block-merge-form"
          phx-change="search_destination"
          phx-debounce="200"
          phx-submit="submit_block_action"
          class="space-y-2 border-t border-base-300 pt-3"
        >
          <input type="hidden" name="block_action[action]" value="merge" />
          <.input
            id="block-merge-search"
            field={@form[:search]}
            type="search"
            label="Find a block"
            placeholder="Search block ID"
            autocomplete="off"
            help="Choose the block these trips join. A merge never creates an ID."
          />

          <fieldset>
            <legend class="text-sm font-medium">Merge into</legend>
            <div class="mt-2 space-y-2">
              <label
                :for={option <- @merge_options}
                data-role="merge-option"
                data-block={option.block_id}
                class="flex min-h-11 cursor-pointer items-center gap-2 border border-base-300 px-3 py-2 has-[:checked]:border-primary has-[:checked]:bg-primary/5"
              >
                <input
                  type="radio"
                  id={"block-merge-" <> dom_token(option.block_id)}
                  name="block_action[destination]"
                  value={option.block_id}
                  checked={@action.merge == option.block_id}
                  class="radio radio-sm"
                />
                <span>
                  <span class="text-sm font-medium">Block {option.block_id}</span>
                  <small class="block text-base-content/70">{option.detail}</small>
                </span>
              </label>
            </div>
            <p id="block-merge-summary" class="mt-2 text-sm text-base-content/70" role="status">
              {destination_summary(@merge_options, @merge_total)}
            </p>
          </fieldset>

          <p
            :if={@action.kind == :merge}
            id="block-merge-error"
            class="text-sm text-error"
            role="alert"
          >
            {@action.error}
          </p>

          <button type="submit" id="block-merge-submit" class="btn btn-sm min-h-11">
            Merge blocks
          </button>
        </.form>

        <div class="border-t border-base-300 pt-3">
          <button
            type="button"
            id="block-remove-all"
            phx-click="submit_block_action"
            phx-value-action="remove_all"
            class="btn btn-sm min-h-11"
          >
            Remove all trips
          </button>
          <p
            :if={@action.kind == :remove_all}
            id="block-remove-error"
            class="text-sm text-error"
            role="alert"
          >
            {@action.error}
          </p>
        </div>
      </div>
    </.drawer>
    """
  end

  # The rename field's own error: the sentence the context's refusal maps to, so
  # it sits under the input it belongs to (AC-27). The merge's own error has no
  # field of its own and prints under the picker instead.
  defp rename_errors(%{kind: :rename, error: error}) when is_binary(error), do: [error]
  defp rename_errors(_action), do: []

  # --- the block's garage and vehicle type (step 38) ---------------------------

  # A block whose calendars disagree has no garage to show, so the picker opens
  # on the prompt rather than on one of the two answers (AC-37, R4). Every other
  # block opens on the resolution the day load already made.
  defp garage_prompt(%{resolution: %{conflict: conflict}}) when conflict in [nil, []],
    do: nil

  defp garage_prompt(_block), do: "Choose one garage"

  # The refusal under the garage picker. It is the field's own error, so the
  # select is marked invalid and the form's focus hook lands on it.
  defp attribute_errors(%{error: error}) when is_binary(error), do: [error]
  defp attribute_errors(_attributes), do: []

  # The garage's help names where the value comes from, in the reference's three
  # cases: the calendars disagree and the picker has to settle it; the block
  # takes its first trip's route's home garage; or the route's home garage is
  # named as the answer the block currently resolves to. The route and its
  # setting are read off the loaded day, never re-resolved here (R4, INV-9).
  defp garage_help(block, garages, route_settings, routes, day_types) do
    case block.resolution.conflict do
      [_ | _] = rows ->
        "Set differently per calendar: " <>
          Enum.map_join(rows, ", ", &conflict_row_sentence(&1, garages, day_types)) <>
          ". Saving sets one garage for every calendar in this block."

      _none ->
        case route_garage(block, route_settings) do
          nil ->
            "No route on this block names a home garage."

          garage_id ->
            "Route #{route_label(routes, first_route(block))}'s home garage is " <>
              "#{garage_name(garages, garage_id)}."
        end
    end
  end

  # A conflict row names the calendar by the same rule every other surface uses:
  # the day type whose only service is this row's service, or the service ID.
  defp conflict_row_sentence(row, garages, day_types) do
    "#{garage_name(garages, row.garage_id)} on #{service_label(row.service_id, day_types)}"
  end

  defp service_label(service_id, day_types) do
    case Enum.find(day_types, &(&1.service_ids == [service_id])) do
      %{label: label} -> label
      nil -> service_id
    end
  end

  # The first trip's route is the route R4 resolves the block from, so the help
  # names the same one the resolution read.
  defp first_route(%{trips: trips}) do
    case Checks.sequence(trips) do
      [first | _rest] -> first.route_id
      [] -> trips |> List.first() |> then(&(&1 && &1.route_id))
    end
  end

  defp route_garage(block, route_settings) do
    case first_route(block) do
      nil -> nil
      route_id -> get_in(route_settings, [route_id, :garage_id])
    end
  end

  # The type's help names the requirement and the limits, as the reference does:
  # a route that requires a type says so and then lists what every type allows,
  # and a route that requires nothing lists the limits on their own.
  defp vehicle_type_help(block, route_settings, types, routes) do
    limits = Enum.map_join(types, " · ", &"#{&1.name} #{limit_label(&1.max_out_minutes)}")

    case required_type(block, route_settings) do
      nil ->
        "Limits: #{limits}."

      type_id ->
        "Route #{route_label(routes, first_route(block))} requires #{type_name(types, type_id)}. " <>
          "Limits: #{limits}."
    end
  end

  # The route is named the way this page names it everywhere else — the short
  # name, then the long one, then the ID — so the help reads “Route 12”, not the
  # route's long name.
  defp route_label(routes, route_id),
    do: route_option_label(route_id, Map.get(routes, route_id, %{}))

  defp limit_label(nil), do: "no set limit"

  defp limit_label(minutes) do
    if rem(minutes, 60) == 0,
      do: "#{div(minutes, 60)} h limit",
      else: "#{minutes} min limit"
  end

  defp required_type(block, route_settings) do
    case first_route(block) do
      nil -> nil
      route_id -> get_in(route_settings, [route_id, :required_vehicle_type_id])
    end
  end

  defp garage_name(_garages, nil), do: "no garage"

  defp garage_name(garages, garage_id) do
    case Enum.find(garages, &(&1.id == garage_id)) do
      nil -> "a garage that no longer exists"
      garage -> garage.name
    end
  end

  defp type_name(_types, nil), do: "any type"

  defp type_name(types, type_id) do
    case Enum.find(types, &(&1.id == type_id)) do
      nil -> "a type that no longer exists"
      type -> type.name
    end
  end

  # The “Also changes” preview: every other day type the same block number runs
  # on, with the value this save gives it. The block's own services are the ones
  # its rows are keyed by, so another day type is reached when it contains one of
  # them *and* holds a trip of this block (AC-19, R12) — the same two conditions
  # the context's own affected list applies, read here off the loaded day so the
  # reader sees the reach before saving rather than only in the review.
  defp also_changes(nil, _block, _day_types, _garages, _types, _day_type), do: []

  defp also_changes(
         %{garage_id: garage, vehicle_type_id: type},
         block,
         day_types,
         garages,
         types,
         selected_day_type
       ) do
    resolution = block.resolution
    change = change_parts(garage, type, resolution, garages, types)

    # A block whose calendars disagree has no single garage to compare a choice
    # against, so the reader has not decided anything yet and the preview stays
    # out of the way until the picker holds a garage (AC-37, R4).
    if change == [] or (undecided?(resolution) and blank_choice(garage) == nil) do
      []
    else
      services = block.trips |> Enum.map(& &1.service_id) |> MapSet.new()
      block_id = block.summary.block_id

      day_types
      |> Enum.reject(&(&1.key == selected_day_type_key(selected_day_type)))
      |> Enum.filter(&holds_block?(&1, services))
      |> Enum.map(&also_change_row(&1, block_id, services, day_types, change))
    end
  end

  # One “Also changes” card: the other day type's own label and date count, and
  # the sentence naming the trips the two share and the value this save gives it.
  defp also_change_row(day_type, block_id, services, day_types, change) do
    shared = Enum.map_join(shared_service_names(day_type, services, day_types), " and ", & &1)

    %{
      key: day_type.key,
      label: day_type.label,
      date_count: day_type.date_count,
      sentence:
        "Block #{block_id} runs the same #{shared} trips there. " <> change_sentence(change)
    }
  end

  defp blank_choice(""), do: nil
  defp blank_choice(value), do: value

  defp undecided?(%{conflict: conflict}), do: conflict not in [nil, []]
  defp undecided?(_resolution), do: false

  defp selected_day_type_key(nil), do: nil
  defp selected_day_type_key(day_type), do: day_type.key

  # Another day type is reached when it holds a trip of this block, which is a
  # day type whose services include one of the block's own services: the block
  # runs on those services, so it runs there too (AC-19, R12).
  defp holds_block?(day_type, services) do
    Enum.any?(day_type.service_ids, &MapSet.member?(services, &1))
  end

  defp shared_service_names(day_type, services, day_types) do
    day_type.service_ids
    |> Enum.filter(&MapSet.member?(services, &1))
    |> Enum.map(&service_label(&1, day_types))
  end

  # The value this save gives the other day type, in the reference's words: a
  # garage that becomes the chosen one, a type that becomes the chosen one (or
  # “any type” when the reader cleared it), and both joined when both changed.
  defp change_sentence([]), do: "Its garage and type stay the same."
  defp change_sentence([one]), do: "Its #{one} too."
  defp change_sentence([first, second]), do: "Its #{first} and its #{second} too."

  defp change_parts(garage, type, resolution, garages, types) do
    []
    |> then(
      &if blank_choice(garage) != resolution.garage_id,
        do: ["garage becomes #{garage_name(garages, blank_choice(garage))}" | &1],
        else: &1
    )
    |> then(
      &if blank_choice(type) != resolution.vehicle_type_id,
        do: ["type becomes #{type_name(types, blank_choice(type))}" | &1],
        else: &1
    )
    |> Enum.reverse()
  end

  # The vehicle's day, as the reference's “Vehicle's day” table reads it: the
  # pull-out from the resolved garage, the block's `Checks.sequence/1` trips each
  # preceded by the drive and the wait its gap holds, the pull-back, and then the
  # trips the sequence left out (a repeating or an untimed one) so a trip the
  # block owns is never hidden from a drawer that names its count.
  #
  # The gaps, the drives and the waits are the block's own `Movements.build/3`
  # result (R2, R3, INV-8) and `Checks.gaps/1` pairs, both built over the same
  # sequence and therefore aligned by index, and the operator-change mark comes
  # from the same `Relief.window`s the timeline reads — the later trip's sequence
  # index is the window's own `gap_index`, as `plotted/1` uses it. Nothing here
  # re-derives a movement or a window.
  defp vehicle_day_rows(block, movements, routes, max_piece_minutes) do
    sequence = Checks.sequence(block.trips)
    sequenced = MapSet.new(sequence, & &1.id)
    unplotted = Enum.reject(block.trips, &MapSet.member?(sequenced, &1.id))
    relief = relief_gaps(block, max_piece_minutes)
    garage = block.summary.garage_name || "the garage"

    lead =
      case movements.pull_out do
        nil -> []
        pull -> [leave_row(pull, List.first(sequence), garage)]
      end

    middle =
      sequence
      |> Enum.with_index()
      |> Enum.flat_map(fn {trip, index} ->
        connection_rows(trip, index, block, movements, relief) ++ [trip_row(trip, routes)]
      end)

    tail =
      case movements.pull_back do
        nil -> []
        pull -> [return_row(pull, List.last(sequence), garage)]
      end

    lead ++ middle ++ tail ++ Enum.map(unplotted, &trip_row(&1, routes, trip_note(block, &1)))
  end

  defp leave_row(pull, trip, garage) do
    %{
      kind: :leave,
      time: clock(pull.start_secs),
      activity: "Leave #{garage} garage",
      detail: pull_detail(pull, stop_name(trip && trip.first_stop), :out),
      error?: false,
      trip: nil,
      gap: nil
    }
  end

  defp return_row(pull, _trip, garage) do
    %{
      kind: :return,
      time: clock(pull.end_secs),
      activity: "Return to #{garage} garage",
      detail: pull_detail(pull, nil, :back),
      error?: false,
      trip: nil,
      gap: nil
    }
  end

  # The pull's own minutes and their source. An unknown drive has no minutes at
  # all, so it says so rather than printing a zero-minute drive; an entered one
  # carries no `est.` mark, because a person gave it (AC-3). The pull-out names
  # the stop it reaches, and the pull-back has no destination to name.
  defp pull_detail(%{drive_secs: nil}, to, :out), do: "Driving time unknown to #{to}"
  defp pull_detail(%{drive_secs: nil}, _to, :back), do: "Driving time unknown"

  defp pull_detail(%{drive_secs: secs, source: source}, to, :out),
    do: "#{minutes(secs)}#{est_mark(source)} to #{to}"

  defp pull_detail(%{drive_secs: secs, source: source}, _to, :back),
    do: "#{minutes(secs)}#{est_mark(source)}"

  defp trip_row(trip, routes, note \\ nil) do
    stops = "#{stop_name(trip.first_stop)} → #{stop_name(trip.last_stop)}"

    %{
      kind: :trip,
      time: time_out(trip.first_departure, trip.last_arrival),
      activity: "Trip #{trip.trip_id} · route #{route_badge_name(routes, trip.route_id)}",
      detail: if(note, do: "#{stops} · #{note}", else: stops),
      error?: false,
      trip: trip,
      gap: nil
    }
  end

  # The rows one gap contributes, in the order the vehicle meets them, and they
  # stand *before* the later trip of the pair they join. The first trip has no gap
  # before it; an overlap has no drive and no wait behind it, an
  # infeasible drive has a wait that cannot happen, and an unknown drive claims
  # nothing at all (FH-40). `index` is the later trip's own position in the
  # sequence, so the movement — and the `Relief.window` that names it — is the one
  # before it.
  defp connection_rows(_trip, 0, _block, _movements, _relief), do: []

  defp connection_rows(trip, index, block, movements, relief) do
    movement = Enum.at(movements.gaps, index - 1)
    gap = Enum.at(block.gaps, index - 1)
    to_stop = stop_name(trip.first_stop)
    change? = MapSet.member?(relief, index - 1)

    cond do
      is_nil(movement) ->
        []

      gap.gap_secs < 0 ->
        [overlap_row(movement, gap)]

      movement.kind == :layover ->
        [wait_row(movement, gap, to_stop, change?)]

      movement.feasible? == false ->
        [drive_row(movement, gap, to_stop, true)]

      movement.kind == :unknown ->
        [drive_row(movement, gap, to_stop, false)]

      true ->
        [drive_row(movement, gap, to_stop, false), wait_row(movement, gap, to_stop, change?)]
    end
  end

  # The drive before the next trip. An empty move has no known drive, so the row
  # says that; a drive longer than the gap says how long and how little there is,
  # in the error colour the reference marks it with.
  defp drive_row(movement, gap, to_stop, error?) do
    detail =
      cond do
        error? ->
          "! Needs #{minutes(movement.drive_secs)}; has #{div(gap.gap_secs, 60)}"

        movement.drive_secs == nil ->
          "Driving time unknown"

        true ->
          "#{minutes(movement.drive_secs)}#{est_mark(movement.source)}"
      end

    %{
      kind: :drive,
      time: clock(movement.arrival_secs),
      activity: "Drive to #{to_stop}",
      detail: detail,
      error?: error?,
      trip: nil,
      gap: gap
    }
  end

  defp overlap_row(movement, gap) do
    %{
      kind: :overlap,
      time: clock(movement.arrival_secs),
      activity: "Overlap",
      detail: "#{minutes(-gap.gap_secs)} overlap",
      error?: true,
      trip: nil,
      gap: gap
    }
  end

  # The wait a reachable drive leaves behind, which starts when the drive ends
  # rather than when the earlier trip arrived. The `⇄` mark is the instant an
  # operator change is possible at that stop (R5), so it follows the block's own
  # relief windows and appears only while a limit is set.
  defp wait_row(movement, gap, to_stop, relief?) do
    %{
      kind: :wait,
      time: clock(movement.arrival_secs + (movement.drive_secs || 0)),
      activity: "Wait at #{to_stop}",
      detail:
        "#{div(movement.wait_secs || gap.gap_secs, 60)} min" <>
          if(relief?, do: " · operators can change ⇄", else: ""),
      error?: false,
      trip: nil,
      gap: gap
    }
  end

  # Why a trip the sequence left out is in the block but not in the vehicle's
  # timed day. A repeating trip and a trip with no usable times are notices rather
  # than problems, so they are the trip's own row's note rather than a callout
  # above the table.
  defp trip_note(block, trip) do
    case block.findings
         |> Enum.filter(
           &(&1.code in [:frequency_trip, :unplottable] and &1.trip_ids == [trip.id])
         )
         |> Enum.map(&code_label(&1.code)) do
      [] -> nil
      labels -> Enum.join(labels, " · ")
    end
  end

  # The block's own problems, worst first, as the callouts above the table. A
  # notice is not a problem to act on here: an empty move or a repeating trip is
  # already a row in the day below, and the callouts are the errors and warnings
  # a planner works through.
  defp block_problems(block) do
    block.findings
    |> Enum.filter(&(&1.severity in [:error, :warning]))
    |> Enum.uniq_by(&Checks.finding_key/1)
    |> Enum.sort_by(&issue_rank/1)
  end

  # The connection a problem is about, when the problem is one of a connection's
  # own and names one of the block's gaps: the pair of trips that gap joins. A
  # problem about a trip alone — a wrong type, an in-seat record, a block over
  # its type's limit — has no connection to open, and a stretch with nowhere to
  # change operators names the two trips it covers rather than the connection
  # between them, so it carries no link either.
  @gap_finding_codes [
    :overlap,
    :cannot_reach,
    :short_layover,
    :repositions,
    :interlining_not_allowed
  ]

  defp connection_gap(%{code: code} = finding, block) when code in @gap_finding_codes do
    pair = MapSet.new(finding.trip_ids)

    if MapSet.size(pair) == 2 do
      Enum.find(block.gaps, &(MapSet.new([&1.from_id, &1.to_id]) == pair))
    end
  end

  defp connection_gap(_finding, _block), do: nil

  # Whether any leg of the block is an estimate rather than an entered time, which
  # is what the summary line's `est.` mark and the drive rows follow (AC-3).
  defp estimated_leg?(movements) do
    Enum.any?([movements.pull_out, movements.pull_back], &estimated_source?/1) or
      Enum.any?(movements.gaps, &estimated_source?/1)
  end

  defp estimated_source?(%{source: :estimated}), do: true
  defp estimated_source?(_leg), do: false

  defp est_mark(:estimated), do: " est."
  defp est_mark(_source), do: ""

  defp gap_minutes(%{gap_secs: secs}), do: div(secs, 60)

  # The route's badge name, the number a planner reads off the timeline. The
  # short name is the badge; a route without one falls back to its stored ID
  # rather than to its long name, which does not fit the cell.
  defp route_badge_name(routes, route_id) do
    route = Map.get(routes, route_id) || %{}
    route[:short_name] || route_id
  end

  # Copy: the layover at one stop, the same station, a nearby stop with its
  # distance and the time available, or the empty move, which alone says the
  # driving time is unknown (and, without coordinates, that it cannot be estimated
  # either).
  defp gap_text(%{gap_secs: secs}, _from, _to) when secs < 0,
    do: "#{minutes(-secs)} overlap"

  defp gap_text(%{handoff: :same_stop, gap_secs: secs}, _from, to),
    do: "#{minutes(secs)} layover at #{stop_name(to.first_stop)}"

  defp gap_text(%{handoff: :same_station, gap_secs: secs}, from, _to),
    do: "Same station · #{minutes(secs)} at #{station_name(from.last_stop)}"

  defp gap_text(%{handoff: {:nearby, meters}, gap_secs: secs}, _from, _to),
    do: "Nearby stop · #{meters} m · #{minutes(secs)} available"

  defp gap_text(%{handoff: {:moves, nil}}, from, to),
    do: move_text(from, to, " (coordinates unavailable)")

  defp gap_text(%{handoff: {:moves, _meters}}, from, to), do: move_text(from, to, "")

  defp move_text(from, to, qualifier) do
    "Moves empty: #{stop_name(from.last_stop)} → #{stop_name(to.first_stop)}. " <>
      "Driving time is unknown#{qualifier}."
  end

  # The station a same-station handoff shares is the stops' parent station; a stop
  # reference carries the parent's ID rather than its name, so the ID stands for
  # the station here.
  defp station_name(%{parent_station: parent})
       when is_binary(parent) and parent != "",
       do: parent

  defp station_name(stop), do: stop_name(stop)

  # The rider note is for a handoff a rider could make on foot: the same stop, the
  # same station or a nearby one. An empty move never shows it, however short the
  # gap (Copy, FH-19).
  defp rider_note?(%{handoff: :same_stop}), do: true
  defp rider_note?(%{handoff: :same_station}), do: true
  defp rider_note?(%{handoff: {:nearby, _meters}}), do: true
  defp rider_note?(_gap), do: false

  @doc """
  Renders the notice a `trip=` deep link shows when the trip is not in the loaded
  day type: one link per day type the trip runs in, or the unavailable sentence
  when the version holds no such trip (AC-29).
  """
  attr :open, :boolean, required: true
  attr :trip_id, :string, required: true
  attr :day_types, :list, default: nil
  attr :version_id, :string, required: true

  def trip_elsewhere(%{day_types: nil} = assigns) do
    ~H"""
    <.drawer
      id="trip-elsewhere"
      open={@open}
      title={"Trip " <> @trip_id <> " isn't in this version"}
    >
      <div id="blocks-trip-elsewhere">
        <p>Trip {@trip_id} isn't in this version.</p>
      </div>
    </.drawer>
    """
  end

  def trip_elsewhere(%{day_types: []} = assigns) do
    ~H"""
    <.drawer id="trip-elsewhere" open={@open} title="Trip has no active service dates">
      <div id="blocks-trip-elsewhere">
        <p>Trip {@trip_id} has no active service dates in this version.</p>
      </div>
    </.drawer>
    """
  end

  def trip_elsewhere(assigns) do
    ~H"""
    <.drawer id="trip-elsewhere" open={@open} title="Trip runs on another day type">
      <div id="blocks-trip-elsewhere">
        <p>Trip {@trip_id} is not in this day type.</p>
        <div class="mt-3 space-y-1">
          <.link
            :for={day_type <- @day_types}
            patch={day_type_trip_path(@version_id, day_type.key, @trip_id)}
            data-role="trip-day-type"
            data-day={day_type.key}
            class="link link-primary block min-h-11 content-center"
          >
            {day_type_option_label(day_type)}
          </.link>
        </div>
      </div>
    </.drawer>
    """
  end

  # One definition-list row of the trip drawer, so every field shares the same
  # two-column shape and a long value wraps inside its own column.
  attr :label, :string, required: true
  slot :inner_block, required: true

  defp trip_field(assigns) do
    ~H"""
    <div class="grid grid-cols-[minmax(6rem,auto)_1fr] gap-x-4 py-2">
      <dt class="text-base-content/70">{@label}</dt>
      <dd class="min-w-0">{render_slot(@inner_block)}</dd>
    </div>
    """
  end

  @doc """
  Renders the Blocks workspace: the work-queue tabs, the Timeline/List and
  Whole day/Zoom in segmented controls, the hint line and the current panel.

  The Blocks tab holds the paged timeline or the paged List view, both over the
  same streamed page of blocks: the timeline is one 36px row per block inside a
  container that scrolls in both axes, and the List view is one stacked trip
  table per block. The Unassigned tab holds the paged pool and its “Select this
  page” control. A day type with no blocks shows the first-use copy in the
  Blocks tab and still lists its unassigned trips in the pool.

  A phone-width reader gets the List view rather than the timeline: the two are
  the same page in two densities, and the List view is the full-size control
  surface (Accessibility posture). The colocated hook pushes `set_view` once when
  the URL carries no view; it never patches a URL that already does.
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
  attr :max_piece_minutes, :integer, default: nil
  attr :routes, :map, required: true
  attr :selected_ids, :any, required: true
  attr :bulk, :map, required: true

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

        <div class="flex flex-wrap items-end gap-3">
          <div
            :if={@state.panel == :blocks and @counts.blocks > 0}
            class="flex flex-wrap items-end gap-3"
          >
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

          <%!-- The reference puts “Select this page” beside the pool's tabs and
          in the List view's head, where the controls are large. --%>
          <button
            :if={select_page?(@state, @counts, @pool_visible_count, @visible_count)}
            id="blocks-select-page"
            type="button"
            phx-click="select_page"
            class="btn btn-sm min-h-11"
          >
            Select this page
          </button>
        </div>
      </div>

      <p class="border-b border-base-300 px-4 py-2 text-xs text-base-content/70">
        {workspace_note(@state, @filtered?)}
      </p>

      <%!-- The bar sits between the toolbar and the records, so it stays in view
      while the reader pages through the selection (AC-24, UX obligations). --%>
      <.bulk_bar
        :if={@bulk.count > 0}
        count={@bulk.count}
        elsewhere={@bulk.elsewhere}
        removable?={@bulk.removable?}
      />

      <%= cond do %>
        <% @state.panel == :pool -> %>
          <p
            :if={@counts.blocks == 0}
            id="blocks-workspace-guidance"
            class="text-sm text-base-content/70"
          >
            Start by selecting trips and assigning them to a new block.
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
        <% @state.view == :timeline -> %>
          <.timeline
            state={@state}
            block_rows={@block_rows}
            axis={@axis}
            routes={@routes}
            max_piece_minutes={@max_piece_minutes}
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

      <.untimed_list
        :if={@state.panel == :blocks}
        trips={@untimed_trips}
        routes={@routes}
        version_id={@state.version_id}
      />

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

      <div
        :if={@state.panel == :pool and @pool_visible_count > 0}
        id="blocks-pool-pager"
        class="border-t border-base-300 px-4"
      >
        <.pagination
          page={@state.pool_page}
          per_page={@page_size}
          total={@pool_visible_count}
          entity="trips"
          event="paginate_pool"
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
  Renders the selection bar: the count, how many of the selected trips are on
  another page, and the three bulk actions.

  The count is the whole selection, so a selection that spans pages reports how
  many of its trips the current page does not hold (“2 selected · 1 on other
  pages”) and keeps saying so while the reader pages (AC-24). “Clear selection”
  empties the set; “Assign N trips” opens the selection-scoped assignment form;
  “Remove from block” is offered only when a selected trip has a block, because
  the others are already in the pool (the reference hides it the same way).
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
      class="mx-4 my-3 flex flex-wrap items-center justify-between gap-x-4 gap-y-2 border border-primary/30 bg-primary/10 px-4 py-2.5"
    >
      <strong id="bulk-count">{bulk_count_label(@count, @elsewhere)}</strong>

      <div class="flex flex-wrap items-center gap-2">
        <button
          id="bulk-clear"
          type="button"
          phx-click="clear_selection"
          class="btn btn-sm min-h-11"
        >
          Clear selection
        </button>
        <button
          :if={@removable?}
          id="bulk-remove"
          type="button"
          phx-click="unassign"
          phx-value-scope="selection"
          class="btn btn-sm min-h-11"
        >
          Remove from block
        </button>
        <button
          id="bulk-assign"
          type="button"
          phx-click="open_assign"
          phx-value-scope="selection"
          class="btn btn-sm btn-primary min-h-11"
        >
          Assign {count_label(@count, "trip", "trips")}
        </button>
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
  Issues; the block's heading also carries its two distance figures, `km with
  riders` and `km without (est.)`, read from the block's own movements (AC-32)
  and the same numbers the Plan summary and the export read. The route's long
  name is the trip's secondary line, and the terminal is the destination line of
  the From → To cell.

  The gap is the layover before the trip, from the block's own `gaps/1` pairs, so
  it agrees with the timeline's gap bars; the first trip and every trip outside
  the plottable sequence have none. The Issues cell prints the trip's findings as
  status badges, worst first, or “No problems”.
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
        movements: assigns.block.movements,
        gaps: Map.new(assigns.block.gaps, &{&1.to_id, &1})
      )

    ~H"""
    <section id={@dom} class="border-t border-base-300 py-2">
      <h3 class="flex flex-wrap items-center gap-2 px-4 text-sm font-semibold">
        Block
        <button
          type="button"
          data-role="list-block"
          phx-click="open_block"
          phx-value-block={@summary.block_id}
          class="link link-primary min-h-11 inline-flex items-center"
        >
          {@summary.block_id}
        </button>
        <span class="font-normal text-base-content/70">
          {count_label(@summary.trip_count, "trip", "trips")}
        </span>
        <span class="font-normal text-base-content/70">
          <span data-role="list-km-riders" data-km={@movements.service_km}>
            {km(@movements.service_km)} km with riders
          </span>
          <span data-role="list-km-deadhead" data-km={@movements.deadhead_km}>
            {km(@movements.deadhead_km)} km without (est.)
          </span>
        </span>
      </h3>

      <.table id={"block-list-" <> @dom} rows={@rows} responsive="stack">
        <:col :let={trip} label="Select">
          <.select_trip trip={trip} checked={MapSet.member?(@selected_ids, trip.id)} />
        </:col>
        <:col :let={trip} label="Trip">
          <div>
            <strong>{trip.trip_id}</strong>
            <small class="block text-base-content/70">
              {route_name(@routes, trip.route_id)}
            </small>
          </div>
        </:col>
        <:col :let={trip} label="Route">
          <.route_badge_for route_id={trip.route_id} routes={@routes} />
        </:col>
        <:col :let={trip} label="Start">{clock(trip.first_departure)}</:col>
        <:col :let={trip} label="End">{clock(trip.last_arrival)}</:col>
        <:col :let={trip} label="From → To">
          <.endpoints trip={trip} />
        </:col>
        <:col :let={trip} label="Gap">
          <%= if gap = Map.get(@gaps, trip.id) do %>
            <span data-role="list-gap" data-minutes={div(gap.gap_secs, 60)}>
              {gap_label(gap)}
            </span>
          <% else %>
            <span class="text-base-content/70">—</span>
          <% end %>
        </:col>
        <:col :let={trip} label="Issues">
          <.issue_badges findings={Map.get(@findings_by_trip, trip.id, [])} />
        </:col>
      </.table>
    </section>
    """
  end

  @doc """
  Renders the paged Unassigned panel: the pool page, its eligibility text and
  its own empty states.

  The columns are the reference's Select, Route / trip, Block, Start → end,
  From → to, Checks and Action. A frequency trip prints “Repeats every N min ·
  not a single trip”; a trip whose endpoint time is missing prints “Time missing”
  with a link to its route's Schedules for its calendar; an eligible trip offers
  “Assign trip” (`open_assign`, scope `trip`) where the other two offer “View
  trip”.

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
    <div :if={@route_filter} id="blocks-pool-filtered-empty" class="px-4 py-8 text-center">
      <p class="text-sm text-base-content/70">No unassigned trips match</p>
      <button
        id="blocks-pool-clear-filters"
        type="button"
        phx-click="filter"
        phx-value-route=""
        phx-value-status="all"
        class="btn btn-sm min-h-11 mt-2"
      >
        Clear filters
      </button>
    </div>

    <div :if={is_nil(@route_filter)} id="blocks-pool-empty" class="px-4 py-8 text-center">
      <p class="text-sm text-base-content/70">All trips have a block</p>
    </div>
    """
  end

  def pool(assigns) do
    ~H"""
    <.table id="blocks-pool-table" rows={@pool_rows} responsive="stack">
      <:col :let={{_dom, trip}} label="Select">
        <.select_trip trip={trip} checked={MapSet.member?(@selected_ids, trip.id)} />
      </:col>
      <:col :let={{_dom, trip}} label="Route / trip">
        <div class="flex items-center gap-2">
          <.route_badge_for route_id={trip.route_id} routes={@routes} />
          <div>
            <strong>{trip.trip_id}</strong>
            <small class="block text-base-content/70">
              {route_name(@routes, trip.route_id)}
            </small>
          </div>
        </div>
      </:col>
      <:col :let={{_dom, _trip}} label="Block">Unassigned</:col>
      <:col :let={{_dom, trip}} label="Start → end">
        <div>
          <div>{clock(trip.first_departure)} → {clock(trip.last_arrival)}</div>
          <div
            :if={text = eligibility_text(trip)}
            data-role="pool-eligibility"
            class="text-sm text-base-content/70"
          >
            <%= if trip.plottable? do %>
              {text}
            <% else %>
              {text} ·
              <.link
                id={"pool-schedules-" <> dom_token(trip.trip_id)}
                navigate={schedules_path(@version_id, trip)}
                class="link link-primary"
              >
                Open in Schedules
              </.link>
            <% end %>
          </div>
        </div>
      </:col>
      <:col :let={{_dom, trip}} label="From → to">
        <.endpoints trip={trip} />
      </:col>
      <:col :let={{_dom, trip}} label="Checks">
        <.issue_badges findings={Map.get(@findings_by_trip, trip.id, [])} />
      </:col>
      <:col :let={{_dom, trip}} label="Action">
        <div class="whitespace-nowrap">
          <button
            :if={eligible?(trip)}
            type="button"
            data-role="assign-trip"
            phx-click="open_assign"
            phx-value-scope="trip"
            phx-value-trip={trip.trip_id}
            class="link link-primary min-h-11 inline-flex items-center"
          >
            Assign trip
          </button>
          <button
            :if={not eligible?(trip)}
            type="button"
            data-role="view-trip"
            phx-click="open_trip"
            phx-value-trip={trip.trip_id}
            class="link link-primary min-h-11 inline-flex items-center"
          >
            View trip
          </button>
        </div>
      </:col>
    </.table>
    """
  end

  @doc """
  Renders the “not plotted” disclosure of the Blocks panel: every trip that has
  a block but no usable endpoint time, with its reason and a link to its route's
  Schedules for its calendar.

  The timeline cannot draw these trips and the pool does not hold them, so this
  list is where a blocked trip with missing timing stays visible (AC-23).
  """
  attr :trips, :list, required: true
  attr :routes, :map, required: true
  attr :version_id, :string, required: true

  def untimed_list(assigns) do
    ~H"""
    <details
      :if={@trips != []}
      id="blocks-untimed"
      class="border-t border-base-300 px-4 py-2 text-sm"
    >
      <summary class="min-h-11 cursor-pointer content-center">
        Not plotted · {length(@trips)}
      </summary>

      <ul class="mt-2 space-y-2">
        <li
          :for={trip <- @trips}
          data-role="untimed-trip"
          data-trip={trip.trip_id}
          class="flex flex-wrap items-center gap-2"
        >
          <.route_badge_for route_id={trip.route_id} routes={@routes} />
          <strong>{trip.trip_id}</strong>
          <span data-role="untimed-reason">{eligibility_text(trip)}</span>
          <.link
            id={"untimed-schedules-" <> dom_token(trip.trip_id)}
            navigate={schedules_path(@version_id, trip)}
            class="link link-primary min-h-11 inline-flex items-center"
          >
            Open in Schedules
          </.link>
        </li>
      </ul>
    </details>
    """
  end

  # The row's selection control: a 44px target around a daisyUI checkbox, and
  # the trip's natural ID in the event. The checked state is the page's own
  # selection, so a re-streamed row shows the state the reader last set (AC-24).
  attr :trip, :map, required: true
  attr :checked, :boolean, required: true

  defp select_trip(assigns) do
    ~H"""
    <label
      class="grid min-h-11 min-w-11 place-items-center"
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
        class="checkbox"
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
      <span class="block text-base-content/70">→ {stop_name(@trip.last_stop)}</span>
    </div>
    """
  end

  # The findings that name this trip, worst first, as status badges; a trip
  # without one says so in text rather than leaving the cell blank.
  attr :findings, :list, required: true

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
      <span :if={@issues == []} class="text-base-content/70">No problems</span>
      <.status_badge
        :for={finding <- @issues}
        status={severity_status(finding.severity)}
        label={code_label(finding.code)}
        data-role="trip-issue"
        data-code={finding.code}
      />
    </div>
    """
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

  # A day-type link's URL state: the two parameters the page reads, so following
  # it opens the trip's drawer again in the day type it names.
  defp day_type_trip_path(version_id, day_key, trip_id) do
    "/gtfs/#{version_id}/blocks?" <> URI.encode_query([{"day", day_key}, {"trip", trip_id}])
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
  attr :max_piece_minutes, :integer, default: nil

  def timeline(assigns) do
    assigns =
      assigns
      |> assign(:columns, sort_columns())
      |> assign(:ticks, axis_ticks(assigns.axis))
      |> assign(:track_style, track_style(assigns.axis))

    ~H"""
    <.timeline_legend relief?={not is_nil(@max_piece_minutes)} />
    <div id="blocks-timeline-scroll">
      <table
        id="blocks-timeline"
        data-scale={@state.scale}
        aria-label="Blocks by service-day time"
      >
        <colgroup>
          <col class="blocks-col-block" />
          <col class="blocks-col-garage" />
          <col class="blocks-col-out" />
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
            max_piece_minutes={@max_piece_minutes}
          />
        </tbody>
      </table>
    </div>
    """
  end

  @doc """
  Renders one 36px block row: the sticky Block, Garage · type, Time out, Hours and
  Status cells and the track with the block's trip bars and gaps.

  Garage · type prints the block's R4 resolution — `Main · Cutaway`, `Main · Any
  type` when nothing requires a type, `No garage` when no garage resolves, and
  `Differs · Cutaway` in the warning colour when the block's calendars disagree
  (INV-9). Time out is the platform span from `Movements.build/3`, so a vehicle
  that pulls out before midnight reads `23:45 −1d–01:30 +1d`.

  The bars are the block's sequence (plottable, non-frequency trips) so they line
  up with `gaps/1`'s consecutive pairs; an unplottable or repeating trip appears
  in its block and in the Status cell's finding instead of as a bar. With a route
  filter applied, a trip of another route renders no bar and no gap, matching the
  filter that already excluded the block when it has no trip on the route.

  The garage legs and the drives come from the block's derived movements (R2, R3,
  INV-8) rather than from a second rule: a pull-out before the first bar and a
  pull-back after the last one open the block drawer, a feasible drive splits its
  gap into the hatched drive and the wait that follows it, a drive the vehicle
  cannot make in time is one clipped mark carrying `!` and no wait, and a drive
  the version cannot compute carries `?` with no wait either. Every one of them
  is a button with a title, so no information is hover-only.
  """
  attr :dom, :string, required: true
  attr :block, :map, required: true
  attr :axis, :map, default: nil
  attr :routes, :map, required: true
  attr :track_style, :string, default: nil
  attr :route_filter, :string, default: nil
  attr :max_piece_minutes, :integer, default: nil

  def block_row(assigns) do
    movements = assigns.block.movements

    assigns =
      assigns
      |> assign(:summary, assigns.block.summary)
      |> assign(:plotted, plotted(assigns.block))
      |> assign(:status, status_label(assigns.block.summary))
      |> assign(:garage, garage_type(assigns.block.summary))
      |> assign(:pull_out, movements.pull_out)
      |> assign(:pull_back, movements.pull_back)
      |> assign(:relief, relief_gaps(assigns.block, assigns.max_piece_minutes))

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
      <td class={["blocks-meta", "blocks-meta-garage", @garage.class]} title={@garage.title}>
        {@garage.text}
      </td>
      <td class={["blocks-meta", "blocks-meta-out"]}>
        {time_out(@summary.start_secs, @summary.end_secs)}
      </td>
      <td class={["blocks-meta", "blocks-meta-hours"]}>{hours(@summary.hours)}</td>
      <td class={["blocks-meta", "blocks-meta-status"]}>
        <span data-role="block-status" class="inline-flex items-center gap-1">
          <.icon name={@status.icon} class="size-3.5 shrink-0" /> {@status.label}
        </span>
      </td>
      <td class="blocks-track" style={@track_style}>
        <.pull_bar
          :if={@pull_out}
          pull={@pull_out}
          block_id={@summary.block_id}
          garage={@summary.garage_name}
          direction={:out}
          axis={@axis}
        />
        <%= for row <- @plotted do %>
          <%= if visible?(row.trip, @route_filter) do %>
            <%!-- A negative gap_secs is an overlap, whose bars already carry the mark. --%>
            <%!-- A drive the vehicle cannot make, or one the version cannot compute, --%>
            <%!-- takes the whole gap: there is no honest wait to draw after it. --%>
            <.drive_bar
              :if={row.movement && row.movement.kind != :layover && row.gap.gap_secs >= 0}
              gap={row.movement}
              from={row.previous}
              to={row.trip}
              axis={@axis}
            />
            <.gap
              :if={row.gap && row.gap.gap_secs >= 0 && waitable?(row.movement)}
              gap={row.gap}
              from={row.previous}
              axis={@axis}
              short?={row.short?}
              drive_secs={row.movement && row.movement.drive_secs}
              relief?={MapSet.member?(@relief, row.gap_index)}
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
        <.pull_bar
          :if={@pull_back}
          pull={@pull_back}
          block_id={@summary.block_id}
          garage={@summary.garage_name}
          direction={:back}
          axis={@axis}
        />
      </td>
    </tr>
    """
  end

  @doc """
  Renders the legend above the timeline: what each mark on a row means.

  The keys are the same marks the rows draw, in the order the reference lists
  them — garage travel, driving without riders and the waiting minutes, with the
  operator-change key only when a relief limit is set, because with no limit
  there is no operator change to place and no `⇄` can appear on a row.
  """
  attr :relief?, :boolean, required: true

  def timeline_legend(assigns) do
    ~H"""
    <div
      id="blocks-timeline-legend"
      class="flex flex-wrap items-center gap-x-4 gap-y-1 border-b border-base-300 bg-canvas px-4 py-2 text-[13px] text-base-content"
    >
      <span :for={{class, label} <- legend_keys(@relief?)} class="inline-flex items-center gap-1.5">
        <span class={["blocks-legend-key", class]} aria-hidden="true">{legend_mark(class)}</span>
        <span>{label}</span>
      </span>
    </div>
    """
  end

  defp legend_keys(relief?) do
    [
      {"blocks-pull", "Garage travel"},
      {"blocks-drive", "Driving without riders"},
      {"blocks-wait", "Waiting · minutes"}
    ] ++ if(relief?, do: [{"blocks-legend-relief", "Operators can change"}], else: [])
  end

  # Each key paints the mark it names, so the legend cannot drift from the
  # surface it explains; the operator-change key carries the `⇄` a marked wait
  # ends with, the others carry no text.
  defp legend_mark("blocks-legend-relief"), do: "⇄"
  defp legend_mark(_class), do: ""

  @doc """
  Renders one garage leg as a button positioned by the day type's axis.

  A pull-out runs from the garage to the first departure and a pull-back from the
  last arrival back to the garage; both open the block drawer, and the title
  names the garage, the time and where the driving time came from — an entered
  time and an estimate are different claims about the same bar. The bar itself
  carries no text, as in the reference: its minutes are in the title rather than
  competing with a trip bar's route label.
  """
  attr :pull, :map, required: true
  attr :block_id, :string, required: true
  attr :garage, :string, default: nil
  attr :direction, :atom, required: true, values: [:out, :back]
  attr :axis, :map, default: nil

  def pull_bar(assigns) do
    assigns = assign(assigns, :style, span_geometry(assigns.pull, assigns.axis))

    ~H"""
    <button
      type="button"
      data-role={(@direction == :out && "pull-out") || "pull-back"}
      data-block={@block_id}
      phx-click="open_block"
      phx-value-block={@block_id}
      style={@style}
      class="blocks-track-mark blocks-pull"
      title={pull_title(@pull, @garage, @direction)}
    >
    </button>
    """
  end

  @doc """
  Renders one drive as a button positioned by the day type's axis.

  Three shapes, each carrying its own text so the status is never colour alone: a
  feasible drive is hatched and starts the wait that follows it; a drive the
  vehicle cannot make in time takes the whole gap in a red hatch with a 2px
  outline and `!`; a drive the version cannot compute takes the gap with `?` and
  claims nothing about it (FH-40). All three open the gap drawer.
  """
  attr :gap, :map, required: true
  attr :from, :map, required: true
  attr :to, :map, required: true
  attr :axis, :map, default: nil

  def drive_bar(assigns) do
    assigns =
      assigns
      |> assign(:bad?, assigns.gap.feasible? == false)
      |> assign(:unknown?, assigns.gap.kind == :unknown)
      |> assign(:style, drive_geometry(assigns.gap, assigns.axis))

    ~H"""
    <button
      type="button"
      data-role={
        cond do
          @bad? -> "drive-bad"
          @unknown? -> "drive-unknown"
          true -> "drive"
        end
      }
      data-from={@from.id}
      data-to={@to.id}
      phx-click="open_gap"
      phx-value-from={@from.id}
      phx-value-to={@to.id}
      style={@style}
      class={[
        "blocks-track-mark",
        "blocks-drive",
        @bad? && "blocks-drive-bad",
        @unknown? && "blocks-drive-unknown"
      ]}
      title={drive_title(@gap, @from, @to)}
    >
      <span :if={@bad?} data-role="drive-bad-mark">!</span>
      <span :if={@unknown?} data-role="drive-unknown-mark">?</span>
    </button>
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
  departure, so `from` is the earlier trip of the pair; a gap the vehicle spends
  part of driving starts after that drive instead, and prints the wait it is left
  with rather than the whole gap. Its minutes print only when the bar is at least
  32px wide, which the container query reads from the bar's own width. An empty
  move draws dashed with the move icon and a short layover draws the warning
  outline, so the two differ by more than colour. A wait at a marked stop ends
  its label with `⇄` once the bar is wide enough for both, which is the instant an
  operator change is possible there (R5).
  """
  attr :gap, :map, required: true
  attr :from, :map, required: true
  attr :axis, :map, default: nil
  attr :short?, :boolean, default: false
  attr :drive_secs, :integer, default: nil
  attr :relief?, :boolean, default: false

  def gap(assigns) do
    assigns =
      assigns
      |> assign(:move?, match?({:moves, _}, assigns.gap.handoff))
      |> assign(:wait_secs, assigns.gap.gap_secs - (assigns.drive_secs || 0))
      |> assign(:style, gap_geometry(assigns.gap, assigns.from, assigns.axis, assigns.drive_secs))

    ~H"""
    <button
      type="button"
      data-role="blocks-gap"
      data-from={@from.id}
      data-to={@gap.to_id}
      data-minutes={div(@wait_secs, 60)}
      data-handoff={handoff_key(@gap.handoff)}
      data-short={to_string(@short?)}
      data-relief={to_string(@relief?)}
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
      <span class="blocks-gap-label">
        {div(@wait_secs, 60)}<span :if={@relief?} data-role="blocks-gap-relief"> ⇄</span>
      </span>
    </button>
    """
  end

  @doc """
  Prints parsed seconds as `HH:MM`, with ` −1d` before midnight and ` +1d` after
  it (Copy). A negative service-day second floors into the day before rather than
  truncating towards it, so −900 s reads 23:45 −1d rather than 00:00.
  """
  def clock(nil), do: "—"

  def clock(secs) when is_integer(secs) do
    days = Integer.floor_div(secs, 86_400)
    within = rem(secs, 86_400)

    clock =
      String.pad_leading(Integer.to_string(div(within, 3600)), 2, "0") <>
        ":" <> String.pad_leading(Integer.to_string(div(rem(within, 3600), 60)), 2, "0")

    case days do
      0 -> clock
      days when days < 0 -> clock <> " −" <> Integer.to_string(-days) <> "d"
      days -> clock <> " +#{days}d"
    end
  end

  # The Time out cell: the platform span on one line, or a dash when the block has
  # no span at all rather than a dash at either end of a pair.
  defp time_out(nil, _end_secs), do: "—"
  defp time_out(_start_secs, nil), do: "—"

  defp time_out(start_secs, end_secs) do
    clock(start_secs) <> "–" <> clock(end_secs)
  end

  # The Garage · type cell. A block whose calendars disagree has no single
  # garage, so it prints the warning word instead of one of the two names (AC-32);
  # the full text is in `title` because the column is narrower than the longest
  # garage and type names.
  defp garage_type(%{conflict?: true} = summary) do
    garage_cell("Differs", summary.type_name, "blocks-meta-garage-conflict")
  end

  defp garage_type(%{garage_name: nil}) do
    garage_cell("No garage", nil, "blocks-meta-garage-none")
  end

  defp garage_type(summary), do: garage_cell(summary.garage_name, summary.type_name, nil)

  defp garage_cell(garage, type_name, class) do
    type = type_name || "Any type"
    text = garage <> " · " <> type

    %{text: text, title: text, class: class}
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

  defp count_items(counts) do
    [
      %{key: "blocks", label: "Blocks", count: counts.blocks, tone: :neutral},
      %{key: "unassigned", label: "Unassigned trips", count: counts.unassigned, tone: :info},
      %{key: "problems", label: "Problems", count: counts.problems, tone: :error},
      %{key: "notices", label: "Notices", count: counts.notices, tone: :warning}
    ]
  end

  # The three plan figures the Plan summary owns (AC-34). Each keeps its own key
  # so its button is a stable DOM id, and the strip sends `plan_summary` for all
  # three. The minimum is the day's lower bound and the peak is the day's own,
  # so both are the whole day type's whatever the workspace is showing.
  defp figure_items(figures, peak) do
    [
      %{
        key: "vehicles",
        label: "Vehicles",
        count: figures.vehicles,
        detail: "· minimum #{figures.minimum}",
        tone: :neutral
      },
      %{
        key: "riders",
        label: "Time with riders",
        count: figures.riders,
        value: "#{figures.riders}%",
        tone: :neutral
      },
      %{
        key: "peak",
        label: "Peak out",
        count: peak.count,
        detail: peak_detail_suffix(peak),
        tone: :neutral
      }
    ]
  end

  defp peak_detail_suffix(%{at_secs: nil}), do: nil
  defp peak_detail_suffix(peak), do: "at #{clock(peak.at_secs)}"

  # One sentence per short fleet row, in the day's own row order: the typed row
  # before the garage total, so a garage short on both reads as two checks
  # rather than one repeated line.
  defp shortfall_summary(shortfalls) do
    Enum.map_join(shortfalls, " ", fn row ->
      "#{row.garage} · #{row.type}: needs #{row.needed} at #{clock(row.at_secs)}, " <>
        "#{row.listed} listed."
    end)
  end

  defp peak_detail(%{at_secs: nil}), do: "No block is timed"

  defp peak_detail(peak) do
    "Peak at #{clock(peak.at_secs)} · excludes " <>
      count_label(peak.excluded_unassigned, "unassigned trip", "unassigned trips") <>
      " and " <> count_label(peak.excluded_frequency, "frequency trip", "frequency trips")
  end

  defp count_label(1, singular, _plural), do: "1 #{singular}"
  defp count_label(count, _singular, plural), do: "#{count} #{plural}"

  # The chart's text equivalent and its caption. The bars are one garage · type's
  # vehicles out per 15-minute bin, so the label names that row and its listing
  # rather than the whole day type, and the sentence under the chart repeats the
  # same numbers for a reader who cannot see the pixels.
  defp plan_chart_label(chart) do
    row = chart.row

    "#{row.garage} #{row.type} vehicles out by 15 minutes; peak #{row.needed} at " <>
      "#{clock(row.at_secs)}; #{row.listed} listed. Chart covers " <>
      "#{clock(List.first(chart.bins).start_secs)} to " <>
      "#{clock(List.last(chart.bins).start_secs + 900)}."
  end

  defp chart_summary(%{at_secs: nil} = row), do: fleet_when(row.at_secs, row.needed)

  defp chart_summary(row) do
    sentence =
      "#{row.garage} · #{row.type}: #{row.needed} out at the busiest time (#{clock(row.at_secs)}); " <>
        "#{row.listed} listed."

    if row.short? do
      sentence <> " #{row.needed - row.listed} short."
    else
      sentence
    end
  end

  # The Time and distance rows, in the reference's order. `drive_secs` and
  # `deadhead_km` come from estimated driving times unless every pair on the day
  # has been entered, so those two rows carry the `est.` mark while any pair is
  # still an estimate (AC-3).
  defp total_rows(figures, estimated?) do
    [
      {"platform", "Total time out", hours(secs_to_hours(figures.platform_secs)), false},
      {"service", "Trips with riders", hours(secs_to_hours(figures.service_secs)), false},
      {"layover", "Waiting between trips", hours(secs_to_hours(figures.layover_secs)), false},
      {"drive", "Driving without riders", hours(secs_to_hours(figures.drive_secs)), estimated?},
      {"service_km", "Distance with riders", "#{km(figures.service_km)} km", false},
      {"deadhead_km", "Distance without riders", "#{km(figures.deadhead_km)} km", estimated?}
    ]
  end

  defp secs_to_hours(secs), do: secs / 3600

  defp repeating_note(false), do: ""
  defp repeating_note(true), do: " Repeating service isn’t counted."

  defp provisional_note(false), do: ""
  defp provisional_note(true), do: " Totals are provisional while errors remain."

  # A listing with no demand has no busiest time to name, so the column carries a
  # dash rather than a clock the row never reached.
  defp fleet_when(nil, _needed), do: "—"
  defp fleet_when(_at_secs, 0), do: "—"
  defp fleet_when(at_secs, _needed), do: clock(at_secs)

  defp min_layover_label(nil), do: "the plan’s"
  defp min_layover_label(minutes), do: "#{minutes}-minute"

  defp too_long?(%{secs: secs}, limit) when is_integer(limit), do: secs > limit * 60
  defp too_long?(_stretch, _limit), do: false

  defp too_long_note(%{secs: secs, block_id: block_id}, limit) when is_integer(limit) do
    if secs > limit * 60 do
      " Block #{block_id} has no place to change operators for #{duration(div(secs, 60))}."
    else
      ""
    end
  end

  defp too_long_note(_stretch, _limit), do: ""

  defp stretch_label(nil), do: "—"

  defp stretch_label(%{secs: secs, block_id: block_id}) do
    "#{duration(div(secs, 60))} in block #{block_id}"
  end

  # Whole hours, then minutes only when there are some, so a stretch of exactly
  # two hours reads "2 h" rather than "2 h 0 min".
  defp duration(minutes) when rem(minutes, 60) == 0, do: "#{div(minutes, 60)} h"

  defp duration(minutes) do
    "#{div(minutes, 60)} h #{rem(minutes, 60)} min"
  end

  @doc """
  Returns one bar's height as a percentage of the chart's tallest bar.

  The scale is the caller's, so a chart draws the listing line on the same
  scale as its bars (`BlocksLive` builds the Plan summary chart's with this
  function). A chart with nothing to draw has no bars, so a zero maximum gives a
  zero height rather than a division by zero.
  """
  @spec bar_height(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def bar_height(_count, 0), do: 0
  def bar_height(count, max), do: round(count / max * 100)

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
  defp code_label(:cannot_reach), do: "Can't reach"
  defp code_label(:type_mismatch), do: "Wrong type"
  defp code_label(:short_layover), do: "Short layover"
  defp code_label(:in_seat_stale), do: "In-seat row"
  defp code_label(:in_seat_unconfirmed), do: "Can't confirm"
  defp code_label(:repositions), do: "Empty move"
  defp code_label(:too_long), do: "Too long"
  defp code_label(:no_relief_opportunity), do: "No operator change"
  defp code_label(:interlining_not_allowed), do: "Route switch"
  defp code_label(:block_attributes_conflict), do: "Garage differs"
  defp code_label(:fleet_shortfall), do: "Not enough vehicles"
  defp code_label(:frequency_trip), do: "Frequency"
  defp code_label(:unplottable), do: "Time missing"

  defp finding_detail(%{code: :cannot_reach, detail: %{drive_secs: drive, gap_secs: secs}}) do
    "The drive between these two trips needs #{minutes(drive)} and there are #{minutes(secs)}."
  end

  defp finding_detail(%{code: :too_long, detail: detail}) do
    "The vehicle is out of the garage #{duration(div(detail.platform_secs, 60))}; the limit is #{minutes(detail.limit_minutes)}."
  end

  defp finding_detail(%{code: :no_relief_opportunity, detail: detail}) do
    "The vehicle runs #{duration(div(detail.secs, 60))} with no place to change operators; " <>
      "the limit is #{minutes(detail.limit_secs)}."
  end

  defp finding_detail(%{code: :type_mismatch}) do
    "A trip’s route requires a vehicle type this block does not have."
  end

  defp finding_detail(%{code: :interlining_not_allowed}) do
    "These two trips are different routes, and the block settings do not allow switching there."
  end

  defp finding_detail(%{code: :block_attributes_conflict}) do
    "This block’s calendars disagree about its garage; saving one sets it for all of them."
  end

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

  # The trip drawer's record list: every state's copy from the page's vocabulary,
  # with the match that has no warning and the two severities the badge tints.
  defp in_seat_state_text(:matches), do: "Matches the block on all shared dates"
  defp in_seat_state_text({_state, reason}), do: in_seat_reason(reason)

  defp transfer_type_label(4), do: "Riders stay on board"
  defp transfer_type_label(_type), do: "Riders must get off and board again"

  defp transfer_state_status(:matches), do: "completed"
  defp transfer_state_status({:stale, _reason}), do: "warning"
  defp transfer_state_status({:unconfirmed, _reason}), do: "info"

  defp transfer_state_label(:matches), do: "Matches block"
  defp transfer_state_label({:stale, _reason}), do: "Needs review"
  defp transfer_state_label({:unconfirmed, _reason}), do: "Can't confirm"

  defp frequency_text(%{headway_secs: secs}) do
    "Repeats every #{div(secs, 60)} min; individual vehicle work can't be checked here. " <>
      "An imported block can be removed."
  end

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
      %{key: "garage", label: "Garage · type"},
      %{key: "out", label: "Time out"},
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
    span_geometry(%{start_secs: trip.first_departure, end_secs: trip.last_arrival}, axis)
  end

  defp gap_geometry(gap, previous, axis, drive_secs) do
    drive = drive_secs || 0

    span_geometry(
      %{
        start_secs: previous.last_arrival + drive,
        end_secs: previous.last_arrival + gap.gap_secs
      },
      axis
    )
  end

  defp drive_geometry(gap, axis) do
    # A drive the vehicle cannot make, and one the version cannot compute, take
    # the whole gap: there is no honest width to give them but the gap's.
    width =
      case {gap.kind, gap.feasible?} do
        {:drive, true} -> gap.drive_secs
        _takes_the_gap -> gap.gap_secs
      end

    span_geometry(
      %{start_secs: gap.arrival_secs, end_secs: gap.arrival_secs + max(width, 0)},
      axis
    )
  end

  defp span_geometry(%{start_secs: start_secs, end_secs: end_secs}, axis) do
    {start, span} = axis_geometry(axis)

    "left: #{percent(start_secs - start, span)}%; " <>
      "width: #{percent(end_secs - start_secs, span)}%"
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
        # The index of the movement for that pair, which is the `gap_index` a
        # `Relief.window` carries; the trip's own position in the sequence is one
        # higher for every gap after the first.
        gap_index: index - 1,
        # The derived movement for the same pair, in the same order, so a drive
        # and the wait it leaves behind line up with the bars between them.
        movement: if(index == 0, do: nil, else: Enum.at(block.movements.gaps, index - 1)),
        overlap?: overlap?,
        shift?: overlap? and rem(overlapping_depth(sequence, index, trip), 2) == 1,
        short?: gap != nil and MapSet.member?(short_pairs, MapSet.new([gap.from_id, gap.to_id]))
      }
    end)
  end

  # The gaps whose wait an operator change can happen in, as R5's windows name
  # them. With no relief limit set there is no piece of work to hand over, so no
  # gap is marked and the legend carries no operator-change key either.
  defp relief_gaps(_block, nil), do: MapSet.new()

  defp relief_gaps(block, _max_piece_minutes) do
    block.windows
    |> MapSet.new(& &1.gap_index)
  end

  # A wait exists only where the movements derived one: an unknown drive has no
  # wait behind it, and an infeasible one has a gap the vehicle cannot cover.
  defp waitable?(%{kind: :drive, feasible?: true}), do: true
  defp waitable?(%{kind: :layover}), do: true
  defp waitable?(_gap), do: false

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
  defp code_icon(:cannot_reach), do: "hero-x-circle-mini"
  defp code_icon(:type_mismatch), do: "hero-x-circle-mini"
  defp code_icon(:fleet_shortfall), do: "hero-x-circle-mini"
  defp code_icon(:short_layover), do: "hero-exclamation-triangle-mini"
  defp code_icon(:in_seat_stale), do: "hero-exclamation-triangle-mini"
  defp code_icon(:too_long), do: "hero-exclamation-triangle-mini"
  defp code_icon(:no_relief_opportunity), do: "hero-exclamation-triangle-mini"
  defp code_icon(:interlining_not_allowed), do: "hero-exclamation-triangle-mini"
  defp code_icon(:block_attributes_conflict), do: "hero-exclamation-triangle-mini"
  defp code_icon(:repositions), do: "hero-arrow-up-right-mini"
  defp code_icon(_code), do: "hero-information-circle-mini"

  defp hours(nil), do: "—"
  defp hours(hours), do: :erlang.float_to_binary(hours * 1.0, decimals: 1)

  # Kilometres to one decimal, the unit AC-7 and the page copy both use. A
  # block with no movement is 0.0 rather than a dash: the vehicle drove nowhere.
  defp km(value), do: :erlang.float_to_binary(value * 1.0, decimals: 1)

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

  # Copy for where a driving time came from. An entered time is a human's known
  # route, an estimate is this version's own guess and an unknown is neither, so
  # the three never read alike.
  defp source_phrase(:entered, seconds), do: "#{minutes(seconds)} entered"
  defp source_phrase(:estimated, seconds), do: "#{minutes(seconds)} estimated"
  defp source_phrase(_unknown, _seconds), do: "driving time unknown"

  defp pull_title(pull, garage, :out) do
    "Pull-out · leaves #{garage_label(garage)} at #{clock(pull.start_secs)}, " <>
      "#{source_phrase(pull.source, pull.drive_secs)}"
  end

  defp pull_title(pull, garage, :back) do
    "Pull-back · returns to #{garage_label(garage)} at #{clock(pull.end_secs)}, " <>
      "#{source_phrase(pull.source, pull.drive_secs)}"
  end

  defp garage_label(nil), do: "the garage"
  defp garage_label(name), do: "#{name} garage"

  defp drive_title(%{feasible?: false} = gap, _from, to) do
    "Can't reach #{stop_name(to.first_stop)} · needs #{minutes(gap.drive_secs)} " <>
      "to get there, has #{minutes(gap.gap_secs)}"
  end

  defp drive_title(%{kind: :unknown} = gap, from, to) do
    "Drive to #{stop_name(to.first_stop)} · the driving time from " <>
      "#{stop_name(from.last_stop)} is not known for " <>
      "#{clock(gap.arrival_secs)}–#{clock(gap.departure_secs)}"
  end

  defp drive_title(gap, _from, to) do
    "Drive to #{stop_name(to.first_stop)} · " <>
      "#{clock(gap.arrival_secs)}–#{clock(gap.arrival_secs + gap.drive_secs)}, " <>
      "#{source_phrase(gap.source, gap.drive_secs)}, then wait " <>
      "#{minutes(gap.wait_secs)}"
  end

  # --- the assignment form and the review (step 25) --------------------------

  # The picker's status line: how many of the day type's block IDs the search
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
  # (FH-18). The selection scope gets its own callout and one line per trip,
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

  # The bulk callout's per-trip reason: the rule that refused it, in the pool's
  # own words (“repeats” for a frequency trip, “time missing” for one whose
  # endpoint time is missing).
  defp bulk_ineligibility_reason(%{frequency?: true} = trip),
    do: "repeats every #{div(trip.headway_secs, 60)} min"

  defp bulk_ineligibility_reason(_trip), do: "time missing"

  # The confirm button repeats the verb and its object (AC-26).
  defp confirm_label(%{command: {:attributes, _block, _garage, _type}}),
    do: "Save block settings"

  defp confirm_label(%{command: {:rename, _source, _target}}), do: "Rename block"
  defp confirm_label(%{command: {:merge, _source, _target}}), do: "Merge blocks"

  defp confirm_label(%{command: {:unassign, _ids}, changes: changes}),
    do: "Remove " <> count_label(length(changes), "trip", "trips")

  defp confirm_label(%{changes: changes}),
    do: "Assign " <> count_label(length(changes), "trip", "trips")

  defp confirm_label(_review), do: "Save changes"

  # An attribute save moves no trip, so the dialog names what it does write and
  # the affected calendars rather than a table of assignments that would be empty
  # (AC-19, AC-37).
  defp attributes?(%{command: {:attributes, _block, _garage, _type}}), do: true
  defp attributes?(_review), do: false

  defp effect_sentence(_effect, %{command: {:attributes, _block, _garage, _type}}) do
    "The block's garage and type are saved here and apply to every calendar it runs on."
  end

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
