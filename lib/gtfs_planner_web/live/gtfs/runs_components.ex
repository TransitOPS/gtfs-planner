defmodule GtfsPlannerWeb.Gtfs.RunsComponents do
  @moduledoc """
  The Runs page's shell: the head, the scope bar and the load-state panels.

  Everything here is the page's *frame* rather than its content. A later step
  adds the plan, the drawers and the editors into the same frame, so this module
  owns only what the reader sees before there is anything to read: which day
  type is selected, and what the page says when it has nothing to show.

  The composition follows `.specs/08-basic-runs/references/runs-prototype.html`
  at `?state=loading`, `no-blocks` and `load-error`: a head of H1 plus subtitle
  and actions, a scope bar carrying the day-type select beside the date summary,
  and a card holding either the state panel or — from step 22 — the plan.

  The state panels deliberately mirror `BlocksComponents.page_state/1`. The two
  pages are siblings under the Operations bar and reach the same five states
  from the same read, so two vocabularies for the same condition would be a
  cost with no benefit. The copy differs, because the two pages send the reader
  somewhere different when there is nothing to show.
  """

  use GtfsPlannerWeb, :html

  alias GtfsPlannerWeb.Gtfs.BlocksComponents

  @doc """
  Renders the page head: the H1, the subtitle and any head actions.

  The subtitle is the definition a reader needs before the table: a run is one
  operator's day, made of one or two pieces of vehicle work plus report,
  travel, breaks and sign-off. Actions arrive through a slot, and a shell with
  no actions yet renders none — an empty action strip would be a control that
  cannot do anything, and a disabled placeholder would be worse.
  """
  slot :actions

  def page_head(assigns) do
    ~H"""
    <div
      class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between"
      data-role="runs-head"
    >
      <div class="min-w-0">
        <.header>
          Runs
          <:subtitle>
            A run is one operator's day: one or two pieces of vehicle work, with
            report, travel, breaks and sign-off.
          </:subtitle>
        </.header>
      </div>
      <div :if={@actions != []} id="runs-head-actions" class="flex flex-wrap gap-2">
        {render_slot(@actions)}
      </div>
    </div>
    """
  end

  @doc """
  Renders the scope bar: the day-type select, the selected day's date summary
  and the crew-rules summary beside it.

  The select is `BlocksComponents.day_select/1` unchanged. Reusing it is not
  cosmetic: a reader who has learned the Blocks day-type control is already
  holding the knowledge this one asks for, and a second control that looks
  almost the same but is not the same would be worse than either.
  """
  attr :day_types, :list, required: true
  attr :selected, :string, required: true
  attr :disabled, :boolean, default: false

  slot :date_summary
  slot :crew_summary

  def scope_bar(assigns) do
    ~H"""
    <section
      id="runs-scope"
      aria-label="Day type and crew rules"
      class="rounded-card border border-subtle bg-white"
    >
      <div class="flex flex-wrap items-end gap-x-5 gap-y-3 px-4 py-4 sm:px-5">
        <form id="runs-day-form" phx-change="select_day">
          <BlocksComponents.day_select
            id="runs-day"
            day_types={@day_types}
            selected={@selected}
            disabled={@disabled}
          />
        </form>

        <p id="runs-day-dates" class="min-h-11 content-center text-sm text-base-content/70">
          {if @date_summary == [],
            do: date_summary_text(@day_types, @selected),
            else: render_slot(@date_summary)}
        </p>

        <div :if={@crew_summary != []} class="ml-auto">
          {render_slot(@crew_summary)}
        </div>
      </div>
    </section>
    """
  end

  # The date summary reads the selected day type's own figures, so the bar can
  # never claim a day type's dates the read did not return. A day type that is
  # not in the list — an unknown `?day=` — falls back to the "choose one" line
  # rather than rendering an empty gap.
  defp date_summary_text(day_types, selected) do
    case Enum.find(day_types, &(&1.key == selected)) do
      nil -> "Choose a day type to see its service dates."
      day_type -> "#{day_type.label} · #{day_type.date_count} service dates"
    end
  end

  @doc """
  Renders one load state.

  `:loading` is skeleton rows, not a spinner: the shape the plan will take is
  already known, so a skeleton of that shape means the page does not jump when
  the rows arrive. `:unavailable` is a callout rather than a panel, because it is
  not a state the page is in — it is a failure to leave the state it was in, and
  the runs already on screen stay there.
  """
  attr :kind, :atom, required: true
  attr :version_id, :any, default: nil
  attr :day_types, :list, default: []

  # The four states that have a panel. `:loaded` and `:unavailable` are states
  # the page can BE in without a panel here, and the reason is worth stating
  # rather than filling in with an empty box:
  #
  #   * `:unavailable` is presented by `unavailable_callout/0` ABOVE the
  #     content, because a failed reload does not replace the runs the reader is
  #     already looking at. A panel here would be a second, competing surface
  #     for one condition.
  #   * `:loaded` has nothing to put in a card until the plan exists. Rendering
  #     an empty bordered card would read as a failure to load, which is the one
  #     impression this page must never give. The shell therefore renders no
  #     plan card in that state and the plan step fills the same card in.
  #
  # The catch-all is a deliberate guard, not a fallback: it fails loudly naming
  # the states this function handles, so a later step adding a sixth state is
  # told what to do rather than getting a bare FunctionClauseError.
  def page_state(%{kind: kind} = assigns)
      when kind not in [:loaded, :unavailable] do
    render_state_panel(assigns, kind)
  end

  def page_state(%{kind: kind}) do
    raise ArgumentError,
          "RunsComponents.page_state/1 has no panel for #{inspect(kind)}. " <>
            "It renders :loading, :no_dates, :empty and :unknown; :loaded is " <>
            "presented by the plan card and :unavailable by unavailable_callout/0."
  end

  defp render_state_panel(assigns, :loading) do
    ~H"""
    <div id="runs-loading" role="status" aria-live="polite">
      <.skeleton id="runs-skeleton" label="Loading runs…">
        <div class="space-y-2">
          <div class="h-6 w-40 bg-base-300"></div>
          <div :for={_row <- 1..6} class="h-11 w-full bg-base-300"></div>
        </div>
      </.skeleton>
    </div>
    """
  end

  defp render_state_panel(assigns, :no_dates) do
    ~H"""
    <div id="runs-no-dates">
      <.empty_state title="No calendar in this version has a service date.">
        Add the days a calendar runs, then group the trips on those dates into each
        vehicle's work before cutting them into runs.
        <:action>
          <.link
            id="runs-no-dates-link"
            navigate={~p"/gtfs/#{@version_id}/calendars"}
            class="btn btn-primary"
          >
            Open Calendars
          </.link>
        </:action>
      </.empty_state>
    </div>
    """
  end

  defp render_state_panel(assigns, :empty) do
    ~H"""
    <div id="runs-empty">
      <.empty_state title="No blocks to cut into runs">
        Group trips into blocks first. Runs split each vehicle's work between
        operators, so there is nothing to cut until a block exists.
        <:action>
          <.link
            id="runs-empty-link"
            navigate={~p"/gtfs/#{@version_id}/blocks"}
            class="btn btn-primary"
          >
            Go to Blocks
          </.link>
        </:action>
      </.empty_state>
    </div>
    """
  end

  defp render_state_panel(assigns, :unknown) do
    ~H"""
    <div id="runs-unknown-day">
      <.empty_state title="Choose a day type">
        This day type no longer matches the calendars. No day type is applied for you and
        nothing has changed.
        <:action>
          <form id="runs-unknown-day-form" phx-submit="select_day" class="mx-auto max-w-sm">
            <BlocksComponents.day_select id="runs-unknown-day-select" day_types={@day_types} />
            <button type="submit" class="btn btn-primary mt-3">Show selected day</button>
          </form>
        </:action>
      </.empty_state>
    </div>
    """
  end

  @doc """
  Renders the callout shown when a reload failed while runs are already on
  screen.

  This is deliberately not a `page_state/1` panel. A panel replaces the content;
  the runs the reader was looking at are still correct, and the failure is about
  the *next* read, not the current one. So the callout sits above the content,
  the content stays, and retry re-runs the same read with the same URL.
  """
  def unavailable_callout(assigns) do
    ~H"""
    <.callout id="runs-unavailable" kind="error" title="Runs couldn't load.">
      You're seeing the runs that loaded before; nothing has changed.
      <button
        id="runs-retry"
        type="button"
        phx-click="retry"
        class="link link-primary min-h-11"
      >
        Try again
      </button>
    </.callout>
    """
  end

  @doc """
  Renders the plan card. From step 22 this holds the plan itself; until then it
  holds the state panel, so the page has a card of the right shape in both.
  """
  attr :version_id, :any, default: nil
  slot :inner_block

  def plan_card(assigns) do
    ~H"""
    <section
      id="runs-plan"
      aria-label="Runs"
      class="overflow-clip rounded-card border border-subtle bg-white"
    >
      {render_slot(@inner_block)}
    </section>
    """
  end

  @doc """
  Renders the note under the plan, which is a scope statement rather than
  decoration: it says what this page does not change.
  """
  def page_footnote(assigns) do
    ~H"""
    <p id="runs-footnote" class="text-sm text-base-content/70">
      Runs change operator work only. Public trips and vehicle blocks stay as they are.
      Runs appear in the GTFS + operations (TODS) export as <code>run_events.txt</code>.
    </p>
    """
  end
end
