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
  Renders the plan card. From step 22 this holds the plan itself; until then it
  holds the state panel, so the page has a card of the right shape in both.
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
end
