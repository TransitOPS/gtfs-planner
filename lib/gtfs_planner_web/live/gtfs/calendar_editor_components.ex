defmodule GtfsPlannerWeb.Gtfs.CalendarEditorComponents do
  @moduledoc """
  The calendar editor's presentation in the TransitOps application design system.

  `GtfsPlannerWeb.Gtfs.CalendarLive` owns every event, form and write; these
  components only choose structure, wording and marks for values the domain
  already derived (`Gtfs.Calendars.ServiceDates` periods, breaks, month cells and
  warnings). The calendar list keeps using `CalendarComponents`, so nothing here
  changes what that page renders.

  The result comes first: the header says what the calendar runs and which trips
  depend on it, the preview beside the form shows the days it runs (including
  unsaved edits), and the changes card keeps date changes, which apply when
  confirmed, apart from the schedule form, which alone has Save.
  """

  use GtfsPlannerWeb, :html

  import GtfsPlannerWeb.PlannerComponents, only: [message: 1]

  @short_format "%b %-d"
  @weekday_date_format "%a, %b %-d, %Y"

  @weekdays [
    monday: "Monday",
    tuesday: "Tuesday",
    wednesday: "Wednesday",
    thursday: "Thursday",
    friday: "Friday",
    saturday: "Saturday",
    sunday: "Sunday"
  ]

  @badge_tones %{
    success: "bg-success-bg text-success-fg",
    warning: "bg-warning-bg text-warning-fg",
    neutral: "border border-subtle bg-canvas text-default"
  }

  @cell_tones %{
    service: "bg-soft font-bold text-cyan-800",
    removed:
      "border border-warning-line bg-warning-bg font-semibold text-warning-fg line-through",
    added: "border border-action-hover bg-selection font-bold text-action-hover",
    none: "font-medium text-muted"
  }

  @cell_words %{
    service: "Runs",
    removed: "Day off, no service",
    added: "Extra service",
    none: "Not a service day"
  }

  @visible_routes 6

  ## Dates and counts

  @doc "One civil date the way the Calendars list writes it: `Sep 1, 2026`."
  defdelegate format_date(date), to: GtfsPlannerWeb.Gtfs.CalendarComponents

  @doc "A civil date with its weekday: `Thu, Nov 26, 2026`."
  def weekday_date(%Date{} = date), do: Calendar.strftime(date, @weekday_date_format)

  @doc """
  A date range that drops what the reader already knows: `Sep 5 – 10, 2026` inside
  one month, `Sep 5 – Oct 10, 2026` inside one year, both years otherwise.
  """
  def date_span(%Date{} = date, %Date{} = date), do: format_date(date)

  def date_span(%Date{year: year, month: month} = first, %Date{year: year, month: month} = last),
    do: "#{Calendar.strftime(first, @short_format)} – #{last.day}, #{year}"

  def date_span(%Date{year: year} = first, %Date{year: year} = last),
    do: "#{Calendar.strftime(first, @short_format)} – #{format_date(last)}"

  def date_span(%Date{} = first, %Date{} = last),
    do: "#{format_date(first)} – #{format_date(last)}"

  @doc "`1 trip`, `2 trips`; a plural that is not `noun <> s` is passed as `many`."
  def plural(1, one, _many), do: "1 #{one}"
  def plural(count, one, many), do: "#{count} #{many || one <> "s"}"
  def plural(count, one), do: plural(count, one, nil)

  ## What the header says

  @doc """
  The one status word for a calendar, in the Calendars list's vocabulary and order.

  Returns `{tone, label}` where tone is `:success`, `:warning` or `:neutral`.
  """
  def status(source) do
    warnings = source.warnings

    ended? = Enum.any?(warnings, &(&1.reason == :ended))
    ends_soon = Enum.find(warnings, &(&1.reason == :ends_soon))
    no_service? = Enum.any?(warnings, &(&1.reason == :no_service))

    cond do
      ended? -> {:neutral, "Ended"}
      ends_soon && ends_soon.days_remaining == 0 -> {:warning, "Ends today"}
      ends_soon -> {:warning, "Ends in #{plural(ends_soon.days_remaining, "day")}"}
      no_service? -> {:warning, "No service"}
      source.usage.trip_count == 0 -> {:neutral, "Not used by trips"}
      source.today in source.active_dates -> {:success, "Runs today"}
      true -> {:neutral, "Scheduled"}
    end
  end

  @doc "What the calendar runs, in one plain sentence fragment."
  def lede(%{kind: :weekly, calendar: %{} = calendar, active_dates: dates}) do
    Enum.join(
      [
        "Runs #{days_phrase(calendar)}",
        date_span(calendar.start_date, calendar.end_date),
        plural(length(dates), "service day")
      ],
      " · "
    )
  end

  def lede(%{active_dates: []}), do: "Runs only on chosen dates · none added yet"

  def lede(%{active_dates: dates}) do
    "Runs only on chosen dates · #{plural(length(dates), "date")}, " <>
      date_span(List.first(dates), List.last(dates))
  end

  @doc "Who depends on the calendar."
  def usage_line(%{trip_count: 0}), do: "No trips use this calendar yet"

  def usage_line(%{trip_count: trips, routes: routes}) do
    "#{plural(trips, "trip")} on #{plural(length(routes), "route")} " <>
      "#{if trips == 1, do: "uses", else: "use"} this calendar"
  end

  defp days_phrase(calendar) do
    on =
      for {{field, name}, index} <- Enum.with_index(@weekdays),
          Map.fetch!(calendar, field) == 1,
          do: {index, name}

    indexes = Enum.map(on, &elem(&1, 0))
    names = Enum.map(on, &elem(&1, 1))

    cond do
      on == [] -> "no days of the week"
      length(on) == 7 -> "every day"
      length(on) == 1 -> "#{hd(names)} only"
      consecutive?(indexes) and length(on) == 2 -> Enum.join(names, " and ")
      consecutive?(indexes) -> "#{hd(names)} to #{List.last(names)}"
      true -> join_names(names)
    end
  end

  defp consecutive?(indexes), do: indexes == Enum.to_list(hd(indexes)..List.last(indexes))

  defp join_names(names) do
    {init, [last]} = Enum.split(names, -1)
    Enum.join(init, ", ") <> " and " <> last
  end

  ## Page head

  @doc """
  The breadcrumb, title, status word, summary lines and the calendar's own actions.
  """
  attr :list_path, :string, required: true
  attr :crumb, :string, required: true
  attr :heading, :string, required: true
  attr :badge, :any, default: nil, doc: "`{tone, label}` from `status/1`"
  attr :lede, :string, default: nil
  slot :meta
  slot :actions

  def editor_head(assigns) do
    ~H"""
    <div id="calendar-page-head" class="pb-6">
      <nav aria-label="Breadcrumb" class="flex min-h-11 items-center text-[13px] text-muted">
        <.link
          navigate={@list_path}
          class="inline-flex min-h-11 items-center text-muted underline-offset-4 hover:text-strong hover:underline"
        >
          Calendars
        </.link>
        <span aria-hidden="true" class="px-1">/</span>
        <span aria-current="page" class="min-w-0 break-words font-semibold text-strong">
          {@crumb}
        </span>
      </nav>

      <div class="mt-1 flex flex-wrap items-start justify-between gap-x-8 gap-y-4">
        <div class="min-w-0 max-w-[760px]">
          <div class="flex flex-wrap items-center gap-x-3 gap-y-2">
            <h1 id="calendar-title" class="break-words">{@heading}</h1>
            <.state_badge :if={@badge} badge={@badge} />
          </div>
          <p :if={@lede} id="calendar-lede" class="mt-3 text-[15px] leading-relaxed text-default">
            {@lede}
          </p>
          <p :if={@meta != []} id="calendar-meta" class="mt-1 text-[13px] text-muted">
            {render_slot(@meta)}
          </p>
        </div>
        <div :if={@actions != []} class="flex flex-wrap gap-2">{render_slot(@actions)}</div>
      </div>
    </div>
    """
  end

  attr :badge, :any, required: true

  defp state_badge(%{badge: {tone, label}} = assigns) do
    assigns = assign(assigns, tone: Map.fetch!(@badge_tones, tone), label: label)

    ~H"""
    <span
      id="calendar-badge"
      class={["inline-flex items-center rounded-badge px-2.5 py-1 text-[13px] font-semibold", @tone]}
    >
      {@label}
    </span>
    """
  end

  ## Schedule form pieces

  @doc "The two ways a calendar runs, as cards that say what each is for."
  attr :name, :string, required: true
  attr :kind, :string, required: true

  attr :dates_only_disabled, :boolean,
    default: false,
    doc: "true while the stored range is reversed, so converting would read its dates"

  def kind_cards(assigns) do
    ~H"""
    <fieldset id="calendar-kind" class="mt-6 min-w-0">
      <legend class="text-[13px] font-[650] text-strong">How does it run?</legend>
      <div class="mt-2 grid gap-3 sm:grid-cols-2">
        <label class={kind_card_class()}>
          <input
            type="radio"
            id="calendar-kind-weekly"
            name={@name}
            value="weekly"
            checked={@kind == "weekly"}
            class="mt-1 size-4 shrink-0 accent-action"
          />
          <span class="min-w-0">
            <span class="block text-sm font-semibold text-strong">Regular weekly service</span>
            <span class="mt-0.5 block text-[13px] leading-snug text-muted">
              The same days every week between two dates. Use it for weekday, Saturday or Sunday service.
            </span>
          </span>
        </label>
        <label class={kind_card_class()}>
          <input
            type="radio"
            id="calendar-kind-dates-only"
            name={@name}
            value="dates_only"
            checked={@kind == "dates_only"}
            disabled={@dates_only_disabled}
            aria-describedby={@dates_only_disabled && "calendar-range-error"}
            class="mt-1 size-4 shrink-0 accent-action"
          />
          <span class="min-w-0">
            <span class="block text-sm font-semibold text-strong">Only on chosen dates</span>
            <span class="mt-0.5 block text-[13px] leading-snug text-muted">
              Runs only on the dates you list. Use it for events and one-off service.
            </span>
          </span>
        </label>
      </div>
    </fieldset>
    """
  end

  defp kind_card_class do
    [
      "flex min-h-[84px] cursor-pointer gap-3 rounded-control border border-control bg-white p-3.5",
      "has-[:checked]:border-action has-[:checked]:bg-selection has-[:checked]:ring-1 has-[:checked]:ring-action",
      "has-[:focus-visible]:outline-2 has-[:focus-visible]:outline-offset-2 has-[:focus-visible]:outline-focus"
    ]
  end

  @doc """
  The seven service days as toggles, with quick sets for the common patterns.

  Each toggle is a native checkbox, so the form submits `calendar[weekdays][]`
  and the group is one `fieldset` that carries the error.
  """
  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :options, :list, required: true, doc: "`{label, value}` pairs, Monday first"
  attr :selected, :list, default: []
  attr :presets, :list, required: true, doc: "`{label, days}` pairs for the quick sets"
  attr :error, :string, default: nil

  def weekday_toggles(assigns) do
    assigns = assign(assigns, :invalid?, assigns.error not in [nil, ""])

    ~H"""
    <div>
      <div class="flex flex-wrap items-center justify-between gap-x-4">
        <span id={"#{@id}-label"} class="text-[13px] font-[650] text-strong">Service days</span>
        <div class="flex flex-wrap items-center gap-x-1 text-[13px] text-muted">
          <span>Quick set</span>
          <button
            :for={{label, _days} <- @presets}
            id={"calendar-preset-#{label |> String.downcase() |> String.replace(" ", "-")}"}
            type="button"
            phx-click="preset_days"
            phx-value-preset={label}
            class="inline-flex min-h-11 items-center rounded-control px-2 text-[13px] font-[650] text-action hover:underline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
          >
            {label}
          </button>
        </div>
      </div>
      <fieldset
        id={@id}
        aria-labelledby={"#{@id}-label"}
        aria-describedby={if(@invalid?, do: "#{@id}-error")}
        aria-invalid={to_string(@invalid?)}
        class="min-w-0"
      >
        <div class="grid grid-cols-7 gap-1 sm:flex sm:gap-1.5">
          <label :for={{label, value} <- @options} class="min-w-0">
            <input
              type="checkbox"
              id={"#{@id}-#{value}"}
              name={@name}
              value={value}
              checked={value in @selected}
              class="peer sr-only"
            />
            <span class={[
              "inline-flex min-h-11 w-full cursor-pointer items-center justify-center rounded-control border bg-white px-0 text-[13px] font-bold text-strong sm:min-w-[52px]",
              "hover:bg-canvas peer-checked:border-navy-800 peer-checked:bg-navy-800 peer-checked:text-white peer-checked:hover:bg-navy-800",
              "peer-focus-visible:outline-2 peer-focus-visible:outline-offset-2 peer-focus-visible:outline-focus",
              if(@invalid?, do: "border-error-line", else: "border-control")
            ]}>
              <span aria-hidden="true">{String.slice(label, 0, 3)}</span>
              <span class="sr-only">{label}</span>
            </span>
          </label>
        </div>
      </fieldset>
      <p
        :if={@invalid?}
        id={"#{@id}-error"}
        class="mt-2 flex items-start gap-1.5 text-[13px] font-semibold text-error-fg"
      >
        <.icon name="hero-exclamation-circle" class="mt-px size-4 shrink-0" />
        <span>{@error}</span>
      </p>
    </div>
    """
  end

  @doc """
  The sticky bottom row of the schedule card: what saving does, then Discard changes
  (only while the form differs from what is stored) and the one primary.
  """
  attr :live_action, :atom, required: true
  attr :dirty?, :boolean, required: true
  attr :pending?, :boolean, required: true
  attr :note, :string, required: true
  attr :list_path, :string, required: true

  def save_bar(assigns) do
    ~H"""
    <div
      id="calendar-save-bar"
      class="-mx-4 mt-6 flex flex-wrap items-center justify-between gap-x-6 gap-y-3 border-t border-subtle bg-white px-4 py-3 sm:sticky sm:bottom-0 sm:z-10 sm:-mx-5 sm:flex-nowrap sm:px-5"
    >
      <p
        id="calendar-save-note"
        class="w-full min-w-0 text-[13px] leading-snug text-muted sm:w-auto sm:flex-1"
      >
        {@note}
      </p>
      <div class="flex shrink-0 flex-wrap items-center gap-3">
        <.button
          :if={@live_action == :show and @dirty?}
          id="calendar-discard"
          type="button"
          variant="secondary"
          class="min-h-11"
          phx-click="ask_discard"
        >
          Discard changes
        </.button>
        <.button
          :if={@live_action == :new}
          id="calendar-cancel"
          variant="secondary"
          class="min-h-11"
          navigate={@list_path}
        >
          Cancel
        </.button>
        <.button
          id="calendar-save"
          type="submit"
          class="min-h-11"
          disabled={@pending?}
          phx-disable-with={if(@live_action == :new, do: "Creating…", else: "Saving…")}
        >
          {if @live_action == :new, do: "Create calendar", else: "Save calendar"}
        </.button>
      </div>
    </div>
    """
  end

  ## Service preview

  @doc """
  One read-only month of the days the calendar runs, beside the form.

  The grid is built from the stored schedule plus any unsaved schedule fields, so
  it updates while the form is edited. The container takes the keyboard: the left
  and right arrows move a month and Home returns to today.
  """
  attr :month_grid, :map, required: true
  attr :kind, :string, required: true, doc: "the previewed kind: `weekly` or `dates_only`"
  attr :dirty?, :boolean, required: true
  attr :today, :any, required: true

  def preview_card(assigns) do
    weekly? = assigns.kind == "weekly"

    assigns =
      assigns
      |> assign(:weekly?, weekly?)
      |> assign(:weeks, effective_weeks(assigns.month_grid.weeks, weekly?))
      |> assign(:cell_tones, @cell_tones)
      |> assign(:weekdays, Enum.map(@weekdays, &elem(&1, 1)))

    ~H"""
    <aside
      id="calendar-preview"
      aria-labelledby="calendar-preview-title"
      class="min-w-0 overflow-hidden rounded-card border border-subtle bg-white lg:sticky lg:top-4 lg:col-start-2 lg:row-span-3 lg:row-start-1 lg:self-start"
    >
      <div class="border-b border-subtle bg-canvas px-4 py-4 sm:px-5">
        <h2
          id="calendar-preview-title"
          class="text-lg font-bold leading-snug tracking-[-0.01em] text-strong"
        >
          Service preview
        </h2>
        <p id="calendar-preview-intro" class="mt-0.5 text-[13px] text-muted">
          {if @dirty?,
            do: "Includes your unsaved changes.",
            else: "Days when trips on this calendar run."}
        </p>
      </div>
      <div class="px-3 py-4 sm:px-5">
        <div class="flex items-center justify-between gap-2">
          <div class="flex items-center gap-1.5">
            <button
              id="calendar-preview-prev"
              type="button"
              phx-click="preview_step"
              phx-value-step="prev"
              aria-label="Show the previous month"
              class={month_button_class()}
            >
              <.icon name="hero-chevron-left" class="size-4" />
            </button>
            <button
              id="calendar-preview-next"
              type="button"
              phx-click="preview_step"
              phx-value-step="next"
              aria-label="Show the next month"
              class={month_button_class()}
            >
              <.icon name="hero-chevron-right" class="size-4" />
            </button>
          </div>
          <strong id="calendar-preview-month" class="text-base font-bold text-strong">
            {@month_grid.title}
          </strong>
          <button
            id="calendar-preview-today"
            type="button"
            phx-click="preview_step"
            phx-value-step="today"
            class="inline-flex min-h-11 items-center justify-center rounded-control border border-control bg-white px-3.5 text-sm font-[650] text-strong hover:bg-canvas focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
          >
            Today
          </button>
        </div>

        <div
          id="months"
          tabindex="0"
          role="group"
          aria-label={"Service preview for #{@month_grid.title}"}
          phx-keydown="preview_keys"
          class="mt-3 rounded-control focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
        >
          <table
            id={"months-#{@month_grid.year}-#{@month_grid.month}"}
            class="w-full table-fixed border-separate border-spacing-0.5"
          >
            <caption class="sr-only">{@month_grid.title}</caption>
            <thead>
              <tr>
                <th
                  :for={day <- @weekdays}
                  scope="col"
                  class="pb-1 text-center text-[13px] font-semibold text-muted"
                >
                  <span aria-hidden="true">{String.slice(day, 0, 3)}</span>
                  <span class="sr-only">{day}</span>
                </th>
              </tr>
            </thead>
            <tbody>
              <tr :for={week <- @weeks}>
                <td
                  :for={cell <- week}
                  id={cell && "month-cell-#{Date.to_iso8601(cell.date)}"}
                  aria-label={cell && cell_label(cell, @today)}
                  class="p-0"
                >
                  <span
                    :if={cell}
                    class={[
                      "relative flex min-h-11 w-full items-center justify-center rounded-control text-sm tabular-nums",
                      Map.fetch!(@cell_tones, cell.state)
                    ]}
                  >
                    {cell.day}
                    <span
                      :if={cell.state in [:removed, :added]}
                      aria-hidden="true"
                      class="absolute right-1 top-0.5 text-[11px] font-bold leading-none"
                    >
                      {if cell.state == :removed, do: "×", else: "+"}
                    </span>
                    <span
                      :if={cell.date == @today}
                      aria-hidden="true"
                      class="absolute bottom-1 left-1/2 size-1 -translate-x-1/2 rounded-full bg-strong"
                    >
                    </span>
                  </span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
        <p id="preview-date-status" class="mt-2 text-[13px] text-muted">
          Click the preview, then use the left and right arrow keys to change month.
        </p>

        <ul
          id="months-legend"
          aria-label="Legend"
          class="mt-4 flex flex-wrap gap-x-4 gap-y-1.5 text-[13px] text-default"
        >
          <li class="inline-flex items-center gap-1.5">
            <span aria-hidden="true" class="inline-flex size-5 rounded-badge bg-soft"></span>Runs
          </li>
          <li :if={@weekly?} class="inline-flex items-center gap-1.5">
            <span
              aria-hidden="true"
              class="inline-flex size-5 items-center justify-center rounded-badge border border-warning-line bg-warning-bg text-[11px] font-bold text-warning-fg"
            >
              ×
            </span>Day off
          </li>
          <li :if={@weekly?} class="inline-flex items-center gap-1.5">
            <span
              aria-hidden="true"
              class="inline-flex size-5 items-center justify-center rounded-badge border border-action-hover bg-selection text-[11px] font-bold text-action-hover"
            >
              +
            </span>Extra service
          </li>
          <li class="inline-flex items-center gap-1.5">
            <span aria-hidden="true" class="inline-flex size-5 rounded-badge border border-subtle">
            </span>Not a service day
          </li>
          <li class="inline-flex items-center gap-1.5">
            <span aria-hidden="true" class="inline-flex size-5 items-center justify-center">
              <span class="size-1.5 rounded-full bg-strong"></span>
            </span>Today
          </li>
        </ul>
      </div>
    </aside>
    """
  end

  defp month_button_class do
    "inline-flex size-11 items-center justify-center rounded-control border border-control bg-white text-strong hover:bg-canvas focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
  end

  # A chosen-dates calendar has no regular days, so an added date is simply a day it
  # runs, not extra service.
  defp effective_weeks(weeks, true), do: weeks

  defp effective_weeks(weeks, false),
    do: Enum.map(weeks, fn week -> Enum.map(week, &added_as_service/1) end)

  defp added_as_service(%{state: :added} = cell), do: %{cell | state: :service}
  defp added_as_service(cell), do: cell

  defp cell_label(cell, today) do
    base = "#{weekday_date(cell.date)}: #{Map.fetch!(@cell_words, cell.state)}"
    if cell.date == today, do: base <> ", today", else: base
  end

  ## Days off and extra service

  @doc """
  The whole schedule on one axis: regular service, breaks, days off, extra service
  and today, drawn from the derived periods so it cannot disagree with the list.
  """
  attr :calendar, :any, default: nil
  attr :kind, :atom, required: true
  attr :periods, :map, required: true
  attr :active_dates, :list, required: true
  attr :today, :any, required: true
  attr :list_path, :string, required: true

  def service_strip(assigns) do
    assigns = assign(assigns, :strip, strip(assigns))

    ~H"""
    <div :if={@strip} id="periods" class="@container mb-6">
      <div id="periods-timeline" role="img" aria-label={@strip.label}>
        <div class="relative mt-4 h-9">
          <span
            :for={bar <- @strip.bars}
            id={bar.id}
            title={bar.title}
            class={bar.class}
            style={bar.style}
          >
          </span>
          <span
            :for={tick <- @strip.marks}
            class={tick.class}
            style={tick.style}
            title={tick.title}
          >
          </span>
          <span
            :if={@strip.today}
            class="absolute top-0 h-9 w-0.5 bg-strong"
            style={@strip.today}
          >
          </span>
          <span
            :if={@strip.today}
            class="absolute -translate-x-1/2 whitespace-nowrap rounded-badge bg-strong px-1 text-[11px] font-semibold leading-4 text-white"
            style={@strip.today <> ";top:-16px"}
          >
            Today
          </span>
        </div>
        <div class="relative mt-1 h-5">
          <span
            :for={tick <- @strip.axis}
            class={[
              "absolute top-0 h-3.5 whitespace-nowrap border-l border-subtle pl-1 text-[12px] leading-4 text-muted",
              tick.thin? && "hidden @min-[34rem]:block"
            ]}
            style={tick.style}
          >
            {tick.label}
          </span>
        </div>
      </div>

      <ul
        id="periods-legend"
        aria-label="Timeline legend"
        class="mt-2 flex flex-wrap gap-x-4 gap-y-1.5 text-[13px] text-default"
      >
        <li class="inline-flex items-center gap-1.5">
          <span aria-hidden="true" class="h-3 w-5 rounded-badge bg-cyan-700"></span>{service_word(
            @kind
          )}
        </li>
        <li :if={@kind == :weekly} class="inline-flex items-center gap-1.5">
          <span
            aria-hidden="true"
            class="h-3 w-5 rounded-badge border-2 border-dashed border-warning-line bg-warning-bg"
          >
          </span>Break
        </li>
        <li :if={@kind == :weekly} class="inline-flex items-center gap-1.5">
          <span aria-hidden="true" class="h-4 w-[3px] rounded-badge bg-warning-line"></span>Day off
        </li>
        <li :if={@kind == :weekly} class="inline-flex items-center gap-1.5">
          <span aria-hidden="true" class="h-4 w-[3px] rounded-badge bg-action"></span>Extra service
        </li>
        <li :if={@strip.today} class="inline-flex items-center gap-1.5">
          <span aria-hidden="true" class="h-4 w-0.5 bg-strong"></span>Today
        </li>
      </ul>

      <p
        :if={@periods.breaks != []}
        id="periods-gaps"
        phx-no-format
        class="mt-3 text-[13px] text-muted"
      >{gap_sentence(@periods.breaks)} Check that another calendar covers those dates, or riders have no service then. <.link navigate={@list_path} class="font-[650] text-action underline underline-offset-2">See gaps in Calendars</.link></p>
    </div>
    """
  end

  defp service_word(:weekly), do: "Regular service"
  defp service_word(_kind), do: "Service date"

  defp gap_sentence(breaks) do
    breaks
    |> Enum.map_join(". ", fn interval ->
      "No service #{date_span(interval.first_date, interval.last_date)} (#{plural(interval.service_days, "service day")})"
    end)
    |> Kernel.<>(".")
  end

  # Bars are placed by civil-day offset inside the whole span, so a long schedule is
  # drawn whole instead of clipped to a window. A single day keeps a visible width.
  defp strip(%{kind: :weekly, calendar: %{start_date: first, end_date: last}} = assigns) do
    extra = assigns.periods.extra_days

    lo = Enum.min([first | extra], Date)
    hi = Enum.max([last | extra], Date)
    geometry = geometry(lo, hi)

    period_bars =
      Enum.map(assigns.periods.periods, fn interval ->
        %{
          id: "periods-segment-period-#{interval.first_date}",
          title: "#{date_span(interval.first_date, interval.last_date)} · regular service",
          class: "absolute top-4 h-3.5 rounded-badge bg-cyan-700",
          style: span_style(geometry, interval.first_date, interval.last_date),
          sort: interval.first_date,
          rank: 0
        }
      end)

    break_bars =
      Enum.map(assigns.periods.breaks, fn interval ->
        %{
          id: "periods-segment-break-#{interval.first_date}",
          title: "#{date_span(interval.first_date, interval.last_date)} · break",
          class:
            "absolute top-4 h-3.5 rounded-badge border-2 border-dashed border-warning-line bg-warning-bg",
          style: span_style(geometry, interval.first_date, interval.last_date),
          sort: interval.first_date,
          rank: 1
        }
      end)

    bars =
      (period_bars ++ break_bars)
      |> Enum.sort_by(&{Date.to_erl(&1.sort), &1.rank})
      |> Enum.map(&Map.take(&1, [:id, :title, :class, :style]))

    marks =
      Enum.map(assigns.periods.holidays, &mark(geometry, &1, "bg-warning-line", "Day off")) ++
        Enum.map(extra, &mark(geometry, &1, "bg-action", "Extra service"))

    periods = assigns.periods

    label =
      "Service from #{format_date(first)} to #{format_date(last)}: " <>
        Enum.join(
          [
            plural(length(periods.periods), "period"),
            plural(length(periods.breaks), "break"),
            plural(
              length(periods.holidays) + length(other_days_off(periods)),
              "day off",
              "days off"
            ),
            plural(length(extra), "extra service day")
          ],
          ", "
        ) <> "."

    %{
      bars: bars,
      marks: marks,
      axis: axis(lo, hi),
      today: today_style(geometry, assigns.today),
      label: label
    }
  end

  defp strip(%{kind: :dates_only, active_dates: [first | _] = dates} = assigns) do
    last = List.last(dates)
    geometry = geometry(first, last)

    bars =
      Enum.map(dates, fn date ->
        %{
          id: "periods-segment-date-#{date}",
          title: format_date(date),
          class: "absolute top-4 h-3.5 rounded-badge bg-cyan-700",
          style: span_style(geometry, date, date)
        }
      end)

    %{
      bars: bars,
      marks: [],
      axis: axis(first, last),
      today: today_style(geometry, assigns.today),
      label:
        "Service on #{plural(length(dates), "chosen date")} from #{format_date(first)} to #{format_date(last)}."
    }
  end

  defp strip(_assigns), do: nil

  defp geometry(lo, hi), do: %{lo: lo, total: Date.diff(hi, lo) + 1}

  defp left_percent(%{lo: lo, total: total}, date), do: Date.diff(date, lo) / total * 100

  defp width_percent(%{total: total}, first, last),
    do: max((Date.diff(last, first) + 1) / total * 100, 0.35)

  defp span_style(geometry, first, last),
    do:
      "left: #{pct(left_percent(geometry, first))}; width: #{pct(width_percent(geometry, first, last))}"

  defp mark(geometry, date, color, title) do
    %{
      class: "absolute top-2.5 h-[26px] w-[3px] rounded-badge #{color}",
      style: "left: #{pct(left_percent(geometry, date))}",
      title: "#{weekday_date(date)} · #{title}"
    }
  end

  defp today_style(%{lo: lo, total: total} = geometry, %Date{} = today) do
    if Date.compare(today, lo) != :lt and Date.diff(today, lo) < total,
      do: "left: #{pct(left_percent(geometry, today))}"
  end

  defp pct(value), do: "#{Float.round(value * 1.0, 3)}%"

  # A short span labels its two ends; a long one labels month starts. Labels thin out
  # by how many months there are, and a narrow container shows only every other
  # thinned label so the axis never collides with itself.
  defp axis(date, date),
    do: [%{style: "left: 0", label: Calendar.strftime(date, @short_format), thin?: false}]

  defp axis(lo, hi) do
    geometry = geometry(lo, hi)

    if geometry.total <= 62 do
      [
        %{style: "left: 0", label: Calendar.strftime(lo, @short_format), thin?: false},
        %{
          style: "left: 100%; transform: translateX(-100%)",
          label: Calendar.strftime(hi, @short_format),
          thin?: false
        }
      ]
    else
      months = month_starts(lo, hi)
      stride = max(div(length(months) + 11, 12), 1)

      months
      |> Enum.with_index()
      |> Enum.filter(fn {_month, index} -> rem(index, stride) == 0 end)
      |> Enum.with_index()
      |> Enum.map(fn {{month, _index}, shown} ->
        january? = month.month == 1

        %{
          style: "left: #{pct(max(left_percent(geometry, max_date(month, lo)), 0.0))}",
          label:
            if(january? or shown == 0,
              do: Calendar.strftime(month, "%b %Y"),
              else: Calendar.strftime(month, "%b")
            ),
          thin?: rem(shown, 2) == 1
        }
      end)
    end
  end

  defp max_date(a, b), do: if(Date.compare(a, b) == :lt, do: b, else: a)

  defp month_starts(lo, hi) do
    first = Date.beginning_of_month(lo)

    first
    |> Stream.iterate(&(&1 |> Date.end_of_month() |> Date.add(1)))
    |> Enum.take_while(&(Date.compare(&1, hi) != :gt))
    |> Enum.reject(&(Date.compare(&1, lo) == :lt and Date.diff(lo, &1) > 15))
  end

  # Removals on days the calendar does not run (they change nothing) are still days
  # off in the person's list, so the summary counts them with the holidays.
  defp other_days_off(periods) do
    holidays = MapSet.new(periods.holidays)
    Enum.reject(periods.removed_days, &MapSet.member?(holidays, &1))
  end

  @doc """
  The stored date changes in date order: each break once, with the dates inside it one
  disclosure away, and every other change on its own row.
  """
  attr :kind, :atom, required: true
  attr :calendar, :any, default: nil
  attr :periods, :map, required: true
  attr :exceptions, :list, required: true
  attr :warnings, :list, required: true
  attr :editable, :boolean, default: true, doc: "false hides the buttons that remove a change"

  def change_list(assigns) do
    rows = change_rows(assigns.kind, assigns.periods.breaks, assigns.exceptions)
    notes = row_notes(assigns.warnings)

    assigns =
      assigns
      |> assign(:rows, rows)
      |> assign(:notes, notes)
      |> assign(:summary, change_summary(assigns.kind, assigns.periods, assigns.exceptions, rows))

    ~H"""
    <div id="calendar-exceptions">
      <div
        :if={@rows == []}
        id="calendar-changes-empty"
        class="rounded-control border border-dashed border-control px-5 py-8 text-center"
      >
        <h3 class="text-base font-bold text-strong">
          {if @kind == :weekly, do: "No days off or extra service yet", else: "No service dates yet"}
        </h3>
        <p class="mx-auto mt-1 max-w-[52ch] text-sm text-muted">
          <%= if @kind == :weekly do %>
            This calendar runs every regular service day between its start and end dates. Add the holidays and breaks when trips shouldn’t run.
          <% else %>
            Trips on this calendar don’t run on any day until you add dates. Pick a date above and choose Add service date.
          <% end %>
        </p>
      </div>

      <div :if={@rows != []}>
        <p id="calendar-changes-summary" class="mb-1 text-[13px] font-semibold text-strong">
          {@summary}
        </p>
        <table class="w-full text-left text-sm">
          <caption class="sr-only">
            {if @kind == :weekly, do: "Days off and extra service", else: "Service dates"}
          </caption>
          <thead>
            <tr class="text-[13px] font-semibold text-default">
              <th scope="col" class="pb-2 pr-3 font-semibold">Date</th>
              <th scope="col" class="hidden pb-2 pr-3 font-semibold sm:table-cell">Service</th>
              <th scope="col" class="pb-2 text-right font-semibold">
                <span class="sr-only">Actions</span>
              </th>
            </tr>
          </thead>
          <tbody>
            <%= for row <- @rows do %>
              <.break_row :if={row.kind == :break} row={row} editable={@editable} />
              <.day_row
                :if={row.kind == :day}
                entry={row.entry}
                weekly?={@kind == :weekly}
                note={Map.get(@notes, row.entry.date)}
                editable={@editable}
              />
            <% end %>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  attr :row, :map, required: true
  attr :editable, :boolean, default: true

  defp break_row(assigns) do
    ~H"""
    <tr id={"calendar-break-#{@row.first_date}"} class="border-t border-subtle align-top">
      <td class="py-3 pr-3">
        <span class="block font-semibold text-strong">
          {date_span(@row.first_date, @row.last_date)}
        </span>
        <span class="block text-[13px] text-muted">
          Break · {plural(@row.service_days, "service day")} without service
        </span>
        <span class="mt-1 block sm:hidden">
          <.change_badge tone={:warning}>No service</.change_badge>
        </span>
        <details
          :if={@row.dates != []}
          id={"calendar-break-dates-#{@row.first_date}"}
          phx-mounted={JS.ignore_attributes("open")}
          class="group mt-0.5"
        >
          <summary class="inline-flex min-h-11 cursor-pointer list-none items-center gap-1.5 text-[13px] font-semibold text-strong [&::-webkit-details-marker]:hidden">
            <.icon
              name="hero-chevron-right"
              class="size-3.5 text-muted transition-transform group-open:rotate-90 motion-reduce:transition-none"
            /> Show the {length(@row.dates)} dates
          </summary>
          <ul class="mb-2 ml-1 grid gap-0.5 border-l border-subtle pl-3">
            <li
              :for={date <- @row.dates}
              id={"calendar-exception-chips-#{date}"}
              class="flex flex-wrap items-center justify-between gap-2 text-[13px]"
            >
              <span>{weekday_date(date)}</span>
              <button
                :if={@editable}
                id={"calendar-exception-chips-remove-#{date}"}
                type="button"
                phx-click="remove_date"
                phx-value-date={Date.to_iso8601(date)}
                class={link_button_class()}
              >
                Restore service<span class="sr-only"> on {format_date(date)}</span>
              </button>
            </li>
          </ul>
        </details>
      </td>
      <td class="hidden whitespace-nowrap py-3 pr-3 sm:table-cell">
        <.change_badge tone={:warning}>No service</.change_badge>
      </td>
      <td class="whitespace-nowrap py-1 text-right">
        <button
          :if={@editable}
          id={"periods-remove-break-break-#{@row.first_date}"}
          type="button"
          phx-click="remove_break"
          phx-value-dates={Enum.map_join(@row.dates, ",", &Date.to_iso8601/1)}
          class={link_button_class()}
        >
          Restore service<span class="sr-only"> for the break {date_span(@row.first_date, @row.last_date)}</span>
        </button>
      </td>
    </tr>
    """
  end

  attr :entry, :map, required: true
  attr :weekly?, :boolean, required: true
  attr :note, :string, default: nil
  attr :editable, :boolean, default: true

  defp day_row(assigns) do
    assigns = assign(assigns, :removed?, assigns.entry.exception_type == 2)

    ~H"""
    <tr id={"calendar-exception-chips-#{@entry.date}"} class="border-t border-subtle align-top">
      <td class="py-3 pr-3">
        <span class="block font-semibold text-strong">{weekday_date(@entry.date)}</span>
        <span :if={@note} class="mt-1 flex items-start gap-1 text-[13px] text-warning-fg">
          <.icon name="hero-exclamation-triangle" class="mt-0.5 size-3.5 shrink-0" />
          <span>{@note}</span>
        </span>
        <span class="mt-1 block sm:hidden">
          <.day_state removed?={@removed?} weekly?={@weekly?} />
        </span>
      </td>
      <td class="hidden whitespace-nowrap py-3 pr-3 sm:table-cell">
        <.day_state removed?={@removed?} weekly?={@weekly?} />
      </td>
      <td class="whitespace-nowrap py-1 text-right">
        <button
          :if={@editable}
          id={"calendar-exception-chips-remove-#{@entry.date}"}
          type="button"
          phx-click="remove_date"
          phx-value-date={Date.to_iso8601(@entry.date)}
          class={link_button_class()}
        >
          {cond do
            @removed? -> "Restore service"
            @weekly? -> "Remove extra service"
            true -> "Remove date"
          end}<span class="sr-only"> on {format_date(@entry.date)}</span>
        </button>
      </td>
    </tr>
    """
  end

  attr :removed?, :boolean, required: true
  attr :weekly?, :boolean, required: true

  defp day_state(assigns) do
    ~H"""
    <.change_badge :if={@removed?} tone={:warning}>No service</.change_badge>
    <.change_badge :if={not @removed? and @weekly?} tone={:info}>Extra service</.change_badge>
    <.change_badge :if={not @removed? and not @weekly?} tone={:info}>Runs</.change_badge>
    """
  end

  attr :tone, :atom, values: [:warning, :info], required: true
  slot :inner_block, required: true

  defp change_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center rounded-badge px-2 py-1 text-[13px] font-semibold",
      if(@tone == :warning, do: "bg-warning-bg text-warning-fg", else: "bg-info-bg text-info-fg")
    ]}>
      {render_slot(@inner_block)}
    </span>
    """
  end

  defp link_button_class do
    "inline-flex min-h-11 items-center rounded-control px-2 text-[13px] font-[650] text-action hover:underline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
  end

  # Breaks come from the derived periods; the removals inside one are its restore
  # dates. Every other stored change is its own row, so no stored row is hidden.
  defp change_rows(kind, breaks, exceptions) do
    break_rows =
      if kind == :weekly, do: Enum.map(breaks, &break_row_data(&1, exceptions)), else: []

    day_rows =
      for entry <- exceptions,
          not (entry.exception_type == 2 and in_any_break?(entry.date, break_rows)),
          do: %{kind: :day, sort: entry.date, entry: entry}

    Enum.sort_by(break_rows ++ day_rows, &Date.to_erl(&1.sort))
  end

  defp break_row_data(interval, exceptions) do
    dates =
      for %{exception_type: 2, date: date} <- exceptions,
          in_interval?(date, interval),
          do: date

    %{
      kind: :break,
      sort: interval.first_date,
      first_date: interval.first_date,
      last_date: interval.last_date,
      service_days: interval.service_days,
      dates: Enum.sort(dates, Date)
    }
  end

  defp in_interval?(date, %{first_date: first, last_date: last}),
    do: Date.compare(date, first) != :lt and Date.compare(date, last) != :gt

  defp in_any_break?(date, break_rows), do: Enum.any?(break_rows, &in_interval?(date, &1))

  defp change_summary(:weekly, periods, exceptions, rows) do
    removed_outside =
      Enum.count(exceptions, fn entry ->
        entry.exception_type == 2 and
          not Enum.any?(rows, &(&1.kind == :break and in_interval?(entry.date, &1)))
      end)

    Enum.join(
      [
        plural(removed_outside, "day off", "days off"),
        plural(length(periods.breaks), "break"),
        plural(length(periods.extra_days), "extra service day")
      ],
      " · "
    )
  end

  defp change_summary(:dates_only, _periods, exceptions, _rows),
    do: plural(length(exceptions), "service date")

  # A stored change can be redundant or outside the range; the row says so where the
  # person is looking, and the page summary says how many there are.
  defp row_notes(warnings) do
    for %{date: date} = warning <- warnings, into: %{} do
      {date, row_note(warning, date)}
    end
  end

  defp row_note(%{reason: :redundant_addition}, _date),
    do: "No effect: this day already runs on the regular schedule."

  defp row_note(%{reason: :removal_on_nonservice_day}, date),
    do: "No effect: this calendar doesn’t run on #{weekday_name(date)}s."

  defp row_note(%{reason: :outside_range, exception: :added}, _date),
    do: "Outside the regular dates. Stored as its own change."

  defp row_note(%{reason: :outside_range}, _date),
    do: "No effect: outside the regular dates."

  defp weekday_name(date) do
    {_field, name} = Enum.at(@weekdays, Date.day_of_week(date) - 1)
    name
  end

  ## Warnings and reviews

  @doc """
  One plain sentence for a stored or reviewed warning.

  `kind` is the calendar's kind after the change under review; `range` is the weekly
  range as text when the caller knows it, or `nil` inside a review that is about to
  change it.
  """
  def warning_line(warning, kind, range \\ nil)

  def warning_line(%{reason: :ended, last_date: date}, kind, _range) do
    "This calendar ended on #{format_date(date)}, so its trips no longer run. " <>
      if(kind == :weekly,
        do: "Extend the end date to bring service back.",
        else: "Add service dates to bring it back."
      )
  end

  def warning_line(%{reason: :ends_soon, last_date: date, days_remaining: days}, kind, _range) do
    lead =
      if days == 0,
        do: "Ends today, on #{format_date(date)}.",
        else: "Ends in #{plural(days, "day")}, on #{format_date(date)}."

    lead <>
      if(kind == :weekly,
        do: " Extend the end date, or make sure another calendar takes over.",
        else: " Add more dates, or make sure another calendar takes over."
      )
  end

  def warning_line(%{reason: :no_service}, _kind, _range),
    do: "No service days. Choose service days and dates, or add service dates."

  def warning_line(%{reason: :redundant_addition, date: date}, _kind, _range),
    do:
      "#{weekday_date(date)} already runs on the regular schedule, so the extra service changes nothing."

  def warning_line(%{reason: :removal_on_nonservice_day, date: date}, _kind, _range),
    do:
      "#{weekday_date(date)} isn’t a service day for this calendar, so removing service that day changes nothing."

  def warning_line(%{reason: :outside_range, exception: :added, date: date}, _kind, range),
    do:
      "#{weekday_date(date)} is outside the regular dates#{range_suffix(range)}. It runs only because it is stored as its own change."

  def warning_line(%{reason: :outside_range, date: date}, _kind, range),
    do:
      "#{weekday_date(date)} is outside the regular dates#{range_suffix(range)}, so this day off changes nothing."

  def warning_line(%{reason: reason}, _kind, _range), do: to_string(reason)

  defp range_suffix(nil), do: ""
  defp range_suffix(range), do: " (#{range})"

  @doc "The warnings a person can act on; a break's coverage gap is stated under the strip."
  def actionable(warnings), do: Enum.reject(warnings, &(&1.reason == :coverage_gap))

  @doc """
  The warnings worth repeating inside a review dialog: what the change would leave
  with no effect or outside the regular range.
  """
  def review_warnings(warnings) do
    Enum.filter(
      warnings,
      &(&1.reason in [
          :outside_range,
          :no_service,
          :redundant_addition,
          :removal_on_nonservice_day
        ])
    )
  end

  @doc "The weekly range as text, or `nil` for a calendar with no weekly row."
  def range_label(%{start_date: first, end_date: last}), do: date_span(first, last)
  def range_label(_calendar), do: nil

  ## Trips

  @doc """
  The routes whose trips use this calendar, busiest first, and the reason a calendar
  with trips cannot be deleted.
  """
  attr :usage, :map, required: true
  attr :version_id, :any, required: true

  def trips_card(assigns) do
    routes = Enum.sort_by(assigns.usage.routes, &{-&1.trip_count, &1.route_id})
    {shown, rest} = Enum.split(routes, @visible_routes)

    assigns = assign(assigns, shown: shown, rest: rest, trips: assigns.usage.trip_count)

    ~H"""
    <section
      id="calendar-trips"
      aria-labelledby="calendar-trips-title"
      class="min-w-0 overflow-hidden rounded-card border border-subtle bg-white lg:col-start-1"
    >
      <div class="border-b border-subtle bg-canvas px-4 py-4 sm:px-5">
        <h2
          id="calendar-trips-title"
          tabindex="-1"
          class="text-lg font-bold leading-snug tracking-[-0.01em] text-strong"
        >
          Trips that use this calendar
        </h2>
        <p class="mt-0.5 text-[13px] text-muted">
          {if @trips > 0,
            do:
              "#{plural(@trips, "trip")} on #{plural(length(@usage.routes), "route")}. Editing this calendar changes service for all of them.",
            else: "Nothing runs on this calendar yet."}
        </p>
      </div>
      <div id="calendar-usage" class="px-4 py-2 sm:px-5">
        <div :if={@trips == 0 or @usage.routes == []} class="px-2 py-8 text-center">
          <h3 class="text-base font-bold text-strong">No trips use this calendar</h3>
          <p class="mx-auto mt-1 max-w-[52ch] text-sm text-muted">
            Open a route’s schedule and choose this calendar for its trips. A calendar with no trips can be deleted.
          </p>
          <div class="mt-4">
            <.button
              id="calendar-open-routes"
              variant="secondary"
              class="min-h-11"
              navigate={"/gtfs/#{@version_id}/routes"}
            >
              Open routes
            </.button>
          </div>
        </div>

        <div :if={@trips > 0 and @usage.routes != []}>
          <.route_table
            routes={@shown}
            version_id={@version_id}
            caption="Routes that use this calendar"
          />
          <details
            :if={@rest != []}
            id="calendar-usage-more"
            phx-mounted={JS.ignore_attributes("open")}
            class="group"
          >
            <summary class={[
              link_button_class(),
              "cursor-pointer list-none [&::-webkit-details-marker]:hidden"
            ]}>
              <span class="group-open:hidden">
                Show {length(@rest)} more {if length(@rest) == 1, do: "route", else: "routes"}
              </span>
              <span class="hidden group-open:inline">Show fewer routes</span>
            </summary>
            <.route_table
              routes={@rest}
              version_id={@version_id}
              caption="More routes that use this calendar"
              head?={false}
            />
          </details>
          <p class="mb-2 mt-3 border-t border-subtle pt-3 text-[13px] text-muted">
            A calendar that trips use can’t be deleted. Move its trips to another calendar first.
          </p>
        </div>
      </div>
    </section>
    """
  end

  attr :routes, :list, required: true
  attr :version_id, :any, required: true
  attr :caption, :string, required: true
  attr :head?, :boolean, default: true

  defp route_table(assigns) do
    ~H"""
    <table class="w-full text-left text-sm">
      <caption class="sr-only">{@caption}</caption>
      <thead :if={@head?}>
        <tr class="text-[13px] font-semibold text-default">
          <th scope="col" class="py-2 pr-3 font-semibold">Route</th>
          <th scope="col" class="py-2 text-right font-semibold">Trips</th>
        </tr>
      </thead>
      <tbody>
        <tr :for={route <- @routes} class="border-t border-subtle">
          <td class="py-0 pr-3">
            <.link
              id={"calendar-usage-route-#{route.route_id}"}
              navigate={"/gtfs/#{@version_id}/routes/#{route.route_id}"}
              class="inline-flex min-h-11 items-center font-semibold text-action underline-offset-4 hover:underline"
            >
              {route.route_id}
            </.link>
          </td>
          <td class="py-0 text-right tabular-nums">{route.trip_count}</td>
        </tr>
      </tbody>
    </table>
    """
  end

  ## Loading

  @doc "The loading state mirrors both columns of the editor."
  def loading(assigns) do
    ~H"""
    <section
      id="calendar-loading"
      aria-busy="true"
      aria-label="Loading calendar"
      class="mt-2 grid gap-6 motion-safe:animate-pulse lg:grid-cols-[minmax(0,1fr)_420px]"
    >
      <div class="grid gap-6">
        <div class="rounded-card border border-subtle">
          <div class="border-b border-subtle bg-canvas px-5 py-4">
            <div class="h-5 w-40 rounded-badge bg-navy-100"></div>
            <div class="mt-2 h-3 w-64 rounded-badge bg-canvas"></div>
          </div>
          <div class="grid gap-5 px-5 py-6">
            <div class="h-11 w-full max-w-[480px] rounded-control bg-canvas"></div>
            <div class="grid gap-3 sm:grid-cols-2">
              <div class="h-[84px] rounded-control bg-canvas"></div>
              <div class="h-[84px] rounded-control bg-canvas"></div>
            </div>
            <div class="grid gap-3 sm:grid-cols-2">
              <div class="h-11 max-w-[220px] rounded-control bg-canvas"></div>
              <div class="h-11 max-w-[220px] rounded-control bg-canvas"></div>
            </div>
          </div>
        </div>
        <div class="h-48 rounded-card border border-subtle bg-canvas"></div>
      </div>
      <div class="h-[440px] rounded-card border border-subtle bg-canvas"></div>
      <p class="text-sm text-muted lg:col-span-2" role="status">Loading calendar…</p>
    </section>
    """
  end

  ## Outcome messages

  @doc """
  An outcome the calendar editor reports in place: the title says what happened and
  the optional second line what to do or what remains. Errors are announced at once;
  successes are a polite status. Both keep the ids the editor's tests and hooks use.
  """
  attr :kind, :string, values: ~w(success error), required: true
  attr :outcome, :any, required: true, doc: "a title, or `{title, body}`"

  def outcome(assigns) do
    {title, body} =
      case assigns.outcome do
        {title, body} -> {title, body}
        title -> {title, nil}
      end

    assigns = assign(assigns, title: title, body: body, id: outcome_id(assigns.kind))

    ~H"""
    <.message :if={is_nil(@body)} id={@id} kind={@kind} title={@title} tabindex="-1" />
    <.message :if={@body} id={@id} kind={@kind} title={@title} tabindex="-1">{@body}</.message>
    """
  end

  defp outcome_id("success"), do: "calendar-status"
  defp outcome_id("error"), do: "calendar-error"
end
