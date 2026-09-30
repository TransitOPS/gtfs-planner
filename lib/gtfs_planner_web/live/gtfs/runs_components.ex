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

  def timeline(assigns) do
    assigns =
      assigns
      |> assign(:columns, sort_columns())
      |> assign(:ticks, axis_ticks(assigns.axis))
      |> assign(:track_style, track_style(assigns.axis))

    ~H"""
    <div id="runs-timeline-scroll">
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
    """
  end

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
      <td class={["runs-meta", "runs-meta-id"]}>
        <button
          type="button"
          phx-click="open_run"
          phx-value-run={@run.run_id}
          class="runs-run-button"
          title={"Run " <> @run.run_id}
        >
          {@run.run_id}
        </button>
      </td>
      <td class={["runs-meta", "runs-meta-type"]} data-role="run-type">
        {type_label(@run.work.type)}
      </td>
      <td class={["runs-meta", "runs-meta-on"]} data-role="run-sign-on">
        {BlocksComponents.clock(@run.work.sign_on_secs)}
      </td>
      <td class={["runs-meta", "runs-meta-off"]} data-role="run-sign-off">
        {BlocksComponents.clock(@run.work.sign_off_secs)}
      </td>
      <td class={["runs-meta", "runs-meta-spread"]} data-role="run-spread">
        {hm(@run.work.spread_secs)}
      </td>
      <td class={["runs-meta", "runs-meta-paid"]} data-role="run-paid">
        {hm(@run.work.paid_secs)}
      </td>
      <td class={["runs-meta", "runs-meta-status"]}>
        <.status_cell findings={@run.findings} />
      </td>
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
