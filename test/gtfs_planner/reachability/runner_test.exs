defmodule GtfsPlanner.Reachability.RunnerTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Reachability.{Envelope, Runner}

  defp stop(id, location_type, opts \\ []) do
    %{
      stop_id: id,
      stop_name: Keyword.get(opts, :name, id),
      stop_lat: Keyword.get(opts, :lat, Decimal.new("39.95")),
      stop_lon: Keyword.get(opts, :lon, Decimal.new("-75.16")),
      location_type: location_type,
      wheelchair_boarding: 1,
      parent_station: Keyword.get(opts, :parent_station),
      level_id: Keyword.get(opts, :level_id),
      stop_desc: nil
    }
  end

  defp pathway(from, to, opts \\ []) do
    %{
      pathway_id: Keyword.get(opts, :id, "PW_#{from}_#{to}"),
      pathway_mode: Keyword.get(opts, :mode, 1),
      is_bidirectional: Keyword.get(opts, :bidirectional, true),
      from_stop_id: from,
      to_stop_id: to,
      traversal_time: Keyword.get(opts, :traversal_time, 60),
      length: Keyword.get(opts, :length),
      stair_count: Keyword.get(opts, :stair_count),
      max_slope: nil,
      signposted_as: nil,
      reversed_signposted_as: nil,
      min_width: Keyword.get(opts, :min_width)
    }
  end

  describe "run/2" do
    test "produces a complete envelope for a connected station" do
      station = stop("STATION", 1, name: "Test Station")

      child_stops = [
        stop("ENT_A", 2, name: "Entrance A"),
        stop("PLAT_1", 0, name: "Platform 1")
      ]

      pathways = [pathway("ENT_A", "PLAT_1", traversal_time: 45)]
      started_at = DateTime.utc_now()

      assert {:ok, envelope} =
               Runner.run(
                 %{station: station, child_stops: child_stops, pathways: pathways, levels: []},
                 started_at
               )

      assert envelope["engine"] == "pathways_router"
      assert envelope["result_schema_version"] == 1
      assert envelope["outcome"] == "passed"
      assert envelope["totals"]["pair_count"] == 4
      assert envelope["totals"]["reachable"] == 4
      assert length(envelope["pairs"]) == 4

      indices = Enum.map(envelope["pairs"], & &1["index"])
      assert indices == [0, 1, 2, 3]
    end

    test "wheelchair-only unreachable produces warning outcome" do
      station = stop("STATION", 1)

      child_stops = [
        stop("ENT_A", 2),
        stop("PLAT_1", 0)
      ]

      pathways = [pathway("ENT_A", "PLAT_1", mode: 2, traversal_time: 30)]
      started_at = DateTime.utc_now()

      assert {:ok, envelope} =
               Runner.run(
                 %{station: station, child_stops: child_stops, pathways: pathways, levels: []},
                 started_at
               )

      assert envelope["outcome"] == "warning"
      assert envelope["totals"]["walking_reachable"] == 2
      assert envelope["totals"]["wheelchair_unreachable"] == 2
    end

    test "empty battery produces not_applicable outcome" do
      station = stop("STATION", 1)
      child_stops = [stop("PLAT_1", 0)]
      started_at = DateTime.utc_now()

      assert {:ok, envelope} =
               Runner.run(
                 %{station: station, child_stops: child_stops, pathways: [], levels: []},
                 started_at
               )

      assert envelope["outcome"] == "not_applicable"
      assert envelope["totals"]["pair_count"] == 0
    end

    test "envelope is JSON-encodable" do
      station = stop("STATION", 1)
      child_stops = [stop("ENT_A", 2), stop("PLAT_1", 0)]
      pathways = [pathway("ENT_A", "PLAT_1")]
      started_at = DateTime.utc_now()

      {:ok, envelope} =
        Runner.run(
          %{station: station, child_stops: child_stops, pathways: pathways, levels: []},
          started_at
        )

      assert {:ok, json} = Jason.encode(envelope)
      assert {:ok, decoded} = Jason.decode(json)
      assert decoded == envelope
    end

    test "records provenance of the same snapshot it routed" do
      snapshot = %{
        station: stop("STATION", 1),
        child_stops: [stop("ENT_A", 2), stop("PLAT_1", 0)],
        pathways: [pathway("ENT_A", "PLAT_1", min_width: Decimal.new("1.05"))],
        levels: [%{level: %{level_id: "L1", level_index: Decimal.new("0"), level_name: "Ground"}}]
      }

      assert {:ok, envelope} = Runner.run(snapshot, DateTime.utc_now())

      assert envelope["input_provenance"] == Envelope.input_provenance(snapshot)
      assert envelope["input_provenance"]["closure_evaluation"] == "not_evaluated"
    end

    test "a pathway width change produces a different digest" do
      station = stop("STATION", 1)
      child_stops = [stop("ENT_A", 2), stop("PLAT_1", 0)]
      started_at = DateTime.utc_now()

      narrow = %{
        station: station,
        child_stops: child_stops,
        pathways: [pathway("ENT_A", "PLAT_1", min_width: Decimal.new("0.90"))],
        levels: []
      }

      wider = %{
        narrow
        | pathways: [pathway("ENT_A", "PLAT_1", min_width: Decimal.new("0.9000"))]
      }

      assert {:ok, narrow_envelope} = Runner.run(narrow, started_at)
      assert {:ok, wider_envelope} = Runner.run(wider, started_at)

      # Recorded scale is not the execution input; the value is.
      assert narrow_envelope["input_provenance"] == wider_envelope["input_provenance"]

      {:ok, no_width} = Runner.run(%{narrow | pathways: [pathway("ENT_A", "PLAT_1")]}, started_at)

      assert no_width["input_provenance"]["digest"] !=
               narrow_envelope["input_provenance"]["digest"]
    end
  end
end
