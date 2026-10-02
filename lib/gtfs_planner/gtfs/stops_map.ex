defmodule GtfsPlanner.Gtfs.StopsMap do
  @moduledoc """
  The Map view's read model: every stop in a version, one line per pattern, the
  routes those lines belong to, and the bounds to fit them in.

  `load/2` issues a fixed set of five queries whatever the version holds. That
  is the whole point of the module. A read model that grows a query per pattern
  is a read model whose cost an editor feels as the map stutters, and a feed
  with 300 patterns would then take 300 round trips to draw a picture that
  changes rarely. The count is asserted in `stops_map_test.exs` at one pattern
  and at fifty, and measured again at 300 in the tagged budget test.

  Lines come from saved geometry, in this order: the
  pattern's own `shape_id` when it has shape rows, otherwise the most common
  `shape_id` among its linked trips, otherwise a straight `:connector` through
  the pattern's located stops in position order. Nothing here calls an
  alignments resolver: this is a read of what is landed, not a proposal about
  what it should be. The redraw path is `Alignments`' business.

  Points are `{lon, lat}` tuples here, the order `StopPlacement` and the map hook
  use. `display_payload/2` is the boundary that converts them to `[lon, lat]`
  JSON arrays, so nothing downstream has to remember which is which.

  Everything is scoped by `organization_id` and `gtfs_version_id`. A row of
  another version never reaches the map, including a shape of the same
  `shape_id` in another version.
  """

  import Ecto.Query

  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.RoutePatternStop
  alias GtfsPlanner.Gtfs.Shape
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopPlacement
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo

  @type point :: {float(), float()}
  @type stop_row :: %{
          required(:id) => Ecto.UUID.t(),
          required(:stop_id) => String.t(),
          required(:name) => String.t() | nil,
          required(:desc) => String.t() | nil,
          required(:code) => String.t() | nil,
          required(:point) => point() | nil,
          required(:location_type) => integer(),
          required(:parent_station) => String.t() | nil,
          optional(:zone_id) => String.t() | nil,
          required(:served?) => boolean(),
          required(:pattern_ids) => [Ecto.UUID.t()]
        }
  @type line :: %{
          required(:pattern_id) => Ecto.UUID.t(),
          required(:route_id) => String.t(),
          required(:direction_id) => integer() | nil,
          required(:headsign) => String.t() | nil,
          required(:source) => :shape | :connector,
          required(:points) => [point()]
        }
  @type route :: %{
          required(:route_id) => String.t(),
          required(:short_name) => String.t() | nil,
          required(:long_name) => String.t() | nil,
          required(:color) => String.t() | nil,
          required(:text_color) => String.t() | nil
        }
  @type model :: %{
          required(:stops) => [stop_row()],
          required(:lines) => [line()],
          required(:routes) => %{optional(String.t()) => route()},
          required(:bounds) => {point(), point()} | nil
        }

  @doc """
  Reads the whole version's map model in one fixed set of queries.

  Returns `{:ok, model}`, where `model` carries every stop with its point,
  type, parent, served flag and the patterns that visit it, one line per
  pattern, the routes those patterns belong to, and the bounding pair of
  located stops. A version with no located stop has `bounds: nil` rather than a
  fabricated box at the origin: the hook has nothing to fit and says so.
  """
  @spec load(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, model()} | {:error, :unavailable}
  def load(organization_id, gtfs_version_id) do
    stops = load_stops(organization_id, gtfs_version_id)
    occurrences = load_occurrences(organization_id, gtfs_version_id)
    trip_shapes = load_trip_shape_counts(organization_id, gtfs_version_id)
    served_by_time = load_served_by_stop_times(organization_id, gtfs_version_id)

    patterns = load_patterns(occurrences)

    points_by_shape =
      load_shape_points(organization_id, gtfs_version_id, chosen_shape_ids(patterns, trip_shapes))

    {:ok,
     %{
       stops: stop_rows(stops, occurrences, served_by_time),
       lines: lines(patterns, trip_shapes, points_by_shape, stops),
       routes: routes(patterns),
       bounds: bounds(stops)
     }}
  rescue
    DBConnection.ConnectionError -> {:error, :unavailable}
  end

  @doc """
  The JSON-safe form of the model the map hook consumes.

  Lines are simplified at `tolerance_m` metres, keeping each line's first and
  last point: a line that lost its endpoints would be drawn short, and a shape's
  last point is often the only evidence of where a route actually turns. Points
  become `[lon, lat]` arrays of JSON numbers, and every UUID becomes its string
  so the payload survives `Jason.encode!/1` without a custom encoder.
  """
  @spec display_payload(model(), float()) :: map()
  def display_payload(model, tolerance_m) do
    %{
      stops: Enum.map(model.stops, &display_stop/1),
      lines: Enum.map(model.lines, &display_line(&1, tolerance_m)),
      routes: model.routes,
      bounds: display_bounds(model.bounds)
    }
  end

  @doc """
  Reads one stop of the version for the edit panel, as the `%Stop{}` itself.

  `load/2` answers what to draw and hands back plain rows, because everything
  downstream of it is JSON. The edit panel is the one reader that needs the
  schema struct: `StopEditing.update_stop/4` and `StopReferences.usage/3` both
  take a `%Stop{}`, and `updated_at` is the row this panel posts back so the
  command can refuse a save that would overwrite another editor.

  Scoped by organization and version exactly as `load/2` is, so a stop ID from
  the query string cannot open another feed's stop, and a stop of another
  version is `:not_found` rather than an answer.
  """
  @spec load_stop(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, Stop.t()} | {:error, :not_found | :unavailable}
  def load_stop(organization_id, gtfs_version_id, stop_id)
      when is_binary(stop_id) do
    from(stop in Stop,
      where:
        stop.organization_id == ^organization_id and stop.gtfs_version_id == ^gtfs_version_id and
          stop.stop_id == ^stop_id,
      limit: 1
    )
    |> Repo.one()
    |> case do
      %Stop{} = stop -> {:ok, stop}
      nil -> {:error, :not_found}
    end
  rescue
    DBConnection.ConnectionError -> {:error, :unavailable}
  end

  # 1. Stops. Every stop in the version, located or not: an unlocated stop still
  # belongs in the browse panel, and dropping it here would make the panel lie
  # about how many stops the version has.
  defp load_stops(organization_id, gtfs_version_id) do
    from(stop in Stop,
      where:
        stop.organization_id == ^organization_id and stop.gtfs_version_id == ^gtfs_version_id,
      order_by: [asc: stop.stop_id],
      select: %{
        id: stop.id,
        stop_id: stop.stop_id,
        name: stop.stop_name,
        desc: stop.stop_desc,
        code: stop.stop_code,
        lat: stop.stop_lat,
        lon: stop.stop_lon,
        location_type: stop.location_type,
        parent_station: stop.parent_station,
        zone_id: stop.zone_id
      }
    )
    |> Repo.all()
  end

  # 2. Patterns with their route, direction, headsign and ordered occurrences.
  # One query, because the occurrence rows are what make a connector line and
  # what tells a stop which patterns visit it.
  defp load_occurrences(organization_id, gtfs_version_id) do
    from(pattern in RoutePattern,
      join: route in Route,
      on:
        route.route_id == pattern.route_id and
          route.organization_id == pattern.organization_id and
          route.gtfs_version_id == pattern.gtfs_version_id,
      left_join: occurrence in RoutePatternStop,
      on: occurrence.route_pattern_id == pattern.id,
      where:
        pattern.organization_id == ^organization_id and
          pattern.gtfs_version_id == ^gtfs_version_id,
      order_by: [
        asc: pattern.route_pattern_sort_order,
        asc: pattern.route_pattern_id,
        asc: occurrence.position
      ],
      select: %{
        pattern_id: pattern.id,
        route_pattern_id: pattern.route_pattern_id,
        route_id: pattern.route_id,
        direction_id: pattern.direction_id,
        headsign: pattern.headsign,
        shape_id: pattern.shape_id,
        route_short_name: route.route_short_name,
        route_long_name: route.route_long_name,
        route_color: route.route_color,
        route_text_color: route.route_text_color,
        stop_id: occurrence.stop_id,
        position: occurrence.position
      }
    )
    |> Repo.all()
  end

  # 3. How many trips link each pattern to each shape. The counts, not the
  # trips: a feed with 40,000 trips on 300 patterns must not load 40,000 rows
  # to learn which shape is the common one.
  defp load_trip_shape_counts(organization_id, gtfs_version_id) do
    from(trip in Trip,
      where:
        trip.organization_id == ^organization_id and trip.gtfs_version_id == ^gtfs_version_id and
          not is_nil(trip.shape_id) and not is_nil(trip.route_pattern_id),
      group_by: [trip.route_pattern_id, trip.shape_id],
      order_by: [asc: trip.route_pattern_id, desc: count(trip.shape_id), asc: trip.shape_id],
      select: {trip.route_pattern_id, trip.shape_id, count(trip.shape_id)}
    )
    |> Repo.all()
  end

  # 5. Served by `stop_times` alone. `route_pattern_stops` already arrived with
  # query 2, so the union happens in memory; this is the only other table that
  # can make a stop served.
  defp load_served_by_stop_times(organization_id, gtfs_version_id) do
    from(stop_time in StopTime,
      distinct: true,
      where:
        stop_time.organization_id == ^organization_id and
          stop_time.gtfs_version_id == ^gtfs_version_id,
      select: stop_time.stop_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  # 4. Shape points for exactly the shapes the lines will use. Reading them for
  # every shape in the version would import geometry the map never draws.
  defp load_shape_points(_organization_id, _gtfs_version_id, []), do: %{}

  defp load_shape_points(organization_id, gtfs_version_id, shape_ids) do
    from(shape in Shape,
      where:
        shape.organization_id == ^organization_id and shape.gtfs_version_id == ^gtfs_version_id and
          shape.shape_id in ^shape_ids,
      order_by: [asc: shape.shape_id, asc: shape.shape_pt_sequence],
      select: {shape.shape_id, shape.shape_pt_lat, shape.shape_pt_lon}
    )
    |> Repo.all()
    |> Enum.group_by(fn {shape_id, _lat, _lon} -> shape_id end, fn {_shape_id, lat, lon} ->
      point(lat, lon)
    end)
    |> Map.new(fn {shape_id, points} -> {shape_id, Enum.reject(points, &is_nil/1)} end)
  end

  # Group the occurrence rows into one entry per pattern, keeping the route
  # fields once and the ordered stop ids alongside.
  defp load_patterns(occurrences) do
    occurrences
    |> Enum.group_by(& &1.pattern_id)
    |> Enum.sort_by(fn {pattern_id, _rows} -> pattern_id end)
    |> Enum.map(fn {pattern_id, rows} ->
      first = hd(rows)

      %{
        pattern_id: pattern_id,
        route_pattern_id: first.route_pattern_id,
        route_id: first.route_id,
        direction_id: first.direction_id,
        headsign: first.headsign,
        shape_id: first.shape_id,
        route_short_name: first.route_short_name,
        route_long_name: first.route_long_name,
        route_color: first.route_color,
        route_text_color: first.route_text_color,
        stop_ids: rows |> Enum.map(& &1.stop_id) |> Enum.uniq()
      }
    end)
  end

  # The pattern's own shape when it has one, else the shape most of its linked
  # trips use, else nothing — the caller falls back to a connector. Ties break
  # on `shape_id` (the ordering of query 3) so two runs of the same feed draw the
  # same line.
  defp chosen_shape_ids(patterns, trip_shapes) do
    by_pattern = group_trip_shapes(trip_shapes)

    patterns
    |> Enum.map(fn pattern ->
      # `Map.get/3` answers `nil` for a pattern no trip is linked to, which is
      # the common case: a pattern whose shape came from its own `shape_id`
      # before any trip existed. The pattern's own shape wins either way.
      case Map.get(by_pattern, pattern.route_pattern_id) do
        [most_common | _] -> pattern.shape_id || most_common
        _ -> pattern.shape_id
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  # `trips.route_pattern_id` is the natural pattern id, not the row's UUID, so
  # this groups by the natural id the patterns also carry.
  defp group_trip_shapes(trip_shapes) do
    trip_shapes
    |> Enum.group_by(
      fn {route_pattern_id, _shape_id, _count} -> route_pattern_id end,
      fn {_route_pattern_id, shape_id, _count} -> shape_id end
    )
  end

  defp stop_rows(stops, occurrences, served_by_time) do
    patterns_by_stop =
      Enum.group_by(occurrences, & &1.stop_id, & &1.pattern_id)

    stops
    |> Enum.map(fn stop ->
      visitors = Map.get(patterns_by_stop, stop.stop_id, [])

      %{
        id: stop.id,
        stop_id: stop.stop_id,
        name: stop.name,
        desc: stop.desc,
        code: stop.code,
        point: point(stop.lat, stop.lon),
        location_type: stop.location_type,
        parent_station: stop.parent_station,
        zone_id: stop.zone_id,
        served?: MapSet.member?(served_by_time, stop.stop_id) or visitors != [],
        pattern_ids: visitors |> Enum.uniq() |> Enum.sort()
      }
    end)
  end

  defp lines(patterns, trip_shapes, points_by_shape, stops) do
    by_pattern = group_trip_shapes(trip_shapes)

    points_by_stop =
      Enum.reduce(stops, %{}, fn stop, acc ->
        Map.put(acc, stop.stop_id, point(stop.lat, stop.lon))
      end)

    Enum.map(patterns, fn pattern ->
      linked = Map.get(by_pattern, pattern.route_pattern_id)

      case shape_points(pattern, linked, points_by_shape) do
        [] ->
          pattern
          |> Map.put(:source, :connector)
          |> Map.put(:points, connector_points(pattern.stop_ids, points_by_stop))

        points ->
          pattern |> Map.put(:source, :shape) |> Map.put(:points, points)
      end
    end)
  end

  # `own` is the pattern's own shape when it has shape rows. A `shape_id` with
  # no rows falls through to the linked-trip shape, because a pattern naming a
  # shape the version does not have has no geometry from that name.
  defp shape_points(pattern, linked_shape_ids, points_by_shape) do
    own = if pattern.shape_id, do: Map.get(points_by_shape, pattern.shape_id, []), else: []

    cond do
      own != [] ->
        own

      is_list(linked_shape_ids) and linked_shape_ids != [] ->
        Map.get(points_by_shape, hd(linked_shape_ids), [])

      true ->
        []
    end
  end

  # A connector is the pattern's own located stops in order. A pattern with
  # fewer than two located stops has no line at all: a one-point line draws
  # nothing and pretending otherwise would put a mark on the map that no vehicle
  # ever follows.
  defp connector_points(stop_ids, points_by_stop) do
    stop_ids
    |> Enum.map(&Map.get(points_by_stop, &1))
    |> Enum.reject(&is_nil/1)
  end

  defp routes(patterns) do
    patterns
    |> Map.new(fn pattern ->
      {pattern.route_id,
       %{
         route_id: pattern.route_id,
         short_name: pattern.route_short_name,
         long_name: pattern.route_long_name,
         color: pattern.route_color,
         text_color: pattern.route_text_color
       }}
    end)
  end

  # Floats, not the `Decimal` structs the columns hold: `Enum.min/2` over
  # structs compares them as terms, not as numbers, and would order a negative
  # coordinate by its coefficient rather than by its value.
  defp bounds(stops) do
    located =
      for %{lat: lat, lon: lon} <- stops,
          not is_nil(lat) and not is_nil(lon),
          do: {to_float(lon), to_float(lat)}

    case located do
      [] ->
        nil

      points ->
        {lons, lats} = Enum.unzip(points)

        {{Enum.min(lons), Enum.min(lats)}, {Enum.max(lons), Enum.max(lats)}}
    end
  end

  defp display_stop(stop) do
    %{
      id: to_string(stop.id),
      stop_id: stop.stop_id,
      name: stop.name,
      desc: stop.desc,
      code: stop.code,
      point: display_point(stop.point),
      location_type: stop.location_type,
      parent_station: stop.parent_station,
      # The model says `served?` because Elixir asks a question; JSON asks for a
      # name. Left as-is it reaches the hook as the key `"served?"`, and the
      # hook's `stop.served` is then undefined for every stop — which reads as
      # served, so an unserved stop draws as a served one.
      served: stop.served?,
      pattern_ids: Enum.map(stop.pattern_ids, &to_string/1)
    }
  end

  defp display_line(line, tolerance_m) do
    %{
      pattern_id: to_string(line.pattern_id),
      route_id: line.route_id,
      direction_id: line.direction_id,
      headsign: line.headsign,
      source: line.source,
      points: line.points |> StopPlacement.simplify(tolerance_m) |> Enum.map(&display_point/1)
    }
  end

  defp display_point(nil), do: nil
  defp display_point({lon, lat}), do: [lon, lat]

  defp display_bounds(nil), do: nil

  defp display_bounds({south_west, north_east}),
    do: [display_point(south_west), display_point(north_east)]

  defp point(nil, _lon), do: nil
  defp point(_lat, nil), do: nil
  defp point(lat, lon), do: {to_float(lon), to_float(lat)}

  defp to_float(%Decimal{} = value), do: Decimal.to_float(value)
  defp to_float(value) when is_float(value), do: value
  defp to_float(value) when is_integer(value), do: value * 1.0
end
