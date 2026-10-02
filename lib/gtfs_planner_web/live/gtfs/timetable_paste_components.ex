defmodule GtfsPlannerWeb.Gtfs.TimetablePasteComponents do
  @moduledoc """
  Presentation for the Paste timetable page shell.

  Step 21 owns the shell: the schedule line (`scope_line/1`), the setup
  empty states (`setup_empty/1`) and the first-paint skeleton. Step 22 owns
  the Change schedule drawer (`scope_drawer/1`): the calendar select over
  every calendar, the direction radios and the direction-filtered pattern
  select with trip counts. Step 23 owns the Timetable step (`source_step/1`):
  the paste form textarea, hint, Layout disclosure, Read timetable, inline
  errors and the collapsed summary, plus the review placeholder steps 25-28
  replace with real UI. Step 24 owns the Columns step (`columns_step/1`):
  the pasted grid with a Use-as select per column, status badges with
  one-line reasons, Confirm match for close matches, the Review-trips error
  summary, the all-unmatched layout hint and the pattern stop strip. Step 25
  owns the Review header (`review_header/1`): How to apply, Fill other stops
  from, Stops view, the three metrics, the refusal and nothing callouts
  and the filter buttons. Step 26 owns the review matrix
  (`review_matrix/1`): the streamed timetable rows with change badges,
  pasted and estimated times, was-values, removals and the timing note.
  Step 27 owns the row decisions (`row_decision/1`): the pattern select,
  the cell correction, the twelve-hour choice, the pairing radios, skip
  and restore, and Add anyway, plus the discarded-decisions notice.
  Step 28 owns the apply bar (`apply_bar/1`), the apply outcome notices
  (`notices/1`) and the Replace and Discard confirmations
  (`replace_confirm/1`, `discard_confirm/1`). Step 30 owns the leave and
  version-switch guards: the switch and leave confirmations
  (`switch_confirm/1`, `leave_confirm/1`), the colocated
  `.PasteLeaveGuard` hook (`leave_guard/1`) that intercepts tab, header
  and version-switcher navigation plus `beforeunload` while the form holds
  text, and the Open Schedules link's dirty-only `data-confirm`.
  """
  use GtfsPlannerWeb, :html

  alias Phoenix.LiveView.JS

  import GtfsPlannerWeb.PlannerComponents,
    only: [first_use: 1, drawer_scroll: 1, drawer_footer: 1, message: 1]

  alias GtfsPlanner.Gtfs.GtfsTime
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Wording
  alias GtfsPlannerWeb.Gtfs.TimetablePasteReview

  # Small decision buttons follow the prototype's secondary small button:
  # keyboard-operable at 44 px with a visible label.
  @decision_button_class "inline-flex min-h-11 items-center justify-center gap-1.5 rounded-control border border-control bg-white px-3 text-[13px] font-[650] text-strong hover:bg-canvas"

  @doc """
  Renders the schedule line: the resolved Calendar, Direction and Pattern plus
  the Change schedule button that opens the scope drawer (step 22).

  A missing calendar or pattern renders the prototype's "None yet" / "None in
  this direction" placeholders; the matching setup empty state renders below
  the line.
  """
  attr :calendar, :map, default: nil, doc: "the resolved scope calendar, if any"
  attr :direction_name, :string, required: true, doc: "Outbound or Inbound"
  attr :pattern, :map, default: nil, doc: "the chosen direction pattern, if any"

  def scope_line(assigns) do
    ~H"""
    <section
      id="paste-scope"
      aria-label="Schedule"
      class="flex flex-wrap items-center gap-x-10 gap-y-3 rounded-card border border-subtle bg-white px-5 py-3"
    >
      <dl class="flex flex-wrap gap-x-10 gap-y-3">
        <div id="paste-scope-calendar" class="min-w-0">
          <dt class="text-[13px] text-muted">Calendar</dt>
          <dd class="mt-0.5 text-sm font-semibold text-strong">
            <%= if @calendar do %>
              {@calendar.name}
              <span :if={calendar_detail(@calendar)} class="font-normal text-muted">
                {calendar_detail(@calendar)}
              </span>
            <% else %>
              None yet
            <% end %>
          </dd>
        </div>
        <div id="paste-scope-direction" class="min-w-0">
          <dt class="text-[13px] text-muted">Direction</dt>
          <dd class="mt-0.5 text-sm font-semibold text-strong">{@direction_name}</dd>
        </div>
        <div id="paste-scope-pattern" class="min-w-0">
          <dt class="text-[13px] text-muted">Pattern</dt>
          <dd class="mt-0.5 text-sm font-semibold text-strong">
            <%= if @pattern do %>
              {@pattern.name}
              <span class="font-normal text-muted">
                {case @pattern do
                  %{occurrences: occurrences} when is_list(occurrences) ->
                    Wording.count_noun(length(occurrences), "stop")

                  _pattern ->
                    nil
                end}
              </span>
            <% else %>
              None in this direction
            <% end %>
          </dd>
        </div>
      </dl>
      <.button
        id="paste-scope-open"
        variant="secondary"
        class="ml-auto min-h-11"
        phx-click="open_scope_drawer"
      >
        Change schedule
      </.button>
    </section>
    """
  end

  @doc """
  Renders the setup empty state when pasting cannot start: the version has no
  calendars (`:no_calendar`) or the chosen direction has no patterns
  (`:no_pattern`). Each state carries the one link that unblocks it.
  """
  attr :reason, :atom, values: [:no_calendar, :no_pattern], required: true
  attr :route_label, :string, required: true, doc: "Route 12 style label"
  attr :direction_adjective, :string, default: "outbound", doc: "outbound or inbound"
  attr :calendars_path, :string, required: true, doc: "where Create calendar goes"
  attr :patterns_path, :string, required: true, doc: "where Create pattern goes"

  def setup_empty(assigns) do
    ~H"""
    <div class="mt-4">
      <.first_use
        :if={@reason == :no_calendar}
        id="paste-setup-empty"
        title="This version has no calendars yet"
        icon="hero-calendar-days"
      >
        A calendar sets the days trips run. Create one, then paste the timetable for it.
        <:action>
          <.button navigate={@calendars_path} class="min-h-11">
            <.icon name="hero-plus" class="size-4" /> Create calendar
          </.button>
        </:action>
      </.first_use>
      <.first_use
        :if={@reason == :no_pattern}
        id="paste-setup-empty"
        title={"#{@route_label} has no #{@direction_adjective} pattern yet"}
        icon="hero-map"
      >
        A pattern sets the stops a trip calls at and their order. Pasted times are matched
        to its stops, so create one before pasting, or change the direction.
        <:action>
          <.button navigate={@patterns_path} class="min-h-11">
            <.icon name="hero-plus" class="size-4" /> Create pattern
          </.button>
        </:action>
      </.first_use>
    </div>
    """
  end

  @doc "Renders the first-paint skeleton shown before the LiveView connects."
  def loading_skeleton(assigns) do
    ~H"""
    <div id="paste-loading" role="status" aria-label="Loading paste timetable" class="mt-6">
      <div class="flex flex-wrap items-center gap-x-10 gap-y-3" aria-hidden="true">
        <div class="grid min-w-0 gap-2">
          <span class="h-4 w-24 rounded-badge bg-canvas"></span>
          <span class="h-6 w-64 rounded-badge bg-canvas"></span>
        </div>
        <span class="ml-auto h-11 w-36 rounded-badge bg-canvas"></span>
      </div>
    </div>
    """
  end

  @doc """
  Renders the Change schedule drawer: the draft Calendar, Direction and
  Pattern that `change_schedule` patches into the URL while the paste stays.

  The drawer is the workspace `drawer/1` (planner chrome) with
  `return_focus_id` set to the Change schedule button, so Close, Cancel,
  Escape and the backdrop all return focus to `#paste-scope-open`. The
  calendar select lists every calendar, including dates-only ones; the
  direction radios carry the direction labels; the pattern select lists the
  draft direction's patterns with their trip counts on the draft calendar.
  When a review already exists, a warning names the rebuild.

  Direction uses native radio inputs: `CoreComponents.input/1` documents
  radio as unsupported ("best written directly in your templates"), and
  the calendar and route-form components already write native radios the
  same way.
  """
  attr :open, :boolean, required: true, doc: "the drawer is requested open"
  attr :form, :any, required: true, doc: "the draft scope form from `to_form`"
  attr :calendars, :list, required: true, doc: "every calendar summary"
  attr :draft_scope, :map, default: nil, doc: "the prepared draft scope, if any"
  attr :review, :any, default: nil, doc: "the current paste review, if any"
  attr :route_label, :string, required: true, doc: "Route 12 style label"

  def scope_drawer(assigns) do
    assigns =
      assigns
      |> assign(:calendar_options, calendar_options(assigns.calendars))
      |> assign(:direction_options, direction_options(draft_trips(assigns.draft_scope)))
      |> assign(:pattern_options, pattern_options(assigns.draft_scope))
      |> assign(:direction_value, assigns.form[:direction].value)

    ~H"""
    <.drawer
      id="paste-scope-drawer"
      chrome="planner"
      open={@open}
      title="Change schedule"
      on_close="close_scope_drawer"
      initial_focus={:first_field}
      return_focus_id="paste-scope-open"
      class="max-w-[480px]"
    >
      <:lede>Route {@route_label} · the trips your paste adds or replaces</:lede>
      <.form
        :if={@open}
        for={@form}
        id="paste-scope-form"
        phx-change="scope_draft_change"
        phx-submit="change_schedule"
        class="flex min-h-0 flex-1 flex-col"
      >
        <.drawer_scroll>
          <.message
            :if={@review}
            id="paste-scope-rebuild-warning"
            kind="warning"
            title="Changing the schedule rebuilds the review"
          >
            Your paste stays; columns are matched again.
          </.message>
          <.input
            field={@form[:service_id]}
            id="paste-scope-calendar-field"
            type="select"
            label="Calendar"
            options={@calendar_options}
            help="Pasted trips run on this calendar's days."
          />
          <fieldset id="paste-scope-direction-field">
            <legend class="text-[13px] font-[650] text-strong">Direction</legend>
            <div class="mt-1.5 grid gap-1">
              <label
                :for={option <- @direction_options}
                class="inline-flex min-h-11 items-center gap-2 text-sm"
              >
                <input
                  type="radio"
                  id={"paste-scope-direction-field-#{option.value}"}
                  name={@form[:direction].name}
                  value={option.value}
                  checked={@direction_value == option.value}
                  class="size-4 accent-action"
                />
                {option.label}
              </label>
            </div>
          </fieldset>
          <.input
            field={@form[:pattern]}
            id="paste-scope-pattern-field"
            type="select"
            label="Pattern"
            options={@pattern_options}
            help={pattern_help(@direction_value)}
          />
        </.drawer_scroll>
        <.drawer_footer>
          <.button type="button" variant="secondary" phx-click="close_scope_drawer">
            Cancel
          </.button>
          <.button type="submit" id="paste-scope-apply">Use schedule</.button>
        </.drawer_footer>
      </.form>
    </.drawer>
    """
  end

  defp draft_trips(%{trips: trips}), do: trips
  defp draft_trips(_draft_scope), do: []

  defp calendar_options(calendars) do
    Enum.map(calendars, fn calendar ->
      {calendar_option_label(calendar), calendar.service_id}
    end)
  end

  defp calendar_option_label(calendar) do
    base = calendar.name || calendar.service_id
    kind = if calendar.kind == :dates_only, do: " · Specific dates", else: ""
    "#{base}#{kind}#{calendar_dates(calendar)}"
  end

  defp calendar_dates(%{first_active_date: %Date{} = first, last_active_date: %Date{} = last}) do
    " · #{date_span_label(first, last)}"
  end

  defp calendar_dates(_calendar), do: ""

  # A range keeps both ends; a single date reads once. `Wording.date/1` formats each end.
  defp date_span_label(date, date), do: Wording.date(date)

  defp date_span_label(first, last), do: "#{Wording.date(first)} – #{Wording.date(last)}"

  defp direction_options(trips) do
    for direction_id <- [0, 1] do
      %{value: to_string(direction_id), label: scope_direction_label(trips, direction_id)}
    end
  end

  defp scope_direction_label(trips, direction_id) do
    base = Trip.direction_label(direction_id)

    case common_headsign(trips, direction_id) do
      nil -> base
      headsign -> "#{base} · to #{headsign}"
    end
  end

  defp common_headsign(trips, direction_id) do
    headsigns =
      trips
      |> Enum.filter(&(&1.direction_id == direction_id))
      |> Enum.map(& &1.trip_headsign)
      |> Enum.reject(&(&1 in [nil, ""]))

    case headsigns do
      [] ->
        nil

      headsigns ->
        counts = Enum.frequencies(headsigns)
        most = counts |> Map.values() |> Enum.max()

        counts
        |> Enum.filter(fn {_headsign, count} -> count == most end)
        |> Enum.map(&elem(&1, 0))
        |> Enum.min_by(&{String.downcase(&1), &1})
    end
  end

  defp pattern_options(%{patterns: patterns, trips: trips}) do
    Enum.map(patterns, fn pattern ->
      count = Enum.count(trips, &(&1.route_pattern_id == pattern.route_pattern_id))
      {"#{pattern.name} · #{Wording.count_noun(count, "trip")}", pattern.id}
    end)
  end

  defp pattern_options(_draft_scope), do: []

  defp pattern_help("1"), do: pattern_help_text("inbound")
  defp pattern_help(_direction), do: pattern_help_text("outbound")

  defp pattern_help_text(adjective) do
    "Columns are matched to its stops. A row that skips stops goes on another #{adjective} " <>
      "pattern when exactly one fits."
  end

  defp calendar_detail(%{first_active_date: %Date{} = first, last_active_date: %Date{} = last}) do
    "#{Wording.date(first)} – #{Wording.date(last)}"
  end

  defp calendar_detail(_calendar), do: nil

  @doc """
  Renders step 1, the Timetable step: the paste form while it is open and
  the collapsed summary after a successful read.

  The open form holds the `#paste-source` textarea (monospace,
  `phx-debounce="blur"`, labelled 'Timetable copied from your
  spreadsheet'), the `#paste-source-hint`, the `#paste-layout` disclosure
  with layout radios and the header checkbox, and the `#paste-read` button.
  A failed read renders the specific message as `#paste-source-error`
  (wired through `<.input>` errors, so the field carries `aria-invalid`)
  and keeps the text. A successful read collapses to
  `#paste-source-summary` with the Edit timetable button.

  The hint is a plain paragraph rather than the input help text so it keeps
  the contract `#paste-source-hint` id; `<.input>` reserves
  `#paste-source-help` for its own help element.
  """
  attr :form, :any, required: true, doc: "the paste form from `to_form`"
  attr :error, :any, default: nil, doc: "the last read failure reason, if any"
  attr :open, :boolean, required: true, doc: "the step is expanded"
  attr :review, :any, default: nil, doc: "the last successful review, if any"

  def source_step(assigns) do
    assigns =
      assigns
      |> assign(:error_message, paste_error_message(assigns.error))
      |> assign(:layout_value, assigns.form[:layout].value || "auto")
      |> assign(:header_checked, header_checked?(assigns.form))
      |> assign(:summary, source_summary(assigns.review, assigns.form))

    ~H"""
    <section
      :if={@open or is_nil(@review)}
      id="paste-source-step"
      aria-label="Timetable"
      class="overflow-hidden rounded-card border border-subtle bg-white"
    >
      <div class="flex flex-wrap items-center gap-3 border-b border-subtle bg-canvas px-5 py-3.5">
        <span class="grid size-7 shrink-0 place-items-center rounded-full bg-soft text-[13px] font-bold text-strong">
          1
        </span>
        <div class="min-w-0">
          <h2 class="text-[17px] font-bold tracking-normal text-strong">Timetable</h2>
          <p class="text-[13px] text-muted">From Excel, Google Sheets or Numbers</p>
        </div>
      </div>
      <div class="grid gap-3 px-5 py-5">
        <.input
          type="textarea"
          field={@form[:text]}
          id="paste-source"
          label="Timetable copied from your spreadsheet"
          errors={if @error_message, do: [@error_message], else: []}
          phx-debounce="blur"
          rows="12"
          class="w-full textarea textarea-lg font-mono text-[13px] leading-6"
        />
        <p id="paste-source-hint" class="text-[13px] text-muted">
          Copy the stop names and the trip rows together. Times like 6:05, 6:05 PM and
          25:10 work. Leave a cell empty, or use –, where a trip skips a stop. Up to
          500 trips.
        </p>
        <details id="paste-layout" class="group text-sm">
          <summary class="inline-flex min-h-11 cursor-pointer list-none items-center gap-1.5 font-[650] text-strong [&::-webkit-details-marker]:hidden">
            Layout
            <span class="font-normal text-muted">
              · {layout_summary(@layout_value, @header_checked)}
            </span>
          </summary>
          <div class="mt-2 flex flex-wrap gap-x-8 gap-y-3 pl-6">
            <fieldset>
              <legend class="text-[13px] font-[650] text-strong">Trips are</legend>
              <div class="mt-1 flex flex-wrap gap-x-5">
                <label
                  :for={option <- layout_options()}
                  class="inline-flex min-h-11 items-center gap-2"
                >
                  <input
                    type="radio"
                    id={"paste-layout-#{option.value}"}
                    name={@form[:layout].name}
                    value={option.value}
                    checked={@layout_value == option.value}
                    class="size-4 accent-action"
                  />
                  {option.label}
                </label>
              </div>
            </fieldset>
            <.input
              type="checkbox"
              field={@form[:header]}
              id="paste-layout-header"
              label="First row or column has stop names"
              class="size-4 accent-action"
            />
          </div>
        </details>
      </div>
      <div class="flex flex-wrap items-center justify-between gap-3 border-t border-subtle px-5 py-4">
        <p class="text-[13px] text-muted">Reading doesn’t change the schedule.</p>
        <.button id="paste-read" type="submit" class="min-h-11" phx-disable-with="Reading…">
          Read timetable
        </.button>
      </div>
    </section>
    <section
      :if={!@open and not is_nil(@review)}
      id="paste-source-summary"
      aria-label="Timetable"
      class="flex flex-wrap items-center gap-x-4 gap-y-2 rounded-card border border-subtle bg-white px-5 py-2.5"
    >
      <!-- Step 31: the textarea unmounts with the source step, so the text,
        layout and header ride hidden fields here. A socket reconnect replays
        the form through LiveView form recovery, and without these the fresh
        mount would come back empty even with decisions restored. The open
        and collapsed states are exact complements, so exactly one control
        carries each name at all times. -->
      <input
        type="hidden"
        id="paste-source-text"
        name={@form[:text].name}
        value={@form[:text].value || ""}
      />
      <input
        type="hidden"
        id="paste-source-layout"
        name={@form[:layout].name}
        value={@layout_value}
      />
      <input
        type="hidden"
        id="paste-source-header"
        name={@form[:header].name}
        value={if @header_checked, do: "true", else: "false"}
      />
      <span
        class="grid size-7 shrink-0 place-items-center rounded-full bg-success-bg text-success-fg"
        title="Done"
      >
        <.icon name="hero-check" class="size-4" />
      </span>
      <h2 class="text-[15px] font-bold text-strong">Timetable</h2>
      <p class="min-w-0 flex-1 basis-[280px] text-sm text-muted">{@summary}</p>
      <.button id="paste-source-edit" type="button" variant="secondary" phx-click="edit_source">
        Edit timetable
      </.button>
    </section>
    """
  end

  @doc """
  Renders step 2, the Columns step: the pasted grid with a Use-as select
  per column, a status badge with a one-line reason, Confirm match for
  close matches, the Review-trips error summary, the all-unmatched layout
  hint and the pattern stop strip.

  The grid shows the first four data rows under a header row carrying
  `Column <letter>` and the pasted header. Each select posts back as
  `paste[overrides][<col>]` (`"occ:<id>"`, a trip field name, `"ignore"`
  or `""` for the automatic pick) and renders inside the page's
  `#paste-form`, so every change flows through the form's `input` event.
  Selects use `<.input>`, which reserves the `#paste-map-<col>-help` and
  `-error` ids for the one-line reason; the badge row below keeps the
  `#paste-map-<col>-status` id. Status copy follows the prototype's
  columns stage: Exact, Close match, No match, Not used, the paired
  Arrival/Departure, the override Chosen, the confirmed Checked and Out of
  order.
  """
  attr :review, :map, required: true, doc: "the pure paste review with columns and issues"
  attr :scope, :map, required: true, doc: "the loaded paste scope with patterns and stops"
  attr :header?, :boolean, default: true, doc: "the first grid row holds stop names"
  attr :show_errors, :boolean, default: false, doc: "Review trips was pressed with issues"

  def columns_step(assigns) do
    assigns =
      assigns
      |> assign(:pattern, columns_pattern(assigns.scope))
      |> assign(:occurrences, columns_occurrences(assigns.scope))
      |> assign(:columns, columns_sorted(assigns.review))
      |> assign(:issues, Map.get(assigns.review, :column_issues, []) || [])
      |> assign(:samples, column_samples(assigns.review, assigns.header?))
      |> assign(:total_rows, column_total_rows(assigns.review, assigns.header?))

    assigns =
      assigns
      |> assign(:stop_options, stop_options(assigns.occurrences, assigns.scope))
      |> assign(:mapped_any?, Enum.any?(assigns.columns, &occurrence_target?/1))
      |> assign(
        :all_unmatched?,
        assigns.columns != [] and not Enum.any?(assigns.columns, &occurrence_target?/1) and
          Enum.any?(assigns.columns, &(&1.status == :unmatched))
      )
      |> assign(:strip, strip_entries(assigns.occurrences, assigns.columns, assigns.scope))
      |> assign(:badges, column_badges(assigns.columns, assigns.occurrences, assigns.scope))

    ~H"""
    <section
      id="paste-columns"
      aria-label="Columns"
      class="overflow-hidden rounded-card border border-subtle bg-white"
    >
      <div class="flex flex-wrap items-center gap-3 border-b border-subtle bg-canvas px-5 py-3.5">
        <span class="grid size-7 shrink-0 place-items-center rounded-full bg-soft text-[13px] font-bold text-strong">
          2
        </span>
        <div class="min-w-0">
          <h2 class="text-[17px] font-bold tracking-normal text-strong">Columns</h2>
          <p class="text-[13px] text-muted">
            Match each column to a stop on {pattern_name(@pattern)}, in the pattern's order.
          </p>
        </div>
      </div>
      <div class="grid grid-cols-1 gap-4 px-5 py-5 [&>*]:min-w-0">
        <div
          :if={@show_errors and @issues != []}
          id="paste-column-errors"
          tabindex="-1"
          role="alert"
          class="rounded-card border border-error-line bg-error-bg px-4 py-3 text-sm text-error-fg outline-none"
        >
          <p class="font-bold">{issue_count_text(@issues)}</p>
          <ul class="mt-1 list-disc pl-5">
            <li :for={issue <- @issues}>
              <%= if issue.col == nil do %>
                Match at least two columns to stops.
              <% else %>
                <.link
                  href={"#paste-map-#{issue.col}"}
                  phx-click={JS.focus(to: "#paste-map-#{issue.col}")}
                  class="font-[650] text-error-fg underline"
                >
                  Column {column_letter(issue.col)} “{column_header(@columns, issue.col)}”
                </.link>: {issue_kind_text(
                  issue.kind
                )}
              <% end %>
            </li>
          </ul>
        </div>
        <p :if={@all_unmatched?} id="paste-layout-hint" class="text-sm text-muted">
          Stops down the side?
          <a href="#paste-layout" class="font-[650] underline">Change the layout.</a>
        </p>
        <div
          class="relative overflow-x-auto rounded-control border border-subtle"
          tabindex="0"
          role="region"
          aria-label="Pasted columns"
        >
          <table id="columns-table" class="w-full border-collapse text-left text-sm">
            <thead>
              <tr class="bg-canvas">
                <th
                  :for={column <- @columns}
                  scope="col"
                  class="min-w-[184px] border-b border-subtle px-3 pb-1 pt-3 align-bottom font-normal"
                >
                  <span class="text-[12px] text-muted">Column {column_letter(column.col)}</span>
                  <span class="block truncate font-[650] text-strong">
                    <%= if column.header == "" do %>
                      <span class="font-normal italic text-muted">No name</span>
                    <% else %>
                      {column.header}
                    <% end %>
                  </span>
                </th>
              </tr>
              <tr class="bg-canvas">
                <td :for={column <- @columns} class="border-b border-subtle px-3 pb-3 pt-1 align-top">
                  <.input
                    type="select"
                    id={"paste-map-#{column.col}"}
                    name={"paste[overrides][#{column.col}]"}
                    value={column_value(column)}
                    prompt="Choose a match"
                    options={column_options(@stop_options)}
                    aria-label={"Use column #{column_letter(column.col)} as"}
                    errors={column_input_errors(@badges[column.col])}
                    help={column_input_help(@badges[column.col])}
                  />
                  <div id={"paste-map-#{column.col}-status"} class="mt-2 text-[13px]">
                    <span class="flex flex-wrap items-center gap-2">
                      <.status_badge
                        status={@badges[column.col].tone}
                        label={@badges[column.col].label}
                      />
                      <button
                        :if={@badges[column.col].confirm?}
                        type="button"
                        id={"paste-confirm-#{column.col}"}
                        class="btn btn-outline btn-sm min-h-9"
                        phx-click="confirm_column"
                        phx-value-col={column.col}
                      >
                        Confirm match
                      </button>
                    </span>
                  </div>
                </td>
              </tr>
            </thead>
            <tbody class="font-mono text-[13px]">
              <tr :for={row <- @samples}>
                <td
                  :for={cell <- row}
                  class="border-b border-subtle px-3 py-2 tabular-nums text-default"
                >
                  <%= if cell == "" do %>
                    <span class="text-muted">–</span>
                  <% else %>
                    {cell}
                  <% end %>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
        <p class="text-[13px] text-muted">
          Showing {length(@samples)} of {Wording.count_noun(@total_rows, "row")}. Two neighbouring
          columns for one stop are its arrival and departure.
        </p>
        <div id="paste-pattern-strip">
          <h3 class="font-sans text-[13px] font-[650] tracking-normal text-strong">
            {pattern_name(@pattern)} · where each column goes
          </h3>
          <ol class="mt-2 flex flex-wrap items-stretch gap-y-2">
            <li :for={entry <- @strip} class="flex items-center">
              <span class={[
                "flex min-h-11 items-center gap-2 rounded-control border px-2.5 py-1 text-[13px]",
                if(entry.letters == [],
                  do: "border-dashed border-subtle text-muted",
                  else: "border-control bg-white text-strong"
                )
              ]}>
                <span class="tabular-nums text-muted">{entry.position}</span>
                <span class={if entry.letters == [], do: nil, else: "font-[650]"}>
                  {entry.name}
                </span>
                <span
                  :for={letter <- entry.letters}
                  title={"Column #{letter_column(letter)}"}
                  class="rounded-badge bg-soft px-1.5 font-[650] text-cyan-800"
                >
                  {letter}
                </span>
                <span
                  :if={entry.letters == [] and entry.missing == "no column"}
                  class="font-[650] text-warning-fg"
                >
                  no column
                </span>
                <span :if={entry.letters == [] and entry.missing == "filled in"} class="italic">
                  filled in
                </span>
              </span>
              <span :if={!entry.last} class="h-px w-3 bg-control" aria-hidden="true"></span>
            </li>
          </ol>
        </div>
      </div>
      <div class="flex flex-wrap items-center justify-between gap-3 border-t border-subtle px-5 py-4">
        <p class="text-[13px] text-muted">{issue_count_text(@issues)}</p>
        <button
          type="button"
          id="paste-to-review"
          class="btn btn-primary min-h-11"
          phx-click="to_review"
        >
          Review trips
        </button>
      </div>
    </section>
    """
  end

  @doc """
  The Excel-style letter for a zero-based column index: 0 is A, 25 is Z,
  26 is AA. Shared with `TimetablePasteLive`, which diffs the submitted
  Use-as selects against these effective values so untouched columns never
  pin their automatic pick into an override.
  """
  @spec column_letter(non_neg_integer()) :: String.t()
  def column_letter(col) when is_integer(col) and col >= 0 do
    do_column_letter(col + 1, "")
  end

  defp do_column_letter(0, acc), do: acc

  defp do_column_letter(number, acc) do
    remainder = rem(number - 1, 26)
    do_column_letter(div(number - 1, 26), <<65 + remainder>> <> acc)
  end

  @doc """
  The select value for a review column: `"occ:<id>"` for a stop,
  the trip field name, `"ignore"` or `""` for the automatic pick.
  Shared with `TimetablePasteLive` for the same diffing reason.
  """
  @spec column_value(map()) :: String.t()
  def column_value(%{target: {:occurrence, id, _side}}), do: "occ:#{id}"
  def column_value(%{target: :trip_short_name}), do: "trip_short_name"
  def column_value(%{target: :block_id}), do: "block_id"
  def column_value(%{target: :trip_headsign}), do: "trip_headsign"
  def column_value(%{target: :ignore}), do: "ignore"
  def column_value(_column), do: ""

  defp columns_pattern(scope) when is_map(scope) do
    patterns = Map.get(scope, :patterns, []) || []
    Enum.find(patterns, &(&1.id == scope.pattern_id))
  end

  defp columns_pattern(_scope), do: nil

  defp columns_occurrences(scope) do
    case columns_pattern(scope) do
      %{occurrences: occurrences} when is_list(occurrences) ->
        Enum.sort_by(occurrences, & &1.position)

      _pattern ->
        []
    end
  end

  defp pattern_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp pattern_name(_pattern), do: "this pattern"

  defp columns_sorted(review) do
    review |> Map.get(:columns, []) |> Enum.sort_by(& &1.col)
  end

  defp column_samples(review, header?) do
    grid = Map.get(review, :grid, []) || []

    data =
      if header? do
        case grid do
          [] -> []
          [_header | rest] -> rest
        end
      else
        grid
      end

    Enum.take(data, 4)
  end

  defp column_total_rows(review, header?) do
    grid = Map.get(review, :grid, []) || []
    if header?, do: max(length(grid) - 1, 0), else: length(grid)
  end

  defp occurrence_target?(%{target: {:occurrence, _, _}}), do: true
  defp occurrence_target?(_column), do: false

  # The strip and the pairing display ignore out-of-order columns, like the
  # prototype's `stopCols` ignores its problem columns: a misplaced column
  # does not claim its occurrence until it is moved back into order.
  defp strip_col?(%{status: :out_of_order}), do: false
  defp strip_col?(%{target: {:occurrence, _, _}}), do: true
  defp strip_col?(_column), do: false

  defp stop_options(occurrences, scope) do
    occurrences
    |> Enum.with_index(1)
    |> Enum.map(fn {occurrence, number} ->
      %{number: number, id: occurrence.id, name: occurrence_stop_name(scope, occurrence)}
    end)
  end

  defp occurrence_stop_name(scope, occurrence) do
    stops = Map.get(scope, :stops, %{}) || %{}

    case Map.get(stops, occurrence.stop_id) do
      %{stop_name: name} when is_binary(name) -> name
      _stop -> ""
    end
  end

  defp column_options(stop_options) do
    [
      {"Stops on this pattern, in order",
       Enum.map(stop_options, &{"#{&1.number} · #{&1.name}", "occ:#{&1.id}"})},
      {"Trip details",
       [{"Trip number", "trip_short_name"}, {"Block", "block_id"}, {"Headsign", "trip_headsign"}]},
      {"Not used", "ignore"}
    ]
  end

  @doc """
  Renders step 3, the Review header: How to apply, Fill other stops from,
  Stops view, the three current → after metrics, the refusal and nothing
  callouts, the filter buttons and the review matrix (step 26).

  The mode radios (`paste[mode]`) and the stops radios (`paste[stops_view]`)
  are native inputs inside the page's `#paste-form`, so every change flows
  through the form's `input` event and recomputes the pure review;
  `CoreComponents.segmented_control/1` is not used because it renders its
  own form, which cannot nest inside `#paste-form` (the vehicle drawer in
  `fleet_live.ex` carries the same note). The template select posts
  `paste[template_timing_id]`. The filter buttons are plain `type="button"`
  `phx-click="paste_filter"` controls carrying `phx-value-filter`:
  `pressed_filter/1` only emits a bare `phx-value`, which the LiveView
  client never collects (it gathers `phx-value-*` plus the element's own
  value, empty on a button). The metrics are hand-rolled rather than
  `metric/1` because each carries a sub-line; the refusals and the nothing
  notice reuse `message/1` (alert for errors, status for info, like the
  prototype). Copy follows the prototype's review stage. The matrix reads
  its rows from the `:plan_rows` stream the LiveView resets on every
  recompute, filter and view change.
  """
  attr :review, :map, required: true, doc: "the pure paste review with grid, rows and plan"

  attr :scope, :map,
    required: true,
    doc: "the loaded paste scope with calendar, patterns and route"

  attr :input, :map,
    required: true,
    doc: "the LiveView paste input with mode, template, stops view and filter"

  attr :columns, :list,
    required: true,
    doc: "the matrix display columns from `TimetablePasteReview.build/3`"

  attr :rows, :any,
    required: true,
    doc: "the `:plan_rows` stream items for the matrix"

  attr :shown, :integer,
    required: true,
    doc: "the filtered row count (streams are not countable)"

  attr :timing_note, :any,
    default: nil,
    doc: "the open timing-note `pattern_id|name` ref, if any"

  attr :show_errors, :boolean,
    default: false,
    doc: "show the apply-time `#paste-review-errors` summary when rows still need a decision"

  attr :notice, :atom,
    default: nil,
    doc: "the current step-28 apply outcome, for the apply bar status"

  def review_header(assigns) do
    plan = assigns.review.plan
    counts = plan.counts
    mode = review_mode(assigns.input)

    assigns =
      assigns
      |> assign(:plan, plan)
      |> assign(:counts, counts)
      |> assign(:mode, mode)
      |> assign(:stops_view, review_stops_view(assigns.input))
      |> assign(:filter, review_filter(assigns.input))
      |> assign(:calendar_name, review_calendar_name(assigns.scope))
      |> assign(:direction_name, review_direction_name(assigns.scope))
      |> assign(:direction_adjective, review_direction_adjective(assigns.scope))
      |> assign(:pasted_rows, length(assigns.review.rows || []))
      |> assign(:consequence, apply_consequence(mode, assigns.scope, plan))
      |> assign(:template_options, template_options(assigns.scope))
      |> assign(:template_value, effective_template(assigns.input, assigns.scope))
      |> assign(:trips_before, plan.trips.before)
      |> assign(:trips_after, plan.trips.after)
      |> assign(:vehicles_before, plan.vehicles.before)
      |> assign(:vehicles_after, plan.vehicles.after)
      |> assign(:timings, plan.new_timings || [])
      |> assign(:applied, counts.add + counts.change + counts.remove)
      |> assign(:route_short, review_route_short(assigns.scope))
      |> assign(:filters, visible_filters(assigns.input, plan))
      |> assign(:refusal, plan.refusal)
      |> assign(:discarded, discarded_decisions(plan))

    ~H"""
    <section
      id="paste-review"
      aria-label="Review"
      class="overflow-hidden rounded-card border border-subtle bg-white"
    >
      <div class="flex flex-wrap items-center gap-3 border-b border-subtle bg-canvas px-5 py-3.5">
        <span class="grid size-7 shrink-0 place-items-center rounded-full bg-soft text-[13px] font-bold text-strong">
          3
        </span>
        <div class="min-w-0">
          <div class="flex flex-wrap items-center gap-2">
            <h2 class="text-[17px] font-bold tracking-normal text-strong">Review</h2>
            <.status_badge status="warning" label="Not applied" />
          </div>
          <p class="text-[13px] text-muted">
            {@calendar_name} · {@direction_name} · {Wording.count_noun(@pasted_rows, "pasted row")}
          </p>
        </div>
      </div>
      <div class="flex flex-wrap items-end gap-x-8 gap-y-4 border-b border-subtle px-5 py-4">
        <div class="min-w-0 flex-1 basis-[420px]">
          <fieldset id="paste-mode">
            <legend class="text-[13px] font-[650] text-strong">How to apply</legend>
            <div class="mt-1.5 flex flex-wrap items-center gap-x-4 gap-y-2">
              <div class="inline-flex overflow-hidden rounded-control border border-control">
                <label class={[
                  "inline-flex min-h-11 cursor-pointer items-center px-4 text-sm font-[650] transition-colors focus-within:outline-2 focus-within:outline-focus",
                  @mode == :add && "bg-navy-800 text-white",
                  @mode != :add && "bg-white text-strong hover:bg-canvas"
                ]}>
                  <input
                    type="radio"
                    name="paste[mode]"
                    value="add"
                    checked={@mode == :add}
                    class="sr-only"
                  /> Add trips
                </label>
                <label class={[
                  "inline-flex min-h-11 cursor-pointer items-center px-4 text-sm font-[650] transition-colors focus-within:outline-2 focus-within:outline-focus",
                  @mode == :replace && "bg-navy-800 text-white",
                  @mode != :replace && "bg-white text-strong hover:bg-canvas"
                ]}>
                  <input
                    type="radio"
                    name="paste[mode]"
                    value="replace"
                    checked={@mode == :replace}
                    class="sr-only"
                  /> Replace trips
                </label>
              </div>
              <p
                id="paste-mode-help"
                class="min-w-0 flex-1 basis-[240px] text-[13px] text-muted"
              >
                {@consequence}
              </p>
            </div>
          </fieldset>
        </div>
        <div class="flex flex-wrap items-end gap-x-6 gap-y-3">
          <div class="w-full sm:w-[210px]">
            <.input
              type="select"
              id="paste-template"
              name="paste[template_timing_id]"
              label="Fill other stops from"
              value={@template_value}
              options={@template_options}
            />
          </div>
          <fieldset id="paste-stops-view">
            <legend class="text-[13px] font-[650] text-strong">Stops view</legend>
            <div class="mt-1.5 inline-flex overflow-hidden rounded-control border border-control">
              <label class={[
                "inline-flex min-h-11 cursor-pointer items-center px-4 text-sm font-[650] transition-colors focus-within:outline-2 focus-within:outline-focus",
                @stops_view == :pasted && "bg-navy-800 text-white",
                @stops_view != :pasted && "bg-white text-strong hover:bg-canvas"
              ]}>
                <input
                  type="radio"
                  name="paste[stops_view]"
                  value="pasted"
                  checked={@stops_view == :pasted}
                  class="sr-only"
                /> Pasted
              </label>
              <label class={[
                "inline-flex min-h-11 cursor-pointer items-center px-4 text-sm font-[650] transition-colors focus-within:outline-2 focus-within:outline-focus",
                @stops_view == :all && "bg-navy-800 text-white",
                @stops_view != :all && "bg-white text-strong hover:bg-canvas"
              ]}>
                <input
                  type="radio"
                  name="paste[stops_view]"
                  value="all"
                  checked={@stops_view == :all}
                  class="sr-only"
                /> All stops
              </label>
            </div>
          </fieldset>
        </div>
      </div>
      <div class="grid grid-cols-1 gap-4 border-b border-subtle px-5 py-4 sm:grid-cols-3">
        <div id="paste-metric-trips" class="min-w-0">
          <p class="text-[13px] text-muted">Trips · {@calendar_name} {@direction_adjective}</p>
          <p class="mt-1 font-display text-[26px] font-semibold tabular-nums text-strong">
            {@trips_before}
            <%= if @trips_before == @trips_after do %>
              <span class="font-sans text-[15px] font-normal text-muted">no change</span>
            <% else %>
              → {@trips_after}
            <% end %>
          </p>
          <p class="text-[13px] text-muted">{trips_detail(@counts)}</p>
        </div>
        <div id="paste-metric-vehicles" class="min-w-0">
          <p class="text-[13px] text-muted">Vehicles needed · route {@route_short} alone</p>
          <p class="mt-1 font-display text-[26px] font-semibold tabular-nums text-strong">
            {@vehicles_before}
            <%= if @vehicles_before == @vehicles_after do %>
              <span class="font-sans text-[15px] font-normal text-muted">no change</span>
            <% else %>
              → {@vehicles_after}
            <% end %>
          </p>
          <p class="text-[13px] text-muted">
            {@calendar_name}, both directions<%= if @counts.needs_decision > 0 do %>
              · rows that need a decision aren’t counted
            <% end %>
          </p>
        </div>
        <div id="paste-metric-timings" class="min-w-0">
          <p class="text-[13px] text-muted">New timings</p>
          <p class="mt-1 font-display text-[26px] font-semibold tabular-nums text-strong">
            {length(@timings)}
          </p>
          <p class="text-[13px] text-muted">
            <%= if @timings == [] do %>
              Every row matches an existing timing
            <% else %>
              {timing_names(@timings)}
            <% end %>
          </p>
        </div>
      </div>
      <.message
        :if={match?({:frequency, _trip}, @refusal)}
        id="paste-refusal-frequency"
        kind="error"
        title="Replace can’t run on this schedule."
        class="mx-5 mt-4"
      >
        {frequency_detail(@scope, @refusal)} Replace would remove it, and frequency service is
        changed on Schedules. Add the trips instead, or change the frequency service first.
        <:action>
          <button
            type="button"
            id="paste-use-add"
            class="btn btn-outline min-h-11"
            phx-click="use_add"
          >
            Use Add trips
          </button>
        </:action>
      </.message>
      <.message
        :if={match?({:stops_differ, _trip}, @refusal)}
        id="paste-refusal-stops"
        kind="error"
        title="Replace can’t run on this schedule."
        class="mx-5 mt-4"
      >
        {stops_differ_detail(@scope, @refusal)} Replace would remove it, and custom service is
        changed on Schedules. Add the trips instead, or fix the trip first.
        <:action>
          <button
            type="button"
            id="paste-use-add"
            class="btn btn-outline min-h-11"
            phx-click="use_add"
          >
            Use Add trips
          </button>
        </:action>
      </.message>
      <.message
        :if={@refusal == :nothing_accepted}
        id="paste-refusal-empty"
        kind="error"
        title="Replace needs at least one pasted trip."
        class="mx-5 mt-4"
      >
        Every row is skipped, so applying would remove all {Wording.count_noun(@trips_before, "trip")} and
        add none. Restore a row, or use Add trips.
        <:action>
          <button
            type="button"
            id="paste-use-add"
            class="btn btn-outline min-h-11"
            phx-click="use_add"
          >
            Use Add trips
          </button>
        </:action>
      </.message>
      <.message
        :if={@refusal == nil and @applied == 0 and @counts.needs_decision == 0}
        id="paste-nothing"
        kind="info"
        title="Nothing to apply."
        class="mx-5 mt-4"
      >
        Every row repeats a trip that already exists, so there is nothing to apply.
      </.message>
      <.message
        :if={@discarded != []}
        id="paste-decisions-notice"
        kind="warning"
        role="status"
        title={discarded_title(@discarded)}
        class="mx-5 mt-4"
      />
      <div
        :if={@show_errors and attention_rows(@review) != []}
        id="paste-review-errors"
        tabindex="-1"
        role="alert"
        class="mx-5 mt-4 rounded-card border border-error-line bg-error-bg px-4 py-3 text-sm text-error-fg outline-none"
      >
        <p class="font-bold">
          Nothing applied yet. {attention_title(@counts.needs_decision)}
        </p>
        <ul class="mt-1 list-disc pl-5">
          <li :for={entry <- attention_rows(@review)}>
            <a
              href={"#paste-row-#{entry.row}"}
              class="font-[650] text-error-fg underline"
            >
              Row {entry.row}<%= if entry.trip do %>
                · trip {entry.trip}<% end %>
            </a>: {entry.hint}
          </li>
        </ul>
        <p class="mt-1">Decide or skip each one. Skipped rows aren’t applied.</p>
      </div>
      <div
        id="paste-filters"
        class="flex flex-wrap items-center gap-2 px-5 pb-3 pt-4"
        role="group"
        aria-label="Show rows"
      >
        <button
          :for={{key, label, count} <- @filters}
          type="button"
          id={"paste-filter-#{key}"}
          phx-click="paste_filter"
          phx-value-filter={key}
          aria-pressed={to_string(@filter == key)}
          class={[
            "inline-flex min-h-11 items-center gap-1.5 rounded-control border px-3 text-[13px] font-[650]",
            @filter == key && "border-action bg-selection text-action",
            @filter != key && "border-control bg-white text-strong hover:bg-canvas"
          ]}
        >
          {label}<span class={["tabular-nums", @filter != key && "text-muted"]}>{count}</span>
        </button>
      </div>
      <.review_matrix
        review={@review}
        scope={@scope}
        input={@input}
        columns={@columns}
        rows={@rows}
        shown={@shown}
        timing_note={@timing_note}
      />
      <.apply_bar review={@review} input={@input} notice={@notice} />
    </section>
    """
  end

  @doc """
  Renders step 26, the review matrix: Row, Trip (+Block), Change badge,
  one column per pasted stop (Pasted view) or every occurrence (All stops
  view), Timing and Details.

  Rows come from the `:plan_rows` stream the LiveView resets on every
  recompute, filter and view change (`paste-row-<n>` for pasted rows,
  `paste-remove-<trip_id>` for removals); the column set and the filtered
  count arrive as plain assigns because streams are not enumerable. Cells
  render pasted times bold, estimates italic muted,
  `Not served`, `+1 day` at or past 24:00, `arr HH:MM` for a differing
  arrival, `was HH:MM` on changed cells and struck old times for removals.
  Timing buttons store a `pattern_id|name` ref through `paste_timing` and
  the note resolves it from the current review; rows on another pattern
  name it above the timing. Row and Trip pin with sticky columns inside
  the labelled scroll region. Decision controls live in the Details cell
  and arrive in step 27.
  """
  attr :review, :map, required: true, doc: "the pure paste review with grid, rows and plan"
  attr :scope, :map, required: true, doc: "the loaded paste scope with patterns and stops"
  attr :input, :map, required: true, doc: "the LiveView paste input with stops view"
  attr :columns, :list, required: true, doc: "the matrix display columns"
  attr :rows, :any, required: true, doc: "the `:plan_rows` stream items"
  attr :shown, :integer, required: true, doc: "the filtered row count"
  attr :timing_note, :any, default: nil, doc: "the open timing-note ref, if any"

  def review_matrix(assigns) do
    assigns =
      assigns
      |> assign(
        :note,
        TimetablePasteReview.timing_note(
          assigns.review,
          assigns.scope,
          assigns.input,
          assigns.timing_note
        )
      )
      |> assign(:pattern_name, matrix_pattern_name(assigns.scope))
      |> assign(:stops_view, review_stops_view(assigns.input))
      |> assign(:colspan, length(assigns.columns) + 5)

    ~H"""
    <div
      class="relative overflow-x-auto border-t border-subtle"
      tabindex="0"
      role="region"
      aria-label="Review rows"
    >
      <table id="paste-review-table" class="w-full border-collapse text-left text-sm">
        <thead>
          <tr class="bg-canvas text-[13px] text-strong">
            <th
              scope="col"
              class="sticky left-0 z-30 w-14 min-w-14 border-b border-subtle bg-canvas px-3 py-2.5 font-[650]"
            >
              Row
            </th>
            <th
              scope="col"
              class="sticky left-14 z-30 min-w-[92px] border-b border-subtle bg-canvas px-3 py-2.5 font-[650]"
            >
              Trip
            </th>
            <th
              scope="col"
              class="min-w-[124px] border-b border-subtle px-3 py-2.5 font-[650]"
            >
              Change
            </th>
            <th
              :for={column <- @columns}
              scope="col"
              class="min-w-[84px] border-b border-subtle px-3 py-2.5 text-right font-[650]"
            >
              {column.name}
              <small
                :if={@stops_view == :all and column.pasted?}
                class="block text-[12px] font-normal text-muted"
              >
                Pasted
              </small>
            </th>
            <th
              scope="col"
              class="min-w-[180px] border-b border-subtle px-3 py-2.5 font-[650]"
            >
              Timing
            </th>
            <th
              scope="col"
              class="min-w-[360px] border-b border-subtle px-3 py-2.5 font-[650]"
            >
              Details
            </th>
          </tr>
        </thead>
        <tbody id="paste-rows" phx-update="stream">
          <tr
            :for={{dom_id, row} <- @rows}
            id={dom_id}
            tabindex="-1"
            class={[matrix_row_bg(row.op), "outline-none focus:outline-2 focus:outline-focus"]}
          >
            <td class={[
              matrix_row_bg(row.op),
              "sticky left-0 z-10 border-b border-subtle px-3 py-2.5 align-top tabular-nums text-muted"
            ]}>
              <%= if row.row_no do %>
                {row.row_no}
              <% else %>
                –
              <% end %>
            </td>
            <th
              scope="row"
              class={[
                matrix_row_bg(row.op),
                "sticky left-14 border-b border-subtle px-3 py-2.5 align-top font-[650] text-strong"
              ]}
            >
              <%= if row.trip do %>
                {row.trip}
              <% else %>
                <span class="font-normal text-muted">–</span>
              <% end %>
              <small :if={row.block} class="block text-[12px] font-normal text-muted">
                Block {row.block}
              </small>
            </th>
            <td class="border-b border-subtle px-3 py-2.5 align-top">
              <.status_badge status={elem(row.badge, 1)} label={elem(row.badge, 0)} />
            </td>
            <td
              :for={cell <- row.cells}
              class="whitespace-nowrap border-b border-subtle px-3 py-2.5 text-right align-top"
            >
              <.matrix_cell cell={cell} muted={row.op in [:duplicate, :skipped, :unchanged]} />
            </td>
            <td class="border-b border-subtle px-3 py-2.5 align-top text-[13px]">
              <span
                :if={row.pattern_note}
                class="block max-w-[240px] truncate font-[650] text-strong"
                title={row.pattern_note}
              >
                {row.pattern_note}
              </span>
              <%= if row.timing do %>
                <button
                  type="button"
                  phx-click="paste_timing"
                  phx-value-ref={row.timing.ref}
                  class="inline-flex min-h-8 items-center gap-1.5 text-[13px] font-[650] text-action underline underline-offset-4"
                >
                  <%= if row.timing.new? do %>
                    New ·
                  <% end %>
                  {row.timing.name}
                </button>
              <% else %>
                <span class="text-muted">–</span>
              <% end %>
            </td>
            <td class="border-b border-subtle px-3 py-2.5 align-top">
              <.row_decision :if={row.decision} decision={row.decision} />
              <div :if={row.details != []} class="grid gap-1 text-[13px] text-muted">
                <p :for={detail <- row.details} class={detail.warning? && "text-warning-fg"}>
                  {detail.text}
                </p>
              </div>
            </td>
          </tr>
        </tbody>
        <%!-- The empty state lives in its own body: every child of the
        stream container above needs a DOM id. --%>
        <tbody :if={@shown == 0}>
          <tr>
            <td colspan={@colspan} class="px-5 py-8 text-center text-sm text-muted">
              No rows match this filter.
              <button
                type="button"
                class="font-[650] text-action underline underline-offset-4"
                phx-click="paste_filter"
                phx-value-filter="all"
              >
                Show all rows
              </button>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    <div
      :if={@note}
      id="paste-timing-note"
      role="status"
      class="flex flex-wrap items-start justify-between gap-3 border-t border-cyan-200 bg-cyan-50 px-5 py-3 text-[13px] text-cyan-900"
    >
      <p class="min-w-0 flex-1 basis-[360px]">
        <strong>{@note.name}</strong> · {timing_note_body(@note)}
      </p>
      <button
        type="button"
        id="paste-timing-close"
        class="btn btn-outline btn-sm min-h-9"
        phx-click="paste_timing_close"
      >
        Close
      </button>
    </div>
    <p :if={!@note} class="border-t border-subtle px-5 py-3 text-[13px] text-muted">
      Bold times are pasted and stay exact. Rows on a pattern other than {@pattern_name} name it above their timing.
      <%= if @stops_view == :all do %>
        Italic times are filled in from the timing:
        stored to the second as estimates, shown to the minute.
      <% else %>
        Choose All stops to see
        the times filled in between them.
      <% end %>
      Select a timing name to see how it was built.
    </p>
    """
  end

  @doc """
  Renders step 27, one row's decision controls for the matrix Details cell.

  The control follows the row's issue shape from
  `TimetablePasteReview.build/3`: an ambiguous-pattern select (`N patterns
  fit. Choose the one this trip follows.`), a no-pattern notice, a cell
  correction (header, raw value, letter hint), a twelve-hour choice (three
  readings, after-midnight first), pairing radios (trip and block per
  option plus `Neither · add as a new trip`), skip and restore, and Add
  anyway for duplicates. Pattern, cell and pairing controls are native
  form fields, so they post through `#paste-form`'s `input` event like the
  columns selects; the buttons are `type="button"` server events.
  """
  attr :decision, :map, required: true, doc: "the precomputed row decision from the review"

  def row_decision(assigns) do
    assigns = assign(assigns, :decision_button_class, @decision_button_class)

    ~H"""
    <div :if={@decision.kind == :pattern} class="grid gap-2">
      <p class="text-[13px] text-warning-fg">
        <%= if @decision.misfit? do %>
          <strong>The chosen pattern no longer fits this row.</strong>
          Choose the one this trip follows.
        <% else %>
          <strong>
            {Wording.count_noun(length(@decision.options), "pattern fits", "patterns fit")}.
          </strong>
          Choose the one this trip follows.
        <% end %>
      </p>
      <div class="flex flex-wrap items-center gap-2">
        <label class="sr-only" for={"paste-pattern-#{@decision.row}"}>
          Pattern for row {@decision.row}
        </label>
        <select
          id={"paste-pattern-#{@decision.row}"}
          name={"paste[pattern_choices][#{@decision.row}]"}
          aria-invalid="true"
          class="min-h-11 w-[240px] rounded-control border border-control bg-white px-3 text-sm text-strong"
        >
          <option value="">Choose pattern</option>
          <option
            :for={option <- @decision.options}
            value={option.value}
            selected={@decision.current == option.value}
          >
            {option.name}
          </option>
        </select>
        <button
          type="button"
          id={"paste-skip-#{@decision.row}"}
          phx-click="paste_skip"
          phx-value-row={@decision.row}
          class={@decision_button_class}
        >
          Skip row
        </button>
      </div>
    </div>
    <div :if={@decision.kind == :no_pattern} class="grid gap-2">
      <p class="text-[13px] text-warning-fg">
        <strong>No pattern fits.</strong>
        No {@decision.direction} pattern calls at exactly these stops. Skip the row, or add the pattern and review again.
      </p>
      <div class="flex flex-wrap gap-2">
        <button
          type="button"
          id={"paste-skip-#{@decision.row}"}
          phx-click="paste_skip"
          phx-value-row={@decision.row}
          class={@decision_button_class}
        >
          Skip row
        </button>
      </div>
    </div>
    <div :if={@decision.kind == :cell} class="grid gap-2">
      <p class="text-[13px] text-warning-fg">
        <strong>{@decision.header}:</strong>
        <%= if @decision.backwards? do %>
          {@decision.raw} is earlier than the stop before it.
        <% else %>
          “{@decision.raw}” isn’t a time<%= if @decision.letter do %>
            : it has the letter {@decision.letter} where a digit belongs
          <% end %>.
        <% end %>
      </p>
      <div class="flex flex-wrap items-center gap-2">
        <label class="sr-only" for={"paste-cell-#{@decision.row}-#{@decision.col}"}>
          Time at {@decision.header}, row {@decision.row}
        </label>
        <input
          id={"paste-cell-#{@decision.row}-#{@decision.col}"}
          name={"paste[cells][#{@decision.row}][#{@decision.col}]"}
          value={@decision.value}
          phx-debounce="blur"
          aria-invalid="true"
          class="min-h-11 w-24 rounded-control border border-control bg-white px-3 font-mono text-sm text-strong"
        />
        <button
          type="button"
          id={"paste-cell-save-#{@decision.row}"}
          phx-click="paste_cell_save"
          phx-value-row={@decision.row}
          phx-value-col={@decision.col}
          class={@decision_button_class}
        >
          Use time
        </button>
        <button
          type="button"
          id={"paste-skip-#{@decision.row}"}
          phx-click="paste_skip"
          phx-value-row={@decision.row}
          class={@decision_button_class}
        >
          Skip row
        </button>
      </div>
    </div>
    <div :if={@decision.kind == :twelve} class="grid gap-2">
      <p class="text-[13px] text-warning-fg">
        <strong>Starts at {GtfsTime.display(@decision.secs)};</strong>
        the other trips start in the evening. Which time is it?
      </p>
      <div class="flex flex-wrap gap-2">
        <button
          type="button"
          id={"paste-twelve-#{@decision.row}-after-midnight"}
          phx-click="paste_twelve"
          phx-value-row={@decision.row}
          phx-value-choice="86400"
          class={@decision_button_class}
        >
          {GtfsTime.display(@decision.secs + 86_400)} · after midnight
        </button>
        <button
          type="button"
          id={"paste-twelve-#{@decision.row}-plus-twelve"}
          phx-click="paste_twelve"
          phx-value-row={@decision.row}
          phx-value-choice="43200"
          class={@decision_button_class}
        >
          {GtfsTime.display(@decision.secs + 43_200)}
        </button>
        <button
          type="button"
          id={"paste-twelve-#{@decision.row}-keep"}
          phx-click="paste_twelve"
          phx-value-row={@decision.row}
          phx-value-choice="keep"
          class={@decision_button_class}
        >
          Keep {GtfsTime.display(@decision.secs)}
        </button>
      </div>
    </div>
    <fieldset :if={@decision.kind == :pairing}>
      <legend class="text-[13px] text-warning-fg">
        <strong>{pairing_legend(@decision)}</strong>
        Choose the one this row replaces. The other is removed.
      </legend>
      <div class="mt-1 grid">
        <label
          :for={{option, index} <- Enum.with_index(@decision.options)}
          class="inline-flex min-h-11 items-center gap-2 text-[13px]"
        >
          <input
            type="radio"
            id={"paste-pair-#{@decision.row}-#{index}"}
            name={"paste[pairs][#{@decision.row}]"}
            value={option.value}
            checked={@decision.current == option.value}
            class="size-4 accent-action"
          />Trip {option.trip} · {if option.block, do: "Block #{option.block}", else: "No block"}
        </label>
        <label class="inline-flex min-h-11 items-center gap-2 text-[13px]">
          <input
            type="radio"
            id={"paste-pair-#{@decision.row}-neither"}
            name={"paste[pairs][#{@decision.row}]"}
            value="neither"
            checked={neither_chosen?(@decision.current)}
            class="size-4 accent-action"
          />Neither · add as a new trip
        </label>
      </div>
    </fieldset>
    <div
      :if={@decision.kind == :duplicate}
      class="flex items-center justify-end gap-3"
    >
      <button
        type="button"
        id={"paste-keep-#{@decision.row}"}
        phx-click="paste_keep"
        phx-value-row={@decision.row}
        class={@decision_button_class}
      >
        Add anyway
      </button>
    </div>
    <div
      :if={@decision.kind == :skipped}
      class="flex items-center justify-end gap-3"
    >
      <button
        type="button"
        id={"paste-restore-#{@decision.row}"}
        phx-click="paste_restore"
        phx-value-row={@decision.row}
        class={@decision_button_class}
      >
        Restore row
      </button>
    </div>
    <div
      :if={@decision.kind == :kept}
      class="flex items-center justify-between gap-3"
    >
      <p class="text-[13px] text-muted">Added alongside an existing trip.</p>
      <button
        type="button"
        id={"paste-unkeep-#{@decision.row}"}
        phx-click="paste_unkeep"
        phx-value-row={@decision.row}
        class="min-h-11 font-[650] text-action underline underline-offset-4"
      >
        Skip it
      </button>
    </div>
    """
  end

  defp pairing_legend(%{start_secs: start_secs, options: options}) when is_integer(start_secs) do
    "#{Wording.count_noun(length(options), "trip", "trips")} leave at #{GtfsTime.display(start_secs)}."
  end

  defp pairing_legend(%{options: options}) do
    "#{Wording.count_noun(length(options), "trip leaves", "trips leave")} at the same time."
  end

  defp neither_chosen?(current) when is_binary(current),
    do: String.downcase(String.trim(current)) == "neither"

  defp neither_chosen?(_current), do: false

  defp discarded_title(discards) when is_list(discards) do
    case length(discards) do
      1 -> "1 saved choice no longer applies and was cleared."
      count -> "#{count} saved choices no longer apply and were cleared."
    end
  end

  @doc """
  Renders one matrix time cell: pasted times bold, estimates italic muted,
  `Not served`, `+1 day` at or past 24:00,
  `arr HH:MM` for a differing arrival, `was HH:MM` on changed cells and
  struck old times for removals.
  """
  attr :cell, :map, required: true, doc: "the cell view model"
  attr :muted, :boolean, required: true, doc: "duplicates, skips and repeats read muted"

  def matrix_cell(assigns) do
    cell = assigns.cell

    assigns =
      assigns
      |> assign(:main, cell.secs && GtfsTime.display(cell.secs))
      |> assign(:arr, cell.arr_secs && GtfsTime.display(cell.arr_secs))
      |> assign(:was, cell.was_secs && GtfsTime.display(cell.was_secs))
      |> assign(:next_day?, is_integer(cell.secs) and cell.secs >= 86_400)

    ~H"""
    <%= cond do %>
      <% @cell.state == :not_served -> %>
        <span class="italic text-muted">Not served</span>
      <% @cell.state == :blank -> %>
        <span class="text-muted">–</span>
      <% @cell.struck? -> %>
        <s class="tabular-nums text-muted">{@main}</s>
      <% true -> %>
        <small :if={@arr} class="mr-1 text-[12px] text-muted">arr {@arr}</small><span class={[
          "tabular-nums",
          matrix_time_class(@cell, @muted)
        ]}>{@main}</span><small :if={@next_day?} class="ml-1 text-[12px] text-muted">+1 day</small>
        <small :if={@was} class="block text-[12px] text-muted">was <s>{@was}</s></small>
    <% end %>
    """
  end

  # --- Review header (step 25) ---

  @review_filter_defs [
    {"all", "All rows"},
    {"add", "Add"},
    {"change", "Change"},
    {"remove", "Remove"},
    {"unchanged", "No change"},
    {"duplicate", "Already exists"},
    {"skipped", "Skipped"},
    {"needs_decision", "Needs decision"},
    {"warnings", "Warnings"}
  ]

  defp review_mode(%{mode: :replace}), do: :replace
  defp review_mode(%{mode: "replace"}), do: :replace
  defp review_mode(_input), do: :add

  defp review_stops_view(%{stops_view: :all}), do: :all
  defp review_stops_view(%{stops_view: "all"}), do: :all
  defp review_stops_view(_input), do: :pasted

  defp review_filter(%{filter: filter})
       when filter in ~w(all add change remove unchanged duplicate skipped needs_decision warnings),
       do: filter

  defp review_filter(_input), do: "all"

  defp review_calendar_name(%{calendar: %{name: name}})
       when is_binary(name) and name != "",
       do: name

  defp review_calendar_name(_scope), do: "this calendar"

  defp review_direction_name(%{direction_id: 1}), do: "Inbound"
  defp review_direction_name(_scope), do: "Outbound"

  defp review_direction_adjective(%{direction_id: 1}), do: "inbound"
  defp review_direction_adjective(_scope), do: "outbound"

  defp review_route_short(%{route: %{route_short_name: short}})
       when is_binary(short) and short != "",
       do: short

  defp review_route_short(%{route: %{route_id: id}}) when is_binary(id), do: id
  defp review_route_short(_scope), do: "this route"

  defp apply_consequence(:add, _scope, _plan),
    do: "Existing trips stay. Rows that repeat an existing departure are skipped."

  defp apply_consequence(:replace, scope, plan) do
    "Trips on #{review_calendar_name(scope)} · #{review_direction_adjective(scope)} on " <>
      "#{replace_pattern_names(scope, plan)} that aren’t in your paste are removed. " <>
      "Other patterns, calendars and the other direction stay."
  end

  defp replace_pattern_names(scope, plan) do
    ids = if is_list(plan.replace_patterns), do: plan.replace_patterns, else: []
    patterns = if is_list(Map.get(scope, :patterns)), do: scope.patterns, else: []

    names =
      ids
      |> Enum.map(&find_pattern_name(&1, patterns))
      |> Enum.reject(&is_nil/1)

    case names do
      [] -> "the pasted patterns"
      names -> Enum.join(names, " and ")
    end
  end

  defp find_pattern_name(id, patterns) do
    Enum.find_value(patterns, fn pattern ->
      if pattern_id(pattern) == id, do: pattern_name(pattern)
    end)
  end

  defp pattern_id(%{id: id}), do: id
  defp pattern_id(%{"id" => id}), do: id
  defp pattern_id(_pattern), do: nil

  defp review_pattern(scope) when is_map(scope) do
    patterns = Map.get(scope, :patterns, []) || []

    Enum.find(List.wrap(patterns), fn pattern ->
      pattern_id(pattern) == Map.get(scope, :pattern_id)
    end)
  end

  defp review_pattern(_scope), do: nil

  defp template_options(scope) do
    case review_pattern(scope) do
      %{timings: timings} when is_list(timings) ->
        Enum.map(timings, fn timing ->
          {"#{timing_name(timing)} · #{timing_minutes(timing)} min", timing_id(timing)}
        end)

      _pattern ->
        []
    end
  end

  # The select shows the input timing when it belongs to the pattern, else
  # the pattern's most-used timing (highest trip count, ties keep scope
  # order) — the same fallback `RowResolver` reviews with.
  defp effective_template(input, scope) do
    timings =
      case review_pattern(scope) do
        %{timings: timings} when is_list(timings) -> timings
        _pattern -> []
      end

    ids = timings |> Enum.map(&timing_id/1) |> Enum.reject(&is_nil/1)
    wanted = Map.get(input, :template_timing_id) || Map.get(input, "template_timing_id")

    if is_binary(wanted) and wanted in ids do
      wanted
    else
      most_used_timing(timings) || ""
    end
  end

  defp most_used_timing([]), do: nil

  defp most_used_timing(timings) do
    timings |> Enum.sort_by(&timing_trip_count/1, :desc) |> List.first() |> timing_id()
  end

  defp timing_name(timing) when is_map(timing) do
    Map.get(timing, :name) || Map.get(timing, "name") || "Timing"
  end

  defp timing_name(_timing), do: "Timing"

  defp timing_id(timing) when is_map(timing) do
    Map.get(timing, :id) || Map.get(timing, "id")
  end

  defp timing_id(_timing), do: nil

  defp timing_trip_count(timing) when is_map(timing) do
    Map.get(timing, :trip_count) || Map.get(timing, "trip_count") || 0
  end

  defp timing_trip_count(_timing), do: 0

  defp timing_names(timings), do: Enum.map_join(timings, ", ", &timing_name/1)

  defp timing_minutes(timing) when is_map(timing) do
    departures =
      timing
      |> timing_rows()
      |> Enum.map(&timing_departure/1)
      |> Enum.reject(&is_nil/1)

    case departures do
      [] -> 0
      departures -> div(Enum.max(departures) - Enum.min(departures), 60)
    end
  end

  defp timing_minutes(_timing), do: 0

  defp timing_rows(timing) do
    List.wrap(Map.get(timing, :rows) || Map.get(timing, "rows"))
  end

  defp timing_departure(row) when is_map(row) do
    case Map.get(row, :departure_offset, Map.get(row, "departure_offset")) do
      offset when is_integer(offset) -> offset
      _offset -> nil
    end
  end

  defp timing_departure(_row), do: nil

  defp trips_detail(counts) do
    parts =
      [{"added", counts.add}, {"removed", counts.remove}, {"changed", counts.change}]
      |> Enum.filter(fn {_label, count} -> is_integer(count) and count > 0 end)
      |> Enum.map(fn {label, count} -> "#{count} #{label}" end)

    case parts do
      [] -> "Nothing added or removed"
      parts -> Enum.join(parts, " · ")
    end
  end

  # Step 26 adds the Warnings filter step 25 deferred: rows carrying plan
  # warnings, counted here because `plan.counts` has no warnings total.
  defp visible_filters(input, plan) do
    changes = if is_list(plan.changes), do: plan.changes, else: []
    counts = Map.put(plan.counts, :warnings, Enum.count(changes, &TimetablePasteReview.warned?/1))
    total = length(changes)
    current = review_filter(input)

    @review_filter_defs
    |> Enum.map(fn {key, label} -> {key, label, filter_count(key, counts, total)} end)
    |> Enum.filter(fn {key, _label, count} ->
      key == "all" or key == current or count > 0
    end)
  end

  defp filter_count("all", _counts, total), do: total
  defp filter_count(key, counts, _total), do: Map.get(counts, String.to_atom(key), 0)

  defp refusal_trip({kind, trip}) when kind in [:frequency, :stops_differ] and is_map(trip),
    do: trip

  defp refusal_trip(_refusal), do: %{}

  # Stale choices `Plan` validated off the rebuilt candidates
  # (`plan.discarded_decisions`): a one-line notice, no row links.
  defp discarded_decisions(plan) when is_map(plan) do
    case Map.get(plan, :discarded_decisions, Map.get(plan, "discarded_decisions")) do
      discards when is_list(discards) -> discards
      _discards -> []
    end
  end

  defp discarded_decisions(_plan), do: []

  defp refusal_trip_id(refusal) do
    trip = refusal_trip(refusal)
    Map.get(trip, :trip_id) || Map.get(trip, "trip_id")
  end

  defp trip_pattern_name(scope, trip) do
    ref = Map.get(trip, :route_pattern_id) || Map.get(trip, "route_pattern_id")
    patterns = Map.get(scope, :patterns, []) || []

    Enum.find_value(patterns, fn pattern ->
      pattern_ref =
        Map.get(pattern, :route_pattern_id) || Map.get(pattern, "route_pattern_id")

      if pattern_ref == ref, do: pattern_name(pattern)
    end) || "This pattern"
  end

  defp frequency_detail(scope, refusal) do
    trip = refusal_trip(refusal)
    pattern = trip_pattern_name(scope, trip)
    calendar = review_calendar_name(scope)

    case frequency_window(trip) do
      %{headway: headway, start: start, finish: finish}
      when is_binary(start) and is_binary(finish) ->
        "#{pattern} also has frequency service on #{calendar}: " <>
          "every #{headway} min, #{start}–#{finish}."

      _window ->
        "#{pattern} also has frequency service on #{calendar}."
    end
  end

  defp stops_differ_detail(scope, refusal) do
    trip = refusal_trip(refusal)
    pattern = trip_pattern_name(scope, trip)

    case refusal_trip_id(refusal) do
      nil -> "The trip on #{pattern} has custom stop times that differ from the pattern."
      id -> "Trip #{id} on #{pattern} has custom stop times that differ from the pattern."
    end
  end

  defp frequency_window(trip) when is_map(trip) do
    rows =
      Map.get(trip, :frequencies) || Map.get(trip, "frequencies") ||
        Map.get(trip, :frequency_rows) || Map.get(trip, "frequency_rows")

    case List.first(List.wrap(rows)) do
      %{headway_secs: headway} = window when is_integer(headway) ->
        %{
          headway: div(headway, 60),
          start: clock_time(window, :start_time),
          finish: clock_time(window, :end_time)
        }

      _row ->
        nil
    end
  end

  defp frequency_window(_trip), do: nil

  defp clock_time(window, key) when is_map(window) do
    case Map.get(window, key) || Map.get(window, to_string(key)) do
      %Time{} = time ->
        GtfsTime.display(Time.to_seconds_after_midnight(time) |> elem(0))

      binary when is_binary(binary) ->
        case GtfsTime.coerce(binary) do
          nil -> raw_clock_parts(binary)
          secs -> GtfsTime.display(secs)
        end

      _time ->
        nil
    end
  end

  defp clock_time(_window, _key), do: nil

  defp raw_clock_parts(binary) do
    case String.split(binary, ":") do
      [hour, minute | _rest] -> "#{hour}:#{minute}"
      _parts -> nil
    end
  end

  @doc """
  The inline message for a failed read. Copy follows the spec proposal §1
  and the prototype source stage: each reason names its fix and the text
  stays in the textarea.
  """
  def paste_error_message(nil), do: nil

  def paste_error_message(:empty),
    do: "Paste a timetable first. Copy the stop names and the rows of times together."

  def paste_error_message(:no_times),
    do: "No times found. Copy the rows of times as well as the stop names."

  def paste_error_message({:too_large, _bytes}),
    do: "This paste is larger than 200 KB. Paste one calendar and direction at a time."

  def paste_error_message({:too_many_rows, count}),
    do:
      "This paste has #{count} trip rows. Paste up to 500 at a time: split the timetable, or remove rows you don’t need."

  def paste_error_message({:too_many_columns, count}),
    do:
      "This paste has #{count} columns. Paste up to 150: remove columns you don’t need, such as notes."

  def paste_error_message({:unclosed_quote, line}),
    do:
      "A quoted cell that starts on line #{line} never closes. Copy the cells from the spreadsheet again."

  def paste_error_message(_reason),
    do: "This paste couldn’t be read. Copy the cells from the spreadsheet again."

  defp layout_options do
    [
      %{value: "auto", label: "Detect automatically"},
      %{value: "trips_in_rows", label: "Rows"},
      %{value: "stops_in_rows", label: "Columns (stops down the side)"}
    ]
  end

  defp layout_summary(layout_value, header_checked) do
    label =
      case layout_value do
        "trips_in_rows" -> "Rows"
        "stops_in_rows" -> "Columns (stops down the side)"
        _layout -> "Detect automatically"
      end

    if header_checked, do: label, else: "#{label} · no header row"
  end

  defp header_checked?(form) do
    form[:header].value not in ["false", false]
  end

  defp source_summary(nil, _form), do: nil

  defp source_summary(review, form) when is_map(review) do
    grid = Map.get(review, :grid, [])
    columns = grid |> List.first([]) |> length()
    rows = length(grid)
    trips = if header_checked?(form), do: max(rows - 1, 0), else: rows

    summary =
      "#{Wording.count_noun(trips, "trip row")} · #{Wording.count_noun(columns, "column")} · #{orientation_label(Map.get(review, :orientation))}"

    if header_checked?(form), do: summary, else: "#{summary} · no header row"
  end

  defp orientation_label(:stops_in_rows), do: "stops down the side"
  defp orientation_label(_orientation), do: "trips in rows"

  # --- Columns step badges, reasons, strip and error summary ---

  # The badge for one review column. Tones map onto the `status_badge/1`
  # vocabulary; labels and reasons follow the prototype's columns stage.
  # Paired neighbours sharing one occurrence read Arrival/Departure;
  # anything else follows its matcher status.
  defp column_badge(columns, column, occurrences, scope) do
    case column do
      %{status: :out_of_order} ->
        %{
          tone: "error",
          label: "Out of order",
          reason: order_reason(columns, column, occurrences, scope),
          confirm?: false
        }

      %{status: :close} ->
        %{
          tone: "warning",
          label: "Close match",
          reason: close_reason(column, occurrences, scope),
          confirm?: true
        }

      %{status: :unmatched} ->
        %{
          tone: "error",
          label: "No match",
          reason: "Choose a stop, or Not used.",
          confirm?: false
        }

      %{status: :unused} ->
        %{tone: "draft", label: "Not used", reason: "No times in this column.", confirm?: false}

      %{target: {:occurrence, _id, :arrival}} = col when is_map(col) ->
        arrival_badge(columns, col)

      %{target: {:occurrence, _id, :departure}} = col when is_map(col) ->
        departure_badge(columns, col)

      %{target: target} when target in [:trip_short_name, :block_id, :trip_headsign] ->
        field_badge(column)

      _column ->
        %{tone: "draft", label: "Unknown", reason: nil, confirm?: false}
    end
  end

  defp arrival_badge(columns, col) do
    if paired?(columns, col) do
      %{tone: "pass", label: "Arrival", reason: nil, confirm?: false}
    else
      occurrence_badge(col)
    end
  end

  defp departure_badge(columns, col) do
    if paired?(columns, col) do
      %{
        tone: "pass",
        label: "Departure",
        reason: "Pairs with column #{column_letter(col.col - 1)}.",
        confirm?: false
      }
    else
      occurrence_badge(col)
    end
  end

  defp field_badge(column) do
    if column.status == :chosen do
      %{tone: "pass", label: "Chosen", reason: nil, confirm?: false}
    else
      %{tone: "pass", label: "Exact", reason: "By column name.", confirm?: false}
    end
  end

  defp occurrence_badge(%{status: :chosen} = _column),
    do: %{tone: "pass", label: "Chosen", reason: nil, confirm?: false}

  defp occurrence_badge(%{status: :confirmed} = _column),
    do: %{tone: "pass", label: "Checked", reason: nil, confirm?: false}

  defp occurrence_badge(%{by: by} = _column),
    do: %{tone: "pass", label: "Exact", reason: exact_reason(by), confirm?: false}

  defp exact_reason(nil), do: nil
  defp exact_reason(:stop_code), do: "By stop code."
  defp exact_reason(:stop_id), do: "By stop ID."
  defp exact_reason(:stop_name), do: "By stop name."
  defp exact_reason(:similar_name), do: "By similar name."
  defp exact_reason(:keyword), do: "By column name."
  defp exact_reason(_by), do: nil

  defp paired?(columns, %{col: col, target: {:occurrence, id, _side}}) do
    Enum.any?(columns, fn
      %{col: other, target: {:occurrence, other_id, _}} ->
        other_id == id and abs(other - col) == 1

      _column ->
        false
    end)
  end

  defp paired?(_columns, _column), do: false

  defp close_reason(column, occurrences, scope) do
    case column_stop_name(column, occurrences, scope) do
      "" -> "Check the close match."
      stop -> "Check that “#{column.header}” is #{stop}."
    end
  end

  defp order_reason(columns, column, occurrences, scope) do
    current = column_stop_name(column, occurrences, scope)
    position = occurrence_position(column, occurrences)

    after_column =
      Enum.find(columns, fn other ->
        other.col < column.col and strip_col?(other) and
          occurrence_position(other, occurrences) > position
      end)

    case {current, after_column} do
      {"", _} ->
        "This column is out of pattern order."

      {name, nil} ->
        "#{name} comes before the column to its left on this pattern."

      {name, other} ->
        "#{name} comes before #{column_stop_name(other, occurrences, scope)} on this pattern."
    end
  end

  defp column_stop_name(%{target: {:occurrence, id, _side}}, occurrences, scope) do
    with %{stop_id: stop_id} <- Enum.find(occurrences, &(&1.id == id)),
         %{stop_name: name} when is_binary(name) <-
           Map.get(Map.get(scope, :stops, %{}) || %{}, stop_id) do
      name
    else
      _missing -> ""
    end
  end

  defp column_stop_name(_column, _occurrences, _scope), do: ""

  defp occurrence_position(%{target: {:occurrence, id, _side}}, occurrences) do
    case Enum.find(occurrences, &(&1.id == id)) do
      %{position: position} when is_integer(position) -> position
      _missing -> -1
    end
  end

  defp occurrence_position(_column, _occurrences), do: -1

  # `<.input>` renders `errors` through its own error element (with
  # `aria-invalid`) and `help` as plain text; the badge row never repeats
  # the reason, so bad columns pass it as errors and good columns as help.
  defp column_badges(columns, occurrences, scope) do
    Map.new(columns, &{&1.col, column_badge(columns, &1, occurrences, scope)})
  end

  defp column_input_errors(%{tone: tone, reason: reason}) when tone in ["error", "warning"] do
    [reason]
  end

  defp column_input_errors(_badge), do: []

  defp column_input_help(%{tone: tone}) when tone in ["error", "warning"], do: nil
  defp column_input_help(%{reason: reason}), do: reason

  defp issue_count_text([]), do: "All columns are matched."
  defp issue_count_text([_single]), do: "1 column needs a decision before review."
  defp issue_count_text(issues), do: "#{length(issues)} columns need a decision before review."

  defp issue_kind_text(:close), do: "check the close match"
  defp issue_kind_text(:out_of_order), do: "out of order"
  defp issue_kind_text(:unmatched), do: "choose a stop or Not used"
  defp issue_kind_text(_kind), do: "needs a decision"

  defp column_header(columns, col) do
    case Enum.find(columns, &(&1.col == col)) do
      %{header: header} -> header
      _missing -> ""
    end
  end

  defp strip_entries(occurrences, columns, scope) do
    mapped_any? = Enum.any?(columns, &strip_col?/1)
    last_index = max(length(occurrences) - 1, 0)

    occurrences
    |> Enum.with_index()
    |> Enum.map(fn {occurrence, index} ->
      hits =
        columns
        |> Enum.filter(&strip_hit?(&1, occurrence.id))
        |> Enum.sort_by(& &1.col)

      missing =
        cond do
          hits != [] -> nil
          index == 0 or index == last_index or not mapped_any? -> "no column"
          true -> "filled in"
        end

      %{
        position: index + 1,
        name: occurrence_stop_name(scope, occurrence),
        letters: Enum.map(hits, &strip_letter(&1, length(hits))),
        missing: missing,
        last: index == last_index
      }
    end)
  end

  defp strip_hit?(%{status: :out_of_order}, _id), do: false
  defp strip_hit?(%{target: {:occurrence, id, _side}}, id), do: true
  defp strip_hit?(_column, _id), do: false

  defp strip_letter(%{col: col, target: {:occurrence, _id, :arrival}}, _count),
    do: "#{column_letter(col)} arr"

  defp strip_letter(%{col: col, target: {:occurrence, _id, :departure}}, count)
       when count > 1,
       do: "#{column_letter(col)} dep"

  defp strip_letter(%{col: col}, _count), do: column_letter(col)

  defp letter_column(letter) when is_binary(letter) do
    letter |> String.split(" ") |> List.first("")
  end

  # --- Review matrix (step 26) ---

  defp matrix_row_bg(:needs_decision), do: "bg-warning-bg/40"
  defp matrix_row_bg(:remove), do: "bg-error-bg/30"
  defp matrix_row_bg(_op), do: "bg-white"

  defp matrix_time_class(%{pasted?: true}, false), do: "font-[650] text-strong"
  defp matrix_time_class(%{pasted?: true}, true), do: "text-muted"
  defp matrix_time_class(_cell, _muted), do: "italic text-muted"

  defp matrix_pattern_name(scope) when is_map(scope) do
    patterns = Map.get(scope, :patterns, []) || []

    case Enum.find(patterns, &(&1.id == Map.get(scope, :pattern_id))) do
      %{name: name} when is_binary(name) and name != "" -> name
      _pattern -> "this pattern"
    end
  end

  defp matrix_pattern_name(_scope), do: "this pattern"

  defp timing_note_body(%{new?: false} = note) do
    base =
      "Existing timing on #{note.pattern_name}, #{note.duration} min. " <>
        "Every time in these rows, including the filled-in ones, matches it, so it’s reused."

    if note.users > 0 do
      base <> " Used by #{Wording.count_noun(note.users, "row")} here."
    else
      base
    end
  end

  defp timing_note_body(%{new?: true} = note) do
    base = "New timing on #{note.pattern_name}, #{note.duration} min. Pasted times are exact."

    estimated =
      case {note.estimated, note.template_name} do
        {[], _template} ->
          ""

        {stops, template} when is_binary(template) ->
          " Times at #{Enum.join(stops, ", ")} are estimated from #{template}, scaled to each pasted segment. " <>
            "They are stored to the second, marked as estimates (timepoint 0), and shown here to the minute."

        {stops, _template} ->
          " Times at #{Enum.join(stops, ", ")} are spaced evenly between the pasted times. " <>
            "They are stored to the second, marked as estimates (timepoint 0), and shown here to the minute."
      end

    base <> estimated <> " Applying creates it for #{Wording.count_noun(note.users, "trip")}."
  end

  @doc """
  Renders step 28, the sticky apply bar at the foot of the review: the
  apply status, Discard paste and the Apply / Replace trips button.

  The button posts `paste_apply` with `phx-disable-with`, so a second
  click never double-applies; clicking it also marks the hidden
  `#paste-applying` flag, so a reconnect during the apply recovers
  through form recovery into the unknown-outcome notice instead of
  re-applying. A lost socket shows `#paste-notice-offline` and disables
  the button until it returns, exactly like the Schedules controls.
  """
  attr :review, :map, required: true, doc: "the pure paste review with plan counts"
  attr :input, :map, required: true, doc: "the LiveView paste input with the mode"
  attr :notice, :atom, default: nil, doc: "the current apply outcome, if any"

  def apply_bar(assigns) do
    counts = assigns.review.plan.counts
    mode = review_mode(assigns.input)
    applied = counts.add + counts.change + counts.remove
    refusal = assigns.review.plan.refusal

    assigns =
      assigns
      |> assign(:applied, applied)
      |> assign(:mode, mode)
      |> assign(:refusal, refusal)
      |> assign(:needs_decision, counts.needs_decision)
      |> assign(:label, apply_label(mode, applied))
      |> assign(:disable_with, "Applying #{Wording.count_noun(applied, "change")}…")
      |> assign(:status, apply_status(mode, assigns.review, assigns.notice))
      |> assign(
        :disabled?,
        not is_nil(refusal) or (applied == 0 and counts.needs_decision == 0) or
          assigns.notice == :permission
      )

    ~H"""
    <div
      id="paste-apply-bar"
      class="sticky bottom-0 z-20 flex flex-wrap items-center justify-between gap-3 border-t border-subtle bg-white/95 px-5 py-3.5 backdrop-blur"
    >
      <p id="paste-apply-status" role="status" tabindex="-1" class="text-sm text-muted">
        {@status}
      </p>
      <div class="flex flex-wrap gap-3">
        <.button
          type="button"
          id="paste-discard"
          variant="secondary"
          class="min-h-11"
          phx-click="paste_discard"
        >
          Discard paste
        </.button>
        <.button
          type="button"
          id="paste-apply"
          class="min-h-11"
          phx-click={
            JS.set_attribute({"value", "true"}, to: "#paste-applying")
            |> JS.push("paste_apply")
          }
          phx-disable-with={@disable_with}
          disabled={@disabled?}
          aria-describedby="paste-apply-status"
          phx-disconnected={
            JS.show(to: "#paste-notice-offline")
            |> JS.set_attribute({"disabled", ""}, to: "#paste-apply")
          }
          phx-connected={
            JS.hide(to: "#paste-notice-offline")
            |> JS.remove_attribute("disabled", to: "#paste-apply")
          }
        >
          {@label}
        </.button>
      </div>
      <input type="hidden" id="paste-applying" name="paste[applying]" value="false" />
    </div>
    """
  end

  @doc """
  Renders step 28, the apply outcome notices above the review: stale,
  busy, mixed service, failed, unknown, reconnected and permission, plus the always
  present (hidden) offline notice the apply bar's socket pair toggles.
  """
  attr :notice, :atom, default: nil, doc: "the current apply outcome, if any"
  attr :failed_reference, :string, default: nil, doc: "the failed notice's reference id"
  attr :refusal_message, :string, default: nil, doc: "the mixed-service refusal sentence"
  attr :scope, :map, required: true, doc: "the loaded paste scope"
  attr :review, :map, default: nil, doc: "the pure paste review, for the unknown count"
  attr :version_id, :any, required: true, doc: "the current GTFS version id"
  attr :route_id, :string, required: true, doc: "the natural route id"

  attr :has_text, :boolean,
    default: false,
    doc: "the paste form holds text, so Open Schedules asks first (step 30)"

  def notices(assigns) do
    assigns =
      assigns
      |> assign(:calendar_name, review_calendar_name(assigns.scope))
      |> assign(:direction_adjective, review_direction_adjective(assigns.scope))
      |> assign(:unknown_count, unknown_change_count(assigns.review))

    ~H"""
    <div id="paste-notices" class="mt-4 grid gap-3 empty:hidden">
      <.message
        :if={@notice == :stale}
        id="paste-notice-stale"
        kind="warning"
        role="status"
        tabindex="-1"
        title={"Nothing was applied. #{@calendar_name} #{@direction_adjective} changed after this review."}
        class="outline-none"
      >
        Review again to compare your paste with the current schedule. Your paste,
        columns and decisions stay.
        <:action>
          <.button
            type="button"
            id="paste-review-again"
            variant="secondary"
            class="min-h-11"
            phx-click="paste_review_again"
          >
            Review again
          </.button>
        </:action>
      </.message>
      <.message
        :if={@notice == :busy}
        id="paste-notice-busy"
        kind="warning"
        role="status"
        tabindex="-1"
        title="Nothing was applied. Someone else was saving this route."
        class="outline-none"
      >
        Another change to this route finished first. Apply again; if the schedule
        changed, the review is rebuilt first.
        <:action>
          <.button
            type="button"
            id="paste-apply-again"
            variant="secondary"
            class="min-h-11"
            phx-click="paste_apply"
          >
            Apply again
          </.button>
        </:action>
      </.message>
      <.message
        :if={@notice == :mixed_service}
        id="paste-notice-mixed-service"
        kind="error"
        role="alert"
        tabindex="-1"
        title="Nothing was applied."
        class="outline-none"
      >
        {@refusal_message} Your paste, columns and decisions stay.
      </.message>
      <.message
        :if={@notice == :failed}
        id="paste-notice-failed"
        kind="error"
        role="alert"
        tabindex="-1"
        title="Nothing was applied. The schedule couldn’t be saved."
        class="outline-none"
      >
        The server stopped before finishing, so every change was rolled back. Your
        paste, columns and decisions stay. Reference {@failed_reference}.
        <:action>
          <.button
            type="button"
            id="paste-try-again"
            variant="secondary"
            class="min-h-11"
            phx-click="paste_apply"
          >
            Try again
          </.button>
        </:action>
      </.message>
      <.message
        :if={@notice == :unknown}
        id="paste-notice-unknown"
        kind="warning"
        role="status"
        tabindex="-1"
        title="The connection dropped while applying. It isn’t known whether the changes were saved."
        class="outline-none"
      >
        Check Schedules before applying again. If the {Wording.count_noun(@unknown_count, "change")} {unknown_verb(
          @unknown_count
        )} saved, reviewing again shows {unknown_them(@unknown_count)} as trips that already exist.
        <:action>
          <div class="flex flex-wrap gap-2">
            <.link
              id="paste-open-schedules"
              href="#"
              phx-click="paste_leave"
              data-confirm={@has_text && leave_confirm_message()}
              class="btn btn-outline min-h-11"
            >
              Open Schedules
            </.link>
            <.button
              type="button"
              id="paste-unknown-review-again"
              variant="secondary"
              class="min-h-11"
              phx-click="paste_review_again"
            >
              Review again
            </.button>
          </div>
        </:action>
      </.message>
      <.message
        :if={@notice == :reconnected}
        id="paste-notice-reconnected"
        kind="info"
        role="status"
        tabindex="-1"
        title="Reconnected. Your paste was restored."
        class="outline-none"
      >
        The timetable, columns and decisions came back with the page, and the review
        was rebuilt against the current schedule.
        <:action>
          <.button
            type="button"
            id="paste-dismiss-notice"
            variant="secondary"
            class="min-h-11"
            phx-click="paste_dismiss_notice"
          >
            Dismiss
          </.button>
        </:action>
      </.message>
      <.message
        :if={@notice == :permission}
        id="paste-notice-permission"
        kind="error"
        role="alert"
        tabindex="-1"
        title="Nothing was applied. You can’t edit this version any more."
        class="outline-none"
      >
        Your role changed while this page was open. Ask an organization administrator
        for Editor access. Your paste stays here until you leave.
      </.message>
      <.message
        id="paste-notice-offline"
        kind="warning"
        role="status"
        title="Connection lost. Reconnecting…"
        hidden
        phx-disconnected={JS.remove_attribute("hidden")}
        phx-connected={JS.set_attribute({"hidden", ""})}
      >
        Your paste stays on this page. You can keep reviewing; applying waits for the
        connection.
      </.message>
    </div>
    """
  end

  @doc """
  Renders step 28, the Replace confirmation: a `confirm_dialog` naming the
  removed trips, the counts, the patterns and the transfers, focused on
  Keep reviewing with Replace trips as the confirm.
  """
  attr :open, :boolean, required: true, doc: "the dialog is requested open"
  attr :review, :map, required: true, doc: "the pure paste review with the plan"
  attr :scope, :map, required: true, doc: "the loaded paste scope"
  attr :input, :map, required: true, doc: "the LiveView paste input with the mode"

  def replace_confirm(assigns) do
    plan = assigns.review.plan
    counts = plan.counts

    assigns =
      assigns
      |> assign(:counts, counts)
      |> assign(:removals, replace_removals(plan))
      |> assign(:transfers, plan.transfers_removed || 0)
      |> assign(:patterns, replace_pattern_names(assigns.scope, plan))
      |> assign(:calendar_name, review_calendar_name(assigns.scope))
      |> assign(:direction_adjective, review_direction_adjective(assigns.scope))

    ~H"""
    <.confirm_dialog
      id="paste-replace-confirm"
      chrome="planner"
      open={@open}
      title={"Replace #{@calendar_name} #{@direction_adjective} trips?"}
      confirm_label="Replace trips"
      pending_label="Replacing…"
      cancel_label="Keep reviewing"
      on_confirm="paste_replace_confirm"
      on_cancel="paste_replace_cancel"
      return_focus_id="paste-apply"
      described_by="paste-replace-confirm-body"
    >
      <div>
        <p>
          This removes {Wording.count_noun(@counts.remove, "trip")} ({replace_removal_list(@removals)}),
          changes {@counts.change} and adds {@counts.add} on {@patterns}.
        </p>
        <p :if={@transfers > 0} class="mt-2">
          <strong class="text-strong">{Wording.count_noun(@transfers, "transfer")}</strong>
          that {transfer_verb(@transfers)} the removed {Wording.noun(@counts.remove, "trip")} {transfer_are(
            @transfers
          )} removed too.
        </p>
        <p class="mt-2 text-muted">
          Other patterns, calendars and the other direction stay as they are. History
          records the removed trips, but applying can’t be undone here.
        </p>
      </div>
    </.confirm_dialog>
    """
  end

  @doc """
  Renders step 28, the Discard paste confirmation: a `confirm_dialog`
  that clears the pasted timetable, the columns and the decisions.
  Nothing has been applied, so discarding only drops the draft input.
  """
  attr :open, :boolean, required: true, doc: "the dialog is requested open"

  def discard_confirm(assigns) do
    ~H"""
    <.confirm_dialog
      id="paste-discard-confirm"
      chrome="planner"
      open={@open}
      title="Discard this paste?"
      confirm_label="Discard paste"
      pending_label="Discarding…"
      cancel_label="Keep reviewing"
      on_confirm="paste_discard_confirm"
      on_cancel="paste_discard_cancel"
      return_focus_id="paste-discard"
      described_by="paste-discard-confirm-body"
    >
      <p>
        The pasted timetable, columns and decisions go away. Nothing has been applied.
      </p>
    </.confirm_dialog>
    """
  end

  @doc """
  Renders step 30, the version-switch confirmation: a `confirm_dialog`
  naming the version, focused on Keep reviewing with Switch version as
  the confirm. Confirming navigates like `RouteSchedulesLive`
  `switch_version/2`; cancelling keeps the paste.
  """
  attr :open, :boolean, required: true, doc: "the dialog is requested open"
  attr :version_name, :string, required: true, doc: "the target version name"

  def switch_confirm(assigns) do
    ~H"""
    <.confirm_dialog
      id="paste-switch-confirm"
      chrome="planner"
      open={@open}
      title={"Switch to #{@version_name}?"}
      confirm_label="Switch version"
      pending_label="Switching…"
      cancel_label="Keep reviewing"
      on_confirm="paste_switch_confirm"
      on_cancel="paste_switch_cancel"
      return_focus_id="gtfs-version-trigger"
      described_by="paste-switch-confirm-body"
    >
      <p>
        Each version has its own schedules, so your pasted timetable and review are
        discarded. Paste again after switching.
      </p>
    </.confirm_dialog>
    """
  end

  @doc """
  Renders step 30, the leave confirmation: a `confirm_dialog` shown when
  in-app navigation (the route tabs, the header) is intercepted with a
  paste in progress. Confirming leaves for the intercepted path;
  cancelling keeps the paste. The copy matches the prototype's leave
  state.
  """
  attr :open, :boolean, required: true, doc: "the dialog is requested open"

  def leave_confirm(assigns) do
    ~H"""
    <.confirm_dialog
      id="paste-leave-confirm"
      chrome="planner"
      open={@open}
      title="Leave without applying?"
      confirm_label="Leave page"
      pending_label="Leaving…"
      cancel_label="Keep reviewing"
      on_confirm="paste_leave_confirm"
      on_cancel="paste_leave_cancel"
      return_focus_id="paste-source"
      described_by="paste-leave-confirm-body"
    >
      <p>
        Your pasted timetable, column matches and decisions are discarded. Nothing
        has been applied to the schedule.
      </p>
    </.confirm_dialog>
    """
  end

  @doc """
  Renders step 30, the leave guard hook: an inert, invisible element
  carrying the colocated `.PasteLeaveGuard` hook. The hook manages its
  own listeners (never the element's children), so the element is
  `phx-update="ignore"`d with a stable id and `hidden`.

  While the paste form holds text (or a columns/review step is on the
  page), the hook answers `beforeunload`, which covers full-page leaves
  such as the header version switcher, and intercepts in-app
  (`data-phx-link="redirect"`) navigation clicks plus header version
  option clicks, pushing them to the LiveView (`paste_leave_guard` /
  `switch_gtfs_version`) so the server opens `#paste-leave-confirm` /
  `#paste-switch-confirm`. With an empty form the hook stays silent and
  navigation is immediate.
  """
  def leave_guard(assigns) do
    ~H"""
    <div
      id="paste-leave-guard"
      phx-hook=".PasteLeaveGuard"
      phx-update="ignore"
      hidden
    >
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".PasteLeaveGuard">
      export default {
        mounted() {
          this.beforeUnload = (event) => {
            if (!this.hasPaste()) return
            event.preventDefault()
            event.returnValue = ""
          }
          window.addEventListener("beforeunload", this.beforeUnload)
          this.clickHandler = (event) => {
            if (!(event.target instanceof Element)) return
            const version = event.target.closest("#gtfs-version-switcher [data-version-option]")
            const nav = event.target.closest('a[data-phx-link="redirect"]')
            if (!version && !nav) return
            if (!this.hasPaste()) return
            if (version && version.dataset.versionId === this.currentVersion()) return
            event.preventDefault()
            event.stopPropagation()
            if (version) {
              this.pushEvent("switch_gtfs_version", {version: version.dataset.versionId})
            } else {
              this.pushEvent("paste_leave_guard", {to: nav.getAttribute("href")})
            }
          }
          document.addEventListener("click", this.clickHandler, true)
        },
        destroyed() {
          window.removeEventListener("beforeunload", this.beforeUnload)
          document.removeEventListener("click", this.clickHandler, true)
        },
        currentVersion() {
          return document.querySelector("#gtfs-version-switcher")?.dataset.currentVersion || null
        },
        hasPaste() {
          const source = document.querySelector("#paste-source")
          if (source && source.value.trim() !== "") return true
          return !!document.querySelector("#paste-review, #paste-columns")
        }
      }
    </script>
    """
  end

  # --- Apply bar, notices and confirmations (step 28) ---

  defp apply_label(:replace, applied),
    do: "Replace trips · #{Wording.count_noun(applied, "change")}"

  defp apply_label(_mode, applied), do: "Apply #{Wording.count_noun(applied, "change")}"

  defp apply_status(_mode, _review, :permission),
    do: "Editing isn’t available with your current role."

  defp apply_status(_mode, %{plan: %{refusal: refusal}}, _notice) when not is_nil(refusal),
    do: "Replace can’t run on this schedule."

  defp apply_status(_mode, %{plan: plan}, _notice) do
    counts = plan.counts
    applied = counts.add + counts.change + counts.remove

    cond do
      plan.refusal == :nothing_accepted ->
        "Replace needs at least one pasted trip."

      applied == 0 and counts.needs_decision == 0 ->
        "Nothing to apply."

      counts.needs_decision > 0 ->
        "#{Wording.count_noun(counts.needs_decision, "row")} need a decision before applying."

      true ->
        "Ready. Nothing has been saved yet."
    end
  end

  defp attention_title(1), do: "1 row needs a decision."
  defp attention_title(count), do: "#{count} rows need a decision."

  # Rows still needing a decision, in plan order, for the
  # `#paste-review-errors` summary: each links to its matrix row.
  defp attention_rows(%{plan: %{changes: changes}}) when is_list(changes) do
    changes
    |> Enum.filter(&(change_op(&1) == :needs_decision))
    |> Enum.map(&attention_entry/1)
    |> Enum.reject(&is_nil/1)
  end

  defp attention_rows(_review), do: []

  defp attention_entry(change) do
    case attention_row_no(change) do
      nil -> nil
      row -> %{row: row, trip: attention_trip(change), hint: attention_hint(change)}
    end
  end

  defp change_op(change) when is_map(change) do
    Map.get(change, :op, Map.get(change, "op"))
  end

  defp change_op(_change), do: nil

  defp attention_row_no(change) do
    row = Map.get(change, :row, Map.get(change, "row"))

    cond do
      is_map(row) and is_integer(Map.get(row, :row, Map.get(row, "row"))) ->
        Map.get(row, :row, Map.get(row, "row"))

      is_integer(Map.get(change, :row_no, Map.get(change, "row_no"))) ->
        Map.get(change, :row_no, Map.get(change, "row_no"))

      true ->
        nil
    end
  end

  defp attention_trip(change) do
    case Map.get(change, :trip_short_name, Map.get(change, "trip_short_name")) do
      short when is_binary(short) and short != "" -> short
      _short -> nil
    end
  end

  defp attention_hint(change) do
    row = Map.get(change, :row, Map.get(change, "row"))
    issue = if is_map(row), do: Map.get(row, :issue, Map.get(row, "issue")), else: nil
    candidates = List.wrap(Map.get(change, :candidates, Map.get(change, "candidates", [])))

    issue_hint(issue) || candidate_hint(candidates)
  end

  defp issue_hint(issue) do
    cond do
      match?({:pattern, _}, issue) -> "choose a pattern"
      issue == :no_pattern -> "no pattern fits"
      match?({:cell, _, _}, issue) -> "fix a time"
      match?({:backwards, _, _}, issue) -> "fix a time"
      match?({:twelve_hour, _}, issue) -> "confirm the start time"
      issue == :empty -> "add times"
      true -> nil
    end
  end

  defp candidate_hint(candidates) do
    if Enum.any?(candidates, &is_map/1) do
      "choose the trip it replaces"
    else
      "choose a pattern"
    end
  end

  defp unknown_change_count(%{plan: %{counts: counts}}) when is_map(counts) do
    (Map.get(counts, :add) || 0) + (Map.get(counts, :change) || 0) +
      (Map.get(counts, :remove) || 0)
  end

  defp unknown_change_count(_review), do: 0

  defp unknown_verb(1), do: "was"
  defp unknown_verb(_count), do: "were"

  defp unknown_them(1), do: "it"
  defp unknown_them(_count), do: "them"

  # Step 30, the leave `data-confirm` copy for the page's own Open
  # Schedules link: the prototype's leave dialog content in the one
  # string a native confirm shows. The `.PasteLeaveGuard` hook carries
  # the same copy for the tabs and header it intercepts.
  defp leave_confirm_message do
    "Leave without applying? Your pasted timetable, column matches and decisions " <>
      "are discarded. Nothing has been applied to the schedule."
  end

  # Removals in plan order for the Replace confirmation: each names its
  # natural trip id and start clock.
  defp replace_removals(%{changes: changes}) when is_list(changes) do
    changes
    |> Enum.filter(&(change_op(&1) == :remove))
    |> Enum.map(fn change ->
      trip = Map.get(change, :trip, Map.get(change, "trip", %{}))
      %{id: removal_trip_id(trip), start: removal_start(trip)}
    end)
  end

  defp replace_removals(_plan), do: []

  defp removal_trip_id(trip) when is_map(trip) do
    Map.get(trip, :trip_id, Map.get(trip, "trip_id", "this trip"))
  end

  defp removal_trip_id(_trip), do: "this trip"

  defp removal_start(trip) when is_map(trip) do
    case Map.get(trip, :start_secs, Map.get(trip, "start_secs")) do
      secs when is_integer(secs) -> GtfsTime.display(secs)
      _secs -> nil
    end
  end

  defp removal_start(_trip), do: nil

  defp replace_removal_list([]), do: "no trips"

  defp replace_removal_list(removals) do
    Enum.map_join(removals, ", ", fn
      %{id: id, start: nil} -> id
      %{id: id, start: start} -> "#{id} at #{start}"
    end)
  end

  defp transfer_verb(1), do: "names"
  defp transfer_verb(_count), do: "name"

  defp transfer_are(1), do: "is"
  defp transfer_are(_count), do: "are"
end
