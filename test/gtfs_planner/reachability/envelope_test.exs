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
      assert envelope["engine_ref"] == "f1bf1b58e29307d410742af95dfde18111bcb07a"
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

    test "omits provenance when the caller supplies none and stays readable" do
      started_at = ~U[2026-07-27 18:00:00.000000Z]
      p0 = pair(0, :entry, :walking, "A", "B")

      envelope =
        Envelope.build(%{
          station: %{stop_id: "S", stop_name: "Station"},
          pairs: [p0],
          results: [%{pair: p0, outcome: :reachable, route: route(), reason: nil}],
          diagnostics: [],
          topology: %{entrance_count: 1, platform_count: 1, pathway_count: 1, level_count: 0},
          started_at: started_at,
          completed_at: started_at,
          input_provenance: nil
        })

      refute Map.has_key?(envelope, "input_provenance")
      assert envelope["result_schema_version"] == 1
      assert envelope["metadata"]["station_stop_id"] == "S"
    end

    test "carries the supplied provenance unchanged alongside the existing keys" do
      started_at = ~U[2026-07-27 18:00:00.000000Z]
      p0 = pair(0, :entry, :walking, "A", "B")

      provenance = Envelope.input_provenance(snapshot())

      envelope =
        Envelope.build(%{
          station: snapshot().station,
          pairs: [p0],
          results: [%{pair: p0, outcome: :reachable, route: route(), reason: nil}],
          diagnostics: [],
          topology: %{entrance_count: 1, platform_count: 1, pathway_count: 1, level_count: 1},
          started_at: started_at,
          completed_at: started_at,
          input_provenance: provenance
        })

      assert envelope["input_provenance"] == provenance
      assert envelope["result_schema_version"] == 1
      assert envelope["engine"] == "pathways_router"
      assert Jason.decode!(Jason.encode!(envelope)) == envelope
    end
  end

  describe "input_provenance/1" do
    test "records a versioned lowercase sha256 digest and honest closure evaluation" do
      provenance = Envelope.input_provenance(snapshot())

      assert provenance["version"] == 1
      assert provenance["closure_evaluation"] == "not_evaluated"
      assert provenance["digest"] =~ ~r/\A[0-9a-f]{64}\z/
    end

    test "row order and recorded decimal scale do not change the digest" do
      shuffled = %{
        snapshot()
        | levels: Enum.reverse(snapshot().levels),
          child_stops: Enum.reverse(snapshot().child_stops),
          pathways: Enum.reverse(snapshot().pathways)
      }

      base = snapshot()

      rescaled = %{
        base
        | child_stops: update_at(base.child_stops, 0, &%{&1 | stop_lat: Decimal.new("39.95000")})
      }

      assert Envelope.input_provenance(shuffled) == Envelope.input_provenance(base)
      assert Envelope.input_provenance(rescaled) == Envelope.input_provenance(base)
    end

    test "an execution field change alters the digest" do
      base = snapshot()
      base_digest = Envelope.input_provenance(base)["digest"]

      changes = [
        {"pathway endpoint",
         %{base | pathways: update_at(base.pathways, 0, &%{&1 | to_stop_id: "PLAT_2"})}},
        {"pathway min_width",
         %{base | pathways: update_at(base.pathways, 0, &%{&1 | min_width: Decimal.new("0.9")})}},
        {"child coordinates",
         %{
           base
           | child_stops: update_at(base.child_stops, 0, &%{&1 | stop_lat: Decimal.new("40.0")})
         }},
        {"level index",
         %{
           base
           | levels: [%{level: %{level_id: "L1", level_index: Decimal.new("1"), level_name: "L"}}]
         }},
        {"child location_type",
         %{base | child_stops: update_at(base.child_stops, 0, &%{&1 | location_type: 3})}}
      ]

      for {label, changed} <- changes do
        digest = Envelope.input_provenance(changed)["digest"]

        assert digest != base_digest, "expected #{label} to change the digest"
      end
    end

    test "station membership is part of the digest" do
      base = snapshot()

      assert Envelope.input_provenance(%{base | station: nil})["digest"] !=
               Envelope.input_provenance(base)["digest"]
    end
  end

  defp update_at(list, index, fun), do: List.update_at(list, index, fun)

  defp snapshot do
    %{
      station: %{
        stop_id: "STATION",
        stop_name: "Test Station",
        stop_desc: nil,
        stop_lat: Decimal.new("39.95"),
        stop_lon: Decimal.new("-75.16"),
        location_type: 1,
        wheelchair_boarding: 1,
        parent_station: nil,
        level_id: "L1"
      },
      child_stops: [
        %{
          stop_id: "ENT_A",
          stop_name: "Entrance A",
          stop_desc: nil,
          stop_lat: Decimal.new("39.95"),
          stop_lon: Decimal.new("-75.16"),
          location_type: 2,
          wheelchair_boarding: 1,
          parent_station: "STATION",
          level_id: "L1"
        },
        %{
          stop_id: "PLAT_1",
          stop_name: "Platform 1",
          stop_desc: nil,
          stop_lat: Decimal.new("39.950001"),
          stop_lon: Decimal.new("-75.16"),
          location_type: 0,
          wheelchair_boarding: 1,
          parent_station: "STATION",
          level_id: "L1"
        }
      ],
      pathways: [
        %{
          pathway_id: "PW_1",
          pathway_mode: 1,
          from_stop_id: "ENT_A",
          to_stop_id: "PLAT_1",
          is_bidirectional: true,
          traversal_time: 45,
          length: nil,
          stair_count: nil,
          max_slope: nil,
          signposted_as: nil,
          reversed_signposted_as: nil,
          min_width: Decimal.new("1.05")
        }
      ],
      levels: [%{level: %{level_id: "L1", level_index: Decimal.new("0"), level_name: "Ground"}}]
    }
  end
end
