defmodule GtfsPlanner.Gtfs.ImportTest do
  use GtfsPlanner.DataCase, async: false

  alias GtfsPlanner.Gtfs.Import
  alias GtfsPlannerWeb.Gtfs.ImportLive

  import GtfsPlanner.GtfsFixtures

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

      assert {:ok, result} =
               Import.import_files(organization.id, gtfs_version.id, files)

      counts = result.counts
      assert counts.routes == 0
      assert counts.levels == 2
      assert counts.stops == 2
      assert counts.pathways == 0
      assert counts.route_patterns == 0
      assert result.unrecognized_files == []
      assert is_binary(result.topic)
      assert result.archive_warnings == []
      assert result.extensions == :not_present
      assert Import.Result.publishable?(result)

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

      assert {:ok, result} =
               Import.import_files(organization.id, gtfs_version.id, files)

      # Verify pathways were created
      pathways = Gtfs.list_pathways(organization.id, gtfs_version.id)
      assert length(pathways) == 1
      pathway = hd(pathways)
      assert pathway.pathway_id == "P1"

      # Verify pathway is linked to the correct stops
      from_stop = Gtfs.get_stop_by_stop_id(organization.id, gtfs_version.id, pathway.from_stop_id)
      to_stop = Gtfs.get_stop_by_stop_id(organization.id, gtfs_version.id, pathway.to_stop_id)
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
      assert match?([_], levels)
      assert Enum.all?(levels, &(&1.level_id == "L1"))

      # Verify no stops were created (transaction rolled back)
      stops = Gtfs.list_stops(organization.id, gtfs_version.id)
      assert stops == []
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

      assert {:ok, result} =
               Import.import_files(organization.id, gtfs_version.id, files)

      assert result.counts.pathways == 1

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

      assert {:ok, result} =
               Import.import_files(organization.id, gtfs_version.id, files)

      assert result.counts.pathways == 1

      # Verify pathway was created with nil length
      pathways = Gtfs.list_pathways(organization.id, gtfs_version.id)
      assert length(pathways) == 1
      pathway = hd(pathways)
      assert pathway.pathway_id == "P1"
      assert pathway.length == nil
    end

    test "imports agencies successfully", %{
      organization: organization,
      gtfs_version: gtfs_version
    } do
      agency_content = """
      agency_id,agency_name,agency_url,agency_timezone
      SEPTA,Southeastern Pennsylvania Transportation Authority,https://www.septa.org,America/New_York
      """

      files = [
        %{filename: "agency.txt", content: agency_content}
      ]

      assert {:ok, result} =
               Import.import_files(organization.id, gtfs_version.id, files)

      assert result.counts.agencies == 1

      agencies =
        GtfsPlanner.Repo.all(Gtfs.Agency)
        |> Enum.filter(
          &(&1.organization_id == organization.id && &1.gtfs_version_id == gtfs_version.id)
        )

      assert length(agencies) == 1
      agency = hd(agencies)
      assert agency.agency_id == "SEPTA"
      assert agency.agency_name == "Southeastern Pennsylvania Transportation Authority"
      assert agency.agency_timezone == "America/New_York"
    end

    test "imports shapes in phase 2 batch flow", %{
      organization: organization,
      gtfs_version: gtfs_version
    } do
      shapes_content = """
      shape_id,shape_pt_lat,shape_pt_lon,shape_pt_sequence,shape_dist_traveled
      shape_a,40.7128,-74.0060,1,0.0
      """

      files = [
        %{filename: "shapes.txt", content: shapes_content}
      ]

      assert {:ok, result} =
               Import.import_files(organization.id, gtfs_version.id, files)

      assert result.counts.shapes == 1

      shapes =
        GtfsPlanner.Repo.all(Gtfs.Shape)
        |> Enum.filter(
          &(&1.organization_id == organization.id && &1.gtfs_version_id == gtfs_version.id)
        )

      assert length(shapes) == 1
      shape = hd(shapes)
      assert shape.shape_id == "shape_a"
      assert shape.shape_pt_sequence == 1
    end

    test "returns all supported count keys even for empty file list", %{
      organization: organization,
      gtfs_version: gtfs_version
    } do
      assert {:ok, result} =
               Import.import_files(organization.id, gtfs_version.id, [])

      counts = result.counts
      assert MapSet.new(Map.keys(counts)) == MapSet.new(Import.supported_count_keys())
      assert Enum.all?(counts, fn {_key, count} -> count == 0 end)
      assert result.extensions == :not_present
      assert Import.Result.publishable?(result)
    end

    @tag :skip
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

  describe "strict full-feed parsing" do
    alias GtfsPlanner.Gtfs

    setup do
      organization = GtfsPlanner.OrganizationsFixtures.organization_fixture()
      gtfs_version = GtfsPlanner.VersionsFixtures.gtfs_version_fixture(organization.id)

      %{organization: organization, gtfs_version: gtfs_version}
    end

    test "Phase 1 header failure returns structured ParseError and rolls back earlier files", %{
      organization: organization,
      gtfs_version: gtfs_version
    } do
      levels_content = "level_id,level_id,level_name\nL1,0.0,Ground Floor"

      stops_content = """
      stop_id,stop_name,stop_lat,stop_lon,level_id
      S1,Main Station,40.7128,-74.0060,L1
      """

      files = [
        %{filename: "levels.txt", content: levels_content},
        %{filename: "stops.txt", content: stops_content}
      ]

      assert {:error, %Import.ParseError{file: "levels.txt", reason: :duplicate_header}} =
               Import.import_files(organization.id, gtfs_version.id, files)

      # No levels and no stops were inserted: the Phase 1 transaction rolled back.
      assert Gtfs.list_levels(organization.id, gtfs_version.id) == []
      assert Gtfs.list_stops(organization.id, gtfs_version.id) == []
    end

    test "Phase 2 header failure returns structured ParseError without publishing", %{
      organization: organization,
      gtfs_version: gtfs_version
    } do
      levels_content = """
      level_id,level_index,level_name
      L1,0.0,Ground Floor
      """

      shapes_content = "shape_id,shape_id,shape_pt_lat,shape_pt_lon,shape_pt_sequence"

      files = [
        %{filename: "levels.txt", content: levels_content},
        %{filename: "shapes.txt", content: shapes_content}
      ]

      assert {:error, %Import.ParseError{file: "shapes.txt", reason: :duplicate_header}} =
               Import.import_files(organization.id, gtfs_version.id, files)

      shapes =
        GtfsPlanner.Repo.all(Gtfs.Shape)
        |> Enum.filter(
          &(&1.organization_id == organization.id && &1.gtfs_version_id == gtfs_version.id)
        )

      assert shapes == []
    end

    test "expand_archives emits a structured warning for a nested archive", %{
      organization: organization,
      gtfs_version: gtfs_version
    } do
      outer_levels = "level_id,level_index,level_name\nL1,0.0,Ground Floor"

      {:ok, {_name, nested_zip}} = :zip.create(~c"nested.zip", [{~c"x.txt", "x"}], [:memory])

      {:ok, {_name, outer_zip}} =
        :zip.create(
          ~c"gtfs.zip",
          [
            {~c"levels.txt", outer_levels},
            {~c"nested.zip", nested_zip}
          ],
          [:memory]
        )

      files = [%{filename: "gtfs.zip", content: outer_zip}]

      {expanded, warnings} = Import.expand_archives(files)

      assert [%{filename: "gtfs.zip", reason: :nested_archive}] = warnings

      # The nested archive is not expanded into the file list.
      assert Enum.all?(expanded, fn entry ->
               not String.ends_with?(String.downcase(entry.filename), ".zip")
             end)
    end
  end

  describe "registry coverage" do
    test "import and liveview recognized filename sets match" do
      assert MapSet.new(Import.supported_filenames()) == ImportLive.recognized_gtfs_filenames()
    end
  end

  describe "zip expansion" do
    setup do
      organization = GtfsPlanner.OrganizationsFixtures.organization_fixture()
      gtfs_version = GtfsPlanner.VersionsFixtures.gtfs_version_fixture(organization.id)

      %{organization: organization, gtfs_version: gtfs_version}
    end

    test "expands .zip archive and imports contained GTFS files", %{
      organization: organization,
      gtfs_version: gtfs_version
    } do
      levels_content = "level_id,level_index,level_name\nL1,0.0,Ground Floor"
      stops_content = "stop_id,stop_name,stop_lat,stop_lon,level_id\nS1,Stop 1,40.7,-74.0,L1"

      # Create a zip in memory
      {:ok, {_name, zip_binary}} =
        :zip.create(
          ~c"gtfs.zip",
          [
            {~c"levels.txt", levels_content},
            {~c"stops.txt", stops_content}
          ],
          [:memory]
        )

      files = [%{filename: "gtfs.zip", content: zip_binary}]

      assert {:ok, result} =
               Import.import_files(organization.id, gtfs_version.id, files)

      assert result.counts.levels == 1
      assert result.counts.stops == 1
      assert result.unrecognized_files == []
    end

    test "zip with extensions files categorizes them separately", %{
      organization: organization,
      gtfs_version: gtfs_version
    } do
      levels_content = "level_id,level_index,level_name\nL1,0.0,Ground Floor"
      manifest_json = Jason.encode!(%{"version" => 1, "exported_at" => "2026-01-01T00:00:00Z"})

      {:ok, {_name, zip_binary}} =
        :zip.create(
          ~c"gtfs.zip",
          [
            {~c"levels.txt", levels_content},
            {~c"_pathways_extensions.json", manifest_json},
            {~c"_pathways_extensions/diagrams/station/img.png", "fake png"}
          ],
          [:memory]
        )

      files = [%{filename: "gtfs.zip", content: zip_binary}]

      # Should not error - extensions with no references are logged and skipped
      assert {:ok, result} =
               Import.import_files(organization.id, gtfs_version.id, files)

      assert result.counts.levels == 1
      # Extensions files should not appear in unrecognized
      assert result.unrecognized_files == []
    end

    test "zip with top-level folder imports extensions and restores image files", %{
      organization: organization,
      gtfs_version: gtfs_version
    } do
      levels_content = "level_id,level_index,level_name\n32095_BUSWAY,0.0,Busway"

      stops_content =
        "stop_id,stop_name,stop_lat,stop_lon,location_type\n32095,Olney Transit Center,40.0,-75.0,1"

      manifest_json =
        Jason.encode!(%{
          "version" => 1,
          "exported_at" => "2026-02-25T00:00:00Z",
          "stop_diagram_coordinates" => [
            %{"stop_id" => "32095", "diagram_coordinate" => %{"x" => 49.4, "y" => 19.6}}
          ],
          "stop_levels" => [
            %{
              "stop_id" => "32095",
              "level_id" => "32095_BUSWAY",
              "diagram_filename" => "lvl_busway.png",
              "scale_point_a" => %{"x" => 10.0, "y" => 20.0},
              "scale_point_b" => %{"x" => 20.0, "y" => 20.0},
              "scale_distance_meters" => "3.0",
              "scale_meters_per_unit" => "0.3"
            }
          ],
          "route_active_flags" => [],
          "diagram_images" => [
            %{
              "station_stop_id" => "32095",
              "filename" => "lvl_busway.png",
              "zip_path" => "_pathways_extensions/diagrams/32095/lvl_busway.png"
            }
          ]
        })

      {:ok, {_name, zip_binary}} =
        :zip.create(
          ~c"gtfs.zip",
          [
            {~c"gtfs_export/levels.txt", levels_content},
            {~c"gtfs_export/stops.txt", stops_content},
            {~c"gtfs_export/_pathways_extensions.json", manifest_json},
            {~c"gtfs_export/_pathways_extensions/diagrams/32095/lvl_busway.png", "fake png"},
            {~c"__MACOSX/._levels.txt", "ignored"}
          ],
          [:memory]
        )

      files = [%{filename: "gtfs.zip", content: zip_binary}]

      assert {:ok, result} =
               Import.import_files(organization.id, gtfs_version.id, files)

      assert result.counts.levels == 1
      assert result.counts.stops == 1
      assert result.counts.extensions_stop_coordinates == 1
      assert result.counts.extensions_stop_levels == 1
      assert result.counts.extensions_images == 1
      assert result.unrecognized_files == []
      assert result.extensions == :complete
      assert Import.Result.publishable?(result)

      uploads_path = Application.fetch_env!(:gtfs_planner, :uploads_path)

      restored =
        Path.join([
          uploads_path,
          "diagrams",
          organization.id,
          gtfs_version.id,
          "32095",
          "lvl_busway.png"
        ])

      assert File.read!(restored) == "fake png"
    end

    test "zip without root folder imports extensions and restores image files", %{
      organization: organization,
      gtfs_version: gtfs_version
    } do
      levels_content = "level_id,level_index,level_name\n32095_BUSWAY,0.0,Busway"

      stops_content =
        "stop_id,stop_name,stop_lat,stop_lon,location_type\n32095,Olney Transit Center,40.0,-75.0,1"

      manifest_json =
        Jason.encode!(%{
          "version" => 1,
          "exported_at" => "2026-02-25T00:00:00Z",
          "stop_diagram_coordinates" => [
            %{"stop_id" => "32095", "diagram_coordinate" => %{"x" => 49.4, "y" => 19.6}}
          ],
          "stop_levels" => [
            %{
              "stop_id" => "32095",
              "level_id" => "32095_BUSWAY",
              "diagram_filename" => "lvl_busway_no_root.png",
              "scale_point_a" => %{"x" => 10.0, "y" => 20.0},
              "scale_point_b" => %{"x" => 20.0, "y" => 20.0},
              "scale_distance_meters" => "3.0",
              "scale_meters_per_unit" => "0.3"
            }
          ],
          "route_active_flags" => [],
          "diagram_images" => [
            %{
              "station_stop_id" => "32095",
              "filename" => "lvl_busway_no_root.png",
              "zip_path" => "_pathways_extensions/diagrams/32095/lvl_busway_no_root.png"
            }
          ]
        })

      {:ok, {_name, zip_binary}} =
        :zip.create(
          ~c"gtfs.zip",
          [
            {~c"levels.txt", levels_content},
            {~c"stops.txt", stops_content},
            {~c"_pathways_extensions.json", manifest_json},
            {~c"_pathways_extensions/diagrams/32095/lvl_busway_no_root.png", "fake png no root"}
          ],
          [:memory]
        )

      files = [%{filename: "gtfs.zip", content: zip_binary}]

      assert {:ok, result} =
               Import.import_files(organization.id, gtfs_version.id, files)

      assert result.counts.levels == 1
      assert result.counts.stops == 1
      assert result.counts.extensions_stop_coordinates == 1
      assert result.counts.extensions_stop_levels == 1
      assert result.counts.extensions_images == 1
      assert result.unrecognized_files == []
      assert result.extensions == :complete
      assert Import.Result.publishable?(result)

      uploads_path = Application.fetch_env!(:gtfs_planner, :uploads_path)

      restored =
        Path.join([
          uploads_path,
          "diagrams",
          organization.id,
          gtfs_version.id,
          "32095",
          "lvl_busway_no_root.png"
        ])

      assert File.read!(restored) == "fake png no root"
    end

    test "expand_archives returns warning for corrupt zip" do
      files = [%{filename: "bad.zip", content: "not a real zip"}]
      {expanded, warnings} = Import.expand_archives(files)
      assert expanded == []
      assert [%{filename: "bad.zip", reason: :unzip_failed}] = warnings
    end

    test "import_files returns archive warnings when zip cannot be expanded", %{
      organization: organization,
      gtfs_version: gtfs_version
    } do
      files = [%{filename: "bad.zip", content: "not a real zip"}]

      assert {:ok, result} =
               Import.import_files(organization.id, gtfs_version.id, files)

      assert result.unrecognized_files == []
      assert [%{filename: "bad.zip", reason: :unzip_failed}] = result.archive_warnings
      refute Import.Result.publishable?(result)
    end

    test "ignored and nested zip entries count toward archive limits" do
      entries =
        Enum.map(1..10_000, fn idx ->
          {~c"__MACOSX/ignored_#{idx}.txt", "x"}
        end) ++ [{~c"nested.zip", "nested"}]

      {:ok, {_name, zip_binary}} = :zip.create(~c"too_many_ignored.zip", entries, [:memory])

      {expanded, warnings} =
        Import.expand_archives([%{filename: "too_many_ignored.zip", content: zip_binary}])

      assert expanded == []

      assert [
               %{
                 filename: "too_many_ignored.zip",
                 reason: :archive_too_large,
                 detail: detail
               }
             ] = warnings

      assert detail =~ "too_many_entries"
    end

    test "expand_archives returns archive_too_large when extracted bytes exceed limits" do
      original_total_limit =
        Application.get_env(:gtfs_planner, :import_max_zip_uncompressed_bytes)

      original_entry_limit =
        Application.get_env(:gtfs_planner, :import_max_zip_entry_uncompressed_bytes)

      on_exit(fn ->
        case original_total_limit do
          nil -> Application.delete_env(:gtfs_planner, :import_max_zip_uncompressed_bytes)
          value -> Application.put_env(:gtfs_planner, :import_max_zip_uncompressed_bytes, value)
        end

        case original_entry_limit do
          nil ->
            Application.delete_env(:gtfs_planner, :import_max_zip_entry_uncompressed_bytes)

          value ->
            Application.put_env(:gtfs_planner, :import_max_zip_entry_uncompressed_bytes, value)
        end
      end)

      Application.put_env(:gtfs_planner, :import_max_zip_uncompressed_bytes, 1_000)
      Application.put_env(:gtfs_planner, :import_max_zip_entry_uncompressed_bytes, 10)

      zip_binary =
        zip_with_patched_central_directory_uncompressed_size(
          [{~c"big.txt", String.duplicate("a", 20)}],
          1
        )

      {expanded, warnings} =
        Import.expand_archives([%{filename: "post_unzip.zip", content: zip_binary}])

      assert expanded == []

      assert [
               %{
                 filename: "post_unzip.zip",
                 reason: :archive_too_large,
                 detail: detail
               }
             ] = warnings

      assert detail =~ "entry_too_large"
    end

    test "zip size check accepts 500MB exactly" do
      max_total_bytes = 500 * 1024 * 1024

      limits = %{
        max_entries: 10_000,
        max_total_bytes: max_total_bytes,
        max_entry_bytes: max_total_bytes
      }

      assert Import.zip_entry_sizes_within_limits?([max_total_bytes], limits)
    end

    test "default per-entry cap accepts a single 500MB entry" do
      with_entry_limit_unset(fn ->
        limits = Import.zip_limits()
        assert Import.zip_entry_sizes_within_limits?([500 * 1024 * 1024], limits)
      end)
    end

    test "default per-entry cap rejects 500MB + 1 byte for a single entry" do
      with_entry_limit_unset(fn ->
        limits = Import.zip_limits()
        refute Import.zip_entry_sizes_within_limits?([500 * 1024 * 1024 + 1], limits)
      end)
    end

    test "default per-entry cap accepts a typical large GTFS stop_times.txt" do
      with_entry_limit_unset(fn ->
        entry_sizes = [143_966_327, 1, 1, 1, 1]
        assert Import.zip_entry_sizes_within_limits?(entry_sizes, Import.zip_limits())
      end)
    end

    test "explicit per-entry config below the default is honored" do
      with_entry_limit_unset(fn ->
        Application.put_env(
          :gtfs_planner,
          :import_max_zip_entry_uncompressed_bytes,
          100 * 1024 * 1024
        )

        limits = Import.zip_limits()
        refute Import.zip_entry_sizes_within_limits?([200 * 1024 * 1024], limits)
      end)
    end

    test "zip size check rejects 500MB + 1 byte" do
      max_total_bytes = 500 * 1024 * 1024

      limits = %{
        max_entries: 10_000,
        max_total_bytes: max_total_bytes,
        max_entry_bytes: max_total_bytes
      }

      refute Import.zip_entry_sizes_within_limits?([max_total_bytes, 1], limits)
    end

    test "zip size check rejects entries above per-entry cap" do
      limits = %{
        max_entries: 10_000,
        max_total_bytes: 500 * 1024 * 1024,
        max_entry_bytes: 100 * 1024 * 1024
      }

      refute Import.zip_entry_sizes_within_limits?([100 * 1024 * 1024 + 1], limits)
    end
  end

  describe "import_files/4 extensions phase" do
    setup do
      organization = GtfsPlanner.OrganizationsFixtures.organization_fixture()
      gtfs_version = GtfsPlanner.VersionsFixtures.gtfs_version_fixture(organization.id)

      # Own a unique upload root so version isolation/cleanup never touches the shared root.
      previous = Application.get_env(:gtfs_planner, :uploads_path)

      root =
        Path.join(System.tmp_dir!(), "import_ext_phase_#{System.unique_integer([:positive])}")

      Application.put_env(:gtfs_planner, :uploads_path, root)

      on_exit(fn ->
        File.rm_rf!(root)

        if is_nil(previous) do
          Application.delete_env(:gtfs_planner, :uploads_path)
        else
          Application.put_env(:gtfs_planner, :uploads_path, previous)
        end
      end)

      %{organization: organization, gtfs_version: gtfs_version}
    end

    defp full_feed_with_extensions(manifest_json, image_files, opts \\ []) do
      levels_content = "level_id,level_index,level_name\n32095_BUSWAY,0.0,Busway"

      stops_content =
        "stop_id,stop_name,stop_lat,stop_lon,location_type\n32095,Olney,40.0,-75.0,1"

      image_entry =
        if Keyword.get(opts, :omit_image, false) do
          []
        else
          [
            {~c"_pathways_extensions/diagrams/32095/lvl.png",
             Map.get(image_files, "_pathways_extensions/diagrams/32095/lvl.png", "")}
          ]
        end

      {:ok, {_name, zip_binary}} =
        :zip.create(
          ~c"gtfs.zip",
          [
            {~c"levels.txt", levels_content},
            {~c"stops.txt", stops_content},
            {~c"_pathways_extensions.json", manifest_json}
            | image_entry
          ],
          [:memory]
        )

      zip_binary
    end

    defp manifest_with_image do
      Jason.encode!(%{
        "version" => 1,
        "exported_at" => "2026-02-25T00:00:00Z",
        "stop_diagram_coordinates" => [],
        "stop_levels" => [
          %{
            "stop_id" => "32095",
            "level_id" => "32095_BUSWAY",
            "diagram_filename" => "lvl.png",
            "scale_point_a" => %{"x" => 10.0, "y" => 20.0},
            "scale_point_b" => %{"x" => 20.0, "y" => 20.0},
            "scale_distance_meters" => "3.0",
            "scale_meters_per_unit" => "0.3"
          }
        ],
        "route_active_flags" => [],
        "diagram_images" => [
          %{
            "station_stop_id" => "32095",
            "filename" => "lvl.png",
            "zip_path" => "_pathways_extensions/diagrams/32095/lvl.png"
          }
        ]
      })
    end

    test "complete extension import returns extensions :complete and is publishable", %{
      organization: organization,
      gtfs_version: gtfs_version
    } do
      zip_binary =
        full_feed_with_extensions(manifest_with_image(), %{
          "_pathways_extensions/diagrams/32095/lvl.png" => "fake png"
        })

      assert {:ok, result} =
               Import.import_files(organization.id, gtfs_version.id, [
                 %{filename: "gtfs.zip", content: zip_binary}
               ])

      assert result.extensions == :complete
      assert result.counts.extensions_images == 1
      assert Import.Result.publishable?(result)
    end

    test "missing image binary fails the whole import", %{
      organization: organization,
      gtfs_version: gtfs_version
    } do
      # Reference an image but provide no binary for it (image entry omitted from zip).
      manifest = manifest_with_image()
      zip_binary = full_feed_with_extensions(manifest, %{}, omit_image: true)

      assert {:error, {:image_restore_failed, {:missing_binary, zip_path}}} =
               Import.import_files(organization.id, gtfs_version.id, [
                 %{filename: "gtfs.zip", content: zip_binary}
               ])

      assert zip_path == "_pathways_extensions/diagrams/32095/lvl.png"
    end

    test "unsafe image path fails the whole import", %{
      organization: organization,
      gtfs_version: gtfs_version
    } do
      # Pre-create the referenced station and level via fixtures so the extension
      # manifest validation passes; the standard import below does not recreate them.
      stop_fixture(organization.id, gtfs_version.id, stop_id: "station_main", location_type: 1)
      level_fixture(organization.id, gtfs_version.id, level_id: "L1")

      manifest =
        Jason.encode!(%{
          "version" => 1,
          "exported_at" => "2026-02-25T00:00:00Z",
          "stop_diagram_coordinates" => [],
          "stop_levels" => [
            %{
              "stop_id" => "station_main",
              "level_id" => "L1",
              "diagram_filename" => "../escape.png",
              "scale_point_a" => nil,
              "scale_point_b" => nil,
              "scale_distance_meters" => nil,
              "scale_meters_per_unit" => nil
            }
          ],
          "route_active_flags" => [],
          "diagram_images" => [
            %{
              "station_stop_id" => "station_main",
              "filename" => "../escape.png",
              "zip_path" => "_pathways_extensions/diagrams/station_main/../escape.png"
            }
          ]
        })

      # The unsafe filename must match the manifest's referenced path.
      image_entry =
        {~c"_pathways_extensions/diagrams/station_main/../escape.png", "fake png"}

      # Standard files reference a DIFFERENT level/stop than the fixtures.
      levels_content = "level_id,level_index,level_name\n32095_BUSWAY,0.0,Busway"

      stops_content =
        "stop_id,stop_name,stop_lat,stop_lon,location_type\n32095,Olney,40.0,-75.0,1"

      {:ok, {_name, zip_binary}} =
        :zip.create(
          ~c"gtfs.zip",
          [
            {~c"levels.txt", levels_content},
            {~c"stops.txt", stops_content},
            {~c"_pathways_extensions.json", manifest},
            image_entry
          ],
          [:memory]
        )

      assert {:error, {:image_restore_failed, {:write_failed, _zip_path, :unsafe_path}}} =
               Import.import_files(organization.id, gtfs_version.id, [
                 %{filename: "gtfs.zip", content: zip_binary}
               ])
    end

    test "extension database failure (missing reference) fails the whole import", %{
      organization: organization,
      gtfs_version: gtfs_version
    } do
      manifest =
        Jason.encode!(%{
          "version" => 1,
          "exported_at" => "2026-02-25T00:00:00Z",
          "stop_diagram_coordinates" => [
            %{"stop_id" => "MISSING_STOP", "diagram_coordinate" => %{"x" => 1, "y" => 2}}
          ],
          "stop_levels" => [],
          "route_active_flags" => [],
          "diagram_images" => []
        })

      zip_binary = full_feed_with_extensions(manifest, %{})

      assert {:error, {:missing_references, _refs}} =
               Import.import_files(organization.id, gtfs_version.id, [
                 %{filename: "gtfs.zip", content: zip_binary}
               ])
    end
  end

  defp with_entry_limit_unset(fun) do
    original_entry_limit =
      Application.get_env(:gtfs_planner, :import_max_zip_entry_uncompressed_bytes)

    Application.delete_env(:gtfs_planner, :import_max_zip_entry_uncompressed_bytes)

    try do
      fun.()
    after
      case original_entry_limit do
        nil ->
          Application.delete_env(:gtfs_planner, :import_max_zip_entry_uncompressed_bytes)

        value ->
          Application.put_env(:gtfs_planner, :import_max_zip_entry_uncompressed_bytes, value)
      end
    end
  end

  defp zip_with_patched_central_directory_uncompressed_size(entries, patched_size) do
    {:ok, {_name, zip_binary}} = :zip.create(~c"patched.zip", entries, [:memory])
    signature = <<0x50, 0x4B, 0x01, 0x02>>
    {central_header_offset, _} = :binary.match(zip_binary, signature)
    size_offset = central_header_offset + 24

    binary_part(zip_binary, 0, size_offset) <>
      <<patched_size::little-32>> <>
      binary_part(zip_binary, size_offset + 4, byte_size(zip_binary) - size_offset - 4)
  end
end
