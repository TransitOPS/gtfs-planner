defmodule GtfsPlanner.Reachability.Runner do
  @moduledoc """
  Builds the dual station graph once, plans every battery pair in both modes,
  scores the outcomes, and returns the envelope. Performs no database writes.
  """

  alias GtfsPlanner.Reachability.{Battery, Envelope, Pair, Scoring}
  alias GtfsPlanner.Routing

  @spec run(map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def run(
        %{station: station, child_stops: child_stops, pathways: pathways, levels: levels},
        started_at
      ) do
    snapshot = %{child_stops: child_stops, pathways: pathways, levels: levels}
    pairs = Battery.derive(snapshot)

    {:ok, graph} = Routing.build_station_graph(snapshot)

    results = plan_all(graph, pairs)
    completed_at = DateTime.utc_now()

    topology = %{
      entrance_count: Enum.count(child_stops, &(&1.location_type == 2)),
      platform_count: Enum.count(child_stops, &(&1.location_type == 0)),
      pathway_count: length(pathways),
      level_count: length(levels)
    }

    envelope =
      Envelope.build(%{
        station: station,
        pairs: pairs,
        results: results,
        diagnostics: graph.diagnostics,
        topology: topology,
        started_at: started_at,
        completed_at: completed_at
      })

    {:ok, envelope}
  end

  defp plan_all(graph, pairs) do
    Enum.map(pairs, fn %Pair{} = pair ->
      wheelchair? = pair.mode == :wheelchair

      plan_result =
        Routing.plan(graph, pair.from_stop_id, pair.to_stop_id, wheelchair: wheelchair?)

      outcome = Scoring.pair_outcome(plan_result)

      {route, reason} =
        case plan_result do
          {:ok, route} -> {route, nil}
          {:error, reason} -> {nil, format_reason(reason)}
        end

      %{pair: pair, outcome: outcome, route: route, reason: reason}
    end)
  end

  defp format_reason(:no_path), do: "no_path"
  defp format_reason(:same_origin_and_destination), do: "same_origin_and_destination"
  defp format_reason({:unknown_element, id}), do: "unknown_element: #{id}"
  defp format_reason(other), do: inspect(other)
end
