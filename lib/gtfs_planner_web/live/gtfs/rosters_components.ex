defmodule GtfsPlannerWeb.Gtfs.RostersComponents do
  @moduledoc """
  Function components for Operations › Rosters.

  The page's head, its states and its grid live here so
  `GtfsPlannerWeb.Gtfs.RostersLive` stays a small state owner. The scope bar,
  count strip and messages are steps 24 and 25's, the grid is step 26's, and the
  open work, pick row and export section arrive with the steps that own them —
  each a new function in this module rather than a branch inside the LiveView's
  `render/1`.

  The markup follows the design system the restyled Blocks page uses: the page
  carries the shared `.ds-page` scope, the head uses `CoreComponents`'s
  `header/1` and `button/1`, the states are `PlannerComponents` panels and the
  loading skeleton is `CoreComponents.skeleton/1` with its own bars. The
  prototype (`.specs/09-basic-rosters/references/rosters-prototype.html`) is the
  authority for the copy and the hierarchy; it is not reproduced here, because
  its sample data, its state switcher and its simulation are prototype-only.

  ## What the grid reads

  Nothing here recomputes a figure. `Rosters.Roster.build/1` produced the slots,
  the stale states, the weekly paid time, the days-off groups and the findings,
  and every cell below formats those and nothing else, so the grid cannot
  disagree with the count strip above it about the same version (INV-15). A
  finding's *words* live with the finding: the short words the Problems column
  shows and the full sentence behind its `title` are one reading of the same
  map, written as two functions over it so neither can invent a fact.

  ## Why the loading state mirrors the grid

  A skeleton whose shape is not the shape of what arrives makes the page jump
  when the real content replaces it, and it tells the reader nothing about what
  is coming. The loading panel therefore draws a Line column, seven weekday
  columns and eight rows — the shape step 26's grid has — and the head's
  editing control is disabled with the reason in `title`, because a control that
  is off with no explanation is a dead end rather than a pause.
  """

  use GtfsPlannerWeb, :html

  import GtfsPlannerWeb.PlannerComponents, only: [first_use: 1, message: 1]

  alias GtfsPlannerWeb.CoreComponents
  alias GtfsPlannerWeb.Gtfs.BlocksComponents

  @weekdays ~w(Mon Tue Wed Thu Fri Sat Sun)

  # The full weekday name, for a slot's spoken label and a day-off group's ends.
  # The three-letter heading is a column label; it is not what a screen reader
  # should say for a day, so the heading carries both and the label uses this.
  @weekday_names ~w(Monday Tuesday Wednesday Thursday Friday Saturday Sunday)

  # A control that is off while the roster has not loaded says why. One
  # sentence, written once, because the head's `title` and the loading panel's
  # copy are the same fact said to the reader in the two places they look for it.
  @paused_reason "Editing is paused until the roster loads."

  # The same pause after a *failed* read is a different sentence: the roster
  # loaded once and this version of it is no longer being kept fresh, which is
  # what the message above the lines says too. One reason, one place it is
  # written, and the head's `title` and the message body cannot drift apart.
  @refresh_paused_reason "Editing is paused until the roster refreshes."

  @seconds_per_hour 3_600
  @seconds_per_minute 60
  @seconds_per_day 86_400

  @doc """
  Renders the page head: the H1, the one subtitle sentence, and the Add line
  action.

  `Add line` is secondary, never primary. At most one primary belongs to a state
  of this page, and the clean state has none: a line is created from open work
  as often as from here, so the head offers the entry point without claiming the
  page's one emphasis.

  Two states change it, for two different reasons. While the roster is loading
  — or paused after a failed read — the button is disabled and `title` carries
  the reason, because a control that is off with no explanation is a dead end
  rather than a pause. In the no-runs state it is not drawn at all: there is no
  run to put in a line, so the action would create an empty line that cannot be
  filled, and the page's one action is already the one that makes runs.

  Step 30 gives the event its real write; until then `add_line` is the head's
  declared entry point and the guard that covers it, and nothing more.
  """
  attr :state, :atom, required: true, values: [:loading, :ready, :no_runs, :unavailable]

  # Module attributes are not readable inside a `~H` sigil — there `@name` is
  # an assign — so the two constants below are put on the assigns the templates
  # read. They are read from one place each, so they cannot drift apart.
  def page_head(assigns) do
    assigns =
      assigns
      |> assign(:paused_reason, paused_reason(assigns.state))
      |> assign(:locked?, assigns.state in [:loading, :unavailable])

    ~H"""
    <div id="rosters-head" data-role="rosters-head" class="pt-8">
      <.header>
        Roster lines
        <:subtitle>
          Each line is one week of work that repeats through the service period.
          Operators pick lines by seniority outside the app; record each pick here.
        </:subtitle>
        <:actions>
          <.button
            :if={@state != :no_runs}
            id="rosters-add-line"
            type="button"
            variant="secondary"
            class="min-h-11"
            phx-click="add_line"
            disabled={@locked?}
            title={if @locked?, do: @paused_reason, else: nil}
          >
            Add line
          </.button>
        </:actions>
      </.header>
    </div>
    """
  end

  @doc """
  The sentence a failed refresh says, for the LiveView to hand to the grid's
  disabled controls.

  It is one string in one module because three surfaces say it — the message
  body, the head's button `title` and every disabled slot in the grid — and a
  reader who is told "editing is paused" in one of them and something else in
  another has been told two things.
  """
  def refresh_paused_reason, do: @refresh_paused_reason

  defp paused_reason(:unavailable), do: @refresh_paused_reason
  defp paused_reason(_state), do: @paused_reason

  @doc """
  Renders the scope bar: the two controls that set the page's scope, and the one
  sentence that says what the lines are measured against.

  Both controls are buttons that open a drawer, and both are drawn even while
  the roster is paused — a disabled control whose panel would hold the very
  figures the reader is trying to read is worse than the control itself. What a
  pause takes away is the *editing*, which the head's Add line already owns.

  The figures are the composition's own: the base week comes from
  `roster.base_week` through `Rosters.BaseWeek.groups/1`'s labels, and the
  settings are `roster.rules`. Nothing here re-walks the day types to answer a
  question the composition already answered (INV-15).
  """
  attr :roster, :map, required: true
  attr :operators_count, :integer, required: true

  def scope_bar(assigns) do
    assigns =
      assigns
      |> assign(:groups, scope_groups(assigns.roster))
      |> assign(:base_week_dates, base_week_dates(assigns.roster.base_week))

    ~H"""
    <div
      id="rosters-scope"
      role="group"
      aria-label="Roster settings and operators"
      class="flex flex-wrap items-center gap-x-3 gap-y-3 px-5 py-4"
    >
      <button
        type="button"
        id="rosters-settings-button"
        phx-click="open_settings"
        class="inline-flex min-h-11 max-w-full items-center gap-1.5 rounded-control border border-control bg-white px-3 text-left text-sm text-strong hover:bg-canvas"
      >
        <span class="shrink-0 font-[650]">Roster settings</span>
        <span class="min-w-0 text-muted">
          · {@groups} · rest {minutes(@roster.rules.min_rest_minutes)} · warn above {@roster.rules.weekly_hours_warn_above} h
        </span>
      </button>

      <button
        type="button"
        id="rosters-operators-button"
        phx-click="open_operators"
        class="inline-flex min-h-11 items-center gap-1.5 rounded-control border border-control bg-white px-3 text-sm text-strong hover:bg-canvas"
      >
        <span class="font-[650]">Operators</span>
        <span class="tabular text-muted">· {@operators_count}</span>
      </button>

      <p class="ml-auto text-[13px] text-muted">
        Lines repeat on {@base_week_dates} base-week dates in this version
      </p>
    </div>
    """
  end

  # "Mon–Fri Weekdays · Sat Saturdays" — the weekday range the composition
  # grouped by, then that group's day type. A version with no base week at all
  # has nothing to say here, so the bar names the rule it does know rather than
  # rendering an empty pair of separators.
  defp scope_groups(%{groups: []}), do: "No base week"

  defp scope_groups(roster) do
    Enum.map_join(roster.groups, " · ", &"#{&1.label} #{&1.day_type.label}")
  end

  # The dates the version's lines actually repeat on: each weekday's own base
  # day type's dates *on that weekday*, counted from the base week the
  # composition resolved. The whole number is the only claim this makes.
  defp base_week_dates(base_week) do
    Enum.reduce(1..7, 0, fn weekday, total ->
      case base_week[weekday] do
        %{day_type: %{dates: dates}} ->
          total + Enum.count(dates, &(Date.day_of_week(&1) == weekday))

        _other ->
          total
      end
    end)
  end

  @doc """
  Renders the count strip: the six figures a planner reads the page by.

  The tiles are `CoreComponents.count_strip/1` in display mode. They are
  deliberately **not** filters — the filter row owns filtering, and a figure
  that is also a control is a figure whose meaning changes when it is pressed.

  Every number here is the composition's. `Rosters.Roster.build/1` counted the
  lines, the run-days, the open work, the weekly paid range and the problems;
  this function only finds them in the map and formats them, so the strip cannot
  disagree with the grid it sits above (INV-15).
  """
  attr :roster, :map, required: true
  attr :class, :any, default: nil

  def count_strip(assigns) do
    ~H"""
    <CoreComponents.count_strip
      id="rosters-count-strip"
      items={count_items(@roster)}
      class={@class}
    />
    """
  end

  defp count_items(roster) do
    summary = roster.summary
    threshold = roster.rules.weekly_hours_warn_above
    open_total = summary.open_by_weekday |> Map.values() |> Enum.sum()

    [
      %{
        key: "lines",
        label: "Lines",
        count: summary.lines,
        tone: :neutral,
        detail: "#{summary.open_lines} open"
      },
      %{
        key: "run_days",
        label: "Run-days in lines",
        count: summary.run_days_in_lines,
        tone: :neutral,
        detail: "of #{summary.run_days_total}"
      },
      %{
        key: "open_work",
        label: "Open work",
        count: open_total,
        tone: if(open_total > 0, do: :info, else: :success),
        detail: open_by_weekday_text(summary.open_by_weekday)
      },
      weekly_paid_item(roster, summary, threshold),
      split_days_off_item(summary),
      problems_item(roster, summary)
    ]
  end

  # "17:07–51:00 · average 38:46 · 2 above 48 h". A version with no paid work
  # says so in the detail and shows an em dash for the range, because a strip
  # tile that claims a range of zeroes would read as "every line is free".
  defp weekly_paid_item(roster, summary, threshold) do
    case summary.weekly_paid do
      nil ->
        %{
          key: "weekly_paid",
          label: "Weekly paid",
          count: 0,
          tone: :neutral,
          value: "—",
          detail: "No line has work yet"
        }

      paid ->
        over = paid.above_threshold

        %{
          key: "weekly_paid",
          label: "Weekly paid",
          count: Enum.count(roster.lines, &(&1.paid_secs > 0)),
          tone: if(over > 0, do: :warning, else: :neutral),
          value: "#{hours_minutes(paid.min_secs)}–#{hours_minutes(paid.max_secs)}",
          detail: "average #{hours_minutes(paid.avg_secs)} · #{above_phrase(over, threshold)}"
        }
    end
  end

  # Zero is said in words rather than as a digit: "0 above 48 h" reads as a
  # figure that is somehow wrong, and the prototype says "none".
  defp above_phrase(0, threshold), do: "none above #{threshold} h"
  defp above_phrase(1, threshold), do: "1 above #{threshold} h"
  defp above_phrase(over, threshold), do: "#{over} above #{threshold} h"

  # The number is the planner's figure; the sentence beside it is what makes
  # the number mean something, so a split line reads as a problem rather than as
  # a count of something the planner chose.
  defp split_days_off_item(summary) do
    detail =
      cond do
        summary.split_days_off > 0 ->
          "#{summary.split_days_off} " <>
            if(summary.split_days_off == 1,
              do: "line without two in a row",
              else: "lines without two in a row"
            )

        summary.lines > 0 ->
          "every line has two in a row"

        true ->
          nil
      end

    %{
      key: "split_days_off",
      label: "Split days off",
      count: summary.split_days_off,
      tone: if(summary.split_days_off > 0, do: :warning, else: :neutral),
      detail: detail
    }
  end

  defp problems_item(roster, summary) do
    %{
      key: "problems",
      label: "Lines with problems",
      count: summary.lines_with_problems,
      tone:
        cond do
          summary.lines_with_problems == 0 -> :success
          any_error?(roster.lines) -> :error
          true -> :warning
        end
    }
  end

  # Error severity is a property of the findings the composition already put on
  # the lines; reading it here is not a second pass over the runs.
  defp any_error?(lines) do
    Enum.any?(lines, fn line ->
      Enum.any?(line.findings, &(&1.code == :run_has_errors))
    end)
  end

  defp open_by_weekday_text(open_by_weekday) do
    Enum.map_join(1..7, " · ", fn weekday ->
      "#{Enum.at(@weekdays, weekday - 1)} #{Map.get(open_by_weekday, weekday, 0)}"
    end)
  end

  # Service-day seconds as the rest of the page writes them: hours and minutes,
  # which is what the grid's weekly paid cell and the prototype both use.
  defp hours_minutes(secs) when is_integer(secs) do
    "#{div(secs, @seconds_per_hour)}:#{pad(rem(div(secs, @seconds_per_minute), 60))}"
  end

  defp pad(minutes) when minutes < 10, do: "0#{minutes}"
  defp pad(minutes), do: "#{minutes}"

  # The minimum rest is stored in minutes and usually read in hours ("rest
  # 10 h"), because a rule a planner sets between 8 and 12 hours is a rule in
  # hours. A rule that is not a whole number of hours keeps its minutes.
  defp minutes(minutes) when rem(minutes, 60) == 0, do: "#{div(minutes, 60)} h"
  defp minutes(minutes), do: "#{div(minutes, 60)} h #{rem(minutes, 60)} min"

  @doc """
  Renders the roster grid: one row per line, seven weekday slots, and the four
  columns that describe the week as a whole.

  Everything in the row is the composition's own words. The slots, the stale
  states, the figures and the findings all arrive from `Rosters.Roster.build/1`
  (INV-15); this function finds them and formats them, so the grid cannot
  disagree with the count strip above it about the same version.

  The rows are a LiveView stream keyed by line, re-streamed on every roster
  read, so a refresh that changes one line's days patches that row rather than
  redrawing the week.

  ## Why a slot says one thing and the problems column says another

  A slot is a 44px target: it can hold a run ID and its times, and that is all.
  Everything else about the day — the warning that it starts after a short rest,
  the reason a stale slot is stale — is said once, in words, in the Problems
  column, and the slot carries the same fact as a marker so the two cannot
  disagree about which day is meant.

  ## Why the times are the Runs page's

  A run's sign-on and sign-off are `BlocksComponents.clock/1`, the same helper
  the Runs page and the Blocks page print, so a run that signs off after
  midnight reads `01:30 +1d` here as it does everywhere else in the app rather
  than as a second convention the reader has to learn on this page.
  """
  attr :roster, :map, required: true
  attr :rows, :list, required: true, doc: "the streamed `[{dom_id, line}]` rows"
  attr :locked?, :boolean, default: false
  attr :paused_reason, :string, default: nil

  def grid(assigns) do
    assigns =
      assigns
      # Module attributes are not readable inside a `~H` sigil — there `@name` is
      # an assign — so the column headings are put on the assigns.
      |> assign(:weekdays, @weekdays)
      |> assign(:weekday_names, @weekday_names)
      |> assign(:weekday_titles, weekday_titles(assigns.roster.base_week))

    ~H"""
    <div
      id="rosters-grid-scroll"
      role="region"
      aria-label="Roster lines. Scroll sideways for the full week."
      tabindex="-1"
      class="rosters-grid-scroll"
    >
      <table id="rosters-grid" aria-describedby="rosters-grid-hint">
        <caption class="sr-only">
          Roster lines: one week of runs per line, with days off, weekly paid time,
          problems and operator
        </caption>
        <colgroup>
          <col class="rosters-col-line" />
          <col :for={_day <- 1..7} class="rosters-col-day" />
          <col class="rosters-col-off" />
          <col class="rosters-col-paid" />
          <col class="rosters-col-problems" />
          <col class="rosters-col-operator" />
        </colgroup>
        <thead>
          <tr>
            <th scope="col" class="rosters-col-line">Line</th>
            <th
              :for={{day, weekday} <- Enum.with_index(@weekdays, 1)}
              scope="col"
              class="rosters-col-day rosters-day-head"
              title={Map.get(@weekday_titles, weekday)}
            >
              <span aria-hidden="true">{day}</span>
              <span class="sr-only">{Enum.at(@weekday_names, weekday - 1)}</span>
            </th>
            <th scope="col" class="rosters-col-off">Days off</th>
            <th scope="col" class="rosters-col-paid rosters-num">Weekly paid</th>
            <th scope="col" class="rosters-col-problems">Problems</th>
            <th scope="col" class="rosters-col-operator">Operator</th>
          </tr>
        </thead>
        <tbody id="rosters-grid-body">
          <tr :for={{dom_id, line} <- @rows} id={dom_id} class="rosters-line-row">
            <th scope="row" class="rosters-line-cell">
              <.line_cell line={line} locked?={@locked?} />
            </th>
            <td :for={weekday <- 1..7} class="rosters-slot-cell">
              <.slot_cell
                line={line}
                weekday={weekday}
                locked?={@locked?}
                paused_reason={@paused_reason}
              />
            </td>
            <td class="rosters-pad">
              <.days_off_cell line={line} />
            </td>
            <td class="rosters-pad rosters-num">
              <.paid_cell line={line} />
            </td>
            <td class="rosters-pad">
              <.problems_cell line={line} />
            </td>
            <td class="rosters-pad">
              <.operator_cell line={line} locked?={@locked?} />
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  # "Monday · Weekday" for each weekday's own heading, read from the base week
  # the composition resolved. A weekday with no base day type has no title to
  # give, and the heading then says the weekday and nothing more.
  defp weekday_titles(base_week) do
    Map.new(1..7, fn weekday ->
      case Map.get(base_week, weekday) do
        %{day_type: %{label: label}} ->
          {weekday, "#{Enum.at(@weekday_names, weekday - 1)} · #{label}"}

        _no_base ->
          {weekday, nil}
      end
    end)
  end

  @doc """
  The Line cell: the line number as a link into the line drawer, and whether the
  line is assigned or still open.

  The two go in one cell because the number alone does not say whether anybody
  picked the line, and the reader's first question about a row is exactly that.
  """
  attr :line, :map, required: true
  attr :locked?, :boolean, default: false

  def line_cell(assigns) do
    ~H"""
    <div class="rosters-line">
      <button
        type="button"
        id={"rosters-line-#{@line.line_number}-open"}
        class="rosters-line-link"
        phx-click="open_line"
        phx-value-line={@line.id}
        disabled={@locked?}
        aria-label={"Line #{@line.line_number}, #{line_state(@line)}. Open line details"}
      >
        {@line.line_number}
      </button>
      <span class={["rosters-line-state", is_nil(@line.operator) && "rosters-line-open"]}>
        {line_state(@line)}
      </span>
    </div>
    """
  end

  defp line_state(%{operator: nil}), do: "Open"
  defp line_state(%{operator: _operator}), do: "Assigned"

  @doc """
  One weekday's slot: the run it holds over the run's times, `Off` for a day off,
  and `Stale run` for a slot whose run no longer matches what it was set with.

  A slot is always a 44px button, including a day off, because a row of seven
  days is one target a planner aims at and an Off that is not clickable is a
  hole in the row. What each state carries is in `data-slot`, so a test and a
  reviewer can tell work from off from stale without reading the words.

  The warning marker is on the **later** day of a short rest, because that is the
  day the planner would change: it is the one that starts too soon.
  """
  attr :line, :map, required: true
  attr :weekday, :integer, required: true
  attr :locked?, :boolean, default: false
  attr :paused_reason, :string, default: nil

  def slot_cell(assigns) do
    ~H"""
    <button
      type="button"
      id={"slot-#{@line.line_number}-#{@weekday}"}
      class={[
        "rosters-slot",
        slot_state_class(@line, @weekday),
        short_rest?(@line, @weekday) && "rosters-slot-rest",
        run_errors?(@line, @weekday) && "rosters-slot-error"
      ]}
      data-slot={slot_state(@line, @weekday)}
      data-warning={slot_warning(@line, @weekday)}
      phx-click="open_slot"
      phx-value-line={@line.id}
      phx-value-weekday={@weekday}
      disabled={@locked?}
      title={@paused_reason}
      aria-label={slot_label(@line, @weekday, @paused_reason)}
    >
      <span class="rosters-slot-run">
        <span :if={short_rest?(@line, @weekday) or run_errors?(@line, @weekday)} aria-hidden="true">
          {slot_marker(@line, @weekday)}
        </span>
        {slot_run(@line, @weekday)}
      </span>
      <small :if={slot_times(@line, @weekday)} class="rosters-slot-times">
        {slot_times(@line, @weekday)}
      </small>
    </button>
    """
  end

  # The slot's three states, read from the composition: no row for the weekday is
  # a day off, a stale slot says so, and anything else is a working day.
  defp slot_state(line, weekday) do
    case Map.get(line.slots, weekday) do
      nil -> "off"
      %{state: {:stale, _reason}} -> "stale"
      _working -> "work"
    end
  end

  defp slot_state_class(line, weekday) do
    "rosters-slot-" <> slot_state(line, weekday)
  end

  defp slot_run(line, weekday) do
    case Map.get(line.slots, weekday) do
      nil -> "Off"
      %{run_id: run_id} -> run_id
    end
  end

  # A stale slot still shows the run it names, because that is the run the
  # planner has to go and look at; "Stale run" is the word under it.
  defp slot_times(line, weekday) do
    case Map.get(line.slots, weekday) do
      %{state: {:stale, _reason}} ->
        "Stale run"

      %{run: %{work: work}} ->
        slot_span(work)

      _other ->
        nil
    end
  end

  # A run's two ends on one service-day clock. The composition keeps a sign-off
  # past midnight as its within-day time, so a run that starts at 22:15 and ends
  # at 00:50 would read `22:15–0:50` and lose which morning the work finished in.
  # An end earlier than the start is exactly that run, so the end is carried into
  # the next service day and prints as `22:15–24:50`.
  defp slot_span(%{sign_on_secs: sign_on, sign_off_secs: sign_off}) do
    sign_off = if sign_off < sign_on, do: sign_off + @seconds_per_day, else: sign_off

    "#{slot_time(sign_on)}–#{slot_time(sign_off)}"
  end

  # Service-day hours as `H:MM`, unbounded — the same words the weekly paid cell
  # and the prototype use, so a run that signs off at 00:17 reads `24:17` here
  # and the page has one clock. A sign-on *before* the service day has no
  # positive hour to print, so it defers to the Runs page's helper, which says
  # `23:45 −1d` rather than the meaningless `0:-15`.
  defp slot_time(secs) when is_integer(secs) and secs < 0, do: BlocksComponents.clock(secs)
  defp slot_time(secs) when is_integer(secs), do: hours_minutes(secs)

  # One marker per slot, and only ever one: a short rest is a warning and a run
  # with errors is an error, and a day that is both says the error.
  defp slot_marker(line, weekday) do
    if run_errors?(line, weekday), do: "!", else: "△"
  end

  # The composition's own findings, so a marker cannot disagree with the words
  # in the Problems column.
  defp short_rest?(line, weekday) do
    Enum.any?(line.findings, &(&1.code == :short_rest and weekday in &1.weekdays))
  end

  defp run_errors?(line, weekday) do
    Enum.any?(line.findings, &(&1.code == :run_has_errors and weekday in &1.weekdays))
  end

  defp slot_warning(line, weekday) do
    cond do
      run_errors?(line, weekday) -> "run-errors"
      short_rest?(line, weekday) -> "short-rest"
      true -> nil
    end
  end

  # The spoken label carries the same facts as the visible ones, because the
  # visible ones are a run ID and two times: "1004" tells a screen reader
  # nothing about which day or which run's work it is.
  defp slot_label(line, weekday, paused_reason) do
    name = Enum.at(@weekday_names, weekday - 1)

    text =
      case Map.get(line.slots, weekday) do
        nil ->
          "Line #{line.line_number}, #{name}: day off."

        %{state: {:stale, reason}} = slot ->
          "Line #{line.line_number}, #{name}: stale run. #{stale_sentence(slot, reason)}"

        %{run_id: run_id, run: %{work: work}} ->
          "Line #{line.line_number}, #{name}: run #{run_id}, " <>
            "#{slot_span(work)}." <>
            rest_sentence(line, weekday)
      end

    if paused_reason, do: text <> " " <> paused_reason, else: text <> " Open to change the day."
  end

  defp rest_sentence(line, weekday) do
    case Enum.find(line.findings, &(&1.code == :short_rest and weekday in &1.weekdays)) do
      nil ->
        ""

      finding ->
        " " <> finding_sentence(finding)
    end
  end

  # The three stale reasons in the words the reader can act on. The stored times
  # are the ones the slot was set with and the current ones are what the run
  # derives now, so "changed" is a difference the reader can see rather than a
  # word they have to trust.
  defp stale_sentence(slot, :run_removed) do
    "Run #{slot.run_id} no longer exists."
  end

  defp stale_sentence(slot, :run_changed) do
    %{stored: stored} = slot

    "Run #{slot.run_id} changed since it was set: was " <>
      "#{BlocksComponents.clock(stored.sign_on_secs)}–#{BlocksComponents.clock(stored.sign_off_secs)}, now " <>
      "#{BlocksComponents.clock(slot.run.work.sign_on_secs)}–#{BlocksComponents.clock(slot.run.work.sign_off_secs)}."
  end

  defp stale_sentence(_slot, :base_changed), do: "The base week changed for that day."

  @doc """
  The Days off cell: the groups of consecutive days off, and a warning marker
  when the line has no two in a row.

  The groups come from the composition's own `days_off`, counted cyclically, so
  Sunday and Monday read as one group rather than as two separate days.
  """
  attr :line, :map, required: true

  def days_off_cell(assigns) do
    ~H"""
    <span class={["rosters-days-off", not @line.days_off.ok? && "rosters-warning-text"]}>
      <span :if={not @line.days_off.ok?} aria-hidden="true">△ </span>{days_off_text(@line)}
    </span>
    """
  end

  defp days_off_text(%{days_off: %{groups: [[1, 2, 3, 4, 5, 6, 7]]}}), do: "All week"

  defp days_off_text(%{days_off: %{groups: [[]]}}), do: "None"

  defp days_off_text(%{days_off: %{groups: groups}}) do
    Enum.map_join(groups, ", ", &days_off_group/1)
  end

  # "Sat–Sun" for a run of days, "Tue" on its own. A group that wraps the week
  # (Sunday into Monday) is a real group and prints as one.
  defp days_off_group([weekday]), do: Enum.at(@weekdays, weekday - 1)

  defp days_off_group([first | _] = group) do
    "#{Enum.at(@weekdays, first - 1)}–#{Enum.at(@weekdays, List.last(group) - 1)}"
  end

  @doc """
  The Weekly paid cell: the line's paid hours as `H:MM`, the hours over 40
  beneath, and the warning treatment above the configured threshold.

  Both figures are the composition's: `paid_secs` is the sum of the line's fresh
  slots only, so a stale slot's untrusted times are not in it, and
  `over_40_secs` is what that sum runs over 40 h by.
  """
  attr :line, :map, required: true

  def paid_cell(assigns) do
    ~H"""
    <span class={["rosters-paid", over_hours?(@line) && "rosters-paid-warning"]}>
      <strong>
        <span :if={over_hours?(@line)} aria-hidden="true">△ </span>{paid_text(@line)}
      </strong>
      <span :if={@line.over_40_secs > 0}>{over_text(@line)}</span>
    </span>
    """
  end

  defp paid_text(%{paid_secs: 0}), do: "—"
  defp paid_text(%{paid_secs: paid_secs}), do: hours_minutes(paid_secs)

  defp over_text(%{over_40_secs: over}), do: "+#{hours_minutes(over)} over 40"

  # The warning treatment follows the composition's own finding, which is the
  # rule ("strictly above the configured hours"), rather than the cell
  # recomputing the comparison.
  defp over_hours?(line) do
    Enum.any?(line.findings, &(&1.code == :weekly_hours))
  end

  @doc """
  The Problems cell: an icon and the first finding in words, with the rest as a
  count.

  One finding in full and the rest as `+N`, because the column is narrow and the
  reader's question is "is this line a problem, and which one" — answered by the
  first — while the full list is one hover or one drawer away (step 32). Every
  finding is a warning or an error, never colour alone: the words carry it.
  """
  attr :line, :map, required: true

  def problems_cell(assigns) do
    ~H"""
    <span
      class={["rosters-problems", problems_tone(@line)]}
      data-status={problems_status(@line)}
      title={problems_detail(@line)}
    >
      <.icon name={problems_icon(@line)} class="rosters-problems-icon" />
      <span>{problems_text(@line)}</span>
    </span>
    """
  end

  defp problems_text(%{findings: []}), do: "No problems"

  defp problems_text(%{findings: [finding | rest]}) do
    case rest do
      [] -> finding_words(finding)
      _more -> finding_words(finding) <> " +#{length(rest)}"
    end
  end

  defp problems_status(%{findings: []}), do: "ok"

  defp problems_status(%{findings: [finding | _rest]}) do
    case finding.code do
      :run_has_errors -> "error"
      code -> Atom.to_string(code)
    end
  end

  defp problems_tone(%{findings: []}), do: "rosters-ok-text"
  defp problems_tone(%{findings: [%{code: :run_has_errors} | _rest]}), do: "rosters-error-text"
  defp problems_tone(%{findings: [_finding | _rest]}), do: "rosters-warning-text"

  defp problems_icon(%{findings: []}), do: "hero-check-circle"
  defp problems_icon(%{findings: [%{code: :run_has_errors} | _rest]}), do: "hero-x-circle"
  defp problems_icon(%{findings: [_finding | _rest]}), do: "hero-exclamation-triangle"

  defp problems_detail(%{findings: []}), do: nil

  defp problems_detail(%{findings: findings}) do
    Enum.map_join(findings, " ", &finding_sentence/1)
  end

  # The short words the column shows. Each names what happened and, where the
  # finding carries it, which days it happened on — a warning a reader cannot
  # place is a warning they cannot act on.
  defp finding_words(%{code: :short_rest, detail: detail}) do
    "Short rest #{short_day(detail.from)} → #{short_day(detail.to)}"
  end

  defp finding_words(%{code: :weekly_hours, detail: detail}) do
    "Over #{detail.warn_above_hours} h"
  end

  defp finding_words(%{code: :days_off}), do: "Days off apart"
  defp finding_words(%{code: :stale_slot, detail: %{reason: :run_removed}}), do: "Run removed"
  defp finding_words(%{code: :stale_slot, detail: %{reason: :run_changed}}), do: "Run changed"

  defp finding_words(%{code: :stale_slot, detail: %{reason: :base_changed}}),
    do: "Base week changed"

  defp finding_words(%{code: :run_has_errors}), do: "Run has errors"

  defp short_day(weekday), do: Enum.at(@weekdays, weekday - 1)

  # The long sentence behind the words: what the finding measured, in the same
  # figures the rest of the page uses.
  defp finding_sentence(%{code: :short_rest, detail: detail}) do
    "#{short_day(detail.from)} → #{short_day(detail.to)}: " <>
      "#{rest_hours(detail.rest_secs)} of rest after the run; minimum " <>
      "#{rest_hours(detail.min_secs)}."
  end

  defp finding_sentence(%{code: :weekly_hours, detail: detail}) do
    "Paid #{hours_minutes(detail.paid_secs)} a week, over the #{detail.warn_above_hours} h warning."
  end

  defp finding_sentence(%{code: :days_off}) do
    "This line has no two days off in a row."
  end

  defp finding_sentence(%{code: :stale_slot, detail: %{reason: reason}}) do
    stale_reason_words(reason)
  end

  defp finding_sentence(%{code: :run_has_errors, detail: detail}) do
    "Run #{detail.run_id} has errors on the Runs page. The export leaves it out until they are fixed."
  end

  defp stale_reason_words(:run_removed), do: "The run no longer exists."
  defp stale_reason_words(:run_changed), do: "The run's times changed since the slot was set."
  defp stale_reason_words(:base_changed), do: "The base week changed for that day."

  # A duration of minutes, in the hours and minutes a planner reads a rest rule
  # in: 289 minutes reads `4 h 49 min`, not `4:49`, which would read as a clock.
  defp rest_hours(secs) when is_integer(secs), do: minutes(div(secs, @seconds_per_minute))

  @doc """
  The Operator cell: the operator's name and employee ID, or `Open`, plus the
  one control that records the pick.

  The button is a link-styled control rather than a `.btn` because it sits in a
  dense row beside a value, and it is the only action in the cell: a picker that
  offered more would be a second page's worth of controls in a 200px column.
  """
  attr :line, :map, required: true
  attr :locked?, :boolean, default: false

  def operator_cell(assigns) do
    ~H"""
    <div class="rosters-operator">
      <span :if={@line.operator} class="rosters-operator-value">
        <span class="rosters-operator-name">{@line.operator.display_name}</span>
        <span class="rosters-operator-id">{@line.operator.employee_id}</span>
      </span>
      <span :if={is_nil(@line.operator)} class="rosters-muted">Open</span>
      <button
        type="button"
        id={"rosters-record-pick-#{@line.line_number}"}
        class="rosters-pick-link"
        phx-click="record_pick"
        phx-value-line={@line.id}
        disabled={@locked?}
        aria-label={pick_label(@line)}
      >
        {pick_action(@line)}
      </button>
    </div>
    """
  end

  defp pick_action(%{operator: nil}), do: "Record pick"
  defp pick_action(%{operator: _operator}), do: "Change"

  defp pick_label(%{line_number: number, operator: nil}) do
    "Record pick for line #{number}"
  end

  defp pick_label(%{line_number: number, operator: operator}) do
    "Change pick for line #{number}, held by #{operator.display_name}"
  end

  @doc """
  Renders the page's messages: the stale-slot warning, the no-operators notice
  and the failed-refresh error.

  Every message has one next action, which is what makes a message a route out
  of the state rather than an explanation of it. The failed refresh comes first
  because it is the one that changes what the reader can do: the lines below are
  the last ones that loaded, and editing is paused until a refresh succeeds.

  A message never appears for a page that has no roster on screen. With nothing
  loaded there is nothing stale and nothing to pick, so the loading and no-runs
  states say their own one thing.
  """
  attr :roster, :map, required: true
  attr :operators_count, :integer, required: true
  attr :unavailable?, :boolean, default: false
  attr :version_id, :string, required: true

  def messages(assigns) do
    assigns =
      assigns
      |> assign(:stale, assigns.roster.summary.stale_slots)
      |> assign(:refresh_paused_reason, @refresh_paused_reason)

    ~H"""
    <div id="rosters-messages" class="mt-4 grid gap-3 empty:hidden">
      <.message
        :if={@unavailable?}
        id="rosters-unavailable"
        kind="error"
        title="The roster could not refresh."
        class="border-l-4 border-error-line"
      >
        You’re seeing the lines loaded a moment ago; nothing has changed. {@refresh_paused_reason}
        <:action>
          <.button id="rosters-retry" phx-click="retry_load" variant="secondary" class="min-h-11">
            Retry loading
          </.button>
        </:action>
      </.message>

      <.message
        :if={@stale > 0}
        id="rosters-stale-message"
        kind="warning"
        title={stale_title(@stale)}
        class="border-l-4 border-warning-line"
      >
        Stale slots are left out of the operations export. Open each one to choose a run or clear the day.
        <:action>
          <.button phx-click="show_stale" variant="secondary" class="min-h-11">
            Show stale slots
          </.button>
        </:action>
      </.message>

      <.message
        :if={@operators_count == 0}
        id="rosters-no-operators-message"
        kind="info"
        title="Add operators to record the pick."
        class="border-l-4 border-cyan-700"
      >
        Each operator needs an employee ID and a display name. Nothing else is stored.
        <:action>
          <.button
            id="rosters-add-operator"
            phx-click="open_operators"
            variant="secondary"
            class="min-h-11"
            disabled={@unavailable?}
            title={if @unavailable?, do: @refresh_paused_reason}
          >
            Add operator
          </.button>
        </:action>
      </.message>
    </div>
    """
  end

  defp stale_title(1),
    do: "1 slot is stale: its run was removed, changed, or no longer matches the base week."

  defp stale_title(count),
    do:
      "#{count} slots are stale: their runs were removed, changed, or no longer match the base week."

  @doc """
  Renders the first-use state: runs exist, so there is something to build from,
  and there is no line yet.

  This is not the no-runs state with different words. There the page has nothing
  to show and the next move is on another page; here the open work below is the
  next move and it is on this one, so the action goes there.

  The action is an anchor to the open-work region rather than an event, because
  scrolling to a region on the same page needs no server round trip — and the
  region it names is the one step 30 fills.
  """
  def no_lines(assigns) do
    ~H"""
    <.first_use id="rosters-first-use" icon="hero-layers" title="No roster lines yet">
      A line is one week of work for one operator. Start in Open work below: Create Mon–Fri line
      turns a weekday run into five days of work with Saturday and Sunday off. Weekend work is
      added day by day.
      <:action>
        <.button id="rosters-go-to-open-work" href="#rosters-open-work" class="min-h-11">
          Go to open work
        </.button>
      </:action>
    </.first_use>
    """
  end

  @doc """
  Renders the page's one toast: a refusal or a confirmation, fixed at the foot of
  the viewport because it is about the whole edit rather than about a row.

  `role="status"` with `aria-live="polite"`: it arrives while the reader is
  looking at the page they acted on, and it is an announcement, not a heading.
  The dark surface is the only inverted treatment on this page, because a
  confirmation is not part of the page's reading order and should not look as
  though it were. There is no Undo here: the page has no undoable write yet, and
  a button that has nothing to undo is worse than no button.
  """
  attr :toast, :map, default: nil

  def toast(assigns) do
    ~H"""
    <div
      :if={@toast}
      id="rosters-toast"
      role="status"
      aria-live="polite"
      data-role="rosters-toast"
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
      <span id="rosters-toast-text" data-role="toast-text">{@toast.text}</span>

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
  Renders the page's own states: the first-paint skeleton and the version that
  has no runs to build lines from.

  The two are different facts with different next moves, so they are different
  panels. Loading is this page's first render and says so in words. No runs is a
  settled fact about the version — nothing failed — and its one action goes to
  the page that makes runs, which is the only thing that can change it. It is
  also the page's one primary, which is why the head's Add line is not drawn
  beside it.
  """
  attr :kind, :atom, required: true, values: [:loading, :no_runs]
  attr :version_id, :string, required: true

  def page_state(%{kind: :loading} = assigns) do
    assigns =
      assign(assigns, :weekdays, @weekdays)
      |> assign(:paused_reason, @paused_reason)

    ~H"""
    <div id="rosters-loading" role="status" aria-live="polite" data-role="rosters-state">
      <%!-- `skeleton/1` owns the pulse and hides its inner block from assistive
      tech exactly as the shared component intends, so it draws the grid rows and
      nothing else. The card is this element, not the skeleton: the visible copy
      is the last thing in the card, where the prototype and the restyled Blocks
      page put it — a label above the grid reads as a column heading rather than
      as the state of the page — and a copy in its own box below the card reads as
      a stray sentence. --%>
      <div class="overflow-clip rounded-card border border-subtle bg-white">
        <.skeleton id="rosters-skeleton" rows={0} label="" class="px-0 pb-0 pt-0">
          <div aria-hidden="true">
            <div class="flex items-center gap-1 border-b border-subtle bg-canvas px-2 py-2">
              <div class="w-14 shrink-0 text-[13px] font-semibold text-muted">Line</div>
              <div
                :for={day <- @weekdays}
                class="w-[90px] shrink-0 text-[13px] font-semibold text-muted"
              >
                {day}
              </div>
            </div>
            <div
              :for={_row <- 1..8}
              class="flex items-center gap-1 border-b border-subtle px-2 last:border-b-0"
              style="height:48px"
            >
              <div class="h-5 w-14 shrink-0 rounded-badge bg-canvas"></div>
              <div
                :for={_day <- @weekdays}
                class="h-11 w-[90px] shrink-0 rounded-control bg-canvas"
              >
              </div>
            </div>
          </div>
        </.skeleton>
        <p class="border-t border-subtle px-5 py-3 text-[13px] text-muted">
          Loading roster lines… {@paused_reason}
        </p>
      </div>
    </div>
    """
  end

  def page_state(%{kind: :no_runs} = assigns) do
    ~H"""
    <.first_use id="rosters-no-runs" icon="hero-clock" title="Cut runs first">
      Roster lines are built from runs. Runs split each vehicle’s work between
      operators; each line is then one operator’s week of runs.
      <:action>
        <.button id="rosters-go-to-runs" navigate={~p"/gtfs/#{@version_id}/runs"} class="min-h-11">
          Go to Runs
        </.button>
      </:action>
    </.first_use>
    """
  end
end
