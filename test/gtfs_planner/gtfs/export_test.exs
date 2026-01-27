defmodule GtfsPlanner.Gtfs.ExportTest do
  use GtfsPlanner.DataCase

  alias GtfsPlanner.Gtfs.Export

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  setup do
    user = user_fixture()
    organization = organization_fixture()
    gtfs_version = gtfs_version_fixture(organization.id)

    %{
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      organization_id: organization.id,
      gtfs_version_id: gtfs_version.id
    }
  end

  describe "export_to_zip/3 with :pathways type" do
    test "generates ZIP with stops.txt, levels.txt, and pathways.txt", %{
      organization_id: org_id,
      gtfs_version_id: version_id
    } do
      # Create test data
      stop1 = stop_fixture(org_id, version_id, stop_id: "STOP1")

      stop2 =
        stop_fixture(org_id, version_id, stop_id: "STOP2")

      _level1 =
        level_fixture(org_id, version_id, level_id: "LEVEL1")

      pathway_fixture(
        org_id,
        version_id,
        stop1.id,
        stop2.id,
        pathway_id: "PATH1"
      )

      # Export
      assert {:ok, zip_binary} = Export.export_to_zip(org_id, version_id, :pathways)
      assert is_binary(zip_binary)

      # Unzip and verify files
      {:ok, files} = :zip.unzip(zip_binary, [:memory])
      filenames = Enum.map(files, fn {name, _content} -> to_string(name) end)

      assert "stops.txt" in filenames
      assert "levels.txt" in filenames
      assert "pathways.txt" in filenames

      # Verify stops.txt content
      {_, stops_content} = Enum.find(files, fn {name, _} -> to_string(name) == "stops.txt" end)
      stops_lines = String.split(to_string(stops_content), "\n", trim: true)
      assert length(stops_lines) >= 2
      assert hd(stops_lines) =~ "stop_id"

      # Verify levels.txt content
      {_, levels_content} = Enum.find(files, fn {name, _} -> to_string(name) == "levels.txt" end)
      levels_lines = String.split(to_string(levels_content), "\n", trim: true)
      assert length(levels_lines) >= 2
      assert hd(levels_lines) =~ "level_id"

      # Verify pathways.txt content
      {_, pathways_content} =
        Enum.find(files, fn {name, _} -> to_string(name) == "pathways.txt" end)

      pathways_lines = String.split(to_string(pathways_content), "\n", trim: true)
      assert length(pathways_lines) >= 2
      assert hd(pathways_lines) =~ "pathway_id"
    end

    test "excludes other GTFS files", %{organization_id: org_id, gtfs_version_id: version_id} do
      # Create stops and levels for pathways export
      stop_fixture(org_id, version_id, stop_id: "STOP1")
      level_fixture(org_id, version_id, level_id: "LEVEL1")

      # Create data for files that should NOT be in pathways export
      agency_fixture(org_id, version_id, agency_id: "AGENCY1")

      route_fixture(
        org_id,
        version_id,
        route_id: "ROUTE1",
        route_short_name: "1"
      )

      assert {:ok, zip_binary} = Export.export_to_zip(org_id, version_id, :pathways)

      {:ok, files} = :zip.unzip(zip_binary, [:memory])
      filenames = Enum.map(files, fn {name, _content} -> to_string(name) end)

      # Should NOT include agency, routes, etc.
      refute "agency.txt" in filenames
      refute "routes.txt" in filenames
      refute "trips.txt" in filenames
    end
  end

  describe "export_to_zip/3 with :full type" do
    test "generates ZIP with all GTFS files that have data", %{
      organization_id: org_id,
      gtfs_version_id: version_id
    } do
      # Create test data for various file types
      agency_fixture(org_id, version_id, agency_id: "AGENCY1")
      stop_fixture(org_id, version_id, stop_id: "STOP1")

      route_fixture(
        org_id,
        version_id,
        route_id: "ROUTE1",
        route_short_name: "1"
      )

      assert {:ok, zip_binary} = Export.export_to_zip(org_id, version_id, :full)
      assert is_binary(zip_binary)

      {:ok, files} = :zip.unzip(zip_binary, [:memory])
      filenames = Enum.map(files, fn {name, _content} -> to_string(name) end)

      # Should include files with data
      assert "agency.txt" in filenames
      assert "stops.txt" in filenames
      assert "routes.txt" in filenames
    end

    test "returns error when no data exists", %{
      organization_id: org_id,
      gtfs_version_id: version_id
    } do
      # Don't create any data
      assert {:error, :no_data} = Export.export_to_zip(org_id, version_id, :full)
    end
  end

  describe "CSV format compliance" do
    test "excludes internal fields from exported CSV", %{
      organization_id: org_id,
      gtfs_version_id: version_id
    } do
      stop_fixture(org_id, version_id, stop_id: "STOP1")

      assert {:ok, zip_binary} = Export.export_to_zip(org_id, version_id, :pathways)

      {:ok, files} = :zip.unzip(zip_binary, [:memory])
      {_, stops_content} = Enum.find(files, fn {name, _} -> to_string(name) == "stops.txt" end)
      stops_csv = to_string(stops_content)
      header = stops_csv |> String.split("\n") |> hd()

      # Should NOT include internal fields
      columns = String.split(header, ",")
      refute "id" in columns
      refute "organization_id" in columns
      refute "gtfs_version_id" in columns
      refute "inserted_at" in columns
      refute "updated_at" in columns
      refute "diagram_coordinate" in columns

      # Should include GTFS fields
      assert header =~ "stop_id"
    end

    test "resolves UUID foreign keys to GTFS string IDs", %{
      organization_id: org_id,
      gtfs_version_id: version_id
    } do
      # Create parent station
      parent_station =
        stop_fixture(
          org_id,
          version_id,
          stop_id: "PARENT_STATION",
          location_type: 1
        )

      # Create level
      level =
        level_fixture(org_id, version_id, level_id: "LEVEL1")

      # Create child stop with parent_station and level references
      stop_fixture(
        org_id,
        version_id,
        stop_id: "CHILD_STOP",
        parent_station: parent_station.stop_id,
        level_id: level.level_id,
        location_type: 0
      )

      assert {:ok, zip_binary} = Export.export_to_zip(org_id, version_id, :pathways)

      {:ok, files} = :zip.unzip(zip_binary, [:memory])
      {_, stops_content} = Enum.find(files, fn {name, _} -> to_string(name) == "stops.txt" end)
      stops_csv = to_string(stops_content)

      # Find the child stop row
      child_row =
        stops_csv
        |> String.split("\n", trim: true)
        |> Enum.find(fn line -> line =~ "CHILD_STOP" end)

      # Should contain GTFS string IDs, not UUIDs
      assert child_row =~ "PARENT_STATION"
      assert child_row =~ "LEVEL1"

      # Should NOT contain UUID format
      refute child_row =~ ~r/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/
    end

    test "properly escapes CSV fields with special characters", %{
      organization_id: org_id,
      gtfs_version_id: version_id
    } do
      # Create stop with special characters in name
      stop_fixture(
        org_id,
        version_id,
        stop_id: "STOP1",
        stop_name: "Station, Platform \"A\""
      )

      assert {:ok, zip_binary} = Export.export_to_zip(org_id, version_id, :pathways)

      {:ok, files} = :zip.unzip(zip_binary, [:memory])
      {_, stops_content} = Enum.find(files, fn {name, _} -> to_string(name) == "stops.txt" end)
      stops_csv = to_string(stops_content)

      # Find the stop row
      stop_row =
        stops_csv
        |> String.split("\n", trim: true)
        |> Enum.find(fn line -> line =~ "STOP1" end)

      # Field with comma and quotes should be quoted and quotes should be doubled
      assert stop_row =~ ~s("Station, Platform ""A""")
    end
  end

  describe "edge cases" do
    test "handles empty version (no data)", %{
      organization_id: org_id,
      gtfs_version_id: version_id
    } do
      assert {:error, :no_data} = Export.export_to_zip(org_id, version_id, :pathways)
    end

    test "filters data by organization and version", %{
      organization_id: org_id,
      gtfs_version_id: version_id
    } do
      # Create data for this version
      stop_fixture(org_id, version_id, stop_id: "STOP1")

      # Create data for a different organization
      other_org = organization_fixture()
      other_version = gtfs_version_fixture(other_org.id)

      stop_fixture(
        other_org.id,
        other_version.id,
        stop_id: "OTHER_STOP"
      )

      assert {:ok, zip_binary} = Export.export_to_zip(org_id, version_id, :pathways)

      {:ok, files} = :zip.unzip(zip_binary, [:memory])
      {_, stops_content} = Enum.find(files, fn {name, _} -> to_string(name) == "stops.txt" end)
      stops_csv = to_string(stops_content)

      # Should include only this version's data
      assert stops_csv =~ "STOP1"
      refute stops_csv =~ "OTHER_STOP"
    end
  end
end
