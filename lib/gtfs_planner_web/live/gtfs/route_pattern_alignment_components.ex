defmodule GtfsPlannerWeb.Gtfs.RoutePatternAlignmentComponents do
  @moduledoc """
  Server-rendered Alignment task shell (slice A).

  Presents the `Gtfs.alignment_editor/4` read model: workspace header with the
  R9 status badge, the section inspector with per-section status and scope,
  the selected-section detail and the GTFS shape footer. Slice A has no draft
  or map interactivity yet: section selection is server-side, Save stays
  disabled until the draft/save flow lands, and the map pane is an ignored
  container the map hook fills in a later step. No generation control renders
  (CR-10).
  """

  use GtfsPlannerWeb, :html

  attr :alignment, :map, default: nil, doc: "the Gtfs.alignment_editor/4 read model"
  attr :state, :map, required: true, doc: "alignment UI state (selected section first)"
  attr :notice, :atom, default: nil, doc: ":read_only, :out_of_date, :imported_shape or nil"
  attr :dialog_open, :boolean, default: false, doc: "opens the help dialog"
  attr :editable?, :boolean, default: false, doc: "false renders the read-only notice"
  attr :offline?, :boolean, default: false, doc: "kept for later steps; save stays disabled"
  attr :version_name, :string, default: nil, doc: "named in the help dialog scope line"
  attr :organization_name, :string, default: nil, doc: "named in the help dialog scope line"

  attr :delete_dialog, :map,
    default: nil,
    doc: "%{position, from, to} when the delete dialog is open"

  attr :discard_dialog, :any,
    default: nil,
    doc: "non-nil when the alignment discard dialog is open"

  attr :simplify_dialog, :map,
    default: nil,
    doc: "%{position, tolerance} when the simplify dialog is open"

  def alignment_task(assigns) do
    assigns =
      assigns
      |> assign(:visits_by_position, visits_by_position(assigns.alignment))
      |> assign(:selected, selected_section(assigns.alignment, assigns.state))
      |> assign(:dirty_positions, dirty_positions(assigns.state))
      |> assign(:flagged_positions, flagged_positions(assigns.state))
      |> assign(:header_status, header_status(assigns.alignment))
      |> assign(:footer_status, footer_status(assigns.alignment))
      |> assign(:save_title, save_title(assigns.alignment, assigns.editable?))
      |> assign(:saved_count, saved_count(assigns.alignment))

    assigns =
      assign(
        assigns,
        :header_status,
        dirty_header_status(assigns.dirty_positions, assigns.header_status)
      )

    ~H"""
    <div id="alignment-task" class="mt-6">
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div>
          <div class="flex flex-wrap items-center gap-2">
            <h3 id="alignment-title" class="text-lg font-semibold">Alignment</h3>
            <span id="alignment-status" class={["badge", @header_status.tone]}>
              {@header_status.text}
            </span>
          </div>
          <p class="mt-1 text-sm text-base-content/70">
            Set the path your bus takes between stops.
          </p>
        </div>
        <div class="flex flex-wrap items-center gap-2">
          <button
            id="alignment-help"
            type="button"
            phx-click="alignment_open_help"
            class="btn btn-outline min-h-11"
          >
            <.icon name="hero-question-mark-circle-solid" class="h-5 w-5" /> How to edit
          </button>
          <%!-- Save enables with the draft/save flow in a later step; until then it
            stays disabled with a per-state reason so no dead event ever fires.
            It carries data-commit so the RoutePatternEditor hook disables it
            while offline (step 27 guard wiring). --%>
          <button
            :if={@dirty_positions != []}
            id="alignment-discard"
            type="button"
            phx-click="alignment_open_discard"
            class="btn btn-outline min-h-11"
          >
            Discard changes
          </button>
          <button
            id="alignment-save"
            type="button"
            disabled
            title={@save_title}
            data-commit="alignment"
            class="btn btn-primary min-h-11"
          >
            Save alignment
          </button>
        </div>
      </div>

      <.callout
        :if={@notice == :map_error}
        id="alignment-notice"
        kind="warning"
        title="The background map couldn't load"
      >
        <div class="flex flex-wrap items-center justify-between gap-3">
          <p>Your alignment and stop list are still available.</p>
          <button
            type="button"
            phx-click="alignment_retry_tiles"
            class="btn btn-outline min-h-11 shrink-0"
          >
            Retry map
          </button>
        </div>
      </.callout>

      <.callout
        :if={@notice == :read_only}
        id="alignment-notice"
        kind="info"
        title="You can view this alignment"
      >
        An editor can change the vehicle&rsquo;s path.
      </.callout>

      <.callout
        :if={@notice == :out_of_date}
        id="alignment-notice"
        kind="warning"
        title="Out of date"
      >
        Stops or shared paths changed since this pattern was saved. The export uses the
        saved shape until the pattern is saved again.
      </.callout>

      <.callout
        :if={@notice == :imported_shape}
        id="alignment-notice"
        kind="info"
        title="Imported path · original shape retained"
      >
        This pattern already has a shape. Review it before converting it into editable sections.
      </.callout>

      <div class="mt-4 flex flex-col gap-4 lg:grid lg:grid-cols-[316px_minmax(0,1fr)]">
        <section aria-label="Alignment map" class="order-1 min-w-0 lg:order-2">
          <div
            id="alignment-map-root"
            phx-hook="PatternAlignment"
            phx-update="ignore"
            data-tile-url="/map/tiles/osm-bright/{z}/{x}/{y}"
            class="flex min-h-80 items-center justify-center rounded-lg border border-base-300 bg-base-200 p-6 lg:min-h-[520px]"
          >
            <p id="alignment-map-loading" role="status" class="text-sm text-base-content/70">
              Loading map…
            </p>
          </div>
        </section>

        <aside
          aria-label="Alignment sections"
          class="order-2 min-w-0 rounded-lg border border-base-300 lg:order-1"
        >
          <div class="border-b border-base-200 p-4">
            <div class="flex items-center justify-between gap-2">
              <h4 class="font-semibold">Path between stops</h4>
              <p class="text-sm text-base-content/60">
                {@saved_count} of {length(@alignment.sections)} saved
              </p>
            </div>
            <p class="mt-1 text-sm text-base-content/60">Select a section to inspect it.</p>
          </div>

          <div id="alignment-sections" class="flex flex-col gap-2 p-4">
            <.section_row
              :for={section <- @alignment.sections}
              section={section}
              visits_by_position={@visits_by_position}
              selected={@selected != nil and section.position == @selected.position}
              dirty?={section.position in @dirty_positions}
              flagged?={section.position in @flagged_positions}
            />
          </div>

          <.section_detail
            :if={@selected}
            section={@selected}
            visits_by_position={@visits_by_position}
            total={length(@alignment.sections)}
            editable?={@editable?}
            dirty?={@selected.position in @dirty_positions}
            flagged?={@selected.position in @flagged_positions}
          />

          <div id="alignment-footer" class="border-t border-base-200 p-4">
            <div class="flex items-center justify-between gap-2">
              <p class="text-sm font-semibold">GTFS shape</p>
              <p class="text-sm">{@footer_status.word}</p>
            </div>
            <p class="mt-1 text-sm text-base-content/70">{@footer_status.sentence}</p>
          </div>
        </aside>
      </div>

      <.help_dialog
        open={@dialog_open}
        version_name={@version_name}
        organization_name={@organization_name}
      />

      <.discard_dialog dialog={@discard_dialog} />
      <.delete_dialog dialog={@delete_dialog} />
      <.simplify_dialog dialog={@simplify_dialog} />
    </div>
    """
  end

  attr :section, :map, required: true
  attr :visits_by_position, :map, required: true
  attr :selected, :boolean, required: true
  attr :dirty?, :boolean, default: false
  attr :flagged?, :boolean, default: false

  def section_row(assigns) do
    assigns =
      assigns
      |> assign(:names, section_names(assigns.section, assigns.visits_by_position))
      |> assign(:status, draft_status(assigns.section, assigns[:dirty?], assigns[:flagged?]))
      |> assign(:scope, section_scope(assigns.section, assigns.visits_by_position))

    ~H"""
    <button
      type="button"
      id={"alignment-section-#{@section.position}"}
      phx-click="alignment_select_section"
      phx-value-position={@section.position}
      aria-pressed={to_string(@selected)}
      class={[
        "flex min-h-11 w-full items-start gap-3 rounded-lg border px-3 py-2 text-left",
        if(@selected, do: "border-primary", else: "border-base-300")
      ]}
    >
      <span
        aria-hidden="true"
        class="flex h-6 w-6 shrink-0 items-center justify-center rounded-full border border-base-300 text-xs font-semibold"
      >
        {@section.position}
      </span>
      <span class="min-w-0 flex-1">
        <span class="block text-sm font-semibold">
          {@names.from} <span class="text-base-content/60">→</span>
          <br />{@names.to}
        </span>
        <span class="mt-1 flex flex-wrap items-center justify-between gap-2">
          <.alignment_status_badge
            id={"alignment-section-status-#{@section.position}"}
            text={@status.text}
            tone={@status.tone}
          />
          <span class="text-xs text-base-content/60">{@scope}</span>
        </span>
      </span>
    </button>
    """
  end

  attr :section, :map, required: true
  attr :visits_by_position, :map, required: true
  attr :total, :integer, required: true

  attr :editable?, :boolean,
    default: false,
    doc: "shows the keyboard point list toggle for editable non-missing sections"

  attr :dirty?, :boolean, default: false
  attr :flagged?, :boolean, default: false

  def section_detail(assigns) do
    assigns =
      assigns
      |> assign(:names, section_names(assigns.section, assigns.visits_by_position))
      |> assign(:status, draft_status(assigns.section, assigns[:dirty?], assigns[:flagged?]))
      |> assign(:repeat, repeat_labels(assigns.section, assigns.visits_by_position))
      |> assign(:guidance, section_guidance(assigns.section))
      |> assign(:draw?, draw_section?(assigns.section, assigns.editable?))
      |> assign(:more?, more_actions?(assigns.section, assigns.editable?))
      |> assign(:use_shared?, use_shared?(assigns.section))
      |> assign(
        :simplify?,
        simplify_section?(assigns.section, assigns.visits_by_position, assigns.editable?)
      )

    ~H"""
    <div id="alignment-detail" class="border-t border-base-200 p-4">
      <div class="flex items-center justify-between gap-2">
        <p class="text-xs font-medium tracking-wide text-base-content/60">
          SECTION {@section.position} OF {@total}
        </p>
        <.alignment_status_badge id="alignment-detail-status" text={@status.text} tone={@status.tone} />
      </div>
      <p class="mt-2 text-sm font-semibold">{@names.from} → {@names.to}</p>
      <p :if={@repeat} class="mt-1 text-sm text-base-content/60">
        Visits {@repeat.from} → {@repeat.to}
      </p>
      <p class="mt-1 text-sm text-base-content/70">{@guidance}</p>
      <%!-- Draw manually (step 26): the primary action on sections without
        saved geometry. No Generate control renders (CR-10). --%>
      <div :if={@draw?} class="pa-actions mt-3">
        <button
          type="button"
          id="alignment-draw"
          phx-click={
            JS.dispatch("alignment:action",
              to: "#alignment-map-root",
              detail: %{action: "draw", position: @section.position}
            )
          }
          class="btn btn-outline min-h-11 w-full"
        >
          Draw manually
        </button>
      </div>
      <%!-- The keyboard point list (step 25): the button dispatches a DOM
        action to the PatternAlignment hook, which owns the ignored list
        container below (CR-5). Rendered only for editable non-missing
        sections; step 26 adds the remaining section actions here. --%>
      <div :if={@editable? and @section.kind != :missing} class="mt-3 flex flex-wrap gap-2">
        <button
          type="button"
          id="alignment-point-list-toggle"
          phx-click={
            JS.dispatch("alignment:action",
              to: "#alignment-map-root",
              detail: %{action: "toggle_points"}
            )
          }
          class="btn btn-outline min-h-11"
          aria-expanded="false"
          aria-controls="alignment-point-list"
        >
          Point list
        </button>
      </div>
      <div
        :if={@editable? and @section.kind != :missing}
        id="alignment-point-list"
        phx-update="ignore"
      >
      </div>
      <%!-- More section actions (step 26): Simplify, Clear and Delete for
        saved sections, plus Use shared path on overrides beside a shared
        path. Simplify lives here (not beside Point list) because the
        server cannot see hook drafts; it renders from saved geometry. --%>
      <details :if={@more?} class="pa-more-actions mt-3">
        <summary>More section actions</summary>
        <div class="pa-actions">
          <button
            :if={@simplify?}
            type="button"
            id="alignment-simplify-open"
            phx-click="alignment_open_simplify"
            phx-value-position={@section.position}
            class="btn btn-outline min-h-11 w-full"
          >
            Simplify
          </button>
          <button
            type="button"
            id="alignment-clear"
            phx-click={
              JS.dispatch("alignment:action",
                to: "#alignment-map-root",
                detail: %{action: "clear", position: @section.position}
              )
            }
            class="btn btn-outline min-h-11 w-full"
          >
            Clear interior points
          </button>
          <button
            type="button"
            id="alignment-delete-open"
            phx-click="alignment_open_delete"
            phx-value-position={@section.position}
            class="btn btn-outline min-h-11 w-full"
          >
            Delete section
          </button>
          <button
            :if={@use_shared?}
            type="button"
            id="alignment-use-shared"
            phx-click={
              JS.dispatch("alignment:action",
                to: "#alignment-map-root",
                detail: %{action: "use_shared", position: @section.position}
              )
            }
            class="btn btn-outline min-h-11 w-full"
          >
            Use shared path
          </button>
        </div>
      </details>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :text, :string, required: true
  attr :tone, :string, required: true

  # Named `alignment_status_badge` (not the subspec's `status_badge`): the
  # CoreComponents `status_badge/1` import through `:html` conflicts with a
  # local of that name. This one is the daisyUI badge with symbol + text.
  def alignment_status_badge(assigns) do
    ~H"""
    <span id={@id} class={["badge", @tone]}>{@text}</span>
    """
  end

  attr :dialog, :map, default: nil, doc: "%{position, from, to} or nil"

  def delete_dialog(assigns) do
    ~H"""
    <.confirm_dialog
      id="alignment-delete-dialog"
      open={@dialog != nil}
      title="Delete this section's path?"
      confirm_label="Delete path"
      pending_label="Deleting…"
      on_confirm="alignment_confirm_delete"
      on_cancel="alignment_close_dialog"
      described_by="alignment-delete-dialog-body"
      return_focus_id="alignment-delete-open"
    >
      <div>
        <p :if={@dialog}>
          {@dialog.from} → {@dialog.to} will have no path in this pattern. The stops
          and their timings stay in place.
        </p>
        <p class="mt-2 text-sm text-base-content/70">
          Other patterns keep their paths. You can undo this draft change.
        </p>
      </div>
    </.confirm_dialog>
    """
  end

  attr :dialog, :map, default: nil, doc: "%{position, tolerance} or nil"

  def simplify_dialog(assigns) do
    ~H"""
    <.confirm_dialog
      id="alignment-simplify-dialog"
      open={@dialog != nil}
      title="Simplify this section"
      confirm_label="Preview simplification"
      pending_label="Simplifying…"
      confirm_variant="primary"
      on_confirm="alignment_confirm_simplify"
      on_cancel="alignment_close_dialog"
      described_by="alignment-simplify-dialog-body"
      return_focus_id="alignment-simplify-open"
    >
      <div>
        <p>Preview fewer points while keeping the stop anchors fixed.</p>
        <div class="mt-3">
          <label
            for="alignment-simplify-tolerance"
            class="block text-sm font-semibold"
          >
            Maximum path deviation
          </label>
          <select
            id="alignment-simplify-tolerance"
            name="tolerance_m"
            phx-change="alignment_simplify_tolerance"
            class="select select-bordered mt-1 min-h-11 w-full"
          >
            <option value="5" selected={@dialog && @dialog.tolerance == 5}>
              5 metres · preserve detail
            </option>
            <option value="10" selected={@dialog == nil or @dialog.tolerance == 10}>
              10 metres · balanced
            </option>
            <option value="25" selected={@dialog && @dialog.tolerance == 25}>
              25 metres · fewer points
            </option>
          </select>
        </div>
        <p class="mt-3 text-sm text-base-content/70">
          Applies to the selected points, or to this section when none are
          selected. Stop anchors stay fixed.
        </p>
      </div>
    </.confirm_dialog>
    """
  end

  attr :dialog, :any, default: nil, doc: "non-nil when the discard dialog is open"

  def discard_dialog(assigns) do
    ~H"""
    <.confirm_dialog
      id="alignment-discard-dialog"
      open={@dialog != nil}
      title="Discard unsaved changes?"
      confirm_label="Discard changes"
      pending_label="Discarding…"
      on_confirm="alignment_confirm_discard"
      on_cancel="alignment_close_dialog"
      described_by="alignment-discard-dialog-body"
      return_focus_id="alignment-discard"
    >
      <div>
        <p>
          Your saved path will stay unchanged. The edits in this draft will be lost.
        </p>
      </div>
    </.confirm_dialog>
    """
  end

  attr :open, :boolean, required: true
  attr :version_name, :string, default: nil
  attr :organization_name, :string, default: nil

  def help_dialog(assigns) do
    ~H"""
    <.confirm_dialog
      id="alignment-help-dialog"
      open={@open}
      title="Draw the path your bus takes"
      confirm_label="Close"
      pending_label="Closing…"
      on_confirm="alignment_close_help"
      on_cancel="alignment_close_help"
      cancel_label="Close"
      single_action={true}
      described_by="alignment-help-dialog-body"
      return_focus_id="alignment-help"
    >
      <ol class="list-decimal pl-5">
        <li class="mb-3">
          <strong>Select a section.</strong> Choose two consecutive stop visits from the list.
        </li>
        <li class="mb-3">
          <strong>Draw the path.</strong> Draw where the bus travels between the two stops.
          Check bus lanes, turns, and terminal access. The stop locations stay fixed.
        </li>
        <li class="mb-3">
          <strong>Review shared sections.</strong> A path shared with other patterns asks
          who should receive the change.
        </li>
        <li>
          <strong>Review and save.</strong> Saving writes the path so exports include it
          in shapes.txt.
        </li>
      </ol>
      <p :if={@version_name && @organization_name} class="mt-4 text-sm text-base-content/70">
        Saved paths belong to {@organization_name} in version {@version_name}.
      </p>
    </.confirm_dialog>
    """
  end

  # Draw is the primary action on sections without saved geometry:
  # missing sections, and blocked zero-length connectors whose anchors
  # resolve. A blocked section without coordinates cannot be drawn.
  defp draw_section?(%{kind: :missing}, true), do: true

  defp draw_section?(%{kind: :blocked, blocked_reason: reason}, true),
    do: reason != :no_coordinates

  defp draw_section?(_section, _editable?), do: false

  # Clear, Delete (and Simplify below) act on saved geometry.
  defp more_actions?(%{kind: kind}, true) when kind in [:override, :shared],
    do: true

  defp more_actions?(_section, _editable?), do: false

  defp use_shared?(%{kind: :override, shared_points: shared})
       when is_list(shared) and length(shared) > 0,
       do: true

  defp use_shared?(_section), do: false

  # Simplify needs at least 4 anchor-to-anchor points: both anchors plus
  # at least 2 interior points. Sections without resolvable anchors never
  # reach 4.
  defp simplify_section?(section, visits_by_position, true) do
    interior = length(section.points || [])
    anchors = if section_anchors?(section, visits_by_position), do: 2, else: 0
    anchors + interior >= 4
  end

  defp simplify_section?(_section, _visits, _editable?), do: false

  defp section_anchors?(section, visits_by_position) do
    from = Map.get(visits_by_position, section.position, %{})
    to = Map.get(visits_by_position, section.position + 1, %{})
    visit_coords?(from) and visit_coords?(to)
  end

  defp visit_coords?(%{lat: lat, lon: lon})
       when is_number(lat) and is_number(lon),
       do: true

  defp visit_coords?(_visit), do: false

  defp visits_by_position(nil), do: %{}

  defp visits_by_position(alignment) do
    Map.new(alignment.visits, &{&1.position, &1})
  end

  defp section_names(section, visits_by_position) do
    from = Map.get(visits_by_position, section.position, %{})
    to = Map.get(visits_by_position, section.position + 1, %{})
    %{from: Map.get(from, :name, ""), to: Map.get(to, :name, "")}
  end

  defp selected_section(nil, _state), do: nil

  defp selected_section(alignment, state) do
    wanted = (state && state[:selected]) || 1
    Enum.find(alignment.sections, &(&1.position == wanted)) || List.first(alignment.sections)
  end

  defp section_status(%{kind: :missing}), do: %{text: "! Missing", tone: "badge-error"}
  defp section_status(%{kind: :blocked}), do: %{text: "⚠ Blocked", tone: "badge-error"}
  defp section_status(_section), do: %{text: "✓ Saved", tone: "badge-success"}

  # Draft badges (step 27 guards): a dirty section reads ◷ Unsaved even
  # when its saved kind is Saved/Shared, and a flagged section asks for
  # review. Text plus symbol, never color alone.
  defp draft_status(_section, true, _flagged?),
    do: %{text: "◷ Unsaved", tone: "badge-warning"}

  defp draft_status(_section, _dirty?, true),
    do: %{text: "Check this section", tone: "badge-warning"}

  defp draft_status(section, _dirty?, _flagged?), do: section_status(section)

  defp dirty_positions(%{dirty_positions: positions}) when is_list(positions),
    do: positions

  defp dirty_positions(_state), do: []

  defp flagged_positions(%{flagged_positions: positions}) when is_list(positions),
    do: positions

  defp flagged_positions(_state), do: []

  defp dirty_header_status([_ | _] = _dirty, _status),
    do: %{text: "◷ Unsaved changes", tone: "badge-warning"}

  defp dirty_header_status(_dirty, status), do: status

  defp section_scope(section, visits_by_position) do
    from = Map.get(visits_by_position, section.position, %{})
    to = Map.get(visits_by_position, section.position + 1, %{})

    if String.contains?(Map.get(from, :label, ""), "/") or
         String.contains?(Map.get(to, :label, ""), "/") do
      "Visit #{section.position} → #{section.position + 1}"
    else
      section_scope(section)
    end
  end

  defp section_scope(%{kind: :shared, shared_users: users}) when is_integer(users),
    do: "Shared · #{users} patterns"

  defp section_scope(%{kind: :shared}), do: "Shared"
  defp section_scope(%{kind: :override}), do: "Custom path"
  defp section_scope(_section), do: "This pattern"

  defp header_status(nil), do: %{text: "Not exported", tone: "badge-ghost"}

  defp header_status(alignment) do
    status = alignment.status

    cond do
      status.missing > 0 -> %{text: "! #{status.missing} missing", tone: "badge-error"}
      status.blocked > 0 -> %{text: "⚠ Blocked", tone: "badge-error"}
      status.export == :current -> %{text: "✓ Exported", tone: "badge-success"}
      status.export == :stale -> %{text: "◷ Out of date", tone: "badge-warning"}
      status.export == :imported -> %{text: "Imported shape", tone: "badge-ghost"}
      true -> %{text: "Not exported", tone: "badge-ghost"}
    end
  end

  defp footer_status(nil),
    do: %{word: "Not exported", sentence: "Draw the missing paths to export this pattern."}

  # The footer answers what the export contains, so a present or imported
  # shape reports its export state even when sections are missing; the header
  # badge already summarizes section completeness.
  defp footer_status(alignment) do
    status = alignment.status

    cond do
      status.export == :current ->
        %{word: "✓ Exported", sentence: "Saved paths are included in shapes.txt."}

      status.export == :stale ->
        %{word: "◷ Out of date", sentence: "Saving again refreshes the exported shape."}

      status.export == :imported ->
        %{word: "Imported shape", sentence: "The export uses the imported shape."}

      status.missing > 0 or status.blocked > 0 ->
        %{word: "Incomplete", sentence: "Add the missing paths to complete this pattern."}

      true ->
        %{word: "Not exported", sentence: "Draw the missing paths to export this pattern."}
    end
  end

  defp save_title(_alignment, false), do: "Only editors can save alignment."

  defp save_title(alignment, true) do
    status = alignment.status

    cond do
      status.missing > 0 or status.blocked > 0 ->
        "Add the missing paths to complete this pattern."

      status.export == :current ->
        "Saved paths are included in shapes.txt."

      true ->
        "Saving is enabled once paths can be drawn."
    end
  end

  defp saved_count(nil), do: 0

  defp saved_count(alignment) do
    Enum.count(alignment.sections, &(&1.kind in [:override, :shared]))
  end

  defp section_guidance(%{kind: :missing}),
    do: "This section has no saved path. Draw where the bus travels."

  defp section_guidance(%{kind: :blocked, blocked_reason: :no_coordinates}),
    do: "A stop on this section has no coordinates, so no path can be drawn."

  defp section_guidance(%{kind: :blocked}),
    do: "Both ends of this section are at the same location, so no path can be drawn."

  defp section_guidance(%{kind: :shared, shared_users: users}) when is_integer(users) do
    others = max(users - 1, 0)
    "This section has a saved path. Used by this pattern and #{others} others."
  end

  defp section_guidance(%{kind: :shared}), do: "This section has a saved path."
  defp section_guidance(_section), do: "This section has a saved path for this pattern."

  defp repeat_labels(section, visits_by_position) do
    from = Map.get(visits_by_position, section.position, %{})
    to = Map.get(visits_by_position, section.position + 1, %{})
    from_label = Map.get(from, :label, "")
    to_label = Map.get(to, :label, "")

    if String.contains?(from_label, "/") or String.contains?(to_label, "/") do
      %{from: from_label, to: to_label}
    else
      nil
    end
  end
end
