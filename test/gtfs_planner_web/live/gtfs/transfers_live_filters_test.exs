defmodule GtfsPlannerWeb.Gtfs.TransfersLiveFiltersTest do
  @moduledoc """
  Merge evidence (EV-17) for the list pane's search and filters.

  The toolbar must search the way the catalog searches, filter by a station and
  its children, by a stored route or a stored trip's route and by type, count the
  three selects, combine every control with AND, keep the applied values in the
  form, round-trip through the URL, drop a value the current view cannot honor,
  and show the filtered-empty state instead of first use when the query hides
  every rule.

  The cases assert literal URLs, form values and row ids against the shared
  fixture network, so a filter that does not survive the URL, misses a station's
  children, ignores a selected trip's route, applies a value meant for another
  view, confuses the filtered-empty state with first use, or loses the search
  term after the patch is rejected here. EV-17 does not prove the browser's
  behavior; the `list:` journey in `assets/e2e/transfers.spec.js` (EV-29, step 30)
  and the captures in `evidence/step-018/` cover the rendered pixels.
  """
  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.TransfersFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts

  setup %{conn: conn} do
    organization = organization_fixture()
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)
    transfer_network_fixture(organization.id, version.id)

    %{
      conn: log_in_user(conn, user, organization: organization),
      organization: organization,
      version: version
    }
  end

  describe "the toolbar" do
    test "the disclosure starts closed and the toggle reveals the filter fields", ctx do
      rule!(ctx, %{
        from_stop_id: "CEN-A",
        to_stop_id: "HBR",
        from_route_id: "12",
        transfer_type: 0
      })

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version))

      assert has_element?(
               view,
               "#transfers-filters-toggle[aria-expanded='false'][aria-controls='transfer-filter-fields']"
             )

      assert has_element?(view, "#transfer-filter-fields[hidden]")
      assert text_of(doc(view), "#transfers-filters-toggle") == "Filters"

      view |> element("#transfers-filters-toggle") |> render_click()

      assert has_element?(view, "#transfers-filters-toggle[aria-expanded='true']")
      refute has_element?(view, "#transfer-filter-fields[hidden]")

      # The three selects name themselves and their unfiltered choice, and the
      # options come from the listed rows' own stops, routes and types.
      assert has_element?(view, "#transfer-filter-stop option[value='']", "All locations")
      assert has_element?(view, "#transfer-filter-route option[value='']", "All routes")
      assert has_element?(view, "#transfer-filter-type option[value='']", "All types")
      assert has_element?(view, "#transfer-filter-stop option", "Central Station")
      assert has_element?(view, "#transfer-filter-route option", "12 · Riverside")
      assert has_element?(view, "#transfer-filter-type option", "Recommended")
      assert has_element?(view, "#transfer-filter-attention")
      assert has_element?(view, "#transfers-clear-filters", "Clear filters")
    end

    test "typing in the search field narrows the list and keeps the term", ctx do
      museum = rule!(ctx, %{from_stop_id: "MUS", to_stop_id: "HBR", transfer_type: 0})
      rule!(ctx, %{from_stop_id: "MKT", to_stop_id: "HBR", transfer_type: 1})

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version))

      view |> form("#transfer-search-form", %{"q" => "museum"}) |> render_change()

      assert_patched(view, ~p"/gtfs/#{ctx.version.id}/transfers?q=museum")

      assert row_ids(doc(view)) == ["transfers-#{museum.id}"]
      assert has_element?(view, "#transfer-search-form input[name='q'][value='museum']")
    end

    test "the checkbox's own form payload applies the filter", ctx do
      flagged =
        rule!(ctx, %{
          from_stop_id: "CEN-A",
          to_stop_id: "HBR",
          from_route_id: "GONE",
          transfer_type: 2,
          min_transfer_time: 180
        })

      rule!(ctx, %{from_stop_id: "MKT", to_stop_id: "HBR", transfer_type: 0})

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version))

      # `<.input type="checkbox">` renders a hidden "false" beside the checked
      # "true" under the one name, so this is the payload the browser sends.
      view
      |> render_change("filter", %{
        "stop" => "",
        "route" => "",
        "type" => "",
        "attention" => ["false", "true"]
      })

      assert_patched(view, ~p"/gtfs/#{ctx.version.id}/transfers?attention=1")
      assert row_ids(doc(view)) == ["transfers-#{flagged.id}"]

      # The checkbox is not one of the three counted selects.
      assert text_of(doc(view), "#transfers-filters-toggle") == "Filters"
    end

    test "the stop select lists a station with its children and counts the filter", ctx do
      station = rule!(ctx, %{from_stop_id: "CEN", to_stop_id: "HBR", transfer_type: 0})
      bay_a = rule!(ctx, %{from_stop_id: "CEN-A", to_stop_id: "HBR", transfer_type: 1})
      bay_c = rule!(ctx, %{from_stop_id: "CEN-C", to_stop_id: "HBR", transfer_type: 3})
      market = rule!(ctx, %{from_stop_id: "MKT", to_stop_id: "HBR", transfer_type: 0})

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version))

      view |> element("#transfers-filters-toggle") |> render_click()

      view
      |> form("#transfer-filter-form", %{
        "stop" => "CEN",
        "route" => "",
        "type" => "",
        "attention" => "false"
      })
      |> render_change()

      assert_patched(view, ~p"/gtfs/#{ctx.version.id}/transfers?stop=CEN")

      expected =
        Enum.sort([
          "transfers-#{station.id}",
          "transfers-#{bay_a.id}",
          "transfers-#{bay_c.id}"
        ])

      assert Enum.sort(row_ids(doc(view))) == expected
      refute has_element?(view, "#transfers-#{market.id}")
      assert has_element?(view, "#transfer-filter-stop option[value='CEN'][selected]")
      assert text_of(doc(view), "#transfers-filters-toggle") == "Filters (1)"
    end

    test "the route select matches a stored route and a stored trip's route", ctx do
      stored =
        rule!(ctx, %{
          from_stop_id: "MKT",
          to_stop_id: "HBR",
          from_route_id: "24",
          transfer_type: 0
        })

      by_trip =
        rule!(ctx, %{
          from_stop_id: "CEN-A",
          to_stop_id: "MUS",
          from_trip_id: "24-0840",
          transfer_type: 1
        })

      other =
        rule!(ctx, %{
          from_stop_id: "MKT",
          to_stop_id: "MUS",
          from_trip_id: "12-0815",
          transfer_type: 0
        })

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version))

      view |> form("#transfer-filter-form", %{"route" => "24"}) |> render_change()

      assert_patched(view, ~p"/gtfs/#{ctx.version.id}/transfers?route=24")

      expected = Enum.sort(["transfers-#{stored.id}", "transfers-#{by_trip.id}"])

      assert Enum.sort(row_ids(doc(view))) == expected
      refute has_element?(view, "#transfers-#{other.id}")
      assert has_element?(view, "#transfer-filter-route option[value='24'][selected]")
      assert text_of(doc(view), "#transfers-filters-toggle") == "Filters (1)"
    end

    test "the type select lists only that type", ctx do
      impossible = rule!(ctx, %{from_stop_id: "MKT", to_stop_id: "HBR", transfer_type: 3})
      rule!(ctx, %{from_stop_id: "MUS", to_stop_id: "HBR", transfer_type: 0})

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version))

      view |> form("#transfer-filter-form", %{"type" => "3"}) |> render_change()

      assert_patched(view, ~p"/gtfs/#{ctx.version.id}/transfers?type=3")

      assert row_ids(doc(view)) == ["transfers-#{impossible.id}"]
      assert has_element?(view, "#transfer-filter-type option[value='3'][selected]")
      assert text_of(doc(view), "#transfers-filters-toggle") == "Filters (1)"
    end
  end

  describe "combining filters" do
    test "stop, route, type and Needs attention combine with AND and round-trip", ctx do
      # One rule per way the AND can fail: the matching rule sits under Central
      # Station, names route 24 on its to side, is type 2 and needs attention for a
      # stored route the version does not have. Each neighbour fails exactly one
      # conjunct, and the six-field key stays unique because no two share all six
      # selector columns.
      matching =
        rule!(ctx, %{
          from_stop_id: "CEN-A",
          to_stop_id: "HBR",
          from_route_id: "GONE",
          to_route_id: "24",
          transfer_type: 2,
          min_transfer_time: 180
        })

      # Type 3 at another platform of the same station.
      rule!(ctx, %{
        from_stop_id: "CEN-C",
        to_stop_id: "HBR",
        from_route_id: "GONE",
        to_route_id: "24",
        transfer_type: 3
      })

      # Outside the station's coverage.
      rule!(ctx, %{
        from_stop_id: "MKT",
        to_stop_id: "HBR",
        from_route_id: "GONE",
        to_route_id: "24",
        transfer_type: 2,
        min_transfer_time: 180
      })

      # Another route on both sides.
      rule!(ctx, %{
        from_stop_id: "CEN-C",
        to_stop_id: "HBR",
        from_route_id: "GONE",
        to_route_id: "12",
        transfer_type: 2,
        min_transfer_time: 180
      })

      # Nothing to attend to: both routes exist and no other rule'd effect applies
      # to the same trip pairs.
      rule!(ctx, %{
        from_stop_id: "CEN-A",
        to_stop_id: "HBR",
        from_route_id: "12",
        to_route_id: "24",
        transfer_type: 2,
        min_transfer_time: 180
      })

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version))

      view
      |> form("#transfer-filter-form", %{
        "stop" => "CEN",
        "route" => "24",
        "type" => "2",
        "attention" => "true"
      })
      |> render_change()

      # The page's own patch carries the params in the order
      # `sort_verified_routes_query_params` gives them in the test env, so this
      # expectation is written in that canonical order.
      assert_patched(
        view,
        ~p"/gtfs/#{ctx.version.id}/transfers?attention=1&route=24&stop=CEN&type=2"
      )

      assert row_ids(doc(view)) == ["transfers-#{matching.id}"]
      assert text_of(doc(view), "#transfers-filters-toggle") == "Filters (3)"

      # The same URL renders the same rows and the same form values, so the list
      # and the URL cannot disagree about the filter.
      url = ~p"/gtfs/#{ctx.version.id}/transfers?attention=1&route=24&stop=CEN&type=2"
      {:ok, same, _html} = live(ctx.conn, url)

      assert row_ids(doc(same)) == ["transfers-#{matching.id}"]
      assert has_element?(same, "#transfer-filter-stop option[value='CEN'][selected]")
      assert has_element?(same, "#transfer-filter-route option[value='24'][selected]")
      assert has_element?(same, "#transfer-filter-type option[value='2'][selected]")
      assert has_element?(same, "#transfer-filter-attention[checked]")

      # The search is the other form's, and narrows without dropping a filter.
      same |> form("#transfer-search-form", %{"q" => "harbor"}) |> render_change()

      assert_patched(
        same,
        ~p"/gtfs/#{ctx.version.id}/transfers?attention=1&q=harbor&route=24&stop=CEN&type=2"
      )

      assert row_ids(doc(same)) == ["transfers-#{matching.id}"]
    end
  end

  describe "filter params and the filtered-empty state" do
    test "a search or filter change drops the selected rule and the page", ctx do
      many_rules(ctx, 51)

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version))

      view
      |> element("button[phx-click='paginate'][phx-value-page='2']")
      |> render_click()

      assert_patched(view, ~p"/gtfs/#{ctx.version.id}/transfers?page=2")
      assert ["transfers-" <> second_page_id] = row_ids(doc(view))

      url = ~p"/gtfs/#{ctx.version.id}/transfers?page=2&rule=#{second_page_id}"
      {:ok, selected, _html} = live(ctx.conn, url)

      assert has_element?(selected, "#transfer-select-#{second_page_id}[aria-current='true']")

      selected |> form("#transfer-search-form", %{"q" => "central"}) |> render_change()

      assert_patched(selected, ~p"/gtfs/#{ctx.version.id}/transfers?q=central")

      {:ok, filtered, _html} = live(ctx.conn, url)

      filtered |> form("#transfer-filter-form", %{"type" => "0"}) |> render_change()

      assert_patched(filtered, ~p"/gtfs/#{ctx.version.id}/transfers?type=0")
    end

    test "a type for another view and an unknown attention value are dropped", ctx do
      rule!(ctx, %{from_stop_id: "CEN-A", to_stop_id: "HBR", transfer_type: 0})

      assert {:error, {:live_redirect, %{to: redirected_to}}} =
               live(ctx.conn, transfers_path(ctx.version) <> "?type=4&attention=yes")

      assert redirected_to == transfers_path(ctx.version)

      {:ok, view, _html} = live(ctx.conn, redirected_to)

      refute has_element?(view, "#transfer-filter-type option[value='4']")
      refute has_element?(view, "#transfer-filter-attention[checked]")
      # A nil filter value leaves `options_for_select/2` with nothing to mark, so
      # the empty option carries no `selected` attribute; it is still the select's
      # value because it comes first.
      assert has_element?(view, "#transfer-filter-type option[value='']", "All types")
      assert text_of(doc(view), "#transfers-filters-toggle") == "Filters"
    end

    test "an unknown stop keeps its option selected and empties the list", ctx do
      rule!(ctx, %{from_stop_id: "CEN-A", to_stop_id: "HBR", transfer_type: 0})

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version) <> "?stop=UNKNOWN")

      assert has_element?(view, "#transfer-filter-stop option[value='UNKNOWN'][selected]")
      assert text_of(doc(view), "#transfer-filter-stop option[value='UNKNOWN']") == "UNKNOWN"
      assert has_element?(view, "#transfers-no-results", "No matching connections")
      assert text_of(doc(view), "#transfers-filters-toggle") == "Filters (1)"
    end

    test "a filter that hides every rule shows the filtered-empty state, not first use", ctx do
      rule!(ctx, %{from_stop_id: "CEN-A", to_stop_id: "HBR", transfer_type: 0})
      rule!(ctx, %{from_stop_id: "MKT", to_stop_id: "HBR", transfer_type: 1})

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version) <> "?q=zzz")

      assert has_element?(view, "#transfers-no-results", "No matching connections")

      assert text_of(doc(view), "#transfers-no-results") =~
               "Try another stop, route, or search term."

      # The count bar stays above the state, as the reference has it, so an
      # emptied list still reads how many rules matched.
      assert text_of(doc(view), "#transfers-count") == "0 rules"
      assert text_of(doc(view), "#transfers-direction-hint") == "One direction per rule"

      refute has_element?(view, "#transfers-first-use")
      refute has_element?(view, "#transfers")

      view |> element("#transfers-no-results-clear") |> render_click()

      assert_patched(view, transfers_path(ctx.version))
      assert has_element?(view, "#transfers")
      refute has_element?(view, "#transfers-no-results")
    end

    test "the toolbar's Clear filters patches the bare list from a filtered URL", ctx do
      rule!(ctx, %{from_stop_id: "CEN-A", to_stop_id: "HBR", transfer_type: 0})

      {:ok, view, _html} =
        live(ctx.conn, transfers_path(ctx.version) <> "?q=zzz&attention=1")

      assert has_element?(view, "#transfers-no-results")

      view |> element("#transfers-clear-filters") |> render_click()

      assert_patched(view, transfers_path(ctx.version))
      assert has_element?(view, "#transfers")
      assert has_element?(view, "#transfer-search-form input[name='q'][value='']")
      refute has_element?(view, "#transfer-filter-attention[checked]")
    end
  end

  defp transfers_path(version), do: "/gtfs/#{version.id}/transfers"

  defp rule!(ctx, attrs), do: transfer_fixture(ctx.organization.id, ctx.version.id, attrs)

  # 51 rules need 51 distinct keys, because the six-field key is unique per
  # version; the fixture network's eight stops supply more ordered pairs than the
  # two pages need.
  defp many_rules(ctx, count) do
    stops = ~w(CEN-A CEN-C CEN-E CEN MKT HBR MUS NOC)

    pairs = for from <- stops, to <- stops, from != to, do: {from, to}

    pairs
    |> Enum.take(count)
    |> Enum.map(fn {from, to} ->
      rule!(ctx, %{from_stop_id: from, to_stop_id: to, transfer_type: 0})
    end)
  end

  defp doc(view), do: LazyHTML.from_fragment(render(view))

  defp text_of(document, selector) do
    document |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()
  end

  defp row_ids(document) do
    document
    |> LazyHTML.query("tbody#transfers tr")
    |> Enum.map(fn row -> row |> LazyHTML.attribute("id") |> List.first() end)
  end
end
