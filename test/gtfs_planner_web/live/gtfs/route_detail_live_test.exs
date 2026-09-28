defmodule GtfsPlannerWeb.Gtfs.RouteDetailLiveTest do
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.TransfersFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.CatalogReadAdapter
  alias GtfsPlanner.Gtfs.CatalogReadAdapterMock
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

  # The Details workspace itself. The first case mounts the ordinary
  # authenticated route with the default catalog adapter: `RouteDetailLive`
  # reads through `Gtfs.load_route_editor/3` -> `CatalogReadAdapter.Repo`, so the
  # saved row, its agency options and its audit attribution are all production
  # reads (no private assign injection, no substituted adapter).
  describe "details workspace" do
    setup :shared_setup

    test "ordinary authenticated Details renders the saved values in the shared controls", %{
      conn: conn,
      organization: organization,
      gtfs_version: version
    } do
      agency_fixture(organization.id, version.id, %{
        agency_id: "AG1",
        agency_name: "Harbor Transit",
        agency_url: "https://harbor.example.com"
      })

      route =
        route_fixture(organization.id, version.id, %{
          route_id: "DETAILS1",
          route_short_name: "D1",
          route_long_name: "Details Route",
          route_type: 3,
          agency_id: "AG1",
          route_desc: "Runs along the waterfront.",
          route_url: "https://example.com/d1",
          route_color: "0B6E4F",
          route_text_color: "FFFFFF",
          route_sort_order: 7,
          continuous_pickup: 2,
          continuous_drop_off: 3,
          network_id: "HARBOR"
        })

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/#{route.route_id}")

      # The header is saved identity, and the form carries the same values.
      assert has_element?(view, "#route-details-heading", "Details Route")
      assert has_element?(view, "#route-details-badge")
      assert has_element?(view, "#route-details-mode-label", "Bus")

      assert has_element?(view, "#route-details-form #route-details-identity")
      assert has_element?(view, "#route-details-form #route-details-color-fields")
      assert has_element?(view, "#route-details-form #route-details-rider")
      assert has_element?(view, "#route-details-form #route-details-additional")

      assert has_element?(view, "input#route-details-short[value='D1']")
      assert has_element?(view, "input#route-details-long[value='Details Route']")
      assert has_element?(view, "textarea#route-details-desc", "Runs along the waterfront.")
      assert has_element?(view, "input#route-details-url[value='https://example.com/d1']")
      assert has_element?(view, "input#route-details-sort[value='7']")
      assert has_element?(view, "input#route-details-network[value='HARBOR']")
      assert has_element?(view, "select#route-details-pickup option[value='2'][selected]")
      assert has_element?(view, "select#route-details-dropoff option[value='3'][selected]")
      assert has_element?(view, "input#route-details-color[value='0B6E4F']")
      assert has_element?(view, "input#route-details-text[value='FFFFFF']")
      # A one-agency version reads the assignment, not a select (AC-5).
      assert has_element?(view, "#route-details-agency-readonly")
      assert has_element?(view, "input[type='hidden']#route-details-agency[value='AG1']")

      # The URL is editable content, never interpolated into a link.
      refute render(view) =~ ~s(href="https://example.com/d1")
    end

    test "Additional details is collapsed, summarizes its values and states the route ID read-only",
         %{
           conn: conn,
           organization: organization,
           gtfs_version: version
         } do
      route =
        route_fixture(organization.id, version.id, %{
          route_id: "DETAILS2",
          route_short_name: "D2",
          route_sort_order: 4,
          continuous_pickup: 0,
          continuous_drop_off: 1,
          network_id: "BAY"
        })

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/#{route.route_id}")

      # Collapsed by default (R7/AC-18): no `open` attribute, and the summary
      # repeats the values the closed disclosure still owes the operator.
      refute has_element?(view, "#route-details-additional[open]")

      assert has_element?(
               view,
               "#route-details-additional-summary",
               "Display order 4 · Boarding between stops: Anywhere along the route · Network BAY · Route ID DETAILS2"
             )

      # The natural ID is creation-only (R1), so it is stated, not editable.
      assert has_element?(view, "#route-details-route-id", "DETAILS2")
      assert has_element?(view, "#route-details-additional p", "Route ID")
      refute has_element?(view, "input[name='route[route_id]']")
      assert has_element?(view, "#route-details-additional label[for='route-details-sort']")
    end

    test "network and boarding defaults the route does not have are named as unset, not dropped",
         %{
           conn: conn,
           organization: organization,
           gtfs_version: version
         } do
      route =
        route_fixture(organization.id, version.id, %{
          route_id: "DETAILS3",
          route_short_name: "D3",
          route_sort_order: nil,
          network_id: nil
        })

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/#{route.route_id}")

      summary = view |> element("#route-details-additional-summary") |> render()

      assert summary =~ "Display order not set"
      assert summary =~ "Route ID DETAILS3"
      refute summary =~ "Network"
    end

    test "the saved-identity line names the real last-saved actor from the route audit", %{
      conn: conn,
      organization: organization,
      gtfs_version: version
    } do
      agency_fixture(organization.id, version.id, %{
        agency_id: "AG2",
        agency_name: "Harbor Transit",
        agency_url: "https://harbor.example.com"
      })

      route =
        route_fixture(organization.id, version.id, %{
          route_id: "DETAILS4",
          route_short_name: "D4",
          agency_id: "AG2"
        })

      actor = user_fixture()

      audit = %AuditContext{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        actor_id: actor.id,
        actor_email: actor.email
      }

      {:ok, _log} =
        Repo.transaction(fn ->
          case Gtfs.record_change_in_transaction(audit, :route, route, "updated", %{
                 before: %{"route_short_name" => "D3"},
                 after: %{"route_short_name" => "D4"}
               }) do
            {:ok, log} -> log
            {:error, changeset} -> Repo.rollback(changeset)
          end
        end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/#{route.route_id}")

      saved = view |> element("#route-details-saved-identity") |> render()
      assert saved =~ "Harbor Transit"
      assert saved =~ "Route ID DETAILS4"
      assert saved =~ "Last saved"
      assert saved =~ actor.email
    end

    test "a route with no audit entry reads as unknown attribution, never as a recent actor", %{
      conn: conn,
      organization: organization,
      gtfs_version: version
    } do
      route =
        route_fixture(organization.id, version.id, %{
          route_id: "DETAILS5",
          route_short_name: "D5",
          agency_id: nil
        })

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/#{route.route_id}")

      assert has_element?(
               view,
               "#route-details-saved-identity",
               "Last saved never — imported or unknown attribution"
             )
    end

    test "the transfers link keeps counting this route's general rules", %{
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

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/24")

      assert has_element?(view, "#route-transfers-link", "Transfers here (1)")
      assert has_element?(view, "#route-details-map-region")
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

      stub(CatalogReadAdapterMock, :load_route_editor, fn _org, _ver, _route_id ->
        {:error, :unavailable}
      end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/UNAVAIL")

      assert has_element?(view, "#route-unavailable")
      assert has_element?(view, "#route-retry")
    end

    test "retry restores the workspace after unavailable", %{
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

      stub(CatalogReadAdapterMock, :load_route_editor, fn org, ver, route_id ->
        count = :atomics.add_get(call_count, 1, 1)

        if count <= 2 do
          {:error, :unavailable}
        else
          CatalogReadAdapter.Repo.load_route_editor(org, ver, route_id)
        end
      end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/RETRY1")

      assert has_element?(view, "#route-unavailable")

      view
      |> element("#route-retry")
      |> render_click()

      refute has_element?(view, "#route-unavailable")
      assert has_element?(view, "#route-details-form")
      assert has_element?(view, "input#route-details-short[value='R1']")
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

      assert has_element?(view, "#route-transfers-link", "Transfers here (2)")

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

      assert has_element?(view, "#route-transfers-link", "Transfers here (0)")

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

      stub(CatalogReadAdapterMock, :load_route_editor, fn org, ver, route_id ->
        # `live/2` runs `handle_params/3` once for the static render and once for
        # the connected one, as the retry case above records.
        if :atomics.add_get(call_count, 1, 1) <= 2 do
          {:error, :unavailable}
        else
          CatalogReadAdapter.Repo.load_route_editor(org, ver, route_id)
        end
      end)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/24")

      assert has_element?(view, "#route-unavailable")
      refute has_element?(view, "#route-transfers-link")

      view |> element("#route-retry") |> render_click()

      assert has_element?(view, "#route-transfers-link", "Transfers here (1)")
    end
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
