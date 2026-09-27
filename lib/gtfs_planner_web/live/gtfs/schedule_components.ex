defmodule GtfsPlannerWeb.Gtfs.ScheduleComponents do
  @moduledoc """
  Read-side presentation for the route Schedules page.

  Every component here renders data the scoped read already loaded through
  `GtfsPlanner.Gtfs.load_route_schedule/4`: the controls row that turns filter
  values into URL parameters, the planning summary, one timetable per pattern
  section, and the empty, unlinked and unavailable notices. Stored stop times are
  displayed as they are; nothing here recomputes a trip from a timing.

  The timetable keeps its selection and Start columns pinned while the stop
  columns scroll inside the table's own container, so the page itself never
  scrolls horizontally. Mutation controls are deliberately absent: the drawers,
  row actions and bulk toolbar arrive only with the write wiring.
  """
  use GtfsPlannerWeb, :html

  alias GtfsPlanner.Gtfs.GtfsTime
  alias GtfsPlanner.Gtfs.RoutePattern

  # The pinned selection column is a fixed 3rem so the Start column can pin at a
  # known offset without measuring the rendered table.
  defp selection_cell_class, do: "sticky left-0 z-20 w-12 min-w-12 max-w-12 px-0 text-center"
  defp start_cell_class, do: "sticky left-12 z-20"

  @doc """
  Renders the controls row: calendar and pattern selects, the direction and
  stops segmented controls, and the link to calendar management.

  Each control posts its own field through the `filters` event, which the
  LiveView turns into the canonical URL parameters.
  """
  attr :calendar_form, :any, required: true
  attr :pattern_form, :any, required: true
  attr :calendars, :list, required: true
  attr :patterns, :list, required: true
  attr :filters, :map, required: true
  attr :direction_labels, :map, required: true
  attr :calendars_path, :string, required: true

  def controls(assigns) do
    assigns =
      assigns
      |> assign(:calendar_options, calendar_options(assigns.calendars))
      |> assign(:pattern_options, pattern_options(assigns.patterns, assigns.filters))
      |> assign(:direction_options, direction_options(assigns.direction_labels))
      |> assign(:stops_options, [{"Timepoints", "timepoints"}, {"All stops", "all"}])
      |> assign(:direction_value, to_string(assigns.filters.direction_id))
      |> assign(:stops_value, to_string(assigns.filters.stops))

    ~H"""
    <div id="schedules-controls" class="flex flex-wrap items-end gap-x-6 gap-y-4">
      <div class="w-full min-w-[240px] sm:w-auto sm:max-w-[320px]">
        <.form for={@calendar_form} id="schedule-calendar-form" phx-change="filters">
          <.input
            id="calendar-filter"
            field={@calendar_form[:service_id]}
            type="select"
            label="Calendar"
            prompt={@calendars == [] && "No calendars"}
            options={@calendar_options}
          />
        </.form>
      </div>

      <.segmented_control
        id="direction-filter"
        name="direction"
        legend="Direction"
        event="filters"
        options={@direction_options}
        value={@direction_value}
      />

      <div class="w-full min-w-[220px] sm:w-auto sm:max-w-[320px]">
        <.form for={@pattern_form} id="schedule-pattern-form" phx-change="filters">
          <.input
            id="pattern-filter"
            field={@pattern_form[:pattern]}
            type="select"
            label="Pattern"
            options={@pattern_options}
          />
        </.form>
      </div>

      <.segmented_control
        id="stops-filter"
        name="stops"
        legend="Stops shown"
        event="filters"
        options={@stops_options}
        value={@stops_value}
      />

      <div class="sm:ml-auto">
        <.link
          navigate={@calendars_path}
          id="schedules-manage-calendars"
          class="link inline-flex min-h-11 items-center text-sm"
        >
          Manage calendars
        </.link>
      </div>
    </div>
    """
  end

  @doc """
  Renders the trip and stop counts for the view plus the legend for the chosen
  stops mode and the after-midnight reminder.
  """
  attr :row_count, :integer, required: true
  attr :calendar_label, :string, required: true
  attr :direction_label, :string, required: true
  attr :stops, :atom, required: true

  def sections_meta(assigns) do
    ~H"""
    <div class="border-t border-base-300 pt-3">
      <div class="flex flex-wrap items-baseline justify-between gap-x-6 gap-y-1">
        <p id="schedules-view-counts" class="text-sm font-semibold">
          {@row_count} trips · {@calendar_label} · {@direction_label}
        </p>
        <p id="schedules-stops-legend" class="text-sm text-base-content/70">
          <%= if @stops == :all do %>
            All stops shown. Scroll each timetable to see more stops.
          <% else %>
            Timepoints are the key stops used in public timetables.
          <% end %>
        </p>
      </div>
      <p class="mt-1 text-xs text-base-content/70">
        After midnight, hours keep counting: <span class="font-mono">25:10</span>
        = 1:10 AM next day. The trip still belongs to the previous service day.
      </p>
    </div>
    """
  end

  @doc """
  Renders the planning summary: the vehicles-needed lower bound for this route
  alone, the direction's trips per hour, the incomplete-times note and the
  change marker container.
  """
  attr :summary, :map, required: true
  attr :route, :map, required: true
  attr :calendar_label, :string, required: true
  attr :direction_label, :string, required: true
  attr :vehicle_change, :any, default: nil

  def planning_summary(assigns) do
    assigns =
      assigns
      |> assign(:vehicles, assigns.summary.vehicles)
      |> assign(:hours, assigns.summary.trips_per_hour)

    ~H"""
    <section
      id="planning-summary"
      class="grid gap-6 border-t border-base-300 pt-4 lg:grid-cols-[minmax(0,3fr)_minmax(0,7fr)]"
    >
      <div id="vehicles-needed" class="min-w-0">
        <.count_strip
          id="planning-vehicles"
          items={[
            %{key: "vehicles", label: "Vehicles needed", count: @vehicles.count, tone: :neutral}
          ]}
        />
        <p id="vehicles-needed-line" class="mt-1 text-2xl leading-tight font-semibold">
          At least {@vehicles.count} vehicles for route {route_label(@route)} alone
        </p>
        <p id="vehicles-needed-context" class="mt-1 text-sm">
          {@calendar_label} · both directions
          <%= if @vehicles.at_secs do %>
            · most at {clock(@vehicles.at_secs)}
          <% end %>
        </p>
        <p class="mt-2 text-sm text-base-content/70">
          The most trips on this calendar running at once, in both directions. Other routes can
          share vehicles, and time between trips can mean more.
        </p>
        <p id="vehicle-change" class="mt-1 text-sm font-semibold text-warning">
          <%= if @vehicle_change do %>
            <span>{@vehicle_change.from} → {@vehicle_change.to}</span>
          <% end %>
        </p>
      </div>

      <div id="trips-per-hour-block" class="min-w-0">
        <p class="text-sm font-semibold">Trips per hour · {@direction_label}</p>
        <div id="trips-per-hour-scroll" class="overflow-x-auto">
          <table id="trips-per-hour" class="table table-sm w-auto">
            <thead>
              <tr>
                <th scope="col">Hour</th>
                <th
                  :for={{hour, _count, _approximate?} <- @hours}
                  id={"trips-per-hour-hour-#{hour}"}
                  scope="col"
                  class="text-right tabular-nums"
                >
                  {hour_label(hour)}
                </th>
              </tr>
            </thead>
            <tbody>
              <tr>
                <th scope="row">Trips</th>
                <td
                  :for={{hour, count, approximate?} <- @hours}
                  id={"trips-per-hour-count-#{hour}"}
                  class={[
                    "text-right tabular-nums",
                    count == 0 && "font-normal text-base-content/70"
                  ]}
                >
                  {hour_count_label(count, approximate?)}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
        <p class="mt-1 text-xs text-base-content/70">
          First departure. ≈ marks hours with frequency service, whose departures are not fixed
          times.
        </p>
        <p :if={@summary.incomplete_trip_count > 0} id="incomplete-times-note" class="mt-1 text-sm">
          {incomplete_times_note(@summary.incomplete_trip_count)}
        </p>
      </div>
    </section>
    """
  end

  @doc "Renders the warning notice for trips that belong to no section of their direction."
  attr :count, :integer, required: true
  attr :patterns_path, :string, required: true

  def unlinked_trips(assigns) do
    ~H"""
    <div id="schedules-unlinked">
      <.callout kind="warning" title={"#{@count} trips aren't linked to a pattern"}>
        Build patterns to include them in these timetables.
        <.link navigate={@patterns_path} class="link ml-1 inline-flex min-h-11 items-center">
          Go to patterns
        </.link>
      </.callout>
    </div>
    """
  end

  @doc "Renders the first-use notice for a version that has no calendars."
  attr :calendars_path, :string, required: true

  def no_calendars(assigns) do
    ~H"""
    <div id="schedules-no-calendars">
      <.empty_state title="This version has no calendars" class="bg-base-100">
        A calendar says which days a trip runs. Schedules need one before trips can be listed.
        <:action>
          <.link navigate={@calendars_path} class="btn btn-sm btn-primary min-h-11">
            Manage calendars
          </.link>
        </:action>
      </.empty_state>
    </div>
    """
  end

  @doc "Renders the first-use notice for a route that has no patterns."
  attr :patterns_path, :string, required: true

  def no_patterns(assigns) do
    ~H"""
    <div id="schedules-no-patterns">
      <.empty_state title="This route has no patterns yet" class="bg-base-100">
        Patterns define the stops a trip serves. Create a pattern and timing, then add departures.
        <:action>
          <.link navigate={@patterns_path} class="btn btn-sm btn-primary min-h-11">
            Go to patterns
          </.link>
        </:action>
      </.empty_state>
    </div>
    """
  end

  @doc "Renders the empty view when the chosen calendar and direction have no trips."
  attr :calendar_label, :string, required: true
  attr :direction_label, :string, required: true
  attr :pattern_name, :string, default: nil

  def no_trips(assigns) do
    ~H"""
    <div id="schedules-no-trips">
      <.empty_state title={no_trips_title(assigns)} class="bg-base-100">
        Add a departure using a pattern and timing.
      </.empty_state>
    </div>
    """
  end

  @doc """
  Renders one pattern section: its heading, headway bands, one line per timing
  in use, the omitted-stop count and its timetable table.
  """
  attr :section, :map, required: true
  attr :selected_ids, :any, required: true

  def section(assigns) do
    section = assigns.section
    rows = section.rows

    assigns =
      assigns
      |> assign(:rows, rows)
      |> assign(:section_id, section.pattern.route_pattern_id)
      |> assign(
        :all_selected?,
        rows != [] and Enum.all?(rows, &MapSet.member?(assigns.selected_ids, &1.id))
      )

    ~H"""
    <section aria-labelledby={"section-#{@section_id}-heading"}>
      <div class="flex flex-wrap items-baseline justify-between gap-x-6 gap-y-1">
        <h2
          id={"section-#{@section_id}-heading"}
          class="flex items-center gap-2 text-lg font-semibold"
        >
          {@section.pattern.route_pattern_name || @section.pattern.route_pattern_id}
          <span class={["badge badge-sm", typicality_class(@section.pattern.route_pattern_typicality)]}>
            {RoutePattern.typicality_label(@section.pattern.route_pattern_typicality)}
          </span>
        </h2>
        <p id={"section-#{@section_id}-facts"} class="text-sm text-base-content/70">
          {length(@rows)} trips · {length(@section.all_columns)} stops
        </p>
      </div>

      <dl class="mt-2 space-y-1 text-sm">
        <div class="flex flex-wrap gap-x-6">
          <dt class="w-44 shrink-0 text-base-content/70">Departures</dt>
          <dd class="flex flex-wrap gap-x-6">
            <span
              :for={{band, index} <- Enum.with_index(@section.bands)}
              id={"section-#{@section_id}-band-#{index}"}
            >
              {band_text(band)}
            </span>
          </dd>
        </div>
        <div class="flex flex-wrap gap-x-6">
          <dt class="w-44 shrink-0 text-base-content/70">
            <%= if @section.stops == :all do %>
              Minutes between stops
            <% else %>
              Minutes between timepoints
            <% end %>
          </dt>
          <dd class="flex flex-wrap gap-x-6">
            <span
              :for={line <- @section.timing_lines}
              id={"section-#{@section_id}-timing-#{line.timing_id}"}
            >
              {timing_line_text(line)}
            </span>
            <span
              :if={@section.custom_trip_count > 0}
              id={"section-#{@section_id}-custom-trips"}
            >
              {@section.custom_trip_count} {custom_trips_label(@section.custom_trip_count)}
            </span>
          </dd>
        </div>
        <div
          :if={@section.stops == :timepoints and @section.omitted_stop_count > 0}
          class="flex flex-wrap gap-x-6"
        >
          <dt class="w-44 shrink-0"></dt>
          <dd id={"section-#{@section_id}-omitted"} class="text-base-content/70">
            {@section.omitted_stop_count} stops not shown
          </dd>
        </div>
      </dl>

      <div
        id={"section-#{@section_id}-table-container"}
        class="mt-3 overflow-x-auto rounded-box border border-base-300 bg-base-100"
      >
        <table id={"section-#{@section_id}-table"} class="table">
          <thead>
            <tr>
              <th scope="col" class={[selection_cell_class(), "bg-base-100"]}>
                <label class="flex min-h-11 min-w-11 items-center justify-center">
                  <input
                    type="checkbox"
                    id={"section-#{@section_id}-select-all"}
                    checked={@all_selected?}
                    phx-click="toggle_section"
                    phx-value-section={"section-#{@section_id}"}
                    aria-label="Select every trip in this section"
                    class="checkbox checkbox-sm"
                  />
                </label>
              </th>
              <th
                scope="col"
                class={[start_cell_class(), "bg-base-100 border-r border-base-300 text-right"]}
              >
                <span class="block">Departure</span>
                <span class="block text-xs font-normal">First stop</span>
              </th>
              <th
                :for={column <- @section.columns}
                scope="col"
                class="text-right whitespace-nowrap"
              >
                <span class="block" title={column.stop_name}>{column.stop_name}</span>
                <span class="block text-xs font-normal">{column.stop_code}</span>
              </th>
              <th scope="col" class="whitespace-nowrap">
                <span class="block">Timing</span>
                <span class="block text-xs font-normal">Minutes between stops</span>
              </th>
              <th scope="col" class="text-right">Trip no.</th>
              <th scope="col">Block</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @rows} id={"trip-#{row.trip_id}"} class="group">
              <td class={[selection_cell_class(), "bg-base-100 group-hover:bg-base-200"]}>
                <label class="flex min-h-11 min-w-11 items-center justify-center">
                  <input
                    type="checkbox"
                    id={"trip-select-#{row.trip_id}"}
                    checked={MapSet.member?(@selected_ids, row.id)}
                    phx-click="toggle_trip"
                    phx-value-trip={row.id}
                    aria-label={"Select trip #{row.trip_id}"}
                    class="checkbox checkbox-sm"
                  />
                </label>
              </td>
              <td class={[
                start_cell_class(),
                "border-r border-base-300 bg-base-100 text-right group-hover:bg-base-200"
              ]}>
                <span
                  id={"trip-#{row.trip_id}-start"}
                  class="font-semibold tabular-nums"
                  title={row.start_cell.title}
                >
                  {row.start_cell.text}
                </span>
                <span
                  :if={row.start_cell.marker}
                  class="ml-0.5 font-mono text-xs text-base-content/70"
                >
                  {row.start_cell.marker}
                </span>
              </td>
              <td
                :for={column <- @section.columns}
                class="text-right whitespace-nowrap tabular-nums"
              >
                <.timetable_cell :if={not row.stops_differ?} cell={row_cell(row, column)} />
              </td>
              <td class="whitespace-nowrap">
                <%= cond do %>
                  <% row.custom? -> %>
                    <.status_badge status={:warning} label="Custom times" />
                  <% true -> %>
                    <span>{row.timing}</span>
                <% end %>
                <span :if={row.headsign} class="block text-xs font-normal">
                  To {row.headsign}
                </span>
                <span
                  :if={row.frequency_label}
                  id={"trip-#{row.trip_id}-frequency"}
                  class="block text-xs text-base-content/70"
                >
                  {row.frequency_label}
                </span>
                <span
                  :if={row.stops_differ?}
                  id={"trip-#{row.trip_id}-stops-differ"}
                  class="block text-xs text-base-content/70"
                >
                  Stops differ from this pattern
                </span>
              </td>
              <td class="text-right font-mono whitespace-nowrap">
                {row.trip_short_name || row.trip_id}
              </td>
              <td class="whitespace-nowrap">{row.block_id || "—"}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
    """
  end

  @doc "Renders one formatted timetable cell with its day marker."
  attr :cell, :map, required: true

  def timetable_cell(assigns) do
    ~H"""
    <span>
      <span class="tabular-nums" title={@cell.title}>{@cell.text}</span>
      <span :if={@cell.marker} class="ml-0.5 font-mono text-xs text-base-content/70">
        {@cell.marker}
      </span>
    </span>
    """
  end

  # --- helpers ---------------------------------------------------------------

  defp calendar_options(calendars) do
    Enum.map(calendars, fn calendar ->
      {calendar_option_label(calendar), calendar.service_id}
    end)
  end

  defp calendar_option_label(calendar) do
    name = calendar.name || calendar.service_id
    kind = if calendar.kind == :dates_only, do: " · Dates only", else: ""
    "#{name} · #{calendar.service_id} · #{calendar.route_trip_count} trips#{kind}"
  end

  defp pattern_options(patterns, filters) do
    direction_patterns = Enum.filter(patterns, &(&1.direction_id == filters.direction_id))
    [{"All patterns", "all"} | Enum.map(direction_patterns, &{&1.name, &1.id})]
  end

  defp direction_options(direction_labels) do
    for direction_id <- [0, 1], do: {direction_labels[direction_id], to_string(direction_id)}
  end

  defp route_label(route), do: route.route_short_name || route.route_id

  defp hour_label(hour), do: hour |> Integer.to_string() |> String.pad_leading(2, "0")

  defp hour_count_label(0, _approximate?), do: "0"
  defp hour_count_label(count, true), do: "≈#{count}"
  defp hour_count_label(count, _approximate?), do: Integer.to_string(count)

  defp no_trips_title(%{pattern_name: nil} = assigns),
    do: "No trips on #{assigns.calendar_label} going #{assigns.direction_label}"

  defp no_trips_title(assigns), do: "No trips on this pattern for #{assigns.calendar_label}"

  defp row_cell(row, column) do
    Map.get(row.cells, column.position) ||
      %{text: "—", marker: nil, title: nil, missing?: true}
  end

  defp band_text(%{kind: :frequency} = band) do
    "#{clock(band.first_secs)}–#{clock(band.last_secs)} · every #{band.max_headway_minutes} min · " <>
      "frequency service"
  end

  defp band_text(%{kind: :irregular} = band) do
    window =
      if band.first_secs == band.last_secs,
        do: clock(band.first_secs),
        else: "#{clock(band.first_secs)}–#{clock(band.last_secs)}"

    "#{window} · #{band.trip_count} trips"
  end

  defp band_text(band) do
    headway =
      if band.min_headway_minutes == band.max_headway_minutes,
        do: "every #{band.min_headway_minutes} min",
        else: "#{band.min_headway_minutes}–#{band.max_headway_minutes} min"

    "#{clock(band.first_secs)}–#{clock(band.last_secs)} · #{headway} · #{band.trip_count} trips"
  end

  defp timing_line_text(line) do
    segments_text = Enum.map_join(line.segments, " · ", &round_minutes/1)
    between = if line.segments == [], do: "", else: segments_text <> " min · "

    "#{line.name}: " <>
      between <>
      "#{round_minutes(line.total_secs)} min total · " <>
      "#{line.trip_count} trips"
  end

  defp round_minutes(seconds), do: round(seconds / 60)

  defp custom_trips_label(1), do: "custom-time trip"
  defp custom_trips_label(_count), do: "custom-time trips"

  defp incomplete_times_note(1), do: "1 trip without complete times is not counted."

  defp incomplete_times_note(count),
    do: "#{count} trips without complete times are not counted."

  defp clock(seconds),
    do: seconds |> GtfsTime.format() |> String.split(":") |> Enum.take(2) |> Enum.join(":")

  defp typicality_class(1), do: "badge-success"
  defp typicality_class(5), do: "badge-success"
  defp typicality_class(3), do: "badge-warning"
  defp typicality_class(4), do: "badge-warning"
  defp typicality_class(_), do: "badge-ghost"
end
