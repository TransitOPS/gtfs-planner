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
  """

  use GtfsPlannerWeb, :html

  alias GtfsPlanner.Gtfs.GtfsTime
  alias GtfsPlanner.Gtfs.Pathway

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
