defmodule GtfsPlannerWeb.Gtfs.RoutesLiveTest do
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.CatalogReadAdapterMock
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Repo

  import Ecto.Query

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

  describe "RoutesLive workbench redesign" do
    setup :shared_setup

    test "search and filters form one toolbar inside the workbench card", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      route = route_fixture(organization.id, version.id, %{route_id: "TB1"})

      stub_catalog(fn _opts -> {:ok, route_page([route], 1, 1, [route.route_type], [])} end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      # The two server forms stay addressable, but the markup groups them.
      assert has_element?(view, "section#routes-workbench")
      assert has_element?(view, "#routes-toolbar form#route-search-form")
      assert has_element?(view, "#routes-toolbar form#route-filter-form")
      assert has_element?(view, "#route-filter-form select#active")
    end

    test "summary shows the route count and one chip per active constraint", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      r1 = route_fixture(organization.id, version.id, %{route_id: "CNT1", route_type: 3})
      r2 = route_fixture(organization.id, version.id, %{route_id: "CNT2", route_type: 0})

      stub_catalog(fn opts ->
        rows = if Keyword.get(opts, :route_type) == 3, do: [r1], else: [r1, r2]
        total = if Keyword.get(opts, :route_type) == 3, do: 1, else: 2

        {:ok,
         route_page(
           rows,
           total,
           1,
           [3, 0],
           []
         )}
      end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      assert has_element?(view, "#routes-summary #routes-count", "2 routes")

      view
      |> form("#route-filter-form", %{"route_type" => "3"})
      |> render_change()

      assert_patched(view, "/gtfs/#{version.id}/routes?route_type=3")

      assert has_element?(view, "#routes-count", "1 route")
      assert has_element?(view, "#routes-chip-route_type", "Bus")
      refute has_element?(view, "#routes-chip-search")
    end

    test "a chip dismisses only its own constraint", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      route = route_fixture(organization.id, version.id, %{route_id: "CHP1", route_type: 3})

      stub_catalog(fn _opts -> {:ok, route_page([route], 1, 1, [3], [])} end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      view
      |> form("#route-filter-form", %{"route_type" => "3", "active" => "true"})
      |> render_change()

      assert_patched(view, "/gtfs/#{version.id}/routes?active=true&route_type=3")

      view |> element("#routes-chip-route_type") |> render_click()

      # The status filter survives; the mode chip is gone.
      assert_patched(view, "/gtfs/#{version.id}/routes?active=true")
      refute has_element?(view, "#routes-chip-route_type")
      assert has_element?(view, "#routes-chip-active", "Active")
    end

    test "mobile list mirrors the table under its own container", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      route =
        route_fixture(organization.id, version.id, %{route_id: "MOB1", route_short_name: "M"})

      stub_catalog(fn _opts -> {:ok, route_page([route], 1, 1, [route.route_type], [])} end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      assert has_element?(view, "ul#routes-list[phx-update='stream']")
      assert has_element?(view, "#routes-list li a[href='/gtfs/#{version.id}/routes/MOB1']")
    end

    test "name cell falls back from long name to short name to route ID", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      # route_long_name is present, route_short_name is not: the cell shows the
      # long name.
      no_short =
        route_fixture(organization.id, version.id, %{
          route_id: "NOSHORT",
          route_short_name: nil,
          route_long_name: "Harbour – Airport"
        })

      stub_catalog(fn _opts -> {:ok, route_page([no_short], 1, 1, [], [])} end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      assert has_element?(view, "#routes-container", "Harbour – Airport")

      # Neither name is present: the changeset rejects it, so insert past it to
      # cover the last step of the fallback chain, which ends at the route ID.
      {:ok, _route} =
        Repo.insert(%Route{
          organization_id: organization.id,
          gtfs_version_id: version.id,
          route_id: "NEITHER",
          route_type: 3,
          route_color: "0000FF",
          route_text_color: "FFFFFF"
        })

      neither = Repo.one!(from r in Route, where: r.route_id == "NEITHER")

      stub_catalog(fn _opts -> {:ok, route_page([neither], 1, 1, [], [])} end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      assert has_element?(view, "#routes-container", "NEITHER")
    end

    test "inactive routes are marked without a colored status word", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      route = route_fixture(organization.id, version.id, %{route_id: "INA1", active: false})

      stub_catalog(fn _opts -> {:ok, route_page([route], 1, 1, [route.route_type], [])} end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      assert has_element?(view, "#routes-container", "Inactive")
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
      refute has_element?(view, "#new-route-trigger")
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

      # The version has an agency, so the empty state is about routes: a version
      # with no agency shows the onboarding instead (step 21, AC-24).
      agency_fixture(organization.id, version.id, %{
        agency_id: "A1",
        agency_name: "Alpha Transit"
      })

      stub_catalog(fn _opts -> {:ok, route_page([], 0, 1, [], [])} end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      assert has_element?(view, "#routes-first-use-empty")
      assert has_element?(view, "#routes-first-use-empty a", "Import feed")
      refute has_element?(view, "#routes-agency-onboarding")
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

  describe "RoutesLive area navigation" do
    setup :shared_setup

    test "mounts the Routes tabs with Routes current above the unchanged catalog", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      stub_catalog(fn _opts -> {:ok, route_page([], 0, 1, [], [])} end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      assert has_element?(view, "#routes-tabs")
      assert has_element?(view, "#routes-tab-routes[aria-current='page']")

      assert has_element?(
               view,
               "#routes-tab-transfers[href='/gtfs/#{version.id}/transfers']"
             )

      refute has_element?(view, "#routes-tab-transfers[aria-current='page']")

      # The page keeps its own heading and filter form; the bar adds no heading.
      assert has_element?(view, "#route-filter-form")
      assert has_element?(view, "#route-search-form")

      assert Enum.empty?(LazyHTML.query(LazyHTML.from_fragment(render(view)), "#routes-tabs h1"))
    end

    test "loads the route catalog through the production adapter on an ordinary mount", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      # This module swaps in CatalogReadAdapterMock for its other cases. An
      # ordinary mount takes the default Repo adapter, so remove the override
      # here; the setup's on_exit restores the previous configuration.
      Application.delete_env(:gtfs_planner, @adapter_key)

      conn = log_in_user(conn, user, organization: organization)

      route =
        route_fixture(organization.id, version.id, %{
          route_id: "REAL1",
          route_short_name: "R1"
        })

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")
      html = render(view)

      assert has_element?(view, "#routes-tabs")
      assert has_element?(view, "#routes-tab-routes[aria-current='page']")
      assert has_element?(view, "#routes-tab-transfers")
      assert html =~ route.route_id
      refute html =~ "Route catalog unavailable"
    end
  end

  describe "RoutesLive route links" do
    setup :shared_setup

    test "links a route whose ID has reserved URL characters by its encoded path", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      # These cases read through the production adapter; the setup's on_exit
      # restores the mock override.
      Application.delete_env(:gtfs_planner, @adapter_key)

      conn = log_in_user(conn, user, organization: organization)
      route = route_fixture(organization.id, version.id, %{route_id: "QA/SLASH 1"})
      encoded_path = "/gtfs/#{version.id}/routes/QA%2FSLASH%201"

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")
      doc = LazyHTML.from_fragment(render(view))

      assert doc |> LazyHTML.query("tr#routes-#{route.id} a") |> LazyHTML.attribute("href") ==
               [encoded_path]

      assert doc
             |> LazyHTML.query("li#routes_mobile-#{route.id} a")
             |> LazyHTML.attribute("href") == [encoded_path]
    end

    test "opens the route detail page from the encoded link", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      Application.delete_env(:gtfs_planner, @adapter_key)

      conn = log_in_user(conn, user, organization: organization)

      route_fixture(organization.id, version.id, %{
        route_id: "QA/SLASH 1",
        route_short_name: "QA1",
        route_long_name: "Slash Route"
      })

      {:ok, list_view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      [href] =
        list_view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#routes a")
        |> LazyHTML.attribute("href")

      {:ok, detail_view, _html} = live(conn, href)

      assert has_element?(detail_view, "#route-workspace h1#route-title", "Slash Route")
    end
  end

  describe "RoutesLive route status filters" do
    setup :shared_setup

    # These cases exercise the ordinary public entrypoint (LiveView mount ->
    # Gtfs.load_route_catalog/3 -> the concrete CatalogReadAdapter.Repo ->
    # Gtfs.list_routes/3 and Gtfs.count_routes/3) with database fixtures, so
    # the module's mock override is removed for each of them.
    test "Active shows true and NULL rows, Inactive shows only explicit false, and counts match rows",
         %{
           conn: conn,
           user: user,
           organization: organization,
           gtfs_version: version
         } do
      Application.delete_env(:gtfs_planner, @adapter_key)
      conn = log_in_user(conn, user, organization: organization)

      route_fixture(organization.id, version.id, %{route_id: "STAT-TRUE", active: true})
      route_fixture(organization.id, version.id, %{route_id: "STAT-NULL", active: nil})
      route_fixture(organization.id, version.id, %{route_id: "STAT-FALSE", active: false})

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes?active=true")

      assert has_element?(view, "a", "STAT-TRUE")
      assert has_element?(view, "a", "STAT-NULL")
      refute has_element?(view, "a", "STAT-FALSE")
      assert status_row_count(view) == 2
      assert has_element?(view, "div", "of 2 routes")

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes?active=false")

      refute has_element?(view, "a", "STAT-TRUE")
      refute has_element?(view, "a", "STAT-NULL")
      assert has_element?(view, "a", "STAT-FALSE")
      assert status_row_count(view) == 1
      assert has_element?(view, "div", "of 1 routes")

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      assert status_row_count(view) == 3
      assert has_element?(view, "div", "of 3 routes")

      # Filtering never backfills stored NULLs.
      assert Gtfs.get_route_by_route_id(organization.id, version.id, "STAT-TRUE").active == true
      assert Gtfs.get_route_by_route_id(organization.id, version.id, "STAT-NULL").active == nil
      assert Gtfs.get_route_by_route_id(organization.id, version.id, "STAT-FALSE").active == false
    end

    test "search, mode and agency filters combine with the effective status predicate", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      Application.delete_env(:gtfs_planner, @adapter_key)
      conn = log_in_user(conn, user, organization: organization)

      agency = agency_fixture(organization.id, version.id)

      route_fixture(organization.id, version.id, %{
        route_id: "COMBO-ACTIVE",
        route_short_name: "Combotest One",
        route_type: 3,
        agency_id: agency.agency_id,
        active: true
      })

      route_fixture(organization.id, version.id, %{
        route_id: "COMBO-NULL",
        route_short_name: "Combotest Two",
        route_type: 3,
        agency_id: agency.agency_id,
        active: nil
      })

      route_fixture(organization.id, version.id, %{
        route_id: "COMBO-FALSE",
        route_short_name: "Combotest Three",
        route_type: 3,
        agency_id: agency.agency_id,
        active: false
      })

      route_fixture(organization.id, version.id, %{
        route_id: "COMBO-OTHER",
        route_short_name: "Combotest Four",
        route_type: 2,
        active: nil
      })

      query = "route_type=3&agency_id=#{agency.agency_id}&search=combotest"

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes?active=true&#{query}")

      assert has_element?(view, "a", "COMBO-ACTIVE")
      assert has_element?(view, "a", "COMBO-NULL")
      refute has_element?(view, "a", "COMBO-FALSE")
      refute has_element?(view, "a", "COMBO-OTHER")
      assert status_row_count(view) == 2
      assert has_element?(view, "div", "of 2 routes")

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes?active=false&#{query}")

      assert has_element?(view, "a", "COMBO-FALSE")
      refute has_element?(view, "a", "COMBO-ACTIVE")
      refute has_element?(view, "a", "COMBO-NULL")
      refute has_element?(view, "a", "COMBO-OTHER")
      assert status_row_count(view) == 1
      assert has_element?(view, "div", "of 1 routes")
    end

    test "pagination keeps the status predicate in the URL and stored nulls", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      Application.delete_env(:gtfs_planner, @adapter_key)
      conn = log_in_user(conn, user, organization: organization)

      for idx <- 1..50 do
        route_fixture(organization.id, version.id, %{
          route_id: "PAGE#{String.pad_leading(Integer.to_string(idx), 3, "0")}",
          active: true
        })
      end

      route_fixture(organization.id, version.id, %{route_id: "ZZNULL", active: nil})
      route_fixture(organization.id, version.id, %{route_id: "AAFALSE", active: false})

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes?active=true")

      assert status_row_count(view) == 50
      assert has_element?(view, "div", "of 51 routes")
      refute has_element?(view, "a", "ZZNULL")

      view
      |> element("button[phx-click='paginate'][phx-value-page='2']")
      |> render_click()

      assert_patched(
        view,
        "/gtfs/#{version.id}/routes?active=true&page=2&sort_by=route_id&sort_dir=asc"
      )

      # The NULL route is the 51st Active row.
      assert has_element?(view, "a", "ZZNULL")
      refute has_element?(view, "a", "PAGE001")
      refute has_element?(view, "a", "AAFALSE")
      assert status_row_count(view) == 1
      assert has_element?(view, "div", "of 51 routes")

      assert Gtfs.get_route_by_route_id(organization.id, version.id, "ZZNULL").active == nil
    end

    test "unknown status values present as All statuses", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      Application.delete_env(:gtfs_planner, @adapter_key)
      conn = log_in_user(conn, user, organization: organization)

      route_fixture(organization.id, version.id, %{route_id: "NORM-TRUE", active: true})
      route_fixture(organization.id, version.id, %{route_id: "NORM-NULL", active: nil})
      route_fixture(organization.id, version.id, %{route_id: "NORM-FALSE", active: false})

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes?active=bogus")

      assert status_row_count(view) == 3
      assert has_element?(view, "div", "of 3 routes")
      assert has_element?(view, "option[selected]", "All statuses")
    end
  end

  defp status_row_count(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("tbody#routes tr")
    |> Enum.count()
  end
end
