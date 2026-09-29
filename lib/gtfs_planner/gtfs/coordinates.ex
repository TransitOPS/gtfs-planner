defmodule GtfsPlanner.Gtfs.Coordinates do
  @moduledoc """
  Shared helpers for reading and normalizing point coordinates.
  """

  @type point_key :: :x | :y
  @type normalized_point :: %{x: number(), y: number()}

  # Diagram space is width-normalized (see `GtfsPlanner.Gtfs.FloorplanTransform`):
  # the floorplan image's width spans x = 0..100 and its height spans
  # y = 0..100 * h / w, so a portrait image extends past y = 100.
  #
  # The server does not store a floorplan's pixel size, so y is bounded by a
  # ceiling that admits any image up to a 4:1 height-to-width ratio rather than
  # the exact per-level 100 * h / w. Once the pixel size is stored on
  # `stop_levels`, bound y by 100 * h / w for the level being edited instead.
  @max_diagram_x 100
  @max_diagram_y 400

  @spec normalize_point(term()) :: normalized_point() | nil
  def normalize_point(%{} = point) do
    x = point_value(point, :x)
    y = point_value(point, :y)

    if is_number(x) and is_number(y), do: %{x: x / 1, y: y / 1}, else: nil
  end

  def normalize_point(_), do: nil

  @doc """
  Largest x or y a diagram coordinate may take. The lower bound is 0 on both axes.
  """
  @spec max_diagram_coordinate(point_key()) :: pos_integer()
  def max_diagram_coordinate(:x), do: @max_diagram_x
  def max_diagram_coordinate(:y), do: @max_diagram_y

  @spec point_value(map(), point_key()) :: term()
  def point_value(point, key) do
    Map.get(point, key) || Map.get(point, Atom.to_string(key))
  end
end
