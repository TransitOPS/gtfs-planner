defmodule GtfsPlanner.Gtfs.StopTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.Stop

  describe "slugify/1" do
    test "slugifies a normal name" do
      assert Stop.slugify("Platform A") == "platform_a"
    end

    test "removes special characters" do
      assert Stop.slugify("Track #3 — West!") == "track_3_west"
    end

    test "returns empty string for empty input" do
      assert Stop.slugify("") == ""
    end

    test "returns empty string for nil input" do
      assert Stop.slugify(nil) == ""
    end

    test "keeps numeric-only values" do
      assert Stop.slugify("42") == "42"
    end

    test "truncates to 64 characters" do
      long_name = String.duplicate("a", 80)
      assert Stop.slugify(long_name) == String.duplicate("a", 64)
    end

    test "trims leading and trailing whitespace" do
      assert Stop.slugify("  Platform A  ") == "platform_a"
    end
  end

  describe "generate_stop_id/2" do
    test "generates stop id for platform" do
      assert Stop.generate_stop_id(0, "Track 1") == "platform_track_1"
    end

    test "generates stop id for entrance" do
      assert Stop.generate_stop_id(2, "Main Entrance") == "entrance_main_entrance"
    end

    test "returns empty string for empty name" do
      assert Stop.generate_stop_id(3, "") == ""
    end

    test "returns empty string for nil name" do
      assert Stop.generate_stop_id(3, nil) == ""
    end

    test "uses expected location_type prefixes" do
      assert Stop.generate_stop_id(0, "A") == "platform_a"
      assert Stop.generate_stop_id(1, "A") == "station_a"
      assert Stop.generate_stop_id(2, "A") == "entrance_a"
      assert Stop.generate_stop_id(3, "A") == "node_a"
      assert Stop.generate_stop_id(4, "A") == "boarding_a"
    end
  end
end
