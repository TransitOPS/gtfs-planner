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
  from, Stops view, the three metrics, the refusal and nothing callouts, the
  filter buttons and the `#paste-rows` placeholder step 26 streams its matrix
  into.
  """
  use GtfsPlannerWeb, :html

  alias Phoenix.LiveView.JS

  import GtfsPlannerWeb.PlannerComponents,
    only: [first_use: 1, drawer_scroll: 1, drawer_footer: 1, message: 1]

  alias GtfsPlanner.Gtfs.Trip

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
              <span class="font-normal text-muted">{stop_count(@pattern)}</span>
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
    " · #{date_label(first, last)}"
  end

  defp calendar_dates(_calendar), do: ""

  defp date_label(date, date), do: Calendar.strftime(date, "%b %-d, %Y")

  defp date_label(first, last) do
    "#{Calendar.strftime(first, "%b %-d, %Y")} – #{Calendar.strftime(last, "%b %-d, %Y")}"
  end

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
      {"#{pattern.name} · #{trip_count(count)}", pattern.id}
    end)
  end

  defp pattern_options(_draft_scope), do: []

  defp pattern_help("1"), do: pattern_help_text("inbound")
  defp pattern_help(_direction), do: pattern_help_text("outbound")

  defp pattern_help_text(adjective) do
    "Columns are matched to its stops. A row that skips stops goes on another #{adjective} " <>
      "pattern when exactly one fits."
  end

  defp trip_count(1), do: "1 trip"
  defp trip_count(count), do: "#{count} trips"

  defp calendar_detail(%{first_active_date: %Date{} = first, last_active_date: %Date{} = last}) do
    "#{Calendar.strftime(first, "%b %-d, %Y")} – #{Calendar.strftime(last, "%b %-d, %Y")}"
  end

  defp calendar_detail(_calendar), do: nil

  defp stop_count(%{occurrences: occurrences}) when is_list(occurrences) do
    case length(occurrences) do
      1 -> "1 stop"
      count -> "#{count} stops"
    end
  end

  defp stop_count(_pattern), do: nil

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
      <span
        class="grid size-7 shrink-0 place-items-center rounded-full bg-success-bg text-success-fg"
        title="Done"
      >
        <.icon name="hero-check" class="size-4" />
      </span>
      <h2 class="text-[15px] font-bold text-strong">Timetable</h2>
      <p class="min-w-0 flex-1 basis-[280px] text-sm text-muted">{@summary}</p>
      <.button id="paste-source-edit" variant="secondary" phx-click="edit_source">
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
          Showing {length(@samples)} of {row_count_text(@total_rows)}. Two neighbouring
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

  defp row_count_text(1), do: "1 row"
  defp row_count_text(count), do: "#{count} rows"

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
  callouts, the filter buttons and the `#paste-rows` placeholder step 26
  streams its matrix into.

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
  prototype). Copy follows the prototype's review stage.
  """
  attr :review, :map, required: true, doc: "the pure paste review with grid, rows and plan"

  attr :scope, :map,
    required: true,
    doc: "the loaded paste scope with calendar, patterns and route"

  attr :input, :map,
    required: true,
    doc: "the LiveView paste input with mode, template, stops view and filter"

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
            {@calendar_name} · {@direction_name} · {plural(@pasted_rows, "pasted row")}
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
        Every row is skipped, so applying would remove all {plural(@trips_before, "trip")} and
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
      <%!-- Step 26 streams the review matrix into `#paste-rows`. --%>
      <div id="paste-rows" class="border-t border-subtle px-5 py-4">
        <p class="text-sm text-muted">The review rows will appear here.</p>
      </div>
    </section>
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
    {"needs_decision", "Needs decision"}
  ]

  defp review_mode(%{mode: :replace}), do: :replace
  defp review_mode(%{mode: "replace"}), do: :replace
  defp review_mode(_input), do: :add

  defp review_stops_view(%{stops_view: :all}), do: :all
  defp review_stops_view(%{stops_view: "all"}), do: :all
  defp review_stops_view(_input), do: :pasted

  defp review_filter(%{filter: filter})
       when filter in ~w(all add change remove unchanged duplicate skipped needs_decision),
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
      |> Enum.map(fn id ->
        Enum.find_value(patterns, fn pattern ->
          if pattern_id(pattern) == id, do: pattern_name(pattern)
        end)
      end)
      |> Enum.reject(&is_nil/1)

    case names do
      [] -> "the pasted patterns"
      names -> Enum.join(names, " and ")
    end
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

    cond do
      is_binary(wanted) and wanted in ids -> wanted
      true -> most_used_timing(timings) || ""
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

  defp visible_filters(input, plan) do
    counts = plan.counts
    total = if is_list(plan.changes), do: length(plan.changes), else: 0
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
        Calendar.strftime(time, "%H:%M")

      binary when is_binary(binary) ->
        case String.split(binary, ":") do
          [hour, minute | _rest] -> "#{hour}:#{minute}"
          _parts -> nil
        end

      _time ->
        nil
    end
  end

  defp clock_time(_window, _key), do: nil

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
      "#{plural(trips, "trip row")} · #{plural(columns, "column")} · #{orientation_label(Map.get(review, :orientation))}"

    if header_checked?(form), do: summary, else: "#{summary} · no header row"
  end

  defp orientation_label(:stops_in_rows), do: "stops down the side"
  defp orientation_label(_orientation), do: "trips in rows"

  defp plural(1, one), do: "1 #{one}"
  defp plural(count, one), do: "#{count} #{one}s"

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
        if paired?(columns, col) do
          %{tone: "pass", label: "Arrival", reason: nil, confirm?: false}
        else
          occurrence_badge(col)
        end

      %{target: {:occurrence, _id, :departure}} = col when is_map(col) ->
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

      %{target: target} when target in [:trip_short_name, :block_id, :trip_headsign] ->
        if column.status == :chosen do
          %{tone: "pass", label: "Chosen", reason: nil, confirm?: false}
        else
          %{tone: "pass", label: "Exact", reason: "By column name.", confirm?: false}
        end

      _column ->
        %{tone: "draft", label: "Unknown", reason: nil, confirm?: false}
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
end
