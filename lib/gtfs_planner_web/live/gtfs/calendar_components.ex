defmodule GtfsPlannerWeb.Gtfs.CalendarComponents do
  @moduledoc """
  Presentation pieces shared by the calendar list and the calendar editor.

  Every value here comes from the domain: `Gtfs.Calendars` derived the periods,
  breaks, holidays, extra days and month cells from the native rows, so these
  functions only choose wording, symbols and structure. No date logic lives in a
  template, and the preview therefore cannot disagree with the stored schedule.

  The symbols carry text as well: each month cell exposes its exact accessible
  date label plus a visually hidden state word, and the legend names all four
  states, so a reader who cannot see the symbol still learns the same fact.
  """

  use GtfsPlannerWeb, :html

  @symbols %{service: "●", removed: "×", added: "+", none: "–"}
  @state_words %{
    service: "Regular service",
    removed: "Service removed",
    added: "Service added",
    none: "No service scheduled"
  }
  @exception_words %{added: "Service added", removed: "Service removed"}
  @date_format "%b %-d, %Y"
  @month_day_format "%a, %b %-d, %Y"

  @doc "Formats one civil date for calendar surfaces."
  def format_date(%Date{} = date), do: Elixir.Calendar.strftime(date, @date_format)

  @doc """
  Renders the derived service periods, breaks, holidays and extra dates.

  The timeline is proportional to civil days, so a long schedule is drawn whole
  instead of being clipped to a fixed span. Break rows offer `remove_break` with
  the exact removed dates; every other row is informational.
  """
  attr :id, :string, required: true
  attr :periods, :map, required: true
  attr :exceptions, :list, default: []
  attr :timeline_label, :string, required: true
  attr :editable, :boolean, default: false

  def periods_section(assigns) do
    assigns =
      assigns
      |> assign(:segments, timeline_segments(assigns.periods, assigns.exceptions))
      |> assign(:has_weekly, assigns.periods.periods != [] or assigns.periods.breaks != [])
      |> assign(:other_days_off, other_days_off(assigns.periods))

    ~H"""
    <div id={@id}>
      <div
        :if={@has_weekly and @segments != []}
        id={"#{@id}-timeline"}
        role="img"
        aria-label={@timeline_label}
        class="flex h-4 w-full gap-px overflow-hidden rounded-sm"
      >
        <span
          :for={segment <- @segments}
          class={[
            "h-4",
            if(segment.kind == :break, do: "bg-warning", else: "bg-primary")
          ]}
          style={"flex: #{segment.days}"}
          title={segment.title}
        >
        </span>
      </div>

      <div :if={@has_weekly and @segments != []} class="mt-3 space-y-2">
        <div
          :for={segment <- @segments}
          id={"#{@id}-segment-#{segment.id}"}
          class="flex flex-wrap items-center justify-between gap-2 text-sm"
        >
          <span>
            <span :if={segment.kind == :break} class="font-semibold">Break · </span>
            <strong>{segment.range_label}</strong>
            <span class="text-base-content/70"> ·  {segment.detail}</span>
          </span>
          <button
            :if={segment.kind == :break and @editable}
            id={"#{@id}-remove-break-#{segment.id}"}
            type="button"
            class="link text-sm"
            phx-click="remove_break"
            phx-value-dates={Enum.map_join(segment.dates, ",", &Date.to_iso8601/1)}
          >
            Remove break
          </button>
        </div>
      </div>

      <p :if={@other_days_off != []} class="mt-3 text-sm">
        <strong>Other days off:</strong>
        {Enum.map_join(@other_days_off, " · ", &format_date/1)}
      </p>

      <p :if={@periods.extra_days != []} class="mt-3 text-sm">
        <strong>Extra service:</strong>
        {Enum.map_join(@periods.extra_days, " · ", &format_date/1)}
        <span class="text-base-content/70"> · outside the regular schedule</span>
      </p>

      <p :if={@periods.holidays != []} class="mt-3 text-sm">
        <strong>Single days off:</strong>
        {Enum.map_join(@periods.holidays, " · ", &format_date/1)}
      </p>
    </div>
    """
  end

  @doc """
  Renders the reviewed warnings that need a decision before a write.

  Each warning names its calendar, its date and why the stored change has no
  effect, so a reader can find the redundant exception in the date list.
  """
  attr :id, :string, required: true
  attr :warnings, :list, required: true
  attr :service_label, :string, default: nil

  def warning_list(assigns) do
    assigns =
      assign(
        assigns,
        :entries,
        Enum.map(assigns.warnings, &warning_entry(&1, assigns.service_label))
      )

    ~H"""
    <div :if={@entries != []} id={@id} class="mt-3">
      <.callout kind="warning" title={warning_title(length(@entries))}>
        <ul class="mt-2 space-y-1 text-sm">
          <li :for={entry <- @entries}>{entry}</li>
        </ul>
      </.callout>
    </div>
    """
  end

  @doc """
  Renders the three-month service preview with its legend and keyboard hints.

  Month cells are buttons so the grid is reachable; the container handles
  ArrowLeft/ArrowRight (and Home) to move the window, and reports the focused
  date in a polite status region.
  """
  attr :id, :string, required: true
  attr :months, :list, required: true
  attr :preview_label, :string, required: true

  def preview_section(assigns) do
    assigns =
      assigns
      |> assign(:symbols, @symbols)
      |> assign(:state_words, @state_words)
      |> assign(:exception_words, @exception_words)

    ~H"""
    <div
      id={@id}
      tabindex="0"
      role="group"
      aria-label={@preview_label}
      phx-keydown="preview_keys"
      class="focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary"
    >
      <div class="grid gap-6 md:grid-cols-3">
        <div :for={month <- @months} id={"#{@id}-#{month.year}-#{month.month}"}>
          <h3 class="text-sm font-semibold">{month.title}</h3>
          <table class="mt-1 w-full text-center text-xs">
            <thead>
              <tr class="text-base-content/70">
                <th :for={day <- ~w(M T W T F S S)} scope="col" class="pb-1 font-medium">
                  <span aria-hidden="true">{day}</span>
                  <span class="sr-only">{weekday_name(day)}</span>
                </th>
              </tr>
            </thead>
            <tbody>
              <tr :for={week <- month.weeks}>
                <td :for={cell <- week} class="p-0.5">
                  <span
                    :if={cell}
                    id={"month-cell-#{Date.to_iso8601(cell.date)}"}
                    class={[
                      "flex h-7 w-full items-center justify-center rounded-sm text-xs font-medium",
                      cell_class(cell.state)
                    ]}
                    title={"#{cell.label} · #{Map.fetch!(@symbols, cell.state)}"}
                    aria-label={cell_aria_label(cell)}
                  >
                    <span aria-hidden="true">{cell.day}</span>
                    <span class="sr-only">{Map.fetch!(@state_words, cell.state)}</span>
                    <span
                      :if={cell.exception}
                      class="ml-0.5 text-[10px] font-bold"
                      aria-hidden="true"
                    >
                      {exception_symbol(cell.exception)}
                    </span>
                    <span :if={cell.exception} class="sr-only">
                      {Map.fetch!(@exception_words, cell.exception)} recorded
                    </span>
                  </span>
                  <span :if={is_nil(cell)} aria-hidden="true">&nbsp;</span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>

      <ul id={"#{@id}-legend"} class="mt-4 flex flex-wrap gap-4 text-sm">
        <li :for={{state, symbol} <- legend_order()} class="inline-flex items-center gap-2">
          <span class={[
            "inline-flex h-5 w-5 items-center justify-center rounded-sm",
            cell_class(state)
          ]}>
            <span aria-hidden="true">{symbol}</span>
          </span>
          <span>{Map.fetch!(@state_words, state)}</span>
        </li>
      </ul>
    </div>
    """
  end

  @doc """
  Renders the individual exception dates as removable chips.

  A chip names the date and its type and removes exactly that stored row through
  `remove_date`; the value is the ISO date, never a client-supplied index.
  """
  attr :id, :string, required: true
  attr :entries, :list, required: true
  attr :editable, :boolean, default: false

  def date_chips(assigns) do
    ~H"""
    <ul :if={@entries != []} id={@id} class="mt-2 flex flex-wrap gap-2">
      <li
        :for={entry <- @entries}
        id={"#{@id}-#{entry.date}"}
        class="inline-flex items-center gap-2 rounded-full border border-control-border px-3 py-1 text-sm"
      >
        <span class="font-medium">{format_date(entry.date)}</span>
        <span class="text-base-content/70">
          {if entry.exception_type == 1, do: "Service added", else: "Service removed"}
        </span>
        <button
          :if={@editable}
          id={"#{@id}-remove-#{entry.date}"}
          type="button"
          class="link text-xs"
          phx-click="remove_date"
          phx-value-date={Date.to_iso8601(entry.date)}
        >
          <span aria-hidden="true">Remove</span>
          <span class="sr-only">Remove the service change on {format_date(entry.date)}</span>
        </button>
      </li>
    </ul>
    """
  end

  @doc """
  Renders the used-by callout with links to the existing route details.

  The count and every route ID come from the scoped grouped usage read, so a
  blocked deletion states the real number of trips.
  """
  attr :id, :string, required: true
  attr :usage, :map, required: true
  attr :version_id, :any, required: true

  def usage_strip(assigns) do
    ~H"""
    <div id={@id} class="flex flex-wrap items-center gap-x-4 gap-y-2 text-sm">
      <span>
        <strong>{@usage.trip_count}</strong>
        {if @usage.trip_count == 1, do: "trip uses this calendar", else: "trips use this calendar"}
      </span>
      <ul :if={@usage.routes != []} class="flex flex-wrap gap-2">
        <li :for={route <- @usage.routes} class="text-base-content/70">
          <.link
            id={"#{@id}-route-#{route.route_id}"}
            navigate={"/gtfs/#{@version_id}/routes/#{route.route_id}"}
            class="link link-primary"
          >
            {route.route_id}
          </.link>
          <span>({route.trip_count})</span>
        </li>
      </ul>
      <span :if={@usage.routes == []} class="text-base-content/70">No routes yet</span>
    </div>
    """
  end

  ## Period helpers

  defp timeline_segments(periods, exceptions) do
    break_segments =
      Enum.map(periods.breaks, fn interval ->
        %{
          kind: :break,
          id: "break-#{Date.to_iso8601(interval.first_date)}",
          days: Date.diff(interval.last_date, interval.first_date) + 1,
          range_label: range_label(interval.first_date, interval.last_date),
          detail: "#{interval.service_days} service days removed",
          title: "#{range_label(interval.first_date, interval.last_date)} · break",
          dates: nil,
          first_date: interval.first_date
        }
      end)

    period_segments =
      Enum.map(periods.periods, fn interval ->
        %{
          kind: :period,
          id: "period-#{Date.to_iso8601(interval.first_date)}",
          days: Date.diff(interval.last_date, interval.first_date) + 1,
          range_label: range_label(interval.first_date, interval.last_date),
          detail: "regular service",
          title: "#{range_label(interval.first_date, interval.last_date)} · regular service",
          dates: nil,
          first_date: interval.first_date
        }
      end)

    # Break rows carry the exact stored removals in their interval, which is what
    # the restore command removes; a break interval has no dates list of its own.
    segments =
      (break_segments ++ period_segments)
      |> Enum.sort_by(&{&1.first_date, &1.kind == :break})

    Enum.map(segments, fn segment ->
      if segment.kind == :break do
        Map.put(segment, :dates, stored_removals(periods, exceptions, segment.first_date))
      else
        segment
      end
    end)
  end

  # A single day off appears in both `holidays` and `removed_days`, so the longer
  # list subtracts the short runs it would otherwise repeat.
  defp other_days_off(periods) do
    holidays = MapSet.new(periods.holidays)

    Enum.reject(periods.removed_days, &MapSet.member?(holidays, &1))
  end

  defp stored_removals(periods, exceptions, first_date) do
    case Enum.find(periods.breaks, &(&1.first_date == first_date)) do
      nil -> []
      %{first_date: first, last_date: last} -> removals_between(exceptions, first, last)
    end
  end

  defp removals_between(exceptions, first, last) do
    exceptions
    |> Enum.filter(&(&1.exception_type == 2))
    |> Enum.map(& &1.date)
    |> Enum.filter(&(Date.compare(&1, first) != :lt and Date.compare(&1, last) != :gt))
    |> Enum.sort(Date)
  end

  defp range_label(date, date), do: format_date(date)

  defp range_label(first, last), do: "#{format_date(first)} – #{format_date(last)}"

  ## Warning helpers

  defp warning_title(1), do: "1 service warning to review"
  defp warning_title(count), do: "#{count} service warnings to review"

  defp warning_entry(%{reason: :outside_range} = warning, _label) do
    "#{format_date(warning.date)} is outside the regular date range; it is stored as an explicit change."
  end

  defp warning_entry(%{reason: :redundant_addition} = warning, _label) do
    "#{format_date(warning.date)} is already a regular service day, so the addition has no effect."
  end

  defp warning_entry(%{reason: :removal_on_nonservice_day} = warning, _label) do
    "#{format_date(warning.date)} had no service, so the removal has no effect."
  end

  defp warning_entry(%{reason: :coverage_gap} = warning, _label) do
    "No service between #{format_date(warning.first_date)} and #{format_date(warning.last_date)}."
  end

  defp warning_entry(%{reason: :ends_soon} = warning, _label) do
    "Ends in #{warning.days_remaining} days, on #{format_date(warning.last_date)}."
  end

  defp warning_entry(%{reason: :ended} = warning, _label) do
    "Ended on #{format_date(warning.last_date)}."
  end

  defp warning_entry(%{reason: :no_service}, label) do
    "No service days#{if label, do: " on #{label}", else: ""}. Choose regular days or add service dates."
  end

  defp warning_entry(warning, _label), do: inspect(warning.reason)

  ## Preview helpers

  defp cell_class(:service), do: "bg-primary/15 text-base-content"
  defp cell_class(:added), do: "bg-success/25 text-base-content"
  defp cell_class(:removed), do: "bg-error/20 text-base-content line-through"
  defp cell_class(:none), do: "bg-base-200 text-base-content/60"

  defp cell_aria_label(cell) do
    base =
      Elixir.Calendar.strftime(cell.date, @month_day_format) <>
        ": " <> Map.fetch!(@state_words, cell.state)

    case cell.exception do
      nil -> base
      exception -> base <> "; " <> Map.fetch!(@exception_words, exception) <> " recorded"
    end
  end

  defp exception_symbol(:added), do: "+"
  defp exception_symbol(:removed), do: "×"

  defp legend_order, do: [service: "●", removed: "×", added: "+", none: "–"]

  defp weekday_name("M"), do: "Monday"
  defp weekday_name("T"), do: "Tuesday"
  defp weekday_name("W"), do: "Wednesday"
  defp weekday_name("F"), do: "Friday"
  defp weekday_name("S"), do: "Saturday"
  defp weekday_name(_other), do: "Sunday"
end
