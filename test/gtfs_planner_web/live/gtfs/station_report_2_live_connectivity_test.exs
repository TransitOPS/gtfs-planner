defmodule GtfsPlannerWeb.Gtfs.StationReport2LiveConnectivityTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts

  # The report is loaded asynchronously; every case waits for the scoped result
  # before asserting on report content.
  defp live_report(conn, path) do
    {:ok, view, _html} = live(conn, path)
    {view, render_async(view, 5_000)}
  end

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

      {_view, html} =
        live_report(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report")

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

      {_view, html} =
        live_report(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report")

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

      {view, _html} =
        live_report(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report")

      # Side Entrance has no pathways → zero reachability → alert
      assert has_element?(
               view,
               "[role='alert']:not(#client-error):not(#server-error):not(#gtfs-version-failure)"
             )

      alert_html =
        view
        |> element(
          "[role='alert']:not(#client-error):not(#server-error):not(#gtfs-version-failure)"
        )
        |> render()

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

      {_view, html} =
        live_report(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report")

      # Entrance-to-platform has partial connectivity (ENT_B disconnected) → Fail badge
      assert html =~ "Fail"
    end

    test "toggling dimension shows and hides route detail inline", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {view, _html} =
        live_report(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report")

      # Open entrance_to_platform detail
      view
      |> element(
        "button[phx-click='toggle_connectivity_dimension'][phx-value-dimension='entrance_to_platform']"
      )
      |> render_click()

      html = render(view)
      assert html =~ "Entrance to platform"
      assert html =~ "Reachable"

      # Every source row for the dimension is now disclosed on screen.
      assert has_element?(view, "#connectivity-detail-entrance_to_platform-ENT_A")

      refute has_element?(
               view,
               "#connectivity-detail-entrance_to_platform-ENT_A[class*='hidden']"
             )

      # Close it again
      view
      |> element(
        "button[phx-click='toggle_connectivity_dimension'][phx-value-dimension='entrance_to_platform']"
      )
      |> render_click()

      # The detail is hidden on screen again, but stays in the document so that
      # printing still carries the evidence.
      assert has_element?(
               view,
               "#connectivity-detail-entrance_to_platform-ENT_A[class*='hidden']"
             )

      assert has_element?(
               view,
               "#connectivity-detail-entrance_to_platform-ENT_A[class*='print:block']"
             )
    end

    test "multiple dimensions can be open simultaneously", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {view, _html} =
        live_report(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report")

      # Open both entrance_to_platform and platform_to_platform
      view
      |> element(
        "button[phx-click='toggle_connectivity_dimension'][phx-value-dimension='entrance_to_platform']"
      )
      |> render_click()

      view
      |> element(
        "button[phx-click='toggle_connectivity_dimension'][phx-value-dimension='platform_to_platform']"
      )
      |> render_click()

      html = render(view)
      # Both dimensions should show route detail sections
      assert html =~ "Entrance-to-Platform Reachability"
      assert html =~ "Platform Interconnection Reachability"
    end

    test "target rows show route badges when dimension is open", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {view, _html} =
        live_report(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report")

      view
      |> element(
        "button[phx-click='toggle_connectivity_dimension'][phx-value-dimension='entrance_to_platform']"
      )
      |> render_click()

      # Reachability is stated in words beside its semantic token, per AC-9.
      assert has_element?(
               view,
               "[data-source-row='entrance_to_platform-ENT_A'] [data-route-status]",
               "Reachable"
             )

      assert has_element?(
               view,
               "[data-source-row='entrance_to_platform-ENT_B'] [data-route-status]",
               "No path"
             )
    end

    test "expanding a target row shows step table", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {view, _html} =
        live_report(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report")

      # Open the dimension first
      view
      |> element(
        "button[phx-click='toggle_connectivity_dimension'][phx-value-dimension='entrance_to_platform']"
      )
      |> render_click()

      # Click expand on a reachable target
      view
      |> element(
        "button[phx-click='toggle_route_expand'][phx-value-source_id='ENT_A'][phx-value-target_id='PLAT_1']"
      )
      |> render_click()

      assert has_element?(view, "#route-ENT_A-PLAT_1")

      # The step table is a real table with real header cells.
      for header <- ["Mode", "Stop name", "Instruction"] do
        assert has_element?(view, "#route-ENT_A-PLAT_1 table thead tr th", header),
               "expected a step-table column header #{inspect(header)}"
      end
    end

    test "expanding a no-path target shows explanatory message", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {view, _html} =
        live_report(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report")

      view
      |> element(
        "button[phx-click='toggle_connectivity_dimension'][phx-value-dimension='entrance_to_platform']"
      )
      |> render_click()

      # An unreachable pair is named in words rather than painted, so the
      # disclosure control carries no status colour of its own.
      assert has_element?(
               view,
               "[data-source-row='entrance_to_platform-ENT_B'] [data-route-status='nopath']",
               "No path"
             )

      # Click expand on a no-path target
      view
      |> element(
        "button[phx-click='toggle_route_expand'][phx-value-source_id='ENT_B'][phx-value-target_id='PLAT_1']"
      )
      |> render_click()

      assert has_element?(view, "#route-ENT_B-PLAT_1", "No directed path exists")
      refute has_element?(view, "#route-ENT_B-PLAT_1[class*='hidden']")

      # Click again to collapse
      view
      |> element(
        "button[phx-click='toggle_route_expand'][phx-value-source_id='ENT_B'][phx-value-target_id='PLAT_1']"
      )
      |> render_click()

      assert has_element?(view, "#route-ENT_B-PLAT_1[class*='hidden']")
      assert has_element?(view, "#route-ENT_B-PLAT_1[class*='print:block']")

      assert has_element?(
               view,
               "button[phx-click='toggle_route_expand'][phx-value-source_id='ENT_B'][phx-value-target_id='PLAT_1'][aria-expanded='false']"
             )
    end

    test "URL with dimensions param restores open dimensions", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {view, html} =
        live_report(
          conn,
          "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report?dimensions=platform_to_platform"
        )

      assert html =~ "Platform to platform"
      assert html =~ "Platform Interconnection Reachability"

      # The URL seeds server-owned disclosure, not client DOM state.
      assert has_element?(view, "#connectivity-detail-platform_to_platform-PLAT_1")

      refute has_element?(
               view,
               "#connectivity-detail-platform_to_platform-PLAT_1[class*='hidden']"
             )
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

      {view, _html} =
        live_report(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report")

      # Open the entrance_to_platform dimension
      view
      |> element(
        "button[phx-click='toggle_connectivity_dimension'][phx-value-dimension='entrance_to_platform']"
      )
      |> render_click()

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

  describe "Connectivity inaccessible row highlight" do
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
          stop_id: "STATION_INACC",
          stop_name: "Inaccessible Row Station",
          location_type: 1,
          parent_station: nil
        })

      _level1 =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "L_INACC_STREET",
          level_name: "Street",
          level_index: 0.0
        })

      _level2 =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "L_INACC_PLATFORM",
          level_name: "Platform",
          level_index: -1.0
        })

      entrance =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "ENT_INACC",
          stop_name: "Stairs Entrance",
          location_type: 2,
          parent_station: station.stop_id,
          level_id: "L_INACC_STREET"
        })

      platform =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "PLAT_INACC",
          stop_name: "Stairs Platform",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: "L_INACC_PLATFORM"
        })

      _pw_stairs =
        pathway_fixture(organization.id, gtfs_version.id, entrance.stop_id, platform.stop_id, %{
          pathway_id: "PW_INACC_STAIRS",
          pathway_mode: 2,
          is_bidirectional: true,
          traversal_time: 30
        })

      %{
        user: user,
        organization: organization,
        gtfs_version: gtfs_version,
        station: station
      }
    end

    test "a reachable stairs-only route states not accessible in words", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {view, _html} =
        live_report(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report")

      view
      |> element(
        "button[phx-click='toggle_connectivity_dimension'][phx-value-dimension='entrance_to_platform']"
      )
      |> render_click()

      target = target_button("ENT_INACC", "PLAT_INACC")

      # Accessibility is the shared three-state presentation, not a generic badge
      # and never colour alone.
      assert has_element?(
               view,
               "#{target} [data-accessibility='not_accessible']",
               "Not accessible"
             )

      assert has_element?(view, "#{target}[aria-expanded='false']")

      view |> element(target) |> render_click()

      assert has_element?(view, "#route-ENT_INACC-PLAT_INACC")
      assert has_element?(view, "#{target}[aria-expanded='true']")
      refute has_element?(view, "#route-ENT_INACC-PLAT_INACC[class*='hidden']")

      view |> element(target) |> render_click()

      # Collapsed on screen, still in the document for print.
      assert has_element?(view, "#route-ENT_INACC-PLAT_INACC[class*='hidden']")
      assert has_element?(view, "#route-ENT_INACC-PLAT_INACC[class*='print:block']")
      assert has_element?(view, "#{target}[aria-expanded='false']")
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

      {view, _html} =
        live_report(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report")

      # Open the entrance_to_platform dimension
      view
      |> element(
        "button[phx-click='toggle_connectivity_dimension'][phx-value-dimension='entrance_to_platform']"
      )
      |> render_click()

      # Expand the ENT_SIGN → PLAT_SIGN route
      view
      |> element(
        "button[phx-click='toggle_route_expand'][phx-value-source_id='ENT_SIGN'][phx-value-target_id='PLAT_SIGN']"
      )
      |> render_click()

      # The forward route's own steps carry the forward signpost only; the
      # reverse signpost belongs to the platform-to-exit route.
      route_html = view |> element("#route-ENT_SIGN-PLAT_SIGN") |> render()

      assert route_html =~ "To Platform"
      refute route_html =~ "To Exit"
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

      {view, _html} =
        live_report(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report")

      assert has_element?(view, "#report2-reachability-connectivity")
    end

    test "a dimension with no sources explains the gap instead of an empty table", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {view, _html} =
        live_report(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report")

      for dimension <- [:entrance_to_platform, :platform_to_platform, :platform_to_exit] do
        assert has_element?(view, "#connectivity-empty-#{dimension}"),
               "expected an explained empty state for #{dimension}"
      end

      bodies =
        view
        |> element("#report2-reachability-connectivity")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("tbody")
        |> Enum.to_list()

      for body <- bodies do
        refute body |> LazyHTML.query("tr") |> Enum.empty?(),
               "the connectivity section renders an empty table body instead of an empty state"
      end
    end
  end

  describe "Connectivity presentation contracts" do
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
          stop_id: "STATION_PRES",
          stop_name: "Presentation Station",
          location_type: 1,
          parent_station: nil
        })

      _level =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "L_PRES",
          level_name: "Street",
          level_index: 0.0
        })

      connected =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "ENT_FULL",
          stop_name: "Connected Entrance",
          location_type: 2,
          parent_station: station.stop_id,
          level_id: "L_PRES"
        })

      _orphan =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "ENT_NONE",
          stop_name: "Orphan Entrance",
          location_type: 2,
          parent_station: station.stop_id,
          level_id: "L_PRES"
        })

      plat_a =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "PLAT_A",
          stop_name: "Platform A",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: "L_PRES"
        })

      _plat_b =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "PLAT_B",
          stop_name: "Platform B",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: "L_PRES"
        })

      # ENT_FULL reaches PLAT_A only, so its row is partial; ENT_NONE reaches
      # nothing, so its row is none. PLAT_A reaches no other platform.
      _pw =
        pathway_fixture(organization.id, gtfs_version.id, connected.stop_id, plat_a.stop_id, %{
          pathway_id: "PW_PRES",
          pathway_mode: 1,
          is_bidirectional: true,
          traversal_time: 40
        })

      %{
        user: user,
        organization: organization,
        gtfs_version: gtfs_version,
        station: station
      }
    end

    test "reachability states are readable as words for partial and none", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {view, _html} =
        live_report(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report")

      assert has_element?(
               view,
               "[data-source-row='entrance_to_platform-ENT_FULL'] [data-reachability='partial']",
               "Partially reachable"
             )

      assert has_element?(
               view,
               "[data-source-row='entrance_to_platform-ENT_NONE'] [data-reachability='none']",
               "Not reachable"
             )
    end

    test "a source row discloses through a real button, never an interactive row", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {view, _html} =
        live_report(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report")

      button =
        "button[phx-click='toggle_connectivity_source'][phx-value-dimension='entrance_to_platform'][phx-value-source_stop_id='ENT_FULL']"

      assert has_element?(
               view,
               "#{button}[aria-expanded='false'][aria-controls='connectivity-detail-entrance_to_platform-ENT_FULL']"
             )

      view |> element(button) |> render_click()

      assert has_element?(view, "#{button}[aria-expanded='true']")

      refute has_element?(view, "#report2-reachability-connectivity tr[role='button']")
      refute has_element?(view, "#report2-reachability-connectivity [phx-keydown]")
    end

    test "the dimension count strip reports sources, targets, and connected pairs", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {view, _html} =
        live_report(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report")

      strip = "#connectivity-entrance_to_platform-counts"

      assert has_element?(view, "#{strip}[data-role='count-strip'][data-mode='display']")
      assert has_element?(view, "#{strip}-item-sources", "Sources")
      assert has_element?(view, "#{strip}-item-targets", "Targets")
      assert has_element?(view, "#{strip}-item-connected_pairs", "Connected pairs")
      assert has_element?(view, "#{strip}-item-unreachable_pairs", "Unreachable pairs")
      refute has_element?(view, "#{strip} button")
    end

    test "route totals and accessibility keep their calculated values", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {view, _html} =
        live_report(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report")

      route_html = view |> element("#route-ENT_FULL-PLAT_A") |> render()

      # 40s is the fixture's single traversal time; the presentation rewrite must
      # not change what the Connectivity builder calculated.
      assert route_html =~ "40s"

      assert has_element?(
               view,
               "#{target_button("ENT_FULL", "PLAT_A")} [data-accessibility='accessible']",
               "Accessible"
             )

      assert has_element?(
               view,
               "#{target_button("ENT_NONE", "PLAT_A")} [data-accessibility='unknown']",
               "No data"
             )
    end
  end

  defp target_button(source_id, target_id) do
    "button[phx-click='toggle_route_expand'][phx-value-source_id='#{source_id}'][phx-value-target_id='#{target_id}']"
  end
end
