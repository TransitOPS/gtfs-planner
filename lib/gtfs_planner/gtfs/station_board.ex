defmodule GtfsPlanner.Gtfs.StationBoard do
  @moduledoc """
  Builds the station board's per-station summaries for one GTFS version.

  `base/2` reads the version's stations, child stops, pathways, levels and latest
  changes in bulk, so the board pays a fixed number of queries instead of one per
  station. A station's child stops follow the station report's rule: its direct
  children plus `location_type` 4 boarding areas whose parent is a direct child. A
  pathway belongs to a station when either endpoint is one of its child stops.

  Every read is scoped by organization and version; the caller passes both ids
  from the mount context and no request input selects them.
  """

  import Ecto.Query

  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Level
  alias GtfsPlanner.Gtfs.Pathway
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopLevel
  alias GtfsPlanner.Repo

  @type base :: %{
          id: Ecto.UUID.t(),
          stop_id: String.t(),
          name: String.t() | nil,
          level_count: non_neg_integer(),
          floorplan_count: non_neg_integer(),
          pathway_count: non_neg_integer(),
          last_edited_at: DateTime.t() | nil,
          last_edited_by: String.t() | nil
        }

  @doc """
  Returns one summary per station of the version, sorted by `stop_id`.
  """
  @spec base(Ecto.UUID.t(), Ecto.UUID.t()) :: [base()]
  def base(organization_id, gtfs_version_id) do
    case list_stations(organization_id, gtfs_version_id) do
      [] -> []
      stations -> build(stations, organization_id, gtfs_version_id)
    end
  end

  @doc """
  Groups the version's stops under their station by the station report's child rule.

  `entries` holds `{stop_id, parent_station, location_type}` for the version's
  stations (`location_type` 1, which keys the result) and stops. Each station's set
  holds its direct children plus its `location_type` 4 boarding areas whose parent
  is a direct child; a station with no children gets an empty set.
  """
  @spec children_by_station([{String.t(), String.t() | nil, integer() | nil}]) ::
          %{String.t() => MapSet.t(String.t())}
  def children_by_station(entries) do
    children_by_parent =
      Enum.group_by(
        entries,
        fn {_stop_id, parent_station, _location_type} -> parent_station end,
        fn {stop_id, _parent_station, _location_type} -> stop_id end
      )

    boarding_areas_by_parent =
      entries
      |> Enum.filter(fn {_stop_id, _parent_station, location_type} -> location_type == 4 end)
      |> Enum.group_by(
        fn {_stop_id, parent_station, _location_type} -> parent_station end,
        fn {stop_id, _parent_station, _location_type} -> stop_id end
      )

    entries
    |> Enum.filter(fn {_stop_id, _parent_station, location_type} -> location_type == 1 end)
    |> Map.new(fn {station_stop_id, _parent_station, _location_type} ->
      direct_children = Map.get(children_by_parent, station_stop_id, [])

      boarding_areas =
        Enum.flat_map(direct_children, &Map.get(boarding_areas_by_parent, &1, []))

      {station_stop_id, MapSet.new(direct_children ++ boarding_areas)}
    end)
  end

  defp build(stations, organization_id, gtfs_version_id) do
    child_rows = list_child_stop_rows(organization_id, gtfs_version_id)

    children =
      children_by_station(station_entries(stations) ++ child_entries(child_rows))

    pathway_counts = count_pathways(organization_id, gtfs_version_id, children)
    stop_level_rows = list_stop_level_rows(organization_id, gtfs_version_id)

    facts = %{
      child_levels: child_level_sets(child_rows, children),
      children: children,
      floorplan_counts: floorplan_counts(stop_level_rows),
      last_edits: last_edits_by_station(organization_id, gtfs_version_id),
      pathway_counts: pathway_counts,
      stop_level_levels: level_ids_by_station(stop_level_rows)
    }

    Enum.map(stations, &summarize(&1, facts))
  end

  defp summarize(station, facts) do
    child_levels = Map.get(facts.child_levels, station.stop_id, MapSet.new())
    stop_level_levels = Map.get(facts.stop_level_levels, station.id, MapSet.new())
    {last_edited_at, last_edited_by} = Map.get(facts.last_edits, station.stop_id, {nil, nil})

    %{
      id: station.id,
      stop_id: station.stop_id,
      name: station.name,
      level_count: MapSet.size(MapSet.union(child_levels, stop_level_levels)),
      floorplan_count: Map.get(facts.floorplan_counts, station.id, 0),
      pathway_count: Map.get(facts.pathway_counts, station.stop_id, 0),
      last_edited_at: last_edited_at,
      last_edited_by: last_edited_by
    }
  end

  defp list_stations(organization_id, gtfs_version_id) do
    from(s in Stop,
      where:
        s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id and
          s.location_type == 1,
      order_by: [asc: s.stop_id],
      select: %{id: s.id, stop_id: s.stop_id, name: s.stop_name}
    )
    |> Repo.all()
  end

  defp list_child_stop_rows(organization_id, gtfs_version_id) do
    from(s in Stop,
      where:
        s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id and
          not is_nil(s.parent_station),
      select: {s.stop_id, s.parent_station, s.location_type, s.level_id}
    )
    |> Repo.all()
  end

  defp list_stop_level_rows(organization_id, gtfs_version_id) do
    from(sl in StopLevel,
      join: l in Level,
      on:
        l.id == sl.level_id and l.organization_id == ^organization_id and
          l.gtfs_version_id == ^gtfs_version_id,
      where: sl.organization_id == ^organization_id and sl.gtfs_version_id == ^gtfs_version_id,
      select: {sl.stop_id, l.level_id, sl.diagram_filename}
    )
    |> Repo.all()
  end

  defp last_edits_by_station(organization_id, gtfs_version_id) do
    from(c in ChangeLog,
      where: c.organization_id == ^organization_id and c.gtfs_version_id == ^gtfs_version_id,
      where: not is_nil(c.station_stop_id),
      distinct: [c.station_stop_id],
      order_by: [asc: c.station_stop_id, desc: c.inserted_at, desc: c.id],
      select: {c.station_stop_id, c.inserted_at, c.actor_email}
    )
    |> Repo.all()
    |> Map.new(fn {station_stop_id, inserted_at, actor_email} ->
      {station_stop_id, {inserted_at, actor_email}}
    end)
  end

  defp station_entries(stations), do: Enum.map(stations, &{&1.stop_id, nil, 1})

  defp child_entries(child_rows) do
    Enum.map(child_rows, fn {stop_id, parent_station, location_type, _level_id} ->
      {stop_id, parent_station, location_type}
    end)
  end

  defp child_to_station(children) do
    for {station_stop_id, child_stop_ids} <- children,
        child_stop_id <- child_stop_ids,
        into: %{},
        do: {child_stop_id, station_stop_id}
  end

  defp count_pathways(organization_id, gtfs_version_id, children) do
    station_by_child = child_to_station(children)

    from(p in Pathway,
      where: p.organization_id == ^organization_id and p.gtfs_version_id == ^gtfs_version_id,
      select: {p.from_stop_id, p.to_stop_id}
    )
    |> Repo.all()
    |> Enum.flat_map(fn {from_stop_id, to_stop_id} ->
      [from_stop_id, to_stop_id]
      |> Enum.map(&Map.get(station_by_child, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
    end)
    |> Enum.frequencies()
  end

  defp child_level_sets(child_rows, children) do
    station_by_child = child_to_station(children)

    child_rows
    |> Enum.flat_map(fn {stop_id, _parent_station, _location_type, level_id} ->
      case {Map.get(station_by_child, stop_id), level_id} do
        {station_stop_id, level_id}
        when is_binary(station_stop_id) and is_binary(level_id) ->
          [{station_stop_id, level_id}]

        _unassigned ->
          []
      end
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {station_stop_id, level_ids} -> {station_stop_id, MapSet.new(level_ids)} end)
  end

  defp level_ids_by_station(stop_level_rows) do
    stop_level_rows
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {station_id, level_ids} -> {station_id, MapSet.new(level_ids)} end)
  end

  defp floorplan_counts(stop_level_rows) do
    stop_level_rows
    |> Enum.filter(fn {_station_id, _level_id, diagram_filename} ->
      diagram_filename not in [nil, ""]
    end)
    |> Enum.frequencies_by(&elem(&1, 0))
  end
end
