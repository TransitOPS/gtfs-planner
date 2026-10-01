defmodule GtfsPlannerWeb.Gtfs.RostersComponents do
  @moduledoc """
  Function components for Operations › Rosters.

  The page's head and its states live here so `GtfsPlannerWeb.Gtfs.RostersLive`
  stays a small state owner. The head and the two states below it are the whole
  of this step: the scope bar, count strip, grid, open work and export section
  arrive with the steps that own them, and each is a new function in this module
  rather than a branch inside the LiveView's `render/1`.

  The markup follows the design system the restyled Blocks page uses: the page
  carries the shared `.ds-page` scope, the head uses `CoreComponents`'s
  `header/1` and `button/1`, the states are `PlannerComponents` panels and the
  loading skeleton is `CoreComponents.skeleton/1` with its own bars. The
  prototype (`.specs/09-basic-rosters/references/rosters-prototype.html`) is the
  authority for the copy and the hierarchy; it is not reproduced here, because
  its sample data, its state switcher and its simulation are prototype-only.

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

  @weekdays ~w(Mon Tue Wed Thu Fri Sat Sun)

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
