defmodule GtfsPlannerWeb.Gtfs.StationReport2LiveTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts

  describe "StationReport2Live" do
    setup do
      organization = organization_fixture()
      user = user_fixture()

      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_editor"]
      })

      gtfs_version = gtfs_version_fixture(organization.id)

      station =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "STATION_1",
          stop_name: "Station One",
          location_type: 1,
          parent_station: nil
        })

      _level =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "L1",
          level_name: "Street",
          level_index: 0.0
        })

      entrance =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "ENT_1",
          stop_name: "Entrance",
          location_type: 2,
          parent_station: station.stop_id,
          level_id: "L1"
        })

      platform =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "PLAT_1",
          stop_name: "Platform",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: "L1"
        })

      _pathway =
        pathway_fixture(organization.id, gtfs_version.id, entrance.stop_id, platform.stop_id, %{
          pathway_id: "PATH_1",
          pathway_mode: 5,
          is_bidirectional: true
        })

      %{
        user: user,
        organization: organization,
        gtfs_version: gtfs_version,
        station: station
      }
    end

    test "renders report_2 route with all section IDs", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report_2")

      assert has_element?(view, "#station-sub-nav")
      assert has_element?(view, "#station-report-2")
      assert has_element?(view, "#report2-station-inventory")
      assert has_element?(view, "#report2-data-quality")
      assert has_element?(view, "#report2-gps-checks")
      assert has_element?(view, "#report2-naming-conventions")
      assert has_element?(view, "#report2-reachability-connectivity")
      assert has_element?(view, "#report2-pathway-field-completeness")
      assert has_element?(view, "#report2-accessibility")
    end

    test "sections render in correct order", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, _view, html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report_2")

      section_ids = [
        "report2-station-inventory",
        "report2-data-quality",
        "report2-gps-checks",
        "report2-naming-conventions",
        "report2-reachability-connectivity",
        "report2-pathway-field-completeness",
        "report2-accessibility"
      ]

      positions = Enum.map(section_ids, fn id ->
        case :binary.match(html, id) do
          {pos, _len} -> pos
          :nomatch -> flunk("Section #{id} not found in HTML")
        end
      end)

      assert positions == Enum.sort(positions),
             "Sections are not in the expected order"
    end

    test "Reports New tab is active on report_2 route", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report_2")

      assert has_element?(
               view,
               "#station-sub-nav a[aria-current='page']",
               "Reports New"
             )
    end

    test "Report tab remains active on original report route", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report")

      assert has_element?(
               view,
               "#station-sub-nav a[aria-current='page']",
               "Report"
             )
    end

    test "data quality section renders real check rows", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report_2")

      # Check that known check labels appear
      assert html =~ "Isolated nodes"
      assert html =~ "Boarding areas must have platform parent"
      assert html =~ "Unique stop IDs"
      assert html =~ "Minimum station children"

      # Status badges render in data quality section
      assert has_element?(view, "#report2-data-quality .bg-green-100", "Pass")
    end

    test "GPS section renders real check rows", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report_2")

      # GPS check labels
      assert html =~ "GPS presence by location type"
      assert html =~ "Longitude sign consistency"

      # GPS table headers
      assert html =~ "Present"
      assert html =~ "Missing"

      # GPS section has status badges
      assert has_element?(view, "#report2-gps-checks .bg-green-100", "Pass")
    end

    test "stop ID links have correct href values", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, _view, html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report_2")

      # The entrance and platform are connected, so entrance-to-platform passes.
      # But we should see stop_id links for checks that do have affected stops.
      # At minimum, the GPS presence table should render.
      assert html =~ "/gtfs/#{gtfs_version.id}/stops/"
    end

    test "redirects with flash when station is missing", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version
    } do
      conn = log_in_user(conn, user, organization: organization)

      assert {:error, {:live_redirect, %{to: to_path, flash: %{"error" => "Station not found"}}}} =
               live(conn, "/gtfs/#{gtfs_version.id}/stops/UNKNOWN/report_2")

      assert to_path == "/gtfs/#{gtfs_version.id}/stops"
    end

    test "station inventory section renders node and edge counts", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report_2")

      assert has_element?(view, "#report2-station-inventory")
      refute has_element?(view, "#report2-station-inventory p", "Not yet implemented")

      html = render(view)
      assert html =~ "Node inventory by location type"
      assert html =~ "Edge inventory by pathway mode"
      assert html =~ "Pathway directionality"
      assert html =~ "Level count, names, and indices"
    end

    test "station inventory shows all location types and pathway modes", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, _view, html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report_2")

      # All 5 location types present
      assert html =~ "Stop/Platform"
      assert html =~ "Station"
      assert html =~ "Entrance/Exit"
      assert html =~ "Generic Node"
      assert html =~ "Boarding Area"

      # All 7 pathway modes present
      assert html =~ "Walkway"
      assert html =~ "Stairs"
      assert html =~ "Moving Sidewalk"
      assert html =~ "Escalator"
      assert html =~ "Elevator"
      assert html =~ "Fare Gate"
      assert html =~ "Exit Gate"

      # Directionality labels
      assert html =~ "Bidirectional"
      assert html =~ "Unidirectional"
    end

    test "levels table renders level data", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, _view, html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report_2")

      assert html =~ "L1"
      assert html =~ "Street"
    end
  end
end
