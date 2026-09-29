defmodule GtfsPlannerWeb.Gtfs.RoutePatternAlignmentComponents do
  @moduledoc """
  Server-rendered Alignment task shell (slice A).

  Presents the `Gtfs.alignment_editor/4` read model: workspace header with the
  R9 status badge, the section inspector with per-section status and scope,
  the selected-section detail and the GTFS shape footer. Step 32 wires the
  street-generation controls (CR-10's slice-A restriction is lifted for
  these controls only): the empty-state overlay, the per-section Generate
  button with its replace dialog, the in-flight overlay with cancel, and
  the routing failure notices. Generation only produces drafts (CR-9); Save
  stays the only commit.
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

  attr :pending, :map,
    default: nil,
    doc: "save review pending a dialog choice (%{kind} :save | :blocked | :conflict)"

  attr :save_notice, :any,
    default: nil,
    doc: ":stale_stops, :stale_review, :busy, :save_error or {:error, message}"

  attr :import_dialog, :map,
    default: nil,
    doc: "%{shape_id} when the import review dialog is open"

  attr :applying?, :boolean,
    default: false,
    doc: "disables Save while a save apply round-trips"

  attr :generation, :map,
    default: nil,
    doc: "%{token, positions, pattern_id} while street routing is in flight"

  attr :generate_dialog, :map,
    default: nil,
    doc: "%{positions, from, to} when the generate replace dialog is open"

  attr :generate_notice, :map,
    default: nil,
    doc: "%{kind: :no_route | :unavailable, failures: [%{position, from, to}]}"

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
      |> assign(:missing_count, missing_count(assigns.alignment))
      |> assign(:save_enabled, save_enabled?(assigns))
      |> assign(:generating?, not is_nil(assigns[:generation]))
      |> assign(:save_pending?, not is_nil(assigns[:pending]))
      |> assign(:generate_overlay?, generate_overlay?(assigns.alignment, assigns[:editable?]))

    # The first-alignment overlay is a nudge, not a gate: once a draft
    # exists (generated or drawn) the hook owns visible geometry, so the
    # overlay gets out of the way. Discarding the draft brings it back.
    assigns =
      assign(
        assigns,
        :overlay_dismissed?,
        assigns.generating? or assigns.dirty_positions != []
      )

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
          <%!-- Save dispatches to the hook, which pushes alignment_save_requested
            with its dirty sections for review (step 28). It stays disabled with
            a per-state reason so no dead event ever fires. --%>
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
            disabled={!@save_enabled}
            title={
              save_button_title(
                @alignment,
                @editable?,
                @offline?,
                @applying?,
                @dirty_positions,
                @generating?
              )
            }
            data-commit="alignment"
            phx-click={
              JS.dispatch("alignment:action", to: "#alignment-map-root", detail: %{action: "save"})
            }
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
        title={import_notice_title(@alignment)}
      >
        <div class="flex flex-wrap items-center justify-between gap-3">
          <p>{import_notice_body(@alignment)}</p>
          <button
            type="button"
            id="alignment-review-import"
            phx-click="alignment_open_import"
            class="btn btn-outline min-h-11 shrink-0"
          >
            {import_notice_cta(@alignment)}
          </button>
        </div>
      </.callout>

      <.callout
        :if={@save_notice == :stale_stops}
        id="alignment-save-notice"
        kind="warning"
        title="Stops changed since you opened this alignment"
      >
        <div class="flex flex-wrap items-center justify-between gap-3">
          <p>Your previous saved path is retained until you review the new stop order.</p>
          <button
            type="button"
            id="alignment-save-reload"
            phx-click="alignment_reload"
            class="btn btn-outline min-h-11 shrink-0"
          >
            Reload
          </button>
        </div>
      </.callout>

      <.callout
        :if={@save_notice == :stale_review}
        id="alignment-save-notice"
        kind="warning"
        title="The patterns this save affects changed. Review again."
      >
        <div class="flex flex-wrap items-center justify-between gap-3">
          <p>Your draft is still here. Review the latest paths before saving.</p>
          <button
            type="button"
            id="alignment-review-again"
            phx-click="alignment_review_again"
            class="btn btn-outline min-h-11 shrink-0"
          >
            Review again
          </button>
        </div>
      </.callout>

      <.callout
        :if={@save_notice in [:busy, :save_error]}
        id="alignment-save-notice"
        kind="error"
        title="Your changes weren't saved. Try again."
      >
        <div class="flex flex-wrap items-center justify-between gap-3">
          <p>Your draft is still here.</p>
          <button
            type="button"
            id="alignment-save-retry"
            phx-click={
              JS.dispatch("alignment:action", to: "#alignment-map-root", detail: %{action: "save"})
            }
            class="btn btn-outline min-h-11 shrink-0"
          >
            Try again
          </button>
        </div>
      </.callout>

      <.callout
        :if={match?({:error, _}, @save_notice)}
        id="alignment-save-notice"
        kind="error"
        title="Your changes weren't saved."
      >
        {save_notice_message(@save_notice)}
      </.callout>

      <%!-- Step 32 routing failures: name the failed sections with Retry and
        Draw manually, and push nothing (AC-37). Drafts and saved paths stay
        unchanged; the API key never appears here. --%>
      <.callout
        :if={@generate_notice != nil and @generate_notice.kind == :no_route}
        id="alignment-generate-notice"
        kind="warning"
        title="No street path found"
      >
        <div class="flex flex-wrap items-center justify-between gap-3">
          <p>{generate_notice_body(@generate_notice)}</p>
          <div class="flex flex-wrap gap-2">
            <button
              type="button"
              id="alignment-generate-retry"
              phx-click="alignment_generate_paths"
              phx-value-retry="true"
              data-commit="alignment"
              class="btn btn-outline min-h-11 shrink-0"
            >
              Retry
            </button>
            <button
              type="button"
              id="alignment-generate-draw"
              phx-click={
                JS.dispatch("alignment:action",
                  to: "#alignment-map-root",
                  detail: %{action: "draw", position: generate_draw_position(@generate_notice)}
                )
              }
              class="btn btn-outline min-h-11 shrink-0"
            >
              Draw manually
            </button>
          </div>
        </div>
      </.callout>

      <.callout
        :if={@generate_notice != nil and @generate_notice.kind == :unavailable}
        id="alignment-generate-notice"
        kind="error"
        title="Street routing is unavailable"
      >
        <div class="flex flex-wrap items-center justify-between gap-3">
          <p>Draw the section or try again later.</p>
          <div class="flex flex-wrap gap-2">
            <button
              type="button"
              id="alignment-generate-retry"
              phx-click="alignment_generate_paths"
              phx-value-retry="true"
              data-commit="alignment"
              class="btn btn-outline min-h-11 shrink-0"
            >
              Retry
            </button>
            <button
              :if={generate_draw_position(@generate_notice) != nil}
              type="button"
              id="alignment-generate-draw"
              phx-click={
                JS.dispatch("alignment:action",
                  to: "#alignment-map-root",
                  detail: %{action: "draw", position: generate_draw_position(@generate_notice)}
                )
              }
              class="btn btn-outline min-h-11 shrink-0"
            >
              Draw manually
            </button>
          </div>
        </div>
      </.callout>

      <div class="mt-4 flex flex-col gap-4 lg:grid lg:grid-cols-[316px_minmax(0,1fr)]">
        <section aria-label="Alignment map" class="order-1 min-w-0 lg:order-2">
          <%!-- Step 32 generation overlays: server-rendered siblings over the
            map container, outside the ignored hook element. --%>
          <div class="relative">
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
            <div
              :if={@generate_overlay? and not @overlay_dismissed?}
              id="alignment-generate-overlay"
              class="absolute inset-0 z-[1100] flex items-center justify-center rounded-lg bg-base-100/85 p-6"
            >
              <div class="max-w-sm text-center">
                <h4 class="text-base font-semibold">Give this pattern a path</h4>
                <p class="mt-2 text-sm text-base-content/70">
                  Start with a suggested street path, then adjust it to match where
                  your bus actually travels.
                </p>
                <button
                  type="button"
                  id="alignment-generate-all"
                  phx-click="alignment_generate_paths"
                  data-commit="alignment"
                  disabled={@offline? or @save_pending?}
                  title={generate_all_title(@offline?, @save_pending?)}
                  class="btn btn-primary mt-4 min-h-11 w-full"
                >
                  Generate street paths
                </button>
                <button
                  type="button"
                  id="alignment-overlay-draw"
                  phx-click={
                    JS.dispatch("alignment:action",
                      to: "#alignment-map-root",
                      detail: %{action: "draw", position: first_missing_position(@alignment)}
                    )
                  }
                  class="btn btn-ghost mt-2 min-h-11 w-full"
                >
                  Or draw a section
                </button>
              </div>
            </div>
            <div
              :if={@generating?}
              id="alignment-generating"
              role="status"
              class="absolute inset-0 z-[1100] flex items-center justify-center rounded-lg bg-base-100/85 p-6"
            >
              <div class="max-w-sm text-center">
                <h4 class="text-base font-semibold">Finding a street path…</h4>
                <p class="mt-2 text-sm text-base-content/70">
                  Your saved paths stay unchanged.
                </p>
                <button
                  type="button"
                  id="alignment-cancel-generation"
                  phx-click="alignment_cancel_generation"
                  class="btn btn-outline mt-4 min-h-11 w-full"
                >
                  Cancel generation
                </button>
              </div>
            </div>
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
            <%!-- Step 32 all-missing generation for partially drawn patterns:
              the empty-state overlay covers the first-alignment moment only,
              so this entry point fires the same event while sections remain. --%>
            <button
              :if={@editable? and @missing_count > 0 and @missing_count < length(@alignment.sections)}
              type="button"
              id="alignment-generate-missing"
              phx-click="alignment_generate_paths"
              data-commit="alignment"
              disabled={@offline? or @generating? or @save_pending?}
              title={generate_button_title(@offline?, @generating?, @save_pending?)}
              class="btn btn-outline mt-3 min-h-11 w-full"
            >
              Generate street paths
            </button>
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
            offline?={@offline?}
            generating?={@generating?}
            save_pending?={@save_pending?}
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
      <.save_dialog
        pending={@pending}
        visits_by_position={@visits_by_position}
        applying?={@applying?}
        version_name={@version_name}
        organization_name={@organization_name}
      />
      <.import_dialog dialog={@import_dialog} alignment={@alignment} />
      <.generate_replace_dialog dialog={@generate_dialog} />
      <.blocked_dialog pending={@pending} />
      <.conflict_dialog pending={@pending} visits_by_position={@visits_by_position} />
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

  attr :offline?, :boolean, default: false, doc: "disables Generate until reconnected"
  attr :generating?, :boolean, default: false, doc: "disables Generate while routing"

  attr :save_pending?, :boolean,
    default: false,
    doc: "disables Generate while a save review is open"

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
      |> assign(:generate?, generate_section?(assigns.section, assigns.editable?))
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
      <%!-- Generate street path (step 32): the street-routing entry point on
        sections with stop coordinates. Replacing saved points asks first
        through the replace dialog; nothing is written before Save (CR-9). --%>
      <div :if={@generate?} class="pa-actions mt-3">
        <button
          type="button"
          id="alignment-generate-section"
          phx-click="alignment_generate_paths"
          phx-value-position={@section.position}
          data-commit="alignment"
          disabled={@offline? or @generating? or @save_pending?}
          title={generate_button_title(@offline?, @generating?, @save_pending?)}
          class="btn btn-outline min-h-11 w-full"
        >
          Generate street path
        </button>
      </div>
      <%!-- Draw manually (step 26): the primary action on sections without
        saved geometry. --%>
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
      <%!-- The keyboard point list (steps 25, 30): the button dispatches a DOM
        action to the PatternAlignment hook, which owns the ignored list
        container below (CR-5). Rendered for every editable section, including
        missing ones: after Draw manually the hook holds a `set` draft, so the
        list offers "No interior points yet. Use Add midpoint to start." and
        keyboard users can complete a drawn section. Before the draw the hook
        no-ops the toggle, since a missing section without a draft is not
        editable. Step 26 adds the remaining section actions here. --%>
      <div :if={@editable?} class="mt-3 flex flex-wrap gap-2">
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
        :if={@editable?}
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
          <form id="alignment-simplify-tolerance-form" phx-change="alignment_simplify_tolerance">
            <select
              id="alignment-simplify-tolerance"
              name="tolerance_m"
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
          </form>
        </div>
        <p class="mt-3 text-sm text-base-content/70">
          Applies to the selected points, or to this section when none are
          selected. Stop anchors stay fixed.
        </p>
      </div>
    </.confirm_dialog>
    """
  end

  attr :pending, :map, default: nil, doc: "save review pending a scope choice"
  attr :visits_by_position, :map, required: true
  attr :applying?, :boolean, default: false
  attr :version_name, :string, default: nil
  attr :organization_name, :string, default: nil

  # Step 28 scope dialog: per changed section the scope radios default to
  # "Only this pattern"; shared deletions list the patterns left missing;
  # replaced imports name each shape and trip count (INV-5). The radios
  # report through the form's phx-change into the pending scopes, so the
  # Save path confirm applies exactly the chosen outcome.
  def save_dialog(assigns) do
    assigns = assign(assigns, :review, save_review(assigns.pending))

    ~H"""
    <.confirm_dialog
      id="alignment-save-dialog"
      open={@review != nil}
      title={save_dialog_title(@review)}
      confirm_label="Save path"
      pending_label="Saving…"
      pending={@applying?}
      confirm_variant="primary"
      on_confirm="confirm_alignment_save"
      on_cancel="alignment_cancel_save"
      described_by="alignment-save-dialog-body"
      return_focus_id="alignment-save"
      size="lg"
    >
      <div :if={@review}>
        <form id="alignment-save-form" phx-change="alignment_save_choice">
          <div :for={section <- save_scope_sections(@review)} class="mt-4">
            <.save_scope_fieldset
              section={section}
              pending={@pending}
              visits_by_position={@visits_by_position}
            />
          </div>
          <div
            :for={section <- save_delete_sections(@review)}
            class="mt-4 rounded-lg border border-base-300 p-3"
          >
            <p class="text-sm font-semibold">
              {section_name(section, @visits_by_position)} will have no path in {length(
                section.affected
              )} {if(length(section.affected) == 1, do: "pattern", else: "patterns")}:
            </p>
            <ul class="mt-2 list-disc pl-5 text-sm">
              <li :for={user <- section.affected}>
                {user.route_label} · {user.pattern_label}
              </li>
            </ul>
          </div>
          <div :if={@review.replaced_shapes != []} class="mt-4 rounded-lg border border-base-300 p-3">
            <p class="text-sm font-semibold">Replace imported shapes</p>
            <ul class="mt-2 list-disc pl-5 text-sm">
              <li :for={entry <- @review.replaced_shapes}>
                Shape {entry.shape_id} ({entry.trip_count} {if(entry.trip_count == 1,
                  do: "trip",
                  else: "trips"
                )})
              </li>
            </ul>
            <p class="mt-2 text-sm text-base-content/70">
              Shapes no trip still uses are removed. Their points are kept in change history.
            </p>
          </div>
        </form>
        <p
          :if={@version_name && @organization_name}
          class="mt-4 text-sm text-base-content/70"
        >
          Changes apply within {@version_name}, {@organization_name}.
        </p>
      </div>
    </.confirm_dialog>
    """
  end

  attr :section, :map, required: true
  attr :pending, :map, required: true
  attr :visits_by_position, :map, required: true

  def save_scope_fieldset(assigns) do
    assigns =
      assigns
      |> assign(:names, section_names(assigns.section, assigns.visits_by_position))
      |> assign(:checked, save_scope_value(assigns.pending, assigns.section.position))
      |> assign(:rematerialize_by_pattern, rematerialize_by_pattern(assigns.section))

    ~H"""
    <fieldset class="rounded-lg border border-base-300 p-3">
      <legend class="px-1 text-sm font-semibold">
        {@names.from} → {@names.to} has a shared path. Choose where to apply your edit.
      </legend>
      <label
        for={"alignment-save-scope-#{@section.position}-local"}
        class="mt-2 flex min-h-11 cursor-pointer items-start gap-3 rounded-lg border border-base-300 p-3 has-checked:border-primary"
      >
        <input
          type="radio"
          id={"alignment-save-scope-#{@section.position}-local"}
          name={"scopes[#{@section.position}]"}
          value="local"
          checked={@checked == "local"}
          class="radio mt-1"
        />
        <span>
          <strong>Only this pattern</strong>
          <small class="block text-base-content/70">
            Create a custom path for this pattern. Other patterns keep the shared path.
          </small>
        </span>
      </label>
      <label
        for={"alignment-save-scope-#{@section.position}-shared"}
        class="mt-2 flex min-h-11 cursor-pointer items-start gap-3 rounded-lg border border-base-300 p-3 has-checked:border-primary"
      >
        <input
          type="radio"
          id={"alignment-save-scope-#{@section.position}-shared"}
          name={"scopes[#{@section.position}]"}
          value="shared"
          checked={@checked == "shared"}
          class="radio mt-1"
        />
        <span>
          <strong>All {length(@section.affected) + 1} patterns using the shared path</strong>
          <span class="mt-1 block text-sm">
            <span :for={user <- @section.affected} class="block">
              {user.route_label} · {user.pattern_label} — {affected_export_note(
                user,
                @rematerialize_by_pattern
              )}
            </span>
            <span :for={user <- @section.custom_unchanged} class="block text-base-content/70">
              {user.pattern_label} has a custom path and will not change.
            </span>
          </span>
        </span>
      </label>
    </fieldset>
    """
  end

  attr :pending, :map, default: nil, doc: "blocked review with %{blockers}"

  # Step 28 blocked dialog: names each pattern and trip whose stop-time
  # count no longer matches. Nothing was written.
  def blocked_dialog(assigns) do
    assigns = assign(assigns, :blockers, blocked_blockers(assigns.pending))

    ~H"""
    <.confirm_dialog
      id="alignment-blocked-dialog"
      open={@blockers != []}
      title="This path can't be saved yet"
      confirm_label="Close"
      pending_label="Closing…"
      on_confirm="alignment_cancel_save"
      on_cancel="alignment_cancel_save"
      cancel_label="Close"
      single_action={true}
      described_by="alignment-blocked-dialog-body"
      return_focus_id="alignment-save"
    >
      <div :if={@blockers != []}>
        <p :for={blocker <- @blockers} class="mt-2 text-sm first:mt-0">
          Trip {blocker.trip_id} in {blocker.pattern_label} has {blocker.stop_time_count} stop times, but the pattern has {blocker.visit_count} visits. Fix the
          trip's stop times, then save again. Nothing was saved.
        </p>
      </div>
    </.confirm_dialog>
    """
  end

  attr :pending, :map, default: nil, doc: "conflict with %{draft, current}"
  attr :visits_by_position, :map, required: true

  # Step 28 conflict dialog: the latest saved sections beside the draft.
  # "Load latest" discards the draft; "Keep as local draft" rebases the
  # hook and records the positions so the next save stays local.
  def conflict_dialog(assigns) do
    assigns = assign(assigns, :current, conflict_current(assigns.pending))

    ~H"""
    <.confirm_dialog
      id="alignment-conflict-dialog"
      open={@current != []}
      title="Review the newer shared path"
      confirm_label="Keep as local draft"
      pending_label="Keeping…"
      confirm_variant="primary"
      on_confirm="alignment_conflict_keep_local"
      on_cancel="alignment_close_dialog"
      described_by="alignment-conflict-dialog-body"
      return_focus_id="alignment-save"
      size="lg"
    >
      <div :if={@current != []}>
        <p>
          A newer shared path was saved while you were editing. Review both
          versions before applying your draft.
        </p>
        <div :for={section <- @current} class="mt-3 grid grid-cols-1 gap-3">
          <div class="rounded-lg border border-base-300 p-3">
            <p class="font-semibold">Latest shared path</p>
            <p class="mt-1 text-sm text-base-content/70">
              {conflict_section_name(section, @visits_by_position)} · {length(section.points || [])} points ·
              used by {section_usage(section)} {if(section_usage(section) == 1,
                do: "pattern",
                else: "patterns"
              )}
            </p>
          </div>
          <div class="rounded-lg border border-base-300 p-3">
            <p class="font-semibold">Your draft</p>
            <p class="mt-1 text-sm text-base-content/70">
              {conflict_section_name(section, @visits_by_position)} · {conflict_draft_points(
                @pending,
                section.position
              )} points ·
              unsaved
            </p>
          </div>
        </div>
        <p class="mt-4 text-sm text-base-content/70">
          Keep your draft as a path for this pattern, or discard it and load the latest shared path.
        </p>
        <button
          type="button"
          id="alignment-conflict-load-latest"
          phx-click="alignment_conflict_load_latest"
          class="btn btn-outline mt-3 min-h-11"
        >
          Load latest
        </button>
      </div>
    </.confirm_dialog>
    """
  end

  attr :dialog, :map, default: nil, doc: "%{shape_id} when the import review dialog is open"
  attr :alignment, :map, default: nil, doc: "the Gtfs.alignment_editor/4 read model"

  # Step 29 import dialog: a single imported shape shows its length,
  # visit count and point count in a card; divergent shapes render as
  # radios with trip counts and lengths plus a warning naming every
  # affected trip. "Keep original" only closes; "Create editable draft"
  # pushes alignment:convert for the chosen shape (CR-9: the server
  # never converts, the hook drafts). The prototype's "Proposed
  # workflow" paragraph is omitted (production behavior is real).
  def import_dialog(assigns) do
    assigns =
      assigns
      |> assign(:shapes, import_shapes(assigns.alignment))
      |> assign(:open?, import_open?(assigns.dialog, assigns.alignment))
      |> assign(:total_trips, import_total_trips(assigns.alignment))
      |> assign(:visit_count, import_visit_count(assigns.alignment))

    ~H"""
    <.confirm_dialog
      id="alignment-import-dialog"
      open={@open?}
      title={import_dialog_title(@shapes)}
      confirm_label="Create editable draft"
      pending_label="Creating…"
      confirm_variant="primary"
      on_confirm="alignment_confirm_import"
      on_cancel="alignment_close_dialog"
      cancel_label="Keep original"
      described_by="alignment-import-dialog-body"
      return_focus_id="alignment-review-import"
      size="lg"
    >
      <div :if={@open?}>
        <p :if={length(@shapes) == 1}>
          The existing whole shape is retained for exports. Conversion creates an
          editable draft; it does not change the saved shape.
        </p>
        <p :if={length(@shapes) > 1}>
          {length(@shapes)} shapes are referenced by this pattern's trips. They are
          retained until you explicitly replace them.
        </p>
        <div :if={length(@shapes) == 1} class="mt-3 rounded-lg border border-base-300 p-3">
          <p class="text-sm font-semibold">Shape {hd(@shapes).shape_id}</p>
          <p class="mt-1 text-sm text-base-content/70">
            {import_shape_km(hd(@shapes))} · {@visit_count} {if(@visit_count == 1,
              do: "visit",
              else: "visits"
            )} · {length(hd(@shapes).points || [])} imported points
          </p>
        </div>
        <form
          :if={length(@shapes) > 1}
          id="alignment-import-form"
          phx-change="alignment_import_choice"
        >
          <label
            :for={shape <- @shapes}
            for={"alignment-import-shape-#{shape.shape_id}"}
            class="mt-2 flex min-h-11 cursor-pointer items-start gap-3 rounded-lg border border-base-300 p-3 has-checked:border-primary"
          >
            <input
              type="radio"
              id={"alignment-import-shape-#{shape.shape_id}"}
              name="import_shape"
              value={shape.shape_id}
              checked={import_selected?(@dialog, shape, @shapes)}
              class="radio mt-1"
            />
            <span>
              <strong>Shape {shape.shape_id}</strong>
              <small class="block text-base-content/70">
                {shape.trip_count} {if(shape.trip_count == 1, do: "trip", else: "trips")} · {import_shape_km(
                  shape
                )}
              </small>
            </span>
          </label>
        </form>
        <p :if={length(@shapes) > 1} class="mt-3">
          <span class="badge badge-warning">
            Saving the replacement would affect all {@total_trips} trips.
          </span>
        </p>
      </div>
    </.confirm_dialog>
    """
  end

  attr :dialog, :map,
    default: nil,
    doc: "%{positions, from, to} when the generate replace dialog is open"

  def generate_replace_dialog(assigns) do
    ~H"""
    <.confirm_dialog
      id="alignment-generate-replace-dialog"
      open={@dialog != nil}
      title="Replace the drawn path?"
      confirm_label="Generate new path"
      pending_label="Generating…"
      confirm_variant="primary"
      on_confirm="alignment_confirm_generate"
      on_cancel="alignment_close_dialog"
      described_by="alignment-generate-replace-dialog-body"
      return_focus_id="alignment-generate-section"
    >
      <div>
        <p :if={@dialog}>
          {@dialog.from} → {@dialog.to} already has a path. Generating replaces
          it with a suggested street path.
        </p>
        <p class="mt-2 text-sm text-base-content/70">
          Nothing is written until you save. You can undo this draft change.
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

  # Generate needs stop coordinates, like Draw, and additionally offers
  # replacing a saved path (the replace dialog asks first). Blocked
  # sections keep their guidance instead: generation cannot fix them.
  defp generate_section?(%{kind: kind}, true) when kind in [:missing, :override, :shared],
    do: true

  defp generate_section?(_section, _editable?), do: false

  # The first-alignment overlay shows while every section is still missing
  # and an editor can generate. Viewers never see generation controls.
  defp generate_overlay?(%{sections: [_ | _] = sections}, true),
    do: Enum.all?(sections, &(&1.kind == :missing))

  defp generate_overlay?(_alignment, _editable?), do: false

  defp first_missing_position(%{sections: sections}) do
    case Enum.find(sections, &(&1.kind == :missing)) do
      %{position: position} -> position
      nil -> nil
    end
  end

  defp first_missing_position(_alignment), do: nil

  defp generate_notice_body(%{failures: failures}) do
    failures
    |> Enum.map(fn %{from: from, to: to} -> "#{from} → #{to}" end)
    |> Enum.map_join("; ", & &1)
    |> case do
      "" -> "Street routing found no path. Draw the section or try again."
      names -> "#{names} may be unreachable by street routing. Draw the section or try again."
    end
  end

  defp generate_notice_body(_notice),
    do: "Street routing found no path. Draw the section or try again."

  defp generate_draw_position(%{failures: [%{position: position} | _]}), do: position
  defp generate_draw_position(_notice), do: nil

  defp generate_button_title(true, _generating?, _save_pending?),
    do: "Reconnect before generating"

  defp generate_button_title(_offline?, true, _save_pending?),
    do: "Generation is already running"

  defp generate_button_title(_offline?, _generating?, true),
    do: "Finish or cancel the open save before generating"

  defp generate_button_title(_offline?, _generating?, _save_pending?), do: nil

  defp generate_all_title(true, _save_pending?), do: "Reconnect before generating"

  defp generate_all_title(_offline?, true),
    do: "Finish or cancel the open save before generating"

  defp generate_all_title(_offline?, _save_pending?), do: nil

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
       when is_list(shared) and shared != [],
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

  defp header_status(nil), do: list_status_parts(nil)

  defp header_status(alignment), do: list_status_parts(alignment.status)

  # Six-state Route › Patterns wording shared by the Alignment task header
  # and the patterns-list cell (step 35): symbol + text, never colour alone.
  defp list_status_parts(nil), do: %{text: "Not exported", tone: "badge-ghost"}

  defp list_status_parts(status) do
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

  defp missing_count(nil), do: 0

  defp missing_count(alignment) do
    Enum.count(alignment.sections, &(&1.kind == :missing))
  end

  # Save enables for editors with a dirty draft; the hook pushes only
  # dirty sections, so a clean draft has nothing to review.
  defp save_enabled?(assigns) do
    assigns.editable? and not assigns.offline? and assigns[:applying?] != true and
      is_nil(assigns[:generation]) and dirty_positions(assigns.state) != []
  end

  defp save_button_title(_alignment, false, _offline?, _applying?, _dirty?, _generating?),
    do: "Only editors can save alignment."

  defp save_button_title(_alignment, true, true, _applying?, _dirty?, _generating?),
    do: "Reconnect before saving."

  defp save_button_title(_alignment, true, _offline?, true, _dirty?, _generating?),
    do: "Saving your alignment…"

  defp save_button_title(_alignment, true, _offline?, _applying?, _dirty?, true),
    do: "Finish or cancel generation before saving."

  defp save_button_title(_alignment, true, _offline?, _applying?, [], _generating?),
    do: "Edit a path to enable saving."

  defp save_button_title(alignment, true, _offline?, _applying?, _dirty?, _generating?),
    do: save_title(alignment, true)

  defp save_notice_message({:error, message}) when is_binary(message), do: message
  defp save_notice_message(_notice), do: "Your draft is still here. Try saving again."

  # Step 29 import notice/dialog copy. A single imported shape keeps the
  # "Imported path" title with a review entry point; divergent shapes
  # name their count and keep both originals until an explicit save.
  defp import_shapes(%{imported_shapes: shapes}) when is_list(shapes), do: shapes
  defp import_shapes(_alignment), do: []

  defp import_notice_title(alignment) do
    case import_shapes(alignment) do
      [_single] -> "Imported path · original shape retained"
      [_ | _] = shapes -> "This pattern uses #{length(shapes)} imported shapes"
      [] -> "Imported path · original shape retained"
    end
  end

  defp import_notice_body(alignment) do
    case import_shapes(alignment) do
      [_single] ->
        "This pattern already has a shape. Review it before converting it into editable sections."

      [_first, _second] ->
        "Choose how to handle these paths before editing. Export retains both originals."

      [_ | _] = shapes ->
        "Choose how to handle these paths before editing. Export retains all #{length(shapes)} originals."

      [] ->
        "This pattern already has a shape. Review it before converting it into editable sections."
    end
  end

  defp import_notice_cta(alignment) do
    if length(import_shapes(alignment)) > 1, do: "Compare shapes", else: "Review imported path"
  end

  defp import_open?(%{shape_id: shape_id}, alignment),
    do: shape_id in Enum.map(import_shapes(alignment), & &1.shape_id)

  defp import_open?(_dialog, _alignment), do: false

  defp import_total_trips(alignment) do
    alignment |> import_shapes() |> Enum.map(& &1.trip_count) |> Enum.sum()
  end

  defp import_visit_count(%{visits: visits}) when is_list(visits), do: length(visits)
  defp import_visit_count(_alignment), do: 0

  defp import_dialog_title([_single]), do: "Review imported path"
  defp import_dialog_title(_shapes), do: "Choose an imported path"

  defp import_shape_km(%{length_m: length_m}) when is_number(length_m) do
    "#{:erlang.float_to_binary(length_m / 1000, decimals: 1)} km"
  end

  defp import_shape_km(_shape), do: "—"

  defp import_selected?(%{shape_id: selected}, %{shape_id: shape_id}, _shapes),
    do: selected == shape_id

  defp import_selected?(_dialog, %{shape_id: shape_id}, [first | _]),
    do: shape_id == first.shape_id

  defp import_selected?(_dialog, _shape, _shapes), do: false

  # The save dialog shows the pending review; any other pending kind
  # leaves it closed.
  defp save_review(%{kind: :save, review: review}), do: review
  defp save_review(_pending), do: nil

  defp save_dialog_title(nil), do: "Who should use this path?"

  defp save_dialog_title(review) do
    if length(save_scope_sections(review)) + length(save_delete_sections(review)) == 1 do
      "Who should use this path?"
    else
      "Who should use these paths?"
    end
  end

  defp save_scope_sections(nil), do: []

  defp save_scope_sections(review) do
    Enum.filter(review.sections, &(&1.action == :choose_scope))
  end

  defp save_delete_sections(nil), do: []

  defp save_delete_sections(review) do
    Enum.filter(review.sections, &(&1.action == :delete_shared and &1.affected != []))
  end

  defp section_name(section, visits_by_position) do
    names = section_names(section, visits_by_position)
    "#{names.from} → #{names.to}"
  end

  defp save_scope_value(%{scopes: scopes}, position),
    do: Map.get(scopes, to_string(position), "local")

  defp save_scope_value(_pending, _position), do: "local"

  defp rematerialize_by_pattern(section) do
    Map.new(section.shared_rematerialize, &{&1.route_pattern_id, &1})
  end

  # What a shared save does to each affected pattern's export, from the
  # review's rematerialization plan: shape-owning complete patterns move
  # to the new path, other shape owners keep theirs, and the rest keep
  # their imported shapes until their own save.
  defp affected_export_note(user, rematerialize_by_pattern) do
    case Map.get(rematerialize_by_pattern, user.route_pattern_id) do
      %{trips: trips} ->
        "updates its exported shape (#{trips} #{if(trips == 1, do: "trip", else: "trips")})"

      nil when user.owns_shape? ->
        "keeps its current shape"

      nil ->
        "keeps its imported shape"
    end
  end

  defp blocked_blockers(%{kind: :blocked, blockers: blockers}), do: blockers
  defp blocked_blockers(_pending), do: []

  defp conflict_current(%{kind: :conflict, current: current}) when is_list(current),
    do: current

  defp conflict_current(_pending), do: []

  defp conflict_section_name(section, visits_by_position) do
    section_name(section, visits_by_position)
  end

  defp section_usage(%{shared_users: users}) when is_integer(users), do: users
  defp section_usage(_section), do: 1

  defp conflict_draft_points(%{draft: draft}, position) when is_list(draft) do
    draft
    |> Enum.find(&(draft_position(&1) == position))
    |> draft_point_count()
  end

  defp conflict_draft_points(_pending, _position), do: 0

  defp draft_position(%{"position" => position}) when is_integer(position), do: position
  defp draft_position(%{position: position}) when is_integer(position), do: position
  defp draft_position(_entry), do: nil

  defp draft_point_count(%{"points" => points}) when is_list(points), do: length(points)
  defp draft_point_count(%{points: points}) when is_list(points), do: length(points)
  defp draft_point_count(_entry), do: 0

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
