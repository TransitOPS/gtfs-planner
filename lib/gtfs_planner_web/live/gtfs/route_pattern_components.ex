defmodule GtfsPlannerWeb.Gtfs.RoutePatternComponents do
  @moduledoc """
  Function components for the route pattern editor.

  The patterns list, the pattern detail header, the Details task, the ordered
  Stops task and the Timings task each render one region of the editor. State
  decisions stay in `GtfsPlannerWeb.Gtfs.RoutePatternLive`; these components
  only present the loaded values, the staged task state and the specified copy.
  """

  use GtfsPlannerWeb, :html

  alias GtfsPlanner.Gtfs.GtfsTime
  alias GtfsPlanner.Gtfs.RoutePattern

  @doc """
  Renders the route's pattern list with its counts, direction grouping and
  per-pattern stop/trip/timing figures.

  Rows are the caller's stream tuples; the count strip stays a separate assign
  so the list never has to be enumerable.
  """
  attr :patterns, :any, required: true
  attr :rest, :global

  def pattern_list(assigns) do
    ~H"""
    <div {@rest}>
      <.table
        id="patterns-list"
        rows={@patterns}
        responsive="stack"
        row_item={fn {_id, summary} -> summary end}
      >
        <:col :let={summary} label="Pattern / service">
          <button
            type="button"
            id={"pattern-open-#{summary.id}"}
            phx-click="open_pattern"
            phx-value-pattern-id={summary.pattern.route_pattern_id}
            class="inline-flex min-h-11 items-center text-left font-semibold text-primary underline-offset-2 hover:underline focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary"
          >
            {summary.pattern.route_pattern_name || summary.pattern.route_pattern_id}
          </button>
          <div class="mt-0.5 text-sm text-base-content/70">
            {summary.pattern.route_pattern_time_desc || "No service description"}
            <span aria-hidden="true">·</span>
            {timing_count_label(summary.timing_count)}
          </div>
        </:col>
        <:col :let={summary} label="Direction">
          {RoutePattern.direction_label(summary.pattern.direction_id)}
        </:col>
        <:col :let={summary} label="Use on this route">
          <span class={["badge badge-sm", typicality_class(summary.pattern.route_pattern_typicality)]}>
            {RoutePattern.typicality_label(summary.pattern.route_pattern_typicality)}
          </span>
        </:col>
        <:col :let={summary} label="Stops" align="right">
          <span class="tabular-nums">{summary.stop_count}</span>
        </:col>
        <:col :let={summary} label="Trips" align="right">
          <span class="tabular-nums">{trip_count_label(summary.trip_count)}</span>
        </:col>
      </.table>
    </div>
    """
  end

  @doc """
  Renders the Patterns list screen and its non-ideal states: a stale refresh
  that keeps the last loaded rows, a partial build with pending trips, a bounded
  derivation error, the unlinked-trips call to action, the honest blocked state
  and first use.
  """
  attr :patterns, :any, required: true
  attr :patterns_empty?, :boolean, required: true
  attr :pattern_count, :integer, required: true
  attr :route_trip_count, :integer, required: true
  attr :pending_trip_count, :integer, required: true
  attr :custom_trip_count, :integer, required: true
  attr :derivation_error, :string, default: nil
  attr :build_state, :atom, required: true
  attr :build_error, :string, default: nil
  attr :stale?, :boolean, required: true
  attr :new_path, :string, required: true

  def pattern_list_states(assigns) do
    assigns =
      assign(
        assigns,
        :blocked?,
        assigns.build_state == :blocked or
          (assigns.patterns_empty? and assigns.pending_trip_count == 0 and
             assigns.custom_trip_count > 0)
      )

    ~H"""
    <div>
      <.callout :if={@stale?} kind="warning" id="patterns-stale" title="Patterns may be out of date">
        The last loaded patterns and counts remain available. Refresh to try again.
      </.callout>

      <%= cond do %>
        <% not @patterns_empty? -> %>
          <div class="flex flex-wrap items-center justify-between gap-3">
            <h2 id="patterns-heading" class="text-xl font-semibold">Patterns</h2>
            <.link navigate={@new_path} id="patterns-create" class="btn btn-primary min-h-11">
              Create pattern
            </.link>
          </div>
          <p class="mt-1 text-sm text-base-content/70">
            Each pattern has a stop order and reusable timings. Trips use a pattern to run that service.
          </p>

          <div class="mt-4">
            <.pattern_count_strip pattern_count={@pattern_count} trip_count={@route_trip_count} />
          </div>

          <div :if={@pending_trip_count > 0} class="mt-3">
            <.callout kind="info" id="patterns-partial" title="Some trips are not grouped yet">
              <strong class="tabular-nums">{@pending_trip_count}</strong>
              trips on this route do not use a pattern yet. Build patterns from their stop order and direction; their current times stay unchanged.
              <div class="mt-3">
                <button
                  id="patterns-build-retry"
                  type="button"
                  phx-click="build_patterns"
                  disabled={@build_state == :building}
                  class="btn btn-sm btn-outline min-h-11"
                >
                  Build patterns from trips
                </button>
              </div>
            </.callout>
          </div>

          <div :if={@derivation_error} class="mt-3">
            <.callout
              kind="error"
              id="patterns-derivation-error"
              title="Pattern building stopped for this route"
            >
              <span class="font-mono text-xs">{@derivation_error}</span>
              <div class="mt-3">
                <button
                  id="patterns-build-error-retry"
                  type="button"
                  phx-click="build_patterns"
                  disabled={@build_state == :building}
                  class="btn btn-sm btn-outline min-h-11"
                >
                  Build patterns from trips
                </button>
              </div>
            </.callout>
          </div>

          <p :if={@build_error} id="patterns-build-error" class="mt-3 text-sm text-error">
            {@build_error}
          </p>

          <.pattern_list patterns={@patterns} class="mt-4" />

          <details class="mt-4 text-sm">
            <summary class="min-h-11 cursor-pointer">When do I need another pattern?</summary>
            <p class="mt-2 text-base-content/70">
              Use another pattern for a different direction, a short turn, or a different set of stops.
              If only the travel times change, add a timing to the existing pattern.
            </p>
          </details>

          <div class="mt-3 flex justify-end">
            <button
              id="patterns-reload"
              type="button"
              phx-click="reload_patterns"
              class="btn btn-ghost btn-sm min-h-11"
            >
              Refresh
            </button>
          </div>
        <% @pending_trip_count > 0 -> %>
          <.empty_state
            id="patterns-unlinked"
            title="Group existing trips into patterns"
            class="mt-4 bg-base-100"
          >
            This route has <strong class="tabular-nums">{@pending_trip_count}</strong>
            trips that are not grouped yet. Build patterns from their stop order and direction; their current times will be kept.
            <:action>
              <button
                id="patterns-build"
                type="button"
                phx-click="build_patterns"
                disabled={@build_state == :building}
                class="btn btn-primary min-h-11"
              >
                Build patterns from trips
              </button>
            </:action>
          </.empty_state>
        <% @blocked? -> %>
          <div id="patterns-build-blocked" class="mt-4">
            <.callout kind="info" title="No trips to group">
              <%= if @custom_trip_count > 0 do %>
                <strong class="tabular-nums">{@custom_trip_count}</strong>
                trips on this route keep their own imported stop times, so there is nothing to group automatically. Add a pattern manually, or review those trips first.
              <% else %>
                No trips on this route are waiting to be grouped into patterns.
              <% end %>
            </.callout>
          </div>
          <div class="mt-4">
            <.empty_state id="patterns-empty-inline" title="Add the first pattern">
              Start with a direction and the stops this service visits. You can set its timings next.
              <:action>
                <.link
                  navigate={@new_path}
                  id="patterns-create-empty"
                  class="btn btn-primary min-h-11"
                >
                  Create pattern
                </.link>
              </:action>
            </.empty_state>
          </div>
        <% true -> %>
          <.empty_state id="patterns-empty" title="Add the first pattern" class="mt-4 bg-base-100">
            Start with a direction and the stops this service visits. You can set its timings next.
            <:action>
              <.link navigate={@new_path} id="patterns-create-empty" class="btn btn-primary min-h-11">
                Create pattern
              </.link>
            </:action>
          </.empty_state>
      <% end %>
    </div>
    """
  end

  @doc "Renders the pattern count strip above the list."
  attr :pattern_count, :integer, required: true
  attr :trip_count, :integer, required: true

  def pattern_count_strip(assigns) do
    ~H"""
    <div
      id="patterns-strip"
      class="flex flex-wrap items-center gap-x-6 gap-y-2 border border-base-300 bg-base-100 px-4 py-3 text-sm"
    >
      <span id="patterns-count"><strong class="tabular-nums">{@pattern_count}</strong> patterns</span>
      <span id="pattern-trip-count">
        <strong class="tabular-nums">{@trip_count}</strong> trips in this version
      </span>
      <span class="text-base-content/70">Grouped by direction</span>
    </div>
    """
  end

  @doc """
  Renders the pattern detail header: the way back to the list, the pattern
  name, its figures, the dirty badge, the published-version notice and the
  Stops/Timings/Details task navigation.
  """
  attr :creating, :boolean, required: true
  attr :pattern_name, :string, required: true
  attr :direction_id, :integer, required: true
  attr :stop_count, :integer, required: true
  attr :trip_count, :integer, required: true
  attr :task, :atom, required: true
  attr :tasks, :list, required: true
  attr :dirty?, :boolean, required: true
  attr :version_name, :string, required: true

  def pattern_detail_header(assigns) do
    ~H"""
    <div>
      <button
        type="button"
        id="pattern-back"
        phx-click="back_to_patterns"
        class="inline-flex min-h-11 items-center gap-1 text-sm text-base-content/70 hover:text-base-content focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary"
      >
        <span aria-hidden="true">←</span> All patterns
      </button>

      <div class="mt-2 flex flex-wrap items-start justify-between gap-3">
        <h2 class="text-xl font-semibold">
          {if @creating, do: "Create pattern", else: @pattern_name}
        </h2>
      </div>

      <div class="mt-3 flex flex-wrap items-center gap-x-6 gap-y-2 border border-base-300 bg-base-100 px-4 py-3 text-sm">
        <span>{RoutePattern.direction_label(@direction_id)}</span>
        <span id="pattern-stop-count"><strong class="tabular-nums">{@stop_count}</strong> stops</span>
        <span id="pattern-trip-total"><strong class="tabular-nums">{@trip_count}</strong> trips</span>
        <span id="edit-status" class={["badge badge-sm", status_class(@dirty?, @creating)]}>
          {status_label(@dirty?, @creating)}
        </span>
      </div>

      <p id="published-version-notice" class="mt-3 text-sm text-base-content/70">
        This changes {@version_name}, a published version.
      </p>

      <nav
        id="pattern-tabs"
        aria-label="Pattern sections"
        class="mt-4 flex flex-wrap gap-1 border-b border-base-300"
      >
        <button
          :for={task <- @tasks}
          type="button"
          id={"pattern-task-#{task}"}
          phx-click="switch_task"
          phx-value-task={task}
          aria-current={@task == task && "page"}
          class={task_tab_class(@task == task)}
        >
          {task_label(task)}
        </button>
      </nav>
    </div>
    """
  end

  @doc """
  Renders the Details task: name, direction, the future-trip headsign default,
  the service description, typicality and the Additional details disclosure
  that keeps the pattern ID and display order out of the primary path.
  """
  attr :form, :any, required: true
  attr :submit_event, :string, required: true
  attr :submit_label, :string, required: true
  attr :pattern_id, :string, default: nil
  attr :dirty?, :boolean, required: true

  def details_task(assigns) do
    ~H"""
    <div id="pattern-details-task" class="mt-6 max-w-2xl">
      <h3 class="text-lg font-semibold">Pattern details</h3>

      <.form
        for={@form}
        id="pattern-details-form"
        phx-change="validate_details"
        phx-submit={@submit_event}
      >
        <.input
          field={@form[:name]}
          id="pattern-details-name"
          type="text"
          label="Pattern name"
          help="Use the endpoints; add a via street or landmark to distinguish a variation."
        />
        <.input
          field={@form[:direction_id]}
          id="pattern-details-direction"
          type="select"
          label="Direction"
          options={RoutePattern.direction_options()}
          help="GTFS direction values do not mean inbound or outbound."
        />
        <.input
          field={@form[:headsign]}
          id="pattern-details-headsign"
          type="text"
          label="Headsign for new trips"
          help="A default for future trips. Existing trip destinations stay unchanged."
        />
        <.input
          field={@form[:time_desc]}
          id="pattern-details-description"
          type="text"
          label="When this pattern runs"
          help="A description for people reading the feed. This does not set service dates."
        />
        <.input
          field={@form[:typicality]}
          id="pattern-details-typicality"
          type="select"
          label="Use on this route"
          options={RoutePattern.typicality_options()}
          help="How this pattern fits the route’s usual service."
        />

        <details id="pattern-details-additional" class="mt-4 border border-base-300 bg-base-100 p-4">
          <summary class="min-h-11 cursor-pointer font-medium">Additional details</summary>
          <div class="mt-3">
            <.input
              field={@form[:sort_order]}
              id="pattern-details-order"
              type="number"
              min="0"
              label="Display order"
              help="Lower numbers appear first within each direction."
            />
            <p class="mt-2 text-sm text-base-content/70">
              Pattern ID:
              <code id="pattern-details-id">
                {@pattern_id || "assigned when you create the pattern"}
              </code>
            </p>
          </div>
        </details>

        <div class="mt-4 flex items-center gap-3">
          <button id="pattern-details-submit" type="submit" class="btn btn-primary min-h-11">
            {@submit_label}
          </button>
          <span class="text-sm text-base-content/70">
            {if @dirty?,
              do: "You have unsaved changes.",
              else: "Changes are saved only when you choose Save."}
          </span>
        </div>
      </.form>
    </div>
    """
  end

  @doc """
  Renders the Stops task.

  An existing pattern shows its ordered stop occurrences read-only. Creating a
  pattern stages stops from the scoped eligible-stop list until the pattern is
  created.
  """
  attr :creating, :boolean, required: true
  attr :occurrences, :any, required: true
  attr :stops, :any, required: true
  attr :staged_stops, :any, required: true
  attr :stop_choices, :any, required: true
  attr :stop_choice_form, :any, required: true

  def stops_task(assigns) do
    assigns =
      assign(
        assigns,
        :staged_rows,
        staged_rows(assigns.staged_stops, Map.new(assigns.stop_choices, &{&1.stop_id, &1}))
      )

    ~H"""
    <div id="pattern-stops-task" class="mt-6">
      <h3 class="text-lg font-semibold">Stops in order</h3>
      <p class="mt-1 text-sm text-base-content/70">
        From the first stop to the last, including stops visited again on a loop.
      </p>

      <div :if={not @creating} class="mt-4">
        <ol
          :if={@occurrences != []}
          id="pattern-stops"
          class="divide-y divide-base-300 border border-base-300 bg-base-100"
        >
          <li
            :for={occurrence <- @occurrences}
            id={"pattern-stop-#{occurrence.position}"}
            class="flex min-h-11 items-center gap-3 px-4 py-3"
          >
            <span class="w-6 shrink-0 text-sm tabular-nums text-base-content/70">
              {occurrence.position}
            </span>
            <span class="min-w-0 flex-1">
              <span class="block font-medium">{stop_name(@stops, occurrence.stop_id)}</span>
              <span class="block text-sm text-base-content/70">
                Stop {occurrence.stop_id}
                <span :if={occurrence.position == 1}> · First stop</span>
                <span :if={occurrence.position == length(@occurrences)}> · Last stop</span>
              </span>
            </span>
          </li>
        </ol>

        <.empty_state :if={@occurrences == []} id="pattern-stops-empty" title="No stops yet">
          This pattern has no saved stops.
        </.empty_state>
      </div>

      <div :if={@creating} class="mt-4">
        <.form for={@stop_choice_form} id="pattern-stop-choice-form" phx-change="choose_stop">
          <.input
            field={@stop_choice_form[:stop_id]}
            id="pattern-stop-choice"
            type="select"
            label="Add a stop"
            prompt="Choose a stop"
            options={
              Enum.map(@stop_choices, fn stop ->
                {"#{stop.stop_name} (#{stop.stop_id})", stop.stop_id}
              end)
            }
            help="Stops and platforms in this version, ordered by name. Choose the stops in the order the route visits them."
          />
        </.form>

        <ol
          :if={@staged_rows != []}
          id="pattern-stops"
          class="mt-4 divide-y divide-base-300 border border-base-300 bg-base-100"
        >
          <li
            :for={{position, stop_id, name, code} <- @staged_rows}
            id={"pattern-stop-#{position}"}
            class="flex min-h-11 items-center gap-3 px-4 py-3"
          >
            <span class="w-6 shrink-0 text-sm tabular-nums text-base-content/70">{position}</span>
            <span class="min-w-0 flex-1">
              <span class="block font-medium">{name}</span>
              <span class="block text-sm text-base-content/70">
                Stop {code}
                <span :if={position == 1}> · First stop</span>
                <span :if={position == length(@staged_rows)}> · Last stop</span>
              </span>
            </span>
            <button
              type="button"
              id={"pattern-remove-stop-#{position}"}
              phx-click="remove_stop"
              phx-value-index={position}
              class="btn btn-ghost btn-sm min-h-11"
            >
              Remove
            </button>
          </li>
        </ol>

        <p :if={@staged_rows == []} id="pattern-stops-empty" class="mt-4 text-sm text-base-content/70">
          No stops added yet. Add at least two stops before creating the pattern.
        </p>

        <div class="mt-4 flex items-center gap-3">
          <button
            id="pattern-create"
            type="button"
            phx-click="create_pattern"
            class="btn btn-primary min-h-11"
          >
            Create pattern
          </button>
          <span class="text-sm text-base-content/70">
            The pattern starts with one timing valued at zero.
          </span>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders the Timings task: the timing summaries with their trip counts and
  only the selected timing's rows, each labelled with its elapsed offsets.
  """
  attr :timings, :any, required: true
  attr :selected_timing, :any, required: true
  attr :selected_timing_rows, :any, required: true
  attr :timing_form, :any, required: true
  attr :timing_options, :any, required: true
  attr :stops, :any, required: true

  def timings_task(assigns) do
    assigns =
      assigns
      |> assign(:selected_summary, selected_summary(assigns.timings, assigns.selected_timing))

    ~H"""
    <div id="pattern-timings-task" class="mt-6">
      <h3 class="text-lg font-semibold">Timings</h3>
      <p class="mt-1 text-sm text-base-content/70">
        Same stops, different travel times. Each trip uses one timing.
      </p>

      <.empty_state :if={@timings == []} id="pattern-timings-empty" title="No timings yet">
        A pattern starts with one timing valued at zero.
      </.empty_state>

      <div :if={@timings != []} class="mt-4">
        <.form for={@timing_form} id="timing-form" phx-change="select_timing">
          <.input
            id="timing-select"
            name="timing_id"
            value={@selected_timing && @selected_timing.id}
            type="select"
            label="Timing"
            options={@timing_options}
          />
        </.form>

        <p id="timing-summary" class="mt-2 text-sm text-base-content/70">
          <strong class="tabular-nums">{@selected_summary}</strong> trips use this timing.
        </p>
      </div>

      <div :if={@selected_timing_rows != []} class="mt-4">
        <.callout kind="info" id="timing-origin" title="Times are measured from the first departure">
          Each value is an elapsed time, so the first arrival is relative to the first departure.
        </.callout>

        <div class="mt-4 overflow-visible">
          <table class="table ds-stack-table">
            <thead>
              <tr>
                <th>Stop</th>
                <th class="text-right">Arrive +mm:ss</th>
                <th class="text-right">Depart +mm:ss</th>
              </tr>
            </thead>
            <tbody id="timing-rows">
              <tr :for={row <- @selected_timing_rows} id={"timing-row-#{row.position}"}>
                <td data-label="Stop">
                  <span class="block font-medium">
                    {row.position}. {stop_name(@stops, row.stop_id)}
                  </span>
                  <span class="block text-sm text-base-content/70">Stop {row.stop_id}</span>
                </td>
                <td data-label="Arrive +mm:ss" class="text-right tabular-nums">
                  {offset_label(row.arrival_offset)}
                </td>
                <td data-label="Depart +mm:ss" class="text-right tabular-nums">
                  {offset_label(row.departure_offset)}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end

  @doc "Renders the page-level error alert and the polite status region."
  attr :error, :string, default: nil
  attr :status, :string, default: nil

  def status_regions(assigns) do
    ~H"""
    <div id="error" role="alert" class="text-sm text-error">{@error}</div>
    <div id="status" role="status" aria-live="polite" class="text-sm text-base-content/70">
      {@status}
    </div>
    """
  end

  defp staged_rows(staged_stops, stops) do
    staged_stops
    |> Enum.with_index(1)
    |> Enum.map(fn {stop_id, position} ->
      {position, stop_id, stop_name(stops, stop_id), stop_id}
    end)
  end

  defp stop_name(stops, stop_id) do
    case Map.get(stops, stop_id) do
      %{stop_name: name} when is_binary(name) and name != "" -> name
      _ -> stop_id
    end
  end

  defp selected_summary(_timings, nil), do: 0

  defp selected_summary(timings, selected) do
    case Enum.find(timings, &(&1.timing.id == selected.id)) do
      %{trip_count: count} -> count
      nil -> 0
    end
  end

  defp offset_label(nil), do: "—"

  defp offset_label(seconds) when is_integer(seconds), do: GtfsTime.format_offset(seconds)

  defp timing_count_label(1), do: "1 timing"
  defp timing_count_label(count), do: "#{count} timings"

  defp trip_count_label(0), do: "Not used yet"
  defp trip_count_label(count), do: count

  defp typicality_class(1), do: "badge-success"
  defp typicality_class(5), do: "badge-success"
  defp typicality_class(3), do: "badge-warning"
  defp typicality_class(4), do: "badge-warning"
  defp typicality_class(_), do: "badge-ghost"

  defp status_label(true, _creating), do: "Unsaved changes"
  defp status_label(false, true), do: "New pattern"
  defp status_label(false, false), do: "Saved in this version"

  defp status_class(true, _creating), do: "badge-warning"
  defp status_class(false, true), do: "badge-ghost"
  defp status_class(false, false), do: "badge-success"

  defp task_tab_class(true),
    do: "min-h-11 border-b-2 border-primary px-3 font-semibold text-primary"

  defp task_tab_class(false),
    do: "min-h-11 border-b-2 border-transparent px-3 text-base-content/70 hover:text-base-content"

  defp task_label(:stops), do: "Stops"
  defp task_label(:timings), do: "Timings"
  defp task_label(:details), do: "Details"
end
