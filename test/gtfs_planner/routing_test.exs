defmodule GtfsPlanner.RoutingTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.{Pathway, Stop}
  alias GtfsPlanner.Routing
  alias GtfsPlanner.Routing.{Diagnostic, Route, StationGraph}

  defp stop(id, opts \\ []) do
    %Stop{
      stop_id: id,
      stop_name: Keyword.get(opts, :name, id),
      stop_lat: Keyword.get(opts, :lat, Decimal.new("39.95")),
      stop_lon: Keyword.get(opts, :lon, Decimal.new("-75.16")),
      location_type: Keyword.get(opts, :location_type, 0),
      wheelchair_boarding: Keyword.get(opts, :wheelchair_boarding, 1),
      parent_station: Keyword.get(opts, :parent_station),
      level_id: Keyword.get(opts, :level_id)
    }
  end

  defp pathway(from, to, opts \\ []) do
    %Pathway{
      pathway_id: Keyword.get(opts, :id, "PW_#{from}_#{to}"),
      pathway_mode: Keyword.get(opts, :mode, 1),
      is_bidirectional: Keyword.get(opts, :bidirectional, true),
      from_stop_id: from,
      to_stop_id: to,
      traversal_time: Keyword.get(opts, :traversal_time, 60),
      length: Keyword.get(opts, :length),
      stair_count: Keyword.get(opts, :stair_count),
      signposted_as: Keyword.get(opts, :signposted_as),
      reversed_signposted_as: Keyword.get(opts, :reversed_signposted_as)
    }
  end

  defp snapshot(stops, pathways, levels \\ []) do
    %{child_stops: stops, pathways: pathways, levels: levels}
  end

  describe "build_station_graph/1" do
    test "zero pathways yields pathway_count 0 with all stop ids in element_ids" do
      stops = [stop("ENT_A", location_type: 2), stop("PLAT_1")]
      snap = snapshot(stops, [])

      assert {:ok, %StationGraph{} = graph} = Routing.build_station_graph(snap)

      assert graph.pathway_count == 0
      assert MapSet.member?(graph.element_ids, "ENT_A")
      assert MapSet.member?(graph.element_ids, "PLAT_1")
    end

    test "a stop with no resolvable coordinates is absent from element_ids" do
      stops = [
        stop("GOOD", lat: Decimal.new("39.95"), lon: Decimal.new("-75.16")),
        %Stop{stop_id: "NOCOORD", stop_lat: nil, stop_lon: nil, location_type: 0}
      ]

      snap = snapshot(stops, [])

      assert {:ok, %StationGraph{} = graph} = Routing.build_station_graph(snap)

      assert MapSet.member?(graph.element_ids, "GOOD")
      refute MapSet.member?(graph.element_ids, "NOCOORD")
    end

    test "a pathway referencing a missing stop yields a missing_endpoint diagnostic" do
      stops = [stop("A")]
      pw = pathway("A", "MISSING")
      snap = snapshot(stops, [pw])

      assert {:ok, %StationGraph{} = graph} = Routing.build_station_graph(snap)

      diag = Enum.find(graph.diagnostics, fn d -> d.code == :missing_endpoint end)
      assert diag != nil
      assert diag.entity_id == "PW_A_MISSING"

      map = Diagnostic.to_map(diag)
      assert {:ok, _} = Jason.encode(map)
    end
  end

  describe "plan/4" do
    setup do
      stops = [
        stop("ENT_A", location_type: 2),
        stop("PLAT_1", location_type: 0)
      ]

      pw = pathway("ENT_A", "PLAT_1", traversal_time: 60)
      snap = snapshot(stops, [pw])
      {:ok, graph} = Routing.build_station_graph(snap)
      %{graph: graph}
    end

    test "connected pair returns {:ok, %Route{}}", %{graph: graph} do
      assert {:ok, %Route{} = route} = Routing.plan(graph, "ENT_A", "PLAT_1")
      assert route.duration_seconds == 60
      assert route.step_count == length(route.steps)
    end

    test "disconnected pair returns {:error, :no_path}", %{graph: _} do
      stops = [stop("X"), stop("Y")]
      snap = snapshot(stops, [])
      {:ok, empty_graph} = Routing.build_station_graph(snap)

      assert {:error, :no_path} = Routing.plan(empty_graph, "X", "Y")
    end

    test "unknown element returns {:error, {:unknown_element, id}}", %{graph: graph} do
      assert {:error, {:unknown_element, "GHOST"}} = Routing.plan(graph, "ENT_A", "GHOST")
    end

    test "same origin and destination returns {:error, :same_origin_and_destination}", %{
      graph: graph
    } do
      assert {:error, :same_origin_and_destination} = Routing.plan(graph, "ENT_A", "ENT_A")
    end
  end

  describe "plan/4 wheelchair" do
    test "wheelchair: true returns :no_path when only link is stairs" do
      stops = [stop("A"), stop("B")]
      pw = pathway("A", "B", mode: 2, traversal_time: 45)
      snap = snapshot(stops, [pw])
      {:ok, graph} = Routing.build_station_graph(snap)

      assert {:ok, %Route{}} = Routing.plan(graph, "A", "B")
      assert {:error, :no_path} = Routing.plan(graph, "A", "B", wheelchair: true)
    end

    test "wheelchair: true returns :no_path when only link is escalator" do
      stops = [stop("A"), stop("B")]
      pw = pathway("A", "B", mode: 4, traversal_time: 30)
      snap = snapshot(stops, [pw])
      {:ok, graph} = Routing.build_station_graph(snap)

      assert {:ok, %Route{}} = Routing.plan(graph, "A", "B")
      assert {:error, :no_path} = Routing.plan(graph, "A", "B", wheelchair: true)
    end

    test "wheelchair: true succeeds when elevator connects endpoints" do
      stops = [stop("A"), stop("B")]

      stairs = pathway("A", "B", id: "PW_STAIRS", mode: 2, traversal_time: 45)
      elevator = pathway("A", "B", id: "PW_ELEV", mode: 5, traversal_time: 90)

      snap = snapshot(stops, [stairs, elevator])
      {:ok, graph} = Routing.build_station_graph(snap)

      assert {:ok, %Route{}} = Routing.plan(graph, "A", "B", wheelchair: true)
    end
  end
end
