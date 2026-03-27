defmodule GtfsPlanner.Gtfs.StationReport2.DataQualityTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.StationReport2.DataQuality

  @required_keys ~w(id label description status value value_format detail_label detail_layout details)a

  defp make_station(attrs \\ %{}) do
    Map.merge(
      %{
        stop_id: "STATION_1",
        stop_name: "Test Station",
        location_type: 1,
        parent_station: nil,
        wheelchair_boarding: nil,
        level_id: nil,
        stop_lat: Decimal.new("40.0"),
        stop_lon: Decimal.new("-74.0")
      },
      attrs
    )
  end

  defp make_stop(attrs) do
    Map.merge(
      %{
        stop_name: "Stop",
        wheelchair_boarding: nil,
        level_id: nil,
        stop_lat: Decimal.new("40.0"),
        stop_lon: Decimal.new("-74.0")
      },
      attrs
    )
  end

  defp make_pathway(attrs) do
    Map.merge(
      %{
        pathway_id: "PW_1",
        pathway_mode: 1,
        is_bidirectional: true
      },
      attrs
    )
  end

  defp empty_snapshot do
    %{station: make_station(), child_stops: [], pathways: []}
  end

  describe "build/1" do
    test "returns exactly 11 items with all required keys for empty station" do
      items = DataQuality.build(empty_snapshot())

      assert length(items) == 11

      Enum.each(items, fn item ->
        Enum.each(@required_keys, fn key ->
          assert Map.has_key?(item, key), "Missing key #{key} in item #{item.id}"
        end)
      end)
    end

    test "items are in the correct order" do
      items = DataQuality.build(empty_snapshot())

      ids = Enum.map(items, & &1.id)

      assert ids == [
               "isolated_nodes",
               "boarding_area_parent_consistency",
               "station_parent_consistency",
               "orphaned_platforms",
               "minimum_station_children",
               "entrance_to_platform_connectivity",
               "platform_interconnection",
               "wheelchair_boarding_consistency",
               "wheelchair_contradicts_context",
               "wheelchair_inferrable",
               "duplicate_stop_ids"
             ]
    end

    test "empty station: all pass or info, minimum_station_children fails" do
      items = DataQuality.build(empty_snapshot())

      min_children = Enum.find(items, &(&1.id == "minimum_station_children"))
      assert min_children.status == :fail
      assert min_children.value == false

      # Other checks should pass (no children to fail on)
      for item <- items, item.id not in ["minimum_station_children", "orphaned_platforms"] do
        assert item.status in [:pass, :info],
               "Expected #{item.id} to be :pass or :info, got #{item.status}"
      end
    end

    test "isolated boarding area fails isolated_nodes check" do
      ba = make_stop(%{stop_id: "BA_1", location_type: 4, parent_station: "STATION_1"})
      snapshot = %{station: make_station(), child_stops: [ba], pathways: []}

      items = DataQuality.build(snapshot)
      isolated = Enum.find(items, &(&1.id == "isolated_nodes"))

      assert isolated.status == :fail
      assert isolated.value == 1
      assert isolated.details == [%{id: "BA_1", name: "Stop"}]
    end

    test "connected boarding area passes isolated_nodes check" do
      platform = make_stop(%{stop_id: "PLAT_1", location_type: 0, parent_station: "STATION_1"})
      ba = make_stop(%{stop_id: "BA_1", location_type: 4, parent_station: "PLAT_1"})

      pw =
        make_pathway(%{
          pathway_id: "PW_1",
          from_stop_id: "PLAT_1",
          to_stop_id: "BA_1",
          is_bidirectional: true
        })

      snapshot = %{station: make_station(), child_stops: [platform, ba], pathways: [pw]}
      items = DataQuality.build(snapshot)
      isolated = Enum.find(items, &(&1.id == "isolated_nodes"))

      assert isolated.status == :pass
      assert isolated.value == 0
    end

    test "boarding area with non-platform parent fails parent consistency" do
      ba =
        make_stop(%{
          stop_id: "BA_1",
          location_type: 4,
          parent_station: "STATION_1"
        })

      snapshot = %{station: make_station(), child_stops: [ba], pathways: []}
      items = DataQuality.build(snapshot)
      check = Enum.find(items, &(&1.id == "boarding_area_parent_consistency"))

      assert check.status == :fail
      assert check.value == 1
      assert %{id: "BA_1", name: "Stop"} in check.details
    end

    test "boarding area with platform parent passes parent consistency" do
      platform = make_stop(%{stop_id: "PLAT_1", location_type: 0, parent_station: "STATION_1"})
      ba = make_stop(%{stop_id: "BA_1", location_type: 4, parent_station: "PLAT_1"})

      snapshot = %{station: make_station(), child_stops: [platform, ba], pathways: []}
      items = DataQuality.build(snapshot)
      check = Enum.find(items, &(&1.id == "boarding_area_parent_consistency"))

      assert check.status == :pass
      assert check.value == 0
    end

    test "entrance with no pathway to platform fails connectivity check" do
      entrance = make_stop(%{stop_id: "ENT_1", location_type: 2, parent_station: "STATION_1"})
      platform = make_stop(%{stop_id: "PLAT_1", location_type: 0, parent_station: "STATION_1"})

      snapshot = %{
        station: make_station(),
        child_stops: [entrance, platform],
        pathways: []
      }

      items = DataQuality.build(snapshot)
      check = Enum.find(items, &(&1.id == "entrance_to_platform_connectivity"))

      assert check.status == :fail
      assert check.value.unreachable == 1
      assert check.value.reachable == 0
      assert %{id: "ENT_1", name: "Stop"} in check.details
    end

    test "entrance connected to platform passes connectivity check" do
      entrance = make_stop(%{stop_id: "ENT_1", location_type: 2, parent_station: "STATION_1"})
      platform = make_stop(%{stop_id: "PLAT_1", location_type: 0, parent_station: "STATION_1"})

      pw =
        make_pathway(%{
          from_stop_id: "ENT_1",
          to_stop_id: "PLAT_1",
          is_bidirectional: true
        })

      snapshot = %{
        station: make_station(),
        child_stops: [entrance, platform],
        pathways: [pw]
      }

      items = DataQuality.build(snapshot)
      check = Enum.find(items, &(&1.id == "entrance_to_platform_connectivity"))

      assert check.status == :pass
      assert check.value.unreachable == 0
      assert check.value.reachable == 1
    end

    test "duplicate stop_id fails duplicate check" do
      stop1 = make_stop(%{stop_id: "DUP_1", location_type: 0, parent_station: "STATION_1"})
      stop2 = make_stop(%{stop_id: "DUP_1", location_type: 0, parent_station: "STATION_1"})

      snapshot = %{station: make_station(), child_stops: [stop1, stop2], pathways: []}
      items = DataQuality.build(snapshot)
      check = Enum.find(items, &(&1.id == "duplicate_stop_ids"))

      assert check.status == :fail
      assert check.value == 1
      assert %{id: "DUP_1", name: "Stop"} in check.details
    end

    test "wheelchair_boarding_consistency: station not wheelchair_boarding=1 passes" do
      snapshot = %{
        station: make_station(%{wheelchair_boarding: nil}),
        child_stops: [],
        pathways: []
      }

      items = DataQuality.build(snapshot)
      check = Enum.find(items, &(&1.id == "wheelchair_boarding_consistency"))

      assert check.status == :pass
      assert check.value == "Not applicable"
    end

    test "wheelchair_boarding_consistency: no accessible path fails" do
      entrance = make_stop(%{stop_id: "ENT_1", location_type: 2, parent_station: "STATION_1"})
      platform = make_stop(%{stop_id: "PLAT_1", location_type: 0, parent_station: "STATION_1"})

      # pathway_mode: 2 = stairs (not step-free)
      pw =
        make_pathway(%{
          from_stop_id: "ENT_1",
          to_stop_id: "PLAT_1",
          pathway_mode: 2,
          is_bidirectional: true
        })

      snapshot = %{
        station: make_station(%{wheelchair_boarding: 1}),
        child_stops: [entrance, platform],
        pathways: [pw]
      }

      items = DataQuality.build(snapshot)
      check = Enum.find(items, &(&1.id == "wheelchair_boarding_consistency"))

      assert check.status == :fail
      assert check.value == "No accessible path"
    end

    test "wheelchair_inferrable: stairs-only connected stop suggests 2" do
      platform = make_stop(%{stop_id: "PLAT_1", location_type: 0, parent_station: "STATION_1", wheelchair_boarding: nil})
      entrance = make_stop(%{stop_id: "ENT_1", location_type: 2, parent_station: "STATION_1", wheelchair_boarding: nil})

      # pathway_mode 2 = stairs
      pw =
        make_pathway(%{
          from_stop_id: "ENT_1",
          to_stop_id: "PLAT_1",
          pathway_mode: 2,
          is_bidirectional: true
        })

      snapshot = %{
        station: make_station(),
        child_stops: [entrance, platform],
        pathways: [pw]
      }

      items = DataQuality.build(snapshot)
      check = Enum.find(items, &(&1.id == "wheelchair_inferrable"))

      assert check.status == :warn
      assert check.value == 2

      ids = Enum.map(check.details, & &1.id)
      assert "ENT_1" in ids
      assert "PLAT_1" in ids
    end

    test "orphaned_platforms always returns :info status" do
      platform = make_stop(%{stop_id: "PLAT_1", location_type: 0, parent_station: "STATION_1"})

      snapshot = %{station: make_station(), child_stops: [platform], pathways: []}
      items = DataQuality.build(snapshot)
      check = Enum.find(items, &(&1.id == "orphaned_platforms"))

      assert check.status == :info
      assert check.value == 1
    end

    test "empty stop_name falls back to stop_id in detail entries" do
      ba =
        make_stop(%{
          stop_id: "BA_EMPTY",
          stop_name: "",
          location_type: 4,
          parent_station: "STATION_1"
        })

      snapshot = %{station: make_station(), child_stops: [ba], pathways: []}
      items = DataQuality.build(snapshot)
      isolated = Enum.find(items, &(&1.id == "isolated_nodes"))

      assert isolated.status == :fail
      assert [%{id: "BA_EMPTY", name: "BA_EMPTY"}] = isolated.details
    end

    test "detail entries include stop_name when present" do
      ba =
        make_stop(%{
          stop_id: "BA_NAMED",
          stop_name: "Main Entrance BA",
          location_type: 4,
          parent_station: "STATION_1"
        })

      snapshot = %{station: make_station(), child_stops: [ba], pathways: []}
      items = DataQuality.build(snapshot)
      isolated = Enum.find(items, &(&1.id == "isolated_nodes"))

      assert isolated.status == :fail
      assert [%{id: "BA_NAMED", name: "Main Entrance BA"}] = isolated.details
    end

    test "wheelchair_inferrable details include name" do
      platform =
        make_stop(%{
          stop_id: "PLAT_1",
          stop_name: "Platform 1",
          location_type: 0,
          parent_station: "STATION_1",
          wheelchair_boarding: nil
        })

      entrance =
        make_stop(%{
          stop_id: "ENT_1",
          stop_name: "Entrance 1",
          location_type: 2,
          parent_station: "STATION_1",
          wheelchair_boarding: nil
        })

      pw =
        make_pathway(%{
          from_stop_id: "ENT_1",
          to_stop_id: "PLAT_1",
          pathway_mode: 2,
          is_bidirectional: true
        })

      snapshot = %{
        station: make_station(),
        child_stops: [entrance, platform],
        pathways: [pw]
      }

      items = DataQuality.build(snapshot)
      check = Enum.find(items, &(&1.id == "wheelchair_inferrable"))

      assert check.status == :warn

      Enum.each(check.details, fn detail ->
        assert Map.has_key?(detail, :name), "Expected :name key in detail #{inspect(detail)}"
      end)

      names = Map.new(check.details, &{&1.id, &1.name})
      assert names["ENT_1"] == "Entrance 1"
      assert names["PLAT_1"] == "Platform 1"
    end
  end
end
