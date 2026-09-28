defmodule GtfsPlannerWeb.Gtfs.BlocksComponents do
  @moduledoc """
  Function components for Operations › Blocks.

  The page's day-type scope, whole-day summary, the Service dates, Checks and
  Peak drawers and the page states live here so
  `GtfsPlannerWeb.Gtfs.BlocksLive` stays a small state owner. Every component
  takes the pieces of the loaded day it prints, never the whole day, so
  `render/1` in the LiveView never reaches into the server-only day assign
  (CR-6). Later steps render the timeline, the pool and the trip, gap and block
  drawers inside the same page.

  Times are printed from parsed seconds with `clock/1`; nothing here re-reads a
  clock string from the database (CR-3).
  """

  use GtfsPlannerWeb, :html

  @doc """
  Renders the day-type scope: the day-type select, the route filter, “Problems
  only”, the Service dates button and the Checks button.

  The day select posts through its own form (`select_day`) so a day change is
  never mistaken for a route filter; the route and status controls post through
  the `filter` form. The scope describes the whole day type, so neither control
  changes the whole-day counts.
  """
  attr :day_types, :list, required: true
  attr :day_type, :map, required: true
  attr :routes, :map, required: true
  attr :state, :map, required: true

  def scope_header(assigns) do
    assigns = assign(assigns, :route_options, route_options(assigns.routes))

    ~H"""
    <div id="blocks-scope" class="flex flex-wrap items-end gap-x-6 gap-y-3">
      <form id="blocks-day-form" phx-change="select_day" class="min-w-0 max-w-full">
        <.day_select id="blocks-day" day_types={@day_types} selected={@day_type.key} />
      </form>

      <form
        id="blocks-filter-form"
        phx-change="filter"
        class="flex flex-wrap items-end gap-x-6 gap-y-3"
      >
        <.input
          type="select"
          id="blocks-route"
          name="route"
          label="Route"
          prompt="All routes"
          value={@state.route || ""}
          options={@route_options}
          class="select select-lg w-full sm:w-48"
        />
        <label class="label min-h-11 cursor-pointer gap-2">
          <input
            type="checkbox"
            id="blocks-problems-only"
            name="status"
            value="problems"
            checked={@state.status == :problems}
            class="checkbox"
          />
          <span class="label-text">Problems only</span>
        </label>
      </form>

      <div class="ml-auto">
        <button
          id="blocks-service-dates"
          type="button"
          phx-click="open_drawer"
          phx-value-key="service_dates"
          class="link link-primary min-h-11"
        >
          Service dates
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Renders the day-type select.

  Every day type prints as “<label> · <date_count> dates”; day types with one
  date sit in an optgroup labelled “Special days”. Passing a `nil` selection
  selects nothing, which is the unknown-day recovery state.
  """
  attr :id, :string, required: true
  attr :day_types, :list, required: true
  attr :selected, :string, default: nil

  def day_select(assigns) do
    assigns = assign(assigns, :options, day_type_options(assigns.day_types))

    ~H"""
    <.input
      type="select"
      id={@id}
      name="day"
      label="Day type"
      value={@selected}
      options={@options}
      class="select select-lg w-full sm:w-80"
    />
    """
  end

  @doc """
  Renders the whole-day count strip and the day-type note.

  Every figure is the whole day type's, so the route filter, “Problems only”
  and any paging leave them unchanged. Each item is a button: the unassigned
  figure opens the unassigned panel and the problems and peak figures open
  their drawer. The items whose key names no target (`blocks`, `notices`) are
  ignored by the handler.
  """
  attr :day_type, :map, required: true
  attr :counts, :map, required: true
  attr :peak, :map, required: true
  attr :open_drawer, :atom, default: nil

  def summary_strip(assigns) do
    assigns =
      assigns
      |> assign(:items, count_items(assigns.counts, assigns.peak))
      |> assign(:selected_key, assigns.open_drawer && Atom.to_string(assigns.open_drawer))

    ~H"""
    <section
      id="blocks-summary"
      aria-label="Whole day type summary"
      class="flex flex-wrap items-center gap-x-6 gap-y-2 border-y border-base-300 py-2"
    >
      <.count_strip
        id="blocks-summary-counts"
        items={@items}
        event="open_drawer"
        selected_key={@selected_key}
      />
      <span id="blocks-peak-detail" class="text-sm text-base-content/70">
        {peak_detail(@peak)}
      </span>
      <span id="blocks-summary-note" class="ml-auto text-sm text-base-content/70">
        Whole day type · {date_count_label(@day_type.date_count)}
      </span>
    </section>
    """
  end

  @doc """
  Renders the page's data states: the first-paint skeleton, the two calendar
  and trip empties, and the unknown-day recovery.

  The skeleton mirrors the header, the count strip and eight rows. The recovery
  state keeps the day select but applies no day type: a restored selection
  loads the day the user chose (INV-6).
  """
  attr :kind, :atom, required: true, values: [:loading, :no_dates, :empty, :unknown]
  attr :day_types, :list, default: []
  attr :version_id, :string, default: nil

  def page_state(%{kind: :loading} = assigns) do
    ~H"""
    <.skeleton id="blocks-skeleton" label="Loading blocks…">
      <div class="space-y-3">
        <div class="h-6 w-36 bg-base-300"></div>
        <div class="h-12 w-full bg-base-300"></div>
        <div :for={_row <- 1..8} class="h-9 w-full bg-base-300"></div>
      </div>
    </.skeleton>
    """
  end

  def page_state(%{kind: :no_dates} = assigns) do
    ~H"""
    <div id="blocks-no-dates">
      <.empty_state title="No calendar in this version has a service date.">
        Add the days a calendar runs, then group the trips on those dates into each
        vehicle's work.
        <:action>
          <.link
            id="blocks-no-dates-link"
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

  def page_state(%{kind: :empty} = assigns) do
    ~H"""
    <div id="blocks-empty">
      <.empty_state title="Blocks need trips with calendars">
        Add scheduled trips and the days they run. Then group them into each vehicle's work.
        <:action>
          <.link
            id="blocks-empty-link"
            navigate={~p"/gtfs/#{@version_id}/routes"}
            class="btn btn-primary"
          >
            Open Routes
          </.link>
        </:action>
      </.empty_state>
    </div>
    """
  end

  def page_state(%{kind: :unknown} = assigns) do
    ~H"""
    <div id="blocks-unknown-day">
      <.empty_state title="Choose a day type">
        This day type no longer matches the calendars. No day type is applied for you and
        nothing has changed.
        <:action>
          <form id="blocks-unknown-day-form" phx-submit="select_day" class="mx-auto max-w-sm">
            <.day_select id="blocks-day" day_types={@day_types} />
            <button type="submit" class="btn btn-primary mt-3">Show selected day</button>
          </form>
        </:action>
      </.empty_state>
    </div>
    """
  end

  @doc """
  Renders the Service dates drawer: the day type's date count, its range and
  every date grouped by month.
  """
  attr :open, :boolean, required: true
  attr :day_type, :map, required: true

  def service_dates_drawer(assigns) do
    assigns = assign(assigns, :months, month_groups(assigns.day_type.dates))

    ~H"""
    <.drawer
      id="service-dates-drawer"
      open={@open}
      title="Service dates"
      return_focus_id="blocks-service-dates"
    >
      <h3 class="text-sm font-semibold">
        {@day_type.label} · {date_count_label(@day_type.date_count)}
      </h3>
      <p class="mt-1 text-sm text-base-content/70">{range_text(@day_type.dates)}</p>

      <div :for={{label, dates} <- @months} class="mt-4" data-role="service-dates-month">
        <h4 class="text-sm font-semibold">{label}</h4>
        <ul class="mt-1 space-y-0.5 text-sm">
          <li :for={date <- dates}>{format_date(date)}</li>
        </ul>
      </div>
    </.drawer>
    """
  end

  @doc """
  Renders the Checks drawer: the day type's problems first, then its notices.

  Each finding names its block, its trips and what the finding is; “Open block”
  and “Open trip” carry the reader to the drawer for that block or trip. A
  finding whose trip is outside the loaded day prints the stored ID without an
  action, because the day-type view does not hold the trips to open.
  """
  attr :open, :boolean, required: true
  attr :findings, :list, required: true
  attr :trip_labels, :map, required: true

  def checks_drawer(assigns) do
    problems = Enum.filter(assigns.findings, &(&1.severity in [:error, :warning]))
    notices = Enum.filter(assigns.findings, &(&1.severity == :notice))

    assigns = assign(assigns, problems: problems, notices: notices)

    ~H"""
    <.drawer
      id="checks-drawer"
      open={@open}
      title="Checks and notices"
      return_focus_id="blocks-review-checks"
    >
      <h3 class="text-sm font-semibold">Problems · {length(@problems)}</h3>
      <div id="checks-drawer-problems" class="mt-2 space-y-4">
        <.finding :for={finding <- @problems} finding={finding} trip_labels={@trip_labels} />
        <p :if={@problems == []} class="text-sm text-base-content/70">None in this day type.</p>
      </div>

      <h3 class="mt-6 border-t border-base-300 pt-4 text-sm font-semibold">
        Notices · {length(@notices)}
      </h3>
      <div id="checks-drawer-notices" class="mt-2 space-y-4">
        <.finding :for={finding <- @notices} finding={finding} trip_labels={@trip_labels} />
        <p :if={@notices == []} class="text-sm text-base-content/70">None in this day type.</p>
      </div>
    </.drawer>
    """
  end

  attr :finding, :map, required: true
  attr :trip_labels, :map, required: true

  defp finding(assigns) do
    ~H"""
    <div
      data-role="blocks-finding"
      data-code={@finding.code}
      data-severity={@finding.severity}
      class="border-l-4 border-base-300 pl-3"
    >
      <div class="flex flex-wrap items-center gap-2">
        <.status_badge status={severity_status(@finding.severity)} label={code_label(@finding.code)} />
        <button
          :if={@finding.block_id}
          data-role="blocks-finding-block"
          type="button"
          phx-click="open_block"
          phx-value-block={@finding.block_id}
          class="link link-primary min-h-11"
        >
          Open block {@finding.block_id}
        </button>
      </div>

      <p class="mt-1 text-sm">{finding_detail(@finding)}</p>

      <p :if={@finding.trip_ids != []} class="mt-1 text-sm">
        <span
          :for={uuid <- @finding.trip_ids}
          class="mr-3 inline-block"
          data-role="blocks-finding-trip"
        >
          <%= if label = @trip_labels[uuid] do %>
            <button
              type="button"
              phx-click="open_trip"
              phx-value-trip={label}
              class="link link-primary min-h-11"
            >
              Open trip {label}
            </button>
          <% else %>
            <span class="text-base-content/70">{uuid}</span>
          <% end %>
        </span>
      </p>
    </div>
    """
  end

  @doc """
  Renders the Peak drawer: the definition, a bar per 15-minute bin, the same
  bins as a table and the count of trips the figure leaves out.
  """
  attr :open, :boolean, required: true
  attr :peak, :map, required: true
  attr :bins, :list, required: true
  attr :axis, :map, default: nil

  def peak_drawer(assigns) do
    max = assigns.bins |> Enum.map(& &1.count) |> Enum.max(fn -> 0 end)

    assigns =
      assigns
      |> assign(:max, max)
      |> assign(:bars, Enum.map(assigns.bins, &Map.put(&1, :height, bar_height(&1.count, max))))

    ~H"""
    <.drawer
      id="peak-drawer"
      open={@open}
      title="Peak vehicles out"
      return_focus_id="blocks-summary-counts-item-peak"
    >
      <p class="text-sm font-semibold">{peak_headline(@peak)} · whole day type</p>
      <p class="mt-1 text-sm text-base-content/70">
        Blocks in progress, including time between trips. Excludes unassigned and frequency
        trips.
      </p>

      <div :if={@bins != []} class="mt-4">
        <div
          id="peak-chart"
          role="img"
          aria-label={peak_chart_label(@peak, @bins, @axis)}
          class="flex h-28 items-end gap-px border-b border-base-300"
        >
          <i
            :for={bar <- @bars}
            id={"peak-bin-bar-#{bar.start_secs}"}
            style={"height: #{bar.height}%"}
            class="min-w-0 flex-1 bg-base-content/40"
            title={"#{clock(bar.start_secs)} · #{bar.count}"}
          >
          </i>
        </div>
        <div class="mt-1 flex justify-between text-xs text-base-content/70">
          <span>{clock(List.first(@bins).start_secs)}</span>
          <span>{clock(List.last(@bins).start_secs + 900)}</span>
        </div>

        <table id="peak-bins" class="table table-sm mt-4">
          <caption class="sr-only">Vehicles out per 15-minute bin</caption>
          <thead>
            <tr>
              <th scope="col">From</th>
              <th scope="col" class="text-right">Vehicles out</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={bar <- @bars} id={"peak-bin-#{bar.start_secs}"} data-role="peak-bin">
              <td>{clock(bar.start_secs)}</td>
              <td class="text-right tabular-nums">{bar.count}</td>
            </tr>
          </tbody>
        </table>
      </div>

      <p :if={@bins == []} id="peak-bins-empty" class="mt-4 text-sm text-base-content/70">
        No block is timed in this day type, so there is no peak to show.
      </p>

      <p id="peak-exclusions" class="mt-4 text-sm text-base-content/70">
        Excludes {count_label(@peak.excluded_unassigned, "unassigned trip", "unassigned trips")} and {count_label(
          @peak.excluded_frequency,
          "frequency trip",
          "frequency trips"
        )}. Trips without
        usable timing are also left out, and this is not a fleet requirement.
      </p>
    </.drawer>
    """
  end

  @doc """
  Prints parsed seconds as `HH:MM`, with ` +1d`/` +2d` after midnight (Copy).
  """
  def clock(nil), do: "—"

  def clock(secs) when is_integer(secs) do
    days = div(secs, 86_400)
    within = rem(secs, 86_400)

    clock =
      String.pad_leading(Integer.to_string(div(within, 3600)), 2, "0") <>
        ":" <> String.pad_leading(Integer.to_string(div(rem(within, 3600), 60)), 2, "0")

    case days do
      0 -> clock
      days -> clock <> " +#{days}d"
    end
  end

  defp route_options(routes) do
    routes
    |> Enum.map(fn {route_id, route} -> {route_option_label(route_id, route), route_id} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp route_option_label(route_id, route) do
    route.short_name || route.long_name || route_id
  end

  defp day_type_options(day_types) do
    {special, regular} = Enum.split_with(day_types, & &1.special?)

    regular = Enum.map(regular, &{day_type_option_label(&1), &1.key})

    case special do
      [] ->
        regular

      special ->
        regular ++ [{"Special days", Enum.map(special, &{day_type_option_label(&1), &1.key})}]
    end
  end

  defp day_type_option_label(day_type) do
    "#{day_type.label} · #{date_count_label(day_type.date_count)}"
  end

  defp date_count_label(1), do: "1 date"
  defp date_count_label(count), do: "#{count} dates"

  defp count_items(counts, peak) do
    [
      %{key: "blocks", label: "Blocks", count: counts.blocks, tone: :neutral},
      %{key: "unassigned", label: "Unassigned trips", count: counts.unassigned, tone: :info},
      %{key: "problems", label: "Problems", count: counts.problems, tone: :error},
      %{key: "notices", label: "Notices", count: counts.notices, tone: :warning},
      %{key: "peak", label: "Peak vehicles out", count: peak.count, tone: :neutral}
    ]
  end

  defp peak_detail(%{at_secs: nil}), do: "No block is timed"

  defp peak_detail(peak) do
    "Peak at #{clock(peak.at_secs)} · excludes " <>
      count_label(peak.excluded_unassigned, "unassigned trip", "unassigned trips") <>
      " and " <> count_label(peak.excluded_frequency, "frequency trip", "frequency trips")
  end

  defp count_label(1, singular, _plural), do: "1 #{singular}"
  defp count_label(count, _singular, plural), do: "#{count} #{plural}"

  defp peak_headline(%{at_secs: nil} = peak), do: "#{peak.count} vehicles out"

  defp peak_headline(peak), do: "#{peak.count} at #{clock(peak.at_secs)}"

  defp peak_chart_label(peak, bins, axis) do
    "Vehicles out per 15-minute bin, #{peak.count} at the peak. " <>
      "Chart covers #{clock(List.first(bins).start_secs)} to " <>
      "#{clock(List.last(bins).start_secs + 900)} of the day type" <>
      if(axis,
        do: " (whole day type #{clock(axis.start_secs)}–#{clock(axis.end_secs)})",
        else: ""
      )
  end

  defp bar_height(_count, 0), do: 0
  defp bar_height(count, max), do: round(count / max * 100)

  defp month_groups(dates) do
    dates
    |> Enum.group_by(&{&1.year, &1.month})
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {{year, month}, dates} ->
      {Calendar.strftime(Date.new!(year, month, 1), "%B %Y"), sort_dates(dates)}
    end)
  end

  # `Date` structs compare by field name order (day before month and year), so
  # chronological order needs the Gregorian day count.
  defp sort_dates(dates), do: Enum.sort_by(dates, &Date.to_gregorian_days/1)

  defp range_text([]), do: "No dates"

  defp range_text(dates) do
    {first, last} = Enum.min_max_by(dates, &Date.to_gregorian_days/1)
    "#{format_date(first)} – #{format_date(last)}"
  end

  defp format_date(date), do: Calendar.strftime(date, "%d %b %Y")

  defp severity_status(:error), do: "error"
  defp severity_status(:warning), do: "warning"
  defp severity_status(:notice), do: "info"

  defp code_label(:overlap), do: "Overlap"
  defp code_label(:short_layover), do: "Short layover"
  defp code_label(:in_seat_stale), do: "In-seat row"
  defp code_label(:in_seat_unconfirmed), do: "Can't confirm"
  defp code_label(:repositions), do: "Empty move"
  defp code_label(:frequency_trip), do: "Frequency"
  defp code_label(:unplottable), do: "Time missing"

  defp finding_detail(%{code: :overlap, detail: %{overlap_secs: secs}}) do
    "Two trips in this block overlap by #{minutes(secs)}."
  end

  defp finding_detail(%{code: :short_layover, detail: %{gap_secs: secs}}) do
    "Only #{minutes(secs)} between two trips in this block."
  end

  defp finding_detail(%{code: :repositions, detail: detail}) do
    "The vehicle moves empty: #{minutes(detail.gap_secs)} available, " <>
      case detail.meters do
        nil -> "driving time unknown."
        meters -> "#{meters} m between the stops."
      end
  end

  defp finding_detail(%{code: :frequency_trip, detail: %{headway_secs: secs}}) do
    "Repeats every #{div(secs, 60)} min; individual vehicle work can't be checked here."
  end

  defp finding_detail(%{code: :unplottable}) do
    "An endpoint time is missing, so this trip can't be plotted or assigned."
  end

  defp finding_detail(%{code: code, detail: %{reason: reason}})
       when code in [:in_seat_stale, :in_seat_unconfirmed] do
    in_seat_reason(reason) <> "."
  end

  defp finding_detail(_finding), do: "Review this finding."

  defp in_seat_reason(:trip_missing), do: "A trip in this record isn't in this version"

  defp in_seat_reason(:no_shared_date), do: "The trips share no date"

  defp in_seat_reason(:no_block),
    do: "No block · Google ignores this record; riders see stay-on-board only from blocks"

  defp in_seat_reason(:stops_changed),
    do: "Stops changed · the record's stops are no longer these trips' end stops"

  defp in_seat_reason({:not_next, failures}) do
    "Not next on this vehicle on " <>
      Enum.map_join(failures, "; ", &"#{&1.label}, #{&1.date_count} dates")
  end

  defp in_seat_reason(:next_service_day),
    do: "Can't be confirmed in this view · next-service-day continuation"

  defp in_seat_reason(:untimed),
    do: "Can't be confirmed in this view · missing or repeating times"

  defp in_seat_reason(:coupling), do: "Can't be confirmed in this view · coupling record"

  defp in_seat_reason(reason) when is_atom(reason),
    do: "Can't be confirmed in this view · #{reason}"

  defp minutes(secs) when is_integer(secs), do: "#{div(secs, 60)} min"
end
