defmodule GtfsPlanner.Gtfs.Flex.Geometry do
  @moduledoc """
  Valid, bounded flex-area geometry and its GeoJSON output (R8).

  `flex_areas.geom` is deliberately not an Ecto field, so every geometry value
  crosses this module as a GeoJSON map. This is the only module that issues
  geometry SQL (R8, CR-1): other modules pass a GeoJSON map in and get one back.

  `normalize/1` decodes a GeoJSON binary (or takes an already decoded map),
  accepts a `Feature`, a one-feature `FeatureCollection`, a `Polygon` or a
  `MultiPolygon`, rejects every other shape, rejects more than 5,000 positions,
  answers `:swapped_coordinates` when a `[lat, lon]` pair would be fixed by
  swapping, and returns PostGIS's own verdict for an invalid ring. A valid shape
  comes back as a valid `MultiPolygon` through the R8 output transform
  (`ST_ForcePolygonCCW(ST_ReducePrecision(g, 0.000001))` and then
  `ST_AsGeoJSON`); `ST_AsGeoJSON` never receives a precision argument, because
  rounding there made a real Census boundary invalid.

  `simplify/2` simplifies in the geometry's best metric SRID with a tolerance in
  metres and returns the R8 output of the result, so it also serves a ring that
  `normalize/1` rejected as too large. `export_geojson/1` applies the output
  transform to geometry that is already stored or derived.

  `put_geom/2` and `get_geojson/1` are the storage pair. Both run on the
  caller's connection, so a context can write geometry inside its own
  transaction.
  """

  alias GtfsPlanner.Repo

  @max_vertices 5_000

  # PostGIS's verdict for the shape ($1 is GeoJSON text).
  @validity_sql """
  SELECT valid, reason, ST_X(location), ST_Y(location)
  FROM ST_IsValidDetail(ST_GeomFromGeoJSON($1))
  """

  # R8 output transform for a stored area: always a MultiPolygon.
  @normalize_sql """
  SELECT ST_AsGeoJSON(
           ST_Multi(
             ST_ForcePolygonCCW(ST_ReducePrecision(ST_GeomFromGeoJSON($1), 0.000001))
           )
         )
  """

  # R8 output transform for geometry that is not (re-)stored.
  @export_sql """
  SELECT ST_AsGeoJSON(
           ST_ForcePolygonCCW(ST_ReducePrecision(ST_GeomFromGeoJSON($1), 0.000001))
         )
  """

  # Simplify in the geometry's best metric SRID, then back to 4326. $2 is the
  # tolerance in metres: a tolerance in degrees would depend on latitude and a
  # fixed projected SRID would distort. ST_SimplifyPreserveTopology never returns
  # an invalid shape, so the output transform is safe in the same query.
  @simplify_sql """
  SELECT valid,
         reason,
         ST_X(location),
         ST_Y(location),
         ST_AsGeoJSON(
           ST_ForcePolygonCCW(ST_ReducePrecision(simplified.geometry, 0.000001))
         )
  FROM (
         SELECT ST_Transform(
                  ST_SimplifyPreserveTopology(ST_Transform(g, _ST_BestSRID(g)), $2),
                  4326
                ) AS geometry
         FROM (SELECT ST_GeomFromGeoJSON($1) AS g) AS source
       ) AS simplified,
       LATERAL ST_IsValidDetail(simplified.geometry)
  """

  @put_geom_sql """
  UPDATE flex_areas
  SET geom = ST_Multi(ST_GeomFromGeoJSON($1))
  WHERE id = $2
  """

  @get_geojson_sql """
  SELECT id::text,
         ST_AsGeoJSON(ST_ForcePolygonCCW(ST_ReducePrecision(geom, 0.000001)))
  FROM flex_areas
  WHERE id = ANY($1) AND geom IS NOT NULL
  """

  @doc """
  Normalises a GeoJSON area to a stored-ready MultiPolygon.

  Returns the normalised geometry and the number of submitted positions, or the
  reason the input cannot be stored: `:unreadable` for a binary that is not
  JSON, `:not_polygon` for anything that is not one closed polygon,
  `:too_many_vertices` above 5,000 positions, `:swapped_coordinates` for a
  `[lat, lon]` input whose swap brings every latitude back inside ±90, or
  `{:invalid, reason, [lon, lat]}` with PostGIS's first problem.
  """
  @spec normalize(map() | binary()) ::
          {:ok, %{geojson: map(), vertices: pos_integer()}}
          | {:error,
             :unreadable
             | :not_polygon
             | :too_many_vertices
             | :swapped_coordinates
             | {:invalid, String.t(), [float()]}}
  def normalize(input) do
    with {:ok, document} <- decode(input),
         {:ok, geometry, positions} <- polygon_geometry(document),
         :ok <- validate_vertex_count(positions),
         :ok <- validate_coordinate_order(positions) do
      storeable_geometry(geometry, positions)
    end
  end

  @doc """
  Applies the R8 output transform to a stored or derived geometry.

  The result carries at most six decimals per coordinate. It is not validated;
  callers pass geometry that `normalize/1` or a derivation already checked.
  """
  @spec export_geojson(map()) :: map()
  def export_geojson(geojson) do
    %Postgrex.Result{rows: [[output]]} = Repo.query!(@export_sql, [Jason.encode!(geojson)])

    Jason.decode!(output)
  end

  @doc """
  Simplifies a geometry with a tolerance in metres and returns the R8 output.

  Runs `ST_SimplifyPreserveTopology` in the geometry's best metric SRID, so holes
  and topology survive. The input may be a ring that `normalize/1` rejected as
  over the vertex cap.
  """
  @spec simplify(map(), pos_integer()) :: {:ok, map()} | {:error, term()}
  def simplify(geojson, tolerance_m) do
    %Postgrex.Result{rows: [[valid, reason, lon, lat, output]]} =
      Repo.query!(@simplify_sql, [Jason.encode!(geojson), tolerance_m])

    if valid do
      {:ok, Jason.decode!(output)}
    else
      {:error, {:invalid, reason, [lon, lat]}}
    end
  end

  @doc """
  Writes one area's geometry, replacing whatever was stored.

  `{:error, :not_found}` means no area with that id exists; the caller is then
  inside its own transaction and can decide what to do about it.
  """
  @spec put_geom(Ecto.UUID.t(), map()) :: :ok | {:error, :not_found}
  def put_geom(area_id, geojson) do
    %Postgrex.Result{num_rows: num_rows} =
      Repo.query!(@put_geom_sql, [Jason.encode!(geojson), Ecto.UUID.dump!(area_id)])

    if num_rows == 1, do: :ok, else: {:error, :not_found}
  end

  @doc """
  Reads stored geometry for the given area ids, keyed by id.

  Areas without geometry (`:route_distance` areas) and unknown ids are absent
  from the result.
  """
  @spec get_geojson([Ecto.UUID.t()]) :: %{Ecto.UUID.t() => map()}
  def get_geojson([]), do: %{}

  def get_geojson(area_ids) when is_list(area_ids) do
    ids = Enum.map(area_ids, &Ecto.UUID.dump!/1)
    %Postgrex.Result{rows: rows} = Repo.query!(@get_geojson_sql, [ids])

    Map.new(rows, fn [id, geojson] -> {id, Jason.decode!(geojson)} end)
  end

  defp decode(input) when is_binary(input) do
    case Jason.decode(input) do
      {:ok, document} -> {:ok, document}
      {:error, _error} -> {:error, :unreadable}
    end
  end

  defp decode(input), do: {:ok, input}

  defp polygon_geometry(%{"type" => "Feature", "geometry" => geometry}),
    do: polygon_geometry(geometry)

  defp polygon_geometry(%{"type" => "FeatureCollection", "features" => [feature]}),
    do: polygon_geometry(feature)

  defp polygon_geometry(%{"type" => "Polygon", "coordinates" => rings}) when is_list(rings) do
    case rings_positions(rings) do
      {:ok, [_ | _] = positions} ->
        {:ok, %{"type" => "Polygon", "coordinates" => rings}, positions}

      _empty_or_error ->
        {:error, :not_polygon}
    end
  end

  defp polygon_geometry(%{"type" => "MultiPolygon", "coordinates" => polygons})
       when is_list(polygons) do
    case polygons_positions(polygons) do
      {:ok, [_ | _] = positions} ->
        {:ok, %{"type" => "MultiPolygon", "coordinates" => polygons}, positions}

      _empty_or_error ->
        {:error, :not_polygon}
    end
  end

  defp polygon_geometry(_document), do: {:error, :not_polygon}

  defp rings_positions(rings) do
    rings
    |> Enum.reduce_while([], fn ring, acc ->
      case ring_positions(ring) do
        {:ok, positions} -> {:cont, [positions | acc]}
        :error -> {:halt, :error}
      end
    end)
    |> positions_result()
  end

  defp polygons_positions(polygons) do
    polygons
    |> Enum.reduce_while([], fn polygon, acc ->
      case rings_positions(polygon) do
        {:ok, [_ | _] = positions} -> {:cont, [positions | acc]}
        _error -> {:halt, :error}
      end
    end)
    |> positions_result()
  end

  defp positions_result(:error), do: :error

  defp positions_result(groups), do: {:ok, groups |> Enum.reverse() |> Enum.concat()}

  defp ring_positions(ring) when is_list(ring) and ring != [] do
    if Enum.all?(ring, &position?/1), do: {:ok, ring}, else: :error
  end

  defp ring_positions(_ring), do: :error

  defp position?([lon, lat | _rest]) when is_number(lon) and is_number(lat), do: true
  defp position?(_position), do: false

  defp validate_vertex_count(positions) when length(positions) > @max_vertices,
    do: {:error, :too_many_vertices}

  defp validate_vertex_count(_positions), do: :ok

  # GeoJSON lists longitude first. A latitude beyond ±90 in the second slot means
  # the pair is reversed, but only a swap that brings every latitude back inside
  # ±90 (and every longitude inside ±180) is a fix worth offering (AC-13).
  defp validate_coordinate_order(positions) do
    if Enum.any?(positions, &out_of_range_latitude?/1) and
         Enum.all?(positions, &swapable_position?/1) do
      {:error, :swapped_coordinates}
    else
      :ok
    end
  end

  defp out_of_range_latitude?([_lon, lat | _rest]), do: abs(lat) > 90

  defp swapable_position?([lon, lat | _rest]), do: abs(lon) <= 90 and abs(lat) <= 180

  defp storeable_geometry(geometry, positions) do
    encoded = Jason.encode!(geometry)

    # The validity query runs first: ST_ReducePrecision raises on an invalid shape
    # instead of returning it, so it must never see one.
    %Postgrex.Result{rows: [[valid, reason, lon, lat]]} = Repo.query!(@validity_sql, [encoded])

    if valid do
      %Postgrex.Result{rows: [[geojson]]} = Repo.query!(@normalize_sql, [encoded])

      {:ok, %{geojson: Jason.decode!(geojson), vertices: length(positions)}}
    else
      {:error, {:invalid, reason, invalid_location(lon, lat, positions)}}
    end
  end

  # Some problems have no reported location; fall back to the first submitted
  # position so the editor always has a point to mark.
  defp invalid_location(nil, nil, [[lon, lat | _rest] | _positions]), do: [lon, lat]
  defp invalid_location(lon, lat, _positions), do: [lon, lat]
end
