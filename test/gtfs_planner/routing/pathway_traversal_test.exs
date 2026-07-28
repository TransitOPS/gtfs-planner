defmodule GtfsPlanner.Routing.PathwayTraversalTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.{Level, Pathway, Stop}
  alias GtfsPlanner.Routing.PathwayTraversal

  defp stop(id, opts \\ []) do
    %Stop{
      stop_id: id,
      stop_name: Keyword.get(opts, :name, id),
      stop_lat: Keyword.get(opts, :lat, Decimal.new("39.95")),
      stop_lon: Keyword.get(opts, :lon, Decimal.new("-75.16")),
      location_type: Keyword.get(opts, :location_type, 0),
      wheelchair_boarding: Keyword.get(opts, :wheelchair_boarding, 1),
      level_id: Keyword.get(opts, :level_id)
    }
  end

  defp level_row(level_id, index, name) do
    %{
      level: %Level{level_id: level_id, level_index: index, level_name: name},
      stop_count: 1,
      diagram_filename: nil,
      stop_level: nil
    }
  end

  describe "traverse/4" do
    test "walkway with traversal_time: 60 returns time_seconds: 60.0" do
      from = stop("A")
      to = stop("B")

      pw = %Pathway{
        pathway_id: "PW_1",
        pathway_mode: 1,
        is_bidirectional: true,
        from_stop_id: "A",
        to_stop_id: "B",
        traversal_time: 60,
        length: Decimal.new("80")
      }

      assert {:ok, result} = PathwayTraversal.traverse(pw, from, to, [])
      assert result.time_seconds == 60.0
    end

    test "walkway with traversal_time: 0 and length: 133 returns time_seconds: 100.0" do
      from = stop("A")
      to = stop("B")

      pw = %Pathway{
        pathway_id: "PW_2",
        pathway_mode: 1,
        is_bidirectional: true,
        from_stop_id: "A",
        to_stop_id: "B",
        traversal_time: 0,
        length: Decimal.new("133")
      }

      assert {:ok, result} = PathwayTraversal.traverse(pw, from, to, [])
      assert result.time_seconds == 100.0
    end

    test "walkway with traversal_time: 0, length: 0, stair_count: 10 derives time from stair tier" do
      from = stop("A")
      to = stop("B")

      pw = %Pathway{
        pathway_id: "PW_3",
        pathway_mode: 2,
        is_bidirectional: true,
        from_stop_id: "A",
        to_stop_id: "B",
        traversal_time: 0,
        length: Decimal.new("0"),
        stair_count: 10
      }

      assert {:ok, result} = PathwayTraversal.traverse(pw, from, to, [])
      assert result.time_seconds > 0.0
    end

    test "elevator with no traversal_time between adjacent levels returns time_seconds: 110.0" do
      from = stop("A", level_id: "L0")
      to = stop("B", level_id: "L1")

      pw = %Pathway{
        pathway_id: "PW_ELEV",
        pathway_mode: 5,
        is_bidirectional: true,
        from_stop_id: "A",
        to_stop_id: "B",
        traversal_time: 0,
        length: Decimal.new("0")
      }

      levels = [level_row("L0", 0.0, "Ground"), level_row("L1", 1.0, "Mezzanine")]

      assert {:ok, result} = PathwayTraversal.traverse(pw, from, to, levels)
      assert result.time_seconds == 110.0
      assert result.distance_meters == nil
    end

    test "unidirectional pathway traversed against direction returns {:error, :no_path}" do
      from = stop("A")
      to = stop("B")

      pw = %Pathway{
        pathway_id: "PW_UNI",
        pathway_mode: 1,
        is_bidirectional: false,
        from_stop_id: "A",
        to_stop_id: "B",
        traversal_time: 60
      }

      assert {:ok, _} = PathwayTraversal.traverse(pw, from, to, [])
      assert {:error, :no_path} = PathwayTraversal.traverse(pw, to, from, [])
    end

    test "bidirectional stairs with negative stair_count on reverse still succeeds" do
      from = stop("A")
      to = stop("B")

      pw = %Pathway{
        pathway_id: "PW_STAIRS",
        pathway_mode: 2,
        is_bidirectional: true,
        from_stop_id: "A",
        to_stop_id: "B",
        traversal_time: 0,
        length: Decimal.new("0"),
        stair_count: 12
      }

      assert {:ok, _} = PathwayTraversal.traverse(pw, from, to, [])
      assert {:ok, _} = PathwayTraversal.traverse(pw, to, from, [])
    end
  end
end
