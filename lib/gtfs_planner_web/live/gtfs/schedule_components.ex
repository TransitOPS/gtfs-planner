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
  defp actions_cell_class, do: "sticky right-0 z-20 whitespace-nowrap"

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
  attr :can_add?, :boolean, required: true
  attr :add_reason, :string, default: nil

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

      <div class="flex items-center gap-4 sm:ml-auto">
        <p :if={not @can_add?} id="schedules-add-blocked" class="text-sm text-base-content/70">
          {@add_reason}
        </p>
        <button
          :if={@can_add?}
          id="schedules-add-trips"
          type="button"
          phx-click="open_add_drawer"
          class="btn btn-primary min-h-11"
          phx-disconnected={JS.set_attribute({"disabled", ""})}
          phx-connected={JS.remove_attribute("disabled")}
        >
          Add trips
        </button>
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
  Renders the disconnected notice and the review confirmation.

  The Save and Add controls bind their own `phx-disconnected`/`phx-connected`
  pairs, so a lost socket disables committing until it returns; this notice
  explains why and disappears on reconnect.
  """
  def connectivity_notice(assigns) do
    ~H"""
    <div
      id="schedules-disconnected"
      hidden
      phx-disconnected={JS.remove_attribute("hidden")}
      phx-connected={JS.set_attribute({"hidden", ""})}
    >
      <.callout kind="warning" title="Connection lost">
        Showing the last loaded schedule. Saving and adding trips stay unavailable until the
        connection returns.
      </.callout>
    </div>
    """
  end

  @doc """
  Renders the bulk toolbar for the current selection.

  It totals the selected rows across sections and offers the bulk delete. The
  count and the delete action come from the selection the server owns, so a
  toolbar left on screen after a view change cannot act on hidden trips.
  """
  attr :selected_count, :integer, required: true

  def bulk_toolbar(assigns) do
    ~H"""
    <div
      :if={@selected_count > 0}
      id="schedules-bulk-toolbar"
      role="status"
      class="flex flex-wrap items-center justify-between gap-4 rounded-box border border-base-300 bg-base-200 px-4 py-3"
    >
      <p class="text-sm font-semibold">{@selected_count} trips selected</p>
      <div class="flex items-center gap-3">
        <button
          id="schedules-clear-selection"
          type="button"
          phx-click="clear_selection"
          class="btn btn-ghost btn-sm min-h-11"
        >
          Clear selection
        </button>
        <button
          id="schedules-delete-selected"
          type="button"
          phx-click="delete_selected"
          class="btn btn-outline btn-error btn-sm min-h-11"
          phx-disconnected={JS.set_attribute({"disabled", ""})}
          phx-connected={JS.remove_attribute("disabled")}
        >
          Delete {(@selected_count == 1 && "1 trip") || "#{@selected_count} trips"}
        </button>
      </div>
    </div>
    """
  end

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
      assign(assigns, :menu_id, "trip-#{assigns.row.trip_id}-menu-panel")
      |> assign(:anchor_name, "--trip-menu-#{assigns.row.id}")

    ~H"""
    <div class="relative flex items-center justify-end gap-1">
      <button
        id={"trip-#{@row.trip_id}-edit"}
        type="button"
        phx-click="open_edit_drawer"
        phx-value-trip={@row.id}
        class="btn btn-ghost btn-sm min-h-11 text-primary"
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
        class="btn btn-ghost btn-sm btn-circle min-h-11 min-w-11"
        aria-label={"More actions for trip #{@row.trip_id}"}
        aria-haspopup="menu"
        title="More actions"
      >
        <.icon name="hero-ellipsis-horizontal" class="size-4" />
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
        class="w-64 rounded-box border border-base-300 bg-base-100 p-1 text-left shadow-lg"
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
          class="block w-full min-h-11 px-3 py-2 text-left text-sm hover:bg-base-200 focus:bg-base-200 focus:outline-none"
        >
          Duplicate trip
        </button>
        <button
          :if={@row.frequency?}
          id={"trip-#{@row.trip_id}-duplicate-disabled"}
          type="button"
          role="menuitem"
          disabled
          class="block w-full min-h-11 px-3 py-2 text-left text-sm opacity-60"
        >
          Duplicate trip
        </button>
        <p
          :if={@row.frequency?}
          id={"trip-#{@row.trip_id}-duplicate-reason"}
          class="px-3 pb-1 text-xs text-base-content/70"
        >
          Frequency service can't be duplicated
        </p>
        <button
          id={"trip-#{@row.trip_id}-delete"}
          type="button"
          role="menuitem"
          popovertarget={@menu_id}
          popovertargetaction="hide"
          phx-click="open_delete_trip"
          phx-value-trip={@row.id}
          class="block w-full min-h-11 px-3 py-2 text-left text-sm text-error hover:bg-base-200 focus:bg-base-200 focus:outline-none"
        >
          Delete trip
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Renders the single and bulk delete confirmation.

  The dialog names the count and calendar for a bulk delete and the trip's start
  and pattern for a single delete, states that the trips leave the published
  version and that this cannot be undone, names the transfer records the deletion
  also removes when any exist, and keeps any delete failure on screen with a
  retry.
  """
  attr :dialog, :any, required: true

  def delete_dialog(assigns) do
    assigns = assign(assigns, :transfer_notice, transfer_notice(assigns.dialog))

    ~H"""
    <.confirm_dialog
      id="delete-dialog"
      open={@dialog != nil}
      title={dialog_title(@dialog)}
      confirm_label={dialog_confirm_label(@dialog)}
      pending_label="Deleting…"
      on_confirm="confirm_delete"
      on_cancel="close_delete"
      described_by="delete-dialog-body"
      return_focus_id={@dialog && @dialog.return_focus_id}
    >
      <div :if={@dialog}>
        <p :if={@dialog.detail} id="delete-dialog-detail">{@dialog.detail}</p>
        <p class={["text-base-content/70", @dialog.detail && "mt-2"]}>
          <%= if @dialog.frequency? do %>
            This removes the trips and their stop times from this published version, including
            frequency service.
            <span :if={@transfer_notice} id="delete-dialog-transfers">{@transfer_notice}</span>
            You cannot
            undo this.
          <% else %>
            This removes the trips and their stop times from this published version.
            <span :if={@transfer_notice} id="delete-dialog-transfers">{@transfer_notice}</span>
            You cannot
            undo this.
          <% end %>
        </p>
        <p :if={@dialog.error} id="delete-error" role="alert" class="mt-2 text-sm text-error">
          {@dialog.error}
        </p>
      </div>
    </.confirm_dialog>
    """
  end

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

  @doc """
  Renders the Add trips, Edit trip and Duplicate drawers.

  The Add drawer previews the exact departures `Gtfs.series_starts/3` will
  create and the primary label counts them. The Edit drawer keeps a custom trip's
  stop times unless a timing is chosen, disables the departure for frequency
  service with a visible reason, and hides the optional accessibility fields and
  the stable trip ID behind a disclosure. Every field error carries its own
  stable id and `aria-invalid`, so the `FormErrorFocus` hook lands on the first
  invalid field.
  """
  attr :drawer, :any, required: true
  attr :patterns, :list, required: true
  attr :calendars, :list, required: true
  attr :block_suggestions, :list, required: true
  attr :patterns_path, :string, required: true

  def trip_drawer(assigns) do
    assigns =
      assigns
      |> assign(:title, drawer_title(assigns.drawer))
      |> assign(:pattern, drawer_pattern(assigns.drawer, assigns.patterns))
      |> assign(:custom?, assigns.drawer != nil and assigns.drawer.custom?)
      |> assign(:frequency?, assigns.drawer != nil and assigns.drawer.frequency?)
      |> assign(:stops_differ?, assigns.drawer != nil and assigns.drawer.stops_differ?)
      |> assign(:values, assigns.drawer && assigns.drawer.values)

    ~H"""
    <.drawer
      id="trip-drawer"
      open={@drawer != nil}
      title={@title}
      on_close="close_drawer"
      initial_focus={:first_field}
      initial_focus_id={drawer_initial_focus_id(@drawer)}
      return_focus_id={@drawer && @drawer.return_focus_id}
    >
      <.form
        :if={@drawer}
        for={%{}}
        as={:drawer}
        id="trip-drawer-form"
        phx-change="drawer_change"
        phx-submit="drawer_submit"
        class="space-y-4"
      >
        <p id="trip-drawer-route" class="text-sm text-base-content/70">
          {drawer_route_line(@drawer, @pattern)}
        </p>

        <.drawer_notice drawer={@drawer} />

        <div :if={(@drawer.mode == :add and @pattern) && @pattern.timings == []}>
          <.callout kind="warning" title="Add a timing first">
            Timings set the minutes between stops for each trip.
            <.link navigate={@patterns_path} class="link ml-1 inline-flex min-h-11 items-center">
              Go to patterns
            </.link>
          </.callout>
        </div>

        <div :if={@custom?}>
          <.callout kind="warning" title="This trip has custom stop times">
            Choose “Use timing” to change its departure or stop times. Other trip details can still
            be saved.
          </.callout>
        </div>

        <div :if={@frequency?}>
          <.callout kind="info" title={frequency_title(@drawer)}>
            Frequency times are shown for reference. This schedule shows frequency service read
            only.
          </.callout>
        </div>

        <div :if={@drawer.mode == :add} class="fieldset mb-2">
          <.input
            id="trip-pattern"
            name="drawer[pattern_id]"
            type="select"
            label="Pattern"
            value={@values["pattern_id"]}
            options={pattern_options(@patterns)}
            help="The stops this trip serves."
            errors={error_list(@drawer, :pattern_id)}
          />
        </div>

        <div :if={not (@frequency? and @drawer.mode == :edit)} class="fieldset mb-2">
          <.input
            id="trip-timing"
            name="drawer[timed_pattern_id]"
            type="select"
            label="Timing"
            value={@values["timed_pattern_id"]}
            options={timing_select_options(@drawer, @pattern)}
            help="A timing is the minutes between stops, not a clock time."
            errors={error_list(@drawer, :timed_pattern_id)}
          />
          <p
            :if={@custom? and @stops_differ?}
            id="trip-timing-reason"
            class="mt-1 text-sm text-base-content/70"
          >
            This trip's stops differ from the pattern, so its custom times are kept.
          </p>
        </div>

        <div :if={@drawer.mode != :duplicate} class="fieldset mb-2">
          <.input
            id="trip-calendar"
            name="drawer[service_id]"
            type="select"
            label="Calendar"
            value={@values["service_id"]}
            options={calendar_options(@calendars)}
            help="The days this trip runs."
            errors={error_list(@drawer, :service_id)}
          />
        </div>

        <div class="fieldset mb-2">
          <.input
            id="trip-start"
            name="drawer[start_time]"
            type="text"
            label={departure_label(@drawer.mode)}
            value={@values["start_time"]}
            disabled={departure_disabled?(@drawer, @custom?, @frequency?)}
            errors={error_list(@drawer, :start_time)}
            help="Use 24-hour time, such as 06:00. After midnight: 25:10 = 1:10 AM next day."
          />
          <p
            :if={departure_disabled?(@drawer, @custom?, @frequency?)}
            id="trip-start-reason"
            class="mt-1 text-sm text-base-content/70"
          >
            {departure_reason(@drawer, @custom?, @frequency?)}
          </p>
        </div>

        <div :if={@drawer.mode == :add} class="space-y-3">
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
              label="Every (minutes)"
              value={@values["every"]}
              errors={error_list(@drawer, :every)}
            />
            <.input
              id="trip-until"
              name="drawer[until]"
              type="text"
              label="Last departure by"
              value={@values["until"]}
              errors={error_list(@drawer, :until)}
            />
          </div>
        </div>

        <.drawer_preview drawer={@drawer} />

        <div :if={@drawer.mode == :edit} class="space-y-3 border-t border-base-300 pt-4">
          <h3 class="text-sm font-semibold">Trip details</h3>
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
          <.input
            id="trip-block"
            name="drawer[block_id]"
            type="text"
            label="Block (optional)"
            value={@values["block_id"]}
            list="trip-block-list"
            help="Trips with the same block use the same vehicle."
            errors={error_list(@drawer, :block_id)}
          />
          <datalist id="trip-block-list">
            <option :for={block <- @block_suggestions} value={block}></option>
          </datalist>
          <details id="trip-accessibility" class="rounded-box border border-base-300 p-3">
            <summary class="min-h-11 cursor-pointer text-sm font-semibold">
              Accessibility and trip ID
            </summary>
            <div class="mt-3 space-y-3">
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
              <p class="text-sm text-base-content/70">
                Trip ID <code id="trip-stable-id">{@drawer.trip_id}</code>
                <br />This ID stays the same when you edit the trip.
              </p>
            </div>
          </details>
        </div>

        <p class="text-sm text-base-content/70">Saving updates this published version in place.</p>

        <div class="flex flex-wrap items-center justify-end gap-3 border-t border-base-300 pt-4">
          <button
            :if={@drawer.mode == :edit}
            id="trip-drawer-delete"
            type="button"
            phx-click="open_delete_trip"
            phx-value-trip={@drawer.trip.id}
            class="btn btn-ghost mr-auto min-h-11 text-error"
          >
            Delete trip
          </button>
          <button
            id="trip-drawer-cancel"
            type="button"
            phx-click="close_drawer"
            class="btn btn-ghost min-h-11"
          >
            Cancel
          </button>
          <.button
            :if={can_submit?(@drawer, @pattern)}
            id="trip-drawer-save"
            type="submit"
            variant="primary"
            class="min-h-11"
            phx-disconnected={JS.set_attribute({"disabled", ""})}
            phx-connected={JS.remove_attribute("disabled")}
          >
            {@drawer.preview.label}
          </.button>
        </div>
      </.form>
    </.drawer>
    """
  end

  defp drawer_route_line(drawer, nil), do: "Route #{drawer.route_label}"
  defp drawer_route_line(drawer, pattern), do: "Route #{drawer.route_label} · #{pattern.name}"

  defp drawer_notice(assigns) do
    ~H"""
    <div
      :if={@drawer.problem}
      id="trip-drawer-error"
      role="alert"
      class="rounded-box border border-error/40 bg-error/10 p-3 text-sm text-error"
    >
      <p>{error_message(@drawer.problem)}</p>
      <button
        :if={@drawer.problem == :stale}
        id="trip-drawer-reload"
        type="button"
        phx-click="reload_drawer"
        class="btn btn-sm btn-outline mt-2 min-h-11"
      >
        Reload
      </button>
    </div>
    """
  end

  defp drawer_preview(assigns) do
    ~H"""
    <div
      id="trip-preview"
      aria-live="polite"
      class="rounded-box border border-base-300 bg-base-200 p-3 text-sm"
    >
      <p :if={@drawer.preview.error} id="trip-preview-error">{@drawer.preview.error}</p>
      <div :if={is_nil(@drawer.preview.error)}>
        <p class="text-base-content/70">{@drawer.preview.meta}</p>
        <p class="mt-1 font-mono text-lg font-semibold tabular-nums">{@drawer.preview.range}</p>
        <p :if={@drawer.preview.total_minutes} class="mt-1">
          First trip: {@drawer.preview.total_minutes} minutes from first to last stop.
        </p>
        <p :if={@drawer.preview.sentence} class="mt-1 font-semibold">{@drawer.preview.sentence}</p>
        <p :if={@drawer.preview.hint} class="mt-1 text-xs text-base-content/70">
          {@drawer.preview.hint}
        </p>
      </div>
    </div>
    """
  end

  # Fixed UI copy for every error atom a schedule mutation can return (CR-6).
  # Raw atoms never reach the screen: an unknown atom falls back to the save
  # failure sentence.
  @doc "Returns the fixed sentence a schedule mutation error shows."
  @spec error_message(atom() | nil) :: String.t()
  def error_message(:stale) do
    "This trip changed since you opened it. Reload it to see the current values."
  end

  def error_message(:busy), do: "Another change is being saved. Try again."

  def error_message(:frequency_trip) do
    "Frequency service can't be edited here. Its blocks, calendar and details can still change."
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
    "That calendar is no longer available. Reload the schedule and try again."
  end

  def error_message(:trip_stop_times_mismatch) do
    "This trip's stop times don't match its pattern. Reload the schedule and try again."
  end

  def error_message(:trip_id_conflict) do
    "That trip ID is already in use. Add the trips again."
  end

  def error_message(:invalid_time) do
    "Enter a departure as HH:MM, for example 06:00 or 25:10."
  end

  def error_message(:unauthorized) do
    "You don't have permission to change this route's trips."
  end

  def error_message(:invalid_interval) do
    "Enter a whole number of minutes greater than zero."
  end

  def error_message(:until_before_start) do
    "The last departure must be at or after the first departure. Use 24:00 or higher after midnight."
  end

  def error_message(:too_many_trips) do
    "Too many trips. Add 200 or fewer at a time by increasing the interval or shortening the time range."
  end

  def error_message(_other), do: save_failure_copy()

  @doc "Returns the sentence a failed save shows while the drawer keeps its input."
  @spec save_failure_copy() :: String.t()
  def save_failure_copy,
    do: "Trips couldn't be saved. Your entries are still here. Try saving again."

  # --- drawer helpers --------------------------------------------------------

  defp drawer_title(nil), do: "Add trips"
  defp drawer_title(%{mode: :add}), do: "Add trips"
  defp drawer_title(%{mode: :edit}), do: "Edit trip"
  defp drawer_title(%{mode: :duplicate}), do: "Duplicate trip"

  defp drawer_initial_focus_id(nil), do: nil
  defp drawer_initial_focus_id(%{mode: :add}), do: "trip-pattern"
  defp drawer_initial_focus_id(_drawer), do: "trip-timing"

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

  defp departure_label(:add), do: "First departure time"
  defp departure_label(_mode), do: "Departure time"

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

  defp frequency_title(%{trip: row}) when is_map(row) do
    case row.frequency_label do
      nil -> "This trip runs on a frequency"
      label -> "This trip runs #{String.downcase(label)}"
    end
  end

  defp frequency_title(_drawer), do: "This trip runs on a frequency"

  defp headsign_help(%{trip: row}, pattern) when is_map(row) do
    reference = row.trip_headsign || (pattern && pattern.headsign)

    case reference do
      nil -> ""
      headsign -> "Leave blank to use #{headsign}."
    end
  end

  defp headsign_help(_drawer, _pattern), do: ""

  defp can_submit?(%{mode: :add}, nil), do: false
  defp can_submit?(%{mode: :add}, pattern), do: pattern.timings != []
  defp can_submit?(%{mode: :edit}, _pattern), do: true
  defp can_submit?(_drawer, pattern), do: pattern != nil and pattern.timings != []

  defp error_list(%{errors: errors}, field) do
    case Map.get(errors, field) do
      nil -> []
      message -> [message]
    end
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
              <th scope="col" class={[actions_cell_class(), "bg-base-100"]}>Actions</th>
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
                  id={"trip-#{row.trip_id}-marker"}
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
              <td class={[actions_cell_class(), "bg-base-100 group-hover:bg-base-200"]}>
                <.row_actions row={row} />
              </td>
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
