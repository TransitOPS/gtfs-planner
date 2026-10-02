defmodule GtfsPlannerWeb.Gtfs.BlocksComponents do
  @moduledoc """
  Function components for Operations › Blocks.

  The page's service-day scope, whole-day summary and plan figures, the paged
  timeline, the List view, the unassigned pool, the Service dates, Checks, Plan
  summary, Block rules, Driving times, Operator changes and Suggest blocks
  drawers, the suggestion preview, the “not shown on the timeline” list and the
  page states live here so
  `GtfsPlannerWeb.Gtfs.BlocksLive` stays a small state owner. Every component
  takes the pieces of the loaded day it prints, never the whole day, so
  `render/1` in the LiveView never reaches into the server-only day assign.
  The trip, gap and block drawers render inside the same page.

  The components are drawn in the TransitOps application design system: the
  page carries the shared `.ds-page` scope, drawers and dialogs use the planner
  chrome, states are messages and first-use panels, and a finding is a tinted
  badge in drawers and cards but icon plus words in a dense table cell. What is
  local to this page is the timeline table and the gap markers, styled by the
  `blocks (design system)` section of `assets/css/app.css`.

  Times are printed from parsed seconds with `clock/1`; nothing here re-reads a
  clock string from the database. The timeline reads the block's trips
  and findings only, and takes the block's plot order from the pure
  `Checks.sequence/1` so its bars align with the block's own `gaps/1` pairs. The
  List view and the pool take a trip's findings from the day's own finding list,
  grouped by trip once per load, and print them as badges.
  """

  use GtfsPlannerWeb, :html

  import GtfsPlannerWeb.PlannerComponents,
    only: [drawer_footer: 1, drawer_scroll: 1, first_use: 1, message: 1]

  alias GtfsPlanner.Gtfs.Blocking.Checks
  alias GtfsPlanner.Gtfs.Blocking.RiderOutcomes
  alias GtfsPlanner.Gtfs.GtfsTime
  alias GtfsPlanner.Values
  alias GtfsPlannerWeb.Components.RouteIdentity

  @doc """
  Renders the service-day scope: the service-day select, the route filter,
  “Problems only”, and the quiet links for Service dates, Block rules and Driving
  times.

  The day select posts through its own form (`select_day`) so a day change is
  never mistaken for a route filter; the route and status controls post through
  the `filter` form. The scope describes the whole service day, so neither control
  changes the whole-day counts. The three links are set rarely, so they sit at the
  far end. The Block rules link prints the stored minimum layover the day load
  read, so a save shows the new one on the next render. The Driving times link
  counts the day's estimated pairs, which the day load derived from its own
  movements, so the number is the one the drawer lists; a day with nothing
  estimated prints the bare label.

  While a suggestion is previewed the service day, the rules and the driving times
  are fixed, because changing any of them would change the plan the suggestion was
  built on.
  """
  attr :day_types, :list, required: true
  attr :day_type, :map, required: true
  attr :routes, :map, required: true
  attr :state, :map, required: true
  attr :min_layover_minutes, :integer, required: true
  attr :estimated_pairs, :integer, default: 0
  attr :preview?, :boolean, default: false

  def scope_header(assigns) do
    assigns =
      assigns
      |> assign(:route_options, route_options(assigns.routes))
      |> assign(:estimated_label, estimated_label(assigns.estimated_pairs))

    ~H"""
    <div id="blocks-scope" class="flex flex-wrap items-end gap-x-5 gap-y-3 p-4">
      <form id="blocks-day-form" phx-change="select_day" class="w-full min-w-0 sm:w-[360px]">
        <.day_select
          id="blocks-day"
          day_types={@day_types}
          selected={@day_type.key}
          disabled={@preview?}
        />
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
          id="blocks-block-rules"
          type="button"
          phx-click="open_drawer"
          phx-value-key="block_rules"
          disabled={@preview?}
          title={preview_title(@preview?, "Block rules change the plan the suggestion was built on")}
          class={link_class()}
        >
          Block rules · {@min_layover_minutes} min layover
        </button>
        <button
          id="blocks-driving-times"
          type="button"
          phx-click="open_drawer"
          phx-value-key="driving_times"
          disabled={@preview?}
          title={
            preview_title(@preview?, "Driving times change the plan the suggestion was built on")
          }
          class={link_class()}
        >
          Driving times{@estimated_label}
        </button>
      </div>

      <p :if={@preview?} id="blocks-preview-hint" class="basis-full text-[13px] text-muted">
        Discard the suggestion to change the service day, the rules or the driving times.
      </p>
    </div>
    """
  end

  @doc """
  Renders the service-day select.

  Every service day prints as “<label> · <N> days”; service days with one date
  sit in an optgroup labelled “Special days”. Passing a `nil` selection selects
  nothing, which is the unknown-day recovery state. `disabled` fixes the day while
  a suggestion built on it is previewed.
  """
  attr :id, :string, required: true
  attr :day_types, :list, required: true
  attr :selected, :string, default: nil
  attr :disabled, :boolean, default: false

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
      disabled={@disabled}
      title={
        if @disabled,
          do: "The suggestion was built on this service day. Discard it to change the service day."
      }
    />
    """
  end

  @doc """
  Renders the whole-day summary tiles, the plan figures beside them and the
  service-day note.

  Every figure is the whole service day's, so the route filter, “Problems only”
  and any paging leave them unchanged. A tile that leads somewhere is a button:
  Unassigned trips opens the unassigned panel while there are any, Problems
  opens Checks, and the three plan figures after the divider all open the Plan
  summary. Blocks and Notices lead nowhere today, so they are plain tiles. A tile
  is neutral until its count needs the operator: Unassigned trips and Problems
  take a state colour above zero and read as done, with a check, at zero.

  `preview?` adds a “Showing the suggestion” chip: while a plan is previewed every
  figure in the strip is the proposal's, not the saved day's, and the strip is the
  first place a reader looks to find that out.
  """
  attr :day_type, :map, required: true
  attr :counts, :map, required: true
  attr :figures, :map, required: true
  attr :peak, :map, required: true
  attr :preview?, :boolean, default: false

  def summary_strip(assigns) do
    assigns =
      assigns
      |> assign(:count_tiles, summary_tiles(assigns.counts))
      |> assign(:figure_tiles, figure_tiles(assigns.figures, assigns.peak))

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
        <.summary_tile :for={tile <- @count_tiles} group="blocks-summary-counts" tile={tile} />
      </div>
      <span
        id="blocks-summary-divider"
        class="hidden h-8 w-px shrink-0 bg-subtle lg:block"
        aria-hidden="true"
      >
      </span>
      <div
        id="blocks-summary-figures"
        data-role="count-strip"
        class="grid min-w-0 grow grid-cols-1 gap-2 sm:flex sm:grow-0 sm:flex-wrap"
      >
        <.summary_tile :for={tile <- @figure_tiles} group="blocks-summary-figures" tile={tile} />
      </div>
      <span
        :if={@preview?}
        id="blocks-preview-chip"
        class="inline-flex items-center rounded-badge bg-selection px-2 py-1 text-[13px] font-semibold text-action"
      >
        Showing the suggestion
      </span>
      <span id="blocks-summary-note" class="ml-auto text-[13px] text-muted">
        Whole service day · {day_count_label(@day_type.date_count)}
      </span>
    </section>
    """
  end

  attr :tile, :map, required: true
  attr :group, :string, required: true

  defp summary_tile(assigns) do
    ~H"""
    <.dynamic_tag
      tag_name={if @tile.action?, do: "button", else: "div"}
      id={@group <> "-item-" <> @tile.key}
      data-role="count-strip-item"
      data-key={@tile.key}
      type={@tile.action? && "button"}
      phx-click={@tile.action? && "open_drawer"}
      phx-value-key={@tile.action? && @tile.target}
      class={[
        "flex min-h-11 items-center gap-2 rounded-control border px-3.5 py-1.5 text-left",
        summary_tile_tone(@tile.tone),
        @tile.wide? && "max-sm:col-span-2",
        @tile.action? && "hover:shadow-card"
      ]}
    >
      <.icon :if={@tile.icon} name={@tile.icon} class="size-[18px] shrink-0" />
      <span class={["text-sm", @tile.tone == :neutral && "text-muted"]}>{@tile.label}</span>
      <strong
        data-role="count-strip-value"
        class="font-display text-[22px] font-semibold leading-none tabular-nums"
      >
        {@tile.value}
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
    <div
      :if={!@garages? or !@vehicles? or @fleet_shortfalls != []}
      id="blocks-notices"
      class="space-y-3"
    >
      <.message
        :if={!@garages?}
        id="blocks-no-garages"
        kind="info"
        title="Add a garage to plan travel to and from the garage."
      >
        Driving between stops still shows. Suggestions need at least one garage.
        <:action>
          <.button
            id="blocks-no-garages-link"
            variant="secondary"
            navigate={"/gtfs/#{@version_id}/settings/garages"}
            class="min-h-11"
          >
            Go to Settings › Garages
          </.button>
        </:action>
      </.message>
      <.message
        :if={@garages? and not @vehicles?}
        id="blocks-no-vehicles"
        kind="info"
        title="Fleet limits aren’t checked."
      >
        No vehicles are listed, so the page can’t tell whether each garage has enough.
        <:action>
          <.button
            id="blocks-no-vehicles-link"
            variant="secondary"
            navigate={"/gtfs/#{@version_id}/settings/fleet"}
            class="min-h-11"
          >
            Go to Settings › Fleet
          </.button>
        </:action>
      </.message>
      <.message
        :if={@fleet_shortfalls != []}
        id="blocks-fleet-shortfall"
        kind="error"
        title="Not enough vehicles."
      >
        <span data-role="blocks-shortfall-summary">{shortfall_summary(@fleet_shortfalls)}</span>
        Rebuilding blocks can’t fix this; add vehicles or move blocks to another garage.
        <:action>
          <div class="flex flex-wrap items-center gap-2">
            <.button
              id="blocks-fleet-shortfall-summary"
              type="button"
              variant="secondary"
              class="min-h-11"
              phx-click="open_drawer"
              phx-value-key="plan_summary"
            >
              Open plan summary
            </.button>
            <.button
              id="blocks-fleet-shortfall-fleet-link"
              variant="secondary"
              navigate={"/gtfs/#{@version_id}/settings/fleet"}
              class="min-h-11"
            >
              Go to Settings › Fleet
            </.button>
          </div>
        </:action>
      </.message>
    </div>
    """
  end

  @doc """
  Renders the page's data states: the first-paint skeleton, the two calendar
  and trip empties, and the unknown-day recovery.

  The skeleton mirrors the scope card, the summary tiles and eight rows. The
  recovery state keeps the service-day select but applies no day: a restored
  selection loads the day the user chose.
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

  Below the day's problems and notices sit the two in-seat cleanup sections
  (AC-21). The first is this day type's records that need review: a stale row
  opens the connection holding it, or one of its own trips when no gap of this
  day hosts it, and a conflicting pair says so and offers the connection to
  settle it in. Its removal is one question over exactly the stale rows - a
  conflict needs a choice, not a deletion, so it never counts. The second is the
  version's records no block of any day type can reach, which no Blocks view can
  show, with its own question over exactly those rows.
  """
  attr :open, :boolean, required: true
  attr :day_type, :map, required: true
  attr :findings, :list, required: true
  attr :trip_labels, :map, required: true
  attr :in_seat_review, :map, default: %{entries: [], stale: []}
  attr :unmatched, :list, default: []
  attr :remove_stale, :map, default: nil
  attr :remove_unmatched, :map, default: nil
  attr :remove_pending, :boolean, default: false

  def checks_drawer(assigns) do
    problems = Enum.filter(assigns.findings, &(&1.severity in [:error, :warning]))
    notices = Enum.filter(assigns.findings, &(&1.severity == :notice))

    assigns =
      assigns
      |> assign(problems: problems, notices: notices)
      |> assign(
        stale_count: length(assigns.in_seat_review.stale),
        stale_copy:
          removal_copy(
            "#{assigns.day_type.label} blocks",
            length(assigns.in_seat_review.stale)
          ),
        unmatched_copy: removal_copy("any block of this version", length(assigns.unmatched))
      )

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

        <%!-- The day type's own in-seat records that need review, and the one
        question that removes the ones no block reaches. --%>
        <section id="checks-in-seat" class="border-t border-subtle pt-5">
          <h3 class="text-[15px] font-bold text-strong">
            In-seat records that need review · {length(@in_seat_review.entries)}
          </h3>

          <ul id="checks-in-seat-entries" class="mt-3">
            <li
              :for={entry <- @in_seat_review.entries}
              id={"checks-in-seat-#{checks_entry_id(entry)}"}
              data-role="checks-in-seat-entry"
              data-kind={entry.kind}
              class="border-t border-subtle py-2.5 text-sm first:border-t-0"
            >
              <.checks_in_seat_entry entry={entry} />
            </li>
          </ul>
          <p :if={@in_seat_review.entries == []} class="text-sm text-muted">
            None on this service day.
          </p>

          <div :if={@stale_count > 0} class="mt-3">
            <.button
              id="checks-remove-stale"
              type="button"
              variant="danger"
              class="min-h-11"
              phx-click="request_remove_stale"
            >
              Remove {@stale_count} {word(
                @stale_count,
                "record that no longer matches",
                "records that no longer match"
              )}
            </.button>
            <p class="mt-1 text-[13px] text-muted">
              Removes records whose trips aren't consecutive or whose stops changed. The
              disagreeing pair needs a choice instead.
            </p>
          </div>
        </section>

        <%!-- The version's in-seat records that no block reaches. No Blocks view
        can show these, so this section is the only place on the page that names
        them. --%>
        <section id="checks-in-seat-version" class="border-t border-subtle pt-5">
          <h3 class="text-[15px] font-bold text-strong">
            This version · {length(@unmatched)} in-seat {word(
              length(@unmatched),
              "record doesn't",
              "records don't"
            )} match any block
          </h3>
          <p class="mt-1 text-[13px] text-muted">
            No Blocks view can show these connections. Routes › Transfers lists them under
            In-seat.
          </p>

          <ul :if={@unmatched != []} id="checks-in-seat-unmatched" class="mt-3">
            <li
              :for={record <- @unmatched}
              id={"checks-unmatched-#{record.id}"}
              data-role="checks-unmatched"
              data-reason={record.reason}
              class="border-t border-subtle py-2 text-sm first:border-t-0"
            >
              Trip {record.from_trip_id} → {record.to_trip_id} · {remove_record_setting(
                record.transfer_type
              )}
              <p class="text-[13px] text-muted">{unmatched_reason_text(record.reason)}</p>
            </li>
          </ul>
          <p :if={@unmatched == []} class="mt-2 text-sm text-muted">None left.</p>

          <.button
            :if={@unmatched != []}
            id="checks-remove-unmatched"
            type="button"
            variant="danger"
            class="mt-3 min-h-11"
            phx-click="request_remove_unmatched"
          >
            Remove {length(@unmatched)} {word(length(@unmatched), "record", "records")}
          </.button>
        </section>
      </.drawer_scroll>
    </.drawer>

    <%!-- The two removal questions. They are the shared `confirm_dialog` rather
    than drawers of their own: a batch of records the editor may still want is a
    question, not a page, and each names the count it deletes so the number a
    reader confirms is the number the list showed. --%>
    <.confirm_dialog
      id="remove-stale-dialog"
      chrome="planner"
      open={not is_nil(@remove_stale)}
      title={@stale_copy.title}
      confirm_label={@stale_copy.confirm}
      pending_label="Removing…"
      pending={@remove_pending}
      on_confirm="confirm_remove_stale"
      on_cancel="cancel_remove_in_seat"
      described_by="remove-stale-dialog-body"
      return_focus_id="checks-remove-stale"
    >
      <%!-- `described_by` names `confirm_dialog`'s own `#remove-stale-dialog-body`
      wrapper, so the paragraph inside it carries no id of its own. --%>
      <p>{@stale_copy.body}</p>
    </.confirm_dialog>

    <.confirm_dialog
      id="remove-unmatched-dialog"
      chrome="planner"
      open={not is_nil(@remove_unmatched)}
      title={@unmatched_copy.title}
      confirm_label={@unmatched_copy.confirm}
      pending_label="Removing…"
      pending={@remove_pending}
      on_confirm="confirm_remove_unmatched"
      on_cancel="cancel_remove_in_seat"
      described_by="remove-unmatched-dialog-body"
      return_focus_id="checks-remove-unmatched"
    >
      <p>{@unmatched_copy.body}</p>
    </.confirm_dialog>
    """
  end

  # One row of the day type's review list. A stale record is a link to the
  # connection that holds it, or to one of its own trips when this day has no
  # gap for it; a conflicting pair is a link to the connection to settle in,
  # because two records disagree and the page cannot pick between them.
  attr :entry, :map, required: true

  defp checks_in_seat_entry(assigns) do
    ~H"""
    <%= if entry = @entry.connection do %>
      <button
        type="button"
        phx-click="open_gap"
        phx-value-from={entry.from.id}
        phx-value-to={entry.to.id}
        phx-value-block={entry.block_id}
        class={link_class()}
      >
        Block {entry.block_id} · trip {entry.from.trip_id} → {entry.to.trip_id}
      </button>
    <% else %>
      <%!-- No gap of this day hosts the pair, so the row opens one of its own
      trips rather than a connection that does not exist. --%>
      <button
        type="button"
        phx-click="open_trip"
        phx-value-trip={@entry.row.from_trip_id}
        class={link_class()}
      >
        Trip {@entry.row.from_trip_id} → {@entry.row.to_trip_id}
      </button>
    <% end %>
    <p data-role="checks-in-seat-state" class="text-[13px] text-muted">
      {if @entry.kind == :conflict,
        do: "Two records disagree · choose one setting",
        else: in_seat_state_text(@entry.state)}
    </p>
    """
  end

  # Each listed row's own DOM id, so the row a reader is looking at can be
  # addressed directly. A conflict is named by the pair it is, a stale record by
  # its own row id.
  defp checks_entry_id(%{kind: :conflict, connection: connection}),
    do: "conflict-" <> String.replace(connection.id, "|", "-")

  defp checks_entry_id(%{kind: :stale, row: row}), do: "stale-" <> row.id

  # R8's three reasons, in the page's own words. A row is listed only because no
  # block in the version reaches it, so each sentence says which of those three
  # it is rather than repeating the day drawer's longer explanation.
  defp unmatched_reason_text(:no_block), do: "Neither trip has a block."
  defp unmatched_reason_text(:trip_missing), do: "A trip isn't in this version."
  defp unmatched_reason_text(:no_shared_date), do: "The trips share no date."

  defp unmatched_reason_text(_reason), do: "No block in this version reaches this record."

  # The removal question's copy, built from the count the drawer is showing and
  # the scope it is about, so the number a reader confirms is the number the list
  # named and the two questions cannot read as the same one. A count of zero has
  # no question, which the caller checks before it renders a button asking it.
  defp removal_copy(scope, count) when count > 0 do
    %{
      title: "Remove #{count} in-seat #{word(count, "record", "records")}?",
      body:
        "#{word(count, "This record no longer matches", "These records no longer match")} #{scope}. " <>
          "Trips and blocks don't change. " <>
          "Each deletion is audited; riders will see whatever apps infer from the blocks.",
      confirm: "Remove #{count} #{word(count, "record", "records")}"
    }
  end

  defp removal_copy(_scope, 0), do: %{title: "", body: "", confirm: "Remove records"}

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
  Renders the Suggested blocks panel: the plan a reader is looking at before
  anything is saved.

  The panel sits between the page's notices and the workbench so the proposal, the
  workbench it changes and the counts above all stay on one screen: existing
  content stays visible because a preview is a reading of the page, not a
  replacement of it.

  Every number is the plan's own. The four metrics read `Blocking.Plan`'s before
  and after figures, the moves and the review's added-problem count, and the panel
  adds the two counts a `current → proposed` pair cannot give on its own: the
  problems that were there before and remain (the review's own `existing` list) and
  the ones the plan removes, which are the saved day's findings the previewed day's
  no longer has, keyed by `Checks.finding_key/1` — the same key the review and the
  day load count problems by, so “2 fixed” is never a second opinion about what a
  problem is.

  The service-day cards are `review_effect/1`, shared with the review dialog rather
  than copied, so a service day says the same thing wherever a plan is read. The
  repeating-service and estimate notes are the day's own counts: repeating service
  is never blocked, and an estimated driving time is still an estimate inside a
  plan that has not been applied.

  Focus lands on the heading when the panel arrives, through the page's scoped
  `FormErrorFocus` hook and its `data-focus-on-mount`, so a keyboard reader's next
  stop is the proposal rather than the button they pressed. While the panel shows,
  Apply suggestion is the page's one primary, until the plan goes stale and “Suggest
  again” takes over.
  """
  attr :plan, :map, required: true
  attr :day_type, :map, required: true
  attr :scope, :atom, required: true
  attr :picked, :list, default: []
  attr :minimum, :integer, default: 0
  attr :existing_problems, :integer, default: 0
  attr :fixed_problems, :integer, default: 0
  attr :repeating_trip_ids, :list, default: []
  attr :estimated_pairs, :integer, default: 0
  attr :apply, :map, default: %{status: :none, title: nil, message: nil, reason: nil}

  # How many saved runs contain the trips this proposal moves. Computed once,
  # where the preview is stored, and never on render.
  attr :runs_touched, :integer, default: 0
  attr :version_id, :string, required: true

  def suggestion_panel(assigns) do
    assigns =
      assigns
      |> assign(:moves, assigns.plan.moves)
      |> assign(:metrics, suggestion_metrics(assigns))
      |> assign(:scope_note, scope_note(assigns))
      |> assign(:facts_note, facts_note(assigns))
      |> assign(:apply_label, apply_label(assigns.apply))
      |> assign(:apply_disabled?, apply_disabled?(assigns.apply))
      |> assign(:suggest_primary?, assigns.apply.status == :stale)

    ~H"""
    <section
      id="suggestion"
      aria-labelledby="suggestion-title"
      phx-hook="FormErrorFocus"
      data-focus-on-mount="suggestion-title"
      class="overflow-hidden rounded-card border border-action/40 bg-white"
    >
      <div class="flex flex-wrap items-start justify-between gap-3 border-b border-subtle px-5 py-4">
        <div>
          <h2
            id="suggestion-title"
            tabindex="-1"
            class="font-display text-[22px] font-semibold leading-tight tracking-[-0.025em] text-strong"
          >
            Suggested blocks
          </h2>
          <p class="mt-1 text-[13px] text-muted">
            {@day_type.label} · {scope_name(@scope)}
          </p>
        </div>
        <.finding_badge tone={:warning} label="Preview · not saved" />
      </div>

      <div class="grid grid-cols-2 border-b border-subtle lg:grid-cols-4">
        <.suggestion_metric
          :for={metric <- @metrics}
          label={metric.label}
          value={metric.value}
          note={metric.note}
        />
      </div>

      <div class="grid gap-4 px-5 py-4">
        <.message
          :if={@apply.status != :none}
          id="suggestion-apply-message"
          kind={apply_kind(@apply.status)}
          title={@apply.title}
          tabindex="-1"
          data-role="suggestion-apply-state"
          data-state={@apply.status}
        >
          {@apply.message}
        </.message>

        <p id="suggestion-scope-note" class="text-sm">
          {@scope_note}
          <span :if={@facts_note}>{@facts_note}</span>
        </p>

        <%!-- The runs this proposal reaches, counted once when the preview was
        built and never on render.
        It is informational: it tells a planner that applying will disturb runs
        they may have built by hand, before they apply rather than after.
        Nothing at zero — a proposal that touches no run has nothing to say about
        runs, and a line reading "0 runs" would be noise on most proposals. --%>
        <p
          :if={@runs_touched > 0}
          id="suggestion-runs-touched"
          data-role="suggestion-runs-touched"
          data-runs={@runs_touched}
          class="text-sm"
        >
          These changes move trips in {@runs_touched}
          {if @runs_touched == 1, do: "run", else: "runs"}. Review them on Runs after applying.
          <.link
            navigate={"/gtfs/#{@version_id}/runs?day=#{@day_type.key}"}
            class={link_class()}
          >
            Go to Runs
          </.link>
        </p>

        <details open>
          <summary class="flex min-h-11 cursor-pointer items-center text-sm font-[650] text-action">
            Inspect {length(@moves)} affected {word(length(@moves), "trip", "trips")} and dates
          </summary>
          <div class="mt-2 grid gap-3">
            <div
              id="suggestion-moves"
              class="max-h-[260px] overflow-auto rounded-card border border-subtle"
            >
              <table :if={@moves != []} id="suggestion-moves-table" class="w-full text-sm">
                <thead class="sticky top-0 bg-canvas text-left text-[13px] text-muted">
                  <tr>
                    <th scope="col" class="px-3 py-2 font-semibold">Trip</th>
                    <th scope="col" class="px-3 py-2 font-semibold">Departs</th>
                    <th scope="col" class="px-3 py-2 font-semibold">Current block</th>
                    <th scope="col" class="px-3 py-2 font-semibold">Proposed block</th>
                    <th scope="col" class="px-3 py-2 font-semibold">Change</th>
                  </tr>
                </thead>
                <tbody class="divide-y divide-subtle/60">
                  <tr :for={move <- @moves}>
                    <td class="px-3 py-1.5">{move.trip.trip_id}</td>
                    <td class="px-3 py-1.5 tabular-nums">{clock(move.trip.first_departure)}</td>
                    <td class="px-3 py-1.5">{move.from || "Unassigned"}</td>
                    <td class="px-3 py-1.5">
                      <strong data-role="suggestion-proposed" class="text-strong">
                        {move.to || "Unassigned"}
                      </strong>
                    </td>
                    <td class="px-3 py-1.5">
                      <span
                        data-role="suggestion-change"
                        data-change={if is_nil(move.from), do: "added", else: "moved"}
                        class="inline-flex items-center rounded-badge bg-selection px-1.5 py-0.5 text-[13px] font-semibold text-action"
                      >
                        {if is_nil(move.from), do: "Added", else: "Moved"}
                      </span>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
            <div class="grid gap-2">
              <.review_effect
                :for={effect <- @plan.review.effects}
                effect={effect}
                review={@plan.review}
                current_label="Current view"
              />
            </div>
          </div>
        </details>

        <div class="flex flex-wrap items-center gap-3">
          <.button
            id="apply-suggestion"
            type="button"
            variant={if @suggest_primary?, do: "secondary", else: "primary"}
            class="min-h-11"
            phx-click="apply_suggestion"
            disabled={@apply_disabled?}
            data-unavailable={@apply.status == :stale}
            title={@apply.reason}
          >
            {@apply_label}
          </.button>
          <.button
            id="discard-suggestion"
            type="button"
            variant="secondary"
            class="min-h-11"
            phx-click="discard_suggestion"
            disabled={@apply.status == :pending}
          >
            Discard suggestion
          </.button>
          <.button
            id="suggest-again"
            type="button"
            variant={if @suggest_primary?, do: "primary", else: "secondary"}
            class="min-h-11"
            phx-click="suggest_again"
            disabled={@apply.status == :pending}
          >
            Suggest again
          </.button>
          <span :if={@apply.reason} id="suggestion-apply-reason" class="text-[13px] text-muted">
            {@apply.reason}
          </span>
          <span
            :if={@scope == :replace_all and @apply.status != :stale}
            class="text-[13px] text-muted"
          >
            Applying asks you to confirm, because hand-tuned blocks may change.
          </span>
        </div>
      </div>
    </section>
    """
  end

  # The Apply button's three labels and its two disabled states, from the result
  # the last attempt produced. A busy or failed apply keeps the preview, so the
  # next click repeats exactly the reviewed write and the button says so; a stale
  # plan is not repeatable, so its label stays and its disabled reason is printed
  # beside it.
  defp apply_label(%{status: status}) when status in [:busy, :failed], do: "Apply again"
  defp apply_label(_apply), do: "Apply suggestion"

  defp apply_disabled?(%{status: status}) when status in [:pending, :stale], do: true
  defp apply_disabled?(_apply), do: false

  defp apply_kind(:pending), do: "info"
  defp apply_kind(:stale), do: "warning"
  defp apply_kind(:busy), do: "warning"
  defp apply_kind(_status), do: "error"

  @doc """
  Renders the applied message where the Suggested blocks panel was.

  A successful apply drops the preview, so there is nothing left to inspect: what
  remains is the sentence saying what changed and the reader's own Dismiss. It
  takes focus so a keyboard reader lands on the outcome rather than on a button
  that has gone.
  """
  attr :applied, :map, required: true

  def suggestion_applied(assigns) do
    ~H"""
    <section
      id="suggestion"
      aria-labelledby="suggestion-applied-title"
      phx-hook="FormErrorFocus"
      data-focus-on-mount="suggestion-applied"
    >
      <.message
        id="suggestion-applied"
        kind="success"
        title="Suggestion applied."
        tabindex="-1"
        data-role="suggestion-applied"
      >
        {@applied.message}
        <:action>
          <.button
            id="dismiss-applied"
            type="button"
            variant="secondary"
            class="min-h-11"
            phx-click="dismiss_applied"
          >
            Dismiss
          </.button>
        </:action>
      </.message>
    </section>
    """
  end

  @doc """
  Renders the replace-all confirmation as the shared review dialog.

  A rebuild re-plans every scheduled trip in the service day, so it is confirmed
  before it is written: the title and the confirm button both name the number of
  trips the plan would move, and the cancel action is “Keep current blocks”,
  which is what the reader chose by closing it. It is the shared `confirm_dialog`
  rather than a second overlay, and its pending state is the panel's own, so the
  confirm button cannot be pressed twice while a write runs.
  """
  attr :replace, :map, required: true
  attr :day_type, :map, required: true
  attr :pending, :boolean, default: false

  def suggestion_replace_dialog(assigns) do
    assigns = assign(assigns, :label, "Replace blocks for #{assigns.replace.moves} trips")

    ~H"""
    <.confirm_dialog
      id="suggestion-replace"
      chrome="planner"
      size="lg"
      open={@replace.open?}
      title={@label <> "?"}
      confirm_label={@label}
      pending_label="Applying…"
      on_confirm="confirm_replace"
      on_cancel="cancel_replace"
      cancel_label="Keep current blocks"
      pending={@pending}
      described_by="suggestion-replace-summary"
      confirm_variant="primary"
      return_focus_id="apply-suggestion"
      data-initial-focus-id="suggestion-replace-summary"
    >
      <%!-- The shared `confirm_dialog` already renders its own
      `#<id>-body` wrapper, so this sentence cannot reuse that id: a duplicate
      id would point `aria-describedby` at the wrapper and would send the
      initial focus to an element that cannot take it, leaving the dialog's
      dismiss button focused instead of the sentence a reader has to read. --%>
      <p id="suggestion-replace-summary" tabindex="-1" class="focus-visible:outline-none">
        Every scheduled trip in {@day_type.label} was planned again. {@replace.moves}
        {if @replace.moves == 1, do: "trip changes", else: "trips change"} block,
        including hand-tuned blocks, on {Enum.join(@replace.days, " and ")}. Each trip's change history keeps its
        previous block.
      </p>
    </.confirm_dialog>
    """
  end

  # The four headline figures. Three read the plan's own
  # before and after pairs; the two that cannot be a pair — the trips that change
  # block and the problems the plan adds — are single numbers, because there is
  # no "before" for a move and the problems a plan fixes are counted beside the
  # ones it leaves.
  defp suggestion_metrics(assigns) do
    plan = assigns.plan
    before = plan.before
    proposed = plan.after

    [
      %{
        label: "Vehicles · current → proposed",
        value: "#{before.vehicles} → #{proposed.vehicles}",
        note: "minimum possible #{assigns.minimum}"
      },
      %{
        label: "Driving without riders · h",
        value: "#{hours_text(before.drive_secs)} → #{hours_text(proposed.drive_secs)}",
        note: if(assigns.estimated_pairs > 0, do: "estimated", else: "entered")
      },
      %{
        label: "Trips changing block",
        value: Integer.to_string(length(plan.moves)),
        note: nil
      },
      %{
        label: "New problems",
        value: Integer.to_string(plan.review.added_problem_count),
        note: problem_note(assigns)
      }
    ]
  end

  # The panel's existing count is the saved day's own problems the plan does not
  # add, so it is derived where the preview is derived rather than read off the
  # review's `existing` list, which covers only the blocks the plan touches.
  defp problem_note(%{existing_problems: 0, fixed_problems: 0}), do: "none existing"

  defp problem_note(assigns) do
    existing = assigns.existing_problems

    [
      if(existing > 0,
        do: "#{existing} existing #{word(existing, "problem remains", "problems remain")}"
      ),
      if(assigns.fixed_problems > 0, do: "#{assigns.fixed_problems} fixed")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  # The per-scope sentence: what the scope left alone, which is the
  # thing a reader cannot see in the numbers.
  defp scope_note(%{scope: :unassigned_only}) do
    "Existing assignments stay; their problems are listed as existing, not caused by this suggestion."
  end

  defp scope_note(%{scope: :replace_all}) do
    "Every scheduled trip in this service day was planned again. Hand-tuned blocks may change."
  end

  defp scope_note(%{scope: :selected, picked: []}) do
    "Only the selected blocks were planned again. Other blocks and unassigned trips don't change."
  end

  defp scope_note(%{scope: :selected, picked: picked}) do
    "Only blocks #{Enum.join(picked, " and ")} were planned again. " <>
      "Other blocks and unassigned trips don't change."
  end

  defp scope_name(:unassigned_only), do: "Unassigned trips only"
  defp scope_name(:selected), do: "Selected blocks"
  defp scope_name(:replace_all), do: "Rebuild the service day"

  # The two facts that bound what a proposal can be trusted to say, and that hold
  # inside a plan as much as outside one: repeating service is never blocked, and
  # a driving time the version estimated is still an estimate. They name the day's
  # own trips and pairs rather than a count, so a reader can go and look.
  defp facts_note(assigns) do
    Enum.reject(
      [repeats_note(assigns.repeating_trip_ids), estimate_note(assigns.estimated_pairs)],
      &is_nil/1
    )
    |> Enum.join(" ")
  end

  defp repeats_note([]), do: nil

  defp repeats_note(ids) do
    "#{Enum.join(ids, ", ")} #{word(length(ids), "repeats", "repeat")} " <>
      "without individual departures and #{word(length(ids), "stays", "stay")} unassigned."
  end

  defp estimate_note(0), do: nil

  defp estimate_note(count) do
    "#{count} #{word(count, "driving time is", "driving times are")} still " <>
      "#{word(count, "an estimate", "estimates")}."
  end

  defp word(1, singular, _plural), do: singular
  defp word(_count, _singular, plural), do: plural

  # The deadhead figure is printed in hours to one decimal; a plan's drive seconds
  # are whole minutes, so the same shape is one decimal of an hour.
  defp hours_text(secs) when is_integer(secs),
    do: :erlang.float_to_binary(secs / 3600, decimals: 1)

  defp hours_text(_no_seconds), do: "—"

  # One headline figure of the Suggested blocks panel: its label, its value and
  # the note beneath it. The value is the panel's own typography rather than the
  # summary tiles', so a two-number `current → proposed` pair reads as one figure
  # and not as two counts in a row.
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :note, :string, default: nil

  defp suggestion_metric(assigns) do
    ~H"""
    <div
      data-role="suggestion-metric"
      class="min-w-0 border-subtle px-5 py-3 max-lg:odd:border-r max-lg:[&:nth-child(n+3)]:border-t lg:border-l lg:first:border-l-0"
    >
      <p data-role="suggestion-metric-label" class="text-[13px] text-muted">
        {@label}
      </p>
      <p
        data-role="suggestion-metric-value"
        class="mt-1 font-display text-[26px] font-semibold leading-none tabular-nums text-strong"
      >
        {@value}
      </p>
      <p :if={@note} data-role="suggestion-metric-note" class="mt-1 text-[13px] text-muted">
        {@note}
      </p>
    </div>
    """
  end

  @doc """
  Renders the Plan summary drawer: what the day's blocks cost in vehicles,
  minutes and kilometres, and how far the fleet is from carrying them.

  The sections are the headline number with the minimum and the riders share and
  the sentence that explains them, the fleet table at the busiest time with its
  chart, the time and distance totals, and the operator changes. Every number is
  `day.figures`, `day.fleet` or `day.longest_stretch` read once per load into
  render assigns, so the drawer prints derived answers and re-derives none of its
  own.

  The chart draws the vehicles out per 15-minute bin of the focused row — the
  first short row, else the first typed row, never a garage total — against that
  row's own listing, and a bin above the listing is an error bar rather than a
  demand bar. The sentence under the chart is its text equivalent, so the encoding
  is readable without the pixels.

  The Operator changes button below the last section opens the drawer that sets
  the limit and the marks, and its own label is the section's answer, so a reader
  who has not set a limit is offered the setup rather than a review.
  """
  attr :open, :boolean, required: true
  attr :figures, :map, required: true
  attr :peak, :map, default: nil
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
      chrome="planner"
      open={@open}
      title="Plan summary"
      return_focus_id="blocks-summary-figures-item-vehicles"
      class="max-w-[520px]"
    >
      <:lede :if={@day_type}>{@day_type.label} · {day_count_label(@day_type.date_count)}</:lede>

      <.drawer_scroll>
        <section id="plan-summary-plan">
          <p
            id="plan-summary-vehicles"
            class="font-display text-[32px] font-semibold leading-none text-strong"
          >
            {@figures.vehicles}
            <span class="text-base font-normal text-muted">vehicles used</span>
          </p>

          <dl id="plan-summary-figures" class="mt-4 grid grid-cols-[1fr_auto] gap-x-4 gap-y-2 text-sm">
            <dt class="text-muted">Minimum possible</dt>
            <dd id="plan-summary-minimum" class="text-right font-semibold tabular-nums text-strong">
              {@figures.minimum}
            </dd>
            <dt class="text-muted">Time with riders</dt>
            <dd id="plan-summary-riders" class="text-right font-semibold tabular-nums text-strong">
              {@figures.riders}%
            </dd>
          </dl>

          <p id="plan-summary-minimum-help" class="mt-3 text-sm text-muted">
            The minimum is the fewest vehicles these trip times allow with a {min_layover_label(
              @min_layover_minutes
            )} layover. Driving between stops and operator
            changes can mean a good plan uses more.{repeating_note(@repeating?)} Time with riders is
            the share of time out of the garage spent carrying riders.
          </p>

          <p :if={@peak} id="plan-summary-peak-note" class="mt-2 text-sm text-muted">
            {peak_note(@peak)}
          </p>
        </section>

        <section id="plan-summary-fleet" class="border-t border-subtle pt-5">
          <h3 class="text-[15px] font-bold text-strong">Fleet at the busiest time</h3>

          <p :if={not @garages?} id="plan-summary-fleet-no-garage" class="mt-2 text-sm text-muted">
            Add a garage to count vehicles out of the garage.
          </p>

          <p
            :if={@garages? and not @vehicles?}
            id="plan-summary-fleet-no-vehicles"
            class="mt-2 text-sm text-muted"
          >
            No vehicles are listed.
            <.link navigate={"/gtfs/#{@version_id}/settings/fleet"} class={link_class()}>
              Go to Settings › Fleet
            </.link>
          </p>

          <table
            :if={@garages? and @vehicles?}
            id="plan-summary-fleet-table"
            class="mt-2 w-full text-sm"
          >
            <caption class="sr-only">
              Vehicles needed and listed per garage and type at the busiest time
            </caption>
            <thead>
              <tr class="bg-canvas text-left text-[13px] text-muted">
                <th scope="col" class="px-3 py-2 font-semibold">Garage · type</th>
                <th scope="col" class="px-3 py-2 text-right font-semibold">Needed</th>
                <th scope="col" class="px-3 py-2 text-right font-semibold">Listed</th>
                <th scope="col" class="px-3 py-2 font-semibold">When</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-subtle/60">
              <tr
                :for={row <- @fleet_rows}
                id={"plan-summary-fleet-#{row.index}"}
                data-role="plan-summary-fleet-row"
                data-total={to_string(row.total?)}
              >
                <td class={["whitespace-nowrap px-3 py-2", row.total? && "text-muted"]}>
                  {row.garage} · {row.type}
                </td>
                <td class={[
                  "px-3 py-2 text-right font-semibold tabular-nums",
                  row.short? && "text-error-fg"
                ]}>
                  {row.needed}{if row.short?, do: " !"}
                </td>
                <td class="px-3 py-2 text-right tabular-nums">{row.listed}</td>
                <td class="px-3 py-2 tabular-nums">{fleet_when(row.at_secs, row.needed)}</td>
              </tr>
            </tbody>
          </table>

          <p
            :if={@garages? and @vehicles?}
            id="plan-summary-fleet-note"
            class="mt-2 text-[13px] text-muted"
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
              class="relative flex h-28 items-end gap-px border-b border-control"
            >
              <i
                :for={bar <- @chart.bars}
                id={"plan-summary-bar-#{bar.start_secs}"}
                data-role="plan-summary-bar"
                data-over-listed={to_string(bar.over_listed?)}
                style={"height: #{bar.height}%"}
                class={[
                  "block min-w-0 flex-1",
                  (bar.over_listed? && "bg-error-line") || "bg-navy-300"
                ]}
                title={"#{clock(bar.start_secs)} · #{bar.count}"}
              >
              </i>
              <span
                id="plan-summary-listed-line"
                data-role="plan-summary-listed-line"
                data-listed={to_string(@chart.row.listed)}
                style={"bottom: #{@chart.listed_height}%"}
                class="pointer-events-none absolute inset-x-0 border-t-2 border-dashed border-warning-line"
              >
              </span>
              <span
                id="plan-summary-listed-label"
                class="pointer-events-none absolute right-0 -translate-y-full bg-white px-1 text-xs font-semibold text-warning-fg"
                style={"bottom: #{@chart.listed_height}%"}
              >
                {@chart.row.listed} listed
              </span>
            </div>
            <div class="mt-1 flex justify-between text-xs tabular-nums text-muted">
              <span>{clock(List.first(@chart.bins).start_secs)}</span>
              <span>{clock(List.last(@chart.bins).start_secs + 900)}</span>
            </div>
            <p id="plan-summary-chart-summary" class="mt-2 text-sm">
              {chart_summary(@chart.row)}
            </p>
          </div>
        </section>

        <section id="plan-summary-time" class="border-t border-subtle pt-5">
          <h3 class="text-[15px] font-bold text-strong">Time and distance</h3>
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
          <p id="plan-summary-time-note" class="mt-2 text-[13px] text-muted">
            Includes travel to and from the garage.{provisional_note(@errors?)}
          </p>
        </section>

        <section id="plan-summary-relief" class="border-t border-subtle pt-5">
          <h3 class="text-[15px] font-bold text-strong">Operator changes</h3>

          <p
            :if={is_nil(@max_piece_minutes)}
            id="plan-summary-relief-off"
            class="mt-2 text-sm text-muted"
          >
            Not checked. Mark the stops where operators can change and set the limit to check each
            block.
          </p>

          <div :if={@max_piece_minutes} id="plan-summary-relief-limit" class="mt-2">
            <dl class="grid grid-cols-[1fr_auto] gap-x-4 gap-y-2 text-sm">
              <dt class="text-muted">Longest time before a change</dt>
              <dd
                data-role="plan-summary-relief-longest"
                class={[
                  "text-right font-semibold tabular-nums",
                  (too_long?(@longest_stretch, @max_piece_minutes) && "text-warning-fg") ||
                    "text-strong"
                ]}
              >
                {stretch_label(@longest_stretch)}
              </dd>
            </dl>
            <p id="plan-summary-relief-note" class="mt-2 text-[13px] text-muted">
              Limit {duration(@max_piece_minutes)} · {count_label(@relief_stop_count, "stop", "stops")} marked.{too_long_note(
                @longest_stretch,
                @max_piece_minutes
              )}
            </p>
          </div>

          <button
            type="button"
            id="plan-summary-relief-open"
            phx-click="open_drawer"
            phx-value-key="operator_changes"
            class={[link_class(), "mt-1"]}
          >
            {if @max_piece_minutes, do: "Review operator changes", else: "Set up operator checks"}
          </button>
        </section>
      </.drawer_scroll>
    </.drawer>
    """
  end

  # One figure row of the Time and distance block. A `dl` may only hold `dt` and
  # `dd`, so the row is a component rather than a bare fragment: the value is one
  # slot and the `est.` mark stays in it, quiet, after the value.
  attr :key, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :estimated, :boolean, required: true

  defp plan_summary_total(assigns) do
    ~H"""
    <dt class="text-muted">{@label}</dt>
    <dd
      data-role={"plan-summary-total-#{@key}"}
      class="text-right font-semibold tabular-nums text-strong"
    >
      {@value}<span :if={@estimated} data-role="plan-summary-est" class="font-normal text-muted">
        est.
      </span>
    </dd>
    """
  end

  @doc """
  Renders the Block rules drawer: the settings every block of every service day
  in this version is drawn against, and the per-route garage and vehicle type the
  blocks resolve from.

  The settings fields are the context's own changeset, so each label, its help
  sentence and the field error sit together and the error text is the context's
  (the page never re-derives the 0–120, 60–1440, 0–60, 5–120 or 1.0–3.0 rules).
  The form validates as the reader types — its `phx-change` is the drawer's own
  event, which re-derives this drawer's state from the payload — and the submit
  saves through `Gtfs.update_blocking_settings/3` and then
  `Gtfs.update_route_operating_settings/3`.

  The Route switches control is the shared `segmented_control`, which renders its
  own `<form>`, so it cannot be a child of the drawer's form (nested forms are not
  valid HTML and the browser drops the inner one, taking its `phx-change` with it).
  It sits between two groups of the form's fields, so the fields' form is
  `contents` inside one grid and `order` puts the control in its reading position.
  The Save button lives in the pinned footer, outside that form, and submits it
  through its `form` attribute.

  The Route garages table is one row per route of the version, each with the
  home garage and required type selects the writer stores, and any refusal the
  context returned for that row prints under its own cell. The error summary
  counts every entry that needs fixing and says the other entries are kept.
  Closing the drawer returns focus to the link that opened it.
  """
  attr :open, :boolean, required: true
  attr :form, :any, required: true
  attr :interlining, :string, required: true
  attr :routes, :map, required: true
  attr :route_rows, :list, required: true
  attr :route_errors, :map, default: %{}
  attr :garages, :list, required: true
  attr :vehicle_types, :list, required: true
  attr :error, :string, default: nil
  attr :error_count, :integer, default: 0

  def block_rules_drawer(assigns) do
    ~H"""
    <.drawer
      id="block-rules-drawer"
      chrome="planner"
      open={@open}
      title="Block rules"
      initial_focus={:first_field}
      initial_focus_id="layover-minutes"
      return_focus_id="blocks-block-rules"
      class="max-w-[640px]"
    >
      <:lede>
        <span id="block-rules-scope">This version · applies to every service day</span>
      </:lede>

      <div id="block-rules-content" phx-hook="FormErrorFocus" class="flex min-h-0 flex-1 flex-col">
        <div class="grid flex-1 grid-cols-[minmax(0,1fr)] content-start gap-5 overflow-y-auto px-5 py-5 sm:px-6">
          <.form
            for={@form}
            id="block-rules-form"
            novalidate
            phx-change="block_rules_change"
            phx-debounce="200"
            phx-submit="save_block_rules"
            class="contents"
          >
            <.message
              :if={@error_count > 0}
              id="block-rules-errors"
              kind="error"
              title={error_summary_title(@error_count)}
              tabindex="-1"
            >
              Your other entries are kept.
            </.message>

            <p
              :if={@error}
              id="block-rules-error"
              role="alert"
              class="text-sm font-semibold text-error-fg"
            >
              {@error}
            </p>

            <.input
              id="layover-minutes"
              field={@form[:min_layover_minutes]}
              type="number"
              min={0}
              max={120}
              step={1}
              label="Minimum layover (min)"
              help="Shorter waits between trips are flagged. 0–120."
              class="w-full input input-lg max-w-40"
            />

            <.input
              id="block-rules-max-block"
              field={@form[:max_block_minutes]}
              type="number"
              min={60}
              max={1440}
              step={1}
              label="Longest time out of the garage (min) (optional)"
              help="Blank uses each vehicle type’s limit only. 60–1,440."
              class="w-full input input-lg max-w-40"
            />

            <.input
              id="block-rules-pull-out-buffer"
              field={@form[:pull_out_buffer_minutes]}
              type="number"
              min={0}
              max={60}
              step={1}
              label="Time before the first trip (min)"
              help="Added to each pull-out for checks and sign-on. 0–60."
              class="w-full input input-lg max-w-40"
            />

            <div class="order-2">
              <.input
                id="block-rules-default-garage"
                field={@form[:default_garage_id]}
                type="select"
                label="Default garage"
                prompt="No default garage"
                options={Enum.map(@garages, &{&1.name, &1.id})}
                help="Used when a block has no garage and its route has no home garage."
              />
            </div>

            <fieldset id="block-rules-driving" class="order-2 grid gap-1">
              <legend class="mb-2 text-[13px] font-[650] text-strong">
                Estimated driving times
              </legend>
              <div class="flex flex-wrap gap-4">
                <.input
                  id="block-rules-speed"
                  field={@form[:deadhead_speed_kmh]}
                  type="number"
                  min={5}
                  max={120}
                  step={1}
                  label="Speed (km/h)"
                  class="w-full input input-lg max-w-32"
                />
                <.input
                  id="block-rules-road-factor"
                  field={@form[:deadhead_circuity]}
                  type="number"
                  min={1}
                  max={3}
                  step={0.1}
                  label="Road factor"
                  class="w-full input input-lg max-w-32"
                />
              </div>
              <p id="block-rules-driving-help" class="text-[13px] text-muted">
                Straight-line distance × road factor ÷ speed. Entered driving times always win.
              </p>
            </fieldset>

            <section id="block-rules-routes" class="order-2 border-t border-subtle pt-5">
              <h3 class="text-[15px] font-bold text-strong">Route garages</h3>
              <p id="block-rules-routes-help" class="mt-1 text-[13px] text-muted">
                Where each route’s blocks start and end, and the vehicle type a route must use.
              </p>
              <div class="mt-3">
                <table class="w-full text-sm max-sm:[&_thead]:hidden max-sm:[&_tr]:grid max-sm:[&_tr]:gap-x-3 max-sm:[&_tr]:py-3 max-sm:[&_td]:block max-sm:[&_td]:px-0 max-sm:[&_td]:py-0">
                  <caption class="sr-only">Home garage and required vehicle type per route</caption>
                  <thead>
                    <tr class="bg-canvas text-left text-[13px] text-muted">
                      <th scope="col" class="px-3 py-2 font-semibold">Route</th>
                      <th scope="col" class="px-3 py-2 font-semibold">Home garage</th>
                      <th scope="col" class="px-3 py-2 font-semibold">Required type</th>
                    </tr>
                  </thead>
                  <tbody class="divide-y divide-subtle/60">
                    <tr
                      :for={{row, index} <- Enum.with_index(@route_rows)}
                      id={"block-rules-route-#{index}"}
                      data-role="block-rules-route-row"
                      data-route={row.route_id}
                    >
                      <td class="whitespace-nowrap px-3 py-2 align-top">
                        <span class="inline-flex min-h-11 items-center gap-2">
                          <.route_badge_for route_id={row.route_id} routes={@routes} />
                          {route_name(@routes, row.route_id)}
                        </span>
                      </td>
                      <td class="px-3 py-2 align-top">
                        <span class="text-[13px] font-[650] text-strong sm:hidden">Home garage</span>
                        <.input
                          id={"block-rules-route-#{index}-garage"}
                          type="select"
                          name={"route_settings[#{row.route_id}][garage_id]"}
                          value={row.garage_id}
                          prompt="No home garage"
                          options={Enum.map(@garages, &{&1.name, &1.id})}
                          errors={List.wrap(Map.get(@route_errors, {row.route_id, :garage_id}))}
                          aria-label={"Home garage for route " <> route_name(@routes, row.route_id)}
                        />
                      </td>
                      <td class="px-3 py-2 align-top">
                        <span class="text-[13px] font-[650] text-strong sm:hidden">
                          Required type
                        </span>
                        <.input
                          id={"block-rules-route-#{index}-type"}
                          type="select"
                          name={"route_settings[#{row.route_id}][required_vehicle_type_id]"}
                          value={row.required_vehicle_type_id}
                          prompt="Any type"
                          options={Enum.map(@vehicle_types, &{&1.name, &1.id})}
                          errors={
                            List.wrap(
                              Map.get(@route_errors, {row.route_id, :required_vehicle_type_id})
                            )
                          }
                          aria-label={"Required type for route " <> route_name(@routes, row.route_id)}
                        />
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </section>
          </.form>

          <%!-- Outside the form on purpose: `segmented_control` renders its own
          `<form phx-change>`, and a nested form is not valid HTML — the browser
          drops the inner element and its change event with it. It posts the same
          event, and its value is the drawer's own state, which the submit reads. --%>
          <div class="order-1">
            <.segmented_control
              id="block-rules-interlining"
              name="interlining"
              legend="Route switches within a block"
              options={[
                {"Anywhere", "any"},
                {"Same stop only", "same_stop"},
                {"Not allowed", "none"}
              ]}
              value={@interlining}
              event="block_rules_change"
              appearance={:joined}
              emphasis={:selection}
            />
            <p id="block-rules-interlining-help" class="mt-1.5 text-[13px] text-muted">
              A vehicle may finish one route and start another. “Same stop only” avoids driving
              without riders between routes.
            </p>
          </div>
        </div>

        <.drawer_footer>
          <p id="block-rules-note" class="mr-auto min-w-0 text-[13px] text-muted">
            Changing these redraws every block.
          </p>
          <.button
            type="button"
            id="block-rules-cancel"
            variant="secondary"
            class="min-h-11"
            phx-click="close_drawer"
          >
            Cancel
          </.button>
          <.button
            type="submit"
            id="block-rules-submit"
            form="block-rules-form"
            class="min-h-11"
            phx-disable-with="Saving…"
          >
            Save block rules
          </.button>
        </.drawer_footer>
      </div>
    </.drawer>
    """
  end

  # The summary counts what is wrong, not what is right, so a reader with one bad
  # entry is not told about the seven good ones.
  defp error_summary_title(1), do: "1 entry needs fixing."
  defp error_summary_title(count), do: "#{count} entries need fixing."

  @doc """
  Renders the Driving times drawer: the day's directional pairs, most used
  first, with each one's minutes, source and a reset for an entered value.

  The rows are the pairs `Gtfs.list_deadhead_pairs/3` read for this service day,
  in that function's own order (uses descending, then labels and refs), so the
  drawer and the day's movements can never disagree about a drive. Each row's
  input carries the `minutes[<from>|<to>]` name — the ordered pair
  `put_deadhead_time/4` takes — and prints the minutes the reader typed so far, so
  a refused save keeps every entry. A row that cannot be measured (`minutes` is
  `nil`) shows a blank input and no badge rather than a zero.

  “Estimated only” hides the entered rows without losing what was typed, the
  count beside it is the drawer's own “N of M estimated”, and the footer keeps
  the note and its two buttons. `focus_id` is the highlighted row's input, which
  is what `?pair=…` sets, so the row a link named is both marked and focused on
  open.
  """
  attr :open, :boolean, required: true
  attr :rows, :list, required: true
  attr :day_label, :string, required: true
  attr :circuity, :any, required: true
  attr :speed, :any, required: true
  attr :estimated_only?, :boolean, default: false
  attr :estimated_count, :integer, required: true
  attr :total_count, :integer, required: true
  attr :focus_id, :string, default: nil
  attr :error, :string, default: nil

  def driving_times_drawer(assigns) do
    ~H"""
    <.drawer
      id="driving-times-drawer"
      chrome="planner"
      open={@open}
      class="max-w-[760px]"
      title="Driving times"
      initial_focus={:first_field}
      initial_focus_id={@focus_id}
      return_focus_id="blocks-driving-times"
    >
      <:lede><span id="driving-times-scope">{@day_label} · this version</span></:lede>

      <div id="driving-times-content" phx-hook="FormErrorFocus" class="flex min-h-0 flex-1 flex-col">
        <%!-- The filter and the rows are one form on purpose: a change event
        then carries the filter and every value the reader typed, so “Estimated
        only” cannot hide a row and lose the entry in it. --%>
        <form
          id="driving-times-form"
          novalidate
          phx-change="filter_driving_times"
          phx-submit="save_driving_times"
          class="flex min-h-0 flex-1 flex-col"
        >
          <.drawer_scroll>
            <p id="driving-times-intro" class="text-sm text-muted">
              Driving without riders between the places this service day’s blocks connect, most
              used first. Estimates use straight-line distance × {@circuity} ÷ {@speed} km/h. Each
              direction is separate.
            </p>

            <.message :if={@error} id="driving-times-error" kind="error" title={@error} />

            <div class="flex flex-wrap items-center justify-between gap-3">
              <label class="flex min-h-11 cursor-pointer items-center gap-2.5 text-sm font-[650] text-strong">
                <input
                  type="checkbox"
                  id="driving-times-estimated-only"
                  name="estimated_only"
                  checked={@estimated_only?}
                  class="size-5 accent-action"
                /> Estimated only
              </label>
              <p id="driving-times-count" class="text-[13px] text-muted">
                {@estimated_count} of {@total_count} estimated
              </p>
            </div>

            <div
              id="driving-times-container"
              class="overflow-x-auto rounded-card border border-subtle"
            >
              <table class="w-full text-sm">
                <thead>
                  <tr class="bg-canvas text-left text-[13px] text-muted">
                    <th scope="col" class="px-3 py-2 font-semibold">From → to</th>
                    <th scope="col" class="px-3 py-2 text-right font-semibold">Used</th>
                    <th scope="col" class="px-3 py-2 font-semibold">Minutes</th>
                    <th scope="col" class="px-3 py-2 font-semibold max-sm:hidden">Source</th>
                    <th scope="col" class="px-3 py-2"><span class="sr-only">Actions</span></th>
                  </tr>
                </thead>
                <tbody id="driving-times" class="divide-y divide-subtle/60">
                  <tr :for={row <- @rows} id={row.dom_id} class={[row.highlighted? && "bg-selection"]}>
                    <td class="px-3 py-2 align-top font-[650] text-strong">
                      <span class="inline-flex min-h-11 items-center">
                        {row.from_label} → {row.to_label}
                      </span>
                    </td>
                    <td class="px-3 py-2 text-right align-top tabular-nums">
                      <span class="inline-flex min-h-11 items-center">{row.uses}</span>
                    </td>
                    <td class="px-3 py-2 align-top">
                      <.input
                        id={row.input_id}
                        type="number"
                        name={"minutes[#{row.key}]"}
                        value={row.value}
                        min={0}
                        max={600}
                        step={1}
                        errors={List.wrap(row.error)}
                        aria-label={"Minutes, #{row.from_label} to #{row.to_label}"}
                        class="w-24 input input-lg"
                      />
                      <%!-- Below sm the Source column is hidden, so the source sits under
                      the minutes it describes. --%>
                      <span class="sm:hidden">
                        <.finding_badge :if={row.source == :entered} tone={:success} label="Entered" />
                        <.finding_badge
                          :if={row.source == :estimated}
                          tone={:neutral}
                          label="Estimated"
                        />
                      </span>
                    </td>
                    <td class="px-3 py-2 align-top max-sm:hidden">
                      <span class="inline-flex min-h-11 items-center">
                        <.finding_badge :if={row.source == :entered} tone={:success} label="Entered" />
                        <.finding_badge
                          :if={row.source == :estimated}
                          tone={:neutral}
                          label="Estimated"
                        />
                        <span :if={row.source == :unknown} class="text-muted">Unknown</span>
                      </span>
                    </td>
                    <td class="px-3 py-2 align-top">
                      <button
                        :if={row.source == :entered}
                        type="button"
                        id={row.dom_id <> "-reset"}
                        phx-click="reset_driving_time"
                        phx-value-pair={row.key}
                        class={[link_class(), "whitespace-nowrap"]}
                      >
                        Reset to estimate
                      </button>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </.drawer_scroll>

          <.drawer_footer>
            <p id="driving-times-note" class="mr-auto min-w-0 text-[13px] text-muted">
              Changing a time redraws the blocks that use it.
            </p>
            <.button
              type="button"
              id="driving-times-cancel"
              variant="secondary"
              class="min-h-11"
              phx-click="close_drawer"
            >
              Cancel
            </.button>
            <.button
              type="submit"
              id="driving-times-submit"
              class="min-h-11"
              phx-disable-with="Saving…"
            >
              Save driving times
            </.button>
          </.drawer_footer>
        </form>
      </div>
    </.drawer>
    """
  end

  @doc """
  Renders the Operator changes drawer: the longest time one operator may work
  before another takes over, and the stops and stations where that can happen.

  The rows are the candidates `Gtfs.list_relief_candidates/3` read for this
  service day, in that function's own order (waits descending, then name, then
  ID), so the drawer and the day it checks cannot disagree about where a change is
  possible. A station row carries the names of the stops it covers on its own
  line, so marking it once is visibly the same thing as marking both bays.

  The limit is pre-filled with 330 when the version has none, which is the
  researched common contract limit; a blank limit is a real answer — it turns the
  checks off — so the field carries the reader's own text and an out-of-range value
  keeps every tick while the error prints under the field. `limit_error` is the
  shared input's own field error, which is also what makes the field
  `aria-invalid` and the target the drawer's focus hook moves to; `error` is the
  drawer's own sentence, for a refusal the field cannot explain and for the flash
  that would otherwise render behind this top-layer dialog.
  """
  attr :open, :boolean, required: true
  attr :rows, :list, required: true
  attr :limit, :string, default: ""
  attr :error, :string, default: nil
  attr :limit_error, :string, default: nil

  def operator_changes_drawer(assigns) do
    ~H"""
    <.drawer
      id="operator-changes-drawer"
      chrome="planner"
      open={@open}
      title="Operator changes"
      initial_focus={:first_field}
      initial_focus_id="operator-changes-limit"
      return_focus_id="blocks-summary-figures-item-vehicles"
      class="max-w-[520px]"
    >
      <%!-- The scope sentence names the version rather than the loaded service
      day, because the limit and the marks are stored per version: a reader who
      sets them here is answering for every service day, while the rows below are
      this one's candidates. --%>
      <:lede><span id="operator-changes-scope">This version · every service day</span></:lede>

      <div
        id="operator-changes-content"
        phx-hook="FormErrorFocus"
        class="flex min-h-0 flex-1 flex-col"
      >
        <form
          id="operator-changes-form"
          novalidate
          phx-submit="save_operator_changes"
          class="flex min-h-0 flex-1 flex-col"
        >
          <.drawer_scroll>
            <p id="operator-changes-intro" class="text-sm text-muted">
              A block longer than one operator’s shift needs a stop where another operator can
              take over. This is also called a relief point.
            </p>

            <%!-- The refused limit is the shared `input`'s own field error, so the
            sentence sits under the field it is about, the field carries
            `aria-invalid`, and the drawer's focus hook moves the reader's focus
            onto it rather than onto the summary above the form. A refusal the
            field cannot explain is the drawer's own sentence instead. --%>
            <.message
              :if={not is_nil(@error) and is_nil(@limit_error)}
              id="operator-changes-error"
              kind="error"
              title={@error}
            />

            <.input
              id="operator-changes-limit"
              type="number"
              name="limit"
              value={@limit}
              min={60}
              max={720}
              step={1}
              label="Longest time before an operator change (min)"
              errors={List.wrap(@limit_error)}
              help="From sign-on, waits included. Blank turns these checks off. 330 min is 5½ hours, the most common contract limit before a meal break. 60–720."
              class="w-28 input input-lg"
            />

            <div
              id="operator-changes-container"
              class="overflow-x-auto rounded-card border border-subtle"
            >
              <table class="w-full text-sm">
                <thead>
                  <tr class="bg-canvas text-left text-[13px] text-muted">
                    <th scope="col" class="px-3 py-2 font-semibold">Stop or station</th>
                    <th scope="col" class="px-3 py-2 text-right font-semibold">Waits here</th>
                    <th scope="col" class="px-3 py-2 font-semibold">Operators can change here</th>
                  </tr>
                </thead>
                <tbody id="operator-changes" class="divide-y divide-subtle/60">
                  <tr :for={row <- @rows} id={row.dom_id}>
                    <td class="px-3 py-2 align-middle">
                      <span class="font-[650] text-strong">{row.name}</span>
                      <span :if={row.station?} class="block text-[13px] text-muted">
                        Station · covers {Enum.join(row.child_names, " and ")}
                      </span>
                    </td>
                    <td class="px-3 py-2 text-right align-middle tabular-nums">{row.waits}</td>
                    <td class="px-3 py-2 align-middle">
                      <%!-- A visible label would repeat the row's own name twice on
                      one row, so the checkbox carries that name as its accessible
                      name instead and the 44 px label around it is the target. --%>
                      <label class="grid min-h-11 min-w-11 cursor-pointer place-items-center">
                        <input
                          type="checkbox"
                          id={row.input_id}
                          name="marked[]"
                          value={row.stop_id}
                          aria-label={"Operators can change at " <> row.name}
                          checked={row.marked?}
                          class="size-5 accent-action"
                        />
                      </label>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>

            <p id="operator-changes-note" class="text-[13px] text-muted">
              Lists the stops where this service day’s trips start or end. Changes partway through
              a trip aren’t checked.
            </p>
          </.drawer_scroll>

          <.drawer_footer>
            <.button
              type="button"
              id="operator-changes-cancel"
              variant="secondary"
              class="min-h-11"
              phx-click="close_drawer"
            >
              Cancel
            </.button>
            <.button
              type="submit"
              id="operator-changes-submit"
              class="min-h-11"
              phx-disable-with="Saving…"
            >
              Save operator changes
            </.button>
          </.drawer_footer>
        </form>
      </div>
    </.drawer>
    """
  end

  @doc """
  Renders the Suggest blocks drawer: which trips a suggestion would plan again,
  the rules it would use, and the two facts that change how far a reader trusts
  it — how many driving times are still estimates, and which repeating service
  is left out.

  The three scopes are the generator's own modes: unassigned trips only, the
  selected blocks, and every trip in the service day. “Selected blocks” is
  disabled with its reason when the timeline has no selection and names the
  blocks it would plan when it has one; the unassigned scope is disabled when the
  service day has nothing unassigned to plan, which is what the generator's own
  pool would answer. Each card is a real label around its radio, so the whole card
  is the 44 px target and its visible title is the radio's accessible name.

  `rules` is the `{label, value}` list the page derived from the loaded day, so
  the drawer prints the stored answers rather than re-reading them. The two links
  leave this drawer for the drawer that owns those rules; a reader who comes back
  opens this one again.

  The drawer writes nothing: it asks for a preview and the page renders that
  separately. `busy` is the double-submit guard — while a suggestion is being
  built the footer names what is happening and both actions are disabled.
  """
  attr :open, :boolean, required: true
  attr :scope, :atom, required: true
  attr :options, :list, required: true
  attr :rules, :list, required: true
  attr :estimated_pairs, :integer, default: 0
  attr :repeating_trip_ids, :list, default: []
  attr :operator_checked?, :boolean, default: false
  attr :too_large, :integer, default: nil
  attr :error, :string, default: nil
  attr :busy, :boolean, default: false
  attr :day_label, :string, default: ""

  def suggest_drawer(assigns) do
    ~H"""
    <.drawer
      id="suggest-drawer"
      chrome="planner"
      open={@open}
      pending={@busy}
      title="Suggest blocks"
      initial_focus={:heading}
      return_focus_id="blocks-suggest"
      class="max-w-[520px]"
    >
      <:lede><span id="suggest-scope">{@day_label}</span></:lede>

      <div id="suggest-content" aria-busy={to_string(@busy)} class="flex min-h-0 flex-1 flex-col">
        <.drawer_scroll>
          <p id="suggest-intro" class="text-sm text-muted">
            Try a plan using your garages, driving times and limits. Nothing is saved until you
            review it and apply it.
          </p>

          <.message :if={not is_nil(@error)} id="suggest-error" kind="error" title={@error} />

          <form id="suggest-scope-form" phx-change="suggest_scope_change">
            <fieldset id="suggest-scopes" class="grid gap-2">
              <legend class="mb-2 text-[13px] font-[650] text-strong">Trips to plan</legend>
              <label
                :for={option <- @options}
                class={[
                  "flex min-h-11 items-start gap-3 rounded-control border border-subtle px-3.5 py-3 has-[:checked]:border-action has-[:checked]:bg-selection",
                  (option.disabled? && "cursor-not-allowed opacity-70") || "cursor-pointer"
                ]}
              >
                <input
                  type="radio"
                  id={"suggest-scope-#{option.value}"}
                  name="scope"
                  value={option.value}
                  checked={@scope == option.value}
                  disabled={option.disabled?}
                  class="mt-0.5 size-4 accent-action"
                />
                <span>
                  <span class="block text-sm font-[650] text-strong">{option.title}</span>
                  <span class="block text-[13px] text-muted">{option.description}</span>
                </span>
              </label>
            </fieldset>
          </form>

          <section id="suggest-rules" class="border-t border-subtle pt-5">
            <h3 class="text-[15px] font-bold text-strong">Rules used</h3>
            <dl id="suggest-rules-list" class="mt-2 grid gap-1.5 text-sm">
              <div :for={{label, value} <- @rules} class="flex justify-between gap-4">
                <dt class="text-muted">{label}</dt>
                <dd class="text-right font-[650] text-strong">{value}</dd>
              </div>
            </dl>
            <div id="suggest-rules-links" class="mt-1 flex flex-wrap gap-x-4">
              <button
                type="button"
                id="suggest-open-rules"
                phx-click="open_drawer"
                phx-value-key="block_rules"
                class={link_class()}
              >
                Block rules
              </button>
              <button
                type="button"
                id="suggest-open-operator-changes"
                phx-click="open_drawer"
                phx-value-key="operator_changes"
                class={link_class()}
              >
                Operator changes
              </button>
            </div>
          </section>

          <.message
            :if={@estimated_pairs > 0}
            id="suggest-estimated-warning"
            kind="warning"
            title={"#{@estimated_pairs} driving times are estimates."}
          >
            Traffic and road access can make them too short. Check the busiest connections before
            applying a plan.
            <div class="mt-0.5">
              <button
                type="button"
                id="suggest-review-driving-times"
                phx-click="open_drawer"
                phx-value-key="driving_times"
                class={link_class()}
              >
                Review driving times
              </button>
            </div>
          </.message>

          <p :if={@repeating_trip_ids != []} id="suggest-repeating" class="text-sm text-muted">
            {Enum.join(@repeating_trip_ids, ", ")} repeats without individual departures and stays
            unassigned.
          </p>

          <p :if={not @operator_checked?} id="suggest-operator-note" class="text-sm text-muted">
            Operator changes aren’t checked, so suggestions may produce blocks no single operator
            can work.
          </p>

          <.message
            :if={not is_nil(@too_large)}
            id="suggest-too-large"
            kind="warning"
            title={"This scope has #{@too_large} trips."}
          >
            A suggestion plans up to 3,000 trips at a time. Choose a narrower scope, or plan this
            service day in more than one suggestion.
          </.message>
        </.drawer_scroll>

        <.drawer_footer>
          <.button
            type="button"
            id="suggest-cancel"
            variant="secondary"
            class="min-h-11"
            phx-click="close_drawer"
            disabled={@busy}
          >
            Cancel
          </.button>
          <.button
            type="button"
            id="suggest-preview"
            class="min-h-11"
            phx-click="preview_suggestion"
            disabled={@busy}
          >
            {if @busy, do: "Building suggestion…", else: "Preview suggestion"}
          </.button>
        </.drawer_footer>
      </div>
    </.drawer>
    """
  end

  @doc """
  Renders the trip drawer: the trip's identity, its stored times and
  block, every service day it runs in with the all-dates scope sentence, its own
  findings and every type 4/5 record naming it.

  The service-day links patch `day` and `trip`, so one link follows the trip to
  another day's page with the drawer open again. The record list holds every
  record that names the trip, including one whose pair has no hosting gap. A
  repeating trip carries the repeat text and one with missing times its warning;
  neither can be plotted.

  A record whose state is stale is broken — no block reaches it — so it offers
  “Remove transfer record”, and the shared `confirm_dialog` names the pair and
  the setting it deletes before anything is removed. Every other record is
  printed as left untouched, because an unconfirmed or matching record may be
  valid GTFS. The removal itself is the LiveView's write; the drawer only asks.

  A trip opened from the block drawer keeps that block in the URL and prints
  “Back to block <id>”, which returns to the block drawer.
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
  attr :remove_record, :map, default: nil
  attr :remove_pending, :boolean, default: false

  def trip_drawer(assigns) do
    assigns =
      assigns
      |> assign(:total_dates, Enum.sum(Enum.map(assigns.day_types, & &1.date_count)))
      |> assign(:title, trip_title(assigns.trip))
      |> assign(:remove_copy, remove_record_copy(assigns.remove_record))

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
              id={transfer_entry_id(entry.row.id)}
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

              <%!-- Only a stale record is broken, so only a stale record offers its
              own removal; a matching or unconfirmed one may be valid GTFS and is
              printed as left untouched. --%>
              <.button
                :if={stale_entry?(entry.state)}
                id={remove_record_button_id(entry.row.id)}
                type="button"
                variant="danger"
                class="mt-2 min-h-11"
                phx-click="request_remove_record"
                phx-value-id={entry.row.id}
              >
                Remove transfer record
              </.button>
              <p :if={not stale_entry?(entry.state)} class="mt-1 text-[13px] text-muted">
                Left untouched: the record may be valid GTFS.
              </p>
            </div>
          </div>
          <p :if={@in_seat == []} class="text-sm text-muted">
            No stay-on-board records mention this trip.
          </p>
        </.drawer_section>

        <%!-- The trip's own assign controls: a blocked trip can be removed from its
        block, and any eligible trip can open the destination picker in this drawer.
        An ineligible trip keeps “Remove from block” only, because an
        assignment needs usable times and a single trip. Opening the picker
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

    <%!-- The removal question. It is the shared `confirm_dialog` rather than a
    drawer of its own: a record the editor may still want is a question, not a
    page. It names the pair and the setting it deletes, and cancelling leaves the
    record exactly as it was. --%>
    <.confirm_dialog
      id="remove-record-dialog"
      chrome="planner"
      open={not is_nil(@remove_record)}
      title={@remove_copy.title}
      confirm_label="Remove record"
      pending_label="Removing…"
      pending={@remove_pending}
      on_confirm="confirm_remove_record"
      on_cancel="cancel_remove_record"
      described_by="remove-record-dialog-body"
      return_focus_id={@remove_copy.return_focus_id}
    >
      <p>{@remove_copy.body}</p>
    </.confirm_dialog>
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
  matching block IDs instead of scanning the service day. “New block” is
  always first because a new ID is resolved under the lock before the review; an
  exact match leads the results; a blocked trip also offers “No block”, which
  removes it. A failed save keeps the chosen radio checked and prints the
  sentence in `#assign-error`, and an ineligible trip is named instead of being
  silently dropped.

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
    carries the destination and the narrowed search together. --%>
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
      silently. A selection gets its own message: the reason per trip
      and “Use eligible trips”, which drops the ineligible trips and keeps the
      dialog open on what remains. --%>
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
  reviewed command.
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
        existing: existing_problem_count(assigns.review),
        attributes?: attributes?(assigns.review)
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

        <div class={[
          "grid gap-3 rounded-card bg-canvas p-3",
          (@attributes? && "grid-cols-2") || "grid-cols-3"
        ]}>
          <.review_metric
            :if={not @attributes?}
            value={length(@review.changes)}
            label="trips change block"
          />
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
            {if @attributes?, do: "Garage and type", else: "Assignment changes"}
          </h3>

          <p :if={@attributes?} id="block-review-attributes" class="mt-2 text-sm">
            No trip changes block. The block's garage and type are saved for every calendar it
            runs on, and the service days below are the ones that changes.
          </p>

          <div
            :if={not @attributes?}
            class="mt-2 max-h-56 overflow-auto rounded-card border border-subtle"
          >
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
            <.review_effect :for={effect <- @review.effects} effect={effect} review={@review} />
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
          {if @attributes?,
            do: "Trip times, stop order, block IDs and stay-on-board records don't change.",
            else: "Trip times, stop order and stay-on-board records don't change."}
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
  Renders one affected service day of a review: its heading, what the change does
  there, the block it splits and the problems it adds.

  The review dialog and the Suggested blocks panel read the same `Review.effects`
  through this one component, so a service day says the same thing in both places
  and a change to the sentence is one change. The selected service day reads
  `current_label` (“This service day” in the review, “Current view” in the panel)
  and the others “Also changes”, and each card carries its own day count, because a
  reader reading the plan on one service day still has to know what the same plan
  does on the others.
  """
  attr :effect, :map, required: true
  attr :review, :map, required: true
  attr :current_label, :string, default: "This service day"

  def review_effect(assigns) do
    ~H"""
    <div
      id={"review-effect-" <> @effect.day_type.key}
      data-role="review-effect"
      data-selected={to_string(@effect.selected?)}
      class="rounded-card border border-subtle px-3.5 py-3 text-sm"
    >
      <p class="font-bold text-strong">
        {if @effect.selected?, do: @current_label, else: "Also changes"} · {@effect.day_type.label} · {day_count_label(
          @effect.day_type.date_count
        )}
      </p>
      <p class="mt-1">{effect_sentence(@effect, @review)}</p>
      <p :for={split <- @effect.splits} class="mt-1">
        Block {split.block_id} splits: {split.remaining} {if split.remaining == 1,
          do: "trip stays",
          else: "trips stay"} on {split.block_id}.
      </p>
      <p
        :for={finding <- added_problems(@effect)}
        data-role="review-added"
        class="mt-1.5 flex flex-wrap items-center gap-2"
      >
        <span class="font-semibold">Added</span>
        <.code_badge code={finding.code} />
        <span>{finding_detail(finding)}</span>
      </p>
      <p :if={added_problems(@effect) == []} class="mt-1 text-muted">
        No new timing or transfer problems on these days.
      </p>
    </div>
    """
  end

  @doc """
  Renders the connection drawer for one pair of trips: the connection's own title
  and subtitle, its times and the handoff, the hints that follow from them, the
  note its saved record earns, the table of what each trip planner will tell a
  rider, and the pair's own driving-time and operator-change links.

  It is a non-modal inspector: it opens beside the page rather than over it, so
  the reader can keep the timeline behind it while they read the connection.

  The title names the two routes the way the timeline's own badges do — through
  the day's route map, never a stored route ID when a short name exists — and the
  subtitle names the block, the two trips and the place the connection is decided
  at, all of which `Blocking.Connections` already grouped.

  The hints, the rider rows, the footnote and the refusal text are
  `Blocking.RiderOutcomes`, so the drawer's claim about what a planner will do is
  written once and the drawer and the refused save cannot disagree.

  The drive, the wait and the windows come from the block's own
  `Movements.build/3` gap and the `Relief.windows/3` of that gap, so the drawer
  re-derives neither a distance, a driving time nor a handoff kind. The source
  badge is the movement's own `:entered` or `:estimated`; a drive whose time the
  version cannot compute says so rather than printing a zero, and a gap that
  needs no drive at all says which handoff made it. A negative gap is an overlap,
  and its drawer prints the overlap minutes; the timeline deliberately draws no
  bar for one, so this drawer and the block drawer's own gap note are how an
  overlapping pair is read.

  The two settings links are the ones that own the numbers: the driving-time link
  names the pair in the `stop:<id>|stop:<id>` form `Gtfs.list_deadhead_pairs/3`
  hands out, and it is offered only for a gap that has a drive to enter. Operator
  changes are open for every gap, because a layover is as much a place to change
  as a drive is.

  Anything the pair's record list leaves open is stated rather than left blank,
  and the two “Inspect” buttons open each trip's own drawer with this block kept,
  so the trip drawer can return here through the block.
  """
  attr :open, :boolean, required: true
  attr :from, :map, required: true
  attr :to, :map, required: true
  attr :gap, :map, required: true
  attr :movement, :map, default: nil
  attr :windows, :list, default: []
  attr :relief_checked?, :boolean, default: false
  attr :day_label, :string, default: nil
  attr :block_id, :string, required: true
  attr :records, :list, required: true
  attr :routes, :map, required: true
  attr :setting, :atom, default: :none, values: [:none, :stay, :reboard, :conflict]
  attr :place, :string, default: nil
  attr :turnback?, :boolean, default: false
  attr :short?, :boolean, default: false
  attr :back_block, :string, default: nil
  attr :version_id, :string, required: true
  attr :connection_form, :any, required: true
  attr :connection_draft, :atom, default: nil
  attr :connection_saved, :atom, default: nil
  attr :connection_check, :any, default: nil
  attr :connection_scope, :map, default: nil
  attr :connection_error, :map, default: nil
  attr :connection_pending, :boolean, default: false
  attr :discard, :map, default: nil

  def gap_drawer(assigns) do
    connection = %{
      from: assigns.from,
      to: assigns.to,
      gap: assigns.gap,
      turnback?: assigns.turnback?
    }

    assigns =
      assigns
      |> assign(:connection, connection)
      |> assign(:text, gap_text(assigns.gap, assigns.from, assigns.to, assigns.movement))
      |> assign(
        :title,
        connection_title(assigns.routes, assigns.from, assigns.to, assigns.turnback?)
      )
      |> assign(:note, gap_note(assigns.gap, assigns.movement))
      |> assign(:places, window_places(assigns.windows, assigns.from, assigns.to))
      |> assign(:pair, drive_pair(assigns.movement, assigns.from, assigns.to))
      |> assign(:hints, RiderOutcomes.hints(connection))
      |> assign(:rider_footnote, RiderOutcomes.footnote())
      |> assign(:record_note, record_note(assigns.records, assigns.to))
      |> assign(:on_board, on_board_text(assigns.gap, assigns.movement))
      |> assign(
        :choices,
        connection_choices(assigns.connection_saved, assigns.connection_check)
      )
      |> assign(:refusal, connection_refusal(assigns.connection_check))
      |> assign(:scope, connection_scope_sentence(assigns.connection_scope))
      |> assign(
        :choice_rows,
        connection_choice_rows(connection, assigns.connection_draft, assigns.setting)
      )
      |> assign(
        :stay_warnings,
        connection_stay_warnings(connection, assigns.gap, assigns.connection_draft)
      )
      |> assign(
        :pair_map,
        connection_pair_map(assigns.from, assigns.to, assigns.gap, assigns.routes)
      )

    ~H"""
    <.drawer
      id="gap-drawer"
      chrome="planner"
      modal={false}
      open={@open}
      pending={@connection_pending}
      title={@title}
      class="max-w-[min(100vw,30rem)]"
    >
      <:lede>
        Block {@block_id} · trip {@from.trip_id} → {@to.trip_id} · {@place}{day_label(@day_label)}
      </:lede>

      <.drawer_scroll>
        <%!-- A layover below the minimum is the block's own :short_layover finding,
        which is also what marks the timeline's gap. A drive the vehicle cannot make
        in time is the block's own :cannot_reach finding, and it is the one notice
        that asks for a decision rather than reporting a number, so it leads the
        drawer. --%>
        <.message
          :if={@note}
          id="gap-text"
          data-short={to_string(@short?)}
          kind={gap_kind(@gap, @movement, @short?)}
          title={@text}
        >
          {@note}
        </.message>
        <.message
          :if={!@note}
          id="gap-text"
          data-short={to_string(@short?)}
          kind={gap_kind(@gap, @movement, @short?)}
          title={@text}
        />

        <dl class="divide-y divide-subtle/70 border-y border-subtle/70 text-sm">
          <.trip_field wide? label="Arrives">
            <strong>{clock(@from.last_arrival)}</strong> · {stop_name(@from.last_stop)}
          </.trip_field>
          <.trip_field wide? label="Departs">
            <strong>{clock(@to.first_departure)}</strong> · {stop_name(@to.first_stop)}
          </.trip_field>
          <.trip_field wide? label="On board">
            <span id="gap-available">{@on_board}</span>
          </.trip_field>
          <.trip_field wide? label="Driving without riders">
            <span id="gap-drive">{drive_text(@movement, @gap)}</span>
            <.finding_badge
              :if={drive_source(@movement)}
              id="gap-drive-source"
              tone={drive_badge_tone(@movement)}
              label={drive_source(@movement)}
            />
          </.trip_field>
          <.trip_field wide? label="Wait">
            <span id="gap-wait">{wait_text(@movement)}</span>
          </.trip_field>
          <.trip_field wide? label="Operators can change">
            <span id="gap-operators">{operator_change_text(@relief_checked?, @places)}</span>
          </.trip_field>
        </dl>

        <%!-- `RiderOutcomes` owns the order these arrive in — the route change, the
        turnback, the wait, then the distance — so the list here is the same list
        the rejected save explains itself with. --%>
        <ul :if={@hints != []} id="gap-hints" class="grid gap-1.5">
          <li
            :for={hint <- @hints}
            data-role="gap-hint"
            data-hint={hint.kind}
            class="flex gap-2 text-[13px] text-default"
          >
            <.icon name={hint_icon(hint.kind)} class="mt-0.5 size-4 shrink-0" />
            <span class="min-w-0">{hint.text}</span>
          </li>
        </ul>

        <.message
          :if={@record_note}
          id="gap-record-note"
          data-role="gap-record"
          data-quiet={to_string(@record_note.quiet?)}
          kind={if @record_note.quiet?, do: "info", else: "warning"}
          title={@record_note.title}
        >
          {@record_note.body}
        </.message>

        <%!-- The three-way choice. The cards are feature-local markup rather than
        `PlannerComponents.choice_cards/1`: that helper has no per-option disabled
        state and no content slot, and the R1 pre-check needs both, so the shared
        API is left alone for its one other consumer. Each card is a whole-card
        label with a real radio inside it, so the keyboard arrows move between the
        options and the focus outline follows the card. --%>
        <.form for={@connection_form} id="connection-form" phx-change="change_connection">
          <fieldset class="min-w-0">
            <legend class="text-base font-bold text-strong">Can riders stay on board?</legend>
            <p :if={@scope} id="connection-scope" class="mt-0.5 text-[13px] text-muted">
              {@scope}
            </p>
            <div class="mt-3 grid gap-2">
              <label
                :for={choice <- @choices}
                data-role="connection-choice"
                data-choice={choice.value}
                data-saved={to_string(choice.saved?)}
                data-disabled={to_string(choice.disabled?)}
                class={[
                  "grid min-w-0 cursor-pointer grid-cols-[18px_minmax(0,1fr)] gap-x-3",
                  "rounded-card border border-control px-3.5 py-3",
                  "has-[:checked]:border-action has-[:checked]:bg-selection",
                  "has-[:focus-visible]:outline-2 has-[:focus-visible]:outline-offset-2",
                  "has-[:focus-visible]:outline-focus",
                  choice.disabled? && "cursor-not-allowed bg-canvas"
                ]}
              >
                <input
                  type="radio"
                  id={"connection-choice-#{choice.dom}"}
                  name="connection[choice]"
                  value={choice.value}
                  checked={@connection_draft == choice.choice}
                  disabled={choice.disabled?}
                  class="mt-0.5 size-[18px] shrink-0 accent-action focus-visible:outline-0"
                />
                <span class="min-w-0">
                  <span class="flex flex-wrap items-center gap-2 text-sm font-semibold text-strong">
                    {choice.title}
                    <span
                      :if={choice.saved?}
                      data-role="connection-saved-tag"
                      class="rounded-badge bg-canvas px-1.5 text-[12px] font-semibold text-default"
                    >
                      Saved
                    </span>
                  </span>
                  <span class="mt-0.5 block text-[13px] text-default">{choice.description}</span>
                  <%!-- The two warnings belong inside the stay card, because they
                  are what choosing stay would cost: the vehicle moving empty
                  between the stops, and OpenTripPlanner dropping the record where
                  pickup or drop-off is not allowed. Both are the pair's own facts,
                  from the block's handoff and from `RiderOutcomes`, and neither
                  refuses the choice. --%>
                  <span
                    :for={warning <- stay_warnings_for(choice.choice, @stay_warnings)}
                    data-role="connection-choice-warning"
                    data-warning={warning.kind}
                    class="mt-2 flex gap-1.5 text-[13px] font-semibold text-warning-fg"
                  >
                    <.icon
                      name="hero-exclamation-triangle-mini"
                      class="mt-0.5 size-4 shrink-0"
                    />
                    <span class="min-w-0">{warning.text}</span>
                  </span>
                </span>
              </label>
            </div>

            <%!-- The pre-check refusal. Its words are `RiderOutcomes`
            `refusal_text/1`, the same text a refused save explains itself with, and
            the link opens the day type that blocks the pair so the editor can fix
            the blocks there. --%>
            <div
              :if={@refusal}
              id="connection-blocked-reason"
              data-role="connection-blocked"
              class="mt-2 flex gap-2 rounded-control bg-canvas px-3.5 py-2.5 text-[13px] text-default"
            >
              <.icon name="hero-information-circle" class="mt-0.5 size-4 shrink-0" />
              <p class="min-w-0">
                <strong class="text-strong">Only Not stated is available.</strong>
                {@refusal.text}
                <.link
                  :if={@refusal.day}
                  id="connection-blocked-day-link"
                  patch={connection_day_path(@version_id, @refusal.day.key, @from, @to)}
                  class="font-semibold text-action underline underline-offset-4 hover:text-action-hover"
                >
                  Open {@refusal.day.label}
                </.link>
              </p>
            </div>
          </fieldset>
        </.form>

        <p :if={rider_note?(@gap)} id="gap-rider-note" class="text-sm">
          Trip planners such as Google Maps may tell riders they can stay on board.
        </p>

        <div class="flex flex-wrap items-center gap-x-4">
          <button
            :if={@pair}
            id="gap-open-driving-times"
            type="button"
            phx-click="open_drawer"
            phx-value-key="driving_times"
            phx-value-pair={@pair}
            class={link_class()}
          >
            {if @movement.source == :entered,
              do: "Change the driving time",
              else: "Enter a known driving time"}
          </button>
          <button
            id="gap-open-operator-changes"
            type="button"
            phx-click="open_drawer"
            phx-value-key="operator_changes"
            class={link_class()}
          >
            Review operator changes
          </button>
        </div>

        <p :if={length(@places) == 2 and @movement} id="gap-change-note" class="text-sm">
          Both stops are marked, but the {drive_minutes(@movement)} drive between them is
          never a change: one operator drives it.
        </p>

        <.drawer_section id="gap-riders" title="What trip planners show riders">
          <div class="max-w-full overflow-x-auto">
            <table class="w-full border-collapse text-left text-[13px]">
              <tbody>
                <tr
                  :for={row <- @choice_rows}
                  data-role="gap-rider-row"
                  data-app={row.app}
                  data-changes={to_string(row.changes?)}
                  class="border-t border-subtle align-top"
                >
                  <th
                    scope="row"
                    class="w-[8.5rem] py-2 pr-3 font-semibold text-default"
                  >
                    {row.app}
                  </th>
                  <td class="py-2">
                    <span class="font-semibold text-strong">{row.title}</span>
                    <span
                      :if={row.changes?}
                      data-role="gap-rider-changes"
                      class="ml-1.5 rounded-badge bg-selection px-1.5 text-[12px] font-semibold text-action"
                    >
                      Changes
                    </span>
                    <br />
                    <span class="text-muted">{row.detail}</span>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
          <p id="gap-rider-footnote" class="mt-2 text-[13px] text-muted">
            {@rider_footnote}
          </p>
        </.drawer_section>

        <%!-- The handoff mini-map (AC-18). It is a picture of the two stops the
        drawer already names above, so it is `phx-update="ignore"` and read-only:
        the hook owns the canvas and never sends an event, and the stops stay
        legible in the drawer's own text with the map gone. The distance rides
        the connector rather than the body, so the picture and the sentence cannot
        drift apart. A pair whose stops this version cannot place renders the
        sentence instead — a half-drawn handoff would be a wrong one. --%>
        <.drawer_section id="gap-where" title="Where the vehicle waits">
          <div :if={@pair_map} id="connection-pair-map-region" class="max-w-full">
            <div
              id="connection-pair-map"
              phx-hook="ConnectionMap"
              phx-update="ignore"
              data-mode="pair"
              data-pair={Jason.encode!(@pair_map)}
              aria-label="Map of the arrival and departure stops"
              class="h-44 w-full overflow-hidden rounded-card border border-subtle"
            >
            </div>
            <p
              id="connection-pair-map-unavailable"
              data-role="connection-map-unavailable"
              class="hidden h-44 w-full content-center bg-canvas px-6 text-center text-[13px] text-muted"
            >
              Map unavailable. The two stops are named above.
            </p>
            <%!-- Leaflet draws its own attribution control inside the canvas, so
            there is no caption here: a second copy of the same credit beside it
            would read as a mistake. --%>
          </div>
          <p
            :if={is_nil(@pair_map)}
            id="connection-pair-map-unknown"
            data-role="connection-map-unknown"
            class="text-[13px] text-muted"
          >
            Location unknown — this version places {connection_pair_unknown(assigns.from, assigns.to)} nowhere.
          </p>
        </.drawer_section>
      </.drawer_scroll>

      <.drawer_footer>
        <%!-- The save's own outcomes, above the footer's actions (AC-15). The
        pending sentence is the same live region the message replaces, so a reader
        hears "Saving…" and then either the reason nothing was written or nothing
        at all, because a success closes the drawer and leaves its result on the
        page instead. --%>
        <p
          id="connection-save-status"
          class="basis-full text-[13px] text-muted"
          aria-live="polite"
          data-pending={to_string(@connection_pending)}
        >
          {connection_save_status(@connection_pending, @connection_draft, @connection_saved, @records)}
        </p>

        <.message
          :if={@connection_error}
          id="connection-save-message"
          kind="error"
          title={@connection_error.title}
          tabindex="-1"
          phx-hook="FormErrorFocus"
          data-focus-on-mount="connection-save-message"
          data-role="connection-save-error"
        >
          {@connection_error.message}
        </.message>

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

        <button
          type="button"
          id="connection-cancel"
          class="btn btn-ghost min-h-11"
          phx-click="close_drawer"
        >
          Cancel
        </button>
        <.button
          id="connection-save"
          type="button"
          class="min-h-11"
          data-role="connection-save"
          phx-click="save_connection"
          phx-disable-with="Saving…"
          disabled={
            not connection_save_enabled?(
              @connection_draft,
              @connection_saved,
              @records,
              @connection_check
            ) or @connection_pending
          }
        >
          {connection_save_label(
            @connection_pending,
            @connection_draft,
            @connection_saved,
            @records,
            @connection_error
          )}
        </.button>
      </.drawer_footer>
    </.drawer>

    <%!-- The discard guard. It is the shared `confirm_dialog` rather than a drawer
    of its own, because a draft the editor may still want is a question, not a
    page: "Keep editing" is the cancel action and therefore the focused one, which
    is the safe default for a dialog that can lose work. The shared dialog owns
    the `-body` id, so the sentence inside it carries no id of its own and
    `aria-describedby` points at that shared region. --%>
    <.confirm_dialog
      id="connection-discard"
      chrome="planner"
      open={not is_nil(@discard)}
      title="Discard this change?"
      confirm_label="Discard change"
      pending_label="Discarding…"
      on_confirm="discard_connection"
      on_cancel="keep_connection_editing"
      cancel_label="Keep editing"
      described_by="connection-discard-body"
      return_focus_id="gap-drawer-title"
    >
      <p>
        Your choice for this connection hasn't been saved. Keep editing to go back to it.
      </p>
    </.confirm_dialog>
    """
  end

  # --- the connection save ----------------------------------------------------

  # Whether the footer offers Save at all: there is a choice, it differs from the
  # saved one (or rewrites a drifted record's stops), and the pre-check has not
  # refused it. "Not stated" is never disabled, because removing a record writes
  # nothing and the write rule cannot refuse it.
  defp connection_save_enabled?(draft, saved, records, check) do
    not is_nil(draft) and connection_unsaved?(draft, saved, records) and
      not connection_choice_blocked?(check, draft)
  end

  # A draft is unsaved when it differs from the saved setting, and also when it
  # matches but the pair's single record's stops drifted: re-choosing the saved
  # type is how those stops are rewritten (R2, AC-6), so the drawer offers
  # "Update record" rather than hiding a write the editor still needs.
  defp connection_unsaved?(draft, saved, [entry]),
    do: draft != saved or stops_drifted?(draft, saved, entry)

  defp connection_unsaved?(draft, saved, _records), do: draft != saved

  defp stops_drifted?(saved, saved, %{state: {:stale, :stops_changed}}), do: true
  defp stops_drifted?(_draft, _saved, _entry), do: false

  defp connection_choice_blocked?({:refused, _state}, :not_stated), do: false
  defp connection_choice_blocked?({:refused, _state}, _choice), do: true
  defp connection_choice_blocked?(_check, _choice), do: false

  # The footer's button label. A pending save says so, a drifted record whose saved
  # type is re-chosen offers the narrower "Update record", a failed save offers
  # "Try again", and everything else is an ordinary "Save setting".
  defp connection_save_label(true, _draft, _saved, _records, _error), do: "Saving…"

  defp connection_save_label(false, draft, saved, records, error) do
    cond do
      is_nil(draft) -> "Save setting"
      is_map(error) -> "Try again"
      stops_drifted?(draft, saved, single_record(records)) -> "Update record"
      true -> "Save setting"
    end
  end

  defp single_record([entry]), do: entry
  defp single_record(_records), do: nil

  # The footer's status line: what Save is about to do, in the page's own words.
  # It is a polite live region rather than an alert, because it reports an action
  # the reader chose rather than a failure.
  defp connection_save_status(true, _draft, _saved, _records), do: "Saving…"

  defp connection_save_status(false, nil, _saved, _records),
    do: "Choose a setting."

  defp connection_save_status(false, draft, saved, records) do
    cond do
      not connection_unsaved?(draft, saved, records) -> "Choose a different setting to save."
      draft == :not_stated and length(records) > 1 -> "Saving removes both records."
      draft == :not_stated and records != [] -> "Saving removes the record."
      length(records) > 1 -> "Saving replaces both records."
      true -> ""
    end
  end

  @doc """
  Renders the result of one connection save or undo, above the workspace.

  The callout is the page's answer to a write that closed the drawer, so it
  persists until it is dismissed or replaced (R10, AC-15). It is a polite status
  rather than an alert: nothing failed unless the sentence says so. Undo is
  offered only when R9's condition held at the save, and a refused Undo keeps the
  reviewable pair's own link so the editor can see what changed instead.
  """
  attr :result, :map, required: true
  attr :version_id, :string, required: true
  attr :day, :string, default: nil

  def connection_result(assigns) do
    ~H"""
    <div class="rounded-card border border-subtle bg-selection px-4 py-3">
      <div class="flex flex-wrap items-center justify-between gap-3">
        <p
          id="connection-result"
          class="min-w-0 text-sm text-strong"
          role="status"
          aria-live="polite"
          data-role="connection-result"
        >
          {@result.text}
          <.link
            :if={@result.open?}
            id="connection-result-open"
            patch={connection_result_path(@version_id, @day, @result.gap)}
            class="ml-2 font-semibold text-action underline underline-offset-4 hover:text-action-hover"
          >
            Open connection
          </.link>
        </p>
        <div class="flex items-center gap-2">
          <button
            :if={@result.undo?}
            id="connection-undo"
            type="button"
            phx-click="undo_connection"
            class="inline-flex min-h-11 items-center rounded-control px-3 text-sm font-semibold text-action underline underline-offset-4 hover:bg-canvas"
          >
            Undo
          </button>
          <button
            id="connection-dismiss"
            type="button"
            aria-label="Dismiss save result"
            phx-click="dismiss_connection_result"
            class="inline-flex size-11 items-center justify-center rounded-control text-default hover:bg-canvas"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>
      </div>
    </div>
    """
  end

  # The deep link a refused Undo offers: the same `gap=` parameter the drawer
  # itself opens from, so the review lands on the pair that changed.
  defp connection_result_path(version_id, day, gap) do
    params =
      [{"gap", gap}] ++ if(is_binary(day), do: [{"day", day}], else: [])

    "/gtfs/#{version_id}/blocks?" <> URI.encode_query(params)
  end

  @doc """
  Renders the block drawer as the vehicle's day: the day's summary line, the
  block's problems, the garage and type form, a Time · Activity · Details table of
  the vehicle's whole day, then the block's three actions.

  The summary line is the day's own figures — the trip count, the *platform* span
  from `Movements.build/3` (so a pull-out before midnight and a pull-back after it
  are inside the range), the hours out of the garage and the day's two kilometre
  totals. The `(est.)` mark follows the block's own legs rather than the day's: an
  entered driving time is a human's real route, so a block whose every leg is
  entered carries no mark.

  The table's rows come from the block's `Movements.build/3` result in the order
  the vehicle does them: the pull-out from the resolved garage, each trip of the
  `Checks.sequence/1` order, the drive and the wait between two trips, and the
  pull-back. A block with no resolvable garage has no pull rows at all, and a
  deadhead, a drive the vehicle cannot make in time and an overlap each say so
  rather than rounding away.

  “Inspect” opens the trip drawer with the block kept, which is what gives that
  drawer its back link, and every drive, wait and overlap opens the gap drawer with
  the block kept, so that drawer offers “Back to block <id>”. The overlap row is
  the only way to open that drawer for an overlapping pair, whose timeline bar is
  deliberately suppressed.

  The problems come worst first, and a problem about one connection carries “Open
  this connection” for the same gap drawer the row opens. Stay-on-board records
  stay read-only: the drawer adds no editing control and no command for them.

  The Garage and type form saves through `Gtfs.set_block_attributes/5`. A block's
  settings belong to its calendar and block number, so a save reaches every
  service day that runs those trips: the form lists those service days under “Also
  changes” before saving, and asks for one garage when the block's calendars
  disagree.

  The actions are “Rename block”, “Merge into another block” and “Remove all
  trips”. A rename renames this block's trips on the selected service day, a merge
  joins them to another block of the day (the picker offers no “New block” and no
  “No block”, because a merge always lands on an existing ID), and remove-all takes
  this block's trips on the selected service day back to the pool. Each one
  submits the same `submit_block_action` event, so all three run through the
  reviewed command and show the same review dialog with its split, its affected
  service days and its added problems.

  A refusal prints under the control that caused it — the rename field's own
  error sits inside the form, so the input keeps what the reader typed — and the
  rename field starts on the block's own ID, so resubmitting it unchanged is the
  “Enter a different block ID.” case rather than a silent no-op.
  """
  attr :open, :boolean, required: true
  attr :block, :map, required: true
  attr :routes, :map, required: true

  attr :movements, :map,
    required: true,
    doc: "the block's `Movements.build/3` result, which the day load already derived"

  attr :max_piece_minutes, :integer,
    default: nil,
    doc: "the operator-change limit; with none set no wait can carry the change mark"

  attr :action, :map,
    default: nil,
    doc: "the drawer's action state, nil while the drawer is closed"

  attr :form, :any, default: nil, doc: "the rename field's and merge search's form"

  attr :merge_options, :list,
    default: [],
    doc: "the other blocks of the service day the picker offers"

  attr :merge_total, :integer, default: 0, doc: "the merge search's match count before the cap"

  attr :attributes, :map,
    default: nil,
    doc: "the garage and type form's state, nil while the drawer is closed"

  attr :attributes_form, :any, default: nil, doc: "the two pickers' form"

  attr :garages, :list, default: [], doc: "the organization's garages, by name"

  attr :vehicle_types, :list, default: [], doc: "the organization's vehicle types, by name"

  attr :route_settings, :map,
    default: %{},
    doc: "per-route home garage and required type, read only to explain a value"

  attr :day_types, :list,
    default: [],
    doc:
      "every service day the version derives, so the preview can name the other ones the save reaches"

  attr :selected_day_type, :map,
    default: nil,
    doc: "the service day the page is showing; the preview never names it as “also”"

  attr :connection_settings, :map,
    default: %{},
    doc:
      "the per-connection setting entries keyed by the two trip ids joined by a bar, the same map the timeline gaps read"

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
        |> Enum.map(&block_day_row(&1, assigns.connection_settings))
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
    <.drawer
      id="block-drawer"
      chrome="planner"
      open={@open}
      title={"Block " <> @summary.block_id}
      class="max-w-[520px]"
    >
      <:lede :if={@selected_day_type}>
        {@selected_day_type.label} · {day_count_label(@selected_day_type.date_count)}
      </:lede>

      <.drawer_scroll>
        <p id="block-day-summary" class="text-sm text-muted">
          {count_label(@summary.trip_count, "trip", "trips")} · {time_out(
            @summary.start_secs,
            @summary.end_secs
          )} · {hours(@summary.hours)} h out of the garage · {km(@movements.service_km)} km with
          riders, {km(@movements.deadhead_km)} km without{if @estimated?, do: " (est.)", else: ""}
        </p>

        <div :if={@problems != []} id="block-problems" class="grid gap-3">
          <.message
            :for={{problem, index} <- Enum.with_index(@problems)}
            kind={severity_status(problem.severity)}
            title={code_label(problem.code)}
            data-role="block-problem"
            data-code={problem.code}
          >
            {finding_detail(problem)}
            <div class="mt-0.5 flex flex-wrap gap-x-4">
              <button
                :if={connection = connection_gap(problem, @block)}
                type="button"
                data-role="block-open-connection"
                phx-click="open_gap"
                phx-value-from={connection.from_id}
                phx-value-to={connection.to_id}
                phx-value-block={@summary.block_id}
                class={link_class()}
              >
                Open this connection
              </button>
              <%!-- A stretch with no place to change operators is a limit or a mark
            the reader can fix in the Operator changes drawer, so the callout offers
            that link rather than only naming the stretch. One block can carry
            several unrelieved stretches and they all open the same drawer, so the
            link appears on the first of them rather than repeating it once per
            stretch. --%>
              <button
                :if={
                  problem.code == :no_relief_opportunity and first_relief_problem?(@problems, index)
                }
                type="button"
                id={"block-open-operator-changes-#{@summary.block_id}"}
                data-role="block-open-operator-changes"
                phx-click="open_drawer"
                phx-value-key="operator_changes"
                class={link_class()}
              >
                Review operator changes
              </button>
            </div>
          </.message>
        </div>

        <%!-- The hook is the page's existing scoped `FormErrorFocus` hook, and it
        is scoped to this form on purpose: a refusal here pushes a focus target
        that only the form's own hook can reach, so the reader's focus never
        crosses into the timeline behind the drawer. --%>
        <section
          :if={@attributes}
          id="block-attributes"
          phx-hook="FormErrorFocus"
          class="border-t border-subtle pt-5"
        >
          <h3 class="text-[15px] font-bold text-strong">Garage and type</h3>
          <.form
            for={@attributes_form}
            id="block-attributes-form"
            phx-change="block_attributes_change"
            phx-submit="save_block_attributes"
            class="mt-3 grid gap-2"
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

            <div :if={@also_changes != []} id="block-also-changes" class="grid gap-2 pt-2">
              <p class="text-[13px] font-[650] text-strong">Also changes</p>
              <div
                :for={change <- @also_changes}
                data-role="block-also-changes"
                data-day-type={change.key}
                class="rounded-card border border-subtle px-3.5 py-3 text-sm"
              >
                <p class="font-bold text-strong">
                  {change.label} · {day_count_label(change.date_count)}
                </p>
                <p class="mt-1">{change.sentence}</p>
              </div>
            </div>

            <p
              :if={@also_changes != []}
              id="block-attributes-note"
              role="status"
              class="text-[13px] text-muted"
            >
              Also changes {Enum.map_join(@also_changes, ", ", & &1.label)}
            </p>

            <div>
              <.button
                type="submit"
                id="block-attributes-submit"
                class="min-h-11"
                phx-disable-with="Saving…"
              >
                Save block settings
              </.button>
            </div>
          </.form>
        </section>

        <section class="border-t border-subtle pt-5">
          <h3 class="text-[15px] font-bold text-strong">Vehicle’s day</h3>

          <div class="mt-2 overflow-x-auto">
            <table id="block-day" class="w-full text-sm">
              <thead>
                <tr class="bg-canvas text-left text-[13px] text-muted">
                  <th scope="col" class="px-3 py-2 font-semibold">Time</th>
                  <th scope="col" class="px-3 py-2 font-semibold">Activity</th>
                  <th scope="col" class="px-3 py-2 font-semibold">Details</th>
                </tr>
              </thead>
              <tbody class="divide-y divide-subtle/60">
                <tr :for={row <- @rows} data-role="block-day-row" data-kind={row.kind}>
                  <td class="whitespace-nowrap px-3 py-2 align-top tabular-nums">{row.time}</td>
                  <td class="px-3 py-2 align-top font-[650] text-strong">{row.activity}</td>
                  <td class={["px-3 py-2 align-top", row.error? && "font-semibold text-error-fg"]}>
                    <%= if gap = row.gap do %>
                      <%!-- The gap's own text and the connection's setting sit in one
                    wrapping row, so a long label drops to its own line under the
                    link rather than beside it, and the two keep a readable gap
                    whichever way the drawer's column falls. --%>
                      <div class="flex flex-wrap items-center gap-x-2 gap-y-1">
                        <button
                          type="button"
                          data-role="block-gap"
                          data-kind={row.kind}
                          data-minutes={gap_minutes(gap)}
                          phx-click="open_gap"
                          phx-value-from={gap.from_id}
                          phx-value-to={gap.to_id}
                          phx-value-block={@summary.block_id}
                          class={[link_class(), "text-left", row.error? && "text-error-fg"]}
                        >
                          {row.detail}
                        </button>
                        <.block_gap_note
                          :if={connection = Map.get(row, :connection)}
                          connection={connection}
                        />
                      </div>
                    <% else %>
                      <span>{row.detail}</span>
                      <button
                        :if={row.trip}
                        type="button"
                        data-role="block-inspect"
                        phx-click="open_trip"
                        phx-value-trip={row.trip.trip_id}
                        phx-value-block={@summary.block_id}
                        aria-label={"Inspect " <> row.trip.trip_id}
                        class={[link_class(), "ml-1"]}
                      >
                        Inspect
                      </button>
                    <% end %>
                  </td>
                </tr>
              </tbody>
            </table>
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
  # it sits under the input it belongs to. The merge's own error has no
  # field of its own and prints under the picker instead.
  defp rename_errors(%{kind: :rename, error: error}) when is_binary(error), do: [error]
  defp rename_errors(_action), do: []

  # --- the block's garage and vehicle type ---------------------------

  # A block whose calendars disagree has no garage to show, so the picker opens
  # on the prompt rather than on one of the two answers. Every other
  # block opens on the resolution the day load already made.
  defp garage_prompt(%{resolution: %{conflict: conflict}}) when conflict in [nil, []],
    do: nil

  defp garage_prompt(_block), do: "Choose one garage"

  # The refusal under the garage picker. It is the field's own error, so the
  # select is marked invalid and the form's focus hook lands on it.
  defp attribute_errors(%{error: error}) when is_binary(error), do: [error]
  defp attribute_errors(_attributes), do: []

  # The garage's help names where the value comes from, in three cases: the
  # calendars disagree and the picker has to settle it; the block
  # takes its first trip's route's home garage; or the route's home garage is
  # named as the answer the block currently resolves to. The route and its
  # setting are read off the loaded day, never re-resolved here.
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

  # The first trip's route is the route the garage resolution reads, so the help
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

  # The type's help names the requirement and the limits: a route that requires
  # a type says so and then lists what every type allows,
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

  # The route is named by its short name, then its ID, so the help reads “Route 12”
  # and not the route's long name.
  defp route_label(routes, route_id), do: route_badge_name(routes, route_id)

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
  # them *and* holds a trip of this block — the same two conditions
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
    # out of the way until the picker holds a garage.
    if change == [] or (undecided?(resolution) and Values.presence(garage) == nil) do
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

  defp undecided?(%{conflict: conflict}), do: conflict not in [nil, []]
  defp undecided?(_resolution), do: false

  defp selected_day_type_key(nil), do: nil
  defp selected_day_type_key(day_type), do: day_type.key

  # Another day type is reached when it holds a trip of this block, which is a
  # day type whose services include one of the block's own services: the block
  # runs on those services, so it runs there too.
  defp holds_block?(day_type, services) do
    Enum.any?(day_type.service_ids, &MapSet.member?(services, &1))
  end

  defp shared_service_names(day_type, services, day_types) do
    day_type.service_ids
    |> Enum.filter(&MapSet.member?(services, &1))
    |> Enum.map(&service_label(&1, day_types))
  end

  # The value this save gives the other day type, in plain words: a
  # garage that becomes the chosen one, a type that becomes the chosen one (or
  # “any type” when the reader cleared it), and both joined when both changed.
  defp change_sentence([]), do: "Its garage and type stay the same."
  defp change_sentence([one]), do: "Its #{one} too."
  defp change_sentence([first, second]), do: "Its #{first} and its #{second} too."

  defp change_parts(garage, type, resolution, garages, types) do
    []
    |> then(
      &if Values.presence(garage) != resolution.garage_id,
        do: ["garage becomes #{garage_name(garages, Values.presence(garage))}" | &1],
        else: &1
    )
    |> then(
      &if Values.presence(type) != resolution.vehicle_type_id,
        do: ["type becomes #{type_name(types, Values.presence(type))}" | &1],
        else: &1
    )
    |> Enum.reverse()
  end

  # The vehicle's day, as the “Vehicle's day” table reads it: the
  # pull-out from the resolved garage, the block's `Checks.sequence/1` trips each
  # preceded by the drive and the wait its gap holds, the pull-back, and then the
  # trips the sequence left out (a repeating or an untimed one) so a trip the
  # block owns is never hidden from a drawer that names its count.
  #
  # The gaps, the drives and the waits are the block's own `Movements.build/3`
  # result and `Checks.gaps/1` pairs, both built over the same
  # sequence and therefore aligned by index, and the operator-change mark comes
  # from the same `Relief.window`s the timeline reads — the later trip's sequence
  # index is the window's own `gap_index`, as `plotted/1` uses it. Nothing here
  # re-derives a movement or a window.
  # The connection a gap note names in words. A gap is one connection, and a
  # connection whose movement the day load split into a drive and a wait is two
  # rows of the vehicle's day, so the note rides the row that is about the
  # connection — the wait between the two trips, or the overlap that leaves no
  # wait at all — and not the drive, which is about moving the vehicle. A row
  # with no gap, and a connection the day's derivation holds nothing for, name
  # no setting: undecided rather than an error.
  defp block_day_row(row, settings) do
    case {row.kind, row.gap} do
      {kind, gap} when kind in [:wait, :overlap] and not is_nil(gap) ->
        Map.put(row, :connection, block_gap_connection(settings, gap))

      _other ->
        row
    end
  end

  defp block_gap_connection(settings, gap) do
    case Map.get(settings, "#{gap.from_id}|#{gap.to_id}") do
      %{setting: setting, review?: review?} -> block_gap_note(setting, review?)
      _undecided -> block_gap_note(:none, false)
    end
  end

  @doc """
  The connection's setting in words, beside a block drawer's gap note.

  The timeline's `gap_marker/2` decides the setting, the icon and the words, so
  one derivation names a connection in both places. A decided connection is a
  badge in the same ground the timeline's chips and the key carry; a pair nobody
  has decided says so in muted words rather than showing an empty badge, because
  the text is what the reader is here for.
  """
  attr :connection, :map, required: true, doc: "a `block_gap_note/2` result"

  def block_gap_note(assigns) do
    ~H"""
    <span
      data-role="block-gap-setting"
      data-setting={@connection.setting}
      class={[
        "inline-flex items-center gap-1 rounded-badge border px-1.5 py-0.5 align-middle text-[13px] font-semibold",
        @connection.class
      ]}
    >
      <.icon :if={@connection.icon} name={@connection.icon} class="size-3.5" />
      {@connection.label}
    </span>
    """
  end

  # The same words and grounds the timeline's gap chips carry, so a connection
  # reads the same in the chart, in the key and in the drawer's list. An undecided
  # pair is muted words with no ground, so the drawer's list is not striped with
  # badges nobody decided.
  defp block_gap_note(:none, _review?) do
    %{setting: "none", class: "border-transparent text-muted", icon: nil, label: "Not stated"}
  end

  defp block_gap_note(_setting, true) do
    %{
      setting: "review",
      class: "border-warning-line bg-warning-bg text-warning-fg",
      icon: "hero-exclamation-triangle-mini",
      label: "Needs review"
    }
  end

  defp block_gap_note(:stay, false) do
    %{
      setting: "stay",
      class: "border-subtle bg-soft text-cyan-800",
      icon: "hero-link-mini",
      label: "Riders stay on board"
    }
  end

  defp block_gap_note(:reboard, false) do
    %{
      setting: "reboard",
      class: "border-navy-700 bg-navy-700 text-white",
      icon: "hero-arrow-right-start-on-rectangle-mini",
      label: "Riders must re-board"
    }
  end

  defp block_gap_note(:conflict, false) do
    %{
      setting: "review",
      class: "border-warning-line bg-warning-bg text-warning-fg",
      icon: "hero-exclamation-triangle-mini",
      label: "Needs review"
    }
  end

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
  # carries no `est.` mark, because a person gave it. The pull-out names
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
  # nothing at all. `index` is the later trip's own position in the
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
  # in the error colour.
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
  # operator change is possible at that stop, so it follows the block's own
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

  # Whether the callout at this index is the first of the block's unrelieved
  # stretches, which is the one that carries the Operator changes link: the
  # drawer is the same for all of them, so one link answers them all.
  defp first_relief_problem?(problems, index) do
    problems
    |> Enum.take(index + 1)
    |> Enum.find_index(&(is_map(&1) and &1.code == :no_relief_opportunity))
    |> Kernel.==(index)
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
  # is what the summary line's `est.` mark and the drive rows follow.
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
  # distance and the time available, the deadhead with the drive it needs, or a
  # drive the vehicle cannot make in time.
  defp gap_text(%{gap_secs: secs}, _from, _to, _movement) when secs < 0,
    do: "#{minutes(-secs)} overlap"

  # The gap the vehicle cannot cover: the drive it needs against the time there is,
  # which is the sentence the drawer leads with. The minutes are the movement's own
  # drive and the block's own gap, not a subtraction here.
  defp gap_text(%{gap_secs: secs}, _from, to, %{feasible?: false, drive_secs: drive})
       when is_integer(drive),
       do: "Needs #{minutes(drive)} to reach #{stop_name(to.first_stop)}; has #{minutes(secs)}."

  defp gap_text(%{handoff: :same_stop, gap_secs: secs}, _from, to, _movement),
    do: "#{minutes(secs)} layover at #{stop_name(to.first_stop)}"

  defp gap_text(%{handoff: :same_station, gap_secs: secs}, from, _to, _movement),
    do: "Same station · #{minutes(secs)} at #{station_name(from.last_stop)}"

  defp gap_text(%{handoff: {:nearby, meters}, gap_secs: secs}, _from, _to, _movement),
    do: "Nearby stop · #{meters} m · #{minutes(secs)} available"

  defp gap_text(%{handoff: {:moves, nil}}, from, to, _movement),
    do: move_text(from, to, " (no coordinates)")

  defp gap_text(%{handoff: {:moves, _meters}}, from, to, movement),
    do: move_text(from, to, movement)

  defp move_text(from, to, %{} = movement) do
    "Deadhead from #{stop_name(from.last_stop)} to #{stop_name(to.first_stop)}. " <>
      "#{drive_minutes(movement)}#{est_mark(movement.source)} to drive."
  end

  defp move_text(from, to, qualifier) do
    "Deadhead from #{stop_name(from.last_stop)} to #{stop_name(to.first_stop)}. " <>
      "Driving time is unknown#{qualifier}."
  end

  # The connection's own name, in the two forms a reader can act on: which route
  # continues as which, or that one route's two directions meet here. A pair of
  # the same route in the same direction simply continues.
  defp connection_title(routes, from, to, turnback?) do
    from_route = route_badge_name(routes, from.route_id)
    to_route = route_badge_name(routes, to.route_id)

    cond do
      turnback? -> "Route #{from_route} turns back"
      from.route_id == to.route_id -> "Route #{from_route} continues"
      true -> "Route #{from_route} continues as Route #{to_route}"
    end
  end

  # Each hint's mark, from the same vocabulary the rest of the page uses: a route
  # change is an arrow, a turnback a U-turn, a wait a clock and a distance a bus.
  defp hint_icon(:route_change), do: "hero-arrow-right"
  defp hint_icon(:turnback), do: "hero-arrow-uturn-left"
  defp hint_icon(:wait), do: "hero-clock"
  defp hint_icon(:distance), do: "hero-truck"

  # The time between the trips and the handoff it happens over, which is the one
  # fact a rider feels. An empty move adds that the driving time is unknown,
  # because that is what the version cannot say — a move whose drive time the day
  # load derived keeps its own number in the row below.
  defp on_board_text(%{handoff: handoff} = gap, movement) do
    text = "#{available_text(gap)} · #{handoff_text(handoff)}"

    # The prototype appends the unknown only to a gap whose vehicle drives empty:
    # a handoff at one stop has no drive to be unsure about, and calling it
    # unknown there reads as a missing fact rather than as "none needed".
    if moves_empty?(handoff) and unknown_drive?(movement) do
      text <> " · Driving time is unknown."
    else
      text
    end
  end

  defp moves_empty?({:moves, _meters}), do: true
  defp moves_empty?(_handoff), do: false

  defp unknown_drive?(nil), do: true
  defp unknown_drive?(%{drive_secs: secs}), do: not is_integer(secs)
  defp unknown_drive?(_movement), do: false

  defp handoff_text(:same_stop), do: "Same stop"
  defp handoff_text(:same_station), do: "Another stop in the same station"

  defp handoff_text({:nearby, meters}) when is_integer(meters),
    do: "#{meters} m walk between stops"

  defp handoff_text({:moves, meters}) when is_integer(meters),
    do: "Vehicle moves empty #{meters} m"

  defp handoff_text({:moves, _meters}), do: "Vehicle moves empty, distance unknown"

  # The note a pair's saved record earns. Two records are one conflict to
  # resolve, a stale or unconfirmed one explains itself in `RiderOutcomes`'
  # words, and a record that matches the block earns only a quiet line naming it,
  # because the rider table below already says what each app will do.
  # --- the connection choice ------------------------------------------------

  # The three options, in the order the reference lists them, each with what it
  # writes. `dom` names the radio's DOM id, `value` is the `InSeatTransfers`
  # choice atom the form and the save share, and `setting` is the
  # `RiderOutcomes` setting the option's rows are derived for. All three always
  # render: a refused pair shows the two explicit options greyed out rather than
  # removing them, so the editor can read what the pre-check took away. "Not
  # stated" is the one option that is never disabled, because removing a record
  # writes nothing and the write rule can therefore not refuse it.
  defp connection_choices(saved, check) do
    refused? = match?({:refused, _}, check)

    for {dom, value, title, description, setting} <- [
          {"not-stated", "not_stated", "Not stated",
           "Apps decide from the block. Writes no transfer record.", :none},
          {"stay", "stay_on_board", "Riders stay on board",
           "Writes an in-seat transfer record (type 4).", :stay},
          {"reboard", "must_reboard", "Riders must re-board",
           "Writes a no-seat transfer record (type 5).", :reboard}
        ],
        into: [] do
      %{
        value: value,
        dom: dom,
        choice: choice_for(value),
        title: title,
        description: description,
        saved?: not is_nil(saved) and saved == choice_for(value),
        disabled?: refused? and setting != :none
      }
    end
  end

  # The choice atom one of the three radio values stands for. The *Saved* tag
  # follows the pair's saved record rather than the current draft, so it moves
  # only when the pair is saved and stays put while the editor is choosing.
  defp choice_for("not_stated"), do: :not_stated
  defp choice_for("stay_on_board"), do: :stay_on_board
  defp choice_for("must_reboard"), do: :must_reboard

  # The pre-check's own answer, as the drawer's refusal text plus the day type
  # that blocks the pair when the refusal names one. Only a not-next failure
  # names a day type, so only that state offers the link; the other refusals are
  # facts about the pair rather than about a date.
  defp connection_refusal(:ok), do: nil
  defp connection_refusal(nil), do: nil

  defp connection_refusal({:refused, {:stale, {:not_next, [failure | _rest]}} = state}) do
    %{
      text: "#{RiderOutcomes.refusal_text(state)} ",
      day: %{key: failure.key, label: failure.label}
    }
  end

  defp connection_refusal({:refused, state}) do
    case RiderOutcomes.refusal_text(state) do
      nil -> nil
      text -> %{text: "#{text} ", day: nil}
    end
  end

  defp connection_refusal(_other), do: nil

  # The scope line: the dates both trips run on, and the day types that make
  # them up. The day types are the drawer's own `day_types` list filtered to the
  # two services, so the count and the names can never disagree.
  defp connection_scope_sentence(nil), do: nil

  defp connection_scope_sentence(%{day_types: []}), do: "These trips share no service day."

  defp connection_scope_sentence(%{day_types: day_types, date_count: date_count}) do
    names = Enum.map_join(day_types, " · ", &"#{&1.label} (#{&1.date_count})")

    "Applies on all #{date_count} #{if date_count == 1, do: "date", else: "dates"} both trips run: #{names}."
  end

  # The warnings the stay option carries, and only while stay is the draft: the
  # empty move the vehicle makes between two stops, and the pickup or drop-off
  # that makes OpenTripPlanner drop the record. Both are the pair's own facts,
  # read from the block's handoff and from `RiderOutcomes`, and neither refuses
  # the choice — they are what choosing stay would cost.
  defp connection_stay_warnings(_connection, _gap, draft) when draft != :stay_on_board, do: []

  defp connection_stay_warnings(connection, %{handoff: {:moves, meters}}, :stay_on_board)
       when is_integer(meters) do
    [
      %{
        kind: :distance,
        text:
          "Stops are #{meters} m apart; riders would stay on board while the vehicle moves empty."
      }
    ] ++ pickup_warning(connection)
  end

  defp connection_stay_warnings(connection, _gap, :stay_on_board),
    do: pickup_warning(connection)

  # The warnings ride inside the stay card, so only that card shows them.
  defp stay_warnings_for(:stay_on_board, warnings), do: warnings
  defp stay_warnings_for(_choice, _warnings), do: []

  defp pickup_warning(connection) do
    case RiderOutcomes.pickup_problem(connection) do
      nil ->
        []

      problem ->
        [
          %{
            kind: :pickup,
            text: "#{problem} OpenTripPlanner drops this record there without warning."
          }
        ]
    end
  end

  # The rider table for the draft the editor has chosen, each row tagged when the
  # chosen option's title differs from the title the saved setting produces. The
  # rows and the tag both come from `RiderOutcomes`, so the table never claims a
  # consumer does something the copy module does not say (CR-3).
  defp connection_choice_rows(connection, draft, saved_setting) do
    saved_rows = RiderOutcomes.rows(connection, saved_setting)

    connection
    |> RiderOutcomes.rows(setting_for_draft(draft))
    |> Enum.zip(saved_rows)
    |> Enum.map(fn {row, saved_row} -> Map.put(row, :changes?, row.title != saved_row.title) end)
  end

  # A pair with no saved setting — one with no record, or one whose two records
  # disagree — has no single outcome until the editor picks, so the table shows
  # the block-derived one, which is what `RiderOutcomes` reads a conflict as.
  defp setting_for_draft(nil), do: :none
  defp setting_for_draft(:not_stated), do: :none
  defp setting_for_draft(:stay_on_board), do: :stay
  defp setting_for_draft(:must_reboard), do: :reboard

  # The blocking day type's link: the Blocks page for that day type, with the
  # pair's own `gap=` deep link kept so the drawer the editor came from is still
  # the one they land on.
  defp connection_day_path(version_id, day_key, from, to) do
    "/gtfs/#{version_id}/blocks?" <>
      URI.encode_query([{"day", day_key}, {"gap", "#{from.id}|#{to.id}"}])
  end

  defp record_note([], _to), do: nil

  defp record_note([_one, _two | _rest], _to) do
    %{
      title: "Two imported records disagree",
      body:
        "One says riders stay on board and one says they must re-board, so apps pick one " <>
          "arbitrarily. Choose a setting to replace both with one record.",
      quiet?: false
    }
  end

  defp record_note([entry], to) do
    case entry.state do
      {:stale, {:not_next, _failures}} ->
        %{
          title: "Saved record needs review",
          body:
            RiderOutcomes.refusal_text(entry.state) <>
              " Choose Not stated to remove it, or fix the blocks on the day type named below.",
          quiet?: false
        }

      {:stale, :stops_changed} ->
        %{
          title: "Saved record has old stops",
          body:
            "It names #{stored_stop_name(entry.row, to)}, but trip #{to.trip_id} now starts at " <>
              "#{stop_name(to.first_stop)}. Validators report this as an error and " <>
              "OpenTripPlanner drops the record. Save to update its stops.",
          quiet?: false
        }

      _state ->
        case RiderOutcomes.refusal_text(entry.state) do
          nil ->
            %{
              title: transfer_type_label(entry.row.transfer_type),
              body: in_seat_state_text(:matches),
              quiet?: true
            }

          body ->
            %{
              title: record_note_title(entry.state),
              body: body,
              quiet?: false
            }
        end
    end
  end

  # The record's stored stop, named the way the stored record names it. The
  # version's own stops are not loaded for this drawer, so the stored ID stands
  # for a stop the day load did not describe — the same fallback the rest of
  # this module uses for a stop it cannot name.
  defp stored_stop_name(row, to) do
    cond do
      is_nil(row.to_stop_id) -> row.from_stop_id
      is_nil(to.first_stop) -> row.to_stop_id
      row.to_stop_id == to.first_stop.stop_id -> row.from_stop_id
      true -> row.to_stop_id
    end
  end

  defp record_note_title({_state, :unconfirmed}), do: "Saved record can't be confirmed"
  defp record_note_title(_state), do: "Saved record needs review"

  # The message's tone follows the block's own verdict: an overlap and a drive the
  # vehicle cannot make in time are the errors the reader has to act on, a layover
  # below the minimum is the warning the timeline's gap chip already marks, and
  # everything else is a note.
  defp gap_kind(%{gap_secs: secs}, _movement, _short?) when secs < 0, do: "error"
  defp gap_kind(_gap, %{feasible?: false}, _short?), do: "error"
  defp gap_kind(_gap, _movement, true), do: "warning"
  defp gap_kind(_gap, _movement, false), do: "info"

  # The one line of advice a gap carries: an overlap and an unreachable drive have
  # something to do next. Any other gap has no note, because the drawer is there to
  # report the pair and the block drawer's own problems carry the rest.
  defp gap_note(%{gap_secs: secs}, _movement) when secs < 0 do
    "The vehicle can't be on both trips at once. Move one of them to another block, or change its times in Schedules."
  end

  defp gap_note(_gap, %{feasible?: false}) do
    "Move one of the trips to another block, or enter a known driving time if the " <>
      "estimate is too long."
  end

  defp gap_note(_gap, _movement), do: nil

  # The time the pair has, which is the gap the block derived. An overlap has no
  # time available to speak of — its own callout prints the overlap — so the row
  # says so rather than printing a negative number of minutes.
  defp available_text(%{gap_secs: secs}) when secs < 0, do: "—"
  defp available_text(%{gap_secs: secs}), do: minutes(secs)

  # The drive without riders, with the source the movement carries. A gap that
  # needs no drive names the handoff that made it, and a drive whose time the
  # version cannot compute says so rather than printing a zero, because a zero
  # would read as a drive that costs nothing.
  defp drive_text(%{kind: :layover}, %{handoff: handoff}), do: "None · #{handoff_label(handoff)}"
  defp drive_text(%{drive_secs: secs}, _gap) when is_integer(secs), do: minutes(secs)
  defp drive_text(_movement, _gap), do: "Unknown · no driving time"

  defp handoff_label(:same_stop), do: "same stop"
  defp handoff_label(:same_station), do: "same station"
  defp handoff_label({:nearby, _meters}), do: "nearby stop"
  defp handoff_label({:moves, _meters}), do: "empty move"

  defp drive_source(%{drive_secs: secs, source: source}) when is_integer(secs),
    do: source_text(source)

  defp drive_source(_movement), do: nil

  defp source_text(:entered), do: "Entered"
  defp source_text(:estimated), do: "Estimated"
  defp source_text(_source), do: nil

  # One badge vocabulary for both sources: an estimate is a quiet note, an entered
  # time is a real one.
  defp drive_badge_tone(%{source: :entered}), do: :success
  defp drive_badge_tone(_movement), do: :neutral

  defp drive_minutes(%{drive_secs: secs}) when is_integer(secs), do: minutes(secs)
  defp drive_minutes(_movement), do: "an unknown number of"

  # The wait a reachable gap leaves behind. A drive the vehicle cannot make and a
  # drive whose length is unknown both leave no wait to report, so the row says so
  # rather than printing a number the movements never derived.
  defp wait_text(%{wait_secs: secs}) when is_integer(secs) and secs >= 0, do: minutes(secs)

  defp wait_text(_movement), do: "—"

  # Whether an operator can change over this gap. With no relief limit set
  # there is no piece of work to hand over, so the row says the checks are off
  # rather than claiming a change is impossible. Otherwise the pair's own windows
  # answer it: the places they name, or plainly no.
  defp operator_change_text(false, _places), do: "Not checked"
  defp operator_change_text(true, []), do: "No"
  defp operator_change_text(true, places), do: "Yes, at " <> Enum.join(places, "; ")

  # Where each of the pair's own windows happens, named the way the drawer names
  # every other stop. A window is always one of the pair's two endpoints or their
  # shared station, so the endpoint stops carry the name; anything else falls back
  # to the stored ID rather than to a stop the day load did not describe.
  defp window_places(windows, from, to) do
    windows
    |> Enum.map(&window_place(&1, from, to))
    |> Enum.uniq()
  end

  defp window_place(%{stop_id: stop_id}, %{last_stop: %{stop_id: stop_id} = stop}, _to),
    do: station_name(stop)

  defp window_place(%{stop_id: stop_id}, _from, %{first_stop: %{stop_id: stop_id} = stop}),
    do: station_name(stop)

  defp window_place(%{stop_id: stop_id}, _from, _to), do: stop_id

  # The handoff mini-map's payload: the stop the earlier trip arrives at, the stop
  # the later trip departs from, each in its own route's colour, and the distance
  # the gap's own handoff already measured. `nil` when either stop has no
  # coordinates, because half a handoff is a wrong one — the drawer prints
  # "Location unknown" instead. Nothing here recomputes the distance: R5 already
  # measured it, and a second measurement could only disagree with the drawer's
  # own text about the same handoff.
  defp connection_pair_map(from, to, gap, routes) do
    with {:ok, arrival} <- pair_point(from.last_stop, route_color(routes, from.route_id)),
         {:ok, departure} <- pair_point(to.first_stop, route_color(routes, to.route_id)) do
      %{
        arrival: arrival,
        departure: departure,
        meters: handoff_meters(gap.handoff)
      }
    else
      :error -> nil
    end
  end

  # A stop reference with usable coordinates, or `:error`. A coordinate the
  # version stores as 0 is a real position; one it never stored is `nil`.
  defp pair_point(stop, color) do
    with %{stop_id: stop_id, name: name, lat: lat, lon: lon} <- stop,
         true <- is_number(lat) and is_number(lon) do
      {:ok, %{stop_id: stop_id, name: name, lat: lat, lon: lon, color: color}}
    else
      _other -> :error
    end
  end

  # The route's own colour, normalized so an unvalidated feed value never reaches
  # a canvas. A route with no usable colour draws in the page's primary, which is
  # what an uncoloured feed gets everywhere else too.
  defp route_color(routes, route_id) do
    case Map.get(routes, route_id) do
      %{route_color: value} ->
        case RouteIdentity.normalize_hex(value) do
          {:ok, hex} -> "#" <> hex
          :error -> nil
        end

      _other ->
        nil
    end
  end

  # R5's own distance. A handoff that does not move the vehicle has nothing to
  # measure, and a deadhead whose length the version could not compute is drawn
  # without a number rather than with a zero.
  defp handoff_meters({:nearby, meters}) when is_number(meters), do: meters
  defp handoff_meters({:moves, meters}) when is_number(meters), do: meters
  defp handoff_meters(_handoff), do: nil

  # The stops the map could not place, named for the sentence that says so.
  defp connection_pair_unknown(from, to) do
    case {pair_placeable?(from.last_stop), pair_placeable?(to.first_stop)} do
      {false, _} -> "the arrival stop"
      {_, false} -> "the departure stop"
      {_, _} -> "one of the two stops"
    end
  end

  defp pair_placeable?(%{lat: lat, lon: lon}), do: is_number(lat) and is_number(lon)
  defp pair_placeable?(_stop), do: false

  # The pair a driving-time entry names, in the stored `stop:<id>` form
  # `Gtfs.list_deadhead_pairs/3` hands out, so the drawer the link opens can
  # highlight and focus that row. Only a gap with a drive of its own can have one.
  defp drive_pair(%{kind: :drive, drive_secs: secs}, %{last_stop: %{stop_id: from_id}}, %{
         first_stop: %{stop_id: to_id}
       })
       when is_integer(secs),
       do: "stop:#{from_id}|stop:#{to_id}"

  defp drive_pair(_movement, _from, _to), do: nil

  # The drawer names the day type the gap was read from, so a pair is read in the
  # scope it was derived in. A day type with no label falls back to no suffix
  # rather than to a blank line.
  defp day_label(nil), do: ""
  defp day_label(label), do: " · " <> label

  # The station a same-station handoff shares is the stops' parent station; a stop
  # reference carries the parent's ID rather than its name, so the ID stands for
  # the station here.
  defp station_name(%{parent_station: parent})
       when is_binary(parent) and parent != "",
       do: parent

  defp station_name(stop), do: stop_name(stop)

  # The rider note is for a handoff a rider could make on foot: the same stop, the
  # same station or a nearby one. A deadhead never shows it, however short the
  # gap.
  defp rider_note?(%{handoff: :same_stop}), do: true
  defp rider_note?(%{handoff: :same_station}), do: true
  defp rider_note?(%{handoff: {:nearby, _meters}}), do: true
  defp rider_note?(_gap), do: false

  @doc """
  Renders the notice a `trip=` deep link shows when the trip is not in the loaded
  service day: one link per service day the trip runs in, or the unavailable
  sentence when the version holds no such trip.
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
  attr :wide?, :boolean, default: false, doc: "a label column wide enough for a long label"
  slot :inner_block, required: true

  defp trip_field(assigns) do
    ~H"""
    <div class={[
      "grid gap-x-4 py-2.5",
      (@wide? && "grid-cols-[11rem_1fr]") || "grid-cols-[minmax(6.5rem,auto)_1fr]"
    ]}>
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
  surface. The colocated hook pushes `set_view` once when
  the URL carries no view; it never patches a URL that already does.

  The view control's third option, Connections, reads the same day as its groups
  of connections rather than as blocks: it carries no trip rows, no block page
  and no timeline scale, so those three and the unassigned pool's own pager are
  hidden in it and the Connections pager reads the group page instead. The tab
  and the view control stay where they are, so leaving the view is one click.

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
  attr :max_piece_minutes, :integer, default: nil
  attr :routes, :map, required: true

  attr :connection_settings, :any,
    default: %{},
    doc: "the day's connections by id, each `%{setting, review?}`"

  attr :connection_setting_options, :any,
    default: [],
    doc: "the Show filter's four values in control order, as `{label, value}`"

  attr :connections, :any,
    default: nil,
    doc:
      "the Connections view's derived state: the page of filtered groups, the pager, the counts, the places, the selected group and the filter chips"

  attr :bulk_choice, :any,
    default: nil,
    doc:
      "the Set-all setting the reader has chosen in the group panel: one of the three setting values, or `nil` while they have chosen none"

  attr :bulk_result, :any,
    default: nil,
    doc:
      "the persistent result of the last Set-all save or bulk Undo, or `nil` before there is one. It belongs to the group panel rather than to the review, so it outlives the review drawer (R10)"

  attr :selected_ids, :any, required: true
  attr :selected_block_ids, :any, required: true, doc: "the block IDs the reader has selected"
  attr :page_block_ids, :any, required: true, doc: "the block IDs the current page holds"
  attr :block_selected_count, :integer, required: true
  attr :bulk, :map, required: true
  attr :primary, :atom, values: [:head, :bulk, :blocks, :empty, :preview], default: :head

  attr :changed_block_ids, :any,
    default: MapSet.new(),
    doc: "the blocks the previewed plan changes"

  attr :preview?, :boolean, default: false

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
            options={[{"Timeline", "timeline"}, {"List", "list"}, {"Connections", "connections"}]}
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

          <%!-- “Select this page” sits beside the pool's tabs and in the List view's
          head, where the controls are large. --%>
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

      <.chart_key
        :if={show_chart_key?(@state, @counts, @filtered?, @visible_count)}
        relief?={not is_nil(@max_piece_minutes)}
        changed?={@preview? and not Enum.empty?(@changed_block_ids)}
      />

      <%!-- The bar sits between the toolbar and the records, so it stays in view
      while the reader pages through the selection. The
      block bar is the Blocks tab's own: it counts blocks, not trips, and its two
      events never touch the Unassigned panel's trip selection. --%>
      <.block_selection_bar
        :if={@block_selected_count > 0 and not @preview?}
        count={@block_selected_count}
        primary?={@primary == :blocks}
      />

      <.bulk_bar
        :if={@bulk.count > 0}
        count={@bulk.count}
        elsewhere={@bulk.elsewhere}
        removable?={@bulk.removable?}
        primary?={@primary == :bulk}
      />

      <div
        id="blocks-panel-body"
        role="tabpanel"
        aria-labelledby={"panel-" <> Atom.to_string(@state.panel)}
      >
        <%= cond do %>
          <% @state.view == :connections -> %>
            <%!-- The Connections view is the blocks work queue read as connections:
            the same day, the same derived groups and no trip rows of its own. --%>
            <.connections_panel
              connections={@connections}
              routes={@routes}
              state={@state}
              version_id={@state.version_id}
              setting_options={@connection_setting_options}
              bulk_choice={@bulk_choice}
              bulk_result={@bulk_result}
            />
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
              max_piece_minutes={@max_piece_minutes}
              connection_settings={@connection_settings}
              selected_block_ids={@selected_block_ids}
              page_block_ids={@page_block_ids}
              changed_block_ids={@changed_block_ids}
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
        :if={@state.panel == :blocks and @state.view != :connections}
        trips={@untimed_trips}
        routes={@routes}
        version_id={@state.version_id}
      />

      <div
        :if={@state.panel == :blocks and @state.view != :connections and @visible_count > 0}
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
        :if={@state.panel == :pool and @state.view != :connections and @pool_visible_count > 0}
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

  # The chart key names every mark on a row in words, at its real size: a gap's
  # states differ by more than colour, and the key is the one place that says so.
  # The garage, driving, waiting, operator-change and changed marks are painted
  # with the classes the rows use, so the key cannot drift from the chart it
  # explains. The operator-change key shows only when a limit is set, because with
  # no limit there is no operator change to place and no `⇄` can appear on a row;
  # the changed key shows only while a suggestion is previewed.
  #
  # The connection group closes the key: the minutes for a gap nobody has decided
  # and the three decided chips, painted with the same grounds the gaps carry and
  # each named in words so the chip's colour is never the whole meaning.
  attr :relief?, :boolean, default: false
  attr :changed?, :boolean, default: false

  defp chart_key(assigns) do
    ~H"""
    <div
      id="blocks-timeline-legend"
      role="group"
      aria-label="Timeline key"
      class="flex flex-wrap items-center gap-x-5 gap-y-1 border-b border-subtle bg-canvas px-4 py-1.5 text-[13px] text-muted"
    >
      <span class="inline-flex items-center gap-1.5">
        <span class="blocks-legend-key blocks-pull" aria-hidden="true"></span> Garage travel
      </span>
      <span class="inline-flex items-center gap-1.5">
        <span class="blocks-legend-key blocks-drive" aria-hidden="true"></span> Driving without riders
      </span>
      <span class="inline-flex items-center gap-1.5">
        <span class="blocks-legend-key blocks-drive blocks-drive-bad" aria-hidden="true">!</span>
        Can't reach
      </span>
      <span class="inline-flex items-center gap-1.5">
        <span class="blocks-legend-key blocks-drive-unknown" aria-hidden="true">?</span>
        Driving time unknown
      </span>
      <span class="inline-flex items-center gap-1.5">
        <span class="blocks-legend-key blocks-wait" aria-hidden="true"></span> Waiting · minutes
      </span>
      <span class="inline-flex items-center gap-1.5">
        <span
          class="inline-flex h-4 w-6 items-center justify-center border-b-[3px] border-warning-line bg-warning-bg text-[11px] font-extrabold text-warning-fg"
          aria-hidden="true"
        >
          !
        </span>
        Short layover
      </span>
      <span :if={@relief?} class="inline-flex items-center gap-1.5">
        <span class="blocks-legend-key blocks-legend-relief" aria-hidden="true">⇄</span>
        Operators can change
      </span>
      <span class="inline-flex items-center gap-1.5">
        <span
          class="inline-flex size-4 items-center justify-center rounded-badge bg-white text-error-fg outline outline-2 outline-error-line"
          aria-hidden="true"
        >
          <.icon name="hero-x-circle-mini" class="size-3" />
        </span>
        Overlap
      </span>
      <span :if={@changed?} class="inline-flex items-center gap-1.5">
        <span class="blocks-legend-key blocks-legend-changed" aria-hidden="true"></span>
        Changed · not saved
      </span>
      <span
        data-role="connection-legend"
        class="ml-auto flex flex-wrap items-center gap-x-4 gap-y-1 border-l border-subtle pl-4"
      >
        <span class="inline-flex items-center gap-1.5">
          <span
            class="blocks-legend-key blocks-legend-connection border-control bg-white text-default"
            aria-hidden="true"
          >
            6
          </span>
          Not stated (minutes)
        </span>
        <span class="inline-flex items-center gap-1.5">
          <span
            class="blocks-legend-key blocks-legend-connection blocks-legend-stay"
            aria-hidden="true"
          >
            <.icon name="hero-link-mini" class="size-3" />
          </span>
          Riders stay on board
        </span>
        <span class="inline-flex items-center gap-1.5">
          <span
            class="blocks-legend-key blocks-legend-connection blocks-legend-reboard"
            aria-hidden="true"
          >
            <.icon name="hero-arrow-right-start-on-rectangle-mini" class="size-3" />
          </span>
          Riders must re-board
        </span>
        <span class="inline-flex items-center gap-1.5">
          <span
            class="blocks-legend-key blocks-legend-connection blocks-legend-review"
            aria-hidden="true"
          >
            <.icon name="hero-exclamation-triangle-mini" class="size-3" />
          </span>
          Needs review
        </span>
      </span>
      <span class="ml-auto hidden 2xl:inline">
        Bars are colored by route and labeled with the route number.
      </span>
    </div>
    """
  end

  defp show_chart_key?(state, counts, filtered?, visible_count) do
    state.panel == :blocks and state.view == :timeline and counts.blocks > 0 and
      not (filtered? and visible_count == 0)
  end

  # The Connections view's count line, read from the derived assigns rather
  # than from a query: how many of the day's connections the filters kept, how
  # many the day holds, and how many places they are decided at. The two plural
  # nouns follow their own counts, so a day of one connection reads as one.
  defp connections_summary(nil), do: ""

  defp connections_summary(connections) do
    "#{connections.count} of #{count_label(connections.total, "connection", "connections")} " <>
      "at #{count_label(length(connections.places), "place", "places")}"
  end

  # The page's groups as one section per place, in the order R12 already sorted
  # them: a place's first appearance on the page is its busiest group, so the
  # sections read the way the groups would if the page were not paged, and a
  # place split across two pages appears on both rather than being merged from
  # groups the reader is not looking at.
  defp connection_sections(connections) do
    connections.groups
    |> Enum.group_by(& &1.place.id)
    |> Enum.map(fn {place_id, groups} ->
      %{
        id: place_id,
        name: place_name(groups),
        groups: groups,
        count: Enum.sum(Enum.map(groups, &length(&1.connections)))
      }
    end)
  end

  # The place name is the group's own, so a section's heading and a row's stop
  # name come from the same derivation and cannot disagree.
  defp place_name([%{place: %{name: name}} | _rest]), do: name

  # A GTFS stop id is feed text, so a section's DOM id is that id encoded without
  # padding rather than the id itself: a stop id holding a quote or a space can
  # then never produce a malformed id.
  defp place_token(place_id), do: Base.url_encode64(place_id, padding: false)

  # The two states a day can be in that show no groups, said as different facts.
  # A day with no connections at all has nothing to filter, so it names the step
  # that creates them; a day whose connections the filters all dropped says so
  # and names the filters.
  defp no_match_text(connections) do
    case connections.chips do
      [] -> "No connection on this service day matches these filters."
      chips -> "No connection matches #{Enum.map_join(chips, " and ", & &1.label)}."
    end
  end

  # A group's own headline: the turnback Google can offer within one route says
  # so, and every other pair says which route it continues as.
  defp connection_continuation(%{turnback?: true}, _routes), do: "Turns back"

  defp connection_continuation(group, routes),
    do: "continues as #{route_label(routes, group.to_route_id)}"

  defp connection_join_icon(%{turnback?: true}), do: "hero-arrow-uturn-right"
  defp connection_join_icon(_group), do: "hero-arrow-right"

  # The arrival stop's own name rather than the place's: the place is the parent
  # station when the stop has one, and the two are one decision but not the same
  # words.
  defp connection_stop_name(group) do
    case Map.get(group.arrival_stop || %{}, :name) do
      name when name in [nil, ""] -> group.place.name
      name -> name
    end
  end

  # The handoff the group's first connection makes, in words. A group can hold
  # more than one kind and the row has one line, so it names the kind its first
  # arrival makes; the group panel lists the rest.
  defp connection_handoff_label([kind | _rest]), do: connection_handoff_name(kind)
  defp connection_handoff_label(_handoffs), do: "Handoff"

  defp connection_handoff_name(:same_stop), do: "Same stop"
  defp connection_handoff_name(:same_station), do: "Same station"
  defp connection_handoff_name(:nearby), do: "Nearby stop"
  defp connection_handoff_name(:moves), do: "Vehicle moves"

  defp connection_wait_text(%{wait_min: min, wait_max: max}) when min == max, do: "#{min}"
  defp connection_wait_text(%{wait_min: min, wait_max: max}), do: "#{min}–#{max}"

  # The setting marks the row shows: the two decided settings the Show filter can
  # keep and the review count, in the order a reader decides them, and only when
  # the group holds one. The stay and re-board marks count the group's connections
  # that need no review, the rule the Show filter applies, so a mark never promises
  # a connection the filter would then drop.
  defp connection_marks(group) do
    decidable = Enum.reject(group.connections, & &1.review?)

    [
      %{
        kind: :stay,
        count: Enum.count(decidable, &(&1.setting == :stay)),
        label: "stay on board",
        icon: "hero-link-mini"
      },
      %{
        kind: :reboard,
        count: Enum.count(decidable, &(&1.setting == :reboard)),
        label: "must re-board",
        icon: "hero-arrow-right-start-on-rectangle-mini"
      },
      %{
        kind: :review,
        count: group.counts.review,
        label: "need review",
        icon: "hero-exclamation-triangle-mini"
      }
    ]
    |> Enum.reject(&(&1.count == 0))
  end

  # The Timeline, on the service day the reader is on. The link exists because a
  # day with no connections has nothing to filter and nothing to page, and
  # assigning trips to blocks is the one step that creates the first connection.
  defp connections_timeline_path(version_id, state) do
    case state.day do
      nil -> "/gtfs/#{version_id}/blocks"
      day -> "/gtfs/#{version_id}/blocks?" <> URI.encode_query(day: day)
    end
  end

  # Renders the Connections view's list side: the Find/Show/Route toolbar, the
  # summary strip with its removable chips, one section per place, the group rows
  # that open a group, the two empty states and the group pager.
  #
  # Everything the panel shows comes from the `:connections` assign step 20's
  # `connections_view/1` derived, over the same server-only `:connections_all`
  # the timeline's chips and the connection drawer read. The panel re-derives
  # nothing: what a filter keeps, in what order, how many of each setting a group
  # holds and which page of groups this is are all decided by
  # `Blocking.Connections` (CR-1, CR-4).
  #
  # The two empty states are different facts. A day with no connections at all has
  # nothing to filter, so it offers the one step that creates them — the Timeline.
  # A day with connections that the filters dropped says so and offers the filters
  # back, because the connections exist and the reader asked the wrong question.
  #
  # The map pane is a locator, never a second copy of the list. It draws one
  # marker per place of the filtered groups and, when a group is selected or a
  # connection is open, the two stops that group's decision is about. Its failure
  # states — no Leaflet, no tiles, a place with no coordinates — each name
  # themselves and leave the list beside it working (CL-15, CR-6).
  attr :connections, :map, required: true
  attr :routes, :map, required: true
  attr :state, :map, required: true
  attr :version_id, :any, required: true
  attr :setting_options, :list, required: true
  attr :bulk_choice, :any, default: nil
  attr :bulk_result, :any, default: nil

  defp connections_panel(assigns) do
    assigns =
      assigns
      |> assign(:sections, connection_sections(assigns.connections))
      |> assign(:route_options, route_options(assigns.routes))
      |> assign(:chips, assigns.connections.chips)
      |> assign(:map_places, connections_map_places(assigns.connections))
      |> assign(:map_selection, connections_map_selection(assigns))
      |> assign(:unplaced_places, connections_unplaced_places(assigns.connections))
      # Set all offers the three settings, never the review filter: "Needs
      # review" is a way of reading the list, not a setting anyone can apply, so
      # the fieldset's radios are the Show control's own values without it.
      |> assign(
        :bulk_options,
        Enum.reject(assigns.setting_options, fn {_label, value} -> value == "review" end)
      )

    ~H"""
    <div id="connections-panel" class="min-w-0 max-w-full">
      <form
        id="connections-filter-form"
        phx-change="filter_connections"
        phx-debounce="300"
        class="flex min-w-0 flex-wrap items-end gap-x-5 gap-y-3 px-4 py-3 md:px-5"
      >
        <div class="min-w-0 flex-1 basis-[200px]">
          <.input
            type="search"
            id="connections-q"
            name="cq"
            label="Find"
            value={@connections.filter.q}
            placeholder="Place, stop, route, trip or block"
            autocomplete="off"
          />
        </div>
        <div class="min-w-0 basis-[240px]">
          <.input
            type="select"
            id="connections-show"
            name="setting"
            label="Show"
            value={@connections.filter.setting || ""}
            prompt="All connections"
            options={@setting_options}
          />
        </div>
        <div class="min-w-0 basis-[150px]">
          <.input
            type="select"
            id="connections-route"
            name="route"
            label="Route"
            value={@connections.filter.route || ""}
            prompt="All routes"
            options={@route_options}
          />
        </div>
      </form>

      <div
        id="connections-summary-strip"
        class="flex min-h-[48px] flex-wrap items-center gap-2 border-y border-subtle px-4 py-1.5 text-[13px] md:px-5"
      >
        <span id="connections-summary" class="font-semibold tabular-nums text-strong">
          {connections_summary(@connections)}
        </span>

        <.connections_chip
          :for={chip <- @chips}
          id={"connections-chip-#{chip.kind}"}
          kind={chip.kind}
          label={chip.label}
        />

        <button
          :if={@chips != []}
          id="connections-clear-filters"
          type="button"
          phx-click="clear_connection_filters"
          class={link_class()}
        >
          Clear filters
        </button>

        <span class="ml-auto text-muted">
          Settings apply to every date both trips run, not only this day type.
        </span>
      </div>

      <%!-- The Set-all result is page state rather than part of one group's
      panel, so it is rendered here above the columns and not inside the group
      panel. A filter change closes the group the save came from, and the result
      is still the reader's answer to their own write (R10), so it survives that
      and is cleared only by Dismiss. It is not shown while a different group is
      open, because it speaks for a group the reader is no longer looking at. --%>
      <div :if={bulk_result_visible?(@bulk_result, @connections.group)} class="px-5 pt-3">
        <.bulk_result :if={@bulk_result} result={@bulk_result} />
      </div>

      <div
        id="connections-layout"
        class="grid min-w-0 max-w-full grid-cols-[400px_minmax(0,1fr)] max-xl:grid-cols-[320px_minmax(0,1fr)] max-md:grid-cols-1"
      >
        <div
          id="connections-list"
          class="h-[max(560px,calc(100dvh-230px))] min-w-0 max-w-full overflow-y-auto border-r border-subtle max-md:border-r-0 max-md:border-b"
        >
          <%!-- A selected group replaces the list in the same column: the reader
          came here to decide one place-and-route pair, and the groups behind it
          are the "All places" link's job. The toolbar and the summary strip stay,
          so the filters that found this group are still the filters that can
          leave it. --%>
          <.connections_group_panel
            :if={@connections.group}
            group={@connections.group}
            routes={@routes}
            state={@state}
            bulk_options={@bulk_options}
            bulk_choice={@bulk_choice}
          />

          <.state_panel
            :if={@connections.total == 0}
            id="connections-empty"
            icon="hero-arrow-path"
            title="No connections yet"
          >
            A connection appears where a block runs two trips in a row. This service day holds
            none, so assign trips to blocks on the Timeline first.
            <:action>
              <.link
                id="connections-timeline-link"
                patch={connections_timeline_path(@version_id, @state)}
                class={link_class()}
              >
                Assign trips to blocks
              </.link>
            </:action>
          </.state_panel>

          <div :if={@connections.total > 0 and @connections.count == 0} class="grid gap-3 p-6">
            <h2 class="font-display text-base font-semibold tracking-[-0.02em] text-strong">
              No connections match
            </h2>
            <p id="connections-no-match-text" class="text-sm text-muted">
              {no_match_text(@connections)}
            </p>
            <div>
              <.button
                id="connections-no-match-clear"
                type="button"
                variant="secondary"
                class="min-h-11"
                phx-click="clear_connection_filters"
              >
                Clear filters
              </.button>
            </div>
          </div>

          <section
            :for={section <- @sections}
            :if={is_nil(@connections.group)}
            id={"connections-place-#{place_token(section.id)}"}
            aria-labelledby={"connections-place-name-#{place_token(section.id)}"}
            class="border-b border-subtle"
          >
            <div class="flex items-baseline justify-between gap-3 bg-canvas px-5 py-2">
              <h2
                id={"connections-place-name-#{place_token(section.id)}"}
                class="font-display text-sm font-semibold tracking-[-0.02em] text-strong"
              >
                {section.name}
              </h2>
              <span class="text-[13px] tabular-nums text-muted">
                {count_label(section.count, "connection", "connections")}
              </span>
            </div>

            <.connection_group_row
              :for={group <- section.groups}
              group={group}
              routes={@routes}
              state={@state}
            />
          </section>

          <div
            :if={@connections.pages > 1 and is_nil(@connections.group)}
            id="connections-pager"
            class="border-t border-subtle px-4"
          >
            <.pagination
              page={@connections.page}
              per_page={@connections.page_size}
              total={@connections.group_count}
              entity="groups"
              event="paginate_groups"
            />
          </div>
        </div>

        <.connections_map_pane
          places={@map_places}
          selection={@map_selection}
          unplaced={@unplaced_places}
        />
      </div>
    </div>
    """
  end

  # The Connections workspace's right column: the map, its own controls and the
  # note naming the places this version cannot place.
  #
  # The hook element is `phx-update="ignore"` and takes its whole input from two
  # server-rendered data attributes, so the server never patches inside the map
  # and the places and the selection can change under a live mount. Everything
  # around it — the zoom and fit controls, the wheel hint, the unavailable
  # notice — is ordinary server-rendered markup, because those are text a reader
  # needs whether or not Leaflet ever loads.
  attr :places, :list, required: true
  attr :selection, :map, default: nil
  attr :unplaced, :list, default: []

  defp connections_map_pane(assigns) do
    ~H"""
    <div
      id="connections-map-pane"
      class="relative h-[max(560px,calc(100dvh-230px))] min-w-0 max-w-full overflow-hidden bg-map-paper"
    >
      <div
        id="connections-map"
        phx-hook="ConnectionMap"
        phx-update="ignore"
        data-mode="network"
        data-places={Jason.encode!(@places)}
        data-selection={Jason.encode!(@selection)}
        aria-label="Map of connection places. Drag to pan; plus and minus zoom."
        tabindex="0"
        class="absolute inset-0 outline-offset-[-3px]"
      >
      </div>

      <%!-- Leaflet draws its own zoom control into the top-right corner (see
      `zoomControlPosition` in the hook) and the hook adds "Show every place"
      beside it, so both controls belong to the map and neither is an orphaned
      button when the map fails to load. --%>

      <div id="connections-map-note" class="absolute left-3 top-3 z-[500] grid max-w-[340px] gap-2">
        <.message
          :for={place <- @unplaced}
          id={"connections-map-note-#{place_token(place.id)}"}
          kind="warning"
          role="status"
          title={"#{place.name} isn't on the map."}
          class="shadow-card"
        >
          Its stop has no coordinates; its {count_label(place.count, "connection", "connections")} are
          still in the list.
        </.message>
      </div>

      <p
        id="connections-map-wheel-hint"
        data-map-wheel-hint
        hidden
        class="pointer-events-none absolute inset-0 z-[600] flex items-center justify-center bg-navy-800/40 px-6 text-center text-sm font-semibold text-white"
      >
        Hold ⌘ or Ctrl and scroll to zoom the map
      </p>

      <div
        id="connections-map-unavailable"
        data-role="connection-map-unavailable"
        hidden
        class="absolute inset-0 z-[1000] content-center bg-canvas px-8 text-center text-[13px] text-muted"
      >
        <p class="font-semibold text-strong">Map unavailable</p>
        <p class="mt-1">The list still works.</p>
      </div>
    </div>
    """
  end

  # The map payload, one row per place of the filtered groups. The count and the
  # review flag are the place's own derivation, and `tokens` and `anchor` name
  # the list the marker stands for: one token opens that group, several scroll to
  # the place's section and put the keyboard on its first row. A place the
  # version cannot place is still sent — with nil coordinates — so the hook skips
  # it and the note below names it rather than the map silently dropping it.
  defp connections_map_places(connections) do
    Enum.map(connections.places, fn place ->
      %{
        id: place.id,
        name: place.name,
        lat: place.lat,
        lon: place.lon,
        count: place.count,
        review?: place.review?,
        tokens: Map.get(connections.place_tokens, place.id, []),
        anchor: "connections-place-#{place_token(place.id)}"
      }
    end)
  end

  # The places the pane names in its own note: those the version stores no
  # coordinates for. A coordinate of 0 is a real position and stays on the map;
  # only a missing one is a place this version cannot draw.
  defp connections_unplaced_places(connections) do
    Enum.filter(connections.places, &place_unplaced?/1)
  end

  defp place_unplaced?(%{lat: lat, lon: lon}), do: not (is_number(lat) and is_number(lon))

  # The selected group's own two stops, or `nil` when no group is selected. The
  # open connection's stops are the same two stops of the group its row belongs
  # to, so the selection is read from the selected group rather than from the
  # drawer: the drawer can only be open for a group this panel is showing, and a
  # group selected without its drawer open still deserves its pins.
  defp connections_map_selection(%{connections: %{group: nil}}), do: nil

  defp connections_map_selection(%{connections: %{group: group}, routes: routes}) do
    with {:ok, arrival} <-
           pair_point(group.arrival_stop, route_color(routes, group.from_route_id)),
         {:ok, departure} <-
           pair_point(group.departure_stop, route_color(routes, group.to_route_id)) do
      %{arrival: arrival, departure: departure}
    else
      # A group whose stops this version cannot place draws no pins. The group
      # panel already names both stops, so nothing is lost by the map saying
      # nothing rather than drawing half a handoff.
      _other -> nil
    end
  end

  # One removable filter chip. Its control carries the kind it removes and the
  # LiveView drops that one filter, so removing a chip never has to reconstruct
  # the other two from the form.
  attr :id, :string, required: true
  attr :kind, :atom, required: true
  attr :label, :string, required: true

  defp connections_chip(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      phx-click="remove_connection_filter"
      phx-value-filter={@kind}
      class="inline-flex min-h-11 items-center gap-1 rounded-badge border border-control bg-white pl-2 pr-1 font-semibold text-strong hover:bg-canvas"
    >
      {@label}
      <.icon name="hero-x-mark" class="size-4 text-muted" />
      <span class="sr-only">Remove filter</span>
    </button>
    """
  end

  # One group row: the two route badges with the arrow or turnback between them,
  # what the connection continues as, the arrival stop, the handoff, the wait
  # range, how many connections the group holds here, and its non-zero setting
  # counts. The row is one button because choosing a group is its only action;
  # the counts are inside it so a reader never has to open a group to learn
  # whether it holds anything needing review.
  attr :group, :map, required: true
  attr :routes, :map, required: true
  attr :state, :map, required: true

  defp connection_group_row(assigns) do
    ~H"""
    <button
      id={"connections-group-#{@group.token}"}
      type="button"
      phx-click="open_group"
      phx-value-group={@group.token}
      aria-current={to_string(@state.group == @group.token)}
      class="grid w-full grid-cols-[minmax(0,1fr)_auto] items-center gap-x-3 border-t border-subtle px-5 py-2.5 text-left hover:bg-canvas aria-[current=true]:bg-selection"
    >
      <span class="flex min-w-0 items-center gap-1.5">
        <.route_badge_for route_id={@group.from_route_id} routes={@routes} />
        <.icon
          name={connection_join_icon(@group)}
          class="size-4 shrink-0 text-muted"
        />
        <.route_badge_for route_id={@group.to_route_id} routes={@routes} />
        <span class="truncate text-sm text-strong">
          <span class="font-semibold">{connection_continuation(@group, @routes)}</span>
          <span :if={@group.headsign} class="font-normal text-muted">
            to {@group.headsign}
          </span>
        </span>
      </span>

      <span
        id={"connections-group-count-#{@group.token}"}
        class="row-span-2 text-right text-[13px] tabular-nums text-strong"
      >
        {length(@group.connections)}
      </span>

      <span class="mt-0.5 flex flex-wrap items-center gap-x-3 gap-y-0.5 text-[13px] text-muted">
        <span>
          {connection_stop_name(@group)} · {connection_handoff_label(@group.handoffs)} · {connection_wait_text(
            @group
          )} min
        </span>
        <.connection_mark :for={mark <- connection_marks(@group)} {mark} />
      </span>
    </button>
    """
  end

  attr :kind, :atom, required: true
  attr :count, :integer, required: true
  attr :label, :string, required: true
  attr :icon, :string, required: true

  defp connection_mark(assigns) do
    ~H"""
    <span class={["connections-mark", "connections-mark-#{@kind}"]}>
      <.icon name={@icon} class="size-3.5 shrink-0" />
      {@count}
      <span class="sr-only">{@label}</span>
    </span>
    """
  end

  # Renders the selected group: "All places" back to the list, the heading with
  # the two route badges, the group's facts, the hints that follow from its first
  # connection, the table of every connection it holds, and the Set-all fieldset.
  #
  # Every number here is one `Blocking.Connections` already derived: the wait and
  # arrival ranges are the group's own, each row's wait is its own gap, and the
  # setting chip is the same `block_gap_note/2` the timeline's gap chips and the
  # drawer's list carry, so R13's four settings read the same in all three. The
  # hints are `Blocking.RiderOutcomes` over the group's first connection, the
  # same list the connection drawer shows for that connection (CR-3).
  #
  # A row's block button opens the connection drawer through the ordinary
  # `open_gap` event with the pair's two trip UUIDs, so the drawer is a deep link
  # and the URL keeps `view=connections` and the group behind it — the reader
  # closes the drawer and is back on this panel.
  #
  # Set all is secondary and inert until a setting is chosen: the review it opens
  # shows what the save would write, so a review reachable without a choice would
  # be a review of nothing. The button says which half is missing.
  attr :group, :map, required: true
  attr :routes, :map, required: true
  attr :state, :map, required: true
  attr :bulk_options, :list, required: true
  attr :bulk_choice, :any, default: nil

  defp connections_group_panel(assigns) do
    assigns =
      assigns
      |> assign(:first, List.first(assigns.group.connections))
      |> assign(:hints, group_hints(assigns.group))
      |> assign(:same_stop?, List.first(assigns.group.handoffs) == :same_stop)

    ~H"""
    <div id="connections-group" class="min-w-0 max-w-full px-5 pb-6 pt-2">
      <button
        id="connections-group-back"
        type="button"
        phx-click={JS.push("close_group") |> JS.focus(to: "#connections-group-#{@group.token}")}
        class={link_class()}
      >
        <.icon name="hero-chevron-left" class="size-4" /> All places
      </button>

      <h2
        id="connections-group-heading"
        class="mt-1 flex flex-wrap items-center gap-2 font-display text-[18px] font-semibold tracking-[-0.02em] text-strong"
      >
        <.route_badge_for route_id={@group.from_route_id} routes={@routes} />
        <.icon name={connection_join_icon(@group)} class="size-5 shrink-0 text-muted" />
        <.route_badge_for route_id={@group.to_route_id} routes={@routes} />
        <span id="connections-group-title">{group_headline(@group, @routes)}</span>
      </h2>

      <dl
        id="connections-group-facts"
        class="mt-3 grid grid-cols-[112px_minmax(0,1fr)] gap-x-3 gap-y-1.5 text-sm"
      >
        <dt class="text-muted">Arrives at</dt>
        <dd>{arrival_stop_name(@group)}</dd>
        <dt class="text-muted">Departs from</dt>
        <dd>{departure_stop_text(@group, @same_stop?)}</dd>
        <dt :if={!@same_stop?} class="text-muted">Handoff</dt>
        <dd :if={!@same_stop?}>{connection_handoff_names(@group.handoffs)}</dd>
        <dt class="text-muted">On board</dt>
        <dd class="tabular-nums">
          {connection_wait_text(@group)} min, arrivals {clock(@group.first_arrival)}–{clock(
            @group.last_arrival
          )}
        </dd>
      </dl>

      <ul :if={@hints != []} id="connections-group-hints" class="mt-3 grid gap-1.5">
        <li
          :for={hint <- @hints}
          data-hint={hint.kind}
          class="flex gap-2 text-[13px] text-default"
        >
          <.icon name={hint_icon(hint.kind)} class="mt-0.5 size-4 shrink-0" />
          <span class="min-w-0">{hint.text}</span>
        </li>
      </ul>

      <h3
        id="connections-group-count"
        class="mt-5 text-sm font-semibold text-strong"
      >
        {count_label(length(@group.connections), "connection", "connections")}
      </h3>

      <div class="mt-2 max-w-full overflow-x-auto">
        <%!-- The production setting chip is the same one the timeline's gap chips
        and the drawer carry, so it is longer than the reference's own short
        label, and a feed's own trip ids are longer than the reference's. One
        line per connection therefore needs more width than the list column has,
        so the table is as wide as its own content and scrolls sideways inside
        the column — the same treatment the List view's block tables already
        give their wide ones. Pinning a column would be the alternative, but it
        hides a required column (Wait) behind the pinned one at scroll zero, and
        `table-row-design.md` asks every column for a visible header. --%>
        <table
          id="connections-group-table"
          class="w-max min-w-[420px] border-collapse whitespace-nowrap text-left text-[13px]"
        >
          <thead>
            <tr class="bg-white text-default">
              <th scope="col" class="h-9 pr-2 font-[650]">Block</th>
              <th scope="col" class="pr-2 font-[650]">Arrives</th>
              <th scope="col" class="pr-2 text-right font-[650]">Wait</th>
              <th scope="col" class="pr-1 font-[650]">Setting</th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={connection <- @group.connections}
              id={"connections-connection-row-#{connection_row_token(connection)}"}
              aria-current={to_string(@state.gap == connection.id)}
              class="border-t border-subtle bg-white hover:bg-canvas aria-[current=true]:bg-selection"
            >
              <td class="pr-2">
                <button
                  id={"connections-connection-#{connection_row_token(connection)}"}
                  type="button"
                  phx-click="open_gap"
                  phx-value-from={connection.from.id}
                  phx-value-to={connection.to.id}
                  phx-value-block={connection.block_id}
                  class="min-h-11 min-w-11 py-1 text-left font-semibold text-action hover:underline"
                >
                  {connection.block_id}
                </button>
              </td>
              <td class="pr-2 tabular-nums">
                {clock(connection.from.last_arrival)}
                <span class="text-[12px] text-muted">
                  {connection.from.trip_id}→{connection.to.trip_id}
                </span>
              </td>
              <td class="pr-2 text-right tabular-nums">
                {connection_wait_minutes(connection)} min
              </td>
              <td class="pr-1">
                <.block_gap_note connection={block_gap_note(connection.setting, connection.review?)} />
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <form
        id="connections-bulk-form"
        phx-change="bulk_choice"
        class="mt-6 rounded-card border border-subtle p-4"
      >
        <fieldset>
          <legend class="px-1 text-sm font-semibold text-strong">
            Set all {length(@group.connections)} at once
          </legend>
          <p id="connections-bulk-note" class="text-[13px] text-muted">
            The review lists every connection with its wait. Leave any out before saving.
          </p>
          <div class="mt-3 grid gap-2">
            <label
              :for={{label, value} <- @bulk_options}
              class="flex min-h-11 cursor-pointer items-center gap-2.5 rounded-control border border-subtle px-3 text-sm has-[:checked]:border-action has-[:checked]:bg-selection"
            >
              <input
                type="radio"
                id={"connections-bulk-#{value}"}
                name="bulk"
                value={value}
                checked={@bulk_choice == value}
                class="size-[18px] accent-action"
              />
              {label}
            </label>
          </div>
        </fieldset>
        <.button
          id="bulk-review-open"
          type="button"
          variant="secondary"
          class="mt-3"
          phx-click="open_bulk_review"
          phx-disabled-with="Reviewing…"
          disabled={is_nil(@bulk_choice)}
        >
          Review {count_label(length(@group.connections), "connection", "connections")}
        </.button>
        <p
          :if={is_nil(@bulk_choice)}
          id="connections-bulk-disabled-note"
          class="mt-1 text-[13px] text-muted"
        >
          Choose a setting to review.
        </p>
      </form>
    </div>
    """
  end

  # The group's own headline, the list row's continuation with the place spelled
  # out: a turnback says so, and every other pair names the route it continues
  # as. The route is the day's own badge name, so a group with a short name reads
  # "Continues as 24" and never "Continues as R24".
  defp group_headline(%{turnback?: true} = group, _routes),
    do: "Turns back at #{group.place.name}"

  defp group_headline(group, routes),
    do: "Continues as #{route_label(routes, group.to_route_id)} at #{group.place.name}"

  # The arrival stop's own name, the place's when the day's derivation carries no
  # stop for it — the same fallback the list row makes.
  defp arrival_stop_name(group) do
    case Map.get(group.arrival_stop || %{}, :name) do
      name when name in [nil, ""] -> group.place.name
      name -> name
    end
  end

  # A pair that hands over at the stop it arrived at has nowhere to go, so the
  # facts say "Same stop" rather than repeating the arrival stop's own name.
  defp departure_stop_text(_group, true), do: "Same stop"

  defp departure_stop_text(group, false) do
    case Map.get(group.departure_stop || %{}, :name) do
      name when name in [nil, ""] -> group.place.name
      name -> name
    end
  end

  # Every handoff kind the group holds, in `Blocking.Connections`' own order. A
  # group can hold more than one — a stop that some pairs hand over at and others
  # walk from — and the facts can say all of them where the list row named one.
  defp connection_handoff_names(handoffs) do
    case handoffs do
      [] -> "Handoff"
      handoffs -> Enum.map_join(handoffs, " · ", &connection_handoff_name/1)
    end
  end

  # The hints of the group's first connection: the copy is per connection, and
  # the first connection is the one the list's row and the heading already
  # describe, so the panel's facts and its hints are about the same pair. The
  # turnback flag is the group's own, which is what `Connections` grouped on.
  defp group_hints(group) do
    case List.first(group.connections) do
      nil -> []
      connection -> RiderOutcomes.hints(Map.merge(connection, %{turnback?: group.turnback?}))
    end
  end

  # One connection's own wait, in whole minutes. The connection is one gap, so it
  # has one wait rather than a range, and an overlap keeps its negative sign
  # exactly as `Connections` reports it.
  defp connection_wait_minutes(connection), do: div(connection.gap.gap_secs, 60)

  # A connection's id is its two trip UUIDs joined by a bar, so the row's DOM id
  # is that id encoded without padding: the same rule the list's section ids and
  # the group's token follow, for the same reason.
  defp connection_row_token(connection), do: Base.url_encode64(connection.id, padding: false)

  @doc """
  Renders the Set-all review: what saving one setting across a whole group would
  do, connection by connection, before anything is written (AC-20, R10).

  The drawer is the page's second non-modal inspector (`modal={false}`, CR-5): the
  group panel's rows, its choice and its filters stay readable and clickable
  beside it, because the review describes those rows rather than replacing them.
  It is wide enough for the four-column table and no wider.

  Every number and every row here is the LiveView's own derivation: the counts
  tally the rows' results, each row's "now → result" is its `from` beside the
  result its `refusal` or its records decided, and the counts card labels are the
  ones AC-20 names. A pair the write rule refused carries
  `Blocking.RiderOutcomes.refusal_text/1`'s own sentence (CR-3) and has no
  include box, because a save cannot act on it; a pair already carrying the
  chosen setting has none either, because there is nothing to write.
  """
  attr :review, :map, required: true
  attr :routes, :map, required: true

  attr :pending, :boolean,
    default: false,
    doc: "a Set-all write is in flight, so the footer reports it and the boxes are inert"

  attr :error, :any,
    default: nil,
    doc:
      "a failed Set-all write's own `%{title, message}`, or `nil`. The review stays open with it (AC-20)"

  def set_all_review(assigns) do
    group = assigns.review.group
    counts = set_all_review_counts(assigns.review)
    included = Enum.count(assigns.review.rows, & &1.include?)
    actionable = Enum.count(assigns.review.rows, &(&1.result in [:add, :replace, :remove]))

    assigns =
      assigns
      |> assign(:group, group)
      |> assign(:counts, counts)
      |> assign(
        :count_columns,
        if(length(counts) == 2, do: "sm:grid-cols-2", else: "sm:grid-cols-4")
      )
      |> assign(:included, included)
      |> assign(:actionable, actionable)
      |> assign(
        :title,
        "Review: #{bulk_setting_label(assigns.review.choice)}"
      )
      |> assign(
        :included_label,
        if(assigns.pending,
          do: "Saving…",
          else: "#{included} of #{actionable} included"
        )
      )
      |> assign(
        :save_label,
        if(assigns.pending,
          do: "Saving…",
          else: "Save #{count_label(included, "connection", "connections")}"
        )
      )

    ~H"""
    <.drawer
      id="set-all-review"
      chrome="planner"
      modal={false}
      open={true}
      on_close="close_bulk_review"
      title={@title}
      return_focus_id="bulk-review-open"
      class="max-w-[min(100vw,42rem)]"
    >
      <:lede>
        <.route_badge_for route_id={@group.from_route_id} routes={@routes} />
        <.icon name={connection_join_icon(@group)} class="size-4 shrink-0 text-muted" />
        <.route_badge_for route_id={@group.to_route_id} routes={@routes} />
        at {@group.place.name} · {count_label(length(@review.rows), "connection", "connections")} ·
        Preview, not saved
      </:lede>

      <.drawer_scroll>
        <.message
          :if={@error}
          id="set-all-review-error"
          kind="error"
          title={@error.title}
          tabindex="-1"
          phx-hook="FormErrorFocus"
          data-focus-on-mount="set-all-review-error"
          data-role="set-all-review-error"
        >
          {@error.message}
        </.message>

        <dl id="set-all-review-counts" class={["grid gap-2", @count_columns]}>
          <div
            :for={{label, value} <- @counts}
            id={"set-all-review-count-#{bulk_count_id(label)}"}
            class="rounded-control border border-subtle px-3 py-2"
          >
            <dt class="text-[13px] text-muted">{label}</dt>
            <dd class="font-display text-[24px] font-semibold tabular-nums text-strong">{value}</dd>
          </div>
        </dl>

        <p id="set-all-review-note" class="text-[13px] text-muted">
          Each connection gets its own record, applied on every date both trips run.
          Clear a box to leave a connection as it is.
        </p>

        <div class="max-w-full overflow-x-auto">
          <table
            id="set-all-review-table"
            class="mt-2 w-full min-w-[480px] border-collapse text-left text-[13px]"
          >
            <thead>
              <tr class="bg-white text-default">
                <th scope="col" class="h-9 w-11 font-[650]"><span class="sr-only">Include</span></th>
                <th scope="col" class="whitespace-nowrap pr-3 font-[650]">Block · arrives</th>
                <th scope="col" class="pr-3 text-right font-[650]">Wait</th>
                <th scope="col" class="font-[650]">Now → result</th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={row <- @review.rows}
                id={"set-all-review-row-#{connection_row_token(row.connection)}"}
                data-result={row.result}
                class={[
                  "border-t border-subtle align-top",
                  if(row.result == :skip,
                    do: "bg-warning-bg",
                    else: "bg-white"
                  )
                ]}
              >
                <td class="py-1">
                  <label
                    :if={row.result in [:add, :replace, :remove]}
                    class="flex size-11 cursor-pointer items-center justify-center"
                  >
                    <input
                      type="checkbox"
                      id={"set-all-review-include-#{connection_row_token(row.connection)}"}
                      checked={row.include?}
                      phx-click="toggle_bulk_row"
                      phx-value-id={row.id}
                      disabled={@pending}
                      aria-label={"Include block #{row.connection.block_id}, #{clock(
                        row.connection.from.last_arrival
                      )}"}
                      class="size-[18px] accent-action"
                    />
                  </label>
                </td>
                <td class="whitespace-nowrap py-2.5 pr-3">
                  <strong>{row.connection.block_id}</strong>
                  · <span class="tabular-nums">{clock(row.connection.from.last_arrival)}</span>
                  <span class="block text-[12px] text-muted">
                    {row.connection.from.trip_id} → {row.connection.to.trip_id}
                  </span>
                </td>
                <td class="whitespace-nowrap py-2.5 pr-3 text-right tabular-nums">
                  {connection_wait_minutes(row.connection)} min
                </td>
                <td class="py-2.5">{bulk_row_result_text(row)}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </.drawer_scroll>

      <.drawer_footer>
        <p
          id="set-all-review-included"
          class="mr-auto text-[13px] text-muted"
          role="status"
          aria-live="polite"
        >
          {@included_label}
        </p>

        <button
          type="button"
          id="set-all-review-cancel"
          class="btn btn-ghost min-h-11"
          phx-click="close_bulk_review"
          disabled={@pending}
        >
          Cancel
        </button>
        <.button
          id="set-all-review-save"
          type="button"
          class="min-h-11"
          phx-click="save_bulk"
          phx-disable-with="Saving…"
          disabled={@included == 0 or @pending}
        >
          {@save_label}
        </.button>
      </.drawer_footer>
    </.drawer>
    """
  end

  # The counts AC-20 names, in the order it names them: a review that removes
  # records reports what it removes and what was already not stated, and a review
  # that writes one reports adds, replaces, pairs already carrying it and pairs
  # the rule refused.
  defp set_all_review_counts(%{choice: "none", rows: rows}) do
    [
      {"Removes", count_result(rows, :remove)},
      {"Already not stated", count_result(rows, :same)}
    ]
  end

  defp set_all_review_counts(%{rows: rows}) do
    [
      {"Adds", count_result(rows, :add)},
      {"Replaces", count_result(rows, :replace)},
      {"Already set", count_result(rows, :same)},
      {"Can't be set", count_result(rows, :skip)}
    ]
  end

  defp count_result(rows, result), do: Enum.count(rows, &(&1.result == result))

  # A count card's DOM id: its label without the spaces and apostrophe, so a
  # case names the card it means.
  defp bulk_count_id(label) do
    label
    |> String.downcase()
    |> String.replace("'", "")
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp bulk_setting_label("none"), do: "not stated"
  defp bulk_setting_label("stay"), do: "riders stay on board"
  defp bulk_setting_label("reboard"), do: "riders must re-board"

  # The "now → result" cell. A refused pair says what the rule said and why it
  # matters here; a pair already carrying the setting says so and stops; every
  # other pair says what it has today and what saving would do to it.
  defp bulk_row_result_text(%{result: :skip} = assigns) do
    ~H"""
    <span class="font-semibold text-warning-fg">Can’t be set.</span>
    {@refusal}
    """
  end

  defp bulk_row_result_text(%{result: :same} = assigns) do
    ~H"""
    <span class="text-muted">Already set</span>
    """
  end

  defp bulk_row_result_text(assigns) do
    assigns = Map.put(assigns, :label, bulk_result_label(assigns.result))

    ~H"""
    {@from} → <strong>{@label}</strong>
    """
  end

  defp bulk_result_label(:add), do: "Adds record"
  defp bulk_result_label(:replace), do: "Replaces record"
  defp bulk_result_label(:remove), do: "Removes record"

  # The persistent result of one Set-all save or bulk Undo, at the top of the
  # group panel it belongs to (R10, AC-20).
  #
  # It is a `PlannerComponents.message/1` rather than a callout of its own because
  # it answers the same question in the same place, and one component keeps the
  # tone, the role and the Dismiss affordance identical across both surfaces. A
  # result with nothing skipped is `success`; one that names skipped pairs is
  # `warning`, because a partial write is neither a failure nor the whole save
  # (PM-5).
  #
  # It is a polite status rather than an alert: it reports an action the reader
  # chose, and its own sentence says whether anything went wrong. Focus moves
  # here when it arrives, so it is focusable and is the drawer's focus target.
  attr :result, :map, required: true

  def bulk_result(assigns) do
    assigns =
      assigns
      |> assign(:skipped, bulk_result_skipped(assigns.result))
      |> assign(:restorable, length(assigns.result.previous))
      |> assign(:unrestorable, Map.get(assigns.result, :unrestorable, 0))

    ~H"""
    <.message
      id="bulk-result"
      kind={if @skipped == [], do: "success", else: "warning"}
      role="status"
      title={bulk_result_title(@result)}
      tabindex="-1"
      phx-hook="FormErrorFocus"
      data-focus-on-mount="bulk-result"
      data-role="bulk-result"
      class="mt-3"
    >
      <ul :if={@skipped != []} id="bulk-result-skipped" class="grid gap-1">
        <li
          :for={skip <- @skipped}
          id={"bulk-result-skip-#{skip_token(skip)}"}
          data-role="bulk-result-skip"
          class="text-[13px]"
        >
          {skip.block}: {skip.reason}
        </li>
      </ul>

      <p
        :if={@unrestorable > 0}
        id="bulk-result-unrestorable"
        data-role="bulk-result-unrestorable"
        class="mt-1 text-[13px]"
      >
        {count_label(@unrestorable, "replaced record", "replaced records")} can’t be restored
        because {if @unrestorable == 1, do: "it", else: "they"} didn’t match the block.
      </p>

      <div id="bulk-result-actions" class="mt-3 flex flex-wrap items-center gap-4">
        <button
          :if={@result.undo? and @restorable > 0}
          id="bulk-undo"
          type="button"
          phx-click="undo_bulk"
          class="inline-flex min-h-11 items-center rounded-control px-2 text-sm font-semibold underline underline-offset-4 hover:bg-canvas"
        >
          Undo {count_label(@restorable, "change", "changes")}
        </button>
        <button
          id="bulk-dismiss"
          type="button"
          phx-click="dismiss_bulk_result"
          class="inline-flex min-h-11 items-center rounded-control px-2 text-sm font-semibold underline underline-offset-4 hover:bg-canvas"
        >
          Dismiss
        </button>
      </div>
    </.message>
    """
  end

  # Which pairs this result names as not written: the save's own skips, or the
  # Undo's once it has run. Both carry the label and reason the write gave.
  defp bulk_result_skipped(%{undo?: false, undo_skipped: skipped}), do: skipped
  defp bulk_result_skipped(%{skipped: skipped}), do: skipped
  defp bulk_result_skipped(_result), do: []

  # A skipped line's own DOM id, from its block label, so a case names the line
  # it means rather than counting them.
  defp skip_token(%{block: block}), do: String.replace(block, ~r/[^A-Za-z0-9]+/, "-")

  # "Saved 9 connections: riders stay on board. 2 skipped:", and the Undo's own
  # sentence once it has run. Both counts are the write's own answer, so the
  # message cannot claim a connection the write did not touch.
  defp bulk_result_title(result) do
    title =
      if Map.has_key?(result, :restored) do
        "Restored #{count_label(result.restored, "connection", "connections")}."
      else
        "Saved #{count_label(length(result.saved), "connection", "connections")}: " <>
          "#{bulk_setting_label(result.setting)}."
      end

    case bulk_result_skipped(result) do
      [] -> title
      skipped -> title <> " #{length(skipped)} skipped:"
    end
  end

  # The result belongs to the group the save came from, so opening another group
  # never puts one group's answer above another's rows. With no group open — the
  # list, or the group a filter change just closed — it stands, because it is the
  # reader's own answer to their own write and nothing has replaced it (R10).
  defp bulk_result_visible?(nil, _group), do: false

  defp bulk_result_visible?(%{group_token: token}, %{token: token}) when is_binary(token),
    do: true

  defp bulk_result_visible?(_result, nil), do: true
  defp bulk_result_visible?(_result, _group), do: false

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
  pages”) and keeps saying so while the reader pages. “Clear selection”
  empties the set; “Assign N trips” opens the selection-scoped assignment form;
  “Remove from block” is offered only when a selected trip has a block, because
  the others are already in the pool.

  While the bar shows, its Assign is the page's one primary: the header's Review
  action drops to secondary. During a suggestion preview Apply suggestion keeps
  the primary, so Assign drops to secondary.
  """
  attr :count, :integer, required: true
  attr :elsewhere, :integer, required: true
  attr :removable?, :boolean, required: true
  attr :primary?, :boolean, default: true

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
          variant={if @primary?, do: "primary", else: "secondary"}
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

  @doc """
  Renders the block selection bar: how many blocks are selected, and the two
  actions.

  It is the trip bar's sibling rather than a second mode of it: the count names
  blocks, and “Clear selection” (`clear_block_selection`) and “Rebuild selected
  blocks” (`rebuild_selected`) never read the Unassigned panel's trip selection.
  While the bar shows, its Rebuild selected blocks is the page's one primary (the
  header's Review action drops to secondary), unless the trip bar is showing too
  and holds it.
  """
  attr :count, :integer, required: true
  attr :primary?, :boolean, default: true

  def block_selection_bar(assigns) do
    ~H"""
    <div
      id="block-selection-bar"
      role="region"
      aria-label="Selected blocks"
      class="mx-4 my-3 flex flex-wrap items-center justify-between gap-x-4 gap-y-2 rounded-card border border-action/30 bg-selection px-4 py-2"
    >
      <strong id="block-selection-count" class="text-sm text-strong">
        {count_label(@count, "block selected", "blocks selected")}
      </strong>

      <div class="flex flex-wrap items-center gap-2">
        <.button
          id="block-selection-clear"
          type="button"
          variant="secondary"
          class="min-h-11"
          phx-click="clear_block_selection"
        >
          Clear selection
        </.button>
        <.button
          id="block-selection-rebuild"
          type="button"
          variant={if @primary?, do: "primary", else: "secondary"}
          class="min-h-11"
          phx-click="rebuild_selected"
        >
          Rebuild selected blocks
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

  # The pool and the List view carry a “Select this page” control where their
  # records are; the timeline has no selection column, so it does
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
  view carries the same page of blocks as the timeline. It has its own
  stream because a stream renders in one container: the timeline's rows and these
  tables are two densities of one page, and the LiveView fills both together. The
  columns are Select, Trip, Route, Start, End, From → To, Gap and
  Issues; the block's heading also carries its two distance figures, `km with
  riders` and `km without (est.)`, read from the block's own movements
  and the same numbers the Plan summary and the export read. The route's long
  name is the trip's secondary line, and the terminal is the destination line of
  the From → To cell.

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
        movements: assigns.block.movements,
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
        <span class="text-[13px] text-muted">
          <span data-role="list-km-riders" data-km={@movements.service_km}>
            {km(@movements.service_km)} km with riders
          </span>
          ·
          <span data-role="list-km-deadhead" data-km={@movements.deadhead_km}>
            {km(@movements.deadhead_km)} km without{if estimated_leg?(@movements), do: " (est.)"}
          </span>
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

  The columns are Select, Route / trip, Start → end, From → to,
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
  list is where a blocked trip with missing timing stays visible.
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
  # selection, so a re-streamed row shows the state the reader last set.
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

  # The timeline row's block checkbox: the same 44px target around a daisyUI
  # checkbox as the trip one, but carrying the block's own ID in its own event, so
  # the Blocks tab's block selection and the Unassigned panel's trip selection
  # never share state.
  attr :block_id, :string, required: true
  attr :checked, :boolean, required: true
  attr :disabled, :boolean, default: false

  defp select_block(assigns) do
    ~H"""
    <%!-- The row's hairline sits inside its 44px, so the target gives that pixel back. --%>
    <label
      class="-mb-px grid min-h-11 min-w-11 place-items-center"
      for={"block-select-" <> dom_token(@block_id)}
    >
      <input
        type="checkbox"
        id={"block-select-" <> dom_token(@block_id)}
        data-role="select-block"
        data-block={@block_id}
        checked={@checked}
        disabled={@disabled}
        phx-click="toggle_block"
        phx-value-block={@block_id}
        aria-label={"Select block " <> @block_id}
        class="size-5 accent-action"
      />
    </label>
    """
  end

  # The header's page checkbox. It is checked when every block on the current page
  # is selected and unchecked otherwise, so the control never claims more than it
  # did. Its accessible name says what it selects.
  attr :checked, :boolean, required: true
  attr :disabled, :boolean, default: false

  defp select_page_blocks(assigns) do
    ~H"""
    <label
      class="flex min-h-11 min-w-11 cursor-pointer flex-col items-center justify-center gap-0.5"
      for="blocks-select-all-blocks"
    >
      <input
        type="checkbox"
        id="blocks-select-all-blocks"
        data-role="select-all-blocks"
        checked={@checked}
        disabled={@disabled}
        phx-click="select_block_page"
        aria-label="Select all blocks on this page"
        class="size-5 accent-action"
      />
    </label>
    """
  end

  # The header checkbox's rule: a page that holds a block and has every one of them
  # selected is fully selected. A partly selected page shows an unchecked control,
  # which is the state the reader's next click acts on (adding the rest). The
  # page's own block IDs are an assign rather than a walk of `@block_rows`,
  # because a live stream may only be consumed by the `for` comprehension that
  # renders it.
  defp page_all_selected?(%{selected_block_ids: selected, page_block_ids: page_ids}) do
    MapSet.size(page_ids) > 0 and MapSet.subset?(page_ids, selected)
  end

  # The trip's endpoint stops: the origin, then the destination on its own line
  # as “→ <terminal>”, which is the From → To cell.
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

  # The route's long name, which prints under the trip ID; a route
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
  a single trip, not a repeating one.

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
  direction in `aria-sort` and an arrow (the `sort` event). The axis and every
  bar are positioned by percentage of the same span, so they stay aligned inside
  the one scroll container.
  """
  attr :state, :map, required: true
  attr :block_rows, :any, required: true
  attr :axis, :map, default: nil
  attr :routes, :map, required: true
  attr :max_piece_minutes, :integer, default: nil

  attr :connection_settings, :any,
    default: %{},
    doc: "the day's connections by id, each `%{setting, review?}`"

  attr :selected_block_ids, :any, required: true, doc: "the block IDs the reader has selected"
  attr :page_block_ids, :any, required: true, doc: "the block IDs the current page holds"

  attr :changed_block_ids, :any,
    default: MapSet.new(),
    doc: "the blocks the previewed plan changes"

  def timeline(assigns) do
    assigns =
      assigns
      |> assign(:columns, sort_columns())
      |> assign(:ticks, axis_ticks(assigns.axis))
      |> assign(:track_style, track_style(assigns.axis))
      |> assign(:page_all_selected?, page_all_selected?(assigns))
      |> assign(:changed?, MapSet.size(assigns.changed_block_ids) > 0)

    ~H"""
    <div id="blocks-timeline-scroll">
      <table id="blocks-timeline" data-scale={@state.scale} aria-label="Blocks by service-day time">
        <colgroup>
          <col class="blocks-col-select" />
          <col class="blocks-col-block" />
          <col class="blocks-col-garage" />
          <col class="blocks-col-out" />
          <col class="blocks-col-hours" />
          <col class="blocks-col-status" />
          <col />
        </colgroup>
        <thead>
          <tr>
            <th scope="col" class="blocks-meta blocks-meta-select">
              <.select_page_blocks checked={@page_all_selected?} disabled={@changed?} />
            </th>
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
            max_piece_minutes={@max_piece_minutes}
            connection_settings={@connection_settings}
            selected?={MapSet.member?(@selected_block_ids, block.summary.block_id)}
            changed?={MapSet.member?(@changed_block_ids, block.summary.block_id)}
          />
        </tbody>
      </table>
    </div>
    """
  end

  @doc """
  Renders one 44px block row: the sticky Select, Block, Garage · type, Time out, Hours and
  Status cells and the track with the block's trip bars and gaps.

  Garage · type prints the block's garage and type resolution — `Main · Cutaway`, `Main · Any
  type` when nothing requires a type, `No garage` when no garage resolves, and
  `Differs · Cutaway` in the warning colour when the block's calendars disagree.
  Time out is the platform span from `Movements.build/3`, so a vehicle
  that pulls out before midnight reads `23:45 −1d–01:30 +1d`.

  The bars are the block's sequence (plottable, non-frequency trips) so they line
  up with `gaps/1`'s consecutive pairs; an unplottable or repeating trip appears
  in its block and in the Status cell's finding instead of as a bar. With a route
  filter applied, a trip of another route renders no bar and no gap, matching the
  filter that already excluded the block when it has no trip on the route.

  The garage legs and the drives come from the block's derived movements rather than from a second rule: a pull-out before the first bar and a
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

  attr :connection_settings, :any,
    default: %{},
    doc: "the day's connections by id, each `%{setting, review?}`"

  attr :selected?, :boolean, default: false, doc: "whether the block is in the reader's selection"
  attr :changed?, :boolean, default: false, doc: "whether the previewed plan changes this block"

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
    <tr
      id={@dom}
      data-block={@summary.block_id}
      data-changed={to_string(@changed?)}
      class={["blocks-row", @changed? && "blocks-row-changed"]}
    >
      <td class={["blocks-meta", "blocks-meta-select"]}>
        <.select_block block_id={@summary.block_id} checked={@selected?} disabled={@changed?} />
      </td>
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
      <%!-- Beside the Changed chip a long status label ellipsizes; the title keeps it whole. --%>
      <td
        class={["blocks-meta", "blocks-meta-status"]}
        title={@changed? && "Changed · " <> @status.label}
      >
        <span
          :if={@changed?}
          data-role="block-changed"
          class="mr-2 inline-flex items-center rounded-badge bg-selection px-1.5 py-0.5 text-[12px] font-bold text-action"
        >
          Changed
        </span>
        <.status_text status={@status} />
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
              setting={gap_setting(@connection_settings, row)}
              review?={gap_review?(@connection_settings, row)}
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
  Renders one garage leg as a button positioned by the service day's axis.

  A pull-out runs from the garage to the first departure and a pull-back from the
  last arrival back to the garage; both open the block drawer, and the title
  names the garage, the time and where the driving time came from — an entered
  time and an estimate are different claims about the same bar. The bar itself
  carries no text: its minutes are in the title rather than
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
  Renders one drive as a button positioned by the service day's axis.

  Three shapes, each carrying its own text so the status is never colour alone: a
  feasible drive is hatched and starts the wait that follows it; a drive the
  vehicle cannot make in time takes the whole gap in a red hatch with a 2px
  outline and `!`; a drive the version cannot compute takes the gap with `?` and
  claims nothing about it. All three open the gap drawer.
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
  departure, so `from` is the earlier trip of the pair; a gap the vehicle spends
  part of driving starts after that drive instead, and prints the wait it is left
  with rather than the whole gap. Its minutes print only when the bar is at least
  26px wide, which the container query reads from the bar's own width. A short
  layover is an 18px warning chip with its “!” always drawn, centred on the wait
  and above the bars, so the states differ by more than colour. A wait at a marked
  stop ends its label with `⇄` once the bar is wide enough for both, which is the
  instant an operator change is possible there.

  `setting` is the connection's own decision, read from the day's
  `Blocking.Connections` derivation: no record is `:none`, one type 4 record is
  `:stay`, one type 5 record is `:reboard` and two or more are `:conflict`. A
  decided gap draws a 22px chip with the matching icon in place of its minutes and
  keeps the bar's own geometry and click target; the minutes stay for a gap with no
  record, which is the case that still needs a decision. `review?` covers a record
  the day load found stale and a pair that carries two records: either way the chip
  is the warning, and the title says so in words as well as in the icon.
  """
  attr :gap, :map, required: true
  attr :from, :map, required: true
  attr :axis, :map, default: nil
  attr :short?, :boolean, default: false
  attr :drive_secs, :integer, default: nil
  attr :relief?, :boolean, default: false

  attr :setting, :atom,
    values: [:none, :stay, :reboard, :conflict],
    default: :none,
    doc: "the connection's decided in-seat setting"

  attr :review?, :boolean,
    default: false,
    doc: "whether the connection's record is stale or duplicated"

  def gap(assigns) do
    assigns =
      assigns
      |> assign(:wait_secs, assigns.gap.gap_secs - (assigns.drive_secs || 0))
      |> assign(:marker, gap_marker(assigns.setting, assigns.review?))
      |> assign(
        :style,
        gap_geometry(assigns.gap, assigns.from, assigns.axis, assigns.drive_secs, assigns.short?)
      )

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
      data-setting={@marker.setting}
      phx-click="open_gap"
      phx-value-from={@from.id}
      phx-value-to={@gap.to_id}
      style={@style}
      class={["blocks-gap", @short? && "blocks-gap-short", @marker.class]}
      title={gap_title(@gap, @marker.label)}
    >
      <span :if={@short?} aria-hidden="true">!</span>
      <%= if @marker.icon do %>
        <span
          data-role="blocks-gap-setting"
          data-setting={@marker.setting}
          class="blocks-gap-chip"
        >
          <.icon name={@marker.icon} class="size-3.5" />
        </span>
      <% else %>
        <span class="blocks-gap-label">
          {div(@wait_secs, 60)}<span :if={@relief?} data-role="blocks-gap-relief"> ⇄</span>
        </span>
      <% end %>
    </button>
    """
  end

  # What one gap draws for its connection: the `data-setting` value the timeline
  # and the Playwright journeys read, the chip's class, its icon and the words its
  # title adds. A record that needs review wins over its own setting, because a
  # stale or doubled record is the thing a planner has to look at.
  defp gap_marker(:none, _review?), do: %{setting: "none", class: nil, icon: nil, label: nil}

  defp gap_marker(_setting, true) do
    %{
      setting: "review",
      class: "blocks-gap-review",
      icon: "hero-exclamation-triangle-mini",
      label: "Needs review"
    }
  end

  defp gap_marker(:stay, false) do
    %{
      setting: "stay",
      class: "blocks-gap-stay",
      icon: "hero-link-mini",
      label: "Riders stay on board"
    }
  end

  defp gap_marker(:reboard, false) do
    %{
      setting: "reboard",
      class: "blocks-gap-reboard",
      icon: "hero-arrow-right-start-on-rectangle-mini",
      label: "Riders must re-board"
    }
  end

  defp gap_marker(:conflict, false) do
    %{
      setting: "review",
      class: "blocks-gap-review",
      icon: "hero-exclamation-triangle-mini",
      label: "Needs review"
    }
  end

  @doc """
  Prints parsed seconds as `HH:MM`, with ` −1d` before midnight and ` +1d` after
  it. A negative service-day second floors into the day before rather than
  truncating towards it, so −900 s reads 23:45 −1d rather than 00:00.
  """
  def clock(nil), do: "—"

  def clock(secs) when is_integer(secs) do
    days = Integer.floor_div(secs, 86_400)
    # `rem/2` keeps the dividend's sign, which would leave a negative second
    # still negative and print `00:-15`. `Integer.mod/2` is the operation that
    # pairs with `floor_div/2`, so the within-day value is never negative.
    within = Integer.mod(secs, 86_400)

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
  # garage, so it prints the warning word instead of one of the two names;
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

  # The suffix rule for the Driving times link: the count is printed only when the
  # day has an estimate to review, and the label starts with a separator so the
  # link reads as one phrase.
  defp estimated_label(0), do: ""
  defp estimated_label(count), do: " · #{count} estimated"

  # A control that is off during a preview says why in its own title, so a
  # reader who reaches for it is told the plan would no longer be the one on
  # screen rather than left to guess.
  defp preview_title(false, _reason), do: nil
  defp preview_title(true, reason), do: reason <> ". Discard the suggestion to change it."

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
  defp summary_tiles(counts) do
    [
      %{
        key: "blocks",
        label: "Blocks",
        count: counts.blocks,
        value: counts.blocks,
        tone: :neutral,
        icon: "hero-rectangle-stack",
        action?: false,
        wide?: false,
        detail: nil,
        target: nil
      },
      unassigned_tile(counts.unassigned),
      problems_tile(counts.problems),
      %{
        key: "notices",
        label: "Notices",
        count: counts.notices,
        value: counts.notices,
        tone: :neutral,
        icon: "hero-information-circle",
        action?: false,
        wide?: false,
        detail: nil,
        target: nil
      }
    ]
  end

  defp unassigned_tile(0) do
    %{
      key: "unassigned",
      label: "Unassigned trips",
      count: 0,
      value: 0,
      tone: :success,
      icon: "hero-check-circle",
      action?: false,
      wide?: false,
      detail: nil,
      target: nil
    }
  end

  defp unassigned_tile(count) do
    %{
      key: "unassigned",
      label: "Unassigned trips",
      count: count,
      value: count,
      tone: :info,
      icon: "hero-inbox",
      action?: true,
      wide?: false,
      detail: nil,
      target: "unassigned"
    }
  end

  defp problems_tile(0) do
    %{
      key: "problems",
      label: "Problems",
      count: 0,
      value: 0,
      tone: :success,
      icon: "hero-check-circle",
      action?: true,
      wide?: false,
      detail: nil,
      target: "problems"
    }
  end

  defp problems_tile(count) do
    %{
      key: "problems",
      label: "Problems",
      count: count,
      value: count,
      tone: :error,
      icon: "hero-exclamation-triangle",
      action?: true,
      wide?: false,
      detail: nil,
      target: "problems"
    }
  end

  # The three plan figures the Plan summary owns. Each keeps its own key so its
  # button is a stable DOM id, and all three open the Plan summary. The minimum is
  # the day's lower bound and the peak is the day's own, so both are the whole
  # service day's whatever the workspace is showing.
  defp figure_tiles(figures, peak) do
    [
      %{
        key: "vehicles",
        label: "Vehicles",
        count: figures.vehicles,
        value: figures.vehicles,
        tone: :neutral,
        icon: nil,
        action?: true,
        wide?: false,
        detail: "· minimum #{figures.minimum}",
        target: "plan_summary"
      },
      %{
        key: "riders",
        label: "Time with riders",
        count: figures.riders,
        value: "#{figures.riders}%",
        tone: :neutral,
        icon: nil,
        action?: true,
        wide?: false,
        detail: nil,
        target: "plan_summary"
      },
      %{
        key: "peak",
        label: "Peak out",
        count: peak.count,
        value: peak.count,
        tone: :neutral,
        icon: nil,
        action?: true,
        wide?: false,
        detail: peak_detail(peak),
        target: "plan_summary"
      }
    ]
  end

  defp peak_detail(%{at_secs: nil}), do: "none timed"
  defp peak_detail(peak), do: "at #{clock(peak.at_secs)}"

  # The Peak out figure's definition, printed in the Plan summary: what it counts
  # and what it leaves out.
  defp peak_note(%{at_secs: nil}), do: "No block has timed trips, so there is no peak."

  defp peak_note(peak) do
    "Peak out is the most blocks in progress at once: #{peak.count} at #{clock(peak.at_secs)}. " <>
      "It leaves out " <>
      count_label(peak.excluded_unassigned, "unassigned trip", "unassigned trips") <>
      " and " <>
      count_label(peak.excluded_frequency, "repeating trip", "repeating trips") <> "."
  end

  # One sentence per short fleet row, in the day's own row order: the typed row
  # before the garage total, so a garage short on both reads as two checks
  # rather than one repeated line.
  defp shortfall_summary(shortfalls) do
    Enum.map_join(shortfalls, " ", fn row ->
      "#{row.garage} · #{row.type}: needs #{row.needed} at #{clock(row.at_secs)}, " <>
        "#{row.listed} listed."
    end)
  end

  defp count_label(1, singular, _plural), do: "1 #{singular}"
  defp count_label(count, _singular, plural), do: "#{count} #{plural}"

  # The chart's text equivalent and its caption. The bars are one garage · type's
  # vehicles out per 15-minute bin, so the label names that row and its listing
  # rather than the whole service day, and the sentence under the chart repeats the
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

  # The Time and distance rows. `drive_secs` and `deadhead_km` come from estimated
  # driving times unless every pair on the day has been entered, so those two rows
  # carry the `est.` mark while any pair is still an estimate.
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

  # A date inside its month's group: the weekday and the day of the month.
  defp short_date(date), do: Calendar.strftime(date, "%a %-d")

  # The kind of message a finding's severity draws.
  defp severity_status(:error), do: "error"
  defp severity_status(:warning), do: "warning"
  defp severity_status(:notice), do: "info"

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

  defp code_meta(:cannot_reach), do: %{label: "Can't reach", tone: :error, icon: "hero-x-circle"}
  defp code_meta(:type_mismatch), do: %{label: "Wrong type", tone: :error, icon: "hero-x-circle"}

  defp code_meta(:fleet_shortfall),
    do: %{label: "Not enough vehicles", tone: :error, icon: "hero-x-circle"}

  defp code_meta(:too_long),
    do: %{label: "Too long", tone: :warning, icon: "hero-exclamation-triangle"}

  defp code_meta(:no_relief_opportunity),
    do: %{label: "No operator change", tone: :warning, icon: "hero-exclamation-triangle"}

  defp code_meta(:interlining_not_allowed),
    do: %{label: "Route switch", tone: :warning, icon: "hero-exclamation-triangle"}

  defp code_meta(:block_attributes_conflict),
    do: %{label: "Garage differs", tone: :warning, icon: "hero-exclamation-triangle"}

  defp code_label(code), do: code_meta(code).label

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

  defp finding_detail(%{code: :repositions, detail: %{meters: nil} = detail}) do
    "The vehicle drives empty with #{minutes(detail.gap_secs)} available. " <>
      "The driving time is unknown."
  end

  defp finding_detail(%{code: :repositions, detail: detail}) do
    "The vehicle drives empty about #{distance_label(detail.meters)} with " <>
      "#{minutes(detail.gap_secs)} available."
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

  # A stale record is the only one no block can reach, so it is the only one
  # that offers its own removal (AC-21).
  defp stale_entry?({:stale, _reason}), do: true
  defp stale_entry?(_state), do: false

  # Each listed record's row is its own id, so the removal button and the dialog
  # that returns focus to it address one record rather than the list.
  defp transfer_entry_id(id), do: "trip-transfer-" <> id

  defp remove_record_button_id(id), do: "remove-record-" <> id

  # The removal question's copy, built from the record the editor asked about.
  # The dialog is always rendered, so a nil record has to read as an empty
  # question rather than raise.
  defp remove_record_copy(nil), do: %{title: "", body: "", return_focus_id: nil}

  defp remove_record_copy(entry) do
    row = entry.row

    %{
      title: "Remove the record for trip #{row.from_trip_id} → #{row.to_trip_id}?",
      body:
        "Deletes one in-seat transfer record (#{remove_record_setting(row.transfer_type)}). " <>
          "Trips and blocks don't change. The deletion is audited.",
      return_focus_id: remove_record_button_id(row.id)
    }
  end

  defp remove_record_setting(4), do: "riders stay on board"
  defp remove_record_setting(_type), do: "riders must get off and board again"

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

  # The axis prints a tick every two hours, from
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
    span_geometry(%{start_secs: trip.first_departure, end_secs: trip.last_arrival}, axis)
  end

  # A short layover is a fixed-width chip centred on the wait it marks, so it stays
  # legible however brief the wait; every other wait spans its own minutes. A wait
  # starts after the drive that precedes it, when the vehicle has one.
  defp gap_geometry(gap, previous, axis, drive_secs, true) do
    {start, span} = axis_geometry(axis)
    wait_start = previous.last_arrival + (drive_secs || 0)
    center = wait_start - start + div(previous.last_arrival + gap.gap_secs - wait_start, 2)

    "left: #{percent(center, span)}%; width: 18px; transform: translateX(-50%)"
  end

  defp gap_geometry(gap, previous, axis, drive_secs, false) do
    span_geometry(
      %{
        start_secs: previous.last_arrival + (drive_secs || 0),
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

  # The gaps whose wait an operator change can happen in, as the block's relief
  # windows name them. With no relief limit set there is no piece of work to hand over, so no
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

  # A row's connection is named by its two trip UUIDs joined by a bar, the same
  # name `Blocking.Connections` gives it, so the timeline and the drawer cannot
  # disagree about which record a gap is showing. A row with no gap, or a gap the
  # day's derivation holds nothing for, is undecided rather than an error.
  defp gap_connection(settings, row) do
    case row.gap do
      nil -> nil
      gap -> Map.get(settings, "#{row.previous.id}|#{gap.to_id}")
    end
  end

  defp gap_setting(settings, row) do
    case gap_connection(settings, row) do
      %{setting: setting} -> setting
      _undecided -> :none
    end
  end

  defp gap_review?(settings, row) do
    case gap_connection(settings, row) do
      %{review?: review?} -> review?
      _undecided -> false
    end
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

  # Kilometres to one decimal, the unit the page copy uses. A
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

  # A gap's hover text: how long it is and what kind of handoff it is.
  defp gap_hover(%{handoff: {:moves, _}} = gap),
    do: "#{minutes(gap.gap_secs)} gap · deadhead, the vehicle drives empty"

  defp gap_hover(%{handoff: :same_stop} = gap), do: "#{minutes(gap.gap_secs)} gap · same stop"

  defp gap_hover(%{handoff: :same_station} = gap),
    do: "#{minutes(gap.gap_secs)} gap · same station"

  defp gap_hover(%{handoff: {:nearby, meters}} = gap),
    do: "#{minutes(gap.gap_secs)} gap · nearby stop, #{meters} m"

  # A decided gap's title names the decision beside the gap's own handoff text,
  # so the chip's icon is never the only thing that says what it means.
  defp gap_title(gap, nil), do: gap_hover(gap)
  defp gap_title(gap, label), do: "#{gap_hover(gap)} · #{label}"

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

  # --- the assignment form and the review --------------------------

  # The picker's status line: how many of the service day's block IDs the search
  # matched, and whether the 25-entry cap cut the list.
  defp destination_summary(options, total) do
    count = length(options)

    if count < total do
      "#{count} of #{total} matching blocks · refine your search"
    else
      "#{count} matching blocks"
    end
  end

  # An ineligible trip is named with its own reason rather than silently dropped.
  # The selection scope gets its own message and one line per trip,
  # because a bulk selection can hold several reasons at once.
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

  # The confirm button repeats the verb and its object.
  defp confirm_label(%{command: {:attributes, _block, _garage, _type}}),
    do: "Save block settings"

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
  defp cancel_label(%{command: {:attributes, _block, _garage, _type}}), do: "Change settings"
  defp cancel_label(_review), do: "Change block"

  # An attribute save moves no trip, so the dialog names what it does write and
  # the affected calendars rather than a table of assignments that would be empty.
  defp attributes?(%{command: {:attributes, _block, _garage, _type}}), do: true
  defp attributes?(_review), do: false

  defp effect_sentence(_effect, %{command: {:attributes, _block, _garage, _type}}) do
    "The block's garage and type are saved here and apply to every calendar it runs on."
  end

  # A plan's effects are read in the panel and in the dialog together, and a plan
  # moves trips between blocks rather than to or from one target, so it says what
  # it does in its own words rather than borrowing the block command's sentence.
  defp effect_sentence(effect, %{command: {:plan, _mode}}) do
    count = length(effect.changed_trip_ids)

    "#{count} #{if count == 1, do: "trip changes", else: "trips change"} block."
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
  # URL-safe Base64 as the block rows, never the raw ID.
  defp dom_token(id), do: Base.url_encode64(id, padding: false)
end
