defmodule GtfsPlanner.Reachability.Envelope do
  @moduledoc """
  Builds the versioned, JSON-safe result payload stored in result_json.
  Schema version 1.
  """

  alias GtfsPlanner.Reachability.{Pair, Scoring}
  alias GtfsPlanner.Routing.Diagnostic

  @engine "pathways_router"
  @engine_ref "c34f9e84b7742de231652cb9bb3b3ba3cc8e8fcd"
  @schema_version 1

  @spec build(%{
          station: map(),
          pairs: [Pair.t()],
          results: [
            %{pair: Pair.t(), outcome: atom(), route: map() | nil, reason: String.t() | nil}
          ],
          diagnostics: [Diagnostic.t()],
          topology: map(),
          started_at: DateTime.t(),
          completed_at: DateTime.t()
        }) :: map()
  def build(%{
        station: station,
        pairs: _pairs,
        results: results,
        diagnostics: diagnostics,
        topology: topology,
        started_at: started_at,
        completed_at: completed_at
      }) do
    outcome = Scoring.run_outcome(Enum.map(results, &%{mode: &1.pair.mode, outcome: &1.outcome}))
    counts = Scoring.counts(Enum.map(results, &%{mode: &1.pair.mode, outcome: &1.outcome}))

    totals = build_totals(results, counts)
    duration_ms = DateTime.diff(completed_at, started_at, :millisecond)

    %{
      "engine" => @engine,
      "engine_ref" => @engine_ref,
      "result_schema_version" => @schema_version,
      "preferences" => "default",
      "metadata" => %{"station_stop_id" => station.stop_id},
      "outcome" => Atom.to_string(outcome),
      "station" => %{"stop_id" => station.stop_id, "stop_name" => station.stop_name},
      "topology" => %{
        "entrance_count" => topology.entrance_count,
        "platform_count" => topology.platform_count,
        "pathway_count" => topology.pathway_count,
        "level_count" => topology.level_count
      },
      "totals" => totals,
      "diagnostics" => Enum.map(diagnostics, &Diagnostic.to_map/1),
      "pairs" => Enum.map(results, &pair_entry/1),
      "started_at" => DateTime.to_iso8601(started_at),
      "completed_at" => DateTime.to_iso8601(completed_at),
      "duration_ms" => duration_ms
    }
  end

  defp build_totals(results, counts) do
    pair_count = length(results)

    walking_reachable =
      Enum.count(results, &(&1.pair.mode == :walking and &1.outcome == :reachable))

    walking_unreachable =
      Enum.count(results, &(&1.pair.mode == :walking and &1.outcome == :unreachable))

    wheelchair_reachable =
      Enum.count(results, &(&1.pair.mode == :wheelchair and &1.outcome == :reachable))

    wheelchair_unreachable =
      Enum.count(results, &(&1.pair.mode == :wheelchair and &1.outcome == :unreachable))

    %{
      "pair_count" => pair_count,
      "reachable" => counts.infos,
      "unreachable" => walking_unreachable + wheelchair_unreachable,
      "invalid" => Enum.count(results, &(&1.outcome == :invalid)),
      "walking_reachable" => walking_reachable,
      "walking_unreachable" => walking_unreachable,
      "wheelchair_reachable" => wheelchair_reachable,
      "wheelchair_unreachable" => wheelchair_unreachable
    }
  end

  defp pair_entry(%{pair: pair, outcome: outcome, route: route, reason: reason}) do
    base = %{
      "index" => pair.index,
      "kind" => Atom.to_string(pair.kind),
      "mode" => Atom.to_string(pair.mode),
      "from_stop_id" => pair.from_stop_id,
      "from_stop_name" => pair.from_stop_name,
      "to_stop_id" => pair.to_stop_id,
      "to_stop_name" => pair.to_stop_name,
      "outcome" => Atom.to_string(outcome),
      "reason" => reason
    }

    case route do
      nil ->
        Map.merge(base, %{
          "duration_seconds" => nil,
          "distance_meters" => nil,
          "generalized_cost" => nil,
          "step_count" => nil
        })

      route ->
        Map.merge(base, %{
          "duration_seconds" => route.duration_seconds,
          "distance_meters" => route.distance_meters,
          "generalized_cost" => route.generalized_cost,
          "step_count" => route.step_count
        })
    end
  end
end
