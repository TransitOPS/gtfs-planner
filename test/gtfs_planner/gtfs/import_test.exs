defmodule GtfsPlanner.Gtfs.ImportTest do
  use GtfsPlanner.DataCase, async: true

  alias GtfsPlanner.Gtfs.Import

  describe "parse_csv_content/1" do
    test "parses simple CSV with header and rows" do
      content = """
      level_id,level_index,level_name
      L1,0.0,Ground Floor
      L2,1.0,Platform
      """

      result = Import.parse_csv_content(content) |> Enum.to_list()

      assert result == [
               %{"level_id" => "L1", "level_index" => "0.0", "level_name" => "Ground Floor"},
               %{"level_id" => "L2", "level_index" => "1.0", "level_name" => "Platform"}
             ]
    end

    test "handles quoted fields with embedded commas" do
      content = """
      stop_id,stop_name,stop_desc
      S1,"Main Station, North Entrance","Bus terminal with indoor waiting area"
      S2,Secondary,"Train platform, track 2"
      """

      result = Import.parse_csv_content(content) |> Enum.to_list()

      assert result == [
               %{
                 "stop_id" => "S1",
                 "stop_name" => "Main Station, North Entrance",
                 "stop_desc" => "Bus terminal with indoor waiting area"
               },
               %{
                 "stop_id" => "S2",
                 "stop_name" => "Secondary",
                 "stop_desc" => "Train platform, track 2"
               }
             ]
    end

    test "handles escaped quotes within quoted fields" do
      content = """
      field1,field2,field3
      value1,"quoted ""value"" with escaped quotes",value3
      "another ""example\""",normal,test
      """

      result = Import.parse_csv_content(content) |> Enum.to_list()

      assert result == [
               %{
                 "field1" => "value1",
                 "field2" => "quoted \"value\" with escaped quotes",
                 "field3" => "value3"
               },
               %{
                 "field1" => "another \"example\"",
                 "field2" => "normal",
                 "field3" => "test"
               }
             ]
    end

    test "handles empty fields" do
      content = """
      level_id,level_index,level_name
      L1,0.0,
      L2,,Second Floor
      ,2.0,Third
      """

      result = Import.parse_csv_content(content) |> Enum.to_list()

      assert result == [
               %{"level_id" => "L1", "level_index" => "0.0", "level_name" => ""},
               %{"level_id" => "L2", "level_index" => "", "level_name" => "Second Floor"},
               %{"level_id" => "", "level_index" => "2.0", "level_name" => "Third"}
             ]
    end

    test "handles trailing newlines and whitespace" do
      content = "field1,field2\nvalue1,value2\n\n"

      result = Import.parse_csv_content(content) |> Enum.to_list()

      assert result == [
               %{"field1" => "value1", "field2" => "value2"}
             ]
    end

    test "returns empty list for empty content" do
      assert Import.parse_csv_content("") |> Enum.to_list() == []
    end

    test "returns empty list for content with only header" do
      content = "level_id,level_index,level_name"
      assert Import.parse_csv_content(content) |> Enum.to_list() == []
    end

    test "skips malformed lines with wrong field count" do
      content = """
      field1,field2,field3
      value1,value2
      value3,value4,value5,value6
      value7,value8,value9
      """

      result = Import.parse_csv_content(content) |> Enum.to_list()

      # Only the properly formed line should be included
      assert result == [
               %{"field1" => "value7", "field2" => "value8", "field3" => "value9"}
             ]
    end

    test "handles mixed quoted and unquoted fields" do
      content = """
      id,name,description
      1,normal,"quoted, description"
      "2","quoted name",normal desc
      """

      result = Import.parse_csv_content(content) |> Enum.to_list()

      assert result == [
               %{"id" => "1", "name" => "normal", "description" => "quoted, description"},
               %{"id" => "2", "name" => "quoted name", "description" => "normal desc"}
             ]
    end
  end

  describe "parse_csv_line/1" do
    test "parses simple CSV line" do
      assert Import.parse_csv_line("value1,value2,value3") ==
               {:ok, ["value1", "value2", "value3"]}
    end

    test "parses CSV line with quoted fields" do
      assert Import.parse_csv_line(~s(value1,"quoted,value",value3)) ==
               {:ok, ["value1", "quoted,value", "value3"]}
    end

    test "parses CSV line with escaped quotes" do
      assert Import.parse_csv_line(~s("quoted ""value"" here",normal)) ==
               {:ok, ["quoted \"value\" here", "normal"]}
    end

    test "handles empty fields" do
      assert Import.parse_csv_line("value1,,value3") == {:ok, ["value1", "", "value3"]}
      assert Import.parse_csv_line(",,") == {:ok, ["", "", ""]}
    end

    test "handles trailing comma" do
      assert Import.parse_csv_line("value1,value2,") == {:ok, ["value1", "value2", ""]}
    end
  end

  describe "import_files/3" do
    alias GtfsPlanner.Gtfs

    setup do
      organization = GtfsPlanner.OrganizationsFixtures.organization_fixture()
      gtfs_version = GtfsPlanner.VersionsFixtures.gtfs_version_fixture(organization.id)

      %{organization: organization, gtfs_version: gtfs_version}
    end

    test "imports levels and stops successfully", %{
      organization: organization,
      gtfs_version: gtfs_version
    } do
      levels_content = """
      level_id,level_index,level_name
      L1,0.0,Ground Floor
      L2,1.0,Platform
      """

      stops_content = """
      stop_id,stop_name,stop_lat,stop_lon,level_id,location_type,wheelchair_boarding
      S1,Main Station,40.7128,-74.0060,L1,1,1
      S2,Platform A,40.7129,-74.0061,L2,0,2
      """

      files = [
        %{filename: "levels.txt", content: levels_content},
        %{filename: "stops.txt", content: stops_content}
      ]

      assert {:ok, {counts, _unrecognized, _topic}} =
               Import.import_files(organization.id, gtfs_version.id, files)

      assert counts.routes == 0
      assert counts.levels == 2
      assert counts.stops == 2
      assert counts.pathways == 0
      assert counts.route_patterns == 0

      # Verify levels were created
      levels = Gtfs.list_levels(organization.id, gtfs_version.id)
      assert length(levels) == 2
      assert Enum.any?(levels, &(&1.level_id == "L1"))
      assert Enum.any?(levels, &(&1.level_id == "L2"))

      # Verify stops were created
      stops = Gtfs.list_stops(organization.id, gtfs_version.id)
      assert length(stops) == 2
      assert Enum.any?(stops, &(&1.stop_id == "S1"))
      assert Enum.any?(stops, &(&1.stop_id == "S2"))
    end

    test "imports levels, stops, and pathways successfully", %{
      organization: organization,
      gtfs_version: gtfs_version
    } do
      levels_content = """
      level_id,level_index,level_name
      L1,0.0,Ground Floor
      """

      stops_content = """
      stop_id,stop_name,stop_lat,stop_lon,level_id
      S1,Stop 1,40.7,-74.0,L1
      S2,Stop 2,40.7,-74.1,L1
      """

      pathways_content = """
      pathway_id,from_stop_id,to_stop_id,pathway_mode,is_bidirectional
      P1,S1,S2,1,1
      """

      files = [
        %{filename: "levels.txt", content: levels_content},
        %{filename: "stops.txt", content: stops_content},
        %{filename: "pathways.txt", content: pathways_content}
      ]

      assert {:ok, {_counts, _unrecognized, _topic}} =
               Import.import_files(organization.id, gtfs_version.id, files)

      # Verify pathways were created
      pathways = Gtfs.list_pathways(organization.id, gtfs_version.id)
      assert length(pathways) == 1
      pathway = hd(pathways)
      assert pathway.pathway_id == "P1"

      # Verify pathway is linked to the correct stops
      from_stop = Gtfs.get_stop!(pathway.from_stop_id)
      to_stop = Gtfs.get_stop!(pathway.to_stop_id)
      assert from_stop.stop_id == "S1"
      assert to_stop.stop_id == "S2"
    end

    test "rolls back transaction when duplicate level_id is present", %{
      organization: organization,
      gtfs_version: gtfs_version
    } do
      # First, create a level with ID "L1" directly
      {:ok, _} =
        Gtfs.create_level(%{
          level_id: "L1",
          level_index: 0.0,
          level_name: "Existing Level",
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id
        })

      # Now try to import a file with the same level_id
      levels_content = """
      level_id,level_index,level_name
      L1,0.0,Ground Floor
      L2,1.0,Platform
      """

      stops_content = """
      stop_id,stop_name,stop_lat,stop_lon,level_id,location_type,wheelchair_boarding
      S1,Main Station,40.7128,-74.0060,L1,1,1
      """

      files = [
        %{filename: "levels.txt", content: levels_content},
        %{filename: "stops.txt", content: stops_content}
      ]

      # Should fail due to duplicate level_id constraint
      assert {:error, _reason} = Import.import_files(organization.id, gtfs_version.id, files)

      # Verify no new levels were created (only the original one exists)
      levels = Gtfs.list_levels(organization.id, gtfs_version.id)
      assert length(levels) == 1
      assert Enum.all?(levels, &(&1.level_id == "L1"))

      # Verify no stops were created (transaction rolled back)
      stops = Gtfs.list_stops(organization.id, gtfs_version.id)
      assert length(stops) == 0
    end

    test "imports pathway with malformed traversal_time, setting it to nil", %{
      organization: organization,
      gtfs_version: gtfs_version
    } do
      levels_content = """
      level_id,level_index,level_name
      L1,0.0,Ground Floor
      """

      stops_content = """
      stop_id,stop_name,stop_lat,stop_lon,level_id
      S1,Stop 1,40.7,-74.0,L1
      S2,Stop 2,40.7,-74.1,L1
      """

      pathways_content = """
      pathway_id,from_stop_id,to_stop_id,pathway_mode,is_bidirectional,traversal_time
      P1,S1,S2,1,1,abc
      """

      files = [
        %{filename: "levels.txt", content: levels_content},
        %{filename: "stops.txt", content: stops_content},
        %{filename: "pathways.txt", content: pathways_content}
      ]

      assert {:ok, {counts, _unrecognized, _topic}} =
               Import.import_files(organization.id, gtfs_version.id, files)

      assert counts.pathways == 1

      # Verify pathway was created with nil traversal_time
      pathways = Gtfs.list_pathways(organization.id, gtfs_version.id)
      assert length(pathways) == 1
      pathway = hd(pathways)
      assert pathway.pathway_id == "P1"
      assert pathway.traversal_time == nil
    end

    test "imports pathway with malformed length, setting it to nil", %{
      organization: organization,
      gtfs_version: gtfs_version
    } do
      levels_content = """
      level_id,level_index,level_name
      L1,0.0,Ground Floor
      """

      stops_content = """
      stop_id,stop_name,stop_lat,stop_lon,level_id
      S1,Stop 1,40.7,-74.0,L1
      S2,Stop 2,40.7,-74.1,L1
      """

      pathways_content = """
      pathway_id,from_stop_id,to_stop_id,pathway_mode,is_bidirectional,length
      P1,S1,S2,1,1,12.34 meters
      """

      files = [
        %{filename: "levels.txt", content: levels_content},
        %{filename: "stops.txt", content: stops_content},
        %{filename: "pathways.txt", content: pathways_content}
      ]

      assert {:ok, {counts, _unrecognized, _topic}} =
               Import.import_files(organization.id, gtfs_version.id, files)

      assert counts.pathways == 1

      # Verify pathway was created with nil length
      pathways = Gtfs.list_pathways(organization.id, gtfs_version.id)
      assert length(pathways) == 1
      pathway = hd(pathways)
      assert pathway.pathway_id == "P1"
      assert pathway.length == nil
    end

    test "rolls back transaction if pathway references unknown stop_id", %{
      organization: organization,
      gtfs_version: gtfs_version
    } do
      levels_content = """
      level_id,level_index,level_name
      L1,0.0,Ground Floor
      """

      stops_content = """
      stop_id,stop_name,stop_lat,stop_lon,level_id
      S1,Stop 1,40.7,-74.0,L1
      """

      pathways_content = """
      pathway_id,from_stop_id,to_stop_id,pathway_mode,is_bidirectional
      P1,S1,S2_UNKNOWN,1,1
      """

      files = [
        %{filename: "levels.txt", content: levels_content},
        %{filename: "stops.txt", content: stops_content},
        %{filename: "pathways.txt", content: pathways_content}
      ]

      assert {:error, _reason} = Import.import_files(organization.id, gtfs_version.id, files)

      # Verify no pathways, stops, or levels were created (transaction rolled back)
      assert Gtfs.list_pathways(organization.id, gtfs_version.id) == []
      assert Gtfs.list_stops(organization.id, gtfs_version.id) == []
      assert Gtfs.list_levels(organization.id, gtfs_version.id) == []
    end
  end
end
