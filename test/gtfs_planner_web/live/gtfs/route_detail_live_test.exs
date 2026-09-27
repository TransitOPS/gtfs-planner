defmodule GtfsPlannerWeb.Gtfs.RouteDetailLiveTest do
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.CatalogReadAdapter
  alias GtfsPlanner.Gtfs.CatalogReadAdapterMock

  @adapter_key :gtfs_catalog_read_adapter

  setup :verify_on_exit!

  # The real context serves every successful read; the adapter substitution
  # exists only to simulate a lost database connection, and is restored on exit.
  defp substitute_read_adapter(_context) do
    previous = Application.fetch_env(:gtfs_planner, @adapter_key)
    Application.put_env(:gtfs_planner, @adapter_key, CatalogReadAdapterMock)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:gtfs_planner, @adapter_key, value)
        :error -> Application.delete_env(:gtfs_planner, @adapter_key)
      end
    end)

    :ok
  end

  defp shared_setup(%{conn: conn}) do
    organization =
      organization_fixture(%{alias: "route-detail-#{System.system_time(:nanosecond)}"})

    user =
      user_fixture(%{email: "route-detail-#{System.unique_integer([:positive])}@example.com"})

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    gtfs_version = gtfs_version_fixture(organization.id)

    %{
      conn: log_in_user(conn, user, organization: organization),
      user: user,
      organization: organization,
      gtfs_version: gtfs_version
    }
  end

  describe "route facts rendering" do
    setup :shared_setup

    test "renders facts in dl/dt/dd with one h1, no field-label headings", %{
      conn: conn,
      organization: organization,
      gtfs_version: version
    } do
      route =
        route_fixture(organization.id, version.id, %{
          route_id: "FACTS1",
          route_short_name: "F1",
          route_long_name: "Facts Route",
          route_color: "FF0000",
          route_text_color: "FFFFFF"
        })

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/#{route.route_id}")

      html = render(view)
      doc = LazyHTML.from_fragment(html)

      assert Enum.count(LazyHTML.query(doc, "h1")) == 1
      refute Enum.empty?(LazyHTML.query(doc, "dl"))
      refute Enum.empty?(LazyHTML.query(doc, "dt"))
      refute Enum.empty?(LazyHTML.query(doc, "dd"))
      assert Enum.empty?(LazyHTML.query(doc, "h3"))
    end

    test "valid https URL renders as link with rel=noopener; malformed URL is plain text", %{
      conn: conn,
      organization: organization,
      gtfs_version: version
    } do
      route =
        route_fixture(organization.id, version.id, %{
          route_id: "URL1",
          route_short_name: "U1",
          route_url: "https://example.com/route"
        })

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/#{route.route_id}")

      assert has_element?(view, "a[href='https://example.com/route'][rel='noopener']")
    end

    test "missing URL renders em dash, not a link", %{
      conn: conn,
      organization: organization,
      gtfs_version: version
    } do
      route =
        route_fixture(organization.id, version.id, %{
          route_id: "NOURL1",
          route_short_name: "NU",
          route_url: nil
        })

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/#{route.route_id}")

      html = render(view)
      doc = LazyHTML.from_fragment(html)
      url_dd = LazyHTML.query(doc, "dd")
      url_texts = Enum.map(url_dd, &LazyHTML.text/1)
      refute Enum.any?(url_texts, &(&1 =~ "http"))
      assert Enum.any?(url_texts, &(&1 =~ "—"))
    end

    test "malformed URL renders as noninteractive text", %{
      conn: conn,
      organization: organization,
      gtfs_version: version
    } do
      route =
        route_fixture(organization.id, version.id, %{
          route_id: "BADURL1",
          route_short_name: "BU",
          route_url: "not-a-url"
        })

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/#{route.route_id}")

      html = render(view)
      refute html =~ ~s(href="not-a-url")
    end

    test "route badge renders via RouteIdentity; raw color metadata shown as mono text", %{
      conn: conn,
      organization: organization,
      gtfs_version: version
    } do
      route =
        route_fixture(organization.id, version.id, %{
          route_id: "BADGE1",
          route_short_name: "B1",
          route_color: "00FF00",
          route_text_color: "000000"
        })

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/#{route.route_id}")

      html = render(view)
      assert html =~ "B1"
      assert html =~ "00FF00"
      assert html =~ "000000"
      assert html =~ "font-mono"
    end
  end

  describe "route not found and unavailable" do
    setup :shared_setup

    test "not-found route redirects with flash", %{
      conn: conn,
      gtfs_version: version
    } do
      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, "/gtfs/#{version.id}/routes/MISSING")

      assert to == "/gtfs/#{version.id}/routes"
    end

    test "unavailable route renders error state with retry button", %{
      conn: conn,
      gtfs_version: version
    } do
      substitute_read_adapter(%{})

      stub(CatalogReadAdapterMock, :fetch_route, fn _org, _ver, _route_id ->
        {:error, :unavailable}
      end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/UNAVAIL")

      assert has_element?(view, "#route-unavailable")
      assert has_element?(view, "#route-retry")
    end

    test "retry restores route after unavailable", %{
      conn: conn,
      organization: organization,
      gtfs_version: version
    } do
      substitute_read_adapter(%{})

      route =
        route_fixture(organization.id, version.id, %{
          route_id: "RETRY1",
          route_short_name: "R1"
        })

      call_count = :atomics.new(1, [])

      stub(CatalogReadAdapterMock, :fetch_route, fn org, ver, route_id ->
        count = :atomics.add_get(call_count, 1, 1)

        if count <= 2 do
          {:error, :unavailable}
        else
          CatalogReadAdapter.Repo.fetch_route(org, ver, route_id)
        end
      end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/RETRY1")

      assert has_element?(view, "#route-unavailable")

      view
      |> element("#route-retry")
      |> render_click()

      refute has_element?(view, "#route-unavailable")
      assert has_element?(view, "dl")
      assert route.route_id == "RETRY1"
    end
  end

  describe "patterns tab" do
    setup :shared_setup

    test "links into the pattern editor for the selected route", %{
      conn: conn,
      organization: organization,
      gtfs_version: version
    } do
      route =
        route_fixture(organization.id, version.id, %{
          route_id: "PATNAV1",
          route_short_name: "PN"
        })

      {:ok, view, _html} =
        live(conn, "/gtfs/#{version.id}/routes/#{route.route_id}")

      assert has_element?(
               view,
               "nav[aria-label='Route navigation'] a[href='/gtfs/#{version.id}/routes/#{route.route_id}/patterns']"
             )
    end
  end

  describe "schedules action" do
    setup :shared_setup

    test "renders blank/deferred state with no schedule content or navigation", %{
      conn: conn,
      organization: organization,
      gtfs_version: version
    } do
      route =
        route_fixture(organization.id, version.id, %{
          route_id: "SCHED1",
          route_short_name: "SC"
        })

      {:ok, view, _html} =
        live(conn, "/gtfs/#{version.id}/routes/#{route.route_id}/schedules")

      assert has_element?(view, "#schedules-deferred")
      html = render(view)
      assert html =~ "future update"
      refute has_element?(view, "nav[aria-label='Route navigation']")
    end
  end
end
