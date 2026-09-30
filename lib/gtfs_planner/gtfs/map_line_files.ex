defmodule GtfsPlanner.Gtfs.MapLineFiles do
  @moduledoc """
  Reading the path files a map line is drawn from.

  `parse/2` is the single door for an uploaded map file (CR-8): the file name
  picks the format, the bytes are read once and never stored, and the answer is
  either the lines the file offers or the one problem that explains why it
  offers none. Every file problem is a plain atom so the upload panel can give
  each one its own message (AC-22).

  This step covers GeoJSON (`.geojson`, `.json`); `.kml`, `.kmz` and `.gpx`
  arrive with the XML reader.
  """

  alias GtfsPlanner.Gtfs.GeoJson

  @type line :: %{name: String.t() | nil, points: [[float()]], joined_from: pos_integer()}

  @type error ::
          :unsupported
          | :network_link
          | :points_only
          | :areas_only
          | :swapped
          | :too_large
          | :empty
          | :unreadable

  # Two pieces of one file's line join when their nearest ends are this close,
  # the same tolerance the client's `joinPieces` uses.
  @join_tolerance_m 50.0
  @earth_radius_m 6_371_008.8

  @doc """
  Reads an uploaded map file into the lines it offers.

  `file_name` selects the format and `bytes` are read without ever being
  stored. Answers `{:ok, lines}` — one entry per line, named from the file and
  carrying the points to draw — or `{:error, reason}`:

    * `:unreadable` — the bytes are not the format the extension claims;
    * `:unsupported` — the extension is not a map file format;
    * `:empty` — the document carries no features, or none with drawable lines;
    * `:points_only` / `:areas_only` — the document holds only points or only
      polygons;
    * `:swapped` — the positions look latitude-first (AC-22's swapped-axes
      message).

  A `LineString` is one line. A `MultiLineString` becomes one line per run of
  parts whose ends meet within #{@join_tolerance_m} m, and `joined_from` counts
  the parts each line came from.
  """
  @spec parse(binary(), String.t()) :: {:ok, [line()]} | {:error, error()}
  def parse(bytes, file_name) when is_binary(bytes) and is_binary(file_name) do
    file_name
    |> Path.extname()
    |> String.downcase()
    |> read(bytes)
  end

  defp read(extension, bytes) when extension in [".geojson", ".json"],
    do: geojson_lines(bytes)

  defp read(_extension, _bytes), do: {:error, :unsupported}

  defp geojson_lines(bytes) do
    with {:ok, document} <- GeoJson.decode(bytes) do
      features = GeoJson.features(document)

      cond do
        features == [] -> {:error, :empty}
        swapped?(features) -> {:error, :swapped}
        true -> built_lines(features)
      end
    end
  end

  # A file can be readable and hold nothing to draw, so reading the lines
  # decides whether the document has any, and the other geometry types explain
  # a file that has none.
  defp built_lines(features) do
    case lines_from(features) do
      [] -> problem_without_lines(features)
      lines -> {:ok, lines}
    end
  end

  defp problem_without_lines(features) do
    cond do
      Enum.any?(features, &point_geometry?/1) -> {:error, :points_only}
      Enum.any?(features, &area_geometry?/1) -> {:error, :areas_only}
      true -> {:error, :empty}
    end
  end

  defp lines_from(features), do: Enum.flat_map(features, &feature_lines/1)

  defp feature_lines(
         %{"geometry" => %{"type" => "LineString", "coordinates" => positions}} = feature
       ),
       do: line_groups([positions], feature_name(feature))

  defp feature_lines(
         %{"geometry" => %{"type" => "MultiLineString", "coordinates" => pieces}} = feature
       )
       when is_list(pieces) do
    line_groups(pieces, feature_name(feature))
  end

  defp feature_lines(_feature), do: []

  # A bare geometry arrives wrapped with empty properties, so a file that has
  # one offers a line with no name rather than an invented one.
  defp feature_name(%{"properties" => %{"name" => name}}) when is_binary(name), do: name
  defp feature_name(_feature), do: nil

  # Feature parts, in file order, folded into runs whose ends meet. Parts that
  # never meet start their own run, so a file's parts come back as the lines
  # they really form.
  defp line_groups(pieces, name) do
    pieces
    |> Enum.reduce([], &add_piece/2)
    |> Enum.reverse()
    |> name_runs(name)
  end

  defp add_piece(piece, runs) when is_list(piece) do
    case drawable(piece) do
      # A part with no usable position is not a line, and a part with one
      # position cannot be drawn, so neither joins or starts a run.
      points when length(points) < 2 ->
        runs

      points ->
        case runs do
          [%{points: _} = current | earlier] ->
            if meets?(List.last(current.points), List.first(points)) do
              [
                %{
                  current
                  | points: current.points ++ points,
                    joined_from: current.joined_from + 1
                }
                | earlier
              ]
            else
              [%{points: points, joined_from: 1} | runs]
            end

          _ ->
            [%{points: points, joined_from: 1} | runs]
        end
    end
  end

  defp add_piece(_piece, runs), do: runs

  defp name_runs(runs, name) do
    case runs do
      [] ->
        []

      [%{points: points, joined_from: joined} | rest] ->
        [
          %{name: name, points: points, joined_from: joined}
          | Enum.map(rest, &Map.put(&1, :name, nil))
        ]
    end
  end

  # GeoJSON lists longitude first; `GeoJson.swapped_axes?/1` owns that rule.
  defp swapped?(features) do
    features
    |> Enum.flat_map(&feature_positions/1)
    |> GeoJson.swapped_axes?()
  end

  defp point_geometry?(%{"geometry" => %{"type" => type}}) when type in ["Point", "MultiPoint"],
    do: true

  defp point_geometry?(_feature), do: false

  defp area_geometry?(%{"geometry" => %{"type" => type}})
       when type in ["Polygon", "MultiPolygon"],
       do: true

  defp area_geometry?(_feature), do: false

  defp drawable(positions) do
    positions
    |> Enum.filter(&position?/1)
    |> Enum.map(fn [lon, lat | _rest] ->
      [Float.round(lon / 1.0, 6), Float.round(lat / 1.0, 6)]
    end)
  end

  defp position?([lon, lat | _rest]) when is_number(lon) and is_number(lat), do: true
  defp position?(_position), do: false

  defp meets?(nil, _next), do: false
  defp meets?(_last, nil), do: false

  defp meets?([lon1, lat1], [lon2, lat2]),
    do: haversine_m(lat1, lon1, lat2, lon2) <= @join_tolerance_m

  defp haversine_m(lat1, lon1, lat2, lon2) do
    dlat = :math.pi() * (lat2 - lat1) / 180.0
    dlon = :math.pi() * (lon2 - lon1) / 180.0
    rad1 = :math.pi() * lat1 / 180.0
    rad2 = :math.pi() * lat2 / 180.0

    a =
      :math.pow(:math.sin(dlat / 2.0), 2) +
        :math.cos(rad1) * :math.cos(rad2) * :math.pow(:math.sin(dlon / 2.0), 2)

    2.0 * @earth_radius_m * :math.asin(:math.sqrt(a))
  end

  defp feature_positions(%{"geometry" => %{"coordinates" => coordinates}}),
    do: positions(coordinates)

  defp feature_positions(_feature), do: []

  # Coordinates nest one level per geometry (a part is a list of positions), so
  # positions are collected at any depth and anything that is not one is
  # skipped rather than mistaken for a coordinate.
  defp positions([lon, lat | _rest]) when is_number(lon) and is_number(lat), do: [[lon, lat]]

  defp positions(nested) when is_list(nested), do: Enum.flat_map(nested, &positions/1)

  defp positions(_other), do: []
end
