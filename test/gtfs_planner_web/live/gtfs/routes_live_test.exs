defmodule GtfsPlannerWeb.Gtfs.RoutesLiveTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  alias GtfsPlanner.Accounts

  describe "RoutesLive filtering and search" do
    setup do
      organization = organization_fixture()
      user = user_fixture()

      # Create user membership in organization with GTFS access
      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_viewer"]
      })

      gtfs_version = gtfs_version_fixture(organization.id)

      %{user: user, organization: organization, gtfs_version: gtfs_version}
    end

    test "filters routes by type", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      # Create routes with different types
      _tram_route = route_fixture(organization.id, version.id, %{route_id: "TRAM1", route_type: 0})
      bus_route = route_fixture(organization.id, version.id, %{route_id: "BUS1", route_type: 3})
      _subway_route = route_fixture(organization.id, version.id, %{route_id: "SUBWAY1", route_type: 1})

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      # Filter by bus routes (route_type: 3)
      html =
        view
        |> form("#route-filter-form", %{"route_type" => "3"})
        |> render_change()

      # Assert filtered routes appear
      assert html =~ bus_route.route_id
      refute html =~ "TRAM1"
      refute html =~ "SUBWAY1"

      # Assert URL contains filter param
      assert_patched(view, "/gtfs/#{version.id}/routes?route_type=3")
    end

    test "searches routes by name", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      # Create routes with different names
      express_route =
        route_fixture(organization.id, version.id, %{
          route_id: "EXP1",
          route_short_name: "Express 1",
          route_long_name: "Downtown Express"
        })

      _local_route =
        route_fixture(organization.id, version.id, %{
          route_id: "LOCAL1",
          route_short_name: "Local 1",
          route_long_name: "Local Service"
        })

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      # Search for "express" routes
      html =
        view
        |> form("#search-form", %{"search" => "express"})
        |> render_change()

      # Assert matching routes appear
      assert html =~ express_route.route_id
      assert html =~ "Express"
      refute html =~ "LOCAL1"
      refute html =~ "Local Service"
    end

    test "sorts routes by column", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      # Create routes with specific short names
      _route_a =
        route_fixture(organization.id, version.id, %{route_id: "R1", route_short_name: "Alpha"})

      _route_b =
        route_fixture(organization.id, version.id, %{route_id: "R2", route_short_name: "Bravo"})

      route_c =
        route_fixture(organization.id, version.id, %{route_id: "R3", route_short_name: "Charlie"})

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      # Click sort header for route_short_name
      html =
        view
        |> element("[phx-value-column=route_short_name]")
        |> render_click()

      # Assert sort indicator appears (ascending first)
      assert html =~ "▲"

      # Click again to sort descending
      html =
        view
        |> element("[phx-value-column=route_short_name]")
        |> render_click()

      # Assert sort indicator changes to descending
      assert html =~ "▼"

      # Assert routes are in descending order (Charlie should be first)
      # Get the tbody content
      tbody_html = view |> element("tbody#routes") |> render()

      # Charlie should appear before Alpha in the HTML
      charlie_pos = :binary.match(tbody_html, route_c.route_id) |> elem(0)
      alpha_pos = :binary.match(tbody_html, "R1") |> elem(0)
      assert charlie_pos < alpha_pos
    end
  end
end
