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

  The access view's range report is prepared here as well. A range report's
  findings are the domain's exact loss periods; grouping them is view-only and
  lossless, so this module derives display rows from the report and never
  recomputes a period, a cause or an instant. A period's `Show at` address comes
  from `access_moment_path/4`, which is also the address the timeline patches to,
  so a link and the request behind it cannot disagree.
  """

  use GtfsPlannerWeb, :html

  import GtfsPlannerWeb.ResultComponents, only: [result_summary: 1, tone_badge: 1]

  alias GtfsPlanner.Gtfs.Coordinates
  alias GtfsPlanner.Gtfs.DiagramStorage
  alias GtfsPlanner.Gtfs.DisplayClock
  alias GtfsPlanner.Gtfs.GtfsTime
  alias GtfsPlanner.Gtfs.Pathway
  alias GtfsPlanner.Gtfs.PathwayEvolution
  alias GtfsPlanner.Wording

  # The two words a range period's lost line is built from. Both are the
  # vocabulary the moment preview's table already uses.
  @range_modes %{step_free: "Step-free", walking: "Walking"}
  @range_directions %{to_platform: "to platform", to_exit: "from platform"}

  # The untouched locator's own prompt. The client hook owns this caption after
  # mount and reads the same words back when nothing is hovered or selected.
  @floorplan_caption_empty "Point at or focus a pathway to see its name. Select it to schedule a closure."

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
    "#{GtfsTime.display(start_time)}–#{GtfsTime.display(end_time)}"
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
        class="group/open flex min-h-11 w-full flex-col items-start px-4 pt-3 pb-1.5 text-left md:px-5 md:pb-3"
      >
        <span class="text-sm font-[650] leading-snug text-strong group-hover/open:underline">
          {@row.pathway_label}
        </span>
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
  attr :class, :string, default: "", doc: "extra classes, such as the diagram mode's md:hidden"

  def pathway_list(assigns) do
    ~H"""
    <div id="closure-pathway-list" class={["grid gap-5 px-4 pt-4 pb-5 md:px-5", @class]}>
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
              class="flex min-h-14 w-full items-center justify-between gap-3 rounded-control border border-control bg-white px-3 py-2 text-left hover:bg-canvas aria-[current=true]:border-action aria-[current=true]:bg-selection"
            >
              <span class="min-w-0">
                <span class="block text-sm font-[650] leading-snug text-strong">
                  {ends_label(pathway)}
                </span>
                <span class="block font-mono text-[12px] text-muted">{pathway.pathway_id}</span>
              </span>
              <span
                :if={count > 0}
                class="shrink-0 rounded-badge bg-canvas px-2 py-0.5 text-[13px] font-[650] tabular-nums text-muted"
              >
                {Wording.count_noun(count, "closure")}
              </span>
            </button>
          </li>
        </ul>
      </section>
    </div>
    """
  end

  @doc """
  Prepares one station's static floorplan for the authoring locator and the
  access preview.

  Only a level with a resolvable floorplan image is selectable; the caption
  names the levels that have no floorplan rather than hiding them, because a
  missing image never means the station has no pathways. The image path comes
  from `DiagramStorage.public_path/4`; this web component adds the configured
  endpoint base URL. An unpublished or absent file yields no floorplan at all
  instead of a broken image.

  Stops and pathways keep the station snapshot's stored width-normalized
  coordinates (`Coordinates.normalize_point/1`), the same normalizer the
  mutation-time preview uses. A pathway belongs to a floorplan when one of its
  endpoints is plotted on the selected level: two plotted endpoints are a
  same-level line, and one plotted endpoint is the cross-level marker at that
  endpoint. Nothing here converts a coordinate, and no pathway is dropped
  silently - a pathway with no plotted endpoint on this level simply has no
  place on this floorplan.

  `ordered_pathways` is the locator list's own order (mode group, then
  `pathway_id`), so the overlay's arrow order and the list's reading order are
  the same order. Returns `nil` when no level has a floorplan image.
  """
  @spec floorplan_display(map(), [map()], keyword()) :: map() | nil
  def floorplan_display(station_data, ordered_pathways, options) do
    organization_id = Keyword.fetch!(options, :organization_id)
    gtfs_version_id = Keyword.fetch!(options, :gtfs_version_id)
    station_stop_id = Keyword.fetch!(options, :station_stop_id)
    station = station_data.station

    levels =
      station_data.levels
      |> Enum.map(&floorplan_level(&1, organization_id, gtfs_version_id, station_stop_id))
      |> Enum.reject(&is_nil/1)

    case levels do
      [] ->
        nil

      levels ->
        selected =
          selected_floorplan_level(
            levels,
            options[:selected_level_id],
            options[:selected_pathway]
          )

        level_id = selected.level_id
        stop_points = floorplan_stop_points(station_data.child_stops, level_id)
        image_level_ids = Enum.map(levels, & &1.level_id)

        %{
          levels: levels,
          selected_level_id: level_id,
          selected_level_label: selected.label,
          levels_without_image:
            station_data.levels
            |> Enum.reject(&(&1.level.level_id in image_level_ids))
            |> Enum.map(&level_label(&1.level)),
          image_url: selected.image_url,
          image_alt: "Floorplan of #{station_label(station)}, #{selected.label}",
          stops: Map.values(stop_points) |> Enum.sort_by(& &1.stop_id),
          stop_points: stop_points,
          pathways:
            floorplan_pathways(
              ordered_pathways,
              stop_points,
              Keyword.get(options, :closure_counts, %{})
            ),
          selected_id: selected_pathway_uuid(options[:selected_pathway])
        }
    end
  end

  defp floorplan_level(
         %{level: level, diagram_filename: filename},
         organization_id,
         gtfs_version_id,
         station_stop_id
       )
       when is_binary(filename) and filename != "" do
    case DiagramStorage.public_path(
           organization_id,
           gtfs_version_id,
           station_stop_id,
           filename
         ) do
      {:ok, path} ->
        url = GtfsPlannerWeb.Endpoint.url() <> path

        %{level_id: level.level_id, label: level_label(level), image_url: url}

      {:error, _reason} ->
        nil
    end
  end

  defp floorplan_level(_level, _organization_id, _gtfs_version_id, _station_stop_id), do: nil

  defp level_label(%{level_name: name}) when is_binary(name) and name != "", do: name
  defp level_label(%{level_id: level_id}), do: level_id
  defp level_label(_level), do: "Level"

  # The explicit level choice wins while it still has an image; otherwise the
  # level of the selected pathway decides, so a selection made in the list or
  # the overlay is always shown on its own level unless the reader chose one.
  defp selected_floorplan_level(levels, chosen_id, selected_pathway) do
    ids = Enum.map(levels, & &1.level_id)

    cond do
      chosen_id in ids ->
        Enum.find(levels, &(&1.level_id == chosen_id))

      pathway_level(selected_pathway) in ids ->
        pathway_level = pathway_level(selected_pathway)
        Enum.find(levels, &(&1.level_id == pathway_level))

      true ->
        hd(levels)
    end
  end

  defp pathway_level(%{from_stop: %{level_id: level_id}}) when level_id not in [nil, ""],
    do: level_id

  defp pathway_level(%{to_stop: %{level_id: level_id}}) when level_id not in [nil, ""],
    do: level_id

  defp pathway_level(_pathway), do: nil

  defp selected_pathway_uuid(%{id: id}), do: id
  defp selected_pathway_uuid(_pathway), do: nil

  defp station_label(%{stop_name: name}) when is_binary(name) and name != "", do: name
  defp station_label(%{stop_id: stop_id}), do: stop_id
  defp station_label(_station), do: "this station"

  # One plotted point per stop of the selected level, keyed by the exact
  # `stop_id` the pathway endpoints use. A stop without usable coordinates has
  # no point and therefore no place on this floorplan.
  defp floorplan_stop_points(child_stops, level_id) do
    child_stops
    |> Enum.filter(&(&1.level_id == level_id))
    |> Enum.reduce(%{}, fn stop, points ->
      case Coordinates.normalize_point(stop.diagram_coordinate) do
        nil ->
          points

        point ->
          Map.put(points, stop.stop_id, %{
            stop_id: stop.stop_id,
            name: stop_label(stop),
            type: stop.location_type,
            x: point.x,
            y: point.y
          })
      end
    end)
  end

  defp floorplan_pathways(ordered_pathways, stop_points, closure_counts) do
    ordered_pathways
    |> Enum.flat_map(fn pathway ->
      from = Map.get(stop_points, pathway.from_stop_id)
      to = Map.get(stop_points, pathway.to_stop_id)

      if is_nil(from) and is_nil(to) do
        []
      else
        [
          %{
            id: pathway.id,
            pathway_id: pathway.pathway_id,
            label: pathway_label(pathway),
            closures: Map.get(closure_counts, pathway.pathway_id, 0),
            from: from,
            to: to
          }
        ]
      end
    end)
  end

  @doc """
  Renders the authoring floorplan, its one caption and its Key.

  The image and the SVG overlay are one island the client hook owns: the island
  keeps a stable id, carries the exact stored coordinates and the current
  closed/selected state as data attributes, and is never patched by the server,
  so an overlay redraw cannot move stored geometry. The Key draws every mark at
  the size it has on the plan, and the caption names the selected or focused
  pathway.

  A station with more than one floorplan level gets one underlined tab per
  level, in the design system's level-switch form. The panel sits on the card's
  own content inset, so the level line, the plan, the caption and the Key share
  one left edge.
  """
  attr :id, :string, required: true
  attr :levels, :list, required: true
  attr :selected_level_id, :string, required: true
  attr :selected_level_label, :string, required: true
  attr :levels_without_image, :list, required: true
  attr :toggle_id, :string, default: nil
  attr :image_url, :string, required: true
  attr :image_alt, :string, required: true
  attr :stops, :list, required: true, doc: "plotted stops of the selected level"
  attr :pathways, :list, required: true, doc: "pathways drawn on the selected level"
  attr :closed_pathway_ids, :list, required: true
  attr :selected_pathway_id, :string, default: nil
  attr :select_event, :string, default: nil

  def closure_floorplan(assigns) do
    ~H"""
    <div id={@id <> "-panel"} data-floorplan-panel class="px-4 pb-5 max-md:hidden md:px-5">
      <div
        :if={length(@levels) > 1}
        id={@id <> "-levels"}
        role="group"
        aria-label="Floorplan level"
        class="flex flex-wrap items-end gap-x-1 border-b border-subtle"
      >
        <span class="mr-2 self-center text-[13px] text-muted">Level</span>
        <button
          :for={level <- @levels}
          id={@id <> "-level-" <> level.level_id}
          type="button"
          phx-click="select_floorplan_level"
          phx-value-level={level.level_id}
          aria-pressed={to_string(level.level_id == @selected_level_id)}
          class="-mb-px inline-flex min-h-11 max-w-[14rem] items-center truncate border-b-2 border-transparent px-3 text-sm font-[650] text-muted hover:border-subtle hover:text-strong aria-pressed:border-action aria-pressed:text-action"
        >
          {level.label}
        </button>
      </div>

      <p id={@id <> "-level-label"} class="mt-2 text-[13px] text-muted">
        Level: {@selected_level_label}{floorplan_without_image_suffix(@levels_without_image)}
      </p>

      <.floorplan_island
        id={@id}
        mode={:authoring}
        note_id={@id <> "-missing"}
        list_id="closure-pathway-list"
        toggle_id={@toggle_id}
        image_url={@image_url}
        image_alt={@image_alt}
        stops={@stops}
        pathways={@pathways}
        closed_pathway_ids={@closed_pathway_ids}
        selected_pathway_id={@selected_pathway_id}
        select_event={@select_event}
      />

      <.floorplan_key id={@id <> "-legend"}>
        <.floorplan_legend_item label="Selected pathway">
          <.floorplan_mark kind={:selected} />
        </.floorplan_legend_item>
        <.floorplan_legend_item label="Pathway">
          <.floorplan_mark kind={:pathway} />
        </.floorplan_legend_item>
        <.floorplan_legend_item label="Continues to another level">
          <.floorplan_mark kind={:cross_level} />
        </.floorplan_legend_item>
        <.floorplan_legend_item label="Has closures">
          <.floorplan_mark kind={:closures} />
        </.floorplan_legend_item>
        <.floorplan_point_items />
      </.floorplan_key>
    </div>
    """
  end

  @doc """
  Renders the access preview's read-only floorplan with the moment's closed set.

  The overlay draws the same stored coordinates as the authoring picker and
  marks each pathway closed with a dashed error line and a cross beside the
  word `Closed`; the list beneath names every closed pathway in text as well,
  so the state never depends on colour. Activating a pathway only highlights
  the existing cause rows the preview already computed - it changes nothing.
  """
  attr :display, :map, required: true
  attr :snapshot, :map, required: true
  attr :closed_instances, :list, required: true, doc: "the preview's closed instances"
  attr :moment, :string, required: true

  def preview_floorplan(assigns) do
    pathways = Map.new(assigns.snapshot.pathways, &{&1.pathway_id, &1})

    closed_ids =
      assigns.closed_instances
      |> Enum.map(& &1.pathway_id)
      |> Enum.uniq()

    assigns =
      assign(assigns,
        closed_ids: closed_ids,
        closed_count: length(closed_ids),
        closed_lines:
          Enum.map(closed_ids, fn pathway_id ->
            floorplan_closed_line(pathway_id, Map.get(pathways, pathway_id), assigns.display)
          end)
      )

    ~H"""
    <section
      id="preview-floorplan"
      data-floorplan-panel
      aria-labelledby="preview-floorplan-title"
      class="mt-6 flex min-w-0 flex-col overflow-clip rounded-card border border-subtle bg-white max-md:hidden"
    >
      <header class="border-b border-subtle px-5 py-3.5">
        <div class="flex flex-wrap items-center justify-between gap-x-4 gap-y-1">
          <h2
            id="preview-floorplan-title"
            class="flex min-h-[26px] items-center font-display text-[18px] tracking-[-0.02em]"
          >
            Station at {@moment}
          </h2>
          <.tone_badge :if={@closed_count > 0} tone="error" id="preview-floorplan-badge">
            {Wording.count_noun(@closed_count, "pathway")} closed
          </.tone_badge>
          <.tone_badge :if={@closed_count == 0} tone="success" id="preview-floorplan-badge">
            No pathway closed
          </.tone_badge>
        </div>
        <p class="mt-0.5 text-[13px] text-muted">
          {@display.selected_level_label}{floorplan_without_image_suffix(
            @display.levels_without_image
          )}
        </p>
      </header>

      <div class="p-4 md:px-5">
        <.floorplan_island
          id="preview-floorplan-canvas"
          mode={:preview}
          frame_class="mx-auto w-full max-w-[640px]"
          note_id="preview-floorplan-missing"
          image_url={@display.image_url}
          image_alt={@display.image_alt}
          stops={@display.stops}
          pathways={@display.pathways}
          closed_pathway_ids={@closed_ids}
        />

        <p id="preview-floorplan-closed" class="mt-3 text-[13px] text-default">
          <span :if={@closed_lines == []} class="text-muted">
            Every pathway on this floorplan is open at this time.
          </span>
          <span :for={line <- @closed_lines} class="block">
            <span class="font-[650] text-error-fg">
              <.icon name="hero-x-mark" class="inline size-3.5" />Closed:
            </span>
            {line.label}
            <span class="font-mono text-muted">{line.pathway_id}</span>
            <span class="text-muted">· {line.placement}</span>
          </span>
        </p>

        <.floorplan_key id="preview-floorplan-legend">
          <.floorplan_legend_item label="Open pathway">
            <.floorplan_mark kind={:pathway} />
          </.floorplan_legend_item>
          <.floorplan_legend_item label="Closed">
            <.floorplan_mark kind={:closed} />
          </.floorplan_legend_item>
          <.floorplan_legend_item label="To another level">
            <.floorplan_mark kind={:cross_level} />
          </.floorplan_legend_item>
          <.floorplan_point_items />
        </.floorplan_key>
      </div>
    </section>
    """
  end

  @doc """
  Renders the floorplan note shown when no image can be shown: either the
  station has no published floorplan file, or the browser could not load one.

  The client hook unhides the same note when an image request fails, so a
  broken image falls back to the visible pathway list with an explicit reason
  instead of an empty picture.
  """
  attr :id, :string, required: true
  attr :hidden, :boolean, default: false

  def floorplan_missing_note(assigns) do
    ~H"""
    <p
      id={@id}
      hidden={@hidden}
      class="flex items-start gap-2.5 border-b border-subtle bg-canvas px-4 py-3 text-[13px] text-muted md:px-5"
    >
      <.icon name="hero-information-circle" class="mt-0.5 size-4 shrink-0" />
      <span>
        No floorplan image is available for this station. Use the list below to choose a pathway.
      </span>
    </p>
    """
  end

  attr :id, :string, required: true, doc: "the ignored island's stable id"
  attr :mode, :atom, required: true, values: [:authoring, :preview]
  attr :frame_class, :string, default: ""
  attr :note_id, :string, required: true
  attr :list_id, :string, default: nil
  attr :toggle_id, :string, default: nil
  attr :image_url, :string, required: true
  attr :image_alt, :string, required: true
  attr :stops, :list, required: true
  attr :pathways, :list, required: true
  attr :closed_pathway_ids, :list, required: true
  attr :selected_pathway_id, :string, default: nil
  attr :select_event, :string, default: nil

  # The island the hook owns completely: LiveView merges only `data-` attributes
  # onto it and never touches its children, so the image, the SVG overlay and
  # the caption are one client-managed region. Every value the overlay draws
  # travels in a data attribute from the server; the hook writes nothing back.
  defp floorplan_island(assigns) do
    assigns = assign(assigns, :caption_empty, @floorplan_caption_empty)

    ~H"""
    <div
      id={@id}
      phx-hook="PathwayEvolutionsFloorplan"
      phx-update="ignore"
      data-image-url={@image_url}
      data-image-alt={@image_alt}
      data-stops={Jason.encode!(@stops)}
      data-pathways={Jason.encode!(@pathways)}
      data-selected-id={@selected_pathway_id || ""}
      data-closed-ids={Jason.encode!(Enum.sort(@closed_pathway_ids))}
      data-select-event={@select_event || ""}
      data-show-stop-names={to_string(@mode == :preview)}
      data-note-id={@note_id}
      data-list-id={@list_id || ""}
      data-toggle-id={@toggle_id || ""}
      class="mt-3"
    >
      <div
        id={@id <> "-frame"}
        data-floorplan-frame
        class={[
          "relative overflow-hidden rounded-control border border-subtle bg-canvas",
          @frame_class
        ]}
      >
        <img
          id={@id <> "-image"}
          data-floorplan-image
          src={@image_url}
          alt={@image_alt}
          class="block w-full opacity-[.62]"
        />
        <svg
          id={@id <> "-svg"}
          data-floorplan-svg
          viewBox="0 0 100 100"
          class="absolute inset-0 size-full"
          role="group"
          aria-label="Pathways on this floorplan"
        >
        </svg>
      </div>

      <p
        :if={@mode == :authoring}
        id={@id <> "-caption"}
        data-floorplan-caption
        class="flex min-h-11 flex-wrap items-center gap-x-2 py-1 text-sm text-muted"
      >
        {@caption_empty}
      </p>
    </div>
    """
  end

  # The Key under a plan. It is titled, and every mark in it is drawn by
  # `floorplan_mark/1` at the size the overlay gives it.
  attr :id, :string, required: true
  slot :inner_block, required: true

  defp floorplan_key(assigns) do
    ~H"""
    <div
      id={@id}
      role="group"
      aria-labelledby={@id <> "-title"}
      class="mt-4 border-t border-subtle pt-3"
    >
      <p id={@id <> "-title"} class="text-[13px] font-[650] text-strong">Key</p>
      <ul class="mt-2 flex flex-wrap gap-x-5 gap-y-2 text-[13px] text-muted">
        {render_slot(@inner_block)}
      </ul>
    </div>
    """
  end

  attr :label, :string, required: true
  slot :inner_block, required: true

  defp floorplan_legend_item(assigns) do
    ~H"""
    <li class="inline-flex items-center gap-2">{render_slot(@inner_block)} {@label}</li>
    """
  end

  # The four kinds of point a plan can carry, named as the design system names
  # them. The station snapshot's child stops are platforms, entrances or exits,
  # junctions and boarding spots.
  defp floorplan_point_items(assigns) do
    ~H"""
    <.floorplan_legend_item label="Platform">
      <.floorplan_mark kind={:platform} />
    </.floorplan_legend_item>
    <.floorplan_legend_item label="Entrance or exit">
      <.floorplan_mark kind={:entrance} />
    </.floorplan_legend_item>
    <.floorplan_legend_item label="Junction">
      <.floorplan_mark kind={:junction} />
    </.floorplan_legend_item>
    <.floorplan_legend_item label="Boarding spot">
      <.floorplan_mark kind={:boarding} />
    </.floorplan_legend_item>
    """
  end

  # One mark of the Key at real size. The overlay sizes its marks in diagram
  # units (one unit is 1% of the plan's width), so a plan about 700px wide
  # renders 7px per unit; the geometry here is the overlay's own
  # (`assets/js/pathway_evolutions_floorplan.js`) at that scale, in the same
  # inks: the pathway ink for lines, the point ink for points, the halo around
  # both, action ink for the selection and the status tokens for a closure.
  attr :kind, :atom,
    required: true,
    values: [
      :selected,
      :pathway,
      :closed,
      :cross_level,
      :closures,
      :platform,
      :entrance,
      :junction,
      :boarding
    ]

  defp floorplan_mark(%{kind: kind} = assigns) when kind in [:selected, :pathway, :closed] do
    ~H"""
    <svg width="36" height="20" viewBox="0 0 36 20" aria-hidden="true">
      <%= case @kind do %>
        <% :selected -> %>
          <line
            x1="3"
            y1="10"
            x2="33"
            y2="10"
            class="stroke-action"
            stroke-width="13"
            stroke-linecap="round"
          />
          <line
            x1="3"
            y1="10"
            x2="33"
            y2="10"
            class="stroke-(--diagram-label-halo)"
            stroke-width="9"
            stroke-linecap="round"
          />
          <line
            x1="3"
            y1="10"
            x2="33"
            y2="10"
            class="stroke-action"
            stroke-width="5.5"
            stroke-linecap="round"
          />
        <% :pathway -> %>
          <line
            x1="3"
            y1="10"
            x2="33"
            y2="10"
            class="stroke-(--diagram-label-halo)"
            stroke-width="7"
            stroke-linecap="round"
          />
          <line
            x1="3"
            y1="10"
            x2="33"
            y2="10"
            class="stroke-(--diagram-pathway-forward)"
            stroke-width="3"
            stroke-linecap="round"
          />
        <% :closed -> %>
          <line
            x1="3"
            y1="10"
            x2="33"
            y2="10"
            class="stroke-(--diagram-label-halo)"
            stroke-width="7"
            stroke-linecap="round"
          />
          <line
            x1="3"
            y1="10"
            x2="33"
            y2="10"
            class="stroke-error-line"
            stroke-width="3"
            stroke-dasharray="7 5"
            stroke-linecap="round"
          />
          <circle cx="18" cy="10" r="8" class="fill-error-bg stroke-error-line" stroke-width="1.6" />
          <path
            d="M14.5 6.5L21.5 13.5M21.5 6.5L14.5 13.5"
            class="stroke-error-fg"
            stroke-width="1.8"
            stroke-linecap="round"
          />
      <% end %>
    </svg>
    """
  end

  defp floorplan_mark(%{kind: :cross_level} = assigns) do
    ~H"""
    <svg width="22" height="22" viewBox="-11 -11 22 22" aria-hidden="true">
      <circle
        r="9"
        class="fill-(--diagram-label-halo) stroke-(--diagram-pathway-forward)"
        stroke-width="1.5"
      />
      <path
        d="M0 -5V5M-3 -2 0 -5 3 -2M-3 2 0 5 3 2"
        class="fill-none stroke-(--diagram-active-stop)"
        stroke-width="1.5"
        stroke-linecap="round"
        stroke-linejoin="round"
      />
    </svg>
    """
  end

  defp floorplan_mark(%{kind: :closures} = assigns) do
    ~H"""
    <svg width="16" height="16" viewBox="-8 -8 16 16" aria-hidden="true">
      <circle
        r="5.25"
        class="fill-(--diagram-active-stop) stroke-(--diagram-label-halo)"
        stroke-width="1.5"
      />
    </svg>
    """
  end

  defp floorplan_mark(%{kind: :platform} = assigns) do
    ~H"""
    <svg width="20" height="28" viewBox="-10 -14 20 28" aria-hidden="true">
      <rect
        x="-7"
        y="-11"
        width="14"
        height="22"
        rx="4.2"
        class="fill-(--diagram-active-stop) stroke-(--diagram-label-halo)"
        stroke-width="1.5"
      />
    </svg>
    """
  end

  defp floorplan_mark(%{kind: :entrance} = assigns) do
    ~H"""
    <svg width="24" height="24" viewBox="-12 -12 24 24" aria-hidden="true">
      <rect
        x="-9.8"
        y="-9.8"
        width="19.6"
        height="19.6"
        rx="2.8"
        class="fill-(--diagram-label-halo) stroke-(--diagram-active-stop)"
        stroke-width="2"
      />
    </svg>
    """
  end

  defp floorplan_mark(%{kind: :junction} = assigns) do
    ~H"""
    <svg width="16" height="16" viewBox="-8 -8 16 16" aria-hidden="true">
      <circle
        r="6.3"
        class="fill-(--diagram-active-stop) stroke-(--diagram-label-halo)"
        stroke-width="1.5"
      />
    </svg>
    """
  end

  defp floorplan_mark(%{kind: :boarding} = assigns) do
    ~H"""
    <svg width="20" height="20" viewBox="-10 -10 20 20" aria-hidden="true">
      <rect
        x="-7.7"
        y="-7.7"
        width="15.4"
        height="15.4"
        class="fill-(--diagram-active-stop) stroke-(--diagram-label-halo)"
        stroke-width="1.5"
      />
    </svg>
    """
  end

  defp floorplan_without_image_suffix([]), do: ""

  defp floorplan_without_image_suffix(labels) do
    " · " <> Enum.join(labels, " and ") <> " " <> has_no_floorplan(labels)
  end

  defp has_no_floorplan([_label]), do: "level has no floorplan"
  defp has_no_floorplan(_labels), do: "levels have no floorplan"

  # One closed pathway's own line: its label when the snapshot still has it,
  # its exact natural id, and where on this floorplan it is (or that it is not
  # on this floorplan at all). The floorplan never silently drops a closed
  # pathway just because its endpoints are on another level.
  defp floorplan_closed_line(pathway_id, pathway, display) do
    from_on? = pathway && Map.has_key?(display.stop_points, pathway.from_stop_id)
    to_on? = pathway && Map.has_key?(display.stop_points, pathway.to_stop_id)

    placement =
      cond do
        from_on? and to_on? -> "dashed line"
        from_on? -> "marker at " <> endpoint_name(display.stop_points, pathway.from_stop_id)
        to_on? -> "marker at " <> endpoint_name(display.stop_points, pathway.to_stop_id)
        true -> "not on this floorplan"
      end

    %{
      pathway_id: pathway_id,
      label: if(pathway, do: pathway_label(pathway), else: pathway_id),
      placement: placement
    }
  end

  defp endpoint_name(stop_points, stop_id) do
    case Map.get(stop_points, stop_id) do
      %{name: name} -> name
      _point -> stop_id
    end
  end

  @doc """
  Returns one window endpoint for the editor's text field: `H:MM` when the
  seconds are zero, otherwise the full service time.

  The field accepts `H:MM`, `HH:MM` and `H:MM:SS`, so the short form a reader
  already saw in the list round-trips unchanged, while `26:00:30` keeps the
  seconds it carries.
  """
  @spec service_time_value(non_neg_integer()) :: String.t()
  # Named exception: the closure field accepts H:MM and keeps nonzero seconds.
  def service_time_value(seconds) when is_integer(seconds) do
    case String.split(GtfsTime.format(seconds), ":") do
      [hours, minutes, "00"] -> "#{hours}:#{minutes}"
      parts -> Enum.join(parts, ":")
    end
  end

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

  The option label is the pathway's `Mode · From ↔ To` label plus the exact
  `pathway_id`, so the chosen option names the same natural ID the row and the
  locator show, and the group order is the locator's own order.
  """
  @spec pathway_options([map()]) :: [{String.t(), [{String.t(), String.t()}]}]
  def pathway_options(pathways) do
    pathways
    |> mode_groups()
    |> Enum.map(fn group ->
      {group.label, Enum.map(group.pathways, &{pathway_option_label(&1), &1.pathway_id})}
    end)
  end

  defp pathway_option_label(pathway), do: "#{pathway_label(pathway)} · #{pathway.pathway_id}"

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

  The sentence states which travel the closure removes: both ways of a
  two-way pathway, or the recorded direction of a one-way one. With no
  pathway chosen it says what the picker accepts.
  """
  @spec pathway_help(map() | nil) :: String.t()
  def pathway_help(nil), do: "Any pathway at this station, including walkways and stairs."

  def pathway_help(%{is_bidirectional: true}), do: "Closes it both ways."

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
    "used by #{Wording.count_noun(trips, "trip")} and " <>
      Wording.count_noun(closures, "closure")
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
    time = Time.from_seconds_after_midnight(rem(end_time, 86_400))

    "#{window_label(%{start_time: start_time, end_time: end_time})} " <>
      "(until #{DisplayClock.format_time(time)} #{later_label(end_time)})"
  end

  defp window_phrase(start_time, end_time),
    do: window_label(%{start_time: start_time, end_time: end_time})

  defp reopen_sentence(%{is_bidirectional: true}, _start_time, end_time),
    do: "Reopens both ways #{reopen_at(end_time)}."

  defp reopen_sentence(pathway, _start_time, end_time),
    do:
      "The #{pathway.pathway_mode |> Pathway.mode_label() |> String.downcase()} reopens #{reopen_at(end_time)}."

  defp reopen_at(86_400), do: "at midnight (24:00)"

  defp reopen_at(end_time) when end_time > 86_400 do
    time = Time.from_seconds_after_midnight(rem(end_time, 86_400))

    "at #{DisplayClock.format_time(time)} #{later_label(end_time)}"
  end

  defp reopen_at(end_time), do: "at #{GtfsTime.display(end_time)}"

  defp calendar_phrase(%{label: label}), do: label
  defp calendar_phrase(_calendar), do: "the calendar"

  # Only a calendar the version knows can say how many active dates it has; a
  # referenced service without a native row leaves the sentence open rather than
  # claiming it does not run.
  defp no_active_dates_suffix(%{active_date_count: 0, label: label}),
    do: " #{label} has no active service dates, so this closure does not apply yet."

  defp no_active_dates_suffix(_calendar), do: ""

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

  # -- access preview --------------------------------------------------------

  @doc """
  Renders the closures view switch: the closure list and the moment access
  preview as two routes of one LiveView.

  This is navigation, not a client-side toggle, so both destinations are
  `patch` links of the mounted view and the current one carries
  `aria-current="page"`. The active segment is the design system's scope
  toggle: the inverse surface with bold white text.
  """
  attr :current, :atom, required: true, doc: "`:index` for the list, `:access` for the preview"
  attr :closures_href, :string, required: true
  attr :access_href, :string, required: true

  def evolutions_view_nav(assigns) do
    ~H"""
    <nav
      id="evolutions-view-nav"
      aria-label="Closure views"
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
      "flex min-h-11 items-center px-4 text-sm no-underline",
      extra,
      current? && "bg-strong font-bold text-white",
      !current? && "font-[650] text-strong hover:bg-canvas"
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
  Renders one connection state: an icon plus the state word, so no status
  depends on color alone.

  A table stays quiet in its common case, so `Available` is coloured text and an
  icon on the row and `No route` is muted: that pair is unreachable even
  without closures, a consequence and not a second problem. Only `Lost`, the
  exception, takes a tinted badge.
  """
  attr :state, :atom, required: true, values: [:available, :lost, :gap]
  attr :id, :string, default: nil

  def connection_badge(%{state: :lost} = assigns) do
    ~H"""
    <.tone_badge tone="error" id={@id} data-connection-state="lost" class="whitespace-nowrap">
      Lost
    </.tone_badge>
    """
  end

  def connection_badge(assigns) do
    ~H"""
    <span
      id={@id}
      data-connection-state={@state}
      class={[
        "inline-flex items-center gap-1.5 whitespace-nowrap text-[13px] font-[650]",
        quiet_class(@state)
      ]}
    >
      <.icon name={quiet_icon(@state)} class="size-4" />{quiet_label(@state)}
    </span>
    """
  end

  defp quiet_class(:available), do: "text-success-fg"
  defp quiet_class(:gap), do: "text-muted"

  defp quiet_icon(:available), do: "hero-check-circle"
  defp quiet_icon(:gap), do: "hero-no-symbol"

  defp quiet_label(:available), do: "Available"
  defp quiet_label(:gap), do: "No route"

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
  attr :floorplan_missing?, :boolean, default: false
  attr :floorplan_href, :string, default: nil

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
        <.tone_badge :if={@incomplete?} tone="warning" id="findings-incomplete-badge">
          Incomplete
        </.tone_badge>
        <p
          id="preview-floorplan-missing"
          hidden={not @floorplan_missing?}
          class="flex items-center gap-1.5 text-[13px] text-muted"
        >
          <.icon name="hero-information-circle" class="size-4" />
          <span>
            No floorplan image is available for this station, so the station view is not shown.
            <a :if={@floorplan_href} href={@floorplan_href} class="font-[650]">Floorplans</a>
          </span>
        </p>
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
                row_index < length(group.rows) - 1 && "border-b border-subtle"
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
                row_index < length(group.rows) - 1 && "border-b border-subtle",
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
            <li :for={row <- group.rows} class="border-t border-subtle py-3 first:border-t-0">
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
            data-cause-pathway={cause.pathway_id}
            class="flex flex-wrap items-center justify-between gap-x-4 gap-y-1 border-t border-subtle py-2 first:border-t-0"
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
        class="flex items-start gap-2 border-t border-subtle bg-canvas px-5 py-3 text-[13px] text-muted"
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

  # The four action instants the domain derives for one selected-date instance,
  # in the order the reference shows them. Each button's second line is the
  # phase's own name, so a reader sees which side of the window it names.
  @timeline_phases [:before, :closes, :during, :reopens]

  # Timeline gridlines every six service hours. A regular tick closer to the end
  # than a twelfth of the axis is dropped instead of printed beside the end
  # label, so `24:00` and `26:00` never overlap on a narrow axis.
  @axis_tick_seconds 21_600

  attr :snapshot, :map, required: true
  attr :preview, :map, required: true
  attr :axis_note, :string, required: true

  @doc """
  Renders the closure-instance timeline of one moment preview.

  Every row is one instance `timeline_instances` carried: an instance belonging
  to the selected service date, or one from an earlier or later service date
  that intersects the displayed span. A row of another service date is labelled
  with that date, and its bar is clipped to the span for drawing only - the
  instance identity, its own window and its own service date stay the domain's
  values. Bars are positioned in service seconds from `timeline_start`, and the
  axis reaches the later of the span and `24:00`.

  Boundary actions are shown only for the selected service date's instances,
  because those are the instances the domain derived `boundary_targets` for
  (AC-38). Each action names an exact instant through that map; the view never
  reparses a civil label or derives an origin of its own.
  """
  def preview_timeline(assigns) do
    assigns = assign(assigns, :timeline, timeline(assigns.preview, assigns.snapshot))

    ~H"""
    <section
      id="preview-timeline"
      aria-labelledby="timeline-title"
      tabindex="-1"
      data-axis-seconds={@timeline.axis}
      class="flex min-w-0 flex-col overflow-clip rounded-card border border-subtle bg-white"
    >
      <header class="flex flex-wrap items-start justify-between gap-x-6 gap-y-2 border-b border-subtle px-5 py-3.5">
        <div class="min-w-0">
          <h2
            id="timeline-title"
            class="flex min-h-[26px] items-center font-display text-[18px] tracking-[-0.02em]"
          >
            Closures on {@timeline.date_label}
          </h2>
          <p id="timeline-sub" class="mt-0.5 text-[13px] text-muted">{@axis_note}</p>
        </div>
        <ul
          class="flex flex-wrap items-center gap-x-4 gap-y-1 text-[13px] text-muted"
          aria-label="Timeline legend"
        >
          <li class="flex items-center gap-1.5">
            <span
              aria-hidden="true"
              class="evo-closed-bar inline-block h-3.5 w-6 rounded-badge"
            ></span>Closed
          </li>
          <li class="flex items-center gap-1.5">
            <span aria-hidden="true" class="inline-block h-4 w-0.5 bg-strong"></span>
            <span id="timeline-cursor-label">Selected time · {@timeline.cursor_label}</span>
          </li>
        </ul>
      </header>

      <div class="px-4 pt-3 pb-4 md:px-5">
        <div class="grid lg:grid-cols-[minmax(0,17rem)_minmax(0,1fr)_minmax(0,20rem)] lg:gap-x-5">
          <div class="max-lg:hidden"></div>
          <div
            id="timeline-axis"
            aria-hidden="true"
            class="relative h-6 text-[12px] tabular-nums text-muted"
          >
            <span
              :for={tick <- @timeline.ticks}
              id={"timeline-tick-#{tick.seconds}"}
              class={["absolute top-0", tick.position]}
              style={if(tick.position == "-translate-x-1/2", do: "left: #{tick.pct}%", else: nil)}
            >
              {tick.label}
            </span>
          </div>
        </div>

        <ol id="timeline-rows" class="mt-1">
          <li
            :for={row <- @timeline.rows}
            id={row.id}
            data-timeline-row={row.instance_id}
            data-service-date={row.service_date}
            data-start-time={row.start_time}
            data-end-time={row.end_time}
            data-from-seconds={row.from}
            data-to-seconds={row.to}
            class="grid items-center border-t border-subtle py-2.5 lg:grid-cols-[minmax(0,17rem)_minmax(0,1fr)_minmax(0,20rem)] lg:gap-x-5"
          >
            <div class="min-w-0 max-lg:mb-2">
              <p class="text-[13px] leading-snug font-[650] text-strong">
                {row.pathway_label}
              </p>
              <p class="flex flex-wrap items-center gap-x-1.5 text-[13px] leading-snug tabular-nums text-muted">
                <span class="font-mono">{row.pathway_id}</span>
                <span>·</span>
                <span>{row.window}</span>
                <span
                  :if={row.elsewhere?}
                  data-spill={row.service_date}
                  class="inline-flex items-center gap-0.5 rounded-badge bg-info-bg px-1.5 text-[13px] font-[650] text-info-fg"
                >
                  <.icon name="hero-chevron-double-left" class="size-3" />From {row.service_label} service
                </span>
              </p>
            </div>

            <div
              id={row.bar_id}
              data-timeline-bar={row.service_date}
              title={row.title}
              class="relative h-8 min-w-0 rounded-badge bg-canvas"
            >
              <span
                :for={tick <- @timeline.ticks}
                :if={tick.seconds > 0}
                aria-hidden="true"
                class="evo-axis-grid absolute inset-y-0 w-px"
                style={"left: #{tick.pct}%"}
              >
              </span>
              <span
                :if={@timeline.cursor_pct}
                id={"#{row.bar_id}-cursor"}
                data-timeline-cursor
                aria-hidden="true"
                class="absolute inset-y-0 z-10 w-0.5 -translate-x-1/2 bg-strong"
                style={"left: #{@timeline.cursor_pct}%"}
              >
              </span>
              <span
                data-timeline-closed={row.service_date}
                class={[
                  "evo-closed-bar absolute inset-y-1 min-w-[3px] rounded-badge",
                  row.clipped_left? && "rounded-l-none border-l-0"
                ]}
                style={"left: #{row.left}%; width: #{row.width}%"}
              >
                <span class="sr-only">Closed {row.window}</span>
              </span>
            </div>

            <div class="mt-2 grid grid-cols-4 gap-1 lg:col-start-3 lg:mt-0">
              <button
                :for={boundary <- row.boundaries}
                id={boundary.id}
                type="button"
                data-boundary-phase={boundary.kind}
                data-boundary-date={boundary.service_date}
                data-boundary-time={boundary.time}
                aria-pressed={to_string(boundary.pressed?)}
                phx-click="preview_boundary"
                phx-value-evolution-id={row.instance_id}
                phx-value-service-date={row.service_date}
                phx-value-phase={boundary.kind}
                class="group flex min-h-11 min-w-0 flex-col items-center justify-center rounded-control border border-control bg-white px-1 leading-tight text-strong hover:bg-canvas aria-pressed:border-action aria-pressed:bg-selection aria-pressed:text-action-hover"
              >
                <span class="min-w-0 text-center text-[13px] font-[650] tabular-nums">
                  <span :if={boundary.weekday}>{boundary.weekday <> " "}</span><span class="whitespace-nowrap">{boundary.time_label}</span>
                </span>
                <span class="text-[12px] text-muted group-aria-pressed:text-action-hover">
                  {boundary.kind}
                </span>
              </button>
              <p
                :if={row.boundaries == []}
                id={row.id <> "-actions"}
                class="col-span-4 flex min-h-11 items-center text-[13px] text-muted"
              >
                Boundary actions are on the {row.service_label} service date.
              </p>
            </div>
          </li>
        </ol>

        <p
          :if={@timeline.rows == []}
          id="timeline-empty"
          class="border-t border-subtle pt-4 text-sm text-muted"
        >
          No closure affects {@timeline.date_label}. Choose another date to see its closures.
        </p>
      </div>
    </section>
    """
  end

  # One row per instance of the displayed span, in the order the domain built
  # them. The axis reaches the later of the span and 24:00, so a window past
  # midnight keeps its whole bar and a short civil day still reads as a day.
  defp timeline(preview, snapshot) do
    starts_at = preview.timeline_start
    axis = max(DateTime.diff(preview.timeline_end, starts_at, :second), 86_400)
    cursor = preview.service_time

    %{
      axis: axis,
      date_label: Calendar.strftime(preview.service_date, "%a, %b %-d"),
      cursor_label: GtfsTime.display(cursor),
      cursor_pct: if(cursor <= axis, do: pct(cursor, axis), else: nil),
      ticks: axis_ticks(axis),
      rows:
        Enum.map(
          preview.timeline_instances,
          &timeline_row(&1, preview, snapshot, starts_at, axis)
        )
    }
  end

  defp timeline_row(instance, preview, snapshot, starts_at, axis) do
    row = Enum.find(snapshot.closures, &(&1.evolution.id == instance.evolution_id))
    from = DateTime.diff(instance.starts_at, starts_at, :second)
    left = max(from, 0)
    right = min(DateTime.diff(instance.ends_at, starts_at, :second), axis)
    elsewhere? = Date.compare(instance.service_date, preview.service_date) != :eq

    %{
      id: "timeline-instance-#{instance.evolution_id}-#{Date.to_iso8601(instance.service_date)}",
      bar_id: "timeline-bar-#{instance.evolution_id}-#{Date.to_iso8601(instance.service_date)}",
      instance_id: instance.evolution_id,
      service_date: Date.to_iso8601(instance.service_date),
      service_label: service_date_label(instance.service_date),
      start_time: instance.start_time,
      end_time: instance.end_time,
      from: left,
      to: max(right, left),
      left: pct(left, axis),
      width: pct(max(right - left, 0), axis),
      clipped_left?: left == 0 and from < 0,
      pathway_label: if(row, do: pathway_label(row.pathway), else: instance.pathway_id),
      pathway_id: instance.pathway_id,
      window: window_label(instance),
      elsewhere?: elsewhere?,
      title: timeline_title(row, instance, elsewhere?),
      boundaries: if(elsewhere?, do: [], else: boundaries(instance, preview))
    }
  end

  # The domain's own boundary targets for one selected-date instance. A phase
  # the preview did not derive is simply absent, and an action carries the exact
  # date and elapsed seconds it names, so a click never renames an instant.
  defp boundaries(instance, preview) do
    Enum.flat_map(@timeline_phases, fn phase ->
      case Map.get(
             preview.boundary_targets,
             {instance.evolution_id, instance.service_date, phase}
           ) do
        %{date: %Date{} = date, time: time} when is_integer(time) ->
          [
            %{
              id: "boundary-#{instance.evolution_id}-#{Date.to_iso8601(date)}-#{phase}",
              kind: Atom.to_string(phase),
              service_date: Date.to_iso8601(date),
              time: time,
              time_label: GtfsTime.display(time),
              weekday:
                if(Date.compare(date, preview.service_date) == :eq, do: nil, else: weekday(date)),
              pressed?:
                Date.compare(date, preview.service_date) == :eq and time == preview.service_time
            }
          ]

        _absent ->
          []
      end
    end)
  end

  defp axis_ticks(axis) do
    regular =
      0
      |> Stream.iterate(&(&1 + @axis_tick_seconds))
      |> Enum.take_while(&(&1 < axis))
      |> Enum.filter(&(&1 == 0 or axis - &1 >= div(axis, 12)))

    (regular ++ [axis])
    |> Enum.uniq()
    |> Enum.map(fn seconds ->
      %{
        seconds: seconds,
        label: GtfsTime.display(seconds),
        pct: pct(seconds, axis),
        position: axis_position(seconds, axis)
      }
    end)
  end

  defp axis_position(0, _axis), do: "left-0"
  defp axis_position(seconds, seconds), do: "right-0"
  defp axis_position(_seconds, _axis), do: "-translate-x-1/2"

  # A percentage with a fixed three decimals, so a bar's own geometry is
  # reproducible and can be read back by an assertion.
  defp pct(seconds, axis) do
    seconds
    |> Kernel./(axis)
    |> Kernel.*(100)
    |> Float.round(3)
    |> :erlang.float_to_binary(decimals: 3)
  end

  defp service_date_label(%Date{} = date), do: Calendar.strftime(date, "%a, %b %-d")

  defp weekday(%Date{} = date), do: Calendar.strftime(date, "%a")

  defp timeline_title(row, instance, elsewhere?) do
    label = if(row, do: pathway_label(row.pathway), else: instance.pathway_id)

    suffix =
      if elsewhere?,
        do: " on the #{Calendar.strftime(instance.service_date, "%A, %B %-d, %Y")} service day",
        else: ""

    "#{label} closed #{window_label(instance)}#{suffix}"
  end

  # -- range report -----------------------------------------------------------

  @doc """
  Returns the exact address of one service moment of the access route.

  The service time is the `HH:MM:SS` form the route accepts, and the station id
  and query are encoded exactly as the router decodes them, so a period's
  `Show at` link and the request behind it name one instant.
  """
  @spec access_moment_path(String.t(), String.t(), Date.t(), non_neg_integer()) :: String.t()
  def access_moment_path(version_id, stop_id, %Date{} = date, time) when is_integer(time) do
    query =
      URI.encode_query([
        {"date", Date.to_iso8601(date)},
        {"time", GtfsTime.format(time)}
      ])

    "/gtfs/#{version_id}/stops/#{URI.encode(stop_id)}/evolutions/access?#{query}"
  end

  @doc """
  Formats a UTC offset in seconds as `+HH:MM` or `-HH:MM`.

  Both the moment line and a range period's DST note read their offsets through
  this one function, so an offset is written one way on the page.
  """
  @spec utc_offset_label(integer()) :: String.t()
  def utc_offset_label(seconds) when is_integer(seconds) do
    total = abs(seconds)
    sign = if seconds < 0, do: "-", else: "+"
    hours = div(total, 3600) |> Integer.to_string() |> String.pad_leading(2, "0")
    minutes = div(rem(total, 3600), 60) |> Integer.to_string() |> String.pad_leading(2, "0")
    sign <> hours <> ":" <> minutes
  end

  @doc """
  Labels a service-date span exactly: one date, a same-month or same-year range,
  or both years when the span crosses one.
  """
  @spec range_dates_label(Date.t(), Date.t()) :: String.t()
  def range_dates_label(%Date{} = first, %Date{} = last) do
    cond do
      Date.compare(first, last) == :eq ->
        Calendar.strftime(first, "%b %-d, %Y")

      first.year != last.year ->
        "#{Calendar.strftime(first, "%b %-d, %Y")}–#{Calendar.strftime(last, "%b %-d, %Y")}"

      first.month != last.month ->
        "#{Calendar.strftime(first, "%b %-d")}–#{Calendar.strftime(last, "%b %-d, %Y")}"

      true ->
        "#{Calendar.strftime(first, "%b %-d")}–#{last.day}, #{last.year}"
    end
  end

  @doc """
  Prepares one range report for display: its exact periods, their groups, and
  whether grouping collapses anything.

  A period is one finding of `Gtfs.analyze_closures/5`, rendered as the domain
  reported it: its occurrence is the service date and elapsed seconds in the
  backend's own `preview_target`, its local window, both UTC offsets and its lost
  and platform findings come from the finding, and its causes are the finding's
  active instances. The view derives nothing: it never reparses a clock label,
  never re-derives a service-day origin, and never approximates a grouped gap as
  a continuous span.

  Grouping is view-only and lossless. Two periods join one group only when their
  local start and end clock values, their local day offset, both UTC offsets,
  their lost findings, their platform step-free findings and their active
  closure identities all agree. Occurrence dates stay an ordered list on the
  group, so its disclosure can name every date it covers. The offsets are part of
  the key, so a daylight-saving change inside a range keeps two groups apart
  instead of merging them into one span that never happened.
  """
  @spec range_display(map(), map(), String.t(), String.t()) :: map()
  def range_display(report, snapshot, version_id, stop_id) do
    stops = Map.new(snapshot.child_stops, &{&1.stop_id, &1})

    periods =
      report.findings
      |> Enum.with_index()
      |> Enum.map(fn {finding, index} ->
        range_period(finding, index, snapshot, stops, version_id, stop_id)
      end)

    groups = range_groups(periods)

    %{
      periods: periods,
      groups: groups,
      grouping?: length(groups) < length(periods),
      caption:
        if(length(groups) < length(periods),
          do: "Loss periods in this range, grouped when their window, offsets and causes repeat",
          else: "Every loss period in this range"
        )
    }
  end

  defp range_period(finding, index, snapshot, stops, version_id, stop_id) do
    target = finding.preview_target
    service_date = target.date
    local_start_date = NaiveDateTime.to_date(finding.local_start)
    local_end_date = NaiveDateTime.to_date(finding.local_end)

    %{
      id: "range-period-#{index}",
      list_id: "range-period-list-#{index}",
      kind: :period,
      index: index,
      period_count: 1,
      service_date: Date.to_iso8601(service_date),
      date_label: date_label(service_date),
      local_start: NaiveDateTime.to_iso8601(finding.local_start),
      local_end: NaiveDateTime.to_iso8601(finding.local_end),
      start_offset: finding.start_utc_offset,
      end_offset: finding.end_utc_offset,
      when_label:
        window_label(%{start_time: target.time, end_time: range_end_time(finding, target)}),
      clock_label: range_window(finding, service_date, local_start_date, local_end_date),
      offset_note: range_offset_note(finding),
      lost: lost_lines(finding.comparison, stops),
      causes: range_causes(finding.instances, service_date, snapshot),
      target_date: Date.to_iso8601(service_date),
      target_time: target.time,
      target_label: GtfsTime.display(target.time),
      href: access_moment_path(version_id, stop_id, target.date, target.time),
      show_id: "range-show-#{index}",
      # Only a grouped row discloses a list of dates; a period row is one date.
      dates: [],
      key: range_key(finding, local_start_date, local_end_date)
    }
  end

  # The identity the specification names: local clock start and end, the local
  # day offset, both UTC offsets, the exact lost findings, the platform step-free
  # findings and the closure identity/window tuples. Occurrence dates and the
  # absolute instants are deliberately absent, so the same window repeating on
  # several dates is one group.
  defp range_key(finding, local_start_date, local_end_date) do
    {
      Calendar.strftime(finding.local_start, "%H:%M"),
      Calendar.strftime(finding.local_end, "%H:%M"),
      Date.diff(local_end_date, local_start_date),
      {finding.start_utc_offset, finding.end_utc_offset},
      range_lost_key(finding.comparison),
      range_platform_key(finding.comparison),
      range_causes_key(finding.instances)
    }
  end

  defp range_lost_key(comparison) do
    comparison.lost
    |> Enum.map(&{&1.entrance_id, &1.platform_id, &1.mode, &1.direction})
    |> Enum.sort()
  end

  defp range_platform_key(comparison) do
    %{to_platform: to_platform, to_exit: to_exit} = comparison.platforms_without_step_free
    {Enum.sort(to_platform), Enum.sort(to_exit)}
  end

  defp range_causes_key(instances) do
    instances
    |> Enum.map(&{&1.evolution_id, &1.service_id, &1.start_time, &1.end_time})
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp range_groups(periods) do
    periods
    |> Enum.group_by(& &1.key)
    |> Enum.map(fn {_key, members} ->
      members = Enum.sort_by(members, &{&1.service_date, &1.target_time})
      first = hd(members)

      first
      |> Map.merge(%{
        id: "range-group-#{first.index}",
        list_id: "range-group-list-#{first.index}",
        kind: :group,
        period_count: length(members),
        date_label: range_pattern(members),
        dates: Enum.map(members, &range_occurrence/1),
        first_date_label: first.date_label,
        show_id: "range-show-group-#{first.index}"
      })
    end)
    |> Enum.sort_by(& &1.index)
  end

  # One date of a group, with its own exact target: the disclosure lists every
  # occurrence and links each one to the pair the backend named for it. The link
  # id is composed by the disclosure from its own id, because the same group is
  # rendered once per presentation and ids must stay unique across both.
  defp range_occurrence(period) do
    %{
      service_date: period.service_date,
      target_time: period.target_time,
      date: period.service_date,
      label: period.date_label,
      href: period.href,
      target_label: period.target_label
    }
  end

  # The group's own date pattern. A span whose every day is present reads as a
  # range; a span with a hole says `Between ...` instead of implying the days in
  # between. Either way the group's own disclosure carries every exact date.
  defp range_pattern(members) do
    dates =
      members
      |> Enum.map(& &1.service_date)
      |> Enum.map(&Date.from_iso8601!/1)
      |> Enum.sort(Date)

    case dates do
      [one] ->
        date_label(one)

      _many ->
        first = hd(dates)
        last = List.last(dates)
        span = Date.diff(last, first) + 1

        cond do
          span != length(dates) -> "Between #{range_dates_label(first, last)}"
          span >= 7 -> "Every day, #{range_dates_label(first, last)}"
          true -> range_dates_label(first, last)
        end
    end
  end

  # The period's end in the service time its start is already counted in: the
  # start is the backend's elapsed seconds from the service date's origin, and
  # the period's length is the elapsed time between its two instants, so the
  # end needs no origin of its own and holds across a daylight-saving change.
  defp range_end_time(finding, target),
    do: target.time + DateTime.diff(finding.ends_at, finding.starts_at, :second)

  # The local clock window of one period, with the local date named whenever it
  # is not the service date the group is keyed by, so a 25:00 window reads as the
  # next civil morning instead of as midnight of its own service date. It is the
  # secondary line under the service-time window the table leads with.
  defp range_window(finding, service_date, local_start_date, local_end_date) do
    window =
      "#{DisplayClock.format_time(finding.local_start)} – #{DisplayClock.format_time(finding.local_end)}"

    cond do
      Date.compare(local_start_date, service_date) != :eq ->
        window <> " on #{date_label(local_start_date)}"

      Date.compare(local_end_date, local_start_date) != :eq ->
        days = Date.diff(local_end_date, local_start_date)
        window <> if(days == 1, do: " next day", else: " +#{days} days")

      true ->
        window
    end
  end

  # A period whose own window crosses a daylight-saving change keeps both offsets
  # visible, so the reader can see why it is not grouped with the ordinary ones.
  defp range_offset_note(%{start_utc_offset: offset, end_utc_offset: offset}), do: nil

  defp range_offset_note(finding) do
    "Starts UTC#{utc_offset_label(finding.start_utc_offset)}, ends UTC#{utc_offset_label(finding.end_utc_offset)}"
  end

  defp lost_lines(comparison, stops) do
    %{to_platform: to_platform, to_exit: to_exit} = comparison.platforms_without_step_free

    platform_lines =
      Enum.map(to_platform, &"No step-free route to #{stop_label(Map.get(stops, &1))}") ++
        Enum.map(to_exit, &"No step-free route from #{stop_label(Map.get(stops, &1))}")

    pair_lines =
      Enum.map(comparison.lost, fn finding ->
        "#{@range_modes[finding.mode]} #{@range_directions[finding.direction]} · " <>
          "#{stop_label(Map.get(stops, finding.entrance_id))} ↔ " <>
          stop_label(Map.get(stops, finding.platform_id))
      end)

    platform_lines ++ pair_lines
  end

  defp range_causes(instances, service_date, snapshot) do
    instances
    |> Enum.uniq_by(&{&1.evolution_id, &1.service_date})
    |> Enum.sort_by(&{&1.service_date, &1.evolution_id})
    |> Enum.map(&range_cause(&1, service_date, snapshot))
  end

  defp range_cause(instance, service_date, snapshot) do
    row = Enum.find(snapshot.closures, &(&1.evolution.id == instance.evolution_id))
    {calendar_label, _detail} = calendar_lines(row && row.calendar, instance.service_id)

    spill =
      if Date.compare(instance.service_date, service_date) == :eq do
        nil
      else
        "from the #{Calendar.strftime(instance.service_date, "%A, %B %-d, %Y")} service day"
      end

    %{
      key: "#{instance.evolution_id}-#{Date.to_iso8601(instance.service_date)}",
      pathway_label: if(row, do: pathway_label(row.pathway), else: instance.pathway_id),
      pathway_id: instance.pathway_id,
      detail:
        [calendar_label, window_label(instance), spill]
        |> Enum.reject(&is_nil/1)
        |> Enum.join(" · ")
    }
  end

  attr :display, :map, required: true, doc: "the prepared range report"
  attr :view, :atom, required: true, values: [:grouped, :all]

  @doc """
  Renders a range report's loss periods: a table at `md` and wider and one card
  per row below it. Both carry the same rows and the same fields, grouped by
  repeated window when the grouped view is selected and one row per period in
  the every-period view. Each row's exact occurrence, local window, offsets and
  period count stay readable as data attributes.
  """
  def range_results(assigns) do
    # The view is resolved by the caller: when nothing repeats, the only honest
    # presentation is the report's own periods, and the caller passes the view
    # the report actually allows. Deriving it here would mutate the attribute
    # after the fact, and a re-render that only changed the report would keep the
    # previous header and its previous row kind.
    assigns =
      assign(
        assigns,
        :rows,
        if(assigns.view == :grouped, do: assigns.display.groups, else: assigns.display.periods)
      )

    ~H"""
    <div id="range-segments">
      <table
        :if={@rows != []}
        id="range-periods-table"
        class="w-full border-collapse text-left text-sm max-md:hidden"
      >
        <caption class="sr-only">{@display.caption}</caption>
        <thead>
          <tr>
            <th
              scope="col"
              class="h-11 w-[12rem] border-b border-subtle bg-canvas py-0 pr-4 pl-5 text-[13px] font-[650] text-base-content"
            >
              {if @view == :grouped, do: "Service dates", else: "Service date"}
            </th>
            <th
              scope="col"
              class="h-11 border-b border-subtle bg-canvas px-4 py-0 text-[13px] font-[650] text-base-content"
            >
              When
            </th>
            <th
              scope="col"
              class="h-11 border-b border-subtle bg-canvas px-4 py-0 text-[13px] font-[650] text-base-content"
            >
              Connections lost
            </th>
            <th
              scope="col"
              class="h-11 min-w-[18rem] border-b border-subtle bg-canvas px-4 py-0 text-[13px] font-[650] text-base-content"
            >
              Caused by
            </th>
            <th
              scope="col"
              class="h-11 w-[9.5rem] border-b border-subtle bg-canvas py-0 pr-5 pl-4 text-[13px] font-[650] text-base-content"
            >
              <span class="sr-only">Preview</span>
            </th>
          </tr>
        </thead>
        <tbody>
          <tr
            :for={row <- @rows}
            id={row.id}
            data-range-row={row.kind}
            data-service-date={row.service_date}
            data-target-time={row.target_time}
            data-period-count={row.period_count}
            data-local-start={row.local_start}
            data-local-end={row.local_end}
            data-start-offset={row.start_offset}
            data-end-offset={row.end_offset}
            class="align-top hover:bg-canvas"
          >
            <th scope="row" class="border-b border-subtle py-2.5 pr-4 pl-5 font-normal">
              <span id={row.id <> "-date-label"} class="block font-[650] text-strong">
                {row.date_label}
              </span>
              <span
                :if={@view == :grouped and row.period_count == 1}
                class="block text-[13px] text-muted"
              >
                1 day
              </span>
              <.range_date_disclosure
                :if={row.dates != []}
                row={row}
                id={row.id <> "-dates"}
              />
            </th>
            <td class="border-b border-subtle px-4 py-2.5">
              <div id={row.id <> "-when"}>
                <span class="block font-[650] tabular-nums text-strong">{row.when_label}</span>
                <span class="block text-[13px] tabular-nums text-muted">{row.clock_label}</span>
              </div>
              <span :if={row.offset_note} class="block text-[13px] text-muted">
                {row.offset_note}
              </span>
            </td>
            <td class="border-b border-subtle px-4 py-2.5">
              <.lost_lines lines={row.lost} id={row.id <> "-lost"} />
            </td>
            <td class="border-b border-subtle px-4 py-2.5">
              <.range_cause_list causes={row.causes} id_prefix={row.id} />
            </td>
            <td class="border-b border-subtle py-1 pr-5 pl-4">
              <.range_show_at row={row} id={row.show_id} />
              <span :if={length(row.dates) > 1} class="block text-[13px] text-muted">
                First on {row.first_date_label}
              </span>
            </td>
          </tr>
        </tbody>
      </table>

      <ul :if={@rows != []} id="range-periods-list" class="md:hidden">
        <li
          :for={row <- @rows}
          id={row.list_id}
          data-range-row={row.kind}
          data-service-date={row.service_date}
          data-target-time={row.target_time}
          data-period-count={row.period_count}
          data-local-start={row.local_start}
          data-local-end={row.local_end}
          data-start-offset={row.start_offset}
          data-end-offset={row.end_offset}
          class="border-t border-subtle px-4 py-3 first:border-t-0"
        >
          <p id={row.list_id <> "-date-label"} class="font-[650] text-strong">{row.date_label}</p>
          <div id={row.list_id <> "-when"} class="mt-0.5">
            <span class="block font-[650] tabular-nums text-strong">{row.when_label}</span>
            <span class="block text-[13px] tabular-nums text-muted">{row.clock_label}</span>
          </div>
          <p :if={row.offset_note} class="text-[13px] text-muted">{row.offset_note}</p>
          <.lost_lines lines={row.lost} id={row.list_id <> "-lost"} />
          <.range_cause_list causes={row.causes} id_prefix={row.list_id} />
          <div class="mt-1 flex flex-wrap items-center gap-x-4 gap-y-1">
            <.range_show_at row={row} id={row.list_id <> "-show"} />
            <.range_date_disclosure
              :if={row.dates != []}
              row={row}
              id={row.list_id <> "-dates"}
            />
          </div>
        </li>
      </ul>
    </div>
    """
  end

  attr :lines, :list, required: true
  attr :id, :string, required: true

  @doc """
  Renders the exact connections one range period loses: the platform that lost
  its last step-free route first, then each lost pair with its mode and
  direction.
  """
  def lost_lines(assigns) do
    ~H"""
    <ul id={@id} class="space-y-0.5">
      <li :for={line <- @lines} class="text-sm text-strong">{line}</li>
    </ul>
    """
  end

  attr :causes, :list, required: true
  attr :id_prefix, :string, required: true

  @doc """
  Renders the active closures of one range period: each closure's pathway label,
  its exact natural ID and its calendar and service window.
  """
  def range_cause_list(assigns) do
    ~H"""
    <ul>
      <li :for={cause <- @causes} id={@id_prefix <> "-cause-" <> cause.key} class="mt-1 first:mt-0">
        <span class="block text-sm text-strong">{cause.pathway_label}</span>
        <span class="block text-[13px] text-muted">
          <span class="font-mono">{cause.pathway_id}</span> · {cause.detail}
        </span>
      </li>
    </ul>
    """
  end

  attr :row, :map, required: true
  attr :id, :string, required: true

  @doc """
  Renders one period's link to the exact moment the backend named for it.
  """
  def range_show_at(assigns) do
    ~H"""
    <.link
      patch={@row.href}
      id={@id}
      data-show-date={@row.target_date}
      data-show-time={@row.target_label}
      class="inline-flex min-h-11 items-center whitespace-nowrap text-sm font-[650] text-action no-underline hover:underline"
    >
      Show at {@row.target_label}
    </.link>
    """
  end

  attr :row, :map, required: true
  attr :id, :string, required: true

  @doc """
  Renders one group's date disclosure: every date it covers, each with its own
  exact `Show at` target, so a repeated window never implies an untouched date
  between two occurrences.
  """
  def range_date_disclosure(assigns) do
    ~H"""
    <details id={@id} data-range-dates={length(@row.dates)} class="mt-0.5">
      <summary class="inline-flex min-h-11 cursor-pointer items-center gap-1 text-[13px] font-[650] text-action">
        <.icon name="hero-chevron-right" class="size-3.5" />{length(@row.dates)} days
      </summary>
      <div class="mt-1 rounded-control bg-canvas px-2 py-2">
        <p class="text-[13px] text-muted">Preview at {@row.target_label} on:</p>
        <ul class="mt-1 flex flex-wrap gap-x-1">
          <li :for={date <- @row.dates}>
            <.link
              patch={date.href}
              id={"#{@id}-#{date.service_date}-#{date.target_time}"}
              data-show-date={date.date}
              data-show-time={date.target_label}
              class="inline-flex min-h-11 items-center rounded-control px-2 text-sm font-[650] tabular-nums text-action no-underline hover:bg-canvas hover:underline"
            >
              {date.label}
            </.link>
          </li>
        </ul>
      </div>
    </details>
    """
  end

  defp date_label(%Date{} = date), do: Calendar.strftime(date, "%a, %b %-d")

  attr :id, :string, required: true
  attr :title, :string, required: true

  attr :body, :list,
    required: true,
    doc: "sentence parts for `sentence/1`: text, and `{:pathway_id, id}` for an ID"

  attr :tone, :atom, required: true, values: [:loss, :ok]
  attr :computed_label, :string, required: true
  attr :moment_label, :string, required: true
  attr :moment_zone, :string, default: nil, doc: "the agency zone and offset, as secondary text"

  @doc """
  Renders the moment preview's result verdict: a tone badge, the conclusion as
  the heading, one paragraph of what it means and the moment it describes.

  A closure that removes access is a confirmed interruption, so a loss takes
  the error tone and an all-clear the success tone. The tone rides on the
  card's head rule and badge, and the words carry the same meaning. The
  computed-at line is the card's footer.
  """
  def preview_banner(assigns) do
    ~H"""
    <.result_summary
      id={@id}
      title_id="preview-result-title"
      tone={if @tone == :loss, do: "error", else: "success"}
      badge={if @tone == :loss, do: "Access interrupted", else: "Access kept"}
      title={@title}
    >
      <span id="preview-result-body"><.sentence parts={@body} /></span>
      <:extra>
        <p id="preview-moment" class="mt-3 text-[13px] tabular-nums text-default">
          {@moment_label}<span :if={@moment_zone} class="text-muted"> · {@moment_zone}</span>
        </p>
      </:extra>
      <:foot><span id="preview-computed">{@computed_label}</span></:foot>
    </.result_summary>
    """
  end

  @doc """
  Renders a sentence built from parts: text, and `{:pathway_id, id}` for a
  pathway's ID, which reads as muted monospace secondary text beside its
  `Mode · From ↔ To` label instead of as a name.
  """
  attr :parts, :list, required: true

  def sentence(assigns) do
    ~H"""
    <span :for={part <- @parts} class={sentence_part_class(part)}>{sentence_part_text(part)}</span>
    """
  end

  defp sentence_part_class({:pathway_id, _id}), do: "font-mono text-[13px] text-muted"
  defp sentence_part_class(_text), do: nil

  defp sentence_part_text({:pathway_id, id}), do: id
  defp sentence_part_text(text), do: text

  defp direction_label(:to_platform), do: "To platform"
  defp direction_label(:to_exit), do: "From platform"

  defp stop_label(%{stop_name: name}) when is_binary(name) and name != "", do: name
  defp stop_label(%{stop_id: stop_id}), do: stop_id
  defp stop_label(_stop), do: "Unknown stop"
end
