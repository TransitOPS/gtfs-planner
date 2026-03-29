defmodule GtfsPlanner.Otp.StationMaterializer.StationClosureTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Otp.StationMaterializer.StationClosure

  describe "derive_kept_stop_ids/2" do
    test "includes station, direct children, and boarding areas under kept platforms" do
      stops = [
        %{"stop_id" => "station_a", "location_type" => "1"},
        %{"stop_id" => "platform_1", "location_type" => "0", "parent_station" => "station_a"},
        %{"stop_id" => "entrance_1", "location_type" => "2", "parent_station" => "station_a"},
        %{"stop_id" => "boarding_1", "location_type" => "4", "parent_station" => "platform_1"},
        %{
          "stop_id" => "boarding_ignored",
          "location_type" => "4",
          "parent_station" => "entrance_1"
        },
        %{"stop_id" => "other_station", "location_type" => "1"},
        %{
          "stop_id" => "other_platform",
          "location_type" => "0",
          "parent_station" => "other_station"
        }
      ]

      assert StationClosure.derive_kept_stop_ids(stops, "station_a") == [
               "boarding_1",
               "entrance_1",
               "platform_1",
               "station_a"
             ]
    end

    test "supports row maps nested under values" do
      stops = [
        %{values: %{"stop_id" => "station_b", "location_type" => "1"}},
        %{
          values: %{
            "stop_id" => "platform_b",
            "location_type" => "0",
            "parent_station" => "station_b"
          }
        },
        %{
          values: %{
            "stop_id" => "boarding_b",
            "location_type" => "4",
            "parent_station" => "platform_b"
          }
        }
      ]

      assert StationClosure.derive_kept_stop_ids(stops, "station_b") == [
               "boarding_b",
               "platform_b",
               "station_b"
             ]
    end

    test "returns station id when there are no matching children" do
      stops = [%{"stop_id" => "station_c", "location_type" => "1"}]

      assert StationClosure.derive_kept_stop_ids(stops, "station_c") == ["station_c"]
    end
  end

  describe "validate_station_prerequisites/2" do
    test "returns ok when station exists exactly once with location_type 1" do
      stops = [
        %{"stop_id" => "station_ok", "location_type" => "1"},
        %{"stop_id" => "platform_ok", "location_type" => "0", "parent_station" => "station_ok"}
      ]

      assert {:ok, %{"stop_id" => "station_ok"}} =
               StationClosure.validate_station_prerequisites(stops, "station_ok")
    end

    test "returns blocking issue when station is missing" do
      stops = [%{"stop_id" => "other_station", "location_type" => "1"}]

      assert {:error, [issue]} =
               StationClosure.validate_station_prerequisites(stops, "station_missing")

      assert issue.code == :station_stop_not_found
      assert issue.severity == :blocking
    end

    test "returns blocking issue when station is duplicated" do
      stops = [
        %{"stop_id" => "station_dup", "location_type" => "1"},
        %{"stop_id" => "station_dup", "location_type" => "1"}
      ]

      assert {:error, [issue]} =
               StationClosure.validate_station_prerequisites(stops, "station_dup")

      assert issue.code == :station_stop_duplicated
      assert issue.severity == :blocking
      assert issue.context.row_count == 2
    end

    test "returns blocking issue when station location_type is not 1" do
      stops = [%{"stop_id" => "station_bad_type", "location_type" => "0"}]

      assert {:error, [issue]} =
               StationClosure.validate_station_prerequisites(stops, "station_bad_type")

      assert issue.code == :station_stop_invalid_type
      assert issue.severity == :blocking
      assert issue.context.location_type == 0
    end
  end
end
