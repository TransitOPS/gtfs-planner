defmodule GtfsPlanner.Gtfs.Coordinates do
  @moduledoc """
  Shared helpers for reading and normalizing point coordinates.
  """

  @type point_key :: :x | :y
  @type normalized_point :: %{x: number(), y: number()}

  @spec normalize_point(term()) :: normalized_point() | nil
  def normalize_point(%{} = point) do
    x = point_value(point, :x)
    y = point_value(point, :y)

    if is_number(x) and is_number(y), do: %{x: x / 1, y: y / 1}, else: nil
  end

  def normalize_point(_), do: nil

  @spec point_value(map(), point_key()) :: term()
  def point_value(point, key) do
    Map.get(point, key) || Map.get(point, Atom.to_string(key))
  end
end
