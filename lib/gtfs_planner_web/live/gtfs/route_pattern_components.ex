defmodule GtfsPlannerWeb.Gtfs.RoutePatternComponents do
  @moduledoc """
  Function components for the route pattern editor.

  The patterns list, the pattern detail header, the Details task, the ordered
  Stops task and the Timings task each render one region of the editor. State
  decisions stay in `GtfsPlannerWeb.Gtfs.RoutePatternLive`; these components
  only present the loaded values, the staged task state and the specified copy.
  """

  use GtfsPlannerWeb, :html

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
  attr :show_actions, :boolean, default: false

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
        <div :if={@show_actions} class="flex flex-wrap gap-2">
          <button
            id="pattern-copy"
            type="button"
            phx-click="copy_pattern"
            class="btn btn-sm btn-outline min-h-11"
          >
            Copy pattern
          </button>
          <button
            id="pattern-delete"
            type="button"
            phx-click="open_delete_pattern"
            class="btn btn-sm btn-ghost min-h-11 text-error"
          >
            Delete pattern
          </button>
        </div>
      </div>

      <div class="mt-3 flex flex-wrap items-center gap-x-6 gap-y-2 border border-base-300 bg-base-100 px-4 py-3 text-sm">
        <span>{RoutePattern.direction_label(@direction_id)}</span>
        <span id="pattern-stop-count"><strong class="tabular-nums">{@stop_count}</strong> stops</span>
        <span id="pattern-trip-total">
          <strong class="tabular-nums">{@trip_count}</strong> {trip_count_noun(@trip_count)}
        </span>
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
          <button
            id="pattern-details-submit"
            type="submit"
            data-commit
            class="btn btn-primary min-h-11"
          >
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

  An existing pattern shows its ordered stop occurrences with their move and
  remove controls; creating a pattern stages stops from the scoped stop search
  until the pattern is created. Custom trips block every structural control and
  explain why, and reordering is offered only while no trips use the pattern.
  """
  attr :creating, :boolean, required: true
  attr :stop_rows, :list, required: true
  attr :custom_trip_count, :integer, required: true
  attr :trip_count, :integer, required: true
  attr :timing_count, :integer, required: true
  attr :reorderable?, :boolean, required: true
  attr :dirty?, :boolean, required: true
  attr :search_form, :any, required: true
  attr :search_options, :list, required: true
  attr :search_status, :string, required: true
  attr :search_truncated?, :boolean, required: true
  attr :insert_form, :any, required: true
  attr :busy?, :boolean, default: false

  def stops_task(assigns) do
    assigns = assign(assigns, :blocked?, assigns.custom_trip_count > 0)

    ~H"""
    <div id="pattern-stops-task" class="mt-6">
      <h3 class="text-lg font-semibold">Stops in order</h3>
      <p class="mt-1 text-sm text-base-content/70">
        From the first stop to the last, including stops visited again on a loop.
      </p>

      <div :if={@blocked?} id="pattern-stops-custom" class="mt-4">
        <.callout kind="warning" title="These trips have custom times">
          <strong class="tabular-nums">{@custom_trip_count}</strong>
          custom {trip_count_noun(@custom_trip_count)} on this pattern: their imported times or stop
          sequence cannot be represented by a timing. These trips keep their imported stop times.
          Stops cannot change while they use this pattern. Copy the pattern to work on separate
          service. Resolving or replacing those trips is outside this release.
          <div class="mt-3">
            <button
              id="pattern-copy-callout"
              type="button"
              phx-click="copy_pattern"
              class="btn btn-sm btn-outline min-h-11"
            >
              Copy pattern
            </button>
          </div>
        </.callout>
      </div>

      <p :if={not @blocked? and @trip_count > 0} id="pattern-stops-impact" class="mt-4 text-sm">
        Adding or removing stops updates <strong class="tabular-nums">{@trip_count}</strong>
        {trip_count_noun(@trip_count)} across {@timing_count} timings. Copy the pattern to change the
        stop order.
      </p>

      <p
        :if={not @blocked? and @trip_count == 0 and not @creating}
        class="mt-4 text-sm text-base-content/70"
      >
        No trips use this pattern yet, so you can change its stop order freely.
      </p>

      <div class="mt-4 border border-base-300 bg-base-100 p-4">
        <h4 class="font-medium">Add a stop</h4>

        <.form for={@search_form} id="pattern-stop-search-form" phx-change="choose_stop">
          <div id="pattern-stop-search-region">
            <.live_component
              module={LiveSelect.Component}
              id="pattern-stop-search"
              field={@search_form[:stop_id]}
              options={@search_options}
              debounce={200}
              update_min_len={1}
              disabled={@blocked? or @busy?}
              placeholder="Stop name or stop ID"
              dropdown_class="bg-base-100 border border-base-300 shadow-lg mt-1 text-base-content"
              option_class="px-4 py-2.5 border-b border-base-300 last:border-b-0"
              active_option_class="bg-primary text-primary-content"
              available_option_class="hover:bg-base-200 cursor-pointer"
              text_input_class="input input-bordered w-full min-h-11"
            >
              <:option :let={option}>
                <span
                  id={"pattern-stop-option-#{option.value}"}
                  class="flex items-center justify-between gap-3"
                >
                  <span class="font-medium">{option.label}</span>
                  <span class="text-sm text-base-content/70">{option.value}</span>
                </span>
              </:option>
            </.live_component>
          </div>
        </.form>

        <p id="pattern-stop-search-status" role="status" class="mt-2 text-sm text-base-content/70">
          {@search_status}
        </p>
        <p :if={@search_truncated?} id="pattern-stop-search-hint" class="text-sm text-base-content/70">
          Refine your search to see the remaining matches.
        </p>

        <.form
          :if={not @creating}
          for={@insert_form}
          id="pattern-insert-form"
          phx-change="set_insert_after"
        >
          <.input
            field={@insert_form[:insert_after]}
            id="pattern-insert-after"
            type="select"
            label="Insert position"
            options={insert_options(@stop_rows)}
            help="Choose where the new stop belongs before you search."
          />
        </.form>
      </div>

      <ol
        id="pattern-stops"
        data-dirty={to_string(@dirty?)}
        class="mt-4 divide-y divide-base-300 border border-base-300 bg-base-100"
      >
        <li
          :for={row <- @stop_rows}
          id={"pattern-stop-#{row.position}"}
          tabindex="-1"
          class="flex min-h-11 flex-wrap items-center gap-3 px-4 py-3 focus-visible:outline focus-visible:outline-2 focus-visible:outline-primary"
        >
          <span class="w-6 shrink-0 text-sm tabular-nums text-base-content/70">{row.position}</span>
          <span class="min-w-0 flex-1">
            <span class="block font-medium">{row.name}</span>
            <span class="block text-sm text-base-content/70">
              Stop {row.stop_id}
              <span :if={row.position == 1}> · First stop</span>
              <span :if={row.last?}> · Last stop</span>
            </span>
          </span>
          <span class="flex items-center gap-1">
            <button
              :if={@reorderable?}
              type="button"
              id={"pattern-stop-#{row.position}-move-up"}
              phx-click="move_stop"
              phx-value-index={row.position}
              phx-value-direction="-1"
              disabled={row.position == 1 or @blocked? or @busy?}
              aria-label={"Move #{row.name} up"}
              class="btn btn-ghost btn-sm min-h-11 min-w-11"
            >
              <span aria-hidden="true">↑</span>
            </button>
            <button
              :if={@reorderable?}
              type="button"
              id={"pattern-stop-#{row.position}-move-down"}
              phx-click="move_stop"
              phx-value-index={row.position}
              phx-value-direction="1"
              disabled={row.last? or @blocked? or @busy?}
              aria-label={"Move #{row.name} down"}
              class="btn btn-ghost btn-sm min-h-11 min-w-11"
            >
              <span aria-hidden="true">↓</span>
            </button>
            <button
              type="button"
              id={"pattern-remove-stop-#{row.position}"}
              phx-click="remove_stop"
              phx-value-index={row.position}
              disabled={@blocked? or @busy?}
              class="btn btn-ghost btn-sm min-h-11"
            >
              Remove
            </button>
          </span>
        </li>
      </ol>

      <p
        :if={@stop_rows == [] and not @creating}
        id="pattern-stops-empty"
        class="mt-4 text-sm text-base-content/70"
      >
        This pattern has no saved stops. Add at least two stops to build its stop list.
      </p>

      <p
        :if={@stop_rows == [] and @creating}
        id="pattern-stops-empty"
        class="mt-4 text-sm text-base-content/70"
      >
        No stops added yet. Add at least two stops before creating the pattern.
      </p>

      <div :if={@creating} class="mt-4 flex items-center gap-3">
        <button
          id="pattern-create"
          type="button"
          data-commit
          phx-click="create_pattern"
          class="btn btn-primary min-h-11"
        >
          Create pattern
        </button>
        <span class="text-sm text-base-content/70">
          The pattern starts with one timing valued at zero.
        </span>
      </div>

      <div :if={not @creating} class="mt-4 flex flex-wrap items-center gap-3">
        <button
          id="pattern-save-stops"
          type="button"
          data-commit
          phx-click="save_stops"
          disabled={@blocked? or @busy?}
          class="btn btn-primary min-h-11"
        >
          Save stops
        </button>
        <span class="text-sm text-base-content/70">
          {if @dirty?,
            do: "You have unsaved stop changes.",
            else: "Stops are saved only when you choose Save stops."}
        </span>
      </div>
    </div>
    """
  end

  @doc """
  Renders the Timings task: the timing summaries, the elapsed arrival/departure
  inputs with their clock preview, the per-stop timepoint and boarding/headsign
  disclosures, and the timing headsign default.
  """
  attr :timings, :any, required: true
  attr :selected_timing, :any, required: true
  attr :timing_rows, :list, required: true
  attr :timing_form, :any, required: true
  attr :timing_options, :list, required: true
  attr :preview_time, :string, required: true
  attr :timing_headsign, :string, required: true
  attr :custom_trip_count, :integer, required: true
  attr :dirty?, :boolean, required: true
  attr :busy?, :boolean, default: false

  def timings_task(assigns) do
    assigns =
      assign(assigns, :trip_count, selected_trip_count(assigns.timings, assigns.selected_timing))

    ~H"""
    <div id="pattern-timings-task" class="mt-6">
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h3 class="text-lg font-semibold">Timings</h3>
          <p class="mt-1 text-sm text-base-content/70">
            Same stops, different travel times. Each trip uses one timing.
          </p>
        </div>
        <button
          id="timing-add"
          type="button"
          phx-click="open_timing_dialog"
          phx-value-mode="add"
          disabled={@busy?}
          class="btn btn-sm btn-outline min-h-11"
        >
          Add timing
        </button>
      </div>

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

        <div class="mt-2 flex flex-wrap items-center justify-between gap-3">
          <p id="timing-summary" class="text-sm text-base-content/70">
            <strong class="tabular-nums">{@trip_count}</strong>
            {trip_count_noun(@trip_count)} {trip_verb(@trip_count)} this timing.
            <span :if={@custom_trip_count > 0}>
              {@custom_trip_count} custom-time {trip_count_noun(@custom_trip_count)} will not change.
            </span>
          </p>
          <span class="flex gap-2">
            <button
              id="timing-rename"
              type="button"
              phx-click="open_timing_dialog"
              phx-value-mode="rename"
              disabled={@busy?}
              class="btn btn-ghost btn-sm min-h-11"
            >
              Rename timing
            </button>
            <button
              id="timing-delete"
              type="button"
              phx-click="open_delete_timing"
              disabled={@busy?}
              class="btn btn-ghost btn-sm min-h-11 text-error"
            >
              Delete timing
            </button>
          </span>
        </div>
      </div>

      <div :if={@timing_rows != []} class="mt-4">
        <.callout kind="info" id="timing-origin" title="Times are measured from the first departure">
          Enter minutes:seconds, for example 04:30. The first arrival is relative to the first
          departure, so a negative first arrival keeps a terminal arrival that happens before its
          departure. Departure can be later than arrival to allow waiting.
        </.callout>

        <div class="mt-4 max-w-xs">
          <form id="timing-preview-form" phx-change="preview_timing">
            <.input
              id="timing-preview"
              name="preview_time"
              value={@preview_time}
              type="text"
              label="Preview a departure at"
              help="24-hour time such as 08:00 or 25:00. Preview only; trip start times won’t change."
            />
          </form>
        </div>

        <form id="timing-edit-form" class="mt-4" phx-change="validate_timing_row">
          <table class="table ds-stack-table">
            <thead>
              <tr>
                <th>Stop</th>
                <th>Arrive +mm:ss</th>
                <th>Depart +mm:ss</th>
                <th>Preview</th>
                <th>Timepoint</th>
              </tr>
            </thead>
            <tbody id="timing-rows">
              <tr :for={row <- @timing_rows} id={"timing-row-#{row.position}"}>
                <td data-label="Stop">
                  <span class="block font-medium">{row.position}. {row.name}</span>
                  <span class="block text-sm text-base-content/70">Stop {row.stop_id}</span>
                </td>
                <td data-label="Arrive +mm:ss">
                  <label
                    class="block text-xs text-base-content/70"
                    for={"timing-arrival-#{row.position}"}
                  >
                    {if row.position == 1,
                      do: "Arrival relative to first departure",
                      else: "Arrive +mm:ss"}
                  </label>
                  <input
                    id={"timing-arrival-#{row.position}"}
                    name={"timing[#{row.position}][arrival]"}
                    type="text"
                    inputmode="numeric"
                    value={row.arrival}
                    aria-invalid={row.arrival_error && "true"}
                    aria-describedby={row.arrival_error && "error"}
                    class={["input input-bordered w-24 min-h-11", row.arrival_error && "border-error"]}
                  />
                </td>
                <td data-label="Depart +mm:ss">
                  <label
                    class="block text-xs text-base-content/70"
                    for={"timing-departure-#{row.position}"}
                  >
                    Depart +mm:ss
                  </label>
                  <input
                    id={"timing-departure-#{row.position}"}
                    name={"timing[#{row.position}][departure]"}
                    type="text"
                    inputmode="numeric"
                    value={row.departure}
                    aria-invalid={row.departure_error && "true"}
                    aria-describedby={row.departure_error && "error"}
                    class={[
                      "input input-bordered w-24 min-h-11",
                      row.departure_error && "border-error"
                    ]}
                  />
                </td>
                <td data-label="Preview">
                  <span id={"timing-preview-#{row.position}"} class="block tabular-nums">
                    {row.preview_arrival} / {row.preview_departure}
                  </span>
                </td>
                <td data-label="Timepoint">
                  <label
                    class="flex min-h-11 items-center gap-2 text-sm"
                    for={"timing-timepoint-#{row.position}"}
                  >
                    <input
                      id={"timing-timepoint-#{row.position}"}
                      name={"timing[#{row.position}][timepoint]"}
                      type="checkbox"
                      value="1"
                      checked={row.timepoint}
                      class="checkbox"
                    />
                    <span class="text-xs text-base-content/70">Timepoint</span>
                  </label>
                </td>
              </tr>
            </tbody>
          </table>

          <p class="mt-2 text-sm text-base-content/70">
            Timepoint marks an exact scheduled time. Unchecked stops use estimated times.
          </p>
          <p id="timing-help" class="mt-1 text-sm text-base-content/70">
            Pickup and drop-off: 0 Regular, 1 Not available, 2 Phone agency, 3 Arrange with driver.
          </p>

          <div class="mt-4 space-y-3">
            <details
              :for={row <- @timing_rows}
              id={"timing-boarding-#{row.position}"}
              class="border border-base-300 bg-base-100 p-3"
            >
              <summary class="min-h-11 cursor-pointer text-sm font-medium">
                Boarding &amp; headsign · {row.name}
              </summary>
              <div class="mt-3 grid gap-4 sm:grid-cols-2">
                <div>
                  <label class="block text-sm" for={"timing-pickup-#{row.position}"}>Pickup</label>
                  <select
                    id={"timing-pickup-#{row.position}"}
                    name={"timing[#{row.position}][pickup]"}
                    class="select select-bordered min-h-11 w-full"
                  >
                    <option
                      :for={option <- pickup_options()}
                      value={option.value}
                      selected={row.pickup == option.value}
                    >
                      {option.label}
                    </option>
                  </select>
                </div>
                <div>
                  <label class="block text-sm" for={"timing-dropoff-#{row.position}"}>Drop-off</label>
                  <select
                    id={"timing-dropoff-#{row.position}"}
                    name={"timing[#{row.position}][drop_off]"}
                    class="select select-bordered min-h-11 w-full"
                  >
                    <option
                      :for={option <- pickup_options()}
                      value={option.value}
                      selected={row.drop_off == option.value}
                    >
                      {option.label}
                    </option>
                  </select>
                </div>
              </div>
              <label class="mt-3 block text-sm" for={"timing-stop-headsign-#{row.position}"}>
                Stop headsign (optional)
              </label>
              <input
                id={"timing-stop-headsign-#{row.position}"}
                name={"timing[#{row.position}][headsign]"}
                type="text"
                value={row.stop_headsign}
                class="input input-bordered min-h-11 w-full"
              />
              <p class="mt-1 text-sm text-base-content/70">
                Use only if the destination shown to riders changes at this stop.
              </p>
            </details>
          </div>

          <div class="mt-4 max-w-md">
            <.input
              id="timing-headsign"
              name="timing_headsign"
              value={@timing_headsign}
              type="text"
              label="Headsign for new trips"
              help="A default for future trips. Existing trip destinations stay unchanged."
            />
          </div>
        </form>

        <div class="mt-4 flex flex-wrap items-center gap-3">
          <button
            id="timing-save"
            type="button"
            data-commit
            phx-click="save_timing"
            disabled={@busy?}
            class="btn btn-primary min-h-11"
          >
            Save timing
          </button>
          <span class="text-sm text-base-content/70">
            {if @dirty?,
              do: "You have unsaved timing changes.",
              else: "Timing values are saved only when you choose Save timing."}
          </span>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders the pre-apply review for a staged stop edit.

  Every timing's proposed added-stop values, estimates and trip count are shown
  before the final action, and each timing must be acknowledged separately so a
  value the reviewer never saw can never be silently confirmed.
  """
  attr :review, :any, required: true
  attr :confirm_label, :string, required: true
  attr :ready?, :boolean, required: true
  attr :requires_acknowledgement?, :boolean, required: true
  attr :version_name, :string, required: true

  def stop_review_dialog(assigns) do
    ~H"""
    <.confirm_dialog
      id="stop-review-dialog"
      open={@review != nil}
      title={review_title(@review, "Save these stops?")}
      confirm_label={@confirm_label}
      pending_label="Updating…"
      on_confirm="apply_stop_review"
      on_cancel="cancel_review"
      described_by="stop-review-dialog-body"
      confirm_variant="primary"
      size="lg"
      confirm_disabled={not @ready?}
      pending={@review != nil and @review.busy}
      return_focus_id="pattern-save-stops"
    >
      <form :if={@review} id="stop-review-values-form" phx-change="update_review_value">
        <p>
          This updates every timing on this pattern.
          <strong>This changes {@version_name}, a published version.</strong>
        </p>

        <p id="stop-review-error" role="alert" class="mt-2 text-sm text-error">
          {@review.error && @review.error.message}
        </p>

        <div :if={@review.error && @review.error.action == :refresh} class="mt-2">
          <button
            id="stop-review-refresh"
            type="button"
            phx-click="refresh_review"
            class="btn btn-sm btn-outline min-h-11"
          >
            Refresh review
          </button>
        </div>
        <div :if={@review.error && @review.error.action == :retry} class="mt-2">
          <button
            id="stop-review-retry"
            type="button"
            phx-click="retry_review"
            class="btn btn-sm btn-outline min-h-11"
          >
            Try review again
          </button>
        </div>

        <div
          :for={block <- @review.blocks}
          id={"stop-review-timing-#{block.timing_id}"}
          class="mt-4 border border-base-300 p-3"
        >
          <p class="font-medium">
            {block.name}
            <span class="font-normal text-base-content/70">
              · {block.trip_count_label}
              <span :if={block.shift}> · start shifts by        {block.shift}</span>
            </span>
          </p>

          <p :if={block.added == []} class="mt-1 text-sm text-base-content/70">
            No added stops in this timing. Its retained times stay as they are.
          </p>

          <div :for={added <- block.added} class="mt-2 grid gap-2 sm:grid-cols-3">
            <p class="text-sm">
              <span class="block font-medium">{added.name}</span>
              <span :if={added.estimated?} class="text-base-content/70">
                Estimated between its neighbours
              </span>
            </p>
            <div>
              <label
                class="block text-xs text-base-content/70"
                for={"stop-review-value-#{block.timing_id}-#{added.key}-arrival"}
              >
                Arrive +mm:ss
              </label>
              <input
                id={"stop-review-value-#{block.timing_id}-#{added.key}-arrival"}
                name={"review[#{block.timing_id}][#{added.key}][arrival]"}
                type="text"
                inputmode="numeric"
                value={added.arrival}
                class="input input-bordered w-24 min-h-11"
              />
            </div>
            <div>
              <label
                class="block text-xs text-base-content/70"
                for={"stop-review-value-#{block.timing_id}-#{added.key}-departure"}
              >
                Depart +mm:ss
              </label>
              <input
                id={"stop-review-value-#{block.timing_id}-#{added.key}-departure"}
                name={"review[#{block.timing_id}][#{added.key}][departure]"}
                type="text"
                inputmode="numeric"
                value={added.departure}
                class="input input-bordered w-24 min-h-11"
              />
            </div>
          </div>

          <label
            class="mt-3 flex min-h-11 items-center gap-2 text-sm"
            for={"stop-review-ack-#{block.timing_id}"}
          >
            <input
              id={"stop-review-ack-#{block.timing_id}"}
              type="checkbox"
              checked={block.acknowledged}
              data-acknowledged={to_string(block.acknowledged)}
              phx-click="acknowledge_review_timing"
              phx-value-timing_id={block.timing_id}
              class="checkbox"
            />
            <span>I reviewed these values for {block.name}.</span>
          </label>
        </div>

        <p class="mt-3 text-sm text-base-content/70">
          Retained stop times keep their absolute clocks; added stop times are what this review
          applies. Geometry is not recalculated.
        </p>
      </form>
    </.confirm_dialog>
    """
  end

  @doc "Renders the confirmation for a timing save that updates trips."
  attr :review, :any, required: true
  attr :version_name, :string, required: true

  def timing_review_dialog(assigns) do
    ~H"""
    <.confirm_dialog
      id="timing-review-dialog"
      open={@review != nil}
      title={review_title(@review, "Update trips?")}
      confirm_label="Update trips"
      pending_label="Updating…"
      on_confirm="apply_timing_review"
      on_cancel="cancel_timing_review"
      described_by="timing-review-dialog-body"
      confirm_variant="primary"
      pending={@review != nil and @review.busy}
      return_focus_id="timing-save"
    >
      <div :if={@review}>
        <p>
          This saves the selected timing and updates the arrival and departure times of its trips.
          Trip start times stay the same.
          <strong>This changes {@version_name}, a published version.</strong>
        </p>
        <p id="timing-review-error" role="alert" class="mt-2 text-sm text-error">
          {@review.error && @review.error.message}
        </p>
      </div>
    </.confirm_dialog>
    """
  end

  @doc "Renders the add/rename timing dialog with its inline name error."
  attr :dialog, :any, required: true

  def timing_dialog(assigns) do
    ~H"""
    <.confirm_dialog
      id="timing-dialog"
      open={@dialog != nil}
      title={timing_dialog_title(@dialog)}
      confirm_label={timing_dialog_confirm_label(@dialog)}
      pending_label="Saving…"
      on_confirm="confirm_timing_dialog"
      on_cancel="close_timing_dialog"
      described_by="timing-dialog-body"
      confirm_variant="primary"
    >
      <form :if={@dialog} id="timing-dialog-form" phx-change="validate_timing_dialog">
        <label class="block text-sm font-medium" for="timing-name">Timing name</label>
        <input
          id="timing-name"
          name="name"
          type="text"
          value={@dialog.name}
          aria-invalid={@dialog.error && "true"}
          aria-describedby={@dialog.error && "timing-dialog-error"}
          class={["input input-bordered min-h-11 w-full", @dialog.error && "border-error"]}
        />
        <p class="mt-1 text-sm text-base-content/70">
          Use a name that helps staff choose the right running times.
        </p>

        <div :if={@dialog.mode == :add} class="mt-3">
          <label class="block text-sm font-medium" for="timing-source">Start with</label>
          <select
            id="timing-source"
            name="source_timing_id"
            class="select select-bordered min-h-11 w-full"
          >
            <option value="">Blank timing (all times zero)</option>
            <option
              :for={option <- @dialog.source_options}
              value={option.value}
              selected={@dialog.source_timing_id == option.value}
            >
              {option.label}
            </option>
          </select>
          <p class="mt-1 text-sm text-base-content/70">No trips are assigned to a new timing.</p>
        </div>

        <p id="timing-dialog-error" role="alert" class="mt-2 text-sm text-error">
          {@dialog.error}
        </p>
      </form>
    </.confirm_dialog>
    """
  end

  @doc "Renders an informational dialog for a refused operation."
  attr :dialog, :any, required: true

  def blocked_dialog(assigns) do
    ~H"""
    <.confirm_dialog
      id="pattern-blocked-dialog"
      open={@dialog != nil}
      pending_label="Close"
      title={@dialog && @dialog.title}
      confirm_label={(@dialog && Map.get(@dialog, :action_label)) || "Close"}
      on_confirm="close_blocked_dialog"
      on_cancel="close_blocked_dialog"
      described_by="pattern-blocked-dialog-body"
      single_action={true}
    >
      <div>
        <p>{@dialog && @dialog.message}</p>
      </div>
    </.confirm_dialog>
    """
  end

  @doc "Renders the confirmation for deleting an unused timing."
  attr :dialog, :any, required: true

  def timing_delete_dialog(assigns) do
    ~H"""
    <.confirm_dialog
      id="timing-delete-dialog"
      open={@dialog != nil}
      title="Delete timing?"
      pending_label="Deleting…"
      confirm_label="Delete timing"
      on_confirm="confirm_delete_timing"
      on_cancel="close_blocked_dialog"
      described_by="timing-delete-dialog-body"
      confirm_variant="danger"
    >
      <div>
        <p>
          No trips use {@dialog && @dialog.name}. This removes its timing values when you confirm.
        </p>
      </div>
    </.confirm_dialog>
    """
  end

  @doc "Renders the confirmation for deleting an unused pattern."
  attr :dialog, :any, required: true

  def pattern_delete_dialog(assigns) do
    ~H"""
    <.confirm_dialog
      id="pattern-delete-dialog"
      open={@dialog != nil}
      title="Delete this pattern?"
      pending_label="Deleting…"
      confirm_label="Delete pattern"
      on_confirm="confirm_delete_pattern"
      on_cancel="close_blocked_dialog"
      described_by="pattern-delete-dialog-body"
      confirm_variant="danger"
    >
      <div>
        <p>
          No trips use {@dialog && @dialog.name}. Deleting it removes its stops and timings when you
          confirm.
        </p>
      </div>
    </.confirm_dialog>
    """
  end

  @doc "Renders the editor's connectivity state while the browser is offline."
  attr :offline?, :boolean, required: true

  def connectivity_banner(assigns) do
    ~H"""
    <div
      id="pattern-connectivity"
      class="mt-3 border border-warning bg-warning/10 px-4 py-3 text-sm"
      hidden={not @offline?}
      aria-hidden={to_string(not @offline?)}
    >
      <strong>Connection lost.</strong>
      Your edits are still here. Reconnect before saving; committing stays disabled until then.
    </div>
    """
  end

  defp review_title(nil, fallback), do: fallback

  defp review_title(%{impact: %{trips_affected: affected}}, fallback) when affected in [nil, 0],
    do: fallback

  defp review_title(%{impact: %{trips_affected: 1}}, _fallback), do: "Update 1 trip?"

  defp review_title(%{impact: %{trips_affected: affected}}, _fallback),
    do: "Update #{affected} trips?"

  defp timing_dialog_title(nil), do: "Add timing"

  defp timing_dialog_title(%{mode: :rename, name: name}) when is_binary(name) and name != "",
    do: "Rename #{name}"

  defp timing_dialog_title(%{mode: :rename}), do: "Rename timing"
  defp timing_dialog_title(_dialog), do: "Add timing"

  defp timing_dialog_confirm_label(%{mode: :rename}), do: "Rename timing"
  defp timing_dialog_confirm_label(_dialog), do: "Add timing"

  defp selected_trip_count(_timings, nil), do: 0

  defp selected_trip_count(timings, selected) do
    case Enum.find(timings, &(&1.timing.id == selected.id)) do
      %{trip_count: count} -> count
      nil -> 0
    end
  end

  defp insert_options(stop_rows) do
    [{"At the end", ""}, {"Before the first stop", "-1"}] ++
      Enum.map(stop_rows, fn row ->
        {"After #{row.position}. #{row.name}", Integer.to_string(row.position)}
      end)
  end

  defp pickup_options do
    [
      %{value: "0", label: "0 Regular"},
      %{value: "1", label: "1 Not available"},
      %{value: "2", label: "2 Phone agency"},
      %{value: "3", label: "3 Arrange with driver"}
    ]
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

  defp timing_count_label(1), do: "1 timing"
  defp timing_count_label(count), do: "#{count} timings"

  defp trip_count_noun(1), do: "trip"
  defp trip_count_noun(_count), do: "trips"

  defp trip_verb(1), do: "uses"
  defp trip_verb(_count), do: "use"

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
