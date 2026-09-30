defmodule GtfsPlannerWeb.Gtfs.ScheduleComponents do
  @moduledoc """
  Presentation for the route Schedules page, drawn in the TransitOps application
  design system.

  Every component here renders data the scoped read already loaded through
  `GtfsPlanner.Gtfs.load_route_schedule/4`: the scope bar that turns service day
  and direction into URL parameters, the planning summary, one timetable card per
  pattern section, the notices and the empty states, plus the trip drawer, the
  row menu and the delete confirmation. Stored stop times are displayed as they
  are; nothing here recomputes a trip from a timing.

  The timetable keeps its selection and Departs columns pinned on the left and
  Actions on the right while the stop columns scroll inside the table's own
  labelled region, so the page itself never scrolls sideways and the header row
  stays in view as the region scrolls.
  """
  use GtfsPlannerWeb, :html

  import GtfsPlannerWeb.PlannerComponents,
    only: [message: 1, first_use: 1, drawer_scroll: 1, drawer_footer: 1, form_section: 1]

  alias GtfsPlanner.Gtfs.GtfsTime
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.Schedules
  alias GtfsPlannerWeb.Gtfs.ScheduleChangeComponents

  # The problems notice names three problems and counts the rest, so a block with
  # many overlaps does not turn the timetable into a wall of sentences.
  @max_notice_problems 3

  # More service days than this become a select: long names stop fitting a toggle.
  @max_toggle_calendars 5

  # The pinned selection column is a fixed 3rem so the Departs column can pin at a
  # known offset without measuring the rendered table.
  @th "sticky top-0 border-b border-subtle bg-canvas px-3 py-2 align-bottom text-[13px] font-[650] leading-snug text-default"
  @td "border-b border-subtle bg-white px-3 group-hover:bg-canvas group-data-[sel=true]:bg-selection"
  @selection_cell "sticky left-0 w-12 min-w-12 px-0 text-center"
  @departs_cell "sticky left-12 min-w-[92px] border-r border-subtle text-right sm:min-w-[132px]"
  @actions_cell "min-w-[132px] text-left sm:sticky sm:right-0 sm:border-l sm:border-subtle"

  @focus_inset "focus-visible:outline-2 focus-visible:outline-offset-[-2px] focus-visible:outline-focus"

  # The grid state a section carries before any action: no reviewed preview, no
  # just-changed trips and no refused cell. `display_sections/2` puts this on every
  # section; the fallback keeps a directly rendered section working.
  @empty_grid %{preview: %{}, just_changed: MapSet.new(), cell_error: nil}

  # --- scope bar ---------------------------------------------------------------

  @doc """
  Renders the scope bar: the service days and direction toggles, and the actions
  that add trips or manage calendars.

  Service days are a toggle that shows each day's trip count so a day with no
  service is visible without opening a menu. Above five service days, and on a
  phone, the same choice is a select. Each control posts its own field through the
  `filters` event, which the LiveView turns into the canonical URL parameters.
  """
  attr :calendar_form, :any, required: true
  attr :calendars, :list, required: true
  attr :filters, :map, required: true
  attr :direction_labels, :map, required: true
  attr :calendars_path, :string, required: true
  attr :paste_path, :string, required: true, doc: "the Schedules-filtered paste page URL"
  attr :can_add?, :boolean, required: true
  attr :add_reason, :string, default: nil

  attr :add_primary?, :boolean,
    default: true,
    doc: "false when an empty state below carries the page's primary action"

  def scope_bar(assigns) do
    assigns =
      assigns
      |> assign(:many_calendars?, length(assigns.calendars) > @max_toggle_calendars)
      |> assign(:calendar_options, calendar_options(assigns.calendars))
      |> assign(:direction_options, direction_options(assigns.direction_labels))
      |> assign(:direction_value, to_string(assigns.filters.direction_id))

    ~H"""
    <div id="schedules-controls" class="mt-6 flex flex-wrap items-end gap-x-8 gap-y-4">
      <div class="min-w-0 max-w-full">
        <div class="mb-1.5 flex items-baseline justify-between gap-6">
          <span id="calendar-filter-label" class="text-[13px] font-semibold text-strong">
            Service days
          </span>
          <.link
            navigate={@calendars_path}
            id="schedules-manage-calendars"
            class={[
              "-my-3 inline-flex min-h-11 items-center text-[13px] font-semibold text-action no-underline hover:underline",
              focus_inset()
            ]}
          >
            Manage calendars
          </.link>
        </div>

        <.toggle
          :if={not @many_calendars?}
          id="calendar-toggle"
          name="service_id"
          label_id="calendar-filter-label"
          options={calendar_toggle_options(@calendars)}
          value={@filters.service_id}
          class="hidden sm:block"
        />
        <.form
          for={@calendar_form}
          id="schedule-calendar-form"
          phx-change="filters"
          class={[not @many_calendars? && "sm:hidden"]}
        >
          <.input
            id="calendar-filter"
            field={@calendar_form[:service_id]}
            type="select"
            options={@calendar_options}
            aria-labelledby="calendar-filter-label"
            class="w-full min-w-[260px] select select-lg"
          />
        </.form>
      </div>

      <.toggle
        id="direction-filter"
        name="direction"
        label="Direction"
        options={@direction_options}
        value={@direction_value}
      />

      <div class="ml-auto">
        <div class="flex flex-wrap items-center justify-end gap-3">
          <.link
            :if={@can_add?}
            id="schedules-paste-timetable"
            navigate={@paste_path}
            class="btn btn-outline min-h-11"
          >
            <.icon name="hero-clipboard-document" class="size-4" /> Paste timetable
          </.link>
          <.button
            :if={@can_add?}
            id="schedules-add-trips"
            type="button"
            variant={if(@add_primary?, do: "primary", else: "secondary")}
            class="min-h-11"
            phx-click="open_add_drawer"
            phx-disconnected={unavailable_offline()}
            phx-connected={available_online()}
          >
            <.icon name="hero-plus" class="size-4" /> Add trips
          </.button>
          <.button
            :if={not @can_add?}
            id="schedules-add-trips"
            type="button"
            variant="secondary"
            class="min-h-11"
            disabled
          >
            <.icon name="hero-plus" class="size-4" /> Add trips
          </.button>
        </div>
        <p
          :if={not @can_add?}
          id="schedules-add-blocked"
          class="mt-1.5 text-right text-[13px] text-muted"
        >
          {@add_reason}
        </p>
      </div>
    </div>
    """
  end

  @doc """
  Renders the toolbar above the timetables: which stops the tables show, which
  pattern they cover, the custom-times filter, the keyboard shortcut sheet's
  button, and how many trips are in view.
  """
  attr :pattern_form, :any, required: true
  attr :patterns, :list, required: true
  attr :filters, :map, required: true
  attr :row_count, :integer, required: true
  attr :custom_count, :integer, required: true
  attr :custom_filter?, :boolean, required: true
  attr :calendar_label, :string, required: true
  attr :direction_label, :string, required: true

  def filter_bar(assigns) do
    assigns =
      assigns
      |> assign(:pattern_options, pattern_options(assigns.patterns, assigns.filters))
      |> assign(:stops_options, [
        %{value: "timepoints", label: "Timepoints", count: nil},
        %{value: "all", label: "All stops", count: nil}
      ])
      |> assign(:stops_value, to_string(assigns.filters.stops))

    ~H"""
    <div id="schedules-toolbar" class="mt-5 flex flex-wrap items-center gap-x-6 gap-y-3">
      <.toggle
        id="stops-filter"
        name="stops"
        label="Stops shown"
        inline
        options={@stops_options}
        value={@stops_value}
      />

      <div class="flex items-center gap-2">
        <label for="pattern-filter" class="text-[13px] font-semibold text-strong">Pattern</label>
        <.form for={@pattern_form} id="schedule-pattern-form" phx-change="filters">
          <.input
            id="pattern-filter"
            field={@pattern_form[:pattern]}
            type="select"
            options={@pattern_options}
            class="w-full min-w-[220px] select select-lg sm:w-auto"
          />
        </.form>
      </div>

      <button
        :if={@custom_count > 0 or @custom_filter?}
        id="custom-times-chip"
        type="button"
        aria-pressed={to_string(@custom_filter?)}
        phx-click="filters"
        phx-value-custom={if(@custom_filter?, do: "0", else: "1")}
        class={[
          "inline-flex min-h-11 items-center gap-1.5 rounded-control border px-3 text-sm font-[650]",
          @custom_filter? && "border-action bg-selection text-strong",
          !@custom_filter? && "border-control bg-white text-strong hover:bg-canvas",
          focus_inset()
        ]}
      >
        <.icon :if={@custom_filter?} name="hero-check-circle" class="size-4 text-action" />
        Custom times <span class="tabular-nums font-normal text-muted">{@custom_count}</span>
      </button>

      <button
        id="keyboard-shortcuts-button"
        type="button"
        phx-click="toggle_shortcuts"
        phx-value-source="button"
        class={[
          "inline-flex min-h-11 items-center justify-center gap-1.5 rounded-control px-3 text-sm font-[650] text-strong hover:bg-canvas",
          focus_inset()
        ]}
      >
        <.icon name="hero-key" class="size-4" />Keyboard shortcuts
      </button>

      <p id="schedules-view-counts" role="status" class="ml-auto text-sm text-muted">
        <span class="font-semibold tabular-nums text-strong">{trip_count(@row_count)}</span>
        · {@calendar_label} · {@direction_label}
      </p>
    </div>
    """
  end

  # A group of radio choices drawn as one joined control. The radios are the
  # control, so the choice works from the keyboard and posts through the form's
  # `phx-change`; the selected segment is filled with the design system's ink and
  # keeps the page's one magenta for the primary action.
  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :label, :string, default: nil, doc: "the visible label; omit when `label_id` names one"
  attr :label_id, :string, default: nil, doc: "an existing element that labels the group"
  attr :inline, :boolean, default: false, doc: "label beside the control, not above it"
  attr :options, :list, required: true, doc: "maps with :value, :label and :count (or nil)"
  attr :value, :string, required: true
  attr :class, :any, default: nil

  defp toggle(assigns) do
    assigns =
      assign(assigns, :labelled_by, assigns.label_id || "#{assigns.id}-label")

    ~H"""
    <form id={"#{@id}-form"} phx-change="filters" class={["min-w-0 max-w-full", @class]}>
      <div class={["flex max-w-full", if(@inline, do: "items-center gap-2", else: "flex-col")]}>
        <span
          :if={@label}
          id={"#{@id}-label"}
          class={["text-[13px] font-semibold text-strong", !@inline && "mb-1.5"]}
        >
          {@label}
        </span>
        <div
          id={@id}
          role="radiogroup"
          aria-labelledby={@labelled_by}
          class="flex max-w-full overflow-x-auto rounded-control border border-control bg-white"
        >
          <label
            :for={option <- @options}
            for={toggle_option_id(@id, option.value)}
            class={[
              "group inline-flex min-h-11 shrink-0 cursor-pointer items-center gap-1.5 border-l border-control px-3 text-sm text-strong first:border-l-0",
              "hover:bg-canvas has-[:checked]:bg-strong has-[:checked]:font-bold has-[:checked]:text-white has-[:checked]:hover:bg-strong",
              "has-[:focus-visible]:outline-2 has-[:focus-visible]:outline-offset-[-2px] has-[:focus-visible]:outline-focus"
            ]}
          >
            <input
              type="radio"
              id={toggle_option_id(@id, option.value)}
              name={@name}
              value={option.value}
              checked={option.value == @value}
              class="sr-only"
            />
            {option.label}
            <span
              :if={option.count != nil}
              class="tabular-nums text-muted group-has-[:checked]:text-navy-100"
            >
              {option.count}
            </span>
          </label>
        </div>
      </div>
    </form>
    """
  end

  # A primary that a lost connection rules out reads as unavailable (the design
  # system's disabled control), not as busy, which is what a bare `disabled` on a
  # primary looks like while its action is in flight.
  defp unavailable_offline,
    do: JS.set_attribute({"disabled", ""}) |> JS.set_attribute({"data-unavailable", ""})

  defp available_online,
    do: JS.remove_attribute("disabled") |> JS.remove_attribute("data-unavailable")

  defp toggle_option_id(id, value),
    do: "#{id}-option-#{String.replace(value, ~r/[^a-zA-Z0-9_-]/, "-")}"

  # --- loading and notices ------------------------------------------------------

  @doc """
  Renders what the page shows before the first read arrives: the shape of the
  scope bar, the summary and one timetable card, so the page does not jump when
  the data lands.
  """
  def loading_skeleton(assigns) do
    ~H"""
    <div id="schedules-loading" role="status" aria-label="Loading schedules" class="mt-6">
      <div class="flex flex-wrap items-end gap-x-8 gap-y-4" aria-hidden="true">
        <div class="grid min-w-0 gap-2">
          <span class="h-4 w-24 rounded-badge bg-canvas"></span>
          <span class="h-11 w-full rounded-badge bg-canvas sm:w-[420px]"></span>
        </div>
        <div class="grid gap-2">
          <span class="h-4 w-20 rounded-badge bg-canvas"></span>
          <span class="h-11 w-64 rounded-badge bg-canvas"></span>
        </div>
        <div class="ml-auto flex gap-3">
          <span class="h-11 w-32 rounded-badge bg-canvas"></span>
        </div>
      </div>
      <div
        class="mt-6 grid gap-3 rounded-card border border-subtle bg-white p-5 lg:grid-cols-[320px_1fr]"
        aria-hidden="true"
      >
        <div class="grid gap-3">
          <span class="h-4 w-28 rounded-badge bg-canvas"></span>
          <span class="h-10 w-24 rounded-badge bg-canvas"></span>
        </div>
        <span class="h-16 w-full rounded-badge bg-canvas"></span>
      </div>
      <div class="mt-8 overflow-clip rounded-card border border-subtle bg-white">
        <div class="grid gap-2 px-5 py-4" aria-hidden="true">
          <span class="h-6 w-96 max-w-full rounded-badge bg-canvas"></span>
          <span class="h-4 w-72 max-w-full rounded-badge bg-canvas"></span>
        </div>
        <div
          :for={_row <- 1..6}
          class="flex items-center gap-4 border-t border-subtle px-5 py-3.5"
          aria-hidden="true"
        >
          <span class="h-5 w-5 rounded-badge bg-canvas"></span>
          <span class="h-4 w-16 rounded-badge bg-canvas"></span>
          <span class="h-4 flex-1 rounded-badge bg-canvas"></span>
          <span class="h-4 flex-1 rounded-badge bg-canvas"></span>
          <span class="h-4 flex-1 rounded-badge bg-canvas"></span>
          <span class="hidden h-4 w-24 rounded-badge bg-canvas sm:block"></span>
        </div>
        <p class="border-t border-subtle px-5 py-3 text-[13px] text-muted">Loading schedules…</p>
      </div>
    </div>
    """
  end

  @doc """
  Renders the disconnected notice.

  The Add, Edit, menu, selection, Delete and Save controls bind their own
  `phx-disconnected`/`phx-connected` pairs, so a lost socket disables committing
  until it returns; this notice explains why and disappears on reconnect.
  """
  def connectivity_notice(assigns) do
    ~H"""
    <div
      id="schedules-disconnected"
      class="mt-5"
      hidden
      phx-disconnected={JS.remove_attribute("hidden")}
      phx-connected={JS.set_attribute({"hidden", ""})}
    >
      <.message kind="warning" title="Connection lost">
        Showing the last loaded schedule. Adding, editing and deleting trips are unavailable
        until the connection returns.
      </.message>
    </div>
    """
  end

  @doc """
  Renders the notice for a read that failed. With no timetables on screen it says
  nothing loaded; with the last loaded timetables still under it, it says they may
  be out of date. Either way the trips are unchanged and one control retries.
  """
  attr :stale?, :boolean, required: true

  def unavailable_notice(assigns) do
    ~H"""
    <div id="schedules-unavailable" class="mt-5">
      <.message
        kind="error"
        title={
          if(@stale?, do: "Schedules couldn't be refreshed", else: "Schedules couldn't be loaded")
        }
      >
        <%= if @stale? do %>
          The timetables below are from your last successful load and may be out of date. Your
          trips haven't changed.
        <% else %>
          Your trips haven't changed. Try loading them again.
        <% end %>
        <:action>
          <.button
            id="schedules-retry"
            type="button"
            variant="secondary"
            class="min-h-11"
            phx-click="retry"
          >
            <.icon name="hero-arrow-path" class="size-4" /> Retry loading
          </.button>
        </:action>
      </.message>
    </div>
    """
  end

  @doc "Renders the warning notice for trips that belong to no section of their direction."
  attr :count, :integer, required: true
  attr :patterns_path, :string, required: true

  def unlinked_trips(assigns) do
    ~H"""
    <div id="schedules-unlinked" class="mt-5">
      <.message
        kind="warning"
        title={
          if(@count == 1,
            do: "1 trip isn't linked to a pattern",
            else: "#{@count} trips aren't linked to a pattern"
          )
        }
      >
        They are left out of the timetables below. Build patterns to include them.
        <:action>
          <.action_link navigate={@patterns_path}>Go to patterns</.action_link>
        </:action>
      </.message>
    </div>
    """
  end

  @doc """
  Renders the block notice a Schedules save can leave behind.

  A D2 clear names the calendar that took the trip off its block; a block problem
  lists up to #{@max_notice_problems} of the trip's current errors and warnings with
  the number of dates each affects. Both carry a Blocks link when the trip's service
  has a day to open, and the notice stays until the next drawer open or filter
  change.
  """
  attr :notice, :map, required: true

  def block_notice(assigns) do
    ~H"""
    <div id="schedules-block-notice" class="mt-5">
      <.message kind="warning" title={notice_title(@notice)}>
        {notice_message(@notice)}
        <:action :if={@notice.link}>
          <.action_link id="schedules-block-notice-link" navigate={@notice.link}>
            Open Blocks
          </.action_link>
        </:action>
      </.message>
    </div>
    """
  end

  attr :id, :string, default: nil
  attr :navigate, :string, required: true
  slot :inner_block, required: true

  defp action_link(assigns) do
    ~H"""
    <.link
      id={@id}
      navigate={@navigate}
      class={[
        "inline-flex min-h-11 items-center gap-1.5 text-sm font-[650] text-action no-underline hover:underline",
        focus_inset()
      ]}
    >
      {render_slot(@inner_block)} <.icon name="hero-arrow-right" class="size-4" />
    </.link>
    """
  end

  defp notice_title(%{kind: :block_cleared}), do: "Trip saved · removed from its block"

  defp notice_title(%{kind: :block_problems, block_id: id}),
    do: "Trip saved · block #{id} needs a look"

  defp notice_message(%{kind: :block_cleared} = notice) do
    "It was on block #{notice.block_id}. On #{notice.calendar_label}, block #{notice.block_id}" <>
      " is another vehicle's work, so the trip now has no block. Assign it on Blocks."
  end

  defp notice_message(%{kind: :block_problems} = notice), do: problems_message(notice.problems)

  # The sentence is per problem: the same block ID repeating across problems is the
  # list, not a defect, so identical sentences collapse to one and the rest are
  # counted.
  defp problems_message(problems) do
    sentences =
      problems
      |> Enum.map(&problem_sentence/1)
      |> Enum.uniq()
      |> Enum.take(@max_notice_problems)

    more = length(problems) - length(sentences)

    Enum.join(sentences ++ more_sentence(more) ++ ["Review on Blocks."], " ")
  end

  defp more_sentence(0), do: []
  defp more_sentence(more), do: ["and #{more} more."]

  defp problem_sentence(%{code: :overlap, block_id: block_id, date_count: date_count}) do
    "Block #{block_id} has an overlap on #{date_count} days."
  end

  defp problem_sentence(%{code: :short_layover, block_id: block_id, date_count: date_count}) do
    "Block #{block_id} has a short layover on #{date_count} days."
  end

  defp problem_sentence(%{code: :in_seat_stale, block_id: block_id, date_count: date_count}) do
    "Block #{block_id} has an in-seat record to review on #{date_count} days."
  end

  defp problem_sentence(%{block_id: block_id, date_count: date_count}) do
    "Block #{block_id} has a problem on #{date_count} days."
  end

  # --- planning summary ------------------------------------------------------------

  @doc """
  Renders the planning summary: the vehicles-needed lower bound for this route
  alone with its change marker, the trips per hour of the direction behind a
  disclosure, and the incomplete-times note.

  The disclosure is a pair of JS commands, so opening it does not round-trip and
  the choice survives the patches a save produces.
  """
  attr :summary, :map, required: true
  attr :route, :map, required: true
  attr :calendar_label, :string, required: true
  attr :direction_label, :string, required: true
  attr :vehicle_change, :any, default: nil

  def planning_summary(assigns) do
    hours = assigns.summary.trips_per_hour

    assigns =
      assigns
      |> assign(:vehicles, assigns.summary.vehicles)
      |> assign(:hours, hours)
      |> assign(:max_hour_count, hours |> Enum.map(&elem(&1, 1)) |> Enum.max(fn -> 1 end))

    ~H"""
    <section
      id="planning-summary"
      aria-label="Service summary"
      class="mt-5 rounded-card border border-subtle bg-white"
    >
      <div
        id="planning-vehicles"
        class="flex flex-wrap items-center gap-x-4 gap-y-1 px-4 py-2 sm:px-5"
      >
        <div id="vehicles-needed" class="flex items-center">
          <p id="planning-vehicles-item-vehicles" class="text-[13px] font-semibold text-muted">
            Vehicles needed
          </p>
          <button
            type="button"
            id="vehicles-help-toggle"
            popovertarget="vehicles-help"
            style="anchor-name: --vehicles-help"
            aria-label="How vehicles needed is counted"
            title="How this is counted"
            class={[
              "-my-2 inline-flex min-h-11 min-w-11 items-center justify-center rounded-control text-muted hover:bg-canvas hover:text-strong",
              focus_inset()
            ]}
          >
            <.icon name="hero-information-circle" class="size-4" />
          </button>
          <div
            id="vehicles-help"
            popover="auto"
            style={
              "inset: auto; position-anchor: --vehicles-help; top: anchor(bottom);" <>
                " left: anchor(left); margin: 0.375rem 0 0 0;" <>
                " position-try-fallbacks: flip-block, flip-inline;"
            }
            class="w-[min(340px,calc(100vw-16px))] rounded-card border border-subtle bg-white p-4 text-left text-sm text-default shadow-float"
          >
            <p class="font-bold text-strong">How vehicles needed is counted</p>
            <p class="mt-1">
              The most {@calendar_label} trips running at once on this route, in both directions.
              Other routes can share vehicles, and time between trips can mean more. Planners also
              call this the peak vehicle requirement.
            </p>
          </div>
        </div>

        <p
          id="vehicles-needed-line"
          class="flex min-w-0 flex-1 basis-[420px] flex-wrap items-baseline gap-x-2"
        >
          <span
            id="vehicles-needed-count"
            class="font-display text-[32px] font-semibold leading-none tabular-nums text-strong"
          >
            {@vehicles.count}
          </span>
          <span class="text-sm text-default">at least, for route {route_label(@route)} alone</span>
          <span id="vehicle-change" role="status" class="contents">
            <span
              :if={@vehicle_change}
              class="inline-flex items-center rounded-badge bg-warning-bg px-2 py-0.5 text-[13px] font-bold tabular-nums text-warning-fg"
            >
              {@vehicle_change.from} → {@vehicle_change.to}
            </span>
          </span>
          <span id="vehicles-needed-context" class="text-[13px] text-muted">
            {vehicles_context(@calendar_label, @vehicles)}
          </span>
        </p>

        <button
          type="button"
          id="hours-toggle"
          aria-expanded="false"
          aria-controls="hours-panel"
          phx-click={
            JS.toggle_attribute({"hidden", ""}, to: "#hours-panel")
            |> JS.toggle_attribute({"aria-expanded", "true", "false"}, to: "#hours-toggle")
          }
          class={[
            "group -my-1 ml-auto inline-flex min-h-11 items-center gap-1 rounded-control px-2 text-sm font-[650] text-action hover:bg-selection",
            focus_inset()
          ]}
        >
          <span class="group-aria-expanded:hidden">Show trips per hour</span>
          <span class="hidden group-aria-expanded:inline">Hide trips per hour</span>
          <.icon
            name="hero-chevron-right"
            class="size-4 transition-transform group-aria-expanded:rotate-90"
          />
        </button>
      </div>

      <div id="hours-panel" hidden class="border-t border-subtle px-4 py-3 sm:px-5">
        <div id="trips-per-hour-block" class="min-w-0">
          <p class="text-[13px] font-semibold text-muted">Trips per hour · {@direction_label}</p>
          <div id="trips-per-hour-scroll" class="mt-1 overflow-x-auto">
            <ol
              id="trips-per-hour"
              aria-label="Trips per hour"
              class="flex min-w-[420px] items-end gap-0.5"
            >
              <li
                :for={{hour, count, approximate?} <- @hours}
                class="flex min-w-[28px] flex-1 flex-col items-center justify-end gap-1"
              >
                <span
                  id={"trips-per-hour-count-#{hour}"}
                  class={[
                    "text-[13px] tabular-nums",
                    count == 0 && "font-normal text-muted",
                    count > 0 && "font-semibold text-strong"
                  ]}
                >
                  {hour_count_label(count, approximate?)}
                </span>
                <span class="flex h-[26px] w-full items-end px-[3px]" aria-hidden="true">
                  <span
                    class={[
                      "block w-full",
                      count == 0 && "bg-subtle",
                      count > 0 && !approximate? && "rounded-t-badge bg-cyan-700",
                      count > 0 && approximate? &&
                        "rounded-t-badge border-2 border-dashed border-cyan-700 bg-soft"
                    ]}
                    style={"height: #{bar_height(count, @max_hour_count)}px"}
                  >
                  </span>
                </span>
                <span
                  id={"trips-per-hour-hour-#{hour}"}
                  class="text-[12px] tabular-nums text-muted"
                  title={hour_title(hour)}
                >
                  {hour_label(hour)}
                </span>
              </li>
            </ol>
          </div>
          <p class="mt-1 text-[13px] text-muted">
            First departure. ≈ marks hours with frequency service, whose departures aren't fixed
            times.
          </p>
        </div>
      </div>

      <p
        :if={@summary.incomplete_trip_count > 0}
        id="incomplete-times-note"
        class="border-t border-subtle px-4 py-2 text-[13px] text-muted sm:px-5"
      >
        {incomplete_times_note(@summary.incomplete_trip_count)}
      </p>
    </section>
    """
  end

  defp vehicles_context(calendar_label, %{at_secs: nil}),
    do: "#{calendar_label} · both directions"

  defp vehicles_context(calendar_label, %{at_secs: at_secs}),
    do: "#{calendar_label} · both directions · most at #{clock(at_secs)}"

  defp bar_height(0, _max), do: 2
  defp bar_height(count, max), do: max(6, round(count / max * 24))

  # --- row actions -------------------------------------------------------------------

  @doc """
  Renders one row's actions: an Edit control and a menu with Duplicate and Delete.

  The menu is a native popover anchored under its trigger. A popover renders in
  the browser's top layer, so it escapes the timetable's scroll container instead
  of being clipped by it, and the browser owns light-dismiss and Escape. A
  frequency row shows Duplicate disabled with the reason in visible text rather
  than a hover-only tooltip.
  """
  attr :row, :map, required: true

  def row_actions(assigns) do
    assigns =
      assigns
      |> assign(:menu_id, "trip-#{assigns.row.trip_id}-menu-panel")
      |> assign(:anchor_name, "--trip-menu-#{assigns.row.id}")

    ~H"""
    <div class="relative flex items-center gap-1">
      <button
        id={"trip-#{@row.trip_id}-edit"}
        type="button"
        phx-click="open_edit_drawer"
        phx-value-trip={@row.id}
        class={[
          "inline-flex min-h-11 min-w-11 items-center justify-center rounded-control px-2 text-sm font-[650] text-action hover:bg-selection",
          "disabled:cursor-not-allowed disabled:text-muted disabled:hover:bg-transparent",
          focus_inset()
        ]}
        phx-disconnected={JS.set_attribute({"disabled", ""})}
        phx-connected={JS.remove_attribute("disabled")}
      >
        Edit
      </button>
      <button
        id={"trip-#{@row.trip_id}-menu"}
        type="button"
        popovertarget={@menu_id}
        style={"anchor-name: #{@anchor_name}"}
        class={[
          "inline-flex min-h-11 min-w-11 items-center justify-center rounded-control text-muted hover:bg-canvas hover:text-strong",
          "disabled:cursor-not-allowed disabled:text-subtle",
          focus_inset()
        ]}
        aria-label={"More actions for trip #{@row.trip_id}"}
        aria-haspopup="menu"
        title="More actions"
        phx-disconnected={JS.set_attribute({"disabled", ""})}
        phx-connected={JS.remove_attribute("disabled")}
      >
        <.icon name="hero-ellipsis-horizontal" class="size-5" />
      </button>

      <div
        id={@menu_id}
        popover="auto"
        role="menu"
        aria-label={"Actions for trip #{@row.trip_id}"}
        style={
          "inset: auto; position-anchor: #{@anchor_name}; top: anchor(bottom);" <>
            " right: anchor(right); margin: 0.25rem 0 0 0;" <>
            " position-try-fallbacks: flip-block, flip-inline;"
        }
        class="w-64 rounded-card border border-subtle bg-white p-1 text-left shadow-float"
      >
        <button
          :if={not @row.frequency?}
          id={"trip-#{@row.trip_id}-duplicate"}
          type="button"
          role="menuitem"
          popovertarget={@menu_id}
          popovertargetaction="hide"
          phx-click="open_duplicate_drawer"
          phx-value-trip={@row.id}
          class={[
            "flex min-h-11 w-full items-center rounded-control px-3 text-left text-sm text-strong hover:bg-canvas",
            focus_inset()
          ]}
        >
          Duplicate trip
        </button>
        <button
          :if={@row.frequency?}
          id={"trip-#{@row.trip_id}-duplicate-disabled"}
          type="button"
          role="menuitem"
          disabled
          class="flex min-h-11 w-full items-center rounded-control px-3 text-left text-sm text-muted"
        >
          Duplicate trip
        </button>
        <p
          :if={@row.frequency?}
          id={"trip-#{@row.trip_id}-duplicate-reason"}
          class="px-3 pb-2 text-[13px] text-muted"
        >
          Frequency service can't be duplicated.
        </p>
        <button
          :if={@row.frequency?}
          id={"trip-#{@row.trip_id}-convert"}
          type="button"
          role="menuitem"
          popovertarget={@menu_id}
          popovertargetaction="hide"
          phx-click="open_change"
          phx-value-kind="convert"
          phx-value-trip={@row.id}
          class={[
            "flex min-h-11 w-full items-center rounded-control px-3 text-left text-sm text-strong hover:bg-canvas",
            focus_inset()
          ]}
        >
          Convert to scheduled trips…
        </button>
        <button
          id={"trip-#{@row.trip_id}-delete"}
          type="button"
          role="menuitem"
          popovertarget={@menu_id}
          popovertargetaction="hide"
          phx-click="open_delete_trip"
          phx-value-trip={@row.id}
          class={[
            "flex min-h-11 w-full items-center rounded-control px-3 text-left text-sm text-error-fg hover:bg-error-bg",
            focus_inset()
          ]}
        >
          Delete trip
        </button>
      </div>
    </div>
    """
  end

  # --- delete confirmation ----------------------------------------------------------

  @doc """
  Renders the single and bulk delete confirmation.

  The dialog names the count and service day for a bulk delete and the trip's start
  and pattern for a single delete, states that the trips leave the published
  version and that this can't be undone, names the transfer records the deletion
  also removes when any exist, and keeps any delete failure on screen with a
  retry.
  """
  attr :dialog, :any, required: true
  attr :version_name, :string, required: true

  def delete_dialog(assigns) do
    assigns = assign(assigns, :transfer_notice, transfer_notice(assigns.dialog))

    ~H"""
    <.confirm_dialog
      id="delete-dialog"
      chrome="planner"
      open={@dialog != nil}
      title={dialog_title(@dialog)}
      confirm_label={dialog_confirm_label(@dialog)}
      cancel_label={dialog_cancel_label(@dialog)}
      pending_label="Deleting…"
      on_confirm="confirm_delete"
      on_cancel="close_delete"
      described_by="delete-dialog-body"
      return_focus_id={@dialog && @dialog.return_focus_id}
    >
      <div :if={@dialog}>
        <p :if={@dialog.detail} id="delete-dialog-detail" class="font-semibold text-strong">
          {@dialog.detail}
        </p>
        <p class={["text-default", @dialog.detail && "mt-2"]}>
          <%= if @dialog.frequency? do %>
            This removes {removal_subject(@dialog)} and {removal_stop_times(@dialog)} from the published {@version_name}, including
            frequency service.
          <% else %>
            This removes {removal_subject(@dialog)} and {removal_stop_times(@dialog)} from the published {@version_name}.
          <% end %>
          <span :if={@transfer_notice} id="delete-dialog-transfers">{@transfer_notice}</span>
          You can't undo this.
        </p>
        <p
          :if={@dialog.error}
          id="delete-error"
          role="alert"
          class="mt-3 flex items-start gap-1.5 text-[13px] font-semibold text-error-fg"
        >
          <.icon name="hero-exclamation-circle" class="mt-0.5 size-4 shrink-0" />
          <span>{@dialog.error}</span>
        </p>
      </div>
    </.confirm_dialog>
    """
  end

  defp removal_subject(%{ids: [_one]}), do: "the trip"
  defp removal_subject(_dialog), do: "the trips"

  defp removal_stop_times(%{ids: [_one]}), do: "its stop times"
  defp removal_stop_times(_dialog), do: "their stop times"

  # The confirmation states the transfer consequence only when a transfer names
  # one of the dialog's trips. A dialog map without a transfer count is a caller
  # defect and raises rather than silently omitting the sentence.
  defp transfer_notice(nil), do: nil
  defp transfer_notice(%{transfer_count: 0}), do: nil

  defp transfer_notice(%{transfer_count: transfer_count, ids: ids}),
    do: transfer_sentence(transfer_count, length(ids))

  # The sentence states how many transfer records the deletion removes, in the
  # number of the count and of the trips the dialog names.
  defp transfer_sentence(1, 1), do: "It also removes 1 transfer record that names this trip."

  defp transfer_sentence(1, _trip_count),
    do: "It also removes 1 transfer record that names these trips."

  defp transfer_sentence(transfer_count, 1),
    do: "It also removes #{transfer_count} transfer records that name this trip."

  defp transfer_sentence(transfer_count, _trip_count),
    do: "It also removes #{transfer_count} transfer records that name these trips."

  defp dialog_title(nil), do: "Delete trips?"
  defp dialog_title(%{title: title}), do: title

  defp dialog_confirm_label(nil), do: "Delete"
  defp dialog_confirm_label(%{confirm_label: label}), do: label

  defp dialog_cancel_label(%{ids: [_one]}), do: "Keep trip"
  defp dialog_cancel_label(_dialog), do: "Keep trips"

  # --- trip drawer -------------------------------------------------------------------

  @doc """
  Renders the Add trips, Edit trip and Duplicate drawers.

  Fields run in the order they change: the departure (and its repeat) first, the
  result card that shows what saving will create, then where the trips run. The
  Add drawer leads with "How the trips run": Scheduled trips keeps that order,
  and Every N minutes replaces the departure and its repeat with the frequency
  windows editor, the riders-see choice and the frequency result card. The Add
  drawer previews the exact departures `Gtfs.series_starts/3` will create and the
  primary label counts them (or adds one frequency service). The Edit drawer keeps
  a custom trip's stop times unless a timing is chosen, disables the departure for
  frequency service with a visible reason, and hides the optional accessibility
  fields and the stable trip ID behind a disclosure. Every field error carries its
  own stable id and `aria-invalid`, so the `FormErrorFocus` hook lands on the
  first invalid field.
  """
  attr :drawer, :any, required: true
  attr :patterns, :list, required: true
  attr :calendars, :list, required: true
  attr :blocks_path, :string, required: true
  attr :patterns_path, :string, required: true
  attr :version_name, :string, required: true

  attr :sections, :list,
    default: [],
    doc: "the page's loaded sections, so the drawer can name the departing stop"

  def trip_drawer(assigns) do
    pattern = drawer_pattern(assigns.drawer, assigns.patterns)

    assigns =
      assigns
      |> assign(:title, drawer_title(assigns.drawer))
      |> assign(:pattern, pattern)
      |> assign(:custom?, assigns.drawer != nil and assigns.drawer.custom?)
      |> assign(:frequency?, assigns.drawer != nil and assigns.drawer.frequency?)
      |> assign(:stops_differ?, assigns.drawer != nil and assigns.drawer.stops_differ?)
      |> assign(:values, assigns.drawer && assigns.drawer.values)
      |> assign(:run_as, drawer_run_as(assigns.drawer))
      |> assign(:frequency_add?, frequency_add?(assigns.drawer))
      |> assign(:frequency_edit?, frequency_edit?(assigns.drawer))
      |> assign(:refusal, drawer_refusal(assigns.drawer))
      |> assign(:stop_name, drawer_stop_name(assigns.sections, pattern))

    ~H"""
    <.drawer
      id="trip-drawer"
      chrome="planner"
      open={@drawer != nil}
      title={@title}
      on_close="close_drawer"
      initial_focus={:first_field}
      initial_focus_id={drawer_initial_focus_id(@drawer)}
      return_focus_id={@drawer && @drawer.return_focus_id}
      class="max-w-[480px]"
    >
      <:lede :if={@drawer}>
        <span id="trip-drawer-route">{drawer_route_line(@drawer, @pattern)}</span>
      </:lede>

      <.form
        :if={@drawer}
        for={%{}}
        as={:drawer}
        id="trip-drawer-form"
        phx-change="drawer_change"
        phx-submit="drawer_submit"
        class="flex min-h-0 flex-1 flex-col"
      >
        <.drawer_scroll>
          <.drawer_notice drawer={@drawer} />

          <.message
            :if={(@drawer.mode == :add and @pattern) && @pattern.timings == []}
            kind="warning"
            title="Add a timing first"
          >
            This pattern has no timing yet. A timing sets the minutes between stops for each trip.
            <:action>
              <.action_link navigate={@patterns_path}>Go to patterns</.action_link>
            </:action>
          </.message>

          <.message :if={@custom?} kind="warning" title="This trip has custom stop times">
            Choose “Use timing” to change its departure or stop times. Other trip details can still
            be saved.
          </.message>

          <.message
            :if={@frequency? and not @frequency_edit?}
            kind="info"
            title={frequency_title(@drawer)}
          >
            Frequency times are shown for reference. The departure and timing can't be edited here.
            You can still change the service days and trip details.
          </.message>

          <div :if={@frequency_edit?} class="grid gap-5">
            <ScheduleChangeComponents.windows_editor
              windows={@values["windows"]}
              stop_name={@stop_name}
            />
            <ScheduleChangeComponents.riders_see
              windows={@values["windows"]}
              exact_times={@values["exact_times"]}
            />
          </div>

          <ScheduleChangeComponents.run_as_choice
            :if={@drawer.mode == :add}
            run_as={@run_as}
            refusal={@refusal}
          />

          <div :if={not @frequency_add? and not @frequency_edit?} class="grid gap-1">
            <.input
              id="trip-start"
              name="drawer[start_time]"
              type="text"
              label={departure_label(@drawer.mode)}
              value={@values["start_time"]}
              disabled={departure_disabled?(@drawer, @custom?, @frequency?)}
              errors={error_list(@drawer, :start_time)}
              inputmode="numeric"
              autocomplete="off"
              spellcheck="false"
              placeholder="06:00"
              class="w-full input input-lg tabular-nums"
              help={departure_help(@drawer, @custom?, @frequency?)}
            />
          </div>

          <div :if={@drawer.mode == :add and not @frequency_add?} class="grid gap-3">
            <.input
              id="trip-repeat"
              name="drawer[repeat]"
              type="checkbox"
              label="Repeat departures"
              checked={@values["repeat"] == "true"}
            />
            <div :if={@values["repeat"] == "true"} class="grid gap-4 sm:grid-cols-2">
              <.input
                id="trip-every"
                name="drawer[every]"
                type="number"
                min="1"
                step="1"
                inputmode="numeric"
                label="Every (minutes)"
                value={@values["every"]}
                errors={error_list(@drawer, :every)}
                class="w-full input input-lg tabular-nums"
              />
              <.input
                id="trip-until"
                name="drawer[until]"
                type="text"
                inputmode="numeric"
                autocomplete="off"
                placeholder="09:00"
                label="Last departure by"
                value={@values["until"]}
                errors={error_list(@drawer, :until)}
                class="w-full input input-lg tabular-nums"
              />
            </div>
          </div>

          <div :if={@frequency_add?} class="grid gap-5">
            <ScheduleChangeComponents.windows_editor
              windows={@values["windows"]}
              stop_name={@stop_name}
            />
            <ScheduleChangeComponents.riders_see
              windows={@values["windows"]}
              exact_times={@values["exact_times"]}
            />
          </div>

          <.drawer_preview drawer={@drawer} />

          <p :if={@frequency_edit?} class="text-[13px] text-muted">
            Headsign, trip number and accessibility are edited as today. Frequency service is never
            assigned to blocks.
          </p>

          <.form_section :if={@drawer.mode == :add} title="Where these trips run" first?={false}>
            <.input
              id="trip-calendar"
              name="drawer[service_id]"
              type="select"
              label="Service days"
              value={@values["service_id"]}
              options={calendar_options(@calendars)}
              help="The days these trips run."
              errors={error_list(@drawer, :service_id)}
            />
            <.input
              id="trip-pattern"
              name="drawer[pattern_id]"
              type="select"
              label="Pattern"
              value={@values["pattern_id"]}
              options={pattern_options(@patterns)}
              help="The stops these trips serve."
              errors={error_list(@drawer, :pattern_id)}
            />
            <.timing_field
              drawer={@drawer}
              pattern={@pattern}
              values={@values}
              custom?={@custom?}
              stops_differ?={@stops_differ?}
            />
          </.form_section>

          <div :if={@drawer.mode == :edit} class="grid gap-5">
            <.timing_field
              :if={not @frequency?}
              drawer={@drawer}
              pattern={@pattern}
              values={@values}
              custom?={@custom?}
              stops_differ?={@stops_differ?}
            />
            <.input
              id="trip-calendar"
              name="drawer[service_id]"
              type="select"
              label="Service days"
              value={@values["service_id"]}
              options={calendar_options(@calendars)}
              help="The days this trip runs."
              errors={error_list(@drawer, :service_id)}
            />
          </div>

          <div :if={@drawer.mode == :duplicate} class="grid gap-5">
            <.timing_field
              drawer={@drawer}
              pattern={@pattern}
              values={@values}
              custom?={@custom?}
              stops_differ?={@stops_differ?}
            />
          </div>

          <.form_section :if={@drawer.mode == :edit} title="Trip details">
            <.input
              id="trip-headsign"
              name="drawer[trip_headsign]"
              type="text"
              label="Headsign (optional)"
              value={@values["trip_headsign"]}
              help={headsign_help(@drawer, @pattern)}
              errors={error_list(@drawer, :trip_headsign)}
            />
            <.input
              id="trip-number"
              name="drawer[trip_short_name]"
              type="text"
              label="Trip number (optional)"
              value={@values["trip_short_name"]}
              errors={error_list(@drawer, :trip_short_name)}
            />
            <div id="trip-block" class="grid gap-1">
              <p class="text-[13px] font-semibold text-strong">Block</p>
              <p id="trip-block-value" class="text-sm text-default">{block_value(@drawer)}</p>
              <.action_link
                :if={is_binary(@drawer.block_day_key)}
                id="trip-block-link"
                navigate={block_link(@drawer, @blocks_path)}
              >
                Change on Blocks
              </.action_link>
              <p
                :if={@drawer.block_day_key == :none}
                id="trip-block-none"
                class="text-[13px] text-muted"
              >
                Not running on any date
              </p>
              <p class="text-[13px] text-muted">
                Trips with the same block use the same vehicle.
              </p>
            </div>
            <details id="trip-accessibility" class="group rounded-control border border-subtle px-3">
              <summary class="flex min-h-11 cursor-pointer list-none items-center justify-between text-sm font-[650] text-strong [&::-webkit-details-marker]:hidden">
                Accessibility and trip ID
                <.icon
                  name="hero-chevron-down"
                  class="size-4 text-muted transition-transform group-open:rotate-180"
                />
              </summary>
              <div class="grid gap-4 pb-4 pt-2">
                <.input
                  id="trip-access"
                  name="drawer[wheelchair_accessible]"
                  type="select"
                  label="Wheelchair access"
                  value={@values["wheelchair_accessible"]}
                  options={accessibility_options("Accessible", "Not accessible")}
                  errors={error_list(@drawer, :wheelchair_accessible)}
                />
                <.input
                  id="trip-bikes"
                  name="drawer[bikes_allowed]"
                  type="select"
                  label="Bikes allowed"
                  value={@values["bikes_allowed"]}
                  options={accessibility_options("Allowed", "Not allowed")}
                  errors={error_list(@drawer, :bikes_allowed)}
                />
                <p class="text-[13px] text-muted">
                  Trip ID
                  <code id="trip-stable-id" class="font-mono text-default">{@drawer.trip_id}</code>
                  <br />This ID stays the same when you edit the trip.
                </p>
              </div>
            </details>
          </.form_section>
        </.drawer_scroll>

        <.drawer_footer>
          <p id="trip-drawer-save-note" class="basis-full text-[13px] text-muted">
            Changes save to {@version_name} right away.
          </p>
          <.button
            :if={@drawer.mode == :edit and @frequency?}
            id="fw-convert"
            type="button"
            variant="quiet"
            class="mr-auto min-h-11"
            phx-click="open_change"
            phx-value-kind="convert"
            phx-value-trip={@drawer.trip.id}
          >
            Convert to scheduled trips…
          </.button>
          <.button
            :if={@drawer.mode == :edit and not @frequency?}
            id="trip-drawer-delete"
            type="button"
            variant="quiet"
            class="mr-auto min-h-11 text-error-fg hover:bg-error-bg"
            phx-click="open_delete_trip"
            phx-value-trip={@drawer.trip.id}
          >
            <.icon name="hero-trash" class="size-4" /> Delete trip
          </.button>
          <.button
            id="trip-drawer-cancel"
            type="button"
            variant="secondary"
            class="min-h-11"
            phx-click="close_drawer"
          >
            Cancel
          </.button>
          <.button
            :if={can_submit?(@drawer, @pattern)}
            id="trip-drawer-save"
            type="submit"
            disabled={submit_disabled?(@drawer)}
            class="min-h-11"
            phx-disable-with="Saving…"
            phx-disconnected={unavailable_offline()}
            phx-connected={available_online()}
          >
            {@drawer.preview.label}
          </.button>
        </.drawer_footer>
      </.form>
    </.drawer>
    """
  end

  attr :drawer, :map, required: true
  attr :pattern, :any, required: true
  attr :values, :map, required: true
  attr :custom?, :boolean, required: true
  attr :stops_differ?, :boolean, required: true

  defp timing_field(assigns) do
    ~H"""
    <div class="grid gap-1">
      <.input
        id="trip-timing"
        name="drawer[timed_pattern_id]"
        type="select"
        label="Timing"
        value={@values["timed_pattern_id"]}
        options={timing_select_options(@drawer, @pattern)}
        help={timing_help(@custom?, @stops_differ?)}
        errors={error_list(@drawer, :timed_pattern_id)}
      />
    </div>
    """
  end

  # The reason a custom trip can't take a timing sits in the field's own help, so it
  # is read with the control rather than after it.
  defp timing_help(true, true),
    do: "This trip's stops differ from the pattern, so its custom times are kept."

  defp timing_help(_custom?, _stops_differ?),
    do: "The minutes a trip takes between stops, not a clock time."

  defp drawer_route_line(drawer, nil), do: "Route #{drawer.route_label}"
  defp drawer_route_line(drawer, pattern), do: "Route #{drawer.route_label} · #{pattern.name}"

  defp drawer_notice(assigns) do
    ~H"""
    <.message
      :if={@drawer.problem}
      id="trip-drawer-error"
      kind="error"
      title={error_message(@drawer.problem)}
    >
      <:action :if={@drawer.problem == :stale}>
        <.button
          id="trip-drawer-reload"
          type="button"
          variant="secondary"
          class="min-h-11"
          phx-click="reload_drawer"
        >
          <.icon name="hero-arrow-path" class="size-4" /> Reload trip
        </.button>
      </:action>
    </.message>
    """
  end

  # The result card: what saving will create, with the departure and the time the
  # trip ends in the display face so the range reads first. The Add drawer's card
  # is the reference's `#add-result-card`; the Edit and Duplicate drawers keep the
  # id the page has always used for this card.
  defp drawer_preview(assigns) do
    assigns = assign(assigns, :card_id, drawer_card_id(assigns.drawer))

    ~H"""
    <div
      id={@card_id}
      aria-live="polite"
      class="rounded-card border border-subtle bg-canvas p-4 text-sm"
    >
      <p
        :if={@drawer.preview.error}
        id={"#{@card_id}-error"}
        class="flex items-start gap-1.5 font-semibold text-error-fg"
      >
        <.icon name="hero-exclamation-circle" class="mt-0.5 size-4 shrink-0" />
        <span>{@drawer.preview.error}</span>
      </p>
      <div :if={is_nil(@drawer.preview.error)}>
        <p :if={@drawer.preview.meta} class="text-muted">{@drawer.preview.meta}</p>
        <p
          :if={@drawer.preview.range}
          class="mt-1 font-display text-[26px] font-semibold leading-tight tabular-nums text-strong"
        >
          {@drawer.preview.range}
        </p>
        <p :if={@drawer.preview.total_minutes} class="mt-1 text-default">
          {preview_total(@drawer)}
        </p>
        <p :if={@drawer.preview.sentence} class="mt-1 font-bold text-strong">
          {@drawer.preview.sentence}
        </p>
        <p :if={@drawer.preview.hint} class="mt-1 text-[13px] text-muted">
          {@drawer.preview.hint}
        </p>
      </div>
    </div>
    """
  end

  defp preview_total(%{mode: :add, preview: preview}),
    do: "First trip: #{preview.total_minutes} minutes from first to last stop."

  defp preview_total(%{preview: preview}),
    do: "#{preview.total_minutes} minutes from first to last stop."

  defp drawer_card_id(%{mode: :add}), do: "add-result-card"
  defp drawer_card_id(_drawer), do: "trip-preview"

  defp drawer_run_as(%{values: values}) when is_map(values), do: values["run_as"] || "scheduled"
  defp drawer_run_as(_drawer), do: "scheduled"

  defp frequency_add?(%{mode: :add} = drawer), do: drawer_run_as(drawer) == "frequency"
  defp frequency_add?(_drawer), do: false

  # The Edit drawer for a frequency trip carries the windows editor in place of
  # the frequency notice (step 35).
  defp frequency_edit?(%{mode: :edit, frequency?: true}), do: true
  defp frequency_edit?(_drawer), do: false

  defp drawer_refusal(%{errors: errors}) when is_map(errors), do: Map.get(errors, :run_as)
  defp drawer_refusal(_drawer), do: nil

  # The first stop the drawer's pattern departs from, read from that pattern's own
  # section; a pattern with no trips yet has no stop column to name.
  defp drawer_stop_name(sections, %{route_pattern_id: pattern_id}) do
    case Enum.find(sections, &(&1.pattern.route_pattern_id == pattern_id)) do
      %{columns: [%{stop_name: name} | _rest]} -> name
      _missing -> nil
    end
  end

  defp drawer_stop_name(_sections, _pattern), do: nil

  defp block_value(%{trip: %{block_id: block_id}}) when is_binary(block_id),
    do: "Block #{block_id}"

  defp block_value(_drawer), do: "No block"

  defp block_link(drawer, blocks_path) do
    blocks_path <>
      "?" <> URI.encode_query(%{"day" => drawer.block_day_key, "trip" => drawer.trip_id})
  end

  # Fixed UI copy for every error a schedule mutation can return (CR-6).
  # Raw errors never reach the screen: an unknown reason falls back to the save
  # failure sentence.
  @doc "Returns the fixed sentence a schedule mutation error shows."
  @spec error_message(
          atom()
          | {:mixed_service, map()}
          | {:out_of_order, pos_integer()}
          | {:refused, [term()]}
          | nil
        ) :: String.t()
  def error_message(:stale) do
    "This trip changed since you opened it. Reload it to see the current values."
  end

  def error_message(:busy), do: "Another change is being saved. Try again."

  def error_message(:frequency_trip) do
    "Frequency service can't be edited here. Its service days and details can still change."
  end

  def error_message(:stops_differ) do
    "This trip's stops differ from the pattern, so it can't use that timing. Keep its custom times."
  end

  def error_message(:timed_pattern_required) do
    "Choose a timing to change this trip's departure or stop times."
  end

  def error_message(:not_found) do
    "This trip or pattern no longer exists. Reload the schedule to see the current trips."
  end

  def error_message(:calendar_not_found) do
    "That service day is no longer available. Reload the schedule and try again."
  end

  def error_message(:trip_stop_times_mismatch) do
    "This trip's stop times don't match its pattern. Reload the schedule and try again."
  end

  def error_message(:trip_id_conflict) do
    "That trip ID is already in use. Add the trips again."
  end

  def error_message(:invalid_time) do
    "Enter a time such as 6:05, 605, 6:05p or 25:10."
  end

  def error_message(:unauthorized) do
    "You don't have permission to change this route's trips."
  end

  def error_message(:invalid_interval) do
    "Enter a whole number of minutes greater than zero."
  end

  # Convert refuses a source whose stored windows cannot be followed (an
  # overlap, a reversed span or a headway that is not a whole number of
  # minutes), because the conversion would otherwise delete a service it cannot
  # faithfully list (R8, AC-19).
  def error_message({:invalid_windows, _errors}) do
    "These frequency windows can't be converted. Edit the frequency service, then convert it."
  end

  def error_message(:until_before_start) do
    "The last departure must be at or after the first departure. Use 24:00 or higher after midnight."
  end

  def error_message(:too_many_trips) do
    "Too many trips. Add 200 or fewer at a time by increasing the interval or shortening the time range."
  end

  # The refused services are the calendar IDs whose dates would become mixed (R9).
  # `error_message/1` reads no payload, so it names those IDs rather than the
  # calendars' display names.
  def error_message({:mixed_service, %{service_ids: [service_id]}}) do
    "#{service_id} already runs frequency service on this pattern. " <>
      "Listed trips can't run on the same days. Convert it to scheduled trips first."
  end

  def error_message({:mixed_service, %{service_ids: service_ids}}) do
    "#{Enum.join(service_ids, ", ")} already run frequency service on this pattern. " <>
      "Listed trips can't run on the same days. Convert the frequency service to scheduled trips first."
  end

  # A version whose every calendar was deleted leaves the grid bar's Copy to
  # calendar and Change calendar verbs with no service day to name.
  def error_message(:no_target_calendar) do
    "There is no other service day to copy or move trips to. Add one on Calendars first."
  end

  # The grid cell refusals: each names the fix, never a value the page would have
  # to supply (an error row is rendered from this copy alone).
  def error_message({:out_of_order, _position}) do
    "That time would put the stops out of order. Type a time at or after the previous stop."
  end

  def error_message(:negative_time) do
    "That time is before the service day starts at 00:00. Type a later time."
  end

  def error_message(:clear_not_allowed) do
    "Only a stop between timepoints can be cleared. Change its time instead."
  end

  def error_message({:refused, errors}) do
    case errors do
      [{:error, reason} | _rest] -> error_message(reason)
      _other -> save_failure_copy()
    end
  end

  def error_message(_other), do: save_failure_copy()

  @doc "Returns the sentence a failed save shows while the drawer keeps its input."
  @spec save_failure_copy() :: String.t()
  def save_failure_copy,
    do: "Trips couldn't be saved. Your entries are still here. Try saving again."

  @doc """
  Returns the Add trips drawer's result-card line while a frequency window does not
  read or overlaps (R8). The window row carries the specific message; the card
  points at it, the way the reference's card does.
  """
  @spec frequency_preview_error() :: String.t()
  def frequency_preview_error, do: "Fix the highlighted window to see a preview."

  @doc """
  Returns the sentence the Add trips drawer's "How the trips run" choice shows when
  adding frequency service would mix a service day (R9, AC-20). The caller names the
  service day the way the page labels it.
  """
  @spec mixed_service_choice_message(String.t()) :: String.t()
  def mixed_service_choice_message(service_label) do
    "#{service_label} already has listed trips on this pattern. Frequency service can't " <>
      "run on the same days. Add scheduled trips instead, or choose another service day."
  end

  @doc """
  Returns the sentence a failed delete shows in the confirmation. A reason with its
  own sentence reads the same as in the drawer; anything else says nothing was
  removed, because the save-failure sentence would talk about entries a delete
  does not have.
  """
  @spec delete_error_message(atom() | nil) :: String.t()
  def delete_error_message(reason) do
    copy = error_message(reason)

    if copy == save_failure_copy(),
      do: "The trips couldn't be deleted. Nothing was removed. Try again.",
      else: copy
  end

  # --- drawer helpers --------------------------------------------------------

  defp drawer_title(nil), do: "Add trips"
  defp drawer_title(%{mode: :add}), do: "Add trips"
  defp drawer_title(%{mode: :edit}), do: "Edit trip"
  defp drawer_title(%{mode: :duplicate}), do: "Duplicate trip"

  # The departure leads every drawer. When it can't be edited the overlay falls back
  # to the first enabled field, which is the timing.
  defp drawer_initial_focus_id(nil), do: nil
  defp drawer_initial_focus_id(_drawer), do: "trip-start"

  defp drawer_pattern(nil, _patterns), do: nil

  defp drawer_pattern(%{mode: :add} = drawer, patterns) do
    Enum.find(patterns, &(&1.id == drawer.values["pattern_id"]))
  end

  defp drawer_pattern(%{trip: row} = drawer, patterns) do
    Enum.find(patterns, &(&1.id == drawer.values["pattern_id"])) ||
      Enum.find(patterns, &(&1.route_pattern_id == row.route_pattern_id))
  end

  defp pattern_options(patterns) do
    Enum.map(patterns, &{&1.name, &1.id})
  end

  defp timing_select_options(%{mode: :edit} = drawer, pattern) do
    timings = if(pattern, do: pattern.timings, else: [])

    custom_option =
      if drawer.custom?,
        do: [{"Keep custom times", "custom"}],
        else: []

    # A custom trip whose stops differ cannot adopt a timing at all, so every
    # "Use timing" choice is disabled with the reason in visible text below.
    disabled? = drawer.custom? and drawer.stops_differ?

    custom_option ++ Enum.map(timings, &timing_option(&1, drawer.custom?, disabled?))
  end

  defp timing_select_options(_drawer, pattern) do
    timings = if(pattern, do: pattern.timings, else: [])
    Enum.map(timings, &timing_option(&1, false, false))
  end

  defp timing_option(timing, custom?, disabled?) do
    prefix = if custom?, do: "Use timing: ", else: ""
    total = timing_total_minutes(timing)
    label = "#{prefix}#{timing.name} · #{total} min total"

    if disabled?,
      do: [key: label, value: timing.id, disabled: "disabled"],
      else: {label, timing.id}
  end

  defp timing_total_minutes(timing) do
    timing
    |> Map.get(:rows, [])
    |> Enum.map(fn row ->
      Map.get(row, :arrival_offset) || Map.get(row, :departure_offset) || 0
    end)
    |> Enum.max(fn -> 0 end)
    |> div(60)
  end

  defp accessibility_options(positive, negative) do
    [
      {"No information", "0"},
      {positive, "1"},
      {negative, "2"}
    ]
  end

  defp departure_label(:add), do: "First departure"
  defp departure_label(:duplicate), do: "Departure of the new trip"
  defp departure_label(_mode), do: "Departure"

  defp departure_disabled?(_drawer, _custom?, true), do: true

  defp departure_disabled?(%{mode: :edit} = drawer, true, _freq),
    do: drawer.values["timed_pattern_id"] == "custom"

  defp departure_disabled?(_drawer, _custom?, _freq), do: false

  defp departure_reason(_drawer, _custom?, true) do
    "Frequency service has no single departure to edit. Its windows are shown below."
  end

  defp departure_reason(_drawer, true, _freq) do
    "Choose a timing to change this trip's departure or stop times."
  end

  defp departure_reason(_drawer, _custom?, _freq), do: nil

  # A departure that can't be edited says why in the field's own help; otherwise the
  # help says how to write one. Both stay readable without the colour of an error.
  defp departure_help(drawer, custom?, frequency?) do
    if departure_disabled?(drawer, custom?, frequency?) do
      departure_reason(drawer, custom?, frequency?)
    else
      "Use 24-hour time, like 06:00. After midnight, keep counting: 25:10 is 1:10 AM the next day."
    end
  end

  defp frequency_title(%{trip: row}) when is_map(row) do
    case row.frequency_label do
      nil -> "This trip runs on a frequency"
      label -> "This trip runs #{String.downcase(label)}"
    end
  end

  defp frequency_title(_drawer), do: "This trip runs on a frequency"

  # Names the headsign a blank field will store: the selected timing's, else the
  # pattern's (`Schedules.fallback_headsign/2`), never the trip's own headsign.
  defp headsign_help(%{values: values}, pattern) when is_map(pattern) do
    timing = Enum.find(pattern.timings, &(&1.id == values["timed_pattern_id"]))

    case Schedules.fallback_headsign(timing && timing.headsign, pattern.headsign) do
      nil -> nil
      headsign -> "Leave blank to use #{headsign}."
    end
  end

  defp headsign_help(_drawer, _pattern), do: nil

  defp can_submit?(%{mode: :add}, nil), do: false
  defp can_submit?(%{mode: :add}, pattern), do: pattern.timings != []
  defp can_submit?(%{mode: :edit}, _pattern), do: true
  defp can_submit?(_drawer, pattern), do: pattern != nil and pattern.timings != []

  # Adding frequency service keeps the drawer's one primary in place but out of
  # reach while the windows do not read or the service day was refused (R8,
  # FH-35); every other drawer leaves the primary available and refuses the save
  # itself, keeping the typed value.
  defp submit_disabled?(drawer) do
    (frequency_add?(drawer) or frequency_edit?(drawer)) and
      (drawer_refusal(drawer) != nil or not is_nil(drawer.preview.error))
  end

  defp error_list(%{errors: errors}, field) do
    case Map.get(errors, field) do
      nil -> []
      message -> [message]
    end
  end

  # --- empty states ----------------------------------------------------------------

  @doc "Renders the first-use state for a version that has no calendars."
  attr :new_calendar_path, :string, required: true

  def no_calendars(assigns) do
    ~H"""
    <div class="mt-8">
      <.first_use id="schedules-no-calendars" title="This version has no calendars yet">
        Service days such as Weekday and Saturday come from calendars. Create a calendar, then add
        trips to it.
        <:action>
          <.button navigate={@new_calendar_path} class="min-h-11">
            <.icon name="hero-plus" class="size-4" /> Create calendar
          </.button>
        </:action>
      </.first_use>
    </div>
    """
  end

  @doc "Renders the first-use state for a route that has no patterns."
  attr :route, :map, required: true
  attr :new_pattern_path, :string, required: true

  def no_patterns(assigns) do
    ~H"""
    <div class="mt-8">
      <.first_use
        id="schedules-no-patterns"
        title={"Route #{route_label(@route)} has no patterns yet"}
      >
        A pattern is the ordered list of stops a trip serves. Create a pattern and a timing, then
        add departures.
        <:action>
          <.button navigate={@new_pattern_path} class="min-h-11">
            <.icon name="hero-plus" class="size-4" /> Create pattern
          </.button>
        </:action>
      </.first_use>
    </div>
    """
  end

  @doc """
  Renders the empty view for the chosen service day, direction and pattern. Each
  situation says what is missing and offers the one step that resolves it: adding
  a timing when no pattern can take a trip, showing every pattern when one pattern
  has none, adding the first trip otherwise.
  """
  attr :route, :map, required: true
  attr :calendar_label, :string, required: true
  attr :direction_label, :string, required: true
  attr :pattern_name, :string, default: nil

  attr :any_trips?, :boolean,
    required: true,
    doc: "whether the route has trips on any service day"

  attr :can_add?, :boolean, required: true
  attr :timing_path, :string, required: true, doc: "where a timing is added"

  def no_trips(assigns) do
    ~H"""
    <div class="mt-8">
      <.first_use id="schedules-no-trips" title={no_trips_title(assigns)}>
        {no_trips_body(assigns)}
        <:action :if={not @can_add?}>
          <.button navigate={@timing_path} class="min-h-11">
            <.icon name="hero-plus" class="size-4" /> Add timing
          </.button>
        </:action>
        <:action :if={@can_add? and @pattern_name != nil}>
          <.button
            id="schedules-show-all-patterns"
            type="button"
            variant="secondary"
            class="min-h-11"
            phx-click="filters"
            phx-value-pattern="all"
          >
            Show all patterns
          </.button>
        </:action>
        <:action :if={@can_add? and @pattern_name == nil}>
          <.button
            id="schedules-empty-add-trips"
            type="button"
            class="min-h-11"
            phx-click="open_add_drawer"
            phx-disconnected={unavailable_offline()}
            phx-connected={available_online()}
          >
            <.icon name="hero-plus" class="size-4" /> Add trips
          </.button>
        </:action>
      </.first_use>
    </div>
    """
  end

  defp no_trips_title(%{can_add?: false}), do: "Add a timing before adding trips"

  defp no_trips_title(%{pattern_name: pattern_name} = assigns) when pattern_name != nil,
    do: "No #{assigns.calendar_label} trips on this pattern"

  defp no_trips_title(%{any_trips?: false} = assigns),
    do: "Route #{route_label(assigns.route)} has no trips yet"

  defp no_trips_title(assigns),
    do: "No #{assigns.calendar_label} trips going #{direction_phrase(assigns.direction_label)}"

  defp no_trips_body(%{can_add?: false}) do
    "A timing sets the running time between stops. Trips can't be added until a pattern has one."
  end

  defp no_trips_body(%{pattern_name: pattern_name}) when pattern_name != nil do
    "Show all patterns to see every trip going this way."
  end

  defp no_trips_body(_assigns), do: "Add the first departure using a pattern and timing."

  defp direction_phrase("To " <> destination), do: "to #{destination}"
  defp direction_phrase(label), do: label

  # --- filtered-empty state --------------------------------------------------

  @doc """
  Renders the filtered-empty state of AC-22: the Custom times filter is on and no
  row in this view has custom times. Show all trips clears the parameter, which
  brings the view's trips back.

  It is deliberately not the first-use card: the view has trips, the filter is
  what emptied it, and the copy and action say so.
  """
  attr :calendar_label, :string, required: true
  attr :direction_label, :string, required: true

  def custom_empty(assigns) do
    ~H"""
    <div class="mt-8">
      <.first_use
        id="custom-empty"
        title={"No trips with custom times on #{@calendar_label} · #{@direction_label}"}
      >
        Every trip in this view follows a timing. The Custom times filter is on.
        <:action>
          <.button
            id="clear-custom"
            type="button"
            variant="secondary"
            class="min-h-11"
            phx-click="filters"
            phx-value-custom="0"
          >
            Show all trips
          </.button>
        </:action>
      </.first_use>
    </div>
    """
  end

  # --- sections --------------------------------------------------------------------

  @doc """
  Renders one pattern section as a card: its heading, headway bands, the timings
  in use, and its timetable. The stop columns after the first sit in a labelled,
  focusable scroll region whose header row stays in view; the footnotes under it
  appear only when they explain something the table shows.
  """
  attr :section, :map, required: true
  attr :selected_ids, :any, required: true
  attr :calendar_label, :string, required: true

  attr :export_defaults_path, :string,
    default: nil,
    doc: "link behind the estimate note; nil renders the note without a link"

  def section(assigns) do
    section = assigns.section
    rows = section.rows

    # An imported pattern keeps its listed and frequency trips editable; the band
    # names the mix and offers Convert so a planner can retire the frequency
    # service (R9, AC-20). The button opens the section's first frequency row.
    first_frequency = Enum.find(rows, & &1.frequency?)
    mixed? = first_frequency != nil and Enum.any?(rows, &(not &1.frequency?))

    {first_stop, stop_columns} =
      case section.columns do
        [first | rest] -> {first, rest}
        [] -> {nil, []}
      end

    assigns =
      assigns
      |> assign(:rows, rows)
      |> assign(:mixed?, mixed?)
      |> assign(:first_frequency_id, first_frequency && first_frequency.id)
      |> assign(:section_id, section.pattern.route_pattern_id)
      |> assign(:first_stop, first_stop)
      |> assign(:first_position, first_stop && first_stop.position)
      |> assign(:stop_columns, stop_columns)
      |> assign(:grid, grid(section))
      |> assign(
        :timing_totals,
        Map.new(section.timing_lines, &{&1.timing_id, round_minutes(&1.total_secs)})
      )
      |> assign(
        :all_selected?,
        rows != [] and Enum.all?(rows, &MapSet.member?(assigns.selected_ids, &1.id))
      )
      |> assign(:after_midnight?, after_midnight?(rows))
      |> assign(:missing_times?, missing_times?(rows, stop_columns))
      |> assign(:estimate_method, Map.get(section, :estimate_method))
      |> assign(:estimate_note, estimate_note(rows, Map.get(section, :estimate_method)))
      |> assign(:estimated_cells?, estimated_cells?(rows))

    ~H"""
    <section
      aria-labelledby={"section-#{@section_id}-heading"}
      class="overflow-clip rounded-card border border-subtle bg-white"
    >
      <div class="px-5 pb-4 pt-4">
        <div class="flex flex-wrap items-baseline justify-between gap-x-6 gap-y-1">
          <h2
            id={"section-#{@section_id}-heading"}
            class="flex flex-wrap items-center gap-x-3 gap-y-1 font-display text-[22px] font-semibold tracking-[-0.02em] text-strong"
          >
            {@section.pattern.route_pattern_name || @section.pattern.route_pattern_id}
            <span class="inline-flex rounded-badge bg-canvas px-2 py-0.5 font-sans text-[13px] font-[650] tracking-normal text-muted">
              {RoutePattern.typicality_label(@section.pattern.route_pattern_typicality)}
            </span>
          </h2>
          <p id={"section-#{@section_id}-facts"} class="text-sm tabular-nums text-muted">
            {facts_text(@section, length(@rows))}
          </p>
        </div>

        <dl class="mt-2 grid gap-x-6 gap-y-1 text-sm sm:grid-cols-[110px_minmax(0,1fr)]">
          <dt class="text-muted">Departures</dt>
          <dd class="flex flex-wrap gap-x-6 gap-y-1">
            <.band
              :for={{band, index} <- Enum.with_index(@section.bands)}
              id={"section-#{@section_id}-band-#{index}"}
              band={band}
            />
          </dd>
          <dt class="text-muted">Timings</dt>
          <dd>
            <div class="flex flex-wrap items-center gap-x-6 gap-y-1">
              <span
                :for={line <- @section.timing_lines}
                id={"section-#{@section_id}-timing-#{line.timing_id}"}
                class="tabular-nums"
              >
                <span class="font-semibold text-strong">{line.name}</span>
                {round_minutes(line.total_secs)} min ·
                <span class="text-muted">{trip_count(line.trip_count)}</span>
              </span>
              <span
                :if={@section.custom_trip_count > 0}
                id={"section-#{@section_id}-custom-trips"}
                class="tabular-nums"
              >
                <span class="font-semibold text-strong">Custom times</span>
                · <span class="text-muted">{trip_count(@section.custom_trip_count)}</span>
              </span>
              <details
                :if={@section.timing_lines != []}
                id={"section-#{@section_id}-timing-detail"}
                class="group contents"
              >
                <summary class={[
                  "-my-2 inline-flex min-h-11 cursor-pointer list-none items-center gap-1 rounded-control font-[650] text-action hover:underline [&::-webkit-details-marker]:hidden",
                  focus_inset()
                ]}>
                  <.icon
                    name="hero-chevron-right"
                    class="size-4 transition-transform group-open:rotate-90"
                  />
                  {minutes_between_label(@section.stops)}
                </summary>
                <ul class="mt-1 grid w-full gap-1 pb-1">
                  <li
                    :for={line <- @section.timing_lines}
                    id={"section-#{@section_id}-timing-#{line.timing_id}-segments"}
                    class="tabular-nums"
                  >
                    <span class="font-semibold text-strong">{line.name}</span>
                    · {segments_text(line)}{round_minutes(line.total_secs)} min total
                  </li>
                </ul>
              </details>
            </div>
          </dd>
        </dl>
      </div>

      <.message
        :if={@mixed?}
        id={"section-#{@section_id}-mixed-service-warning"}
        kind="warning"
        class="rounded-none border-y border-warning-line px-5"
        title="This pattern runs listed trips and frequency service on the same days."
      >
        Trip planners may show only one kind. Convert the frequency service to scheduled trips.
        <:action>
          <.button
            id={"section-#{@section_id}-mixed-convert"}
            type="button"
            variant="secondary"
            class="min-h-11"
            phx-click="open_change"
            phx-value-kind="convert"
            phx-value-trip={@first_frequency_id}
          >
            Convert…
          </.button>
        </:action>
      </.message>

      <div :if={@estimate_note} class="px-5 pb-1 pt-3">
        <.message
          :if={@estimate_note.kind == :estimate}
          id={"section-#{@section_id}-estimate-note"}
          kind="info"
          title={@estimate_note.title}
        >
          Exports estimate them by {@estimate_note.method_label}. They're shown here in
          italics and aren't saved in the trips.
          <:action :if={@export_defaults_path}>
            <.link
              navigate={@export_defaults_path}
              class={[
                "inline-flex min-h-11 items-center text-sm font-[650] text-action hover:underline",
                focus_inset()
              ]}
            >
              Export defaults
            </.link>
          </:action>
        </.message>
        <.message
          :if={@estimate_note.kind == :left_blank}
          id={"section-#{@section_id}-estimate-note"}
          kind="warning"
          role="status"
          title={@estimate_note.title}
        >
          Exports leave them blank, so each rider app will guess them its own way.
          <:action :if={@export_defaults_path}>
            <.link
              navigate={@export_defaults_path}
              class={[
                "inline-flex min-h-11 items-center text-sm font-[650] underline underline-offset-4",
                focus_inset()
              ]}
            >
              Export defaults
            </.link>
          </:action>
        </.message>
      </div>

      <div
        id={"section-#{@section_id}-table-container"}
        tabindex="0"
        role="region"
        aria-label={"#{@calendar_label} timetable, #{@section.pattern.route_pattern_name || @section.pattern.route_pattern_id}"}
        class={[
          "max-h-[min(640px,calc(100dvh-180px))] overflow-auto border-t border-subtle",
          focus_inset()
        ]}
      >
        <table
          id={"section-#{@section_id}-table"}
          class="w-full border-separate border-spacing-0 text-left"
        >
          <thead>
            <tr>
              <th scope="col" class={[th_class(), "z-30", selection_cell_class()]}>
                <label class="flex min-h-11 min-w-11 items-center justify-center">
                  <input
                    type="checkbox"
                    id={"section-#{@section_id}-select-all"}
                    checked={@all_selected?}
                    phx-click="toggle_section"
                    phx-value-section={"section-#{@section_id}"}
                    phx-disconnected={JS.set_attribute({"disabled", ""})}
                    phx-connected={JS.remove_attribute("disabled")}
                    aria-label="Select every trip in this timetable"
                    class="size-[18px] accent-action"
                  />
                </label>
              </th>
              <th scope="col" class={[th_class(), "z-30", departs_cell_class()]}>
                <span class="block">Departs</span>
                <span :if={@first_stop} class="block max-w-[150px] text-[12px] font-normal text-muted">
                  {@first_stop.stop_name}
                </span>
              </th>
              <th
                :for={column <- @stop_columns}
                scope="col"
                class={[th_class(), "z-20 min-w-[116px] text-right"]}
              >
                <span class="block" title={column.stop_name}>{column.stop_name}</span>
                <span class="block text-[12px] font-normal tabular-nums text-muted">
                  {column.stop_code}
                </span>
              </th>
              <th scope="col" class={[th_class(), "z-20 min-w-[210px] text-left"]}>Timing</th>
              <th scope="col" class={[th_class(), "z-20 min-w-[72px] text-left"]}>Block</th>
              <th scope="col" class={[th_class(), "z-20 min-w-[124px] text-left"]}>Trip</th>
              <th scope="col" class={[th_class(), actions_cell_class(), "z-20 sm:z-30"]}>Actions</th>
            </tr>
          </thead>
          <tbody>
            <%= for row <- @rows do %>
              <% preview = Map.get(@grid.preview, row.id, %{})
              cell_error = cell_error_for(@grid, row) %>
              <tr
                id={"trip-#{row.trip_id}"}
                data-sel={to_string(MapSet.member?(@selected_ids, row.id))}
                data-frequency={row.frequency?}
                class={["group", MapSet.member?(@grid.just_changed, row.id) && "is-changed"]}
              >
                <td class={[td_class(), "z-10", selection_cell_class()]}>
                  <label class="flex min-h-11 min-w-11 items-center justify-center">
                    <input
                      type="checkbox"
                      id={"trip-select-#{row.trip_id}"}
                      checked={MapSet.member?(@selected_ids, row.id)}
                      phx-click="toggle_trip"
                      phx-value-trip={row.id}
                      phx-disconnected={JS.set_attribute({"disabled", ""})}
                      phx-connected={JS.remove_attribute("disabled")}
                      aria-label={"Select trip #{row.trip_id}"}
                      class="size-[18px] accent-action"
                    />
                  </label>
                </td>
                <td
                  id={@first_position && "cell-#{row.trip_id}-#{@first_position}"}
                  data-trip={row.id}
                  data-pos={@first_position}
                  data-readonly={row.stops_differ?}
                  tabindex="-1"
                  title={preview_title(preview, @first_position, row.start_cell)}
                  class={[
                    td_class(),
                    "z-10 py-2",
                    departs_cell_class(),
                    preview_class(preview, @first_position, row.start_cell),
                    error_class(cell_error, @first_position)
                  ]}
                >
                  <% departs = shown_cell(@first_position, row.start_cell, preview) %>
                  <span
                    id={"trip-#{row.trip_id}-start"}
                    class="text-[15px] font-bold tabular-nums text-strong"
                    title={departs.title}
                  >
                    {departs.text}
                  </span>
                  <span
                    :if={departs.marker}
                    id={"trip-#{row.trip_id}-marker"}
                    class="ml-1 text-[12px] font-normal text-muted"
                  >
                    {day_marker(departs.marker)}
                  </span>
                </td>
                <td
                  :if={row.stops_differ? and @stop_columns != []}
                  id={"trip-#{row.trip_id}-stops-differ"}
                  colspan={length(@stop_columns)}
                  class={[td_class(), "text-center text-[13px] italic text-muted"]}
                >
                  Stops differ from this pattern, so its times aren't shown here.
                </td>
                <td
                  :for={column <- @stop_columns}
                  :if={not row.stops_differ?}
                  id={"cell-#{row.trip_id}-#{column.position}"}
                  data-trip={row.id}
                  data-pos={column.position}
                  data-estimated={Map.get(row_cell(row, column), :estimated?, false)}
                  tabindex="-1"
                  title={preview_title(preview, column.position, row_cell(row, column))}
                  class={[
                    td_class(),
                    "whitespace-nowrap text-right text-sm tabular-nums",
                    row.frequency? && "italic text-muted",
                    not row.frequency? && "text-default",
                    preview_class(preview, column.position, row_cell(row, column)),
                    error_class(cell_error, column.position)
                  ]}
                >
                  <.timetable_cell cell={shown_cell(column.position, row_cell(row, column), preview)} />
                </td>
                <td
                  id={"cell-#{row.trip_id}-timing"}
                  data-trip={row.id}
                  tabindex="-1"
                  class={[td_class(), "py-2 text-left text-sm"]}
                >
                  <span class="block whitespace-nowrap">
                    <%= if row.custom? do %>
                      <span class="inline-flex rounded-badge bg-warning-bg px-2 py-0.5 text-[13px] font-[650] text-warning-fg">
                        Custom times
                      </span>
                    <% else %>
                      <span class="font-semibold text-strong">{row.timing}</span>
                      <span class="tabular-nums text-muted">
                        {timing_minutes(@timing_totals, row)}
                      </span>
                    <% end %>
                  </span>
                  <span
                    :if={estimate_problem_text(Map.get(row, :estimate_problem))}
                    id={"trip-#{row.trip_id}-estimate-problem"}
                    class="mt-1 inline-flex rounded-badge bg-warning-bg px-2 py-0.5 text-[13px] font-[650] text-warning-fg"
                    role="img"
                    aria-label={estimate_problem_text(Map.get(row, :estimate_problem))}
                  >
                    <.icon name="hero-exclamation-triangle" class="mr-1 size-3.5" />
                    {estimate_problem_text(Map.get(row, :estimate_problem))}
                  </span>
                  <%!-- Today's display over the new Timetable headsign shapes;
                       step 16 owns the final markup (warning ink, "No headsign"). --%>
                  <%= case row.headsign do %>
                    <% {:differs, value, _kind} -> %>
                      <span class="block text-[12px] text-muted">
                        To {value}
                      </span>
                    <% _ -> %>
                  <% end %>
                  <span
                    :if={row.frequency_label}
                    id={"trip-#{row.trip_id}-frequency"}
                    class="block text-[12px] text-muted"
                  >
                    Frequency service · {row.frequency_label}
                  </span>
                </td>
                <td class={[td_class(), "whitespace-nowrap text-left text-sm tabular-nums"]}>
                  <%= if present?(row.block_id) do %>
                    {row.block_id}
                  <% else %>
                    <span class="text-muted">—</span>
                  <% end %>
                </td>
                <td class={[td_class(), "whitespace-nowrap text-left text-sm"]}>
                  <%= if present?(row.trip_short_name) do %>
                    <span class="tabular-nums text-default">{row.trip_short_name}</span>
                  <% else %>
                    <span
                      class="font-mono text-[12px] text-muted"
                      title="No trip number. Showing the trip ID."
                    >
                      {row.trip_id}
                    </span>
                  <% end %>
                </td>
                <td class={[td_class(), "z-10", actions_cell_class()]}>
                  <.row_actions row={row} />
                </td>
              </tr>
              <tr :if={cell_error} id={"trip-#{row.trip_id}-error"} class="err-row">
                <td
                  colspan={length(@stop_columns) + 6}
                  class="border-b border-subtle bg-error-bg px-0 py-2"
                >
                  <p class="sticky left-0 flex max-w-[900px] items-start gap-2 px-4 text-sm font-[650] text-error-fg">
                    <.icon name="hero-exclamation-triangle" class="mt-0.5 size-4" />
                    <span>{cell_error.message}</span>
                  </p>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>

      <div class="grid gap-1 border-t border-subtle px-5 py-3 text-[13px] text-muted">
        <p id={"section-#{@section_id}-stops-legend"}>
          <%= if @section.stops == :all do %>
            All stops shown. Scroll the timetable to see more stops.
          <% else %>
            Timepoints are the key stops used in public timetables.
            <span :if={@section.omitted_stop_count > 0} id={"section-#{@section_id}-omitted"}>
              {stop_count(@section.omitted_stop_count)} not shown.
            </span>
          <% end %>
        </p>
        <p :if={@after_midnight?} id={"section-#{@section_id}-after-midnight"}>
          After midnight, hours keep counting: <span class="font-mono">25:10</span>
          is 1:10 AM the next day. The trip still belongs to this service day.
        </p>
        <p :if={@missing_times?} id={"section-#{@section_id}-missing-times"}>
          — means no time is recorded for that stop.
        </p>
        <p :if={@estimated_cells?} id={"section-#{@section_id}-estimate-legend"}>
          <span class="italic tabular-nums text-cyan-800 underline decoration-cyan-600 decoration-dotted decoration-2 underline-offset-4">
            08:14
          </span>
          estimated when exported, not saved.
        </p>
      </div>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :band, :map, required: true

  defp band(assigns) do
    {window, what, tail} = band_parts(assigns.band)
    assigns = assign(assigns, window: window, what: what, tail: tail)

    ~H"""
    <span id={@id} class="tabular-nums">
      <span class="text-default">{@window}</span>
      <span :if={@what}>· <span class="font-semibold text-strong">{@what}</span></span>
      · <span class="text-muted">{@tail}</span>
    </span>
    """
  end

  @doc "Renders one formatted timetable cell with its day marker."
  attr :cell, :map, required: true

  def timetable_cell(assigns) do
    estimated? = Map.get(assigns.cell, :estimated?, false)
    assigns = assign(assigns, :estimated?, estimated?)

    ~H"""
    <span>
      <span
        class={
          if @estimated? do
            "italic tabular-nums text-cyan-800 underline decoration-cyan-600 decoration-dotted decoration-2 underline-offset-4"
          else
            ["tabular-nums", @cell.missing? && "text-muted"]
          end
        }
        title={cell_title(@cell, @estimated?)}
      >
        {@cell.text}
      </span>
      <span :if={@cell.marker} class="ml-1 text-[12px] text-muted">{day_marker(@cell.marker)}</span>
    </span>
    """
  end

  # --- helpers ---------------------------------------------------------------

  defp th_class, do: @th
  defp td_class, do: @td
  defp selection_cell_class, do: @selection_cell
  defp departs_cell_class, do: @departs_cell
  defp actions_cell_class, do: @actions_cell
  defp focus_inset, do: @focus_inset

  defp calendar_options(calendars) do
    Enum.map(calendars, fn calendar ->
      {calendar_option_label(calendar), calendar.service_id}
    end)
  end

  defp calendar_option_label(calendar) do
    kind = if calendar.kind == :dates_only, do: " · Specific dates", else: ""
    "#{calendar_name(calendar)} · #{trip_count(calendar.route_trip_count)}#{kind}"
  end

  defp calendar_toggle_options(calendars) do
    Enum.map(calendars, fn calendar ->
      %{
        value: calendar.service_id,
        label: calendar_name(calendar),
        count: calendar.route_trip_count
      }
    end)
  end

  defp calendar_name(calendar), do: calendar.name || calendar.service_id

  defp pattern_options(patterns, filters) do
    direction_patterns = Enum.filter(patterns, &(&1.direction_id == filters.direction_id))
    [{"All patterns", "all"} | Enum.map(direction_patterns, &{&1.name, &1.id})]
  end

  defp direction_options(direction_labels) do
    for direction_id <- [0, 1] do
      %{value: to_string(direction_id), label: direction_labels[direction_id], count: nil}
    end
  end

  defp route_label(route), do: route.route_short_name || route.route_id

  defp trip_count(1), do: "1 trip"
  defp trip_count(count), do: "#{count} trips"

  defp stop_count(1), do: "1 stop"
  defp stop_count(count), do: "#{count} stops"

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp hour_label(hour), do: hour |> Integer.to_string() |> String.pad_leading(2, "0")

  defp hour_title(hour) when hour >= 24, do: "#{hour_label(hour - 24)}:00 the next day"
  defp hour_title(_hour), do: nil

  defp hour_count_label(0, _approximate?), do: "0"
  defp hour_count_label(count, true), do: "≈#{count}"
  defp hour_count_label(count, _approximate?), do: Integer.to_string(count)

  # The visible marker reads as words, next to a time that has passed midnight.
  defp day_marker("+1"), do: "+1 day"
  defp day_marker(marker), do: "#{marker} days"

  defp row_cell(row, column) do
    Map.get(row.cells, column.position) ||
      %{text: "—", marker: nil, title: nil, missing?: true, estimated?: false}
  end

  # The grid state a section carries (see `@empty_grid`): the times a review
  # previews without writing, the trips the last write touched, and the one cell
  # a refused write points at.
  defp grid(section), do: Map.get(section, :grid) || @empty_grid

  defp cell_error_for(%{cell_error: %{trip: trip} = error}, row) when trip == row.id, do: error
  defp cell_error_for(_grid, _row), do: nil

  # A reviewed preview replaces the stored cell; a nil preview value is a cleared
  # cell. A stop with no stored time that stays blank is not a change, so it keeps
  # its stored rendering (an estimate stays an estimate). The position comes from
  # the occurrence, so the Departs cell and its stop column share one cell.
  defp shown_cell(position, stored, preview) do
    if previewed?(preview, position, stored),
      do: preview_cell(Map.fetch!(preview, position)),
      else: stored
  end

  defp previewed?(preview, position, stored) do
    case Map.fetch(preview, position) do
      {:ok, nil} -> not blank_cell?(stored)
      {:ok, _seconds} -> true
      :error -> false
    end
  end

  defp blank_cell?(cell), do: cell.missing? or Map.get(cell, :estimated?, false)

  defp preview_cell(nil) do
    %{text: "—", marker: nil, title: nil, missing?: true}
  end

  defp preview_cell(seconds) do
    %{text: preview_clock(seconds), marker: preview_marker(seconds), title: nil, missing?: false}
  end

  # The same clock rules a stored cell uses: seconds appear only when nonzero.
  defp preview_clock(seconds) do
    formatted = GtfsTime.format(seconds)

    if String.ends_with?(formatted, ":00"),
      do: binary_part(formatted, 0, byte_size(formatted) - 3),
      else: formatted
  end

  defp preview_marker(seconds) do
    days = div(seconds, 86_400)
    if days >= 1, do: "+#{days}"
  end

  # The title names the stored value; an estimate was never stored, so it reads "—".
  defp preview_title(preview, position, stored) do
    if previewed?(preview, position, stored),
      do: "Was #{if Map.get(stored, :estimated?, false), do: "—", else: stored.text}"
  end

  defp preview_class(preview, position, stored) do
    if previewed?(preview, position, stored), do: "is-preview"
  end

  defp error_class(%{position: error_position}, position) when error_position == position,
    do: "is-error"

  defp error_class(_error, _position), do: nil

  defp after_midnight?(rows) do
    Enum.any?(rows, fn row ->
      row.start_cell.marker != nil or
        Enum.any?(row.cells, fn {_position, cell} -> cell.marker end)
    end)
  end

  defp missing_times?(rows, stop_columns) do
    Enum.any?(rows, fn row ->
      not row.stops_differ? and Enum.any?(stop_columns, &row_cell(row, &1).missing?)
    end)
  end

  # The estimate note above the table (spec 23, AC-26): with estimation on, the
  # trips with blanks name the export method; with estimation off, the same
  # trips warn that exports leave them blank. Either way there is no "Save
  # estimates" action — bulk writes belong to spec 18.
  defp estimate_note(rows, nil), do: blank_trips_note(rows)

  defp estimate_note(rows, method) do
    blanks = Enum.filter(rows, &row_has_blanks?/1)

    if blanks == [] do
      nil
    else
      %{
        kind: :estimate,
        title: blank_trips_title(blanks),
        method_label: estimate_method_label(method)
      }
    end
  end

  # With estimation off the note still names the trips with blanks, so the
  # sch-off state explains why every rider app will guess them its own way.
  defp blank_trips_note(rows) do
    blanks = Enum.filter(rows, &row_has_blanks?/1)

    if blanks == [], do: nil, else: %{kind: :left_blank, title: blank_trips_title(blanks)}
  end

  defp row_has_blanks?(row) do
    row.custom? and not row.stops_differ? and
      (Enum.any?(row.cells, fn {_position, cell} -> Map.get(cell, :estimated?, false) end) or
         Map.get(row, :estimate_problem) != nil or
         Enum.any?(row.cells, fn {_position, cell} -> cell.missing? end))
  end

  defp blank_trips_title([_single]), do: "1 trip has missing times"
  defp blank_trips_title(blanks), do: "#{length(blanks)} trips have missing times"

  defp estimate_method_label(:even), do: "equal time per stop"
  defp estimate_method_label(_method), do: "distance along the path"

  defp estimated_cells?(rows) do
    Enum.any?(rows, fn row ->
      Enum.any?(row.cells, fn {_position, cell} -> Map.get(cell, :estimated?, false) end)
    end)
  end

  defp estimate_problem_text(:no_first_time), do: "No time at first stop"
  defp estimate_problem_text(:no_last_time), do: "No time at last stop"
  defp estimate_problem_text(:timepoint_without_time), do: "Timepoint without time"
  defp estimate_problem_text(:order), do: "Times out of order"
  defp estimate_problem_text(_reason), do: nil

  # An estimated cell names the exported time and that it is not saved; a day
  # marker title, when present, is kept after it so no signal is lost.
  defp cell_title(cell, true) do
    estimated = "Estimated when exported: #{cell.text}. Not saved in this trip."

    case cell.title do
      nil -> estimated
      title -> estimated <> " " <> title
    end
  end

  defp cell_title(cell, _estimated?), do: cell.title

  defp facts_text(section, row_count) do
    shown = length(section.columns)
    total = length(section.all_columns)

    if shown == total,
      do: "#{trip_count(row_count)} · #{stop_count(total)}",
      else: "#{trip_count(row_count)} · showing #{shown} of #{stop_count(total)}"
  end

  defp minutes_between_label(:all), do: "Minutes between stops"
  defp minutes_between_label(_stops), do: "Minutes between timepoints"

  defp timing_minutes(timing_totals, row) do
    case Map.get(timing_totals, row.timed_pattern_id) do
      nil -> nil
      minutes -> "#{minutes} min"
    end
  end

  defp band_parts(%{kind: :frequency} = band) do
    {"#{clock(band.first_secs)}–#{clock(band.last_secs)}",
     "every #{band.max_headway_minutes} min", "frequency service"}
  end

  defp band_parts(%{kind: :irregular} = band) do
    window =
      if band.first_secs == band.last_secs,
        do: clock(band.first_secs),
        else: "#{clock(band.first_secs)}–#{clock(band.last_secs)}"

    {window, nil, trip_count(band.trip_count)}
  end

  defp band_parts(band) do
    headway =
      if band.min_headway_minutes == band.max_headway_minutes,
        do: "every #{band.min_headway_minutes} min",
        else: "#{band.min_headway_minutes}–#{band.max_headway_minutes} min"

    {"#{clock(band.first_secs)}–#{clock(band.last_secs)}", headway, trip_count(band.trip_count)}
  end

  # The minutes between the displayed stops, with a trailing separator so the total
  # follows on the same line; a timing with no segments has only its total.
  defp segments_text(%{segments: []}), do: ""
  defp segments_text(line), do: Enum.map_join(line.segments, " · ", &round_minutes/1) <> " min · "

  defp round_minutes(seconds), do: round(seconds / 60)

  defp incomplete_times_note(1), do: "1 trip without complete times is not counted."

  defp incomplete_times_note(count),
    do: "#{count} trips without complete times are not counted."

  defp clock(seconds),
    do: seconds |> GtfsTime.format() |> String.split(":") |> Enum.take(2) |> Enum.join(":")
end
