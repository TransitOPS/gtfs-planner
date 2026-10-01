defmodule GtfsPlannerWeb.Gtfs.RostersComponents do
  @moduledoc """
  Function components for Operations › Rosters.

  The page's head and its states live here so `GtfsPlannerWeb.Gtfs.RostersLive`
  stays a small state owner. The head and the two states below it are the whole
  of this step: the scope bar, count strip, grid, open work and export section
  arrive with the steps that own them, and each is a new function in this module
  rather than a branch inside the LiveView's `render/1`.

  The markup follows the design system the restyled Blocks page uses: the page
  carries the shared `.ds-page` scope, the head uses `CoreComponents`'s
  `header/1` and `button/1`, the states are `PlannerComponents` panels and the
  loading skeleton is `CoreComponents.skeleton/1` with its own bars. The
  prototype (`.specs/09-basic-rosters/references/rosters-prototype.html`) is the
  authority for the copy and the hierarchy; it is not reproduced here, because
  its sample data, its state switcher and its simulation are prototype-only.

  ## Why the loading state mirrors the grid

  A skeleton whose shape is not the shape of what arrives makes the page jump
  when the real content replaces it, and it tells the reader nothing about what
  is coming. The loading panel therefore draws a Line column, seven weekday
  columns and eight rows — the shape step 26's grid has — and the head's
  editing control is disabled with the reason in `title`, because a control that
  is off with no explanation is a dead end rather than a pause.
  """

  use GtfsPlannerWeb, :html

  import GtfsPlannerWeb.PlannerComponents, only: [first_use: 1]

  @weekdays ~w(Mon Tue Wed Thu Fri Sat Sun)

  # A control that is off while the roster has not loaded says why. One
  # sentence, written once, because the head's `title` and the loading panel's
  # copy are the same fact said to the reader in the two places they look for it.
  @paused_reason "Editing is paused until the roster loads."

  @doc """
  Renders the page head: the H1, the one subtitle sentence, and the Add line
  action.

  `Add line` is secondary, never primary. At most one primary belongs to a state
  of this page, and the clean state has none: a line is created from open work
  as often as from here, so the head offers the entry point without claiming the
  page's one emphasis.

  Two states change it, for two different reasons. While the roster is loading
  — or paused after a failed read — the button is disabled and `title` carries
  the reason, because a control that is off with no explanation is a dead end
  rather than a pause. In the no-runs state it is not drawn at all: there is no
  run to put in a line, so the action would create an empty line that cannot be
  filled, and the page's one action is already the one that makes runs.

  Step 30 gives the event its real write; until then `add_line` is the head's
  declared entry point and the guard that covers it, and nothing more.
  """
  attr :state, :atom, required: true, values: [:loading, :ready, :no_runs, :unavailable]

  # Module attributes are not readable inside a `~H` sigil — there `@name` is
  # an assign — so the two constants below are put on the assigns the templates
  # read. They are read from one place each, so they cannot drift apart.
  def page_head(assigns) do
    assigns =
      assigns
      |> assign(:paused_reason, @paused_reason)
      |> assign(:locked?, assigns.state in [:loading, :unavailable])

    ~H"""
    <div id="rosters-head" data-role="rosters-head" class="pt-8">
      <.header>
        Roster lines
        <:subtitle>
          Each line is one week of work that repeats through the service period.
          Operators pick lines by seniority outside the app; record each pick here.
        </:subtitle>
        <:actions>
          <.button
            :if={@state != :no_runs}
            id="rosters-add-line"
            type="button"
            variant="secondary"
            class="min-h-11"
            phx-click="add_line"
            disabled={@locked?}
            title={if @locked?, do: @paused_reason, else: nil}
          >
            Add line
          </.button>
        </:actions>
      </.header>
    </div>
    """
  end

  @doc """
  Renders the page's one toast: a refusal or a confirmation, fixed at the foot of
  the viewport because it is about the whole edit rather than about a row.

  `role="status"` with `aria-live="polite"`: it arrives while the reader is
  looking at the page they acted on, and it is an announcement, not a heading.
  The dark surface is the only inverted treatment on this page, because a
  confirmation is not part of the page's reading order and should not look as
  though it were. There is no Undo here: the page has no undoable write yet, and
  a button that has nothing to undo is worse than no button.
  """
  attr :toast, :map, default: nil

  def toast(assigns) do
    ~H"""
    <div
      :if={@toast}
      id="rosters-toast"
      role="status"
      aria-live="polite"
      data-role="rosters-toast"
      data-kind={@toast.kind}
      data-token={@toast.token}
      class="fixed bottom-6 left-1/2 z-[60] flex max-w-[calc(100vw-2rem)] -translate-x-1/2 items-center gap-3 rounded-control bg-neutral px-[18px] py-2 text-sm text-neutral-content shadow-lg"
    >
      <span
        :if={@toast.kind == :refused}
        data-role="toast-icon"
        aria-hidden="true"
        class="inline-flex size-4 shrink-0 items-center justify-center"
      >
        !
      </span>
      <span
        :if={@toast.kind == :done}
        data-role="toast-icon"
        aria-hidden="true"
        class="inline-flex size-4 shrink-0 items-center justify-center"
      >
        &check;
      </span>
      <span id="rosters-toast-text" data-role="toast-text">{@toast.text}</span>

      <button
        type="button"
        phx-click="dismiss_toast"
        data-role="dismiss-toast"
        aria-label="Dismiss"
        class="inline-flex size-11 shrink-0 items-center justify-center rounded-control hover:text-neutral-content/80"
      >
        &times;
      </button>
    </div>
    """
  end

  @doc """
  Renders the page's own states: the first-paint skeleton and the version that
  has no runs to build lines from.

  The two are different facts with different next moves, so they are different
  panels. Loading is this page's first render and says so in words. No runs is a
  settled fact about the version — nothing failed — and its one action goes to
  the page that makes runs, which is the only thing that can change it. It is
  also the page's one primary, which is why the head's Add line is not drawn
  beside it.
  """
  attr :kind, :atom, required: true, values: [:loading, :no_runs]
  attr :version_id, :string, required: true

  def page_state(%{kind: :loading} = assigns) do
    assigns =
      assign(assigns, :weekdays, @weekdays)
      |> assign(:paused_reason, @paused_reason)

    ~H"""
    <div id="rosters-loading" role="status" aria-live="polite" data-role="rosters-state">
      <%!-- `skeleton/1` owns the pulse and hides its inner block from assistive
      tech exactly as the shared component intends, so it draws the grid rows and
      nothing else. The card is this element, not the skeleton: the visible copy
      is the last thing in the card, where the prototype and the restyled Blocks
      page put it — a label above the grid reads as a column heading rather than
      as the state of the page — and a copy in its own box below the card reads as
      a stray sentence. --%>
      <div class="overflow-clip rounded-card border border-subtle bg-white">
        <.skeleton id="rosters-skeleton" rows={0} label="" class="px-0 pb-0 pt-0">
          <div aria-hidden="true">
            <div class="flex items-center gap-1 border-b border-subtle bg-canvas px-2 py-2">
              <div class="w-14 shrink-0 text-[13px] font-semibold text-muted">Line</div>
              <div
                :for={day <- @weekdays}
                class="w-[90px] shrink-0 text-[13px] font-semibold text-muted"
              >
                {day}
              </div>
            </div>
            <div
              :for={_row <- 1..8}
              class="flex items-center gap-1 border-b border-subtle px-2 last:border-b-0"
              style="height:48px"
            >
              <div class="h-5 w-14 shrink-0 rounded-badge bg-canvas"></div>
              <div
                :for={_day <- @weekdays}
                class="h-11 w-[90px] shrink-0 rounded-control bg-canvas"
              >
              </div>
            </div>
          </div>
        </.skeleton>
        <p class="border-t border-subtle px-5 py-3 text-[13px] text-muted">
          Loading roster lines… {@paused_reason}
        </p>
      </div>
    </div>
    """
  end

  def page_state(%{kind: :no_runs} = assigns) do
    ~H"""
    <.first_use id="rosters-no-runs" icon="hero-clock" title="Cut runs first">
      Roster lines are built from runs. Runs split each vehicle’s work between
      operators; each line is then one operator’s week of runs.
      <:action>
        <.button id="rosters-go-to-runs" navigate={~p"/gtfs/#{@version_id}/runs"} class="min-h-11">
          Go to Runs
        </.button>
      </:action>
    </.first_use>
    """
  end
end
