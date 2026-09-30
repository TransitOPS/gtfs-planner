defmodule GtfsPlanner.Gtfs.GeoJson do
  @moduledoc """
  Shared reading of the GeoJSON documents GTFS uploads arrive in.

  A GeoJSON file reaches the app either as a binary or as an already-decoded
  map, and its top level may be a `FeatureCollection`, a single `Feature` or a
  bare geometry. `decode/1` and `features/1` resolve both differences once, so
  area and map-line readers only look at geometry types:

    * `decode/1` answers `{:ok, document}` for a JSON binary or a map, and
      `{:error, :unreadable}` for a binary that is not JSON.
    * `features/1` returns the document's features in document order, wrapping
      a bare `Polygon`, `MultiPolygon`, `LineString` or `MultiLineString`
      geometry as one feature with no properties; anything else yields `[]`.
    * `swapped_axes?/1` takes a list of positions and answers whether they look
      latitude-first. GeoJSON lists longitude first, so a latitude beyond ±90
      in the second slot means the pair is reversed, and only a swap that brings
      every latitude back inside ±90 (and every longitude inside ±180) is worth
      offering as a fix (AC-13).
  """

  @geometry_types ["Polygon", "MultiPolygon", "LineString", "MultiLineString"]

  @doc """
  Reads a GeoJSON document from a JSON binary or passes a decoded map through.

  Answers `{:error, :unreadable}` for a binary that is not JSON.
  """
  @spec decode(map() | binary()) :: {:ok, map()} | {:error, :unreadable}
  def decode(input) when is_binary(input) do
    case Jason.decode(input) do
      {:ok, document} -> {:ok, document}
      {:error, _error} -> {:error, :unreadable}
    end
  end

  def decode(input), do: {:ok, input}

  @doc """
  Returns the document's features in document order.

  A `FeatureCollection` yields its `features`, a `Feature` yields itself, and a
  bare `Polygon`, `MultiPolygon`, `LineString` or `MultiLineString` geometry is
  wrapped as one feature with empty properties, so a single-geometry file needs
  no special case. Anything else yields `[]`.
  """
  @spec features(map()) :: [map()]
  def features(%{"type" => "FeatureCollection", "features" => features}) when is_list(features),
    do: features

  def features(%{"type" => "Feature"} = feature), do: [feature]

  def features(%{"type" => type} = geometry) when type in @geometry_types,
    do: [%{"type" => "Feature", "properties" => %{}, "geometry" => geometry}]

  def features(_document), do: []

  @doc """
  Answers whether the given positions look latitude-first.

  A position is `[longitude, latitude]`, so a latitude beyond ±90 in the second
  slot means the pair is reversed; the answer is `true` only when swapping every
  position brings each latitude back inside ±90 (and each longitude inside ±180).
  """
  @spec swapped_axes?([term()]) :: boolean()
  def swapped_axes?(positions) when is_list(positions) do
    Enum.any?(positions, &out_of_range_latitude?/1) and
      Enum.all?(positions, &swapable_position?/1)
  end

  defp out_of_range_latitude?([_lon, lat | _rest]), do: abs(lat) > 90

  defp swapable_position?([lon, lat | _rest]), do: abs(lon) <= 90 and abs(lat) <= 180
end
