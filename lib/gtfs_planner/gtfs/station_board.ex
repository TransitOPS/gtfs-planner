defmodule GtfsPlanner.Gtfs.StationBoard do
  @moduledoc """
  Builds the station board's per-station summaries for one GTFS version.

  `base/2` reads the version's stations, child stops, pathways, levels and latest
  changes in bulk, so the board pays a fixed number of queries instead of one per
  station. A station's child stops follow the station report's rule: its direct
  children plus `location_type` 4 boarding areas whose parent is a direct child. A
  pathway belongs to a station when either endpoint is one of its child stops.

  `statuses/3` adds each station's report issue count and latest reachability
  result to those summaries, counting with the station report's own `Outcome`
  rule so a board row cannot disagree with the report it links to.

  `classify/2` turns those summaries into a stage, and `query/3` filters,
  searches, orders, pages and counts the board in memory for the current params.

  Every read is scoped by organization and version; the caller passes both ids
  from the mount context and no request input selects them.
  """

  import Ecto.Query

  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Level
  alias GtfsPlanner.Gtfs.Pathway
  alias GtfsPlanner.Gtfs.StationReport2.Outcome
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopLevel
  alias GtfsPlanner.Reachability
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

  @type reachability :: %{
          run_id: Ecto.UUID.t(),
          outcome: :passed | :warning | :failed | :not_applicable,
          reachable: non_neg_integer(),
          pair_count: non_neg_integer(),
          completed_at: DateTime.t(),
          stale?: boolean()
        }

  @type status :: %{issues: non_neg_integer(), reachability: nil | reachability()}

  @type stage :: :not_started | :in_progress | :clean | :unknown

  @type params :: %{
          stage: :all | :not_started | :in_progress | :clean,
          q: String.t(),
          page: pos_integer()
        }

  @page_size 12
  @max_query_length 100

  @stage_params %{
    "all" => :all,
    "not_started" => :not_started,
    "in_progress" => :in_progress,
    "clean" => :clean
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

  @doc """
  Returns the report issue count and latest reachability result per station.

  The result is keyed by station `stop_id`. One bulk read loads the version's
  stations and child stops with their levels, and one loads the version's
  pathways; every station with at least one pathway is summarized with the
  station report's own items, and a station without pathways is not summarized.
  Reachability is the newest completed run per station, with `stale?` true when
  the station's latest change is newer than that run. Snapshots are discarded
  after counting.
  """
  @spec statuses(Ecto.UUID.t(), Ecto.UUID.t(), [base()]) :: %{String.t() => status()}
  def statuses(_organization_id, _gtfs_version_id, []), do: %{}

  def statuses(organization_id, gtfs_version_id, bases) do
    stop_rows = list_station_and_child_stops(organization_id, gtfs_version_id)
    child_rows = Enum.reject(stop_rows, &is_nil(&1.parent_station))

    children =
      children_by_station(
        station_entries(bases) ++
          Enum.map(child_rows, &{&1.stop_id, &1.parent_station, &1.location_type})
      )

    station_by_child = child_to_station(children)
    station_child_stops = child_stops_by_station(child_rows, station_by_child)

    station_pathways =
      pathways_by_station(list_pathway_rows(organization_id, gtfs_version_id), station_by_child)

    stations_by_stop_id =
      stop_rows
      |> Enum.filter(&(&1.location_type == 1))
      |> Map.new(&{&1.stop_id, &1})

    latest =
      Reachability.latest_by_station(
        organization_id,
        gtfs_version_id,
        Enum.map(bases, & &1.stop_id)
      )

    Map.new(bases, fn base ->
      issues = issue_count(base, stations_by_stop_id, station_child_stops, station_pathways)

      {base.stop_id, %{issues: issues, reachability: station_reachability(latest, base)}}
    end)
  end

  @doc """
  Returns the board stage of a station summary.

  A station without pathways is not started regardless of its status. A station
  with pathways and no status (statuses unavailable) is unknown. Otherwise the
  station is clean when it has no issues and its latest reachability run passed
  and is not stale; every other station with pathways is in progress.
  """
  @spec classify(base(), status() | nil) :: stage()
  def classify(%{pathway_count: 0}, _status), do: :not_started

  def classify(_base, nil), do: :unknown

  def classify(_base, %{issues: 0, reachability: %{outcome: :passed, stale?: false}}),
    do: :clean

  def classify(_base, _status), do: :in_progress

  @doc """
  Normalizes the board's URL params, never raising on unexpected values.

  An unknown stage falls back to `:all`, the search term is trimmed to at most
  #{@max_query_length} characters, and a page that is not a positive integer
  falls back to 1.
  """
  @spec parse_params(map()) :: params()
  def parse_params(params) do
    %{
      stage: parse_stage(Map.get(params, "stage")),
      q: parse_query(Map.get(params, "q")),
      page: parse_page(Map.get(params, "page"))
    }
  end

  @doc """
  Filters, searches, orders, pages and counts the board for one version.

  The stage counts are version totals: they describe every station, not only
  the rows matching the stage filter or `q`, and the status-dependent counts are
  `nil` when statuses are `:unavailable`. Rows are ordered by `last_edited_at`
  descending with never-edited stations last, then by name; the `:not_started`
  filter orders by name. A page holds #{@page_size} rows, and a page beyond the
  last one is clamped to the last page.
  """
  @spec query([base()], %{String.t() => status()} | :unavailable, params()) :: %{
          rows: [%{base: base(), status: status() | nil, stage: stage()}],
          page: pos_integer(),
          total_pages: pos_integer(),
          total: non_neg_integer(),
          counts: %{
            all: non_neg_integer(),
            not_started: non_neg_integer(),
            in_progress: non_neg_integer() | nil,
            clean: non_neg_integer() | nil
          }
        }
  def query(bases, statuses, params) do
    classified = Enum.map(bases, &classify_row(&1, statuses))

    rows =
      classified
      |> filter_stage(params.stage)
      |> filter_query(params.q)
      |> sort_rows(params.stage)

    total = length(rows)
    total_pages = max(div(total + @page_size - 1, @page_size), 1)
    page = params.page |> max(1) |> min(total_pages)

    %{
      rows: Enum.slice(rows, (page - 1) * @page_size, @page_size),
      page: page,
      total_pages: total_pages,
      total: total,
      counts: stage_counts(classified, statuses)
    }
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

  # A station without pathways is not started: the board shows 0 issues and the
  # report builders are never called for it.
  defp issue_count(%{pathway_count: 0}, _stations, _child_stops, _pathways), do: 0

  defp issue_count(base, stations, child_stops, pathways) do
    snapshot = %{
      station: Map.fetch!(stations, base.stop_id),
      child_stops: Map.get(child_stops, base.stop_id, []),
      pathways: Map.get(pathways, base.stop_id, [])
    }

    Outcome.counts(Outcome.report_items(snapshot)).failed
  end

  defp station_reachability(latest, base) do
    case Map.get(latest, base.stop_id) do
      nil -> nil
      result -> Map.put(result, :stale?, stale?(base.last_edited_at, result.completed_at))
    end
  end

  defp stale?(nil, _completed_at), do: false

  defp stale?(last_edited_at, completed_at),
    do: DateTime.compare(last_edited_at, completed_at) == :gt

  defp child_stops_by_station(child_rows, station_by_child) do
    child_rows
    |> Enum.flat_map(fn stop ->
      case Map.get(station_by_child, stop.stop_id) do
        nil -> []
        station_stop_id -> [{station_stop_id, stop}]
      end
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp pathways_by_station(pathways, station_by_child) do
    pathways
    |> Enum.flat_map(fn pathway ->
      [pathway.from_stop_id, pathway.to_stop_id]
      |> Enum.map(&Map.get(station_by_child, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.map(&{&1, pathway})
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp list_station_and_child_stops(organization_id, gtfs_version_id) do
    from(s in Stop,
      left_join: l in Level,
      on:
        l.level_id == s.level_id and
          l.organization_id == ^organization_id and
          l.gtfs_version_id == ^gtfs_version_id,
      where:
        s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id and
          (not is_nil(s.parent_station) or s.location_type == 1),
      select: s,
      select_merge: %{level: l}
    )
    |> Repo.all()
  end

  defp list_pathway_rows(organization_id, gtfs_version_id) do
    from(p in Pathway,
      where: p.organization_id == ^organization_id and p.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.all()
  end

  defp classify_row(base, :unavailable),
    do: %{base: base, status: nil, stage: classify(base, nil)}

  defp classify_row(base, statuses) do
    status = Map.get(statuses, base.stop_id)
    %{base: base, status: status, stage: classify(base, status)}
  end

  defp filter_stage(rows, :all), do: rows
  defp filter_stage(rows, stage), do: Enum.filter(rows, &(&1.stage == stage))

  defp filter_query(rows, ""), do: rows

  defp filter_query(rows, q) do
    needle = String.downcase(q)
    Enum.filter(rows, &matches_query?(&1.base, needle))
  end

  defp matches_query?(base, needle) do
    String.contains?(String.downcase(base.stop_id), needle) or
      (is_binary(base.name) and String.contains?(String.downcase(base.name), needle))
  end

  defp sort_rows(rows, :not_started), do: Enum.sort_by(rows, &name_sort_key/1)
  defp sort_rows(rows, _stage), do: Enum.sort_by(rows, &edit_sort_key/1)

  defp name_sort_key(%{base: base}), do: {is_nil(base.name), base.name || "", base.stop_id}

  defp edit_sort_key(%{base: base}) do
    {
      is_nil(base.last_edited_at),
      negated_microseconds(base.last_edited_at),
      is_nil(base.name),
      base.name || "",
      base.stop_id
    }
  end

  defp negated_microseconds(nil), do: nil
  defp negated_microseconds(last_edited_at), do: -DateTime.to_unix(last_edited_at, :microsecond)

  defp stage_counts(classified, :unavailable) do
    %{
      all: length(classified),
      not_started: Enum.count(classified, &(&1.stage == :not_started)),
      in_progress: nil,
      clean: nil
    }
  end

  defp stage_counts(classified, _statuses) do
    %{
      all: length(classified),
      not_started: Enum.count(classified, &(&1.stage == :not_started)),
      in_progress: Enum.count(classified, &(&1.stage == :in_progress)),
      clean: Enum.count(classified, &(&1.stage == :clean))
    }
  end

  defp parse_stage(stage) when is_binary(stage), do: Map.get(@stage_params, stage, :all)
  defp parse_stage(_stage), do: :all

  defp parse_query(q) when is_binary(q) do
    q |> String.trim() |> String.slice(0, @max_query_length)
  end

  defp parse_query(_q), do: ""

  defp parse_page(page) when is_integer(page) and page > 0, do: page

  defp parse_page(page) when is_binary(page) do
    case Integer.parse(page) do
      {number, ""} when number > 0 -> number
      _invalid -> 1
    end
  end

  defp parse_page(_page), do: 1
end
