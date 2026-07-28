defmodule GtfsPlanner.Routing do
  @moduledoc """
  Application-owned routing boundary. The only module outside this namespace
  that may reference PathwaysRouter is this one and modules under Routing/.
  """

  alias GtfsPlanner.Routing.{Diagnostic, FeedAdapter, Route, StationGraph}

  @spec build_station_graph(%{
          optional(:station) => GtfsPlanner.Gtfs.Stop.t(),
          child_stops: [GtfsPlanner.Gtfs.Stop.t()],
          pathways: [GtfsPlanner.Gtfs.Pathway.t()],
          levels: [map()]
        }) :: {:ok, StationGraph.t()}
  def build_station_graph(%{child_stops: stops, pathways: pathways, levels: levels} = snapshot) do
    stop_rows = snapshot |> Map.get(:station) |> feed_stops(stops) |> FeedAdapter.stop_rows()
    pathway_rows = FeedAdapter.pathway_rows(pathways)
    level_rows = FeedAdapter.level_rows(levels)

    {:ok, feed, load_diags} =
      PathwaysRouter.load(stops: stop_rows, pathways: pathway_rows, levels: level_rows)

    {:ok, walking_graph, walk_build_diags} = PathwaysRouter.build(feed)

    wheelchair_feed = filter_wheelchair_feed(feed)
    {:ok, wheelchair_graph, _wheelchair_build_diags} = PathwaysRouter.build(wheelchair_feed)

    diagnostics =
      (load_diags ++ walk_build_diags)
      |> Enum.map(&Diagnostic.from_router/1)

    element_ids = extract_element_ids(walking_graph)

    {:ok,
     %StationGraph{
       walking_graph: walking_graph,
       wheelchair_graph: wheelchair_graph,
       diagnostics: diagnostics,
       element_ids: element_ids,
       pathway_count: length(pathways)
     }}
  end

  @spec plan(StationGraph.t(), String.t(), String.t(), keyword()) ::
          {:ok, Route.t()}
          | {:error, :no_path | :same_origin_and_destination | {:unknown_element, String.t()}}
  def plan(%StationGraph{} = station_graph, from, to, opts \\ []) do
    wheelchair? = Keyword.get(opts, :wheelchair, false)

    graph =
      if wheelchair? do
        station_graph.wheelchair_graph
      else
        station_graph.walking_graph
      end

    case PathwaysRouter.plan(graph,
           from: from,
           to: to,
           wheelchair: wheelchair?,
           preferences: PathwaysRouter.Preferences.default()
         ) do
      {:ok, itinerary} -> {:ok, Route.from_itinerary(itinerary)}
      {:error, reason} -> {:error, reason}
    end
  end

  # Station elements may omit coordinates. The loader recovers them from
  # parent_station, so the station row has to be in the feed — without it, its
  # children are dropped from the graph along with every pathway touching them.
  # The station itself is referenced by no pathway, so it lands as an inert vertex.
  defp feed_stops(nil, child_stops), do: child_stops
  defp feed_stops(station, child_stops), do: [station | child_stops]

  defp filter_wheelchair_feed(%PathwaysRouter.Feed{} = feed) do
    filtered_pathways =
      Enum.reject(feed.pathways, fn pw ->
        pw.mode in [:stairs, :escalator]
      end)

    %{feed | pathways: filtered_pathways}
  end

  defp extract_element_ids(%PathwaysRouter.Graph{vertices: vertices}) do
    vertices
    |> Map.keys()
    |> Enum.reduce(MapSet.new(), fn
      {kind, id}, acc when kind in [:stop, :entrance, :pathway_node, :boarding_area] ->
        MapSet.put(acc, id)

      _, acc ->
        acc
    end)
  end
end
