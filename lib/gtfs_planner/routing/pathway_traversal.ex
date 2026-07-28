defmodule GtfsPlanner.Routing.PathwayTraversal do
  @moduledoc """
  Prices one named pathway by planning across a one-edge graph.
  Replaces TraversalCalculator with OTP-faithful timing.
  """

  alias GtfsPlanner.Routing.FeedAdapter

  @spec traverse(map(), map(), map(), [map()]) ::
          {:ok, %{time_seconds: float(), distance_meters: float() | nil}} | {:error, term()}
  def traverse(pathway, from_stop, to_stop, levels) do
    stop_rows = FeedAdapter.stop_rows([from_stop, to_stop])
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
      distance =
        if itinerary.distance_meters == 0.0 and pathway.pathway_mode == 5 do
          nil
        else
          itinerary.distance_meters
        end

      {:ok, %{time_seconds: itinerary.duration_seconds * 1.0, distance_meters: distance}}
    end
  end
end
