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

  alias GtfsPlanner.Gtfs.Blocking.Checks

  @tick_label_target 12
  @seasonal_threshold 14
  @year_only_months 36

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
            <span class="text-base-content/70">{" · "}{segment.detail}</span>
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

  The focusable preview container handles ArrowLeft/ArrowRight and Home to
  move the month window. Individual cells expose their civil date and service state.
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
                <th
                  :for={day <- ~w(Monday Tuesday Wednesday Thursday Friday Saturday Sunday)}
                  scope="col"
                  class="pb-1 font-medium"
                >
                  <span aria-hidden="true">{String.first(day)}</span>
                  <span class="sr-only">{day}</span>
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
  Renders the shared date selection for a reviewed date change.

  The mode, its date inputs and the removable chips are the same control on every
  surface, so a normalized selection means the same thing in the drawer and in the
  editor. `errors` maps a field name to its message and each message is attached
  to the input it belongs to, so a reversed range or an unreadable date is
  announced with its own control.
  """
  attr :id, :string, required: true
  attr :form, :any, required: true
  attr :mode, :string, required: true
  attr :dates, :list, required: true
  attr :errors, :map, default: %{}
  attr :mode_options, :list, required: true

  def date_selection(assigns) do
    ~H"""
    <div id={@id} class="space-y-3">
      <.input
        id={"#{@id}-mode"}
        field={@form[:mode]}
        type="select"
        label="Dates to change"
        options={@mode_options}
        errors={errors_for(@errors, "mode")}
      />

      <div :if={@mode == "single"}>
        <.input
          id={"#{@id}-date"}
          field={@form[:date]}
          type="date"
          label="Date"
          errors={errors_for(@errors, "date")}
        />
      </div>

      <div :if={@mode == "range"} class="grid gap-3 sm:grid-cols-2">
        <.input
          id={"#{@id}-date-from"}
          field={@form[:date_from]}
          type="date"
          label="First date"
          errors={errors_for(@errors, "date_from")}
        />
        <.input
          id={"#{@id}-date-to"}
          field={@form[:date_to]}
          type="date"
          label="Last date"
          errors={errors_for(@errors, "date_to")}
        />
      </div>

      <div :if={@mode == "several"} class="space-y-2">
        <div class="flex flex-wrap items-end gap-3">
          <div class="w-48">
            <.input
              id={"#{@id}-date-add"}
              field={@form[:date_add]}
              type="date"
              label="Add dates"
              errors={errors_for(@errors, "date_add")}
            />
          </div>
          <button id={"#{@id}-add"} type="submit" class="btn btn-sm btn-outline min-h-11">
            Add date
          </button>
        </div>

        <ul
          :if={@dates != []}
          id={"#{@id}-chips"}
          class="flex flex-wrap gap-2"
          aria-label="Selected dates"
        >
          <li
            :for={date <- @dates}
            id={"#{@id}-chip-#{Date.to_iso8601(date)}"}
            class="inline-flex items-center gap-2 rounded-full border border-control-border px-3 py-1 text-sm"
          >
            <span class="font-medium">{format_date(date)}</span>
            <button
              id={"#{@id}-chip-remove-#{Date.to_iso8601(date)}"}
              type="button"
              class="link text-xs"
              phx-click="date_change_remove_date"
              phx-value-date={Date.to_iso8601(date)}
            >
              <span aria-hidden="true">Remove</span>
              <span class="sr-only">Remove {format_date(date)} from the selected dates</span>
            </button>
          </li>
        </ul>

        <p :if={@dates == []} class="text-sm text-base-content/70">Add each date to change.</p>
      </div>
    </div>
    """
  end

  defp errors_for(errors, field) do
    case Map.get(errors, field) do
      nil -> []
      message -> [message]
    end
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

  ## Coverage presentation

  @doc """
  Renders the shared coverage axis under the Service dates column.

  Every tick is a month boundary with a fractional `position`, so this function only
  formats percentages; the geometry stays in `GtfsPlannerWeb.Gtfs.CalendarCoverage`.
  Labels thin out by available width through CSS container breakpoints: a short axis
  keeps all of them, a long one always shows January and the window start and then
  every fourth, second and finally every month as the column widens. The axis is a
  scale, not a second copy of the data, so it exposes one description instead of
  reading thirteen month names.
  """
  attr :id, :string, default: "calendar-coverage-axis"
  attr :axis, :map, required: true

  def coverage_axis(assigns) do
    assigns =
      assigns
      |> assign(:ticks, tick_rows(assigns.axis.ticks))
      |> assign(:label, axis_label(assigns.axis))

    ~H"""
    <div id={@id} class="calendar-coverage-axis" role="img" aria-label={@label}>
      <span
        :for={band <- @axis.gap_bands}
        class={["calendar-coverage-band", "calendar-coverage-band--axis"]}
        style={band_style(band)}
      >
      </span>
      <span
        :for={tick <- @ticks}
        class="calendar-coverage-tick"
        data-density={tick.density}
        style={"left: #{pct(tick.position)}"}
      >
        <span :if={tick.lined?} class="calendar-coverage-tick-line"></span>
        <span
          :if={tick.labelled?}
          class={["calendar-coverage-tick-label", tick.year? && "font-semibold"]}
        >
          {tick_label(tick)}
        </span>
      </span>
      <span
        :if={@axis.today_position}
        class="calendar-coverage-today"
        style={"left: #{pct(@axis.today_position)}"}
      >
        Today
      </span>
    </div>
    """
  end

  @doc """
  Renders one row's coverage bar with its exact-date caption as one keyboard control.

  `coverage` is the row's projection from `CalendarCoverage.project/2` and `axis`
  carries the scale every row shares, so the bar is drawn on the same axis as the
  header. The whole cell is the control: the lane is decoration and stays
  `aria-hidden`, while the caption below it states the exact first and last date and
  the break, day-off and added-date counts in text, so the bar is never the only
  carrier of a fact and the control always has a readable name. Activating it (click,
  Enter or Space) opens the exact inspector through `open_coverage_details`, which
  carries the row's exact service ID as `phx-value-service-id`;
  `coverage_control_id/1` names the control so a closed inspector returns focus to it.
  """
  attr :row, :map, required: true
  attr :coverage, :map, required: true
  attr :axis, :map, required: true

  def coverage_bar(assigns) do
    ~H"""
    <button
      type="button"
      id={coverage_control_id(@row.service_id)}
      data-calendar-coverage={@row.service_id}
      phx-click="open_coverage_details"
      phx-value-service-id={@row.service_id}
      aria-haspopup="dialog"
      class="calendar-coverage-trigger"
    >
      <span class="sr-only">{@row.name || @row.service_id} coverage details</span>
      <span class="calendar-coverage-lane" aria-hidden="true">
        <span
          :if={@axis.today_position}
          class="calendar-coverage-past"
          style={"width: #{pct(@axis.today_position)}"}
        >
        </span>
        <span
          :for={band <- @axis.gap_bands}
          class="calendar-coverage-band"
          style={band_style(band)}
        >
        </span>
        <span
          :for={mark <- @coverage.marks}
          class={["calendar-coverage-mark", mark_class(mark)]}
          style={mark_style(mark)}
          title={mark_title(mark)}
        >
        </span>
        <span
          :if={@axis.today_position}
          class="calendar-coverage-today-line"
          style={"left: #{pct(@axis.today_position)}"}
        >
        </span>
        <span
          :if={@coverage.offscreen}
          class={["calendar-coverage-outside", outside_class(@coverage.offscreen)]}
        >
          <.icon name={outside_icon(@coverage.offscreen)} class="size-3.5" />
          {outside_label(@coverage.offscreen)}
        </span>
      </span>
      <span class="calendar-coverage-caption">{coverage_caption(@row)}</span>
    </button>
    """
  end

  @doc """
  Names one row's coverage control so the inspector can return focus to it.
  """
  def coverage_control_id(service_id),
    do: "calendar-coverage-open-#{URI.encode_www_form(service_id)}"

  @doc """
  Renders the exact service-date inspector for one coverage control.

  Everything here is the loaded read: the derived periods, breaks, days off and added
  dates, the stored exception rows, the grouped route usage and the agency-local next
  service. The coverage bar is a view of the same dates, so a compressed or clipped
  mark never becomes the only statement about a date: dates outside the visible axis are
  counted with their exact span, an approximate mark says so, and the exact periods stay
  proportional to real civil days instead of the drawn range.
  """
  attr :detail, :map, required: true
  attr :version_id, :any, required: true

  def coverage_details(assigns) do
    assigns =
      assigns
      |> assign(:row, assigns.detail.row)
      |> assign(:periods, assigns.detail.row.periods)
      |> assign(:exceptions, assigns.detail.row.exceptions)
      |> assign(:approximate?, Enum.any?(assigns.detail.coverage.marks, & &1.mixed?))
      |> assign(:next_service, next_service(assigns.detail.row, assigns.detail.today))
      |> assign(:empty_dates_text, empty_dates_text(assigns.detail.row))
      |> assign(:outside_lines, outside_lines(assigns.detail))

    ~H"""
    <div id="calendar-coverage-details-content" class="space-y-6">
      <div>
        <p id="calendar-coverage-details-identity">
          <code class="font-mono">{@row.service_id}</code>
          <span class="text-sm text-base-content/70">{" · "}{@detail.regular_days}</span>
        </p>
        <p class="mt-1 text-sm text-base-content/70">
          Exact service dates behind the bar on the list.
        </p>
      </div>

      <section :if={@row.kind == :weekly} id="calendar-coverage-details-periods-section">
        <h3 class="font-semibold">Regular service and changes</h3>
        <p class="mb-2 text-sm text-base-content/70">
          The weekly range, its breaks, the single days off and the added dates.
        </p>
        <.periods_section
          id="calendar-coverage-details-periods"
          periods={@periods}
          exceptions={@exceptions}
          timeline_label={"Service periods with #{length(@periods.breaks)} breaks"}
        />
        <p :if={@periods.periods == [] and @periods.breaks == []} class="text-sm text-base-content/70">
          This calendar has no regular service days.
        </p>
      </section>

      <section id="calendar-coverage-details-dates-section">
        <h3 class="font-semibold">
          {if @row.kind == :weekly, do: "Stored date changes", else: "Service dates"}
        </h3>
        <p :if={@row.kind == :weekly} class="text-sm text-base-content/70">
          Every added and removed date exactly as it is stored, including the ones outside the
          weekly range.
        </p>
        <.date_chips
          id="calendar-coverage-details-dates"
          entries={@exceptions}
        />
        <p :if={@exceptions == []} class="mt-2 text-sm text-base-content/70">
          {@empty_dates_text}
        </p>
      </section>

      <section id="calendar-coverage-details-next-section">
        <h3 class="font-semibold">Next service</h3>
        <p id="calendar-coverage-details-next" class="mt-1">{next_service_label(assigns)}</p>
      </section>

      <section id="calendar-coverage-details-usage-section">
        <h3 class="font-semibold">Used by</h3>
        <div class="mt-1">
          <.usage_strip
            id="calendar-coverage-details-usage"
            usage={%{trip_count: @row.trip_count, routes: @row.routes}}
            version_id={@version_id}
          />
        </div>
      </section>

      <section id="calendar-coverage-details-outside">
        <h3 class="font-semibold">Outside the timeline</h3>
        <ul class="mt-1 space-y-1 text-sm text-base-content/70">
          <li :for={line <- @outside_lines}>{line}</li>
        </ul>
        <p
          :if={@approximate?}
          id="calendar-coverage-details-approximate"
          class="mt-2 text-sm text-base-content/70"
        >
          Some marks in this range are compressed into bins and drawn approximately. Every
          date above is exact.
        </p>
      </section>
    </div>
    """
  end

  @doc """
  Renders the repair state for one identity whose retained dates cannot be read.

  The row keeps its identity, name and usage, and states the reason and the repair
  action instead of drawing a bar: an unreadable range must never read as "no
  service". The invalid clause of the domain read never evaluates the dates, so this
  branch also never routes the identity into the detail read.
  """
  attr :row, :map, required: true
  attr :version_id, :any, required: true

  def coverage_repair(assigns) do
    ~H"""
    <div data-calendar-coverage-repair={@row.service_id} class="calendar-coverage-repair">
      <span class="font-medium text-warning">Range needs repair</span>
      <p class="mt-0.5">
        <code class="font-mono">{@row.service_id}</code>
        {reason_text(@row.coverage_error.reason)}
      </p>
      <.link
        id={"calendar-coverage-repair-#{URI.encode_www_form(@row.service_id)}"}
        navigate={"/gtfs/#{@version_id}/import"}
        class="link link-primary mt-0.5 inline-block"
      >
        Correct the calendar file and import the feed again
      </.link>
    </div>
    """
  end

  @doc """
  Renders the repair callout for every identity the read could not evaluate.

  The callout names each service ID and the one repair action, and states that the
  version asserts no complete gap set while an identity is unreadable (AC-5).
  """
  attr :id, :string, default: "calendar-coverage-invalid"
  attr :invalid, :list, required: true
  attr :version_id, :any, required: true

  def coverage_invalid(assigns) do
    ~H"""
    <div :if={@invalid != []} id={@id} class="mt-4">
      <.callout kind="warning" title={invalid_title(length(@invalid))}>
        These rows stay listed with their names and trip usage. Their dates were never
        evaluated, so this version asserts no complete set of service gaps until the feed
        is imported again.
        <ul class="mt-2 space-y-1">
          <li :for={error <- @invalid}>
            <code class="font-mono">{error.service_id}</code> — {reason_text(error.reason)}
          </li>
        </ul>
        <.link
          id="calendar-coverage-invalid-repair"
          navigate={"/gtfs/#{@version_id}/import"}
          class="link link-primary mt-2 inline-block"
        >
          Correct the calendar file and import the feed again
        </.link>
      </.callout>
    </div>
    """
  end

  @doc """
  Renders the legend for the axis, the bars and the gap bands.

  Every swatch carries its word as text, so the encoding is readable without the
  colours, and the words are the same ones the caption uses.
  """
  attr :id, :string, default: "calendar-coverage-legend"

  def coverage_legend(assigns) do
    ~H"""
    <ul id={@id} class="calendar-coverage-legend" aria-label="Coverage legend">
      <li :for={{kind, word} <- legend_items()} id={@id <> "-" <> kind}>
        <span class={["calendar-coverage-swatch", "calendar-coverage-swatch--#{kind}"]}></span>
        <span>{word}</span>
      </li>
    </ul>
    """
  end

  @doc """
  Describes one row's coverage for the caption under its bar.

  A weekly row states its period, then its breaks, single days off and added dates; a
  specific-dates row states how many dates it runs and their span. An identity whose
  range could not be read has no caption at all, because it has no evaluated dates.
  """
  def coverage_caption(%{coverage_error: %{}}), do: nil
  def coverage_caption(%{active_dates: []}), do: "No service dates"

  def coverage_caption(%{kind: :dates_only} = row) do
    "#{plural(length(row.active_dates), "date")} · #{span_label(row)}"
  end

  def coverage_caption(row) do
    [
      span_label(row),
      plural(length(row.periods.breaks), "break"),
      plural(length(row.periods.holidays), "day off", "days off"),
      plural(length(row.periods.extra_days), "added date")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp span_label(%{first_active_date: date, last_active_date: date}), do: format_date(date)

  defp span_label(row),
    do: "#{format_date(row.first_active_date)} – #{format_date(row.last_active_date)}"

  defp plural(0, _one, _many), do: nil
  defp plural(1, one, _many), do: "1 #{one}"
  defp plural(count, one, many), do: "#{count} #{many || one <> "s"}"

  defp plural(count, one), do: plural(count, one, nil)

  # The inspector's next service is the first loaded exact date on or after the
  # agency-local today, so it states a real date instead of re-evaluating the range.
  defp next_service(%{active_dates: dates}, %Date{} = today) when is_list(dates) do
    Enum.find(dates, &(Date.compare(&1, today) != :lt))
  end

  defp next_service(_row, _today), do: nil

  defp next_service_label(%{next_service: nil}), do: "None scheduled"

  defp next_service_label(%{next_service: date, detail: %{today: today}}) do
    label = Elixir.Calendar.strftime(date, "%a, %b %-d, %Y")

    if date == today, do: "Today, #{label}", else: label
  end

  defp next_service_label(_assigns), do: "None scheduled"

  defp empty_dates_text(%{kind: :weekly}), do: "This calendar has no stored date changes."
  defp empty_dates_text(_row), do: "This calendar runs on no dates yet."

  # Dates outside the drawn range are counted with their exact span rather than
  # discarded: the axis is a view of the loaded dates, never a limit on them (INV-5).
  defp outside_lines(%{window: nil}) do
    ["This version has no service dates, so there is no timeline to compare against."]
  end

  defp outside_lines(%{window: window} = detail) do
    lines =
      [
        outside_line("before", detail.before, window.first_date),
        outside_line("after", detail.after, window.last_date)
      ]
      |> Enum.reject(&is_nil/1)

    case lines do
      [] -> ["Every service date falls inside the timeline."]
      _lines -> lines ++ ["The timeline is a view of these dates, so none of them is dropped."]
    end
  end

  defp outside_line(_side, [], _edge), do: nil

  defp outside_line("before", dates, edge) do
    "#{plural(length(dates), "service date")} before #{format_date(edge)}: #{date_span(dates)}"
  end

  defp outside_line("after", dates, edge) do
    "#{plural(length(dates), "service date")} after #{format_date(edge)}: #{date_span(dates)}"
  end

  defp date_span([date]), do: format_date(date)

  defp date_span([first | _rest] = dates),
    do: "#{format_date(first)} – #{format_date(List.last(dates))}"

  defp invalid_title(1), do: "1 calendar has a date range that cannot be read"
  defp invalid_title(count), do: "#{count} calendars have a date range that cannot be read"

  defp reason_text(:reversed_range), do: "the weekly range ends before it starts."
  defp reason_text(_reason), do: "the stored dates could not be read."

  defp legend_items do
    [
      {"service", "Regular service"},
      {"removed", "Day off"},
      {"break", "Break"},
      {"added", "Added date"},
      {"gap", "No service on any calendar"},
      {"today", "Today"}
    ]
  end

  # -- Coverage geometry ------------------------------------------------------

  defp pct(value) when is_float(value),
    do: "#{:erlang.float_to_binary(value * 100, decimals: 4)}%"

  defp pct(value) when is_integer(value), do: "#{value}%"

  defp band_style(band), do: "left: #{pct(band.left)}; width: #{pct(band.width)}"

  # A one-day lane would collapse to a hairline, so every bar keeps a 3 px floor the
  # same way the packaged reference does. A single day also gives up 1 px of its lane,
  # which is what separates the day cells of the near range instead of one solid bar.
  defp mark_style(mark) do
    width =
      if Date.compare(mark.first_date, mark.last_date) == :eq do
        "calc(#{pct(mark.width)} - 1px)"
      else
        pct(mark.width)
      end

    "left: #{pct(mark.left)}; width: #{width}; min-width: 3px"
  end

  defp mark_class(%{mixed?: true} = mark),
    do: [mark_class(%{mark | mixed?: false}), "is-approximate"]

  defp mark_class(%{type: type}), do: "calendar-coverage-mark--#{type}"

  defp mark_title(mark) do
    kind =
      case mark.type do
        :service -> "regular service"
        :added -> "added date"
        :removed -> "day off"
        :break -> "break"
      end

    exact = if mark.mixed?, do: "approximately, in this compression: ", else: ""

    case Date.compare(mark.first_date, mark.last_date) do
      :eq ->
        "#{format_date(mark.first_date)}: #{kind}"

      _other ->
        "#{exact}#{format_date(mark.first_date)} – #{format_date(mark.last_date)}: #{kind}"
    end
  end

  defp outside_class(:before), do: "calendar-coverage-outside--before"
  defp outside_class(:after), do: "calendar-coverage-outside--after"

  defp outside_label(:before), do: "Before this range"
  defp outside_label(:after), do: "After this range"

  defp outside_icon(:before), do: "hero-chevron-left"
  defp outside_icon(:after), do: "hero-chevron-right"

  # A label needs about 36 px, so labels thin by rank rather than by a fixed month
  # count: January and the window start always show, then roughly a twelfth of the
  # months, then half, then all as the column widens. An axis longer than three years
  # names its years only, the same rule the packaged reference uses for a long feed.
  defp tick_rows(ticks) when length(ticks) > @year_only_months do
    Enum.map(ticks, fn tick ->
      tick
      |> Map.merge(%{density: "core", labelled?: core_tick?(tick)})
      |> line_for_label()
    end)
  end

  defp tick_rows(ticks) do
    case length(ticks) do
      count when count <= 6 ->
        Enum.map(ticks, &short_tick/1)

      count ->
        stride =
          max(1, ceil_div(count - Enum.count(ticks, &core_tick?/1), @tick_label_target))

        {rows, _rank} = Enum.reduce(ticks, {[], 0}, &rank_tick(&1, &2, stride))

        Enum.reverse(rows)
    end
  end

  defp short_tick(tick),
    do: tick |> Map.merge(%{density: "core", labelled?: true}) |> line_for_label()

  defp rank_tick(tick, {rows, rank}, stride) do
    if core_tick?(tick) do
      {[short_tick(tick) | rows], rank}
    else
      row =
        tick
        |> Map.merge(%{density: density(rank, stride), labelled?: rem(rank, stride) == 0})
        |> line_for_label()

      {[row | rows], rank + 1}
    end
  end

  defp core_tick?(%{year?: true}), do: true
  defp core_tick?(%{line?: false}), do: true
  defp core_tick?(_tick), do: false

  # A month line is drawn only where its label is. An unlabelled tick would otherwise
  # comb a long axis into a texture that competes with the labels, which is what a
  # nine-year feed looked like before this rule.
  defp line_for_label(tick), do: Map.put(tick, :lined?, tick.labelled? and tick.line?)

  defp density(rank, stride) do
    cond do
      rem(rank, 4 * stride) == 0 -> "quarter"
      rem(rank, 2 * stride) == 0 -> "half"
      true -> "full"
    end
  end

  defp ceil_div(value, divisor), do: div(value + divisor - 1, divisor)

  defp tick_label(%{line?: false} = tick),
    do: "#{Elixir.Calendar.strftime(tick.date, "%b")} #{tick.date.year}"

  defp tick_label(%{year?: true} = tick), do: "#{tick.date.year}"
  defp tick_label(tick), do: Elixir.Calendar.strftime(tick.date, "%b")

  defp axis_label(%{first_date: nil}), do: "No service dates to plot on this axis."

  defp axis_label(axis) do
    gaps = Enum.map(axis.gap_bands, &gap_days/1) |> Enum.sum()

    "Coverage timeline, #{format_date(axis.first_date)} to #{format_date(axis.last_date)}." <>
      if(gaps == 0, do: "", else: " #{plural(gaps, "day")} with no service on any calendar.")
  end

  defp gap_days(band), do: Date.diff(band.last_date, band.first_date) + 1

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
      |> Enum.sort_by(&{Date.to_erl(&1.first_date), &1.kind == :break})

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

  ## Combination review

  @week_days [
    {"Mon", :monday},
    {"Tue", :tuesday},
    {"Wed", :wednesday},
    {"Thu", :thursday},
    {"Fri", :friday},
    {"Sat", :saturday},
    {"Sun", :sunday}
  ]

  @doc """
  Names one calendar's regular weekdays the way the Calendars list does.

  A calendar with no weekly row is specific dates; the list and the combination review
  therefore state the same weekly pattern from one function instead of two phrasings.
  """
  def regular_days(%{calendar: nil}), do: "Specific dates"

  def regular_days(%{calendar: calendar}) do
    days = for {label, field} <- @week_days, Map.fetch!(calendar, field) == 1, do: label

    case days do
      ["Mon", "Tue", "Wed", "Thu", "Fri"] -> "Mon–Fri"
      ["Sat", "Sun"] -> "Sat–Sun"
      ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"] -> "Every day"
      [] -> "No weekly days"
      other -> Enum.join(other, ", ")
    end
  end

  @doc """
  Reports whether a reviewed combination changes nothing at all.

  Every moving calendar contributes no trips and the destination's own effective dates are
  unchanged, so the only useful action is to delete the empty source instead. The check reads
  the review's own facts - the moved counts and the destination's gained and lost dates - and
  never re-derives dates, and an incomplete review is never reported as a no-op.
  """
  def combination_nothing?(%{ready?: true, effects: effects}) when is_list(effects) do
    destination = Enum.find(effects, &(not &1.moving?))
    moving = Enum.filter(effects, & &1.moving?)

    destination != nil and Enum.all?(moving, &(&1.trip_count == 0)) and
      destination.gained_dates == [] and destination.lost_dates == []
  end

  def combination_nothing?(_review), do: false

  @doc """
  Renders the destination choice for a reviewed combination.

  Every selected calendar is an option with its exact identity, regular days and coverage
  caption, and the destination states the trips it would keep. The radio values are the exact
  service IDs the review command receives, and the destination starts on the selection's
  most-used calendar, so opening the drawer never depends on click order (AC-20).
  """
  attr :id, :string, required: true
  attr :form, :any, required: true
  attr :rows, :list, required: true
  attr :destination_id, :string, required: true
  attr :review, :map, required: true
  attr :version_id, :any, required: true

  def combination_controls(assigns) do
    assigns =
      assigns
      |> assign(:field, assigns.form[:destination_id])
      |> assign(:candidates, Enum.sort_by(assigns.rows, &display_order/1))

    ~H"""
    <fieldset id={@id} class="min-w-0">
      <legend class="text-base font-semibold">Keep one calendar</legend>
      <p class="mt-1 text-sm text-base-content/70">
        Trips move into it, and it keeps its name and service ID. The others stay in the list
        with 0 trips, so anything that refers to them keeps working.
      </p>
      <div class="mt-3 grid gap-2">
        <label
          :for={row <- @candidates}
          id={"#{@id}-option-#{URI.encode_www_form(row.service_id)}"}
          class={[
            "flex min-h-14 cursor-pointer flex-wrap items-center gap-x-3 gap-y-1 rounded-box border px-3 py-2",
            row.service_id == @destination_id && "border-secondary bg-secondary/5"
          ]}
        >
          <input
            type="radio"
            class="radio radio-sm accent-secondary"
            name={@field.name}
            value={row.service_id}
            checked={row.service_id == @destination_id}
            aria-label={"Keep #{row.name || row.service_id}"}
          />
          <span class="min-w-0 flex-1">
            <span class="block font-semibold">{row.name || row.service_id}</span>
            <span class="block text-sm text-base-content/70">
              <code class="font-mono">{row.service_id}</code>
              {" · "}{regular_days(row)}
              <span :if={coverage_caption(row)}>{" · "}{coverage_caption(row)}</span>
            </span>
          </span>
          <span class="shrink-0 text-sm">
            {destination_trips_label(row, assigns)}
          </span>
        </label>
      </div>
    </fieldset>
    """
  end

  @doc """
  Renders the reviewed result: the headline, the three reviewed totals and what would be stored.

  The headline states the strongest fact the review supports: a no-op points at the source that
  should be deleted, an undecided review states how many dates still need a choice, a review
  whose moves change upcoming dates names them per calendar, and a review whose moves do not
  change any upcoming date says so. The totals and the stored form come from the review's own
  projected dates and the destination's native projection, never from a client total (INV-3).
  """
  attr :id, :string, required: true
  attr :review, :map, required: true
  attr :rows, :list, required: true
  attr :destination_id, :string, required: true
  attr :stored, :map, default: nil
  attr :today, :any, default: nil
  attr :version_id, :any, required: true

  def combination_result(assigns) do
    assigns =
      assign(
        assigns,
        :destination,
        Enum.find(assigns.rows, &(&1.service_id == assigns.destination_id))
      )

    assigns =
      assigns
      |> assign(:upcoming, upcoming_destination_label(assigns))
      |> assign(:headline, result_headline(assigns))

    ~H"""
    <section id={@id} class="min-w-0" aria-labelledby={@id <> "-heading"}>
      <h3 id={@id <> "-heading"} class="text-base font-semibold">Result</h3>
      <div class="mt-2">
        <.callout kind={@headline.kind} title={@headline.title}>
          {@headline.text}
          <.link
            :if={@headline.link}
            id={@id <> "-source-link"}
            navigate={
              "/gtfs/#{@version_id}/calendars/show?service_id=" <>
                URI.encode_www_form(@headline.link.service_id)
            }
            class="link link-primary font-semibold"
          >
            Open {@headline.link.name}
          </.link>
        </.callout>
      </div>

      <dl
        id={@id <> "-totals"}
        class="mt-3 grid divide-y divide-base-300 rounded-box border border-base-300 sm:grid-cols-3 sm:divide-x sm:divide-y-0"
      >
        <div class="min-w-0 px-3 py-2">
          <dt class="text-sm text-base-content/70">Trips moving</dt>
          <dd id={@id <> "-moved"} class="text-xl font-semibold tabular-nums">
            {@review.moved_trip_count}
          </dd>
        </div>
        <div class="min-w-0 px-3 py-2">
          <dt class="truncate text-sm text-base-content/70">
            Upcoming dates, {@destination && (@destination.name || @destination.service_id)}
          </dt>
          <dd id={@id <> "-upcoming"} class="text-xl font-semibold tabular-nums">
            {@upcoming}
          </dd>
        </div>
        <div class="min-w-0 px-3 py-2">
          <dt class="text-sm text-base-content/70">Left with 0 trips</dt>
          <dd id={@id <> "-sources"} class="text-xl font-semibold tabular-nums">
            {plural(length(@review.retained_sources), "calendar")}
          </dd>
        </div>
      </dl>

      <p :if={stored_label(@stored)} id={@id <> "-stored"} class="mt-3 text-sm">
        Stored as {stored_label(@stored)}.
      </p>
      <p
        :if={@stored && dates_only_note(assigns)}
        id={@id <> "-dates-only"}
        class="mt-1 text-sm text-base-content/70"
      >
        {dates_only_note(assigns)}
      </p>
      <p :if={@stored} id={@id <> "-no-new-dates"} class="mt-1 text-sm text-success">
        No new service dates: every date comes from a selected calendar.
      </p>
    </section>
    """
  end

  @doc """
  States the conflict dates a review still needs a decision for.

  Each conflict is a date one selected calendar deliberately stops on while another runs it, and
  the domain groups only civil-adjacent dates whose running and removing calendars are identical.
  The label names the exact dates, the calendars on each side and the missing choice; a decided
  review renders no unresolved group. The review owns the grouping and the IDs, so nothing here
  re-derives which calendars run on a date.
  """
  attr :id, :string, required: true
  attr :review, :map, required: true
  attr :rows, :list, required: true
  attr :today, :any, default: nil

  def combination_conflict_labels(assigns) do
    assigns =
      assigns
      |> assign(:groups, conflict_groups(assigns.review, assigns.rows))
      |> assign(:date_count, length(assigns.review.conflicts))

    ~H"""
    <section :if={@groups != []} id={@id} class="min-w-0" aria-labelledby={@id <> "-heading"}>
      <h3 id={@id <> "-heading"} class="text-base font-semibold">
        Choose what happens on {plural(@date_count, "date")}
      </h3>
      <p class="mt-1 text-sm text-base-content/70">
        One calendar has these dates off while another runs them. A combined calendar can't do
        both, so every trip follows your choice.
      </p>
      <ul class="mt-3 grid gap-2">
        <li
          :for={group <- @groups}
          id={@id <> "-" <> group.key}
          class="min-w-0 rounded-box border border-warning bg-warning/10 px-4 py-3"
        >
          <p class="font-medium">{group.label}</p>
          <p class="mt-0.5 text-sm">
            {group.removing_names} {if length(group.removing_ids) == 1,
              do: "has no service",
              else: "have no service"}. {group.running_names} {if length(group.running_ids) == 1,
              do: "runs",
              else: "run"}.
          </p>
          <p class="mt-1 text-sm font-medium text-warning">
            Needs your choice: the combined calendar either runs the date for every trip or has
            no service.
          </p>
        </li>
      </ul>
    </section>
    """
  end

  @doc """
  States the dates each selected calendar's trips run on after the reviewed combination.

  Every line uses the review's own gained and lost dates: upcoming changes name the weekday
  pattern and the exact span, past-only changes say so, and a calendar whose trips do not move
  says that nothing changes. A calendar with no trips and an undecided review state the fact
  instead of an empty list that would read as "nothing changes" (AC-8).
  """
  attr :id, :string, required: true
  attr :review, :map, required: true
  attr :rows, :list, required: true
  attr :destination_id, :string, required: true

  def combination_effects(assigns) do
    assigns =
      assigns
      |> assign(:entries, effect_entries(assigns))
      |> assign(:undecided?, Enum.any?(assigns.review.effects, &is_nil(&1.gained_dates)))

    ~H"""
    <section id={@id} class="min-w-0" aria-labelledby={@id <> "-heading"}>
      <h3 id={@id <> "-heading"} class="text-base font-semibold">
        When trips run after combining
      </h3>
      <p :if={@undecided?} class="mt-1 text-sm text-base-content/70">
        The dates below the undecided ones depend on your choice.
      </p>
      <ul class="mt-3 divide-y divide-base-300 rounded-box border border-base-300">
        <li
          :for={entry <- @entries}
          id={@id <> "-" <> URI.encode_www_form(entry.service_id)}
          class="flex gap-3 px-4 py-3"
        >
          <.icon name={entry.icon} class={["size-5 shrink-0", entry.icon_class]} />
          <div class="min-w-0">
            <p class="text-sm">
              <strong>{entry.name}</strong>
              <span class="text-base-content/70">{" · "}{entry.role}</span>
            </p>
            <p class="mt-0.5 text-sm">{entry.line}</p>
          </div>
        </li>
      </ul>
    </section>
    """
  end

  @doc """
  States the real block, transfer and retained-source consequences of the reviewed combination.

  Every item comes from the review's own projection: the cleared trip IDs and the findings the
  concrete Blocking producer returned before and after the move, the in-seat records it re-read,
  the retained source IDs and the loaded route usage. New and pre-existing findings are separated
  by the producer's own finding key, and a no-op review renders no consequences at all.
  """
  attr :id, :string, required: true
  attr :review, :map, required: true
  attr :rows, :list, required: true
  attr :destination_id, :string, required: true
  attr :version_id, :any, required: true

  def combination_impacts(assigns) do
    # A no-op has nothing else to check: the headline already names the source to delete, so the
    # section stays out of the drawer instead of restating the same guidance.
    assigns =
      if combination_nothing?(assigns.review) do
        assign(assigns, :items, [])
      else
        assign(assigns, :items, impact_items(assigns))
      end

    ~H"""
    <section :if={@items != []} id={@id} class="min-w-0" aria-labelledby={@id <> "-heading"}>
      <h3 id={@id <> "-heading"} class="text-base font-semibold">Also check</h3>
      <ul class="mt-3 grid gap-3 text-sm">
        <li :for={item <- @items} id={@id <> "-" <> item.key} class="flex gap-2.5">
          <.icon name={item.icon} class={["size-5 shrink-0", item.icon_class]} />
          <span>
            {item.text}
            <.link
              :if={item.link}
              navigate={
                "/gtfs/#{@version_id}/calendars/show?service_id=" <>
                  URI.encode_www_form(item.link.service_id)
              }
              class="link link-primary font-semibold"
            >
              Open {item.link.name}
            </.link>
          </span>
        </li>
      </ul>
      <p class="mt-5 border-t border-base-300 pt-4 text-sm text-base-content/70">
        Blocks groups calendars into day types without combining them, so combining is not needed
        only to view calendars together.
      </p>
    </section>
    """
  end

  defp display_order(row), do: {String.downcase(row.name || row.service_id), row.service_id}

  defp destination_trips_label(row, assigns) do
    if row.service_id == assigns.destination_id do
      moved = assigns.review.moved_trip_count

      if moved > 0 do
        "Keeps #{row.trip_count} + #{moved} trips"
      else
        "Keeps #{plural(row.trip_count, "trip")}"
      end
    else
      if row.trip_count > 0, do: "#{row.trip_count} trips move", else: "No trips"
    end
  end

  defp result_headline(assigns) do
    review = assigns.review
    destination = assigns.destination
    destination_name = destination && (destination.name || destination.service_id)

    cond do
      combination_nothing?(review) ->
        %{
          kind: "info",
          title: "Nothing changes.",
          text: nothing_text(assigns, destination_name),
          link: nothing_link(assigns)
        }

      changed_effects(review) != [] ->
        %{
          kind: "warning",
          title: "Some trips will run on different dates.",
          text: changed_text(assigns) <> pending_text(review),
          link: nil
        }

      review.ready? == false ->
        %{
          kind: "warning",
          title: "Almost ready.",
          text: pending_sentence(review),
          link: nil
        }

      true ->
        %{
          kind: "success",
          title: moved_headline(review.moved_trip_count),
          text: "The kept calendar, #{destination_name}, keeps its dates.",
          link: nil
        }
    end
  end

  defp moved_headline(1), do: "1 trip moves, and no trip changes its upcoming dates."
  defp moved_headline(count), do: "#{count} trips move, and no trip changes its upcoming dates."

  defp nothing_text(assigns, destination_name) do
    sources = source_names(assigns.review, assigns.rows)

    "#{sources} #{if length(assigns.review.retained_sources) == 1, do: "has", else: "have"} no trips, and #{destination_name} already runs on all of #{if length(assigns.review.retained_sources) == 1, do: "its", else: "their"} dates. To tidy the list, delete #{if length(assigns.review.retained_sources) == 1, do: "it", else: "them"} from #{if length(assigns.review.retained_sources) == 1, do: "its page", else: "their pages"} instead. "
  end

  defp nothing_link(assigns) do
    case assigns.review.retained_sources do
      [service_id | _rest] ->
        %{service_id: service_id, name: row_name(assigns.rows, service_id)}

      [] ->
        nil
    end
  end

  defp changed_effects(review) do
    Enum.filter(review.effects, fn effect ->
      effect.moving? and is_list(effect.upcoming_gained_dates) and
        is_list(effect.upcoming_lost_dates) and
        (effect.upcoming_gained_dates != [] or effect.upcoming_lost_dates != [])
    end)
  end

  defp changed_text(assigns) do
    assigns.review
    |> changed_effects()
    |> Enum.map_join("; ", fn effect ->
      gains =
        if effect.upcoming_gained_dates != [] do
          "gain #{plural(length(effect.upcoming_gained_dates), "upcoming date")}"
        end

      losses =
        if effect.upcoming_lost_dates != [] do
          "lose #{plural(length(effect.upcoming_lost_dates), "upcoming date")}"
        end

      joined = [gains, losses] |> Enum.reject(&is_nil/1) |> Enum.join(" and ")

      "#{plural(effect.trip_count, "trip")} from #{row_name(assigns.rows, effect.service_id)} #{joined}"
    end)
    |> Kernel.<>(".")
  end

  defp pending_text(%{conflicts: []}), do: ""

  defp pending_text(review),
    do: " #{pending_sentence(review)}"

  defp pending_sentence(review) do
    count = length(review.conflicts)

    "#{plural(count, "date")} #{if count == 1, do: "needs", else: "need"} your choice."
  end

  defp upcoming_destination_label(assigns) do
    destination = assigns.destination

    if destination == nil do
      "—"
    else
      today = assigns.today

      before =
        Enum.count(destination.active_dates, &(is_nil(today) or Date.compare(&1, today) != :lt))

      case Enum.find(assigns.review.effects, &(&1.service_id == destination.service_id)) do
        %{gained_dates: nil} ->
          "#{before} → after your choice"

        %{upcoming_gained_dates: gained, upcoming_lost_dates: lost} ->
          "#{before} → #{before + length(gained) - length(lost)}"

        nil ->
          "#{before}"
      end
    end
  end

  defp stored_label(nil), do: nil

  defp stored_label(%{calendar: nil, exceptions: exceptions}) do
    plural(length(exceptions), "specific date")
  end

  defp stored_label(%{calendar: calendar, exceptions: exceptions}) do
    removed = Enum.count(exceptions, &(&1.exception_type == 2))
    added = Enum.count(exceptions, &(&1.exception_type == 1))

    "#{regular_days(%{calendar: calendar})}, #{format_date(calendar.start_date)} – " <>
      "#{format_date(calendar.end_date)}, with #{count_label(removed, "day off", "days off")} and " <>
      "#{count_label(added, "added date", "added dates")}"
  end

  # A stored count states zero as well: "with 0 added dates" is a fact about the result, while
  # an omitted count would read as if the number were not known.
  defp count_label(1, one, _many), do: "1 #{one}"
  defp count_label(count, one, many), do: "#{count} #{many || one <> "s"}"

  defp dates_only_note(assigns) do
    stored = assigns.stored
    destination = assigns.destination

    with %{calendar: nil} <- stored,
         %{} = destination,
         %{} = weekly <- weekly_alternative(assigns.rows, destination.service_id) do
      count = length(stored.exceptions)

      "#{destination.name || destination.service_id} stores dates one by one, so the result is " <>
        "stored as #{plural(count, "specific date")}. Keeping #{weekly.name || weekly.service_id} " <>
        "stores a weekly schedule instead."
    else
      _other -> nil
    end
  end

  defp weekly_alternative(rows, destination_id) do
    rows
    |> Enum.reject(&(&1.service_id == destination_id))
    |> Enum.filter(&(&1.calendar != nil))
    |> Enum.max_by(& &1.trip_count, fn -> nil end)
  end

  defp conflict_groups(review, rows) do
    review.conflicts
    |> Enum.group_by(& &1.group_key)
    |> Enum.sort_by(fn {key, _entries} -> key end)
    |> Enum.map(fn {key, entries} -> conflict_group(key, entries, rows) end)
  end

  defp conflict_group(key, entries, rows) do
    dates = entries |> Enum.map(& &1.date) |> Enum.sort(Date)
    first = hd(entries)

    %{
      key: URI.encode_www_form(key),
      label: conflict_label(dates),
      removing_ids: first.removing_ids,
      running_ids: first.running_ids,
      removing_names: service_id_names(first.removing_ids, rows),
      running_names: service_id_names(first.running_ids, rows)
    }
  end

  defp conflict_label([date]), do: format_date(date)

  defp conflict_label([first | _rest] = dates) do
    "#{format_date(first)} – #{format_date(List.last(dates))} · #{plural(length(dates), "date")}"
  end

  # The conflict carries exact service IDs; the loaded rows supply their display names.
  defp service_id_names(service_ids, rows),
    do: Enum.map_join(service_ids, ", ", &row_name(rows, &1))

  defp effect_entries(assigns) do
    destination_id = assigns.destination_id

    assigns.review.effects
    |> Enum.sort_by(fn effect ->
      {if(effect.service_id == destination_id, do: 0, else: 1),
       display_order_effect(effect, assigns.rows)}
    end)
    |> Enum.map(&effect_entry(&1, assigns))
  end

  defp display_order_effect(effect, rows) do
    case Enum.find(rows, &(&1.service_id == effect.service_id)) do
      nil -> {String.downcase(effect.service_id), effect.service_id}
      row -> display_order(row)
    end
  end

  defp effect_entry(effect, assigns) do
    {icon, icon_class, line} = effect_line(effect)

    %{
      service_id: effect.service_id,
      name: row_name(assigns.rows, effect.service_id),
      role: effect_role(effect),
      icon: icon,
      icon_class: icon_class,
      line: line
    }
  end

  defp effect_role(%{moving?: true, trip_count: 0}), do: "no trips"
  defp effect_role(%{moving?: true, trip_count: 1}), do: "1 trip moves"
  defp effect_role(%{moving?: true, trip_count: count}), do: "#{plural(count, "trip")} move"
  defp effect_role(%{trip_count: count}), do: "#{plural(count, "trip")} stay"

  defp effect_line(%{trip_count: 0}) do
    {"hero-minus-circle", "text-base-content/50", "No trips, so nothing changes for riders."}
  end

  defp effect_line(%{gained_dates: nil}) do
    {"hero-question-mark-circle", "text-warning",
     "The dates these trips run depend on your choice."}
  end

  defp effect_line(effect) do
    upcoming_gained = effect.upcoming_gained_dates
    upcoming_lost = effect.upcoming_lost_dates

    cond do
      upcoming_gained != [] or upcoming_lost != [] ->
        {"hero-exclamation-triangle", "text-warning", upcoming_line(effect)}

      effect.past_gained_dates != [] or effect.past_lost_dates != [] ->
        past = length(effect.past_gained_dates) + length(effect.past_lost_dates)

        {"hero-information-circle", "text-base-content/50",
         "Only past dates change (#{plural(past, "date")} before today). Upcoming service stays the same."}

      true ->
        {"hero-check-circle", "text-success", "No change to the dates they run."}
    end
  end

  defp upcoming_line(effect) do
    bits =
      [
        if(effect.upcoming_gained_dates != [],
          do: "Also run on #{describe_dates(effect.upcoming_gained_dates)}",
          else: nil
        ),
        if(effect.upcoming_lost_dates != [],
          do: "Stop running on #{describe_dates(effect.upcoming_lost_dates)}",
          else: nil
        )
      ]
      |> Enum.reject(&is_nil/1)

    seasonal =
      if effect.moving? and length(effect.upcoming_gained_dates) > @seasonal_threshold do
        " If these trips should keep their own dates, don't combine."
      else
        ""
      end

    Enum.join(bits, ". ") <> "." <> seasonal
  end

  # A short list is named exactly; a longer one states its count, its weekday pattern and its
  # span, which is what the reference's consequence line does without re-evaluating any date.
  defp describe_dates(dates) do
    case dates do
      [date] ->
        format_date(date)

      [first, second] ->
        "#{format_date(first)} and #{format_date(second)}"

      [first, second, third] ->
        "#{format_date(first)}, #{format_date(second)} and #{format_date(third)}"

      [first | _rest] = all ->
        pattern = weekday_pattern(all)

        "#{plural(length(all), "date")}#{if pattern, do: " (#{pattern})", else: ""}, " <>
          "#{format_date(first)} – #{format_date(List.last(all))}"
    end
  end

  defp weekday_pattern(dates) do
    case dates |> Enum.map(&Date.day_of_week/1) |> Enum.uniq() |> Enum.sort() do
      [6] -> "Saturdays"
      [7] -> "Sundays"
      [6, 7] -> "weekends"
      [1, 2, 3, 4, 5] -> "weekdays"
      [5, 6] -> "Fridays and Saturdays"
      _other -> nil
    end
  end

  defp impact_items(assigns) do
    effects = assigns.review.block_effects

    case effects do
      nil -> retained_items(assigns)
      %{} -> block_items(assigns, effects) ++ retained_items(assigns)
    end
  end

  defp block_items(_assigns, effects) do
    cleared_block_item(effects) ++ new_finding_items(effects) ++ transfer_items(effects)
  end

  defp cleared_block_item(%{cleared_trip_ids: []}), do: []

  defp cleared_block_item(effects) do
    blocks =
      effects.before_findings
      |> Enum.filter(fn finding ->
        finding.block_id != nil and
          Enum.any?(finding.trip_ids, &(&1 in effects.cleared_trip_ids))
      end)
      |> Enum.map(& &1.block_id)
      |> Enum.uniq()
      |> Enum.sort()

    count = length(effects.cleared_trip_ids)

    [
      %{
        key: "cleared-blocks",
        icon: "hero-exclamation-triangle",
        icon_class: "text-warning",
        text:
          "#{plural(count, "moved trip")} #{if count == 1, do: "leaves", else: "leave"} " <>
            "#{block_label(blocks)} and #{if count == 1, do: "goes", else: "go"} to the unassigned pool on Blocks.",
        link: nil
      }
    ]
  end

  defp block_label([]), do: "its block"
  defp block_label([block_id]), do: "block #{block_id}"
  defp block_label(block_ids), do: "blocks #{Enum.join(block_ids, ", ")}"

  defp new_finding_items(effects) do
    before_keys = MapSet.new(effects.before_findings, &Checks.finding_key/1)

    new_findings =
      Enum.reject(effects.after_findings, &MapSet.member?(before_keys, Checks.finding_key(&1)))

    new_findings
    |> Enum.group_by(& &1.code)
    |> Enum.sort_by(fn {code, _findings} -> code end)
    |> Enum.map(fn {code, findings} -> finding_item(code, findings) end)
  end

  defp finding_item(code, findings) do
    blocks =
      findings |> Enum.map(& &1.block_id) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort()

    %{
      key: "finding-#{code}",
      icon: "hero-exclamation-triangle",
      icon_class: "text-warning",
      text:
        "#{plural(length(findings), "new #{finding_label(code)} warning")}" <>
          if(blocks == [], do: " on the new dates.", else: " on #{block_label(blocks)}."),
      link: nil
    }
  end

  defp finding_label(:overlap), do: "block overlap"
  defp finding_label(:short_layover), do: "short layover"
  defp finding_label(:in_seat_stale), do: "in-seat transfer"
  defp finding_label(:in_seat_unconfirmed), do: "in-seat confirmation"
  defp finding_label(:repositions), do: "repositioning"
  defp finding_label(:frequency_trip), do: "frequency trip"
  defp finding_label(:unplottable), do: "unplottable trip"
  defp finding_label(code), do: "#{code}" |> String.replace("_", " ")

  defp transfer_items(%{transfers: []}), do: []

  defp transfer_items(effects) do
    {changed, unchanged} = Enum.split_with(effects.transfers, &(&1.before != &1.after))

    changed_items =
      Enum.map(changed, fn transfer ->
        %{
          key: "transfer-#{transfer.id}",
          icon: "hero-exclamation-triangle",
          icon_class: "text-warning",
          text:
            "In-seat transfer #{transfer.id} #{in_seat_label(transfer.before)} before the move " <>
              "and #{in_seat_label(transfer.after)} after it.",
          link: nil
        }
      end)

    unchanged_items =
      case unchanged do
        [] ->
          []

        transfers ->
          [
            %{
              key: "transfers-unchanged",
              icon: "hero-check-circle",
              icon_class: "text-success",
              text: unchanged_transfer_text(length(transfers)),
              link: nil
            }
          ]
      end

    changed_items ++ unchanged_items
  end

  defp unchanged_transfer_text(1) do
    "1 in-seat transfer names these trips. It stays; Blocks reports any that no longer match."
  end

  defp unchanged_transfer_text(count) do
    "#{count} in-seat transfers name these trips. They stay; Blocks reports any that no longer match."
  end

  defp in_seat_label(:matches), do: "matches today"

  defp in_seat_label({:stale, reason}),
    do: "no longer matches (#{in_seat_reason(reason)})"

  defp in_seat_label({:unconfirmed, reason}),
    do: "needs confirmation (#{in_seat_reason(reason)})"

  defp in_seat_reason(:trip_missing), do: "a trip is missing"
  defp in_seat_reason(:no_shared_date), do: "no shared date"
  defp in_seat_reason(:no_block), do: "no block"
  defp in_seat_reason(:stops_changed), do: "the recorded stops changed"
  defp in_seat_reason(:next_service_day), do: "the next service day"
  defp in_seat_reason(:untimed), do: "no times"
  defp in_seat_reason(:coupling), do: "the coupling time"

  defp in_seat_reason({:not_next, failures}) do
    "not the next trip on #{plural(length(failures), "day type")}"
  end

  defp in_seat_reason(reason), do: "#{reason}"

  defp retained_items(assigns) do
    sources = Enum.map(assigns.review.retained_sources, &source_item(&1, assigns))
    routes = route_item(assigns)
    sources ++ routes
  end

  defp source_item(service_id, assigns) do
    name = row_name(assigns.rows, service_id)

    %{
      key: "retained-#{URI.encode_www_form(service_id)}",
      icon: "hero-information-circle",
      icon_class: "text-base-content/50",
      text:
        "#{name} stays in the list with 0 trips and its own service ID. Delete it from its " <>
          "page once nothing uses it. ",
      link: %{service_id: service_id, name: name}
    }
  end

  defp route_item(assigns) do
    routes =
      assigns.rows
      |> Enum.filter(&(&1.service_id != assigns.destination_id))
      |> Enum.flat_map(& &1.routes)
      |> Enum.map(& &1.route_id)
      |> Enum.uniq()
      |> Enum.sort()

    case routes do
      [] ->
        []

      route_ids ->
        [
          %{
            key: "routes",
            icon: "hero-information-circle",
            icon_class: "text-base-content/50",
            text:
              "Schedules for #{if length(route_ids) == 1, do: "route", else: "routes"} " <>
                "#{Enum.join(route_ids, ", ")} list the moved trips under " <>
                "#{row_name(assigns.rows, assigns.destination_id)}.",
            link: nil
          }
        ]
    end
  end

  defp source_names(review, rows) do
    review.retained_sources
    |> Enum.map(&row_name(rows, &1))
    |> join_names()
  end

  defp join_names([]), do: ""
  defp join_names([name]), do: name
  defp join_names(names), do: Enum.join(names, ", ")

  defp row_name(rows, service_id) do
    case Enum.find(rows, &(&1.service_id == service_id)) do
      nil -> service_id
      row -> row.name || row.service_id
    end
  end

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
end
