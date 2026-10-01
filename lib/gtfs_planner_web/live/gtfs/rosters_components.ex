defmodule GtfsPlannerWeb.Gtfs.RostersComponents do
  @moduledoc """
  Function components for Operations › Rosters.

  The page's head, its states, its grid and its open work live here so
  `GtfsPlannerWeb.Gtfs.RostersLive` stays a small state owner. The scope bar,
  count strip and messages are steps 24 and 25's, the grid is step 26's and the
  open work is step 30's; the pick row and export section arrive with the steps
  that own them — each a new function in this module rather than a branch inside
  the LiveView's `render/1`.

  ## Open work is the composition's, read once

  `open_work/1` draws `Roster.groups` — one group per base day type, each with
  its label, its day type, its open run-days count and the runs still open on
  some of its weekdays. It computes nothing about runs itself, and the one
  decision it renders is `Rosters.Candidates.new_line_availability/3`: the same
  computation the writer runs under the lock, so "Create Mon–Fri line" is on a
  card exactly when the writer would accept it and gone exactly when it would
  refuse (INV-15, and the "Builder availability has one owner" criterion).

  Those derived figures are computed *here*, in the function component, and not
  in the LiveView's `render/1`. Assigning during a LiveView render invalidates
  the change tracker for the whole template, which is what made step 29's grid
  lose every row on a click; a function component owns its own assigns, so this
  is the safe place for the arithmetic.

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

  ## The filter row and the orderable headers

  Both are one fact read two ways: which rows are on screen and what order they
  are in. Neither decides anything — `RostersLive` parses `?filter=`, `?sort=`
  and `?dir=` and hands this module the answer, and the counts beside the filter
  labels are the summary the count strip above already shows, not a second count
  computed here (INV-15).

  The filter is the shared `CoreComponents.segmented_control/1`, as `#runs-view`
  is on the Runs page: a radio group with a real legend, so it is keyboard
  operable and announces itself as one control. The Stale option exists only
  while a slot is stale, for the same reason the count strip's stale message
  exists then and not before: an option that always says zero is a dead end.
  The headers are `PlannerComponents.sort_header/1`, which carries `aria-sort`
  and the indicator; the grid keeps its own sticky chrome in `#rosters-grid`'s
  CSS, so the header looks the same whether or not it sorts.

  ## A row is one Tab stop, and the server says so

  Seven days a row each being a tab stop is forty tab presses to cross one
  week, so each row's slots share one roving tabindex: Monday carries
  `tabindex="0"` in the server's own HTML and the other six `-1`, and the
  `.RosterRows` hook moves the zero when a key arrives. The split is the Runs
  duty chart's and the reason for it is the same: a client-owned tabindex
  leaves a row with no stop at all in the HTML a browser receives first, which
  is a row no keyboard can enter. `Enter` is deliberately not in the hook — a
  slot is a real `<button>`, so activating the focused one is the browser's
  own click, and the handler behind it is the page's `open_slot` event.

  The hint under the table names the keys in words rather than leaving them to
  be discovered, because a keyboard rule a reader has to find is a rule most
  readers never use. While the grid is paused every slot is disabled and none of
  the keys do anything, so the hint says the pause instead.
  """

  use GtfsPlannerWeb, :html

  import GtfsPlannerWeb.PlannerComponents,
    only: [drawer_footer: 1, drawer_scroll: 1, first_use: 1, message: 1, sort_header: 1]

  alias GtfsPlanner.Gtfs.Rosters.Candidates
  alias GtfsPlanner.Gtfs.Rosters.Checks
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

  `add_line` is a write: it creates the next numbered line and opens the slot
  drawer for its Monday, so the entry point is one click from an empty week.
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
  The row above the grid: which lines are shown, and how many of them.

  The four options are the prototype's. Each carries the count the composition
  already produced for the count strip above, because a filter that says how
  many rows it will leave is a filter a reader can choose; one that does not is a
  guess. `Stale slots` is absent while nothing is stale: an option that can only
  ever say zero is a control that has no answer.

  The legend is a visible `Show`, not a screen-reader-only one, because the
  control's own question — show what? — is one the reader looks for.
  """
  attr :roster, :map, required: true
  attr :filter, :string, required: true
  attr :shown, :integer, required: true
  attr :locked?, :boolean, default: false

  def filter_row(assigns) do
    assigns =
      assigns
      |> assign(:options, filter_options(assigns.roster.summary))
      |> assign(:total, assigns.roster.summary.lines)
      |> assign(:showing_all, assigns.shown == assigns.roster.summary.lines)
      # A module attribute is not readable inside a `~H` sigil — there `@name`
      # is an assign — so the pause sentence is put on the assigns.
      |> assign(:paused_reason, @refresh_paused_reason)

    ~H"""
    <div class="flex flex-wrap items-center gap-3 border-b border-subtle bg-canvas px-5 py-2">
      <CoreComponents.segmented_control
        id="rosters-filter"
        name="filter"
        legend="Show"
        options={@options}
        value={@filter}
        event="set_filter"
        size={:md}
        appearance={:joined}
        emphasis={:strong}
        disabled={@locked?}
        disabled_reason={if @locked?, do: @paused_reason}
      />
      <p id="rosters-filter-count" class="ml-auto text-[13px] text-muted" aria-live="polite">
        {filter_count(assigns)}
      </p>
    </div>
    """
  end

  # "All lines 5" rather than the label alone: the count is what turns a filter
  # into a decision, and it is the same count the strip above already shows.
  defp filter_options(summary) do
    [
      {"All lines #{summary.lines}", "all"},
      {"Open lines #{summary.open_lines}", "open"},
      {"Lines with problems #{summary.lines_with_problems}", "problems"}
    ] ++
      if(summary.stale_slots > 0, do: [{"Stale slots #{summary.stale_slots}", "stale"}], else: [])
  end

  defp filter_count(%{showing_all: true, total: total}), do: plural_lines(total)

  defp filter_count(%{shown: shown, total: total}),
    do: "Showing #{shown} of #{plural_lines(total)}"

  defp plural_lines(1), do: "1 line"
  defp plural_lines(count), do: "#{count} lines"

  @doc """
  Renders the roster grid: one row per line, seven weekday slots, and the four
  columns that describe the week as a whole.

  Everything in the row is the composition's own words. The slots, the stale
  states, the figures and the findings all arrive from `Rosters.Roster.build/1`
  (INV-15); this function finds them and formats them, so the grid cannot
  disagree with the count strip above it about the same version.

  The rows are a LiveView stream keyed by line, re-streamed on every roster
  read and on every change to the filter or the order, so a refresh that changes
  one line's days patches that row rather than redrawing the week. Whether the
  filter left any rows is answered by the count the LiveView passes in, not by
  asking the stream: inside a `phx-update="stream"` container the stream is not a
  list, and comparing it crashes the diff.

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

  attr :rows, :list,
    required: true,
    doc: "the streamed `[{dom_id, chunk}]` rows — a line, or the open pick"

  attr :shown, :integer,
    required: true,
    doc: "how many rows the filter left, drawn by the empty row"

  attr :sort, :atom, required: true, doc: "the column the rows are ordered by"
  attr :dir, :atom, required: true, doc: "the direction they are ordered in"
  attr :locked?, :boolean, default: false
  attr :paused_reason, :string, default: nil

  attr :new_line_id, :string,
    default: nil,
    doc: "the line a write just created, drawn with the new-line highlight"

  attr :pick, :map,
    default: nil,
    doc: "the open pick, streamed as a row of its own under its own line"

  def grid(assigns) do
    assigns =
      assigns
      # Module attributes are not readable inside a `~H` sigil — there `@name` is
      # an assign — so the column headings are put on the assigns.
      |> assign(:weekdays, @weekdays)
      |> assign(:weekday_names, @weekday_names)
      |> assign(:weekday_titles, weekday_titles(assigns.roster.base_week))
      # Which line is being picked is one comparison per row, read here rather
      # than in the sigil where the pick's keys would have to be reached for.
      |> assign(:pick_line_id, assigns.pick && assigns.pick.line_id)

    ~H"""
    <div
      id="rosters-grid-scroll"
      role="region"
      aria-label="Roster lines. Scroll sideways for the full week."
      tabindex="-1"
      class="rosters-grid-scroll"
    >
      <table id="rosters-grid" aria-describedby="rosters-grid-hint" phx-hook=".RosterRows">
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
            <.sort_header
              label="Line"
              sort_key="line"
              sort_by={@sort}
              sort_dir={@dir}
              class="rosters-col-line"
            />
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
            <.sort_header
              label="Weekly paid"
              sort_key="paid"
              sort_by={@sort}
              sort_dir={@dir}
              class="rosters-col-paid rosters-num"
            />
            <th scope="col" class="rosters-col-problems">Problems</th>
            <.sort_header
              label="Operator"
              sort_key="operator"
              sort_by={@sort}
              sort_dir={@dir}
              class="rosters-col-operator"
            />
          </tr>
        </thead>
        <tbody id="rosters-grid-body">
          <.grid_row
            :for={{dom_id, chunk} <- @rows}
            id={dom_id}
            chunk={chunk}
            locked?={@locked?}
            paused_reason={@paused_reason}
            new_line_id={@new_line_id}
            pick_line_id={@pick_line_id}
          />
          <tr :if={@shown == 0} class="rosters-no-match">
            <td colspan="12" class="rosters-pad py-6 text-center text-sm text-muted">
              No lines match this filter.
              <button
                type="button"
                id="rosters-show-all"
                phx-click="set_filter"
                phx-value-filter="all"
                disabled={@locked?}
                class="font-semibold text-action underline hover:text-action-hover disabled:no-underline"
              >
                Show all lines
              </button>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    <div class="flex flex-wrap items-center gap-x-6 gap-y-2 border-t border-subtle px-5 py-3 text-[13px] text-muted">
      <p id="rosters-grid-hint">{keyboard_hint(@paused_reason)}</p>
    </div>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".RosterRows">
      // A row's seven days are ONE tab stop, not one tab stop each.
      //
      // The server owns the tabindex, so a row that has never been focused and a
      // row whose focus has moved look the same in the initial HTML; this hook
      // only moves focus and re-points the roving tabindex when a key arrives.
      // That split is deliberate: if the client owned the tabindex, a row would
      // arrive with no tab stop at all and be unreachable by keyboard.
      export default {
        mounted() {
          // The day each row was last left on, by row id. Re-applied after a
          // patch, so a re-streamed row comes back on the day its reader was
          // standing on rather than silently jumping back to Monday.
          this.rover = {}
          this.handleKeydown = e => this.move(e)
          this.el.addEventListener("keydown", this.handleKeydown)
          this.apply()
        },
        updated() {
          this.apply()
        },
        destroyed() {
          this.el.removeEventListener("keydown", this.handleKeydown)
        },
        apply() {
          this.el.querySelectorAll("#rosters-grid-body tr").forEach(row => {
            const days = Array.from(row.querySelectorAll(".rosters-slot"))
            if (days.length === 0) return
            const to = Math.min(this.rover[row.id] ?? 0, days.length - 1)
            days.forEach((day, i) => { day.tabIndex = i === to ? 0 : -1 })
          })
        },
        // Only the four keys a roving row owns. Everything else is left alone,
        // so Tab still leaves the row, Enter still activates the button, and a
        // reader's own browser shortcuts keep working.
        move(e) {
          const keys = ["ArrowRight", "ArrowLeft", "Home", "End"]
          if (!keys.includes(e.key)) return

          const day = e.target.closest?.(".rosters-slot")
          if (!day || !this.el.contains(day)) return

          // One row, its seven days in document order. The empty-filter row
          // carries no slots and is skipped by the length check.
          const row = day.closest("tr")
          const days = Array.from(row.querySelectorAll(".rosters-slot"))
          const index = days.indexOf(day)
          if (index < 0) return

          const last = days.length - 1
          // Clamped rather than wrapped: Right on Sunday and Left on Monday
          // stay where they are. Wrapping would make a reader who overshot
          // believe they had changed row.
          const to = {
            ArrowRight: Math.min(index + 1, last),
            ArrowLeft: Math.max(index - 1, 0),
            Home: 0,
            End: last
          }[e.key]

          e.preventDefault()
          this.rover[row.id] = to
          this.apply()
          days[to].focus()
        }
      };
    </script>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".RosterNewLine">
      // The row a write just created scrolls itself into view.
      //
      // Every row carries the hook, because a colocated hook name is resolved
      // at compile time and only a literal attribute gets that resolution — a
      // conditional `phx-hook` reaches the browser unresolved and the page logs
      // "unknown hook". So the hook is on every row and asks the row's own
      // `data-new` whether it is the new one, which is one property read on a
      // handful of rows. `block: "center"` rather than `"start"` so the row
      // lands with its own week beside it instead of at the top of the grid
      // with its column headings a screen away.
      //
      // A hook, and not `JS.exec` on `phx-mounted`: on LiveView 1.1 a raw JS
      // string read out of an attribute is executed as a command list, so the
      // expression is parsed as an unknown command and throws — which aborts
      // the rest of the patch, including the slot drawer's own mount.
      export default {
        mounted() {
          if (this.el.dataset.new === "true") {
            this.el.scrollIntoView({block: "center"});
          }
        }
      };
    </script>
    """
  end

  @doc """
  One row of the grid: a line's week, or the pick row under the line it belongs
  to.

  The grid's stream carries both kinds of row. That is not tidiness — a stream
  never redraws a row that is already on screen, so a pick row drawn as a plain
  sibling of the streamed lines would not appear when a pick opens and would not
  go away when it is saved. As an item of the same stream, keyed separately, it
  is inserted directly under its line and removed when the pick closes, and the
  lines around it are left exactly as they were.
  """
  attr :id, :string, required: true, doc: "the stream's own key for this row"
  attr :chunk, :any, required: true, doc: "`{:line, line}` or `{:pick, pick}`"
  attr :locked?, :boolean, default: false
  attr :paused_reason, :string, default: nil
  attr :new_line_id, :string, default: nil
  attr :pick_line_id, :string, default: nil

  def grid_row(%{chunk: {:line, line}} = assigns) do
    assigns = assign(assigns, :line, line)

    ~H"""
    <tr
      id={@id}
      class="rosters-line-row"
      data-new={to_string(@line.id == @new_line_id)}
      phx-hook=".RosterNewLine"
    >
      <th scope="row" class="rosters-line-cell">
        <.line_cell line={@line} locked?={@locked?} />
      </th>
      <td :for={weekday <- 1..7} class="rosters-slot-cell">
        <.slot_cell
          line={@line}
          weekday={weekday}
          locked?={@locked?}
          paused_reason={@paused_reason}
        />
      </td>
      <td class="rosters-pad">
        <.days_off_cell line={@line} />
      </td>
      <td class="rosters-pad rosters-num">
        <.paid_cell line={@line} />
      </td>
      <td class="rosters-pad">
        <.problems_cell line={@line} />
      </td>
      <td class="rosters-pad">
        <.operator_cell
          line={@line}
          locked?={@locked?}
          recording?={@pick_line_id == @line.id}
        />
      </td>
    </tr>
    """
  end

  def grid_row(%{chunk: {:pick, pick}} = assigns) do
    assigns = assign(assigns, :pick, pick)

    ~H"""
    <.pick_row
      id={@id}
      line={@pick.line}
      operators={@pick.operators}
      selected={@pick.selected}
      refusal={@pick.refusal}
    />
    """
  end

  # The hint, or the pause. One sentence, written once, because the table's
  # `aria-describedby` and the paragraph a reader reads are the same fact.
  defp keyboard_hint(paused_reason) do
    paused_reason ||
      "A row’s seven days are one Tab stop. Left and Right move between days; " <>
        "Home and End jump to Monday and Sunday. Enter opens the day."
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
        data-line={@line.line_number}
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

  The `tabindex` is the roving half of one Tab stop per row: Monday is the
  stop and the other six are skipped, and the `.RosterRows` hook on the table
  moves the zero. It is server-rendered so the row has a stop in the HTML the
  browser receives before any script runs.

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
      tabindex={rover_tabindex(@weekday)}
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

  # Monday is the row's tab stop until a key moves it. A weekday outside the
  # week (which the composition never produces) is not a stop either, so a
  # malformed index cannot leave a row with two.
  defp rover_tabindex(1), do: 0
  defp rover_tabindex(_weekday), do: -1

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

  @doc """
  The Days off cell's words, for a page that has to say them outside the grid.

  The cell reads them in place; the toast that confirms a newly built line says
  the same thing, and it reads this rather than a second sentence that could
  describe the same week differently.
  """
  def days_off_text(%{days_off: %{groups: [[1, 2, 3, 4, 5, 6, 7]]}}), do: "All week"

  def days_off_text(%{days_off: %{groups: [[]]}}), do: "None"

  def days_off_text(%{days_off: %{groups: groups}}) do
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

  `recording?` is the line whose pick is open. The cell then says so in words
  rather than offering the control that would reopen the row already under it.
  """
  attr :line, :map, required: true
  attr :locked?, :boolean, default: false
  attr :recording?, :boolean, default: false

  def operator_cell(assigns) do
    ~H"""
    <div class="rosters-operator">
      <span :if={@recording?} class="rosters-muted">Recording pick…</span>
      <span :if={@line.operator && not @recording?} class="rosters-operator-value">
        <span class="rosters-operator-name">{@line.operator.display_name}</span>
        <span class="rosters-operator-id">{@line.operator.employee_id}</span>
      </span>
      <span :if={is_nil(@line.operator) && not @recording?} class="rosters-muted">Open</span>
      <button
        :if={not @recording?}
        type="button"
        id={"rosters-record-pick-#{@line.line_number}"}
        class="rosters-pick-link"
        phx-click="open_pick"
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
  The pick row: the one form the grid carries, opened under its own line.

  Which operators are on offer is the organization's own list in seniority order
  (`Operations.list_operators/1`) minus everybody who already holds a line in
  this version, because one operator holds at most one line here. A line that
  already has a pick leads with the operator who holds it, marked "current", and
  "No operator (open)" clears it — a pick is a record, and clearing one is a
  record too.

  The row is one `<tr>` with a single cell across the whole week, because a form
  that runs under a line and not inside one of its cells is the only shape in
  which a 340px select, two buttons and a refusal fit without squeezing the
  week. `id` is the grid stream's key for the row, so the row is inserted and
  removed with the lines around it; `#rosters-pick-row` is the cell itself, which
  is the part a test and a reviewer address.

  The submitted operator id is not this component's business: the writer casts
  it inside the caller's organization, so a hand-built or stale value cannot
  reach another tenant's operator (the "Scoped identities" criterion).
  """
  attr :id, :string, required: true, doc: "the grid stream's key for this row"
  attr :line, :map, required: true
  attr :operators, :list, required: true, doc: "the operators holding no line in this version"
  attr :selected, :string, default: nil
  attr :refusal, :string, default: nil

  def pick_row(assigns) do
    ~H"""
    <tr id={@id} class="rosters-pick-line">
      <td id="rosters-pick-row" colspan="12" class="rosters-pick-cell">
        <form
          id="rosters-pick-form"
          class="flex flex-wrap items-end gap-x-4 gap-y-3"
          phx-submit="save_pick"
        >
          <input type="hidden" name="line" value={@line.id} />
          <div class="w-[340px] max-w-full">
            <.input
              type="select"
              id="rosters-pick-operator"
              name="operator"
              label={"Record the pick for line #{@line.line_number}"}
              options={pick_options(@line, @operators)}
              value={@selected || ""}
              help={pick_help(@line, @operators)}
            />
          </div>
          <.button type="button" id="rosters-pick-cancel" variant="secondary" phx-click="cancel_pick">
            Cancel
          </.button>
          <.button type="submit" id="rosters-pick-save" phx-disable-with="Saving…">
            Save pick
          </.button>
          <.message
            :if={@refusal}
            id="rosters-pick-error"
            kind="error"
            title="Nothing was saved."
            class="max-w-[720px] border-l-4 border-error-line"
          >
            {@refusal}
          </.message>
        </form>
      </td>
    </tr>
    """
  end

  # The line's own operator leads when it has one, so opening the row on a
  # picked line shows the pick rather than the first name in the list. The
  # clearing answer is there only in that case: there is nothing to clear on a
  # line nobody has picked — except that a select with no options at all is a
  # dead control, which is what a line nobody can offer a name for would be.
  defp pick_options(%{operator: nil}, []), do: [{"No operator (open)", ""}]

  defp pick_options(%{operator: nil}, operators), do: pick_operator_options(operators)

  defp pick_options(%{operator: current}, operators) do
    [{"#{pick_option_label(current)} · current", current.id}, {"No operator (open)", ""}] ++
      pick_operator_options(operators)
  end

  defp pick_operator_options(operators), do: Enum.map(operators, &{pick_option_label(&1), &1.id})

  # The organization's own operator-list order is the pick's order, so the number
  # is on the label rather than the label being rebuilt: numbered operators by
  # number, then operators without one by name (domain rule 11).
  defp pick_option_label(%{seniority_number: nil, display_name: name, employee_id: id}),
    do: "#{name} · #{id}"

  defp pick_option_label(%{seniority_number: number, display_name: name, employee_id: id}),
    do: "##{number} #{name} · #{id}"

  defp pick_help(%{operator: nil}, []),
    do: "Every operator already holds a line, so there is nobody left to pick it."

  defp pick_help(%{operator: _operator}, []),
    do: "Every operator already holds a line, so this pick can only be cleared."

  defp pick_help(_line, _operators),
    do: "Enter the operator who picked this line in the bid."

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

  @doc """
  Open work: one group per base day type, with the runs still open on it.

  The section is the version's own `Roster.groups` and nothing else. Each group
  carries the weekdays based on its day type, the label those weekdays make
  ("Mon–Fri"), the day type's own name, its open run-days count and the runs
  still open on at least one of those weekdays (INV-15). The count beside the
  heading is the group's own `open_run_days`, so the number above the cards is
  the number of run-days behind them rather than a second count of the same
  thing.

  One decision is rendered and it belongs to `Rosters.Candidates`:
  `new_line_availability/3` decides whether a card offers "Create <label> line",
  which is the same computation `create_roster_line_from_run/4` runs under the
  lock. A card with a refused builder therefore shows no button rather than a
  button whose only answer would be a refusal.

  ## Where the refusal is drawn

  A refused create stays on the card it belongs to, as `PlannerComponents.message`
  in error tone, with no flash and no toast: the reason is about that run, and a
  sentence at the foot of the viewport about a card several screens up is a
  sentence the planner has to find. `refusal` carries the run the refusal names,
  so only that card shows it, and it is `RostersComponents.refusal_text/2`'s
  words — the same string the drawer and the disabled group action use.
  """
  attr :roster, :map, required: true
  attr :locked?, :boolean, default: false

  attr :refusal, :map,
    default: nil,
    doc: "`%{run_id:, text:}` for one card, or nil. A refusal belongs to its run."

  def open_work(assigns) do
    assigns = assign(assigns, :groups, open_work_groups(assigns.roster))

    ~H"""
    <section
      id="rosters-open-work"
      aria-labelledby="rosters-open-work-title"
      class="mt-4 rounded-card border border-subtle bg-white"
    >
      <div class="flex flex-wrap items-end justify-between gap-3 border-b border-subtle px-5 py-4">
        <div>
          <h2 id="rosters-open-work-title" tabindex="-1" class="text-[22px]">Open work</h2>
          <p class="mt-1 text-sm text-muted">
            Runs not yet in a line. Create a Mon–Fri line from a weekday run, or add a run’s day to a
            line that has it off.
          </p>
        </div>
      </div>

      <div
        :for={group <- @groups}
        id={"rosters-open-group-#{group.day_type.key}"}
        class="border-t border-subtle px-5 py-4 first-of-type:border-t-0"
      >
        <div class="flex flex-wrap items-baseline justify-between gap-2">
          <h3 class="text-base font-bold">
            {group.label}
            <span class="font-normal text-muted">· {group.day_type.label}</span>
          </h3>
          <span class="tabular text-[13px] text-muted">
            {open_run_days_text(group.open_run_days)}
          </span>
        </div>

        <div
          :if={group.cards != []}
          class="mt-3 grid grid-cols-[repeat(auto-fill,minmax(236px,1fr))] gap-2"
        >
          <.open_run_card
            :for={card <- group.cards}
            card={card}
            locked?={@locked?}
            refusal={@refusal}
          />
        </div>

        <.message
          :if={group.cards == []}
          id={"rosters-open-group-#{group.day_type.key}-clear"}
          kind="success"
          title={"Every #{group.day_type.label} run is in a line."}
        />
      </div>
    </section>
    """
  end

  # The groups, in the composition's own order, with each run's builder answer
  # resolved once. The availability is a pure function of the roster already on
  # the socket, so it is decided here rather than stored on the LiveView: an
  # assign made during a LiveView render is what cost step 29's grid its rows.
  defp open_work_groups(roster) do
    Enum.map(roster.groups, fn group ->
      Map.put(group, :cards, Enum.map(group.open_runs, &open_run_card_data(roster, group, &1)))
    end)
  end

  defp open_run_card_data(roster, group, open_run) do
    key = group.day_type.key

    Map.merge(open_run, %{
      day_type_key: key,
      group_label: group.label,
      weekdays: group.weekdays,
      availability: Candidates.new_line_availability(roster, key, open_run.run_id)
    })
  end

  defp open_run_days_text(1), do: "1 open run-day"
  defp open_run_days_text(count), do: "#{count} open run-days"

  @doc """
  One open run's card: what the run is, when it is open, and what can be built
  from it.

  The figures are the run's own — sign-on, sign-off, paid time, run type — read
  from the composition's `open_runs/1` entry, and the times are printed by the
  same helpers the grid prints them with, so a run reads the same in both places
  (INV-15).

  The weekday chips say which of the group's days the run is still open on. A
  group of more than one weekday needs them, because "Create Mon–Fri line" is
  offered only when the run is open on every one of them and the chips are how a
  planner sees that before reaching for the button. A single-weekday group has
  nothing to distinguish, so it draws none.
  """
  attr :card, :map, required: true
  attr :locked?, :boolean, default: false
  attr :refusal, :map, default: nil

  def open_run_card(assigns) do
    assigns = assign(assigns, :run, assigns.card.run)

    ~H"""
    <div
      class="rosters-open-run"
      id={"rosters-open-run-#{@card.day_type_key}-#{@card.run_id}"}
      data-run={@card.run_id}
      data-open-days={Enum.join(@card.open_weekdays, " ")}
    >
      <div class="flex items-baseline justify-between gap-2">
        <strong class="text-base text-strong">Run {@card.run_id}</strong>
        <span class="text-[13px] text-muted">{run_type_words(@run)}</span>
      </div>

      <div class="rosters-open-times tabular text-sm">
        {slot_span(@run.work)}
        <span class="text-muted">· {hours_minutes(@run.work.paid_secs)} paid</span>
      </div>

      <div
        :if={length(@card.weekdays) > 1}
        class="rosters-day-chips"
        aria-label={"Open on #{Enum.map_join(@card.open_weekdays, ", ", &weekday_name/1)}"}
      >
        <span
          :for={weekday <- @card.weekdays}
          class={[
            "rosters-day-chip",
            weekday in @card.open_weekdays && "rosters-day-chip-open",
            weekday not in @card.open_weekdays && "rosters-day-chip-taken"
          ]}
          aria-hidden="true"
        >
          {short_day(weekday)}
        </span>
      </div>

      <div :if={not @locked?} class="mt-1 flex flex-wrap items-center gap-x-2 gap-y-1">
        <.button
          :if={match?({:ok, _weekdays}, @card.availability)}
          type="button"
          id={"rosters-create-line-#{@card.run_id}"}
          variant="secondary"
          class="min-h-11 px-3"
          phx-click="create_line_from_run"
          phx-value-day_type={@card.day_type_key}
          phx-value-run={@card.run_id}
        >
          Create {@card.group_label} line
        </.button>

        <%!-- "Add to line…" is always offered where a card is: it asks the run's own open
        days which lines have the day off, and the answer is empty only when no line does — which
        is a sentence the drawer says, not a reason to hide the way there. --%>
        <.button
          type="button"
          id={"rosters-add-to-line-#{@card.run_id}"}
          data-action="add-to-line"
          variant="quiet"
          class="min-h-11 px-3 underline underline-offset-4"
          phx-click="open_add_to_line"
          phx-value-day_type={@card.day_type_key}
          phx-value-run={@card.run_id}
        >
          Add to line…
        </.button>
      </div>

      <.message
        :if={@refusal && @refusal.run_id == @card.run_id}
        id={"rosters-create-refusal-#{@card.run_id}"}
        kind="error"
        title="No line was created."
        class="mt-2 border-l-4 border-error-line"
      >
        {@refusal.text}
      </.message>
    </div>
    """
  end

  @doc """
  A builder's refusal as the one sentence a planner reads.

  This is `Rosters.Candidates`' answer written out, and it is written **here**
  because the page is where a planner reads it: the same sentence appears under
  the disabled group action and beside the error a refused write leaves in the
  drawer, so the two cannot describe the same refusal differently (INV-15, and
  the "Builder availability has one owner" criterion).

  `context` carries the facts a refusal names but does not carry: the `run_id`
  the planner chose, the `weekday` whose group was asked for, the `line_number`
  and the version's `min_rest_minutes`. Refusals that need none of them are
  written without them.
  """
  @spec refusal_text(Candidates.refusal(), %{
          required(:run_id) => String.t() | nil,
          required(:weekday) => 1..7 | nil,
          required(:line_number) => pos_integer() | nil,
          required(:min_rest_minutes) => integer()
        }) :: String.t()
  def refusal_text({:unknown_run, run_id}, _context) do
    "Run #{run_id} is not one of this day’s runs."
  end

  def refusal_text(:single_day_group, _context) do
    "That day is the only weekday its day type runs, so there is no group to set."
  end

  def refusal_text({:run_held, weekday, line_number}, %{run_id: run_id}) do
    "Run #{run_id} is in line #{line_number} on #{short_weekday_name(weekday)}."
  end

  def refusal_text({:day_filled, weekday, other_run_id}, %{line_number: number}) do
    "Line #{number} already works run #{other_run_id} on #{short_weekday_name(weekday)}. " <>
      "Clear it first, or set days one at a time."
  end

  def refusal_text(
        {:short_rest, from, to, rest_secs, run_id},
        %{weekday: weekday, min_rest_minutes: min_rest_minutes}
      ) do
    "#{short_weekday_name(from)} → #{short_weekday_name(to)} would leave " <>
      "#{rest_hours(rest_secs)} of rest after run #{run_id}; minimum " <>
      "#{rest_hours(min_rest_minutes * @seconds_per_minute)}." <>
      if(weekday, do: " Set #{weekday_name(weekday)} alone to keep it as a warning.", else: "")
  end

  def refusal_text({:no_base, weekday}, _context) do
    "#{weekday_name(weekday)} has no base day type, so no run can be set there."
  end

  def refusal_text(:not_found, _context), do: "That line is no longer on this version."

  defp weekday_name(weekday), do: Enum.at(@weekday_names, weekday - 1)

  defp short_weekday_name(weekday), do: Enum.at(@weekdays, weekday - 1)

  @doc """
  One short rest as the sentence the confirmation toast carries.

  The same words `refusal_text/2` writes for `{:short_rest, …}`, without the
  "would leave" a refusal needs: after a write the rest is not a forecast, it is
  what the week the planner just built leaves.
  """
  @spec short_rest_sentence(Checks.short_rest(), integer()) :: String.t()
  def short_rest_sentence(%{from: from, to: to, rest_secs: rest_secs}, min_rest_minutes) do
    "#{short_weekday_name(from)} → #{short_weekday_name(to)}: " <>
      "#{rest_hours(rest_secs)} of rest after the run; minimum " <>
      "#{rest_hours(min_rest_minutes * @seconds_per_minute)}."
  end

  @doc """
  The slot drawer: choose the run one weekday of one line works.

  Everything in it is an answer somebody else computed. The week strip and the
  stale note are the composition's own slots (`Rosters.Roster.build/1`), the
  candidate rows are `Rosters.Candidates.slot_candidates/3` in that function's
  order, and whether the group action is available is
  `Candidates.group_availability/4` — the same computation the writer runs under
  the lock, so a button that is enabled writes and one that is off cannot
  (INV-15).

  ## Why the disabled reason is drawn, not withheld

  An action a planner cannot take is still on screen, with the sentence saying
  why underneath it, because a control that vanishes leaves the planner looking
  for it. The sentence is `refusal_text/2` over the same refusal the writer
  would return, so it names the thing to fix first rather than the first thing
  a function happened to test.

  ## The footer is three actions in three places

  `Clear day` at the opposite edge (it is destructive to the day, and the two
  Set actions are not), then the group's secondary action and the day's primary.
  `phx-disable-with` puts a write into its pending state, so a second click
  during the round trip cannot send it twice.
  """
  attr :open, :boolean, required: true
  attr :line, :map, required: true
  attr :weekday, :integer, required: true
  attr :current, :map, default: nil, doc: "the slot as it stands, which may be stale"
  attr :group, :map, default: nil, doc: "the weekday's group: weekdays and label"
  attr :candidates, :list, required: true
  attr :selected_run_id, :string, default: nil
  attr :group_state, :any, default: nil, doc: "`Candidates.group_availability/4`"
  attr :pending?, :boolean, default: false
  attr :refusal, :string, default: nil
  attr :min_rest_minutes, :integer, required: true
  attr :on_close, :string, default: "close_slot"

  def slot_drawer(assigns) do
    assigns =
      assigns
      |> assign(:day_name, weekday_name(assigns.weekday))
      |> assign(:stale, stale_reason(assigns.current))
      |> assign(:group_label, group_label(assigns))

    ~H"""
    <.drawer
      id="rosters-slot-drawer"
      chrome="planner"
      open={@open}
      pending={@pending?}
      on_close={@on_close}
      class="max-w-[min(100vw,52rem)]"
      title={"Line #{@line.line_number} · #{@day_name}"}
      return_focus_id={"slot-#{@line.line_number}-#{@weekday}"}
    >
      <:lede>
        <span id="rosters-slot-lede">
          {(@line.operator && @line.operator.display_name) || "Open line"} · {plural_days(
            map_size(@line.slots)
          )} · {@line.paid_secs |> hours_minutes()} paid a week
        </span>
      </:lede>

      <.drawer_scroll>
        <.message
          :if={@stale}
          id="rosters-slot-stale"
          kind="warning"
          title={slot_stale_title(@current)}
          class="border-l-4 border-warning-line"
        >
          {stale_note(@current, @stale, @group_label, @day_name)}
        </.message>

        <div
          id="rosters-slot-week"
          class="rosters-week-strip"
          role="group"
          aria-label={"Line #{@line.line_number} this week"}
        >
          <div
            :for={weekday <- 1..7}
            class={[
              "rosters-week-day",
              slot_state(@line, weekday) == "work" && "rosters-week-work",
              slot_state(@line, weekday) == "stale" && "rosters-week-stale",
              weekday == @weekday && "rosters-week-here"
            ]}
            aria-current={weekday == @weekday && "true"}
          >
            <b aria-hidden="true">{short_day(weekday)}</b>
            <span class="sr-only">{weekday_name(weekday)}</span>
            <span>{slot_run(@line, weekday)}</span>
            <span :if={slot_times(@line, weekday)} class="rosters-week-times">
              {slot_times(@line, weekday)}
            </span>
          </div>
        </div>

        <fieldset :if={@candidates != []} id="rosters-slot-candidates" class="min-w-0">
          <legend class="text-base font-bold text-strong">Run for {@day_name}</legend>
          <p class="mt-1 text-[13px] text-muted">
            {@day_name} uses {@group_label} runs. Open runs whose sign-on is closest to this line’s
            other days come first. Minimum rest is {minutes(@min_rest_minutes)}.
          </p>

          <div class="mt-3 overflow-x-auto rounded-card border border-subtle">
            <table class="w-full border-separate border-spacing-0 text-sm">
              <caption class="sr-only">
                Runs {@day_name} can take, with the rest each leaves either side
              </caption>
              <thead>
                <tr class="bg-canvas text-left text-[13px] text-muted">
                  <th scope="col" class="px-2 py-2 font-semibold">Run</th>
                  <th scope="col" class="px-2 py-2 font-semibold">Type</th>
                  <th scope="col" class="px-2 py-2 font-semibold">Sign-on</th>
                  <th scope="col" class="px-2 py-2 font-semibold">Sign-off</th>
                  <th scope="col" class="px-2 py-2 text-right font-semibold">Paid</th>
                  <th scope="col" class="px-2 py-2 font-semibold">Rest before</th>
                  <th scope="col" class="px-2 py-2 font-semibold">Rest after</th>
                </tr>
              </thead>
              <tbody id="rosters-slot-rows">
                <tr
                  :for={candidate <- @candidates}
                  id={"rosters-slot-row-#{candidate.run_id}"}
                  class="rosters-pick-row"
                  data-selected={to_string(candidate.run_id == @selected_run_id)}
                >
                  <td class="px-2 py-1">
                    <label class="flex min-h-11 cursor-pointer items-center gap-2.5">
                      <input
                        type="radio"
                        id={"rosters-slot-run-#{candidate.run_id}"}
                        name="rosters-slot-run"
                        value={candidate.run_id}
                        checked={candidate.run_id == @selected_run_id}
                        phx-click="choose_candidate"
                        phx-value-run={candidate.run_id}
                        class="size-5 accent-action"
                      />
                      <span class="font-bold text-strong">{candidate.run_id}</span>
                      <span
                        :if={current_run?(@current, candidate.run_id)}
                        class="text-[13px] text-muted"
                      >
                        current
                      </span>
                    </label>
                  </td>
                  <td class="px-2 py-1 text-muted">{run_type_words(candidate.run)}</td>
                  <td class="px-2 py-1 tabular-nums">
                    {slot_time(candidate.run.work.sign_on_secs)}
                  </td>
                  <td class="px-2 py-1 tabular-nums">
                    {run_off_time(candidate.run.work.sign_off_secs)}
                  </td>
                  <td class="px-2 py-1 text-right tabular-nums">
                    {hours_minutes(candidate.run.work.paid_secs)}
                  </td>
                  <td class="px-2 py-1 tabular-nums">
                    <.rest_cell
                      candidate={candidate}
                      side={:before}
                      min_rest_minutes={@min_rest_minutes}
                    />
                  </td>
                  <td class="px-2 py-1 tabular-nums">
                    <.rest_cell
                      candidate={candidate}
                      side={:after}
                      min_rest_minutes={@min_rest_minutes}
                    />
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </fieldset>

        <.message
          :if={@candidates == []}
          id="rosters-slot-full"
          kind="neutral"
          title={"Every #{@day_name} run is in a line."}
        >
          Clear this day in another line to free a run, or leave this day off.
        </.message>

        <.message
          :if={@refusal}
          id="rosters-slot-refusal"
          kind="error"
          title="Nothing was saved."
        >
          {@refusal}
        </.message>
      </.drawer_scroll>

      <.drawer_footer>
        <.button
          :if={@current}
          type="button"
          id="rosters-clear-day"
          variant="secondary"
          class="mr-auto min-h-11"
          phx-click="clear_day"
          phx-disable-with="Clearing…"
          disabled={@pending?}
        >
          Clear day
        </.button>

        <p
          :if={group_action?(@group, @candidates)}
          id="rosters-group-reason"
          class="basis-full text-right text-[13px] text-muted empty:hidden"
          aria-live="polite"
        >
          {group_reason(@group_state, @selected_run_id, @weekday, @line, @min_rest_minutes)}
        </p>

        <.button
          :if={group_action?(@group, @candidates)}
          type="button"
          id="rosters-set-group"
          variant="secondary"
          class="min-h-11"
          phx-click="set_group"
          phx-disable-with="Saving…"
          disabled={@pending? or not group_available?(@group_state)}
          aria-describedby={if group_available?(@group_state), do: nil, else: "rosters-group-reason"}
        >
          Set {@group_label} to run {@selected_run_id}
        </.button>

        <.button
          :if={@candidates != []}
          type="button"
          id="rosters-set-day"
          class="min-h-11"
          phx-click="set_day"
          phx-disable-with="Saving…"
          disabled={@pending? or is_nil(@selected_run_id)}
        >
          Set {@day_name} to run {@selected_run_id}
        </.button>
      </.drawer_footer>
    </.drawer>
    """
  end

  # The group action belongs to a group of two or more weekdays and to a drawer
  # with something to set. A single-day group has no rule behind it, so
  # `Candidates` refuses it and the page does not offer a button whose only
  # possible answer is a refusal.
  defp group_action?(group, candidates) do
    candidates != [] and not is_nil(group) and length(group.weekdays) > 1
  end

  defp group_available?(:ok), do: true
  defp group_available?(_state), do: false

  defp group_reason(:ok, _run_id, _weekday, _line, _min), do: nil

  defp group_reason({:error, refusal}, run_id, weekday, line, min_rest_minutes) do
    refusal_text(refusal, %{
      run_id: run_id,
      weekday: weekday,
      line_number: line.line_number,
      min_rest_minutes: min_rest_minutes
    })
  end

  defp group_reason(nil, _run_id, _weekday, _line, _min), do: nil

  defp group_label(%{group: %{label: label}}), do: label
  defp group_label(_assigns), do: ""

  defp current_run?(nil, _run_id), do: false
  defp current_run?(%{run_id: run_id}, run_id), do: true
  defp current_run?(_current, _run_id), do: false

  # The rest a candidate would leave on one side. A day off is a muted em dash:
  # there is no neighbour, so there is nothing to be short of. A side under the
  # minimum is measured *and* marked, because the triangle is what a reader
  # scanning the column is looking for, and the words behind it are what a screen
  # reader needs — the mark alone would be a shape with no fact.
  #
  # The threshold is the version's own `rules.min_rest_minutes`, read from the
  # roster and compared here per **side**, because `Candidates`' `short?` is a
  # property of the pair and this column has one cell per side. The availability
  # decisions themselves stay with `Candidates`; this only says which of the two
  # numbers is the low one.
  attr :candidate, :map, required: true
  attr :side, :atom, required: true, values: [:before, :after]
  attr :min_rest_minutes, :integer, required: true

  def rest_cell(assigns) do
    assigns =
      assigns
      |> Map.merge(%{
        secs: Map.get(assigns.candidate, rest_key(assigns.side))
      })

    assigns = Map.put(assigns, :short?, short_rest?(assigns))

    ~H"""
    <span :if={is_nil(@secs)} class="text-muted">—</span>
    <span :if={@secs} class={@short? && "rosters-rest-short"}>
      <span :if={@short?} aria-hidden="true">△ </span>{rest_hours(@secs)}<span
        :if={@short?}
        class="sr-only"
      > (under the minimum)</span>
    </span>
    """
  end

  defp short_rest?(%{secs: nil}), do: false

  defp short_rest?(%{secs: secs, min_rest_minutes: min_rest_minutes}) do
    secs < min_rest_minutes * @seconds_per_minute
  end

  defp rest_key(:before), do: :rest_before_secs
  defp rest_key(:after), do: :rest_after_secs

  # A run's sign-off on the same service-day clock the grid uses, so a run that
  # ends after midnight reads as the next morning rather than as before it
  # started.
  defp run_off_time(sign_off_secs) do
    slot_time(if sign_off_secs < 0, do: sign_off_secs + @seconds_per_day, else: sign_off_secs)
  end

  defp run_type_words(%{work: %{type: :one_piece}}), do: "One piece"
  defp run_type_words(%{work: %{type: :straight}}), do: "Straight"
  defp run_type_words(%{work: %{type: :split}}), do: "Split"
  defp run_type_words(_run), do: "—"

  defp stale_reason(nil), do: nil
  defp stale_reason(%{state: {:stale, reason}}), do: reason
  defp stale_reason(_slot), do: nil

  defp slot_stale_title(%{run_id: run_id}), do: "Run #{run_id} is stale."

  # The three stale reasons, each with the next move. The run's own times are
  # named when it still has any, because "the run changed" is a difference the
  # planner can only act on if they can see both ends of it.
  defp stale_note(%{run_id: run_id} = slot, :run_changed, _group_label, day_name) do
    "#{stale_sentence(slot, :run_changed)} Set #{day_name} to run #{run_id} to keep it with the " <>
      "new times, or choose another run."
  end

  defp stale_note(_slot, :run_removed, group_label, day_name) do
    "The run no longer exists. Choose another #{group_label} run for #{day_name}, or clear the day." <>
      " Until then the export skips this day."
  end

  defp stale_note(_slot, :base_changed, group_label, day_name) do
    "The base week changed for that day. Choose a #{group_label} run for #{day_name}, or clear " <>
      "the day. Until then the export skips this day."
  end

  defp plural_days(1), do: "1 working day"
  defp plural_days(count), do: "#{count} working days"

  @doc """
  The "Add to line" drawer: an open run's day, and the lines that have it off.

  Everything in it is somebody else's answer. The run, its times and the days it
  is open on are the composition's own `open_runs` entry (INV-15), the lines are
  `Rosters.Candidates.lines_for_open_run/3` in that function's order — lines
  where the run keeps every rest first, then the least paid time — and the rest
  either side of each row is the same `rest_cell/1` the slot drawer prints, so a
  number means the same thing in both drawers.

  ## The day comes first when there is a choice to make

  A run open on several weekdays has a day to choose before it has a line to
  choose, so the day choice is drawn above the list and leads the selection: one
  day open means no choice at all and the drawer says which day it is about.

  ## The footer is one primary

  "Create new line" at the opposite edge, Cancel, then the one primary. The
  primary is disabled when the drawer has no line to add to, and the panel above
  it says why — the same rule the slot drawer follows, and for the same reason:
  a control that vanishes leaves the planner looking for it.
  """
  attr :open, :boolean, required: true
  attr :run, :map, required: true, doc: "the run the composition holds open"
  attr :open_weekdays, :list, required: true, doc: "the weekdays of its group it is open on"
  attr :weekday, :integer, required: true, doc: "the day this list is for"
  attr :lines, :list, required: true, doc: "`Candidates.lines_for_open_run/3` rows"
  attr :selected_line_id, :string, default: nil
  attr :day_type_label, :string, required: true
  attr :group_label, :string, required: true
  attr :pending?, :boolean, default: false
  attr :refusal, :string, default: nil
  attr :min_rest_minutes, :integer, required: true
  attr :on_close, :string, default: "close_add_to_line"

  def add_to_line_drawer(assigns) do
    assigns =
      assigns
      |> assign(:run_id, assigns.run.run_id)
      |> assign(:day_name, weekday_name(assigns.weekday))
      |> assign(:selected, selected_add_line(assigns))

    ~H"""
    <.drawer
      id="rosters-add-to-line-drawer"
      chrome="planner"
      open={@open}
      pending={@pending?}
      on_close={@on_close}
      class="max-w-[min(100vw,52rem)]"
      title={"Add run #{@run_id} to a line"}
      return_focus_id={"rosters-add-to-line-#{@run_id}"}
    >
      <:lede>
        <span id="rosters-add-lede">{@day_type_label} · {@group_label}</span>
      </:lede>

      <.drawer_scroll>
        <p id="rosters-add-run" class="text-sm">
          <strong class="text-strong">Run {@run_id}</strong>
          · {run_type_words(@run)} ·
          <span class="tabular">
            {slot_span(@run.work)} · {hours_minutes(@run.work.paid_secs)} paid
          </span>
        </p>

        <fieldset
          :if={length(@open_weekdays) > 1}
          id="rosters-add-day"
          class="min-w-0"
        >
          <legend class="text-[13px] font-[650] text-default">Day</legend>
          <p class="text-[13px] text-muted">
            Run {@run_id} is open on {plural_open_days(length(@open_weekdays))}.
          </p>
          <div
            role="group"
            aria-label="Day to add"
            class="mt-2 inline-flex flex-wrap rounded-control border border-control bg-white p-0.5"
          >
            <button
              :for={day <- @open_weekdays}
              type="button"
              id={"rosters-add-day-#{day}"}
              data-day={day}
              aria-pressed={to_string(day == @weekday)}
              aria-label={weekday_name(day)}
              phx-click="choose_add_day"
              phx-value-weekday={day}
              class="min-h-11 min-w-11 rounded-[4px] px-3 text-sm font-semibold text-muted hover:text-strong aria-pressed:bg-navy-800 aria-pressed:text-white"
            >
              {short_day(day)}
            </button>
          </div>
        </fieldset>

        <p :if={length(@open_weekdays) == 1} id="rosters-add-day-only" class="text-sm">
          Open on {@day_name} only.
        </p>

        <div :if={@lines != []}>
          <h3 class="text-base font-bold">Lines with {@day_name} off</h3>
          <p class="mt-1 text-[13px] text-muted">
            Lines where it keeps the minimum rest come first, then the lines with the fewest paid
            hours. Minimum rest is {minutes(@min_rest_minutes)}.
          </p>
          <div class="mt-3 overflow-x-auto rounded-card border border-subtle">
            <table class="w-full border-separate border-spacing-0 text-sm">
              <caption class="sr-only">Lines with {@day_name} off</caption>
              <thead>
                <tr class="bg-canvas text-left text-[13px] text-muted">
                  <th scope="col" class="px-2 py-2 font-semibold">Line</th>
                  <th scope="col" class="px-2 py-2 font-semibold">Works</th>
                  <th scope="col" class="px-2 py-2 text-right font-semibold">Paid now</th>
                  <th scope="col" class="px-2 py-2 font-semibold">Rest before</th>
                  <th scope="col" class="px-2 py-2 font-semibold">Rest after</th>
                </tr>
              </thead>
              <tbody id="rosters-add-line-rows">
                <tr
                  :for={row <- @lines}
                  id={"rosters-add-line-#{row.line.line_number}"}
                  class="rosters-pick-row"
                  data-line-id={row.line.id}
                  data-selected={to_string(row.line.id == @selected_line_id)}
                  data-short={to_string(row.short?)}
                >
                  <td class="px-2 py-1">
                    <label class="flex min-h-11 cursor-pointer items-center gap-2.5">
                      <input
                        type="radio"
                        id={"rosters-add-line-choice-#{row.line.line_number}"}
                        name="rosters-add-line"
                        value={row.line.id}
                        checked={row.line.id == @selected_line_id}
                        phx-click="choose_add_line"
                        phx-value-line={row.line.id}
                        class="size-5 accent-action"
                      />
                      <span class="font-bold text-strong">Line {row.line.line_number}</span>
                      <span class="text-[13px] text-muted">
                        {if row.line.operator, do: "Assigned", else: "Open"}
                      </span>
                    </label>
                  </td>
                  <td class="px-2 py-1">
                    {plural_working_days(map_size(row.line.slots))}
                    <span class="text-muted">
                      · off {days_off_text(row.line)}
                    </span>
                  </td>
                  <td class="px-2 py-1 text-right tabular-nums">
                    {hours_minutes(row.line.paid_secs)}
                  </td>
                  <td class="px-2 py-1 tabular-nums">
                    <.rest_cell candidate={row} side={:before} min_rest_minutes={@min_rest_minutes} />
                  </td>
                  <td class="px-2 py-1 tabular-nums">
                    <.rest_cell candidate={row} side={:after} min_rest_minutes={@min_rest_minutes} />
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>

        <.message
          :if={@lines == []}
          id="rosters-add-no-line"
          kind="neutral"
          title={"No line has #{@day_name} off."}
        >
          Create a new line for this run.
        </.message>

        <.message
          :if={@refusal}
          id="rosters-add-refusal"
          kind="error"
          title="Nothing was saved."
        >
          {@refusal}
        </.message>
      </.drawer_scroll>

      <.drawer_footer>
        <.button
          type="button"
          id="rosters-add-new-line"
          variant="secondary"
          class="mr-auto min-h-11"
          phx-click="add_to_new_line"
          phx-disable-with="Creating…"
          disabled={@pending?}
        >
          Create new line
        </.button>

        <.button type="button" variant="secondary" class="min-h-11" phx-click={@on_close}>
          Cancel
        </.button>

        <.button
          type="button"
          id="rosters-add-confirm"
          class="min-h-11"
          phx-click="add_to_line"
          phx-disable-with="Saving…"
          disabled={@pending? or is_nil(@selected_line_id)}
        >
          {if @selected_line_id,
            do: "Add to line #{selected_line_number(@lines, @selected_line_id)}",
            else: "Add to line"}
        </.button>
      </.drawer_footer>
    </.drawer>
    """
  end

  # The row the primary button names: the drawer's own selection, or the first
  # row `Candidates` offered when nothing has been chosen. It is drawn rather
  # than stored twice, so the button and the checked radio cannot disagree.
  defp selected_add_line(%{selected_line_id: nil, lines: [%{line: line} | _rest]}), do: line.id
  defp selected_add_line(%{selected_line_id: line_id}), do: line_id

  defp selected_line_number(lines, line_id) do
    case Enum.find(lines, &(&1.line.id == line_id)) do
      %{line: %{line_number: number}} -> number
      _no_line -> nil
    end
  end

  # The column counts working days, so it says "days" rather than the grid's
  # "working days": it sits beside "Paid now", where the reader is comparing two
  # lines rather than reading one line's week.
  defp plural_working_days(1), do: "1 day"
  defp plural_working_days(count), do: "#{count} days"

  defp plural_open_days(1), do: "1 day"
  defp plural_open_days(count), do: "#{count} days"

  @doc """
  The line drawer: one line's whole week, and the one destructive action on it.

  Everything drawn here is the composition's own line: its slots, its weekly
  figures, its days off and its findings. The week table reads the same slot
  helpers the grid's cells read, so a day says the same thing in the drawer as
  it does in the row (INV-15).

  ## The problems come first, and in words

  The Problems column names the first finding and hides the rest behind a
  count; a drawer is where the whole list is read. Each finding is a message
  whose title is the column's own words and whose body is that column's own
  sentence, so neither place can describe the same finding differently. A line
  with no findings says so in words rather than leaving the reader to notice
  the absence.

  ## The footer holds one action, at the opposite edge

  "Delete line" is destructive to the whole week rather than to one day of it,
  so it sits at the far end of the footer away from where the primary actions
  of the other drawers are, and it is the only control here: the week is read
  from this drawer and changed in the grid.
  """
  attr :open, :boolean, required: true
  attr :line, :map, required: true
  attr :pending?, :boolean, default: false
  attr :locked?, :boolean, default: false
  attr :on_close, :string, default: "close_line"

  def line_drawer(assigns) do
    ~H"""
    <.drawer
      id="rosters-line-drawer"
      chrome="planner"
      open={@open}
      pending={@pending?}
      on_close={@on_close}
      title={"Line #{@line.line_number}"}
      return_focus_id={"rosters-line-#{@line.line_number}-open"}
    >
      <:lede>
        <span id="rosters-line-lede">
          {if @line.operator, do: "Assigned", else: "Open"} · {plural_days(map_size(@line.slots))}
        </span>
      </:lede>

      <.drawer_scroll>
        <div id="rosters-line-problems" class="grid gap-2">
          <.message
            :if={@line.findings == []}
            id="rosters-line-no-problems"
            kind="success"
            title="No problems"
          />
          <.message
            :for={finding <- @line.findings}
            id={finding_id(finding)}
            kind={finding_kind(finding)}
            title={"#{finding_words(finding)}."}
          >
            {finding_sentence(finding)}
          </.message>
        </div>

        <dl id="rosters-line-facts" class="mt-5 grid grid-cols-3 gap-4">
          <div>
            <dt class="text-[13px] text-muted">Operator</dt>
            <dd :if={@line.operator} class="mt-0.5 text-sm font-semibold text-strong">
              {@line.operator.display_name}
              <span class="font-mono text-[13px] font-normal text-muted">
                {@line.operator.employee_id}
              </span>
            </dd>
            <dd :if={is_nil(@line.operator)} class="mt-0.5 text-sm font-semibold text-strong">
              Open
            </dd>
          </div>
          <div>
            <dt class="text-[13px] text-muted">Days off</dt>
            <dd class="mt-0.5 text-sm font-semibold text-strong">{days_off_text(@line)}</dd>
          </div>
          <div>
            <dt class="text-[13px] text-muted">Weekly paid</dt>
            <dd class="mt-0.5 text-sm font-semibold text-strong">
              {paid_text(@line)}
              <span :if={@line.over_40_secs > 0} class="font-normal text-muted">
                {over_text(@line)}
              </span>
            </dd>
          </div>
        </dl>

        <h3 class="mt-6 text-base font-bold">Week</h3>
        <div class="mt-2 overflow-x-auto rounded-card border border-subtle">
          <table class="w-full border-separate border-spacing-0 text-sm">
            <caption class="sr-only">Line {@line.line_number} week</caption>
            <thead>
              <tr class="bg-canvas text-left text-[13px] text-muted">
                <th scope="col" class="px-2 py-2 font-semibold">Day</th>
                <th scope="col" class="px-2 py-2 font-semibold">Run</th>
                <th scope="col" class="px-2 py-2 font-semibold">Sign-on–off</th>
                <th scope="col" class="px-2 py-2 text-right font-semibold">Paid</th>
              </tr>
            </thead>
            <tbody id="rosters-line-week">
              <tr
                :for={weekday <- 1..7}
                id={"rosters-line-week-#{weekday}"}
                data-day={weekday}
                data-state={line_day_state(@line, weekday)}
              >
                <th scope="row" class="px-2 py-1 text-left font-semibold">
                  {weekday_name(weekday)}
                </th>
                <td :if={is_nil(Map.get(@line.slots, weekday))} class="px-2 py-1 text-muted">
                  Off
                </td>
                <td :if={Map.get(@line.slots, weekday)} class="px-2 py-1">
                  <span :if={line_day_stale?(@line, weekday)} class="rosters-warning-text">
                    <span aria-hidden="true">△ </span>
                    {Map.fetch!(@line.slots, weekday).run_id} · Stale run
                  </span>
                  <span :if={not line_day_stale?(@line, weekday)}>
                    <strong class="text-strong">
                      {Map.fetch!(@line.slots, weekday).run_id}
                    </strong>
                    <span class="text-[13px] text-muted">
                      {run_type_words(Map.fetch!(@line.slots, weekday).run)}
                    </span>
                  </span>
                </td>
                <td class="px-2 py-1 tabular-nums">
                  <span :if={line_day_run(@line, weekday)}>
                    {slot_span(line_day_run(@line, weekday).work)}
                  </span>
                </td>
                <td class="px-2 py-1 text-right tabular-nums">
                  <span :if={line_day_run(@line, weekday)}>
                    {hours_minutes(line_day_run(@line, weekday).work.paid_secs)}
                  </span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <p id="rosters-line-week-hint" class="mt-3 text-[13px] text-muted">
          Select a day in the grid to change its run.
        </p>
      </.drawer_scroll>

      <.drawer_footer>
        <.button
          type="button"
          id="rosters-delete-line"
          variant="danger"
          class="mr-auto min-h-11"
          phx-click="ask_delete_line"
          phx-disable-with="Deleting…"
          disabled={@locked?}
        >
          <.icon name="hero-trash" class="size-4" />Delete line
        </.button>
      </.drawer_footer>
    </.drawer>
    """
  end

  # One message per finding, so the id has to name which one it is: the code,
  # and the days it is about where the finding places itself in the week. A
  # finding that names no day — no two days off in a row is about the whole
  # line — is identified by its code alone.
  defp finding_id(%{code: code, weekdays: []}), do: "rosters-line-problem-#{code}"

  defp finding_id(%{code: code, weekdays: weekdays}),
    do: "rosters-line-problem-#{code}-#{Enum.join(weekdays, "-")}"

  # A run with errors is the one finding that is an error rather than a warning,
  # and it is the composition's own finding that says so — the same code the
  # Problems column reads its red from.
  defp finding_kind(%{code: :run_has_errors}), do: "error"
  defp finding_kind(_finding), do: "warning"

  # A stale slot is a working day the composition will not trust, so it is a
  # third state rather than either of the two the row can be in.
  defp line_day_state(line, weekday) do
    case Map.get(line.slots, weekday) do
      nil -> "off"
      slot -> if(is_nil(stale_reason(slot)), do: "work", else: "stale")
    end
  end

  defp line_day_stale?(line, weekday) do
    case Map.get(line.slots, weekday) do
      nil -> false
      slot -> not is_nil(stale_reason(slot))
    end
  end

  # A stale slot's stored times are untrusted, so it shows its run ID and says
  # why, rather than printing times the composition has already disowned.
  defp line_day_run(line, weekday) do
    case Map.get(line.slots, weekday) do
      %{run: run} -> if(line_day_stale?(line, weekday), do: nil, else: run)
      _off -> nil
    end
  end

  @doc """
  The delete-line confirmation: what goes, what comes back, and the two answers.

  `CoreComponents.confirm_dialog/1` in planner chrome, as the Garages delete
  confirmation is. The title names the line the planner clicked, and the body
  names the consequence in the same run-days the drawer counts — `run_days` is
  the number of stored days, which is what returns to open work, and the pick
  sentence appears only when there is a pick to remove.

  "Keep line" is the cancel and is first, so the reading order puts the safe
  answer before the destructive one; "Delete line" is the confirm and keeps the
  dialog's own danger treatment. Focus goes back to the Delete line button that
  asked, unless the delete happens, and then the page's own focus push takes it
  to the grid heading.
  """
  attr :open, :boolean, required: true
  attr :line_number, :integer, required: true
  attr :run_days, :integer, required: true
  attr :picked?, :boolean, default: false
  attr :on_confirm, :string, default: "confirm_delete_line"
  attr :on_cancel, :string, default: "cancel_delete_line"

  def delete_line_confirm(assigns) do
    ~H"""
    <.confirm_dialog
      id="rosters-delete-line-confirm"
      chrome="planner"
      open={@open}
      title={"Delete line #{@line_number}?"}
      confirm_label="Delete line"
      cancel_label="Keep line"
      pending_label="Deleting…"
      on_confirm={@on_confirm}
      on_cancel={@on_cancel}
      return_focus_id="rosters-delete-line"
    >
      <p>
        Its {plural_run_days(@run_days)} to open work.{if @picked?,
          do: " The pick recorded for this line is removed.",
          else: ""}
      </p>
    </.confirm_dialog>
    """
  end

  @doc """
  The run-day count's words, for a page that has to say them outside this
  module.

  The confirmation reads this, and so does the toast that reports the delete
  happened, so the count the planner was warned about and the count they are
  told afterwards are one string rather than two that can drift. It is the whole
  clause — the count and the verb it needs — because the count and the verb
  have to agree in both places.
  """
  def plural_run_days(1), do: "1 run-day returns"
  def plural_run_days(count), do: "#{count} run-days return"
end
