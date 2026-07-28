defmodule GtfsPlanner.Reachability.EnvelopeTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Reachability.{Envelope, Pair}
  alias GtfsPlanner.Routing.{Diagnostic, Route}

  defp pair(index, kind, mode, from, to) do
    %Pair{
      index: index,
      kind: kind,
      mode: mode,
      from_stop_id: from,
      from_stop_name: from,
      to_stop_id: to,
      to_stop_name: to
    }
  end

  defp route do
    %Route{
      duration_seconds: 60,
      distance_meters: 80.0,
      generalized_cost: 120,
      step_count: 2,
      steps: []
    }
  end

  describe "build/1" do
    test "produces a JSON-safe envelope with correct structure" do
      started_at = ~U[2026-07-27 18:00:00.000000Z]
      completed_at = ~U[2026-07-27 18:00:01.214000Z]

      p0 = pair(0, :entry, :walking, "ENT_A", "PLAT_1")
      p1 = pair(1, :entry, :wheelchair, "ENT_A", "PLAT_1")

      results = [
        %{pair: p0, outcome: :reachable, route: route(), reason: nil},
        %{pair: p1, outcome: :unreachable, route: nil, reason: "no_path"}
      ]

      diag = %Diagnostic{
        severity: :warning,
        code: :missing_endpoint,
        entity_type: "pathway",
        entity_id: "PW_17",
        message: "Pathway references a missing endpoint"
      }

      envelope =
        Envelope.build(%{
          station: %{stop_id: "PHL_30ST", stop_name: "30th Street Station"},
          pairs: [p0, p1],
          results: results,
          diagnostics: [diag],
          topology: %{entrance_count: 1, platform_count: 1, pathway_count: 2, level_count: 1},
          started_at: started_at,
          completed_at: completed_at
        })

      assert envelope["engine"] == "pathways_router"
      assert envelope["engine_ref"] == "c34f9e84b7742de231652cb9bb3b3ba3cc8e8fcd"
      assert envelope["result_schema_version"] == 1
      assert envelope["preferences"] == "default"
      assert envelope["metadata"]["station_stop_id"] == "PHL_30ST"
      assert envelope["outcome"] == "warning"
      assert envelope["duration_ms"] == 1214

      assert {:ok, _json} = Jason.encode(envelope)
    end

    test "pairs contain no steps key" do
      started_at = ~U[2026-07-27 18:00:00.000000Z]
      completed_at = ~U[2026-07-27 18:00:00.100000Z]

      p0 = pair(0, :entry, :walking, "A", "B")

      results = [%{pair: p0, outcome: :reachable, route: route(), reason: nil}]

      envelope =
        Envelope.build(%{
          station: %{stop_id: "S", stop_name: "Station"},
          pairs: [p0],
          results: results,
          diagnostics: [],
          topology: %{entrance_count: 1, platform_count: 1, pathway_count: 1, level_count: 0},
          started_at: started_at,
          completed_at: completed_at
        })

      [pair_entry] = envelope["pairs"]
      refute Map.has_key?(pair_entry, "steps")
      assert pair_entry["step_count"] == 2
    end

    test "round-trips through Jason encode/decode unchanged" do
      started_at = ~U[2026-07-27 18:00:00.000000Z]
      completed_at = ~U[2026-07-27 18:00:00.500000Z]

      p0 = pair(0, :entry, :walking, "A", "B")
      results = [%{pair: p0, outcome: :reachable, route: route(), reason: nil}]

      envelope =
        Envelope.build(%{
          station: %{stop_id: "S", stop_name: "Station"},
          pairs: [p0],
          results: results,
          diagnostics: [],
          topology: %{entrance_count: 1, platform_count: 1, pathway_count: 1, level_count: 0},
          started_at: started_at,
          completed_at: completed_at
        })

      json = Jason.encode!(envelope)
      decoded = Jason.decode!(json)

      assert decoded == envelope
    end
  end
end
