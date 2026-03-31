defmodule GtfsPlannerWeb.Gtfs.StationReport2LiveConnectivityTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts

  describe "Connectivity section" do
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
          stop_id: "STATION_CONN",
          stop_name: "Connectivity Test Station",
          location_type: 1,
          parent_station: nil
        })

      _level1 =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "L_STREET",
          level_name: "Street",
          level_index: 0.0
        })

      _level2 =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "L_PLATFORM",
          level_name: "Platform",
          level_index: -1.0
        })

      # 2 entrances
      ent_a =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "ENT_A",
          stop_name: "Main Entrance",
          location_type: 2,
          parent_station: station.stop_id,
          level_id: "L_STREET"
        })

      _ent_b =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "ENT_B",
          stop_name: "Side Entrance",
          location_type: 2,
          parent_station: station.stop_id,
          level_id: "L_STREET"
        })

      # 1 generic node
      _node =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "NODE_1",
          stop_name: "Central Node",
          location_type: 3,
          parent_station: station.stop_id,
          level_id: "L_STREET"
        })

      # 2 platforms
      plat_1 =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "PLAT_1",
          stop_name: "Northbound Platform",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: "L_PLATFORM"
        })

      plat_2 =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "PLAT_2",
          stop_name: "Southbound Platform",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: "L_PLATFORM"
        })

      # Pathways: ENT_A → NODE_1 → PLAT_1, ENT_A → NODE_1 → PLAT_2 (all bidirectional)
      _pw1 =
        pathway_fixture(organization.id, gtfs_version.id, ent_a.stop_id, "NODE_1", %{
          pathway_id: "PW_1",
          pathway_mode: 1,
          is_bidirectional: true,
          traversal_time: 30
        })

      _pw2 =
        pathway_fixture(organization.id, gtfs_version.id, "NODE_1", plat_1.stop_id, %{
          pathway_id: "PW_2",
          pathway_mode: 5,
          is_bidirectional: true,
          traversal_time: 45
        })

      _pw3 =
        pathway_fixture(organization.id, gtfs_version.id, "NODE_1", plat_2.stop_id, %{
          pathway_id: "PW_3",
          pathway_mode: 1,
          is_bidirectional: true,
          traversal_time: 20
        })

      # ENT_B is disconnected — no pathways
      # This creates a partially-connected scenario

      %{
        user: user,
        organization: organization,
        gtfs_version: gtfs_version,
        station: station
      }
    end

    test "summary view renders three dimension cards", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, _view, html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report_2")

      assert html =~ "Entrance-to-Platform Reachability"
      assert html =~ "Platform Interconnection Reachability"
      assert html =~ "Platform-to-Exit Reachability"
    end

    test "summary table shows source entity names and reachable/unreachable targets", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, _view, html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report_2")

      assert html =~ "Main Entrance"
      assert html =~ "Side Entrance"
      assert html =~ "Northbound Platform"
      assert html =~ "Southbound Platform"
    end

    test "disconnected entrance shows alert banner with role=alert", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report_2")

      # Side Entrance has no pathways → zero reachability → alert
      assert has_element?(view, "[role='alert']:not(#client-error):not(#server-error)")
      alert_html = view |> element("[role='alert']:not(#client-error):not(#server-error)") |> render()
      assert alert_html =~ "Side Entrance"
      assert alert_html =~ "Needs immediate attention"
    end

    test "dimension badges reflect status correctly", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, _view, html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report_2")

      # Entrance-to-platform has partial connectivity (ENT_B disconnected) → Fail badge
      assert html =~ "Fail"
    end

    test "clicking summary row navigates to detail view with query params", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report_2")

      # Click the first row in entrance-to-platform table (use text match for uniqueness)
      view
      |> element(
        "button[phx-click='navigate_connectivity_detail'][phx-value-dimension='entrance_to_platform']",
        "Main Entrance"
      )
      |> render_click()

      # URL should update with connectivity=detail
      path = "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report_2?connectivity=detail&dimension=entrance_to_platform"
      assert_patch(view, path)
    end

    test "detail view renders source group cards", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, _view, html} =
        live(
          conn,
          "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report_2?connectivity=detail&dimension=entrance_to_platform"
        )

      # Route detail header
      assert html =~ "Connectivity — Route Detail"
      assert html =~ "Entrance to platform"

      # Source names
      assert html =~ "Main Entrance"
      assert html =~ "Side Entrance"
    end

    test "back link from detail returns to summary view", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(
          conn,
          "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report_2?connectivity=detail&dimension=entrance_to_platform"
        )

      # Click back to summary
      view
      |> element("button", "Summary")
      |> render_click()

      path = "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report_2"
      assert_patch(view, path)
    end

    test "target rows show route badges", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, _view, html} =
        live(
          conn,
          "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report_2?connectivity=detail&dimension=entrance_to_platform"
        )

      # Connected targets should show Reachable badge
      assert html =~ "Reachable"
      # Disconnected targets (Side Entrance → platforms) should show No path
      assert html =~ "No path"
    end

    test "expanding a target row shows step table", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(
          conn,
          "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report_2?connectivity=detail&dimension=entrance_to_platform"
        )

      # Click expand on a reachable target
      view
      |> element(
        "button[phx-click='toggle_route_expand'][phx-value-source_id='ENT_A'][phx-value-target_id='PLAT_1']"
      )
      |> render_click()

      html = render(view)
      assert has_element?(view, "#route-ENT_A-PLAT_1")
      # Step table should be visible with semantic table markup
      assert html =~ "<thead>"
      assert html =~ "Mode"
      assert html =~ "Stop name"
      assert html =~ "Instruction"
    end

    test "expanding a no-path target shows explanatory message", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(
          conn,
          "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report_2?connectivity=detail&dimension=entrance_to_platform"
        )

      # Click expand on a no-path target
      view
      |> element(
        "button[phx-click='toggle_route_expand'][phx-value-source_id='ENT_B'][phx-value-target_id='PLAT_1']"
      )
      |> render_click()

      html = render(view)
      assert html =~ "No directed path exists"

      # Click again to collapse
      view
      |> element(
        "button[phx-click='toggle_route_expand'][phx-value-source_id='ENT_B'][phx-value-target_id='PLAT_1']"
      )
      |> render_click()

      html = render(view)
      refute html =~ "No directed path exists"
    end

    test "URL refresh restores correct view state", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      # Load directly into detail view via URL
      {:ok, _view, html} =
        live(
          conn,
          "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report_2?connectivity=detail&dimension=platform_to_platform"
        )

      assert html =~ "Connectivity — Route Detail"
      assert html =~ "Platform to platform"
    end
  end

  describe "Connectivity accessible_note" do
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
          stop_id: "STATION_ACC",
          stop_name: "Accessible Note Station",
          location_type: 1,
          parent_station: nil
        })

      _level1 =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "L_ACC_STREET",
          level_name: "Street",
          level_index: 0.0
        })

      _level2 =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "L_ACC_PLATFORM",
          level_name: "Platform",
          level_index: -1.0
        })

      entrance =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "ENT_ACC",
          stop_name: "Accessible Entrance",
          location_type: 2,
          parent_station: station.stop_id,
          level_id: "L_ACC_STREET"
        })

      # Intermediate nodes for diverging paths
      _node_stairs =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "NODE_STAIRS",
          stop_name: "Stairs Node",
          location_type: 3,
          parent_station: station.stop_id,
          level_id: "L_ACC_PLATFORM"
        })

      _node_elev =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "NODE_ELEV",
          stop_name: "Elevator Node",
          location_type: 3,
          parent_station: station.stop_id,
          level_id: "L_ACC_PLATFORM"
        })

      platform =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "PLAT_ACC",
          stop_name: "Accessible Platform",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: "L_ACC_PLATFORM"
        })

      # Short path via stairs (mode 2): ENT_ACC → NODE_STAIRS → PLAT_ACC
      # General BFS picks this as shortest (30s total)
      _pw_stair1 =
        pathway_fixture(organization.id, gtfs_version.id, entrance.stop_id, "NODE_STAIRS", %{
          pathway_id: "PW_STAIR1",
          pathway_mode: 2,
          is_bidirectional: true,
          traversal_time: 15
        })

      _pw_stair2 =
        pathway_fixture(organization.id, gtfs_version.id, "NODE_STAIRS", platform.stop_id, %{
          pathway_id: "PW_STAIR2",
          pathway_mode: 1,
          is_bidirectional: true,
          traversal_time: 15
        })

      # Longer path via elevator (mode 5): ENT_ACC → NODE_ELEV → PLAT_ACC
      # Step-free BFS picks this (50s total, but stairs are filtered)
      _pw_elev1 =
        pathway_fixture(organization.id, gtfs_version.id, entrance.stop_id, "NODE_ELEV", %{
          pathway_id: "PW_ELEV1",
          pathway_mode: 1,
          is_bidirectional: true,
          traversal_time: 25
        })

      _pw_elev2 =
        pathway_fixture(organization.id, gtfs_version.id, "NODE_ELEV", platform.stop_id, %{
          pathway_id: "PW_ELEV2",
          pathway_mode: 5,
          is_bidirectional: true,
          traversal_time: 25
        })

      %{
        user: user,
        organization: organization,
        gtfs_version: gtfs_version,
        station: station
      }
    end

    test "shows elevator route available when general path uses stairs but step-free path uses elevator",
         %{
           conn: conn,
           user: user,
           organization: organization,
           gtfs_version: gtfs_version,
           station: station
         } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(
          conn,
          "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report_2?connectivity=detail&dimension=entrance_to_platform"
        )

      # Expand the ENT_ACC → PLAT_ACC route
      view
      |> element(
        "button[phx-click='toggle_route_expand'][phx-value-source_id='ENT_ACC'][phx-value-target_id='PLAT_ACC']"
      )
      |> render_click()

      html = render(view)
      assert html =~ "elevator route available"
    end
  end

  describe "Connectivity signposted_as direction" do
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
          stop_id: "STATION_SIGN",
          stop_name: "Signage Test Station",
          location_type: 1,
          parent_station: nil
        })

      _level =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "L_SIGN_STREET",
          level_name: "Street",
          level_index: 0.0
        })

      entrance =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "ENT_SIGN",
          stop_name: "Signage Entrance",
          location_type: 2,
          parent_station: station.stop_id,
          level_id: "L_SIGN_STREET"
        })

      platform =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "PLAT_SIGN",
          stop_name: "Signage Platform",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: "L_SIGN_STREET"
        })

      # Bidirectional pathway from entrance → platform with both signage fields.
      _pw =
        pathway_fixture(organization.id, gtfs_version.id, entrance.stop_id, platform.stop_id, %{
          pathway_id: "PW_SIGN",
          pathway_mode: 1,
          is_bidirectional: true,
          traversal_time: 20,
          signposted_as: "To Platform",
          reversed_signposted_as: "To Exit"
        })

      %{
        user: user,
        organization: organization,
        gtfs_version: gtfs_version,
        station: station
      }
    end

    test "entrance-to-platform step shows forward signposted_as", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(
          conn,
          "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report_2?connectivity=detail&dimension=entrance_to_platform"
        )

      # Expand the ENT_SIGN → PLAT_SIGN route
      view
      |> element(
        "button[phx-click='toggle_route_expand'][phx-value-source_id='ENT_SIGN'][phx-value-target_id='PLAT_SIGN']"
      )
      |> render_click()

      html = render(view)
      # Forward traversal should show signposted_as
      assert html =~ "To Platform"
      refute html =~ "To Exit"
    end

  end

  describe "Connectivity empty state" do
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
          stop_id: "STATION_EMPTY",
          stop_name: "Empty Station",
          location_type: 1,
          parent_station: nil
        })

      %{
        user: user,
        organization: organization,
        gtfs_version: gtfs_version,
        station: station
      }
    end

    test "station with no child stops shows connectivity section without crash", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report_2")

      assert has_element?(view, "#report2-reachability-connectivity")
    end
  end
end
