defmodule GtfsPlannerWeb.Gtfs.StationReport2LiveTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs

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

    test "renders report route with all section IDs", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report")

      assert has_element?(view, "#station-sub-nav")
      assert has_element?(view, "#station-report-2")
      assert has_element?(view, "#report2-station-inventory")
      assert has_element?(view, "#report2-data-quality")
      assert has_element?(view, "#report2-gps-checks")
      assert has_element?(view, "#report2-naming-conventions")
      assert has_element?(view, "#report2-reachability-connectivity")
      assert has_element?(view, "#report2-pathway-field-completeness")
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
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report")

      section_ids = [
        "report2-station-inventory",
        "report2-data-quality",
        "report2-gps-checks",
        "report2-naming-conventions",
        "report2-reachability-connectivity",
        "report2-pathway-field-completeness"
      ]

      positions =
        Enum.map(section_ids, fn id ->
          case :binary.match(html, id) do
            {pos, _len} -> pos
            :nomatch -> flunk("Section #{id} not found in HTML")
          end
        end)

      assert positions == Enum.sort(positions),
             "Sections are not in the expected order"
    end

    test "Reports tab is active on report route", %{
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
               "Reports"
             )
    end

    test "station nav has one reports tab and no legacy label", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      report_href = "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report"

      {:ok, view, html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report")

      assert has_element?(
               view,
               "#station-sub-nav a[href='#{report_href}'][aria-current='page']",
               "Reports"
             )

      refute html =~ "Reports New"
      assert length(:binary.matches(html, report_href)) == 1
    end

    test "legacy report route is not defined", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      conn = get(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report_2")
      assert conn.status == 404
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
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report")

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
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report")

      # GPS check labels
      assert html =~ "GPS presence by location type"
      assert html =~ "Longitude sign consistency"

      # GPS table headers
      assert html =~ "Present"
      assert html =~ "Missing"

      # GPS section has status badges
      assert has_element?(view, "#report2-gps-checks .bg-green-100", "Pass")
    end

    test "stop name links use phx-click select_entity", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report")

      # Stop-name links use phx-click="select_entity" instead of navigation hrefs
      assert has_element?(view, "[phx-click='select_entity'][phx-value-entity_type='stop']")
    end

    test "detail links show stop-name text and title with raw stop_id", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version
    } do
      station =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "STATION_DL",
          stop_name: "Detail Link Station",
          location_type: 1,
          stop_lat: Decimal.new("47.0"),
          stop_lon: Decimal.new("122.0")
        })

      _entrance =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "ENT_DL",
          stop_name: "Entrance Detail",
          location_type: 2,
          parent_station: station.stop_id,
          level_id: "L_DL",
          stop_lat: Decimal.new("47.0"),
          stop_lon: Decimal.new("-122.0001")
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report")

      # The stop-name link shows the human-readable name, not the raw ID
      assert has_element?(
               view,
               "[phx-click='select_entity'][phx-value-entity_id='ENT_DL']",
               "Entrance Detail"
             )

      # The title attribute exposes the raw stop_id for inspection
      assert has_element?(
               view,
               "[phx-click='select_entity'][phx-value-entity_id='ENT_DL'][title='ENT_DL']"
             )
    end

    test "clicking a detail link opens the entity drawer", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report")

      refute has_element?(view, "#report-stop-edit-form")

      # Click a stop-name link to open the drawer
      view
      |> element("[phx-click='select_entity'][phx-value-entity_type='stop']", "Entrance")
      |> render_click()

      # Derived native root
      assert has_element?(view, "dialog#report-entity-drawer-overlay")
      assert has_element?(view, "dialog#report-entity-drawer-overlay[data-open='true']")

      # Inner panel preserves caller-facing ID
      assert has_element?(view, "#report-entity-drawer")
      assert has_element?(view, "#report-stop-edit-form")
    end

    test "closing the entity drawer hides the form", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report")

      # Open the drawer
      view
      |> element("[phx-click='select_entity'][phx-value-entity_type='stop']", "Entrance")
      |> render_click()

      assert has_element?(view, "dialog#report-entity-drawer-overlay[data-open='true']")
      assert has_element?(view, "#report-stop-edit-form")

      # Close the drawer
      render_click(view, "close_entity_drawer")

      # Drawer form is removed; native root reflects closed state
      refute has_element?(view, "#report-stop-edit-form")
      assert has_element?(view, "dialog#report-entity-drawer-overlay[data-open='false']")
    end

    test "large detail sets render without nested overflow text", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version
    } do
      station =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "STATION_EXPAND",
          stop_name: "Expand Station",
          location_type: 1,
          parent_station: nil
        })

      # Create many isolated generic nodes (type 3) to trigger a large detail list
      for i <- 1..12 do
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "GEN_EXP_#{i}",
          stop_name: "Generic Node #{i}",
          location_type: 3,
          parent_station: station.stop_id,
          level_id: "L1"
        })
      end

      # Need at least one entrance and platform for minimum_station_children
      _entrance =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "ENT_EXP",
          stop_name: "Entrance Expand",
          location_type: 2,
          parent_station: station.stop_id,
          level_id: "L1"
        })

      _platform =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "PLAT_EXP",
          stop_name: "Platform Expand",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: "L1"
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report")

      # All 12 generic nodes plus the entrance should appear as isolated
      # Verify the last generic node renders (confirms full list is present)
      assert has_element?(view, "[phx-value-entity_id='GEN_EXP_12']")
      # Verify there is no nested "+ N more" overflow element
      refute has_element?(view, "#report2-data-quality details details")
    end

    test "submitting drawer form saves the stop and closes the drawer", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report")

      # Open the drawer
      view
      |> element("[phx-click='select_entity'][phx-value-entity_type='stop']", "Entrance")
      |> render_click()

      assert has_element?(view, "dialog#report-entity-drawer-overlay[data-open='true']")
      assert has_element?(view, "#report-stop-edit-form")

      # Submit the form with changed data
      view
      |> form("#report-stop-edit-form",
        stop: %{
          stop_name: "Changed Name",
          stop_lat: "48.0",
          stop_lon: "-123.0",
          level_id: "L1",
          wheelchair_boarding: "1",
          platform_code: ""
        }
      )
      |> render_submit()

      # LiveView did not crash and report is still visible
      assert has_element?(view, "#station-report-2")

      # Drawer was closed after successful save
      refute has_element?(view, "#report-stop-edit-form")

      # Data was persisted
      reloaded_stop = Gtfs.get_stop_by_stop_id(organization.id, gtfs_version.id, "ENT_1")
      assert reloaded_stop.stop_name == "Changed Name"
    end

    test "naming conventions section renders heading and summary", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, _view, html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report")

      assert html =~ "Naming &amp; ID Conventions"
      assert html =~ "of 6 checks failed"
    end

    test "naming conventions section renders all 6 check rows", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, _view, html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report")

      assert html =~ "Stop name title case"
      assert html =~ "Generic node ID prefix"
      assert html =~ "Boarding area ID prefix"
      assert html =~ "Entrance ID prefix"
      assert html =~ "location type match"
      assert html =~ "human-written"
    end

    test "naming conventions failing check renders FAIL badge", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version
    } do
      station =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "STATION_NC",
          stop_name: "Naming Station",
          location_type: 1,
          parent_station: nil
        })

      # Entrance without entrance_ prefix triggers naming_entrance_prefix failure
      _bad_entrance =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "door_main",
          stop_name: "Main Door",
          location_type: 2,
          parent_station: station.stop_id,
          level_id: "L1"
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report")

      assert has_element?(view, "#report2-naming-conventions .bg-red-100", "FAIL")
    end

    test "naming conventions passing check renders PASS badge", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report")

      assert has_element?(view, "#report2-naming-conventions .bg-green-100", "PASS")
    end

    test "naming conventions prefix mismatch includes expected prefix", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version
    } do
      station =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "STATION_PM",
          stop_name: "Prefix Mismatch Station",
          location_type: 1,
          parent_station: nil
        })

      # boarding_ prefix on an entrance (type 2) triggers prefix_type_mismatch
      _mismatched =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "boarding_north",
          stop_name: "North Boarding",
          location_type: 2,
          parent_station: station.stop_id,
          level_id: "L1"
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, _view, html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report")

      assert html =~ "Expected prefix"
      assert html =~ "entrance_"
    end

    test "redirects with flash when station is missing", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version
    } do
      conn = log_in_user(conn, user, organization: organization)

      assert {:error, {:live_redirect, %{to: to_path, flash: %{"error" => "Station not found"}}}} =
               live(conn, "/gtfs/#{gtfs_version.id}/stops/UNKNOWN/report")

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
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report")

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
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report")

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
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report")

      assert html =~ "L1"
      assert html =~ "Street"
    end
  end
end
