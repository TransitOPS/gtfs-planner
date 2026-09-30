defmodule GtfsPlanner.Gtfs.Blocking.Distance do
  @moduledoc """
  Path lengths in kilometres, measured from coordinates alone.

  A trip's distance is the length of the path through its shape points, or —
  for a trip with no shape — through its stop coordinates, so one rule measures
  both and a shapeless trip can be marked estimated. A shape shared by
  many trips is measured once by the caller and the result reused.

  The measure never reads `shape_dist_traveled`. That column is a publisher's
  own cumulative distance: it is absent on many feeds, and it has no equivalent
  for a trip built from its stops, so honouring it would make a trip's distance
  depend on how its feed happened to fill the column rather than on where the
  vehicle went. Walking the coordinates always answers, and answers the same way
  for a shape and for a stop path.

  The module is pure: it reads its arguments and calls no repository, clock,
  file or network. It measures through
  `GtfsPlanner.Gtfs.StationReport2.Helpers.haversine/4`, the same great-circle
  helper the station report and `Blocking.DeadheadTimes` use, so one formula
  serves every distance in blocking.
  """

  alias GtfsPlanner.Gtfs.StationReport2.Helpers

  @type point :: {lat :: float(), lon :: float()}

  @metres_per_km 1000

  @doc """
  Returns the length of the path through `points`, in kilometres.

  Each point is a `{lat, lon}` pair and the points are walked in the order
  given, so the caller orders them by `shape_pt_sequence` or `stop_sequence`.
  Legs are summed in metres and the total is divided by 1000, so the result is
  a measured length rather than a rounded one.

  Fewer than two points have no path, and answer `0.0`.
  """
  @spec path_km([point()]) :: float()
  def path_km(points) when is_list(points) do
    metres =
      points
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.reduce(0.0, fn [{from_lat, from_lon}, {to_lat, to_lon}], sum ->
        sum + Helpers.haversine(from_lat, from_lon, to_lat, to_lon)
      end)

    metres / @metres_per_km
  end
end
