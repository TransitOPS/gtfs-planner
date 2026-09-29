defmodule GtfsPlannerWeb.Gtfs.TimetablePasteComponents do
  @moduledoc """
  Presentation for the Paste timetable page shell.

  Step 21 owns the shell only: the schedule line (`scope_line/1`), the setup
  empty states (`setup_empty/1`) and the first-paint skeleton. The Change
  schedule drawer (step 22), the timetable step (step 23) and the review UI
  (steps 25-28) add components here in later steps.
  """
  use GtfsPlannerWeb, :html

  import GtfsPlannerWeb.PlannerComponents, only: [first_use: 1]

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
