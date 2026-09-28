defmodule GtfsPlanner.Gtfs.Alignments.Materializer do
  @moduledoc """
  Pure alignment geometry for route-pattern sections.

  Turns visits (stop anchors) and per-section interior points into the rounded
  shape-point list, cumulative metre distances, per-visit distances and the
  export digest consumed by `Alignments.resolve/1` and `materialize_pattern!/4`.

  Wire and storage order is `[lon, lat]` (INV-1). Axis order changes here when
  writing the `shape_pt_lat` / `shape_pt_lon` columns; the Leaflet boundary in
  `alignment_geometry.js` owns the other conversion.
  """

  @earth_radius_m 6_371_008.8

  @type visit :: %{lat: float() | nil, lon: float() | nil}
  @type interior :: [[float()]]
  @type point :: %{
          sequence: non_neg_integer(),
          lat: Decimal.t(),
          lon: Decimal.t(),
          dist: Decimal.t()
        }
  @type blocker :: %{position: pos_integer(), reason: :no_coordinates | :zero_length}

  @doc """
  Builds the materialized point list for `visits` with per-section `interiors`.

  `visits` are `%{lat, lon}` float maps; `sections` holds one interior
  `[lon, lat]` list per consecutive visit pair. Returns the anchor-first point
  list with 6-decimal coordinates and 2-decimal cumulative haversine distances,
  the distance at each visit anchor, and the digest over the point list and
  anchor indices.
  """
  @spec build([visit()], [interior()]) ::
          {:ok, %{points: [point()], visit_distances: [Decimal.t()], digest: String.t()}}
          | {:error, {:blocked, [blocker()]}}
  def build(visits, sections) when is_list(visits) and is_list(sections) do
    case no_coordinate_blocks(visits) do
      [] -> assemble(visits, sections)
      blocked -> {:error, {:blocked, blocked}}
    end
  end

  @doc """
  Sums haversine metres over a `[[lon, lat], ...]` polyline.
  """
  @spec length_m([[float()]]) :: float()
  def length_m(points) when is_list(points) do
    points
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce(0.0, fn [[lon1, lat1], [lon2, lat2]], acc ->
      acc + haversine_m(lat1, lon1, lat2, lon2)
    end)
  end

  defp no_coordinate_blocks(visits) do
    visits
    |> Enum.with_index()
    |> Enum.flat_map(fn {visit, index} ->
      if is_nil(visit[:lat]) or is_nil(visit[:lon]) do
        before_position = index
        after_position = index + 1
        last_position = length(visits) - 1

        [before_position, after_position]
        |> Enum.filter(&(&1 >= 1 and &1 <= last_position))
        |> Enum.map(&%{position: &1, reason: :no_coordinates})
      else
        []
      end
    end)
    |> Enum.sort_by(& &1.position)
  end

  defp assemble(visits, sections) do
    anchors = Enum.map(visits, &round_anchor/1)
    interiors = Enum.map(sections, &round_interiors/1)

    {points, anchor_indices} = lay_points(anchors, interiors)

    dists = cumulative_dists(points)

    case zero_length_blocks(dists, anchor_indices) do
      [] ->
        entries =
          Enum.with_index(Enum.zip(points, dists), fn {{lat_d, lon_d, _lat_f, _lon_f}, dist_f},
                                                      sequence ->
            %{sequence: sequence, lat: lat_d, lon: lon_d, dist: round_dist(dist_f)}
          end)

        visit_distances =
          Enum.map(anchor_indices, fn index ->
            round_dist(Enum.at(dists, index))
          end)

        {:ok,
         %{
           points: entries,
           visit_distances: visit_distances,
           digest: digest(entries, anchor_indices)
         }}

      blocked ->
        {:error, {:blocked, blocked}}
    end
  end

  defp round_anchor(visit) do
    lat_d = visit[:lat] |> Decimal.from_float() |> Decimal.round(6)
    lon_d = visit[:lon] |> Decimal.from_float() |> Decimal.round(6)
    {lat_d, lon_d, Decimal.to_float(lat_d), Decimal.to_float(lon_d)}
  end

  defp round_interiors(interior) do
    Enum.map(interior, fn [lon, lat] ->
      lon_d = lon |> Decimal.from_float() |> Decimal.round(6)
      lat_d = lat |> Decimal.from_float() |> Decimal.round(6)
      {lat_d, lon_d, Decimal.to_float(lat_d), Decimal.to_float(lon_d)}
    end)
  end

  defp lay_points(anchors, interiors) do
    {rev_points, anchor_indices, _} =
      anchors
      |> Enum.with_index()
      |> Enum.reduce({[], [], nil}, fn {anchor, index}, {rev_points, indices, _next} ->
        at = length(anchors) - 1
        kept = [anchor | rev_points]
        anchor_at = length(kept) - 1
        indices = [anchor_at | indices]

        kept =
          if index < at do
            next_anchor = Enum.at(anchors, index + 1)
            section = Enum.at(interiors, index, [])

            section
            |> drop_run_duplicates(hd(kept))
            |> drop_trailing_anchor(next_anchor)
            |> Enum.reduce(kept, fn point, acc -> [point | acc] end)
          else
            kept
          end

        {kept, indices, nil}
      end)

    points = Enum.reverse(rev_points)
    {points, Enum.reverse(anchor_indices)}
  end

  # Consecutive duplicates carry no geometry: each interior survives only
  # when it differs from the previously kept point (the section's anchor
  # for the first interior). Anchors themselves are never dropped.
  defp drop_run_duplicates(section, prev) do
    {result, _} =
      Enum.map_reduce(section, prev, fn point, kept_prev ->
        if same_point?(point, kept_prev), do: {:drop, kept_prev}, else: {{:keep, point}, point}
      end)

    for {:keep, point} <- result, do: point
  end

  # A trailing interior equal to the next anchor would duplicate the anchor
  # that follows it. A repeat with further interiors after it is a genuine
  # destination crossing (a loop out and back), so only the trailing one goes.
  defp drop_trailing_anchor([], _next_anchor), do: []

  defp drop_trailing_anchor(section, next_anchor) do
    if same_point?(List.last(section), next_anchor) do
      :lists.droplast(section)
    else
      section
    end
  end

  defp same_point?({lat_a, lon_a, _, _}, {lat_b, lon_b, _, _}) do
    Decimal.eq?(lat_a, lat_b) and Decimal.eq?(lon_a, lon_b)
  end

  defp cumulative_dists(points) do
    {_prev, dists, _} =
      Enum.reduce(points, {nil, [], 0.0}, fn {_lat_d, _lon_d, lat_f, lon_f}, {prev, acc, cum} ->
        cum =
          case prev do
            nil -> 0.0
            {prev_lat, prev_lon} -> cum + haversine_m(prev_lat, prev_lon, lat_f, lon_f)
          end

        {{lat_f, lon_f}, [cum | acc], cum}
      end)

    Enum.reverse(dists)
  end

  defp zero_length_blocks(dists, anchor_indices) do
    anchor_indices
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {[from, to], position} ->
      if Decimal.eq?(round_dist(Enum.at(dists, from)), round_dist(Enum.at(dists, to))) do
        [%{position: position, reason: :zero_length}]
      else
        []
      end
    end)
  end

  defp round_dist(cum), do: cum |> Decimal.from_float() |> Decimal.round(2)

  defp digest(entries, anchor_indices) do
    lat_lon =
      Enum.map(entries, fn %{lat: lat, lon: lon} ->
        {Decimal.to_string(lat, :normal), Decimal.to_string(lon, :normal)}
      end)

    :crypto.hash(:sha256, :erlang.term_to_binary({lat_lon, anchor_indices}, [:deterministic]))
    |> Base.encode16(case: :lower)
  end

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
end
