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

  import GtfsPlannerWeb.PlannerComponents, only: [message: 1]

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
