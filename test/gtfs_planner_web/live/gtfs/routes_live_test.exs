defmodule GtfsPlannerWeb.Gtfs.RoutesLiveTest do
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.CatalogReadAdapterMock

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

  defp route_page(rows, total_count, page, route_types, agencies) do
    %{
      rows: rows,
      total_count: total_count,
      page: page,
      route_types: route_types,
      agencies: agencies
    }
  end

  defp stub_catalog(result_fn) do
    stub(CatalogReadAdapterMock, :load_route_catalog, fn _org, _ver, opts ->
      result_fn.(opts)
    end)
  end

  describe "RoutesLive shared table contract" do
    setup :shared_setup

    test "renders one shared table with stable tbody ID and route badge", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      route =
        route_fixture(organization.id, version.id, %{
          route_id: "SHARED1",
          route_short_name: "S1",
          route_color: "FF0000"
        })

      stub_catalog(fn _opts ->
        {:ok, route_page([route], 1, 1, [route.route_type], [])}
      end)

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

      routes =
        Enum.map(1..51, fn idx ->
          route_fixture(organization.id, version.id, %{
            route_id: "PG#{String.pad_leading(Integer.to_string(idx), 3, "0")}"
          })
        end)

      stub_catalog(fn opts ->
        page = Keyword.get(opts, :page, 1)

        rows =
          case page do
            1 -> Enum.take(routes, 50)
            2 -> Enum.drop(routes, 50)
            _ -> []
          end

        {:ok, route_page(rows, 51, page, [], [])}
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

      r1 = route_fixture(organization.id, version.id, %{route_id: "DEDUP1"})
      r2 = route_fixture(organization.id, version.id, %{route_id: "DEDUP2"})

      stub_catalog(fn _opts ->
        {:ok, route_page([r1, r2], 2, 1, [], [])}
      end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      html = render(view)
      doc = LazyHTML.from_fragment(html)

      assert Enum.count(LazyHTML.query(doc, "table")) == 1
      assert Enum.count(LazyHTML.query(doc, "tbody")) == 1
    end

    test "table uses responsive stack and aria-sort on sortable headers", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      route = route_fixture(organization.id, version.id, %{route_id: "SORT1"})

      stub_catalog(fn _opts ->
        {:ok, route_page([route], 1, 1, [], [])}
      end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      html = render(view)
      doc = LazyHTML.from_fragment(html)

      tables = LazyHTML.query(doc, "table.ds-stack-table")
      assert Enum.count(tables) == 1

      assert has_element?(view, "th[aria-sort]")
    end

    test "route ID column uses font-mono and route link is primary", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      route =
        route_fixture(organization.id, version.id, %{
          route_id: "MONO1",
          route_short_name: "M1"
        })

      stub_catalog(fn _opts ->
        {:ok, route_page([route], 1, 1, [], [])}
      end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      assert has_element?(view, "a.font-mono.link-primary", "MONO1")
    end
  end

  describe "RoutesLive unavailable state and retry" do
    setup :shared_setup

    test "renders unavailable callout with retry button when adapter returns error", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      stub_catalog(fn _opts -> {:error, :unavailable} end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      assert has_element?(view, "#routes-unavailable")
      assert has_element?(view, "#routes-retry")
    end

    test "retry restores rows after unavailable", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      route = route_fixture(organization.id, version.id, %{route_id: "RETRY1"})

      call_count = :atomics.new(1, [])

      stub_catalog(fn _opts ->
        count = :atomics.add_get(call_count, 1, 1)

        if count <= 2 do
          {:error, :unavailable}
        else
          {:ok, route_page([route], 1, 1, [], [])}
        end
      end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      assert has_element?(view, "#routes-unavailable")

      view
      |> element("#routes-retry")
      |> render_click()

      refute has_element?(view, "#routes-unavailable")
      assert has_element?(view, "a", "RETRY1")
    end
  end

  describe "RoutesLive page clamping" do
    setup :shared_setup

    test "out-of-range page patches to canonical page", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      routes =
        Enum.map(1..75, fn idx ->
          route_fixture(organization.id, version.id, %{
            route_id: "CL#{String.pad_leading(Integer.to_string(idx), 3, "0")}"
          })
        end)

      stub_catalog(fn opts ->
        page = Keyword.get(opts, :page, 1)
        per_page = Keyword.get(opts, :per_page, 50)
        total = 75
        max_page = max(1, ceil(total / per_page))
        canonical = min(max(page, 1), max_page)

        rows =
          routes
          |> Enum.drop((canonical - 1) * per_page)
          |> Enum.take(per_page)

        {:ok, route_page(rows, total, canonical, [], [])}
      end)

      assert {:error, {:live_redirect, %{to: redirected_to}}} =
               live(conn, "/gtfs/#{version.id}/routes?page=999")

      assert redirected_to =~ "page=2"

      {:ok, view, _html} = live(conn, redirected_to)
      assert has_element?(view, "a", "CL051")
    end
  end

  describe "RoutesLive empty states" do
    setup :shared_setup

    test "first-use empty state with Import feed link when no routes and no filters", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      stub_catalog(fn _opts -> {:ok, route_page([], 0, 1, [], [])} end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      assert has_element?(view, "#routes-first-use-empty")
      assert has_element?(view, "#routes-first-use-empty a", "Import feed")
    end

    test "constrained empty with Clear search when search active and no filters", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      stub_catalog(fn _opts -> {:ok, route_page([], 0, 1, [], [])} end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes?search=nonexistent")

      assert has_element?(view, "#routes-constrained-empty")
      assert has_element?(view, "#routes-clear-filters", "Clear search")
    end

    test "constrained empty with Clear filters when filter active", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      stub_catalog(fn _opts -> {:ok, route_page([], 0, 1, [], [])} end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes?route_type=3")

      assert has_element?(view, "#routes-constrained-empty")
      assert has_element?(view, "#routes-clear-filters", "Clear filters")
    end

    test "clear filters restores rows", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      route = route_fixture(organization.id, version.id, %{route_id: "CLEAR1"})

      stub_catalog(fn opts ->
        search = Keyword.get(opts, :search, "")
        route_type = Keyword.get(opts, :route_type)

        cond do
          search == "nonexistent" ->
            {:ok, route_page([], 0, 1, [], [])}

          route_type == 99 ->
            {:ok, route_page([], 0, 1, [], [])}

          true ->
            {:ok, route_page([route], 1, 1, [route.route_type], [])}
        end
      end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes?search=nonexistent")

      assert has_element?(view, "#routes-constrained-empty")

      view
      |> element("#routes-clear-filters")
      |> render_click()

      assert_patched(view, "/gtfs/#{version.id}/routes")
      assert has_element?(view, "a", "CLEAR1")
    end
  end

  describe "RoutesLive search form" do
    setup :shared_setup

    test "search form has stable ID, visible label, and names-and-IDs hint", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      stub_catalog(fn _opts -> {:ok, route_page([], 0, 1, [], [])} end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      assert has_element?(view, "form#route-search-form")
      assert has_element?(view, "#route-search-form label", "Search")
      assert has_element?(view, "#route-search-form input[type='search']")
      html = render(view)
      assert html =~ "Search names and IDs"
    end

    test "search change resets page to 1", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      route = route_fixture(organization.id, version.id, %{route_id: "SRCH1"})

      stub_catalog(fn opts ->
        page = Keyword.get(opts, :page, 1)
        {:ok, route_page([route], 1, page, [], [])}
      end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes?page=2")

      view
      |> form("#route-search-form", %{"search" => "test"})
      |> render_change()

      assert_patched(view, "/gtfs/#{version.id}/routes?search=test")
    end
  end

  describe "RoutesLive filtering and search" do
    setup :shared_setup

    test "filters routes by type", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      bus_route =
        route_fixture(organization.id, version.id, %{route_id: "BUS1", route_type: 3})

      stub_catalog(fn opts ->
        route_type = Keyword.get(opts, :route_type)

        case route_type do
          3 -> {:ok, route_page([bus_route], 1, 1, [3], [])}
          _ -> {:ok, route_page([bus_route], 1, 1, [3], [])}
        end
      end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      html =
        view
        |> form("#route-filter-form", %{"route_type" => "3"})
        |> render_change()

      assert html =~ bus_route.route_id
      assert_patched(view, "/gtfs/#{version.id}/routes?route_type=3")
    end

    test "searches routes by name", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      express_route =
        route_fixture(organization.id, version.id, %{
          route_id: "EXP1",
          route_short_name: "Express 1",
          route_long_name: "Downtown Express"
        })

      stub_catalog(fn _opts ->
        {:ok, route_page([express_route], 1, 1, [], [])}
      end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      html =
        view
        |> form("#route-search-form", %{"search" => "express"})
        |> render_change()

      assert html =~ express_route.route_id
      assert html =~ "Express"
    end

    test "sorts routes by column", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      route_a =
        route_fixture(organization.id, version.id, %{route_id: "R1", route_short_name: "Alpha"})

      _route_b =
        route_fixture(organization.id, version.id, %{route_id: "R2", route_short_name: "Bravo"})

      route_c =
        route_fixture(organization.id, version.id, %{route_id: "R3", route_short_name: "Charlie"})

      stub_catalog(fn opts ->
        sort_by = Keyword.get(opts, :sort_by, :route_id)
        sort_dir = Keyword.get(opts, :sort_dir, :asc)

        routes =
          case {sort_by, sort_dir} do
            {:route_short_name, :asc} -> [route_a, route_c]
            {:route_short_name, :desc} -> [route_c, route_a]
            _ -> [route_a, route_c]
          end

        {:ok, route_page(routes, 2, 1, [], [])}
      end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      html =
        view
        |> element("[phx-value-key=route_short_name]")
        |> render_click()

      assert html =~ "▲"

      html =
        view
        |> element("[phx-value-key=route_short_name]")
        |> render_click()

      assert html =~ "▼"

      tbody_html = view |> element("tbody#routes") |> render()
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

      routes =
        Enum.map(1..51, fn idx ->
          route_fixture(organization.id, version.id, %{
            route_id: "R#{String.pad_leading(Integer.to_string(idx), 3, "0")}"
          })
        end)

      stub_catalog(fn opts ->
        page = Keyword.get(opts, :page, 1)

        rows =
          case page do
            1 -> Enum.take(routes, 50)
            2 -> Enum.drop(routes, 50)
            _ -> []
          end

        {:ok, route_page(rows, 51, page, [], [])}
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
