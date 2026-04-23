defmodule GtfsPlanner.Gtfs.GraphTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.Graph

  defp pathway(from, to, opts \\ []) do
    %{
      pathway_id: Keyword.get(opts, :pathway_id, "#{from}_#{to}"),
      from_stop_id: from,
      to_stop_id: to,
      pathway_mode: Keyword.get(opts, :pathway_mode, 1),
      is_bidirectional: Keyword.get(opts, :is_bidirectional, true)
    }
  end

  defp stop(stop_id, opts) do
    %{
      stop_id: stop_id,
      stop_name: Keyword.get(opts, :stop_name, stop_id),
      location_type: Keyword.get(opts, :location_type, 3),
      parent_station: Keyword.get(opts, :parent_station, nil),
      level_id: Keyword.get(opts, :level_id, nil)
    }
  end

  describe "build_directed_adjacency/1" do
    test "bidirectional pathway creates edges in both directions" do
      adj = Graph.build_directed_adjacency([pathway("A", "B", is_bidirectional: true)])

      assert MapSet.member?(adj["A"], "B")
      assert MapSet.member?(adj["B"], "A")
    end

    test "unidirectional pathway creates one edge" do
      adj = Graph.build_directed_adjacency([pathway("A", "B", is_bidirectional: false)])

      assert MapSet.member?(adj["A"], "B")
      assert adj["B"] == nil
    end
  end

  describe "build_undirected_adjacency/1" do
    test "treats all pathways as bidirectional" do
      adj = Graph.build_undirected_adjacency([pathway("A", "B", is_bidirectional: false)])

      assert MapSet.member?(adj["A"], "B")
      assert MapSet.member?(adj["B"], "A")
    end
  end

  describe "bfs/2" do
    test "returns all reachable nodes from start" do
      adj =
        Graph.build_directed_adjacency([
          pathway("A", "B"),
          pathway("B", "C")
        ])

      reachable = Graph.bfs("A", adj)

      assert MapSet.member?(reachable, "A")
      assert MapSet.member?(reachable, "B")
      assert MapSet.member?(reachable, "C")
    end

    test "disconnected nodes not included" do
      adj =
        Graph.build_directed_adjacency([
          pathway("A", "B"),
          pathway("C", "D")
        ])

      reachable = Graph.bfs("A", adj)

      assert MapSet.member?(reachable, "A")
      assert MapSet.member?(reachable, "B")
      refute MapSet.member?(reachable, "C")
      refute MapSet.member?(reachable, "D")
    end
  end

  describe "reachable?/3" do
    setup do
      adj =
        Graph.build_directed_adjacency([
          pathway("A", "B"),
          pathway("B", "C")
        ])

      %{adj: adj}
    end

    test "returns true when target is reachable", %{adj: adj} do
      assert Graph.reachable?("A", MapSet.new(["C"]), adj)
    end

    test "returns false when target is not reachable", %{adj: adj} do
      refute Graph.reachable?("A", MapSet.new(["D"]), adj)
    end

    test "returns false for empty target set", %{adj: adj} do
      refute Graph.reachable?("A", MapSet.new(), adj)
    end
  end

  describe "shortest_directed_path_to_any/3" do
    test "returns correct hop sequence for a 3-node chain" do
      adj =
        Graph.build_path_traversal_adjacency([
          pathway("A", "B", pathway_mode: 1, pathway_id: "P1"),
          pathway("B", "C", pathway_mode: 5, pathway_id: "P2")
        ])

      assert {:found, path} =
               Graph.shortest_directed_path_to_any(adj, "A", MapSet.new(["C"]))

      assert [
               %{stop_id: "A", pathway_id: nil, pathway_mode: nil},
               %{stop_id: "B", pathway_id: "P1", pathway_mode: 1},
               %{stop_id: "C", pathway_id: "P2", pathway_mode: 5}
             ] = path
    end

    test "returns :not_found for disconnected nodes" do
      adj =
        Graph.build_path_traversal_adjacency([
          pathway("A", "B", is_bidirectional: false)
        ])

      assert :not_found =
               Graph.shortest_directed_path_to_any(adj, "A", MapSet.new(["C"]))
    end

    test "handles start == target" do
      adj = Graph.build_path_traversal_adjacency([pathway("A", "B")])

      assert {:found, path} =
               Graph.shortest_directed_path_to_any(adj, "A", MapSet.new(["A"]))

      assert [%{stop_id: "A", pathway_id: nil, pathway_mode: nil}] = path
    end
  end

  describe "build_platform_target_index/1" do
    test "maps platform to itself plus its boarding areas" do
      stops = [
        stop("PLAT_1", location_type: 0),
        stop("BA_1", location_type: 4, parent_station: "PLAT_1"),
        stop("BA_2", location_type: 4, parent_station: "PLAT_1"),
        stop("PLAT_2", location_type: 0),
        stop("ENT_1", location_type: 2)
      ]

      index = Graph.build_platform_target_index(stops)

      assert MapSet.equal?(index["PLAT_1"], MapSet.new(["PLAT_1", "BA_1", "BA_2"]))
      assert MapSet.equal?(index["PLAT_2"], MapSet.new(["PLAT_2"]))
      assert index["ENT_1"] == nil
    end
  end

  describe "build_path_traversal_adjacency/1" do
    test "edges are sorted by {to_stop_id, pathway_id}" do
      adj =
        Graph.build_path_traversal_adjacency([
          pathway("A", "C", pathway_id: "P2"),
          pathway("A", "B", pathway_id: "P1")
        ])

      to_ids = Enum.map(adj["A"], & &1.to_stop_id)
      assert to_ids == ["B", "C"]
    end
  end

  describe "build_step_free_path_traversal_adjacency/1" do
    test "filters out stairs (mode 2) and escalators (mode 4)" do
      adj =
        Graph.build_step_free_path_traversal_adjacency([
          pathway("A", "B", pathway_mode: 1, is_bidirectional: false),
          pathway("B", "C", pathway_mode: 2, is_bidirectional: false),
          pathway("C", "D", pathway_mode: 4, is_bidirectional: false),
          pathway("D", "E", pathway_mode: 5, is_bidirectional: false)
        ])

      # Walkway (1) included
      assert Map.has_key?(adj, "A")
      # No edge from B→C (stairs mode 2 filtered out)
      all_edges = Map.values(adj) |> List.flatten()
      refute Enum.any?(all_edges, &(&1.to_stop_id == "C"))
      # No edge from C→D (escalator mode 4 filtered out)
      refute Enum.any?(all_edges, &(&1.to_stop_id == "D" and &1.pathway_mode == 4))
      # Elevator (5) included
      assert Enum.any?(all_edges, &(&1.to_stop_id == "E"))
    end
  end
end
