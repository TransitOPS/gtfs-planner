defmodule GtfsPlannerWeb.Gtfs.StationJournalMarkers do
  @moduledoc """
  Pure page-owned module for building deterministic marker indices, projecting
  active level markers, resolving locators, and generating accessible marker names
  from journal entry payloads.
  """

  alias GtfsPlanner.Gtfs.JournalEntry
  alias GtfsPlanner.Gtfs.Pathway
  alias GtfsPlanner.Gtfs.Stop

  @type marker_kind :: :pin | :node | :pathway
  @type marker_key :: String.t()
  @type target_scope :: %{
          target_type: :node | :pathway,
          target_id: Ecto.UUID.t(),
          label: String.t()
        }
  @type target_snapshots :: %{
          presentations: %{optional(Ecto.UUID.t()) => %{label: String.t()}},
          nodes: %{optional(Ecto.UUID.t()) => Stop.t() | map()},
          pathways: %{optional(Ecto.UUID.t()) => Pathway.t() | map()},
          stop_levels: %{optional(Ecto.UUID.t()) => map()}
        }
  @type geometry :: %{
          active_level_id: String.t() | nil,
          child_stops: [Stop.t() | map()],
          pathways: [Pathway.t() | map()],
          focused_marker_id: marker_key() | nil
        }
  @type marker :: %{
          id: marker_key(),
          kind: marker_kind(),
          target_id: Ecto.UUID.t() | nil,
          entry_ids: [Ecto.UUID.t()],
          focus_entry_id: Ecto.UUID.t(),
          open_count: non_neg_integer(),
          total_count: pos_integer(),
          state: :open | :closed,
          x: float(),
          y: float(),
          accessible_name: String.t(),
          focused?: boolean()
        }
  @type index :: %{
          groups: %{optional(marker_key()) => map()},
          entry_to_marker: %{optional(Ecto.UUID.t()) => marker_key()},
          floorplan_entry_ids: MapSet.t(Ecto.UUID.t()),
          locators: %{optional(Ecto.UUID.t()) => map()}
        }

  @doc """
  Builds a deterministic page-owned marker index from scoped journal entries
  and target snapshots without performing database queries.
  """
  @spec build_index([JournalEntry.t() | map()], target_snapshots()) :: index()
  def build_index(entries, targets) when is_list(entries) and is_map(targets) do
    valid_entries = Enum.reject(entries, &station_entry?/1)
    grouped_entries = collect_grouped_entries(valid_entries, targets)
    processed_groups = Map.new(grouped_entries, &process_group_tuple(&1, targets))

    %{
      groups: processed_groups,
      entry_to_marker: build_entry_to_marker(processed_groups),
      floorplan_entry_ids: build_floorplan_entry_ids(processed_groups),
      locators: build_locators(processed_groups, targets)
    }
  end

  def build_index(_, _),
    do: %{
      groups: %{},
      entry_to_marker: %{},
      floorplan_entry_ids: MapSet.new(),
      locators: %{}
    }

  @doc """
  Projects the index onto active geometry, outputting sorted markers for rendering.
  """
  @spec project(index(), geometry()) :: [marker()]
  def project(%{groups: groups}, geometry) when is_map(groups) and is_map(geometry) do
    active_level_id = normalize_id(geometry[:active_level_id])
    focused_marker_id = geometry[:focused_marker_id]

    groups
    |> Enum.flat_map(&project_single_group(&1, active_level_id, geometry, focused_marker_id))
    |> Enum.sort_by(& &1.id)
  end

  def project(_, _), do: []

  @doc """
  Resolves an active marker by ID against current geometry.
  """
  @spec active_marker(index(), marker_key(), geometry()) :: {:ok, marker()} | :error
  def active_marker(index, marker_id, geometry) when is_binary(marker_id) do
    case Enum.find(project(index, geometry), fn m -> m.id == marker_id end) do
      nil -> :error
      marker -> {:ok, marker}
    end
  end

  def active_marker(_, _, _), do: :error

  @doc """
  Resolves locator data for a given entry ID.
  """
  @spec locate_entry(index(), Ecto.UUID.t()) :: {:ok, map()} | :error
  def locate_entry(%{locators: locators, floorplan_entry_ids: floorplan_ids}, entry_id)
      when is_map(locators) do
    if MapSet.member?(floorplan_ids, entry_id) do
      Map.fetch(locators, entry_id)
    else
      :error
    end
  end

  def locate_entry(_, _), do: :error

  # Private Index Construction Helpers

  defp collect_grouped_entries(valid_entries, targets) do
    Enum.reduce(valid_entries, %{}, fn entry, acc ->
      case classify_entry(entry, targets) do
        {:ok, marker_key, group_data} ->
          existing = Map.get(acc, marker_key, %{group_data | entries: []})
          Map.put(acc, marker_key, %{existing | entries: [entry | existing.entries]})

        :error ->
          acc
      end
    end)
  end

  defp process_group_tuple({marker_key, group}, targets) do
    sorted_entries = sort_entries(group.entries)
    entry_ids = Enum.map(sorted_entries, & &1.id)
    focus_entry_id = List.first(entry_ids)
    open_count = Enum.count(sorted_entries, &is_nil(&1.closed_at))
    total_count = length(sorted_entries)
    state = if open_count > 0, do: :open, else: :closed

    acc_name = build_accessible_name(group, sorted_entries, open_count, total_count, targets)

    processed = %{
      id: marker_key,
      kind: group.kind,
      target_id: group.target_id,
      stop_level_id: group[:stop_level_id],
      x: group[:x],
      y: group[:y],
      entries: sorted_entries,
      entry_ids: entry_ids,
      focus_entry_id: focus_entry_id,
      open_count: open_count,
      total_count: total_count,
      state: state,
      accessible_name: acc_name
    }

    {marker_key, processed}
  end

  defp build_accessible_name(%{kind: :pin}, [pin_entry | _], _open, _total, _targets) do
    excerpt = extract_note_excerpt(pin_entry.body)

    if is_nil(pin_entry.closed_at) do
      "Journal entry: #{excerpt}"
    else
      "Journal entry, closed: #{excerpt}"
    end
  end

  defp build_accessible_name(group, _entries, open_count, total_count, targets) do
    label = resolve_target_label(targets, group.kind, group.target_id)
    "Journal: #{open_count} open of #{total_count} entries · #{label}"
  end

  defp build_entry_to_marker(groups) do
    Enum.reduce(groups, %{}, fn {marker_key, group}, acc ->
      Enum.reduce(group.entry_ids, acc, fn entry_id, map_acc ->
        Map.put(map_acc, entry_id, marker_key)
      end)
    end)
  end

  defp build_floorplan_entry_ids(groups) do
    Enum.reduce(groups, MapSet.new(), fn {_key, group}, set_acc ->
      if group.kind == :pin or group.open_count > 0 do
        Enum.into(group.entry_ids, set_acc)
      else
        set_acc
      end
    end)
  end

  defp build_locators(groups, targets) do
    Enum.reduce(groups, %{}, fn {marker_key, group}, loc_acc ->
      label = resolve_target_label(targets, group.kind, group.target_id)

      Enum.reduce(group.entries, loc_acc, fn entry, inner_acc ->
        loc = %{
          entry_id: entry.id,
          marker_id: marker_key,
          target_type: group.kind,
          target_id: group.target_id,
          level_id: resolve_entry_level_id(group, entry, targets),
          label: label
        }

        Map.put(inner_acc, entry.id, loc)
      end)
    end)
  end

  # Private Projection Helpers

  defp project_single_group({marker_key, group}, active_level_id, geometry, focused_marker_id) do
    case project_group_coordinates(group, active_level_id, geometry) do
      {:ok, x, y} ->
        [
          %{
            id: marker_key,
            kind: group.kind,
            target_id: group.target_id,
            entry_ids: group.entry_ids,
            focus_entry_id: group.focus_entry_id,
            open_count: group.open_count,
            total_count: group.total_count,
            state: if(group.kind == :pin, do: group.state, else: :open),
            x: x,
            y: y,
            accessible_name: group.accessible_name,
            focused?: marker_key == focused_marker_id
          }
        ]

      :error ->
        []
    end
  end

  defp project_group_coordinates(%{kind: :pin} = group, active_level_id, geometry) do
    active_stop_level_id = normalize_id(geometry[:active_stop_level_id])

    if group.stop_level_id == active_level_id or
         (not is_nil(active_stop_level_id) and group.stop_level_id == active_stop_level_id) do
      {:ok, group.x, group.y}
    else
      :error
    end
  end

  defp project_group_coordinates(%{kind: :node} = group, active_level_id, geometry) do
    if group.open_count > 0 do
      project_node_coordinates(group.target_id, active_level_id, geometry[:child_stops])
    else
      :error
    end
  end

  defp project_group_coordinates(%{kind: :pathway} = group, active_level_id, geometry) do
    if group.open_count > 0 do
      project_pathway_coordinates(group.target_id, active_level_id, geometry)
    else
      :error
    end
  end

  defp project_node_coordinates(target_id, active_level_id, child_stops) do
    with stop when not is_nil(stop) <- find_stop(child_stops, target_id),
         {:ok, level_id} <- extract_stop_level_id(stop),
         true <- level_id == active_level_id,
         {:ok, {sx, sy}} <- extract_stop_coordinate(stop) do
      {:ok, sx + 0.75, sy - 0.75}
    else
      _ -> :error
    end
  end

  defp project_pathway_coordinates(target_id, active_level_id, geometry) do
    with pathway when not is_nil(pathway) <- find_pathway(geometry[:pathways], target_id),
         {:ok, from_stop, to_stop} <- resolve_pathway_stops_from_geometry(geometry, pathway),
         {:ok, level_id} <- match_same_level(from_stop, to_stop),
         true <- level_id == active_level_id,
         {:ok, c1, c2} <- extract_valid_pathway_coords(from_stop, to_stop),
         true <- c1 != c2,
         {x, y} <- pathway_offset_point(c1, c2) do
      {:ok, x, y}
    else
      _ -> :error
    end
  end

  # Classification Helpers

  defp station_entry?(entry) do
    target_type = Map.get(entry, :target_type) || Map.get(entry, "target_type")
    target_type in ["station", :station]
  end

  defp classify_entry(entry, targets) do
    target_type = Map.get(entry, :target_type) || Map.get(entry, "target_type")

    case target_type do
      type when type in ["pin", :pin] -> classify_pin(entry, targets)
      type when type in ["node", :node] -> classify_node(entry, targets)
      type when type in ["pathway", :pathway] -> classify_pathway(entry, targets)
      _ -> :error
    end
  end

  defp classify_pin(entry, targets) do
    stop_level_id = Map.get(entry, :stop_level_id) || Map.get(entry, "stop_level_id")
    dx = Map.get(entry, :diagram_x) || Map.get(entry, "diagram_x")
    dy = Map.get(entry, :diagram_y) || Map.get(entry, "diagram_y")

    resolved_level_id =
      case get_stop_level(targets, stop_level_id) do
        {:ok, sl} -> Map.get(sl, :level_id) || Map.get(sl, "level_id") || stop_level_id
        :error -> stop_level_id
      end

    with false <- is_nil(stop_level_id),
         {:ok, x} <- validate_coordinate(dx),
         {:ok, y} <- validate_coordinate(dy) do
      {:ok, "journal-marker-pin-#{entry.id}",
       %{
         kind: :pin,
         target_id: nil,
         stop_level_id: normalize_id(resolved_level_id),
         x: x,
         y: y,
         entries: []
       }}
    else
      _ -> :error
    end
  end

  defp classify_node(entry, targets) do
    target_id = Map.get(entry, :target_id) || Map.get(entry, "target_id")

    with false <- is_nil(target_id),
         {:ok, stop} <- get_node_stop(targets, target_id),
         {:ok, _level_id} <- extract_stop_level_id(stop),
         {:ok, _coords} <- extract_stop_coordinate(stop) do
      {:ok, "journal-marker-node-#{target_id}", %{kind: :node, target_id: target_id, entries: []}}
    else
      _ -> :error
    end
  end

  defp classify_pathway(entry, targets) do
    target_id = Map.get(entry, :target_id) || Map.get(entry, "target_id")

    with false <- is_nil(target_id),
         {:ok, pathway} <- get_pathway(targets, target_id),
         {:ok, from_stop, to_stop} <- resolve_pathway_stops(targets, pathway),
         {:ok, level_id} <- match_same_level(from_stop, to_stop),
         {:ok, c1, c2} <- extract_valid_pathway_coords(from_stop, to_stop),
         true <- c1 != c2 do
      {:ok, "journal-marker-pathway-#{target_id}",
       %{kind: :pathway, target_id: target_id, stop_level_id: level_id, entries: []}}
    else
      _ -> :error
    end
  end

  # Stop and Pathway Lookup Helpers

  defp find_stop(child_stops, target_id) when is_list(child_stops) do
    norm_target = normalize_id(target_id)
    Enum.find(child_stops, &match_stop_id?(&1, norm_target))
  end

  defp find_stop(_, _), do: nil

  defp match_stop_id?(stop, norm_target) do
    id = normalize_id(Map.get(stop, :id) || Map.get(stop, "id"))
    stop_id = normalize_id(Map.get(stop, :stop_id) || Map.get(stop, "stop_id"))
    id == norm_target or stop_id == norm_target
  end

  defp find_pathway(pathways, target_id) when is_list(pathways) do
    norm_target = normalize_id(target_id)
    Enum.find(pathways, &match_pathway_id?(&1, norm_target))
  end

  defp find_pathway(_, _), do: nil

  defp match_pathway_id?(pw, norm_target) do
    id = normalize_id(Map.get(pw, :id) || Map.get(pw, "id"))
    pw_id = normalize_id(Map.get(pw, :pathway_id) || Map.get(pw, "pathway_id"))
    id == norm_target or pw_id == norm_target
  end

  defp get_node_stop(targets, target_id) do
    nodes = Map.get(targets, :nodes) || Map.get(targets, "nodes") || %{}
    norm_id = normalize_id(target_id)

    case Map.get(nodes, target_id) || Map.get(nodes, norm_id) do
      nil -> search_node_map(nodes, norm_id)
      stop -> {:ok, stop}
    end
  end

  defp search_node_map(nodes, norm_id) do
    case Enum.find(nodes, fn {_k, v} -> match_stop_id?(v, norm_id) end) do
      {_k, stop} -> {:ok, stop}
      nil -> :error
    end
  end

  defp get_pathway(targets, target_id) do
    pathways = Map.get(targets, :pathways) || Map.get(targets, "pathways") || %{}
    norm_id = normalize_id(target_id)

    case Map.get(pathways, target_id) || Map.get(pathways, norm_id) do
      nil -> search_pathway_map(pathways, norm_id)
      pw -> {:ok, pw}
    end
  end

  defp search_pathway_map(pathways, norm_id) do
    case Enum.find(pathways, fn {_k, v} -> match_pathway_id?(v, norm_id) end) do
      {_k, pw} -> {:ok, pw}
      nil -> :error
    end
  end

  defp resolve_pathway_stops(targets, pathway) do
    from_id = Map.get(pathway, :from_stop_id) || Map.get(pathway, "from_stop_id")
    to_id = Map.get(pathway, :to_stop_id) || Map.get(pathway, "to_stop_id")

    from_stop = fetch_pathway_endpoint(pathway, :from_stop, targets, from_id)
    to_stop = fetch_pathway_endpoint(pathway, :to_stop, targets, to_id)

    if from_stop && to_stop, do: {:ok, from_stop, to_stop}, else: :error
  end

  defp fetch_pathway_endpoint(pathway, key, targets, stop_id) do
    atom_key = key
    string_key = Atom.to_string(key)

    Map.get(pathway, atom_key) || Map.get(pathway, string_key) ||
      case get_node_stop(targets, stop_id) do
        {:ok, s} -> s
        :error -> nil
      end
  end

  defp resolve_pathway_stops_from_geometry(geometry, pathway) do
    from_id = Map.get(pathway, :from_stop_id) || Map.get(pathway, "from_stop_id")
    to_id = Map.get(pathway, :to_stop_id) || Map.get(pathway, "to_stop_id")

    from_stop =
      find_stop(geometry[:child_stops], from_id) ||
        Map.get(pathway, :from_stop) || Map.get(pathway, "from_stop")

    to_stop =
      find_stop(geometry[:child_stops], to_id) ||
        Map.get(pathway, :to_stop) || Map.get(pathway, "to_stop")

    if from_stop && to_stop, do: {:ok, from_stop, to_stop}, else: :error
  end

  # Geometry & Coordinate Parsing Helpers

  defp extract_stop_level_id(stop) do
    level_id = Map.get(stop, :level_id) || Map.get(stop, "level_id")
    norm = normalize_id(level_id)
    if norm, do: {:ok, norm}, else: :error
  end

  defp match_same_level(from_stop, to_stop) do
    with {:ok, l1} <- extract_stop_level_id(from_stop),
         {:ok, l2} <- extract_stop_level_id(to_stop),
         true <- l1 == l2 do
      {:ok, l1}
    else
      _ -> :error
    end
  end

  defp extract_stop_coordinate(stop) do
    coord = Map.get(stop, :diagram_coordinate) || Map.get(stop, "diagram_coordinate")

    case coord do
      %{x: x, y: y} -> parse_xy(x, y)
      %{"x" => x, "y" => y} -> parse_xy(x, y)
      _ -> :error
    end
  end

  defp parse_xy(x, y) do
    with {:ok, fx} <- validate_coordinate(x),
         {:ok, fy} <- validate_coordinate(y) do
      {:ok, {fx, fy}}
    else
      _ -> :error
    end
  end

  defp extract_valid_pathway_coords(from_stop, to_stop) do
    with {:ok, c1} <- extract_stop_coordinate(from_stop),
         {:ok, c2} <- extract_stop_coordinate(to_stop) do
      {:ok, c1, c2}
    else
      _ -> :error
    end
  end

  defp pathway_offset_point({x1, y1}, {x2, y2}) do
    mx = (x1 + x2) / 2.0
    my = (y1 + y2) / 2.0

    dx = x2 - x1
    dy = y2 - y1
    length = :math.sqrt(dx * dx + dy * dy)

    if length == 0.0 do
      {mx, my}
    else
      {ox, oy} = calculate_offset_vector(dx, dy, length)
      {mx + ox, my + oy}
    end
  end

  defp calculate_offset_vector(dx, dy, length) do
    d1_x = -dy / length * 0.75
    d1_y = dx / length * 0.75

    d2_x = dy / length * 0.75
    d2_y = -dx / length * 0.75

    cond do
      d1_y < 0.0 and d2_y >= 0.0 -> {d1_x, d1_y}
      d2_y < 0.0 and d1_y >= 0.0 -> {d2_x, d2_y}
      d1_x > 0.0 -> {d1_x, d1_y}
      true -> {d2_x, d2_y}
    end
  end

  defp validate_coordinate(val) do
    case to_float(val) do
      {:ok, f} ->
        if not infinite?(f) and f >= 0.0 and f <= 100.0 do
          {:ok, f}
        else
          :error
        end

      :error ->
        :error
    end
  end

  defp to_float(val) when is_float(val), do: {:ok, val}
  defp to_float(val) when is_integer(val), do: {:ok, val * 1.0}

  defp to_float(%Decimal{} = dec) do
    {:ok, Decimal.to_float(dec)}
  rescue
    _ -> :error
  end

  defp to_float(_), do: :error

  defp infinite?(val), do: val in [:infinity, :"-infinity"]

  defp normalize_id(nil), do: nil
  defp normalize_id(id) when is_binary(id), do: id
  defp normalize_id(id), do: to_string(id)

  # Sorting and Label Resolution Helpers

  defp sort_entries(entries) do
    Enum.sort(entries, &entry_order_less?/2)
  end

  defp entry_order_less?(a, b) do
    a_closed? = not is_nil(a.closed_at)
    b_closed? = not is_nil(b.closed_at)

    if a_closed? != b_closed? do
      not a_closed?
    else
      compare_timestamps_and_id(a, b)
    end
  end

  defp compare_timestamps_and_id(a, b) do
    case compare_date_times(a.captured_at, b.captured_at) do
      :gt -> true
      :lt -> false
      :eq -> compare_inserted_at_and_id(a, b)
    end
  end

  defp compare_inserted_at_and_id(a, b) do
    case compare_date_times(a.inserted_at, b.inserted_at) do
      :gt -> true
      :lt -> false
      :eq -> to_string(a.id) >= to_string(b.id)
    end
  end

  defp compare_date_times(%DateTime{} = a, %DateTime{} = b), do: DateTime.compare(a, b)
  defp compare_date_times(nil, %DateTime{}), do: :lt
  defp compare_date_times(%DateTime{}, nil), do: :gt
  defp compare_date_times(nil, nil), do: :eq
  defp compare_date_times(_, _), do: :eq

  defp extract_note_excerpt(body) when is_binary(body) do
    body
    |> String.split(["\r\n", "\n", "\r"])
    |> Enum.map(&String.trim/1)
    |> Enum.find(fn line -> line != "" end)
    |> case do
      nil -> "No note provided"
      line -> line
    end
  end

  defp extract_note_excerpt(_), do: "No note provided"

  defp resolve_target_label(targets, kind, target_id) do
    presentations = Map.get(targets, :presentations) || Map.get(targets, "presentations") || %{}
    pres = Map.get(presentations, target_id) || Map.get(presentations, normalize_id(target_id))

    case extract_label_from_presentation(pres) do
      {:ok, label} -> label
      :error -> fallback_target_label(targets, kind, target_id)
    end
  end

  defp extract_label_from_presentation(pres) when is_map(pres) do
    label = Map.get(pres, :label) || Map.get(pres, "label")
    if is_binary(label) and label != "", do: {:ok, label}, else: :error
  end

  defp extract_label_from_presentation(_), do: :error

  defp fallback_target_label(targets, :node, target_id) do
    case get_node_stop(targets, target_id) do
      {:ok, stop} ->
        Map.get(stop, :stop_name) || Map.get(stop, "stop_name") || "Node #{target_id}"

      :error ->
        "Node #{target_id}"
    end
  end

  defp fallback_target_label(targets, :pathway, target_id) do
    case get_pathway(targets, target_id) do
      {:ok, pw} ->
        Map.get(pw, :signposted_as) || Map.get(pw, "signposted_as") || "Pathway #{target_id}"

      :error ->
        "Pathway #{target_id}"
    end
  end

  defp fallback_target_label(_targets, _kind, _target_id), do: "Pin"

  defp resolve_entry_level_id(group, entry, targets) do
    case group.kind do
      :pin ->
        raw_id = group.stop_level_id || entry.stop_level_id

        case get_stop_level(targets, raw_id) do
          {:ok, sl} -> normalize_id(Map.get(sl, :level_id) || Map.get(sl, "level_id") || raw_id)
          :error -> normalize_id(raw_id)
        end

      :node ->
        resolve_node_entry_level_id(group.target_id, targets)

      :pathway ->
        resolve_pathway_entry_level_id(group.target_id, targets)
    end
  end

  defp get_stop_level(targets, target_id) when not is_nil(target_id) do
    stop_levels = Map.get(targets, :stop_levels) || Map.get(targets, "stop_levels") || %{}
    norm_id = normalize_id(target_id)

    case Map.get(stop_levels, target_id) || Map.get(stop_levels, norm_id) do
      nil -> search_stop_level_map(stop_levels, norm_id)
      sl -> {:ok, sl}
    end
  end

  defp get_stop_level(_targets, _target_id), do: :error

  defp search_stop_level_map(stop_levels, norm_id) do
    case Enum.find(stop_levels, fn {_k, v} ->
           id = normalize_id(Map.get(v, :id) || Map.get(v, "id"))
           id == norm_id
         end) do
      {_k, sl} -> {:ok, sl}
      nil -> :error
    end
  end

  defp resolve_node_entry_level_id(target_id, targets) do
    case get_node_stop(targets, target_id) do
      {:ok, stop} -> normalize_id(Map.get(stop, :level_id) || Map.get(stop, "level_id"))
      :error -> nil
    end
  end

  defp resolve_pathway_entry_level_id(target_id, targets) do
    with {:ok, pw} <- get_pathway(targets, target_id),
         {:ok, from_stop, _to_stop} <- resolve_pathway_stops(targets, pw) do
      normalize_id(Map.get(from_stop, :level_id) || Map.get(from_stop, "level_id"))
    else
      _ -> nil
    end
  end
end
