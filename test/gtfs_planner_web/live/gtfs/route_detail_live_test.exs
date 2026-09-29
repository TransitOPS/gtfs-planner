defmodule GtfsPlannerWeb.Gtfs.RouteDetailLiveTest do
  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Mox
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.TransfersFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.CatalogReadAdapter
  alias GtfsPlanner.Gtfs.CatalogReadAdapterMock
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Repo

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

    test "renders facts in dl/dt/dd with one h1; only group titles are headings", %{
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

      h3_titles =
        doc |> LazyHTML.query("h3") |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

      assert Enum.count(LazyHTML.query(doc, "h1")) == 1
      refute Enum.empty?(LazyHTML.query(doc, "dl"))
      refute Enum.empty?(LazyHTML.query(doc, "dt"))
      refute Enum.empty?(LazyHTML.query(doc, "dd"))
      assert h3_titles == ["What riders see", "Agency and boarding", "Availability"]
    end

    test "the heading is the long name and the badge carries the short name", %{
      conn: conn,
      organization: organization,
      gtfs_version: version
    } do
      route =
        route_fixture(organization.id, version.id, %{
          route_id: "HEAD1",
          route_short_name: "H1",
          route_long_name: "Headline Route",
          route_type: 0
        })

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/#{route.route_id}")

      assert has_element?(view, "h1#route-title", "Headline Route")
      refute has_element?(view, "h1#route-title", "H1")
      assert has_element?(view, "#route-workspace span", "H1")
      assert has_element?(view, "#route-mode", "Tram or light rail")
      assert has_element?(view, "#route-identifier", "Route ID HEAD1")
      assert has_element?(view, "#route-back[href='/gtfs/#{version.id}/routes']", "Routes")
    end

    test "a route with no long name is titled from its short name", %{
      conn: conn,
      organization: organization,
      gtfs_version: version
    } do
      route =
        route_fixture(organization.id, version.id, %{
          route_id: "NONAME1",
          route_short_name: "N9",
          route_long_name: nil
        })

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/#{route.route_id}")

      assert has_element?(view, "h1#route-title", "Route N9")
      assert has_element?(view, "#route-fact-name", "Not set")
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

    test "missing URL renders Not set, not a link", %{
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

      refute has_element?(view, "#route-fact-url a")
      assert has_element?(view, "#route-fact-url", "Not set")
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
      refute has_element?(view, "#route-fact-url a")
      assert has_element?(view, "#route-fact-url", "not-a-url")
      assert has_element?(view, "#route-fact-url", "Not a link")
    end

    test "a URL that is not plain http(s) text is not a link", %{
      conn: conn,
      organization: organization,
      gtfs_version: version
    } do
      route =
        route_fixture(organization.id, version.id, %{
          route_id: "JSURL1",
          route_short_name: "JU",
          route_url: "javascript:alert(1)"
        })

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/#{route.route_id}")

      refute has_element?(view, "#route-fact-url a")
      assert has_element?(view, "#route-fact-url", "Not a link")
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
      assert has_element?(view, "#route-fact-colors .font-mono", "#00FF00")
      assert has_element?(view, "#route-fact-colors .font-mono", "#000000")
      assert html =~ "00FF00"
      assert html =~ "font-mono"
      refute has_element?(view, "#route-fact-colors", "isn't a six-digit color")
    end

    test "a stored color that is not six hex digits is shown as stored with the reason it draws gray",
         %{conn: conn, organization: organization, gtfs_version: version} do
      route =
        route_fixture(organization.id, version.id, %{
          route_id: "BADCOL1",
          route_short_name: "BC"
        })

      Repo.update_all(from(r in Route, where: r.id == ^route.id), set: [route_color: "1F5FB"])

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/#{route.route_id}")

      assert has_element?(view, "#route-fact-colors .font-mono", "1F5FB")
      refute has_element?(view, "#route-fact-colors", "#1F5FB")
      assert has_element?(view, "#route-fact-colors", "isn't a six-digit color")
    end
  end

  describe "route facts in words" do
    setup :shared_setup

    test "pickup and drop-off that match read as one line", %{
      conn: conn,
      organization: organization,
      gtfs_version: version
    } do
      route =
        route_fixture(organization.id, version.id, %{
          route_id: "BOARD1",
          route_short_name: "B1",
          continuous_pickup: 2,
          continuous_drop_off: 2
        })

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/#{route.route_id}")

      assert has_element?(
               view,
               "#route-fact-boarding p",
               "Pickup and drop-off: call the agency first"
             )

      refute has_element?(view, "#route-fact-boarding", "Drop-off:")
    end

    test "pickup and drop-off that differ read as two lines", %{
      conn: conn,
      organization: organization,
      gtfs_version: version
    } do
      route =
        route_fixture(organization.id, version.id, %{
          route_id: "BOARD2",
          route_short_name: "B2",
          continuous_pickup: 0,
          continuous_drop_off: 3
        })

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/#{route.route_id}")

      assert has_element?(view, "#route-fact-boarding p", "Pickup: anywhere along the route")
      assert has_element?(view, "#route-fact-boarding p", "Drop-off: arrange with the driver")
    end

    test "display order shows its number and what it does; a blank one says Not set", %{
      conn: conn,
      organization: organization,
      gtfs_version: version
    } do
      ordered =
        route_fixture(organization.id, version.id, %{
          route_id: "ORDER1",
          route_short_name: "O1",
          route_sort_order: 12
        })

      blank = route_fixture(organization.id, version.id, %{route_id: "ORDER2"})

      {:ok, ordered_view, _html} = live(conn, "/gtfs/#{version.id}/routes/#{ordered.route_id}")
      {:ok, blank_view, _html} = live(conn, "/gtfs/#{version.id}/routes/#{blank.route_id}")

      assert has_element?(ordered_view, "#route-fact-order", "12")
      assert has_element?(ordered_view, "#route-fact-order", "lower numbers list first")
      assert has_element?(blank_view, "#route-fact-order", "Not set")
      refute has_element?(blank_view, "#route-fact-order", "lower numbers list first")
    end

    test "an inactive route says so in the header and in its status", %{
      conn: conn,
      organization: organization,
      gtfs_version: version
    } do
      active = route_fixture(organization.id, version.id, %{route_id: "ACT1"})
      inactive = route_fixture(organization.id, version.id, %{route_id: "INACT1", active: false})

      {:ok, active_view, _html} = live(conn, "/gtfs/#{version.id}/routes/#{active.route_id}")
      {:ok, inactive_view, _html} = live(conn, "/gtfs/#{version.id}/routes/#{inactive.route_id}")

      refute has_element?(active_view, "#route-inactive")
      assert has_element?(active_view, "#route-fact-status", "Active")
      assert has_element?(inactive_view, "#route-inactive", "Inactive")
      assert has_element?(inactive_view, "#route-fact-status", "Inactive")
    end

    test "the GTFS values disclosure keeps the stored value behind each plain-language one", %{
      conn: conn,
      organization: organization,
      gtfs_version: version
    } do
      route =
        route_fixture(organization.id, version.id, %{
          route_id: "RAW1",
          route_short_name: "R1",
          route_desc: nil,
          continuous_pickup: 1
        })

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/#{route.route_id}")

      cells = stored_values(view)

      assert cells["route_id"] == "RAW1"
      assert cells["route_type"] == "3"
      assert cells["continuous_pickup"] == "1"
      assert cells["route_desc"] == "empty"
      assert has_element?(view, "#route-fact-boarding", "only at stops")
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
      assert has_element?(view, "#route-retry", "Try again")
      assert has_element?(view, "#route-back[href='/gtfs/#{version.id}/routes']")
      refute has_element?(view, "#route-workspace")
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

  describe "route tab bar" do
    setup :shared_setup

    test "every route page renders the three tabs with aria-current on the current one", %{
      conn: conn,
      organization: organization,
      gtfs_version: version
    } do
      route =
        route_fixture(organization.id, version.id, %{
          route_id: "TABS1",
          route_short_name: "TB"
        })

      base = "/gtfs/#{version.id}/routes/#{route.route_id}"
      nav = "nav[aria-label='Route navigation']"

      {:ok, details_view, _html} = live(conn, base)

      assert has_element?(
               details_view,
               "#{nav} a[href='#{base}'][aria-current='page']",
               "Details"
             )

      assert has_element?(details_view, "#{nav} a[href='#{base}/patterns']", "Patterns")
      assert has_element?(details_view, "#{nav} a[href='#{base}/schedules']", "Schedules")
      refute has_element?(details_view, "#{nav} a[href='#{base}/patterns'][aria-current='page']")
      refute has_element?(details_view, "#schedules-deferred")

      {:ok, patterns_view, _html} = live(conn, "#{base}/patterns")

      assert has_element?(
               patterns_view,
               "#{nav} a[href='#{base}/patterns'][aria-current='page']",
               "Patterns"
             )

      assert has_element?(patterns_view, "#{nav} a[href='#{base}/schedules']", "Schedules")
      refute has_element?(patterns_view, "#{nav} a[href='#{base}'][aria-current='page']")

      {:ok, schedules_view, _html} = live(conn, "#{base}/schedules")

      assert has_element?(
               schedules_view,
               "#{nav} a[href='#{base}/schedules'][aria-current='page']",
               "Schedules"
             )

      assert has_element?(schedules_view, "#{nav} a[href='#{base}']", "Details")
      assert has_element?(schedules_view, "#{nav} a[href='#{base}/patterns']", "Patterns")

      refute has_element?(
               schedules_view,
               "#{nav} a[href='#{base}/patterns'][aria-current='page']"
             )

      refute has_element?(schedules_view, "#schedules-deferred")
    end
  end

  describe "route ID with reserved URL characters" do
    setup :shared_setup

    test "encodes the Patterns and Schedules tab links and opens both pages", %{
      conn: conn,
      organization: organization,
      gtfs_version: version
    } do
      route_fixture(organization.id, version.id, %{route_id: "QA/SLASH 1"})
      base = "/gtfs/#{version.id}/routes/QA%2FSLASH%201"
      nav = "nav[aria-label='Route navigation']"

      {:ok, details_view, _html} = live(conn, base)

      assert has_element?(
               details_view,
               "#{nav} a[href='#{base}'][aria-current='page']",
               "Details"
             )

      assert has_element?(details_view, "#{nav} a[href='#{base}/patterns']", "Patterns")
      assert has_element?(details_view, "#{nav} a[href='#{base}/schedules']", "Schedules")

      [patterns_href] = tab_hrefs(details_view, "#{nav} a[href$='/patterns']")
      [schedules_href] = tab_hrefs(details_view, "#{nav} a[href$='/schedules']")

      {:ok, patterns_view, _html} = live(conn, patterns_href)

      assert has_element?(
               patterns_view,
               "#{nav} a[href='#{base}/patterns'][aria-current='page']",
               "Patterns"
             )

      {:ok, schedules_view, _html} = live(conn, schedules_href)

      assert has_element?(
               schedules_view,
               "#{nav} a[href='#{base}/schedules'][aria-current='page']",
               "Schedules"
             )
    end
  end

  defp tab_hrefs(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute("href")
  end

  describe "related transfers" do
    setup :shared_setup

    test "the details fact counts this route's general rules and opens the filtered list", %{
      conn: conn,
      organization: organization,
      gtfs_version: version
    } do
      transfer_network_fixture(organization.id, version.id)

      route_rule =
        transfer_fixture(organization.id, version.id, %{
          from_stop_id: "MKT",
          to_stop_id: "HBR",
          from_route_id: "24",
          transfer_type: 2,
          min_transfer_time: 180
        })

      trip_rule =
        transfer_fixture(organization.id, version.id, %{
          from_stop_id: "CEN-A",
          to_stop_id: "CEN-C",
          from_trip_id: "24-0840",
          transfer_type: 0
        })

      # Both of this in-seat row's trips run on route 24, and it is still not
      # counted: related counts cover general rules only (CR-1, INV-1).
      transfer_fixture(organization.id, version.id, %{
        from_stop_id: "CEN",
        to_stop_id: "CEN",
        from_trip_id: "12-0815",
        to_trip_id: "24-0840",
        transfer_type: 4
      })

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/24")

      assert has_element?(view, "#route-transfers-summary", "2 transfer rules mention")
      assert has_element?(view, "#route-transfers-link", "View transfers")

      href = link_href(view, "#route-transfers-link")

      assert href == "/gtfs/#{version.id}/transfers?route=24"

      {:ok, list, _html} = live(conn, href)

      assert Enum.sort(row_ids(list)) ==
               Enum.sort(["transfers-#{route_rule.id}", "transfers-#{trip_rule.id}"])
    end

    test "a route with no rules reads zero and opens an empty list", %{
      conn: conn,
      organization: organization,
      gtfs_version: version
    } do
      transfer_network_fixture(organization.id, version.id)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/24")

      assert has_element?(view, "#route-transfers-summary", "No transfer rules mention")

      {:ok, list, _html} = live(conn, link_href(view, "#route-transfers-link"))

      assert row_ids(list) == []
    end

    test "retrying an unavailable route assigns the count as well", %{
      conn: conn,
      organization: organization,
      gtfs_version: version
    } do
      transfer_network_fixture(organization.id, version.id)

      transfer_fixture(organization.id, version.id, %{
        from_stop_id: "MKT",
        to_stop_id: "HBR",
        from_route_id: "24",
        transfer_type: 0
      })

      substitute_read_adapter(%{})
      call_count = :atomics.new(1, [])

      stub(CatalogReadAdapterMock, :fetch_route, fn org, ver, route_id ->
        # `live/2` runs `handle_params/3` once for the static render and once for
        # the connected one, as the retry case above records.
        if :atomics.add_get(call_count, 1, 1) <= 2 do
          {:error, :unavailable}
        else
          CatalogReadAdapter.Repo.fetch_route(org, ver, route_id)
        end
      end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/24")

      assert has_element?(view, "#route-unavailable")
      refute has_element?(view, "#route-transfers-link")

      view |> element("#route-retry") |> render_click()

      assert has_element?(view, "#route-transfers-summary", "1 transfer rule mentions")
    end
  end

  defp stored_values(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#route-gtfs-values tbody tr")
    |> Map.new(fn row ->
      [field] = row |> LazyHTML.query("th") |> Enum.map(&String.trim(LazyHTML.text(&1)))
      [value] = row |> LazyHTML.query("td") |> Enum.map(&String.trim(LazyHTML.text(&1)))
      {field, value}
    end)
  end

  defp link_href(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("a")
    |> LazyHTML.attribute("href")
    |> List.first()
  end

  defp row_ids(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("tbody#transfers tr")
    |> Enum.map(fn row -> row |> LazyHTML.attribute("id") |> List.first() end)
  end
end
