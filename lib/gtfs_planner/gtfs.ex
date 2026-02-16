defmodule GtfsPlanner.Gtfs do
  @moduledoc """
  The Gtfs context.
  """

  import Ecto.Query, warn: false
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Gtfs.Agency
  alias GtfsPlanner.Gtfs.Area
  alias GtfsPlanner.Gtfs.Attribution
  alias GtfsPlanner.Gtfs.BookingRule
  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.FareAttribute
  alias GtfsPlanner.Gtfs.FareLegJoinRule
  alias GtfsPlanner.Gtfs.FareLegRule
  alias GtfsPlanner.Gtfs.FareMedia
  alias GtfsPlanner.Gtfs.FareProduct
  alias GtfsPlanner.Gtfs.FareRule
  alias GtfsPlanner.Gtfs.FareTransferRule
  alias GtfsPlanner.Gtfs.FeedInfo
  alias GtfsPlanner.Gtfs.Frequency
  alias GtfsPlanner.Gtfs.Level
  alias GtfsPlanner.Gtfs.Location
  alias GtfsPlanner.Gtfs.Network
  alias GtfsPlanner.Gtfs.Pathway
  alias GtfsPlanner.Gtfs.RiderCategory
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.RouteNetwork
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.Shape
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopArea
  alias GtfsPlanner.Gtfs.StopLevel
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.Timeframe
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Gtfs.Translation
  alias GtfsPlanner.Gtfs.Trip

  require Logger

  @doc """
  Returns the list of routes for an organization and GTFS version.

  Accepts optional filters, search, sort, and pagination via opts keyword list.

  ## Examples

      iex> list_routes(organization_id, gtfs_version_id)
      [%Route{}, ...]

      iex> list_routes(organization_id, gtfs_version_id, route_type: 3, search: "express")
      [%Route{}, ...]
  """
  def list_routes(organization_id, gtfs_version_id, opts \\ []) do
    from(r in Route,
      where: r.organization_id == ^organization_id and r.gtfs_version_id == ^gtfs_version_id
    )
    |> maybe_filter_type(opts[:route_type])
    |> maybe_filter_agency(opts[:agency_id])
    |> maybe_filter_active(opts[:active])
    |> maybe_search(opts[:search])
    |> apply_sort(opts[:sort_by], opts[:sort_dir])
    |> paginate(opts[:page], opts[:per_page])
    |> Repo.all()
  end

  @doc """
  Returns the count of routes for an organization and GTFS version.

  Accepts optional filters via opts keyword list.

  ## Examples

      iex> count_routes(organization_id, gtfs_version_id)
      42

      iex> count_routes(organization_id, gtfs_version_id, route_type: 3)
      15
  """
  def count_routes(organization_id, gtfs_version_id, opts \\ []) do
    from(r in Route,
      where: r.organization_id == ^organization_id and r.gtfs_version_id == ^gtfs_version_id
    )
    |> maybe_filter_type(opts[:route_type])
    |> maybe_filter_agency(opts[:agency_id])
    |> maybe_filter_active(opts[:active])
    |> maybe_search(opts[:search])
    |> Repo.aggregate(:count)
  end

  @doc """
  Gets a single route.

  Raises `Ecto.NoResultsError` if the Route does not exist.

  ## Examples

      iex> get_route!(id)
      %Route{}

      iex> get_route!(Ecto.UUID.generate())
      ** (Ecto.NoResultsError)
  """
  def get_route!(id), do: Repo.get!(Route, id)

  @doc """
  Gets a route by its route_id within an organization and GTFS version.

  Returns nil if the route does not exist.

  ## Examples

      iex> get_route_by_route_id(organization_id, gtfs_version_id, "R1")
      %Route{}

      iex> get_route_by_route_id(organization_id, gtfs_version_id, "nonexistent")
      nil
  """
  def get_route_by_route_id(organization_id, gtfs_version_id, route_id) do
    from(r in Route,
      where:
        r.organization_id == ^organization_id and r.gtfs_version_id == ^gtfs_version_id and
          r.route_id == ^route_id
    )
    |> Repo.one()
  end

  @doc """
  Creates a route.

  ## Examples

      iex> create_route(%{organization_id: org_id, gtfs_version_id: version_id, route_id: "R1", route_type: 3, route_short_name: "1"})
      {:ok, %Route{}}

      iex> create_route(%{route_id: nil})
      {:error, %Ecto.Changeset{}}
  """
  def create_route(attrs \\ %{}) do
    %Route{}
    |> Route.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Returns a list of distinct route types for an organization and GTFS version.

  ## Examples

      iex> list_distinct_route_types(organization_id, gtfs_version_id)
      [0, 1, 3]
  """
  def list_distinct_route_types(organization_id, gtfs_version_id) do
    from(r in Route,
      where: r.organization_id == ^organization_id and r.gtfs_version_id == ^gtfs_version_id,
      distinct: true,
      select: r.route_type,
      order_by: r.route_type
    )
    |> Repo.all()
  end

  @doc """
  Returns a list of distinct agency IDs for an organization and GTFS version.

  ## Examples

      iex> list_distinct_agencies(organization_id, gtfs_version_id)
      ["agency1", "agency2"]
  """
  def list_distinct_agencies(organization_id, gtfs_version_id) do
    from(r in Route,
      where:
        r.organization_id == ^organization_id and r.gtfs_version_id == ^gtfs_version_id and
          not is_nil(r.agency_id),
      distinct: true,
      select: r.agency_id,
      order_by: r.agency_id
    )
    |> Repo.all()
  end

  @doc """
  Returns the list of route patterns for a specific route.

  ## Examples

      iex> list_route_patterns_for_route(organization_id, gtfs_version_id, route_id)
      [%RoutePattern{}, ...]
  """
  def list_route_patterns_for_route(organization_id, gtfs_version_id, route_id) do
    from(rp in RoutePattern,
      where:
        rp.organization_id == ^organization_id and rp.gtfs_version_id == ^gtfs_version_id and
          rp.route_id == ^route_id,
      order_by: [asc: rp.direction_id, asc: rp.route_pattern_sort_order]
    )
    |> Repo.all()
  end

  @doc """
  Returns the count of levels for an organization and GTFS version.
  """
  def count_levels(organization_id, gtfs_version_id) do
    from(l in Level,
      where: l.organization_id == ^organization_id and l.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.aggregate(:count)
  end

  @doc """
  Returns the list of levels for an organization and GTFS version.

  ## Examples

      iex> list_levels(organization_id, gtfs_version_id)
      [%Level{}, ...]
  """
  def list_levels(organization_id, gtfs_version_id) do
    from(l in Level,
      where: l.organization_id == ^organization_id and l.gtfs_version_id == ^gtfs_version_id,
      order_by: [asc: l.level_index]
    )
    |> Repo.all()
  end

  @doc """
  Returns all levels for organization and GTFS version.
  """
  def list_all_levels(organization_id, gtfs_version_id) do
    from(l in Level,
      where: l.organization_id == ^organization_id and l.gtfs_version_id == ^gtfs_version_id,
      order_by: [asc: l.level_index]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single level.

  Returns nil if the Level does not exist.

  ## Examples

      iex> get_level(id)
      %Level{}

      iex> get_level(Ecto.UUID.generate())
      nil
  """
  def get_level(id), do: Repo.get(Level, id)

  @doc """
  Gets a single level.

  Raises `Ecto.NoResultsError` if the Level does not exist.

  ## Examples

      iex> get_level!(id)
      %Level{}

      iex> get_level!(Ecto.UUID.generate())
      ** (Ecto.NoResultsError)
  """
  def get_level!(id), do: Repo.get!(Level, id)

  @doc """
  Gets a level by its level_id within an organization and GTFS version.

  Returns nil if the level does not exist.

  ## Examples

      iex> get_level_by_level_id(organization_id, gtfs_version_id, "L1")
      %Level{}

      iex> get_level_by_level_id(organization_id, gtfs_version_id, "nonexistent")
      nil
  """
  def get_level_by_level_id(organization_id, gtfs_version_id, level_id) do
    from(l in Level,
      where:
        l.organization_id == ^organization_id and l.gtfs_version_id == ^gtfs_version_id and
          l.level_id == ^level_id
    )
    |> Repo.one()
  end

  @doc """
  Creates a level.

  ## Examples

      iex> create_level(%{organization_id: org_id, gtfs_version_id: version_id, level_id: "L1", level_index: 0.0})
      {:ok, %Level{}}

      iex> create_level(%{level_id: nil})
      {:error, %Ecto.Changeset{}}
  """
  def create_level(attrs \\ %{}) do
    %Level{}
    |> Level.changeset(attrs)
    |> Repo.insert()
    |> broadcast([:levels, :created])
  end

  @doc """
  Updates a level.

  ## Examples

      iex> update_level(level, %{level_name: "Ground Floor"})
      {:ok, %Level{}}

      iex> update_level(level, %{level_id: nil})
      {:error, %Ecto.Changeset{}}
  """
  def update_level(%Level{} = level, attrs) do
    level
    |> Level.changeset(attrs)
    |> Repo.update()
    |> broadcast([:levels, :updated])
  end

  @doc """
  Deletes a stop_level association.
  """
  def delete_stop_level(%StopLevel{} = stop_level) do
    Repo.delete(stop_level)
    |> broadcast([:stop_levels, :deleted])
  end

  @doc """
  Updates a stop_level's diagram filename.
  """
  def update_stop_level_diagram(%StopLevel{} = stop_level, filename) do
    stop_level
    |> StopLevel.changeset(%{diagram_filename: filename})
    |> Repo.update()
    |> broadcast([:stop_levels, :updated])
  end

  @doc """
  Deletes a level.

  ## Examples

      iex> delete_level(level)
      {:ok, %Level{}}

      iex> delete_level(level)
      {:error, %Ecto.Changeset{}}
  """
  def delete_level(%Level{} = level) do
    Repo.delete(level)
    |> broadcast([:levels, :deleted])
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking level changes.

  ## Examples

      iex> change_level(level)
      %Ecto.Changeset{data: %Level{}}
  """
  def change_level(%Level{} = level, attrs \\ %{}) do
    Level.changeset(level, attrs)
  end

  @doc """
  Returns the count of stops for an organization and GTFS version.
  """
  def count_stops(organization_id, gtfs_version_id) do
    from(s in Stop,
      where: s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.aggregate(:count)
  end

  @doc """
  Returns the list of stops for an organization and GTFS version.
  """
  def list_stops(organization_id, gtfs_version_id) do
    from(s in Stop,
      where: s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id,
      order_by: [asc: s.stop_name]
    )
    |> Repo.all()
  end

  @doc """
  Returns a map of stop_id to list of routes serving that stop.
  """
  def get_routes_for_stops(organization_id, gtfs_version_id, stop_ids) do
    query =
      from(st in StopTime,
        join: t in Trip,
        on:
          st.trip_id == t.trip_id and st.organization_id == t.organization_id and
            st.gtfs_version_id == t.gtfs_version_id,
        join: r in Route,
        on:
          t.route_id == r.route_id and t.organization_id == r.organization_id and
            t.gtfs_version_id == r.gtfs_version_id,
        where:
          st.organization_id == ^organization_id and st.gtfs_version_id == ^gtfs_version_id and
            st.stop_id in ^stop_ids,
        distinct: [st.stop_id, r.route_id],
        order_by: [asc: r.route_short_name],
        select:
          {st.stop_id,
           %{
             route_id: r.route_id,
             route_short_name: r.route_short_name,
             route_color: r.route_color,
             route_text_color: r.route_text_color
           }}
      )

    Repo.all(query)
    |> Enum.group_by(fn {stop_id, _} -> stop_id end, fn {_, route} -> route end)
  end

  @doc """
  Returns a list of routes that serve at least one station (stop with no parent).
  """
  def list_routes_serving_stations(organization_id, gtfs_version_id) do
    from(r in Route,
      where: r.organization_id == ^organization_id and r.gtfs_version_id == ^gtfs_version_id,
      where: fragment("EXISTS (
        SELECT 1 FROM stop_times st
        JOIN trips t ON st.trip_id = t.trip_id AND st.organization_id = t.organization_id AND st.gtfs_version_id = t.gtfs_version_id
        JOIN stops s ON st.stop_id = s.stop_id AND st.organization_id = s.organization_id AND st.gtfs_version_id = s.gtfs_version_id
        WHERE t.route_id = ? AND t.organization_id = ? AND t.gtfs_version_id = ?
        AND s.parent_station IS NULL
      )", r.route_id, r.organization_id, r.gtfs_version_id),
      order_by: [asc: r.route_short_name, asc: r.route_id],
      select: %{
        route_id: r.route_id,
        route_short_name: r.route_short_name,
        route_color: r.route_color
      }
    )
    |> Repo.all()
  end

  @doc """
  Returns the list of stations (stops with no parent) for an organization and GTFS version.

  Accepts optional filters, search, sort, and pagination via opts keyword list.

  ## Examples

      iex> list_stations(organization_id, gtfs_version_id)
      [%Stop{}, ...]
  """
  def list_stations(organization_id, gtfs_version_id, opts \\ []) do
    from(s in Stop,
      where:
        s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id and
          is_nil(s.parent_station)
    )
    |> maybe_filter_route(opts[:route_id], organization_id, gtfs_version_id)
    |> maybe_filter_direction(opts[:direction_id], organization_id, gtfs_version_id)
    |> maybe_filter_wheelchair(opts[:wheelchair_boarding])
    |> maybe_search_stops(opts[:search])
    |> apply_stop_sort(opts[:sort_by], opts[:sort_dir])
    |> paginate(opts[:page], opts[:per_page])
    |> Repo.all()
  end

  @doc """
  Returns the count of stations (stops with no parent) for an organization and GTFS version.

  Accepts optional filters via opts keyword list.

  ## Examples

      iex> count_stations(organization_id, gtfs_version_id)
      42
  """
  def count_stations(organization_id, gtfs_version_id, opts \\ []) do
    from(s in Stop,
      where:
        s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id and
          is_nil(s.parent_station)
    )
    |> maybe_filter_route(opts[:route_id], organization_id, gtfs_version_id)
    |> maybe_filter_direction(opts[:direction_id], organization_id, gtfs_version_id)
    |> maybe_filter_wheelchair(opts[:wheelchair_boarding])
    |> maybe_search_stops(opts[:search])
    |> Repo.aggregate(:count)
  end

  @doc """
  Gets a single stop.

  Returns nil if the Stop does not exist.

  ## Examples

      iex> get_stop(id)
      %Stop{}

      iex> get_stop(Ecto.UUID.generate())
      nil
  """
  def get_stop(id), do: Repo.get(Stop, id)

  @doc """
  Gets a single stop.

  Raises `Ecto.NoResultsError` if the Stop does not exist.

  ## Examples

      iex> get_stop!(id)
      %Stop{}

      iex> get_stop!(Ecto.UUID.generate())
      ** (Ecto.NoResultsError)
  """
  def get_stop!(id), do: Repo.get!(Stop, id)

  @doc """
  Gets a stop by its stop_id within an organization and GTFS version.

  Returns nil if the stop does not exist.

  ## Examples

      iex> get_stop_by_stop_id(organization_id, gtfs_version_id, "stop_123")
      %Stop{}

      iex> get_stop_by_stop_id(organization_id, gtfs_version_id, "nonexistent")
      nil
  """
  def get_stop_by_stop_id(organization_id, gtfs_version_id, stop_id) do
    from(s in Stop,
      where:
        s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id and
          s.stop_id == ^stop_id
    )
    |> Repo.one()
  end

  @doc """
  Returns a unique stop_id within an organization and GTFS version.

  Uses the provided base stop_id if available, otherwise appends `_2`, `_3`, etc.
  """
  def unique_stop_id(organization_id, gtfs_version_id, base_stop_id, exclude_stop_id \\ nil) do
    escaped_base_stop_id = escape_like_pattern(base_stop_id)

    query =
      from(s in Stop,
        where:
          s.organization_id == ^organization_id and
            s.gtfs_version_id == ^gtfs_version_id and
            fragment(
              "? LIKE ? ESCAPE ?",
              s.stop_id,
              ^"#{escaped_base_stop_id}%",
              ^"\\"
            ),
        select: s.stop_id
      )

    query =
      if is_nil(exclude_stop_id) do
        query
      else
        where(query, [s], s.stop_id != ^exclude_stop_id)
      end

    existing_ids =
      query
      |> Repo.all()
      |> MapSet.new()

    if MapSet.member?(existing_ids, base_stop_id) do
      suffix =
        Stream.iterate(2, &(&1 + 1))
        |> Enum.find(fn n ->
          candidate = "#{base_stop_id}_#{n}"
          not MapSet.member?(existing_ids, candidate)
        end)

      case suffix do
        nil ->
          raise "Unable to generate unique stop_id for #{inspect(base_stop_id)}"

        n ->
          "#{base_stop_id}_#{n}"
      end
    else
      base_stop_id
    end
  end

  defp escape_like_pattern(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  @doc """
  Creates a stop.

  ## Examples

      iex> create_stop(%{organization_id: org_id, gtfs_version_id: version_id, stop_id: "stop_123", stop_name: "Central Station"})
      {:ok, %Stop{}}

      iex> create_stop(%{stop_id: nil})
      {:error, %Ecto.Changeset{}}
  """
  def create_stop(attrs \\ %{}) do
    %Stop{}
    |> Stop.changeset(attrs)
    |> Repo.insert()
    |> broadcast([:stops, :created])
  end

  @doc """
  Updates a stop.

  ## Examples

      iex> update_stop(stop, %{stop_name: "Updated Station Name"})
      {:ok, %Stop{}}

      iex> update_stop(stop, %{stop_id: nil})
      {:error, %Ecto.Changeset{}}
  """
  def update_stop(%Stop{} = stop, attrs) do
    stop
    |> Stop.changeset(attrs)
    |> Repo.update()
    |> broadcast([:stops, :updated])
  end

  @doc """
  Deletes a stop.

  ## Examples

      iex> delete_stop(stop)
      {:ok, %Stop{}}

      iex> delete_stop(stop)
      {:error, %Ecto.Changeset{}}
  """
  def delete_stop(%Stop{} = stop) do
    Repo.delete(stop)
    |> broadcast([:stops, :deleted])
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking stop changes.

  ## Examples

      iex> change_stop(stop)
      %Ecto.Changeset{data: %Stop{}}
  """
  def change_stop(%Stop{} = stop, attrs \\ %{}) do
    Stop.changeset(stop, attrs)
  end

  @doc """
  Returns child stops for a parent station, preloading level association.

  ## Examples

      iex> list_child_stops_for_parent(org_id, version_id, parent_id)
      [%Stop{level: %Level{}}, ...]
  """
  def list_child_stops_for_parent(organization_id, gtfs_version_id, parent_station_id) do
    parent_station = Repo.get!(Stop, parent_station_id)

    from(s in Stop,
      left_join: l in Level,
      on:
        l.level_id == s.level_id and
          l.organization_id == ^organization_id and
          l.gtfs_version_id == ^gtfs_version_id,
      where:
        s.organization_id == ^organization_id and
          s.gtfs_version_id == ^gtfs_version_id and
          s.parent_station == ^parent_station.stop_id,
      order_by: [asc: s.stop_name],
      select: s,
      select_merge: %{level: l}
    )
    |> Repo.all()
  end

  @doc """
  Returns the list of levels for a specific station with stop counts.
  Uses a hybrid approach: combines levels from child stops with levels from stop_levels table.

  ## Examples

      iex> list_levels_for_station(organization_id, gtfs_version_id, parent_station_id)
      [%{level: %Level{}, stop_count: 5}, ...]
  """
  def list_levels_for_station(organization_id, gtfs_version_id, parent_station_id) do
    parent_station = Repo.get!(Stop, parent_station_id)

    # Query 1: Levels from child stops that have a level_id set
    levels_from_stops =
      from(s in Stop,
        join: l in Level,
        on:
          l.level_id == s.level_id and
            l.organization_id == ^organization_id and
            l.gtfs_version_id == ^gtfs_version_id,
        where:
          s.organization_id == ^organization_id and
            s.gtfs_version_id == ^gtfs_version_id and
            s.parent_station == ^parent_station.stop_id and
            not is_nil(s.level_id),
        group_by: l.id,
        select: %{level_id: l.id, stop_count: count(s.id)}
      )
      |> Repo.all()
      |> Enum.into(%{}, fn %{level_id: id, stop_count: count} -> {id, count} end)

    # Query 2: Levels from stop_levels table (expressing intent)
    levels_from_stop_levels =
      from(sl in StopLevel,
        join: l in Level,
        on: sl.level_id == l.id,
        where:
          sl.organization_id == ^organization_id and
            sl.gtfs_version_id == ^gtfs_version_id and
            sl.stop_id == ^parent_station_id,
        select: %{level: l, diagram_filename: sl.diagram_filename}
      )
      |> Repo.all()

    # Combine: unique list of level IDs from both sources
    all_level_ids =
      (Map.keys(levels_from_stops) ++ Enum.map(levels_from_stop_levels, & &1.level.id))
      |> Enum.uniq()

    levels_from_stop_levels_by_id =
      Map.new(levels_from_stop_levels, fn %{level: level} = level_data ->
        {level.id, level_data}
      end)

    missing_level_ids =
      all_level_ids
      |> Enum.reject(&Map.has_key?(levels_from_stop_levels_by_id, &1))

    missing_levels_by_id =
      if missing_level_ids == [] do
        %{}
      else
        from(l in Level,
          where: l.id in ^missing_level_ids,
          select: {l.id, l}
        )
        |> Repo.all()
        |> Map.new()
      end

    # Build final result with stop counts and diagram filenames
    all_level_ids
    |> Enum.map(fn level_id ->
      # Get level from stop_levels query if available (includes diagram_filename)
      from_stop_levels = Map.get(levels_from_stop_levels_by_id, level_id)

      level =
        if from_stop_levels do
          from_stop_levels.level
        else
          case Map.fetch(missing_levels_by_id, level_id) do
            {:ok, level} ->
              level

            :error ->
              raise Ecto.NoResultsError,
                queryable: Level,
                query: "level not found for id #{inspect(level_id)} in list_levels_for_station/3"
          end
        end

      stop_count = Map.get(levels_from_stops, level_id, 0)
      diagram_filename = if from_stop_levels, do: from_stop_levels.diagram_filename, else: nil

      %{level: level, stop_count: stop_count, diagram_filename: diagram_filename}
    end)
    |> Enum.sort_by(& &1.level.level_index, :asc)
  end

  @doc """
  Gets a stop_level by stop_id and level_id.
  """
  def get_stop_level(organization_id, gtfs_version_id, stop_id, level_id) do
    from(sl in StopLevel,
      where:
        sl.organization_id == ^organization_id and
          sl.gtfs_version_id == ^gtfs_version_id and
          sl.stop_id == ^stop_id and
          sl.level_id == ^level_id
    )
    |> Repo.one()
  end

  @doc """
  Returns true if the given level is associated with any station other than `station_id`.
  """
  def level_used_by_other_stations?(organization_id, gtfs_version_id, level_id, station_id) do
    from(sl in StopLevel,
      where:
        sl.organization_id == ^organization_id and
          sl.gtfs_version_id == ^gtfs_version_id and
          sl.level_id == ^level_id and
          sl.stop_id != ^station_id
    )
    |> Repo.exists?()
  end

  @doc """
  Removes a level association from a station while preserving the shared level record.
  """
  def remove_level_from_station(
        organization_id,
        gtfs_version_id,
        station_id,
        station_stop_id,
        level_id
      ) do
    Repo.transaction(fn ->
      level = get_level!(level_id)

      from(s in Stop,
        where: s.parent_station == ^station_stop_id and s.level_id == ^level.level_id
      )
      |> Repo.update_all(set: [level_id: nil, diagram_coordinate: nil])

      with %StopLevel{} = stop_level <-
             get_stop_level(organization_id, gtfs_version_id, station_id, level_id),
           {:ok, _deleted_stop_level} <- Repo.delete(stop_level) do
        :removed
      else
        nil -> :removed
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, :removed} -> {:ok, :removed}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Creates a stop_level association.
  """
  def create_stop_level(attrs \\ %{}) do
    %StopLevel{}
    |> StopLevel.changeset(attrs)
    |> Repo.insert()
    |> broadcast([:stop_levels, :created])
  end

  @doc """
  Updates a stop's diagram coordinate.

  ## Examples

      iex> update_stop_diagram_coordinate(stop, %{x: 50.5, y: 25.0})
      {:ok, %Stop{}}
  """
  def update_stop_diagram_coordinate(%Stop{} = stop, %{x: _, y: _} = coordinate) do
    stop
    |> Stop.changeset(%{diagram_coordinate: coordinate})
    |> Repo.update()
    |> broadcast([:stops, :updated])
  end

  @doc """
  Returns child stops for a parent station filtered by level.

  ## Examples

      iex> list_child_stops_for_level(parent_station_id, level_id)
      [%Stop{}, ...]
  """
  def list_child_stops_for_level(parent_station_id, level_id) do
    parent_station = Repo.get!(Stop, parent_station_id)
    level = Repo.get!(Level, level_id)

    from(s in Stop,
      where:
        s.parent_station == ^parent_station.stop_id and
          s.organization_id == ^parent_station.organization_id and
          s.gtfs_version_id == ^parent_station.gtfs_version_id,
      order_by: [asc: s.stop_name]
    )
    |> Repo.all()
    |> Enum.map(fn stop ->
      # Add a virtual field indicating if this stop is on the active level
      Map.put(stop, :on_active_level, stop.level_id == level.level_id)
    end)
  end

  @doc """
  Returns pathways where the from_stop is on the specified level
  and both endpoints belong to the specified parent station.

  ## Examples

      iex> list_pathways_for_level(org_id, version_id, level_id, parent_station_id)
      [%Pathway{from_stop: %Stop{}, to_stop: %Stop{}}, ...]
  """
  def list_pathways_for_level(organization_id, gtfs_version_id, level_id, parent_station_id) do
    parent_station = Repo.get!(Stop, parent_station_id)
    level = Repo.get!(Level, level_id)

    from(p in Pathway,
      join: from_stop in Stop,
      on:
        p.from_stop_id == from_stop.stop_id and
          from_stop.organization_id == ^organization_id and
          from_stop.gtfs_version_id == ^gtfs_version_id,
      join: to_stop in Stop,
      on:
        p.to_stop_id == to_stop.stop_id and
          to_stop.organization_id == ^organization_id and
          to_stop.gtfs_version_id == ^gtfs_version_id,
      where:
        p.organization_id == ^organization_id and
          p.gtfs_version_id == ^gtfs_version_id and
          (from_stop.level_id == ^level.level_id or to_stop.level_id == ^level.level_id) and
          from_stop.parent_station == ^parent_station.stop_id and
          to_stop.parent_station == ^parent_station.stop_id,
      order_by: [asc: p.pathway_id],
      select: p,
      select_merge: %{from_stop: from_stop, to_stop: to_stop}
    )
    |> Repo.all()
    |> Enum.map(fn pathway ->
      # Add flags indicating if this is a cross-level pathway
      from_on_level = pathway.from_stop.level_id == level.level_id
      to_on_level = pathway.to_stop.level_id == level.level_id
      is_cross_level = from_on_level != to_on_level

      Map.merge(pathway, %{
        is_cross_level: is_cross_level,
        from_on_active_level: from_on_level,
        to_on_active_level: to_on_level
      })
    end)
  end

  @doc """
  Returns pathways where from_stop or to_stop is a child of the given station.

  ## Examples

      iex> list_pathways_for_station(org_id, version_id, parent_id)
      [%Pathway{from_stop: %Stop{}, to_stop: %Stop{}}, ...]
  """
  def list_pathways_for_station(organization_id, gtfs_version_id, parent_station_id) do
    parent_station = Repo.get!(Stop, parent_station_id)

    child_stop_ids =
      from(s in Stop,
        where:
          s.organization_id == ^organization_id and
            s.gtfs_version_id == ^gtfs_version_id and
            s.parent_station == ^parent_station.stop_id,
        select: s.stop_id
      )

    from(p in Pathway,
      join: from_stop in Stop,
      on:
        p.from_stop_id == from_stop.stop_id and
          from_stop.organization_id == ^organization_id and
          from_stop.gtfs_version_id == ^gtfs_version_id,
      join: to_stop in Stop,
      on:
        p.to_stop_id == to_stop.stop_id and
          to_stop.organization_id == ^organization_id and
          to_stop.gtfs_version_id == ^gtfs_version_id,
      where:
        p.organization_id == ^organization_id and
          p.gtfs_version_id == ^gtfs_version_id and
          (p.from_stop_id in subquery(child_stop_ids) or
             p.to_stop_id in subquery(child_stop_ids)),
      order_by: [asc: p.pathway_id],
      select: p,
      select_merge: %{from_stop: from_stop, to_stop: to_stop}
    )
    |> Repo.all()
  end

  @doc """
  Returns pathways where the given stop_id is either the from_stop or to_stop.

  ## Examples

      iex> list_pathways_for_stop(org_id, version_id, "stop_123")
      [%Pathway{}, ...]
  """
  def list_pathways_for_stop(organization_id, gtfs_version_id, stop_id) do
    from(p in Pathway,
      where:
        p.organization_id == ^organization_id and
          p.gtfs_version_id == ^gtfs_version_id and
          (p.from_stop_id == ^stop_id or p.to_stop_id == ^stop_id),
      order_by: [asc: p.pathway_id]
    )
    |> Repo.all()
  end

  @doc """
  Returns the count of pathways for an organization and GTFS version.
  """
  def count_pathways(organization_id, gtfs_version_id) do
    from(p in Pathway,
      where: p.organization_id == ^organization_id and p.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.aggregate(:count)
  end

  def list_pathways(organization_id, gtfs_version_id) do
    from(p in Pathway,
      where: p.organization_id == ^organization_id and p.gtfs_version_id == ^gtfs_version_id,
      order_by: [asc: p.pathway_id]
    )
    |> Repo.all()
  end

  @doc """
  Creates a pathway.

  ## Examples

      iex> create_pathway(%{pathway_id: "P1", pathway_mode: 1, ...})
      {:ok, %Pathway{}}
  """
  def create_pathway(attrs \\ %{}) do
    %Pathway{}
    |> Pathway.changeset(attrs)
    |> Repo.insert()
    |> broadcast([:pathways, :created])
  end

  @doc """
  Gets a single pathway.

  Raises `Ecto.NoResultsError` if the Pathway does not exist.

  ## Examples

      iex> get_pathway!(id)
      %Pathway{}

      iex> get_pathway!(Ecto.UUID.generate())
      ** (Ecto.NoResultsError)
  """
  def get_pathway!(id), do: Repo.get!(Pathway, id)

  @doc """
  Gets a single pathway with manually populated from_stop and to_stop.

  Raises `Ecto.NoResultsError` if the Pathway does not exist.

  ## Examples

      iex> get_pathway_with_stops!(id)
      %Pathway{from_stop: %Stop{}, to_stop: %Stop{}}

      iex> get_pathway_with_stops!(Ecto.UUID.generate())
      ** (Ecto.NoResultsError)
  """
  def get_pathway_with_stops!(id) do
    pathway = Repo.get!(Pathway, id)

    from_stop =
      get_stop_by_stop_id(pathway.organization_id, pathway.gtfs_version_id, pathway.from_stop_id)

    to_stop =
      get_stop_by_stop_id(pathway.organization_id, pathway.gtfs_version_id, pathway.to_stop_id)

    %{pathway | from_stop: from_stop, to_stop: to_stop}
  end

  @doc """
  Updates a pathway.

  ## Examples

      iex> update_pathway(pathway, %{pathway_mode: 2})
      {:ok, %Pathway{}}

      iex> update_pathway(pathway, %{pathway_mode: nil})
      {:error, %Ecto.Changeset{}}
  """
  def update_pathway(%Pathway{} = pathway, attrs) do
    pathway
    |> Pathway.changeset(attrs)
    |> Repo.update()
    |> broadcast([:pathways, :updated])
  end

  @doc """
  Deletes a pathway.

  ## Examples

      iex> delete_pathway(pathway)
      {:ok, %Pathway{}}

      iex> delete_pathway(pathway)
      {:error, %Ecto.Changeset{}}
  """
  def delete_pathway(%Pathway{} = pathway) do
    Repo.delete(pathway)
    |> broadcast([:pathways, :deleted])
  end

  # Agency functions

  @doc """
  Returns the count of agencies for an organization and GTFS version.
  """
  def count_agencies(organization_id, gtfs_version_id) do
    from(a in Agency,
      where: a.organization_id == ^organization_id and a.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.aggregate(:count)
  end

  @doc """
  Returns the list of agencies for an organization and GTFS version.
  """
  def list_agencies(organization_id, gtfs_version_id) do
    from(a in Agency,
      where: a.organization_id == ^organization_id and a.gtfs_version_id == ^gtfs_version_id,
      order_by: [asc: a.agency_name]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single agency by UUID.
  """
  def get_agency!(id), do: Repo.get!(Agency, id)

  @doc """
  Gets an agency by its agency_id within an organization and GTFS version.
  """
  def get_agency_by_agency_id(organization_id, gtfs_version_id, agency_id) do
    from(a in Agency,
      where:
        a.organization_id == ^organization_id and a.gtfs_version_id == ^gtfs_version_id and
          a.agency_id == ^agency_id
    )
    |> Repo.one()
  end

  @doc """
  Creates an agency.

  ## Examples

      iex> create_agency(%{organization_id: org_id, gtfs_version_id: version_id, agency_name: "Transit Agency"})
      {:ok, %Agency{}}

      iex> create_agency(%{agency_name: nil})
      {:error, %Ecto.Changeset{}}
  """
  def create_agency(attrs \\ %{}) do
    %Agency{}
    |> Agency.changeset(attrs)
    |> Repo.insert()
  end

  # Area functions

  @doc """
  Returns the list of areas for an organization and GTFS version.
  """
  def list_areas(organization_id, gtfs_version_id) do
    from(a in Area,
      where: a.organization_id == ^organization_id and a.gtfs_version_id == ^gtfs_version_id,
      order_by: [asc: a.area_id]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single area by UUID.
  """
  def get_area!(id), do: Repo.get!(Area, id)

  @doc """
  Gets an area by its area_id within an organization and GTFS version.
  """
  def get_area_by_area_id(organization_id, gtfs_version_id, area_id) do
    from(a in Area,
      where:
        a.organization_id == ^organization_id and a.gtfs_version_id == ^gtfs_version_id and
          a.area_id == ^area_id
    )
    |> Repo.one()
  end

  # Attribution functions

  @doc """
  Returns the count of attributions for an organization and GTFS version.
  """
  def count_attributions(organization_id, gtfs_version_id) do
    from(a in Attribution,
      where: a.organization_id == ^organization_id and a.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.aggregate(:count)
  end

  @doc """
  Returns the list of attributions for an organization and GTFS version.
  """
  def list_attributions(organization_id, gtfs_version_id) do
    from(a in Attribution,
      where: a.organization_id == ^organization_id and a.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.all()
  end

  @doc """
  Gets a single attribution by UUID.
  """
  def get_attribution!(id), do: Repo.get!(Attribution, id)

  # BookingRule functions

  @doc """
  Returns the list of booking rules for an organization and GTFS version.
  """
  def list_booking_rules(organization_id, gtfs_version_id) do
    from(b in BookingRule,
      where: b.organization_id == ^organization_id and b.gtfs_version_id == ^gtfs_version_id,
      order_by: [asc: b.booking_rule_id]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single booking rule by UUID.
  """
  def get_booking_rule!(id), do: Repo.get!(BookingRule, id)

  @doc """
  Gets a booking rule by its booking_rule_id within an organization and GTFS version.
  """
  def get_booking_rule_by_booking_rule_id(organization_id, gtfs_version_id, booking_rule_id) do
    from(b in BookingRule,
      where:
        b.organization_id == ^organization_id and b.gtfs_version_id == ^gtfs_version_id and
          b.booking_rule_id == ^booking_rule_id
    )
    |> Repo.one()
  end

  # FareAttribute functions

  @doc """
  Returns the count of fare attributes for an organization and GTFS version.
  """
  def count_fare_attributes(organization_id, gtfs_version_id) do
    from(f in FareAttribute,
      where: f.organization_id == ^organization_id and f.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.aggregate(:count)
  end

  @doc """
  Returns the list of fare attributes for an organization and GTFS version.
  """
  def list_fare_attributes(organization_id, gtfs_version_id) do
    from(f in FareAttribute,
      where: f.organization_id == ^organization_id and f.gtfs_version_id == ^gtfs_version_id,
      order_by: [asc: f.fare_id]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single fare attribute by UUID.
  """
  def get_fare_attribute!(id), do: Repo.get!(FareAttribute, id)

  @doc """
  Gets a fare attribute by its fare_id within an organization and GTFS version.
  """
  def get_fare_attribute_by_fare_id(organization_id, gtfs_version_id, fare_id) do
    from(f in FareAttribute,
      where:
        f.organization_id == ^organization_id and f.gtfs_version_id == ^gtfs_version_id and
          f.fare_id == ^fare_id
    )
    |> Repo.one()
  end

  # FareLegJoinRule functions

  @doc """
  Returns the list of fare leg join rules for an organization and GTFS version.
  """
  def list_fare_leg_join_rules(organization_id, gtfs_version_id) do
    from(f in FareLegJoinRule,
      where: f.organization_id == ^organization_id and f.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.all()
  end

  @doc """
  Gets a single fare leg join rule by UUID.
  """
  def get_fare_leg_join_rule!(id), do: Repo.get!(FareLegJoinRule, id)

  # FareLegRule functions

  @doc """
  Returns the list of fare leg rules for an organization and GTFS version.
  """
  def list_fare_leg_rules(organization_id, gtfs_version_id) do
    from(f in FareLegRule,
      where: f.organization_id == ^organization_id and f.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.all()
  end

  @doc """
  Gets a single fare leg rule by UUID.
  """
  def get_fare_leg_rule!(id), do: Repo.get!(FareLegRule, id)

  # FareMedia functions

  @doc """
  Returns the list of fare media for an organization and GTFS version.
  """
  def list_fare_media(organization_id, gtfs_version_id) do
    from(f in FareMedia,
      where: f.organization_id == ^organization_id and f.gtfs_version_id == ^gtfs_version_id,
      order_by: [asc: f.fare_media_id]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single fare media by UUID.
  """
  def get_fare_media!(id), do: Repo.get!(FareMedia, id)

  @doc """
  Gets a fare media by its fare_media_id within an organization and GTFS version.
  """
  def get_fare_media_by_fare_media_id(organization_id, gtfs_version_id, fare_media_id) do
    from(f in FareMedia,
      where:
        f.organization_id == ^organization_id and f.gtfs_version_id == ^gtfs_version_id and
          f.fare_media_id == ^fare_media_id
    )
    |> Repo.one()
  end

  # FareProduct functions

  @doc """
  Returns the list of fare products for an organization and GTFS version.
  """
  def list_fare_products(organization_id, gtfs_version_id) do
    from(f in FareProduct,
      where: f.organization_id == ^organization_id and f.gtfs_version_id == ^gtfs_version_id,
      order_by: [asc: f.fare_product_id]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single fare product by UUID.
  """
  def get_fare_product!(id), do: Repo.get!(FareProduct, id)

  # FareRule functions

  @doc """
  Returns the count of fare rules for an organization and GTFS version.
  """
  def count_fare_rules(organization_id, gtfs_version_id) do
    from(f in FareRule,
      where: f.organization_id == ^organization_id and f.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.aggregate(:count)
  end

  @doc """
  Returns the list of fare rules for an organization and GTFS version.
  """
  def list_fare_rules(organization_id, gtfs_version_id) do
    from(f in FareRule,
      where: f.organization_id == ^organization_id and f.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.all()
  end

  @doc """
  Gets a single fare rule by UUID.
  """
  def get_fare_rule!(id), do: Repo.get!(FareRule, id)

  # FareTransferRule functions

  @doc """
  Returns the list of fare transfer rules for an organization and GTFS version.
  """
  def list_fare_transfer_rules(organization_id, gtfs_version_id) do
    from(f in FareTransferRule,
      where: f.organization_id == ^organization_id and f.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.all()
  end

  @doc """
  Gets a single fare transfer rule by UUID.
  """
  def get_fare_transfer_rule!(id), do: Repo.get!(FareTransferRule, id)

  # FeedInfo functions

  @doc """
  Returns the count of feed info for an organization and GTFS version.
  """
  def count_feed_info(organization_id, gtfs_version_id) do
    from(f in FeedInfo,
      where: f.organization_id == ^organization_id and f.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.aggregate(:count)
  end

  @doc """
  Returns the feed info for an organization and GTFS version.
  """
  def get_feed_info(organization_id, gtfs_version_id) do
    from(f in FeedInfo,
      where: f.organization_id == ^organization_id and f.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.one()
  end

  @doc """
  Gets a single feed info by UUID.
  """
  def get_feed_info!(id), do: Repo.get!(FeedInfo, id)

  # Frequency functions

  @doc """
  Returns the count of frequencies for an organization and GTFS version.
  """
  def count_frequencies(organization_id, gtfs_version_id) do
    from(f in Frequency,
      where: f.organization_id == ^organization_id and f.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.aggregate(:count)
  end

  @doc """
  Returns the list of frequencies for an organization and GTFS version.
  """
  def list_frequencies(organization_id, gtfs_version_id) do
    from(f in Frequency,
      where: f.organization_id == ^organization_id and f.gtfs_version_id == ^gtfs_version_id,
      order_by: [asc: f.trip_id, asc: f.start_time]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single frequency by UUID.
  """
  def get_frequency!(id), do: Repo.get!(Frequency, id)

  # Location functions

  @doc """
  Returns the list of locations for an organization and GTFS version.
  """
  def list_locations(organization_id, gtfs_version_id) do
    from(l in Location,
      where: l.organization_id == ^organization_id and l.gtfs_version_id == ^gtfs_version_id,
      order_by: [asc: l.location_id]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single location by UUID.
  """
  def get_location!(id), do: Repo.get!(Location, id)

  @doc """
  Gets a location by its location_id within an organization and GTFS version.
  """
  def get_location_by_location_id(organization_id, gtfs_version_id, location_id) do
    from(l in Location,
      where:
        l.organization_id == ^organization_id and l.gtfs_version_id == ^gtfs_version_id and
          l.location_id == ^location_id
    )
    |> Repo.one()
  end

  # Network functions

  @doc """
  Returns the list of networks for an organization and GTFS version.
  """
  def list_networks(organization_id, gtfs_version_id) do
    from(n in Network,
      where: n.organization_id == ^organization_id and n.gtfs_version_id == ^gtfs_version_id,
      order_by: [asc: n.network_id]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single network by UUID.
  """
  def get_network!(id), do: Repo.get!(Network, id)

  @doc """
  Gets a network by its network_id within an organization and GTFS version.
  """
  def get_network_by_network_id(organization_id, gtfs_version_id, network_id) do
    from(n in Network,
      where:
        n.organization_id == ^organization_id and n.gtfs_version_id == ^gtfs_version_id and
          n.network_id == ^network_id
    )
    |> Repo.one()
  end

  # RiderCategory functions

  @doc """
  Returns the list of rider categories for an organization and GTFS version.
  """
  def list_rider_categories(organization_id, gtfs_version_id) do
    from(r in RiderCategory,
      where: r.organization_id == ^organization_id and r.gtfs_version_id == ^gtfs_version_id,
      order_by: [asc: r.rider_category_id]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single rider category by UUID.
  """
  def get_rider_category!(id), do: Repo.get!(RiderCategory, id)

  @doc """
  Gets a rider category by its rider_category_id within an organization and GTFS version.
  """
  def get_rider_category_by_rider_category_id(organization_id, gtfs_version_id, rider_category_id) do
    from(r in RiderCategory,
      where:
        r.organization_id == ^organization_id and r.gtfs_version_id == ^gtfs_version_id and
          r.rider_category_id == ^rider_category_id
    )
    |> Repo.one()
  end

  # RouteNetwork functions

  @doc """
  Returns the list of route networks for an organization and GTFS version.
  """
  def list_route_networks(organization_id, gtfs_version_id) do
    from(r in RouteNetwork,
      where: r.organization_id == ^organization_id and r.gtfs_version_id == ^gtfs_version_id,
      order_by: [asc: r.network_id, asc: r.route_id]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single route network by UUID.
  """
  def get_route_network!(id), do: Repo.get!(RouteNetwork, id)

  # Shape functions

  @doc """
  Returns the count of shapes for an organization and GTFS version.
  """
  def count_shapes(organization_id, gtfs_version_id) do
    from(s in Shape,
      where: s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.aggregate(:count)
  end

  @doc """
  Returns the list of shapes for an organization and GTFS version.
  """
  def list_shapes(organization_id, gtfs_version_id) do
    from(s in Shape,
      where: s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id,
      order_by: [asc: s.shape_id, asc: s.shape_pt_sequence]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single shape by UUID.
  """
  def get_shape!(id), do: Repo.get!(Shape, id)

  # StopArea functions

  @doc """
  Returns the list of stop areas for an organization and GTFS version.
  """
  def list_stop_areas(organization_id, gtfs_version_id) do
    from(s in StopArea,
      where: s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id,
      order_by: [asc: s.area_id, asc: s.stop_id]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single stop area by UUID.
  """
  def get_stop_area!(id), do: Repo.get!(StopArea, id)

  # Timeframe functions

  @doc """
  Returns the list of timeframes for an organization and GTFS version.
  """
  def list_timeframes(organization_id, gtfs_version_id) do
    from(t in Timeframe,
      where: t.organization_id == ^organization_id and t.gtfs_version_id == ^gtfs_version_id,
      order_by: [asc: t.timeframe_group_id]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single timeframe by UUID.
  """
  def get_timeframe!(id), do: Repo.get!(Timeframe, id)

  # Transfer functions

  @doc """
  Returns the count of transfers for an organization and GTFS version.
  """
  def count_transfers(organization_id, gtfs_version_id) do
    from(t in Transfer,
      where: t.organization_id == ^organization_id and t.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.aggregate(:count)
  end

  @doc """
  Returns the list of transfers for an organization and GTFS version.
  """
  def list_transfers(organization_id, gtfs_version_id) do
    from(t in Transfer,
      where: t.organization_id == ^organization_id and t.gtfs_version_id == ^gtfs_version_id,
      order_by: [asc: t.from_stop_id, asc: t.to_stop_id]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single transfer by UUID.
  """
  def get_transfer!(id), do: Repo.get!(Transfer, id)

  # Translation functions

  @doc """
  Returns the list of translations for an organization and GTFS version.
  """
  def list_translations(organization_id, gtfs_version_id) do
    from(t in Translation,
      where: t.organization_id == ^organization_id and t.gtfs_version_id == ^gtfs_version_id,
      order_by: [asc: t.table_name, asc: t.field_name, asc: t.language]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single translation by UUID.
  """
  def get_translation!(id), do: Repo.get!(Translation, id)

  # Trip functions

  @doc """
  Returns the count of trips for an organization and GTFS version.
  """
  def count_trips(organization_id, gtfs_version_id) do
    from(t in Trip,
      where: t.organization_id == ^organization_id and t.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.aggregate(:count)
  end

  @doc """
  Creates a trip.
  """
  def create_trip(attrs \\ %{}) do
    %Trip{}
    |> Trip.changeset(attrs)
    |> Repo.insert()
  end

  # StopTime functions

  @doc """
  Returns the count of stop times for an organization and GTFS version.
  """
  def count_stop_times(organization_id, gtfs_version_id) do
    from(s in StopTime,
      where: s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.aggregate(:count)
  end

  @doc """
  Creates a stop time.
  """
  def create_stop_time(attrs \\ %{}) do
    %StopTime{}
    |> StopTime.changeset(attrs)
    |> Repo.insert()
  end

  # Calendar functions

  @doc """
  Returns the count of calendars for an organization and GTFS version.
  """
  def count_calendars(organization_id, gtfs_version_id) do
    from(c in Calendar,
      where: c.organization_id == ^organization_id and c.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.aggregate(:count)
  end

  # CalendarDate functions

  @doc """
  Returns the count of calendar dates for an organization and GTFS version.
  """
  def count_calendar_dates(organization_id, gtfs_version_id) do
    from(c in CalendarDate,
      where: c.organization_id == ^organization_id and c.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.aggregate(:count)
  end

  def get_file_inventory(organization_id, gtfs_version_id, export_type) do
    if export_type == :pathways do
      [
        {"stops.txt", count_stops(organization_id, gtfs_version_id)},
        {"levels.txt", count_levels(organization_id, gtfs_version_id)},
        {"pathways.txt", count_pathways(organization_id, gtfs_version_id)}
      ]
    else
      [
        {"agency.txt", count_agencies(organization_id, gtfs_version_id)},
        {"stops.txt", count_stops(organization_id, gtfs_version_id)},
        {"routes.txt", count_routes(organization_id, gtfs_version_id)},
        {"trips.txt", count_trips(organization_id, gtfs_version_id)},
        {"stop_times.txt", count_stop_times(organization_id, gtfs_version_id)},
        {"calendar.txt", count_calendars(organization_id, gtfs_version_id)},
        {"calendar_dates.txt", count_calendar_dates(organization_id, gtfs_version_id)},
        {"fare_attributes.txt", count_fare_attributes(organization_id, gtfs_version_id)},
        {"fare_rules.txt", count_fare_rules(organization_id, gtfs_version_id)},
        {"shapes.txt", count_shapes(organization_id, gtfs_version_id)},
        {"frequencies.txt", count_frequencies(organization_id, gtfs_version_id)},
        {"transfers.txt", count_transfers(organization_id, gtfs_version_id)},
        {"pathways.txt", count_pathways(organization_id, gtfs_version_id)},
        {"levels.txt", count_levels(organization_id, gtfs_version_id)},
        {"feed_info.txt", count_feed_info(organization_id, gtfs_version_id)},
        {"attributions.txt", count_attributions(organization_id, gtfs_version_id)}
      ]
    end
  end

  # Private helper functions

  defp maybe_filter_type(query, nil), do: query
  defp maybe_filter_type(query, ""), do: query

  defp maybe_filter_type(query, route_type) do
    where(query, [r], r.route_type == ^route_type)
  end

  defp maybe_filter_agency(query, nil), do: query
  defp maybe_filter_agency(query, ""), do: query

  defp maybe_filter_agency(query, agency_id) do
    where(query, [r], r.agency_id == ^agency_id)
  end

  defp maybe_filter_active(query, nil), do: query
  defp maybe_filter_active(query, "all"), do: query
  defp maybe_filter_active(query, ""), do: query

  defp maybe_filter_active(query, "true") do
    where(query, [r], r.active == true)
  end

  defp maybe_filter_active(query, "false") do
    where(query, [r], r.active == false)
  end

  defp maybe_filter_wheelchair(query, nil), do: query
  defp maybe_filter_wheelchair(query, ""), do: query

  defp maybe_filter_wheelchair(query, wheelchair_boarding) do
    where(query, [s], s.wheelchair_boarding == ^wheelchair_boarding)
  end

  defp maybe_filter_route(query, nil, _organization_id, _gtfs_version_id), do: query
  defp maybe_filter_route(query, "", _organization_id, _gtfs_version_id), do: query

  defp maybe_filter_route(query, route_id, organization_id, gtfs_version_id) do
    # Step 1: Get representative trip_ids from route_patterns (typically 2-4 trips)
    # This is much faster than scanning all trips for a route
    representative_trip_ids =
      from(rp in RoutePattern,
        where:
          rp.route_id == ^route_id and
            rp.organization_id == ^organization_id and
            rp.gtfs_version_id == ^gtfs_version_id and
            not is_nil(rp.representative_trip_id),
        select: rp.representative_trip_id
      )
      |> Repo.all()

    # Step 2: Get stop_ids using route_patterns (fast) or all trips (fallback)
    stop_ids =
      if representative_trip_ids != [] do
        # Fast path: Query only 2-4 representative trips
        from(st in StopTime,
          where:
            st.trip_id in ^representative_trip_ids and
              st.organization_id == ^organization_id and
              st.gtfs_version_id == ^gtfs_version_id,
          distinct: true,
          select: st.stop_id
        )
        |> Repo.all()
      else
        # Fallback: For data without route_patterns, query all trips
        from(st in StopTime,
          join: t in Trip,
          on:
            st.trip_id == t.trip_id and
              st.organization_id == t.organization_id and
              st.gtfs_version_id == t.gtfs_version_id,
          where:
            t.route_id == ^route_id and
              t.organization_id == ^organization_id and
              t.gtfs_version_id == ^gtfs_version_id,
          distinct: true,
          select: st.stop_id
        )
        |> Repo.all()
      end

    # Step 3: Filter stops using IN clause (efficient with index)
    where(query, [s], s.stop_id in ^stop_ids)
  end

  defp maybe_filter_direction(query, nil, _organization_id, _gtfs_version_id), do: query
  defp maybe_filter_direction(query, "", _organization_id, _gtfs_version_id), do: query

  defp maybe_filter_direction(query, direction_id, organization_id, gtfs_version_id) do
    # Filter stations by direction_id
    # Find stops that are served by trips with the specified direction_id
    stop_ids =
      from(st in StopTime,
        join: t in Trip,
        on:
          st.trip_id == t.trip_id and
            st.organization_id == t.organization_id and
            st.gtfs_version_id == t.gtfs_version_id,
        where:
          t.direction_id == ^direction_id and
            t.organization_id == ^organization_id and
            t.gtfs_version_id == ^gtfs_version_id,
        distinct: true,
        select: st.stop_id
      )
      |> Repo.all()

    where(query, [s], s.stop_id in ^stop_ids)
  end

  defp maybe_search_stops(query, nil), do: query
  defp maybe_search_stops(query, ""), do: query

  defp maybe_search_stops(query, term) do
    pattern = "%#{term}%"
    where(query, [s], ilike(s.stop_id, ^pattern) or ilike(s.stop_name, ^pattern))
  end

  defp apply_stop_sort(query, sort_by, sort_dir)
       when sort_by in [:stop_id, :stop_name, :location_type] and sort_dir in [:asc, :desc] do
    order_by(query, [s], [{^sort_dir, field(s, ^sort_by)}])
  end

  defp apply_stop_sort(query, _sort_by, _sort_dir) do
    order_by(query, [s], asc: s.stop_name)
  end

  defp maybe_search(query, nil), do: query
  defp maybe_search(query, ""), do: query

  defp maybe_search(query, term) do
    search_pattern = "%#{term}%"

    where(
      query,
      [r],
      ilike(r.route_id, ^search_pattern) or
        ilike(r.route_short_name, ^search_pattern) or
        ilike(r.route_long_name, ^search_pattern)
    )
  end

  defp apply_sort(query, nil, _sort_dir), do: order_by(query, [r], asc: r.route_id)
  defp apply_sort(query, _sort_by, nil), do: order_by(query, [r], asc: r.route_id)

  defp apply_sort(query, sort_by, sort_dir)
       when sort_by in [:route_id, :route_short_name, :route_long_name, :route_type, :active] and
              sort_dir in [:asc, :desc] do
    order_by(query, [r], [{^sort_dir, field(r, ^sort_by)}])
  end

  defp apply_sort(query, _sort_by, _sort_dir), do: order_by(query, [r], asc: r.route_id)

  defp paginate(query, nil, _per_page), do: paginate(query, 1, 25)
  defp paginate(query, _page, nil), do: paginate(query, 1, 25)

  defp paginate(query, page, per_page) when is_integer(page) and is_integer(per_page) do
    offset = (page - 1) * per_page
    query |> limit(^per_page) |> offset(^offset)
  end

  defp paginate(query, _page, _per_page), do: paginate(query, 1, 25)

  defp broadcast({:ok, result}, event_topic) do
    broadcast_result =
      case event_topic do
        [:levels, _] ->
          Phoenix.PubSub.broadcast(GtfsPlanner.PubSub, "levels", {event_topic, result})

        [:stops, _] ->
          Phoenix.PubSub.broadcast(GtfsPlanner.PubSub, "stops", {event_topic, result})

        [:pathways, _] ->
          Phoenix.PubSub.broadcast(GtfsPlanner.PubSub, "pathways", {event_topic, result})

        [:stop_levels, _] ->
          Phoenix.PubSub.broadcast(GtfsPlanner.PubSub, "stop_levels", {event_topic, result})
      end

    case broadcast_result do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to broadcast #{inspect(event_topic)} event: #{inspect(reason)}")
    end

    {:ok, result}
  end

  defp broadcast({:error, reason}, _event_topic) do
    {:error, reason}
  end
end
