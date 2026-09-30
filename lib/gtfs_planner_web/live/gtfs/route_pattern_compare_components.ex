defmodule GtfsPlannerWeb.Gtfs.RoutePatternCompareComponents do
  @moduledoc """
  The compare page shell and its pattern slots (spec 19, `AC-13`, `AC-14`,
  `AC-16`): the route header, the title row with its view toggle and calendar
  select, the loading skeleton, the unavailable state, and the A/B slot cards
  with the swap between them. The summary card adds the difference list and the
  metric strip (`AC-7`, `AC-9`, `AC-18`); the `#compare-stops` and `#compare-map`
  containers stay empty for the later steps that fill them.

  The ready state owns the `#compare-workspace` grid the containers sit in.
  Every state decision stays in `RoutePatternCompareLive`; these components
  present it. They reuse `RouteWorkspace.route_header/1`,
  `PlannerComponents.message/1` and `<.button>` and add no parallel header,
  callout, button or dialog (`CR-1`).

  The difference sentences are rendered from `Alignment.differences/2`'s detail
  (`INV-5`): the components format the read's values and recompute nothing. The
  item buttons carry the `data-diff-*` attributes the workspace hook reads and
  post no events (`INV-4`).

  A slot card is a box with a coloured left rule, so it rounds only its right
  side (`rounded-r-card`, `CR-3`): A's rule is navy, B's is cyan. The card's
  facts come from the loaded comparison; the "runs on" list reads the calendars
  the read already counted.

  The calendar options read the loaded comparison and the view switch only makes
  sense with content, so both show once a read has succeeded (the prototype hides
  them while loading and after a failure); the title stays, and the state below it
  says what is happening.
  """
  use GtfsPlannerWeb, :html

  # `<.slot>` is this module's own slot-card component. `Phoenix.Component`
  # exports a `slot/1` macro for named-slot declarations, which HEEx would
  # otherwise resolve for the tag, so the import is narrowed.
  import Phoenix.Component, except: [slot: 1]

  import GtfsPlannerWeb.PlannerComponents, only: [message: 1]
  import GtfsPlannerWeb.RouteWorkspace, only: [route_header: 1]

  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlannerWeb.Components.RouteIdentity

  attr :load_state, :atom, required: true, values: [:loading, :unavailable, :ready]

  attr :route, :map,
    default: nil,
    doc: "the loaded route; nil while loading and after a failed read"

  attr :version, :map, required: true, doc: "the current GTFS version"
  attr :view, :atom, required: true, values: [:two, :all], doc: "the URL's `view` param"
  attr :comparison, :map, default: nil, doc: "the loaded comparison; nil before it loads or fails"
  attr :two_path, :string, required: true, doc: "the compare URL with `view` cleared"
  attr :all_path, :string, required: true, doc: "the compare URL with `view=all`"
  attr :patterns_path, :string, required: true, doc: "the route's Patterns tab"

  attr :slot_paths, :map,
    default: nil,
    doc: "per-side `%{change, open, times}` paths for the slot cards"

  attr :reverse_path, :string,
    default: nil,
    doc: "the compare URL with the `reverse` param toggled; nil without a loaded pair"

  def page(assigns) do
    ~H"""
    <div id="compare-page" class="ds-page">
      <.route_header
        route={@route}
        gtfs_version_id={@version.id}
        active_tab={:patterns}
        loading={@load_state == :loading}
      />

      <section id="compare-view" aria-labelledby="compare-title" class="pt-6">
        <div id="compare-toolbar" class="flex flex-wrap items-center gap-x-5 gap-y-3">
          <h2
            id="compare-title"
            class="mr-auto font-display text-[24px] font-semibold leading-tight tracking-[-0.025em] text-strong sm:text-[26px]"
          >
            Compare patterns
          </h2>

          <div
            :if={@load_state == :ready}
            id="compare-view-toggle"
            role="group"
            aria-label="View"
            class="inline-flex rounded-control border border-control bg-white p-0.5"
          >
            <.link
              id="compare-view-two"
              patch={@two_path}
              aria-current={@view == :two && "page"}
              class={view_option_class()}
            >
              <.icon name="hero-view-columns" class="size-4" /> Two patterns
            </.link>
            <.link
              id="compare-view-all"
              patch={@all_path}
              aria-current={@view == :all && "page"}
              class={view_option_class()}
            >
              <.icon name="hero-squares-2x2" class="size-4" /> All patterns
            </.link>
          </div>

          <label :if={@comparison} for="compare-calendar" class="flex items-center gap-2">
            <span class="text-sm font-[650] text-strong">Trips on</span>
            <select
              id="compare-calendar"
              name="service"
              phx-change="select_calendar"
              class="h-11 w-[250px] max-w-full rounded-control border border-control bg-white px-3 text-sm text-strong"
            >
              <option
                :for={calendar <- @comparison.calendars}
                value={calendar.service_id}
                selected={calendar.service_id == @comparison.service_id}
              >
                {calendar_label(calendar, @comparison)}
              </option>
            </select>
          </label>
        </div>

        <%= cond do %>
          <% @load_state == :loading -> %>
            <.loading_skeleton />
          <% @load_state == :unavailable -> %>
            <.unavailable patterns_path={@patterns_path} />
          <% @view == :all -> %>
            <%!-- The all-patterns overview lands in a later step. --%>
          <% true -> %>
            <.two_pattern_containers
              comparison={@comparison}
              slot_paths={@slot_paths}
              reverse_path={@reverse_path}
            />
        <% end %>
      </section>
    </div>
    """
  end

  # The prototype's view switch: an inset group whose current option takes the
  # selection tint. The view is URL state, so each option is a patch link and
  # marks itself with `aria-current`; the target grows to the 44 px control floor
  # the screens all share.
  defp view_option_class do
    [
      "inline-flex min-h-11 items-center gap-2 rounded-control px-3.5 text-sm font-[650] text-muted no-underline",
      "hover:text-strong aria-[current=page]:bg-selection aria-[current=page]:text-action"
    ]
  end

  # "Weekday (A 2 · B 1 trips)", or the A count alone while B is not chosen yet.
  defp calendar_label(calendar, comparison) do
    a_trips = Map.get(calendar.trips, comparison.a.pattern.route_pattern_id, 0)

    case comparison.b do
      nil ->
        "#{calendar.name} (#{a_trips} trips)"

      b ->
        b_trips = Map.get(calendar.trips, b.pattern.route_pattern_id, 0)
        "#{calendar.name} (A #{a_trips} · B #{b_trips} trips)"
    end
  end

  defp loading_skeleton(assigns) do
    ~H"""
    <div id="compare-loading" class="mt-5 motion-safe:animate-pulse" aria-busy="true">
      <p role="status" class="text-sm text-muted">Lining up the stops…</p>

      <div class="mt-3 grid gap-3 md:grid-cols-[minmax(0,1fr)_44px_minmax(0,1fr)]">
        <div class="h-[168px] rounded-card border border-subtle bg-canvas"></div>
        <div></div>
        <div class="h-[168px] rounded-card border border-subtle bg-canvas"></div>
      </div>

      <div class="mt-6 grid gap-6 lg:grid-cols-[minmax(0,1fr)_400px]">
        <div class="grid gap-4">
          <div class="h-40 rounded-card bg-canvas"></div>
          <div class="h-[420px] rounded-card bg-canvas"></div>
        </div>
        <div class="flex h-[620px] items-center justify-center rounded-card bg-canvas text-sm text-muted">
          Loading map…
        </div>
      </div>
    </div>
    """
  end

  defp unavailable(assigns) do
    ~H"""
    <div id="compare-unavailable" class="mt-5 max-w-[720px]">
      <.message kind="error" title="The comparison didn’t load">
        We couldn’t read these two patterns just now. Nothing has changed. Try again, or go back to
        the patterns list.
        <:action>
          <div class="flex flex-wrap items-center gap-3">
            <.button
              id="compare-retry"
              type="button"
              variant="secondary"
              phx-click="retry"
              class="min-h-11"
            >
              <.icon name="hero-arrow-path" class="size-4" /> Try again
            </.button>
            <.link
              id="compare-unavailable-back"
              navigate={@patterns_path}
              class="inline-flex min-h-11 items-center font-[650] text-strong underline"
            >
              Back to patterns
            </.link>
          </div>
        </:action>
      </.message>
    </div>
    """
  end

  # The compare workspace's layout; later steps fill the empty containers. The
  # slots row and the two-column workspace mirror the prototype, including the
  # map's own column, which stacks above the table below `lg`.
  attr :comparison, :map, required: true
  attr :slot_paths, :map, required: true
  attr :reverse_path, :string, default: nil

  defp two_pattern_containers(assigns) do
    ~H"""
    <div id="compare-two-view" class="mt-4">
      <.slots comparison={@comparison} slot_paths={@slot_paths} />

      <.relation :if={@comparison.alignment} comparison={@comparison} reverse_path={@reverse_path} />

      <div
        id="compare-workspace"
        class="mt-6 grid items-start gap-6 lg:grid-cols-[minmax(0,1fr)_minmax(340px,400px)]"
      >
        <div class="grid min-w-0 gap-6">
          <section
            id="compare-summary"
            aria-labelledby="summary-title"
            class="rounded-card border border-subtle bg-white"
          >
            <.summary comparison={@comparison} />
          </section>
          <section id="compare-stops" aria-label="Stop by stop"></section>
        </div>
        <aside
          id="compare-map-pane"
          aria-label="Map of both patterns"
          class="max-lg:order-first lg:sticky lg:top-4"
        >
          <div id="compare-map"></div>
        </aside>
      </div>
    </div>
    """
  end

  # The two slot cards with the swap control between them (AC-16). The swap is
  # the middle column's one control; it is disabled until a B is chosen. Change
  # and the timing select are patch targets and swap is a server event, so the
  # URL keeps the whole selection (`INV-4`).
  attr :comparison, :map, required: true
  attr :slot_paths, :map, required: true

  defp slots(assigns) do
    ~H"""
    <div
      id="compare-slots"
      class="grid items-stretch gap-3 md:grid-cols-[minmax(0,1fr)_44px_minmax(0,1fr)]"
    >
      <.slot
        id="slot-a"
        letter="A"
        comparison={@comparison}
        side={@comparison.a}
        paths={@slot_paths.a}
        reversed?={reversed?(@comparison)}
      />

      <div class="flex items-center justify-center">
        <.button
          id="compare-swap"
          type="button"
          variant="secondary"
          phx-click="swap"
          disabled={is_nil(@comparison.b)}
          aria-label="Swap A and B"
          title="Swap A and B"
          class="btn-square min-h-11 min-w-11 p-0"
        >
          <.icon name="hero-arrows-right-left" class="size-5 max-md:rotate-90" />
        </.button>
      </div>

      <.slot
        id="slot-b"
        letter="B"
        comparison={@comparison}
        side={@comparison.b}
        unavailable_id={unavailable_id(@comparison)}
        paths={@slot_paths.b}
        reversed?={reversed?(@comparison)}
      />
    </div>
    """
  end

  # The relationship between the two patterns (AC-4, AC-17), between the slots
  # and the workspace. At most one callout renders, in the prototype's order:
  # the reversed view first (the URL asked for B reversed), then an opposite
  # pair, then identical stops, then a pair with no shared stops. Each is a
  # `PlannerComponents.message` with its kind's own icon, so the state is never
  # carried by colour alone (`CR-1`). The reverse toggle is a patch, so the URL
  # keeps the whole selection (`INV-4`).
  attr :comparison, :map, required: true
  attr :reverse_path, :string, required: true

  def relation(%{comparison: %{alignment: %{reversed?: true}}} = assigns) do
    ~H"""
    <.message
      id="relation-reversed"
      kind="info"
      class="mt-4"
      title="B is shown in reverse order"
    >
      <.series_chip letter="B" />
      runs {RoutePattern.direction_label(@comparison.b.pattern.direction_id)}.
      Its stops are listed last to first so they line up with
      <.series_chip letter="A" />; its stop numbers
      count down. Running times aren’t compared while B is reversed, because its times run the other way.
      <:action>
        <.reverse_toggle label="Show B in its own order" path={@reverse_path} />
      </:action>
    </.message>
    """
  end

  def relation(%{comparison: %{alignment: %{opposite?: true}}} = assigns) do
    ~H"""
    <.message
      id="relation-opposite"
      kind="info"
      class="mt-4"
      title="These patterns run in opposite directions"
    >
      <.series_chip letter="B" /> serves most of the same stops in reverse order. To see where the two
      directions serve different stops, show B in reverse order.
      <:action>
        <.reverse_toggle label="Show B in reverse order" path={@reverse_path} />
      </:action>
    </.message>
    """
  end

  def relation(%{comparison: %{alignment: %{identical?: true}}} = assigns) do
    assigns = assign(assigns, :stop_count, plural(length(assigns.comparison.a.stops), "stop"))

    ~H"""
    <.message
      id="relation-identical"
      kind="success"
      class="mt-4"
      title="Same stops in the same order"
    >
      <.series_chip letter="A" /> and <.series_chip letter="B" />
      serve the same {@stop_count} in the same
      order. They differ only in running times and trips.
    </.message>
    """
  end

  def relation(%{comparison: %{alignment: %{counts: %{shared: 0}}}} = assigns) do
    ~H"""
    <.message
      id="relation-none"
      kind="neutral"
      class="mt-4"
      title="These patterns share no stops"
    >
      Nothing lines up, so <.series_chip letter="A" />’s stops are listed first and
      <.series_chip letter="B" />’s after them, and running times aren’t compared. The map shows where
      each runs.
    </.message>
    """
  end

  def relation(assigns), do: ~H""

  # The summary card (`AC-7`, `AC-9`, `AC-18`): the stop-count line, the numbered
  # difference list, the smaller-timing note and the metric strip (end to end,
  # trips and departures by hour). With B absent it renders the "Suggested
  # comparisons" links instead (`AC-15`). The item buttons carry `data-diff-*`
  # for the workspace hook and post no events (`INV-4`).
  attr :comparison, :map, required: true

  def summary(%{comparison: %{b: nil}} = assigns) do
    assigns = assign(assigns, :calendar_name, calendar_name(assigns.comparison))

    ~H"""
    <div id="summary-suggestions" class="px-5 py-5">
      <h3 id="summary-title" class="font-sans text-base font-bold">Suggested comparisons</h3>
      <p class="mt-1 text-sm text-default">
        Other patterns in the same direction as
        <.series_chip letter="A" />, most used on {@calendar_name} first.
      </p>
      <ul class="mt-3 grid gap-2">
        <li :for={suggestion <- @comparison.suggestions}>
          <.link
            id={"summary-suggestion-" <> suggestion.route_pattern_id}
            patch={suggestion_path(@comparison, suggestion)}
            class="flex min-h-14 w-full items-center gap-3 rounded-control border border-subtle px-4 py-2 text-left hover:border-control hover:bg-canvas"
          >
            <span class="min-w-0 flex-1">
              <span class="block text-sm font-[650] text-strong">{suggestion.name}</span>
              <span class="block text-[13px] text-muted">
                {suggestion_meta(@comparison, suggestion, @calendar_name)}
              </span>
            </span>
            <span class="shrink-0 text-sm font-[650] text-action">Compare</span>
          </.link>
        </li>
      </ul>
    </div>
    """
  end

  def summary(assigns) do
    comparison = assigns.comparison
    alignment = comparison.alignment
    counts = alignment.counts

    assigns =
      assigns
      |> assign(:alignment, alignment)
      |> assign(:counts, counts)
      |> assign(:items, if(counts.shared == 0, do: [], else: alignment.differences.items))
      |> assign(:smaller_timing, alignment.differences.smaller_timing)
      |> assign(:calendar_name, calendar_name(comparison))
      |> assign(:hour_max, hour_max(comparison))
      |> assign(:timed?, timed?(comparison))

    ~H"""
    <div id="summary-differences" class="px-5 pb-4 pt-5">
      <div class="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
        <h3 id="summary-title" class="font-sans text-base font-bold">What’s different</h3>
        <p
          id="summary-counts"
          class="flex flex-wrap items-center gap-x-2 gap-y-1 text-sm text-default"
        >
          <span class="flex items-center gap-1">
            Stops:<.sentence_part :for={part <- count_parts(@comparison)} part={part} />
          </span>
        </p>
      </div>

      <ol :if={@items != []} class="mt-3 grid gap-1">
        <li :for={{item, index} <- Enum.with_index(@items)}>
          <button
            type="button"
            id={"summary-diff-#{index + 1}"}
            data-diff-index={index}
            data-diff-rows={Enum.join(item.rows, ",")}
            data-diff-stops={Enum.join(difference_stops(item, @comparison), ",")}
            aria-pressed="false"
            class="group flex min-h-11 w-full items-start gap-3 rounded-control px-2 py-2 text-left hover:bg-canvas aria-pressed:bg-selection"
          >
            <span class="mt-px inline-flex size-6 shrink-0 items-center justify-center rounded-full bg-inverse text-[12px] font-bold text-white group-aria-pressed:bg-action">
              {index + 1}
            </span>
            <span class="min-w-0 flex-1 text-sm leading-relaxed text-default">
              <.sentence_part :for={part <- sentence_parts(item, @comparison)} part={part} />
            </span>
            <span class="mt-0.5 hidden shrink-0 text-[13px] font-[650] text-action sm:inline">
              Show
            </span>
          </button>
        </li>
      </ol>

      <p
        :if={@items == [] and @counts.shared > 0}
        class="mt-3 flex items-center gap-2 text-sm text-default"
      >
        <.icon name="hero-check" class="size-4 text-success-fg" />
        {if @timed?,
          do: "No differences in stops or running times.",
          else: "No differences in stops."}
      </p>

      <p
        :if={@smaller_timing > 0}
        id="summary-smaller-timing"
        class="mt-1 px-2 text-[13px] text-muted"
      >
        {plural(@smaller_timing, "smaller timing difference")}
        {if @smaller_timing == 1, do: "is", else: "are"} in the stop list.
      </p>
    </div>

    <dl class="grid gap-px border-t border-subtle bg-subtle sm:grid-cols-[1fr_1fr_1.4fr]">
      <div class="bg-canvas px-5 py-3">
        <dt class="text-[13px] font-[650] text-muted">End to end (min:sec)</dt>
        <dd id="summary-end" class="mt-1 grid gap-0.5 text-sm text-strong">
          <span class="flex items-center gap-2">
            <.series_chip letter="A" />
            <span
              id="summary-end-a"
              class={["tabular-nums", is_nil(@alignment.end_a) && "text-muted"]}
            >
              {end_value(@alignment.end_a)}
            </span>
          </span>
          <span class="flex items-center gap-2">
            <.series_chip letter="B" />
            <span
              id="summary-end-b"
              class={["tabular-nums", is_nil(@alignment.end_b) && "text-muted"]}
            >
              {end_value(@alignment.end_b)}
            </span>
            <span
              :if={is_integer(@alignment.end_change)}
              id="summary-end-change"
              class="text-[13px] font-[650] text-muted"
            >
              {change_label(@alignment)}
            </span>
          </span>
        </dd>
      </div>

      <div class="bg-canvas px-5 py-3">
        <dt class="text-[13px] font-[650] text-muted">Trips on {@calendar_name}</dt>
        <dd id="summary-trips" class="mt-1 grid gap-0.5 text-sm text-strong">
          <span class="flex items-center gap-2">
            <.series_chip letter="A" />
            <span id="summary-trips-a" class="tabular-nums">{@comparison.a.usage.total}</span>
          </span>
          <span class="flex items-center gap-2">
            <.series_chip letter="B" />
            <span id="summary-trips-b" class="tabular-nums">{@comparison.b.usage.total}</span>
          </span>
        </dd>
      </div>

      <div class="bg-canvas px-5 py-3">
        <dt class="text-[13px] font-[650] text-muted">Departures by hour, 05:00 to midnight</dt>
        <dd class="mt-1.5 grid gap-1.5">
          <.hour_bars letter="A" hours={@comparison.a.usage.hours} max={@hour_max} />
          <.hour_bars letter="B" hours={@comparison.b.usage.hours} max={@hour_max} />
        </dd>
      </div>
    </dl>
    """
  end

  # The difference sentence is a list of text, bold name, series chip and count
  # parts so the chips sit inside the copy; every part is escaped unless it is
  # this module's own markup.
  attr :part, :any, required: true

  defp sentence_part(%{part: {:text, text}} = assigns) do
    assigns = assign(assigns, :text, text)
    ~H"{@text}"
  end

  defp sentence_part(%{part: {:bold, text}} = assigns) do
    assigns = assign(assigns, :text, text)
    ~H"<b>{@text}</b>"
  end

  defp sentence_part(%{part: {:count, count}} = assigns) do
    assigns = assign(assigns, :count, count)
    ~H|<span class="font-[650] tabular-nums text-strong">{@count}</span>|
  end

  defp sentence_part(%{part: {:chip, letter}} = assigns) do
    assigns = assign(assigns, :letter, letter)
    ~H"<.series_chip letter={@letter} />"
  end

  # The stop-count line: "12 in common · 1 only in A · 2 only in B · 4 in a
  # different order", with a zero count dropped and the separators spaced like
  # the reference's flex row (the reference's counts line).
  defp count_parts(comparison) do
    %{shared: shared, a_only: a_only, b_only: b_only, moved: moved} = comparison.alignment.counts

    [
      [{:text, " "}, {:count, shared}, {:text, " in common"}],
      a_only > 0 && [{:count, a_only}, {:text, " only in "}, {:chip, "A"}],
      b_only > 0 && [{:count, b_only}, {:text, " only in "}, {:chip, "B"}],
      moved > 0 && [{:count, moved}, {:text, " in a different order"}]
    ]
    |> Enum.reject(&(&1 == false))
    |> Enum.intersperse([{:text, " · "}])
    |> List.flatten()
  end

  # The sentence templates follow the reference engine's `differences()` wording;
  # `Alignment.differences/2` supplies only the detail (`INV-5`).
  defp sentence_parts(%{kind: :stops, detail: detail}, comparison) do
    stop_parts(detail, comparison) ++ segment_parts(detail.segment)
  end

  defp sentence_parts(%{kind: :moved, detail: %{count: 1}} = item, comparison) do
    {a_row, b_row} = moved_pair(item, comparison)

    [
      {:chip, "B"},
      {:text, " serves "},
      {:bold, stop_name(comparison, a_row.stop_id)},
      {:text,
       " #{if b_row.b_pos < a_row.a_pos, do: "earlier", else: "later"} in the trip: stop "},
      {:text, Integer.to_string(b_row.b_pos)},
      {:text, " of "},
      {:text, Integer.to_string(length(comparison.b.stops))},
      {:text, ", not stop "},
      {:text, Integer.to_string(a_row.a_pos)},
      {:text, " of "},
      {:text, Integer.to_string(length(comparison.a.stops))},
      {:text, "."}
    ]
  end

  defp sentence_parts(%{kind: :moved, detail: %{count: count}} = item, comparison) do
    {a_row, b_row} = moved_pair(item, comparison)

    [
      {:text, "#{count} stops are served in a different order, such as "},
      {:bold, stop_name(comparison, a_row.stop_id)},
      {:text, ": stop "},
      {:text, Integer.to_string(b_row.b_pos)},
      {:text, " in "},
      {:chip, "B"},
      {:text, ", stop "},
      {:text, Integer.to_string(a_row.a_pos)},
      {:text, " in "},
      {:chip, "A"},
      {:text, "."}
    ]
  end

  defp sentence_parts(%{kind: :boarding, rows: [index], detail: detail}, comparison) do
    stop_id = comparison.alignment.rows |> Enum.at(index) |> Map.fetch!(:stop_id)

    [
      {:text, "At "},
      {:bold, stop_name(comparison, stop_id)},
      {:text, ", "},
      {:chip, "B"},
      {:text, " " <> boarding_label(detail.b) <> "; "},
      {:chip, "A"},
      {:text, " " <> boarding_label(detail.a) <> "."}
    ]
  end

  defp sentence_parts(%{kind: :time, detail: %{segment: segment}}, comparison) do
    [
      {:text, "From "},
      {:bold, stop_name(comparison, row_stop(comparison, segment.from))},
      {:text, " to "},
      {:bold, stop_name(comparison, row_stop(comparison, segment.to))},
      {:text, ", "},
      {:chip, "B"},
      {:text, " allows "},
      {:text, format_words(segment.diff)},
      {:text, if(segment.diff > 0, do: " more", else: " less")},
      {:text, " ("},
      {:text, format_duration(segment.b_secs)},
      {:text, " against "},
      {:text, format_duration(segment.a_secs)},
      {:text, ")."}
    ]
  end

  defp stop_parts(%{before: nil, after: nil}, _comparison),
    do: [{:text, "These patterns share no stops."}]

  defp stop_parts(%{before: nil, after: after_, a_only: a_only, b_only: b_only}, comparison),
    do: start_parts(after_, a_only, b_only, comparison)

  defp stop_parts(%{before: before, after: nil, a_only: a_only, b_only: b_only}, comparison),
    do: end_parts(before, a_only, b_only, comparison)

  defp stop_parts(%{before: before, after: after_} = detail, comparison) do
    if detail.a_only != [] and detail.b_only != [] do
      [
        {:text, "Between "},
        {:bold, stop_name(comparison, before)},
        {:text, " and "},
        {:bold, stop_name(comparison, after_)},
        {:text, ", "},
        {:chip, "B"},
        {:text, " serves "},
        {:text, list_names(comparison, detail.b_only)},
        {:text, " instead of "},
        {:text, list_names(comparison, detail.a_only)},
        {:text, "."}
      ]
    else
      {verb, ids} =
        if detail.b_only != [], do: {"adds", detail.b_only}, else: {"skips", detail.a_only}

      [
        {:chip, "B"},
        {:text, " #{verb} "},
        {:text, list_names(comparison, ids)},
        {:text, " between "},
        {:bold, stop_name(comparison, before)},
        {:text, " and "},
        {:bold, stop_name(comparison, after_)},
        {:text, "."}
      ]
    end
  end

  defp start_parts(after_, [], b_only, comparison) do
    [
      {:chip, "B"},
      {:text, " starts "},
      {:text, Integer.to_string(length(b_only))},
      {:text, plural_suffix(b_only)},
      {:text, " earlier, at "},
      {:bold, stop_name(comparison, hd(b_only))},
      {:text, ", and joins "},
      {:chip, "A"},
      {:text, " at "},
      {:bold, stop_name(comparison, after_)},
      {:text, "."}
    ]
  end

  defp start_parts(after_, a_only, [], comparison) do
    [
      {:chip, "B"},
      {:text, " starts at "},
      {:bold, stop_name(comparison, after_)},
      {:text, ". "},
      {:chip, "A"},
      {:text, " starts "},
      {:text, Integer.to_string(length(a_only))},
      {:text, plural_suffix(a_only)},
      {:text, " earlier, at "},
      {:bold, stop_name(comparison, hd(a_only))},
      {:text, "."}
    ]
  end

  defp start_parts(after_, a_only, b_only, comparison) do
    [
      {:text, "They start at different stops: "},
      {:chip, "A"},
      {:text, " at "},
      {:bold, stop_name(comparison, hd(a_only))},
      {:text, ", "},
      {:chip, "B"},
      {:text, " at "},
      {:bold, stop_name(comparison, hd(b_only))},
      {:text, ". Both reach "},
      {:bold, stop_name(comparison, after_)},
      {:text, "."}
    ]
  end

  defp end_parts(before, a_only, [], comparison) do
    [
      {:chip, "B"},
      {:text, " ends at "},
      {:bold, stop_name(comparison, before)},
      {:text, ". "},
      {:chip, "A"},
      {:text, " continues "},
      {:text, Integer.to_string(length(a_only))},
      {:text, " more "},
      {:text, if(length(a_only) == 1, do: "stop", else: "stops")},
      {:text, " to "},
      {:bold, stop_name(comparison, List.last(a_only))},
      {:text, "."}
    ]
  end

  defp end_parts(before, [], b_only, comparison) do
    [
      {:chip, "B"},
      {:text, " continues past "},
      {:bold, stop_name(comparison, before)},
      {:text, " to "},
      {:text, list_names(comparison, b_only)},
      {:text, "."}
    ]
  end

  defp end_parts(before, a_only, b_only, comparison) do
    [
      {:text, "After "},
      {:bold, stop_name(comparison, before)},
      {:text, " they end at different stops: "},
      {:chip, "A"},
      {:text, " at "},
      {:bold, stop_name(comparison, List.last(a_only))},
      {:text, ", "},
      {:chip, "B"},
      {:text, " at "},
      {:bold, stop_name(comparison, List.last(b_only))},
      {:text, "."}
    ]
  end

  defp segment_parts(nil), do: []
  defp segment_parts(%{diff: nil}), do: []
  defp segment_parts(%{diff: 0}), do: [{:text, " The stretch takes the same time in both."}]

  defp segment_parts(%{diff: diff, a_secs: a_secs, b_secs: b_secs}) do
    [
      {:text, " That stretch takes "},
      {:chip, "B"},
      {:text, " " <> format_words(diff) <> if(diff > 0, do: " longer", else: " less") <> " ("},
      {:text, format_duration(b_secs)},
      {:text, " against "},
      {:text, format_duration(a_secs)},
      {:text, ")."}
    ]
  end

  defp moved_pair(item, comparison) do
    rows = comparison.alignment.rows
    a_index = Enum.find(item.rows, &match?(%{type: :a}, Enum.at(rows, &1)))
    a_row = Enum.at(rows, a_index)

    {a_row, Enum.at(rows, a_row.moved_to)}
  end

  defp row_stop(comparison, index),
    do: comparison.alignment.rows |> Enum.at(index) |> Map.fetch!(:stop_id)

  defp stop_name(comparison, stop_id) do
    case Map.get(comparison.stops_by_id, stop_id) do
      %{stop_name: name} when is_binary(name) and name != "" -> name
      _ -> stop_id
    end
  end

  defp list_names(comparison, [stop_id]), do: stop_name(comparison, stop_id)

  defp list_names(comparison, ids) do
    names = Enum.map(ids, &stop_name(comparison, &1))

    if length(names) > 4 do
      Enum.take(names, 3) |> Enum.join(", ") |> Kernel.<>(" and #{length(names) - 3} more")
    else
      {last, rest} = List.pop_at(names, -1)
      Enum.join(rest, ", ") <> " and " <> last
    end
  end

  defp plural_suffix([_one]), do: " stop"
  defp plural_suffix(_ids), do: " stops"

  defp boarding_label(%{pickup_type: 1, drop_off_type: 1}), do: "passes without stopping"
  defp boarding_label(%{pickup_type: 1}), do: "only lets riders off"
  defp boarding_label(%{drop_off_type: 1}), do: "only picks riders up"
  defp boarding_label(_row), do: "picks up and lets off"

  defp difference_stops(item, comparison) do
    rows = comparison.alignment.rows

    item.frame
    |> Enum.map(&Enum.at(rows, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(& &1.stop_id)
    |> Enum.uniq()
  end

  defp end_value(nil), do: "No running times"
  defp end_value(secs), do: format_duration(secs)

  defp change_label(%{end_change: change, end_percent: nil}), do: format_change(change)

  defp change_label(%{end_change: change, end_percent: percent}),
    do: "#{format_change(change)} (#{format_percent(percent)})"

  defp format_change(0), do: "Same"

  defp format_change(secs),
    do: "#{if secs > 0, do: "+", else: "−"}#{format_duration(secs)}"

  defp format_percent(0), do: "0%"
  defp format_percent(percent) when percent > 0, do: "+#{percent}%"
  defp format_percent(percent), do: "−#{abs(percent)}%"

  defp format_duration(secs) do
    secs = abs(secs)
    "#{div(secs, 60)}:#{String.pad_leading(Integer.to_string(rem(secs, 60)), 2, "0")}"
  end

  defp format_words(secs) do
    secs = abs(secs)
    minutes = div(secs, 60)
    rest = rem(secs, 60)

    cond do
      minutes == 0 -> "#{rest} s"
      rest == 0 -> "#{minutes} min"
      true -> "#{minutes} min #{rest} s"
    end
  end

  defp timed?(comparison) do
    not is_nil(comparison.a.timing_id) and not is_nil(comparison.b && comparison.b.timing_id) and
      not reversed?(comparison)
  end

  defp hour_max(comparison) do
    comparison.a.usage.hours
    |> Enum.concat(comparison.b.usage.hours)
    |> Enum.max(fn -> 0 end)
    |> max(1)
  end

  defp suggestion_path(comparison, suggestion) do
    route = comparison.route

    params =
      [{"a", comparison.a.pattern.route_pattern_id}, {"b", suggestion.route_pattern_id}] ++
        if(comparison.service_id, do: [{"service", comparison.service_id}], else: [])

    "/gtfs/#{route.gtfs_version_id}/routes/#{route.route_id}/patterns/compare?" <>
      URI.encode_query(params)
  end

  defp suggestion_meta(comparison, suggestion, calendar_name) do
    trips =
      if suggestion.trips > 0,
        do: "#{plural(suggestion.trips, "trip")} on #{calendar_name}",
        else: "not used on #{calendar_name}"

    "#{suggestion.shared} of #{length(comparison.a.stops)} stops in common · #{trips}"
  end

  # The departures-by-hour chart: 05:00 to midnight, 20 bars per side on one
  # scale, the count in the bar's tooltip (the reference's `hoursChart`).
  attr :letter, :string, required: true, values: ["A", "B"]
  attr :hours, :list, required: true
  attr :max, :integer, required: true

  defp hour_bars(assigns) do
    ~H"""
    <div class="flex items-center gap-2">
      <.series_chip letter={@letter} />
      <div
        data-hour-bars={String.downcase(@letter)}
        class="grid h-7 flex-1 grid-cols-[repeat(20,minmax(0,1fr))] items-end gap-[2px]"
      >
        <span
          :for={hour <- 5..24}
          data-hour-bar={"#{String.downcase(@letter)}-#{hour}"}
          class={[
            "block min-w-0 rounded-t-[2px]",
            hour_bar_class(@letter, hour_count(@hours, hour))
          ]}
          style={"height: #{hour_bar_height(hour_count(@hours, hour), @max)}%"}
          title={hour_bar_title(hour, hour_count(@hours, hour))}
        >
        </span>
      </div>
    </div>
    """
  end

  defp hour_count(hours, hour), do: Enum.at(hours, rem(hour, 24), 0)

  defp hour_bar_class(_letter, 0), do: "bg-subtle/40"
  defp hour_bar_class("A", _count), do: "bg-navy-800"
  defp hour_bar_class("B", _count), do: "bg-cyan-700"

  defp hour_bar_height(0, _max), do: 6
  defp hour_bar_height(count, max), do: max(18, round(count / max * 100))

  defp hour_bar_title(hour, count) do
    "#{clock(rem(hour * 60, 1440))}–#{clock(rem((hour + 1) * 60, 1440))}: #{plural(count, "trip")}"
  end

  defp clock(minutes) do
    "#{String.pad_leading(Integer.to_string(div(minutes, 60)), 2, "0")}:#{String.pad_leading(Integer.to_string(rem(minutes, 60)), 2, "0")}"
  end

  attr :label, :string, required: true
  attr :path, :string, required: true

  defp reverse_toggle(assigns) do
    ~H"""
    <.button
      id="compare-reverse-toggle"
      type="button"
      variant="secondary"
      patch={@path}
      class="min-h-11 gap-2"
    >
      <.icon name="hero-arrows-up-down" class="size-4" /> {@label}
    </.button>
    """
  end

  defp reversed?(%{alignment: %{reversed?: reversed?}}), do: reversed?
  defp reversed?(_comparison), do: false

  attr :id, :string, required: true
  attr :letter, :string, required: true, values: ["A", "B"]
  attr :comparison, :map, required: true

  attr :side, :map,
    default: nil,
    doc: "the loaded side; nil renders this side's empty or unavailable card"

  attr :unavailable_id, :string,
    default: nil,
    doc: "the requested ID when the side did not resolve"

  attr :paths, :map, required: true, doc: "this side's `%{change, open, times}` paths"

  attr :reversed?, :boolean,
    default: false,
    doc: "the URL asked for B reversed; B's meta line says so"

  def slot(assigns) do
    assigns =
      assigns
      |> assign(:calendar_name, calendar_name(assigns.comparison))
      |> assign(:used_calendars, used_calendars(assigns.side, assigns.comparison.calendars))
      |> assign(:pattern_name, pattern_name(assigns.side))
      |> assign(:route_name, route_name(assigns.side))
      |> assign(:other_route?, other_route?(assigns))
      |> assign(:meta_line, meta_line(assigns.side))
      |> assign(:empty_id, empty_id(assigns))

    assigns = assign(assigns, trips(assigns))

    ~H"""
    <div :if={is_nil(@side)} id={@empty_id} class={empty_card_class(@letter, @unavailable_id)}>
      <div class="flex items-start gap-3">
        <.series_chip letter={@letter} />
        <div class="min-w-0">
          <p class={["text-[15px] font-bold", empty_ink(@unavailable_id)]}>
            {empty_title(@letter, @unavailable_id)}
          </p>
          <p class={["mt-1 text-sm", empty_ink(@unavailable_id)]}>
            <%= if @unavailable_id do %>
              The link asked for pattern <span class="font-mono text-[13px]">{@unavailable_id}</span>,
              which isn’t in this version. It may have been deleted or renamed. Choose another
              pattern to compare.
            <% else %>
              Any pattern in this version, on this route or another one.
            <% end %>
          </p>
        </div>
      </div>
      <div>
        <.button type="button" patch={@paths.change} class="min-h-11 gap-2">
          <.icon name="hero-magnifying-glass" class="size-4" /> Choose pattern {@letter}
        </.button>
      </div>
    </div>

    <article
      :if={@side}
      id={@id}
      class={card_class(@letter)}
      aria-label={"Pattern " <> @letter}
    >
      <div class="flex items-start gap-3">
        <.series_chip letter={@letter} />
        <div class="min-w-0 flex-1">
          <h3 class="flex flex-wrap items-center gap-x-2 font-sans text-[15px] font-bold leading-snug text-strong">
            <RouteIdentity.route_badge :if={@other_route?} route={@side.route} />
            <span :if={@other_route?} class="font-[650]">{@route_name} ·</span>
            <span>{@pattern_name}</span>
          </h3>
          <p class="mt-0.5 text-[13px] text-muted">
            {@meta_line}<span
              :if={@letter == "B" and @reversed?}
              class="font-[650] text-info-fg"
            > · shown in reverse order</span>
          </p>
          <p class="mt-0.5 text-sm text-default">
            <span class="font-[650] tabular-nums text-strong">{@trips_lead}</span>{@trips_after}<span
              :if={@trips_note}
              class="text-muted"
            > · {@trips_note}</span>
          </p>
        </div>
        <.button
          id={@id <> "-change"}
          type="button"
          variant="secondary"
          patch={@paths.change}
          class="min-h-11 shrink-0"
        >
          Change {@letter}
        </.button>
      </div>

      <div class="mt-2 flex flex-wrap items-center gap-x-3 gap-y-1 pl-8">
        <label :if={@side.timings != []} class="flex min-w-0 items-center gap-2">
          <span class="shrink-0 text-[13px] font-[650] text-strong">Running times</span>
          <select
            id={@id <> "-timing"}
            name={timing_param(@letter)}
            phx-change="select_timing"
            class="h-11 min-w-0 max-w-[290px] rounded-control border border-control bg-white px-3 text-sm text-strong"
          >
            <option
              :for={timing <- @side.timings}
              value={timing.id}
              selected={timing.id == @side.timing_id}
            >
              {timing_label(timing)}
            </option>
          </select>
        </label>

        <p
          :if={@side.timings == []}
          class="flex min-h-11 flex-wrap items-center gap-x-3 text-sm text-default"
        >
          <span class="text-[13px] font-[650] text-strong">Running times</span>
          None yet
          <.link
            id={@id <> "-add-times"}
            navigate={@paths.times}
            class="inline-flex min-h-11 items-center font-[650] text-action underline"
          >
            Add running times
          </.link>
        </p>

        <.link
          id={@id <> "-open"}
          navigate={@paths.open}
          class="ml-auto inline-flex min-h-11 items-center gap-1.5 rounded-control px-1 text-sm font-[650] text-action hover:underline"
        >
          Open pattern<.icon name="hero-arrow-top-right-on-square" class="size-4" />
        </.link>
      </div>
    </article>
    """
  end

  attr :letter, :string, required: true, values: ["A", "B"]

  defp series_chip(assigns) do
    ~H"""
    <span
      class={[
        "inline-flex size-[18px] shrink-0 items-center justify-center rounded-badge align-[-3px] text-[11px] font-bold leading-none text-white",
        series_chip_class(@letter)
      ]}
      title={"Pattern " <> @letter}
    >
      {@letter}
    </span>
    """
  end

  # A's series colour is the DS navy (the ramp has no 700, so the darkest navy
  # token is the closest match to the prototype's navy-700); B's is cyan-700.
  defp series_border("A"), do: "border-l-navy-800"
  defp series_border("B"), do: "border-l-cyan-700"

  defp series_chip_class("A"), do: "bg-navy-800"
  defp series_chip_class("B"), do: "bg-cyan-700"

  defp card_class(letter) do
    [
      "flex h-full flex-col rounded-r-card border border-l-4 border-subtle bg-white px-4 pb-3 pt-3",
      series_border(letter)
    ]
  end

  defp empty_card_class(letter, unavailable_id) do
    [
      "flex h-full flex-col justify-center gap-3 rounded-r-card border border-l-4 px-5 py-5",
      series_border(letter),
      if(unavailable_id,
        do: "border-error-line bg-error-bg",
        else: "border-dashed border-control bg-canvas"
      )
    ]
  end

  defp empty_ink(nil), do: "text-strong"
  defp empty_ink(_unavailable_id), do: "text-error-fg"

  defp empty_title(_letter, nil), do: "Choose a pattern to compare"
  defp empty_title(letter, _unavailable_id), do: "Pattern #{letter} isn’t available"

  defp empty_id(assigns) do
    if assigns.unavailable_id, do: assigns.id <> "-unavailable", else: assigns.id <> "-empty"
  end

  defp unavailable_id(%{b_error: {:not_found, pattern_id}}), do: pattern_id
  defp unavailable_id(_comparison), do: nil

  defp timing_param("A"), do: "ta"
  defp timing_param("B"), do: "tb"

  # "Weekday base · 2 trips", or the bare name when that timing carries none on
  # the chosen calendar (the prototype's option label).
  defp timing_label(timing) do
    if timing.trips > 0, do: "#{timing.name} · #{plural(timing.trips, "trip")}", else: timing.name
  end

  # The card's one meta line: direction, stops, use and the service description
  # when the pattern has one, in the prototype's order.
  defp meta_line(nil), do: nil

  defp meta_line(side) do
    [
      RoutePattern.direction_label(side.pattern.direction_id),
      plural(length(side.stops), "stop"),
      RoutePattern.typicality_label(side.pattern.route_pattern_typicality),
      service_description(side)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp service_description(%{pattern: %{route_pattern_time_desc: description}}) do
    if blank?(description), do: nil, else: description
  end

  defp service_description(_side), do: nil

  defp pattern_name(nil), do: nil

  defp pattern_name(%{pattern: %{route_pattern_name: name, route_pattern_id: pattern_id}}) do
    if blank?(name), do: pattern_id, else: name
  end

  # The badge already carries the short name, so the heading leads with the long
  # name and falls back through the same fields the route header uses.
  defp route_name(nil), do: nil

  defp route_name(%{route: route}) do
    [route.route_long_name, route.route_short_name, route.route_id]
    |> Enum.find(&(is_binary(&1) and String.trim(&1) != ""))
  end

  defp other_route?(%{letter: "B", side: side} = assigns) when not is_nil(side) do
    side.route.route_id != assigns.comparison.route.route_id
  end

  defp other_route?(_assigns), do: false

  # The pattern's trips on the chosen calendar (AC-9), or the calendars it is
  # used on; both read the counts the comparison already loaded. Only the count
  # is bold, as the prototype has it.
  defp trips(%{side: nil}), do: %{trips_lead: nil, trips_after: nil, trips_note: nil}

  defp trips(assigns) do
    usage = assigns.side.usage

    if usage.total > 0 do
      %{
        trips_lead: plural(usage.total, "trip"),
        trips_after: " on " <> assigns.calendar_name,
        trips_note: trip_notes(usage)
      }
    else
      note =
        case assigns.used_calendars do
          [] -> "no trips in this version"
          names -> "runs on " <> Enum.join(names, ", ")
        end

      %{
        trips_lead: "Not used on " <> assigns.calendar_name,
        trips_after: nil,
        trips_note: note
      }
    end
  end

  defp trip_notes(usage) do
    [
      usage.custom > 0 && "#{usage.custom} with their own times",
      usage.repeating > 0 && "#{usage.repeating} from a repeating trip"
    ]
    |> Enum.reject(&(&1 == false))
    |> Enum.join(" · ")
    |> blank_to_nil()
  end

  defp used_calendars(nil, _calendars), do: []

  defp used_calendars(side, calendars) do
    calendars
    |> Enum.filter(&(Map.get(&1.trips, side.pattern.route_pattern_id, 0) > 0))
    |> Enum.map(& &1.name)
  end

  defp calendar_name(comparison) do
    case Enum.find(comparison.calendars, &(&1.service_id == comparison.service_id)) do
      nil -> "this calendar"
      calendar -> calendar.name
    end
  end

  defp plural(1, word), do: "1 #{word}"
  defp plural(count, word), do: "#{count} #{word}s"

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
