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
  """
  use GtfsPlannerWeb, :html

  @focus_inset "focus-visible:outline-2 focus-visible:outline-offset-[-2px] focus-visible:outline-focus"

  @menu_item "flex min-h-11 w-full items-center rounded-control px-3 text-left text-sm text-strong hover:bg-canvas"

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

  def grid_bar(assigns) do
    assigns = assign(assigns, :selected?, assigns.selected_count > 0)

    ~H"""
    <div
      id="grid-bar"
      data-tone={bar_tone(@selected?, @outcome)}
      class={[
        "sticky bottom-3 z-20 mt-6 rounded-card border px-4 py-2.5 shadow-float",
        if(@selected?, do: "max-w-[980px]", else: "max-w-[760px]"),
        bar_tone_class(@selected?, @outcome)
      ]}
    >
      <%= cond do %>
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

  # `sel` while a selection carries the verbs (the prototype's selection bar),
  # `idle` with the hint, and the outcome's own tone otherwise.
  defp bar_tone(true, _outcome), do: "sel"
  defp bar_tone(false, nil), do: "idle"
  defp bar_tone(false, %{tone: :warning}), do: "warn"
  defp bar_tone(false, %{tone: :info}), do: "info"

  defp bar_tone_class(true, _outcome), do: "border-action bg-selection"
  defp bar_tone_class(false, nil), do: "border-subtle bg-white"

  defp bar_tone_class(false, %{tone: :warning}),
    do: "border-warning-line bg-warning-bg text-warning-fg"

  defp bar_tone_class(false, %{tone: :info}), do: "border-cyan-700/40 bg-soft text-cyan-800"

  defp outcome_text_class(:warning), do: "text-warning-fg"
  defp outcome_text_class(_tone), do: "text-cyan-800"

  defp outcome_icon(:warning), do: "hero-exclamation-triangle"
  defp outcome_icon(_tone), do: "hero-check-circle"

  defp focus_inset, do: @focus_inset

  defp menu_item_class, do: @menu_item

  defp trip_count(1), do: "1 trip"
  defp trip_count(count), do: "#{count} trips"
end
