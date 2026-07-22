defmodule GtfsPlannerWeb.Gtfs.StopsLiveTest do
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

  defp stop_page(rows, total_count, page, available_routes, routes_by_stop) do
    %{
      rows: rows,
      total_count: total_count,
      page: page,
      available_routes: available_routes,
      routes_by_stop: routes_by_stop
    }
  end

  defp stub_catalog(result_fn) do
    stub(CatalogReadAdapterMock, :load_stop_catalog, fn _org, _ver, opts ->
      result_fn.(opts)
    end)
  end

  describe "StopsLive shared table contract" do
    setup :shared_setup

    test "renders one shared table with stable tbody ID and route badge", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      stop =
        stop_fixture(organization.id, version.id, %{
          stop_id: "SHARED1",
          stop_name: "Shared Stop",
          parent_station: nil
        })

      route =
        route_fixture(organization.id, version.id, %{
          route_id: "R1",
          route_short_name: "R1",
          route_color: "FF0000"
        })

      stub_catalog(fn _opts ->
        {:ok, stop_page([stop], 1, 1, [route], %{stop.stop_id => [route]})}
      end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops")

      html = render(view)
      doc = LazyHTML.from_fragment(html)

      assert Enum.count(LazyHTML.query(doc, "table")) == 1
      assert Enum.count(LazyHTML.query(doc, "tbody#stops")) == 1
      assert Enum.count(LazyHTML.query(doc, "#stops-container")) == 1
    end

    test "table uses responsive stack and aria-sort on sortable headers", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      stop = stop_fixture(organization.id, version.id, %{stop_id: "SORT1", parent_station: nil})

      stub_catalog(fn _opts ->
        {:ok, stop_page([stop], 1, 1, [], %{})}
      end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops")

      html = render(view)
      doc = LazyHTML.from_fragment(html)

      tables = LazyHTML.query(doc, "table.ds-stack-table")
      assert Enum.count(tables) == 1

      assert has_element?(view, "th[aria-sort]")
    end

    test "stop ID column uses font-mono and link is primary", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      stop =
        stop_fixture(organization.id, version.id, %{
          stop_id: "MONO1",
          stop_name: "Mono Stop",
          parent_station: nil
        })

      stub_catalog(fn _opts ->
        {:ok, stop_page([stop], 1, 1, [], %{})}
      end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops")

      assert has_element?(view, "a.font-mono.link-primary", "MONO1")
    end
  end

  describe "StopsLive page header and type labels" do
    setup :shared_setup

    test "page header says Stops & stations; rows show Stop or Station per location_type", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      station =
        stop_fixture(organization.id, version.id, %{
          stop_id: "STA1",
          stop_name: "Central Station",
          location_type: 1,
          parent_station: nil
        })

      stop =
        stop_fixture(organization.id, version.id, %{
          stop_id: "STP1",
          stop_name: "Platform Stop",
          location_type: 0,
          parent_station: nil
        })

      stub_catalog(fn _opts ->
        {:ok, stop_page([station, stop], 2, 1, [], %{})}
      end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops")

      assert has_element?(view, "h1", "Stops & stations")
      assert has_element?(view, "td", "Station")
      assert has_element?(view, "td", "Stop/Platform")
    end
  end

  describe "StopsLive unavailable state and retry" do
    setup :shared_setup

    test "renders unavailable callout with retry button when adapter returns error", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      stub_catalog(fn _opts -> {:error, :unavailable} end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops")

      assert has_element?(view, "#stops-unavailable")
      assert has_element?(view, "#stops-retry")
    end

    test "retry restores rows after unavailable", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      stop = stop_fixture(organization.id, version.id, %{stop_id: "RETRY1", parent_station: nil})

      call_count = :atomics.new(1, [])

      stub_catalog(fn _opts ->
        count = :atomics.add_get(call_count, 1, 1)

        if count <= 1 do
          {:error, :unavailable}
        else
          {:ok, stop_page([stop], 1, 1, [], %{})}
        end
      end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops")

      assert has_element?(view, "#stops-unavailable")

      view
      |> element("#stops-retry")
      |> render_click()

      refute has_element?(view, "#stops-unavailable")
      assert has_element?(view, "a", "RETRY1")
    end
  end

  describe "StopsLive partial enrichment" do
    setup :shared_setup

    test "partial enrichment shows rows with enrichment warning and retry button", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      stop =
        stop_fixture(organization.id, version.id, %{
          stop_id: "PARTIAL1",
          stop_name: "Partial Stop",
          parent_station: nil
        })

      stub_catalog(fn _opts ->
        {:partial, stop_page([stop], 1, 1, [], %{}), :route_enrichment_unavailable}
      end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops")

      assert has_element?(view, "a", "PARTIAL1")
      assert has_element?(view, "#stops-enrichment-warning")
      assert has_element?(view, "#stops-enrichment-retry")
    end

    test "retry after enrichment failure restores route badges without losing search/filter state",
         %{
           conn: conn,
           user: user,
           organization: organization,
           gtfs_version: version
         } do
      conn = log_in_user(conn, user, organization: organization)

      stop =
        stop_fixture(organization.id, version.id, %{
          stop_id: "ENRICH1",
          stop_name: "Enrich Stop",
          parent_station: nil
        })

      route =
        route_fixture(organization.id, version.id, %{
          route_id: "ER1",
          route_short_name: "ER1",
          route_color: "00FF00"
        })

      call_count = :atomics.new(1, [])

      stub_catalog(fn _opts ->
        count = :atomics.add_get(call_count, 1, 1)

        if count <= 1 do
          {:partial, stop_page([stop], 1, 1, [], %{}), :route_enrichment_unavailable}
        else
          {:ok, stop_page([stop], 1, 1, [route], %{stop.stop_id => [route]})}
        end
      end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops?search=enrich")

      assert has_element?(view, "#stops-enrichment-warning")

      view
      |> element("#stops-enrichment-retry")
      |> render_click()

      refute has_element?(view, "#stops-enrichment-warning")
      assert has_element?(view, "a", "ENRICH1")
    end
  end

  describe "StopsLive page clamping" do
    setup :shared_setup

    test "out-of-range page patches to canonical page", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      stops =
        Enum.map(1..75, fn idx ->
          stop_fixture(organization.id, version.id, %{
            stop_id: "CL#{String.pad_leading(Integer.to_string(idx), 3, "0")}",
            stop_name: "Stop #{idx}",
            parent_station: nil
          })
        end)

      stub_catalog(fn opts ->
        page = Keyword.get(opts, :page, 1)
        per_page = Keyword.get(opts, :per_page, 50)
        total = 75
        max_page = max(1, ceil(total / per_page))
        canonical = min(max(page, 1), max_page)

        rows =
          stops
          |> Enum.drop((canonical - 1) * per_page)
          |> Enum.take(per_page)

        {:ok, stop_page(rows, total, canonical, [], %{})}
      end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops?page=999")

      # Connected render triggers push_patch to canonical page=2 which
      # live/2 processes internally; assert the rendered content reflects it.
      html = render(view)
      assert html =~ "CL051"
      refute html =~ "CL001"
    end
  end

  describe "StopsLive search and filter reset page" do
    setup :shared_setup

    test "search change resets page to 1", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      stop = stop_fixture(organization.id, version.id, %{stop_id: "SRCH1", parent_station: nil})

      stub_catalog(fn opts ->
        page = Keyword.get(opts, :page, 1)
        {:ok, stop_page([stop], 1, page, [], %{})}
      end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops?page=2")

      view
      |> form("#stop-search-form", %{"search" => "test"})
      |> render_change()

      assert_patched(view, "/gtfs/#{version.id}/stops?search=test")
    end
  end

  describe "StopsLive empty states" do
    setup :shared_setup

    test "first-use empty state with Import feed link when no stops and no filters", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      stub_catalog(fn _opts -> {:ok, stop_page([], 0, 1, [], %{})} end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops")

      assert has_element?(view, "#stops-first-use-empty")
      assert has_element?(view, "#stops-first-use-empty a", "Import feed")
    end

    test "constrained empty with Clear search when search active and no filters", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      stub_catalog(fn _opts -> {:ok, stop_page([], 0, 1, [], %{})} end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops?search=nonexistent")

      assert has_element?(view, "#stops-constrained-empty")
      assert has_element?(view, "#stops-clear-filters", "Clear search")
    end

    test "constrained empty with Clear filters when filter active", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      stub_catalog(fn _opts -> {:ok, stop_page([], 0, 1, [], %{})} end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops?wheelchair_boarding=1")

      assert has_element?(view, "#stops-constrained-empty")
      assert has_element?(view, "#stops-clear-filters", "Clear filters")
    end

    test "clear filters restores rows", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      stop = stop_fixture(organization.id, version.id, %{stop_id: "CLEAR1", parent_station: nil})

      stub_catalog(fn opts ->
        search = Keyword.get(opts, :search, "")
        wheelchair = Keyword.get(opts, :wheelchair_boarding)

        cond do
          search == "nonexistent" ->
            {:ok, stop_page([], 0, 1, [], %{})}

          wheelchair == 1 ->
            {:ok, stop_page([], 0, 1, [], %{})}

          true ->
            {:ok, stop_page([stop], 1, 1, [], %{})}
        end
      end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops?search=nonexistent")

      assert has_element?(view, "#stops-constrained-empty")

      view
      |> element("#stops-clear-filters")
      |> render_click()

      assert_patched(view, "/gtfs/#{version.id}/stops")
      assert has_element?(view, "a", "CLEAR1")
    end
  end

  describe "StopsLive search form" do
    setup :shared_setup

    test "search form has stable ID, visible label, and names-and-IDs hint", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      stub_catalog(fn _opts -> {:ok, stop_page([], 0, 1, [], %{})} end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops")

      assert has_element?(view, "form#stop-search-form")
      assert has_element?(view, "#stop-search-form label", "Search")
      assert has_element?(view, "#stop-search-form input[type='search']")
      html = render(view)
      assert html =~ "Search names and IDs"
    end
  end

  describe "StopsLive pagination" do
    setup :shared_setup

    test "renders shared pagination with configured event", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      stops =
        Enum.map(1..51, fn idx ->
          stop_fixture(organization.id, version.id, %{
            stop_id: "PG#{String.pad_leading(Integer.to_string(idx), 3, "0")}",
            stop_name: "Stop #{idx}",
            parent_station: nil
          })
        end)

      stub_catalog(fn opts ->
        page = Keyword.get(opts, :page, 1)

        rows =
          case page do
            1 -> Enum.take(stops, 50)
            2 -> Enum.drop(stops, 50)
            _ -> []
          end

        {:ok, stop_page(rows, 51, page, [], %{})}
      end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops")

      assert has_element?(view, "button[phx-click='paginate']", "Previous")
      assert has_element?(view, "button[phx-click='paginate']", "Next")
    end
  end

  describe "StopsLive version switching" do
    setup :shared_setup

    test "handle_event switch_gtfs_version navigates to new URL", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version1
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, version2} = GtfsPlanner.Versions.create_gtfs_version(organization.id, %{name: "V2"})

      stub_catalog(fn _opts -> {:ok, stop_page([], 0, 1, [], %{})} end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version1.id}/stops")

      render_hook(view, "switch_gtfs_version", %{"version" => to_string(version2.id)})

      assert_redirect(view, "/gtfs/#{version2.id}/stops")
    end

    test "switch_gtfs_version does not navigate to an unavailable version", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version1
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, staging} =
        GtfsPlanner.Versions.create_staging_gtfs_version(organization.id, %{name: "Staging"})

      other_org = organization_fixture()
      foreign = gtfs_version_fixture(other_org.id)

      stub_catalog(fn _opts -> {:ok, stop_page([], 0, 1, [], %{})} end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version1.id}/stops")

      for bad_id <- [to_string(staging.id), to_string(foreign.id), "not-a-uuid"] do
        html = render_hook(view, "switch_gtfs_version", %{"version" => bad_id})
        assert html =~ "Stops"
        refute_redirected(view)
      end
    end

    test "gtfs_version_loaded does not navigate to an unavailable version", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version1
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, staging} =
        GtfsPlanner.Versions.create_staging_gtfs_version(organization.id, %{name: "Staging"})

      other_org = organization_fixture()
      foreign = gtfs_version_fixture(other_org.id)

      stub_catalog(fn _opts -> {:ok, stop_page([], 0, 1, [], %{})} end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version1.id}/stops")

      for bad_id <- [to_string(staging.id), to_string(foreign.id), "not-a-uuid"] do
        html = render_hook(view, "gtfs_version_loaded", %{"version_id" => bad_id})
        assert html =~ "Stops"
        refute_redirected(view)
      end
    end
  end

  describe "StopsLive loading lifecycle" do
    setup :shared_setup
    setup :set_mox_global

    test "disconnected render shows loading without calling adapter", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      conn = get(conn, "/gtfs/#{version.id}/stops")

      assert conn.status == 200
      html = conn.resp_body

      doc = LazyHTML.from_fragment(html)

      assert Enum.count(LazyHTML.query(doc, "#stops-loading")) == 1

      assert Enum.count(
               LazyHTML.query(doc, "#stops-loading[aria-busy='true'][aria-live='polite']")
             ) == 1

      assert Enum.empty?(LazyHTML.query(doc, "#stops-first-use-empty"))
      assert Enum.empty?(LazyHTML.query(doc, "#stops-constrained-empty"))
    end

    test "connected render calls adapter once and transitions to ready", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      stop =
        stop_fixture(organization.id, version.id, %{
          stop_id: "LOAD1",
          stop_name: "Loaded Stop",
          parent_station: nil
        })

      expect(CatalogReadAdapterMock, :load_stop_catalog, fn _org, _ver, _opts ->
        {:ok, stop_page([stop], 1, 1, [], %{})}
      end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops")

      html = render(view)
      assert html =~ "LOAD1"
      refute html =~ "id=\"stops-loading\""
    end

    test "loading prevents empty-state rendering", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      conn = get(conn, "/gtfs/#{version.id}/stops")

      assert conn.status == 200
      html = conn.resp_body

      doc = LazyHTML.from_fragment(html)

      assert Enum.count(LazyHTML.query(doc, "#stops-loading")) == 1
      assert Enum.empty?(LazyHTML.query(doc, "#stops-first-use-empty"))
      assert Enum.empty?(LazyHTML.query(doc, "#stops-constrained-empty"))
      assert Enum.empty?(LazyHTML.query(doc, "#stops-unavailable"))
      assert Enum.empty?(LazyHTML.query(doc, "#stops-enrichment-warning"))
      assert Enum.count(LazyHTML.query(doc, "tbody#stops")) == 1
      assert Enum.empty?(LazyHTML.query(doc, "tbody#stops tr"))
    end

    test "loading state disables filter selects and search input", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      conn = get(conn, "/gtfs/#{version.id}/stops")

      assert conn.status == 200
      html = conn.resp_body

      doc = LazyHTML.from_fragment(html)

      route_select = LazyHTML.query(doc, "select#route_id")
      refute Enum.empty?(route_select)
      route_select_el = Enum.at(route_select, 0)
      assert not is_nil(LazyHTML.attribute(route_select_el, "disabled"))

      access_select = LazyHTML.query(doc, "select#wheelchair_boarding")
      refute Enum.empty?(access_select)
      access_select_el = Enum.at(access_select, 0)
      assert not is_nil(LazyHTML.attribute(access_select_el, "disabled"))

      search_input = LazyHTML.query(doc, "input#search")
      refute Enum.empty?(search_input)
      search_input_el = Enum.at(search_input, 0)
      assert not is_nil(LazyHTML.attribute(search_input_el, "disabled"))
    end

    test "controls re-enable and table renders after loading resolves", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      stop =
        stop_fixture(organization.id, version.id, %{
          stop_id: "RELOAD1",
          stop_name: "Reload Stop",
          parent_station: nil
        })

      expect(CatalogReadAdapterMock, :load_stop_catalog, fn _org, _ver, _opts ->
        {:ok, stop_page([stop], 1, 1, [], %{})}
      end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops")

      assert has_element?(view, "#stops-container")
      assert has_element?(view, "a", "RELOAD1")

      refute has_element?(view, "#route_id[disabled]")
      refute has_element?(view, "#search[disabled]")
    end

    test "loading guard preserves URL-derived filter values", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      stop =
        stop_fixture(organization.id, version.id, %{
          stop_id: "URLVAL1",
          stop_name: "URL Value Stop",
          parent_station: nil
        })

      conn = get(conn, "/gtfs/#{version.id}/stops?search=testsearch&wheelchair_boarding=1")

      assert conn.status == 200
      html = conn.resp_body

      doc = LazyHTML.from_fragment(html)

      assert Enum.count(LazyHTML.query(doc, "#stops-loading")) == 1
      assert Enum.count(LazyHTML.query(doc, "input#search[value='testsearch']")) == 1

      expect(CatalogReadAdapterMock, :load_stop_catalog, fn _org, _ver, opts ->
        assert Keyword.get(opts, :search) == "testsearch"
        {:ok, stop_page([stop], 1, 1, [], %{})}
      end)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{version.id}/stops?search=testsearch&wheelchair_boarding=1")

      connected = render(view)
      assert connected =~ "URLVAL1"
    end

    test "loading keeps URL-derived sort and pagination controls visible and disabled", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      conn =
        get(
          conn,
          "/gtfs/#{version.id}/stops?sort_by=stop_id&sort_dir=desc&page=3"
        )

      assert conn.status == 200
      doc = LazyHTML.from_fragment(conn.resp_body)

      assert Enum.count(LazyHTML.query(doc, "#stops-container")) == 1
      assert Enum.count(LazyHTML.query(doc, "th[aria-sort='descending']")) == 1
      assert Enum.count(LazyHTML.query(doc, "th button[disabled]")) == 3
      assert Enum.count(LazyHTML.query(doc, "button[phx-click='paginate'][disabled]")) == 2

      assert Enum.count(LazyHTML.query(doc, "button[phx-click='paginate'][phx-value-page='2']")) ==
               1

      assert Enum.count(LazyHTML.query(doc, "button[phx-click='paginate'][phx-value-page='4']")) ==
               1
    end
  end

  describe "StopsLive route filtering" do
    setup :shared_setup

    test "can filter by route", %{
      conn: conn,
      user: user,
      organization: org,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: org)

      station1 =
        stop_fixture(org.id, version.id, %{
          stop_id: "S1",
          stop_name: "Station 1",
          parent_station: nil
        })

      route1 =
        route_fixture(org.id, version.id, %{route_id: "R1", route_short_name: "Route 1"})

      station2 =
        stop_fixture(org.id, version.id, %{
          stop_id: "S2",
          stop_name: "Station 2",
          parent_station: nil
        })

      _route2 =
        route_fixture(org.id, version.id, %{route_id: "R2", route_short_name: "Route 2"})

      stub_catalog(fn opts ->
        route_id = Keyword.get(opts, :route_id, "")

        case route_id do
          "R1" ->
            {:ok, stop_page([station1], 1, 1, [route1], %{station1.stop_id => [route1]})}

          _ ->
            {:ok,
             stop_page([station1, station2], 2, 1, [route1], %{
               station1.stop_id => [route1]
             })}
        end
      end)

      {:ok, view, html} = live(conn, "/gtfs/#{version.id}/stops")

      assert html =~ "Routes"
      assert has_element?(view, "#stop-filter-form select[name='route_id']")

      html =
        view
        |> form("#stop-filter-form", %{"route_id" => "R1"})
        |> render_change()

      assert html =~ "Station 1"
      refute html =~ "Station 2"
      assert_patched(view, "/gtfs/#{version.id}/stops?route_id=R1")
    end
  end
end
