defmodule GtfsPlanner.Routing.PathwayTraversal do
  @moduledoc """
  Prices one named pathway by planning across a one-edge graph.
  Replaces TraversalCalculator with OTP-faithful timing.

  The router keeps only stops that have coordinates, and it measures a pathway
  that records no length between its two stops. A point drawn on a floorplan
  has no coordinates until the floorplan is aligned. When either stop has
  none, both stand at one shared point for pricing: the router keeps them and
  can take a result only from what the pathway records, which is its length,
  traversal time and stair count. A distance or time the pathway does not
  record is returned as `nil`, never as a number taken from that point.
  """

  alias GtfsPlanner.Routing.FeedAdapter

  @spec traverse(map(), map(), map(), [map()]) ::
          {:ok, %{time_seconds: float() | nil, distance_meters: float() | nil}}
          | {:error, term()}
  def traverse(pathway, from_stop, to_stop, levels) do
    positioned? = FeedAdapter.located?(from_stop) and FeedAdapter.located?(to_stop)
    stop_rows = FeedAdapter.stop_rows([from_stop, to_stop])
    stop_rows = if positioned?, do: stop_rows, else: Enum.map(stop_rows, &at_shared_point/1)
    pathway_rows = FeedAdapter.pathway_rows([pathway])
    level_rows = FeedAdapter.level_rows(levels)

    from_id = from_stop.stop_id
    to_id = to_stop.stop_id

    with {:ok, feed, _load_diags} <-
           PathwaysRouter.load(stops: stop_rows, pathways: pathway_rows, levels: level_rows),
         {:ok, graph, _build_diags} <- PathwaysRouter.build(feed),
         {:ok, itinerary} <-
           PathwaysRouter.plan(graph,
             from: from_id,
             to: to_id,
             preferences: PathwaysRouter.Preferences.default()
           ) do
      # An elevator has no walked distance. Between stops without positions a
      # zero means the pathway records nothing to take the value from.
      distance =
        if itinerary.distance_meters == 0.0 and (pathway.pathway_mode == 5 or not positioned?) do
          nil
        else
          itinerary.distance_meters
        end

      time = itinerary.duration_seconds * 1.0
      time = if time == 0.0 and not positioned?, do: nil, else: time

      {:ok, %{time_seconds: time, distance_meters: distance}}
    end
  end

  # Where the point is does not matter, only that both stops share it.
  defp at_shared_point(row), do: %{row | stop_lat: 0.0, stop_lon: 0.0}
end
