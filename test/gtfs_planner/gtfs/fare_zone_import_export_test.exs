defmodule GtfsPlanner.Gtfs.FareZoneImportExportTest do
  @moduledoc """
  Merge evidence (EV-1) for the `stops.txt` `zone_id` round trip. The station-data
  half of EV-1 lives in `test/gtfs_planner/gtfs/import/change_worker_apply_test.exs`.

  - Real `Import.import_files/3` stores each literal `zone_id` byte-for-byte for
    boardable stops, a station and an entrance, with an empty field stored as NULL.
  - A full `Export.export_to_zip/3` writes `stops.txt` with a `zone_id` column
    whose parsed values equal the literal input column (`" A"` keeps its space, the
    empty one stays empty), and `fare_rules.txt` rows equal to the literal input
    rows field for field.
  - Re-importing that export into a second version stores the same stop zone IDs
    and fare rules.
  - The `:pathways` export's `stops.txt` keeps exactly its ten columns and carries
    no `zone_id` column.

  Every expected value below is a hand-written literal, so neither the parser nor
  the exporter can confirm its own output.
  """
  use GtfsPlanner.DataCase, async: false

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Export
  alias GtfsPlanner.Gtfs.Import.CsvParser
  alias GtfsPlanner.Support.StagedImport

  @stops_header "stop_id,stop_name,stop_desc,stop_lat,stop_lon,zone_id," <>
                  "location_type,parent_station,wheelchair_boarding,platform_code,level_id"

  # The full export also writes stop_code, tts_stop_name, stop_url and
  # stop_timezone, so its header differs from the input header above.
  @exported_stops_header "stop_id,stop_code,stop_name,tts_stop_name,stop_desc,stop_lat," <>
                           "stop_lon,zone_id,stop_url,location_type,parent_station," <>
                           "stop_timezone,wheelchair_boarding,platform_code,level_id"

  @pathways_stops_header "stop_id,stop_name,stop_desc,stop_lat,stop_lon,location_type," <>
                           "parent_station,wheelchair_boarding,platform_code,level_id"

  @fare_rules_header "fare_id,route_id,origin_id,destination_id,contains_id"

  @stops_csv """
  #{@stops_header}
  B1,Alpha Stop,,40.0,-70.0,A,0,,,,
  B2,Beta Stop,,40.1,-70.1, A,0,,,,
  B3,Gamma Stop,,40.2,-70.2,Zone 1,0,,,,
  B4,Delta Stop,,40.3,-70.3,,0,,,,
  S1,Central Station,,40.4,-70.4,S,1,,,,
  E1,North Entrance,,40.5,-70.5,E,2,S1,,,
  """

  @fare_rules_csv """
  #{@fare_rules_header}
  F1,,A,B,
  F1,,A,B,C
  F2,,,, A
  F3,R1,Zone 1,,
  """

  # Stored stop zone IDs and location types: the literal input column, with the
  # empty field stored as NULL, for boardable stops, a station and an entrance.
  @expected_stored_stops %{
    "B1" => {"A", 0},
    "B2" => {" A", 0},
    "B3" => {"Zone 1", 0},
    "B4" => {nil, 0},
    "S1" => {"S", 1},
    "E1" => {"E", 2}
  }

  # The same stops read back from the exported stops.txt, where NULL is empty.
  @expected_exported_zones %{
    "B1" => "A",
    "B2" => " A",
    "B3" => "Zone 1",
    "B4" => "",
    "S1" => "S",
    "E1" => "E"
  }

  @fare_rule_columns ~w(fare_id route_id origin_id destination_id contains_id)a

  @expected_stored_fare_rules [
    %{fare_id: "F1", route_id: nil, origin_id: "A", destination_id: "B", contains_id: nil},
    %{fare_id: "F1", route_id: nil, origin_id: "A", destination_id: "B", contains_id: "C"},
    %{fare_id: "F2", route_id: nil, origin_id: nil, destination_id: nil, contains_id: " A"},
    %{fare_id: "F3", route_id: "R1", origin_id: "Zone 1", destination_id: nil, contains_id: nil}
  ]

  @expected_exported_fare_rules [
    %{
      "fare_id" => "F1",
      "route_id" => "",
      "origin_id" => "A",
      "destination_id" => "B",
      "contains_id" => ""
    },
    %{
      "fare_id" => "F1",
      "route_id" => "",
      "origin_id" => "A",
      "destination_id" => "B",
      "contains_id" => "C"
    },
    %{
      "fare_id" => "F2",
      "route_id" => "",
      "origin_id" => "",
      "destination_id" => "",
      "contains_id" => " A"
    },
    %{
      "fare_id" => "F3",
      "route_id" => "R1",
      "origin_id" => "Zone 1",
      "destination_id" => "",
      "contains_id" => ""
    }
  ]

  setup do
    organization = GtfsPlanner.OrganizationsFixtures.organization_fixture()
    version = GtfsPlanner.VersionsFixtures.gtfs_version_fixture(organization.id)

    %{organization: organization, version: version}
  end

  test "import, full export and re-import keep every zone ID and fare rule byte-for-byte", %{
    organization: organization,
    version: version
  } do
    assert {:ok, result} = StagedImport.import_files(organization.id, version.id, input_files())
    assert result.counts[:stops] == 6
    assert result.counts[:fare_rules] == 4

    assert stored_stops(organization.id, version.id) == @expected_stored_stops

    assert MapSet.new(stored_fare_rules(organization.id, version.id)) ==
             MapSet.new(@expected_stored_fare_rules)

    assert {:ok, zip} = Export.export_to_zip(organization.id, version.id, :full)
    entries = unzip(zip)

    stops_text = entry!(entries, "stops.txt")
    assert stops_text |> String.split("\n") |> hd() == @exported_stops_header

    exported_stops = parse!("stops.txt", stops_text)

    assert Map.new(exported_stops.rows, &{&1["stop_id"], &1["zone_id"]}) ==
             @expected_exported_zones

    fare_rules_text = entry!(entries, "fare_rules.txt")
    exported_rules = parse!("fare_rules.txt", fare_rules_text)
    assert exported_rules.headers == ~w(fare_id route_id origin_id destination_id contains_id)
    assert MapSet.new(exported_rules.rows) == MapSet.new(@expected_exported_fare_rules)

    second_version = GtfsPlanner.VersionsFixtures.gtfs_version_fixture(organization.id)

    reimport_files = [
      %{filename: "stops.txt", content: stops_text},
      %{filename: "fare_rules.txt", content: fare_rules_text}
    ]

    assert {:ok, reimport_result} =
             StagedImport.import_files(organization.id, second_version.id, reimport_files)

    assert reimport_result.counts[:stops] == 6
    assert reimport_result.counts[:fare_rules] == 4

    assert stored_stops(organization.id, second_version.id) == @expected_stored_stops

    assert MapSet.new(stored_fare_rules(organization.id, second_version.id)) ==
             MapSet.new(@expected_stored_fare_rules)
  end

  test "the pathways export keeps exactly its ten stops.txt columns", %{
    organization: organization,
    version: version
  } do
    assert {:ok, _result} = StagedImport.import_files(organization.id, version.id, input_files())

    assert {:ok, zip} = Export.export_to_zip(organization.id, version.id, :pathways)
    entries = unzip(zip)

    stops_text = entry!(entries, "stops.txt")
    assert stops_text |> String.split("\n") |> hd() == @pathways_stops_header

    parsed = parse!("stops.txt", stops_text)

    assert parsed.headers ==
             ~w(stop_id stop_name stop_desc stop_lat stop_lon location_type parent_station
                wheelchair_boarding platform_code level_id)

    refute "zone_id" in parsed.headers
    assert length(parsed.rows) == 6
  end

  defp input_files do
    [
      %{filename: "stops.txt", content: @stops_csv},
      %{filename: "fare_rules.txt", content: @fare_rules_csv}
    ]
  end

  defp unzip(zip) do
    {:ok, entries} = :zip.unzip(zip, [:memory])
    entries
  end

  defp entry!(entries, filename) do
    case Enum.find(entries, fn {name, _content} -> to_string(name) == filename end) do
      nil -> flunk("expected #{filename} in the export")
      {_name, content} -> to_string(content)
    end
  end

  defp parse!(filename, content) do
    {:ok, parsed} = CsvParser.stream(filename, content)

    %{
      headers: parsed.headers,
      rows: Enum.map(parsed.events, fn {:ok, _row_number, row} -> row end)
    }
  end

  # Stored stops as {zone_id, location_type} keyed by stop_id, so one comparison
  # covers the exact bytes and the empty value for every location type.
  defp stored_stops(organization_id, gtfs_version_id) do
    organization_id
    |> Gtfs.list_stops(gtfs_version_id)
    |> Map.new(&{&1.stop_id, {&1.zone_id, &1.location_type}})
  end

  defp stored_fare_rules(organization_id, gtfs_version_id) do
    organization_id
    |> Gtfs.list_fare_rules(gtfs_version_id)
    |> Enum.map(&Map.take(&1, @fare_rule_columns))
  end
end
