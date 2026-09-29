defmodule GtfsPlannerWeb.Gtfs.PathwayEvolutionsComponents do
  @moduledoc """
  Presentational pieces of the Schedule closures view.

  The view itself lives in `GtfsPlannerWeb.Gtfs.PathwayEvolutionsLive`; this
  module owns the parts that describe one closure row, one empty state or one
  pathway group, so the row markup, the state framing and the pathway grouping
  stay in one place instead of being restated as the view grows.

  Labels are derived, never stored: a pathway has no name field, so its label is
  the mode plus both endpoint names and a directional arrow, with the exact
  `pathway_id` as secondary text. A window is service-day seconds, formatted
  through `GtfsTime` and shortened to `H:MM` only when the seconds are zero, so a
  value above `24:00:00` still reads as `26:00`. Grouping the pathway list by
  mode is view-only and preserves the snapshot's `pathway_id` order inside each
  group; it never reorders or drops a pathway.

  The editor's own copy lives here too: the select options, the one-sentence
  summary of a window, the pathway help that says which direction a closure
  removes, the calendar detail line, and the overlap / no-active-dates notices a
  save returns. They are derived from the same labels and the same
  `GtfsTime`-formatted window as the list, so the form and the row cannot
  disagree about what a closure does.
  """

  use GtfsPlannerWeb, :html

  alias GtfsPlanner.Gtfs.GtfsTime
  alias GtfsPlanner.Gtfs.Pathway
  alias GtfsPlanner.Gtfs.PathwayEvolution

  # Group order and group labels for the pathway list. Modes outside this list
  # are grouped under their own mode label rather than dropped, so a fare gate or
  # a moving sidewalk still appears where the station has one. The index in this
  # list is also the row order of the closure table, so the list and the table
  # present the same station in the same order.
  @mode_groups [
    {5, "Elevators"},
    {4, "Escalators"},
    {2, "Stairs"},
    {1, "Walkways"},
    {3, "Moving sidewalks"},
    {6, "Fare gates"},
    {7, "Exit gates"}
  ]

  @doc """
  Ranks a pathway mode for display order, lowest first.

  The rank is the mode's position in the locator list, so the closure table and
  the pathway list agree. A mode outside the known list ranks last rather than
  being dropped or sorted arbitrarily among the known ones.
  """
  @spec pathway_rank(integer() | nil) :: non_neg_integer()
  def pathway_rank(mode) do
    case Enum.find_index(@mode_groups, fn {known, _label} -> known == mode end) do
      nil -> length(@mode_groups)
      index -> index
    end
  end

  @doc """
  Returns the one-line label of a pathway: mode, then both endpoints and a
  directional arrow, exactly as the station snapshot carries them.
  """
  @spec pathway_label(map()) :: String.t()
  def pathway_label(pathway) do
    "#{Pathway.mode_label(pathway.pathway_mode)} · #{ends_label(pathway)}"
  end

  @doc """
  Returns a pathway's two endpoint names and its direction.

  A pathway is bidirectional unless it says otherwise, so the arrow is the
  record's own `is_bidirectional` value rather than an assumption about mode.
  """
  @spec ends_label(map()) :: String.t()
  def ends_label(pathway) do
    arrow = if pathway.is_bidirectional, do: "↔", else: "→"

    "#{stop_label(pathway.from_stop)} #{arrow} #{stop_label(pathway.to_stop)}"
  end

  @doc """
  Returns a closure's window as service times, such as `09:00–15:00`.

  `GtfsTime` owns the service-time formatting; only a zero-seconds field is
  shortened, so `26:00:30` keeps its seconds instead of reading as `26:00`.
  """
  @spec window_label(map()) :: String.t()
  def window_label(%{start_time: start_time, end_time: end_time}) do
    "#{compact_time(start_time)}–#{compact_time(end_time)}"
  end

  @doc """
  Returns the service-day note that qualifies a window, or `nil` when the window
  is an ordinary same-day range.

  A window ending after `24:00:00` continues into the next calendar day, and a
  full `00:00`–`24:00` window is the whole service day. Both are stated in text
  rather than by color alone.
  """
  @spec window_note(map()) :: String.t() | nil
  def window_note(%{start_time: start_time, end_time: end_time}) do
    cond do
      end_time > 86_400 -> "Ends the next day"
      start_time == 0 and end_time == 86_400 -> "All day"
      true -> nil
    end
  end

  @doc """
  Returns the calendar column's two lines for one closure row.

  The primary line is the referenced calendar's own label, or a statement that
  the referenced service has no native calendar in this version — the read
  contract allows that row, and it must not be presented as a named calendar.
  The secondary line always carries the exact `service_id`, which is what a
  search, a link and an export carry.
  """
  @spec calendar_lines(map() | nil, String.t()) :: {String.t(), String.t() | nil}
  def calendar_lines(%{label: label} = option, _service_id) when is_binary(label),
    do: {label, calendar_detail(option)}

  def calendar_lines(nil, _service_id),
    do: {"No calendar in this version", nil}

  @doc """
  Returns the calendar's active service-day span and count, or `nil` when the
  calendar option carries no date information.

  The span comes from the read contract's own effective first/last active dates
  and active-date count, so the line cannot imply service on a day the calendar
  does not run.
  """
  @spec calendar_detail(map()) :: String.t() | nil
  def calendar_detail(
        %{first_active_date: %Date{} = first, last_active_date: %Date{} = last} = option
      ),
      do: calendar_span(first, last, Map.get(option, :active_date_count))

  def calendar_detail(_option), do: nil

  defp calendar_span(first, first, _count), do: "#{long_date(first)} only"
  defp calendar_span(first, _last, 1), do: "#{long_date(first)} only"

  defp calendar_span(first, last, count),
    do: "#{short_date(first)} – #{long_date(last)} · #{count} service days"

  defp long_date(%Date{} = date),
    do: "#{Calendar.strftime(date, "%b")} #{date.day}, #{date.year}"

  defp short_date(%Date{} = date), do: "#{Calendar.strftime(date, "%b")} #{date.day}"

  @doc """
  Groups one station's pathways for the locator list.

  The order is fixed by pathway mode, and each group keeps the snapshot's
  `pathway_id` order, so the list is stable between renders.
  """
  @spec mode_groups([map()]) :: [%{label: String.t(), pathways: [map()]}]
  def mode_groups(pathways) do
    @mode_groups
    |> Enum.map(fn {mode, label} ->
      {mode, label, Enum.filter(pathways, &(&1.pathway_mode == mode))}
    end)
    |> Enum.reject(fn {_mode, _label, list} -> list == [] end)
    |> Kernel.++(ungrouped(pathways))
    |> Enum.map(fn {_mode, label, list} -> %{label: label, pathways: list} end)
  end

  defp ungrouped(pathways) do
    known = Enum.map(@mode_groups, fn {mode, _label} -> mode end)

    pathways
    |> Enum.reject(&(&1.pathway_mode in known))
    |> Enum.group_by(& &1.pathway_mode)
    |> Enum.map(fn {mode, list} -> {mode, "#{Pathway.mode_label(mode)} pathways", list} end)
  end

  @doc """
  Returns the classes for one closure row, marking the selected row in text-safe
  ways: the selection background, the inset action bar, and `aria-current` on
  the row's own button.
  """
  @spec closure_row_class(map(), String.t() | nil) :: String.t()
  def closure_row_class(row, selected_id) do
    if to_string(row.id) == selected_id do
      "group/row border-b border-subtle bg-selection shadow-[inset_3px_0_0_var(--color-action)] last:border-b-0"
    else
      "group/row border-b border-subtle last:border-b-0 hover:bg-canvas"
    end
  end

  @doc """
  Renders one closure row's cells.

  The row's own DOM id is the closure UUID, so the row keeps its identity across
  a search or a selection change, and the exact `pathway_id` travels in the cell
  text. The whole pathway cell is one button, which is what makes the list
  keyboard-operable: no extra tab stop per cell and no custom key handling.
  """
  attr :row, :map, required: true, doc: "one derived closure row"
  attr :selected, :boolean, required: true

  def closure_cells(assigns) do
    ~H"""
    <th scope="row" class="p-0 text-left align-top font-normal max-md:col-span-2">
      <button
        type="button"
        id={"closure-open-" <> @row.id}
        phx-click="select_closure"
        phx-value-id={@row.id}
        aria-current={to_string(@selected)}
        aria-label={"Select the closure on " <> @row.pathway_label <> ", " <> @row.pathway_id}
        class="flex min-h-11 w-full flex-col items-start px-4 pt-3 pb-1.5 text-left hover:underline md:px-5 md:pb-3"
      >
        <span class="text-sm font-[650] leading-snug text-strong">{@row.pathway_label}</span>
        <span class="mt-0.5 font-mono text-[12px] text-muted">{@row.pathway_id}</span>
      </button>
    </th>
    <td class="min-w-0 px-4 align-top md:px-3 md:py-3">
      <span class="block leading-snug text-base-content">{@row.calendar_label}</span>
      <span :if={@row.calendar_detail} class="block text-[13px] text-muted">
        {@row.calendar_detail}
      </span>
    </td>
    <td class="px-4 text-right align-top md:py-3 md:pl-3 md:pr-5 md:text-left">
      <span class="font-[650] tabular-nums text-strong">{@row.window}</span>
      <span :if={@row.window_note} class="block text-[13px] font-normal text-muted">
        {@row.window_note}
      </span>
    </td>
    """
  end

  @doc """
  Renders one of the four non-list states inside the closures card.

  Every state carries its own `id` and its own sentence, so a reader who cannot
  see the state can still hear which one it is, and no state is signalled by
  color alone. The caller supplies the state-specific action.
  """
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :message, :string, required: true
  slot :action

  def closures_state(assigns) do
    ~H"""
    <div id={@id} class="px-5 py-12 text-center">
      <h3 class="text-base font-bold text-strong">{@title}</h3>
      <p class="mx-auto mt-1.5 max-w-[50ch] text-sm text-muted">{@message}</p>
      <div :if={@action != []} class="mt-5 flex justify-center gap-3">
        {render_slot(@action)}
      </div>
    </div>
    """
  end

  @doc """
  Renders the station's pathways as the keyboard-operable list alternative.

  Each option is one button, so the list is operable with Tab and Enter/Space
  without a roving tab stop or custom key handling. The DOM id is the pathway's
  UUID and the exact `pathway_id` travels in `data-pathway-id`, which is what a
  `?pathway=` link and a refusal message from another page address.
  """
  attr :groups, :list, required: true
  attr :closure_counts, :map, required: true, doc: "closure count keyed by pathway_id"
  attr :selected_id, :string, default: nil

  def pathway_list(assigns) do
    ~H"""
    <div id="closure-pathway-list" class="grid gap-5 px-4 pt-4 pb-5 md:px-5">
      <section :for={group <- @groups}>
        <h3 class="text-[13px] font-[650] text-base-content">
          {group.label}
          <span class="font-normal tabular-nums text-muted">{length(group.pathways)}</span>
        </h3>
        <ul class="mt-2 grid gap-2 sm:grid-cols-2">
          <li :for={pathway <- group.pathways}>
            <% count = Map.get(@closure_counts, pathway.pathway_id, 0) %>
            <button
              type="button"
              id={"pathway-option-" <> pathway.id}
              data-pathway-id={pathway.pathway_id}
              phx-click="select_pathway"
              phx-value-id={pathway.id}
              aria-current={to_string(@selected_id == pathway.id)}
              aria-label={pathway_label(pathway) <> ", " <> pathway.pathway_id}
              class="flex min-h-14 w-full items-center justify-between gap-3 rounded-control border border-subtle bg-white px-3 py-2 text-left hover:border-control hover:bg-canvas aria-[current=true]:border-action aria-[current=true]:bg-selection"
            >
              <span class="min-w-0">
                <span class="block text-sm font-[650] leading-snug text-strong">
                  {ends_label(pathway)}
                </span>
                <span class="block font-mono text-[12px] text-muted">{pathway.pathway_id}</span>
              </span>
              <span
                :if={count > 0}
                class="shrink-0 rounded-evo-badge bg-canvas px-2 py-0.5 text-[13px] font-[650] tabular-nums text-muted"
              >
                {pluralize_closures(count)}
              </span>
            </button>
          </li>
        </ul>
      </section>
    </div>
    """
  end

  @doc """
  Returns `1 closure` / `n closures` for a count, in words rather than a color.
  """
  @spec pluralize_closures(non_neg_integer()) :: String.t()
  def pluralize_closures(1), do: "1 closure"
  def pluralize_closures(count), do: "#{count} closures"

  @doc """
  Returns one window endpoint for the editor's text field: `H:MM` when the
  seconds are zero, otherwise the full service time.

  The field accepts `H:MM`, `HH:MM` and `H:MM:SS`, so the short form a reader
  already saw in the list round-trips unchanged, while `26:00:30` keeps the
  seconds it carries.
  """
  @spec service_time_value(non_neg_integer()) :: String.t()
  def service_time_value(seconds) when is_integer(seconds), do: compact_time(seconds)
  def service_time_value(_seconds), do: ""

  # -- editor ----------------------------------------------------------------

  @doc """
  Returns a pathway's full label: mode, endpoints and arrow, as the form's
  context line and the delete confirmation name it.
  """
  @spec pathway_full_label(map()) :: String.t()
  def pathway_full_label(pathway) do
    "#{Pathway.mode_label(pathway.pathway_mode)} · #{ends_label(pathway)}"
  end

  @doc """
  Builds the pathway `select` options, grouped by mode.

  The option label is the endpoint line plus the exact `pathway_id`, so the
  chosen option names the same natural ID the row and the locator show, and the
  group order is the locator's own order.
  """
  @spec pathway_options([map()]) :: [{String.t(), [{String.t(), String.t()}]}]
  def pathway_options(pathways) do
    pathways
    |> mode_groups()
    |> Enum.map(fn group ->
      {group.label, Enum.map(group.pathways, &{pathway_option_label(&1), &1.pathway_id})}
    end)
  end

  defp pathway_option_label(pathway), do: "#{ends_label(pathway)} · #{pathway.pathway_id}"

  @doc """
  Builds the calendar `select` options: named calendars by name, then unnamed
  ones by their exact `service_id`.

  The option value is always the exact `service_id`, which is what the closure
  stores and what an export carries; only the label falls back to the ID.
  """
  @spec calendar_options([map()]) :: [{String.t(), String.t()}]
  def calendar_options(calendars) do
    calendars
    |> Enum.sort_by(&{unnamed_calendar?(&1), String.downcase(&1.label)})
    |> Enum.map(&{&1.label, &1.service_id})
  end

  defp unnamed_calendar?(%{name: name}) when is_binary(name), do: String.trim(name) == ""
  defp unnamed_calendar?(_option), do: true

  @doc """
  Returns the select's help sentence for the chosen pathway.

  The sentence states which travel the closure removes: every direction of a
  bidirectional pathway, or the recorded direction of a one-way one. With no
  pathway chosen it says what the picker accepts.
  """
  @spec pathway_help(map() | nil) :: String.t()
  def pathway_help(nil), do: "Any pathway at this station, including walkways and stairs."

  def pathway_help(%{is_bidirectional: true}), do: "Closes travel in both directions."

  def pathway_help(pathway) do
    mode = pathway.pathway_mode |> Pathway.mode_label() |> String.downcase()
    "Closes the #{mode} from #{stop_label(pathway.from_stop)} to #{stop_label(pathway.to_stop)}."
  end

  @doc """
  Returns the calendar detail line: the effective span and count of active
  service days, then the calendar's trip and closure usage.

  The span comes from the read contract's own first/last active dates, so the
  line cannot imply service on a day the calendar does not run.
  """
  @spec calendar_usage_line(map() | nil) :: String.t() | nil
  def calendar_usage_line(nil), do: nil

  def calendar_usage_line(option) do
    [no_active_dates_line(option), calendar_detail(option), usage_clause(option)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp no_active_dates_line(%{active_date_count: 0}), do: "No active service dates"
  defp no_active_dates_line(_option), do: nil

  defp usage_clause(%{trip_count: trips, closure_count: closures}) do
    "used by #{count_label(trips, "trip", "trips")} and " <>
      count_label(closures, "closure", "closures")
  end

  defp usage_clause(_option), do: nil

  @doc """
  Returns the one-sentence summary of the window the form currently holds.

  The sentence describes what saving would apply: which travel closes, the
  service-time window, the calendar's service days, when travel reopens and —
  when the calendar has no active dates — that the closure does not apply yet.
  Values that do not parse yet produce the sentence that says what is missing
  rather than guessing a window.
  """
  @spec closure_summary(map(), map() | nil, map() | nil) :: String.t()
  def closure_summary(_params, nil, _calendar) do
    "Choose a pathway to see when it closes."
  end

  def closure_summary(params, pathway, calendar) do
    case window_seconds(params) do
      nil ->
        "Choose a calendar and enter a window to see when #{ends_label(pathway)} closes."

      {start_time, end_time} ->
        "#{ends_label(pathway)} closes #{window_phrase(start_time, end_time)} " <>
          "on each service day of #{calendar_phrase(calendar)}. " <>
          "#{reopen_sentence(pathway, start_time, end_time)}#{no_active_dates_suffix(calendar)}"
    end
  end

  defp window_seconds(params) do
    with {:ok, start_time} <- PathwayEvolution.parse_service_time(params["start_time"]),
         {:ok, end_time} <- PathwayEvolution.parse_service_time(params["end_time"]),
         true <- end_time > start_time do
      {start_time, end_time}
    else
      _other -> nil
    end
  end

  defp window_phrase(0, 86_400), do: "all day (00:00–24:00)"

  defp window_phrase(start_time, end_time) when end_time > 86_400 do
    "#{window_label(%{start_time: start_time, end_time: end_time})} " <>
      "(until #{clock_label(end_time)} #{later_label(end_time)})"
  end

  defp window_phrase(start_time, end_time),
    do: window_label(%{start_time: start_time, end_time: end_time})

  defp reopen_sentence(%{is_bidirectional: true}, _start_time, end_time),
    do: "Both directions reopen #{reopen_at(end_time)}."

  defp reopen_sentence(pathway, _start_time, end_time),
    do:
      "The #{pathway.pathway_mode |> Pathway.mode_label() |> String.downcase()} reopens #{reopen_at(end_time)}."

  defp reopen_at(86_400), do: "at midnight (24:00)"

  defp reopen_at(end_time) when end_time > 86_400,
    do: "at #{clock_label(end_time)} #{later_label(end_time)}"

  defp reopen_at(end_time), do: "at #{compact_time(end_time)}"

  defp calendar_phrase(%{label: label}), do: label
  defp calendar_phrase(_calendar), do: "the calendar"

  # Only a calendar the version knows can say how many active dates it has; a
  # referenced service without a native row leaves the sentence open rather than
  # claiming it does not run.
  defp no_active_dates_suffix(%{active_date_count: 0, label: label}),
    do: " #{label} has no active service dates, so this closure does not apply yet."

  defp no_active_dates_suffix(_calendar), do: ""

  # The clock time a service time falls on: 26:00 reads as 2:00 AM on the day
  # after the service date, which is what a reader needs to see.
  defp clock_label(seconds) do
    hours = div(seconds, 3600)
    minutes = div(rem(seconds, 3600), 60)
    hour = rem(hours, 12)
    hour = if hour == 0, do: 12, else: hour
    suffix = if rem(hours, 24) < 12, do: "AM", else: "PM"
    "#{hour}:#{String.pad_leading(to_string(minutes), 2, "0")} #{suffix}"
  end

  defp later_label(seconds) do
    case div(seconds, 86_400) do
      1 -> "the next day"
      days -> "#{days} days later"
    end
  end

  @doc """
  Returns the notice a save shows when another closure on the same pathway and
  service overlaps the saved window.

  It names the other window and states the consequence in words: the pathway
  stays closed while either window applies. Adjacent windows never produce it.
  """
  @spec overlap_notice(map(), [map()], map() | nil) :: map()
  def overlap_notice(pathway, others, calendar) do
    %{
      id: "closure-notice-overlap",
      kind: "info",
      title: "Overlaps another closure.",
      body:
        "#{ends_label(pathway)} also closes #{Enum.map_join(others, " and ", &window_label/1)} " <>
          "on #{calendar_phrase(calendar)}. The pathway stays closed while either applies."
    }
  end

  @doc """
  Returns the notice a save shows when the referenced calendar has no active
  service dates, so the closure does not apply until it has some.
  """
  @spec no_active_dates_notice(map() | nil) :: map()
  def no_active_dates_notice(calendar) do
    %{
      id: "closure-notice-no-active-dates",
      kind: "warning",
      title: "No active service dates.",
      body:
        "#{calendar_phrase(calendar)} does not run on any date, so this closure " <>
          "does not apply until the calendar has dates."
    }
  end

  defp count_label(1, singular, _plural), do: "1 #{singular}"
  defp count_label(count, _singular, plural), do: "#{count} #{plural}"

  # -- access preview --------------------------------------------------------

  @doc """
  Renders the Evolutions view switch: the closure list and the moment access
  preview as two routes of one LiveView.

  This is navigation, not a client-side toggle, so both destinations are
  `patch` links of the mounted view and the current one carries
  `aria-current="page"`. The active segment is the design system's strong ink
  with white text, which is the value the v2 reference uses for it.
  """
  attr :current, :atom, required: true, doc: "`:index` for the list, `:access` for the preview"
  attr :closures_href, :string, required: true
  attr :access_href, :string, required: true

  def evolutions_view_nav(assigns) do
    ~H"""
    <nav
      id="evolutions-view-nav"
      aria-label="Evolutions views"
      class="inline-flex h-11 overflow-hidden rounded-control border border-control bg-white"
    >
      <.link
        id="evolutions-tab-closures"
        patch={@closures_href}
        aria-current={if @current == :access, do: "false", else: "page"}
        class={view_tab_class(@current != :access, "")}
      >
        Schedule closures
      </.link>
      <.link
        id="evolutions-tab-access"
        patch={@access_href}
        aria-current={if @current == :access, do: "page", else: "false"}
        class={view_tab_class(@current == :access, "border-l border-control")}
      >
        Check access
      </.link>
    </nav>
    """
  end

  defp view_tab_class(current?, extra) do
    [
      "flex min-h-11 items-center px-4 text-sm font-[650] no-underline",
      extra,
      current? && "bg-strong text-white",
      !current? && "text-base-content hover:bg-canvas"
    ]
  end

  # The four booleans a pair carries, in the order the table shows them: the
  # step-free columns first, then walking, each with to then from the platform.
  @pair_columns [
    {:step_free_to_platform, :step_free, :to_platform},
    {:step_free_to_exit, :step_free, :to_exit},
    {:walking_to_platform, :walking, :to_platform},
    {:walking_to_exit, :walking, :to_exit}
  ]

  # HEEx reads `@name` as an assign, so the column list is reached through a
  # function inside the template.
  defp pair_columns, do: @pair_columns

  @doc """
  Groups a moment preview's entrance/platform pairs by platform for the table.

  A cell's state is derived from the comparison contract, never guessed: a
  direction the base graph never reached is `:gap` (shown as `No route` and
  never blamed on a closure), one the base reached and the closed set does not
  is `:lost`, and anything still reachable is `:available`. Cells carry the
  pair key and the state as data attributes, so a reader of the markup and a
  browser assertion name the same four columns the domain does.
  """
  @spec preview_groups(map(), map()) :: [map()]
  def preview_groups(snapshot, preview) do
    base = Map.new(preview.base.pairs, &{{&1.platform_id, &1.entrance_id}, &1})
    stops = Map.new(snapshot.child_stops, &{&1.stop_id, &1})
    # The station snapshot's level rows carry the level with its stop count, so
    # the row is unwrapped here rather than read as a level itself.
    levels = Map.new(snapshot.levels, fn %{level: level} -> {level.level_id, level} end)

    preview.effective.pairs
    |> Enum.group_by(& &1.platform_id)
    |> Enum.sort_by(fn {platform_id, _pairs} -> platform_id end)
    |> Enum.map(fn {platform_id, pairs} ->
      preview_group(platform_id, pairs, base, stops, levels)
    end)
  end

  defp preview_group(platform_id, pairs, base, stops, levels) do
    platform = Map.get(stops, platform_id)

    %{
      platform_id: platform_id,
      platform_label: stop_label(platform),
      level_label: level_label(platform, levels),
      rows:
        Enum.map(pairs, fn pair ->
          %{
            entrance_id: pair.entrance_id,
            entrance_label: stop_label(Map.get(stops, pair.entrance_id)),
            cells: Enum.map(@pair_columns, &preview_cell(pair, base, &1))
          }
        end)
    }
  end

  defp preview_cell(pair, base, {key, _mode, _direction}) do
    base_pair = Map.get(base, {pair.platform_id, pair.entrance_id})

    %{key: key, state: preview_cell_state(base_pair, pair, key)}
  end

  # A direction the base graph reached and the closed set does not is the
  # connection the check is reporting; one it still reaches is available. An
  # unpaired base pair cannot claim a loss, so it follows the effective graph.
  defp preview_cell_state(nil, effective_pair, key) do
    if Map.fetch!(effective_pair, key), do: :available, else: :lost
  end

  defp preview_cell_state(base_pair, effective_pair, key) do
    cond do
      not Map.fetch!(base_pair, key) -> :gap
      Map.fetch!(effective_pair, key) -> :available
      true -> :lost
    end
  end

  defp level_label(%{level_id: level_id}, levels) when is_binary(level_id) do
    case Map.get(levels, level_id) do
      %{level_name: name} when is_binary(name) and name != "" -> name
      _level -> nil
    end
  end

  defp level_label(_platform, _levels), do: nil

  @doc """
  Renders one connection state as a badge: an icon plus the state word, so no
  status depends on color alone.
  """
  attr :state, :atom, required: true, values: [:available, :lost, :gap]
  attr :id, :string, default: nil

  def connection_badge(assigns) do
    ~H"""
    <span
      id={@id}
      data-connection-state={@state}
      class={[
        "inline-flex items-center gap-1.5 whitespace-nowrap rounded-evo-badge px-2 py-0.5 text-[13px] font-[650]",
        badge_class(@state)
      ]}
    >
      <.icon name={badge_icon(@state)} class="size-3.5" />{badge_label(@state)}
    </span>
    """
  end

  defp badge_class(:available), do: "bg-success/10 text-success"
  defp badge_class(:lost), do: "bg-error/10 text-error"
  defp badge_class(:gap), do: "bg-canvas text-muted ring-1 ring-inset ring-subtle"

  defp badge_icon(:available), do: "hero-check-circle"
  defp badge_icon(:lost), do: "hero-x-circle"
  defp badge_icon(:gap), do: "hero-no-symbol"

  defp badge_label(:available), do: "Available"
  defp badge_label(:lost), do: "Lost"
  defp badge_label(:gap), do: "No route"

  @doc """
  Renders the moment preview's findings: the per-platform connection table, its
  below-`md` list form, the baseline-gap note, the active closures and the
  coverage disclaimer.

  The table and the list carry the same four columns and the same states, so a
  narrow viewport reads the answer without horizontal overflow. An incomplete
  evaluation says so in the header, and a station with no entrance/platform
  pair says that instead of rendering an empty table.
  """
  attr :snapshot, :map, required: true
  attr :preview, :map, required: true
  attr :causes, :list, required: true, doc: "the active closures, prepared for display"
  attr :moment, :string, required: true, doc: "the selected moment, short form"
  attr :incomplete?, :boolean, required: true
  attr :lost?, :boolean, required: true

  def preview_findings(assigns) do
    assigns =
      assign(assigns,
        groups: preview_groups(assigns.snapshot, assigns.preview),
        gap_note?: assigns.preview.comparison.baseline_gaps != []
      )

    ~H"""
    <section
      id="preview-findings"
      aria-labelledby="findings-title"
      class="flex min-w-0 flex-col overflow-clip rounded-card border border-subtle bg-white"
    >
      <header class="flex flex-wrap items-start justify-between gap-x-4 gap-y-2 border-b border-subtle px-5 py-3.5">
        <div>
          <h2
            id="findings-title"
            class="flex min-h-[26px] items-center font-display text-[18px] tracking-[-0.02em]"
          >
            Entrance ↔ platform connections
          </h2>
          <p class="mt-0.5 text-[13px] text-muted">
            Compared with this station without scheduled closures.
          </p>
        </div>
        <span
          :if={@incomplete?}
          id="findings-incomplete-badge"
          class="inline-flex items-center gap-1.5 rounded-evo-badge bg-warning/10 px-2 py-0.5 text-[13px] font-[650] text-warning"
        >
          <.icon name="hero-exclamation-triangle" class="size-3.5" />Incomplete
        </span>
      </header>

      <table
        :if={@groups != []}
        id="findings-table"
        class="w-full border-collapse text-left text-sm max-md:hidden"
      >
        <thead>
          <tr>
            <th
              scope="col"
              rowspan="2"
              class="w-[34%] border-b border-subtle bg-canvas py-2 pr-4 pl-5 align-bottom text-[13px] font-[650] text-base-content"
            >
              Entrance
            </th>
            <th
              scope="colgroup"
              colspan="2"
              class="border-b border-subtle bg-canvas px-4 pt-2 pb-0 text-[13px] font-[650] text-base-content"
            >
              Step-free
            </th>
            <th
              scope="colgroup"
              colspan="2"
              class="border-b border-subtle border-l bg-canvas px-4 pt-2 pb-0 text-[13px] font-[650] text-base-content"
            >
              Walking
            </th>
          </tr>
          <tr>
            <th
              :for={{_key, mode, direction} <- pair_columns()}
              scope="col"
              class={[
                "border-b border-subtle bg-canvas px-4 py-1.5 text-[13px] font-normal text-muted",
                mode == :walking && direction == :to_platform && "border-l"
              ]}
            >
              {direction_label(direction)}
            </th>
          </tr>
        </thead>
        <tbody :for={{group, index} <- Enum.with_index(@groups)} data-platform-id={group.platform_id}>
          <tr>
            <th
              scope="rowgroup"
              colspan="5"
              class={[
                "px-5 pt-3 pb-1 text-left text-[13px] font-[650] text-strong",
                index > 0 && "border-t border-subtle"
              ]}
            >
              {group.platform_label}
              <span :if={group.level_label} class="font-normal text-muted">
                · {group.level_label}
              </span>
            </th>
          </tr>
          <tr :for={{row, row_index} <- Enum.with_index(group.rows)}>
            <th
              scope="row"
              class={[
                "h-12 px-4 py-2 pr-4 pl-5 text-left align-middle font-normal text-strong",
                row_index < length(group.rows) - 1 && "border-b border-subtle/60"
              ]}
            >
              {row.entrance_label}
            </th>
            <td
              :for={cell <- row.cells}
              data-connection={cell.key}
              data-state={cell.state}
              class={[
                "px-4 py-2",
                row_index < length(group.rows) - 1 && "border-b border-subtle/60",
                cell.key == :walking_to_platform && "border-l border-subtle"
              ]}
            >
              <.connection_badge state={cell.state} />
            </td>
          </tr>
        </tbody>
      </table>

      <div :if={@groups != []} id="findings-list" class="md:hidden">
        <section
          :for={{group, index} <- Enum.with_index(@groups)}
          data-platform-id={group.platform_id}
          class={["px-4 pt-3 pb-1", index > 0 && "border-t border-subtle"]}
        >
          <h3 class="text-[13px] font-[650] text-strong">
            {group.platform_label}
            <span :if={group.level_label} class="font-normal text-muted">· {group.level_label}</span>
          </h3>
          <ul>
            <li :for={row <- group.rows} class="border-t border-subtle/60 py-3 first:border-t-0">
              <p class="text-sm font-[650] text-strong">{row.entrance_label}</p>
              <div class="mt-1.5 grid grid-cols-[minmax(4.25rem,auto)_minmax(0,1fr)_minmax(0,1fr)] items-center gap-x-2 gap-y-1.5 text-[13px]">
                <span></span>
                <span class="text-muted">To platform</span>
                <span class="text-muted">From platform</span>
                <span class="font-[650] text-base-content">Step-free</span>
                <span :for={cell <- Enum.slice(row.cells, 0, 2)}>
                  <.connection_badge state={cell.state} />
                </span>
                <span class="font-[650] text-base-content">Walking</span>
                <span :for={cell <- Enum.slice(row.cells, 2, 2)}>
                  <.connection_badge state={cell.state} />
                </span>
              </div>
            </li>
          </ul>
        </section>
      </div>

      <p :if={@groups == []} id="findings-empty" class="px-5 py-6 text-sm text-muted">
        This station has no entrance and platform pair to compare.
      </p>

      <p
        :if={@gap_note?}
        id="findings-gap-note"
        class="flex items-start gap-2 border-t border-subtle px-5 py-2.5 text-[13px] text-muted"
      >
        <.connection_badge state={:gap} />
        <span>Unreachable even without closures, so it is not counted as lost.</span>
      </p>

      <div id="preview-causes" class="flex-1 border-t border-subtle px-5 pt-4 pb-2">
        <h3 class="text-sm font-[650] text-strong">
          {if @lost?, do: "Active closures during this loss", else: "Closures at this moment"}
        </h3>
        <p :if={@causes == []} class="mt-1 text-sm text-muted">
          No closure is active at {@moment}.
        </p>
        <ul :if={@causes != []} class="mt-1">
          <li
            :for={cause <- @causes}
            id={"preview-cause-" <> cause.id}
            class="flex flex-wrap items-center justify-between gap-x-4 gap-y-1 border-t border-subtle/60 py-2 first:border-t-0"
          >
            <div class="min-w-0">
              <p class="text-sm text-strong">
                <span class="font-[650]">{cause.pathway_label}</span>
                <span class="font-mono text-[13px] text-muted">{cause.pathway_id}</span>
              </p>
              <p class="text-[13px] tabular-nums text-muted">{cause.detail}</p>
            </div>
            <a
              id={"preview-cause-link-" <> cause.id}
              href={cause.href}
              class="inline-flex min-h-11 items-center gap-1 text-sm font-[650] text-action no-underline hover:underline"
            >
              Review closure<.icon name="hero-chevron-right" class="size-4" />
            </a>
          </li>
        </ul>
      </div>

      <p
        id="preview-coverage"
        class="flex items-start gap-2 border-t border-subtle bg-canvas/60 px-5 py-3 text-[13px] text-muted"
      >
        <.icon name="hero-information-circle" class="mt-0.5 size-4 shrink-0" />
        <span>
          Directed paths and step-free connections at the selected moment. It does not certify
          slopes, widths, or all wheelchair requirements.
        </span>
      </p>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :body, :string, required: true
  attr :tone, :atom, required: true, values: [:loss, :ok]
  attr :computed_label, :string, required: true
  attr :moment_label, :string, required: true

  @doc """
  Renders the moment preview's result banner: its heading, the contributing
  closures and what remains, the computed-at line and the moment it describes.
  """
  def preview_banner(assigns) do
    ~H"""
    <section
      id={@id}
      aria-labelledby="preview-result-title"
      class={[
        "flex gap-3 rounded-card px-5 py-4",
        @tone == :loss && "bg-error/10",
        @tone == :ok && "bg-success/10"
      ]}
    >
      <.icon
        name={if @tone == :loss, do: "hero-x-circle", else: "hero-check-circle"}
        class={["mt-0.5 size-5", @tone == :loss && "text-error", @tone == :ok && "text-success"]}
      />
      <div class="min-w-0 flex-1">
        <div class="flex flex-wrap items-baseline justify-between gap-x-6 gap-y-1">
          <h2
            id="preview-result-title"
            tabindex="-1"
            class={[
              "font-display text-[20px] focus:outline-none",
              @tone == :loss && "text-error",
              @tone == :ok && "text-success"
            ]}
          >
            {@title}
          </h2>
          <p id="preview-computed" class="text-[13px] tabular-nums max-sm:hidden">
            {@computed_label}
          </p>
        </div>
        <p id="preview-result-body" class="mt-1 text-sm text-strong">{@body}</p>
        <p id="preview-moment" class="mt-1.5 text-[13px] tabular-nums text-base-content">
          {@moment_label}<span class="sm:hidden"> · {@computed_label}</span>
        </p>
      </div>
    </section>
    """
  end

  defp direction_label(:to_platform), do: "To platform"
  defp direction_label(:to_exit), do: "From platform"

  defp compact_time(seconds) do
    case String.split(GtfsTime.format(seconds), ":") do
      [hours, minutes, "00"] -> "#{hours}:#{minutes}"
      parts -> Enum.join(parts, ":")
    end
  end

  defp stop_label(%{stop_name: name}) when is_binary(name) and name != "", do: name
  defp stop_label(%{stop_id: stop_id}), do: stop_id
  defp stop_label(_stop), do: "Unknown stop"
end
