defmodule GtfsPlanner.Gtfs.MapLineFiles do
  @moduledoc """
  Reading the path files a map line is drawn from.

  `parse/2` is the single door for an uploaded map file (CR-8): the file name
  picks the format, the bytes are read once and never stored, and the answer is
  either the lines the file offers or the one problem that explains why it
  offers none. Every file problem is a plain atom so the upload panel can give
  each one its own message (AC-22).

  `encode/2` is its counterpart for a download: `GtfsPlanner.Gtfs.Alignments.line_file/4`
  owns the pieces and stops, and `encode/2` writes them as a GeoJSON
  `FeatureCollection` or a plain `kml` document (AC-27).

  The XML formats (`.kml`, `.kmz`, `.gpx`) are read with a SAX pass that
  disallows entities and external entities, so an entity-expanding document is
  rejected as unreadable instead of expanding, and a `.kmz` is inflated in
  bounded chunks that stop at 20 MB.
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

  # A KMZ entry is untrusted, so its inflate reads the compressed bytes in
  # chunks and stops once this much has come out of it. A chunk is 16 KiB, so
  # the running total is checked against every chunk's output before it is kept:
  # the overshoot a high-ratio entry could otherwise make is bounded by the
  # expansion of a single chunk rather than by the entry's claimed size.
  @max_inflate_bytes 20 * 1024 * 1024
  @inflate_chunk_bytes 16 * 1024

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
      message);
    * `:network_link` — the document only links to a network resource;
    * `:too_large` — a KMZ entry inflated past #{@max_inflate_bytes} bytes.

  A `LineString` is one line. A `MultiLineString` becomes one line per run of
  parts whose ends meet within #{@join_tolerance_m} m, and `joined_from` counts
  the parts each line came from.

  KML and GPX read the same way: every `LineString`/`gx:Track`/`trk`/`rte`
  piece is a part, pieces that meet end to end join into one line named after
  the first `Placemark`/`trk`/`rte` that named one, and any altitude a position
  carries is dropped.
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

  defp read(extension, bytes) when extension in [".kml", ".gpx"],
    do: xml_lines(bytes)

  defp read(".kmz", bytes) do
    with {:ok, entry} <- first_kml_entry(bytes),
         {:ok, document} <- entry_bytes(bytes, entry) do
      xml_lines(document)
    end
  end

  defp read(_extension, _bytes), do: {:error, :unsupported}

  # --- Downloaded map lines --------------------------------------------
  #
  # `encode/2` is the single door for a downloaded map line, the counterpart of
  # `parse/2`: `Alignments.line_file/4` owns the pieces and stops, and only the
  # document shapes are here.

  @doc """
  Encodes an `Alignments.line_file/4` model as a downloadable document.

  Answers `{:ok, document}` — GeoJSON is one `FeatureCollection` holding each
  pattern's line (a `LineString` of one piece, a `MultiLineString` of several,
  never a line drawn across a gap) and a `Point` per stop; KML is a plain `kml`
  document with one `Folder` per pattern, a `Placemark` per line piece and a
  `Placemark` per stop, with every name XML escaped. Coordinates are written
  in `[lon, lat]` order (INV-1). An unknown format answers
  `{:error, :unsupported}`.
  """
  @spec encode(:geojson | :kml, map()) :: {:ok, binary()} | {:error, :unsupported}
  def encode(:geojson, file), do: {:ok, Jason.encode!(geojson(file))}
  def encode(:kml, file), do: {:ok, IO.iodata_to_binary(kml(file))}
  def encode(_format, _file), do: {:error, :unsupported}

  defp geojson(%{name: route, patterns: patterns}) do
    %{
      "type" => "FeatureCollection",
      "features" => Enum.flat_map(patterns, &geojson_pattern(route, &1))
    }
  end

  defp geojson_pattern(route, pattern) do
    line =
      case pattern.pieces do
        [piece] ->
          geometry(%{"type" => "LineString", "coordinates" => piece}, pattern, route)

        pieces when pieces != [] ->
          geometry(%{"type" => "MultiLineString", "coordinates" => pieces}, pattern, route)

        [] ->
          nil
      end

    Enum.reject([line | Enum.map(pattern.stops, &geojson_stop(&1, pattern))], &is_nil/1)
  end

  defp geometry(geometry, pattern, route) do
    %{
      "type" => "Feature",
      "geometry" => geometry,
      "properties" => %{
        "name" => pattern.name,
        "route" => route,
        "route_pattern_id" => pattern.route_pattern_id,
        "direction" => pattern.direction
      }
    }
  end

  defp geojson_stop(stop, pattern) do
    if located?(stop) do
      %{
        "type" => "Feature",
        "geometry" => %{"type" => "Point", "coordinates" => [stop.lon, stop.lat]},
        "properties" => %{
          "name" => stop.name,
          "stop_id" => stop.stop_id,
          "position" => stop.position,
          "route_pattern_id" => pattern.route_pattern_id
        }
      }
    end
  end

  # A visit without coordinates is already a blocked section (R5); it has no
  # point to place in a downloaded file.
  defp located?(%{lon: lon, lat: lat}), do: is_number(lon) and is_number(lat)

  defp kml(%{name: route_name, patterns: patterns}) do
    [
      ~s(<?xml version="1.0" encoding="UTF-8"?>\n),
      ~s(<kml xmlns="http://www.opengis.net/kml/2.2">\n),
      "  <Document>\n",
      element(4, "name", route_name),
      Enum.map(patterns, &kml_folder/1),
      "  </Document>\n",
      "</kml>\n"
    ]
  end

  defp kml_folder(pattern) do
    [
      "    <Folder>\n",
      element(6, "name", pattern.name),
      piece_placemarks(pattern),
      Enum.flat_map(pattern.stops, &kml_stop_placemark/1),
      "    </Folder>\n"
    ]
  end

  defp piece_placemarks(pattern) do
    case pattern.pieces do
      [piece] ->
        [line_placemark(pattern.name, piece)]

      pieces ->
        total = length(pieces)

        pieces
        |> Enum.with_index(1)
        |> Enum.map(fn {piece, index} ->
          line_placemark("#{pattern.name} (#{index}/#{total})", piece)
        end)
    end
  end

  defp line_placemark(name, piece) do
    [
      "      <Placemark>\n",
      element(8, "name", name),
      "        <LineString>\n",
      "          <tessellate>1</tessellate>\n",
      "          <coordinates>",
      coordinates(piece),
      "</coordinates>\n",
      "        </LineString>\n",
      "      </Placemark>\n"
    ]
  end

  defp kml_stop_placemark(stop) do
    if located?(stop) do
      [
        "      <Placemark>\n",
        element(8, "name", stop.name),
        "        <Point>\n",
        "          <coordinates>",
        coordinates([[stop.lon, stop.lat]]),
        "</coordinates>\n",
        "        </Point>\n",
        "      </Placemark>\n"
      ]
    else
      []
    end
  end

  defp element(indent, name, text) do
    [String.duplicate(" ", indent), "<", name, ">", escape_xml(text), "</", name, ">\n"]
  end

  defp coordinates(piece) do
    Enum.map_join(piece, " ", fn [lon, lat] ->
      [format_float(lon), ",", format_float(lat)]
    end)
  end

  defp format_float(value) when is_integer(value), do: Integer.to_string(value)
  defp format_float(value) when is_float(value), do: Float.to_string(value)

  # Every text node is escaped, so a stop or route name with `&`, `<` or `"`
  # cannot break the document.
  defp escape_xml(text) when is_binary(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end

  defp escape_xml(nil), do: ""

  # --- KML, KMZ and GPX -------------------------------------------------
  #
  # Uploaded XML is untrusted, so it is read with a SAX pass that allows no
  # entities and no external entities: an entity-expanding document fails the
  # parse and answers `{:error, :unreadable}` without expanding anything.

  defp xml_lines(bytes) do
    collector = %{pieces: [], name: nil, text: nil, points: nil, kinds: MapSet.new()}

    case :xmerl_sax_parser.stream(bytes, xml_options(collector)) do
      {:ok, collected, _rest} -> built_xml_lines(collected)
      _other -> {:error, :unreadable}
    end
  end

  defp xml_options(collector) do
    [
      :disallow_entities,
      {:external_entities, :none},
      {:event_fun, fn event, location, state -> xml_event(event, location, state) end},
      {:event_state, collector}
    ]
  end

  # `points` collects the positions of the piece currently open, in reverse,
  # so a piece is built the same way whether it arrives as coordinate text
  # (KML), Track `coord` text or GPX point attributes. A piece is named by the
  # `name` read while its `Placemark`, `trk` or `rte` was open.
  defp xml_event({:startElement, _uri, local, _qualified, attributes}, _location, state),
    do: start_element(local, attributes, state)

  defp xml_event({:characters, _characters}, _location, %{text: nil} = state), do: state

  defp xml_event({:characters, characters}, _location, state),
    do: %{state | text: [characters | state.text]}

  defp xml_event({:endElement, _uri, local, _qualified}, _location, state),
    do: end_element(local, state)

  defp xml_event(_event, _location, state), do: state

  defp start_element(local, attributes, state) do
    case local do
      ~c"Placemark" -> %{state | name: nil, points: nil}
      ~c"trk" -> %{state | name: nil, points: []}
      ~c"rte" -> %{state | name: nil, points: []}
      ~c"LineString" -> %{state | points: []}
      ~c"Track" -> %{state | points: []}
      ~c"trkpt" -> add_attribute_point(state, attributes)
      ~c"rtept" -> add_attribute_point(state, attributes)
      local -> open_element(local, state)
    end
  end

  # The elements that contribute no geometry still record what kind of document
  # this is, so a file with nothing to draw can say why.
  defp open_element(~c"Point", state), do: mark_kind(state, :point)
  defp open_element(~c"Polygon", state), do: mark_kind(state, :area)
  defp open_element(~c"NetworkLink", state), do: mark_kind(state, :network_link)

  defp open_element(local, state) when local in [~c"name", ~c"coordinates", ~c"coord"],
    do: %{state | text: []}

  defp open_element(_local, state), do: state

  defp end_element(~c"name", state), do: %{state | name: text(state.text), text: nil}

  defp end_element(~c"coordinates", state),
    do: add_positions(state, coordinates_positions(text(state.text)))

  defp end_element(~c"coord", state),
    do: add_positions(state, coord_positions(text(state.text)))

  defp end_element(local, state) when local in [~c"LineString", ~c"Track", ~c"trk", ~c"rte"] do
    %{
      state
      | pieces: [%{name: state.name, points: Enum.reverse(state.points)} | state.pieces],
        points: nil
    }
  end

  defp end_element(_local, state), do: state

  # A piece that is not open (a `<Point>`'s coordinates, say) collects nothing.
  defp add_positions(%{points: nil} = state, _positions), do: %{state | text: nil}

  defp add_positions(state, positions),
    do: %{state | points: Enum.reverse(positions) ++ state.points, text: nil}

  defp mark_kind(state, kind), do: %{state | kinds: MapSet.put(state.kinds, kind)}

  # KML lists positions as `lon,lat[,alt]` tuples separated by whitespace, and
  # a Track's `gx:coord` as `lon lat alt`; altitude is dropped.
  defp coordinates_positions(text) do
    text
    |> String.split(~r/\s+/u, trim: true)
    |> Enum.flat_map(fn tuple ->
      case String.split(tuple, ",") do
        [lon, lat | _rest] -> position(lon, lat)
        _other -> []
      end
    end)
  end

  defp coord_positions(text) do
    case String.split(String.trim(text), ~r/\s+/u) do
      [lon, lat | _rest] -> position(lon, lat)
      _other -> []
    end
  end

  defp position(lon, lat) do
    with {lon, ""} <- Float.parse(lon),
         {lat, ""} <- Float.parse(lat) do
      [[Float.round(lon, 6), Float.round(lat, 6)]]
    else
      _other -> []
    end
  end

  # A GPX point arrives as `lat`/`lon` attributes rather than as text, so the
  # axes are swapped back into the longitude-first order every reader uses.
  defp add_attribute_point(state, attributes) do
    case {attribute(attributes, ~c"lon"), attribute(attributes, ~c"lat")} do
      {nil, _lat} -> state
      {_lon, nil} -> state
      {lon, lat} -> %{state | points: position(lon, lat) ++ state.points}
    end
  end

  defp attribute(attributes, name) do
    Enum.find_value(attributes, fn {_uri, _prefix, local, value} ->
      if local == name, do: List.to_string(value)
    end)
  end

  defp text(nil), do: ""

  defp text(parts) do
    parts |> Enum.reverse() |> Enum.join() |> String.trim()
  end

  # Every piece the document offered is joined with the same tolerance the
  # GeoJSON reader uses, and the first name the document gave a piece names the
  # first line.
  defp built_xml_lines(state) do
    pieces = Enum.reverse(state.pieces)

    case line_groups(Enum.map(pieces, & &1.points), Enum.find_value(pieces, & &1.name)) do
      [] -> xml_problem(state)
      lines -> {:ok, lines}
    end
  end

  defp xml_problem(state) do
    cond do
      MapSet.member?(state.kinds, :network_link) -> {:error, :network_link}
      MapSet.member?(state.kinds, :point) -> {:error, :points_only}
      MapSet.member?(state.kinds, :area) -> {:error, :areas_only}
      true -> {:error, :empty}
    end
  end

  # A KMZ is a zip holding KML; `:zip.list_dir/1` names its entries with the
  # offset and compressed size of each, and the first `.kml` is the document.
  defp first_kml_entry(bytes) do
    case :zip.list_dir(bytes) do
      {:ok, entries} ->
        case Enum.find(entries, &kml_entry?/1) do
          {:zip_file, _name, _info, _comment, offset, comp_size} ->
            {:ok, {offset, comp_size}}

          _other ->
            {:error, :unreadable}
        end

      {:error, _reason} ->
        {:error, :unreadable}
    end
  end

  defp kml_entry?({:zip_file, name, _info, _comment, _offset, _comp_size}) do
    String.ends_with?(List.to_string(name) |> String.downcase(), ".kml")
  end

  defp kml_entry?(_entry), do: false

  defp entry_bytes(bytes, {offset, comp_size}) do
    case local_entry(bytes, offset, comp_size) do
      # A stored entry is already its own output, so its size is the limit.
      {:ok, 0, payload} ->
        if comp_size > @max_inflate_bytes, do: {:error, :too_large}, else: {:ok, payload}

      {:ok, 8, payload} ->
        inflate(payload)

      _other ->
        {:error, :unreadable}
    end
  end

  # The compressed bytes start after the entry's local header, whose name and
  # extra field lengths move the start of the data.
  defp local_entry(bytes, offset, comp_size)
       when is_integer(offset) and is_integer(comp_size) and offset >= 0 and comp_size >= 0 and
              offset + 30 <= byte_size(bytes) do
    case binary_part(bytes, offset, 30) do
      <<"PK\x03\x04", _version::little-16, _flags::little-16, method::little-16, _time::little-16,
        _date::little-16, _crc::little-32, _compressed::little-32, _uncompressed::little-32,
        name_length::little-16, extra_length::little-16>>
      when method in [0, 8] ->
        entry_payload(bytes, offset + 30 + name_length + extra_length, comp_size, method)

      _other ->
        {:error, :unreadable}
    end
  end

  defp local_entry(_bytes, _offset, _comp_size), do: {:error, :unreadable}

  defp entry_payload(bytes, start, comp_size, method) do
    length = min(comp_size, byte_size(bytes) - start)

    if start <= byte_size(bytes) and length >= 0 do
      {:ok, method, binary_part(bytes, start, length)}
    else
      {:error, :unreadable}
    end
  end

  # Inflate reads the compressed bytes a chunk at a time and stops as soon as
  # more than `@max_inflate_bytes` have come out, so a high-ratio entry never
  # costs the memory its size claims.
  defp inflate(compressed) do
    z = :zlib.open()

    try do
      :zlib.inflateInit(z, -15)
      inflate_step(z, compressed, 0, [], 0)
    after
      :zlib.close(z)
    end
  end

  defp inflate_step(z, compressed, offset, chunks, total) do
    cond do
      total > @max_inflate_bytes ->
        {:error, :too_large}

      offset < byte_size(compressed) ->
        chunk =
          binary_part(
            compressed,
            offset,
            min(@inflate_chunk_bytes, byte_size(compressed) - offset)
          )

        case :zlib.safeInflate(z, chunk) do
          {:continue, output} -> keep(z, compressed, offset, chunks, total, output, chunk)
          other -> inflate_done(other, chunks)
        end

      true ->
        drain(z, compressed, offset, chunks, total)
    end
  end

  # Output is only kept once the total it would make is still inside the cap, so
  # the limit is checked before a chunk is appended rather than after it.
  defp keep(z, compressed, offset, chunks, total, output, input) do
    total = add(total, output)

    if total > @max_inflate_bytes do
      {:error, :too_large}
    else
      inflate_step(z, compressed, offset + byte_size(input), [output | chunks], total)
    end
  end

  # Draining the tail is what tells a finished stream from a truncated one:
  # `:continue` means more output is ready, and an empty read once the input is
  # spent means the stream ended mid-way rather than at a real boundary.
  defp drain(z, compressed, offset, chunks, total) do
    case :zlib.safeInflate(z, <<>>) do
      {:continue, output} ->
        if IO.iodata_length(output) == 0 do
          {:error, :unreadable}
        else
          keep(z, compressed, offset, chunks, total, output, <<>>)
        end

      other ->
        inflate_done(other, chunks)
    end
  end

  defp inflate_done({:finished, output}, chunks),
    do: {:ok, IO.iodata_to_binary([output | chunks])}

  defp inflate_done(_other, _chunks), do: {:error, :unreadable}

  defp add(total, output), do: total + IO.iodata_length(output)

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
        join_or_start(points, runs)
    end
  end

  defp add_piece(_piece, runs), do: runs

  defp join_or_start(points, [%{points: _} = current | earlier]) do
    if meets?(List.last(current.points), List.first(points)) do
      [
        %{current | points: current.points ++ points, joined_from: current.joined_from + 1}
        | earlier
      ]
    else
      [%{points: points, joined_from: 1} | [current | earlier]]
    end
  end

  defp join_or_start(points, runs), do: [%{points: points, joined_from: 1} | runs]

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
