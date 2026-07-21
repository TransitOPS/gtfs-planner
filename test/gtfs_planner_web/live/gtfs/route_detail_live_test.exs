defmodule GtfsPlannerWeb.Gtfs.RouteDetailLiveTest do
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.CatalogReadAdapterMock
  alias GtfsPlanner.Gtfs.RoutePattern

  @adapter_key :gtfs_catalog_read_adapter

  setup :verify_on_exit!

  setup do
    previous = Application.fetch_env(:gtfs_planner, @adapter_key)
    Application.put_env(:gtfs_planner, @adapter_key, CatalogReadAdapterMock)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:gtfs_planner, @adapter_key, value)
        :error -> Application.delete_env(:gtfs_planner, @adapter_key)
      end
    end)
  end

  defp shared_setup(_context) do
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

  defp build_route_pattern(attrs) do
    %RoutePattern{
      id: Ecto.UUID.generate(),
      route_pattern_id:
        Map.get(attrs, :route_pattern_id, "RP_#{System.unique_integer([:positive])}"),
      route_id: Map.get(attrs, :route_id, "R1"),
      direction_id: Map.get(attrs, :direction_id, 0),
      route_pattern_name: Map.get(attrs, :route_pattern_name, "Outbound via Main"),
      route_pattern_typicality: Map.get(attrs, :route_pattern_typicality, 1),
      route_pattern_sort_order: Map.get(attrs, :route_pattern_sort_order, 0),
      organization_id: Map.get(attrs, :organization_id, Ecto.UUID.generate()),
      gtfs_version_id: Map.get(attrs, :gtfs_version_id, Ecto.UUID.generate())
    }
  end

  defp stub_fetch_route(result) do
    stub(CatalogReadAdapterMock, :fetch_route, fn _org, _ver, _route_id -> result end)
  end

  defp stub_load_patterns(result) do
    stub(CatalogReadAdapterMock, :load_route_patterns, fn _org, _ver, _route_id -> result end)
  end

  describe "route facts rendering" do
    setup :shared_setup

    test "renders facts in dl/dt/dd with one h1, no field-label headings", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      route =
        route_fixture(organization.id, version.id, %{
          route_id: "FACTS1",
          route_short_name: "F1",
          route_long_name: "Facts Route",
          route_color: "FF0000",
          route_text_color: "FFFFFF"
        })

      stub_fetch_route({:ok, route})
      stub_load_patterns({:ok, []})

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
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      route =
        route_fixture(organization.id, version.id, %{
          route_id: "URL1",
          route_short_name: "U1",
          route_url: "https://example.com/route"
        })

      stub_fetch_route({:ok, route})
      stub_load_patterns({:ok, []})

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/#{route.route_id}")

      assert has_element?(view, "a[href='https://example.com/route'][rel='noopener']")
    end

    test "missing URL renders em dash, not a link", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      route =
        route_fixture(organization.id, version.id, %{
          route_id: "NOURL1",
          route_short_name: "NU",
          route_url: nil
        })

      stub_fetch_route({:ok, route})
      stub_load_patterns({:ok, []})

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
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      route =
        route_fixture(organization.id, version.id, %{
          route_id: "BADURL1",
          route_short_name: "BU",
          route_url: "not-a-url"
        })

      stub_fetch_route({:ok, route})
      stub_load_patterns({:ok, []})

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/#{route.route_id}")

      html = render(view)
      refute html =~ ~s(href="not-a-url")
    end

    test "route badge renders via RouteIdentity; raw color metadata shown as mono text", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      route =
        route_fixture(organization.id, version.id, %{
          route_id: "BADGE1",
          route_short_name: "B1",
          route_color: "00FF00",
          route_text_color: "000000"
        })

      stub_fetch_route({:ok, route})
      stub_load_patterns({:ok, []})

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
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      stub_fetch_route({:error, :not_found})
      stub_load_patterns({:ok, []})

      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, "/gtfs/#{version.id}/routes/MISSING")

      assert to == "/gtfs/#{version.id}/routes"
    end

    test "unavailable route renders error state with retry button", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      stub_fetch_route({:error, :unavailable})
      stub_load_patterns({:ok, []})

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/UNAVAIL")

      assert has_element?(view, "#route-unavailable")
      assert has_element?(view, "#route-retry")
    end

    test "retry restores route after unavailable", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      route =
        route_fixture(organization.id, version.id, %{
          route_id: "RETRY1",
          route_short_name: "R1"
        })

      call_count = :atomics.new(1, [])

      stub(CatalogReadAdapterMock, :fetch_route, fn _org, _ver, _route_id ->
        count = :atomics.add_get(call_count, 1, 1)

        if count <= 2 do
          {:error, :unavailable}
        else
          {:ok, route}
        end
      end)

      stub_load_patterns({:ok, []})

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/RETRY1")

      assert has_element?(view, "#route-unavailable")

      view
      |> element("#route-retry")
      |> render_click()

      refute has_element?(view, "#route-unavailable")
      assert has_element?(view, "dl")
    end
  end

  describe "patterns state" do
    setup :shared_setup

    test "patterns unavailable shows callout with retry", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      route =
        route_fixture(organization.id, version.id, %{
          route_id: "PATUNAV1",
          route_short_name: "PU"
        })

      stub_fetch_route({:ok, route})
      stub_load_patterns({:error, :unavailable})

      {:ok, view, _html} =
        live(conn, "/gtfs/#{version.id}/routes/#{route.route_id}/patterns")

      assert has_element?(view, "#patterns-unavailable")
      assert has_element?(view, "#patterns-retry")
    end

    test "retry restores patterns table after unavailable", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      route =
        route_fixture(organization.id, version.id, %{
          route_id: "PATRETRY1",
          route_short_name: "PR"
        })

      pattern =
        build_route_pattern(%{
          route_pattern_id: "RP_RETRY",
          route_id: route.route_id,
          organization_id: organization.id,
          gtfs_version_id: version.id
        })

      call_count = :atomics.new(1, [])

      stub(CatalogReadAdapterMock, :load_route_patterns, fn _org, _ver, _route_id ->
        count = :atomics.add_get(call_count, 1, 1)

        if count <= 2 do
          {:error, :unavailable}
        else
          {:ok, [pattern]}
        end
      end)

      stub_fetch_route({:ok, route})

      {:ok, view, _html} =
        live(conn, "/gtfs/#{version.id}/routes/#{route.route_id}/patterns")

      assert has_element?(view, "#patterns-unavailable")

      view
      |> element("#patterns-retry")
      |> render_click()

      refute has_element?(view, "#patterns-unavailable")
      assert has_element?(view, "#route-patterns-table-container")
    end

    test "patterns empty shows empty state with no retry", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      route =
        route_fixture(organization.id, version.id, %{
          route_id: "PATEMPTY1",
          route_short_name: "PE"
        })

      stub_fetch_route({:ok, route})
      stub_load_patterns({:ok, []})

      {:ok, view, _html} =
        live(conn, "/gtfs/#{version.id}/routes/#{route.route_id}/patterns")

      assert has_element?(view, "#patterns-empty")
      refute has_element?(view, "#patterns-retry")
    end

    test "patterns table contains no stop-sequence column", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      route =
        route_fixture(organization.id, version.id, %{
          route_id: "NOSEQ1",
          route_short_name: "NS"
        })

      pattern =
        build_route_pattern(%{
          route_pattern_id: "RP_NOSEQ",
          route_id: route.route_id,
          organization_id: organization.id,
          gtfs_version_id: version.id
        })

      stub_fetch_route({:ok, route})
      stub_load_patterns({:ok, [pattern]})

      {:ok, view, _html} =
        live(conn, "/gtfs/#{version.id}/routes/#{route.route_id}/patterns")

      html = render(view)
      refute html =~ "Stop Sequence"
      refute html =~ "stop-sequence"
      refute html =~ "stop_sequence"
    end

    test "patterns table uses responsive stack with stable IDs", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      route =
        route_fixture(organization.id, version.id, %{
          route_id: "STACK1",
          route_short_name: "ST"
        })

      pattern =
        build_route_pattern(%{
          route_pattern_id: "RP_STACK",
          route_id: route.route_id,
          organization_id: organization.id,
          gtfs_version_id: version.id
        })

      stub_fetch_route({:ok, route})
      stub_load_patterns({:ok, [pattern]})

      {:ok, view, _html} =
        live(conn, "/gtfs/#{version.id}/routes/#{route.route_id}/patterns")

      html = render(view)
      doc = LazyHTML.from_fragment(html)

      assert Enum.count(LazyHTML.query(doc, "table.ds-stack-table")) == 1
      assert has_element?(view, "#route-patterns-table-container")
    end
  end

  describe "schedules action" do
    setup :shared_setup

    test "renders blank/deferred state with no schedule content or navigation", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      route =
        route_fixture(organization.id, version.id, %{
          route_id: "SCHED1",
          route_short_name: "SC"
        })

      stub_fetch_route({:ok, route})
      stub_load_patterns({:ok, []})

      {:ok, view, _html} =
        live(conn, "/gtfs/#{version.id}/routes/#{route.route_id}/schedules")

      assert has_element?(view, "#schedules-deferred")
      html = render(view)
      assert html =~ "future update"
      refute has_element?(view, "nav[aria-label='Route navigation']")
    end
  end
end
