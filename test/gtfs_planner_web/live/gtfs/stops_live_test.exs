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
    stub(CatalogReadAdapterMock, :load_stop_route_options, fn _org, _ver -> {:ok, []} end)

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

  defp stop_page(rows, total_count, page, routes_by_stop) do
    %{
      rows: rows,
      total_count: total_count,
      page: page,
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
        {:ok, stop_page([stop], 1, 1, %{stop.stop_id => [route]})}
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
        {:ok, stop_page([stop], 1, 1, %{})}
      end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops")

      html = render(view)
      doc = LazyHTML.from_fragment(html)

      tables = LazyHTML.query(doc, "table.ds-stack-table")
      assert Enum.count(tables) == 1

      assert has_element?(view, "th[aria-sort]")
    end

    test "stop name is the link and the stop ID is a mono cell", %{
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
        {:ok, stop_page([stop], 1, 1, %{})}
      end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops")

      assert has_element?(
               view,
               "#stops th a[href='/gtfs/#{version.id}/stops/MONO1']",
               "Mono Stop"
             )

      assert has_element?(view, "#stops td.font-mono", "MONO1")
    end
  end

  describe "StopsLive stop links" do
    setup :shared_setup

    test "links a stop whose ID has reserved URL characters by its encoded path and opens its detail page",
         %{conn: conn, user: user, organization: organization, gtfs_version: version} do
      # This case reads through the production adapter; the setup's on_exit
      # restores the mock override.
      Application.delete_env(:gtfs_planner, @adapter_key)

      conn = log_in_user(conn, user, organization: organization)

      stop_fixture(organization.id, version.id, %{
        stop_id: "QA/STN 1",
        stop_name: "Slash Station",
        location_type: 1
      })

      {:ok, list_view, _html} = live(conn, "/gtfs/#{version.id}/stops")

      [href] =
        list_view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("tbody#stops a")
        |> LazyHTML.attribute("href")

      assert href == "/gtfs/#{version.id}/stops/QA%2FSTN%201"

      {:ok, detail_view, _html} = live(conn, href)

      assert has_element?(detail_view, "#station-sub-nav h1", "Slash Station")
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
        {:ok, stop_page([station, stop], 2, 1, %{})}
      end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops")

      assert has_element?(view, "h1", "Stops & stations")
      assert has_element?(view, "td", "Station")
      assert has_element?(view, "td", "Stop/Platform")
    end
  end

  describe "StopsLive Map view entry points" do
    setup :shared_setup

    test "the header offers the Map view and Add stop, with List marked current", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      stub_catalog(fn _opts ->
        {:ok, stop_page([], 0, 1, %{})}
      end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops")

      assert has_element?(view, "#stops-view-map[href='/gtfs/#{version.id}/stops/map']")

      assert has_element?(
               view,
               "#stops-add-stop[href='/gtfs/#{version.id}/stops/map?add=1']",
               "Add stop"
             )

      assert view |> element("#stops-view-list") |> render() =~ "aria-current=\"page\""
    end

    test "the first-use state makes Add stop primary and Import feed secondary", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      stub_catalog(fn _opts ->
        {:ok, stop_page([], 0, 1, %{})}
      end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops")

      assert has_element?(view, "#stops-first-use-empty")
      assert has_element?(view, "#stops-first-use-add-stop", "Add stop")
      assert has_element?(view, "#stops-first-use-import", "Import feed")

      # The header's own Add stop is still there in the first-use state, so a
      # version with no stops has two identical entry points.
      assert has_element?(view, "#stops-add-stop")

      add =
        view |> element("#stops-first-use-add-stop") |> render()

      assert add =~ "/stops/map?add=1"
      assert add =~ "btn-primary"

      import_button =
        view |> element("#stops-first-use-import") |> render()

      assert import_button =~ "btn-outline"
      refute import_button =~ "btn-primary"
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

    test "keeps a URL-selected route visible when the catalog is unavailable", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      stub_catalog(fn _opts -> {:error, :unavailable} end)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{version.id}/stops?route_id=BOOKMARKED")

      assert has_element?(view, "#stops-unavailable")
      assert has_element?(view, "#route_id option[value='BOOKMARKED'][selected]", "BOOKMARKED")
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
          {:ok, stop_page([stop], 1, 1, %{})}
        end
      end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops")

      assert has_element?(view, "#stops-unavailable")

      view
      |> element("#stops-retry")
      |> render_click()

      refute has_element?(view, "#stops-unavailable")
      assert has_element?(view, "#stops td", "RETRY1")
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
        {:partial, stop_page([stop], 1, 1, %{}), :route_enrichment_unavailable}
      end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops")

      assert has_element?(view, "#stops td", "PARTIAL1")
      assert has_element?(view, "#stops-enrichment-warning")
      assert has_element?(view, "#stops-enrichment-retry", "Reload routes")
      assert has_element?(view, "#stops td", "Unavailable")
      refute has_element?(view, "#stops td", "Not served")
      assert has_element?(view, "select#route_id[disabled]")
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
          {:partial, stop_page([stop], 1, 1, %{}), :route_enrichment_unavailable}
        else
          {:ok, stop_page([stop], 1, 1, %{stop.stop_id => [route]})}
        end
      end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops?search=enrich")

      assert has_element?(view, "#stops-enrichment-warning")

      view
      |> element("#stops-enrichment-retry")
      |> render_click()

      refute has_element?(view, "#stops-enrichment-warning")
      assert has_element?(view, "#stops td", "ENRICH1")
    end
  end

  describe "StopsLive page clamping" do
    setup :shared_setup
    setup :set_mox_global

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

      catalog_result = fn opts ->
        page = Keyword.get(opts, :page, 1)
        per_page = Keyword.get(opts, :per_page, 50)
        total = 75
        max_page = max(1, ceil(total / per_page))
        canonical = min(max(page, 1), max_page)

        rows =
          stops
          |> Enum.drop((canonical - 1) * per_page)
          |> Enum.take(per_page)

        {:ok, stop_page(rows, total, canonical, %{})}
      end

      expect(CatalogReadAdapterMock, :load_stop_catalog, fn _org, _version, opts ->
        catalog_result.(opts)
      end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops?page=999")

      assert has_element?(view, "#stops td", "CL051")
      refute has_element?(view, "#stops td", "CL001")
      assert has_element?(view, "button[phx-click='paginate'][phx-value-page='1']", "Previous")

      assert has_element?(
               view,
               "button[phx-click='paginate'][phx-value-page='3'][disabled]",
               "Next"
             )

      # live/2 consumes mount-time patches before returning the view, so there is
      # no stable assert_patch/2 observation point here. The exact Mox expectation
      # proves the canonical patch did not trigger a second catalog read, while
      # the DOM assertions prove that the loaded result is canonical page 2.

      expect(CatalogReadAdapterMock, :load_stop_catalog, fn _org, _version, opts ->
        catalog_result.(opts)
      end)

      render_patch(view, "/gtfs/#{version.id}/stops?page=999")

      requested_path = assert_patch(view)
      requested_uri = URI.parse(requested_path)

      assert requested_uri.path == "/gtfs/#{version.id}/stops"
      assert URI.decode_query(requested_uri.query)["page"] == "999"

      canonical_path = assert_patch(view)
      canonical_uri = URI.parse(canonical_path)

      assert canonical_uri.path == "/gtfs/#{version.id}/stops"
      assert URI.decode_query(canonical_uri.query)["page"] == "2"

      assert has_element?(view, "#stops td", "CL051")
      refute has_element?(view, "#stops td", "CL001")
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
        {:ok, stop_page([stop], 1, page, %{})}
      end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops?page=2")

      view
      |> form("#stop-search-form", %{"search" => "test"})
      |> render_change()

      assert_patched(view, "/gtfs/#{version.id}/stops?search=test")
    end

    test "a whitespace-only search patches a URL without search and lists every row", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      stop = stop_fixture(organization.id, version.id, %{stop_id: "WSSRCH", parent_station: nil})

      stub_catalog(fn opts ->
        case Keyword.get(opts, :search) do
          "" -> {:ok, stop_page([stop], 1, 1, [], %{})}
          _blank -> {:ok, stop_page([], 0, 1, [], %{})}
        end
      end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops")

      html =
        view
        |> form("#stop-search-form", %{"search" => " "})
        |> render_change()

      assert_patched(view, "/gtfs/#{version.id}/stops")
      assert html =~ "WSSRCH"
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

      stub_catalog(fn _opts -> {:ok, stop_page([], 0, 1, %{})} end)

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

      stub_catalog(fn _opts -> {:ok, stop_page([], 0, 1, %{})} end)

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

      stub_catalog(fn _opts -> {:ok, stop_page([], 0, 1, %{})} end)

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
            {:ok, stop_page([], 0, 1, %{})}

          wheelchair == 1 ->
            {:ok, stop_page([], 0, 1, %{})}

          true ->
            {:ok, stop_page([stop], 1, 1, %{})}
        end
      end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops?search=nonexistent")

      assert has_element?(view, "#stops-constrained-empty")

      view
      |> element("#stops-clear-filters")
      |> render_click()

      assert_patched(view, "/gtfs/#{version.id}/stops")
      assert has_element?(view, "#stops td", "CLEAR1")
    end
  end

  describe "StopsLive search form" do
    setup :shared_setup

    test "search form has stable ID, visible label, and a name-or-ID placeholder", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      stop = stop_fixture(organization.id, version.id, %{stop_id: "FORM1", parent_station: nil})
      stub_catalog(fn _opts -> {:ok, stop_page([stop], 1, 1, %{})} end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops")

      assert has_element?(view, "form#stop-search-form")
      assert has_element?(view, "#stop-search-form label", "Search stops and stations")

      assert has_element?(
               view,
               "#stop-search-form input[type='search'][placeholder='Stop name or ID']"
             )
    end

    test "first-use empty state hides the search and filters", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      stub_catalog(fn _opts -> {:ok, stop_page([], 0, 1, %{})} end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops")

      assert has_element?(view, "#stops-first-use-empty")
      refute has_element?(view, "#stop-search-form")
      refute has_element?(view, "#stop-filter-form")
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

        {:ok, stop_page(rows, 51, page, %{})}
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

      stub_catalog(fn _opts -> {:ok, stop_page([], 0, 1, %{})} end)

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

      stub_catalog(fn _opts -> {:ok, stop_page([], 0, 1, %{})} end)

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

      stub_catalog(fn _opts -> {:ok, stop_page([], 0, 1, %{})} end)

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

    test "loading keeps the table layout with placeholder rows", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      conn = get(conn, "/gtfs/#{version.id}/stops")

      doc = LazyHTML.from_fragment(conn.resp_body)

      assert Enum.count(LazyHTML.query(doc, "#stops-container thead th")) == 5
      refute Enum.empty?(LazyHTML.query(doc, "#stops-skeleton[aria-hidden='true'] tr"))
      assert Enum.empty?(LazyHTML.query(doc, "#stops-count"))
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
        {:ok, stop_page([stop], 1, 1, %{})}
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
        {:ok, stop_page([stop], 1, 1, %{})}
      end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops")

      assert has_element?(view, "#stops-container")
      assert has_element?(view, "#stops td", "RELOAD1")

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
        {:ok, stop_page([stop], 1, 1, %{})}
      end)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{version.id}/stops?search=testsearch&wheelchair_boarding=1")

      connected = render(view)
      assert connected =~ "URLVAL1"
    end

    test "disconnected loading keeps a URL-selected route visible", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      conn = get(conn, "/gtfs/#{version.id}/stops?route_id=BOOKMARKED")

      assert conn.status == 200
      doc = LazyHTML.from_fragment(conn.resp_body)

      assert Enum.count(LazyHTML.query(doc, "#route_id option[value='BOOKMARKED'][selected]")) ==
               1
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

  describe "StopsLive rows" do
    setup :shared_setup

    test "the name links to the stop and carries its description", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      stop =
        stop_fixture(organization.id, version.id, %{
          stop_id: "ROW1",
          stop_name: "9th St & US 101",
          stop_desc: "Southbound",
          parent_station: nil
        })

      stub_catalog(fn _opts -> {:ok, stop_page([stop], 1, 1, %{})} end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops")

      assert has_element?(
               view,
               "#stops th a[href='/gtfs/#{version.id}/stops/ROW1']",
               "9th St & US 101"
             )

      assert has_element?(view, "#stops th a", "Southbound")
    end

    test "a stop with no name is opened by its ID", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      stop =
        stop_fixture(organization.id, version.id, %{
          stop_id: "NONAME1",
          stop_name: nil,
          parent_station: nil
        })

      stub_catalog(fn _opts -> {:ok, stop_page([stop], 1, 1, %{})} end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops")

      assert has_element?(view, "#stops th a", "NONAME1")
    end

    test "wheelchair access reads Accessible, Not accessible or Not recorded", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      accessible =
        stop_fixture(organization.id, version.id, %{
          stop_id: "ACC1",
          wheelchair_boarding: 1,
          parent_station: nil
        })

      blocked =
        stop_fixture(organization.id, version.id, %{
          stop_id: "ACC2",
          wheelchair_boarding: 2,
          parent_station: nil
        })

      unknown =
        stop_fixture(organization.id, version.id, %{
          stop_id: "ACC0",
          wheelchair_boarding: 0,
          parent_station: nil
        })

      stub_catalog(fn _opts ->
        {:ok, stop_page([accessible, blocked, unknown], 3, 1, %{})}
      end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops")

      assert has_element?(view, "#stops tr [data-accessibility='accessible']", "Accessible")

      assert has_element?(
               view,
               "#stops tr [data-accessibility='not_accessible']",
               "Not accessible"
             )

      assert has_element?(view, "#stops tr [data-accessibility='unknown']", "Not recorded")
    end

    test "a stop no trip serves says Not served, and served stops show their badges", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      served = stop_fixture(organization.id, version.id, %{stop_id: "SRV1", parent_station: nil})
      idle = stop_fixture(organization.id, version.id, %{stop_id: "SRV2", parent_station: nil})

      route =
        route_fixture(organization.id, version.id, %{route_id: "R9", route_short_name: "R9"})

      stub_catalog(fn _opts ->
        {:ok, stop_page([served, idle], 2, 1, %{served.stop_id => [route]})}
      end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops")

      assert has_element?(view, "#stops-#{served.id} td", "R9")
      assert has_element?(view, "#stops-#{idle.id} td", "Not served")
    end

    test "phones get a list whose item links to the stop", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      station =
        stop_fixture(organization.id, version.id, %{
          stop_id: "PH1",
          stop_name: "Central Station",
          location_type: 1,
          parent_station: nil
        })

      stub_catalog(fn _opts -> {:ok, stop_page([station], 1, 1, %{})} end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops")

      assert has_element?(
               view,
               "#stops-list li a[href='/gtfs/#{version.id}/stops/PH1']",
               "Central Station"
             )

      assert has_element?(view, "#stops-list li a", "ID PH1 · Station")
    end
  end

  describe "StopsLive result count and constraints" do
    setup :shared_setup

    test "counts the catalog, then the matches once a constraint is set", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      stops =
        for id <- ["CNT1", "CNT2"],
            do: stop_fixture(organization.id, version.id, %{stop_id: id, parent_station: nil})

      stub_catalog(fn opts ->
        if Keyword.get(opts, :search) == "cnt1",
          do: {:ok, stop_page([hd(stops)], 1, 1, %{})},
          else: {:ok, stop_page(stops, 2, 1, %{})}
      end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops")
      assert has_element?(view, "#stops-count", "2 stops and stations")
      refute has_element?(view, "#stops-chips button")

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops?search=cnt1")
      assert has_element?(view, "#stops-count", "1 stop or station matches")
    end

    test "shows one removable chip per constraint, labelled with the chosen value", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      stop = stop_fixture(organization.id, version.id, %{stop_id: "CHIP1", parent_station: nil})

      route =
        route_fixture(organization.id, version.id, %{route_id: "R7", route_short_name: "Seven"})

      stub(CatalogReadAdapterMock, :load_stop_route_options, fn _org, _ver -> {:ok, [route]} end)
      stub_catalog(fn _opts -> {:ok, stop_page([stop], 1, 1, %{})} end)

      {:ok, view, _html} =
        live(
          conn,
          "/gtfs/#{version.id}/stops?search=harbour&route_id=R7&direction_id=1&wheelchair_boarding=2"
        )

      assert has_element?(view, "#stops-chip-search", "“harbour”")
      assert has_element?(view, "#stops-chip-route_id", "Seven")
      assert has_element?(view, "#stops-chip-direction_id", "Inbound")
      assert has_element?(view, "#stops-chip-wheelchair_boarding", "Not accessible")
      assert has_element?(view, "#stops-clear-filters", "Clear filters")
    end

    test "removing the search chip keeps the other filters", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      stop = stop_fixture(organization.id, version.id, %{stop_id: "CHIP2", parent_station: nil})
      stub_catalog(fn _opts -> {:ok, stop_page([stop], 1, 1, %{})} end)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{version.id}/stops?search=harbour&wheelchair_boarding=2")

      view |> element("#stops-chip-search") |> render_click()

      assert_patched(view, "/gtfs/#{version.id}/stops?wheelchair_boarding=2")
    end

    test "removing the route chip also drops its direction", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      stop = stop_fixture(organization.id, version.id, %{stop_id: "CHIP3", parent_station: nil})
      stub_catalog(fn _opts -> {:ok, stop_page([stop], 1, 1, %{})} end)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{version.id}/stops?route_id=R1&direction_id=0&search=main")

      view |> element("#stops-chip-route_id") |> render_click()

      assert_patched(view, "/gtfs/#{version.id}/stops?search=main")
    end

    test "choosing another route resets the direction, and other changes keep it", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      stop = stop_fixture(organization.id, version.id, %{stop_id: "DIR1", parent_station: nil})

      routes =
        for id <- ["R1", "R2"],
            do: route_fixture(organization.id, version.id, %{route_id: id, route_short_name: id})

      stub_catalog(fn _opts -> {:ok, stop_page([stop], 1, 1, %{})} end)

      stub(CatalogReadAdapterMock, :load_stop_route_options, fn _org, _ver -> {:ok, routes} end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops?route_id=R1&direction_id=1")

      view
      |> form("#stop-filter-form", %{"wheelchair_boarding" => "1"})
      |> render_change()

      assert_patched(
        view,
        "/gtfs/#{version.id}/stops?direction_id=1&route_id=R1&wheelchair_boarding=1"
      )

      view
      |> form("#stop-filter-form", %{"route_id" => "R2"})
      |> render_change()

      assert_patched(view, "/gtfs/#{version.id}/stops?route_id=R2&wheelchair_boarding=1")
    end

    test "the direction select appears only with a route and names Outbound and Inbound", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      stop = stop_fixture(organization.id, version.id, %{stop_id: "DIR2", parent_station: nil})
      stub_catalog(fn _opts -> {:ok, stop_page([stop], 1, 1, %{})} end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops")
      refute has_element?(view, "select#direction_id")

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops?route_id=R1")
      assert has_element?(view, "select#direction_id option[value='0']", "Outbound")
      assert has_element?(view, "select#direction_id option[value='1']", "Inbound")
    end
  end

  describe "StopsLive empty-result copy" do
    setup :shared_setup

    test "a search with no matches names the search", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      stub_catalog(fn _opts -> {:ok, stop_page([], 0, 1, %{})} end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops?search=harbour")

      assert has_element?(view, "#stops-constrained-empty h2", "No stops match “harbour”")
    end

    test "filters with no matches say so and offer Clear filters", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      stub_catalog(fn _opts -> {:ok, stop_page([], 0, 1, %{})} end)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{version.id}/stops?search=harbour&wheelchair_boarding=2")

      assert has_element?(view, "#stops-constrained-empty h2", "No stops match these filters")
      assert has_element?(view, "#stops-clear-filters", "Clear filters")
    end
  end

  describe "StopsLive route options" do
    setup :shared_setup

    test "loads route options once across search, filter, sort, page and retry", %{
      conn: conn,
      user: user,
      organization: org,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: org)
      stop = stop_fixture(org.id, version.id, %{stop_id: "OPTIONS"})
      route = route_fixture(org.id, version.id, %{route_id: "R1"})

      owner = self()

      stub(CatalogReadAdapterMock, :load_stop_route_options, fn org_id, version_id ->
        send(owner, :route_options_loaded)
        assert org_id == org.id
        assert version_id == version.id
        {:ok, [route]}
      end)

      stub_catalog(fn opts -> {:ok, stop_page([stop], 100, opts[:page], %{})} end)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops")

      for query <- ["search=OPTIONS", "route_id=R1", "sort_by=stop_id&sort_dir=desc", "page=2"] do
        render_patch(view, "/gtfs/#{version.id}/stops?#{query}")
        assert has_element?(view, "#route_id option[value='R1']")
      end

      render_click(view, "retry")
      refute has_element?(view, "#stops-enrichment-warning")
      assert_received :route_options_loaded
      refute_received :route_options_loaded
    end

    for retry <- [:patch, :button] do
      test "unavailable route options keep rows and recover on #{retry}", %{
        conn: conn,
        user: user,
        organization: org,
        gtfs_version: version
      } do
        conn = log_in_user(conn, user, organization: org)
        stop = stop_fixture(org.id, version.id, %{stop_id: "OPTIONS"})
        route = route_fixture(org.id, version.id, %{route_id: "R1"})

        expect(CatalogReadAdapterMock, :load_stop_route_options, fn _org, _ver ->
          {:error, :unavailable}
        end)

        expect(CatalogReadAdapterMock, :load_stop_route_options, fn _org, _ver ->
          {:ok, [route]}
        end)

        stub_catalog(fn _opts -> {:ok, stop_page([stop], 1, 1, %{})} end)

        {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops")
        assert has_element?(view, "#stops tr")
        assert has_element?(view, "#stops-enrichment-warning")
        assert has_element?(view, "#route_id[disabled]")

        case unquote(retry) do
          :patch -> render_patch(view, "/gtfs/#{version.id}/stops?sort_by=stop_id&sort_dir=desc")
          :button -> view |> element("#stops-enrichment-retry") |> render_click()
        end

        assert has_element?(view, "#route_id option[value='R1']")
        refute has_element?(view, "#route_id[disabled]")
        refute has_element?(view, "#stops-enrichment-warning")
      end
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

      stub(CatalogReadAdapterMock, :load_stop_route_options, fn _org, _ver -> {:ok, [route1]} end)

      stub_catalog(fn opts ->
        route_id = Keyword.get(opts, :route_id, "")

        case route_id do
          "R1" ->
            {:ok, stop_page([station1], 1, 1, %{station1.stop_id => [route1]})}

          _ ->
            {:ok,
             stop_page([station1, station2], 2, 1, %{
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

  describe "StopsLive malformed URL parameters" do
    setup :shared_setup

    setup %{conn: conn, user: user, organization: organization, gtfs_version: version} do
      stop =
        stop_fixture(organization.id, version.id, %{
          stop_id: "MALFORMED1",
          stop_name: "Malformed Stop",
          parent_station: nil
        })

      test_pid = self()

      stub_catalog(fn opts ->
        send(test_pid, {:catalog_opts, opts})
        {:ok, stop_page([stop], 1, 1, %{})}
      end)

      %{conn: log_in_user(conn, user, organization: organization)}
    end

    test "ignores a non-numeric wheelchair_boarding filter", %{conn: conn, gtfs_version: version} do
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops?wheelchair_boarding=abc")

      assert has_element?(view, "tbody#stops tr", "MALFORMED1")
      assert_received {:catalog_opts, opts}
      assert opts[:wheelchair_boarding] == nil
    end

    test "ignores an out-of-range wheelchair_boarding filter", %{
      conn: conn,
      gtfs_version: version
    } do
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops?wheelchair_boarding=7")

      assert has_element?(view, "tbody#stops tr", "MALFORMED1")
      assert_received {:catalog_opts, opts}
      assert opts[:wheelchair_boarding] == nil
    end

    test "ignores a non-numeric direction_id filter", %{conn: conn, gtfs_version: version} do
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops?route_id=R1&direction_id=x")

      assert has_element?(view, "tbody#stops tr", "MALFORMED1")
      assert_received {:catalog_opts, opts}
      assert opts[:direction_id] == nil
    end

    test "ignores an out-of-range direction_id filter", %{conn: conn, gtfs_version: version} do
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops?route_id=R1&direction_id=2")

      assert has_element?(view, "tbody#stops tr", "MALFORMED1")
      assert_received {:catalog_opts, opts}
      assert opts[:direction_id] == nil
    end

    test "keeps ascending order when sort_dir is the atom nil", %{
      conn: conn,
      gtfs_version: version
    } do
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops?sort_dir=nil")

      assert has_element?(view, "th[aria-sort='ascending']")
      assert_received {:catalog_opts, opts}
      assert opts[:sort_dir] == :asc
    end

    test "keeps ascending order when sort_dir is another existing atom", %{
      conn: conn,
      gtfs_version: version
    } do
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops?sort_dir=stop_name")

      assert has_element?(view, "th[aria-sort='ascending']")
      assert_received {:catalog_opts, opts}
      assert opts[:sort_dir] == :asc
    end

    test "sorts by stop name when sort_by is a column stops cannot sort by", %{
      conn: conn,
      gtfs_version: version
    } do
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops?sort_by=inserted_at")

      assert has_element?(view, "tbody#stops tr", "MALFORMED1")
      assert_received {:catalog_opts, opts}
      assert opts[:sort_by] == :stop_name
    end

    test "sorts by stop name when sort_by is route_id", %{conn: conn, gtfs_version: version} do
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops?sort_by=route_id")

      assert has_element?(view, "th[aria-sort='ascending']")
      assert_received {:catalog_opts, opts}
      assert opts[:sort_by] == :stop_name
    end

    test "uses the default sort when sort_by and sort_dir are both unknown", %{
      conn: conn,
      gtfs_version: version
    } do
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops?sort_by=nope&sort_dir=nope")

      assert has_element?(view, "th[aria-sort='ascending']")
      assert_received {:catalog_opts, opts}
      assert opts[:sort_by] == :stop_name
      assert opts[:sort_dir] == :asc
    end

    test "uses the default page when page is nested", %{conn: conn, gtfs_version: version} do
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops?page[a]=b")

      assert has_element?(view, "tbody#stops tr", "MALFORMED1")
      assert_received {:catalog_opts, opts}
      assert opts[:page] == 1
    end

    test "ignores a nested search value", %{conn: conn, gtfs_version: version} do
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops?search[a]=b")

      assert has_element?(view, "tbody#stops tr", "MALFORMED1")
      assert_received {:catalog_opts, opts}
      assert opts[:search] == ""
    end

    test "ignores a search value containing a NUL byte", %{conn: conn, gtfs_version: version} do
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops?search=%00")

      assert has_element?(view, "tbody#stops tr", "MALFORMED1")
      assert_received {:catalog_opts, opts}
      assert opts[:search] == ""
    end

    test "ignores a nested route_id value", %{conn: conn, gtfs_version: version} do
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops?route_id[a]=b")

      assert has_element?(view, "tbody#stops tr", "MALFORMED1")
      assert_received {:catalog_opts, opts}
      assert opts[:route_id] == ""
    end
  end
end
