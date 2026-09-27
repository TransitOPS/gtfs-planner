defmodule GtfsPlanner.Operations.TodsTest do
  @moduledoc """
  Pure TODS parsing and classification over the two published TODS example files
  and an extended garage fixture under `test/fixtures/tods/`.

  Expected classifications, row numbers and reason texts are hand-written from
  the TODS specification and the prepared contract; no production function
  computes an expected value. No database rows are created here.
  """

  use ExUnit.Case, async: true

  alias GtfsPlanner.Operations.Tods

  @fixture_dir Path.expand("../../fixtures/tods", __DIR__)

  @garage_example "tods_example_stops_supplement.txt"
  @vehicle_example "tods_example_vehicles.txt"
  @garage_file "stops_supplement.txt"
  @vehicle_file "vehicles.txt"

  @max_import_bytes 2_000_000

  defp fixture(name), do: File.read!(Path.join(@fixture_dir, name))

  defp parse!(kind, content, file) do
    assert {:ok, parsed} = Tods.parse(kind, file, content)
    parsed
  end

  defp classify!(kind, content, file \\ @garage_file),
    do: Tods.classify(parse!(kind, content, file))

  describe "max_import_bytes/0" do
    test "is the documented 2,000,000 byte limit" do
      assert Tods.max_import_bytes() == @max_import_bytes
    end
  end

  describe "parse/3" do
    test "parses the published TODS example garage rows in physical order" do
      assert {:ok, parsed} = Tods.parse(:garages, @garage_example, fixture(@garage_example))

      assert parsed.kind == :garages
      assert parsed.headers == ["stop_id", "location_type", "TODS_location_type"]

      assert parsed.rows == [
               {2,
                %{"stop_id" => "garage", "location_type" => "0", "TODS_location_type" => "garage"}},
               {3,
                %{
                  "stop_id" => "garage-waypoint",
                  "location_type" => "0",
                  "TODS_location_type" => ""
                }}
             ]
    end

    test "parses the published TODS example vehicle rows" do
      assert {:ok, parsed} = Tods.parse(:vehicles, @vehicle_example, fixture(@vehicle_example))

      assert parsed.kind == :vehicles
      assert parsed.headers == ["vehicle_id", "vehicle_label", "license_plate"]

      assert parsed.rows == [
               {2,
                %{
                  "vehicle_id" => "bus-1",
                  "vehicle_label" => "Old Reliable",
                  "license_plate" => "OR-E285104"
                }},
               {3,
                %{
                  "vehicle_id" => "bus-2",
                  "vehicle_label" => "Buster",
                  "license_plate" => "OR-E251432"
                }}
             ]
    end

    test "parses a header-only file into no rows" do
      assert {:ok, %{rows: []}} =
               Tods.parse(:vehicles, @vehicle_file, "vehicle_id,vehicle_label\n")

      assert classify!(:vehicles, "vehicle_id,vehicle_label\n", @vehicle_file) == %{
               accepted: [],
               skipped: [],
               errors: [],
               ignored_columns: []
             }
    end

    test "rejects a missing stop_id or vehicle_id header" do
      assert {:error, message} =
               Tods.parse(:garages, @garage_file, "stop_name,stop_lat\nMain,45.0\n")

      assert message == "#{@garage_file} is missing the stop_id column."

      assert {:error, message} =
               Tods.parse(:vehicles, @vehicle_file, "vehicle_label\nOld Reliable\n")

      assert message == "#{@vehicle_file} is missing the vehicle_id column."
    end

    test "names the row of a CSV parser error" do
      content = "stop_id,TODS_location_type\ngarage,garage\nbroken,garage,extra\n"

      assert {:error, message} = Tods.parse(:garages, @garage_file, content)
      assert message == "#{@garage_file} row 3: Row has the wrong number of values"
    end

    test "reports empty content" do
      assert {:error, message} = Tods.parse(:garages, @garage_file, "")
      assert message == "#{@garage_file}: File is empty"
    end

    test "rejects content over the byte limit before parsing" do
      content = String.duplicate("a", @max_import_bytes + 1)

      assert {:error, message} = Tods.parse(:garages, @garage_file, content)
      assert message == "#{@garage_file} is too large (limit #{@max_import_bytes} bytes)."
    end

    test "accepts content exactly at the byte limit" do
      pad =
        @max_import_bytes - String.length("stop_id,TODS_location_type\n") -
          String.length(",garage\n")

      content = "stop_id,TODS_location_type\n" <> String.duplicate("g", pad) <> ",garage\n"

      assert byte_size(content) == @max_import_bytes
      assert {:ok, %{rows: [{2, row}]}} = Tods.parse(:garages, @garage_file, content)
      assert row["stop_id"] == String.duplicate("g", pad)
      assert row["TODS_location_type"] == "garage"
    end
  end

  describe "classify/1 published TODS examples" do
    test "accepts the garage row and skips the untyped waypoint supplement" do
      assert classify!(:garages, fixture(@garage_example), @garage_example) == %{
               accepted: [%{row: 2, id: "garage", fields: %{}}],
               skipped: [
                 %{
                   row: 3,
                   id: "garage-waypoint",
                   reason: "Changes or adds a public stop; not imported."
                 }
               ],
               errors: [],
               ignored_columns: ["location_type"]
             }
    end

    test "accepts both published vehicles with their mapped fields" do
      assert classify!(:vehicles, fixture(@vehicle_example), @vehicle_file) == %{
               accepted: [
                 %{
                   row: 2,
                   id: "bus-1",
                   fields: %{vehicle_label: "Old Reliable", license_plate: "OR-E285104"}
                 },
                 %{
                   row: 3,
                   id: "bus-2",
                   fields: %{vehicle_label: "Buster", license_plate: "OR-E251432"}
                 }
               ],
               skipped: [],
               errors: [],
               ignored_columns: []
             }
    end
  end

  describe "classify/1 garage rows" do
    test "accepts the extended fixture garages and reports each skipped row's reason" do
      assert %{
               accepted: [main, east],
               skipped: [waypoint, public_stop, deletion],
               errors: [],
               ignored_columns: ["location_type", "zone_id"]
             } = classify!(:garages, fixture(@garage_file))

      assert main == %{
               row: 2,
               id: "garage_main",
               fields: %{name: "Main garage", lat: "45.5121", lon: "-122.6587"}
             }

      assert east == %{
               row: 3,
               id: "garage_east",
               fields: %{name: "East depot", lat: "45.5231", lon: "-122.6765"}
             }

      assert waypoint == %{
               row: 4,
               id: "garage-waypoint",
               reason: "Not a garage (TODS_location_type: waypoint)."
             }

      assert public_stop == %{
               row: 5,
               id: "stop_401",
               reason: "Changes or adds a public stop; not imported."
             }

      assert deletion == %{
               row: 6,
               id: "garage_old",
               reason: "Requests a deletion; deletions are not imported."
             }
    end

    test "checks the deletion flag before the location-type rules" do
      content = "stop_id,TODS_location_type,TODS_delete\nstation,station,1\nwaypoint,,1\n"

      assert classify!(:garages, content) == %{
               accepted: [],
               skipped: [
                 %{
                   row: 2,
                   id: "station",
                   reason: "Requests a deletion; deletions are not imported."
                 },
                 %{
                   row: 3,
                   id: "waypoint",
                   reason: "Requests a deletion; deletions are not imported."
                 }
               ],
               errors: [],
               ignored_columns: []
             }
    end

    test "trims values and matches the location type case-insensitively" do
      content = "stop_id,stop_name,TODS_location_type\n garage_main , Main garage , GARAGE \n"

      assert classify!(:garages, content) == %{
               accepted: [
                 %{row: 2, id: "garage_main", fields: %{name: "Main garage"}}
               ],
               skipped: [],
               errors: [],
               ignored_columns: []
             }
    end

    test "surfaces blank required coordinates for the database-aware preview" do
      content = "stop_id,stop_lat,stop_lon,TODS_location_type\ngarage_blank,,,garage\n"

      assert classify!(:garages, content) == %{
               accepted: [%{row: 2, id: "garage_blank", fields: %{lat: "", lon: ""}}],
               skipped: [],
               errors: [],
               ignored_columns: []
             }
    end

    test "rejects a blank or malformed stop_id" do
      content = "stop_id,TODS_location_type\n ,garage\nbad id,garage\n"

      assert %{accepted: [], errors: [blank, malformed]} = classify!(:garages, content)

      assert blank == %{row: 2, id: nil, reason: "Stop ID is required."}

      assert malformed == %{
               row: 3,
               id: "bad id",
               reason:
                 "Stop ID may contain only letters, numbers, periods, underscores, colons and hyphens."
             }
    end

    test "rejects coordinates outside their ranges and unparseable coordinates" do
      content =
        "stop_id,stop_lat,stop_lon,TODS_location_type\n" <>
          "garage_north,90.1,-122.6,garage\n" <>
          "garage_west,45.0,-180.1,garage\n" <>
          "garage_text,abc,-122.6,garage\n"

      assert classify!(:garages, content) == %{
               accepted: [],
               skipped: [],
               errors: [
                 %{row: 2, id: "garage_north", reason: "stop_lat must be between -90 and 90."},
                 %{row: 3, id: "garage_west", reason: "stop_lon must be between -180 and 180."},
                 %{row: 4, id: "garage_text", reason: "stop_lat is not a number."}
               ],
               ignored_columns: []
             }
    end

    test "accepts coordinates exactly on the range boundaries" do
      content = "stop_id,stop_lat,stop_lon,TODS_location_type\ngarage_edge,-90,180,garage\n"

      assert classify!(:garages, content) == %{
               accepted: [%{row: 2, id: "garage_edge", fields: %{lat: "-90", lon: "180"}}],
               skipped: [],
               errors: [],
               ignored_columns: []
             }
    end

    test "rejects a value over 255 characters and accepts one of exactly 255" do
      too_long = String.duplicate("n", 256)
      longest = String.duplicate("n", 255)

      content = "stop_id,stop_name,TODS_location_type\ngarage_long,#{too_long},garage\n"

      assert %{accepted: [], errors: [error]} = classify!(:garages, content)

      assert error == %{
               row: 2,
               id: "garage_long",
               reason: "stop_name is longer than 255 characters."
             }

      content = "stop_id,stop_name,TODS_location_type\ngarage_long,#{longest},garage\n"

      assert classify!(:garages, content) == %{
               accepted: [%{row: 2, id: "garage_long", fields: %{name: longest}}],
               skipped: [],
               errors: [],
               ignored_columns: []
             }
    end

    test "reports a repeated ID against the first accepted row" do
      content =
        "stop_id,stop_lat,stop_lon,TODS_location_type\n" <>
          " garage_main ,45.5,-122.6,garage\n" <>
          "garage_main,45.6,-122.7,garage\n"

      assert %{accepted: [main], errors: [repeated]} = classify!(:garages, content)

      assert main == %{
               row: 2,
               id: "garage_main",
               fields: %{lat: "45.5", lon: "-122.6"}
             }

      assert repeated == %{
               row: 3,
               id: "garage_main",
               reason: "Repeats garage_main from row 2."
             }
    end

    test "does not treat a row that failed validation as the duplicate source" do
      content =
        "stop_id,stop_lat,stop_lon,TODS_location_type\n" <>
          "garage_main,95.0,-122.6,garage\n" <>
          "garage_main,45.6,-122.7,garage\n"

      assert %{accepted: [main], errors: [invalid]} = classify!(:garages, content)

      assert main == %{
               row: 3,
               id: "garage_main",
               fields: %{lat: "45.6", lon: "-122.7"}
             }

      assert invalid == %{
               row: 2,
               id: "garage_main",
               reason: "stop_lat must be between -90 and 90."
             }
    end

    test "lists foreign columns in header order" do
      content =
        "stop_id,TODS_location_type,zone_id,location_type,notes\n" <>
          "garage_main,garage,,0,parking\n"

      assert %{accepted: [%{fields: %{}}], ignored_columns: ignored} =
               classify!(:garages, content)

      assert ignored == ["zone_id", "location_type", "notes"]
    end
  end

  describe "classify/1 vehicle rows" do
    test "rejects a blank vehicle_id" do
      content = "vehicle_id,vehicle_label\n,Orphan\n"

      assert classify!(:vehicles, content, @vehicle_file) == %{
               accepted: [],
               skipped: [],
               errors: [%{row: 2, id: nil, reason: "Vehicle ID is required."}],
               ignored_columns: []
             }
    end

    test "clears a blank label and omits an absent column" do
      content = "vehicle_id,vehicle_label\nbus-9,\n"

      assert classify!(:vehicles, content, @vehicle_file) == %{
               accepted: [%{row: 2, id: "bus-9", fields: %{vehicle_label: ""}}],
               skipped: [],
               errors: [],
               ignored_columns: []
             }

      assert classify!(:vehicles, "vehicle_id\nbus-9\n", @vehicle_file) == %{
               accepted: [%{row: 2, id: "bus-9", fields: %{}}],
               skipped: [],
               errors: [],
               ignored_columns: []
             }
    end

    test "reports a repeated vehicle_id against the first accepted row" do
      content = "vehicle_id,vehicle_label\n bus-1 ,Old Reliable\nbus-1,Other\n"

      assert %{accepted: [first], errors: [repeated]} =
               classify!(:vehicles, content, @vehicle_file)

      assert first == %{
               row: 2,
               id: "bus-1",
               fields: %{vehicle_label: "Old Reliable"}
             }

      assert repeated == %{row: 3, id: "bus-1", reason: "Repeats bus-1 from row 2."}
    end

    test "treats vehicle IDs as case-sensitive after trimming" do
      content = "vehicle_id\nbus-1\nBUS-1\n"

      assert classify!(:vehicles, content, @vehicle_file) == %{
               accepted: [
                 %{row: 2, id: "bus-1", fields: %{}},
                 %{row: 3, id: "BUS-1", fields: %{}}
               ],
               skipped: [],
               errors: [],
               ignored_columns: []
             }
    end

    test "rejects a vehicle value over 255 characters" do
      too_long = String.duplicate("p", 256)
      content = "vehicle_id,license_plate\nbus-1,#{too_long}\n"

      assert %{accepted: [], errors: [error]} = classify!(:vehicles, content, @vehicle_file)

      assert error == %{
               row: 2,
               id: "bus-1",
               reason: "license_plate is longer than 255 characters."
             }
    end

    test "lists foreign columns in header order" do
      content = "vehicle_id,vehicle_label,license_plate,notes,depot\nbus-1,Old,OR-1,x,y\n"

      assert %{accepted: [%{fields: fields}], ignored_columns: ignored} =
               classify!(:vehicles, content, @vehicle_file)

      assert fields == %{vehicle_label: "Old", license_plate: "OR-1"}
      assert ignored == ["notes", "depot"]
    end
  end
end
