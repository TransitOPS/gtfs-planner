defmodule GtfsPlannerWeb.Gtfs.ScheduleChangeComponents do
  @moduledoc """
  The Schedules page's change surface: the sticky grid bar under the timetable.

  The bar is always present, the design system's always-present grid-bar
  pattern: with nothing selected and no outcome it reads its hint, after a write
  it reports what changed with Undo, and while trips are selected it carries the
  bulk verbs. It sticks to the bottom of the viewport, so a page of hundreds of
  trips keeps its actions in reach.

  While the bar holds the page's one primary action (Shift times) the scope
  bar's Add trips steps back to secondary (the design system's hand-off), so the
  page never shows two primaries. The bar is 760 px wide as a message and 980 px
  while it carries the selection verbs, the prototype's proposed extension over
  the design system's 760 px maximum: four verbs plus Delete and Clear stay on
  one row.

  The module also owns the frequency windows editor the trip drawers render
  (R8): the From / Until / Every rows with their departures sentences and inline
  validation, and the "What riders see" choice with its headway note.
  """
  use GtfsPlannerWeb, :html

  import GtfsPlannerWeb.PlannerComponents, only: [message: 1, drawer_scroll: 1, drawer_footer: 1]

  alias GtfsPlanner.Gtfs.GtfsTime
  alias GtfsPlanner.Gtfs.Schedules.FrequencyWindows
  alias GtfsPlanner.Gtfs.Schedules.TimeEntry
  alias GtfsPlannerWeb.Gtfs.ScheduleComponents

  @focus_inset "focus-visible:outline-2 focus-visible:outline-offset-[-2px] focus-visible:outline-focus"

  @menu_item "flex min-h-11 w-full items-center rounded-control px-3 text-left text-sm text-strong hover:bg-canvas"

  # The Shift strip's minutes chips, in the reference's order.
  defp shift_minutes, do: [1, 2, 5, 10, 15, 60]

  @doc """
  Renders the sticky grid bar.

  The selection verbs and the outcome share the bar: a nudge keeps its
  selection, so the outcome takes a line above the verbs separated by a rule. An
  outcome without a selection takes the bar on its own, in the tone the write
  reported (info on the design system's soft cyan, a warning on the warning
  ground). Undo appears only for an outcome that is undoable and follows the
  server's stack; it is disabled while the stack is empty.

  The verbs post the events the LiveView owns: `open_change` opens a strip,
  drawer or dialog with the kind, `copy_trips` fills the clipboard, and the
  existing `delete_selected` and `clear_selection` keep the bulk delete and the
  selection reset.
  """
  attr :selected_count, :integer, required: true
  attr :outcome, :map, default: nil, doc: "the last write: `%{tone, text, undo?}`"
  attr :undo_stack, :list, required: true
  attr :change, :map, default: nil, doc: "the open reviewed change, when one is"
  attr :strip, :map, default: nil, doc: "the docked strip's loaded view data"
  attr :version_name, :string, default: nil

  def grid_bar(assigns) do
    assigns =
      assigns
      |> assign(:selected?, assigns.selected_count > 0)
      |> assign(:stripped?, change_strip?(assigns.change))

    ~H"""
    <div
      id="grid-bar"
      data-tone={bar_tone(@stripped?, @selected?, @outcome)}
      class={[
        "sticky bottom-3 z-30 mt-6 rounded-card border px-4 py-2.5 shadow-float",
        bar_width_class(@stripped?, @selected?),
        bar_tone_class(@stripped?, @selected?, @outcome)
      ]}
    >
      <%= cond do %>
        <% @stripped? -> %>
          <.change_strip change={@change} strip={@strip} version_name={@version_name} />
        <% @selected? -> %>
          <.outcome_line :if={@outcome} outcome={@outcome} undo_stack={@undo_stack} stacked? />
          <div class="flex flex-wrap items-center gap-x-2 gap-y-2">
            <p id="selection-count" class="mr-2 font-bold tabular-nums text-action">
              {trip_count(@selected_count)} selected
            </p>
            <.button
              id="bulk-shift"
              type="button"
              variant="primary"
              class="min-h-11"
              phx-click="open_change"
              phx-value-kind="shift"
            >
              Shift times
            </.button>
            <.button
              id="bulk-timing"
              type="button"
              variant="secondary"
              class="min-h-11"
              phx-click="open_change"
              phx-value-kind="timing"
            >
              Change timing
            </.button>
            <.button
              id="bulk-copy"
              type="button"
              variant="secondary"
              class="min-h-11"
              phx-click="open_change"
              phx-value-kind="copy"
            >
              Copy to calendar
            </.button>
            <div class="relative">
              <button
                id="bulk-more"
                type="button"
                popovertarget="bulk-menu"
                style="anchor-name: --bulk-menu"
                aria-haspopup="menu"
                class={[
                  "inline-flex min-h-11 items-center justify-center gap-1.5 rounded-control border border-control bg-white px-3 text-sm font-[650] text-strong hover:bg-canvas",
                  focus_inset()
                ]}
              >
                More <.icon name="hero-chevron-down" class="size-4" />
              </button>
              <div
                id="bulk-menu"
                popover="auto"
                role="menu"
                aria-label="More actions for the selected trips"
                style={
                  "inset: auto; position-anchor: --bulk-menu; bottom: anchor(top);" <>
                    " left: anchor(left); margin: 0 0 0.25rem 0;" <>
                    " position-try-fallbacks: flip-block, flip-inline;"
                }
                class="w-64 rounded-card border border-subtle bg-white p-1 text-left shadow-float"
              >
                <button
                  id="bulk-move"
                  type="button"
                  role="menuitem"
                  popovertarget="bulk-menu"
                  popovertargetaction="hide"
                  phx-click="open_change"
                  phx-value-kind="move"
                  class={[menu_item_class(), focus_inset()]}
                >
                  Change calendar…
                </button>
                <button
                  id="bulk-duplicate"
                  type="button"
                  role="menuitem"
                  popovertarget="bulk-menu"
                  popovertargetaction="hide"
                  phx-click="open_change"
                  phx-value-kind="duplicate"
                  class={[menu_item_class(), focus_inset()]}
                >
                  Duplicate trips…
                </button>
                <button
                  id="bulk-clip"
                  type="button"
                  role="menuitem"
                  popovertarget="bulk-menu"
                  popovertargetaction="hide"
                  phx-click="copy_trips"
                  class={[menu_item_class(), "justify-between", focus_inset()]}
                >
                  Copy trips <kbd>⌘C</kbd>
                </button>
              </div>
            </div>
            <.button
              id="bulk-delete"
              type="button"
              variant="quiet"
              class="min-h-11 border border-error-line bg-white text-error-fg hover:bg-error-bg"
              phx-click="delete_selected"
              phx-disconnected={JS.set_attribute({"disabled", ""})}
              phx-connected={JS.remove_attribute("disabled")}
            >
              <.icon name="hero-trash" class="size-4" /> Delete {trip_count(@selected_count)}
            </.button>
            <.button
              id="clear-selection"
              type="button"
              variant="quiet"
              class="min-h-11 text-strong"
              phx-click="clear_selection"
            >
              Clear selection
            </.button>
          </div>
        <% @outcome -> %>
          <.outcome_line outcome={@outcome} undo_stack={@undo_stack} />
        <% true -> %>
          <p id="grid-bar-message" class="flex min-h-11 items-center gap-2 text-sm text-muted">
            <.icon name="hero-information-circle" class="size-4 shrink-0" />
            Select trips to shift, copy or change them. Press <kbd>?</kbd>
            for keyboard shortcuts.
          </p>
      <% end %>
    </div>
    """
  end

  # The last write's line. Above the verbs it is a rule-separated line in the
  # bar's own pink; alone it is the bar's content at the bar's own 44 px height,
  # so an outcome without an Undo button keeps the same bar as one with it.
  # Undo follows the outcome's own `undo?` and the server's stack, so a refusal
  # never offers an undo it cannot perform.
  attr :outcome, :map, required: true
  attr :undo_stack, :list, required: true
  attr :stacked?, :boolean, default: false

  defp outcome_line(assigns) do
    ~H"""
    <div
      id="grid-bar-outcome"
      class={[
        "flex flex-wrap items-center gap-x-3 text-sm",
        if(@stacked?, do: "mb-2 gap-y-1 border-b border-action/20 pb-2", else: "min-h-11 gap-y-2"),
        outcome_text_class(@outcome.tone)
      ]}
    >
      <.icon
        name={outcome_icon(@outcome.tone)}
        class={["shrink-0", if(@stacked?, do: "size-4", else: "size-5")]}
      />
      <p id="grid-bar-message" class="min-w-0 flex-1">{@outcome.text}</p>
      <.button
        :if={@outcome.undo?}
        id="undo-action"
        type="button"
        variant={if(@stacked?, do: "quiet", else: "secondary")}
        class={["min-h-11", @stacked? && "text-strong"]}
        phx-click="undo"
        disabled={@undo_stack == []}
      >
        <.icon name="hero-arrow-uturn-left" class="size-4" /> Undo
      </.button>
    </div>
    """
  end

  @doc """
  Renders the docked Shift or Change timing strip.

  The strip replaces the bar's selection verbs while a reviewed change is open
  (the prototype's docked action strip). Its controls post `change_params`: the
  Shift strip's direction group posts `later`/`earlier`, its minutes field and
  chips post `minutes`, its "Starting at" select posts `from_position` and the
  timing select posts `timing_id`. The consequence list renders the review's own
  change set with one fixed sentence per tag, the block problems grouped when
  more than two arrive, and the footer carries the commit sentence with Cancel
  and the change's one primary. A stale review replaces the primary with Refresh
  preview behind the changed-elsewhere callout, and a refusal (or an incomplete
  parameter set) renders its reason and disables the primary.
  """
  attr :change, :map, required: true

  attr :strip, :map,
    default: nil,
    doc: "the loaded strip view data (labels, options, preview lines)"

  attr :version_name, :string, default: nil

  def change_strip(assigns) do
    strip = assigns.strip || %{}
    change = assigns.change
    errors = error_lines(change)

    assigns =
      assign(assigns,
        strip: strip,
        kind: change.kind,
        count: strip_count(change),
        preview_lines: strip[:preview_lines] || [],
        consequence_lines: consequence_lines(change, strip),
        warning_lines: warning_lines(change, strip),
        error_lines: errors,
        stale?: change.stale? == true,
        enabled?: enabled?(change, errors)
      )

    ~H"""
    <div
      id={if @kind == :shift, do: "shift-strip", else: "timing-strip"}
      role="group"
      aria-labelledby="strip-title"
      class="grid gap-3"
      phx-mounted={JS.focus(to: strip_focus(@kind))}
    >
      <div class="flex flex-wrap items-baseline gap-x-3">
        <h3 id="strip-title" class="text-base font-bold text-strong">
          {strip_title(@kind)} · {@strip[:who] || trip_count(length(@change.ids))}
        </h3>
        <p class="text-[13px] text-muted">
          The new times show in the timetable in amber until you apply.
        </p>
      </div>

      <.shift_controls :if={@kind == :shift} change={@change} strip={@strip} />
      <.timing_control :if={@kind == :timing} change={@change} strip={@strip} />

      <.message
        :if={@stale?}
        id="strip-stale"
        kind="warning"
        role="alert"
        title="These trips changed after this preview. Nothing was written."
      >
        Refresh the preview to see their current times, then apply again.
      </.message>

      <div id="strip-consequences" class="grid gap-1.5 text-sm">
        <p :for={line <- @preview_lines} class="text-default">{line}</p>
        <p :for={line <- @consequence_lines} class="text-default">{line}</p>
        <div
          :for={line <- @warning_lines}
          class="flex gap-2 border-l-4 border-warning-line bg-warning-bg px-3 py-1.5 text-warning-fg"
        >
          <.icon name="hero-exclamation-triangle" class="mt-0.5 size-4 shrink-0" />
          <span>{line}</span>
        </div>
        <p :for={line <- @error_lines} class="flex gap-2 font-[650] text-error-fg">
          <.icon name="hero-exclamation-triangle" class="mt-0.5 size-4 shrink-0" />
          <span>{line}</span>
        </p>
      </div>

      <div class="flex flex-wrap items-center justify-end gap-3 border-t border-action/20 pt-3">
        <p class="mr-auto text-[13px] text-muted">
          Changes save to {@version_name} right away.
        </p>
        <.button
          id="strip-cancel"
          type="button"
          variant="secondary"
          class="min-h-11"
          phx-click={
            JS.push("cancel_change")
            |> JS.dispatch("timetable-grid:keep-cursor", to: "#schedules-grid")
          }
        >
          Cancel
        </.button>
        <.button
          :if={@stale?}
          id="strip-refresh"
          type="button"
          variant="primary"
          class="min-h-11"
          phx-click={
            JS.push("refresh_change")
            |> JS.dispatch("timetable-grid:keep-cursor", to: "#schedules-grid")
          }
        >
          Refresh preview
        </.button>
        <.button
          :if={not @stale?}
          id="strip-apply"
          type="button"
          variant="primary"
          class="min-h-11"
          phx-click={
            JS.push("apply_change")
            |> JS.dispatch("timetable-grid:keep-cursor", to: "#schedules-grid")
          }
          phx-disable-with={apply_label(@kind)}
          disabled={not @enabled?}
          data-unavailable={not @enabled? || nil}
        >
          {primary_label(@change, @count)}
        </.button>
      </div>
    </div>
    """
  end

  # The Shift strip's controls: the Later/Earlier aria-pressed group, the minutes
  # field with its chips, and "Starting at" for the patterns that offer one. The
  # field posts through the form's `change_params` on blur; the group and the
  # chips post the single value they own, so a re-review never depends on the
  # client re-sending the rest of the command.
  attr :change, :map, required: true
  attr :strip, :map, required: true

  defp shift_controls(assigns) do
    assigns = assign(assigns, :params, assigns.change.params)

    ~H"""
    <.form
      for={%{}}
      as={:change}
      id="strip-form"
      phx-change="change_params"
      phx-submit="change_params"
      class="flex flex-wrap items-end gap-x-4 gap-y-3"
    >
      <div class="flex max-w-full flex-col">
        <span id="shift-direction-label" class="mb-1.5 text-[13px] font-semibold text-strong">
          Direction
        </span>
        <div
          id="shift-direction"
          role="group"
          aria-labelledby="shift-direction-label"
          class="flex max-w-full overflow-x-auto rounded-control border border-control bg-white"
        >
          <button
            :for={{value, label} <- [{"later", "Later"}, {"earlier", "Earlier"}]}
            type="button"
            data-direction={value}
            aria-pressed={to_string(direction_value(@params.direction) == value)}
            phx-click="change_params"
            phx-value-direction={value}
            class={[
              "inline-flex min-h-11 shrink-0 items-center border-l border-control px-3 text-sm text-strong first:border-l-0",
              "hover:bg-canvas aria-pressed:bg-strong aria-pressed:font-bold aria-pressed:text-white",
              focus_inset()
            ]}
          >
            {label}
          </button>
        </div>
      </div>

      <.input
        id="strip-min"
        name="change[minutes]"
        type="text"
        label="Minutes"
        value={@params.minutes}
        inputmode="numeric"
        autocomplete="off"
        spellcheck="false"
        phx-debounce="blur"
        class="w-[84px] input input-lg text-right tabular-nums"
      />

      <div class="flex gap-1">
        <button
          :for={minutes <- shift_minutes()}
          type="button"
          data-minutes={minutes}
          aria-pressed={to_string(@params.minutes == minutes)}
          phx-click="change_params"
          phx-value-minutes={minutes}
          class={[
            "inline-flex h-11 min-w-11 items-center justify-center rounded-control border px-2 text-sm font-[650] tabular-nums",
            chip_class(@params.minutes == minutes),
            focus_inset()
          ]}
        >
          {minutes}
        </button>
      </div>

      <.input
        :if={@strip[:from_options] != [] and @strip[:from_options] != nil}
        id="strip-from"
        name="change[from_position]"
        type="select"
        label="Starting at"
        options={Enum.map(@strip[:from_options], &{&1.label, &1.value})}
        value={@params.from_position || 0}
        class="w-full min-w-[220px] select select-lg"
      />
    </.form>
    """
  end

  # Change timing has one control: the selection's pattern timings. A pattern
  # with no timings renders no select; its refusal sentence is the surface.
  attr :change, :map, required: true
  attr :strip, :map, required: true

  defp timing_control(assigns) do
    ~H"""
    <.form
      for={%{}}
      as={:change}
      id="strip-form"
      phx-change="change_params"
      phx-submit="change_params"
      class="flex flex-wrap items-end gap-x-4 gap-y-3"
    >
      <.input
        :if={@strip[:timing_options] not in [nil, []]}
        id="strip-timing"
        name="change[timing_id]"
        type="select"
        label={@strip[:timing_label] || "Timing"}
        options={@strip[:timing_options]}
        value={@change.params.timing_id}
        class="w-full min-w-[360px] select select-lg"
      />
    </.form>
    """
  end

  @doc "Whether the open change renders as the docked strip."
  def change_strip?(%{kind: kind}) when kind in [:shift, :timing], do: true
  def change_strip?(_change), do: false

  # --- Copy to calendar and Change calendar: the change review drawer ---------

  @doc """
  Renders the Copy to calendar and Change calendar review drawer.

  The design system's change review: a title that repeats the count, a context
  line, the "Preview · not saved" badge, the target service-day select, the copy
  skip choice, three metric cells, the changes table, one card per affected
  service day and a footer that names what the primary will do. The review is the
  drawer's only behavioral input: its inserts name the new trip IDs, its skipped
  and cleared-block notes fill the table, its counts fill the metrics, and its
  refusal consequences disable the primary and raise the error banner. A stale
  review replaces the primary with Refresh preview (FH-33); the refusal's reason
  disables the primary and its status sits in the footer.
  """
  attr :change, :map, required: true
  attr :drawer, :map, required: true
  attr :version_name, :string, default: nil

  def change_review_drawer(assigns) do
    change = assigns.change
    drawer = assigns.drawer
    change_set = reviewed_change_set(change)
    count = review_count(change, drawer, change_set)
    refusal = review_refusal(change, drawer.to)
    skip? = Map.get(change.params, :skip_existing, true) != false

    assigns =
      assign(assigns,
        kind: change.kind,
        copy?: change.kind == :copy,
        skip?: skip?,
        rows: review_rows(change, drawer, change_set, refusal != nil),
        metrics: review_metrics(change, change_set, count, refusal != nil),
        cards: review_cards(change, drawer, change_set),
        refusal: refusal,
        stale?: change.stale? == true,
        count: count,
        title: review_title(change.kind, length(drawer.rows), drawer.to),
        context: "#{drawer.from} → #{drawer.to} · #{assigns.version_name}",
        status: review_status(change.kind, refusal, assigns.version_name),
        skip_help: skip_help(change_set, skip?, drawer.to),
        primary_label: review_primary(change.kind, count),
        apply_label: review_apply_label(change.kind),
        enabled?: refusal == nil and change.stale? != true and count > 0
      )

    ~H"""
    <.drawer
      id="change-review"
      chrome="planner"
      open
      title={@title}
      on_close="cancel_change"
      return_focus_id={@drawer.return_focus_id}
    >
      <:lede>{@context}</:lede>
      <:header_actions>
        <span class="inline-flex items-center rounded-badge bg-warning-bg px-2 py-0.5 text-[13px] font-[650] text-warning-fg">
          Preview · not saved
        </span>
      </:header_actions>

      <.form
        for={%{}}
        as={:change}
        id="review-form"
        phx-change="change_params"
        phx-submit="change_params"
        class="flex min-h-0 flex-1 flex-col"
      >
        <.drawer_scroll>
          <div class="grid gap-4 sm:grid-cols-[minmax(0,280px)_minmax(0,1fr)] sm:items-end">
            <.input
              id="review-target"
              name="change[service_id]"
              type="select"
              label={if @copy?, do: "Copy to", else: "Move to"}
              options={@drawer.target_options}
              value={@change.params[:service_id]}
              class="w-full select select-lg"
            />
            <.input
              :if={@copy?}
              id="review-skip"
              name="change[skip_existing]"
              type="checkbox"
              label="Skip trips that already leave at the same time"
              checked={@skip?}
              help={@skip_help}
            />
          </div>

          <.message
            :if={@refusal}
            id="review-refusal"
            kind="error"
            role="alert"
            title={@refusal.title}
          >
            <%= if @refusal.body do %>
              {@refusal.body}
            <% end %>
          </.message>

          <.message
            :if={@stale?}
            id="review-stale"
            kind="warning"
            role="alert"
            title="These trips changed after this preview. Nothing was written."
          >
            Refresh the preview to see their current times, then apply again.
          </.message>

          <div class="grid grid-cols-3 gap-px overflow-hidden rounded-card border border-subtle bg-subtle">
            <div :for={{label, value} <- @metrics} class="bg-white px-4 py-3">
              <p class="text-[13px] text-muted">{label}</p>
              <p class="mt-0.5 font-display text-[26px] font-semibold leading-none tabular-nums text-strong">
                {value}
              </p>
            </div>
          </div>

          <div class="max-h-[300px] overflow-auto rounded-control border border-subtle">
            <table class="w-full text-sm">
              <thead>
                <tr class="text-left text-[13px] text-default">
                  <th class="border-b border-subtle bg-canvas px-3 py-2 font-[650]">Trip</th>
                  <th class="border-b border-subtle bg-canvas px-3 py-2 text-right font-[650]">
                    Departs
                  </th>
                  <th class="border-b border-subtle bg-canvas px-3 py-2 font-[650]">
                    {if @copy?, do: "New trip ID", else: "Block now → after"}
                  </th>
                  <th
                    :if={@copy?}
                    class="border-b border-subtle bg-canvas px-3 py-2 font-[650]"
                  >
                    Note
                  </th>
                </tr>
              </thead>
              <tbody>
                <tr :for={row <- @rows} class="border-t border-subtle">
                  <td class="px-3 py-2 font-mono text-[12px] text-muted">{row.label}</td>
                  <td class="px-3 py-2 text-right font-[650] tabular-nums text-strong">
                    {row.clock}
                  </td>
                  <td class={["px-3 py-2 text-[12px]", row.third_class]}>{row.third}</td>
                  <td :if={@copy?} class={["px-3 py-2", row.note_class]}>{row.note}</td>
                </tr>
              </tbody>
            </table>
          </div>

          <section
            :for={card <- @cards}
            class="rounded-card border border-subtle px-4 py-3"
          >
            <h4 class="text-sm font-bold text-strong">
              <span :if={card.prefix} class="font-normal text-muted">{card.prefix}</span>
              {card.title}
            </h4>
            <p class="mt-1 text-sm text-default">{card.body}</p>
          </section>
        </.drawer_scroll>

        <.drawer_footer>
          <p id="review-status" class="mr-auto max-w-[340px] text-[13px] text-muted">
            {@status}
          </p>
          <.button
            id="review-cancel"
            type="button"
            variant="secondary"
            class="min-h-11"
            phx-click={
              JS.push("cancel_change")
              |> JS.dispatch("timetable-grid:keep-cursor", to: "#schedules-grid")
            }
          >
            Keep trips
          </.button>
          <.button
            :if={@stale?}
            id="review-refresh"
            type="button"
            variant="primary"
            class="min-h-11"
            phx-click={
              JS.push("refresh_change")
              |> JS.dispatch("timetable-grid:keep-cursor", to: "#schedules-grid")
            }
          >
            Refresh preview
          </.button>
          <.button
            :if={not @stale?}
            id="review-apply"
            type="button"
            variant="primary"
            class="min-h-11"
            phx-click={
              JS.push("apply_change")
              |> JS.dispatch("timetable-grid:keep-cursor", to: "#schedules-grid")
            }
            phx-disable-with={@apply_label}
            disabled={not @enabled?}
            data-unavailable={not @enabled? || nil}
          >
            {@primary_label}
          </.button>
        </.drawer_footer>
      </.form>
    </.drawer>
    """
  end

  # The reviewed change set, or the shapes an absent review renders with.
  defp reviewed_change_set(%{review: %{change_set: change_set}}), do: change_set

  defp reviewed_change_set(_change),
    do: %{updates: [], inserts: [], deletes: [], consequences: []}

  defp reviewed_consequences(%{review: %{change_set: %{consequences: consequences}}}),
    do: consequences

  defp reviewed_consequences(_change), do: []

  # The primary counts what the review will write: the inserts a copy keeps, and
  # every trip a move carries.
  defp review_count(%{kind: :copy}, _drawer, change_set), do: length(change_set.inserts)
  defp review_count(%{kind: :move}, drawer, _change_set), do: length(drawer.rows)

  # The first refusal the review or the apply reported. R9's refusal names the
  # target service day the person chose rather than the raw service IDs, because
  # the drawer is about that service day.
  defp review_refusal(change, to) do
    reviewed =
      for {:error, reason} <- reviewed_consequences(change), do: reason

    applied = for {:error, reason} <- List.wrap(change.refusal), do: reason

    case reviewed ++ applied do
      [] -> nil
      [reason | _rest] -> refusal_copy(reason, to)
    end
  end

  defp refusal_copy({:mixed_service, _details}, to) do
    %{
      title: "#{to} already runs frequency service on this pattern.",
      body:
        "Listed trips can't run on the same days. Convert the frequency service to scheduled trips first."
    }
  end

  defp refusal_copy(reason, _to),
    do: %{title: ScheduleComponents.error_message(reason), body: nil}

  # The reference's three cells: what is written, what the skip choice leaves
  # alone (or the blocks a move leaves) and the block problems the action adds.
  defp review_metrics(%{kind: :copy}, change_set, count, blocked?) do
    [
      {"Trips copied", if(blocked?, do: 0, else: count)},
      {"Skipped", note_count(change_set, :skipped_existing)},
      {"New problems", problem_count(change_set)}
    ]
  end

  defp review_metrics(%{kind: :move}, change_set, count, blocked?) do
    [
      {"Trips move", if(blocked?, do: 0, else: count)},
      {"Leave their block", note_count(change_set, :cleared_block)},
      {"New problems", problem_count(change_set)}
    ]
  end

  defp note_count(change_set, tag) do
    Enum.count(change_set.consequences, &match?({:note, {^tag, _id, _value}}, &1))
  end

  defp problem_count(change_set) do
    for {:warning, {:block_findings, findings}} <- change_set.consequences, reduce: 0 do
      total -> total + length(findings)
    end
  end

  # One table row per selected trip: the copy's new ID and note, or the move's
  # block before and after.
  defp review_rows(%{kind: :copy}, drawer, change_set, blocked?) do
    new_ids = Map.new(change_set.inserts, &{&1.source_id, &1.attrs.trip_id})

    skipped =
      MapSet.new(for {:note, {:skipped_existing, id, _clock}} <- change_set.consequences, do: id)

    Enum.map(drawer.rows, fn row ->
      new_id = Map.get(new_ids, row.trip_id)
      skipped? = MapSet.member?(skipped, row.trip_id)

      %{
        label: row.label,
        clock: row.clock,
        third: new_id || "—",
        third_class: if(new_id, do: "font-mono text-strong", else: "font-mono text-muted"),
        note: copy_note(blocked?, skipped?, new_id),
        note_class: copy_note_class(blocked?, skipped?)
      }
    end)
  end

  defp review_rows(%{kind: :move}, drawer, change_set, _blocked?) do
    after_blocks =
      Map.new(change_set.updates, fn update ->
        {update.trip_id, Map.get(update.fields, :block_id, :kept)}
      end)

    Enum.map(drawer.rows, fn row ->
      {block, cleared?} = block_change(row.block_id, Map.get(after_blocks, row.trip_id))

      %{
        label: row.label,
        clock: row.clock,
        third: block,
        third_class:
          if(cleared?,
            do: "font-[650] tabular-nums text-warning-fg",
            else: "tabular-nums text-default"
          ),
        note: nil,
        note_class: nil
      }
    end)
  end

  defp copy_note(true, _skipped?, _new_id), do: "Not copied"
  defp copy_note(false, true, _new_id), do: "Skipped · already leaves at this time"
  defp copy_note(false, false, nil), do: "Not copied"
  defp copy_note(false, false, _new_id), do: "Starts without a block"

  defp copy_note_class(true, _skipped?), do: "text-muted"
  defp copy_note_class(false, true), do: "text-muted"
  defp copy_note_class(false, false), do: "text-default"

  # A trip with no block answers the column's question with no block, not with
  # "none" (the reference's dash row); a trip that loses its block names it.
  defp block_change(nil, _after), do: {"— → —", false}
  defp block_change(block, :kept), do: {"#{block} → #{block}", false}
  defp block_change(block, nil), do: {"#{block} → none", true}
  defp block_change(block, kept_block), do: {"#{block} → #{kept_block}", false}

  # The reference's one card per service day: the target day says what happens
  # there, and a source day the target shares dates with gets its own card.
  defp review_cards(change, drawer, change_set) do
    [target_card(change, drawer, change_set) | shared_cards(change, drawer, change_set)]
  end

  defp target_card(change, drawer, change_set) do
    %{prefix: nil, title: drawer.to, body: target_card_body(change, drawer, change_set)}
  end

  defp target_card_body(change, drawer, change_set) do
    blocked? = Enum.any?(change_set.consequences, &match?({:error, _reason}, &1))
    cleared = note_count(change_set, :cleared_block)

    cond do
      blocked? ->
        nothing_moved_body(change.kind)

      change.kind == :copy ->
        "Copies start without a block and appear in the Blocks pool for #{drawer.to}. " <>
          "No new timing or block problems."

      cleared > 0 ->
        cleared_block_body(change_set, drawer.to, cleared)

      true ->
        "No new block problems."
    end
  end

  defp nothing_moved_body(:copy), do: "Nothing is added while the frequency service is there."
  defp nothing_moved_body(:move), do: "Nothing is moved while the frequency service is there."

  # R6 clears a moved trip's block when its companion set changes, whether that
  # leaves it carrying the block alone or joins it to another vehicle's work, so
  # the sentence names neither cause alone.
  defp cleared_block_body(change_set, to, count) do
    verb = if count == 1, do: "leaves", else: "leave"
    subject = if count == 1, do: "it wouldn't", else: "they wouldn't"
    pronoun = if count == 1, do: "it goes", else: "they go"
    blocks = Enum.join(cleared_block_names(change_set), ", ")

    "#{trip_count(count)} #{verb} block #{blocks}: #{subject} run with the same trips " <>
      "on #{to}, so #{pronoun} to the unassigned pool on Blocks."
  end

  defp cleared_block_names(change_set) do
    change_set.consequences
    |> Enum.flat_map(fn
      {:note, {:cleared_block, _id, block}} -> [block]
      _consequence -> []
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp shared_cards(change, drawer, change_set) do
    for {:warning, {:shared_dates, _service_id, count}} <- change_set.consequences do
      %{
        prefix: "Also changes · ",
        title: drawer.from,
        body: shared_card_body(change, drawer, count)
      }
    end
  end

  defp shared_card_body(%{kind: :copy}, drawer, count) do
    "#{drawer.from} and #{drawer.to} both run on #{count} dates. " <>
      "On those dates riders would see the originals and the copies. " <>
      "To change which dates each service day covers, use Calendars."
  end

  defp shared_card_body(%{kind: :move}, drawer, count) do
    "#{drawer.from} and #{drawer.to} both run on #{count} dates. " <>
      "On those dates the trips still run. " <>
      "To change which dates each service day covers, use Calendars."
  end

  defp review_title(:copy, count, to), do: "Copy #{trip_count(count)} to #{to}?"
  defp review_title(:move, count, to), do: "Move #{trip_count(count)} to #{to}?"

  defp review_primary(:copy, count), do: "Copy #{trip_count(count)}"
  defp review_primary(:move, count), do: "Move #{trip_count(count)}"

  defp review_apply_label(:copy), do: "Copying…"
  defp review_apply_label(:move), do: "Moving…"

  defp review_status(kind, refusal, _version_name) when is_map(refusal) do
    "Nothing can be #{refusal_verb(kind)} while that frequency service runs on these days."
  end

  defp review_status(kind, nil, version_name) do
    "Nothing changes until you #{commit_verb(kind)}.#{saves_clause(version_name)}"
  end

  defp refusal_verb(:move), do: "moved"
  defp refusal_verb(_kind), do: "added"

  defp commit_verb(:copy), do: "copy"
  defp commit_verb(:move), do: "move"
  defp commit_verb(:paste), do: "paste"
  defp commit_verb(:duplicate), do: "duplicate"

  defp saves_clause(nil), do: ""
  defp saves_clause(version_name), do: " Then it saves to #{version_name} right away."

  # The skip help states what the review already found on the target service day;
  # with the choice off, every selected trip is copied whether or not one is
  # there, so the line answers a question the choice no longer asks.
  defp skip_help(_change_set, false, _to), do: nil

  defp skip_help(change_set, true, to) do
    case note_count(change_set, :skipped_existing) do
      0 -> "None do on #{to}."
      1 -> "1 trip already runs at the same time on #{to}."
      count -> "#{count} trips already run at the same time on #{to}."
    end
  end

  # --- Paste copied trips and Duplicate trips: the change dialog -------------

  @doc """
  Renders the Paste copied trips and Duplicate trips dialog.

  The reference's `#paste-dialog` and `#duplicate-dialog`: the copied trips'
  context line, the service-day select (a paste only, because a duplicate stays
  on the current day, R7), the Times choice — the same times or a new first
  departure the trips keep their spacing from — the skip choice, one result line
  naming the departures that will be added, and one primary. The review is the
  dialog's only behavioral input: its inserts fill the result line and the
  primary's count, its skipped notes fill the skip help, and its refusal raises
  the error banner and disables the primary. A stale review turns the primary
  into Refresh preview (FH-33), and closing the dialog returns focus to the grid.
  """
  attr :change, :map, required: true
  attr :paste, :map, required: true
  attr :version_name, :string, default: nil

  def paste_dialog(assigns) do
    change = assigns.change
    paste = assigns.paste
    change_set = reviewed_change_set(change)
    refusal = review_refusal(change, paste.target_name)
    skip? = Map.get(change.params, :skip_existing, true) != false
    adding = length(change_set.inserts)
    duplicate? = paste.duplicate?
    stale? = change.stale? == true
    enabled? = refusal == nil and adding > 0

    assigns =
      assign(assigns,
        duplicate?: duplicate?,
        prefix: paste.prefix,
        title: "#{paste_verb(duplicate?)} #{trip_count(length(change.ids))}",
        refusal: refusal,
        skip?: skip?,
        skip_help: skip_help(change_set, skip?, paste.target_name),
        result: paste_result(change_set, paste.target_name, refusal),
        stale?: stale?,
        status: review_status(change.kind, refusal, assigns.version_name),
        confirm_id: if(stale?, do: "#{paste.prefix}-refresh", else: "#{paste.prefix}-apply"),
        confirm_label:
          if(stale?,
            do: "Refresh preview",
            else: "#{paste_verb(duplicate?)} #{trip_count(adding)}"
          ),
        pending_label: paste_pending(duplicate?, stale?),
        on_confirm: if(stale?, do: "refresh_change", else: "apply_change"),
        confirm_disabled: not stale? and not enabled?
      )

    ~H"""
    <.confirm_dialog
      id={@paste.dialog_id}
      chrome="planner"
      size="xl"
      open
      title={@title}
      confirm_id={@confirm_id}
      confirm_label={@confirm_label}
      cancel_id={"#{@prefix}-cancel"}
      cancel_label="Cancel"
      pending_label={@pending_label}
      on_confirm={@on_confirm}
      on_cancel="cancel_change"
      confirm_disabled={@confirm_disabled}
      return_focus_id={@paste.return_focus_id}
      described_by={"#{@prefix}-dialog-body"}
      data-initial-focus-id={@paste.initial_focus_id}
    >
      <p id={"#{@prefix}-context"} class="text-[13px] text-muted">{@paste.context}</p>

      <.form
        for={%{}}
        as={:change}
        id={"#{@prefix}-form"}
        phx-change="change_params"
        phx-submit="change_params"
        class="mt-4 grid gap-4"
      >
        <.input
          :if={not @duplicate?}
          id={"#{@prefix}-service"}
          name="change[service_id]"
          type="select"
          label="Service day"
          options={@paste.target_options}
          value={@change.params[:service_id]}
          class="w-full select select-lg"
        />

        <fieldset class="grid gap-2">
          <legend :if={not @duplicate?} class="text-[13px] font-semibold text-strong">Times</legend>

          <label :if={not @duplicate?} class={choice_card_class(@change.params[:mode] == :same)}>
            <input
              type="radio"
              id={"#{@prefix}-same"}
              name="change[mode]"
              value="same"
              checked={@change.params[:mode] == :same}
              class="mt-0.5 size-[18px] shrink-0 accent-[var(--color-action)]"
            />
            <span class="min-w-0">
              <strong class="block text-sm font-[650] text-strong">Same times</strong>
              <small class="mt-0.5 block text-[13px] leading-snug text-default">
                {@paste.same_help}
              </small>
            </span>
          </label>

          <label :if={not @duplicate?} class={choice_card_class(@change.params[:mode] == :at)}>
            <input
              type="radio"
              id={"#{@prefix}-new-time"}
              name="change[mode]"
              value="at"
              checked={@change.params[:mode] == :at}
              class="mt-0.5 size-[18px] shrink-0 accent-[var(--color-action)]"
            />
            <span class="min-w-0">
              <strong class="block text-sm font-[650] text-strong">
                First departure at a new time
              </strong>
              <small class="mt-0.5 block text-[13px] leading-snug text-default">
                The trips keep their spacing.
              </small>
            </span>
          </label>

          <.input
            :if={@duplicate? or @change.params[:mode] == :at}
            id={"#{@prefix}-at"}
            name="change[first_departure]"
            type="text"
            label="First departure at"
            value={@change.params[:first_departure]}
            placeholder="16:30"
            inputmode="numeric"
            autocomplete="off"
            spellcheck="false"
            phx-debounce="blur"
            errors={List.wrap(@paste.time_error)}
            class="w-[140px] input input-lg text-right tabular-nums"
          />
        </fieldset>

        <.input
          id={"#{@prefix}-skip"}
          name="change[skip_existing]"
          type="checkbox"
          label="Skip trips that already leave at the same time"
          checked={@skip?}
          help={@skip_help}
        />

        <.message
          :if={@refusal}
          id={"#{@prefix}-refusal"}
          kind="error"
          role="alert"
          title={@refusal.title}
        >
          <%= if @refusal.body do %>
            {@refusal.body}
          <% end %>
        </.message>

        <.message
          :if={@stale?}
          id={"#{@prefix}-stale"}
          kind="warning"
          role="alert"
          title="These trips changed after this preview. Nothing was written."
        >
          Refresh the preview to see their current times, then apply again.
        </.message>

        <p
          :if={@result}
          id={"#{@prefix}-result"}
          class="rounded-control bg-canvas px-3 py-2 tabular-nums"
        >
          {@result}
        </p>
      </.form>

      <:status>
        <p id={"#{@prefix}-status"} class="mr-auto max-w-[240px] text-[13px] text-muted">
          {@status}
        </p>
      </:status>
    </.confirm_dialog>
    """
  end

  defp paste_verb(true), do: "Duplicate"
  defp paste_verb(false), do: "Paste"

  defp paste_pending(_duplicate?, true), do: "Refreshing…"
  defp paste_pending(true, _stale?), do: "Duplicating…"
  defp paste_pending(false, _stale?), do: "Pasting…"

  # The one result line: the departures the review will add, in clock order. A
  # review with nothing to add (all skipped, incomplete) or with a refusal
  # renders no line; the skip help, the refusal banner and the disabled primary
  # already say why.
  defp paste_result(_change_set, _to, refusal) when is_map(refusal), do: nil

  defp paste_result(change_set, to, _refusal) do
    departures =
      change_set.inserts
      |> Enum.map(&insert_departure/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort()

    case departures do
      [] ->
        nil

      departures ->
        "Adds #{trip_count(length(change_set.inserts))} on #{to}: " <>
          "#{Enum.join(departures, ", ")}. They start without a block."
    end
  end

  defp insert_departure(%{stop_times: [first | _rest]}),
    do: clock_label(first[:departure_time] || first[:arrival_time])

  defp insert_departure(_insert), do: nil

  # --- frequency windows editor -----------------------------------------------

  @doc """
  Renders the frequency windows editor (R8).

  One From / Until / Every row per window with its remove button and, under it,
  the departures sentence `FrequencyWindows.summary/1` produces or the inline
  error `FrequencyWindows.validate/1` implies. Rows carry the drawer's raw text,
  so a typed value renders back exactly as typed, and a row earns its summary
  sentence only while it passes validation: an overlapping window can never read
  as one that saves.

  The times are read with the page's one typed-time grammar (`TimeEntry`), which
  accepts service times past 24:00 (R2). Remove and Add post the drawer's own
  events (`drawer_remove_window` with the row index, `drawer_add_window`); the
  row ids are stable, so the drawer can focus the From input of a window it adds.
  """
  attr :windows, :list,
    required: true,
    doc: "the raw rows to edit, each `%{from:, until:, every:}` of typed text"

  attr :stop_name, :string, default: nil, doc: "the first stop the windows depart from"

  def windows_editor(assigns) do
    assigns = assign(assigns, :rows, window_rows(assigns.windows))

    ~H"""
    <fieldset id="frequency-windows" class="grid gap-3">
      <legend class="mb-1 text-[13px] font-[650] text-default">
        Windows
        <span :if={@stop_name} class="font-normal text-muted">· departures from {@stop_name}</span>
      </legend>
      <p class="-mt-1 text-[13px] leading-snug text-muted">
        Until is the first time with no departure. Windows can touch but not overlap.
      </p>
      <div class="grid grid-cols-[1fr_1fr_1fr_44px] gap-3 text-[13px] font-[650] text-muted">
        <span>From</span>
        <span>Until</span>
        <span>Every</span>
        <span></span>
      </div>
      <div id="win-rows" class="grid gap-3">
        <div
          :for={row <- @rows}
          id={"windows-row-#{row.index}"}
          class="grid grid-cols-[1fr_1fr_1fr_44px] items-start gap-3"
        >
          <input
            id={"windows-#{row.index}-from"}
            name={"drawer[windows][#{row.index}][from]"}
            type="text"
            value={row.from}
            inputmode="numeric"
            autocomplete="off"
            spellcheck="false"
            aria-invalid={to_string(row.errors != [])}
            class={[control_class(), "text-right"]}
          />
          <input
            id={"windows-#{row.index}-until"}
            name={"drawer[windows][#{row.index}][until]"}
            type="text"
            value={row.until}
            inputmode="numeric"
            autocomplete="off"
            spellcheck="false"
            aria-invalid={to_string(row.errors != [])}
            class={[control_class(), "text-right"]}
          />
          <span class="relative min-w-0">
            <input
              id={"windows-#{row.index}-every"}
              name={"drawer[windows][#{row.index}][every]"}
              type="text"
              value={row.every}
              inputmode="numeric"
              autocomplete="off"
              spellcheck="false"
              aria-invalid={to_string(row.errors != [])}
              class={[control_class(), "pr-12 text-right"]}
            />
            <span class="pointer-events-none absolute right-3 top-1/2 -translate-y-1/2 text-[13px] text-muted">
              min
            </span>
          </span>
          <button
            type="button"
            id={"windows-remove-#{row.index}"}
            phx-click="drawer_remove_window"
            phx-value-index={row.index}
            disabled={length(@rows) == 1}
            title="Remove window"
            class={[
              "inline-flex size-11 items-center justify-center rounded-control text-muted",
              "hover:bg-canvas hover:text-error-fg disabled:text-subtle",
              focus_inset()
            ]}
          >
            <.icon name="hero-trash" class="size-4" />
          </button>
          <p
            :if={row.errors != []}
            class="col-span-4 -mt-1 flex gap-1.5 text-[13px] font-[650] text-error-fg"
          >
            <.icon name="hero-exclamation-circle" class="mt-0.5 size-4 shrink-0" />
            <span>{Enum.join(row.errors, " ")}</span>
          </p>
          <p
            :if={row.errors == [] and row.summary}
            class="col-span-4 -mt-1 text-[13px] leading-snug text-muted"
          >
            {row.summary}
          </p>
          <p
            :if={row.warning}
            class="col-span-4 -mt-1 flex gap-1.5 text-[13px] font-[650] text-warning-fg"
          >
            <.icon name="hero-exclamation-triangle" class="mt-0.5 size-4 shrink-0" />
            <span>{row.warning}</span>
          </p>
        </div>
      </div>
      <button
        type="button"
        id="win-add"
        phx-click="drawer_add_window"
        class={[
          "inline-flex min-h-11 items-center gap-1.5 justify-self-start text-sm font-[650] text-action hover:underline",
          focus_inset()
        ]}
      >
        <.icon name="hero-plus" class="size-4" /> Add window
      </button>
    </fieldset>
    """
  end

  @doc """
  Renders the "What riders see" choice the frequency editor shares (R8).

  `exact_times` is the drawer's stored value: `"1"` for each departure time,
  `"0"` for the headway itself, and anything else (a blank stored value) reads
  as the default choice without writing one. While the headway choice is on, the
  longest typed gap earns its note above 10 minutes and its warning above 20:
  riders check a schedule for the first, and trip planners stop showing
  departure times for the second.
  """
  attr :windows, :list, required: true, doc: "the same raw rows the windows editor edits"

  attr :exact_times, :any,
    default: "1",
    doc: "the drawer's stored choice: `\"1\"`, `\"0\"` or blank"

  def riders_see(assigns) do
    exact? = to_string(assigns.exact_times) != "0"

    assigns =
      assigns
      |> assign(:exact?, exact?)
      |> assign(:note, riders_note(not exact?, max_headway_secs(assigns.windows)))

    ~H"""
    <fieldset id="riders-see" class="grid gap-2">
      <legend class="mb-1.5 text-[13px] font-[650] text-default">What riders see</legend>
      <div class="grid gap-2 sm:grid-cols-2">
        <label class={choice_card_class(@exact?)}>
          <input
            type="radio"
            id="riders-each-departure"
            name="drawer[exact_times]"
            value="1"
            checked={@exact?}
            class="mt-0.5 size-[18px] shrink-0 accent-[var(--color-action)]"
          />
          <span class="min-w-0">
            <strong class="block text-sm font-[650] text-strong">Each departure time</strong>
            <small class="mt-0.5 block text-[13px] leading-snug text-default">
              Timetables and trip planners list every departure, like scheduled trips.
            </small>
          </span>
        </label>
        <label class={choice_card_class(not @exact?)}>
          <input
            type="radio"
            id="riders-every-n-minutes"
            name="drawer[exact_times]"
            value="0"
            checked={not @exact?}
            class="mt-0.5 size-[18px] shrink-0 accent-[var(--color-action)]"
          />
          <span class="min-w-0">
            <strong class="block text-sm font-[650] text-strong">Every N minutes</strong>
            <small class="mt-0.5 block text-[13px] leading-snug text-default">
              Riders see “every 10 min” instead of times. For frequent service not held to a schedule.
            </small>
          </span>
        </label>
      </div>
      <.field_note :if={@note} tone={@note.tone}>{@note.text}</.field_note>
    </fieldset>
    """
  end

  # One row's raw text plus everything the editor decides from it: the parsed
  # seconds, the inline errors and, only while the row is valid, its departures
  # sentence and its shorter-than-the-gap warning.
  defp window_rows(windows) do
    rows =
      windows
      |> Enum.with_index()
      |> Enum.map(fn {values, index} ->
        Map.put(window_row(values), :index, index)
      end)

    r8_errors = r8_errors(rows)

    Enum.map(rows, fn row ->
      errors = row_errors(row, Map.get(r8_errors, row.index, []))

      case errors do
        [] ->
          summary = FrequencyWindows.summary(window(row))

          Map.merge(row, %{
            errors: [],
            summary: summary_sentence(summary, row),
            warning: warning_sentence(summary)
          })

        errors ->
          Map.merge(row, %{errors: errors, summary: nil, warning: nil})
      end
    end)
  end

  defp window_row(values) do
    %{
      from: Map.get(values, :from),
      until: Map.get(values, :until),
      every: Map.get(values, :every),
      start_secs: parse_clock(Map.get(values, :from)),
      end_secs: parse_clock(Map.get(values, :until)),
      headway_secs: parse_headway(Map.get(values, :every))
    }
  end

  # `validate/1` reads whole windows only, so a row still missing a time or a gap
  # stays out of it; that row's own error is already on the row.
  defp r8_errors(rows) do
    valid =
      Enum.filter(rows, fn row ->
        is_integer(row.start_secs) and is_integer(row.end_secs) and is_integer(row.headway_secs)
      end)

    case FrequencyWindows.validate(Enum.map(valid, &window/1)) do
      :ok ->
        %{}

      {:error, errors} ->
        ordered = Enum.sort_by(valid, & &1.start_secs)

        Enum.reduce(errors, %{}, fn %{index: index, reason: reason}, acc ->
          row = Enum.at(valid, index)
          message = r8_message(reason, row, ordered)
          Map.update(acc, row.index, [message], &(&1 ++ [message]))
        end)
    end
  end

  defp r8_message(:until_not_after_from, _row, _ordered), do: "Until must be later than From."

  defp r8_message(:invalid_headway, _row, _ordered),
    do: ScheduleComponents.error_message(:invalid_interval)

  defp r8_message(:overlap, row, ordered) do
    case previous_window(row, ordered) do
      nil ->
        "Windows can touch but not overlap."

      previous ->
        "Overlaps #{clock(previous.start_secs)}–#{clock(previous.end_secs)}. " <>
          "Windows can touch but not overlap."
    end
  end

  # `validate/1` reports an overlap on the later of two windows in start order.
  defp previous_window(row, ordered) do
    ordered
    |> Enum.reduce_while(nil, fn candidate, previous ->
      if candidate.index == row.index, do: {:halt, previous}, else: {:cont, candidate}
    end)
  end

  defp row_errors(row, r8_errors) do
    time_errors =
      if is_integer(row.start_secs) and is_integer(row.end_secs),
        do: [],
        else: [ScheduleComponents.error_message(:invalid_time)]

    headway_errors =
      if is_integer(row.headway_secs),
        do: [],
        else: [ScheduleComponents.error_message(:invalid_interval)]

    time_errors ++ headway_errors ++ r8_errors
  end

  defp summary_sentence(summary, row) do
    "#{departures_label(summary.count)} · last #{clock(summary.last_secs)}; " <>
      "the next would be #{clock(summary.next_secs)}#{ends_with_window_clause(row)}."
  end

  # The next departure lands exactly on Until: it belongs to the next window, if
  # any, so the sentence says so (the reference's clause).
  defp ends_with_window_clause(row) do
    if rem(row.end_secs - row.start_secs, row.headway_secs) == 0,
      do: ", when this window ends",
      else: ""
  end

  defp warning_sentence(%{longer_than_window?: true}),
    do: "The gap between departures is longer than this window. Raise Until or lower Every."

  defp warning_sentence(_summary), do: nil

  defp departures_label(1), do: "1 departure"
  defp departures_label(count), do: "#{count} departures"

  defp window(row) do
    %{start_secs: row.start_secs, end_secs: row.end_secs, headway_secs: row.headway_secs}
  end

  # The page's one typed-time grammar (R2): a window time accepts the same
  # readings a grid cell does, including a service time past 24:00.
  defp parse_clock(text) do
    case TimeEntry.parse(text) do
      {:ok, %{secs: secs}} -> secs
      {:error, _reason} -> nil
    end
  end

  # The gap is a whole number of minutes, at least one (R8); anything else is
  # left to the row's own error, so `validate/1` only ever sees whole windows.
  defp parse_headway(text) do
    case text |> to_string() |> String.trim() |> Integer.parse() do
      {minutes, ""} when minutes > 0 -> minutes * 60
      _other -> nil
    end
  end

  defp max_headway_secs(windows) do
    windows
    |> Enum.map(&parse_headway(Map.get(&1, :every)))
    |> Enum.reject(&is_nil/1)
    |> Enum.max(fn -> nil end)
  end

  # The note belongs to the headway choice only; the departure-time choice has
  # nothing to warn about.
  defp riders_note(false, _max_headway_secs), do: nil

  defp riders_note(true, max_headway_secs)
       when is_integer(max_headway_secs) and max_headway_secs > 20 * 60 do
    %{
      tone: :warning,
      text:
        "Gaps over 20 minutes: riders plan around a wait of up to the full gap, and " <>
          "trip planners show no departure times. Choose Each departure time."
    }
  end

  defp riders_note(true, max_headway_secs)
       when is_integer(max_headway_secs) and max_headway_secs > 10 * 60 do
    %{
      tone: :info,
      text:
        "Above 10 minutes, many riders check a schedule before leaving. " <>
          "Each departure time gives them one."
    }
  end

  defp riders_note(_choice?, _max_headway_secs), do: nil

  attr :tone, :atom, required: true, values: [:info, :warning]
  slot :inner_block, required: true

  defp field_note(assigns) do
    ~H"""
    <p class={["mt-1.5 flex items-start gap-2 px-3 py-2 text-[13px] leading-snug", note_class(@tone)]}>
      <.icon name={note_icon(@tone)} class="mt-0.5 size-4 shrink-0" />
      <span>{render_slot(@inner_block)}</span>
    </p>
    """
  end

  defp note_class(:warning), do: "border-l-4 border-warning-line bg-warning-bg text-warning-fg"
  defp note_class(:info), do: "rounded-control bg-info-bg text-info-fg"

  defp note_icon(:warning), do: "hero-exclamation-triangle"
  defp note_icon(:info), do: "hero-information-circle"

  defp control_class do
    "h-11 w-full min-w-0 rounded-control border border-control bg-white px-3 text-sm text-strong tabular-nums placeholder:text-muted " <>
      "aria-[invalid=true]:border-2 aria-[invalid=true]:border-error-fg disabled:bg-canvas disabled:text-muted " <>
      @focus_inset
  end

  defp clock(secs) do
    secs
    |> GtfsTime.format()
    |> String.split(":")
    |> Enum.take(2)
    |> Enum.join(":")
  end

  # The reference's radio choice cards; the chosen card takes the selection tint
  # and the whole card is the radio's label.
  defp choice_card_class(checked?) do
    [
      "flex min-h-11 cursor-pointer items-start gap-3 rounded-card border px-3.5 py-3",
      "has-[:focus-visible]:outline-2 has-[:focus-visible]:outline-offset-2 has-[:focus-visible]:outline-focus",
      if(checked?,
        do: "border-action bg-selection",
        else: "border-control bg-white hover:bg-canvas"
      )
    ]
  end

  defp chip_class(true), do: "border-action bg-white text-action"
  defp chip_class(false), do: "border-subtle bg-white text-strong hover:bg-canvas"

  defp strip_title(:shift), do: "Shift times"
  defp strip_title(:timing), do: "Change timing"

  defp strip_focus(:shift), do: "#strip-min"
  defp strip_focus(:timing), do: "#strip-timing"

  defp apply_label(:shift), do: "Shifting…"
  defp apply_label(:timing), do: "Changing timing…"

  defp direction_value(1), do: "later"
  defp direction_value(-1), do: "earlier"
  defp direction_value(_direction), do: nil

  # The primary counts what it will change: the command's trips for a shift, and
  # the eligible trips the review planned for a timing change.
  defp primary_label(%{kind: :shift, ids: ids}, _count), do: "Shift #{trip_count(length(ids))}"
  defp primary_label(%{kind: :timing}, count), do: "Change timing for #{trip_count(count)}"

  defp strip_count(%{kind: :shift, ids: ids}), do: length(ids)

  defp strip_count(%{kind: :timing, review: %{counts: %{changed: count}}}), do: count

  defp strip_count(%{ids: ids}), do: length(ids)

  # The primary is available only for a clean, current review with something to
  # change. A refusal keeps its review but carries an error, so it disables the
  # primary the same way an apply refusal does.
  defp enabled?(change, errors) do
    change.review != nil and errors == [] and change.stale? != true and strip_count(change) > 0
  end

  defp review_consequences(%{review: %{change_set: %{consequences: consequences}}}),
    do: consequences

  defp review_consequences(_change), do: []

  # The plain lines the reference renders before the warnings: the frequency
  # windows the shift moves and the frequency trips the position shift leaves
  # out, then the block sentence when the shifted trips keep a block.
  defp consequence_lines(change, strip) do
    consequences = review_consequences(change)

    windows_moved_line(consequences) ++
      excluded_frequency_line(consequences) ++
      blocks_kept_line(change, strip)
  end

  defp windows_moved_line(consequences) do
    case consequence_ids(consequences, :windows_moved) do
      [] -> []
      ids -> ["Frequency windows move too (#{service_count(length(ids))})."]
    end
  end

  defp excluded_frequency_line(consequences) do
    count =
      Enum.count(consequences, &match?({:note, {:excluded, _trip_id, :frequency_whole}}, &1))

    if count == 0 do
      []
    else
      ["#{service_count(count)} left out, because frequency service moves as a whole."]
    end
  end

  defp blocks_kept_line(%{kind: :shift}, %{blocks_kept?: true}), do: ["Trips keep their blocks."]
  defp blocks_kept_line(_change, _strip), do: []

  # The warnings the reference groups after the plain lines, in the planner's own
  # order: block problems, the after-midnight note, a same-time departure, the
  # trips that become custom, a timing change's lost custom times and the trips
  # whose stops differ.
  defp warning_lines(change, strip) do
    consequences = review_consequences(change)

    block_lines(consequences) ++
      crosses_midnight_lines(consequences, strip) ++
      duplicate_departure_lines(consequences) ++
      becomes_custom_lines(change, consequences, strip) ++
      loses_custom_times_lines(consequences) ++
      excluded_stops_lines(consequences)
  end

  # More than two block findings collapse to one line naming the blocks, the
  # reference's grouping; one or two keep their own finding.
  defp block_lines(consequences) do
    findings =
      Enum.flat_map(consequences, fn
        {:warning, {:block_findings, added}} when is_list(added) -> added
        _consequence -> []
      end)

    case findings do
      [] -> []
      [finding] -> [block_finding_line(finding)]
      [first, second] -> [block_finding_line(first), block_finding_line(second)]
      many -> [grouped_block_line(many)]
    end
  end

  defp grouped_block_line(findings) do
    blocks =
      findings
      |> Enum.map(&Map.get(&1, :block_id))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()

    "#{length(findings)} blocks get a layover under 5 min or overlap: #{Enum.join(blocks, ", ")}."
  end

  defp block_finding_line(%{code: :overlap, block_id: block_id, detail: %{overlap_secs: secs}}),
    do: "Block #{block_id}: two trips overlap by #{minute_label(secs)}."

  defp block_finding_line(%{code: :short_layover, block_id: block_id, detail: %{gap_secs: secs}}),
    do: "Block #{block_id}: a #{minute_label(secs)} layover is under the 5 min minimum."

  defp block_finding_line(%{code: :repositions, block_id: block_id, detail: %{meters: meters}}),
    do: "Block #{block_id}: a hand-off moves #{meters} m."

  defp block_finding_line(%{code: :frequency_trip, block_id: block_id}),
    do: "Block #{block_id}: frequency service can't join a block."

  defp block_finding_line(%{code: :unplottable, block_id: block_id}),
    do: "Block #{block_id}: a trip has no plottable times."

  defp block_finding_line(%{code: :in_seat_stale, block_id: block_id}),
    do: "Block #{block_id}: an in-seat record needs review."

  defp block_finding_line(%{block_id: block_id}), do: "Block #{block_id} has a new problem."

  defp crosses_midnight_lines(consequences, strip) do
    case consequence_ids(consequences, :crosses_midnight) do
      [] ->
        []

      ids ->
        tail =
          case strip[:calendar_label] do
            label when is_binary(label) -> " and stay on #{label}'s service day"
            _no_calendar -> ""
          end

        ["#{trip_count(length(ids))} would start after midnight (24:00 or later)#{tail}."]
    end
  end

  defp duplicate_departure_lines(consequences) do
    times =
      for {:warning, {:duplicate_departure, _trip_id, time}} <- consequences, do: time

    case Enum.uniq(times) do
      [] ->
        []

      times ->
        [
          "Another trip on this pattern already leaves at " <>
            "#{Enum.map_join(times, ", ", &clock_label/1)}."
        ]
    end
  end

  # The review's departure time is the full stored clock; the strip's copy shows
  # the minute face the timetable shows.
  defp clock_label(time) when is_binary(time) do
    time |> String.split(":") |> Enum.take(2) |> Enum.join(":")
  end

  defp clock_label(time), do: to_string(time)

  defp becomes_custom_lines(change, consequences, strip) do
    case consequence_ids(consequences, :becomes_custom) do
      [] ->
        []

      ids ->
        ["#{trip_count(length(ids))} will have custom times#{custom_stop_clause(change, strip)}"]
    end
  end

  defp custom_stop_clause(%{params: %{from_position: position}}, strip)
       when is_integer(position) do
    case Enum.find(strip[:from_options] || [], &(&1.value == position)) do
      %{stop: stop} when is_binary(stop) ->
        ", because the minutes between stops change at #{stop}."

      _no_stop ->
        "."
    end
  end

  defp custom_stop_clause(_change, _strip), do: "."

  defp loses_custom_times_lines(consequences) do
    case consequence_ids(consequences, :loses_custom_times) do
      [] ->
        []

      ids ->
        [
          "#{trip_count(length(ids))} #{has_or_have(ids)} custom times and #{takes_or_take(ids)} this timing's times."
        ]
    end
  end

  defp excluded_stops_lines(consequences) do
    count = Enum.count(consequences, &match?({:note, {:excluded, _trip_id, :stops_differ}}, &1))

    if count == 0 do
      []
    else
      [
        "#{trip_count(count)}'s stops differ from the pattern and #{left_out_verb(count)} left out."
      ]
    end
  end

  defp has_or_have([_single]), do: "has"
  defp has_or_have(_ids), do: "have"

  defp takes_or_take([_single]), do: "takes"
  defp takes_or_take(_ids), do: "take"

  defp left_out_verb([_single]), do: "is"
  defp left_out_verb(_count), do: "are"

  defp consequence_ids(consequences, tag) do
    for {:note, {^tag, ids}} <- consequences, id <- List.wrap(ids), do: id
  end

  # The errors the reference renders last: the review's own refusals, the apply's
  # refusal, and the incomplete-parameter note. Identical sentences collapse, so
  # a refused apply never shows the same reason twice.
  defp error_lines(change) do
    review_errors =
      for {:error, reason} <- review_consequences(change), do: strip_error(reason)

    refusal_errors = for {:error, reason} <- List.wrap(change.refusal), do: strip_error(reason)

    Enum.uniq(review_errors ++ refusal_errors ++ incomplete_error(change))
  end

  defp incomplete_error(%{kind: :shift, review: nil, refusal: nil}),
    do: ["Enter the minutes to shift by."]

  defp incomplete_error(_change), do: []

  defp strip_error(:negative_time) do
    "A trip would start before 00:00. Nothing can be shifted earlier than the start of the service day."
  end

  defp strip_error(:no_eligible_trips) do
    "None of the selected trips can use this timing. Their stops differ from the pattern."
  end

  defp strip_error(reason), do: ScheduleComponents.error_message(reason)

  defp minute_label(secs), do: "#{round(secs / 60)} min"

  defp service_count(1), do: "1 service"
  defp service_count(count), do: "#{count} services"

  # `sel` while a strip or a selection carries the bar (the prototype's selection
  # bar), `idle` with the hint, and the outcome's own tone otherwise.
  defp bar_tone(true, _selected?, _outcome), do: "sel"
  defp bar_tone(false, true, _outcome), do: "sel"
  defp bar_tone(false, false, nil), do: "idle"
  defp bar_tone(false, false, %{tone: :warning}), do: "warn"
  defp bar_tone(false, false, %{tone: :info}), do: "info"

  # DS bars are 760 px at most. The selection bar carries four verbs plus Delete
  # and Clear, so it takes 980 px; the docked strip takes 1040 px so its controls
  # stay on one row. Both are recorded as proposed DS extensions in the
  # prototype notes.
  defp bar_width_class(true, _selected?), do: "max-w-[1040px]"
  defp bar_width_class(false, true), do: "max-w-[980px]"
  defp bar_width_class(false, false), do: "max-w-[760px]"

  defp bar_tone_class(true, _selected?, _outcome), do: "border-action bg-selection"
  defp bar_tone_class(false, true, _outcome), do: "border-action bg-selection"
  defp bar_tone_class(false, false, nil), do: "border-subtle bg-white"

  defp bar_tone_class(false, false, %{tone: :warning}),
    do: "border-warning-line bg-warning-bg text-warning-fg"

  defp bar_tone_class(false, false, %{tone: :info}),
    do: "border-cyan-700/40 bg-soft text-cyan-800"

  defp outcome_text_class(:warning), do: "text-warning-fg"
  defp outcome_text_class(_tone), do: "text-cyan-800"

  defp outcome_icon(:warning), do: "hero-exclamation-triangle"
  defp outcome_icon(_tone), do: "hero-check-circle"

  defp focus_inset, do: @focus_inset

  defp menu_item_class, do: @menu_item

  defp trip_count(1), do: "1 trip"
  defp trip_count(count), do: "#{count} trips"
end
