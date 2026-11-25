defmodule GtfsPlannerWeb.Gtfs.StationReport2LiveAccessibilityLinksTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts

  defp live_report(conn, path) do
    {:ok, view, _html} = live(conn, path)
    {view, render_async(view, 5_000)}
  end

  defp report_path(gtfs_version, station),
    do: "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report"

  defp accessibility_path(gtfs_version, station),
    do: "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report/accessibility"

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
        stop_id: "STATION_ACC_LINKS",
        stop_name: "Accessibility Links Station",
        location_type: 1,
        parent_station: nil
      })

    _street =
      level_fixture(organization.id, gtfs_version.id, %{
        level_id: "L_STREET",
        level_name: "Street",
        level_index: 0.0
      })

    _platform_level =
      level_fixture(organization.id, gtfs_version.id, %{
        level_id: "L_PLAT",
        level_name: "Platform",
        level_index: -1.0
      })

    entrance_main =
      stop_fixture(organization.id, gtfs_version.id, %{
        stop_id: "ENT_MAIN",
        stop_name: "Main Entrance",
        location_type: 2,
        parent_station: station.stop_id,
        level_id: "L_STREET",
        wheelchair_boarding: 1
      })

    entrance_isolated =
      stop_fixture(organization.id, gtfs_version.id, %{
        stop_id: "ENT_ISOLATED",
        stop_name: "Isolated Entrance",
        location_type: 2,
        parent_station: station.stop_id,
        level_id: "L_STREET"
      })

    platform_north =
      stop_fixture(organization.id, gtfs_version.id, %{
        stop_id: "PLAT_NORTH",
        stop_name: "Northbound Platform",
        location_type: 0,
        parent_station: station.stop_id,
        level_id: "L_PLAT",
        wheelchair_boarding: 1,
        platform_code: "1"
      })

    platform_south =
      stop_fixture(organization.id, gtfs_version.id, %{
        stop_id: "PLAT_SOUTH",
        stop_name: "Southbound Platform",
        location_type: 0,
        parent_station: station.stop_id,
        level_id: "L_PLAT",
        wheelchair_boarding: 2,
        platform_code: "2"
      })

    _pw_elev =
      pathway_fixture(
        organization.id,
        gtfs_version.id,
        entrance_main.stop_id,
        platform_north.stop_id,
        %{
          pathway_id: "PW_ELEV_MAIN",
          pathway_mode: 5,
          is_bidirectional: true,
          traversal_time: 40,
          min_width: Decimal.new("1.2")
        }
      )

    _pw_walk =
      pathway_fixture(
        organization.id,
        gtfs_version.id,
        platform_north.stop_id,
        platform_south.stop_id,
        %{
          pathway_id: "PW_PLAT_WALK",
          pathway_mode: 1,
          is_bidirectional: true,
          traversal_time: 20,
          min_width: Decimal.new("1.8")
        }
      )

    %{
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      entrance_main: entrance_main,
      entrance_isolated: entrance_isolated,
      platform_north: platform_north,
      platform_south: platform_south
    }
  end

  describe "accessibility links in Routes riders can take" do
    test "renders section CTA link to accessibility views", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)
      {view, _html} = live_report(conn, report_path(gtfs_version, station))

      expected_href = accessibility_path(gtfs_version, station)

      assert has_element?(
               view,
               "#report2-reachability-connectivity a#station-report-accessibility-link[href='#{expected_href}']"
             )
    end

    test "renders per-pair ?from=&to= links on expanded entrance-to-platform cards only", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)
      {view, _html} = live_report(conn, report_path(gtfs_version, station))

      view
      |> element(
        "button[phx-click='toggle_connectivity_dimension'][phx-value-dimension='entrance_to_platform']"
      )
      |> render_click()

      # Reachable entrance-to-platform card
      view
      |> element(
        "button[phx-click='toggle_route_expand'][phx-value-source_id='ENT_MAIN'][phx-value-target_id='PLAT_NORTH']"
      )
      |> render_click()

      expected_reachable_href =
        "#{accessibility_path(gtfs_version, station)}?from=ENT_MAIN&to=PLAT_NORTH"

      assert has_element?(
               view,
               "#route-ENT_MAIN-PLAT_NORTH a#route-accessibility-link-ENT_MAIN-PLAT_NORTH[href='#{expected_reachable_href}']"
             )

      # Unreachable entrance-to-platform card also links to the pair
      view
      |> element(
        "button[phx-click='toggle_route_expand'][phx-value-source_id='ENT_ISOLATED'][phx-value-target_id='PLAT_NORTH']"
      )
      |> render_click()

      expected_isolated_href =
        "#{accessibility_path(gtfs_version, station)}?from=ENT_ISOLATED&to=PLAT_NORTH"

      assert has_element?(
               view,
               "#route-ENT_ISOLATED-PLAT_NORTH a#route-accessibility-link-ENT_ISOLATED-PLAT_NORTH[href='#{expected_isolated_href}']"
             )

      # Non-entrance-to-platform dimensions do not render entrance-to-platform pair links
      view
      |> element(
        "button[phx-click='toggle_connectivity_dimension'][phx-value-dimension='platform_to_platform']"
      )
      |> render_click()

      view
      |> element(
        "button[phx-click='toggle_route_expand'][phx-value-source_id='PLAT_NORTH'][phx-value-target_id='PLAT_SOUTH']"
      )
      |> render_click()

      refute has_element?(
               view,
               "#route-PLAT_NORTH-PLAT_SOUTH a#route-accessibility-link-PLAT_NORTH-PLAT_SOUTH"
             )
    end
  end

  describe "?edit_stop_id=<uuid> deep-link handling (CR-S1 / INV-4)" do
    test "initial mount with valid child stop UUID resolves after async load, opens drawer, and clears param",
         %{
           conn: conn,
           user: user,
           organization: organization,
           gtfs_version: gtfs_version,
           station: station,
           platform_north: platform_north
         } do
      conn = log_in_user(conn, user, organization: organization)
      base_path = report_path(gtfs_version, station)

      {view, _html} = live_report(conn, "#{base_path}?edit_stop_id=#{platform_north.id}")

      assert_patch(view, base_path)

      assert has_element?(view, "#report-stop-edit-form")
      refute has_element?(view, "#flash-error")

      state = :sys.get_state(view.pid)
      assert state.socket.assigns.drawer_entity.id == platform_north.id
      assert is_nil(state.socket.assigns.pending_edit_stop_id)
    end

    test "same-station live patch with valid child stop UUID opens drawer and clears param when already loaded",
         %{
           conn: conn,
           user: user,
           organization: organization,
           gtfs_version: gtfs_version,
           station: station,
           platform_south: platform_south
         } do
      conn = log_in_user(conn, user, organization: organization)
      base_path = report_path(gtfs_version, station)

      {view, _html} = live_report(conn, base_path)
      refute has_element?(view, "#report-stop-edit-form")

      render_patch(view, "#{base_path}?edit_stop_id=#{platform_south.id}")

      assert_patch(view, base_path)
      assert has_element?(view, "#report-stop-edit-form")
      refute has_element?(view, "#flash-error")

      state = :sys.get_state(view.pid)
      assert state.socket.assigns.drawer_entity.id == platform_south.id
    end

    test "malformed UUID flashes generic refusal, keeps drawer closed, and clears param", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)
      base_path = report_path(gtfs_version, station)

      {view, _html} = live_report(conn, "#{base_path}?edit_stop_id=not-a-uuid")

      assert_patch(view, base_path)
      refute has_element?(view, "#report-stop-edit-form")
      refute has_element?(view, "#report-stop-lookup-error")
      assert has_element?(view, "#flash-error")
    end

    test "unknown UUID flashes generic refusal, keeps drawer closed, and clears param", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)
      base_path = report_path(gtfs_version, station)

      {view, _html} = live_report(conn, "#{base_path}?edit_stop_id=#{Ecto.UUID.generate()}")

      assert_patch(view, base_path)
      refute has_element?(view, "#report-stop-edit-form")
      refute has_element?(view, "#report-stop-lookup-error")
      assert has_element?(view, "#flash-error")
    end

    test "stop belonging to another station in the same version flashes generic refusal and keeps drawer closed",
         %{
           conn: conn,
           user: user,
           organization: organization,
           gtfs_version: gtfs_version,
           station: station
         } do
      other_station =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "OTHER_STATION_ACC",
          stop_name: "Other Station",
          location_type: 1
        })

      other_platform =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "OTHER_PLAT",
          stop_name: "Other Station Platform",
          location_type: 0,
          parent_station: other_station.stop_id,
          level_id: "L_PLAT"
        })

      conn = log_in_user(conn, user, organization: organization)
      base_path = report_path(gtfs_version, station)

      {view, _html} = live_report(conn, "#{base_path}?edit_stop_id=#{other_platform.id}")

      assert_patch(view, base_path)
      refute has_element?(view, "#report-stop-edit-form")
      refute has_element?(view, "#report-stop-lookup-error")
      assert has_element?(view, "#flash-error")
    end

    test "stop belonging to another GTFS version flashes generic refusal and keeps drawer closed",
         %{
           conn: conn,
           user: user,
           organization: organization,
           gtfs_version: gtfs_version,
           station: station
         } do
      other_version = gtfs_version_fixture(organization.id)

      other_version_station =
        stop_fixture(organization.id, other_version.id, %{
          stop_id: station.stop_id,
          stop_name: "Other Version Station",
          location_type: 1
        })

      other_version_platform =
        stop_fixture(organization.id, other_version.id, %{
          stop_id: "PLAT_OTHER_VER",
          stop_name: "Other Version Platform",
          location_type: 0,
          parent_station: other_version_station.stop_id
        })

      conn = log_in_user(conn, user, organization: organization)
      base_path = report_path(gtfs_version, station)

      {view, _html} = live_report(conn, "#{base_path}?edit_stop_id=#{other_version_platform.id}")

      assert_patch(view, base_path)
      refute has_element?(view, "#report-stop-edit-form")
      refute has_element?(view, "#report-stop-lookup-error")
      assert has_element?(view, "#flash-error")
    end

    test "stop belonging to another organization flashes generic refusal and keeps drawer closed",
         %{
           conn: conn,
           user: user,
           organization: organization,
           gtfs_version: gtfs_version,
           station: station
         } do
      other_org = organization_fixture()
      other_org_version = gtfs_version_fixture(other_org.id)

      other_org_station =
        stop_fixture(other_org.id, other_org_version.id, %{
          stop_id: station.stop_id,
          stop_name: "Foreign Org Station",
          location_type: 1
        })

      other_org_platform =
        stop_fixture(other_org.id, other_org_version.id, %{
          stop_id: "PLAT_OTHER_ORG",
          stop_name: "Foreign Org Platform",
          location_type: 0,
          parent_station: other_org_station.stop_id
        })

      conn = log_in_user(conn, user, organization: organization)
      base_path = report_path(gtfs_version, station)

      {view, _html} = live_report(conn, "#{base_path}?edit_stop_id=#{other_org_platform.id}")

      assert_patch(view, base_path)
      refute has_element?(view, "#report-stop-edit-form")
      refute has_element?(view, "#report-stop-lookup-error")
      assert has_element?(view, "#flash-error")
    end

    test "same-station live patch with foreign stop UUID flashes generic refusal and keeps drawer closed",
         %{
           conn: conn,
           user: user,
           organization: organization,
           gtfs_version: gtfs_version,
           station: station
         } do
      other_org = organization_fixture()
      other_org_version = gtfs_version_fixture(other_org.id)

      other_org_stop =
        stop_fixture(other_org.id, other_org_version.id, %{
          stop_id: "FOREIGN_PATCH_STOP",
          stop_name: "Foreign Patch Stop",
          location_type: 0
        })

      conn = log_in_user(conn, user, organization: organization)
      base_path = report_path(gtfs_version, station)

      {view, _html} = live_report(conn, base_path)

      render_patch(view, "#{base_path}?edit_stop_id=#{other_org_stop.id}")

      assert_patch(view, base_path)
      refute has_element?(view, "#report-stop-edit-form")
      refute has_element?(view, "#report-stop-lookup-error")
      assert has_element?(view, "#flash-error")
    end
  end
end
