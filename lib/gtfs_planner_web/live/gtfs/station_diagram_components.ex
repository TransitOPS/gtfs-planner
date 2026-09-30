defmodule GtfsPlannerWeb.Gtfs.StationDiagramComponents do
  @moduledoc """
  Function components for the station diagram editor.
  Extracted from StationDiagramLive to improve modularity and readability.
  """
  use Phoenix.Component

  import GtfsPlannerWeb.CoreComponents

  import GtfsPlannerWeb.PlannerComponents,
    only: [drawer_footer: 1, drawer_scroll: 1, form_section: 1, message: 1, unsaved_badge: 1]

  import GtfsPlannerWeb.Gtfs.StationJournalComponents,
    only: [journal_context_box: 1, entity_journal_panel: 1]

  import GtfsPlannerWeb.Live.Gtfs.ChangeHistoryComponents

  alias GtfsPlanner.Gtfs.Coordinates
  alias GtfsPlanner.Gtfs.Extensions.PathSafety
  alias GtfsPlanner.Gtfs.Pathway
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlannerWeb.Components.TransitPresentation
  alias Phoenix.LiveView.JS

  # Overlay sizes are CSS pixels, emitted as `data-base-*` attributes that the
  # DiagramCanvas hook converts to viewBox units for the current window and
  # zoom. Geometry attributes such as `x`, `r` and `stroke-width` are only
  # first-paint placeholders in plan units; the hook overwrites them.
  @stop_label_font_size 12
  @stop_label_stroke_width 3
  @stop_label_line_height 14
  @stop_label_char_width 6.5
  @stop_label_box_padding_x 6
  @stop_label_box_padding_y 2
  @stop_label_box_stroke 1
  @stop_label_max_line_chars 18
  @stop_label_max_lines 3

  # ============================================================================
  # Editing Presence Control
  # ============================================================================

  attr :station_editing_status, :any, default: nil
  attr :current_user, :any, required: true

  def editing_presence_control(assigns) do
    is_owner =
      assigns.station_editing_status != nil and
        assigns.station_editing_status.user_id == assigns.current_user.id

    assigns = assign(assigns, :is_owner, is_owner)

    ~H"""
    <%= cond do %>
      <% is_nil(@station_editing_status) -> %>
        <button
          id="mark-editing-button"
          type="button"
          title="Tell others you're working on this station"
          class="inline-flex min-h-11 items-center gap-1.5 rounded-control px-2.5 text-[13px] font-[650] text-muted hover:bg-canvas hover:text-strong"
          phx-click="set_station_editing_status"
        >
          <.icon name="hero-pencil" class="size-4" /> Mark as editing
        </button>
      <% @is_owner -> %>
        <div class="inline-flex items-center gap-1 rounded-control bg-info-bg pl-3 text-[13px] text-info-fg">
          <span id="editing-status-text" role="status" class="font-[650]">
            You're editing
          </span>
          <button
            id="done-editing-button"
            type="button"
            class="inline-flex min-h-11 items-center rounded-control px-3 text-[13px] font-[650] text-info-fg underline underline-offset-4 hover:bg-white/50"
            phx-click="clear_station_editing_status"
          >
            I'm done
          </button>
        </div>
      <% true -> %>
        <div class="inline-flex min-h-11 items-center gap-2 rounded-control bg-warning-bg px-3 text-[13px] text-warning-fg">
          <.icon name="hero-users" class="size-4" />
          <span id="editing-status-text" role="status">
            <span class="font-[650]">{@station_editing_status.user.email}</span>
            is editing
            <time
              datetime={DateTime.to_iso8601(@station_editing_status.started_at)}
              class="sr-only"
              title={DateTime.to_iso8601(@station_editing_status.started_at)}
            >
              {DateTime.to_iso8601(@station_editing_status.started_at)}
            </time>
          </span>
        </div>
    <% end %>
    """
  end

  # ============================================================================
  # Diagram Action Strip (the workspace toolbar)
  # ============================================================================

  # One 56px row that holds what a mapper changes every few minutes, which
  # level and what a click does, and the rare per-level and per-station tasks
  # behind More. Counts live once, on the side panel's tabs.
  attr :mode, :atom, required: true
  attr :has_diagram, :boolean, required: true
  attr :has_scale, :boolean, default: false
  attr :active_stop_level, :any, default: nil
  attr :levels, :list, default: []
  attr :levels_with_floorplan, :any, default: nil
  attr :active_level, :any, default: nil
  attr :active_level_name, :string, default: ""
  attr :other_levels, :list, default: []
  attr :enabled_count, :integer, default: 0
  attr :station, :any, required: true

  def diagram_action_strip(assigns) do
    open_panel =
      JS.toggle(to: "#diagram-more-panel")
      |> JS.toggle_attribute({"aria-expanded", "true", "false"}, to: "#diagram-more-trigger")

    close_panel =
      JS.hide(to: "#diagram-more-panel")
      |> JS.set_attribute({"aria-expanded", "false"}, to: "#diagram-more-trigger")

    mode_options = [
      %{label: "Select", value: "view", icon: "hero-cursor-arrow-rays"},
      %{
        label: "Add point",
        value: "add",
        icon: "hero-map-pin",
        disabled: not assigns.has_diagram
      },
      %{
        label: "Connect",
        value: "connect",
        icon: "hero-link",
        disabled: not assigns.has_diagram
      },
      %{label: "Align", value: "map", icon: "hero-map", disabled: not assigns.has_diagram}
    ]

    assigns =
      assigns
      |> assign(:open_panel, open_panel)
      |> assign(:close_panel, close_panel)
      |> assign(:mode_options, mode_options)
      |> assign(:level_tabs, sort_levels(assigns.levels))

    ~H"""
    <div
      id="diagram-action-strip"
      class="relative z-20 flex min-h-[56px] flex-wrap items-stretch gap-x-3 border-b border-subtle px-2 sm:px-3"
    >
      <a
        id="skip-to-floorplan"
        href="#floorplan-workspace"
        phx-click={JS.focus(to: "#floorplan-workspace")}
        class="sr-only focus:not-sr-only focus:absolute focus:left-3 focus:top-2 focus:z-40 focus:rounded-control focus:bg-action focus:px-3 focus:py-1.5 focus:text-sm focus:font-[650] focus:text-white focus:shadow-float"
      >
        Skip to floorplan
      </a>

      <span
        :if={@mode in [:add, :connect, :map]}
        id="diagram-station-name"
        class="my-1.5 mr-1 inline-flex min-h-11 max-w-[14rem] items-center self-center text-[13px] font-semibold text-muted"
      >
        <span class="truncate">{@station.stop_name || @station.stop_id}</span>
      </span>

      <nav
        id="level-control"
        aria-label="Levels"
        class="-mb-px flex min-w-0 max-w-full items-stretch overflow-x-auto"
      >
        <span class="flex shrink-0 items-center pr-2 text-[13px] text-muted">Level</span>
        <button
          :for={level <- @level_tabs}
          id={"level-option-#{level.id}"}
          type="button"
          data-level-id={level.level_id}
          aria-current={@active_level && level.id == @active_level.id && "true"}
          phx-click={JS.push("switch_level", value: %{level_id: level.id})}
          class={[
            "-mb-px inline-flex min-h-[55px] shrink-0 items-center gap-1.5 whitespace-nowrap border-b-2 px-3 text-sm font-semibold",
            "focus-visible:outline-2 focus-visible:outline-offset-[-2px] focus-visible:outline-focus",
            if(@active_level && level.id == @active_level.id,
              do: "border-action text-action",
              else: "border-transparent text-default hover:border-subtle hover:text-strong"
            )
          ]}
        >
          {level.level_name || level.level_id}
          <span
            :if={not level_has_floorplan?(@levels_with_floorplan, level)}
            class={[
              "text-[12px] font-normal",
              if(@active_level && level.id == @active_level.id, do: "text-action", else: "text-muted")
            ]}
          >
            · No floorplan
          </span>
        </button>
      </nav>

      <div class="mx-1 hidden h-6 w-px shrink-0 self-center bg-subtle sm:block"></div>

      <div class="my-1.5 self-center max-sm:hidden">
        <.segmented_control
          id="diagram-mode"
          name="mode"
          legend="Editing mode"
          legend_class="sr-only"
          options={@mode_options}
          value={Atom.to_string(@mode)}
          event="switch_mode"
          appearance={:joined}
          emphasis={:selection}
        />
      </div>

      <p
        :if={not @has_diagram}
        id="diagram-mode-reason"
        class="max-w-[22rem] self-center text-[12.5px] leading-snug text-muted max-sm:hidden"
      >
        Add point, Connect and Align need a floorplan on {@active_level_name}.
      </p>

      <div class="ml-auto flex items-center gap-1 self-center">
        <.other_levels_panel
          :if={@mode == :map and @has_diagram}
          other_levels={@other_levels}
          enabled_count={@enabled_count}
        />

        <div class="relative">
          <button
            id="diagram-more-trigger"
            type="button"
            class="flex min-h-11 items-center gap-1 rounded-control px-2.5 text-sm font-[650] text-strong hover:bg-canvas"
            aria-expanded="false"
            aria-controls="diagram-more-panel"
            phx-click={@open_panel}
          >
            <.icon name="hero-ellipsis-horizontal" class="size-4" /> More
            <.icon name="hero-chevron-down" class="size-3.5 text-muted" />
          </button>

          <div
            id="diagram-more-panel"
            phx-click-away={@close_panel}
            phx-window-keydown={@close_panel}
            phx-key="escape"
            style="display: none;"
            class="absolute right-0 top-full z-40 mt-1 w-64 rounded-card border border-subtle bg-white p-1.5 shadow-float"
          >
            <p
              :if={@active_level}
              class="px-3 pb-1 pt-1.5 text-[12.5px] font-[650] text-muted"
            >
              {@active_level_name}
            </p>
            <button
              :if={@active_level}
              id="edit-level-action"
              type="button"
              class={menu_item_class()}
              phx-click={@close_panel |> JS.push("open_edit_level")}
            >
              Edit level…
            </button>
            <button
              :if={@active_level && @has_diagram}
              id="replace-floorplan-action"
              type="button"
              class={menu_item_class()}
              phx-click={@close_panel |> JS.push("open_diagram_upload_drawer")}
            >
              Replace floorplan…
            </button>
            <button
              :if={@active_level && @has_diagram && @mode == :view}
              id="set-scale-action"
              type="button"
              class={menu_item_class()}
              phx-click={@close_panel |> JS.push("toggle_measurement")}
            >
              {if @has_scale, do: "Recalibrate scale", else: "Set scale"}
            </button>
            <div :if={@active_level} class="my-1 border-t border-subtle"></div>
            <p class="px-3 pb-1 pt-1.5 text-[12.5px] font-[650] text-muted">Station</p>
            <button
              id="add-level-action"
              type="button"
              class={menu_item_class()}
              phx-click={@close_panel |> JS.push("open_add_level")}
            >
              Add level…
            </button>
            <button
              id="apply-naming-action"
              type="button"
              class={menu_item_class()}
              phx-click={@close_panel |> JS.push("open_naming_drawer")}
            >
              Standardize stop IDs…
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp menu_item_class,
    do:
      "flex min-h-11 w-full items-center rounded-control px-3 text-left text-sm text-strong hover:bg-canvas"

  # Top floor first, the way a rider reads a station. A level without an index
  # sorts last so it never hides between two real floors.
  defp sort_levels(levels) do
    Enum.sort_by(levels, fn level ->
      case level.level_index do
        index when is_number(index) -> {0, -index}
        _ -> {1, 0}
      end
    end)
  end

  # Membership of the set the LiveView derives from `list_levels_for_station/3`,
  # which is the only place the diagram filename survives: it hangs off the
  # query row, not off `Level`, which has no such field. A nil set means the
  # caller did not supply one, and no level is claimed to be missing a
  # floorplan on the strength of an absent answer.
  defp level_has_floorplan?(nil, _level), do: true

  defp level_has_floorplan?(%MapSet{} = with_floorplan, %{id: id}),
    do: MapSet.member?(with_floorplan, id)

  defp level_has_floorplan?(_, _), do: true

  # ============================================================================
  # Workspace status bar and scale status
  # ============================================================================

  # One message on the left, the level's scale on the right. The outcome of the
  # last action replaces the mode hint; the canvas chip carries the instruction
  # for Add point, Connect and setting the scale, so the line never repeats it.
  attr :mode, :atom, required: true
  attr :has_diagram, :boolean, required: true
  attr :measurement_enabled, :boolean, default: false
  attr :has_scale, :boolean, default: false
  attr :active_stop_level, :any, default: nil
  attr :scale_status, :any, default: nil
  attr :placement_status, :any, default: nil
  attr :naming_status, :any, default: nil

  def workspace_status(assigns) do
    facts = scale_facts(assigns.active_stop_level)

    assigns =
      assigns
      |> assign(:scale_value, facts.value)
      |> assign(:scale_distance, facts.distance)
      |> assign(:plan_width, facts.width)
      |> assign(:hint, mode_hint(assigns))
      |> assign(
        :outcomes,
        [
          {"scale-status", "dismiss_scale_status", assigns.scale_status},
          {"placement-status", "dismiss_placement_status", assigns.placement_status},
          {"naming-status", "dismiss_naming_status", assigns.naming_status}
        ]
        |> Enum.filter(fn {_id, _event, message} -> message end)
      )

    ~H"""
    <div
      :if={@has_diagram or @outcomes != []}
      id="diagram-status-bar"
      class="flex min-h-11 flex-wrap items-center gap-x-4 gap-y-1 border-t border-subtle bg-white px-3 py-1 text-[13px]"
    >
      <p
        :for={{id, event, message} <- @outcomes}
        id={id}
        role="status"
        aria-live="polite"
        class="inline-flex min-w-0 items-center gap-1.5 font-[650] text-cyan-800"
      >
        <.icon name="hero-check" class="size-3.5 shrink-0" />
        <span class="min-w-0">{message}</span>
        <button
          type="button"
          class="inline-flex min-h-11 items-center rounded-control px-2 font-[650] text-cyan-800 underline underline-offset-4 hover:bg-canvas"
          phx-click={event}
        >
          Dismiss
        </button>
      </p>
      <p
        :if={@outcomes == [] && @hint}
        id="mode-hint"
        class="min-w-0 text-muted max-sm:hidden sm:truncate"
      >
        {@hint}
      </p>
      <p
        :if={@outcomes == [] && @has_diagram}
        id="mode-hint-phone"
        class="min-w-0 text-muted sm:hidden"
      >
        Placing points and drawing pathways needs a larger screen.
      </p>

      <div :if={@has_diagram} id="scale-control" class="ml-auto flex items-center gap-2">
        <.scale_control
          measurement_enabled={@measurement_enabled}
          has_scale={@has_scale}
          scale_value={@scale_value}
          scale_distance={@scale_distance}
          plan_width={@plan_width}
          editable={@mode == :view}
        />
      </div>
    </div>
    """
  end

  defp scale_facts(%{scale_meters_per_unit: %Decimal{} = mpu} = stop_level) do
    %{
      value: mpu |> Decimal.round(3) |> Decimal.normalize() |> Decimal.to_string(:normal),
      width: mpu |> Decimal.mult(100) |> Decimal.round(0) |> Decimal.to_string(:normal),
      distance: measured_distance(stop_level)
    }
  end

  defp scale_facts(_stop_level), do: %{value: nil, width: nil, distance: nil}

  defp measured_distance(%{scale_distance_meters: %Decimal{} = meters}),
    do: meters |> Decimal.round(1) |> Decimal.normalize() |> Decimal.to_string(:normal)

  defp measured_distance(_stop_level), do: nil

  defp mode_hint(%{has_diagram: false}), do: nil

  defp mode_hint(%{mode: :view, measurement_enabled: true}),
    do: "Mark two points a known distance apart, such as the width of a corridor."

  defp mode_hint(%{mode: :view}),
    do: "Click a point or pathway to edit it. Hold a point, then drag to move it."

  defp mode_hint(_assigns), do: nil

  attr :measurement_enabled, :boolean, default: false
  attr :has_scale, :boolean, default: false
  attr :scale_value, :string, default: nil
  attr :scale_distance, :string, default: nil
  attr :plan_width, :string, default: nil
  attr :editable, :boolean, default: true

  defp scale_control(assigns) do
    scale_open =
      JS.toggle(to: "#scale-actions-panel")
      |> JS.toggle_attribute({"aria-expanded", "true", "false"}, to: "#scale-actions-trigger")

    scale_close =
      JS.hide(to: "#scale-actions-panel")
      |> JS.set_attribute({"aria-expanded", "false"}, to: "#scale-actions-trigger")

    assigns =
      assigns
      |> assign(:scale_open, scale_open)
      |> assign(:scale_close, scale_close)

    ~H"""
    <%= cond do %>
      <% @measurement_enabled -> %>
        <span class="inline-flex min-h-11 items-center gap-1.5 font-[650] text-info-fg">
          <.ruler_icon class="size-4" /> Setting scale
        </span>
        <button
          type="button"
          class="inline-flex min-h-11 items-center rounded-control px-2 font-[650] text-action hover:bg-selection"
          phx-click="toggle_measurement"
        >
          Cancel
        </button>
      <% @has_scale and not @editable -> %>
        <span class="inline-flex min-h-11 items-center gap-1.5 text-muted">
          <.ruler_icon class="size-4" /> Scale {@scale_value} m per unit
        </span>
      <% @has_scale -> %>
        <div class="relative">
          <button
            id="scale-actions-trigger"
            type="button"
            class="inline-flex min-h-11 items-center gap-1.5 rounded-control px-2 text-default hover:bg-canvas"
            aria-expanded="false"
            aria-controls="scale-actions-panel"
            aria-label={"Scale #{@scale_value} meters per diagram unit. Scale options."}
            phx-click={@scale_open}
          >
            <.ruler_icon class="size-4 text-muted" /> Scale {@scale_value} m per unit
            <.icon name="hero-chevron-down" class="size-3.5 text-muted" />
          </button>
          <div
            id="scale-actions-panel"
            phx-click-away={@scale_close}
            phx-window-keydown={@scale_close}
            phx-key="escape"
            style="display: none;"
            class="absolute bottom-full right-0 z-30 mb-1 w-64 rounded-card border border-subtle bg-white p-1.5 shadow-float"
          >
            <p :if={@scale_distance} class="px-3 pb-1 pt-1.5 text-[12.5px] text-muted">
              Measured over {@scale_distance} m. The plan is about {@plan_width} m across.
            </p>
            <button
              type="button"
              class={menu_item_class()}
              phx-click={@scale_close |> JS.push("toggle_measurement")}
            >
              Recalibrate scale
            </button>
            <button
              type="button"
              class={menu_item_class()}
              phx-click={@scale_close |> JS.push("clear_calibration")}
            >
              Clear scale
            </button>
          </div>
        </div>
      <% @editable -> %>
        <button
          type="button"
          title="Lengths can't be measured from the plan until you set a scale"
          class="inline-flex min-h-11 items-center gap-1.5 rounded-control px-2 font-[650] text-warning-fg hover:bg-warning-bg"
          phx-click="toggle_measurement"
        >
          <.icon name="hero-exclamation-triangle" class="size-4" /> No scale · Set scale
        </button>
      <% true -> %>
        <span class="inline-flex min-h-11 items-center text-muted">No scale set</span>
    <% end %>
    """
  end

  attr :class, :string, default: "size-4"

  defp ruler_icon(assigns) do
    ~H"""
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="1.8"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
      class={["shrink-0", @class]}
    >
      <path d="M3 17 17 3l4 4L7 21zM8 16l1.5 1.5M11 13l1.5 1.5M14 10l1.5 1.5M17 7l1.5 1.5" />
    </svg>
    """
  end

  # ============================================================================
  # Diagram Upload Drawer
  # ============================================================================

  attr :open, :boolean, required: true
  attr :upload, Phoenix.LiveView.UploadConfig, required: true
  attr :active_level, :any, required: true
  attr :active_level_name, :string, required: true
  attr :upload_phase, :atom, required: true
  attr :diagram_error, :string, default: nil
  attr :has_diagram, :boolean, default: false

  def diagram_upload_drawer(assigns) do
    ~H"""
    <.drawer
      id="diagram-upload-drawer"
      chrome="planner"
      open={@open}
      on_close="close_diagram_upload_drawer"
      title={"Replace floorplan for #{@active_level_name}"}
      initial_focus={:first_field}
      return_focus_id="diagram-more-trigger"
      class="max-w-[480px]"
    >
      <:lede>Replacing it resets the scale. Placed points and pathways stay where they are.</:lede>
      <form
        :if={@has_diagram}
        id="diagram-upload-form-replace"
        phx-change="upload_diagram"
        class="flex min-h-0 flex-1 flex-col"
      >
        <.drawer_scroll>
          <.upload_field
            id="replace-floorplan-upload"
            upload={@upload}
            label="Floorplan image"
            help="PNG or JPEG, up to 10 MB."
            cancel_event="cancel_diagram_upload"
            state={upload_phase_to_state(@upload_phase)}
            disabled={@upload_phase in [:uploading, :validating, :probing_candidate, :committing]}
            pending_label={upload_pending_label(@upload_phase)}
          />
          <.message
            :if={@diagram_error}
            id="diagram-upload-error"
            kind="error"
            title={@diagram_error}
          />
        </.drawer_scroll>
      </form>
    </.drawer>
    """
  end

  defp upload_phase_to_state(:idle), do: :idle
  defp upload_phase_to_state(:uploading), do: :uploading
  defp upload_phase_to_state(:validating), do: :validating
  defp upload_phase_to_state(:probing_candidate), do: :probing_candidate
  defp upload_phase_to_state(:committing), do: :committing

  defp upload_phase_to_state(:awaiting_replacement_confirmation),
    do: :awaiting_replacement_confirmation

  defp upload_phase_to_state(:failed), do: :failed
  defp upload_phase_to_state(:succeeded), do: :succeeded
  defp upload_phase_to_state(_), do: :idle

  defp upload_pending_label(:uploading), do: "Uploading diagram…"
  defp upload_pending_label(:validating), do: "Validating diagram…"
  defp upload_pending_label(:probing_candidate), do: "Probing candidate…"
  defp upload_pending_label(:committing), do: "Committing diagram…"
  defp upload_pending_label(_), do: "Uploading diagram…"

  attr :other_levels, :list, default: []
  attr :enabled_count, :integer, default: 0

  def other_levels_panel(assigns) do
    open_panel =
      JS.toggle(to: "#other-levels-panel")
      |> JS.toggle_attribute({"aria-expanded", "true", "false"}, to: "#other-levels-button")

    close_panel =
      JS.hide(to: "#other-levels-panel")
      |> JS.set_attribute({"aria-expanded", "false"}, to: "#other-levels-button")

    assigns =
      assigns
      |> assign(:open_panel, open_panel)
      |> assign(:close_panel, close_panel)

    ~H"""
    <div class="relative">
      <button
        id="other-levels-button"
        type="button"
        class="btn btn-sm btn-ghost min-h-11"
        aria-haspopup="dialog"
        aria-controls="other-levels-panel"
        aria-expanded="false"
        phx-click={@open_panel}
      >
        <.icon name="hero-square-3-stack-3d" class="w-4 h-4" /> Other levels
        <span :if={@enabled_count > 0} class="badge badge-sm badge-primary">
          {@enabled_count}
        </span>
      </button>

      <div
        id="other-levels-panel"
        role="dialog"
        aria-label="Other levels"
        phx-click-away={@close_panel}
        phx-window-keydown={@close_panel}
        phx-key="escape"
        style="display: none;"
        class="absolute right-0 z-20 mt-2 w-80 rounded-box border border-base-300 bg-base-100 shadow-lg"
      >
        <div class="flex items-center justify-between border-b border-base-200 px-4 py-2">
          <span class="text-sm font-medium text-base-content">Other levels</span>
          <button
            type="button"
            class="btn btn-ghost btn-xs min-h-11"
            phx-click="clear_other_levels"
          >
            Clear
          </button>
        </div>

        <%= if @other_levels == [] do %>
          <p class="px-4 py-6 text-sm text-base-content/70">
            This station has no other levels to compare.
          </p>
        <% else %>
          <ul class="max-h-80 overflow-y-auto py-1">
            <li :for={row <- @other_levels} class="px-4 py-3">
              <div class="flex items-center gap-2">
                <span
                  class="inline-block h-3 w-3 shrink-0 rounded-full"
                  style={"background-color: #{row.color};"}
                  aria-hidden="true"
                >
                </span>
                <span class="truncate text-sm font-medium text-base-content">{row.name}</span>
              </div>
              <p class="mt-0.5 text-xs text-base-content/70">
                {row.geo_stop_count}/{row.total_stop_count} located
              </p>
              <div class="mt-2 flex flex-col gap-1">
                <label class="flex items-center gap-2 text-sm">
                  <input
                    type="checkbox"
                    class="checkbox checkbox-sm"
                    phx-click="toggle_other_level_floorplan"
                    phx-value-level-id={row.level_id}
                    checked={row.floorplan_on?}
                    disabled={not row.floorplan_eligible?}
                    aria-describedby={
                      not row.floorplan_eligible? && "floorplan-reason-#{row.level_id}"
                    }
                  />
                  <span>Floorplan</span>
                  <span
                    :if={not row.floorplan_eligible?}
                    id={"floorplan-reason-#{row.level_id}"}
                    class="text-xs text-base-content/70"
                  >
                    {floorplan_disabled_reason(row)}
                  </span>
                </label>
                <label class="flex items-center gap-2 text-sm">
                  <input
                    type="checkbox"
                    class="checkbox checkbox-sm"
                    phx-click="toggle_other_level_stops"
                    phx-value-level-id={row.level_id}
                    checked={row.stops_on?}
                    disabled={not row.stops_eligible?}
                    aria-describedby={not row.stops_eligible? && "stops-reason-#{row.level_id}"}
                  />
                  <span>Stops</span>
                  <span
                    :if={not row.stops_eligible?}
                    id={"stops-reason-#{row.level_id}"}
                    class="text-xs text-base-content/70"
                  >
                    No geo-coded child stops
                  </span>
                </label>
              </div>
            </li>
          </ul>
        <% end %>
      </div>
    </div>
    """
  end

  defp floorplan_disabled_reason(%{has_diagram?: false}), do: "No diagram"
  defp floorplan_disabled_reason(_row), do: "Not yet aligned"

  attr :organization_id, :string, required: true
  attr :gtfs_version_id, :string, required: true
  attr :station, :any, required: true
  attr :active_level, :any, default: nil
  attr :active_stop_level, :any, default: nil
  attr :align_center_lat, :any, default: nil
  attr :align_center_lon, :any, default: nil
  attr :align_scale_mpp, :any, default: nil
  attr :align_rotation_deg, :any, default: nil
  attr :image_natural_width, :any, default: nil
  attr :image_natural_height, :any, default: nil
  attr :child_stops_total, :integer, default: 0
  attr :child_stops_with_geo, :integer, default: 0
  attr :child_stops_with_floorplan, :integer, default: 0
  attr :anchor_count, :integer, default: 0
  attr :cross_level_pathway_total, :integer, default: 0
  attr :cross_level_pathway_with_geo, :integer, default: 0
  attr :other_levels_floorplan_count, :integer, default: 0
  attr :map_generation, :string, required: true
  attr :map_state, :atom, default: :initializing
  attr :alignment_preview, :map, default: nil
  attr :alignment_unsaved?, :boolean, default: false
  # Measured fit of the operator's current placement, scored server-side from
  # FloorplanTransform.residual_rmse_meters/4. `nil` until a scoring round trip
  # resolves, which is also the resting state on first render.
  #   nil
  # | %{status: :ready, rmse_meters: float(), anchor_count: pos_integer()}
  # | %{status: :insufficient_anchors, anchor_count: non_neg_integer()}
  # | %{status: :unavailable}
  attr :alignment_fit, :map, default: nil
  attr :coordinate_review, :map, default: nil
  attr :review_transform, :map, default: nil
  attr :coordinate_review_status, :string, default: nil
  attr :coordinate_review_error, :string, default: nil

  def map_canvas(assigns) do
    # Popover wiring for the two demoted control clusters, following the
    # #level-control-trigger / #level-control-panel idiom in this module.
    # `close` hides and resets the trigger's aria-expanded; `dismiss` also
    # returns focus. `dismiss` is used only where the panel is known to be
    # open — phx-click-away is visibility-guarded by LiveView, and the
    # trigger's own phx-keydown only fires while the trigger has focus.
    center_close =
      JS.hide(to: "#map-alignment-center-panel")
      |> JS.set_attribute({"aria-expanded", "false"}, to: "#map-alignment-center-trigger")

    zoom_close =
      JS.hide(to: "#map-alignment-zoom-panel")
      |> JS.set_attribute({"aria-expanded", "false"}, to: "#map-alignment-zoom-trigger")

    # phx-window-keydown fires on every Escape anywhere on the page, and
    # phx-keydown fires only when the event target itself carries it — so a
    # panel-level phx-keydown never sees Escape typed in a panel input. The
    # window path therefore carries the focus, gated on the trigger's own
    # aria-expanded so it returns focus when the panel is open and leaves
    # focus alone when it is not.
    center_window_dismiss =
      JS.focus(to: "#map-alignment-center-trigger[aria-expanded='true']")
      |> JS.hide(to: "#map-alignment-center-panel")
      |> JS.set_attribute({"aria-expanded", "false"}, to: "#map-alignment-center-trigger")

    zoom_window_dismiss =
      JS.focus(to: "#map-alignment-zoom-trigger[aria-expanded='true']")
      |> JS.hide(to: "#map-alignment-zoom-panel")
      |> JS.set_attribute({"aria-expanded", "false"}, to: "#map-alignment-zoom-trigger")

    floorplan_url =
      diagram_image_href(
        assigns.organization_id,
        assigns.gtfs_version_id,
        assigns.station,
        assigns.active_stop_level
      )

    initial_lat = assigns.station.stop_lat || 0
    initial_lon = assigns.station.stop_lon || 0

    has_alignment? =
      not is_nil(assigns.align_center_lat) and
        not is_nil(assigns.align_center_lon) and
        not is_nil(assigns.align_scale_mpp) and
        not is_nil(assigns.align_rotation_deg)

    # Tie the hook root's DOM id to the active stop_level so switching levels
    # remounts the hook with the new level's floorplan and alignment attrs.
    canvas_id =
      case assigns.active_stop_level do
        %{id: id} -> "map-canvas-#{id}"
        _ -> "map-canvas"
      end

    assigns =
      assigns
      |> assign(:floorplan_url, floorplan_url)
      |> assign(:initial_lat, initial_lat)
      |> assign(:initial_lon, initial_lon)
      |> assign(:has_alignment?, has_alignment?)
      |> assign(:map_state_message, map_state_message(assigns.map_state))
      |> assign(
        :map_controls_disabled_reason,
        map_controls_disabled_reason(
          assigns.map_state,
          assigns.image_natural_width,
          assigns.image_natural_height
        )
      )
      |> assign(
        :auto_alignment_disabled_reason,
        auto_alignment_disabled_reason(
          assigns.map_state,
          assigns.image_natural_width,
          assigns.image_natural_height
        )
      )
      |> assign(:canvas_id, canvas_id)
      |> assign(
        :center_open,
        JS.toggle(to: "#map-alignment-center-panel")
        |> JS.toggle_attribute({"aria-expanded", "true", "false"},
          to: "#map-alignment-center-trigger"
        )
      )
      |> assign(:center_window_dismiss, center_window_dismiss)
      |> assign(:center_dismiss, JS.focus(center_close, to: "#map-alignment-center-trigger"))
      |> assign(
        :zoom_open,
        JS.toggle(to: "#map-alignment-zoom-panel")
        |> JS.toggle_attribute({"aria-expanded", "true", "false"},
          to: "#map-alignment-zoom-trigger"
        )
      )
      |> assign(:zoom_window_dismiss, zoom_window_dismiss)
      |> assign(:zoom_dismiss, JS.focus(zoom_close, to: "#map-alignment-zoom-trigger"))
      # `display: "flex"` is load-bearing, not cosmetic: JS.toggle restores
      # `block` by default, which would drop the panel's flex column and leave
      # the scroll body unconstrained — the header would scroll away and
      # everything past the panel's height would be clipped with no way to reach
      # it.
      |> assign(
        :help_open,
        JS.toggle(to: "#map-alignment-help-panel", display: "flex")
        |> JS.toggle_attribute({"aria-expanded", "true", "false"},
          to: "#map-alignment-help-trigger"
        )
      )
      |> assign(
        :help_dismiss,
        JS.focus(to: "#map-alignment-help-trigger[aria-expanded='true']")
        |> JS.hide(to: "#map-alignment-help-panel")
        |> JS.set_attribute({"aria-expanded", "false"}, to: "#map-alignment-help-trigger")
      )
      |> assign(:residual_readout, residual_readout(assigns.alignment_fit))
      # While a scoring round trip is in flight the hook swaps the value's text
      # for "Measuring…" and sets data-fit-state="measuring" on the container.
      # The band it replaces must go with it: a warning colour left standing
      # over "Measuring…" is exactly the stale verdict read as current that this
      # readout exists to prevent. Both lines therefore fall back to the neutral
      # readout role for that one attribute value, so the hook still writes only
      # text and a presentational attribute and never touches a class.
      |> assign(
        :measuring_class,
        "group-data-[fit-state=measuring]:font-normal group-data-[fit-state=measuring]:text-base-content/70"
      )
      |> assign_review_projection()

    ~H"""
    <div class="flex min-h-0 flex-1 flex-col">
      <%!-- `tabindex="-1"` is what makes the keyboard bindings on this element
      reachable. The hook binds nudging and hold-to-hide here rather than on the
      ignored canvas, because the tools panel is a sibling of that canvas
      (INV-10E-3) — but a plain `<div>` cannot hold focus, so after the most
      common gesture of all, dragging the floorplan with the mouse, focus sits
      on `<body>` and every shortcut is dead. `-1` keeps the element out of the
      tab order, so the tab chain through the controls is unchanged; it only
      lets a click on the imagery land focus inside the workspace. --%>
      <div id="map-alignment-workspace" tabindex="-1" class="relative flex min-h-0 flex-1">
        <div
          id={@canvas_id}
          class="map-canvas relative min-h-0 flex-1 bg-base-200 border border-base-300 rounded-lg overflow-hidden aspect-square"
          phx-hook="MapAlignment"
          phx-update="ignore"
          data-active-level-id={@active_level && @active_level.level_id}
          data-floorplan-url={@floorplan_url}
          data-initial-lat={@initial_lat}
          data-initial-lon={@initial_lon}
          data-initial-zoom="19"
          data-align-center-lat={if @has_alignment?, do: @align_center_lat}
          data-align-center-lon={if @has_alignment?, do: @align_center_lon}
          data-align-scale-mpp={if @has_alignment?, do: @align_scale_mpp}
          data-align-rotation-deg={if @has_alignment?, do: @align_rotation_deg}
          data-image-natural-width={@image_natural_width}
          data-image-natural-height={@image_natural_height}
          data-map-generation={@map_generation}
        >
          <div id="map-alignment-leaflet" class="absolute inset-0" style="z-index: 0;"></div>
          <div
            id="map-other-overlays"
            class="absolute inset-0"
            style="z-index: 1; pointer-events: none;"
          >
          </div>
          <div
            id="map-alignment-overlay"
            data-overlay-role="active"
            data-editable-overlay="true"
            class="absolute inset-0 cursor-move"
            style="z-index: 2; transform-origin: center;"
          >
            <img
              src={@floorplan_url}
              alt="Level floorplan"
              class="absolute inset-0 w-full h-full object-contain pointer-events-none"
            />
          </div>
          <button
            id="map-alignment-rotate-handle"
            data-edit-target-overlay="active"
            type="button"
            title="Drag to rotate the floorplan"
            aria-label="Rotate floorplan"
            class="absolute top-2 right-2 w-8 h-8 bg-white border border-base-300 rounded-full shadow flex items-center justify-center cursor-grab text-base-content/70 hover:bg-base-200"
            style="z-index: 3;"
          >
            <.icon name="hero-arrow-path" class="w-4 h-4" />
          </button>
          <div
            id="map-other-pins"
            class="absolute inset-0 pointer-events-none"
            style="z-index: 4;"
          >
          </div>
          <div
            id="map-alignment-pins-active"
            data-overlay-role="active"
            class="absolute inset-0 pointer-events-none"
            style="z-index: 5;"
          >
          </div>
          <button
            id="map-alignment-scale-handle"
            data-edit-target-overlay="active"
            type="button"
            title="Drag to resize the floorplan"
            aria-label="Resize floorplan"
            class="absolute bottom-2 right-2 w-8 h-8 bg-white border border-base-300 rounded-full shadow flex items-center justify-center cursor-grab text-base-content/70 hover:bg-base-200"
            style="z-index: 3;"
          >
            <.icon name="hero-arrows-pointing-out" class="w-4 h-4" />
          </button>
        </div>
        <div
          id="map-alignment-tools"
          class="absolute z-20 top-4 left-4 flex w-auto max-h-[calc(100%-2rem)] flex-col gap-1 bg-base-100 border border-base-300 rounded-lg shadow-md p-1"
        >
          <div class="flex items-center justify-between gap-1 px-0.5">
            <button
              id="map-alignment-restore-saved"
              type="button"
              class="tooltip tooltip-right btn btn-ghost btn-square h-8 w-8 min-h-8 p-0 text-primary disabled:text-base-content/30"
              phx-click="restore_saved_alignment"
              disabled={not @alignment_unsaved?}
              data-tip="Restore saved alignment"
              aria-label="Restore saved alignment"
            >
              <.icon name="hero-arrow-path" class="w-4 h-4" />
            </button>
            <button
              id="map-alignment-tools-toggle"
              type="button"
              class="tooltip tooltip-right btn btn-ghost btn-square h-8 w-8 min-h-8 p-0 text-base-content/70"
              data-collapsed="false"
              data-tip="Hide tools"
              aria-label="Hide tools"
            >
              <.icon name="hero-chevron-up" class="w-4 h-4" />
            </button>
          </div>

          <%!-- All eight transform controls in one pad: the cross moves, the top
          corners rotate, the bottom corners scale. Every button carries its
          operation, plain step and Shift step in `title`, so the pad needs no
          row labels and no live readouts — the floorplan itself, and the
          residual metres in the commit bar, are the feedback that matters. --%>
          <%!-- The pad rounds its own corner cells rather than clipping the grid:
          an `overflow-hidden` here would also clip every button's tooltip. --%>
          <div class="grid w-fit grid-cols-[repeat(3,2.75rem)] gap-px rounded-md border border-base-300 bg-base-300">
            <.transform_button control={transform_control("rotate-left")} class="rounded-tl-md" />
            <.transform_button control={transform_control("up")} />
            <.transform_button control={transform_control("rotate-right")} class="rounded-tr-md" />
            <.transform_button control={transform_control("left")} />
            <div class="h-11 w-11 bg-base-100"></div>
            <.transform_button control={transform_control("right")} />
            <.transform_button control={transform_control("scale-down")} class="rounded-bl-md" />
            <.transform_button control={transform_control("down")} />
            <.transform_button control={transform_control("scale-up")} class="rounded-br-md" />
          </div>

          <div class="flex h-9 w-[8.5rem] items-center gap-1.5 px-1">
            <label
              for="map-alignment-opacity"
              class="tooltip tooltip-right shrink-0 text-base-content/60"
              data-tip="Floorplan opacity"
            >
              <.icon name="hero-photo" class="w-4 h-4" />
            </label>
            <div
              id="map-alignment-opacity-tip"
              class="tooltip tooltip-right min-w-0 flex-1"
              data-tip="Floorplan opacity · 70%"
            >
              <input
                id="map-alignment-opacity"
                type="range"
                min="0"
                max="1"
                step="0.05"
                value="0.7"
                phx-update="ignore"
                class="range range-xs w-full text-base-content/40 border border-base-300 bg-base-200/60"
              />
            </div>
          </div>

          <%= if @other_levels_floorplan_count >= 1 do %>
            <div class="flex h-9 w-[8.5rem] items-center gap-1.5 px-1">
              <label
                for="map-other-overlays-opacity"
                class="tooltip tooltip-right shrink-0 text-base-content/60"
                data-tip="Other-levels opacity"
              >
                <.icon name="hero-square-3-stack-3d" class="w-4 h-4" />
              </label>
              <div
                id="map-other-overlays-opacity-tip"
                class="tooltip tooltip-right min-w-0 flex-1"
                data-tip="Other-levels opacity · 70%"
              >
                <input
                  id="map-other-overlays-opacity"
                  type="range"
                  min="0"
                  max="1"
                  step="0.05"
                  value="0.7"
                  phx-update="ignore"
                  class="range range-xs w-full text-base-content/40 border border-base-300 bg-base-200/60"
                />
              </div>
            </div>
          <% end %>
        </div>
        <div
          :if={@alignment_preview && @alignment_preview.status == :ready}
          id="auto-alignment-status"
          role="status"
          aria-live="polite"
          aria-describedby="auto-alignment-fit-value auto-alignment-fit-description"
          class="absolute z-10 top-4 left-1/2 -translate-x-1/2 inline-flex items-center gap-2 bg-blue-50 border border-blue-200 rounded-md px-3 py-2 text-sm text-blue-900 shadow-sm"
        >
          <strong class="font-medium">Unsaved auto-alignment preview</strong>
        </div>
        <%!-- In-app help for the align surface, opened from the commit bar.
        Reactive help, not a coach mark: the operator asked for it, so it takes
        the whole workspace and answers the concept, the task and the reference
        in that order rather than rationing itself to a corner. The commit bar
        stays visible below, so every control the copy names is on screen while
        it is read. --%>
        <div
          id="map-alignment-help-panel"
          role="dialog"
          aria-labelledby="map-alignment-help-title"
          phx-click-away={@help_dismiss}
          phx-window-keydown={@help_dismiss}
          phx-key="escape"
          style="display: none;"
          class="absolute inset-0 z-30 flex flex-col overflow-hidden bg-base-100 border border-base-300 rounded-lg shadow-lg text-sm"
        >
          <div class="flex shrink-0 items-start justify-between gap-6 border-b border-base-300 px-6 py-5">
            <div class="min-w-0">
              <h2 id="map-alignment-help-title" class="text-lg font-semibold tracking-tight">
                Aligning a floorplan
              </h2>
              <p class="mt-1 max-w-[70ch] text-base-content/80">
                A floorplan is a picture with no place on the earth. Aligning gives it one, so a
                stop you drew on the plan can be turned into a real coordinate.
              </p>
            </div>
            <button
              id="map-alignment-help-close"
              type="button"
              class="btn btn-ghost btn-square min-h-11 h-11 w-11 shrink-0 p-0 text-base-content/70"
              aria-label="Close help"
              phx-click={@help_dismiss}
            >
              <.icon name="hero-x-mark" class="size-5" />
            </button>
          </div>

          <div class="min-h-0 flex-1 overflow-y-auto overscroll-contain">
            <div class="grid gap-x-10 gap-y-7 px-6 py-6 lg:grid-cols-2">
              <.help_section
                class="lg:col-span-2"
                icon="hero-globe-alt"
                tone="primary"
                title="What alignment records"
              >
                <p class="max-w-[70ch]">
                  Aligning stores three facts about this level's image.
                </p>
                <dl class="mt-4 grid gap-4 sm:grid-cols-3">
                  <div
                    :for={row <- align_records_rows()}
                    class="rounded-md border border-base-200 p-4"
                  >
                    <dt class="flex items-center gap-2.5 font-semibold text-base-content">
                      <span class="flex size-9 shrink-0 items-center justify-center rounded-md bg-primary/12 text-primary">
                        <.icon name={row.icon} class="size-5" />
                      </span>
                      {row.term}
                    </dt>
                    <dd class="mt-2 text-base-content/80">{row.description}</dd>
                  </div>
                </dl>
                <p class="mt-4 max-w-[70ch]">
                  Those three turn any point on the plan into a latitude and longitude. That
                  conversion is what
                  <span class="font-semibold text-base-content">Update stop coordinates…</span>
                  writes and what <span class="font-semibold text-base-content">Fit</span>
                  measures. Moving the plan changes them; nothing is written until you save.
                </p>
              </.help_section>

              <.help_section
                class="lg:col-span-2"
                icon="hero-list-bullet"
                tone="primary"
                title="The usual path"
              >
                <ol class="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
                  <li
                    :for={{step, index} <- Enum.with_index(align_path_steps(), 1)}
                    class="rounded-md border border-base-200 p-4"
                  >
                    <p class="flex items-center gap-2.5">
                      <span class="flex size-7 shrink-0 items-center justify-center rounded-full bg-primary text-sm font-semibold text-primary-content">
                        {index}
                      </span>
                      <span class="font-semibold text-base-content">{step.title}</span>
                    </p>
                    <p class="mt-2 text-base-content/80">{step.description}</p>
                  </li>
                </ol>
                <p class="mt-4 max-w-[70ch] text-base-content/70">
                  With fewer than three anchor stops there is nothing to solve from. Skip to step
                  three and place the plan by eye against the imagery.
                </p>
              </.help_section>

              <.help_section icon="hero-map-pin" tone="info" title="Anchor stops">
                <p>
                  An anchor is a child stop on this level carrying
                  <span class="font-semibold text-base-content">
                    both a position on the floorplan and real map coordinates
                  </span>
                  of its own. Two features run on anchors: Auto-align solves the alignment
                  from them, and Fit scores an alignment against them.
                </p>
                <p class="mt-3">
                  Three is the minimum. Two anchors fix a scale, a rotation and a position
                  exactly, so a two-anchor fit always scores zero and tells you nothing.
                </p>
                <p class="mt-3 text-base-content/70">
                  The bar below counts how many child stops sit on the plan, under <span class="font-medium text-base-content">Placed</span>. Fit names how many
                  anchors it measured over.
                </p>
              </.help_section>

              <.help_section icon="hero-check-badge" tone="success" title="Reading the fit">
                <p>
                  Fit is the root-mean-square distance between where each anchor lands under the
                  current alignment and where its own coordinates put it. Lower is better.
                </p>
                <dl class="mt-3 flex flex-col divide-y divide-base-200 border-y border-base-200">
                  <div :for={row <- align_fit_rows()} class="flex gap-4 py-2.5">
                    <dt class={["w-40 shrink-0 font-medium tabular-nums", row.tone_class]}>
                      {row.reading}
                    </dt>
                    <dd class="min-w-0 text-base-content/80">{row.meaning}</dd>
                  </div>
                </dl>
                <p class="mt-3 text-base-content/70">Fit never blocks a save.</p>
              </.help_section>

              <.help_section
                class="lg:col-span-2"
                icon="hero-cursor-arrow-rays"
                tone="neutral"
                title="Moving the floorplan"
              >
                <div class="grid gap-x-10 gap-y-6 lg:grid-cols-2">
                  <div>
                    <p>
                      The pad in the top left corner of the map drives three operations. The
                      diagram repeats its layout, tinted by operation.
                    </p>
                    <div class="mt-4 flex flex-wrap items-start gap-6">
                      <div
                        aria-hidden="true"
                        class="grid w-fit shrink-0 grid-cols-[repeat(3,3rem)] gap-px rounded-md border border-base-300 bg-base-300"
                      >
                        <span
                          :for={cell <- align_pad_diagram_cells()}
                          class={[
                            "flex size-12 items-center justify-center text-lg font-medium",
                            cell.class
                          ]}
                        >
                          {cell.glyph}
                        </span>
                      </div>

                      <table class="min-w-0 flex-1 text-left">
                        <thead>
                          <tr class="border-b border-base-200 text-xs text-base-content/60">
                            <th scope="col" class="pb-1.5 pr-3 font-medium">Operation</th>
                            <th scope="col" class="pb-1.5 pr-3 font-medium">Keys</th>
                            <th scope="col" class="pb-1.5 pr-3 font-medium">Step</th>
                            <th scope="col" class="pb-1.5 font-medium">Shift</th>
                          </tr>
                        </thead>
                        <tbody>
                          <tr :for={row <- align_transform_rows()} class="border-b border-base-200">
                            <th
                              scope="row"
                              class={["py-2 pr-3 font-semibold whitespace-nowrap", row.tone_class]}
                            >
                              {row.operation}
                            </th>
                            <td class="py-2 pr-3 whitespace-nowrap text-base-content/80">
                              {row.keys}
                            </td>
                            <td class="py-2 pr-3 tabular-nums whitespace-nowrap text-base-content/80">
                              {row.step}
                            </td>
                            <td class="py-2 tabular-nums whitespace-nowrap text-base-content/80">
                              {row.shift_step}
                            </td>
                          </tr>
                        </tbody>
                      </table>
                    </div>
                    <p class="mt-4 text-base-content/70">
                      Keys act on the map only while focus is inside the workspace. If a key does
                      nothing, click the imagery once and try again.
                    </p>
                  </div>

                  <div>
                    <p>Or work on the map directly.</p>
                    <dl class="mt-4 flex flex-col gap-3">
                      <div :for={row <- align_map_gesture_rows()} class="flex items-start gap-3">
                        <dt class="flex size-8 shrink-0 items-center justify-center rounded-md border border-base-300 bg-base-200 text-base-content/70">
                          <.icon :if={row[:icon]} name={row.icon} class="size-4" />
                          <span :if={row[:key]} class="text-sm font-semibold">{row.key}</span>
                        </dt>
                        <dd class="min-w-0 pt-1">
                          <span class="font-semibold text-base-content">{row.term}</span>
                          <span class="text-base-content/80">{row.description}</span>
                        </dd>
                      </div>
                    </dl>
                  </div>
                </div>
              </.help_section>

              <.help_section icon="hero-eye" tone="neutral" title="Seeing what you are doing">
                <p>
                  An opaque floorplan hides the imagery you are matching it to. Four controls
                  trade one view for the other.
                </p>
                <dl class="mt-3 flex flex-col gap-3">
                  <div :for={row <- align_visibility_rows()} class="flex items-start gap-3">
                    <dt class="flex size-8 shrink-0 items-center justify-center rounded-md border border-base-300 bg-base-200 text-base-content/70">
                      <.icon :if={row[:icon]} name={row.icon} class="size-4" />
                      <span :if={row[:key]} class="text-sm font-semibold">{row.key}</span>
                    </dt>
                    <dd class="min-w-0 pt-1">
                      <span class="font-semibold text-base-content">{row.term}</span>
                      <span class="text-base-content/80">{row.description}</span>
                    </dd>
                  </div>
                </dl>
              </.help_section>

              <.help_section
                icon="hero-square-3-stack-3d"
                tone="info"
                title="Another level as a guide"
              >
                <p>
                  A station's levels sit on top of each other in the real world, so a level you
                  have already aligned is the best reference for the next one. The
                  <span class="font-semibold text-base-content">
                    Other levels
                  </span>
                  menu in the strip above the map brings one onto this map in its own
                  color.
                </p>
                <dl class="mt-3 flex flex-col gap-3">
                  <div :for={row <- align_guide_rows()} class="flex items-start gap-3">
                    <dt class="flex size-8 shrink-0 items-center justify-center rounded-md bg-info/12 text-info">
                      <.icon name={row.icon} class="size-4" />
                    </dt>
                    <dd class="min-w-0 pt-1">
                      <span class="font-semibold text-base-content">{row.term}</span>
                      <span class="text-base-content/80">{row.description}</span>
                    </dd>
                  </div>
                </dl>
                <p class="mt-3 text-base-content/70">
                  A box you cannot tick states why beside it: the level has no diagram, is not
                  aligned yet, or has no stops with coordinates.
                </p>
              </.help_section>

              <.help_section icon="hero-inbox-arrow-down" tone="warning" title="Saving your work">
                <dl class="flex flex-col gap-3">
                  <div :for={row <- align_save_rows()}>
                    <dt class="font-semibold text-base-content">{row.term}</dt>
                    <dd class="mt-0.5 text-base-content/80">{row.description}</dd>
                  </div>
                </dl>
                <p class="mt-3 text-base-content/70">
                  <span class="font-medium text-base-content">Unsaved</span>
                  in the bar below means the plan has moved since the last save.
                </p>
              </.help_section>

              <.help_section
                icon="hero-exclamation-triangle"
                tone="warning"
                title="When Auto-align refuses"
              >
                <p>
                  Auto-align declines rather than applying a fit it cannot stand behind. The bar
                  below states which case you hit.
                </p>
                <dl class="mt-3 flex flex-col gap-3">
                  <div :for={row <- align_blocked_rows()}>
                    <dt class="font-semibold text-base-content">{row.term}</dt>
                    <dd class="mt-0.5 text-base-content/80">{row.description}</dd>
                  </div>
                </dl>
              </.help_section>
            </div>
          </div>
        </div>
      </div>
      <div class="shrink-0 border-t border-subtle bg-white py-2">
        <%!-- Read on the left, act on the right, and the three kinds of acting
        kept apart: view changes nothing, assist moves the floorplan, commit
        writes to the database. --%>
        <div
          id="map-alignment-commit-bar"
          class="flex flex-wrap items-center gap-x-4 gap-y-2 px-3"
        >
          <dl class="flex min-w-0 shrink flex-wrap items-center gap-x-5 gap-y-1 text-xs">
            <div
              id="map-alignment-residual"
              data-fit-state={@residual_readout.state}
              class="group flex items-baseline gap-1.5 whitespace-nowrap"
            >
              <dt class="text-base-content/60">Fit</dt>
              <dd
                id="map-alignment-residual-value"
                class={[@residual_readout.value_class, @measuring_class]}
              >
                {@residual_readout.value}
              </dd>
              <%!-- Hidden while a measurement is in flight. The hook replaces the
              value with "Measuring…" but cannot reach this, and a qualifier left
              standing beside it would be the stale verdict read as current. --%>
              <dd
                :if={@residual_readout.qualifier}
                class={[
                  "group-data-[fit-state=measuring]:hidden",
                  @residual_readout.qualifier_class
                ]}
              >
                {@residual_readout.qualifier}
              </dd>
            </div>

            <div
              data-role="child-stop-coverage"
              class="flex items-baseline gap-1.5 whitespace-nowrap"
            >
              <dt class="text-base-content/60">Placed</dt>
              <dd class="font-medium tabular-nums text-base-content">
                {@child_stops_with_floorplan} of {@child_stops_total}
              </dd>
              <dd :if={unplaced_note(@child_stops_unplaced)} class="text-base-content/50">
                {unplaced_note(@child_stops_unplaced)}
              </dd>
            </div>

            <div
              :if={@alignment_unsaved?}
              id="map-alignment-unsaved"
              class="flex items-baseline gap-1.5 whitespace-nowrap"
            >
              <dt class="sr-only">Status</dt>
              <dd class="inline-flex items-center gap-1.5 font-medium text-warning">
                <span class="inline-block size-1.5 rounded-full bg-warning"></span>Unsaved
              </dd>
            </div>
          </dl>

          <%!-- Help closes the read-only group: it explains the surface, it does
          not act on it. --%>
          <button
            id="map-alignment-help-trigger"
            type="button"
            class="btn btn-ghost btn-sm min-h-11 shrink-0 gap-1.5 px-3 text-xs font-medium text-base-content/70"
            aria-expanded="false"
            aria-controls="map-alignment-help-panel"
            phx-click={@help_open}
          >
            <.icon name="hero-question-mark-circle-solid" class="size-5" /> Help
          </button>

          <div class="ml-auto flex shrink-0 flex-wrap items-center gap-2">
            <div class="join">
              <div class="relative join-item">
                <button
                  id="map-alignment-center-trigger"
                  type="button"
                  class="tooltip tooltip-top btn btn-sm join-item min-h-11 px-3"
                  data-tip="Center the map on a coordinate"
                  aria-label="Center the map on a coordinate"
                  aria-expanded="false"
                  aria-controls="map-alignment-center-panel"
                  phx-click={@center_open}
                  phx-keydown={@center_dismiss}
                  phx-key="escape"
                >
                  <.icon name="hero-viewfinder-circle" class="size-4" />
                </button>

                <div
                  id="map-alignment-center-panel"
                  phx-click-away={@center_dismiss}
                  phx-window-keydown={@center_window_dismiss}
                  phx-key="escape"
                  style="display: none;"
                  class="absolute left-0 bottom-full mb-1 z-30 flex w-52 flex-col gap-3 border border-base-300 bg-base-100 rounded-box shadow-lg p-3 text-sm"
                >
                  <div class="flex flex-col gap-1">
                    <label
                      for="map-alignment-lat-input"
                      class="text-xs font-medium text-base-content/80"
                    >
                      Latitude
                    </label>
                    <input
                      id="map-alignment-lat-input"
                      type="number"
                      step="any"
                      value={@initial_lat}
                      class="input input-sm input-bordered min-h-11 w-full"
                    />
                  </div>
                  <div class="flex flex-col gap-1">
                    <label
                      for="map-alignment-lon-input"
                      class="text-xs font-medium text-base-content/80"
                    >
                      Longitude
                    </label>
                    <input
                      id="map-alignment-lon-input"
                      type="number"
                      step="any"
                      value={@initial_lon}
                      class="input input-sm input-bordered min-h-11 w-full"
                    />
                  </div>
                  <button
                    id="map-alignment-apply-center"
                    type="button"
                    class="btn btn-sm btn-block min-h-11"
                  >
                    Center map
                  </button>
                </div>
              </div>

              <div class="relative join-item">
                <button
                  id="map-alignment-zoom-trigger"
                  type="button"
                  class="tooltip tooltip-top btn btn-sm join-item min-h-11 px-3"
                  data-tip="Change the map zoom"
                  aria-label="Change the map zoom"
                  aria-expanded="false"
                  aria-controls="map-alignment-zoom-panel"
                  phx-click={@zoom_open}
                  phx-keydown={@zoom_dismiss}
                  phx-key="escape"
                >
                  <.icon name="hero-magnifying-glass" class="size-4" />
                </button>

                <div
                  id="map-alignment-zoom-panel"
                  phx-click-away={@zoom_dismiss}
                  phx-window-keydown={@zoom_window_dismiss}
                  phx-key="escape"
                  style="display: none;"
                  class="absolute left-0 bottom-full mb-1 z-30 flex w-52 flex-col gap-1 border border-base-300 bg-base-100 rounded-box shadow-lg p-3 text-sm"
                >
                  <div class="flex items-baseline justify-between gap-2">
                    <label for="map-alignment-zoom" class="text-xs font-medium text-base-content/80">
                      Map zoom
                    </label>
                    <span
                      id="map-alignment-zoom-value"
                      class="text-xs tabular-nums text-base-content/70"
                    >
                      19.0
                    </span>
                  </div>
                  <input
                    id="map-alignment-zoom"
                    type="range"
                    min="19"
                    max="22"
                    step="0.5"
                    value="19"
                    class="range range-xs w-full"
                    phx-update="ignore"
                  />
                </div>
              </div>
            </div>

            <div class="h-6 w-px shrink-0 bg-base-300"></div>

            <button
              id="map-alignment-preview-auto"
              type="button"
              class="btn btn-sm min-h-11 shrink-0 phx-click-loading:opacity-60"
              phx-click="preview_alignment"
              phx-disable-with="Aligning…"
              title={"Positions the floorplan from the #{@anchor_count} stops that already have both a floorplan position and map coordinates"}
              disabled={
                @map_state == :fatal or
                  invalid_floorplan_image_dims?(@image_natural_width, @image_natural_height)
              }
              aria-describedby={
                if @auto_alignment_disabled_reason,
                  do: "map-auto-alignment-disabled-reason"
              }
            >
              Auto-align
            </button>

            <div class="h-6 w-px shrink-0 bg-base-300"></div>

            <div id="map-alignment-actions" class="flex shrink-0 items-center gap-2">
              <button
                id="map-alignment-save"
                type="button"
                class="btn btn-sm min-h-11"
                disabled={@map_state == :fatal}
              >
                Save position
              </button>
              <button
                id="map-alignment-apply"
                type="button"
                class="btn btn-sm btn-primary min-h-11"
                title="Review every coordinate change before it is written"
                disabled={
                  @map_state == :fatal or
                    invalid_floorplan_image_dims?(@image_natural_width, @image_natural_height)
                }
              >
                Update stop coordinates…
              </button>
              <button
                :if={@map_state in [:offline, :imagery_unavailable, :buildings_degraded, :fatal]}
                id="map-alignment-retry"
                type="button"
                class="btn btn-sm min-h-11"
                phx-click="retry_map_alignment"
              >
                Retry map
              </button>
            </div>
          </div>

          <%!-- Anything that only applies in a degraded or blocked state gets its
          own line beneath, so the resting bar stays one row. --%>
          <div
            :if={
              @map_state_message || @map_controls_disabled_reason ||
                @auto_alignment_disabled_reason ||
                (@alignment_preview && @alignment_preview.status in [:ready, :error])
            }
            class="flex basis-full flex-wrap items-center gap-x-4 gap-y-1 text-xs"
          >
            <p
              :if={@map_state_message}
              id="map-alignment-state"
              class="text-base-content/70"
              aria-live="polite"
            >
              {@map_state_message}
            </p>
            <p
              :if={@map_controls_disabled_reason}
              id="map-alignment-disabled-reason"
              class="text-base-content/70"
            >
              {@map_controls_disabled_reason}
            </p>
            <p
              :if={@auto_alignment_disabled_reason}
              id="map-auto-alignment-disabled-reason"
              class="text-base-content/70"
            >
              {@auto_alignment_disabled_reason}
            </p>
            <%= if @alignment_preview && @alignment_preview.status == :ready do %>
              <span id="auto-alignment-fit-value" class="text-base-content/70">
                Suggested alignment fits to
                <strong class="text-base-content">
                  {:erlang.float_to_binary(@alignment_preview.rmse_meters, decimals: 1)} m
                </strong>
              </span>
              <span class="text-base-content/60" id="auto-alignment-fit-description">
                Measured over {@alignment_preview.anchor_count} anchor stops. Lower is better.
              </span>
            <% end %>
            <%= if @alignment_preview && @alignment_preview.status == :error do %>
              <span id="auto-alignment-error" role="alert" class="text-error">
                {@alignment_preview.message}
              </span>
              <%= if @alignment_preview.reason == :insufficient_anchors do %>
                <span class="text-base-content/70">
                  Place more stops with both a floorplan position and map coordinates, then try again.
                </span>
              <% end %>
              <%= if @alignment_preview.reason == :high_residual do %>
                <span class="text-base-content/70">
                  Check the anchor stops' positions, then try again.
                </span>
              <% end %>
            <% end %>
          </div>
          <%!-- The hook owns this text and it is announced, not laid out: its
          useful half is how many stops are placed, which the Placed fact already
          shows, and its other half is a negative that read as a fault when it sat
          in the row permanently. --%>
          <span id="map-alignment-preview-status" class="sr-only" aria-live="polite">
            Coordinate-change preview not ready
          </span>
        </div>

        <%= if @coordinate_review_status do %>
          <p
            id="coordinate-review-status"
            role="status"
            aria-live="polite"
            class="mt-4 text-xs text-base-content/70"
          >
            {@coordinate_review_status}
          </p>
        <% end %>

        <.confirm_dialog
          :if={@coordinate_review}
          id="coordinate-review-dialog"
          open={@coordinate_review != nil}
          title={"Update coordinates for #{review_stop_count(@review_change_count)}?"}
          confirm_label={"Update #{review_stop_count(@review_change_count)}"}
          pending_label="Updating…"
          on_confirm="apply_coordinate_review"
          on_cancel="cancel_coordinate_review"
          return_focus_id="map-alignment-apply"
          described_by="coordinate-review-consequence"
          size="lg"
          confirm_variant="primary"
        >
          <p id="coordinate-review-consequence" class="text-sm text-base-content/70">
            This saves the floorplan alignment and replaces latitude/longitude for the stops below.
            <%= for clause <- @review_consequence_clauses do %>
              <span class="ml-1">{clause}</span>
            <% end %>
          </p>
          <div class="mt-3 border border-warning/60 bg-warning/10 px-3 py-2 text-sm text-base-content">
            <strong class="font-medium">Recovery:</strong>
            this update cannot be reverted as one batch. Review the coordinate changes before applying.
          </div>
          <div
            :if={@coordinate_review_error}
            id="coordinate-review-error"
            role="alert"
            tabindex="-1"
            phx-mounted={JS.focus()}
            class="mt-3 border border-error/50 bg-error/10 px-3 py-2 text-sm text-error"
          >
            {@coordinate_review_error}
          </div>
          <div id="coordinate-review-table-scroller" class="mt-4 overflow-x-auto">
            <table id="coordinate-review-table" class="w-full text-sm border-collapse">
              <caption class="sr-only">
                Proposed coordinate changes for {review_stop_count(@review_change_count)}
              </caption>
              <thead>
                <tr class="border-b border-base-300 text-left text-xs text-base-content/60">
                  <th scope="col" class="py-2 pr-3 pl-1 font-medium">Stop</th>
                  <th scope="col" class="py-2 px-3 text-right font-medium">
                    Current coordinates
                  </th>
                  <th scope="col" class="py-2 px-3 text-right font-medium">
                    New coordinates
                  </th>
                  <th scope="col" class="py-2 pl-3 pr-1 text-right font-medium">Change</th>
                </tr>
              </thead>
              <tbody class="font-mono">
                <tr
                  :for={change <- @coordinate_review.changes}
                  id={"coordinate-review-row-#{change.stop_id}"}
                  class="border-b border-base-200"
                >
                  <td class="py-3 pr-3 pl-1 text-xs">
                    {change.stop_external_id || change.stop_id}
                  </td>
                  <td class="py-3 px-3 text-right text-xs tabular-nums">
                    {review_coordinate(change.current.lat)}, {review_coordinate(change.current.lon)}
                  </td>
                  <td class="py-3 px-3 text-right text-xs tabular-nums">
                    {review_coordinate(change.proposed.lat)}, {review_coordinate(change.proposed.lon)}
                  </td>
                  <td class="py-3 pl-3 pr-1 text-right text-xs tabular-nums">
                    {review_distance(change.distance_meters)}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </.confirm_dialog>
      </div>
    </div>
    """
  end

  defp invalid_floorplan_image_dims?(width, height),
    do: not (is_integer(width) and width > 0 and is_integer(height) and height > 0)

  # `#map-alignment-residual` reports the measured fit of whatever the operator
  # has placed. Every shape of the assign resolves to a rendered line, because a
  # blank readout or a bare `0` next to Save position reads as "the fit is
  # fine" — the exact misreading this element exists to prevent.
  #
  # 2.0 m is the same bar `AlignmentInference`'s `@max_rmse_meters` enforces on
  # an *inferred* fit, and 3 the same floor as its `anchor_minimum/0` and
  # `FloorplanTransform`'s `@fit_anchor_minimum`. Both are restated here rather
  # than imported: this module has no inference dependency and gains none.
  # `check_residual/1` rejects `rmse > 2.0`, so 2.0 exactly is within tolerance.
  @fit_tolerance_meters 2.0
  @fit_anchor_minimum 3

  # Two stacked lines: the label states the verdict, the value carries the
  # numbers. The band is therefore legible in monochrome — an out-of-tolerance
  # fit reads "Fit over 2.0 m" whether or not the warning colour lands — and
  # every state keeps the same two-line shape and width class, so the block
  # neither jitters nor grows the 44 px control row.
  #
  # `state` feeds `data-fit-state` and is only ever one of the three resolved
  # values. The hook overwrites it with "measuring" while a scoring round trip
  # is in flight, which the markup already styles, so the hook only has to set
  # the attribute and the value's text.
  # The fit reads as one labelled fact: a term, a number, and what the number was
  # measured over. Above tolerance it says what to do about it rather than only
  # that a threshold was crossed.
  defp residual_readout(%{status: :ready, rmse_meters: rmse, anchor_count: count})
       when is_number(rmse) and is_integer(count) do
    if rmse > @fit_tolerance_meters do
      %{
        state: "ready",
        value: "#{format_meters(rmse)} m",
        qualifier: "over #{anchor_count_phrase(count)} — check the alignment",
        value_class: "font-medium tabular-nums text-warning",
        qualifier_class: "text-warning/80"
      }
    else
      %{
        state: "ready",
        value: "#{format_meters(rmse)} m",
        qualifier: "over #{anchor_count_phrase(count)}",
        value_class: "font-medium tabular-nums text-base-content",
        qualifier_class: "text-base-content/50"
      }
    end
  end

  # With nothing measured, the value element carries the whole line, quietly. It
  # still renders, because it is what the hook overwrites while measuring.
  defp residual_readout(%{status: :insufficient_anchors}) do
    %{
      state: "insufficient",
      value: "needs #{@fit_anchor_minimum} anchor stops",
      qualifier: nil,
      value_class: "text-base-content/50",
      qualifier_class: nil
    }
  end

  # `nil` (nothing measured yet) and `:unavailable` (a round trip that could not
  # score) share one resting line: in both cases no measurement exists, and the
  # operator's next move is the same.
  defp residual_readout(_fit) do
    %{
      state: "unavailable",
      value: "move the floorplan to measure",
      qualifier: nil,
      value_class: "text-base-content/50",
      qualifier_class: nil
    }
  end

  defp format_meters(value), do: :erlang.float_to_binary(value * 1.0, decimals: 1)

  # The zero case carries no information, so it is not rendered.
  defp unplaced_note(0), do: nil
  defp unplaced_note(1), do: "1 unplaced stays as it is"
  defp unplaced_note(count), do: "#{count} unplaced stay as they are"

  defp anchor_count_phrase(1), do: "1 anchor"
  defp anchor_count_phrase(count), do: "#{count} anchors"

  defp map_controls_disabled_reason(:fatal, _width, _height),
    do: "Map service is unavailable. Retry the map before saving or previewing coordinates."

  defp map_controls_disabled_reason(_map_state, width, height) do
    if invalid_floorplan_image_dims?(width, height),
      do: "Floorplan image is not ready. Preview coordinates after it loads.",
      else: nil
  end

  defp auto_alignment_disabled_reason(:fatal, _width, _height),
    do: "Map service is unavailable. Retry the map before previewing auto-alignment."

  defp auto_alignment_disabled_reason(_map_state, width, height) do
    if invalid_floorplan_image_dims?(width, height),
      do: "Floorplan image is not ready. Preview auto-alignment after it loads.",
      else: nil
  end

  defp map_state_message(:initializing), do: "Loading map…"

  defp map_state_message(:imagery_unavailable),
    do: "Map imagery is unavailable. You can continue aligning the floorplan."

  defp map_state_message(:buildings_degraded),
    do: "Building outlines are unavailable. You can continue aligning the floorplan."

  defp map_state_message(:offline), do: "You are offline. The floorplan remains available."
  defp map_state_message(:reconnecting), do: "Reconnecting to the map…"
  defp map_state_message(:fatal), do: "Map service is unavailable. Retry to continue."
  defp map_state_message(_map_state), do: nil

  # Opposing nudges must undo each other, so every control emits the same fine
  # step and the coarse step (10 px / 5° / ×1.1, owned by `_adjustTransform`) is
  # reached with Shift rather than by a duplicate button (INV-09D-4). Each title
  # names the operation and both step sizes — the tooltip is the only place the
  # modifier is spelled out per control.
  defp transform_controls do
    [
      %{
        group: :move,
        action: "left",
        coarse: false,
        label: "←",
        title: "Move floorplan left · 2 px (Shift 10 px)"
      },
      %{
        group: :move,
        action: "up",
        coarse: false,
        label: "↑",
        title: "Move floorplan up · 2 px (Shift 10 px)"
      },
      %{
        group: :move,
        action: "down",
        coarse: false,
        label: "↓",
        title: "Move floorplan down · 2 px (Shift 10 px)"
      },
      %{
        group: :move,
        action: "right",
        coarse: false,
        label: "→",
        title: "Move floorplan right · 2 px (Shift 10 px)"
      },
      %{
        group: :rotate,
        action: "rotate-left",
        coarse: false,
        label: "↺",
        title: "Rotate floorplan left · 1° (Shift 5°)"
      },
      %{
        group: :rotate,
        action: "rotate-right",
        coarse: false,
        label: "↻",
        title: "Rotate floorplan right · 1° (Shift 5°)"
      },
      %{
        group: :scale,
        action: "scale-down",
        coarse: false,
        label: "−",
        title: "Shrink floorplan · 1% (Shift 10%)"
      },
      %{
        group: :scale,
        action: "scale-up",
        coarse: false,
        label: "+",
        title: "Grow floorplan · 1% (Shift 10%)"
      }
    ]
  end

  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :tone, :string, default: "neutral"
  attr :class, :string, default: nil
  slot :inner_block, required: true

  # One card per section on the help grid. The top rule is what makes the grid
  # legible: cards in different columns start on the same line whatever their
  # height, so the panel reads as a laid-out page rather than stacked boxes.
  defp help_section(assigns) do
    ~H"""
    <section class={["border-t-2 border-base-300 pt-4 first:border-t-0 first:pt-0", @class]}>
      <h3 class="flex items-center gap-3">
        <span class={[
          "flex size-9 shrink-0 items-center justify-center rounded-md",
          help_tone_chip(@tone)
        ]}>
          <.icon name={@icon} class="size-5" />
        </span>
        <span class="text-base font-semibold">{@title}</span>
      </h3>
      <div class="mt-3 text-sm text-base-content/80">
        {render_slot(@inner_block)}
      </div>
    </section>
    """
  end

  defp help_tone_chip("primary"), do: "bg-primary/12 text-primary"
  defp help_tone_chip("info"), do: "bg-info/12 text-info"
  defp help_tone_chip("success"), do: "bg-success/12 text-success"
  defp help_tone_chip("warning"), do: "bg-warning/12 text-warning"
  defp help_tone_chip(_), do: "bg-base-200 text-base-content/70"

  # The pad replica, tinted by operation so the diagram and the legend key each
  # other. Colour is the category here, not decoration; the legend repeats every
  # grouping in words so it never carries meaning alone.
  defp align_pad_diagram_cells do
    move = "bg-primary/12 text-primary"
    rotate = "bg-info/12 text-info"
    scale = "bg-secondary/12 text-secondary"

    [
      %{glyph: "↺", class: rotate},
      %{glyph: "↑", class: move},
      %{glyph: "↻", class: rotate},
      %{glyph: "←", class: move},
      %{glyph: "", class: "bg-base-100"},
      %{glyph: "→", class: move},
      %{glyph: "−", class: scale},
      %{glyph: "↓", class: move},
      %{glyph: "+", class: scale}
    ]
  end

  # The three quantities `FloorplanTransform` stores per level, named the way an
  # operator would rather than by column name. This is the concept the rest of
  # the panel refers back to, so it opens the help.
  defp align_records_rows do
    [
      %{
        icon: "hero-map-pin",
        term: "Center",
        description: "The latitude and longitude under the middle of the image."
      },
      %{
        icon: "hero-arrows-pointing-out",
        term: "Scale",
        description: "How many meters of ground one pixel of the image covers."
      },
      %{
        icon: "hero-arrow-path",
        term: "Rotation",
        description: "How far the image is turned from north."
      }
    ]
  end

  # The task, in the order an operator performs it. Auto-align first because it
  # is the only step that can do the whole job on its own.
  defp align_path_steps do
    [
      %{
        title: "Auto-align",
        description:
          "Fits the plan to this level's anchor stops, when there are at least three, " <>
            "and moves it immediately. Nothing is written until you save."
      },
      %{
        title: "Read the fit",
        description:
          "Fit reports how far the anchors land from their recorded coordinates. " <>
            "Under 2.0 m is a good alignment."
      },
      %{
        title: "Correct by hand",
        description:
          "Drag, nudge, rotate and resize until the plan's walls sit over the same " <>
            "walls in the imagery."
      },
      %{
        title: "Save",
        description:
          "Save position keeps the alignment. Update stop coordinates… also rewrites " <>
            "the child stops' coordinates, after you review every change."
      }
    ]
  end

  # One row per operation on the pad, carrying both step sizes. The plain and
  # Shift steps are stated per operation on purpose: Shift is 5× on rotate and
  # 10× on move and resize, so a single "ten times as far" line was wrong.
  defp align_transform_rows do
    [
      %{
        operation: "Move",
        keys: "← ↑ ↓ →",
        step: "2 px",
        shift_step: "10 px",
        tone_class: "text-primary"
      },
      %{
        operation: "Rotate",
        keys: "[ and ]",
        step: "1°",
        shift_step: "5°",
        tone_class: "text-info"
      },
      %{
        operation: "Resize",
        keys: "− and =",
        step: "1%",
        shift_step: "10%",
        tone_class: "text-secondary"
      }
    ]
  end

  # What the operator can do on the map without touching the tools panel.
  defp align_map_gesture_rows do
    [
      %{
        icon: "hero-hand-raised",
        term: "Drag the floorplan",
        description: "anywhere on it to move it."
      },
      %{
        icon: "hero-arrow-path",
        term: "Rotate handle",
        description: "sits top right of the map. Drag it to turn the plan."
      },
      %{
        icon: "hero-arrows-pointing-out",
        term: "Resize handle",
        description: "sits bottom right of the map. Drag it to grow or shrink the plan."
      }
    ]
  end

  # Grouped by what they achieve, not by where they sit: every one of these
  # trades a view of the floorplan for a view of what is under it.
  defp align_visibility_rows do
    [
      %{
        key: "H",
        term: "Hold H",
        description: "blanks the floorplan for as long as you hold it."
      },
      %{
        icon: "hero-photo",
        term: "Floorplan opacity",
        description: "fades the plan so the imagery shows through it."
      },
      %{
        icon: "hero-square-3-stack-3d",
        term: "Other-levels opacity",
        description: "fades the guide levels, when any are shown."
      },
      %{
        icon: "hero-chevron-up",
        term: "Hide tools",
        description: "collapses the tools panel when it covers something you need."
      }
    ]
  end

  # The two things the Other levels menu can draw, and what each is good for.
  defp align_guide_rows do
    [
      %{
        icon: "hero-photo",
        term: "Floorplan",
        description:
          "draws that level's plan under yours. Line up the walls, shafts and " <>
            "platform edges the two levels share."
      },
      %{
        icon: "hero-map-pin",
        term: "Stops",
        description:
          "drops that level's stops as colored pins at their real coordinates. An " <>
            "elevator serving both levels should land on its own pin."
      }
    ]
  end

  # The four states the Fit readout renders, each paired with what to do about
  # it. The readings are the strings `residual_readout/1` writes.
  defp align_fit_rows do
    [
      %{
        reading: "Under 2.0 m",
        meaning: "A good alignment. Save it.",
        tone_class: "text-base-content"
      },
      %{
        reading: "Over 2.0 m",
        meaning:
          "Flagged, with check the alignment beside it. Usually one anchor is misplaced " <>
            "rather than the whole plan.",
        tone_class: "text-warning"
      },
      %{
        reading: "needs 3 anchor stops",
        meaning: "Too few anchors on this level to score anything.",
        tone_class: "text-base-content/60"
      },
      %{
        reading: "move the floorplan to measure",
        meaning: "Nothing measured yet. Nudge the plan once and it scores.",
        tone_class: "text-base-content/60"
      }
    ]
  end

  # The three controls that change what is stored, kept in one place so the two
  # writes are read against each other rather than found separately.
  defp align_save_rows do
    [
      %{
        term: "Save position",
        description: "Stores where the floorplan sits on the map. Child stops are untouched."
      },
      %{
        term: "Update stop coordinates…",
        description:
          "Also writes each child stop's latitude and longitude from its position on " <>
            "the floorplan. Every change is listed for review before any of it is written."
      },
      %{
        term: "Restore saved alignment",
        description:
          "The circular arrow in the tools panel. Puts the plan back where it was last " <>
            "saved and discards every change since."
      }
    ]
  end

  # The three refusals, phrased as the operator's next move rather than as the
  # server's reason code.
  defp align_blocked_rows do
    [
      %{
        term: "Fewer than three anchors",
        description:
          "Give more child stops map coordinates, or place more of them on the floorplan, " <>
            "then try again."
      },
      %{
        term: "Cannot get within 2.0 m",
        description:
          "One wrong anchor drags the whole solve. Check each anchor's floorplan position " <>
            "and its coordinates."
      },
      %{
        term: "Floorplan or map not ready",
        description:
          "The image has not loaded, or the map service is down. Imagery is optional: you " <>
            "can still align against another level."
      }
    ]
  end

  defp transform_control(action) do
    Enum.find(transform_controls(), &(&1.action == action))
  end

  attr :control, :map, required: true
  attr :class, :string, default: nil

  defp transform_button(assigns) do
    ~H"""
    <button
      id={"map-transform-#{@control.action}-#{if @control.coarse, do: "coarse", else: "fine"}"}
      type="button"
      class={
        [
          "tooltip tooltip-right",
          "btn btn-ghost h-11 w-11 min-h-11 min-w-11 rounded-none p-0 text-base",
          "bg-base-100 hover:bg-base-200",
          # The pad clips its corners, which would clip an outward focus ring on
          # every edge cell. Draw it inside the cell so it stays whole.
          "focus-visible:outline-offset-[-2px]",
          @class
        ]
      }
      data-map-transform-action={@control.action}
      data-map-transform-coarse={to_string(@control.coarse)}
      data-tip={@control.title}
      aria-label={@control.title}
    >
      {@control.label}
    </button>
    """
  end

  # Derive the post-review projection counts and consequence clauses from the
  # stored review so the dialog title, confirm button, consequence, and table
  # all read from one projection (INV-7, DC-4). Pre-review placement vocabulary
  # (placed/total/unplaced) is derived from the normalizable floorplan count.
  defp assign_review_projection(assigns) do
    review = assigns.coordinate_review

    {change_count, unchanged_count, unplaced_count, consequence_clauses} =
      case review do
        %{changes: changes, unchanged_count: unchanged, unplaced_count: unplaced} ->
          {length(changes), unchanged, unplaced,
           review_consequence_clauses(length(changes), unchanged, unplaced)}

        _ ->
          {0, 0, 0, []}
      end

    child_stops_unplaced = max(assigns.child_stops_total - assigns.child_stops_with_floorplan, 0)

    assigns
    |> assign(:review_change_count, change_count)
    |> assign(:review_unchanged_count, unchanged_count)
    |> assign(:review_unplaced_count, unplaced_count)
    |> assign(:review_consequence_clauses, consequence_clauses)
    |> assign(:child_stops_unplaced, child_stops_unplaced)
  end

  # Build the post-review consequence clauses, omitting any zero-count group so
  # the consequence never lists "0 already match" (DC-4).
  defp review_consequence_clauses(changed, unchanged, unplaced) do
    []
    |> append_if(changed > 0, review_changed_clause(changed))
    |> append_if(unchanged > 0, review_unchanged_clause(unchanged))
    |> append_if(unplaced > 0, review_unplaced_clause(unplaced))
  end

  defp review_stop_count(1), do: "1 stop"
  defp review_stop_count(count), do: "#{count} stops"

  defp review_changed_clause(count),
    do: "#{review_stop_count(count)} will receive new coordinates."

  defp review_unchanged_clause(1), do: "1 stop already matches."
  defp review_unchanged_clause(count), do: "#{count} stops already match."

  defp review_unplaced_clause(1), do: "1 stop without placement stays unchanged."
  defp review_unplaced_clause(count), do: "#{count} stops without placement stay unchanged."

  defp append_if(list, true, clause), do: list ++ [clause]
  defp append_if(list, false, _clause), do: list

  # Six-decimal display for both stored Decimal and derived float coordinates.
  # Changed-versus-unchanged remains Package 06's domain comparison and is never
  # inferred from these formatted strings (DC-8).
  defp review_coordinate(nil), do: "—"

  defp review_coordinate(%Decimal{} = value) do
    format_review_decimal(value)
  end

  defp review_coordinate(value) when is_number(value) do
    format_review_float(value * 1.0)
  end

  defp review_distance(nil), do: "New"

  defp review_distance(value) when is_number(value) do
    format_review_float(value * 1.0, 1)
  end

  defp format_review_decimal(%Decimal{} = value) do
    value
    |> Decimal.to_float()
    |> format_review_float()
  end

  defp format_review_float(value, decimals \\ 6) do
    :erlang.float_to_binary(value * 1.0, decimals: decimals)
  end

  # ============================================================================
  # Diagram Canvas
  # ============================================================================

  attr :station, :any, required: true
  attr :active_level, :any, required: true
  attr :active_stop_level, :any, default: nil
  attr :streams, :any, required: true
  attr :active_point_id, :any
  attr :pending_xy, :any
  attr :selected_stop_id, :any
  attr :selected_from_stop, :any, default: nil
  attr :mode, :atom, required: true
  attr :cross_level_badges_by_stop, :map, default: %{}
  attr :organization_id, :string, required: true
  attr :gtfs_version_id, :string, required: true
  attr :ruler_point_a, :any, default: nil
  attr :ruler_point_b, :any, default: nil
  attr :scale_point_a, :any, default: nil
  attr :scale_point_b, :any, default: nil
  attr :measurement_enabled, :boolean, default: false
  attr :has_diagram, :boolean, default: false
  attr :upload, :any, default: nil
  attr :upload_phase, :atom, default: :idle
  attr :point_count, :integer, default: 0

  def diagram_canvas(assigns) do
    canvas_key = diagram_canvas_key(assigns.active_level, assigns.active_stop_level)

    image_href =
      diagram_image_href(
        assigns.organization_id,
        assigns.gtfs_version_id,
        assigns.station,
        assigns.active_stop_level
      )

    assigns =
      assigns
      |> assign(:canvas_key, canvas_key)
      |> assign(:image_href, image_href)

    ~H"""
    <div id="plan-wrap" class="relative size-full overflow-hidden bg-canvas">
      <%= cond do %>
        <% @active_stop_level && @active_stop_level.diagram_filename -> %>
          <svg
            id={"diagram-canvas-#{@canvas_key}"}
            phx-hook="DiagramCanvas"
            data-canvas-key={@canvas_key}
            viewBox="0 0 100 100"
            preserveAspectRatio="xMidYMid meet"
            class={[
              "absolute inset-0 block size-full",
              if(@mode == :view, do: "cursor-default", else: "cursor-crosshair")
            ]}
          >
            <image
              href={@image_href}
              x="0"
              y="0"
              width="100"
              height="100"
              preserveAspectRatio="xMidYMid meet"
            />
          </svg>
          <.diagram_overlay
            streams={@streams}
            active_point_id={@active_point_id}
            pending_xy={@pending_xy}
            selected_stop_id={@selected_stop_id}
            mode={@mode}
            cross_level_badges_by_stop={@cross_level_badges_by_stop}
            ruler_point_a={@ruler_point_a}
            ruler_point_b={@ruler_point_b}
            scale_point_a={@scale_point_a}
            scale_point_b={@scale_point_b}
            measurement_enabled={@measurement_enabled}
          />
          <div
            id="diagram-edit-tooltip"
            class="diagram-edit-tooltip is-hidden"
            role="tooltip"
            aria-hidden="true"
          >
          </div>
          <.plan_hint
            mode={@mode}
            selected_from_stop={@selected_from_stop}
            measurement_enabled={@measurement_enabled}
            ruler_point_a={@ruler_point_a}
            ruler_point_b={@ruler_point_b}
          />
          <.plan_controls />
        <% @active_level -> %>
          <.empty_diagram_state
            has_diagram={@has_diagram}
            upload={@upload}
            upload_phase={@upload_phase}
            level_name={@active_level.level_name || @active_level.level_id}
            point_count={@point_count}
          />
        <% true -> %>
          <.no_level_state />
      <% end %>
    </div>
    """
  end

  defp diagram_canvas_key(active_level, active_stop_level) do
    level_part = if active_level, do: to_string(active_level.id), else: "no-level"

    file_part =
      if active_stop_level, do: active_stop_level.diagram_filename || "no-file", else: "no-file"

    safe_level = String.replace(level_part, ~r/[^A-Za-z0-9_-]/, "_")
    safe_file = String.replace(file_part, ~r/[^A-Za-z0-9_.-]/, "_")
    "#{safe_level}-#{safe_file}"
  end

  # Renders the versioned diagram URL for the editor. The version id is part of the
  # public path shape (`/uploads/diagrams/<org>/<version>/<station>/<file>`), and
  # `UploadsPlug` gates delivery by the version's database publication status. This
  # keeps the relative path plus `?v=` cache-buster the editor relies on rather than
  # the disk-checked absolute resolver, so a freshly persisted filename renders
  # immediately.
  defp diagram_image_href(organization_id, gtfs_version_id, station, active_stop_level) do
    case active_stop_level do
      %{diagram_filename: filename} when is_binary(filename) ->
        station_dir = PathSafety.stop_storage_dir(station.stop_id)
        token = URI.encode_www_form(filename)
        encoded_filename = URI.encode(filename)

        if is_binary(station_dir) and is_binary(gtfs_version_id) do
          "/uploads/diagrams/#{organization_id}/#{gtfs_version_id}/#{station_dir}/#{encoded_filename}?v=#{token}"
        else
          nil
        end

      _ ->
        nil
    end
  end

  attr :streams, :any, required: true
  attr :active_point_id, :any
  attr :pending_xy, :any
  attr :selected_stop_id, :any
  attr :mode, :atom, required: true
  attr :cross_level_badges_by_stop, :map, default: %{}
  attr :ruler_point_a, :any, default: nil
  attr :ruler_point_b, :any, default: nil
  attr :scale_point_a, :any, default: nil
  attr :scale_point_b, :any, default: nil
  attr :measurement_enabled, :boolean, default: false

  defp diagram_overlay(assigns) do
    ~H"""
    <svg
      id="diagram-overlay"
      data-mode={@mode}
      data-measurement-enabled={if @measurement_enabled, do: "true", else: "false"}
      class="absolute inset-0 w-full h-full pointer-events-none"
      viewBox="0 0 100 100"
      preserveAspectRatio="xMidYMid meet"
    >
      <defs>
        <marker
          id="pathway-arrow"
          viewBox="0 0 6 6"
          refX="6"
          refY="3"
          markerWidth="1.5"
          markerHeight="1.5"
          orient="auto-start-reverse"
          markerUnits="userSpaceOnUse"
        >
          <path
            d="M 0 0 L 6 3 L 0 6 z"
            fill="#FF00FF"
            stroke="#FF00FF"
            stroke-width="0.35"
            stroke-linejoin="round"
          />
        </marker>
      </defs>

      <.pathways_layer streams={@streams} mode={@mode} />
      <.ruler_line
        :if={@measurement_enabled and @ruler_point_a}
        point_a={@ruler_point_a}
        point_b={@ruler_point_b}
        style={:draft}
      />
      <.stops_layer
        streams={@streams}
        active_point_id={@active_point_id}
        mode={@mode}
        measurement_enabled={@measurement_enabled}
        cross_level_badges_by_stop={@cross_level_badges_by_stop}
      />
      <.journal_markers_layer streams={@streams} mode={@mode} />
      <.ruler_line
        :if={(@mode == :view and @scale_point_a) && @scale_point_b}
        point_a={@scale_point_a}
        point_b={@scale_point_b}
        style={:saved}
      />
      <.pending_marker
        :if={@pending_xy && is_number(@pending_xy.x) && @mode == :add && @selected_stop_id == nil}
        pending_xy={@pending_xy}
      />
    </svg>
    """
  end

  attr :streams, :any, required: true
  attr :mode, :atom, required: true

  def journal_markers_layer(assigns) do
    ~H"""
    <g id="journal-markers-svg" phx-update="stream">
      <g
        :for={{dom_id, marker} <- @streams.journal_markers}
        id={dom_id}
        data-journal-marker="true"
        data-journal-kind={marker.kind}
        data-journal-target-id={marker.target_id}
        data-center-x={marker.x}
        data-center-y={marker.y}
        class={[
          "journal-marker-group",
          if(@mode == :view,
            do: "pointer-events-auto cursor-pointer focus:outline-none",
            else: "pointer-events-none"
          )
        ]}
        tabindex={if @mode == :view, do: "0"}
        role={if @mode == :view, do: "button"}
        aria-label={marker.accessible_name}
        phx-click={if @mode == :view, do: "journal_marker_clicked"}
        phx-value-id={if @mode == :view, do: marker.id}
      >
        <title>{marker.accessible_name}</title>

        <%= case marker.kind do %>
          <% :pin -> %>
            <g
              data-journal-pin="true"
              data-center-x={marker.x}
              data-center-y={marker.y}
              transform={"translate(#{marker.x}, #{marker.y})"}
            >
              <path
                data-journal-pin-body="true"
                d="M 0 0 C -0.4 -0.56 -0.72 -0.88 -0.72 -1.28 A 0.72 0.72 0 1 1 0.72 -1.28 C 0.72 -0.88 0.4 -0.56 0 0 Z"
                stroke-width="0.12"
              />
              <circle
                data-journal-pin-head="true"
                cx="0"
                cy="-1.28"
                r="0.24"
              />
            </g>
          <% _node_or_pathway -> %>
            <circle
              data-journal-dot="true"
              data-center-x={marker.x}
              data-center-y={marker.y}
              cx={marker.x}
              cy={marker.y}
              r="0.6"
              stroke-width="0.12"
            />
        <% end %>

        <circle
          :if={marker.focused?}
          data-journal-ring="true"
          data-center-x={marker.x}
          data-center-y={marker.y}
          cx={marker.x}
          cy={marker.y}
          r="1.32"
          stroke-width="0.12"
          stroke-dasharray="0.4 0.3"
        />

        <rect
          data-journal-hit-target="true"
          data-journal-kind={marker.kind}
          data-center-x={marker.x}
          data-center-y={marker.y}
          x={marker.x - 1.75}
          y={if marker.kind == :pin, do: marker.y - 2.625, else: marker.y - 1.75}
          width="3.5"
          height="3.5"
          fill="transparent"
        />
      </g>
    </g>
    """
  end

  attr :streams, :any, required: true
  attr :mode, :atom, required: true

  defp pathways_layer(assigns) do
    ~H"""
    <g id="pathways-svg" phx-update="stream">
      <%= for {dom_id, pathway} <- @streams.pathways do %>
        <%= if pathway.from_stop.diagram_coordinate && pathway.to_stop.diagram_coordinate do %>
          <.pathway_element id={dom_id} pathway={pathway} mode={@mode} />
        <% end %>
      <% end %>
    </g>
    """
  end

  attr :id, :string, required: true
  attr :pathway, :any, required: true
  attr :mode, :atom, required: true

  defp pathway_element(assigns) do
    from_coordinate = assigns.pathway.from_stop.diagram_coordinate
    to_coordinate = assigns.pathway.to_stop.diagram_coordinate

    x1 = from_coordinate["x"]
    y1 = from_coordinate["y"]
    x2 = to_coordinate["x"]
    y2 = to_coordinate["y"]
    {line_x1, line_y1, line_x2, line_y2} = parallel_offset(x1, y1, x2, y2, 0.0)

    one_way? = assigns.pathway.is_bidirectional != true

    forward_label_text =
      Map.get(assigns.pathway, :display_signposted_as, assigns.pathway.signposted_as)

    reverse_label_text =
      Map.get(
        assigns.pathway,
        :display_reversed_signposted_as,
        assigns.pathway.reversed_signposted_as
      )

    has_forward_label? = present_text?(forward_label_text)

    has_reverse_label? =
      assigns.pathway.is_bidirectional == true and present_text?(reverse_label_text)

    assigns =
      assigns
      |> assign(:x1, line_x1)
      |> assign(:y1, line_y1)
      |> assign(:x2, line_x2)
      |> assign(:y2, line_y2)
      |> assign(:one_way?, one_way?)
      |> assign(:stroke_mult, if(Map.get(assigns.pathway, :is_paired), do: 1.8, else: 1.0))
      |> assign(:opacity, "1")
      |> assign(:forward_label_text, forward_label_text)
      |> assign(:reverse_label_text, reverse_label_text)
      |> assign(:has_forward_label?, has_forward_label?)
      |> assign(:has_reverse_label?, has_reverse_label?)
      |> assign(:editable?, assigns.mode == :view)

    ~H"""
    <g
      id={@id}
      opacity={@opacity}
      class="group cursor-pointer pointer-events-auto"
      data-from-stop-id={@pathway.from_stop.id}
      data-to-stop-id={@pathway.to_stop.id}
      data-editable={if @editable?, do: "pathway"}
      data-tooltip={if @editable?, do: "Click to edit pathway"}
      data-tooltip-color={if @editable?, do: "#FF00FF"}
      tabindex={if @editable?, do: "0"}
      role={if @editable?, do: "button"}
      aria-label={if @editable?, do: pathway_aria_label(@pathway)}
      phx-click={if @editable?, do: "edit_pathway"}
      phx-value-id={if @editable?, do: @pathway.id}
    >
      <line
        x1={@x1}
        y1={@y1}
        x2={@x2}
        y2={@y2}
        stroke="transparent"
        stroke-width="2"
        data-pathway-hit="true"
        data-base-stroke="14"
      />
      <line
        :if={@editable?}
        x1={@x1}
        y1={@y1}
        x2={@x2}
        y2={@y2}
        stroke="transparent"
        stroke-width="0.8"
        data-pathway-tooltip-hit="true"
        data-tooltip-trigger="true"
        data-base-stroke="6"
      />

      <%= case @pathway.pathway_mode do %>
        <% 1 -> %>
          <.pathway_walkway
            x1={@x1}
            y1={@y1}
            x2={@x2}
            y2={@y2}
            mode={@mode}
            one_way?={@one_way?}
            stroke_mult={@stroke_mult}
          />
        <% 2 -> %>
          <.pathway_stairs
            x1={@x1}
            y1={@y1}
            x2={@x2}
            y2={@y2}
            mode={@mode}
            one_way?={@one_way?}
            stroke_mult={@stroke_mult}
          />
        <% 3 -> %>
          <.pathway_moving_sidewalk
            x1={@x1}
            y1={@y1}
            x2={@x2}
            y2={@y2}
            mode={@mode}
            one_way?={@one_way?}
            stroke_mult={@stroke_mult}
          />
        <% 4 -> %>
          <.pathway_escalator
            x1={@x1}
            y1={@y1}
            x2={@x2}
            y2={@y2}
            mode={@mode}
            one_way?={@one_way?}
            stroke_mult={@stroke_mult}
          />
        <% 5 -> %>
          <.pathway_elevator
            x1={@x1}
            y1={@y1}
            x2={@x2}
            y2={@y2}
            one_way?={@one_way?}
            stroke_mult={@stroke_mult}
          />
        <% 6 -> %>
          <.pathway_fare_gate
            x1={@x1}
            y1={@y1}
            x2={@x2}
            y2={@y2}
            mode={@mode}
            one_way?={@one_way?}
            stroke_mult={@stroke_mult}
          />
        <% 7 -> %>
          <.pathway_exit_gate
            x1={@x1}
            y1={@y1}
            x2={@x2}
            y2={@y2}
            mode={@mode}
            one_way?={@one_way?}
            stroke_mult={@stroke_mult}
          />
        <% _ -> %>
          <.pathway_walkway
            x1={@x1}
            y1={@y1}
            x2={@x2}
            y2={@y2}
            mode={@mode}
            one_way?={@one_way?}
            stroke_mult={@stroke_mult}
          />
      <% end %>

      <.pathway_label
        :if={@has_forward_label?}
        x1={@x1}
        y1={@y1}
        x2={@x2}
        y2={@y2}
        text={@forward_label_text}
        side={:forward}
      />
      <.pathway_label
        :if={@has_reverse_label?}
        x1={@x1}
        y1={@y1}
        x2={@x2}
        y2={@y2}
        text={@reverse_label_text}
        side={:reverse}
      />
    </g>
    """
  end

  attr :x1, :float, required: true
  attr :y1, :float, required: true
  attr :x2, :float, required: true
  attr :y2, :float, required: true
  attr :mode, :atom, required: true
  attr :one_way?, :boolean, required: true
  attr :stroke_mult, :float, default: 1.0

  defp pathway_walkway(assigns) do
    ~H"""
    <line
      x1={@x1}
      y1={@y1}
      x2={@x2}
      y2={@y2}
      stroke="#FF00FF"
      stroke-width="0.30"
      stroke-linecap="butt"
      marker-start={if @one_way?, do: nil, else: "url(#pathway-arrow)"}
      marker-end="url(#pathway-arrow)"
      data-pathway-line="true"
      data-pathway-end-trim="10"
      data-base-stroke={2.5 * @stroke_mult}
      class={
        if(@mode == :add,
          do: "",
          else: "pointer-events-none transition-colors group-hover:stroke-[#FF4500]"
        )
      }
    />
    """
  end

  attr :x1, :float, required: true
  attr :y1, :float, required: true
  attr :x2, :float, required: true
  attr :y2, :float, required: true
  attr :mode, :atom, required: true
  attr :one_way?, :boolean, required: true
  attr :stroke_mult, :float, default: 1.0

  defp pathway_stairs(assigns) do
    assigns =
      assign(
        assigns,
        :ticks,
        glyph_bars(assigns.x1, assigns.y1, assigns.x2, assigns.y2, 1)
      )

    ~H"""
    <line
      x1={@x1}
      y1={@y1}
      x2={@x2}
      y2={@y2}
      stroke="#FF00FF"
      stroke-width="0.30"
      stroke-linecap="butt"
      marker-start={if @one_way?, do: nil, else: "url(#pathway-arrow)"}
      marker-end="url(#pathway-arrow)"
      data-pathway-line="true"
      data-pathway-end-trim="10"
      data-base-stroke={2.5 * @stroke_mult}
      class={
        if(@mode == :add,
          do: "",
          else: "pointer-events-none transition-colors group-hover:stroke-[#FF4500]"
        )
      }
    />
    <line
      :for={tick <- @ticks}
      x1={tick.mid_x}
      y1={tick.mid_y}
      x2={tick.mid_x}
      y2={tick.mid_y}
      data-glyph-mid-x={tick.mid_x}
      data-glyph-mid-y={tick.mid_y}
      data-glyph-dir-x={tick.dir_x}
      data-glyph-dir-y={tick.dir_y}
      data-glyph-along={tick.along}
      data-glyph-half-along={tick.half_along}
      data-glyph-half-perp={tick.half_perp}
      stroke="#FF00FF"
      stroke-width="0.26"
      stroke-linecap="round"
      data-pathway-center-tick="true"
      data-base-stroke={2 * @stroke_mult}
      class="pointer-events-none transition-colors group-hover:stroke-[#FF4500]"
    />
    """
  end

  attr :x1, :float, required: true
  attr :y1, :float, required: true
  attr :x2, :float, required: true
  attr :y2, :float, required: true
  attr :mode, :atom, required: true
  attr :one_way?, :boolean, required: true
  attr :stroke_mult, :float, default: 1.0

  defp pathway_moving_sidewalk(assigns) do
    assigns =
      assign(
        assigns,
        :cross_segments,
        glyph_cross(assigns.x1, assigns.y1, assigns.x2, assigns.y2)
      )

    ~H"""
    <line
      x1={@x1}
      y1={@y1}
      x2={@x2}
      y2={@y2}
      stroke="#FF00FF"
      stroke-width="0.30"
      stroke-linecap="butt"
      marker-start={if @one_way?, do: nil, else: "url(#pathway-arrow)"}
      marker-end="url(#pathway-arrow)"
      data-pathway-line="true"
      data-pathway-end-trim="10"
      data-base-stroke={2.5 * @stroke_mult}
      class={
        if(@mode == :add,
          do: "",
          else: "pointer-events-none transition-colors group-hover:stroke-[#FF4500]"
        )
      }
    />
    <line
      :for={segment <- @cross_segments}
      x1={segment.mid_x}
      y1={segment.mid_y}
      x2={segment.mid_x}
      y2={segment.mid_y}
      data-glyph-mid-x={segment.mid_x}
      data-glyph-mid-y={segment.mid_y}
      data-glyph-dir-x={segment.dir_x}
      data-glyph-dir-y={segment.dir_y}
      data-glyph-along={segment.along}
      data-glyph-half-along={segment.half_along}
      data-glyph-half-perp={segment.half_perp}
      stroke="#FF00FF"
      stroke-width="0.26"
      stroke-linecap="round"
      data-pathway-center-cross="true"
      data-base-stroke={2 * @stroke_mult}
      class="pointer-events-none transition-colors group-hover:stroke-[#FF4500]"
    />
    """
  end

  attr :x1, :float, required: true
  attr :y1, :float, required: true
  attr :x2, :float, required: true
  attr :y2, :float, required: true
  attr :mode, :atom, required: true
  attr :one_way?, :boolean, required: true
  attr :stroke_mult, :float, default: 1.0

  defp pathway_escalator(assigns) do
    assigns =
      assign(
        assigns,
        :ticks,
        glyph_bars(assigns.x1, assigns.y1, assigns.x2, assigns.y2, 3)
      )

    ~H"""
    <line
      x1={@x1}
      y1={@y1}
      x2={@x2}
      y2={@y2}
      stroke="#FF00FF"
      stroke-width="0.30"
      stroke-linecap="butt"
      marker-start={if @one_way?, do: nil, else: "url(#pathway-arrow)"}
      marker-end="url(#pathway-arrow)"
      data-pathway-line="true"
      data-pathway-end-trim="10"
      data-base-stroke={2.5 * @stroke_mult}
      class={
        if(@mode == :add,
          do: "",
          else: "pointer-events-none transition-colors group-hover:stroke-[#FF4500]"
        )
      }
    />
    <line
      :for={tick <- @ticks}
      x1={tick.mid_x}
      y1={tick.mid_y}
      x2={tick.mid_x}
      y2={tick.mid_y}
      data-glyph-mid-x={tick.mid_x}
      data-glyph-mid-y={tick.mid_y}
      data-glyph-dir-x={tick.dir_x}
      data-glyph-dir-y={tick.dir_y}
      data-glyph-along={tick.along}
      data-glyph-half-along={tick.half_along}
      data-glyph-half-perp={tick.half_perp}
      stroke="#FF00FF"
      stroke-width="0.26"
      stroke-linecap="round"
      data-pathway-center-bar="true"
      data-base-stroke={2 * @stroke_mult}
      class="pointer-events-none transition-colors group-hover:stroke-[#FF4500]"
    />
    """
  end

  attr :x1, :float, required: true
  attr :y1, :float, required: true
  attr :x2, :float, required: true
  attr :y2, :float, required: true
  attr :one_way?, :boolean, required: true
  attr :stroke_mult, :float, default: 1.0

  defp pathway_elevator(assigns) do
    {mid_x, mid_y} = pathway_midpoint(assigns.x1, assigns.y1, assigns.x2, assigns.y2)

    assigns =
      assigns
      |> assign(:mid_x, mid_x)
      |> assign(:mid_y, mid_y)

    ~H"""
    <line
      x1={@x1}
      y1={@y1}
      x2={@mid_x}
      y2={@mid_y}
      stroke="#FF00FF"
      stroke-width="0.26"
      stroke-linecap="butt"
      marker-start={if @one_way?, do: nil, else: "url(#pathway-arrow)"}
      data-pathway-connector="true"
      data-pathway-end-trim-start="10"
      data-pathway-end-trim-end="12"
      data-base-stroke={2 * @stroke_mult}
      class="pointer-events-none transition-colors group-hover:stroke-[#FF4500]"
    />
    <line
      x1={@mid_x}
      y1={@mid_y}
      x2={@x2}
      y2={@y2}
      stroke="#FF00FF"
      stroke-width="0.26"
      stroke-linecap="butt"
      marker-end="url(#pathway-arrow)"
      data-pathway-connector="true"
      data-pathway-end-trim-start="12"
      data-pathway-end-trim-end="10"
      data-base-stroke={2 * @stroke_mult}
      class="pointer-events-none transition-colors group-hover:stroke-[#FF4500]"
    />
    <rect
      x={@mid_x}
      y={@mid_y}
      width="0"
      height="0"
      fill="#FFFFFF"
      stroke="#FF00FF"
      stroke-width="0.30"
      data-pathway-elevator-box="true"
      data-center-x={@mid_x}
      data-center-y={@mid_y}
      data-base-width="16"
      data-base-height="16"
      data-base-stroke={2.5 * @stroke_mult}
      class="pointer-events-none transition-colors group-hover:stroke-[#FF4500]"
    />
    <text
      x={@mid_x}
      y={@mid_y}
      fill="#FF00FF"
      font-size="0.275"
      text-anchor="middle"
      dominant-baseline="central"
      data-pathway-elevator-text="true"
      data-center-x={@mid_x}
      data-center-y={@mid_y}
      data-base-font-size="11"
      class="pointer-events-none select-none transition-colors group-hover:fill-[#FF4500]"
    >
      ↕
    </text>
    """
  end

  attr :x1, :float, required: true
  attr :y1, :float, required: true
  attr :x2, :float, required: true
  attr :y2, :float, required: true
  attr :mode, :atom, required: true
  attr :one_way?, :boolean, required: true
  attr :stroke_mult, :float, default: 1.0

  defp pathway_fare_gate(assigns) do
    {rail_a_x1, rail_a_y1, rail_a_x2, rail_a_y2} =
      parallel_offset(assigns.x1, assigns.y1, assigns.x2, assigns.y2, 0.28)

    {rail_b_x1, rail_b_y1, rail_b_x2, rail_b_y2} =
      parallel_offset(assigns.x1, assigns.y1, assigns.x2, assigns.y2, -0.28)

    assigns =
      assigns
      |> assign(:rail_a_x1, rail_a_x1)
      |> assign(:rail_a_y1, rail_a_y1)
      |> assign(:rail_a_x2, rail_a_x2)
      |> assign(:rail_a_y2, rail_a_y2)
      |> assign(:rail_b_x1, rail_b_x1)
      |> assign(:rail_b_y1, rail_b_y1)
      |> assign(:rail_b_x2, rail_b_x2)
      |> assign(:rail_b_y2, rail_b_y2)

    ~H"""
    <line
      x1={@rail_a_x1}
      y1={@rail_a_y1}
      x2={@rail_a_x2}
      y2={@rail_a_y2}
      stroke="#FF00FF"
      stroke-width="0.30"
      stroke-linecap="round"
      data-pathway-rail="true"
      data-rail-base-offset="3.5"
      data-base-stroke={2.5 * @stroke_mult}
      class={
        if(@mode == :add,
          do: "",
          else: "pointer-events-none transition-colors group-hover:stroke-[#FF4500]"
        )
      }
    />
    <line
      x1={@rail_b_x1}
      y1={@rail_b_y1}
      x2={@rail_b_x2}
      y2={@rail_b_y2}
      stroke="#FF00FF"
      stroke-width="0.30"
      stroke-linecap="round"
      data-pathway-rail="true"
      data-rail-base-offset="-3.5"
      data-base-stroke={2.5 * @stroke_mult}
      class={
        if(@mode == :add,
          do: "",
          else: "pointer-events-none transition-colors group-hover:stroke-[#FF4500]"
        )
      }
    />
    <line
      x1={@x1}
      y1={@y1}
      x2={@x2}
      y2={@y2}
      stroke="transparent"
      stroke-width="0.30"
      stroke-linecap="butt"
      marker-start={if @one_way?, do: nil, else: "url(#pathway-arrow)"}
      marker-end="url(#pathway-arrow)"
      data-pathway-arrow-guide="true"
      data-pathway-end-trim="10"
      data-base-stroke={2.5 * @stroke_mult}
      class="pointer-events-none"
    />
    """
  end

  attr :x1, :float, required: true
  attr :y1, :float, required: true
  attr :x2, :float, required: true
  attr :y2, :float, required: true
  attr :mode, :atom, required: true
  attr :one_way?, :boolean, required: true
  attr :stroke_mult, :float, default: 1.0

  defp pathway_exit_gate(assigns) do
    {rail_a_x1, rail_a_y1, rail_a_x2, rail_a_y2} =
      parallel_offset(assigns.x1, assigns.y1, assigns.x2, assigns.y2, 0.16)

    {rail_b_x1, rail_b_y1, rail_b_x2, rail_b_y2} =
      parallel_offset(assigns.x1, assigns.y1, assigns.x2, assigns.y2, -0.16)

    assigns =
      assigns
      |> assign(:rail_a_x1, rail_a_x1)
      |> assign(:rail_a_y1, rail_a_y1)
      |> assign(:rail_a_x2, rail_a_x2)
      |> assign(:rail_a_y2, rail_a_y2)
      |> assign(:rail_b_x1, rail_b_x1)
      |> assign(:rail_b_y1, rail_b_y1)
      |> assign(:rail_b_x2, rail_b_x2)
      |> assign(:rail_b_y2, rail_b_y2)

    ~H"""
    <line
      x1={@rail_a_x1}
      y1={@rail_a_y1}
      x2={@rail_a_x2}
      y2={@rail_a_y2}
      stroke="#FF00FF"
      stroke-width="0.30"
      stroke-linecap="round"
      data-pathway-rail="true"
      data-rail-base-offset="2.5"
      data-base-stroke={2.5 * @stroke_mult}
      class={
        if(@mode == :add,
          do: "",
          else: "pointer-events-none transition-colors group-hover:stroke-[#FF4500]"
        )
      }
    />
    <line
      x1={@rail_b_x1}
      y1={@rail_b_y1}
      x2={@rail_b_x2}
      y2={@rail_b_y2}
      stroke="#FF00FF"
      stroke-width="0.30"
      stroke-linecap="round"
      data-pathway-rail="true"
      data-rail-base-offset="-2.5"
      data-base-stroke={2.5 * @stroke_mult}
      class={
        if(@mode == :add,
          do: "",
          else: "pointer-events-none transition-colors group-hover:stroke-[#FF4500]"
        )
      }
    />
    <line
      x1={@x1}
      y1={@y1}
      x2={@x2}
      y2={@y2}
      stroke="transparent"
      stroke-width="0.30"
      stroke-linecap="butt"
      marker-start={if @one_way?, do: nil, else: "url(#pathway-arrow)"}
      marker-end="url(#pathway-arrow)"
      data-pathway-arrow-guide="true"
      data-pathway-end-trim="10"
      data-base-stroke={2.5 * @stroke_mult}
      class="pointer-events-none"
    />
    """
  end

  attr :x1, :float, required: true
  attr :y1, :float, required: true
  attr :x2, :float, required: true
  attr :y2, :float, required: true
  attr :text, :string, required: true
  attr :side, :atom, required: true

  defp pathway_label(assigns) do
    {mid_x, mid_y} = pathway_midpoint(assigns.x1, assigns.y1, assigns.x2, assigns.y2)

    {offset_x, offset_y} =
      label_offset(assigns.x1, assigns.y1, assigns.x2, assigns.y2, assigns.side)

    {rotation, flipped?} =
      pathway_label_angle_metadata(assigns.x1, assigns.y1, assigns.x2, assigns.y2)

    display_text = direction_indicator(assigns.text, assigns.side, flipped?)

    assigns =
      assigns
      |> assign(:mid_x, mid_x)
      |> assign(:mid_y, mid_y)
      |> assign(:offset_x, offset_x)
      |> assign(:offset_y, offset_y)
      |> assign(:x, mid_x)
      |> assign(:y, mid_y)
      |> assign(:rotation, rotation)
      |> assign(:display_text, display_text)

    ~H"""
    <text
      x={@x}
      y={@y}
      transform={"rotate(#{@rotation}, #{@x}, #{@y})"}
      fill="#FF00FF"
      stroke="#FFFFFF"
      stroke-width="0.2"
      paint-order="stroke fill"
      font-size="0.78"
      text-anchor="middle"
      dominant-baseline="central"
      data-pathway-label="true"
      data-midpoint-x={@mid_x}
      data-midpoint-y={@mid_y}
      data-offset-x={@offset_x}
      data-offset-y={@offset_y}
      data-rotation={@rotation}
      data-base-font-size="11"
      data-base-stroke="3"
      class="pointer-events-none select-none transition-colors group-hover:fill-[#FF4500]"
    >
      {@display_text}
    </text>
    """
  end

  attr :streams, :any, required: true
  attr :active_point_id, :any
  attr :mode, :atom, required: true
  attr :measurement_enabled, :boolean, default: false
  attr :cross_level_badges_by_stop, :map, default: %{}

  defp stops_layer(assigns) do
    assigns =
      assigns
      |> assign(:stop_label_font_size, @stop_label_font_size)
      |> assign(:stop_label_stroke_width, @stop_label_stroke_width)
      |> assign(:stop_label_line_height, @stop_label_line_height)
      |> assign(:stop_label_box_padding_x, @stop_label_box_padding_x)
      |> assign(:stop_label_box_padding_y, @stop_label_box_padding_y)
      |> assign(:stop_label_box_stroke, @stop_label_box_stroke)

    ~H"""
    <g id="stops-svg" phx-update="stream">
      <%= for {dom_id, stop} <- @streams.child_stops do %>
        <%= if stop.diagram_coordinate do %>
          <% cx = stop.diagram_coordinate["x"] %>
          <% cy = stop.diagram_coordinate["y"] %>
          <% active_fill = if(@active_point_id == stop.id, do: "#FF4500", else: "#0080FF") %>
          <% label = stop_label_text(stop) %>
          <% label_layout = stop_label_layout(label) %>
          <% label_offset_x = stop_label_x_offset(stop.location_type) %>
          <% label_offset_y = stop_label_y_offset(stop.location_type) %>
          <% stop_aria_label = stop_aria_label(stop) %>
          <g
            id={dom_id}
            class="group pointer-events-auto"
            data-stop-id={stop.id}
            data-stop-state={if(@active_point_id == stop.id, do: "selected", else: "active")}
            data-stop-center-x={cx}
            data-stop-center-y={cy}
            data-editable="stop"
            data-tooltip={stop_tooltip_text(@mode, @measurement_enabled)}
            data-tooltip-color={active_fill}
            tabindex={if @mode == :view, do: "0"}
            role={if @mode == :view, do: "button"}
            aria-label={stop_aria_label}
          >
            <rect
              x={cx - 1.75}
              y={cy - 1.75}
              width="3.5"
              height="3.5"
              fill="transparent"
              stroke="transparent"
              stroke-width="0"
              data-stop-hit-target="true"
              data-tooltip-trigger="true"
              data-location-type={stop.location_type}
              data-center-x={cx}
              data-center-y={cy}
              class="cursor-pointer"
              phx-click="stop_clicked"
              phx-value-id={stop.id}
            />
            <%= case stop.location_type do %>
              <% 0 -> %>
                <rect
                  x={cx - 0.5}
                  y={cy - 1.6}
                  width="1.0"
                  height="2.0"
                  rx="0.2"
                  fill={active_fill}
                  stroke="#FFFFFF"
                  stroke-width="0.12"
                  paint-order="stroke fill"
                  class="pointer-events-none transition-colors group-hover:fill-[#FF4500]"
                  data-stop-marker="true"
                  data-location-type={stop.location_type}
                  data-center-x={cx}
                  data-center-y={cy}
                />
              <% 2 -> %>
                <rect
                  x={cx - 0.5}
                  y={cy - 1.6}
                  width="1.0"
                  height="2.0"
                  rx="0.2"
                  fill="#FFFFFF"
                  stroke={active_fill}
                  stroke-width="0.16"
                  class="pointer-events-none transition-colors group-hover:stroke-[#FF4500]"
                  data-stop-marker="true"
                  data-location-type={stop.location_type}
                  data-center-x={cx}
                  data-center-y={cy}
                />
              <% 4 -> %>
                <rect
                  x={cx - 0.6}
                  y={cy - 0.96}
                  width="1.2"
                  height="1.2"
                  rx="0.2"
                  fill={active_fill}
                  stroke="#FFFFFF"
                  stroke-width="0.12"
                  paint-order="stroke fill"
                  class="pointer-events-none transition-colors group-hover:fill-[#FF4500]"
                  data-stop-marker="true"
                  data-location-type={stop.location_type}
                  data-center-x={cx}
                  data-center-y={cy}
                />
              <% _ -> %>
                <circle
                  cx={cx}
                  cy={cy}
                  r="0.6"
                  fill={active_fill}
                  stroke="#FFFFFF"
                  stroke-width="0.12"
                  paint-order="stroke fill"
                  class="pointer-events-none transition-colors group-hover:fill-[#FF4500]"
                  data-stop-marker="true"
                  data-location-type={stop.location_type}
                  data-center-x={cx}
                  data-center-y={cy}
                />
            <% end %>
            <rect
              :if={label_layout}
              fill="transparent"
              fill-opacity="0"
              stroke="transparent"
              stroke-width="0.08"
              paint-order="stroke fill"
              data-stop-label-box="true"
              data-center-x={cx}
              data-center-y={cy}
              data-label-offset-x={label_offset_x}
              data-label-offset-y={label_offset_y}
              data-base-width={label_layout.box_width}
              data-base-height={label_layout.box_height}
              data-base-padding-x={@stop_label_box_padding_x}
              data-base-padding-y={@stop_label_box_padding_y}
              data-base-stroke={@stop_label_box_stroke}
              data-label-line-count={label_layout.line_count}
              class="pointer-events-none transition-colors group-hover:fill-[#FF4500]"
            />
            <text
              :if={label_layout}
              x={cx}
              y={cy}
              font-family="Inter, sans-serif"
              font-weight="500"
              font-size="0.72"
              letter-spacing="0.01em"
              fill={active_fill}
              stroke="#FFFFFF"
              stroke-width="0.17"
              paint-order="stroke fill"
              text-anchor="start"
              dominant-baseline="hanging"
              data-stop-label="true"
              data-center-x={cx}
              data-center-y={cy}
              data-label-offset-x={label_offset_x}
              data-label-offset-y={label_offset_y}
              data-base-font-size={@stop_label_font_size}
              data-base-stroke={@stop_label_stroke_width}
              data-base-line-height={@stop_label_line_height}
              data-label-line-count={label_layout.line_count}
              data-label-truncated={if label_layout.truncated?, do: "true", else: "false"}
              class="pointer-events-none transition-colors group-hover:fill-[#FF4500]"
            >
              <%= for {line, index} <- Enum.with_index(label_layout.lines) do %>
                <tspan x={cx} dy={if(index == 0, do: "0", else: "0.84")}>
                  {line}
                </tspan>
              <% end %>
            </text>
            <.cross_level_badges
              stop={stop}
              mode={@mode}
              cross_level_badges_by_stop={@cross_level_badges_by_stop}
            />
          </g>
        <% end %>
      <% end %>
    </g>
    """
  end

  defp stop_label_text(stop) do
    case stop.location_type do
      0 -> stop_name_with_platform(stop)
      4 -> stop_name_with_platform(stop)
      _ -> present_text(stop.stop_name)
    end
  end

  defp stop_label_layout(nil), do: nil

  defp stop_label_layout(label_text) do
    {lines, truncated?} =
      wrap_stop_label_lines(label_text, @stop_label_max_line_chars, @stop_label_max_lines)

    line_count = length(lines)
    max_line_chars = lines |> Enum.map(&String.length/1) |> Enum.max(fn -> 0 end)
    text_width = max_line_chars * @stop_label_char_width
    text_height = line_count * @stop_label_line_height

    %{
      lines: lines,
      truncated?: truncated?,
      line_count: line_count,
      box_width: text_width + @stop_label_box_padding_x * 2,
      box_height: text_height + @stop_label_box_padding_y * 2
    }
  end

  defp wrap_stop_label_lines(label_text, max_line_chars, max_lines)
       when is_binary(label_text) and max_line_chars > 0 and max_lines > 0 do
    tokens =
      label_text
      |> String.split(~r/\s+/, trim: true)
      |> Enum.flat_map(&split_long_label_token(&1, max_line_chars))

    {lines, current_line} =
      Enum.reduce(tokens, {[], nil}, fn token, {lines, current_line} ->
        candidate =
          case current_line do
            nil -> token
            "" -> token
            _ -> "#{current_line} #{token}"
          end

        if String.length(candidate) <= max_line_chars do
          {lines, candidate}
        else
          {lines ++ [current_line], token}
        end
      end)

    lines =
      case current_line do
        nil -> lines
        "" -> lines
        _ -> lines ++ [current_line]
      end

    if length(lines) <= max_lines do
      {lines, false}
    else
      kept_lines = Enum.take(lines, max_lines)
      index = max_lines - 1
      final_line = kept_lines |> Enum.at(index) |> truncate_label_line(max_line_chars)
      {List.replace_at(kept_lines, index, final_line), true}
    end
  end

  defp split_long_label_token(token, max_line_chars)
       when is_binary(token) and max_line_chars > 0 do
    if String.length(token) <= max_line_chars do
      [token]
    else
      token
      |> String.graphemes()
      |> Enum.chunk_every(max_line_chars)
      |> Enum.map(&Enum.join/1)
    end
  end

  defp truncate_label_line(nil, _max_line_chars), do: "..."

  defp truncate_label_line(line, max_line_chars)
       when is_binary(line) and max_line_chars > 0 do
    room = max(max_line_chars - 3, 0)
    String.slice(line, 0, room) <> "..."
  end

  defp view_mode_instruction(true, nil, _point_b), do: "Click the first end of a known distance."
  defp view_mode_instruction(true, _point_a, nil), do: "Click the other end."

  defp view_mode_instruction(true, _point_a, _point_b),
    do: "Enter the real-world distance and save."

  defp stop_name_with_platform(stop) do
    name = present_text(stop.stop_name)
    platform = present_text(stop.platform_code)

    case {name, platform} do
      {nil, nil} -> nil
      {name, nil} -> name
      {nil, platform} -> platform
      {name, platform} -> "#{name} · #{platform}"
    end
  end

  defp present_text(value) when is_binary(value) do
    text = String.trim(value)
    if text == "", do: nil, else: text
  end

  defp present_text(_), do: nil

  defp stop_aria_label(stop) do
    stop_id = present_text(stop.stop_id) || "Unknown"

    case present_text(stop.stop_name) do
      nil -> "Stop #{stop_id}"
      stop_name -> "Stop #{stop_name} (#{stop_id})"
    end
  end

  # Screen px from the stop coordinate to the label's top-left, clear of the marker.
  defp stop_label_x_offset(_location_type), do: 2

  defp stop_label_y_offset(4), do: 6
  defp stop_label_y_offset(location_type) when location_type in [0, 2], do: 8
  defp stop_label_y_offset(_location_type), do: 10

  defp stop_tooltip_text(:view, false), do: "Click to edit, hold to move"
  defp stop_tooltip_text(:view, true), do: "Editing disabled while measuring"
  defp stop_tooltip_text(:connect, _measurement_enabled), do: "Select stop to create pathway"
  defp stop_tooltip_text(_mode, _measurement_enabled), do: "Click to edit stop"

  defp pathway_aria_label(pathway) do
    mode_label = Pathway.mode_label(pathway.pathway_mode)
    from_label = pathway_stop_display(pathway.from_stop)
    to_label = pathway_stop_display(pathway.to_stop)

    "#{mode_label} pathway from #{from_label} to #{to_label}"
  end

  defp cross_level_badge_tooltip(mode_label), do: "#{mode_label} pathway. Click to edit pathway"
  defp cross_level_badge_aria_label(mode_label), do: "Cross-level #{mode_label} pathway"

  attr :stop, :any, required: true
  attr :mode, :atom, required: true
  attr :cross_level_badges_by_stop, :map, required: true

  defp cross_level_badges(assigns) do
    badges =
      assigns.cross_level_badges_by_stop
      |> Map.get(assigns.stop.id, [])
      |> Enum.with_index()

    assigns =
      assigns
      |> assign(:badges, badges)
      |> assign(:editable?, assigns.mode == :view)

    ~H"""
    <%= if @stop.diagram_coordinate do %>
      <% cx = @stop.diagram_coordinate["x"] %>
      <% cy = @stop.diagram_coordinate["y"] %>
      <%= for {badge, index} <- @badges do %>
        <% badge_offset_x = 22 + index * 20 %>
        <% mode_label = Pathway.mode_label(badge.pathway_mode) %>
        <g
          id={"cross-level-badge-#{badge.pathway_id}"}
          class="group pointer-events-auto cursor-pointer"
          data-cross-level-pathway-badge="true"
          data-pathway-id={badge.pathway_id}
          data-tooltip={if @editable?, do: cross_level_badge_tooltip(mode_label)}
          data-tooltip-color={if @editable?, do: "#FF00FF"}
          tabindex={if @editable?, do: "0"}
          role={if @editable?, do: "button"}
          aria-label={if @editable?, do: cross_level_badge_aria_label(mode_label)}
          phx-click={if @editable?, do: "edit_pathway"}
          phx-value-id={if @editable?, do: badge.pathway_id}
        >
          <rect
            fill="transparent"
            stroke="transparent"
            stroke-width="0"
            data-cross-level-badge-hit="true"
            data-base-size="20"
            data-tooltip-trigger="true"
            data-center-x={cx}
            data-center-y={cy}
            data-badge-offset-x={badge_offset_x}
          />
          <title>{mode_label}</title>
          <%= if badge.pathway_mode in [2, 4] do %>
            <.cross_level_stairs_icon
              center_x={cx}
              center_y={cy}
              offset_x={badge_offset_x}
              fill="#FF00FF"
              editable?={@editable?}
            />
          <% else %>
            <.cross_level_elevator_icon
              center_x={cx}
              center_y={cy}
              offset_x={badge_offset_x}
              fill="#FF00FF"
              editable?={@editable?}
            />
          <% end %>
        </g>
      <% end %>
    <% end %>
    """
  end

  attr :center_x, :float, required: true
  attr :center_y, :float, required: true
  attr :offset_x, :integer, required: true
  attr :fill, :string, required: true
  attr :editable?, :boolean, required: true

  defp cross_level_stairs_icon(assigns) do
    ~H"""
    <path
      class={[
        "pointer-events-none",
        @editable? && "transition-colors group-hover:fill-[#FF4500]"
      ]}
      fill={@fill}
      data-cross-level-badge-stairs="true"
      data-center-x={@center_x}
      data-center-y={@center_y}
      data-badge-offset-x={@offset_x}
    />
    """
  end

  attr :center_x, :float, required: true
  attr :center_y, :float, required: true
  attr :offset_x, :integer, required: true
  attr :fill, :string, required: true
  attr :editable?, :boolean, required: true

  defp cross_level_elevator_icon(assigns) do
    ~H"""
    <path
      class={[
        "pointer-events-none",
        @editable? && "transition-colors group-hover:fill-[#FF4500]"
      ]}
      fill={@fill}
      data-cross-level-badge-elevator="true"
      data-center-x={@center_x}
      data-center-y={@center_y}
      data-badge-offset-x={@offset_x}
    />
    """
  end

  attr :pending_xy, :any, required: true

  defp pending_marker(assigns) do
    ~H"""
    <polygon
      points={"#{@pending_xy.x},#{@pending_xy.y - 1} #{@pending_xy.x - 0.75},#{@pending_xy.y + 0.5} #{@pending_xy.x + 0.75},#{@pending_xy.y + 0.5}"}
      data-cx={@pending_xy.x}
      data-cy={@pending_xy.y}
      fill="#f97316"
      stroke="#fff"
      stroke-width="0.15"
    />
    """
  end

  attr :point_a, :any, required: true
  attr :point_b, :any, default: nil
  attr :style, :atom, required: true

  defp ruler_line(assigns) do
    point_a = Coordinates.normalize_point(assigns.point_a)
    point_b = Coordinates.normalize_point(assigns.point_b)

    cond do
      point_a == nil ->
        ~H""

      point_b == nil and assigns.style == :draft ->
        assigns =
          assigns
          |> assign(:ax, point_a.x)
          |> assign(:ay, point_a.y)
          |> assign(:line_color, "#f97316")

        ~H"""
        <g class="pointer-events-none">
          <circle
            cx={@ax}
            cy={@ay}
            r="0.35"
            fill="#ffffff"
            stroke={@line_color}
            stroke-width="0.13"
            data-ruler-endpoint="true"
            data-center-x={@ax}
            data-center-y={@ay}
            data-base-radius="4"
            data-base-stroke="2"
          />
        </g>
        """

      point_b == nil ->
        ~H""

      true ->
        {mid_x, mid_y} = pathway_midpoint(point_a.x, point_a.y, point_b.x, point_b.y)
        top_node = if point_a.y <= point_b.y, do: point_a, else: point_b
        saved_label? = assigns.style == :saved
        label_anchor_x = if(saved_label?, do: top_node.x, else: mid_x)
        label_anchor_y = if(saved_label?, do: top_node.y, else: mid_y)
        label_offset_x = if(saved_label?, do: 8, else: 0)
        label_offset_y = if(saved_label?, do: 0, else: -12)

        assigns =
          assigns
          |> assign(:ax, point_a.x)
          |> assign(:ay, point_a.y)
          |> assign(:bx, point_b.x)
          |> assign(:by, point_b.y)
          |> assign(:mx, mid_x)
          |> assign(:my, mid_y)
          |> assign(:line_color, if(saved_label?, do: "#16a34a", else: "#f97316"))
          |> assign(:label_text, if(saved_label?, do: "SCALE", else: "Measure"))
          |> assign(:saved_label?, saved_label?)
          |> assign(:label_anchor_x, label_anchor_x)
          |> assign(:label_anchor_y, label_anchor_y)
          |> assign(:label_offset_x, label_offset_x)
          |> assign(:label_offset_y, label_offset_y)

        ~H"""
        <g
          class={
            if @style == :saved, do: "cursor-pointer pointer-events-auto", else: "pointer-events-none"
          }
          data-ruler-type={if @style == :saved, do: "saved"}
        >
          <line
            :if={@style == :saved}
            x1={@ax}
            y1={@ay}
            x2={@bx}
            y2={@by}
            stroke="transparent"
            stroke-width="1.5"
            data-ruler-hit-area="true"
            data-base-stroke="12"
          />
          <line
            x1={@ax}
            y1={@ay}
            x2={@bx}
            y2={@by}
            stroke={@line_color}
            stroke-width="0.25"
            data-ruler-line="true"
            data-base-stroke="2"
          />
          <circle
            cx={@ax}
            cy={@ay}
            r="0.35"
            fill="#ffffff"
            stroke={@line_color}
            stroke-width="0.13"
            data-ruler-endpoint="true"
            data-center-x={@ax}
            data-center-y={@ay}
            data-base-radius="4"
            data-base-stroke="2"
          />
          <circle
            cx={@bx}
            cy={@by}
            r="0.35"
            fill="#ffffff"
            stroke={@line_color}
            stroke-width="0.13"
            data-ruler-endpoint="true"
            data-center-x={@bx}
            data-center-y={@by}
            data-base-radius="4"
            data-base-stroke="2"
          />
          <text
            x={@label_anchor_x}
            y={@label_anchor_y}
            fill={@line_color}
            stroke="#ffffff"
            stroke-width="0.16"
            paint-order="stroke fill"
            font-size="0.78"
            font-weight="600"
            text-anchor={if @saved_label?, do: "start", else: "middle"}
            dominant-baseline="central"
            data-ruler-label="true"
            data-midpoint-x={@mx}
            data-midpoint-y={@my}
            data-label-anchor-x={if @saved_label?, do: @label_anchor_x}
            data-label-anchor-y={if @saved_label?, do: @label_anchor_y}
            data-label-offset-x={if @saved_label?, do: @label_offset_x}
            data-label-offset-y={@label_offset_y}
            data-base-font-size="11"
            data-base-stroke="3"
            class="select-none"
          >
            {@label_text}
          </text>
        </g>
        """
    end
  end

  # The one instruction a step in progress needs, on the plan where the eye is.
  # The status bar never repeats it. Resting in Select, nothing sits on the plan.
  attr :mode, :atom, required: true
  attr :selected_from_stop, :any, default: nil
  attr :measurement_enabled, :boolean, default: false
  attr :ruler_point_a, :any, default: nil
  attr :ruler_point_b, :any, default: nil

  defp plan_hint(assigns) do
    assigns = assign(assigns, :step, plan_hint_step(assigns))

    ~H"""
    <div
      :if={@step}
      id="plan-hint"
      class="pointer-events-none absolute left-3 top-3 z-10 max-w-[calc(100%-24px)]"
    >
      <div class="pointer-events-auto inline-flex items-center gap-2.5 rounded-control border border-subtle bg-white/95 py-1 pl-2 pr-2 text-[13px] text-strong shadow-card">
        <span
          :if={@step != ""}
          class="grid size-6 shrink-0 place-items-center rounded-full bg-selection text-[12.5px] font-bold text-action"
        >
          {@step}
        </span>
        <%= cond do %>
          <% @mode == :view and @measurement_enabled -> %>
            <span>{view_mode_instruction(true, @ruler_point_a, @ruler_point_b)}</span>
            <button
              type="button"
              class="-my-1 inline-flex min-h-9 items-center rounded-control px-2.5 text-sm font-[650] text-action hover:bg-selection"
              phx-click="toggle_measurement"
            >
              Cancel
            </button>
          <% @mode == :add -> %>
            <span>Click the floorplan where the point belongs.</span>
          <% @mode == :connect and @selected_from_stop == nil -> %>
            <span>Click the starting point.</span>
          <% @mode == :connect -> %>
            <span>
              From <strong class="font-[650]">{stop_display_name(@selected_from_stop)}</strong>.
              Click the destination.
            </span>
            <button
              type="button"
              class="-my-1 inline-flex min-h-9 items-center rounded-control px-2.5 text-sm font-[650] text-action hover:bg-selection"
              phx-click="clear_from_selection"
              aria-label="Clear starting stop"
            >
              Clear start
            </button>
          <% true -> %>
        <% end %>
      </div>
    </div>
    """
  end

  # The numbered step a chip shows: measuring counts its two points, Connect
  # its start and destination, and Add point is one click, so it has no number.
  defp plan_hint_step(%{mode: :view, measurement_enabled: true, ruler_point_a: nil}), do: 1
  defp plan_hint_step(%{mode: :view, measurement_enabled: true}), do: 2
  defp plan_hint_step(%{mode: :add}), do: ""
  defp plan_hint_step(%{mode: :connect, selected_from_stop: nil}), do: 1
  defp plan_hint_step(%{mode: :connect}), do: 2
  defp plan_hint_step(_assigns), do: nil

  defp stop_display_name(nil), do: ""
  defp stop_display_name(stop), do: stop.stop_name || stop.stop_id

  # Key at the lower left, view controls at the lower right, on the plan and
  # nowhere else. The pan buttons exist for keyboard operators, so they appear
  # once focus is inside the plan (`#plan-wrap:focus-within`, in the page CSS);
  # mouse users pan with Shift-drag or the middle button.
  defp plan_controls(assigns) do
    ~H"""
    <div
      id="plan-key"
      class="pointer-events-none absolute inset-y-3 left-3 z-20 flex flex-col justify-end"
    >
      <div
        id="diagram-legend-panel"
        role="dialog"
        aria-label="Key"
        phx-click-away={close_key()}
        phx-window-keydown={close_key(JS.focus(to: "#diagram-legend-trigger[aria-expanded='true']"))}
        phx-key="escape"
        style="display: none;"
        class="pointer-events-auto mb-2 min-h-0 w-[300px] max-w-[calc(100vw-48px)] overflow-y-auto rounded-card border border-subtle bg-white p-4 shadow-float"
      >
        <div class="flex items-center justify-between">
          <h3 class="text-[15px] font-bold text-strong">Key</h3>
          <button
            type="button"
            id="diagram-legend-close"
            aria-label="Close key"
            class="-mr-2 -mt-2 grid size-11 place-items-center rounded-control text-muted hover:bg-canvas hover:text-strong"
            phx-click={close_key() |> JS.focus(to: "#diagram-legend-trigger")}
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>

        <p class="mt-1 text-[12.5px] font-[650] text-muted">Points</p>
        <ul class="mt-1.5 grid gap-1.5">
          <li
            :for={
              {type, label} <- [
                {0, "Platform"},
                {2, "Entrance or exit"},
                {3, "Junction"},
                {4, "Boarding spot"}
              ]
            }
            class="flex items-center gap-3 text-sm"
          >
            <.point_symbol type={type} class="size-5" /> <span>{label}</span>
          </li>
          <li class="flex items-center gap-3 text-sm">
            <span class="grid size-5 shrink-0 place-items-center rounded-full border-2 border-(--diagram-active-stop) bg-white text-(--diagram-active-stop)">
              <.icon name="hero-arrows-up-down" class="size-3" />
            </span>
            <span>Pathway to another level</span>
          </li>
          <li class="flex items-center gap-3 text-sm">
            <svg viewBox="-8 -20 16 22" class="h-5 w-4 shrink-0" aria-hidden="true">
              <path
                d="M 0 0 C -4 -5.6 -7.2 -8.8 -7.2 -12.8 A 7.2 7.2 0 1 1 7.2 -12.8 C 7.2 -8.8 4 -5.6 0 0 Z"
                stroke-width="1.2"
                class="fill-(--diagram-journal-open) stroke-white"
              />
              <circle cx="0" cy="-12.8" r="2.4" class="fill-white" />
            </svg>
            <span>Journal note placed on the plan</span>
          </li>
          <li class="flex items-center gap-3 text-sm">
            <svg viewBox="0 0 16 16" class="size-5 shrink-0" aria-hidden="true">
              <circle
                cx="8"
                cy="8"
                r="4.5"
                stroke-width="1.5"
                class="fill-(--diagram-journal-open) stroke-white"
              />
            </svg>
            <span>Journal note on a point or pathway</span>
          </li>
        </ul>

        <p class="mt-3 text-[12.5px] font-[650] text-muted">Pathways</p>
        <ul class="mt-1.5 grid gap-1.5">
          <li :for={mode <- 1..7} class="flex items-center gap-3 text-sm">
            <.pathway_symbol mode={mode} class="h-5 w-9" /> <span>{key_pathway_label(mode)}</span>
          </li>
          <li class="text-[12.5px] text-muted">An arrowhead marks a one-way pathway.</li>
        </ul>

        <p class="mt-3 text-[12.5px] font-[650] text-muted">Moving around</p>
        <ul class="mt-1.5 grid gap-1 text-[12.5px] text-default">
          <li>
            Click a point or pathway to edit it. Hold a point, then drag to move it; Esc cancels.
          </li>
          <li>
            Shift-drag or middle-drag pans. Ctrl or Cmd + scroll zooms; scroll pans when zoomed in.
          </li>
          <li>Tab reaches the plan; Enter opens the focused point or pathway.</li>
        </ul>
      </div>
      <button
        id="diagram-legend-trigger"
        type="button"
        aria-expanded="false"
        aria-controls="diagram-legend-panel"
        class="pointer-events-auto inline-flex min-h-11 items-center gap-1.5 self-start rounded-control border border-subtle bg-white px-3 text-[13px] font-[650] text-strong shadow-card hover:bg-canvas"
        phx-click={
          JS.toggle(to: "#diagram-legend-panel")
          |> JS.toggle_attribute({"aria-expanded", "true", "false"}, to: "#diagram-legend-trigger")
        }
      >
        <.icon name="hero-list-bullet" class="size-4" /> Key
      </button>
    </div>

    <div id="plan-view-controls" class="absolute bottom-3 right-3 z-10 flex items-end gap-2">
      <div
        id="pan-cluster"
        class="items-stretch overflow-clip rounded-control border border-subtle bg-white shadow-card"
      >
        <button
          :for={
            {direction, label, icon} <- [
              {"up", "Pan up", "hero-arrow-up"},
              {"down", "Pan down", "hero-arrow-down"},
              {"left", "Pan left", "hero-arrow-left"},
              {"right", "Pan right", "hero-arrow-right"}
            ]
          }
          type="button"
          data-pan={direction}
          aria-label={label}
          title={label}
          class="grid size-11 place-items-center text-strong hover:bg-canvas [&:not(:first-child)]:border-l [&:not(:first-child)]:border-subtle"
        >
          <.icon name={icon} class="size-4" />
        </button>
      </div>
      <div class="flex items-stretch overflow-clip rounded-control border border-subtle bg-white shadow-card">
        <button
          type="button"
          data-zoom="out"
          aria-label="Zoom out"
          title="Zoom out"
          class="grid size-11 place-items-center text-strong hover:bg-canvas"
        >
          <.icon name="hero-minus" class="size-4" />
        </button>
        <span
          data-zoom-label
          class="grid min-w-[52px] select-none place-items-center border-x border-subtle text-[12.5px] font-[650] tabular-nums text-default"
        >
          100%
        </span>
        <button
          type="button"
          data-zoom="in"
          aria-label="Zoom in"
          title="Zoom in"
          class="grid size-11 place-items-center text-strong hover:bg-canvas"
        >
          <.icon name="hero-plus" class="size-4" />
        </button>
        <button
          type="button"
          data-reset="true"
          aria-label="Reset view"
          title="Fit the whole floorplan"
          class="grid size-11 place-items-center border-l border-subtle text-strong hover:bg-canvas"
        >
          <.icon name="hero-arrows-pointing-out" class="size-4" />
        </button>
      </div>
    </div>
    """
  end

  defp close_key(js \\ %JS{}) do
    js
    |> JS.hide(to: "#diagram-legend-panel")
    |> JS.set_attribute({"aria-expanded", "false"}, to: "#diagram-legend-trigger")
  end

  defp key_pathway_label(1), do: "Walkway"
  defp key_pathway_label(2), do: "Stairs"
  defp key_pathway_label(3), do: "Moving sidewalk"
  defp key_pathway_label(4), do: "Escalator"
  defp key_pathway_label(5), do: "Elevator"
  defp key_pathway_label(6), do: "Fare gate"
  defp key_pathway_label(7), do: "Exit gate"

  # The marker a point type draws on the plan, at list and key size. Shape
  # carries the type, so it reads without the colour.
  attr :type, :integer, default: 3
  attr :class, :string, default: "size-4"

  defp point_symbol(assigns) do
    ~H"""
    <svg viewBox="0 0 16 16" class={["shrink-0", @class]} aria-hidden="true">
      <%= case @type do %>
        <% 0 -> %>
          <rect x="4.5" y="1.5" width="7" height="13" rx="1.2" class="fill-(--diagram-active-stop)" />
        <% 2 -> %>
          <rect
            x="4.5"
            y="1.5"
            width="7"
            height="13"
            rx="1.2"
            stroke-width="1.8"
            class="fill-white stroke-(--diagram-active-stop)"
          />
        <% 4 -> %>
          <rect
            x="3.5"
            y="3.5"
            width="9"
            height="9"
            rx="1.2"
            class="fill-(--diagram-active-stop)"
          />
        <% 1 -> %>
          <rect
            x="2.5"
            y="2.5"
            width="11"
            height="11"
            rx="2"
            stroke-width="1.8"
            class="fill-white stroke-(--diagram-active-stop)"
          />
        <% _ -> %>
          <circle cx="8" cy="8" r="5" class="fill-(--diagram-active-stop)" />
      <% end %>
    </svg>
    """
  end

  # The mark a pathway mode draws on the plan, at list and key size.
  attr :mode, :integer, default: 1
  attr :one_way?, :boolean, default: nil
  attr :class, :string, default: "h-4 w-7"

  defp pathway_symbol(assigns) do
    one_way? =
      case assigns.one_way? do
        nil -> assigns.mode in [3, 4, 6, 7]
        value -> value
      end

    assigns = assign(assigns, :arrow?, one_way?)

    ~H"""
    <svg viewBox="0 0 28 16" class={["shrink-0", @class]} aria-hidden="true">
      <g
        fill="none"
        stroke-linecap="round"
        class="stroke-(--diagram-pathway-forward)"
      >
        <path :if={@mode not in [6, 7]} d="M2 8h24" stroke-width="2.2" />
        <path :if={@mode == 2} d="M14 3.5v9" stroke-width="1.8" />
        <path :if={@mode == 3} d="M11 4.5l6 7M17 4.5l-6 7" stroke-width="1.6" />
        <path :if={@mode == 4} d="M11 3.5v9M14 3.5v9M17 3.5v9" stroke-width="1.6" />
        <path :if={@mode in [6, 7]} d="M2 5.5h22M2 10.5h22" stroke-width="1.6" />
        <rect
          :if={@mode == 5}
          x="9"
          y="2.5"
          width="10"
          height="11"
          rx="2"
          stroke-width="1.8"
          class="fill-white"
        />
        <path :if={@mode == 5} d="M14 5v6M12 6.5l2-2 2 2M12 9.5l2 2 2-2" stroke-width="1.2" />
      </g>
      <path :if={@arrow?} d="M22 4.5 27 8l-5 3.5z" class="fill-(--diagram-pathway-forward)" />
    </svg>
    """
  end

  attr :has_diagram, :boolean, default: false
  attr :upload, :any, default: nil
  attr :upload_phase, :atom, default: :idle
  attr :level_name, :string, required: true
  attr :point_count, :integer, default: 0

  defp empty_diagram_state(assigns) do
    ~H"""
    <div
      id="empty-diagram-state"
      class="absolute inset-0 grid place-items-center overflow-y-auto bg-canvas p-6"
    >
      <div class="mx-auto max-w-[520px] text-center">
        <span class="mx-auto mb-4 grid size-12 place-items-center rounded-full bg-white text-cyan-700">
          <.icon name="hero-photo" class="size-6" />
        </span>
        <h2 class="font-display text-[20px] font-semibold tracking-[-0.02em] text-strong">
          No floorplan for {@level_name}
        </h2>
        <p class="mt-2 text-sm text-muted">
          Upload an image of this level's floor plan, then place points and pathways on it.
          <span :if={@point_count > 0}>
            The {@point_count} {if @point_count == 1, do: "point", else: "points"} already on {@level_name}
            {if @point_count == 1, do: "is", else: "are"} listed at right.
          </span>
        </p>
        <form id="diagram-upload-form-empty" phx-change="upload_diagram" class="mt-6 space-y-2">
          <.upload_field
            :if={@upload}
            id="empty-floorplan-upload"
            upload={@upload}
            label="Floorplan image"
            help="PNG or JPEG, up to 10 MB."
            cancel_event="cancel_diagram_upload"
            appearance={:button}
            action_label="Upload floorplan"
            state={upload_phase_to_state(@upload_phase)}
            disabled={@upload_phase in [:uploading, :validating, :probing_candidate, :committing]}
            pending_label={upload_pending_label(@upload_phase)}
          />
        </form>
      </div>
    </div>
    """
  end

  defp no_level_state(assigns) do
    ~H"""
    <div
      id="no-level-state"
      class="absolute inset-0 grid place-items-center overflow-y-auto bg-canvas p-6"
    >
      <div class="mx-auto max-w-[520px] text-center">
        <h2 class="font-display text-[22px] font-semibold tracking-[-0.02em] text-strong">
          This station has no levels yet
        </h2>
        <p class="mt-2 text-sm text-muted">
          A level is a floor or storey of the station, like Street, Concourse or Platform. Add a
          level, then upload a floorplan to place points and pathways.
        </p>
        <div class="mt-6">
          <.button type="button" phx-click="open_add_level" class="min-h-11">Add level</.button>
        </div>
      </div>
    </div>
    """
  end

  # ============================================================================
  # Child Stop Drawer (the point editor)
  # ============================================================================

  attr :pending_xy, :any
  attr :selected_stop_id, :any
  attr :editing_stop, :any, default: nil
  attr :child_stop_form, :any, required: true
  attr :mode, :atom, required: true
  attr :all_levels, :list, required: true
  attr :editing_level, :boolean, default: false
  attr :stop_id_mode, :atom, default: :auto
  attr :active_level, :any, default: nil
  attr :reposition_mode, :boolean, default: false
  attr :reposition_search, :string, default: ""
  attr :reposition_stops, :list, default: []
  attr :reposition_x, :string, default: ""
  attr :reposition_y, :string, default: ""
  attr :platform_options, :list, default: []
  attr :history_open_for, :any, default: nil
  attr :history_entries, :list, default: []
  attr :history_state, :atom, default: :idle
  attr :history_filter_form, :any, default: nil
  attr :history_field_filter, :string, default: "all"
  attr :history_zone, :any, default: nil
  attr :history_local_times, :map, default: %{}
  attr :history_today, :any, default: nil
  attr :history_now, :any, default: nil
  attr :rollback_preview, :any, default: nil
  attr :journal_context, :any, default: nil
  attr :drawer_journal_entries, :any, default: nil
  attr :drawer_journal_open_for, :any, default: nil
  attr :drawer_journal_state, :atom, default: :idle
  attr :drawer_journal_total_count, :integer, default: 0
  attr :drawer_journal_loaded_once?, :boolean, default: false
  attr :drawer_journal_refresh_error?, :boolean, default: false
  attr :drawer_journal_error_message, :string, default: nil
  attr :drawer_journal_authors, :map, default: %{}
  attr :drawer_journal_local_times, :map, default: %{}
  attr :drawer_journal_display_zone, :any, default: nil
  attr :drawer_journal_now, :any, default: nil
  attr :drawer_journal_scope, :any, default: nil
  attr :journal_target_counts, :map, default: %{}
  attr :child_stop_error, :any, default: nil

  def child_stop_drawer(assigns) do
    show_toggle =
      assigns.mode == :add && assigns.pending_xy != nil && assigns.selected_stop_id == nil

    reposition? = assigns.reposition_mode && is_nil(assigns.selected_stop_id)

    {drawer_title, drawer_lede} = point_drawer_heading(assigns, reposition?)

    show_history_tabs = assigns.selected_stop_id != nil

    history_active =
      show_history_tabs and
        assigns.history_open_for == {"stop", assigns.selected_stop_id}

    journal_active =
      show_history_tabs and
        assigns.drawer_journal_open_for == {"stop", assigns.selected_stop_id}

    assigns =
      assigns
      |> assign(:drawer_title, drawer_title)
      |> assign(:drawer_lede, drawer_lede)
      |> assign(:reposition?, reposition?)
      |> assign(:show_toggle, show_toggle)
      |> assign(:show_history_tabs, show_history_tabs)
      |> assign(:history_active, history_active)
      |> assign(:journal_active, journal_active)
      |> assign(
        :journal_count,
        entity_journal_count(
          journal_active and assigns.drawer_journal_loaded_once?,
          assigns.drawer_journal_total_count,
          assigns.journal_target_counts,
          {"node", assigns.selected_stop_id}
        )
      )

    ~H"""
    <.drawer
      id="child-stop-drawer"
      chrome="planner"
      open={@pending_xy != nil && (@mode == :add || (@mode == :view && @selected_stop_id != nil))}
      on_close="close_drawer"
      title={@drawer_title}
      class="max-w-[440px]"
    >
      <:lede :if={@drawer_lede}>{@drawer_lede}</:lede>
      <:header_actions>
        <div :if={@show_toggle} class="inline-flex rounded-control border border-control p-0.5">
          <button
            id="enter-new-stop-mode"
            type="button"
            aria-pressed={to_string(!@reposition_mode)}
            class="inline-flex min-h-10 items-center whitespace-nowrap rounded-[5px] px-3 text-sm font-[650] text-default hover:bg-canvas aria-[pressed=true]:bg-selection aria-[pressed=true]:text-action"
            phx-click="exit_reposition_mode"
          >
            New point
          </button>
          <button
            id="enter-reposition-mode"
            type="button"
            aria-pressed={to_string(@reposition_mode)}
            class="inline-flex min-h-10 items-center whitespace-nowrap rounded-[5px] px-3 text-sm font-[650] text-default hover:bg-canvas aria-[pressed=true]:bg-selection aria-[pressed=true]:text-action"
            phx-click="enter_reposition_mode"
          >
            Move an existing point here
          </button>
        </div>
      </:header_actions>

      <.history_tab_strip
        :if={@show_history_tabs}
        entity_type="stop"
        entity_id={@selected_stop_id}
        history_active={@history_active}
        show_journal={true}
        journal_active={@journal_active}
        journal_count={@journal_count}
      />

      <div
        id="stop-panel-details"
        role={if @show_history_tabs, do: "tabpanel"}
        aria-labelledby={if @show_history_tabs, do: "stop-tab-details"}
        hidden={@history_active || @journal_active}
        class="flex min-h-0 flex-1 flex-col"
      >
        <div :if={@journal_context} class="border-b border-subtle px-5 pt-4 sm:px-6">
          <.journal_context_box context={@journal_context} />
        </div>

        <.reposition_stop_view
          :if={@reposition?}
          reposition_stops={@reposition_stops}
          reposition_search={@reposition_search}
          active_level={@active_level}
          reposition_x={@reposition_x}
          reposition_y={@reposition_y}
        />

        <.child_stop_form
          :if={@pending_xy && !@reposition?}
          child_stop_form={@child_stop_form}
          child_stop_error={@child_stop_error}
          platform_options={@platform_options}
          selected_stop_id={@selected_stop_id}
          pending_xy={@pending_xy}
          all_levels={@all_levels}
          editing_level={@editing_level}
          stop_id_mode={@stop_id_mode}
          active_level={@active_level}
        />
      </div>

      <div
        id="stop-panel-history"
        role={if @show_history_tabs, do: "tabpanel"}
        aria-labelledby={if @show_history_tabs, do: "stop-tab-history"}
        hidden={!@history_active}
        class="min-h-0 flex-1 overflow-y-auto px-5 py-5 sm:px-6"
      >
        <.change_log_list
          :if={@history_active}
          entries={@history_entries}
          entity_type="stop"
          state={@history_state}
          filter_form={@history_filter_form}
          history_field_filter={@history_field_filter}
          zone={@history_zone}
          local_times={@history_local_times}
          today={@history_today}
          now={@history_now}
          rollback_preview={@rollback_preview}
        />
      </div>

      <div
        :if={@show_history_tabs}
        id="stop-panel-journal"
        role="tabpanel"
        aria-labelledby="stop-tab-journal"
        hidden={!@journal_active}
        class="min-h-0 flex-1 overflow-y-auto px-5 py-5 sm:px-6"
      >
        <.entity_journal_panel
          :if={@journal_active}
          entity_type="stop"
          entity_id={@selected_stop_id}
          entity_label="point"
          journal_entries={@drawer_journal_entries}
          journal_state={@drawer_journal_state}
          journal_entries_exist?={@drawer_journal_total_count > 0}
          journal_error_fallback?={@drawer_journal_refresh_error?}
          journal_scope={@drawer_journal_scope}
          journal_authors={@drawer_journal_authors}
          journal_local_times={@drawer_journal_local_times}
          journal_now={@drawer_journal_now}
        />
      </div>
    </.drawer>
    """
  end

  defp point_drawer_heading(_assigns, true),
    do: {"Move an existing point here", "Choose the point that belongs at this spot."}

  defp point_drawer_heading(%{selected_stop_id: nil} = assigns, false),
    do: {"Add a point", "On #{level_display_name(assigns.all_levels, active_level_id(assigns))}."}

  defp point_drawer_heading(%{editing_stop: nil}, false), do: {"Edit point", nil}

  defp point_drawer_heading(%{editing_stop: stop}, false) do
    {stop.stop_name || stop.stop_id, "#{point_type_label(stop.location_type)} · #{stop.stop_id}"}
  end

  defp active_level_id(%{active_level: %{level_id: level_id}}), do: level_id
  defp active_level_id(_assigns), do: nil

  attr :reposition_stops, :list, default: []
  attr :reposition_search, :string, default: ""
  attr :active_level, :any, default: nil
  attr :reposition_x, :string, default: ""
  attr :reposition_y, :string, default: ""

  defp reposition_stop_view(assigns) do
    normalized_search =
      assigns.reposition_search
      |> to_string()
      |> String.trim()
      |> String.downcase()

    filtered_stops =
      Enum.filter(assigns.reposition_stops, fn stop ->
        if normalized_search == "" do
          true
        else
          stop_id = stop.stop_id |> to_string() |> String.downcase()
          stop_name = stop.stop_name |> to_string() |> String.downcase()

          String.contains?(stop_id, normalized_search) or
            String.contains?(stop_name, normalized_search)
        end
      end)

    unpositioned_stops =
      Enum.filter(filtered_stops, fn stop ->
        is_nil(stop.diagram_coordinate) or stop.level_id in [nil, ""]
      end)

    positioned_stops =
      Enum.filter(filtered_stops, fn stop ->
        stop.diagram_coordinate != nil and not is_nil(assigns.active_level) and
          stop.level_id == assigns.active_level.level_id
      end)

    search_form = to_form(%{"query" => assigns.reposition_search}, as: :search)
    coordinate_form = to_form(%{"x" => assigns.reposition_x, "y" => assigns.reposition_y})

    assigns =
      assigns
      |> assign(:search_form, search_form)
      |> assign(:coordinate_form, coordinate_form)
      |> assign(:unpositioned_stops, unpositioned_stops)
      |> assign(:positioned_stops, positioned_stops)

    ~H"""
    <.drawer_scroll>
      <.form
        for={@coordinate_form}
        id="reposition-coordinate-form"
        phx-change="validate_reposition_coordinates"
      >
        <fieldset class="grid gap-1.5">
          <legend class="text-[13px] font-[650] text-default">Spot on the floorplan</legend>
          <div class="grid grid-cols-2 gap-3">
            <.input
              field={@coordinate_form[:x]}
              id="reposition-x-input"
              type="number"
              label="X, across"
              step="any"
            />
            <.input
              field={@coordinate_form[:y]}
              id="reposition-y-input"
              type="number"
              label="Y, down"
              step="any"
            />
          </div>
        </fieldset>
      </.form>

      <.form
        for={@search_form}
        id="reposition-search-form"
        phx-change="reposition_search"
        phx-submit="reposition_search"
      >
        <.input
          field={@search_form[:query]}
          id="reposition-search-input"
          type="text"
          label="Find a point"
          placeholder="Find by name or ID"
          phx-debounce="200"
        />
      </.form>

      <section class="grid gap-2">
        <h3 class="text-[13px] font-[650] text-default">Not placed on this level</h3>
        <ul
          id="unpositioned-stops-table"
          class="divide-y divide-subtle border-y border-subtle"
        >
          <li
            :for={stop <- @unpositioned_stops}
            id={"unpositioned-stop-row-#{stop.id}"}
            class="flex items-center justify-between gap-3 py-1.5"
          >
            <.reposition_row stop={stop} />
            <.button
              type="button"
              variant="secondary"
              class="min-h-11"
              phx-click="reposition_stop"
              phx-value-id={stop.id}
              aria-label={reposition_row_label("Place here", stop)}
            >
              Place here
            </.button>
          </li>
          <li :if={@unpositioned_stops == []} class="py-3 text-sm text-muted">
            No matching points to place.
          </li>
        </ul>
      </section>

      <section class="grid gap-2">
        <h3 class="text-[13px] font-[650] text-default">Already on this level</h3>
        <ul id="positioned-stops-table" class="divide-y divide-subtle border-y border-subtle">
          <li
            :for={stop <- @positioned_stops}
            id={"positioned-stop-row-#{stop.id}"}
            class="flex items-center justify-between gap-3 py-1.5"
          >
            <.reposition_row stop={stop} />
            <.button
              type="button"
              variant="secondary"
              class="min-h-11"
              phx-click="reposition_stop"
              phx-value-id={stop.id}
              aria-label={reposition_row_label("Move here", stop)}
            >
              Move here
            </.button>
          </li>
          <li :if={@positioned_stops == []} class="py-3 text-sm text-muted">
            No matching points on this level.
          </li>
        </ul>
      </section>
    </.drawer_scroll>
    """
  end

  attr :stop, :any, required: true

  defp reposition_row(assigns) do
    ~H"""
    <div class="flex min-w-0 items-center gap-3">
      <.point_symbol type={@stop.location_type} />
      <div class="min-w-0">
        <p class="truncate text-sm font-[650] text-strong">{@stop.stop_name || @stop.stop_id}</p>
        <p class="truncate text-[12.5px] text-muted">
          {point_type_label(@stop.location_type)} · <span class="font-mono">{@stop.stop_id}</span>
        </p>
      </div>
    </div>
    """
  end

  # Row-action label naming the target stop; the parenthetical name is omitted
  # when the stop has no name, so no empty "()" is announced to assistive tech.
  defp reposition_row_label(action, stop) do
    case stop.stop_name do
      name when is_binary(name) and name != "" -> "#{action} — #{stop.stop_id} (#{name})"
      _ -> "#{action} — #{stop.stop_id}"
    end
  end

  attr :child_stop_form, :any, required: true
  attr :child_stop_error, :any, default: nil
  attr :selected_stop_id, :any
  attr :pending_xy, :any, required: true
  attr :all_levels, :list, required: true
  attr :editing_level, :boolean, default: false
  attr :stop_id_mode, :atom, default: :auto
  attr :active_level, :any, default: nil
  attr :platform_options, :list, default: []

  defp child_stop_form(assigns) do
    # A point inside a station can be a platform, entrance, junction or boarding spot.
    # Type 1 (Station) must not have a parent station, so it is not offered.
    location_type_options = [
      {"Platform", "0"},
      {"Entrance or exit", "2"},
      {"Junction", "3"},
      {"Boarding spot", "4"}
    ]

    wheelchair_boarding_options = [
      {"Not specified", ""},
      {"Same as the station", "0"},
      {"Accessible", "1"},
      {"Not accessible", "2"}
    ]

    current_level_id =
      assigns.child_stop_form[:level_id].value ||
        if(assigns.active_level, do: assigns.active_level.level_id, else: nil)

    current_level_display = level_display_name(assigns.all_levels, current_level_id)
    location_type = parse_optional_int(assigns.child_stop_form[:location_type].value) || 3

    assigns =
      assigns
      |> assign(:location_type_options, location_type_options)
      |> assign(:wheelchair_boarding_options, wheelchair_boarding_options)
      |> assign(:current_level_id, current_level_id || "")
      |> assign(:current_level_display, current_level_display)
      |> assign(:is_new_stop, assigns.selected_stop_id == nil)
      |> assign(:location_type, location_type)
      |> assign(:type_hint, point_type_hint(location_type))
      |> assign(:show_platform_code, location_type in [0, 4])

    ~H"""
    <.form
      for={@child_stop_form}
      id="child-stop-form"
      phx-submit="save_child_stop"
      phx-change="validate_child_stop"
      class="flex min-h-0 flex-1 flex-col"
    >
      <.drawer_scroll>
        <.deletion_refusal
          :if={@child_stop_error}
          id="child-stop-in-use-error"
          refusal={@child_stop_error}
        />

        <.input
          field={@child_stop_form[:stop_name]}
          type="text"
          label="Name"
          placeholder="e.g., Elevator A lobby"
          help="How riders see this place."
          required
        />

        <.input
          field={@child_stop_form[:location_type]}
          type="select"
          label="Type"
          options={@location_type_options}
          prompt={if @location_type == 1, do: "Choose a type"}
          required={@location_type == 1}
          help={
            if @location_type == 1,
              do: "This point is stored as a station, which can't be inside a station.",
              else: @type_hint
          }
        />

        <.input
          field={@child_stop_form[:wheelchair_boarding]}
          type="select"
          label="Wheelchair access"
          options={@wheelchair_boarding_options}
        />

        <.input
          :if={@show_platform_code}
          field={@child_stop_form[:platform_code]}
          type="text"
          label="Platform code (optional)"
          placeholder="e.g., 2A"
        />

        <.input
          :if={@location_type == 4 && @platform_options != []}
          field={@child_stop_form[:parent_platform]}
          type="select"
          label="On platform (optional)"
          options={[{"None (directly under the station)", ""} | @platform_options]}
        />

        <p
          :if={@location_type == 4 && @platform_options == []}
          id="parent-platform-info"
          class="text-[13px] text-muted"
        >
          No platforms defined for this station yet.
        </p>

        <fieldset class="grid gap-1.5">
          <legend class="text-[13px] font-[650] text-default">Position on the floorplan</legend>
          <div class="grid grid-cols-2 gap-3">
            <.input
              field={@child_stop_form[:x]}
              type="number"
              label="X, across"
              placeholder="e.g., 42.5"
              step="any"
            />
            <.input
              field={@child_stop_form[:y]}
              type="number"
              label="Y, down"
              placeholder="e.g., 78.3"
              step="any"
            />
          </div>
          <p class="text-[13px] text-muted">
            Click or drag on the plan to set it, or type the numbers here.
          </p>
        </fieldset>

        <%= if @selected_stop_id != nil && @editing_level do %>
          <.input
            field={@child_stop_form[:level_id]}
            id="child-stop-level-id-select"
            type="select"
            label="Level"
            options={
              Enum.map(@all_levels, fn level ->
                {"#{level.level_name || level.level_id} (#{trunc(level.level_index)})",
                 level.level_id}
              end)
            }
          />
        <% else %>
          <.input
            field={@child_stop_form[:level_id]}
            id="child-stop-level-id-hidden"
            type="hidden"
            value={@current_level_id}
          />
          <div class="grid gap-1.5">
            <span class="text-[13px] font-[650] text-default">Level</span>
            <div class="flex min-h-11 items-center justify-between gap-3 rounded-control bg-canvas px-3 text-sm">
              <span>{@current_level_display}</span>
              <button
                :if={@selected_stop_id != nil}
                type="button"
                class="inline-flex min-h-11 items-center px-1 text-[13px] font-[650] text-action hover:underline"
                phx-click="toggle_level_edit"
              >
                Change
              </button>
            </div>
          </div>
        <% end %>

        <.form_section title="GTFS details">
          <%= if @stop_id_mode == :auto && @is_new_stop do %>
            <div class="grid gap-1.5">
              <span class="text-[13px] font-[650] text-default">Stop ID</span>
              <p class="flex min-h-11 items-center rounded-control bg-canvas px-3 font-mono text-[13px]">
                {if @child_stop_form[:stop_id].value in [nil, ""],
                  do: "Type a name above",
                  else: @child_stop_form[:stop_id].value}
              </p>
              <.input field={@child_stop_form[:stop_id]} type="hidden" />
              <p class="text-[13px] text-muted">
                Made from the type and name.
                <button
                  type="button"
                  class="inline-flex min-h-11 items-center px-1 font-[650] text-action hover:underline"
                  phx-click="toggle_stop_id_mode"
                >
                  Set manually
                </button>
              </p>
            </div>
          <% else %>
            <div class="grid gap-1.5">
              <.input
                field={@child_stop_form[:stop_id]}
                type="text"
                label="Stop ID"
                placeholder="e.g., platform-2-01"
                required={@is_new_stop && @stop_id_mode == :manual}
                help={if(!@is_new_stop, do: "Leave blank to make it from the name.")}
              />
              <button
                :if={@is_new_stop}
                type="button"
                class="inline-flex min-h-11 items-center justify-self-start px-1 text-[13px] font-[650] text-action hover:underline"
                phx-click="toggle_stop_id_mode"
              >
                Make it from the name
              </button>
            </div>
          <% end %>

          <div class="grid grid-cols-2 gap-3">
            <.input
              field={@child_stop_form[:stop_lat]}
              type="number"
              label="Latitude (optional)"
              placeholder="e.g., 40.0466"
              step="any"
              min="-90"
              max="90"
            />
            <.input
              field={@child_stop_form[:stop_lon]}
              type="number"
              label="Longitude (optional)"
              placeholder="e.g., -73.9877"
              step="any"
              min="-180"
              max="180"
            />
          </div>
        </.form_section>

        <div
          :if={@selected_stop_id}
          id="remove-from-diagram-section"
          class="grid gap-2 border-t border-subtle pt-5"
        >
          <h3 class="text-base font-bold text-strong">Remove from the plan</h3>
          <p class="text-[13px] text-muted">
            Clears the point's position. The point is kept, but pathways connected to it are deleted.
          </p>
          <.button
            id="remove-from-diagram-button"
            type="button"
            variant="secondary"
            class="min-h-11 justify-self-start"
            phx-click="request_confirmation"
            phx-value-action="remove_from_diagram"
            phx-value-id={@selected_stop_id}
            phx-value-origin="remove-from-diagram-button"
          >
            Remove from plan
          </.button>
        </div>

        <div
          :if={@selected_stop_id}
          id="delete-child-stop-section"
          class="grid gap-2 border-t border-subtle pt-5"
        >
          <h3 class="text-base font-bold text-error-fg">Delete point</h3>
          <p class="text-[13px] text-muted">
            Deletes the point and any pathways connected to it. This can't be undone.
          </p>
          <.button
            id="delete-child-stop-button"
            type="button"
            variant="danger"
            class="min-h-11 justify-self-start"
            phx-click="request_confirmation"
            phx-value-action="delete_child_stop"
            phx-value-id={@selected_stop_id}
            phx-value-origin="delete-child-stop-button"
          >
            Delete point
          </.button>
        </div>
      </.drawer_scroll>

      <.drawer_footer>
        <.button
          id="child-stop-cancel"
          type="button"
          variant="secondary"
          class="min-h-11"
          phx-click="close_drawer"
        >
          Cancel
        </.button>
        <.button id="child-stop-submit" type="submit" class="min-h-11">
          {if @selected_stop_id, do: "Save changes", else: "Create point"}
        </.button>
      </.drawer_footer>
    </.form>
    """
  end

  defp point_type_hint(0), do: "Where riders board a vehicle."
  defp point_type_hint(1), do: "A station inside this station. Rarely needed."
  defp point_type_hint(2), do: "Where riders enter or leave the station."
  defp point_type_hint(4), do: "A spot along a platform where a vehicle stops."
  defp point_type_hint(_), do: "A landing, hallway or other place where paths meet."

  defp level_display_name(_levels, nil), do: "Unassigned"
  defp level_display_name(_levels, ""), do: "Unassigned"

  defp level_display_name(levels, level_id) do
    case Enum.find(levels, fn level -> level.level_id == level_id end) do
      nil -> level_id
      level -> "#{level.level_name || level.level_id} (#{trunc(level.level_index)})"
    end
  end

  defp parse_optional_int(nil), do: nil
  defp parse_optional_int(""), do: nil

  defp parse_optional_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _} -> parsed
      :error -> nil
    end
  end

  defp parse_optional_int(value) when is_integer(value), do: value
  defp parse_optional_int(_), do: nil

  defp pathway_midpoint(x1, y1, x2, y2), do: {(x1 + x2) / 2, (y1 + y2) / 2}

  defp pathway_length(x1, y1, x2, y2) do
    dx = x2 - x1
    dy = y2 - y1
    :math.sqrt(dx * dx + dy * dy)
  end

  defp perpendicular_unit(x1, y1, x2, y2) do
    length = pathway_length(x1, y1, x2, y2)

    if length <= 0.0 do
      {0.0, -1.0}
    else
      dx = x2 - x1
      dy = y2 - y1
      {-dy / length, dx / length}
    end
  end

  # Mode glyph strokes are laid out in the hook, in screen px, from the pathway's
  # midpoint and direction. Each stroke runs `half_along`/`half_perp` px either
  # side of a point `along` px from the midpoint (along the pathway / across it).
  @glyph_bar_spacing 5
  @glyph_bar_half_length 5
  @glyph_cross_half_diagonal 3.5

  defp glyph_bars(x1, y1, x2, y2, count) do
    case glyph_frame(x1, y1, x2, y2) do
      nil ->
        []

      frame ->
        start_offset = -((count - 1) / 2)

        for index <- 0..(count - 1) do
          Map.merge(frame, %{
            along: (start_offset + index) * @glyph_bar_spacing,
            half_along: 0,
            half_perp: @glyph_bar_half_length
          })
        end
    end
  end

  defp glyph_cross(x1, y1, x2, y2) do
    case glyph_frame(x1, y1, x2, y2) do
      nil ->
        []

      frame ->
        [
          Map.merge(frame, %{
            along: 0,
            half_along: @glyph_cross_half_diagonal,
            half_perp: @glyph_cross_half_diagonal
          }),
          Map.merge(frame, %{
            along: 0,
            half_along: @glyph_cross_half_diagonal,
            half_perp: -@glyph_cross_half_diagonal
          })
        ]
    end
  end

  defp glyph_frame(x1, y1, x2, y2) do
    length = pathway_length(x1, y1, x2, y2)

    if length > 0 do
      {mid_x, mid_y} = pathway_midpoint(x1, y1, x2, y2)
      %{mid_x: mid_x, mid_y: mid_y, dir_x: (x2 - x1) / length, dir_y: (y2 - y1) / length}
    end
  end

  defp parallel_offset(x1, y1, x2, y2, offset) do
    {perp_x, perp_y} = perpendicular_unit(x1, y1, x2, y2)

    {
      x1 + perp_x * offset,
      y1 + perp_y * offset,
      x2 + perp_x * offset,
      y2 + perp_y * offset
    }
  end

  # Screen px from the pathway line to the sign text.
  @pathway_label_offset 10.0

  defp label_offset(x1, y1, x2, y2, side) do
    {perp_x, perp_y} = perpendicular_unit(x1, y1, x2, y2)
    {above_x, above_y} = canonical_label_side(perp_x, perp_y)
    distance = @pathway_label_offset

    case side do
      :reverse -> {-above_x * distance, -above_y * distance}
      _ -> {above_x * distance, above_y * distance}
    end
  end

  defp canonical_label_side(perp_x, perp_y) when perp_y < 0, do: {perp_x, perp_y}
  defp canonical_label_side(perp_x, perp_y) when perp_y > 0, do: {-perp_x, -perp_y}
  defp canonical_label_side(perp_x, perp_y) when perp_x > 0, do: {-perp_x, -perp_y}
  defp canonical_label_side(perp_x, perp_y), do: {perp_x, perp_y}

  defp pathway_label_angle_metadata(x1, y1, x2, y2) do
    angle = :math.atan2(y2 - y1, x2 - x1) * 180 / :math.pi()
    {pathway_label_rotation(angle), pathway_label_flipped?(angle)}
  end

  defp pathway_label_flipped?(angle) when angle > 90, do: true
  defp pathway_label_flipped?(angle) when angle < -90, do: true
  defp pathway_label_flipped?(_angle), do: false

  defp direction_indicator(text, :forward, false), do: "#{text} →"
  defp direction_indicator(text, :forward, true), do: "← #{text}"
  defp direction_indicator(text, :reverse, false), do: "← #{text}"
  defp direction_indicator(text, :reverse, true), do: "#{text} →"

  defp pathway_label_rotation(angle) when angle > 90, do: angle - 180
  defp pathway_label_rotation(angle) when angle < -90, do: angle + 180
  defp pathway_label_rotation(angle), do: angle

  # ============================================================================
  # Ruler Drawer (the scale)
  # ============================================================================

  attr :open, :boolean, required: true
  attr :ruler_form, :any, required: true

  def ruler_drawer(assigns) do
    ~H"""
    <.drawer
      id="ruler-drawer"
      chrome="planner"
      open={@open}
      on_close="close_ruler_drawer"
      title="Set the scale"
      initial_focus={:first_field}
      class="max-w-[440px]"
    >
      <:lede>Lengths are measured from the plan once it has a scale.</:lede>
      <.form
        for={@ruler_form}
        id="ruler-form"
        phx-submit="save_ruler"
        class="flex min-h-0 flex-1 flex-col"
      >
        <.drawer_scroll>
          <.input
            field={@ruler_form[:distance_meters]}
            type="number"
            label="Distance between the two points (meters)"
            step="0.01"
            min="0.01"
            required
            help="Measure something you know, such as the width of a corridor. Saving recalculates the length of every pathway on this level."
          />
        </.drawer_scroll>
        <.drawer_footer>
          <.button
            id="ruler-cancel"
            type="button"
            variant="secondary"
            class="min-h-11"
            phx-click="close_ruler_drawer"
          >
            Cancel
          </.button>
          <.button id="ruler-submit" type="submit" class="min-h-11">Save scale</.button>
        </.drawer_footer>
      </.form>
    </.drawer>
    """
  end

  # ============================================================================
  # Pathway Drawer
  # ============================================================================

  attr :open, :boolean, required: true
  attr :pathway_form, :any, required: true
  attr :editing_pathway, :any
  attr :editing_pathway_pair, :list, default: []
  attr :active_pathway_tab, :atom, default: :first
  attr :pathway_form_dirty, :boolean, default: false
  attr :has_scale, :boolean, default: false
  attr :pathway_error, :string, default: nil
  attr :pathway_in_use, :any, default: nil
  attr :history_open_for, :any, default: nil
  attr :history_entries, :list, default: []
  attr :history_state, :atom, default: :idle
  attr :history_filter_form, :any, default: nil
  attr :history_field_filter, :string, default: "all"
  attr :history_zone, :any, default: nil
  attr :history_local_times, :map, default: %{}
  attr :history_today, :any, default: nil
  attr :history_now, :any, default: nil
  attr :rollback_preview, :any, default: nil
  attr :journal_context, :any, default: nil
  attr :drawer_journal_entries, :any, default: nil
  attr :drawer_journal_open_for, :any, default: nil
  attr :drawer_journal_state, :atom, default: :idle
  attr :drawer_journal_total_count, :integer, default: 0
  attr :drawer_journal_loaded_once?, :boolean, default: false
  attr :drawer_journal_refresh_error?, :boolean, default: false
  attr :drawer_journal_error_message, :string, default: nil
  attr :drawer_journal_authors, :map, default: %{}
  attr :drawer_journal_local_times, :map, default: %{}
  attr :drawer_journal_display_zone, :any, default: nil
  attr :drawer_journal_now, :any, default: nil
  attr :drawer_journal_scope, :any, default: nil
  attr :journal_target_counts, :map, default: %{}

  def pathway_drawer(assigns) do
    pathway_id = assigns.editing_pathway && Map.get(assigns.editing_pathway, :id)
    show_history_tabs = assigns.open and not is_nil(pathway_id)

    history_active =
      show_history_tabs and assigns.history_open_for == {"pathway", pathway_id}

    journal_active =
      show_history_tabs and assigns.drawer_journal_open_for == {"pathway", pathway_id}

    {drawer_title, drawer_lede} =
      case assigns.editing_pathway do
        %{from_stop: _, to_stop: _} = pathway ->
          {pathway_row_label(pathway),
           "#{Pathway.mode_label(pathway.pathway_mode)} · #{pathway.pathway_id}"}

        _ ->
          {"Edit pathway", nil}
      end

    assigns =
      assigns
      |> assign(:show_history_tabs, show_history_tabs)
      |> assign(:history_active, history_active)
      |> assign(:journal_active, journal_active)
      |> assign(:pathway_id, pathway_id)
      |> assign(:drawer_title, drawer_title)
      |> assign(:drawer_lede, drawer_lede)
      |> assign(
        :journal_count,
        entity_journal_count(
          journal_active and assigns.drawer_journal_loaded_once?,
          assigns.drawer_journal_total_count,
          assigns.journal_target_counts,
          {"pathway", pathway_id}
        )
      )

    ~H"""
    <.drawer
      id="pathway-drawer"
      chrome="planner"
      open={@open}
      on_close="close_pathway_drawer"
      title={@drawer_title}
      class="max-w-[560px]"
    >
      <:lede :if={@drawer_lede}>{@drawer_lede}</:lede>
      <:header_actions>
        <.unsaved_badge :if={@pathway_form_dirty} id="pathway-dirty-indicator" />
        <div
          :if={@open and length(@editing_pathway_pair) == 2}
          id="pathway-pair-tabs"
          class="inline-flex rounded-control border border-control p-0.5"
        >
          <button
            id="pathway-tab-first"
            type="button"
            phx-click="switch_pathway_tab"
            phx-value-tab="first"
            data-confirm={if @pathway_form_dirty, do: "Discard unsaved pathway changes?"}
            aria-selected={if @active_pathway_tab == :first, do: "true", else: "false"}
            class="inline-flex min-h-10 items-center whitespace-nowrap rounded-[5px] px-3 text-sm font-[650] text-default hover:bg-canvas aria-[selected=true]:bg-selection aria-[selected=true]:text-action"
          >
            First pathway
          </button>
          <button
            id="pathway-tab-second"
            type="button"
            phx-click="switch_pathway_tab"
            phx-value-tab="second"
            data-confirm={if @pathway_form_dirty, do: "Discard unsaved pathway changes?"}
            aria-selected={if @active_pathway_tab == :second, do: "true", else: "false"}
            class="inline-flex min-h-10 items-center whitespace-nowrap rounded-[5px] px-3 text-sm font-[650] text-default hover:bg-canvas aria-[selected=true]:bg-selection aria-[selected=true]:text-action"
          >
            Second pathway
          </button>
        </div>
        <.button
          :if={
            (length(@editing_pathway_pair) == 1 and @editing_pathway) &&
              not Map.get(@editing_pathway, :is_cross_level, false)
          }
          id="add-second-pathway-btn"
          type="button"
          variant="secondary"
          size="sm"
          class="min-h-11"
          phx-click="add_second_pathway"
          data-confirm={if @pathway_form_dirty, do: "Discard unsaved pathway changes?"}
        >
          Add second pathway
        </.button>
      </:header_actions>

      <.history_tab_strip
        :if={@show_history_tabs}
        entity_type="pathway"
        entity_id={@pathway_id}
        history_active={@history_active}
        show_journal={true}
        journal_active={@journal_active}
        journal_count={@journal_count}
      />

      <div
        id="pathway-panel-details"
        role={if @show_history_tabs, do: "tabpanel"}
        aria-labelledby={if @show_history_tabs, do: "pathway-tab-details"}
        hidden={@history_active || @journal_active}
        class="flex min-h-0 flex-1 flex-col"
      >
        <div :if={@open and @journal_context} class="border-b border-subtle px-5 pt-4 sm:px-6">
          <.journal_context_box context={@journal_context} />
        </div>

        <.pathway_form
          :if={@open}
          pathway_form={@pathway_form}
          editing_pathway={@editing_pathway}
          has_scale={@has_scale}
          pathway_error={@pathway_error}
          pathway_in_use={@pathway_in_use}
        />
      </div>

      <div
        id="pathway-panel-history"
        role={if @show_history_tabs, do: "tabpanel"}
        aria-labelledby={if @show_history_tabs, do: "pathway-tab-history"}
        hidden={!@history_active}
        class="min-h-0 flex-1 overflow-y-auto px-5 py-5 sm:px-6"
      >
        <.change_log_list
          :if={@history_active}
          entries={@history_entries}
          entity_type="pathway"
          state={@history_state}
          filter_form={@history_filter_form}
          history_field_filter={@history_field_filter}
          zone={@history_zone}
          local_times={@history_local_times}
          today={@history_today}
          now={@history_now}
          rollback_preview={@rollback_preview}
        />
      </div>

      <div
        :if={@show_history_tabs}
        id="pathway-panel-journal"
        role="tabpanel"
        aria-labelledby="pathway-tab-journal"
        hidden={!@journal_active}
        class="min-h-0 flex-1 overflow-y-auto px-5 py-5 sm:px-6"
      >
        <.entity_journal_panel
          :if={@journal_active}
          entity_type="pathway"
          entity_id={@pathway_id}
          entity_label="pathway"
          journal_entries={@drawer_journal_entries}
          journal_state={@drawer_journal_state}
          journal_entries_exist?={@drawer_journal_total_count > 0}
          journal_error_fallback?={@drawer_journal_refresh_error?}
          journal_scope={@drawer_journal_scope}
          journal_authors={@drawer_journal_authors}
          journal_local_times={@drawer_journal_local_times}
          journal_now={@drawer_journal_now}
        />
      </div>
    </.drawer>
    """
  end

  attr :editing_pathway, :any, required: true
  attr :pathway_form, :any, required: true

  defp pathway_preview(assigns) do
    from_stop = assigns.editing_pathway.from_stop
    to_stop = assigns.editing_pathway.to_stop

    # Read mode, bidirectional, and signage from form values so the preview
    # updates live as the user edits, falling back to the saved pathway.
    form = assigns.pathway_form
    pathway = assigns.editing_pathway

    mode =
      parse_preview_int(form[:pathway_mode] && form[:pathway_mode].value, pathway.pathway_mode)

    bidirectional? =
      case form[:is_bidirectional] && form[:is_bidirectional].value do
        val when val in [true, "true", "1", 1] -> true
        val when val in [false, "false", "0", 0] -> false
        nil -> pathway.is_bidirectional
        _ -> pathway.is_bidirectional
      end

    signposted_as =
      if form[:signposted_as], do: form[:signposted_as].value, else: pathway.signposted_as

    reversed_signposted_as =
      if form[:reversed_signposted_as],
        do: form[:reversed_signposted_as].value,
        else: pathway.reversed_signposted_as

    from_id =
      case from_stop do
        %Stop{} = s -> s.stop_id
        _ -> "?"
      end

    to_id =
      case to_stop do
        %Stop{} = s -> s.stop_id
        _ -> "?"
      end

    from_name =
      case from_stop do
        %Stop{} = s -> s.stop_name || s.stop_id
        _ -> "Unknown"
      end

    to_name =
      case to_stop do
        %Stop{} = s -> s.stop_name || s.stop_id
        _ -> "Unknown"
      end

    has_forward_sign? = present_text?(signposted_as)
    has_reverse_sign? = bidirectional? and present_text?(reversed_signposted_as)

    assigns =
      assigns
      |> assign(:mode, mode)
      |> assign(:bidirectional?, bidirectional?)
      |> assign(:from_id, from_id)
      |> assign(:to_id, to_id)
      |> assign(:from_name, from_name)
      |> assign(:to_name, to_name)
      |> assign(:signposted_as, signposted_as)
      |> assign(:reversed_signposted_as, reversed_signposted_as)
      |> assign(:has_forward_sign?, has_forward_sign?)
      |> assign(:has_reverse_sign?, has_reverse_sign?)

    ~H"""
    <div id="pathway-preview" class="rounded-control border border-subtle bg-canvas px-3 py-2">
      <h4 class="mb-0.5 text-[12.5px] font-[650] text-muted">Preview</h4>
      <TransitPresentation.pathway_summary pathway={@editing_pathway} class="mb-2" />
      <svg
        data-pathway-preview="true"
        viewBox="0 0 480 40"
        class="w-full"
        aria-label={"Pathway from #{@from_id} to #{@to_id}"}
      >
        <defs>
          <marker
            id="preview-arrow"
            viewBox="0 0 10 10"
            refX="9"
            refY="5"
            markerWidth="5"
            markerHeight="5"
            orient="auto-start-reverse"
          >
            <path d="M 0 0 L 10 5 L 0 10 z" fill="var(--diagram-pathway-forward)" />
          </marker>
        </defs>

        <%!-- From node --%>
        <g>
          <title>{@from_name}</title>
          <circle cx="14" cy="16" r="5" fill="var(--diagram-active-stop)" />
          <text
            x="0"
            y="32"
            text-anchor="start"
            font-family="Figtree, sans-serif"
            font-size="7"
            fill="var(--diagram-active-stop)"
            font-weight="600"
          >
            {@from_id}
          </text>
        </g>

        <%!-- To node --%>
        <g>
          <title>{@to_name}</title>
          <circle cx="466" cy="16" r="5" fill="var(--diagram-active-stop)" />
          <text
            x="480"
            y="32"
            text-anchor="end"
            font-family="Figtree, sans-serif"
            font-size="7"
            fill="var(--diagram-active-stop)"
            font-weight="600"
          >
            {@to_id}
          </text>
        </g>

        <%!-- Signage above the line --%>
        <text
          :if={@has_forward_sign?}
          x="240"
          y="8"
          text-anchor="middle"
          font-family="Figtree, sans-serif"
          font-size="7"
          fill="var(--color-muted)"
        >
          {@signposted_as} →
        </text>

        <%!-- Pathway line with mode-specific visuals --%>
        {pathway_preview_line(assigns)}

        <%!-- Signage below the line --%>
        <text
          :if={@has_reverse_sign?}
          x="240"
          y="26"
          text-anchor="middle"
          font-family="Figtree, sans-serif"
          font-size="7"
          fill="var(--color-muted)"
        >
          ← {@reversed_signposted_as}
        </text>
      </svg>

      <div class="flex justify-center">
        <.button
          type="button"
          variant="secondary"
          class="min-h-11"
          phx-click="flip_pathway"
          phx-value-id={@editing_pathway.id}
        >
          Flip direction
        </.button>
      </div>
    </div>
    """
  end

  defp parse_preview_int(nil, fallback), do: fallback

  defp parse_preview_int(val, fallback) when is_binary(val) do
    case Integer.parse(val) do
      {int, _} -> int
      :error -> fallback
    end
  end

  defp parse_preview_int(val, _fallback) when is_integer(val), do: val
  defp parse_preview_int(_val, fallback), do: fallback

  defp pathway_preview_line(%{mode: 1} = assigns) do
    ~H"""
    <line
      x1="22"
      y1="16"
      x2="458"
      y2="16"
      stroke="var(--diagram-pathway-forward)"
      stroke-width="1.2"
      marker-start={if @bidirectional?, do: "url(#preview-arrow)", else: nil}
      marker-end="url(#preview-arrow)"
    />
    """
  end

  defp pathway_preview_line(%{mode: 2} = assigns) do
    ~H"""
    <line
      x1="22"
      y1="16"
      x2="458"
      y2="16"
      stroke="var(--diagram-pathway-forward)"
      stroke-width="1.2"
      marker-start={if @bidirectional?, do: "url(#preview-arrow)", else: nil}
      marker-end="url(#preview-arrow)"
    />
    <line x1="240" y1="11" x2="240" y2="21" stroke="var(--diagram-pathway-forward)" stroke-width="1" />
    """
  end

  defp pathway_preview_line(%{mode: 3} = assigns) do
    ~H"""
    <line
      x1="22"
      y1="16"
      x2="458"
      y2="16"
      stroke="var(--diagram-pathway-forward)"
      stroke-width="1.2"
      marker-start={if @bidirectional?, do: "url(#preview-arrow)", else: nil}
      marker-end="url(#preview-arrow)"
    />
    <line x1="236" y1="11" x2="244" y2="21" stroke="var(--diagram-pathway-forward)" stroke-width="1" />
    <line x1="244" y1="11" x2="236" y2="21" stroke="var(--diagram-pathway-forward)" stroke-width="1" />
    """
  end

  defp pathway_preview_line(%{mode: 4} = assigns) do
    ~H"""
    <line
      x1="22"
      y1="16"
      x2="458"
      y2="16"
      stroke="var(--diagram-pathway-forward)"
      stroke-width="1.2"
      marker-start={if @bidirectional?, do: "url(#preview-arrow)", else: nil}
      marker-end="url(#preview-arrow)"
    />
    <line x1="234" y1="11" x2="234" y2="21" stroke="var(--diagram-pathway-forward)" stroke-width="1" />
    <line x1="240" y1="11" x2="240" y2="21" stroke="var(--diagram-pathway-forward)" stroke-width="1" />
    <line x1="246" y1="11" x2="246" y2="21" stroke="var(--diagram-pathway-forward)" stroke-width="1" />
    """
  end

  defp pathway_preview_line(%{mode: 5} = assigns) do
    ~H"""
    <line
      x1="22"
      y1="16"
      x2="215"
      y2="16"
      stroke="var(--diagram-pathway-forward)"
      stroke-width="1.2"
      marker-start={if @bidirectional?, do: "url(#preview-arrow)", else: nil}
    />
    <rect
      x="215"
      y="8"
      width="50"
      height="16"
      rx="2"
      fill="white"
      stroke="var(--diagram-pathway-forward)"
      stroke-width="1"
    />
    <text
      x="240"
      y="16"
      text-anchor="middle"
      dominant-baseline="central"
      font-family="Inter, sans-serif"
      font-size="10"
      fill="var(--diagram-pathway-forward)"
    >
      &#x2195;
    </text>
    <line
      x1="265"
      y1="16"
      x2="458"
      y2="16"
      stroke="var(--diagram-pathway-forward)"
      stroke-width="1.2"
      marker-end="url(#preview-arrow)"
    />
    """
  end

  defp pathway_preview_line(%{mode: 6} = assigns) do
    ~H"""
    <line
      x1="22"
      y1="14"
      x2="458"
      y2="14"
      stroke="var(--diagram-pathway-forward)"
      stroke-width="1"
      marker-start={if @bidirectional?, do: "url(#preview-arrow)", else: nil}
      marker-end="url(#preview-arrow)"
    />
    <line x1="22" y1="18" x2="458" y2="18" stroke="var(--diagram-pathway-forward)" stroke-width="1" />
    """
  end

  defp pathway_preview_line(%{mode: 7} = assigns) do
    ~H"""
    <line
      x1="22"
      y1="14"
      x2="458"
      y2="14"
      stroke="var(--diagram-pathway-forward)"
      stroke-width="1"
      marker-start={if @bidirectional?, do: "url(#preview-arrow)", else: nil}
      marker-end="url(#preview-arrow)"
    />
    <line x1="22" y1="18" x2="458" y2="18" stroke="var(--diagram-pathway-forward)" stroke-width="1" />
    """
  end

  defp pathway_preview_line(assigns) do
    ~H"""
    <line
      x1="22"
      y1="16"
      x2="458"
      y2="16"
      stroke="var(--diagram-pathway-forward)"
      stroke-width="1.2"
      marker-start={if @bidirectional?, do: "url(#preview-arrow)", else: nil}
      marker-end="url(#preview-arrow)"
    />
    """
  end

  attr :id, :string, required: true
  attr :refusal, :any, required: true

  # AC-12: the shared refusal for a deletion the closure guard refused. It
  # renders inside the surface that owns the action — the pathway drawer or the
  # child-stop drawer — keeps that surface and its values open, and links each
  # blocked pathway to its exact closures filter. `phx-mounted` moves focus to
  # the explanation when it appears; dismissing the confirmation returns focus to
  # the trigger afterwards.
  defp deletion_refusal(assigns) do
    ~H"""
    <.message
      id={@id}
      kind="error"
      title={@refusal.title}
      tabindex="-1"
      phx-mounted={JS.focus()}
    >
      <p class="m-0">{@refusal.body}</p>
      <ul :if={@refusal.links != []} class="m-0 mt-1 grid list-none gap-1 p-0">
        <li :for={{link, index} <- Enum.with_index(@refusal.links)}>
          <.link
            id={"#{@id}-#{index}"}
            href={link.href}
            data-pathway-id={link.pathway_id}
            class="inline-flex min-h-11 items-center font-semibold underline underline-offset-2"
          >
            {link.label}
            <span :if={link.detail} class="ml-1.5 font-mono text-[13px] font-normal">
              {link.detail}
            </span>
          </.link>
        </li>
      </ul>
    </.message>
    """
  end

  attr :pathway_form, :any, required: true
  attr :editing_pathway, :any
  attr :has_scale, :boolean, default: false
  attr :pathway_error, :string, default: nil
  attr :pathway_in_use, :any, default: nil

  defp pathway_form(assigns) do
    # Build pathway mode options using Pathway module functions
    pathway_mode_options =
      Pathway.pathway_modes()
      |> Enum.sort_by(fn {_name, mode_value} -> mode_value end)
      |> Enum.map(fn {_name, mode_value} ->
        {Pathway.mode_label(mode_value), to_string(mode_value)}
      end)

    {from_name, to_name} =
      case assigns.editing_pathway do
        %{from_stop: from, to_stop: to} -> {pathway_stop_display(from), pathway_stop_display(to)}
        _ -> {"the start", "the destination"}
      end

    assigns =
      assigns
      |> assign(:pathway_mode_options, pathway_mode_options)
      |> assign(:from_name, from_name)
      |> assign(:to_name, to_name)
      |> assign(:exit_gate?, to_string(assigns.pathway_form[:pathway_mode].value) == "7")

    ~H"""
    <.form
      for={@pathway_form}
      id="pathway-form"
      phx-submit="save_pathway"
      phx-change="pathway_form_changed"
      class="flex min-h-0 flex-1 flex-col"
    >
      <.drawer_scroll>
        <%!-- ID is hidden as it's auto-managed or readonly --%>
        <.input field={@pathway_form[:pathway_id]} type="hidden" />
        <.deletion_refusal
          :if={@pathway_in_use}
          id="pathway-in-use-error"
          refusal={@pathway_in_use}
        />
        <.message :if={@pathway_error} id="pathway-form-error" kind="error" title={@pathway_error} />

        <.pathway_preview
          :if={@editing_pathway}
          editing_pathway={@editing_pathway}
          pathway_form={@pathway_form}
        />

        <.input
          field={@pathway_form[:pathway_mode]}
          type="select"
          label="Type"
          options={@pathway_mode_options}
          required
          help="Walkway, stairs, elevator, gate or another way through."
        />

        <.input
          field={@pathway_form[:is_bidirectional]}
          type="checkbox"
          label="Both ways: riders can use it in either direction"
          disabled={@exit_gate?}
          help={if @exit_gate?, do: "Exit gates are one-way."}
        />

        <.form_section title="Measurements" first?>
          <div class="grid gap-5 sm:grid-cols-2">
            <.input
              field={@pathway_form[:traversal_time]}
              type="number"
              label="Travel time (seconds)"
              step="1"
              min="0"
              help="Average time to get through."
            />

            <div class="grid content-start gap-1">
              <.input
                field={@pathway_form[:length]}
                type="number"
                label="Length (meters)"
                step="0.01"
                min="0"
                help="Horizontal length."
              />
              <button
                :if={
                  @has_scale and @editing_pathway != nil and
                    blank_pathway_length_value?(@pathway_form[:length].value)
                }
                type="button"
                class="inline-flex min-h-11 items-center justify-self-start text-[13px] font-[650] text-action hover:underline"
                phx-click="calculate_pathway_length"
              >
                Calculate length?
              </button>
            </div>
          </div>

          <.input
            field={@pathway_form[:min_width]}
            type="number"
            label="Minimum width (meters, optional)"
            step="0.01"
            min="0"
            placeholder="Not specified"
            help="Recommended if narrower than 1 meter."
          />

          <.input
            :if={@pathway_form[:pathway_mode].value == "2"}
            field={@pathway_form[:stair_count]}
            type="number"
            label="Number of steps"
            step="1"
            min="0"
            help="Up is positive."
          />
        </.form_section>

        <.form_section title="Signs">
          <.input
            field={@pathway_form[:signposted_as]}
            type="text"
            label={"Sign text toward #{@to_name}"}
            help="What signs say on the way there."
          />

          <.input
            :if={truthy_input_value?(@pathway_form[:is_bidirectional].value)}
            field={@pathway_form[:reversed_signposted_as]}
            type="text"
            label={"Sign text toward #{@from_name}"}
            help="What signs say on the way back."
          />
        </.form_section>

        <div :if={@editing_pathway} class="grid gap-2 border-t border-subtle pt-5">
          <h3 class="text-base font-bold text-error-fg">Delete pathway</h3>
          <p class="text-[13px] text-muted">This can't be undone.</p>
          <.button
            id="delete-pathway-button"
            type="button"
            variant="danger"
            class="min-h-11 justify-self-start"
            phx-click="request_confirmation"
            phx-value-action="delete_pathway"
            phx-value-id={@editing_pathway.id}
            phx-value-origin="delete-pathway-button"
          >
            Delete pathway
          </.button>
        </div>
      </.drawer_scroll>

      <.drawer_footer>
        <.button
          id="pathway-cancel"
          type="button"
          variant="secondary"
          class="min-h-11"
          phx-click="close_pathway_drawer"
        >
          Cancel
        </.button>
        <.button id="pathway-submit" type="submit" class="min-h-11">Save changes</.button>
      </.drawer_footer>
    </.form>
    """
  end

  defp blank_pathway_length_value?(nil), do: true

  defp blank_pathway_length_value?(value) when is_binary(value) do
    String.trim(value) == ""
  end

  defp blank_pathway_length_value?(_value), do: false

  defp truthy_input_value?(value) when value in [true, "true", 1, "1"], do: true
  defp truthy_input_value?(_value), do: false

  # ============================================================================
  # Level Sidebar
  # ============================================================================

  attr :show_level_modal, :atom
  attr :level_form, :any, required: true
  attr :available_levels, :list, default: []
  attr :level_mode, :atom, default: :existing
  attr :editing_level_uuid, :string, default: nil
  attr :level_shared, :boolean, default: false
  attr :history_open_for, :any, default: nil
  attr :history_entries, :list, default: []
  attr :history_state, :atom, default: :idle
  attr :history_filter_form, :any, default: nil
  attr :history_field_filter, :string, default: "all"
  attr :history_zone, :any, default: nil
  attr :history_local_times, :map, default: %{}
  attr :history_today, :any, default: nil
  attr :history_now, :any, default: nil
  attr :rollback_preview, :any, default: nil

  def level_sidebar(assigns) do
    show_history_tabs =
      assigns.show_level_modal == :edit and not is_nil(assigns.editing_level_uuid)

    history_active =
      show_history_tabs and
        assigns.history_open_for == {"level", assigns.editing_level_uuid}

    assigns =
      assigns
      |> assign(:show_history_tabs, show_history_tabs)
      |> assign(:history_active, history_active)

    ~H"""
    <.drawer
      id="level-sidebar"
      chrome="planner"
      open={@show_level_modal != nil}
      on_close="close_level_modal"
      title={if @show_level_modal == :add, do: "Add level", else: "Edit level"}
      class="max-w-[480px]"
    >
      <:lede>A level is a floor of the station, such as Street, Concourse or Platform.</:lede>
      <.history_tab_strip
        :if={@show_history_tabs}
        entity_type="level"
        entity_id={@editing_level_uuid}
        history_active={@history_active}
      />

      <div
        id="level-panel-details"
        role={if @show_history_tabs, do: "tabpanel"}
        aria-labelledby={if @show_history_tabs, do: "level-tab-details"}
        hidden={@history_active}
        class="flex min-h-0 flex-1 flex-col"
      >
        <.level_form
          :if={@show_level_modal}
          level_form={@level_form}
          show_level_modal={@show_level_modal}
          available_levels={@available_levels}
          level_mode={@level_mode}
          editing_level_uuid={@editing_level_uuid}
          level_shared={@level_shared}
        />
      </div>

      <div
        id="level-panel-history"
        role={if @show_history_tabs, do: "tabpanel"}
        aria-labelledby={if @show_history_tabs, do: "level-tab-history"}
        hidden={!@history_active}
        class="min-h-0 flex-1 overflow-y-auto px-5 py-5 sm:px-6"
      >
        <.change_log_list
          :if={@history_active}
          entries={@history_entries}
          entity_type="level"
          state={@history_state}
          filter_form={@history_filter_form}
          history_field_filter={@history_field_filter}
          zone={@history_zone}
          local_times={@history_local_times}
          today={@history_today}
          now={@history_now}
          rollback_preview={@rollback_preview}
        />
      </div>
    </.drawer>
    """
  end

  attr :level_form, :any, required: true
  attr :show_level_modal, :atom, required: true
  attr :available_levels, :list, default: []
  attr :level_mode, :atom, default: :existing
  attr :editing_level_uuid, :string, default: nil
  attr :level_shared, :boolean, default: false

  defp level_form(assigns) do
    ~H"""
    <div :if={@show_level_modal == :add} class="border-b border-subtle px-5 py-4 sm:px-6">
      <fieldset id="level-mode-choice" class="grid min-w-0 gap-2">
        <legend class="mb-1 text-[13px] font-[650] text-default">Which level</legend>
        <label
          :for={
            {mode, label, description} <- [
              {"existing", "Use an existing level", "A level that is already in this feed."},
              {"new", "Create a new level", "Name a new floor of this station."}
            ]
          }
          class={[
            "flex cursor-pointer items-start gap-3 rounded-control border border-control bg-white px-4 py-3",
            "has-[:checked]:border-action has-[:checked]:bg-selection",
            "has-[:focus-visible]:outline-2 has-[:focus-visible]:outline-offset-2 has-[:focus-visible]:outline-focus"
          ]}
        >
          <input
            type="radio"
            name="mode"
            class="mt-0.5 size-5 shrink-0 accent-action focus-visible:outline-0"
            checked={@level_mode == String.to_existing_atom(mode)}
            phx-click="level_mode_changed"
            phx-value-mode={mode}
          />
          <span class="min-w-0">
            <span class="block text-sm font-bold text-strong">{label}</span>
            <span class="mt-0.5 block text-[13px] leading-snug text-muted">{description}</span>
          </span>
        </label>
      </fieldset>
    </div>

    <.form
      for={@level_form}
      id="level-form"
      phx-submit="save_level"
      class="flex min-h-0 flex-1 flex-col"
    >
      <.drawer_scroll>
        <.message
          :if={@show_level_modal == :edit && @level_shared}
          kind="info"
          title="This level is shared"
        >
          Changes here apply everywhere it's used, not just this station.
        </.message>

        <%= if @show_level_modal == :add && @level_mode == :existing do %>
          <%= if @available_levels == [] do %>
            <div id="no-available-levels" class="rounded-control bg-canvas p-4 text-center">
              <p class="text-sm font-bold text-strong">
                All levels are already assigned to this station
              </p>
              <p class="mt-1 text-[13px] text-muted">
                Choose "Create a new level" to add a new one.
              </p>
            </div>
          <% else %>
            <.input
              field={@level_form[:existing_level_id]}
              type="select"
              label="Level"
              options={
                Enum.map(
                  @available_levels,
                  &{"#{&1.level_name || &1.level_id} (#{trunc(&1.level_index)})", &1.id}
                )
              }
              prompt="Choose a level…"
              required
            />
          <% end %>
        <% else %>
          <.input
            field={@level_form[:level_name]}
            type="text"
            label="Name (optional)"
            placeholder="e.g., Ground floor"
            phx-change="level_name_changed"
            help="How riders see this floor."
          />

          <.input
            field={@level_form[:level_index]}
            type="number"
            label="Floor number"
            step="1"
            required
            help="0 is ground, negative is below it, positive is above it."
          />

          <.form_section title="GTFS details">
            <.input
              field={@level_form[:level_id]}
              type="text"
              label="Level ID"
              placeholder="e.g., STATION_GROUND_FLOOR"
              phx-blur="level_id_changed"
              help="Made from the name unless you enter one."
            />
          </.form_section>
        <% end %>

        <div
          :if={@show_level_modal == :edit && @editing_level_uuid}
          class="grid gap-2 border-t border-subtle pt-5"
        >
          <h3 class="text-base font-bold text-strong">Remove from this station</h3>
          <p class="text-[13px] text-muted">
            Unassigns every point on this level and removes its floorplan. The level itself is not deleted.
          </p>
          <.button
            id="remove-level-from-station-button"
            type="button"
            variant="secondary"
            class="min-h-11 justify-self-start"
            phx-click="request_confirmation"
            phx-value-action="remove_level_from_station"
            phx-value-id={@editing_level_uuid}
            phx-value-origin="remove-level-from-station-button"
          >
            Remove level
          </.button>
        </div>
      </.drawer_scroll>

      <.drawer_footer>
        <.button
          id="level-cancel"
          type="button"
          variant="secondary"
          class="min-h-11"
          phx-click="close_level_modal"
        >
          Cancel
        </.button>
        <.button id="level-submit" type="submit" class="min-h-11">
          {if @show_level_modal == :add, do: "Add level", else: "Save changes"}
        </.button>
      </.drawer_footer>
    </.form>
    """
  end

  # ============================================================================
  # Naming Drawer (Standardize stop IDs)
  # ============================================================================

  attr :open, :boolean, default: false
  attr :style, :atom, default: :kebab
  attr :preview_rows, :list, default: []
  attr :renamed_stops_count, :integer, default: 0
  attr :updated_pathways_count, :integer, default: 0
  attr :applying?, :boolean, default: false
  attr :error, :string, default: nil
  attr :excluded_ids, :any, default: %MapSet{}

  def naming_drawer(assigns) do
    ~H"""
    <.drawer
      id="naming-drawer"
      chrome="planner"
      open={@open}
      on_close="close_naming_drawer"
      title="Standardize stop IDs"
      return_focus_id="diagram-more-trigger"
      class="max-w-[560px]"
    >
      <:lede>Rename this station's stops to follow one convention. Pathways update to match.</:lede>
      <div class="flex min-h-0 flex-1 flex-col">
        <.drawer_scroll>
          <div
            id="naming-style"
            role="group"
            aria-label="Naming convention"
            class="inline-flex justify-self-start rounded-control border border-control p-0.5"
          >
            <button
              :for={{style, label} <- [{:kebab, "Name-based"}, {:structured, "Structured"}]}
              type="button"
              aria-pressed={to_string(@style == style)}
              phx-click="change_naming_style"
              phx-value-style={style}
              class="inline-flex min-h-10 items-center whitespace-nowrap rounded-[5px] px-3 text-sm font-[650] text-default hover:bg-canvas aria-[pressed=true]:bg-selection aria-[pressed=true]:text-action"
            >
              {label}
            </button>
          </div>

          <div :if={@style == :kebab} class="grid gap-3 text-sm text-default">
            <p>
              Renames child stops using a kebab-case version of each stop's name with a sequence
              number:
            </p>
            <code class="block rounded-control bg-canvas px-3 py-2 font-mono text-[13px]">
              {"{name}-{seq}"}
            </code>
            <dl class="grid gap-1 text-[13px]">
              <div class="flex gap-2">
                <dt class="min-w-[5rem] font-[650] text-strong">name</dt>
                <dd class="text-muted">Stop name, lowercased and hyphenated</dd>
              </div>
              <div class="flex gap-2">
                <dt class="min-w-[5rem] font-[650] text-strong">seq</dt>
                <dd class="text-muted">Two-digit sequence for stops with the same name</dd>
              </div>
            </dl>
          </div>

          <div :if={@style == :structured} class="grid gap-3 text-sm text-default">
            <p>
              Renames child stops using a deterministic convention based on each stop's type,
              highest-priority connected pathway, and level:
            </p>
            <code class="block rounded-control bg-canvas px-3 py-2 font-mono text-[13px]">
              {"{station}_{type}_{feature}_{level}_{seq}"}
            </code>
            <dl class="grid gap-1 text-[13px]">
              <div class="flex gap-2">
                <dt class="min-w-[5rem] font-[650] text-strong">station</dt>
                <dd class="text-muted">Parent station stop_id, slugified</dd>
              </div>
              <div class="flex gap-2">
                <dt class="min-w-[5rem] font-[650] text-strong">type</dt>
                <dd class="text-muted">platform, entrance, node, or boarding</dd>
              </div>
              <div class="flex gap-2">
                <dt class="min-w-[5rem] font-[650] text-strong">feature</dt>
                <dd class="text-muted">
                  Highest-priority pathway mode (elevator, escalator, stairs, etc.) or general
                </dd>
              </div>
              <div class="flex gap-2">
                <dt class="min-w-[5rem] font-[650] text-strong">level</dt>
                <dd class="text-muted">Level ID, slugified (or nolvl)</dd>
              </div>
              <div class="flex gap-2">
                <dt class="min-w-[5rem] font-[650] text-strong">seq</dt>
                <dd class="text-muted">Two-digit sequence within each group</dd>
              </div>
            </dl>
          </div>

          <.message :if={@error} id="naming-error" kind="error" title={@error} />

          <p :if={@preview_rows == [] and is_nil(@error)} class="text-sm text-muted">
            No child stops to rename for this station.
          </p>

          <div :if={@preview_rows != []} class="grid gap-2">
            <h3 class="text-[13px] font-[650] text-default">Preview</h3>
            <div class="max-h-72 overflow-auto rounded-control border border-subtle">
              <table class="w-full table-fixed border-collapse text-left text-[13px]">
                <colgroup>
                  <col class="w-11" />
                  <col class="w-[45%]" />
                  <col />
                </colgroup>
                <thead class="sticky top-0 bg-canvas">
                  <tr>
                    <th scope="col" class="w-11 px-2 py-1.5">
                      <input
                        type="checkbox"
                        class="size-5 accent-action"
                        checked={MapSet.size(@excluded_ids) == 0}
                        aria-label="Select all child stops for renaming"
                        phx-click="toggle_naming_select_all"
                      />
                    </th>
                    <th scope="col" class="px-2 py-1.5 font-[650] text-default">Current ID</th>
                    <th scope="col" class="px-2 py-1.5 font-[650] text-default">New ID</th>
                  </tr>
                </thead>
                <tbody class="divide-y divide-subtle">
                  <tr
                    :for={row <- @preview_rows}
                    id={"naming-row-#{row.old_id}"}
                    class={MapSet.member?(@excluded_ids, row.old_id) && "opacity-40"}
                  >
                    <td class="w-11 px-2 py-1">
                      <input
                        type="checkbox"
                        class="size-5 accent-action"
                        checked={not MapSet.member?(@excluded_ids, row.old_id)}
                        aria-label={"Select #{row.old_id} for renaming"}
                        phx-click="toggle_naming_row"
                        phx-value-id={row.old_id}
                      />
                    </td>
                    <td class="break-all px-2 py-1 font-mono text-xs">{row.old_id}</td>
                    <td class="break-all px-2 py-1 font-mono text-xs">{row.new_id}</td>
                  </tr>
                </tbody>
              </table>
            </div>

            <p class="text-sm text-default">
              <span :if={MapSet.size(@excluded_ids) > 0}>
                <span class="font-medium">{@renamed_stops_count}</span>
                of <span class="font-medium">{length(@preview_rows)}</span>
                child stops selected for renaming.
              </span>
              <span :if={MapSet.size(@excluded_ids) == 0}>
                <span class="font-medium">{@renamed_stops_count}</span>
                {if(@renamed_stops_count == 1, do: "child stop", else: "child stops")} will be renamed.
              </span>
              <span class="font-medium">{@updated_pathways_count}</span>
              {if(@updated_pathways_count == 1, do: "pathway reference", else: "pathway references")}
              {if(MapSet.size(@excluded_ids) > 0,
                do: " will be updated for the selected stops.",
                else: " will be updated."
              )}
            </p>
          </div>
        </.drawer_scroll>

        <.drawer_footer>
          <.button
            id="naming-cancel"
            type="button"
            variant="secondary"
            class="min-h-11"
            phx-click="close_naming_drawer"
          >
            Cancel
          </.button>
          <.button
            id="apply-naming-convention"
            type="button"
            class="min-h-11"
            phx-click="apply_naming_convention"
            phx-disable-with="Renaming…"
            disabled={
              @preview_rows == [] || @applying? || @error ||
                MapSet.size(@excluded_ids) == length(@preview_rows)
            }
          >
            Rename {@renamed_stops_count} {if @renamed_stops_count == 1, do: "point", else: "points"}
          </.button>
        </.drawer_footer>
      </div>
    </.drawer>
    """
  end

  # ============================================================================
  # Side Panel
  # ============================================================================

  # The docked panel beside the plan: the level's points and pathways as lists,
  # and the station journal, under one row of tabs. The tabs carry the only
  # counts on the page. Add point and Connect put a short card of instructions
  # above the lists; Align has no panel.
  attr :mode, :atom, required: true
  attr :active_level, :any, default: nil
  attr :active_level_name, :string, default: ""
  attr :has_diagram, :boolean, default: false
  attr :levels, :list, default: []
  attr :child_stops_list, :list, required: true
  attr :unassigned_child_stops, :list, required: true
  attr :pathways_list, :list, required: true
  attr :active_point_id, :any, default: nil
  attr :panel_tab, :atom, values: [:points, :pathways], default: :points
  attr :list_query, :string, default: ""
  attr :stop_search_form, :any, required: true
  attr :selected_from_stop, :any, default: nil
  attr :journal_scope, :any, default: nil
  attr :journal_entry_count, :integer, default: 0
  attr :journal_panel_open?, :boolean, default: false
  slot :journal, doc: "the station journal, shown while its tab is open"

  def side_panel(assigns) do
    query = assigns.list_query |> to_string() |> String.trim() |> String.downcase()

    points = filter_points(assigns.child_stops_list, query)
    unassigned = filter_points(assigns.unassigned_child_stops, query)
    pathways = filter_pathways(assigns.pathways_list, query)

    selected_tab = if assigns.journal_panel_open?, do: :journal, else: assigns.panel_tab

    assigns =
      assigns
      |> assign(:query, query)
      |> assign(:points, points)
      |> assign(:unassigned, unassigned)
      |> assign(:pathways, pathways)
      |> assign(:selected_tab, selected_tab)
      |> assign(
        :pathway_search_form,
        to_form(%{"list_query" => assigns.list_query}, as: :pathway_search)
      )

    ~H"""
    <aside
      id="side-panel"
      aria-label="Points, pathways and journal"
      class="flex min-h-0 min-w-0 flex-col border-t border-subtle bg-white lg:border-l lg:border-t-0"
    >
      <div
        id="side-panel-tabs"
        role="tablist"
        aria-label={"On #{@active_level_name}"}
        aria-orientation="horizontal"
        phx-hook="TablistHook"
        class="flex shrink-0 border-b border-subtle px-1"
      >
        <.panel_tab
          id="panel-tab-points"
          controls="points-panel"
          label="Points"
          count={length(@child_stops_list)}
          selected?={@selected_tab == :points}
          click="select_panel_tab"
          value="points"
        />
        <.panel_tab
          id="panel-tab-pathways"
          controls="pathways-panel"
          label="Pathways"
          count={length(@pathways_list)}
          selected?={@selected_tab == :pathways}
          click="select_panel_tab"
          value="pathways"
        />
        <.panel_tab
          :if={@journal_scope}
          id="journal-trigger"
          count_id="journal-trigger-count"
          controls="station-journal-panel"
          label="Journal"
          count={@journal_entry_count}
          selected?={@selected_tab == :journal}
          expanded={to_string(@journal_panel_open?)}
          click={if @journal_panel_open?, do: "close_journal", else: "open_journal"}
        />
      </div>

      <.add_point_card :if={@mode == :add} active_level_name={@active_level_name} />
      <.connect_card :if={@mode == :connect} selected_from_stop={@selected_from_stop} />

      <div :if={@journal_panel_open?} class="flex min-h-0 flex-1 flex-col">
        {render_slot(@journal)}
      </div>

      <div
        id="lists-section"
        hidden={@journal_panel_open?}
        class="flex min-h-0 flex-1 flex-col"
      >
        <div
          id="points-panel"
          role="tabpanel"
          aria-labelledby="panel-tab-points"
          hidden={@panel_tab != :points}
          class="min-h-0 flex-1 overflow-y-auto overscroll-contain"
        >
          <.list_search
            :if={@mode == :view}
            id="stop-search-form"
            form={@stop_search_form}
            input_id="stop-id-search"
            input_name="stop_id_query"
            submit="search_stop"
            query={@list_query}
            what="point"
          />
          <.points_list
            points={@points}
            unassigned={@unassigned}
            all_points={@child_stops_list}
            unassigned_all={@unassigned_child_stops}
            query={@list_query}
            active_point_id={@active_point_id}
            active_level_name={@active_level_name}
            has_diagram={@has_diagram}
            mode={@mode}
          />
        </div>
        <div
          id="pathways-panel"
          role="tabpanel"
          aria-labelledby="panel-tab-pathways"
          hidden={@panel_tab != :pathways}
          class="min-h-0 flex-1 overflow-y-auto overscroll-contain"
        >
          <.list_search
            :if={@mode == :view and (@pathways_list != [] or @query != "")}
            id="pathway-search-form"
            form={@pathway_search_form}
            input_id="pathway-search"
            input_name="list_query"
            submit="filter_panel_list"
            query={@list_query}
            what="pathway"
          />
          <.pathways_list
            pathways={@pathways}
            all_pathways={@pathways_list}
            query={@list_query}
            active_level={@active_level}
            active_level_name={@active_level_name}
            levels={@levels}
            has_diagram={@has_diagram}
            mode={@mode}
          />
        </div>
      </div>
    </aside>
    """
  end

  attr :id, :string, required: true
  attr :count_id, :string, default: nil
  attr :controls, :string, required: true
  attr :label, :string, required: true
  attr :count, :integer, required: true
  attr :selected?, :boolean, required: true
  attr :click, :string, required: true
  attr :value, :string, default: nil

  attr :expanded, :any,
    default: nil,
    doc: "aria-expanded, for a tab that opens and closes a panel"

  defp panel_tab(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      role="tab"
      phx-click={@click}
      phx-value-tab={@value}
      aria-selected={to_string(@selected?)}
      aria-expanded={@expanded}
      aria-controls={@controls}
      tabindex={if @selected?, do: "0", else: "-1"}
      class={[
        "-mb-px inline-flex min-h-11 items-center gap-1.5 border-b-2 px-3 text-sm font-semibold",
        "focus-visible:outline-2 focus-visible:outline-offset-[-2px] focus-visible:outline-focus",
        if(@selected?,
          do: "border-action text-action",
          else: "border-transparent text-muted hover:border-subtle hover:text-strong"
        )
      ]}
    >
      {@label}
      <span
        id={@count_id}
        class={[
          "rounded-badge px-1.5 text-[12px] tabular-nums",
          if(@selected?, do: "bg-selection text-action", else: "bg-canvas text-default")
        ]}
      >
        {@count}
      </span>
    </button>
    """
  end

  attr :active_level_name, :string, default: ""

  defp add_point_card(assigns) do
    ~H"""
    <div id="add-point-card" class="shrink-0 border-b border-subtle px-3 py-3">
      <h2 class="text-[15px] font-bold text-strong">Add a point</h2>
      <p class="mt-0.5 text-[12.5px] text-muted">On {@active_level_name}. You can move it later.</p>
      <p class="mt-2 text-sm text-default">
        Click the floorplan, then name the point and choose its type.
      </p>
      <p class="mt-3 text-[12.5px] text-muted">
        Can't click the plan? Enter the position instead.
      </p>
      <.button
        id="keyboard-create-stop"
        type="button"
        variant="secondary"
        class="mt-1.5 min-h-11"
        phx-click="open_create_form"
      >
        Enter coordinates
      </.button>
    </div>
    """
  end

  attr :selected_from_stop, :any, default: nil

  defp connect_card(assigns) do
    ~H"""
    <div id="connect-card" class="shrink-0 border-b border-subtle px-3 py-3">
      <h2 class="text-[15px] font-bold text-strong">Connect two points</h2>
      <p class="mt-0.5 text-[12.5px] text-muted">
        Click the start, then the destination. The pathway starts as a two-way walkway you can change.
      </p>
      <ol class="mt-3 divide-y divide-subtle">
        <li class="flex min-h-11 items-center gap-3 py-1.5">
          <span class={[
            "grid size-6 shrink-0 place-items-center rounded-full text-[12.5px] font-bold",
            if(@selected_from_stop,
              do: "bg-cyan-700 text-white",
              else: "bg-selection text-action"
            )
          ]}>
            <.icon :if={@selected_from_stop} name="hero-check" class="size-3.5" />
            <span :if={!@selected_from_stop}>1</span>
          </span>
          <div class="min-w-0 flex-1">
            <p class="text-[12.5px] text-muted">Start</p>
            <p class="truncate text-sm font-[650] text-strong">
              {if @selected_from_stop,
                do: stop_display_name(@selected_from_stop),
                else: "Not chosen yet"}
            </p>
          </div>
          <button
            :if={@selected_from_stop}
            type="button"
            class="inline-flex min-h-11 items-center rounded-control px-2.5 text-sm font-[650] text-action hover:bg-selection"
            phx-click="clear_from_selection"
          >
            Clear
          </button>
        </li>
        <li class="flex min-h-11 items-center gap-3 py-1.5">
          <span class="grid size-6 shrink-0 place-items-center rounded-full bg-selection text-[12.5px] font-bold text-action">
            2
          </span>
          <div class="min-w-0 flex-1">
            <p class="text-[12.5px] text-muted">Destination</p>
            <p class="text-sm font-[650] text-strong">Not chosen yet</p>
          </div>
        </li>
      </ol>
      <p class="mt-2 text-[12.5px] text-muted">
        Two points can have up to two pathways, such as a fare gate in and an exit gate out. The
        new pathway opens for editing so you can set its details.
      </p>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :form, :any, required: true
  attr :input_id, :string, required: true
  attr :input_name, :string, required: true
  attr :submit, :string, required: true
  attr :query, :string, default: ""
  attr :what, :string, required: true

  defp list_search(assigns) do
    ~H"""
    <div class="sticky top-0 z-10 border-b border-subtle bg-white px-3 py-2">
      <.form for={@form} id={@id} phx-change="filter_panel_list" phx-submit={@submit}>
        <div class="relative">
          <.icon
            name="hero-magnifying-glass"
            class="pointer-events-none absolute left-2.5 top-1/2 size-4 -translate-y-1/2 text-muted"
          />
          <input
            type="search"
            id={@input_id}
            name={@input_name}
            value={@query}
            phx-debounce="200"
            autocomplete="off"
            aria-label={"Find a #{@what} by name or ID"}
            placeholder="Find by name or ID"
            class="h-10 w-full rounded-control border border-control bg-white pl-9 pr-3 text-sm text-strong placeholder:text-muted"
          />
        </div>
      </.form>
    </div>
    """
  end

  attr :points, :list, required: true
  attr :unassigned, :list, required: true
  attr :all_points, :list, required: true
  attr :unassigned_all, :list, required: true
  attr :query, :string, default: ""
  attr :active_point_id, :any, default: nil
  attr :active_level_name, :string, default: ""
  attr :has_diagram, :boolean, default: false
  attr :mode, :atom, required: true

  defp points_list(assigns) do
    ~H"""
    <%= cond do %>
      <% @all_points == [] and @unassigned_all == [] -> %>
        <div id="child-stops-empty" class="px-6 py-10 text-center">
          <h3 class="text-[15px] font-bold text-strong">No points on {@active_level_name} yet</h3>
          <p class="mx-auto mt-1.5 max-w-[32ch] text-sm text-muted">
            Points are the places riders pass through: entrances, platforms, and junctions where
            paths meet. {if @has_diagram,
              do: "Add the first point, then connect points with pathways.",
              else: "Upload a floorplan to place them."}
          </p>
          <.button
            :if={@has_diagram and @mode != :add}
            id="empty-add-point"
            type="button"
            class="mt-4 min-h-11"
            phx-click="switch_mode"
            phx-value-mode="add"
          >
            <.icon name="hero-map-pin" class="size-4" /> Add point
          </.button>
        </div>
      <% @points == [] and @unassigned == [] -> %>
        <.no_match what="points" query={@query} />
      <% true -> %>
        <ul
          :if={@points != []}
          id="child-stops-table"
          class="divide-y divide-subtle border-b border-subtle"
        >
          <li :for={stop <- @points} id={"child-stop-row-#{stop.id}"}>
            <.point_row stop={stop} current?={@active_point_id == stop.id} />
          </li>
        </ul>
        <p :if={@points == [] and @query != ""} class="px-3 pt-3 text-sm text-muted">
          No points on {@active_level_name} match "{@query}".
        </p>
        <div :if={@unassigned != []}>
          <h3 class="px-3 pb-0.5 pt-4 text-[12.5px] font-[650] text-muted">
            Not placed on any level
          </h3>
          <ul
            id="unassigned-stops-table"
            class="divide-y divide-subtle border-y border-subtle"
          >
            <li :for={stop <- @unassigned} id={"unassigned-stop-row-#{stop.id}"}>
              <.point_row stop={stop} current?={@active_point_id == stop.id} />
            </li>
          </ul>
        </div>
    <% end %>
    """
  end

  attr :stop, :any, required: true
  attr :current?, :boolean, default: false

  defp point_row(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="edit_child_stop"
      phx-value-id={@stop.id}
      aria-current={@current? && "true"}
      class={[
        "flex min-h-[52px] w-full items-center gap-3 px-3 py-1.5 text-left hover:bg-canvas",
        "focus-visible:outline-2 focus-visible:outline-offset-[-2px] focus-visible:outline-focus",
        @current? && "bg-selection"
      ]}
    >
      <.point_symbol type={@stop.location_type} />
      <span class="min-w-0 flex-1">
        <span class={[
          "block truncate text-sm font-[650]",
          if(@current?, do: "text-action", else: "text-strong")
        ]}>
          {@stop.stop_name || @stop.stop_id}
        </span>
        <span class="block truncate text-[12.5px] text-muted">
          {point_type_label(@stop.location_type)} · <span class="font-mono">{@stop.stop_id}</span>
        </span>
      </span>
      <span
        :if={@stop.wheelchair_boarding == 2}
        class="inline-flex shrink-0 items-center gap-1 text-[12px] font-[650] text-error-fg"
      >
        <.icon name="hero-x-mark" class="size-3.5" /> Not accessible
      </span>
    </button>
    """
  end

  attr :pathways, :list, required: true
  attr :all_pathways, :list, required: true
  attr :query, :string, default: ""
  attr :active_level, :any, default: nil
  attr :active_level_name, :string, default: ""
  attr :levels, :list, default: []
  attr :has_diagram, :boolean, default: false
  attr :mode, :atom, required: true

  defp pathways_list(assigns) do
    ~H"""
    <%= cond do %>
      <% @all_pathways == [] -> %>
        <div id="pathways-empty" class="px-6 py-10 text-center">
          <h3 class="text-[15px] font-bold text-strong">
            No pathways on {@active_level_name} yet
          </h3>
          <p class="mx-auto mt-1.5 max-w-[32ch] text-sm text-muted">
            A pathway is a walkable link between two points: a corridor, stairs, an elevator, a gate.
          </p>
          <.button
            :if={@has_diagram and @mode != :connect}
            id="empty-connect-points"
            type="button"
            class="mt-4 min-h-11"
            phx-click="switch_mode"
            phx-value-mode="connect"
          >
            <.icon name="hero-link" class="size-4" /> Connect points
          </.button>
        </div>
      <% @pathways == [] -> %>
        <.no_match what="pathways" query={@query} />
      <% true -> %>
        <ul id="pathways-table" class="divide-y divide-subtle border-b border-subtle">
          <li :for={pathway <- @pathways} id={"pathway-row-#{pathway.id}"}>
            <button
              type="button"
              phx-click="edit_pathway"
              phx-value-id={pathway.id}
              class={[
                "flex min-h-[52px] w-full items-center gap-3 px-3 py-1.5 text-left hover:bg-canvas",
                "focus-visible:outline-2 focus-visible:outline-offset-[-2px] focus-visible:outline-focus"
              ]}
            >
              <.pathway_symbol mode={pathway.pathway_mode} one_way?={!pathway.is_bidirectional} />
              <span class="min-w-0 flex-1">
                <span class="block truncate text-sm font-[650] text-strong">
                  {pathway_row_label(pathway)}
                </span>
                <span class="block truncate text-[12.5px] text-muted">
                  {pathway_meta(pathway, @active_level, @levels)} ·
                  <span class="font-mono">{pathway.pathway_id}</span>
                </span>
              </span>
            </button>
          </li>
        </ul>
    <% end %>
    """
  end

  attr :what, :string, required: true
  attr :query, :string, required: true

  defp no_match(assigns) do
    ~H"""
    <div class="px-6 py-10 text-center">
      <h3 class="text-[15px] font-bold text-strong">No {@what} match "{@query}"</h3>
      <p class="mx-auto mt-1.5 max-w-[32ch] text-sm text-muted">
        Check the spelling, or clear the search to see every {if @what == "points",
          do: "point",
          else: "pathway"} on this level.
      </p>
      <.button
        type="button"
        variant="secondary"
        class="mt-4 min-h-11"
        phx-click="filter_panel_list"
        phx-value-list_query=""
      >
        Clear search
      </.button>
    </div>
    """
  end

  # What a point is called in the lists and the key: the terms a mapper uses,
  # not the GTFS location types they map to.
  defp point_type_label(0), do: "Platform"
  defp point_type_label(1), do: "Station"
  defp point_type_label(2), do: "Entrance or exit"
  defp point_type_label(4), do: "Boarding spot"
  defp point_type_label(_), do: "Junction"

  defp pathway_row_label(pathway) do
    arrow = if pathway.is_bidirectional, do: "↔", else: "→"
    "#{pathway_stop_display(pathway.from_stop)} #{arrow} #{pathway_stop_display(pathway.to_stop)}"
  end

  defp pathway_meta(pathway, active_level, levels) do
    [
      Pathway.mode_label(pathway.pathway_mode),
      if(pathway.is_bidirectional, do: "both ways", else: "one way"),
      if(pathway.traversal_time, do: "#{pathway.traversal_time} s"),
      if(pathway.length, do: "#{format_decimal(pathway.length)} m"),
      cross_level_meta(pathway, active_level, levels)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp cross_level_meta(pathway, active_level, levels) do
    case cross_level_target_level(pathway, active_level) do
      "—" ->
        nil

      level_id ->
        case Enum.find(levels, &(&1.level_id == level_id)) do
          %{level_name: name} when is_binary(name) and name != "" -> "to #{name}"
          _ -> "to #{level_id}"
        end
    end
  end

  defp filter_points(stops, ""), do: stops

  defp filter_points(stops, query) do
    Enum.filter(stops, fn stop ->
      [stop.stop_name, stop.stop_id, point_type_label(stop.location_type)]
      |> Enum.any?(&matches_query?(&1, query))
    end)
  end

  defp filter_pathways(pathways, ""), do: pathways

  defp filter_pathways(pathways, query) do
    Enum.filter(pathways, fn pathway ->
      [pathway_row_label(pathway), pathway.pathway_id, Pathway.mode_label(pathway.pathway_mode)]
      |> Enum.any?(&matches_query?(&1, query))
    end)
  end

  defp matches_query?(value, query) when is_binary(value),
    do: value |> String.downcase() |> String.contains?(query)

  defp matches_query?(_value, _query), do: false

  defp pathway_stop_display(%Stop{} = stop), do: stop.stop_name || stop.stop_id
  defp pathway_stop_display(_), do: "Unknown"

  defp cross_level_target_level(pathway, active_level) do
    active_level_id = if active_level, do: active_level.level_id, else: nil
    from_level_id = pathway.from_stop && pathway.from_stop.level_id
    to_level_id = pathway.to_stop && pathway.to_stop.level_id

    cond do
      from_level_id in [nil, ""] or to_level_id in [nil, ""] ->
        "—"

      from_level_id == to_level_id ->
        "—"

      active_level_id in [nil, ""] ->
        to_level_id

      from_level_id == active_level_id ->
        to_level_id

      to_level_id == active_level_id ->
        from_level_id

      true ->
        to_level_id
    end
  end

  defp format_decimal(nil), do: nil
  defp format_decimal(%Decimal{} = decimal), do: Decimal.to_string(decimal, :normal)
  defp format_decimal(value), do: to_string(value)

  defp present_text?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_text?(_), do: false

  # The Journal tab must state its count from any tab, so the badge reads the
  # station journal snapshot until the entity panel has loaded its own exact
  # count for this entity.
  defp entity_journal_count(true, loaded_count, _target_counts, _target), do: loaded_count

  defp entity_journal_count(false, _loaded_count, target_counts, target),
    do: Map.get(target_counts, target, 0)
end
