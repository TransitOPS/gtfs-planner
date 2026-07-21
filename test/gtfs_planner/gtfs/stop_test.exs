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

  describe "changeset/2 coordinate validation" do
    test "accepts in-range latitude and longitude" do
      attrs =
        base_stop_attrs()
        |> Map.put(:stop_lat, "40.7128")
        |> Map.put(:stop_lon, "-74.0060")

      changeset = Stop.changeset(%Stop{}, attrs)

      assert changeset.valid?
    end

    test "rejects latitude greater than 90" do
      attrs = Map.put(base_stop_attrs(), :stop_lat, "91")
      changeset = Stop.changeset(%Stop{}, attrs)

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :stop_lat)
    end

    test "rejects longitude greater than 180" do
      attrs = Map.put(base_stop_attrs(), :stop_lon, "181")
      changeset = Stop.changeset(%Stop{}, attrs)

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :stop_lon)
    end

    test "accepts missing latitude and longitude" do
      changeset = Stop.changeset(%Stop{}, base_stop_attrs())

      assert changeset.valid?
    end
  end

  describe "changeset/2 and import_changeset/2 level requirements" do
    test "changeset/2 requires level_id when parent_station is set" do
      attrs =
        base_stop_attrs()
        |> Map.put(:parent_station, "PARENT_STATION")
        |> Map.put(:level_id, nil)

      changeset = Stop.changeset(%Stop{}, attrs)

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :level_id)
    end

    test "import_changeset/2 allows nil level_id when parent_station is set" do
      attrs =
        base_stop_attrs()
        |> Map.put(:parent_station, "PARENT_STATION")
        |> Map.put(:level_id, nil)

      changeset = Stop.import_changeset(%Stop{}, attrs)

      assert changeset.valid?
    end
  end

  describe "resolve_wheelchair_boarding/2" do
    test "returns accessible/direct for a child value of 1" do
      child = %Stop{wheelchair_boarding: 1}

      assert Stop.resolve_wheelchair_boarding(child, nil) ==
               %{status: :accessible, source: :direct}
    end

    test "returns not_accessible/direct for a child value of 2" do
      child = %Stop{wheelchair_boarding: 2}

      assert Stop.resolve_wheelchair_boarding(child, nil) ==
               %{status: :not_accessible, source: :direct}
    end

    test "a direct value wins over a conflicting parent" do
      child = %Stop{wheelchair_boarding: 2}
      parent = %Stop{wheelchair_boarding: 1}

      assert Stop.resolve_wheelchair_boarding(child, parent) ==
               %{status: :not_accessible, source: :direct}
    end

    test "inherits accessible from a parent 1 when the child is 0" do
      child = %Stop{wheelchair_boarding: 0}
      parent = %Stop{wheelchair_boarding: 1}

      assert Stop.resolve_wheelchair_boarding(child, parent) ==
               %{status: :accessible, source: :inherited}
    end

    test "inherits accessible from a parent 1 when the child is nil" do
      child = %Stop{wheelchair_boarding: nil}
      parent = %Stop{wheelchair_boarding: 1}

      assert Stop.resolve_wheelchair_boarding(child, parent) ==
               %{status: :accessible, source: :inherited}
    end

    test "inherits not_accessible from a parent 2 when the child is 0" do
      child = %Stop{wheelchair_boarding: 0}
      parent = %Stop{wheelchair_boarding: 2}

      assert Stop.resolve_wheelchair_boarding(child, parent) ==
               %{status: :not_accessible, source: :inherited}
    end

    test "returns unknown/missing for a child 0 with no parent" do
      child = %Stop{wheelchair_boarding: 0}

      assert Stop.resolve_wheelchair_boarding(child, nil) ==
               %{status: :unknown, source: :missing}
    end

    test "returns unknown/missing for a child nil with a parent 0" do
      child = %Stop{wheelchair_boarding: nil}
      parent = %Stop{wheelchair_boarding: 0}

      assert Stop.resolve_wheelchair_boarding(child, parent) ==
               %{status: :unknown, source: :missing}
    end

    test "returns unknown/missing for a child nil with a parent nil" do
      child = %Stop{wheelchair_boarding: nil}
      parent = %Stop{wheelchair_boarding: nil}

      assert Stop.resolve_wheelchair_boarding(child, parent) ==
               %{status: :unknown, source: :missing}
    end

    test "leaves both input structs unchanged" do
      child = %Stop{wheelchair_boarding: 0, stop_id: "CHILD"}
      parent = %Stop{wheelchair_boarding: 1, stop_id: "PARENT"}

      _result = Stop.resolve_wheelchair_boarding(child, parent)

      assert child.wheelchair_boarding == 0
      assert child.stop_id == "CHILD"
      assert parent.wheelchair_boarding == 1
      assert parent.stop_id == "PARENT"
    end
  end

  defp base_stop_attrs do
    %{
      stop_id: "STOP_1",
      organization_id: Ecto.UUID.generate(),
      gtfs_version_id: Ecto.UUID.generate()
    }
  end
end
