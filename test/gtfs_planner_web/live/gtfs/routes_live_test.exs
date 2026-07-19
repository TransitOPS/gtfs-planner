defmodule GtfsPlannerWeb.Gtfs.RoutesLiveTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  alias GtfsPlanner.Accounts

  describe "RoutesLive shared table contract" do
    setup do
      organization = organization_fixture()
      user = user_fixture()

      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_editor"]
      })

      gtfs_version = gtfs_version_fixture(organization.id)

      %{user: user, organization: organization, gtfs_version: gtfs_version}
    end

    test "renders one shared table with stable tbody ID and route badge", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      route_fixture(organization.id, version.id, %{
        route_id: "SHARED1",
        route_short_name: "S1",
        route_color: "FF0000"
      })

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      html = render(view)
      doc = LazyHTML.from_fragment(html)

      assert Enum.count(LazyHTML.query(doc, "table")) == 1
      assert Enum.count(LazyHTML.query(doc, "tbody#routes")) == 1
      assert Enum.count(LazyHTML.query(doc, "#routes-container")) == 1
    end

    test "renders shared pagination with configured event", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      Enum.each(1..51, fn idx ->
        route_fixture(organization.id, version.id, %{
          route_id: "PG#{String.pad_leading(Integer.to_string(idx), 3, "0")}"
        })
      end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      assert has_element?(view, "button[phx-click='paginate']", "Previous")
      assert has_element?(view, "button[phx-click='paginate']", "Next")
    end

    test "does not duplicate route or action IDs", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      route_fixture(organization.id, version.id, %{route_id: "DEDUP1"})
      route_fixture(organization.id, version.id, %{route_id: "DEDUP2"})

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      html = render(view)
      doc = LazyHTML.from_fragment(html)

      assert Enum.count(LazyHTML.query(doc, "table")) == 1
      assert Enum.count(LazyHTML.query(doc, "tbody")) == 1
    end
  end

  describe "RoutesLive filtering and search" do
    setup do
      organization = organization_fixture()
      user = user_fixture()

      # Create user membership in organization with GTFS access
      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_editor"]
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
      _tram_route =
        route_fixture(organization.id, version.id, %{route_id: "TRAM1", route_type: 0})

      bus_route = route_fixture(organization.id, version.id, %{route_id: "BUS1", route_type: 3})

      _subway_route =
        route_fixture(organization.id, version.id, %{route_id: "SUBWAY1", route_type: 1})

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

      # Click sort header for route_short_name (shared table uses phx-value-key)
      html =
        view
        |> element("[phx-value-key=route_short_name]")
        |> render_click()

      # Assert sort indicator appears (ascending first)
      assert html =~ "▲"

      # Click again to sort descending
      html =
        view
        |> element("[phx-value-key=route_short_name]")
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

    test "paginates routes", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      Enum.each(1..51, fn idx ->
        route_fixture(organization.id, version.id, %{
          route_id: "R#{String.pad_leading(Integer.to_string(idx), 3, "0")}"
        })
      end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      html =
        view
        |> element("button[phx-click='paginate'][phx-value-page='2']")
        |> render_click()

      assert html =~ "R051"
      refute html =~ "R001"

      assert_patched(
        view,
        "/gtfs/#{version.id}/routes?page=2&sort_by=route_id&sort_dir=asc"
      )
    end
  end
end
