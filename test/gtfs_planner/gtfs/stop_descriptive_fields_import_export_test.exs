defmodule GtfsPlanner.Gtfs.StopDescriptiveFieldsImportExportTest do
  @moduledoc """
  Round trip for the `stops.txt` `stop_code`, `tts_stop_name`, `stop_url` and
  `stop_timezone` columns: full import stores each value as written (empty as NULL),
  the full export writes them back in GTFS reference order, re-importing that
  export keeps them, and the `:pathways` export leaves them out.

  Every expected value is a hand-written literal, so neither the parser nor the
  exporter can confirm its own output.
  """
  use GtfsPlanner.DataCase, async: false

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Export
  alias GtfsPlanner.Gtfs.Import
  alias GtfsPlanner.Gtfs.Import.CsvParser

  @stops_header "stop_id,stop_code,stop_name,tts_stop_name,stop_desc,stop_lat,stop_lon," <>
                  "zone_id,stop_url,location_type,parent_station,stop_timezone," <>
                  "wheelchair_boarding,platform_code,level_id"

  @pathways_stops_header "stop_id,stop_name,stop_desc,stop_lat,stop_lon,location_type," <>
                           "parent_station,wheelchair_boarding,platform_code,level_id"

  @stops_csv """
  stop_id,stop_code,stop_name,tts_stop_name,stop_lat,stop_lon,stop_url,stop_timezone,location_type
  B1,4021,Alpha Stop,Alpha Street,40.0,-70.0,https://example.test/stops/B1,America/New_York,0
  B2, 4022,Beta Stop,,40.1,-70.1,"https://example.test/stops?a=1,2",,0
  B3,,Gamma Stop,Gamma  Street,40.2,-70.2,,America/Chicago,0
  B4,,Delta Stop,,40.3,-70.3,,,0
  S1,S-1,Central Station,Central,40.4,-70.4,https://example.test/stations/S1,Europe/Paris,1
  """

  # Stored {stop_code, tts_stop_name, stop_url, stop_timezone} by stop_id: the
  # literal input, with every empty field stored as NULL.
  @expected_stored %{
    "B1" => {"4021", "Alpha Street", "https://example.test/stops/B1", "America/New_York"},
    "B2" => {" 4022", nil, "https://example.test/stops?a=1,2", nil},
    "B3" => {nil, "Gamma  Street", nil, "America/Chicago"},
    "B4" => {nil, nil, nil, nil},
    "S1" => {"S-1", "Central", "https://example.test/stations/S1", "Europe/Paris"}
  }

  # The same values read back from the exported stops.txt, where NULL is empty.
  @expected_exported %{
    "B1" => {"4021", "Alpha Street", "https://example.test/stops/B1", "America/New_York"},
    "B2" => {" 4022", "", "https://example.test/stops?a=1,2", ""},
    "B3" => {"", "Gamma  Street", "", "America/Chicago"},
    "B4" => {"", "", "", ""},
    "S1" => {"S-1", "Central", "https://example.test/stations/S1", "Europe/Paris"}
  }

  setup do
    organization = GtfsPlanner.OrganizationsFixtures.organization_fixture()
    version = GtfsPlanner.VersionsFixtures.gtfs_version_fixture(organization.id)

    %{organization: organization, version: version}
  end

  test "import, full export and re-import keep every stop_code, tts_stop_name, stop_url and stop_timezone",
       %{organization: organization, version: version} do
    assert {:ok, result} = Import.import_files(organization.id, version.id, input_files())
    assert result.counts[:stops] == 5

    assert stored(organization.id, version.id) == @expected_stored

    assert {:ok, zip} = Export.export_to_zip(organization.id, version.id, :full)
    stops_text = zip |> unzip() |> entry!("stops.txt")

    assert stops_text |> String.split("\n") |> hd() == @stops_header

    assert Map.new(parse_rows(stops_text), &{&1["stop_id"], exported_values(&1)}) ==
             @expected_exported

    second_version = GtfsPlanner.VersionsFixtures.gtfs_version_fixture(organization.id)

    assert {:ok, reimport_result} =
             Import.import_files(organization.id, second_version.id, [
               %{filename: "stops.txt", content: stops_text}
             ])

    assert reimport_result.counts[:stops] == 5
    assert stored(organization.id, second_version.id) == @expected_stored
  end

  test "the pathways export keeps exactly its ten stops.txt columns", %{
    organization: organization,
    version: version
  } do
    assert {:ok, _result} = Import.import_files(organization.id, version.id, input_files())

    assert {:ok, zip} = Export.export_to_zip(organization.id, version.id, :pathways)
    stops_text = zip |> unzip() |> entry!("stops.txt")

    assert stops_text |> String.split("\n") |> hd() == @pathways_stops_header
    assert length(parse_rows(stops_text)) == 5
  end

  defp input_files, do: [%{filename: "stops.txt", content: @stops_csv}]

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

  defp parse_rows(content) do
    {:ok, parsed} = CsvParser.stream("stops.txt", content)
    Enum.map(parsed.events, fn {:ok, _row_number, row} -> row end)
  end

  defp exported_values(row) do
    {row["stop_code"], row["tts_stop_name"], row["stop_url"], row["stop_timezone"]}
  end

  defp stored(organization_id, gtfs_version_id) do
    organization_id
    |> Gtfs.list_stops(gtfs_version_id)
    |> Map.new(&{&1.stop_id, {&1.stop_code, &1.tts_stop_name, &1.stop_url, &1.stop_timezone}})
  end
end
