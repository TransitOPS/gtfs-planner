defmodule GtfsPlannerWeb.Gtfs.TimetablePasteComponents do
  @moduledoc """
  Presentation for the Paste timetable page shell.

  Step 21 owns the shell: the schedule line (`scope_line/1`), the setup
  empty states (`setup_empty/1`) and the first-paint skeleton. Step 22 owns
  the Change schedule drawer (`scope_drawer/1`): the calendar select over
  every calendar, the direction radios and the direction-filtered pattern
  select with trip counts. The timetable step (step 23) and the review UI
  (steps 25-28) add components here in later steps.
  """
  use GtfsPlannerWeb, :html

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
end
