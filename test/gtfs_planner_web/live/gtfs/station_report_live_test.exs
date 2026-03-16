defmodule GtfsPlannerWeb.Gtfs.StationReportLiveTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs

  describe "StationReportLive" do
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

      level_1 =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "L1",
          level_name: "Street",
          level_index: 0.0
        })

      level_2 =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "L2",
          level_name: "Platform",
          level_index: 1.0
        })

      {:ok, _} =
        Gtfs.create_stop_level(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: station.id,
          level_id: level_1.id
        })

      {:ok, _} =
        Gtfs.create_stop_level(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: station.id,
          level_id: level_2.id
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
          level_id: "L2"
        })

      _boarding =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "BOARD_1",
          stop_name: "Boarding 1",
          location_type: 4,
          parent_station: platform.stop_id,
          level_id: "L2"
        })

      _pathway =
        pathway_fixture(organization.id, gtfs_version.id, entrance.stop_id, platform.stop_id, %{
          pathway_id: "PATH_1",
          pathway_mode: 5,
          is_bidirectional: true,
          min_width: Decimal.new("1.5"),
          signposted_as: "To platform",
          reversed_signposted_as: "To entrance"
        })

      _pathway_to_boarding =
        pathway_fixture(organization.id, gtfs_version.id, platform.stop_id, "BOARD_1", %{
          pathway_id: "PATH_2",
          pathway_mode: 1,
          is_bidirectional: true,
          length: Decimal.new("8.0"),
          signposted_as: "Boarding 1",
          reversed_signposted_as: "From boarding"
        })

      %{
        user: user,
        organization: organization,
        gtfs_version: gtfs_version,
        station: station
      }
    end

    test "renders report route with stable section and item IDs", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report")

      assert has_element?(view, "#station-sub-nav")
      assert has_element?(view, "#station-report")
      assert has_element?(view, "#report-section-inventory")
      assert has_element?(view, "#report-section-data_integrity")
      assert has_element?(view, "#report-section-entrance_platform_connectivity")
      assert has_element?(view, "#report-item-node_inventory")
      assert has_element?(view, "#report-item-step_free_routes")
      assert has_element?(view, "#report-item-entrance_platform_paths")
      assert has_element?(view, "#report-item-unavailable_metrics")
      assert has_element?(view, "#report-summary-completeness-methodology-toggle", "methodology")

      assert has_element?(
               view,
               "#report-section-data_integrity-methodology-toggle",
               "methodology"
             )

      assert has_element?(view, "#report-section-accessibility-methodology-toggle", "methodology")

      assert has_element?(
               view,
               "#report-section-entrance_platform_connectivity-methodology-toggle",
               "methodology"
             )

      assert has_element?(
               view,
               "#report-section-attribute_completeness-methodology-toggle",
               "methodology"
             )

      assert has_element?(
               view,
               "#station-sub-nav a[aria-current='page']",
               "Report"
             )
    end

    test "toggles methodology mode in data quality section on and off", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report")

      assert has_element?(view, "#report-item-isolated_nodes")
      refute has_element?(view, "#report-section-data_integrity-methodology")

      view
      |> element("#report-section-data_integrity-methodology-toggle")
      |> render_click()

      assert has_element?(view, "#report-section-data_integrity-methodology")

      assert has_element?(
               view,
               "#report-method-data_integrity-isolated_nodes"
             )

      refute has_element?(view, "#report-item-isolated_nodes")
      assert has_element?(view, "#report-section-data_integrity-methodology-toggle", "back")

      view
      |> element("#report-section-data_integrity-methodology-toggle")
      |> render_click()

      refute has_element?(view, "#report-section-data_integrity-methodology")
      assert has_element?(view, "#report-item-isolated_nodes")

      assert has_element?(
               view,
               "#report-section-data_integrity-methodology-toggle",
               "methodology"
             )
    end

    test "methodology toggles remain independent across accessibility, connectivity, and completeness",
         %{
           conn: conn,
           user: user,
           organization: organization,
           gtfs_version: gtfs_version,
           station: station
         } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report")

      view
      |> element("#report-section-accessibility-methodology-toggle")
      |> render_click()

      assert has_element?(view, "#report-section-accessibility-methodology")
      assert has_element?(view, "#report-method-accessibility-step_free_routes")
      refute has_element?(view, "#report-item-step_free_routes")
      assert has_element?(view, "#report-item-entrance_platform_paths")
      assert has_element?(view, "#report-item-pathway_attribute_completeness")

      view
      |> element("#report-section-entrance_platform_connectivity-methodology-toggle")
      |> render_click()

      assert has_element?(view, "#report-section-accessibility-methodology")
      assert has_element?(view, "#report-section-entrance_platform_connectivity-methodology")

      assert has_element?(
               view,
               "#report-method-entrance_platform_connectivity-entrance_platform_paths"
             )

      refute has_element?(view, "#report-item-entrance_platform_paths")
      assert has_element?(view, "#report-item-pathway_attribute_completeness")

      view
      |> element("#report-section-attribute_completeness-methodology-toggle")
      |> render_click()

      assert has_element?(view, "#report-section-accessibility-methodology")
      assert has_element?(view, "#report-section-entrance_platform_connectivity-methodology")
      assert has_element?(view, "#report-section-attribute_completeness-methodology")
      assert has_element?(view, "#report-method-attribute_completeness-signage_completeness")
      refute has_element?(view, "#report-item-pathway_attribute_completeness")
      assert has_element?(view, "#report-section-not_available")

      view
      |> element("#report-section-accessibility-methodology-toggle")
      |> render_click()

      refute has_element?(view, "#report-section-accessibility-methodology")
      assert has_element?(view, "#report-item-step_free_routes")
      assert has_element?(view, "#report-section-entrance_platform_connectivity-methodology")
      assert has_element?(view, "#report-section-attribute_completeness-methodology")
    end

    test "toggles path direction and renders trip visualization containers", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report")

      pair_dom = "ENT_1__BOARD_1"

      view
      |> element("#report-entrance-ENT_1 > summary")
      |> render_click()

      assert has_element?(view, "#report-trip-visualization-#{pair_dom}")
      assert has_element?(view, "#report-trip-summary-#{pair_dom}")
      assert has_element?(view, "#report-trip-timeline-#{pair_dom}")
      assert has_element?(view, "#report-trip-steps-#{pair_dom}")
      assert has_element?(view, "#report-trip-profile-#{pair_dom}")
      assert has_element?(view, "#report-trip-analysis-#{pair_dom}")
      assert has_element?(view, "#report-trip-direction-button-#{pair_dom}", "Forward view")

      assert has_element?(
               view,
               "#report-trip-steps-#{pair_dom} tbody tr:nth-child(1) td:nth-child(4)",
               "To platform"
             )

      assert has_element?(
               view,
               "#report-trip-steps-#{pair_dom} tbody tr:nth-child(2) td:nth-child(4)",
               "Boarding 1"
             )

      view
      |> element("#report-trip-direction-button-#{pair_dom}")
      |> render_click()

      assert has_element?(view, "#report-trip-direction-button-#{pair_dom}", "Reverse view")

      assert has_element?(
               view,
               "#report-trip-steps-#{pair_dom} tbody tr:nth-child(1) td:nth-child(4)",
               "From boarding"
             )

      assert has_element?(
               view,
               "#report-trip-steps-#{pair_dom} tbody tr:nth-child(2) td:nth-child(4)",
               "To entrance"
             )
    end

    test "uses reverse signage when the final segment is traversed against pathway direction", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version
    } do
      station =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "STATION_REV",
          stop_name: "Reverse Signage Station",
          location_type: 1,
          parent_station: nil
        })

      level_1 =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "L1_REV",
          level_name: "Street",
          level_index: 0.0
        })

      level_2 =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "L2_REV",
          level_name: "Platform",
          level_index: 1.0
        })

      {:ok, _} =
        Gtfs.create_stop_level(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: station.id,
          level_id: level_1.id
        })

      {:ok, _} =
        Gtfs.create_stop_level(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: station.id,
          level_id: level_2.id
        })

      entrance =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "ENT_REV",
          stop_name: "Reverse Entrance",
          location_type: 2,
          parent_station: station.stop_id,
          level_id: "L1_REV"
        })

      concourse =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "GEN_REV",
          stop_name: "Reverse Concourse",
          location_type: 3,
          parent_station: station.stop_id,
          level_id: "L1_REV"
        })

      platform =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "PLAT_REV",
          stop_name: "Reverse Platform",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: "L2_REV"
        })

      _boarding =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "BOARD_REV",
          stop_name: "Reverse Boarding",
          location_type: 4,
          parent_station: platform.stop_id,
          level_id: "L2_REV"
        })

      _lobby =
        pathway_fixture(organization.id, gtfs_version.id, entrance.stop_id, concourse.stop_id, %{
          pathway_id: "PATH_REV_1",
          pathway_mode: 1,
          is_bidirectional: true,
          signposted_as: "To concourse",
          reversed_signposted_as: "To entrance"
        })

      _final =
        pathway_fixture(organization.id, gtfs_version.id, "BOARD_REV", concourse.stop_id, %{
          pathway_id: "PATH_REV_2",
          pathway_mode: 1,
          is_bidirectional: true,
          signposted_as: "To concourse",
          reversed_signposted_as: "To platform"
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report")

      pair_dom = "ENT_REV__BOARD_REV"

      view
      |> element("#report-entrance-ENT_REV > summary")
      |> render_click()

      assert has_element?(
               view,
               "#report-trip-steps-#{pair_dom} tbody tr:nth-child(2) td:nth-child(4)",
               "To platform"
             )

      refute has_element?(
               view,
               "#report-trip-steps-#{pair_dom} tbody tr:nth-child(2) td:nth-child(4)",
               "To concourse"
             )

      view
      |> element("#report-trip-direction-button-#{pair_dom}")
      |> render_click()

      assert has_element?(
               view,
               "#report-trip-steps-#{pair_dom} tbody tr:nth-child(1) td:nth-child(4)",
               "To concourse"
             )
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

    test "station sub-nav renders report tab on details and diagram pages", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, details_view, _html} = live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}")

      assert has_element?(
               details_view,
               "#station-sub-nav a[href='/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report']",
               "Report"
             )

      {:ok, diagram_view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram")

      assert has_element?(
               diagram_view,
               "#station-sub-nav a[href='/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report']",
               "Report"
             )
    end
  end
end
