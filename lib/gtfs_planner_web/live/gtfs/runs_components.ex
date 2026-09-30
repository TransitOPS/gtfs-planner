defmodule GtfsPlannerWeb.Gtfs.RunsComponents do
  @moduledoc """
  The Runs page's shell: the head, the scope bar and the load-state panels.

  Everything here is the page's *frame* rather than its content. A later step
  adds the plan, the drawers and the editors into the same frame, so this module
  owns only what the reader sees before there is anything to read: which day
  type is selected, and what the page says when it has nothing to show.

  The composition follows `.specs/08-basic-runs/references/runs-prototype.html`
  at `?state=loading`, `no-blocks` and `load-error`: a head of H1 plus subtitle
  and actions, a scope bar carrying the day-type select beside the date summary,
  and a card holding either the state panel or — from step 22 — the plan.

  The state panels deliberately mirror `BlocksComponents.page_state/1`. The two
  pages are siblings under the Operations bar and reach the same five states
  from the same read, so two vocabularies for the same condition would be a
  cost with no benefit. The copy differs, because the two pages send the reader
  somewhere different when there is nothing to show.
  """

  use GtfsPlannerWeb, :html

  # The page's own `count_strip/1` is the card's name for this surface, and it
  # *builds* the house strip rather than being it. The import is narrowed rather
  # than the function renamed, so `CoreComponents.count_strip/1` is reached by a
  # qualified call and the wrapper keeps the name the spec records.
  import GtfsPlannerWeb.CoreComponents, except: [count_strip: 1]

  alias GtfsPlannerWeb.CoreComponents
  alias GtfsPlannerWeb.Gtfs.BlocksComponents
  alias GtfsPlannerWeb.Components.RouteIdentity

  # The select's marker for "a run of its own". Run IDs are one to eight
  # letters, digits or hyphens, so no real run can carry this value and the
  # marker can never be confused with a run the page is offering.
  @new_run_option "__new"

  @doc """
  Renders the page head: the H1, the subtitle and any head actions.

  The subtitle is the definition a reader needs before the table: a run is one
  operator's day, made of one or two pieces of vehicle work plus report,
  travel, breaks and sign-off. Actions arrive through a slot, and a shell with
  no actions yet renders none — an empty action strip would be a control that
  cannot do anything, and a disabled placeholder would be worse.
  """
  slot :actions

  def page_head(assigns) do
    ~H"""
    <div
      class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between"
      data-role="runs-head"
    >
      <div class="min-w-0">
        <.header>
          Runs
          <:subtitle>
            A run is one operator's day: one or two pieces of vehicle work, with
            report, travel, breaks and sign-off.
          </:subtitle>
        </.header>
      </div>
      <div :if={@actions != []} id="runs-head-actions" class="flex flex-wrap gap-2">
        {render_slot(@actions)}
      </div>
    </div>
    """
  end

  @doc """
  Renders the scope bar: the day-type select, the selected day's date summary
  and the crew-rules summary beside it.

  The select is `BlocksComponents.day_select/1` unchanged. Reusing it is not
  cosmetic: a reader who has learned the Blocks day-type control is already
  holding the knowledge this one asks for, and a second control that looks
  almost the same but is not the same would be worse than either.
  """
  attr :day_types, :list, required: true
  attr :selected, :string, required: true
  attr :disabled, :boolean, default: false

  slot :date_summary
  slot :crew_summary
  slot :counts

  def scope_bar(assigns) do
    ~H"""
    <section
      id="runs-scope"
      aria-label="Day type and crew rules"
      class="rounded-card border border-subtle bg-white"
    >
      <div class="flex flex-wrap items-end gap-x-5 gap-y-3 px-4 py-4 sm:px-5">
        <form id="runs-day-form" phx-change="select_day">
          <BlocksComponents.day_select
            id="runs-day"
            day_types={@day_types}
            selected={@selected}
            disabled={@disabled}
          />
        </form>

        <p id="runs-day-dates" class="min-h-11 content-center text-sm text-base-content/70">
          {if @date_summary == [],
            do: date_summary_text(@day_types, @selected),
            else: render_slot(@date_summary)}
        </p>

        <div :if={@crew_summary != []} class="ml-auto">
          {render_slot(@crew_summary)}
        </div>
      </div>

      <div
        :if={@counts != []}
        id="runs-scope-counts"
        class="border-t border-subtle px-4 py-3 sm:px-5"
      >
        {render_slot(@counts)}
      </div>
    </section>
    """
  end

  # The date summary reads the selected day type's own figures, so the bar can
  # never claim a day type's dates the read did not return. A day type that is
  # not in the list — an unknown `?day=` — falls back to the "choose one" line
  # rather than rendering an empty gap.
  defp date_summary_text(day_types, selected) do
    case Enum.find(day_types, &(&1.key == selected)) do
      nil -> "Choose a day type to see its service dates."
      day_type -> "#{day_type.label} · #{day_type.date_count} service dates"
    end
  end

  @doc """
  Renders one load state.

  `:loading` is skeleton rows, not a spinner: the shape the plan will take is
  already known, so a skeleton of that shape means the page does not jump when
  the rows arrive. `:unavailable` is a callout rather than a panel, because it is
  not a state the page is in — it is a failure to leave the state it was in, and
  the runs already on screen stay there.
  """
  attr :kind, :atom, required: true
  attr :version_id, :any, default: nil
  attr :day_types, :list, default: []

  # The four states that have a panel. `:loaded` and `:unavailable` are states
  # the page can BE in without a panel here, and the reason is worth stating
  # rather than filling in with an empty box:
  #
  #   * `:unavailable` is presented by `unavailable_callout/0` ABOVE the
  #     content, because a failed reload does not replace the runs the reader is
  #     already looking at. A panel here would be a second, competing surface
  #     for one condition.
  #   * `:loaded` has nothing to put in a card until the plan exists. Rendering
  #     an empty bordered card would read as a failure to load, which is the one
  #     impression this page must never give. The shell therefore renders no
  #     plan card in that state and the plan step fills the same card in.
  #
  # The catch-all is a deliberate guard, not a fallback: it fails loudly naming
  # the states this function handles, so a later step adding a sixth state is
  # told what to do rather than getting a bare FunctionClauseError.
  def page_state(%{kind: kind} = assigns)
      when kind not in [:loaded, :unavailable] do
    render_state_panel(assigns, kind)
  end

  def page_state(%{kind: kind}) do
    raise ArgumentError,
          "RunsComponents.page_state/1 has no panel for #{inspect(kind)}. " <>
            "It renders :loading, :no_dates, :empty and :unknown; :loaded is " <>
            "presented by the plan card and :unavailable by unavailable_callout/0."
  end

  defp render_state_panel(assigns, :loading) do
    ~H"""
    <div id="runs-loading" role="status" aria-live="polite">
      <.skeleton id="runs-skeleton" label="Loading runs…">
        <div class="space-y-2">
          <div class="h-6 w-40 bg-base-300"></div>
          <div :for={_row <- 1..6} class="h-11 w-full bg-base-300"></div>
        </div>
      </.skeleton>
    </div>
    """
  end

  defp render_state_panel(assigns, :no_dates) do
    ~H"""
    <div id="runs-no-dates">
      <.empty_state title="No calendar in this version has a service date.">
        Add the days a calendar runs, then group the trips on those dates into each
        vehicle's work before cutting them into runs.
        <:action>
          <.link
            id="runs-no-dates-link"
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

  defp render_state_panel(assigns, :empty) do
    ~H"""
    <div id="runs-empty">
      <.empty_state title="No blocks to cut into runs">
        Group trips into blocks first. Runs split each vehicle's work between
        operators, so there is nothing to cut until a block exists.
        <:action>
          <.link
            id="runs-empty-link"
            navigate={~p"/gtfs/#{@version_id}/blocks"}
            class="btn btn-primary"
          >
            Go to Blocks
          </.link>
        </:action>
      </.empty_state>
    </div>
    """
  end

  defp render_state_panel(assigns, :unknown) do
    ~H"""
    <div id="runs-unknown-day">
      <.empty_state title="Choose a day type">
        This day type no longer matches the calendars. No day type is applied for you and
        nothing has changed.
        <:action>
          <form id="runs-unknown-day-form" phx-submit="select_day" class="mx-auto max-w-sm">
            <BlocksComponents.day_select id="runs-unknown-day-select" day_types={@day_types} />
            <button type="submit" class="btn btn-primary mt-3">Show selected day</button>
          </form>
        </:action>
      </.empty_state>
    </div>
    """
  end

  @doc """
  Renders the callout shown when a reload failed while runs are already on
  screen.

  This is deliberately not a `page_state/1` panel. A panel replaces the content;
  the runs the reader was looking at are still correct, and the failure is about
  the *next* read, not the current one. So the callout sits above the content,
  the content stays, and retry re-runs the same read with the same URL.
  """
  def unavailable_callout(assigns) do
    ~H"""
    <.callout id="runs-unavailable" kind="error" title="Runs couldn't load.">
      You're seeing the runs that loaded before; nothing has changed.
      <button
        id="runs-retry"
        type="button"
        phx-click="retry"
        class="link link-primary min-h-11"
      >
        Try again
      </button>
    </.callout>
    """
  end

  @doc """
  Renders the plan card. From step 22 this holds the count strip's drawer and
  from this step the duty chart; before either it holds the state panel, so the
  page has a card of the right shape throughout.
  """
  attr :version_id, :any, default: nil
  slot :inner_block

  def plan_card(assigns) do
    ~H"""
    <section
      id="runs-plan"
      aria-label="Runs"
      class="overflow-clip rounded-card border border-subtle bg-white"
    >
      {render_slot(@inner_block)}
    </section>
    """
  end

  @doc """
  Renders the note under the plan, which is a scope statement rather than
  decoration: it says what this page does not change.
  """
  def page_footnote(assigns) do
    ~H"""
    <p id="runs-footnote" class="text-sm text-base-content/70">
      Runs change operator work only. Public trips and vehicle blocks stay as they are.
      Runs appear in the GTFS + operations (TODS) export as <code>run_events.txt</code>.
    </p>
    """
  end

  # ── The count strip ────────────────────────────────────────────────────────

  @doc """
  Renders the day type's count strip: what the runs cost, in one row of tiles.

  Every figure is read out of `derived.stats` — the numbers this page shows are
  the ones the read derived, not a second arithmetic pass over the runs. That is
  the whole reason the strip exists as a component and not as a template: if
  the strip computed a share of its own it would be a second source of truth for
  a figure the plan also shows, and the two would eventually disagree.

  The tiles are `CoreComponents.count_strip/1` in button mode. The house
  component carries the focus ring, the `aria-pressed` state and the argument
  checking, so this module supplies only the figures and their words.

  The prototype opens the *summary* drawer from every tile. This does the same,
  including the Uncovered work tile: the summary drawer's Time section carries
  that work, so the destination really does answer the question. The prototype
  switches to the Uncovered work **tab** there, which step 27 owns; until then
  the drawer is where a reader sees those figures.
  """
  attr :stats, :map, required: true
  attr :spread_limit_minutes, :integer, required: true
  attr :selected_key, :string, default: nil

  def count_strip(assigns) do
    ~H"""
    <CoreComponents.count_strip
      id="runs-count-strip"
      items={count_items(@stats, @spread_limit_minutes)}
      event="open_drawer"
      selected_key={@selected_key}
    />
    """
  end

  @doc """
  Renders the count strip's shape while the day is still loading.

  A skeleton of the strip rather than nothing, so the scope bar does not grow a
  row into existence under the reader: ux-states' "skeletons mirror the final
  layout", and the strip is a row of tiles of a known width.
  """
  def count_strip_skeleton(assigns) do
    ~H"""
    <div id="runs-count-strip-skeleton" class="flex flex-wrap items-center gap-2">
      <.skeleton :for={_tile <- 1..5} class="h-11 w-48 rounded-control">
        <div class="h-4 w-36 bg-base-300"></div>
      </.skeleton>
    </div>
    """
  end

  # One item per tile, in the prototype's order. `count` is the figure the tile
  # reports, because `CoreComponents.count_strip/1` reads it to decide the
  # figure's tone and to mark a zero unavailable — so for a tile whose value is
  # a formatted string, `:value` carries the string and `:count` stays the
  # number behind it, which is also what a test reads.
  defp count_items(stats, spread_limit_minutes) do
    spread = stats.longest_spread
    spread_secs = spread && spread.secs
    over_limit? = spread_secs != nil and spread_secs > spread_limit_minutes * 60
    uncovered = stats.uncovered

    [
      %{
        key: "runs",
        label: "Runs",
        count: stats.runs,
        detail:
          "· #{stats.by_type.straight} straight · #{stats.by_type.split} split · #{stats.by_type.one_piece} one piece",
        tone: :neutral
      },
      %{
        key: "straight_share",
        label: "Straight share",
        count: stats.straight_share || 0,
        value: percent(stats.straight_share),
        disabled_reason: no_share_reason(stats),
        tone: :neutral
      },
      %{
        key: "paid_hours",
        label: "Paid hours",
        count: stats.paid_secs,
        value: "#{hours(stats.paid_secs)} h",
        tone: :neutral
      },
      %{
        key: "on_vehicles",
        label: "Time on vehicles",
        count: stats.vehicle_share || 0,
        value: percent(stats.vehicle_share),
        detail: "of paid time",
        tone: :neutral
      },
      %{
        key: "longest_spread",
        label: "Longest spread",
        count: spread_secs || 0,
        value: if(spread, do: hm(spread.secs), else: "—"),
        detail: spread_detail(spread, spread_limit_minutes),
        tone: if(over_limit?, do: :warning, else: :neutral)
      },
      %{
        key: "uncovered",
        label: "Uncovered work",
        count: uncovered.trips,
        value: if(uncovered.trips > 0, do: "#{uncovered.trips} trips", else: "None"),
        detail: if(uncovered.trips > 0, do: duration(uncovered.secs), else: nil),
        tone: if(uncovered.trips > 0, do: :warning, else: :neutral)
      }
    ]
  end

  # A dash is the honest answer here, and the two reasons it is a dash are
  # different, so the strip says which. "No runs" and "no run had a choice" are
  # not the same condition, and a reader deciding whether to suggest runs needs
  # to tell them apart.
  defp no_share_reason(%{runs: 0}), do: "No runs in this day type"
  defp no_share_reason(_stats), do: "No run had a choice of straight or split"

  defp spread_detail(nil, _limit), do: nil

  defp spread_detail(spread, limit),
    do: "run #{spread.run_id} · limit #{Integer.to_string(div(limit, 60))}:#{pad(rem(limit, 60))}"

  # ── The summary drawer ─────────────────────────────────────────────────────

  @doc """
  Renders the Runs summary drawer.

  Two kinds of content with two different provenances, deliberately kept apart:

    * the day type's own figures and the crew rules **in use** come from the
      `runs_day` the page has already loaded, so they are on screen the moment
      the drawer opens and they cannot disagree with the strip above it;
    * the straight share of **every** day type comes from
      `Gtfs.run_day_type_shares/2`, which is a whole-version read and the reason
      this content is loaded with `start_async` rather than with the page.

  So the drawer opens instantly and one slow query cannot hold the strip hostage.
  The share table is the one part that has a loading line and an error line,
  because it is the one part whose absence the reader cannot infer from the
  drawer being open.
  """
  attr :open?, :boolean, default: false
  attr :stats, :map, required: true
  attr :crew, :map, required: true
  attr :max_piece_minutes, :integer, default: nil
  attr :relief_stop_ids, :list, default: []
  attr :day_label, :string, required: true
  attr :day_type_key, :string, default: nil
  attr :shares_state, :atom, default: :loading
  attr :shares, :list, default: []

  def summary_drawer(assigns) do
    ~H"""
    <.drawer
      id="runs-summary-drawer"
      open={@open?}
      on_close="close_drawer"
      title="Runs summary"
      return_focus_id="runs-count-strip-item-runs"
    >
      <p id="runs-summary-drawer-subtitle" class="text-sm text-base-content/70">
        {@day_label}
      </p>

      <h3 id="runs-summary-types" class="mt-2 text-base font-bold">Runs by type</h3>
      <div id="runs-summary-type-rows" class="mt-2">
        <.summary_row id="runs-summary-straight" label="Straight" value={@stats.by_type.straight} />
        <.summary_row id="runs-summary-split" label="Split" value={@stats.by_type.split} />
        <.summary_row id="runs-summary-one-piece" label="One piece" value={@stats.by_type.one_piece} />
      </div>

      <h3 id="runs-summary-share-heading" class="mt-6 text-base font-bold">Straight share</h3>
      <p class="mt-1 text-[13px] text-base-content/70">
        Straight runs as a share of straight and split runs. Contracts often set a minimum,
        such as 60% on weekdays.
      </p>

      <div id="runs-share-table-region" class="mt-2">
        <p :if={@shares_state == :loading} id="runs-share-loading" class="text-sm" role="status">
          Loading every day type's share…
        </p>

        <p :if={@shares_state == :failed} id="runs-share-error" class="text-sm text-error">
          The share for every day type could not load. This day type's own figures are above.
        </p>

        <table
          :if={@shares_state == :loaded}
          id="runs-share-table"
          class="table table-sm w-full border-separate border-spacing-0 text-sm"
        >
          <caption class="sr-only">Straight share by day type</caption>
          <thead>
            <tr>
              <th scope="col">Day type</th>
              <th scope="col" class="text-right">Straight</th>
              <th scope="col" class="text-right">Split</th>
              <th scope="col" class="text-right">Share</th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={share <- @shares}
              id={"runs-share-row-#{share.day_type_key}"}
              data-selected={to_string(share.day_type_key == @day_type_key)}
              class={share.day_type_key == @day_type_key && "bg-primary/10"}
            >
              <th scope="row" class="text-left font-semibold">{share.label}</th>
              <td class="tabular-nums text-right">{share.straight}</td>
              <td class="tabular-nums text-right">{share.split}</td>
              <td class="tabular-nums text-right" data-role="share-value">
                {percent(share.share)}
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <h3 id="runs-summary-time-heading" class="mt-6 text-base font-bold">Time</h3>
      <div id="runs-summary-time-rows" class="mt-2">
        <.summary_row
          id="runs-summary-paid"
          label="Paid hours"
          value={"#{hours(@stats.paid_secs)} h"}
        />
        <.summary_row
          id="runs-summary-on-vehicles"
          label="Time on vehicles"
          value={percent(@stats.vehicle_share)}
          note="Share of paid time spent on vehicles. Report, travel, sign-off and paid breaks make up the rest."
        />
        <.summary_row
          id="runs-summary-spread"
          label="Longest spread"
          value={if @stats.longest_spread, do: hm(@stats.longest_spread.secs), else: "—"}
          note={spread_note(@stats.longest_spread, @crew.max_spread_minutes)}
        />
        <.summary_row
          id="runs-summary-uncovered"
          label="Uncovered work"
          value={uncovered_value(@stats.uncovered)}
          note={uncovered_note(@stats.uncovered)}
        />
      </div>

      <h3 id="runs-summary-rules-heading" class="mt-6 text-base font-bold">Rules in use</h3>
      <dl id="runs-summary-rules" class="mt-2 grid grid-cols-[180px_1fr] gap-x-4 gap-y-1.5 text-sm">
        <.rule id="runs-rule-max-piece" label="Longest piece" value={piece_limit(@max_piece_minutes)} />
        <.rule
          id="runs-rule-relief-points"
          label="Relief points"
          value={relief_points(@relief_stop_ids)}
        />
        <.rule
          id="runs-rule-report"
          label="Report"
          value={
            "#{@crew.report_pull_out_minutes} min before a pull-out, #{@crew.report_relief_minutes} min before a relief"
          }
        />
        <.rule id="runs-rule-sign-off" label="Sign-off" value={"#{@crew.sign_off_minutes} min"} />
        <.rule
          id="runs-rule-paid-break"
          label="Paid break"
          value={"#{@crew.paid_break_max_minutes} min or less"}
        />
        <.rule
          id="runs-rule-spread"
          label="Longest spread"
          value={duration(@crew.max_spread_minutes * 60)}
        />
      </dl>
    </.drawer>
    """
  end

  # A label above a right-aligned figure, with an optional quiet line beneath.
  # `tabular-nums` on the figure is what keeps a column of these from shifting
  # as its digits change between renders.
  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :note, :string, default: nil

  defp summary_row(assigns) do
    ~H"""
    <div id={@id} class="border-b border-subtle py-2 text-sm">
      <div class="flex items-baseline justify-between gap-4">
        <span class="text-base-content/70">{@label}</span>
        <span data-role="value" class="tabular-nums text-right font-semibold text-base-content">
          {@value}
        </span>
      </div>
      <p :if={@note} class="mt-0.5 text-[13px] text-base-content/70">{@note}</p>
    </div>
    """
  end

  # A definition list, so the rules are read as label → value pairs and a
  # screen reader announces the label with its value rather than a table header
  # that belongs to a table which is not there.
  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true

  defp rule(assigns) do
    ~H"""
    <dt id={@id} class="text-base-content/70">{@label}</dt>
    <dd data-role="value">{@value}</dd>
    """
  end

  # `hrs(n) = (n / 60).toFixed(1)` in the prototype, and n there is MINUTES. Every
  # figure reaching this module is in SECONDS, so the conversion is /3600 here —
  # dividing by 60 alone prints hours as if they were minutes, which reads as
  # "1205.0 h" for a day whose paid time is twenty hours.
  defp hours(secs) when is_integer(secs) do
    :erlang.float_to_binary(secs / 3600, decimals: 1)
  end

  defp percent(nil), do: "—"
  defp percent(value) when is_integer(value), do: "#{value}%"

  # "11:43" — hours and minutes, which is how a spread is read off a clock rather
  # than as a count of seconds.
  defp hm(secs) when is_integer(secs) do
    minutes = div(secs, 60)
    "#{div(minutes, 60)}:#{pad(rem(minutes, 60))}"
  end

  # Whole hours, then minutes only when there are some, so exactly two hours
  # reads "2 h" rather than "2 h 0 min".
  defp duration(secs) when is_integer(secs) do
    minutes = div(secs, 60)

    if rem(minutes, 60) == 0,
      do: "#{div(minutes, 60)} h",
      else: "#{div(minutes, 60)} h #{rem(minutes, 60)} min"
  end

  defp piece_limit(nil), do: "Not set"
  defp piece_limit(minutes), do: duration(minutes * 60)

  # The count, because a reader deciding whether relief is set up needs the
  # number; the names beside it, because a count alone cannot be checked against
  # the Blocks page where the marks are made.
  defp relief_points([]), do: "None marked"
  defp relief_points(ids), do: "#{length(ids)} marked · #{Enum.join(ids, ", ")}"

  defp spread_note(nil, _limit), do: nil

  defp spread_note(spread, limit),
    do: "Run #{spread.run_id} · limit #{Integer.to_string(div(limit, 60))}:#{pad(rem(limit, 60))}"

  defp uncovered_value(%{trips: 0}), do: "None"
  defp uncovered_value(%{trips: trips}), do: "#{trips} trips"

  defp uncovered_note(%{trips: 0}), do: nil

  defp uncovered_note(%{trips: _trips, secs: secs}),
    do: "#{duration(secs)} on vehicles with no operator"

  defp pad(minutes) when minutes < 10, do: "0" <> Integer.to_string(minutes)
  defp pad(minutes), do: Integer.to_string(minutes)

  # ── The duty chart ─────────────────────────────────────────────────────────

  @tick_secs 7200
  @axis_label_max_percent 92.0
  @min_track_span_secs 60

  @doc """
  Renders the duty chart: one 44 px row per run, its seven fact columns and its
  track of piece bars against the service-day axis.

  The structure is `BlocksComponents.timeline/1`'s, deliberately: a fixed-layout
  table, a `colgroup` of named widths, a sticky header row above sticky fact
  columns, a percentage-positioned track and a two-hourly axis. The two charts
  are siblings under the Operations bar and a reader scrolling one has already
  learned the other's behaviour, so a second set of rules for what is the same
  idea would be a cost with no benefit.

  The differences are the day's, not the idea's: **runs** are the row's identity
  rather than blocks, there are **seven** fact columns to Blocks' six, the rows
  are **44 px** rather than 36 because a run is a person and a block is not, and
  the row carries a **track of pieces** rather than a block's sequence of trips
  and gaps.

  The Status cell carries this run's finding COUNT and not its status text: the
  icon-plus-words wording belongs to step 24, and a cell with nothing in it is
  the one thing a table row must never be. A count is honest in the meantime and
  cannot be contradicted by the words that replace it.

  `aria-sort` is on every header whether or not it is the sorted one, so the
  sort state never appears or disappears between renders — the same rule
  `CoreComponents.count_strip/1` follows for `aria-pressed`.
  """
  attr :run_rows, :any, required: true
  attr :axis, :map, default: nil
  attr :routes, :map, required: true
  attr :sort, :atom, required: true
  attr :dir, :atom, required: true
  attr :scale, :atom, required: true
  attr :crew, :map, default: nil

  def timeline(assigns) do
    assigns =
      assigns
      |> assign(:columns, sort_columns())
      |> assign(:ticks, axis_ticks(assigns.axis))
      |> assign(:track_style, track_style(assigns.axis))

    ~H"""
    <div id="runs-timeline-scroll" phx-hook=".RunsRovingRow">
      <table
        id="runs-timeline"
        data-scale={@scale}
        aria-label="Runs by service-day time"
      >
        <colgroup>
          <col class="runs-col-run" />
          <col class="runs-col-type" />
          <col class="runs-col-on" />
          <col class="runs-col-off" />
          <col class="runs-col-spread" />
          <col class="runs-col-paid" />
          <col class="runs-col-status" />
          <col />
        </colgroup>
        <thead>
          <tr>
            <th
              :for={column <- @columns}
              scope="col"
              aria-sort={aria_sort(@sort, @dir, column.key)}
              class={["runs-meta", "runs-meta-#{column.key}"]}
            >
              <button
                type="button"
                phx-click="sort"
                phx-value-key={column.key}
                class="runs-sort"
              >
                {column.label}
                <span :if={Atom.to_string(@sort) == column.key} aria-hidden="true">
                  {sort_arrow(@dir)}
                </span>
              </button>
            </th>
            <th scope="col" class="runs-axis">
              <span class="runs-axis-inner">
                <span :for={tick <- @ticks} class="runs-axis-tick" style={tick.style}>
                  {tick.label}
                </span>
              </span>
            </th>
          </tr>
        </thead>
        <tbody id="runs-timeline-body" phx-update="stream">
          <.run_row
            :for={{dom_id, %{run: run}} <- @run_rows}
            dom={dom_id}
            run={run}
            axis={@axis}
            routes={@routes}
            track_style={@track_style}
          />
        </tbody>
      </table>
    </div>

    <.timeline_footnote paid_break_minutes={paid_break_minutes(@crew)} />

    <script :type={Phoenix.LiveView.ColocatedHook} name=".RunsRovingRow">
      // A run row's pieces are ONE tab stop, not one tab stop each.
      //
      // The server owns the tabindex, so a row that has never been focused and a
      // row whose focus has moved look the same in the initial HTML; this hook
      // only moves focus and re-points the roving tabindex when a key arrives.
      // That split is deliberate: if the client owned the tabindex, a row would
      // arrive with no tab stop at all and be unreachable by keyboard.
      export default {
        mounted() {
          this.handleKeydown = e => this.move(e)
          this.el.addEventListener("keydown", this.handleKeydown)
        },
        destroyed() {
          this.el.removeEventListener("keydown", this.handleKeydown)
        },
        // Only the four keys a roving row owns. Everything else is left alone,
        // so Tab still leaves the row, Enter still activates the bar, and a
        // reader's own browser shortcuts keep working.
        move(e) {
          const keys = ["ArrowRight", "ArrowLeft", "Home", "End"]
          if (!keys.includes(e.key)) return

          const el = e.target.closest?.(".runs-piece")
          if (!el || !this.el.contains(el)) return

          // One row, its pieces in document order. `closest("tr")` is the row,
          // and a run's pieces are the only piece bars inside it.
          const row = Array.from(el.closest("tr").querySelectorAll(".runs-piece"))
          const index = row.indexOf(el)
          if (index < 0) return

          const last = row.length - 1
          // Clamped rather than wrapped: Right on the last piece and Left on the
          // first stay where they are. Wrapping would make a reader who overshot
          // believe they had changed row.
          const to = {
            ArrowRight: Math.min(index + 1, last),
            ArrowLeft: Math.max(index - 1, 0),
            Home: 0,
            End: last
          }[e.key]

          e.preventDefault()
          row.forEach((bar, i) => { bar.tabIndex = i === to ? 0 : -1 })
          row[to].focus()
        }
      };
    </script>
    """
  end

  @doc """
  Renders the two-part footnote under the chart: how the keyboard works, and how
  paid time is measured.

  The roving hint is visible words rather than a tooltip or a hidden label,
  because a keyboard rule a reader has to discover is a rule most readers never
  find. It sits under the table it describes, in the same muted type as the rest
  of the footnote, so it reads as an aside about the chart rather than as a
  control.
  """
  attr :paid_break_minutes, :any, required: true

  def timeline_footnote(assigns) do
    ~H"""
    <div
      id="runs-timeline-foot"
      class="flex flex-wrap items-center justify-between gap-3 border-t border-base-300 px-5 py-3 text-[13px] text-base-content/70"
    >
      <span id="roving-hint">
        Each row&rsquo;s pieces are one Tab stop. Left and Right move between pieces; Home and
        End jump to the first and last. Enter opens the run.
      </span>
      <span id="paid-time-note">
        Travel marked &ldquo;est.&rdquo; is estimated from garage-to-stop driving times. Paid
        time = report (per piece) + time on vehicles + travel + breaks of {@paid_break_minutes} min
        or less + sign-off.
      </span>
    </div>
    """
  end

  # The footnote quotes the version's OWN paid-break limit rather than the
  # design default, because a break's hatching already says the same thing and
  # the sentence must not be able to disagree with it. A version with no limit
  # read is shown as an em dash rather than as a number nobody set.
  defp paid_break_minutes(nil), do: "—"
  defp paid_break_minutes(%{paid_break_max_minutes: nil}), do: "—"
  defp paid_break_minutes(%{paid_break_max_minutes: minutes}), do: minutes

  @doc """
  Renders one 44 px run row: the sticky Run, Type, Sign-on, Sign-off, Spread,
  Paid and Status cells and the track of the run's piece bars.

  Sign-on and Sign-off are `BlocksComponents.clock/1`, so a run that signs off
  after midnight reads `01:30 +1d` rather than a bare `01:30` that would look
  like it had signed on before it started. Spread and Paid are hours and
  minutes, matching how the summary drawer prints the same two figures — a
  chart that formatted them differently from the drawer would make the two
  disagree about the same number.

  The track holds the run's **pieces** and nothing else at this step: the
  report, travel, break and sign-off marks between them, and the chart key that
  explains them, are step 24's. The piece bars are already positioned by the
  day's own axis, so a run that signs on at 05:00 and signs off at 14:00 puts
  its bars where the axis says they belong.
  """
  attr :dom, :string, required: true
  attr :run, :map, required: true
  attr :axis, :map, default: nil
  attr :routes, :map, required: true
  attr :track_style, :string, default: nil

  def run_row(assigns) do
    assigns =
      assign(assigns, :marks, marks(assigns.run.work.segments, assigns.axis))

    ~H"""
    <tr
      id={@dom}
      data-run={@run.run_id}
      data-type={@run.work.type}
      class="runs-row"
    >
      <.run_facts run={@run} variant={:timeline} />
      <td class="runs-track" style={@track_style}>
        <span class="runs-lane">
          <.segment_mark :for={mark <- @marks} mark={mark} />
          <.piece_bar
            :for={piece <- @run.pieces}
            run={@run}
            piece={piece}
            index={index_of(@run.pieces, piece)}
            axis={@axis}
            route={Map.get(@routes, piece.route_id) || %{}}
            severity={piece_severity(piece, @run.findings, index_of(@run.pieces, piece))}
          />
        </span>
      </td>
    </tr>
    """
  end

  @doc """
  Renders the Runs List view: the same runs, the same figures and the same sort,
  as a table a reader can scan and compare rather than a chart a reader reads
  positionally.

  The list is for the questions a timeline cannot answer well. "Which runs are
  over an hour's spread?" is three seconds of arithmetic in a table and a
  hunt through a chart; "when do these two runs overlap?" is the reverse. Neither
  view is the real one and both are one sort state, so switching between them
  never loses the order the reader chose.

  `docs/design/table-row-design.md` governs this table and the timeline is not
  exempt from it: numbers right and tabular, text left, terse headers, full-row
  hover, a link-looking Run, and **no vertical gridlines** — the separators are
  horizontal because a grid here would put eight lines between every two numbers
  a reader is meant to compare.

  The seven fact cells are `run_facts/1`, shared with the timeline, so the two
  views cannot disagree about the same run. The eighth column, Pieces, is the
  list's own and carries what the track draws as position: block, span and where
  the piece starts and ends. The row's Run cell is a `<th scope="row">`, the way
  the reference has it, so a screen reader announces the row by its run rather
  than by seven bare cells.
  """
  attr :run_rows, :any, required: true
  attr :sort, :atom, required: true
  attr :dir, :atom, required: true
  attr :day_label, :string, default: "this day"

  def list(assigns) do
    ~H"""
    <div
      id="runs-list-scroll"
      class="overflow-auto"
      style="max-height: var(--runs-timeline-max-height)"
    >
      <table id="runs-list" class="w-full border-separate border-spacing-0 text-sm">
        <caption class="sr-only">Runs for {@day_label}</caption>
        <thead>
          <tr>
            <th
              :for={column <- list_columns(@sort)}
              scope="col"
              aria-sort={aria_sort(@sort, @dir, column.key)}
              class="runs-list-th"
            >
              <button type="button" phx-click="sort" phx-value-key={column.key} class="runs-sort">
                {column.label}
                <span :if={Atom.to_string(@sort) == column.key} aria-hidden="true">
                  {sort_arrow(@dir)}
                </span>
              </button>
            </th>
          </tr>
        </thead>
        <tbody id="runs-list-body" phx-update="stream">
          <tr
            :for={{dom_id, %{run: run}} <- @run_rows}
            id={dom_id}
            data-run={run.run_id}
            data-type={run.work.type}
            class="runs-list-row"
          >
            <.run_facts run={run} variant={:list} />
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  # The timeline's seven columns plus Pieces, in the reference's order: Pieces
  # sits third, between Type and Sign-on, because a piece is what a run IS and
  # the clock is only when it happens.
  defp list_columns(_sort) do
    (sort_columns() ++ [%{key: "pieces", label: "Pieces"}])
    |> Enum.sort_by(&column_order/1)
  end

  defp column_order(%{key: "id"}), do: 0
  defp column_order(%{key: "type"}), do: 1
  defp column_order(%{key: "pieces"}), do: 2
  defp column_order(%{key: "sign_on"}), do: 3
  defp column_order(%{key: "sign_off"}), do: 4
  defp column_order(%{key: "spread"}), do: 5
  defp column_order(%{key: "paid"}), do: 6
  defp column_order(%{key: "status"}), do: 7

  # One piece in the list's own words: block, then the span it occupies, then
  # where it starts and ends.
  #
  # The card specifies `B <block> <start>–<end>`, which is what this prints. The
  # reference says `Block <n> · <start>–<end> · <from> → <to>`; the difference is
  # recorded rather than quietly resolved, because the card is the gate and the
  # reader gains nothing from the longer spelling in a column this narrow. The
  # places are not dropped — they are on the piece's `title`, and step 29's drawer
  # carries them in full.
  defp piece_line(piece) do
    "B #{piece.block_id} #{BlocksComponents.clock(piece.start_secs)}–#{BlocksComponents.clock(piece.end_secs)}"
  end

  @doc """
  Renders the run drawer: one run, in the order a reader asks about it.

  **Problems, then pieces, then paid time, then the rule.** A reader who opens a
  run's drawer is usually asking one of two questions — is this run sound, and
  what am I being paid for — and the order answers them in that order. Problems
  first because a run with an error above it should not be read past.

  ## Why the pay table adds up

  The drawer's whole claim is that a reader can see where the Paid figure in the
  run's row came from. So the lines are **the run's own `work.segments`, one line
  each**, and not a fixed set of kinds with totals looked up beside them. That is
  what makes the sum a fact rather than a coincidence: `work.paid_secs` is
  computed from those same segments, so a line added to the work without a kind
  the table knows about would show up as a gap in the sum instead of passing
  unnoticed.

  ## Why an unpaid break has no value

  A break of 5 h 35 min that is not paid has two true numbers and the table can
  only hold one. Printing the length in the value column would say the run was
  paid for it; printing "0 min" would say the break did not happen. So the length
  goes in the **label** — "Break, unpaid (5 h 35 min)" — and the value cell is
  **empty**, which is the only cell that can mean "nothing, and here is why".

  A break the operator cannot reach is drawn the same way. A negative span is not
  a duration; it is a finding, and step 24 already has words for it.
  """
  attr :run, :map, required: true
  attr :day_type_key, :string, required: true
  attr :version_id, :string, required: true
  attr :crew, :map, required: true
  attr :stop_names, :map, default: %{}
  attr :open?, :boolean, default: false
  attr :on_close, :string, default: "close_drawer"
  attr :return_focus_id, :string, default: "runs-page"
  attr :rename_form, :any, required: true
  # A list, not a form field's errors: see the `errors=` attribute below.
  attr :rename_errors, :list, default: []
  # `{label, value}` options for the per-piece move select, and the number the
  # "New run" option will actually use. The page builds both from the day's runs;
  # the drawer only decides which value means "a run of its own".
  attr :move_form, :any, required: true
  attr :move_runs, :list, default: []
  # Block ID to that block's relief windows. A piece cannot answer "where could
  # this split" on its own, so the drawer is handed its blocks' windows.
  attr :piece_windows, :map, default: %{}
  attr :next_run_id, :string, default: "1"
  attr :split_form, :any, required: true

  def run_drawer(assigns) do
    ~H"""
    <.drawer
      id="run-drawer"
      open={@open?}
      on_close={@on_close}
      title={"Run #{@run.run_id}"}
      return_focus_id={@return_focus_id}
    >
      <p id="run-drawer-summary" class="text-sm text-base-content/70">
        {run_type_label(@run.work.type)} &middot; {length(@run.pieces)} {if length(@run.pieces) == 1,
          do: "piece",
          else: "pieces"} &middot; {duration(@run.work.spread_secs)} spread &middot; {duration(
          @run.work.paid_secs
        )} paid
      </p>

      <div id="run-drawer-findings" class="mt-3">
        <p
          :if={@run.findings == []}
          data-role="run-no-problems"
          class="flex items-center gap-1.5 text-sm text-success"
        >
          No problems
        </p>
        <ul :if={@run.findings != []} class="grid gap-2">
          <li
            :for={finding <- @run.findings}
            data-role="run-finding"
            data-code={finding.code}
            data-severity={finding.severity}
            class="border-l-4 border-warning bg-warning/10 px-4 py-3"
          >
            <p class="flex items-center gap-1.5 text-sm">
              <span class={[severity_class(finding.severity), "flex items-center gap-1.5"]}>
                <.icon name={severity_icon(finding.severity)} class="size-4" />
                {finding_label(finding)}
              </span>
            </p>
            <p :if={finding_detail(finding)} class="mt-0.5 text-sm text-base-content/70">
              {finding_detail(finding)}
            </p>
          </li>
        </ul>
      </div>

      <h3 class="mt-5 text-base font-bold">Pieces</h3>
      <div id="run-drawer-pieces" class="mt-2">
        <table id="run-drawer-pieces-table" class="w-full border-separate border-spacing-0 text-sm">
          <caption class="sr-only">Pieces of run {@run.run_id}</caption>
          <thead>
            <tr>
              <th scope="col" class="runs-uncovered-th">Piece</th>
              <th scope="col" class="runs-uncovered-th">Block</th>
              <th scope="col" class="runs-uncovered-th">Time</th>
              <th scope="col" class="runs-uncovered-th">From &rarr; to</th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={{piece, index} <- Enum.with_index(@run.pieces, 1)}
              data-role="run-piece"
              data-piece={index}
              data-block={piece.block_id}
              data-start={piece.start_secs}
              data-end={piece.end_secs}
              class="runs-uncovered-row"
            >
              <td class="runs-uncovered-td tabular-nums" data-role="piece-number">{index}</td>
              <td class="runs-uncovered-td" data-role="piece-block">
                <.link
                  href={
                    "/gtfs/#{@version_id}/blocks?day=#{@day_type_key}&block=#{piece.block_id}"
                  }
                  data-role="piece-block-link"
                  data-block={piece.block_id}
                  class="min-h-11 font-semibold text-action underline underline-offset-4"
                >
                  Block {piece.block_id}
                </.link>
                <div class="text-[13px] text-base-content/70">
                  Route {piece.route_id} &middot; {length(piece.trips)} trips
                </div>
              </td>
              <td class="runs-uncovered-td tabular-nums" data-role="piece-time">
                {BlocksComponents.clock(piece.start_secs)}&ndash;{BlocksComponents.clock(
                  piece.end_secs
                )}
                <div class="text-[13px] text-base-content/70">
                  {duration(piece.end_secs - piece.start_secs)}
                </div>
              </td>
              <td class="runs-uncovered-td" data-role="piece-places">
                {piece_place(@stop_names, piece.start_stop, piece.start_kind)}
                <br />&rarr; {piece_place(@stop_names, piece.end_stop, piece.end_kind)}
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <h3 class="mt-5 text-base font-bold">Paid time</h3>
      <.pay_table work={@run.work} pieces={@run.pieces} crew={@crew} />

      <p id="run-drawer-rule" data-role="run-rule" class="mt-2 text-[13px] text-base-content/70">
        {crew_rule_sentence(@crew)}
      </p>

      <h3 class="mt-5 text-base font-bold">Move a piece to another run</h3>
      <p class="mt-1 text-sm text-base-content/70">
        Only the trips in the piece you choose move. Everything else on this run stays.
      </p>

      <div :for={{piece, index} <- Enum.with_index(@run.pieces, 1)} class="mt-4">
        <fieldset class="rounded-card border border-base-300 px-4 pb-4 pt-2">
          <legend class="px-1 text-[13px] font-semibold text-base-content">
            Piece {index} &middot; block {piece.block_id}
          </legend>
          <.form
            for={@move_form}
            id={"run-move-piece-form-#{index}"}
            novalidate
            phx-submit="move_piece"
            action="#run-drawer"
          >
            <%!-- The piece is named by POSITION, because that is what the
                  fieldset above says. The trips come from the drawer's own piece
                  list, never from a `trip_id` a form could tamper with. --%>
            <input type="hidden" name="piece" value={index} />
            <div class="grid grid-cols-1 items-end gap-3 sm:grid-cols-[1fr_auto]">
              <div>
                <.input
                  field={@move_form[:to]}
                  id={"run-move-to-#{index}"}
                  type="select"
                  label="Move piece to run"
                  prompt="Choose a run"
                  options={move_options(@move_runs, @next_run_id)}
                  errors={[]}
                />
              </div>
              <.button type="submit" phx-disable-with="Moving…" class="min-h-11">
                Move piece
              </.button>
            </div>
          </.form>

          <div class="mt-4">
            <h4 class="text-[13px] font-semibold text-base-content">Split at a relief point</h4>

            <p
              :if={split_points(piece, @piece_windows) == []}
              class="mt-1 text-sm text-base-content/70"
            >
              No relief point inside this piece.
            </p>

            <.form
              :if={split_points(piece, @piece_windows) != []}
              for={@split_form}
              id={"run-split-piece-form-#{index}"}
              novalidate
              phx-submit="split_piece"
              action="#run-drawer"
            >
              <input type="hidden" name="piece" value={index} />
              <div class="mt-2 grid gap-3 sm:grid-cols-2">
                <div>
                  <.input
                    field={@split_form[:gap]}
                    id={"run-split-at-#{index}"}
                    type="select"
                    label="Split at relief window"
                    prompt="Choose a relief point"
                    options={split_options(piece, @piece_windows, @stop_names)}
                    errors={[]}
                  />
                </div>
                <div>
                  <.input
                    field={@split_form[:to]}
                    id={"run-split-to-#{index}"}
                    type="select"
                    label="Later trips go to"
                    prompt="Choose a run"
                    options={move_options(@move_runs, @next_run_id)}
                    errors={[]}
                  />
                </div>
              </div>
              <.button type="submit" phx-disable-with="Splitting…" class="mt-3 min-h-11">
                Split piece
              </.button>
            </.form>
          </div>
        </fieldset>
      </div>

      <h3 class="mt-5 text-base font-bold">Rename this run</h3>
      <.form for={@rename_form} id="run-rename-form" novalidate phx-submit="rename_run" class="mt-2">
        <p class="text-sm text-base-content/70">
          Every trip on this run moves to the new ID. Nothing else changes.
        </p>
        <p :if={@rename_errors != []} data-role="rename-error-summary" class="sr-only">
          This run could not be renamed.
        </p>
        <div class="mt-3 grid gap-3 sm:grid-cols-[minmax(0,14rem)_auto] sm:items-start">
          <div>
            <%!-- `errors` is passed EXPLICITLY because `CoreComponents.input/1`
                  reads its own `@errors` attribute and never looks at
                  `field.errors`. A form that carries a changeset and forgets
                  this attribute renders a field with an error in it that no
                  reader can see: `aria-invalid` stays "false", the error node
                  is absent, and the submit appears to do nothing at all. --%>
            <.input
              field={@rename_form[:run_id]}
              id="run-name"
              type="text"
              label="New run ID"
              help="One to eight letters, digits or hyphens."
              value={@rename_form[:run_id].value || @run.run_id}
              errors={@rename_errors}
            />
          </div>
          <.button type="submit" phx-disable-with="Renaming…" class="min-h-11">
            Rename run
          </.button>
        </div>
      </.form>
    </.drawer>
    """
  end

  @doc """
  Renders one run's paid time as its own lines, and the total they add to.

  Every line is one segment of `work.segments`, so the lines ARE the work rather
  than a restatement of it. `data-paid` marks the cells that count toward the
  total, which is what lets a reader — and the gate — add them up without
  re-deriving which kinds are paid.
  """
  attr :work, :map, required: true
  attr :pieces, :list, default: []
  attr :crew, :map, default: %{}

  def pay_table(assigns) do
    ~H"""
    <table id="run-pay-table" class="mt-2 w-full border-separate border-spacing-0 text-sm">
      <caption class="sr-only">Paid time for this run</caption>
      <tbody>
        <tr
          :for={{segment, index} <- Enum.with_index(@work.segments, 0)}
          data-role="pay-line"
          data-kind={segment.kind}
          data-index={index}
          data-paid={to_string(segment.paid? and segment.end_secs >= segment.start_secs)}
          data-secs={segment.end_secs - segment.start_secs}
          class="runs-uncovered-row"
        >
          <td class="runs-uncovered-td" data-role="pay-label">
            {pay_label(segment, @pieces)}
            <span
              :if={
                segment.kind == :break and not segment.paid? and
                  segment.end_secs >= segment.start_secs
              }
              data-role="pay-unpaid-length"
              class="text-base-content/70"
            >
              ({duration(segment.end_secs - segment.start_secs)})
            </span>
          </td>
          <td
            class="runs-uncovered-td text-right tabular-nums"
            data-role="pay-value"
            data-paid={to_string(segment.paid? and segment.end_secs >= segment.start_secs)}
          >
            <span :if={segment.paid? and segment.end_secs >= segment.start_secs}>
              {duration(segment.end_secs - segment.start_secs)}
            </span>
          </td>
        </tr>
        <tr class="runs-uncovered-row">
          <th scope="row" class="runs-uncovered-td font-bold" data-role="pay-total-label">
            Paid
          </th>
          <td
            class="runs-uncovered-td text-right tabular-nums font-bold"
            data-role="pay-total"
            data-secs={@work.paid_secs}
          >
            {duration(@work.paid_secs)}
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  # One label per kind, and the two that need to know which piece they belong to.
  #
  # A report is "before piece N", and whether it is a PULL-OUT or a RELIEF comes
  # from that piece's own `start_kind` — not from the report segment, which
  # carries no place at all. Reading the two as interchangeable is how a run
  # would claim 15 minutes of report before a change of operator when the crew
  # rules say 5.
  defp pay_label(%{kind: :report, piece_index: index}, pieces) do
    kind = piece_start_kind(pieces, index)
    "Report before piece #{index} (#{kind})"
  end

  defp pay_label(%{kind: :piece, piece_index: index}, _pieces), do: "Piece #{index}"
  defp pay_label(%{kind: :travel}, _pieces), do: "Travel"
  defp pay_label(%{kind: :sign_off}, _pieces), do: "Sign-off"
  defp pay_label(%{kind: :break}, _pieces), do: "Break"
  defp pay_label(%{kind: kind}, _pieces), do: to_string(kind)

  defp piece_start_kind(pieces, index) do
    case Enum.at(pieces, (index || 1) - 1) do
      %{start_kind: :block_start} -> "pull-out"
      %{start_kind: :relief} -> "relief"
      _other -> "relief"
    end
  end

  # The crew rules in words, so a reader can check the arithmetic above it
  # without opening the crew drawer.
  #
  # Every number is the version's OWN, and a rule nobody set says so rather than
  # reading "0 min" — which would be a claim about a limit of zero rather than
  # about no limit.
  defp crew_rule_sentence(crew) do
    "Paid time = report (#{crew.report_pull_out_minutes} min before each pull-out, " <>
      "#{crew.report_relief_minutes} min before each relief) + time on vehicles + travel + " <>
      "a break of #{crew.paid_break_max_minutes} minutes or less + sign-off " <>
      "(#{crew.sign_off_minutes} min)."
  end

  defp run_type_label(:split), do: "Split"
  defp run_type_label(:straight), do: "Straight"
  defp run_type_label(:one_piece), do: "One piece"

  # A place, with the kind of boundary it is, because a change of operator at a
  # relief is not the same place-change as a garage move and the reader is being
  # told where a run may be interrupted.
  # The select's options, "New run (N)" first because that is the prototype's
  # order, followed by the day's runs. The value `"__new"` is a MARKER, not an
  # ID: run IDs are one to eight letters, digits or hyphens, so a run could
  # never be called `__new`, and the marker cannot collide with a real run.
  # A KEYWORD list of `label: value`, which is what `options_for_select/2` reads.
  # A list of `{label, value}` tuples renders each pair's whole text as BOTH the
  # label and the value, so every option posts its own sentence as a run ID and
  # the move fails as an unusable run ID.
  # A FLAT list of `{label, value}` pairs — the shape `options_for_select/2`
  # reads, which renders `value="1002"` for `{"Run 1002 ...", "1002"}`.
  #
  # Nesting each pair in its own list, `[{"Run 1002 ...", "1002"}]`, is the shape
  # that fails, and it fails LOUDLY on the way past: "expected :key key when
  # building <option> from keyword list". The other failing shape is a keyword
  # list of string keys, which renders each option's whole label as its VALUE —
  # so the list looks right on screen and every option posts its own sentence as
  # a run ID.
  # The piece's internal gaps that HAVE a relief window, in order.
  #
  # Only the FIRST window of each gap is offered, because that is the handover:
  # `Relief.windows/3` returns a gap's `:origin` window before its `:destination`
  # one and the origin is the earlier of the two instants (the rule `Runs.Pieces`
  # already states). Offering both would offer two instants for one handover,
  # and the later one is not where the operator changes.
  #
  # A gap with no window at all is not offered. That is not a missing feature:
  # the handover then happens where the incoming trip ends rather than at a
  # marked relief point, and a piece can only be split where the operator can
  # actually change over.
  defp split_points(piece, _piece_windows) when length(piece.trips) < 2, do: []

  defp split_points(piece, piece_windows) do
    # `@piece_windows` is a MAP of block ID to that block's windows, so the
    # piece's own block is selected here. Enumerating the map instead — which
    # yields `{block_id, windows}` tuples — reaches `first_window/2` with tuples
    # where it expects windows, and every piece raises BadMapError.
    windows = Map.get(piece_windows, piece.block_id, [])

    # A piece's `gaps` also carries the gap that forms its own START boundary.
    # That one is not a place the piece can be split — the piece already starts
    # there, and splitting at it would move every trip and leave nothing behind.
    # Only the gaps BETWEEN two of the piece's trips are offered, which is what
    # "internal" means in the card's wording.
    piece.gaps
    |> Enum.with_index(1)
    |> Enum.filter(fn {_gap, position} -> position < length(piece.trips) end)
    |> Enum.flat_map(fn {gap, position} ->
      case first_window(windows, gap.index) do
        nil -> []
        window -> [%{position: position, gap: gap, window: window}]
      end
    end)
  end

  defp first_window(windows, gap_index) do
    windows
    |> Enum.filter(&(&1.gap_index == gap_index))
    |> List.first()
  end

  # "<time> at <stop> (after <trip>)": when the handover is, where, and which
  # trip the reader would be splitting after.
  defp split_options(piece, windows, stop_names) do
    piece
    |> split_points(windows)
    |> Enum.map(fn %{position: position, window: window} ->
      {split_option_text(piece, position, window, stop_names), to_string(position)}
    end)
  end

  defp split_option_text(piece, position, window, stop_names) do
    stop = Map.get(stop_names, window.stop_id) || window.stop_id
    after_trip = Enum.at(piece.trips, position - 1)

    "#{BlocksComponents.clock(window.start_secs)} at #{stop} (after #{trip_id(after_trip)})"
  end

  defp trip_id(nil), do: "the end of this piece"
  defp trip_id(trip), do: trip.id

  defp move_options(runs, next_run_id) do
    [{"New run (#{next_run_id})", @new_run_option} | Enum.map(runs, &move_option/1)]
  end

  # "Run 1002 · one piece · 06:00–14:00": which run, what shape, and when — the
  # three things that let a reader tell two runs apart without opening either.
  defp move_option(run) do
    {move_option_text(run), run.run_id}
  end

  defp move_option_text(run) do
    "Run #{run.run_id} · #{run_type_label(run.work.type)} · " <>
      BlocksComponents.clock(run.work.sign_on_secs) <>
      "–" <> BlocksComponents.clock(run.work.sign_off_secs)
  end

  defp piece_place(_stop_names, nil, _kind), do: "Unknown stop"

  defp piece_place(stop_names, %{stop_id: stop_id}, kind) do
    [
      Map.get(stop_names, stop_id) || stop_id,
      kind == :relief && "(relief point)"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp finding_detail(%{code: :piece_too_long, detail: %{secs: secs, limit_secs: limit}}) do
    "#{duration(secs)} against a limit of #{duration(limit)}."
  end

  defp finding_detail(%{code: :spread_too_long, detail: %{secs: secs, limit_secs: limit}}) do
    "#{duration(secs)} spread against a limit of #{duration(limit)}."
  end

  defp finding_detail(_finding), do: nil

  @doc """
  Renders the `Runs · N | Uncovered work · N` tabs.

  The counts are in the labels because the second tab's whole purpose is to say
  how much work is outside any run: a tab called "Uncovered work" with nothing
  after it makes the reader open it to find out, and a count they can see is one
  fewer click for the answer.

  `role="tablist"` with `aria-selected` on the pressed tab, and the selected tab
  is also the one carrying `aria-current`, so the state is not carried by colour
  alone. An amber dot on the uncovered tab when it is non-zero is the same
  information without the words, for a reader scanning the strip.
  """
  attr :panel, :atom, required: true, values: [:runs, :uncovered]
  attr :run_count, :integer, required: true
  attr :uncovered_trips, :integer, required: true
  attr :uncovered_segments, :integer, required: true

  def tabs(assigns) do
    ~H"""
    <div role="tablist" aria-label="Runs sections" class="flex flex-wrap items-center gap-1">
      <button
        :for={{key, atom, label, count} <- tab_items(@run_count, @uncovered_trips)}
        type="button"
        role="tab"
        id={"runs-tab-#{key}"}
        phx-click="set_panel"
        phx-value-panel={key}
        aria-selected={to_string(@panel == atom)}
        aria-current={@panel == atom && "page"}
        data-role="panel-tab"
        data-panel={key}
        data-count={count}
        class={[
          "min-h-11 rounded-r-control px-3 text-sm font-semibold",
          @panel == atom && "bg-secondary/15 text-primary",
          @panel != atom && "text-base-content/70 hover:bg-base-200"
        ]}
      >
        {label}
        <span
          :if={key == "uncovered" and @uncovered_segments > 0}
          data-role="uncovered-dot"
          aria-hidden="true"
        >
          ●
        </span>
      </button>
    </div>
    """
  end

  # `key` and `atom` are carried together on purpose. The `phx-value-panel` and
  # the `id` are strings because the DOM is; `@panel` is an atom because it came
  # out of the URL through `panel_value/1`. Comparing one to the other is the
  # `:day != "day"` trap step 26 recorded, and it is SILENT here: `aria-selected`
  # reads "false" on both tabs and the pressed tab is styled as unpressed, with
  # no error anywhere. The dot and the count still work, so the tab looks
  # plausible and the one thing the tablist exists to say is missing.
  defp tab_items(run_count, uncovered_trips) do
    [
      {"runs", :runs, "Runs · #{run_count}", run_count},
      {"uncovered", :uncovered, "Uncovered work · #{uncovered_trips}", uncovered_trips}
    ]
  end

  @doc """
  Renders the amber callout that says work is outside every run.

  It sits UNDER the count strip rather than above the page, because it is a
  reading of the numbers the reader is already looking at: the count strip says
  how many trips are uncovered, and this says what that costs in vehicle hours
  and offers the way through. Above the page it would be a banner about
  something the reader had not been introduced to.

  **It never blocks.** The Runs tab is the default panel, the callout names its
  own action, and a reader who ignores it is looking at a working page. Nothing
  on this page requires acting on it.

  The count is TRIPS, not segments: "4 trips are not in a run" is the number the
  count strip's own tile shows, so the two agree. A segment count would read as
  a different measurement of the same thing.
  """
  attr :segments, :list, required: true
  attr :duration_secs, :integer, required: true

  def uncovered_callout(assigns) do
    ~H"""
    <div :if={@segments != []} id="runs-uncovered-callout" class="mt-3">
      <.callout kind="warning" title={"#{uncovered_trip_count(@segments)} trips are not in a run."}>
        {duration(@duration_secs)} of vehicle work has no operator.
        <div class="mt-2">
          <button
            type="button"
            phx-click="set_panel"
            phx-value-panel="uncovered"
            data-role="review-uncovered"
            class="min-h-11 rounded-control border border-base-content/20 px-3 text-sm font-semibold hover:bg-base-200"
          >
            Review uncovered work
          </button>
        </div>
      </.callout>
    </div>
    """
  end

  defp uncovered_trip_count(segments) do
    Enum.reduce(segments, 0, &(length(&1.trips) + &2))
  end

  @doc """
  Renders the uncovered work table: the vehicle work on the chart that no run
  covers, one row per block segment.

  The point of the panel is the question "what is left?", and the columns answer
  it in the order a reader asks it: which block, how much work, when, between
  which places, and — the one the table exists for — **when the next operator
  could take it over**. A change of operator is only possible at a relief window,
  so a segment whose next window has already passed while another is an hour away
  is a different piece of work from one with a window in five minutes, and a
  table that showed only the times would make them look the same.

  Rows are ordered by block and then by start, the order the prototype uses, so
  two segments of one block read as a sequence rather than as two rows. A segment
  with no window left in its own span says so in words — "No relief point" —
  rather than leaving the cell empty, because an empty cell reads as a rendering
  fault and this is a real and consequential absence.

  The Create run button is present and **inert**: step 28 gives it its handler.
  It carries the segment's identity in `phx-value-*` so that step is a wiring
  change and not a markup change.
  """
  attr :segments, :list, required: true
  attr :windows, :map, required: true
  attr :routes, :map, default: %{}
  attr :stop_names, :map, default: %{}

  def uncovered(assigns) do
    ~H"""
    <div id="runs-uncovered">
      <div :if={@segments == []} id="runs-uncovered-empty" class="px-5 py-10 text-center">
        <p class="font-semibold">Every blocked trip is in a run.</p>
        <p class="mt-1 text-sm text-base-content/70">
          Trips that lose their run, or new blocks, appear here.
        </p>
      </div>

      <div :if={@segments != []} id="runs-uncovered-scroll" class="overflow-auto">
        <table id="runs-uncovered-table" class="w-full border-separate border-spacing-0 text-sm">
          <caption class="sr-only">Vehicle work with no operator, by block</caption>
          <thead>
            <tr>
              <th scope="col" class="runs-uncovered-th">Block</th>
              <th scope="col" class="runs-uncovered-th text-right">Trips</th>
              <th scope="col" class="runs-uncovered-th">Time</th>
              <th scope="col" class="runs-uncovered-th">From &rarr; to</th>
              <th scope="col" class="runs-uncovered-th">Next relief window</th>
              <th scope="col" class="runs-uncovered-th"><span class="sr-only">Action</span></th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={{segment, index} <- Enum.with_index(ordered_segments(@segments), 0)}
              id={"uncovered-#{index}"}
              data-role="uncovered-row"
              data-block={segment.block_id}
              data-start={segment.start_secs}
              data-end={segment.end_secs}
              data-trips={length(segment.trips)}
              class="runs-uncovered-row"
            >
              <th scope="row" class="runs-uncovered-td" data-role="uncovered-block">
                <span class="inline-flex items-center gap-2">
                  <span class="font-semibold">Block {segment.block_id}</span>
                  <span
                    :if={route_color(@routes, segment.route_id)}
                    data-role="uncovered-route"
                    data-route={segment.route_id}
                    class="inline-flex h-6 min-w-8 items-center justify-center rounded-badge px-1.5 text-[13px] font-bold text-white"
                    style={"background: #{route_color(@routes, segment.route_id)}"}
                  >
                    {segment.route_id}
                  </span>
                </span>
              </th>
              <td class="runs-uncovered-td text-right tabular-nums" data-role="uncovered-trips">
                {length(segment.trips)}
              </td>
              <td class="runs-uncovered-td tabular-nums" data-role="uncovered-time">
                {BlocksComponents.clock(segment.start_secs)}&ndash;{BlocksComponents.clock(
                  segment.end_secs
                )}
                <div class="text-[13px] text-base-content/70">
                  {duration(segment.end_secs - segment.start_secs)} on the vehicle
                </div>
              </td>
              <td class="runs-uncovered-td" data-role="uncovered-places">
                {place_name(@stop_names, segment.start_stop)} &rarr; {place_name(
                  @stop_names,
                  segment.end_stop
                )}
              </td>
              <td class="runs-uncovered-td" data-role="uncovered-relief">
                <.next_relief segment={segment} windows={@windows} stop_names={@stop_names} />
              </td>
              <td class="runs-uncovered-td text-right">
                <button
                  type="button"
                  phx-click="create_run"
                  phx-disable-with="Creating…"
                  phx-value-block={segment.block_id}
                  phx-value-start={segment.start_secs}
                  phx-value-end={segment.end_secs}
                  phx-value-index={index}
                  data-role="create-run"
                  data-block={segment.block_id}
                  title={"Create a run for block #{segment.block_id}, #{BlocksComponents.clock(segment.start_secs)}-#{BlocksComponents.clock(segment.end_secs)}"}
                  class="min-h-11 rounded-control border border-base-content/20 px-3 text-sm font-semibold hover:bg-base-200"
                >
                  Create run
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  # The next window a change of operator could happen in, or nothing.
  #
  # A window counts only if it is INSIDE this segment's own span: a relief point
  # before the work started or after it ended is not somewhere an operator can
  # pick this work up, and quoting one would be a number that cannot be acted on.
  #
  # Both figures are resolved ONCE here. The obvious inline alternative reads
  # `@windows` in the markup, and `@windows` is the whole `%{block_id => list}`
  # map — so `Enum.count` walks the MAP and hands the predicate a `{key, value}`
  # tuple, which fails on `&1.start_secs` and crashes the panel. Resolving the
  # block's own list into an assign is also the only way the "and N more" line
  # and the "Next relief" line cannot disagree about what they counted.
  attr :segment, :map, required: true
  attr :windows, :map, required: true
  attr :stop_names, :map, required: true

  defp next_relief(assigns) do
    block_windows = Map.get(assigns.windows, assigns.segment.block_id, [])

    in_span =
      Enum.filter(
        block_windows,
        &(&1.start_secs >= assigns.segment.start_secs and
            &1.start_secs <= assigns.segment.end_secs)
      )

    assigns =
      assigns
      |> assign(:next, Enum.min_by(in_span, & &1.start_secs, fn -> nil end))
      |> assign(:extra, max(length(in_span) - 1, 0))

    ~H"""
    <%= if @next do %>
      <span data-role="relief-window">
        Next relief {BlocksComponents.clock(@next.start_secs)} at {place_name(@stop_names, %{
          stop_id: @next.stop_id
        })}
        <div :if={@extra > 0} class="text-[13px] text-base-content/70">and {@extra} more</div>
      </span>
    <% else %>
      <span data-role="no-relief" class="text-base-content/70">No relief point</span>
    <% end %>
    """
  end

  # A segment's own places, in the version's own words. A stop the day does not
  # name falls back to its id rather than to a dash: the place is real even when
  # the page cannot spell it, and a dash would read as an absence.
  defp place_name(_stop_names, nil), do: "Unknown stop"
  defp place_name(stop_names, %{stop_id: stop_id}), do: Map.get(stop_names, stop_id) || stop_id

  defp route_color(routes, route_id) do
    case Map.get(routes, route_id) do
      %{color: color} when is_binary(color) and color != "" -> color
      _other -> nil
    end
  end

  # By block, then by start. Block is a number, so it is compared as one: a
  # string compare puts 109 before 11 and a reader would see their blocks out of
  # order with nothing to suggest why.
  defp ordered_segments(segments) do
    Enum.sort_by(segments, &{String.to_integer(&1.block_id), &1.start_secs})
  end

  @doc """
  Renders the toast: one line saying what just happened, and an Undo when the
  write can be taken back.

  **This component and its two assigns are the page's one undo surface**, and
  steps 30, 31, 32 and 37 all use them rather than building their own. A move, a
  split, a rename and a create all reach the same reader through the same box, so
  "where is the Undo" has one answer and the refusal message reads the same way
  whoever caused it.

  `:toast` is `%{text:, kind:, token:}` or nil; `:undo` is `%{moves:, trips:}` or
  nil. **Undo is not shown unless there is something to undo** — a toast that
  offers Undo with nothing behind it is a control that does nothing, which is the
  same objection step 26 raised about the scale control on the List and step 27
  raised about it on this panel.

  `data-token` carries the timer token. It is the one piece of internal state the
  DOM exposes, and it is there so the timer's contract can be TESTED: a stale
  timer is unobservable from the outside without it, and a test that cannot
  construct the stale case will not notice its guard being deleted. It renders
  as a string, because the DOM has no integers.

  `role="status"` with `aria-live="polite"`: the toast arrives while the reader is
  looking at the row they just edited, and it is an announcement, not a heading.
  The Undo button is inside the live region, so its arrival is announced too.

  It is `fixed` at the foot of the viewport because it is about the whole edit
  rather than about the row, and a reader who has scrolled to another block can
  still undo the change they made above.

  The dark surface is the reference's, and it is the only place on this page with
  an inverted treatment: a confirmation is not part of the page's reading order
  and should not look as though it is.
  """
  attr :toast, :map, default: nil
  attr :undo, :map, default: nil

  def toast(assigns) do
    ~H"""
    <div
      :if={@toast}
      id="runs-toast"
      role="status"
      aria-live="polite"
      data-role="runs-toast"
      data-kind={@toast.kind}
      data-token={@toast.token}
      class="fixed bottom-6 left-1/2 z-[60] flex max-w-[calc(100vw-2rem)] -translate-x-1/2 items-center gap-3 rounded-control bg-neutral px-[18px] py-2 text-sm text-neutral-content shadow-lg"
    >
      <span
        :if={@toast.kind == :refused}
        data-role="toast-icon"
        aria-hidden="true"
        class="inline-flex size-4 shrink-0 items-center justify-center"
      >
        !
      </span>
      <span
        :if={@toast.kind == :done}
        data-role="toast-icon"
        aria-hidden="true"
        class="inline-flex size-4 shrink-0 items-center justify-center"
      >
        &check;
      </span>
      <span id="runs-toast-text" data-role="toast-text">{@toast.text}</span>

      <button
        :if={@undo}
        id="runs-undo"
        type="button"
        phx-click="undo"
        data-role="undo"
        data-trips={@undo.trips}
        class="inline-flex min-h-11 items-center gap-1.5 rounded-control px-2 font-semibold underline underline-offset-4 hover:text-neutral-content/80"
      >
        Undo
      </button>

      <button
        type="button"
        phx-click="dismiss_toast"
        data-role="dismiss-toast"
        aria-label="Dismiss"
        class="inline-flex size-11 shrink-0 items-center justify-center rounded-control hover:text-neutral-content/80"
      >
        &times;
      </button>
    </div>
    """
  end

  @doc """
  Renders one run's seven fact cells: Run, Type, Sign-on, Sign-off, Spread, Paid
  and Status.

  **There is one implementation of these cells and both views call it.** The
  card asks for "the same values as the timeline", and a second copy of seven
  cells is seven chances to drift - the day a `BlocksComponents.clock/1` is
  swapped for a bare `fmt/1` on one view only, nothing would fail, and the two
  tables would quietly disagree about the same run.

  The list's eighth column, Pieces, is rendered HERE rather than passed in as a
  slot or appended by the caller. The POSITION is part of the contract — it is
  the third column, after Type — and a caller that supplied the cell could put it
  anywhere, which would leave the header naming one column and the cells in
  another. A test that counted columns would not notice; a reader would. So the
  component owns the whole column order for both views, and `list_columns/0`
  names the same order in the header.

  `variant` chooses the CLASSES and nothing else. The timeline's cells are sticky
  and sit at fixed offsets from the left of a scrolling track; the list's are
  ordinary cells in a table that scrolls once. The values, the `data-role` hooks
  and the Run button are identical, which is what lets a test compare the two
  views cell by cell.
  """
  attr :run, :map, required: true
  attr :variant, :atom, required: true, values: [:timeline, :list]

  def run_facts(assigns) do
    ~H"""
    <th scope="row" class={fact_class(@variant, "id")} data-role="run-id">
      <button
        type="button"
        phx-click="open_run"
        phx-value-run={@run.run_id}
        id={"runs-run-#{@run.run_id}"}
        class="runs-run-button"
        title={"Open run " <> @run.run_id}
      >
        {@run.run_id}
      </button>
    </th>
    <td class={fact_class(@variant, "type")} data-role="run-type">
      {type_label(@run.work.type)}
    </td>
    <.list_pieces :if={@variant == :list} run={@run} />
    <td class={fact_class(@variant, "on")} data-role="run-sign-on">
      {BlocksComponents.clock(@run.work.sign_on_secs)}
    </td>
    <td class={fact_class(@variant, "off")} data-role="run-sign-off">
      {BlocksComponents.clock(@run.work.sign_off_secs)}
    </td>
    <td class={fact_class(@variant, "spread")} data-role="run-spread">
      {hm(@run.work.spread_secs)}
    </td>
    <td class={fact_class(@variant, "paid")} data-role="run-paid">
      {hm(@run.work.paid_secs)}
    </td>
    <td class={fact_class(@variant, "status")}>
      <.status_cell findings={@run.findings} />
    </td>
    """
  end

  # The list's Pieces cell: one line per piece, `B <block> <start>–<end>`.
  #
  # One line per piece so a two-piece run is two lines and a reader can count them
  # without reading. The card specifies this spelling; the reference spells the
  # block out in full and adds the places, and the difference is recorded rather
  # than quietly resolved - the card is the gate, the column is narrow, and the
  # places are on the piece's `title` and in step 29's drawer.
  attr :run, :map, required: true

  defp list_pieces(assigns) do
    ~H"""
    <td class="runs-fact runs-fact-pieces" data-role="run-pieces">
      <div :for={{piece, index} <- Enum.with_index(@run.pieces, 1)} data-piece={index}>
        {piece_line(piece)}
      </div>
    </td>
    """
  end

  defp fact_class(:timeline, key), do: ["runs-meta", "runs-meta-#{key}"]
  defp fact_class(:list, key), do: ["runs-fact", "runs-fact-#{key}"]

  @doc """
  Renders one piece as a button positioned by the day's axis.

  The label is `B <block>` — block first, because a reader comparing a piece
  against the Blocks page is looking for the block, and the run number is
  already in the row's first column one cell away. The prototype falls back to
  the bare block number and then to no label at all when the bar is too narrow;
  that measuring needs a browser, so the full label is rendered here and the
  CSS clips it with `overflow: hidden`, which is the same outcome without the
  layout thrash. Step 24's marks can revisit it with a render in hand.

  The route colour is a **bottom rule** rather than the fill, so two pieces of
  different routes on one run are told apart at a glance while the fill stays
  the one colour the design system owns.

  **`tabindex` is rendered here, by the server, and not by the hook.** The
  roving rule needs a row to arrive with exactly one piece in the tab order, and
  a client that computed the tabindex on mount would leave every row with none
  until its hook ran — a row the reader cannot reach at all in the moment before
  JavaScript arrives. The server draws the first piece as `0` and the rest as
  `-1`, so the initial HTML is already correct and the hook only re-points it
  when a key moves focus. A one-piece run therefore has one `tabindex="0"` and
  no `-1` sibling, which is the whole point: the row is one stop whether it
  holds one piece or six.
  """
  attr :run, :map, required: true
  attr :piece, :map, required: true
  attr :index, :integer, required: true
  attr :axis, :map, default: nil
  attr :route, :map, default: nil
  attr :severity, :atom, default: nil

  def piece_bar(assigns) do
    assigns =
      assign(
        assigns,
        :style,
        join_style([piece_geometry(assigns.piece, assigns.axis), route_rule(assigns.route)])
      )

    ~H"""
    <button
      type="button"
      data-role="piece"
      data-piece={@index}
      data-block={@piece.block_id}
      phx-click="open_run"
      phx-value-run={@run.run_id}
      tabindex={if @index == 1, do: "0", else: "-1"}
      style={@style}
      class={["runs-piece", @severity && "runs-piece-#{@severity}"]}
      title={piece_title(@run, @piece, @index)}
    >
      <.boundary_mark :if={@piece.start_boundary} boundary={@piece.start_boundary} side={:in} />
      <span class="runs-piece-label">B {@piece.block_id}</span>
      <.boundary_mark :if={@piece.end_boundary} boundary={@piece.end_boundary} side={:out} />
    </button>
    """
  end

  defp piece_title(run, piece, index) do
    "Run #{run.run_id}, piece #{index}: block #{piece.block_id}, " <>
      "#{BlocksComponents.clock(piece.start_secs)} to #{BlocksComponents.clock(piece.end_secs)}"
  end

  # A piece's position and width as percentages of the same span the axis uses,
  # so the two align at any width and at either scale. Two decimals, matching
  # `BlocksComponents`, so a test can read the geometry out of the style.
  defp piece_geometry(piece, axis) do
    {start, span} = axis_geometry(axis)

    "left: #{percent(piece.start_secs - start, span)}%; " <>
      "width: #{percent(piece.end_secs - piece.start_secs, span)}%"
  end

  # The route's own colour as a bottom rule on the bar. The fill stays the one
  # colour the design system owns, so two pieces of different routes on one run
  # are told apart without two pieces of the same route looking like different
  # kinds of work.
  #
  # A route with no colour, or no route at all, gets NO rule rather than a
  # fallback one. A rule that is always drawn in the system's own grey is
  # indistinguishable from a route colour that happens to be grey, so a
  # fabricated default would be a claim about the route that is not true; the
  # piece's label and title still name the block, and step 24's marks are where
  # the route is made explicit.
  defp route_rule(nil), do: nil

  defp route_rule(%{} = route) do
    case RouteIdentity.normalize_hex(Map.get(route, :route_color)) do
      {:ok, hex} -> "box-shadow: inset 0 -4px 0 ##{hex};"
      :error -> nil
    end
  end

  defp sort_columns do
    [
      %{key: "id", label: "Run"},
      %{key: "type", label: "Type"},
      %{key: "sign_on", label: "Sign-on"},
      %{key: "sign_off", label: "Sign-off"},
      %{key: "spread", label: "Spread"},
      %{key: "paid", label: "Paid"},
      %{key: "status", label: "Status"}
    ]
  end

  defp aria_sort(sort, dir, key) do
    cond do
      Atom.to_string(sort) != key -> "none"
      dir == :asc -> "ascending"
      true -> "descending"
    end
  end

  defp sort_arrow(:asc), do: "↑"
  defp sort_arrow(_dir), do: "↓"

  defp type_label(:one_piece), do: "One piece"
  defp type_label(:straight), do: "Straight"
  defp type_label(:split), do: "Split"

  @doc """
  Renders the `⇄` or `!` at a piece edge where the operator changes.

  `⇄` means the change is where a plan says it may happen: a boundary the
  version marked as a relief point. `!` means it is not — the operator changed
  away from a relief point, which is rule 6's error and the reason the change is
  a problem at all. Both are on the piece that carries the edge, so the mark
  moves with the bar when the track is zoomed.
  """
  attr :boundary, :map, required: true
  attr :side, :atom, required: true, values: [:in, :out]

  def boundary_mark(assigns) do
    ~H"""
    <span
      data-role="boundary"
      data-at-relief={to_string(assigns.boundary.at_relief?)}
      data-side={@side}
      class={[
        "runs-boundary",
        @side == :out && "runs-boundary-out",
        if(assigns.boundary.at_relief?, do: "runs-boundary-relief", else: "runs-boundary-bad")
      ]}
      aria-hidden="true"
    >
      {if assigns.boundary.at_relief?, do: "⇄", else: "!"}
    </span>
    """
  end

  @doc """
  Renders one `WorkTime` segment as a mark on the track.

  The DOM `data-kind` is NOT the domain's `kind`, and deliberately: the domain
  has one `:break` where the chart has three, because a break the operator
  cannot take, a break they take unpaid and a break they are paid for are three
  different things to look at and one thing to compute. A negative span is
  `break-cant-reach` — the later piece starts before the earlier one ends, and
  the mark takes the earlier piece's real width rather than being hidden.

  Every mark carries a `title` in words, so nothing on the track is hover-only.
  The travel mark carries an `est.` label when its source is `:estimated`, and
  a `?` when the version could not answer the leg at all — an unmeasured
  stretch drawn as if it were known would be worse than a gap.
  """
  attr :mark, :map, required: true

  def segment_mark(assigns) do
    ~H"""
    <span
      data-role="mark"
      data-kind={@mark.kind}
      data-seg={@mark.segment}
      data-source={to_string(@mark.source)}
      style={@mark.style}
      class={["runs-mark", "runs-mark-#{@mark.kind}"]}
      title={@mark.title}
    >
      <span :if={@mark.label} class="runs-mark-label">{@mark.label}</span>
    </span>
    """
  end

  @doc """
  Renders the chart key: every mark the track can draw, in words, in the same
  order the track draws them.

  Each key paints the mark it names rather than describing it, so the key cannot
  drift from the surface it explains — the same rule
  `BlocksComponents.timeline_legend/2` follows, and the reason the paid break
  reads as hatched here and as hatched on a row. A reader who cannot see the
  hatching can still read "Paid break", and vice versa.
  """
  def chart_key(assigns) do
    ~H"""
    <div
      id="chart-key"
      aria-label="What each mark on the chart means"
      class="flex flex-wrap items-center gap-x-5 gap-y-2 border-b border-subtle px-5 py-2 text-[13px] text-base-content"
    >
      <span :for={entry <- chart_key_entries()} class="inline-flex items-center gap-1.5">
        <.key_swatch entry={entry} />
        <span data-role="chart-key-label">{entry.label}</span>
      </span>
    </div>
    """
  end

  attr :entry, :map, required: true

  defp key_swatch(assigns) do
    ~H"""
    <span
      data-role="chart-key-swatch"
      data-kind={@entry.key}
      class={["runs-key", "runs-key-#{@entry.key}"]}
      aria-hidden="true"
    >
      <span :if={@entry.text} class="runs-key-text">{@entry.text}</span>
    </span>
    """
  end

  # The eight marks, in the reference's order: the piece first, because the
  # piece is what a row is about and the rest is what happened around it.
  defp chart_key_entries do
    [
      %{
        key: "piece",
        label: "Piece of vehicle work: block number, route colour underneath",
        text: "B 301"
      },
      %{key: "report", label: "Report or sign-off", text: nil},
      %{key: "travel", label: "Travel, estimated", text: nil},
      %{key: "paid", label: "Paid break", text: nil},
      %{key: "unpaid", label: "Unpaid break (split)", text: nil},
      %{key: "relief", label: "Change at a relief point", text: "⇄"},
      %{key: "bad", label: "Change away from a relief point", text: "!"},
      %{key: "reach", label: "Can\u2019t reach the next piece", text: "!"}
    ]
  end

  @doc """
  Renders a run's status: an icon, the words, and how many more there are.

  **Never colour alone**, and never a bare count. The words carry the meaning
  and the icon repeats it, so a reader who cannot separate amber from white
  still reads "Piece too long" — which is the one thing a Status cell is for.
  `+N` says there are more without listing them, because the cell is 176px and a
  list would either wrap or truncate the one finding that matters.

  The worst finding leads, and `Runs.Checks` returns errors before warnings
  before notices, so the lead is the one that stops a plan being published.
  """
  attr :findings, :list, required: true

  def status_cell(assigns) do
    assigns = assign(assigns, :status, status_of(assigns.findings))

    ~H"""
    <span
      data-role="run-status"
      data-status={@status.state}
      class={["inline-flex min-w-0 max-w-full items-center gap-1.5", "text-[13px]", @status.class]}
    >
      <.icon name={@status.icon} class="size-4 shrink-0" />
      <span data-role="run-status-label" class="truncate">{@status.label}</span>
      <span
        :if={@status.more > 0}
        data-role="run-status-more"
        class="shrink-0 font-normal text-base-content/70"
      >
        +{@status.more}
      </span>
    </span>
    """
  end

  # The five codes `Runs.Checks` raises about a run, in its own words. A code
  # with no entry here is a NEW code, and it falls through to its own name rather
  # than to a wrong label: a finding nobody thought to word is still a finding,
  # and showing "too_many_pieces" is honest where "Too many pieces" would be a
  # guess.
  defp status_of([]) do
    %{
      state: "ok",
      icon: "hero-check-mini",
      label: "No problems",
      more: 0,
      class: "text-success"
    }
  end

  defp status_of(findings) do
    worst = List.first(findings)
    label = finding_label(worst)
    more = max(length(findings) - 1, 0)

    %{
      state: Atom.to_string(worst.code),
      icon: severity_icon(worst.severity),
      label: label,
      more: more,
      class: severity_class(worst.severity)
    }
  end

  defp finding_label(%{code: :not_at_relief}), do: "Not at a relief point"
  defp finding_label(%{code: :too_many_pieces}), do: "Too many pieces"
  defp finding_label(%{code: :cannot_reach_piece}), do: "Can\u2019t reach piece"
  defp finding_label(%{code: :piece_too_long}), do: "Piece too long"
  defp finding_label(%{code: :spread_too_long}), do: "Spread too long"
  defp finding_label(%{code: :travel_unknown}), do: "Travel not known"
  defp finding_label(%{code: :uncovered_work}), do: "Not in a run"
  defp finding_label(%{code: :orphan_assignments}), do: "Assignment no longer in this day type"
  defp finding_label(%{code: code}), do: Atom.to_string(code)

  # The house icons `BlocksComponents` already uses for the same three states.
  defp severity_icon(:error), do: "hero-x-circle-mini"
  defp severity_icon(:warning), do: "hero-exclamation-triangle-mini"
  defp severity_icon(_severity), do: "hero-information-circle-mini"

  defp severity_class(:error), do: "font-semibold text-error"
  defp severity_class(:warning), do: "font-semibold text-warning"
  defp severity_class(_severity), do: "font-semibold text-base-content/70"

  # The worst severity among the findings that name THIS piece, or nil.
  #
  # Each code is mapped explicitly, because `detail.piece` means three different
  # things in `Runs.Checks`: an integer index for `:piece_too_long`, a RUN ID
  # string for `:cannot_reach_piece`, and absent for the rest. Reading one of
  # them as another would outline the wrong bar, so a code not listed here
  # outlines nothing and shows in the Status cell instead — the conservative
  # direction, since a missing outline hides a mark rather than inventing one.
  defp piece_severity(piece, findings, index) do
    findings
    |> Enum.filter(&names_piece?(&1, piece, index))
    |> Enum.map(& &1.severity)
    |> worst_severity()
  end

  defp names_piece?(%{code: :piece_too_long, detail: %{piece: piece_index}}, _piece, index),
    do: piece_index == index

  defp names_piece?(
         %{code: :cannot_reach_piece, detail: %{after_piece: piece_index}},
         _piece,
         index
       ),
       do: piece_index == index

  defp names_piece?(%{code: :not_at_relief, block_id: block_id}, piece, _index),
    do: block_id == piece.block_id

  defp names_piece?(_finding, _piece, _index), do: false

  defp worst_severity([]), do: nil

  defp worst_severity(severities) do
    # Errors beat warnings beat notices. The order is `Runs.Checks`'s own
    # return order, so the outline a piece wears is the one a reader would
    # have found first in the Status cell.
    Enum.find(severities, &(&1 == :error)) || Enum.find(severities, &(&1 == :warning)) || :notice
  end

  # ── The segments, positioned ────────────────────────────────────────────────

  # Every segment that is not the piece itself, positioned on the day's axis.
  # The piece segments are skipped: the piece bar already draws that span, and
  # drawing it twice would put a mark under a bar the reader cannot see through.
  defp marks(segments, axis) do
    segments
    |> Enum.reject(&(&1.kind == :piece))
    |> Enum.map(&mark(&1, axis))
  end

  defp mark(segment, axis) do
    kind = mark_kind(segment)
    {start, span} = axis_geometry(axis)

    # A negative break is drawn over the piece it follows, at the width of the
    # stretch it cannot cover. Clamping it to zero width would render a run that
    # cannot reach its next piece as a run with no mark there at all.
    from = min(segment.start_secs, segment.end_secs)
    length_secs = abs(segment.end_secs - segment.start_secs)

    %{
      kind: kind,
      # `data-kind` is the CHART's name for the mark and `data-seg` is the
      # domain's. They differ for a break, which the chart splits three ways,
      # and they agree for a sign-off, which the chart draws as a report mark.
      # Carrying both means a test can ask "is this a report or a sign-off?"
      # without reading the title, and the words are still the last word.
      segment: Atom.to_string(segment.kind),
      source: segment.source,
      style:
        "left: #{percent(from - start, span)}%; " <>
          "width: #{percent(length_secs, span)}%",
      label: mark_label(segment, kind),
      title: mark_title(segment, kind)
    }
  end

  # One `:break` in the domain, three in the chart: a break the operator is paid
  # for, one they are not, and one they cannot take at all.
  defp mark_kind(%{kind: :break, start_secs: start, end_secs: finish}) when finish < start,
    do: "cant-reach"

  defp mark_kind(%{kind: :break, paid?: true}), do: "break-paid"
  defp mark_kind(%{kind: :break}), do: "break-unpaid"
  defp mark_kind(%{kind: :travel}), do: "travel"
  defp mark_kind(%{kind: :report}), do: "report"
  defp mark_kind(%{kind: :sign_off}), do: "report"
  defp mark_kind(%{kind: _other}), do: "other"

  # `est.` on a measured-by-estimate leg and `?` on one the version could not
  # answer. A travel leg drawn as if it were known would be worse than a gap,
  # because the gap is visible and the lie is not.
  defp mark_label(%{source: :estimated}, "travel"), do: "est."
  defp mark_label(%{source: :unknown}, "travel"), do: "?"
  defp mark_label(_segment, _kind), do: nil

  defp mark_title(%{kind: :report, start_secs: from, end_secs: to}, _kind),
    do: "Report, #{duration(to - from)}, ending #{BlocksComponents.clock(to)}"

  defp mark_title(%{kind: :sign_off, start_secs: from, end_secs: to}, _kind),
    do: "Sign-off, #{duration(to - from)}, from #{BlocksComponents.clock(from)}"

  defp mark_title(%{kind: :travel, start_secs: from, end_secs: to} = segment, _kind) do
    "Travel, #{duration(to - from)}, estimated" <> unknown_note(segment.source)
  end

  defp mark_title(%{kind: :break, paid?: true} = segment, "break-paid"),
    do: "Paid break, #{duration(segment.end_secs - segment.start_secs)}"

  defp mark_title(%{kind: :break, paid?: false} = segment, "break-unpaid"),
    do: "Unpaid break, #{duration(segment.end_secs - segment.start_secs)}"

  defp mark_title(%{kind: :break} = segment, "cant-reach"),
    do:
      "Can't reach the next piece in time, #{duration(abs(segment.end_secs - segment.start_secs))} short"

  defp mark_title(_segment, _kind), do: ""

  defp unknown_note(:unknown), do: " · the version could not answer this leg"
  defp unknown_note(_source), do: ""
  defp axis_ticks(nil), do: []

  defp axis_ticks(axis) do
    {start, span} = axis_geometry(axis)
    count = max(div(span + @tick_secs - 1, @tick_secs), 1)

    0..(count - 1)
    |> Enum.map(&{&1, &1 * @tick_secs * 100 / span})
    |> Enum.reject(fn {_index, left} -> left > @axis_label_max_percent end)
    |> Enum.map(fn {index, left} ->
      %{
        style: "left: #{percent_value(left)}%",
        label: BlocksComponents.clock(start + index * @tick_secs)
      }
    end)
  end

  # One faint rule every two hours, as a repeating gradient, so the track and the
  # axis share a single spacing rule and cannot drift apart.
  defp track_style(nil), do: nil

  defp track_style(axis) do
    {_start, span} = axis_geometry(axis)
    "--runs-grid: #{percent(@tick_secs, span)}%"
  end

  defp axis_geometry(%{start_secs: start, end_secs: end_secs}) do
    {start, max(end_secs - start, @min_track_span_secs)}
  end

  defp axis_geometry(_axis), do: {0, @min_track_span_secs}

  defp percent(value, span), do: percent_value(value * 100 / span)
  defp percent_value(value), do: :erlang.float_to_binary(value * 1.0, decimals: 2)

  defp join_style(styles) do
    styles |> Enum.reject(&is_nil/1) |> Enum.join("; ")
  end

  defp index_of(pieces, piece) do
    Enum.find_index(pieces, &(&1 == piece)) + 1
  end
end
