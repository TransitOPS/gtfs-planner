defmodule GtfsPlannerWeb.Gtfs.TransfersLiveListTest do
  @moduledoc """
  Merge evidence (EV-16) for the general rules list pane.

  The list must render exactly the current view's general rules with the four
  agreed columns, name each endpoint with the scope its rule applies to, mark a
  rule that needs attention with text as well as color, keep its count and
  direction hint, sort, page and select the way the URL says, and canonicalize the
  params it cannot honor.

  The cases assert literal rows, copy and patched URLs against the shared fixture
  network, so a list that leaks in-seat rows or another version's rows, drops a
  dangling reference instead of naming it, renders attention without text, sorts
  or pages differently from the URL, or leaves a non-canonical param in the URL
  is rejected here. EV-16 does not prove the browser's behavior; the `list:`
  journey in `assets/e2e/transfers.spec.js` (EV-29, step 30) and the visual
  captures in `evidence/step-017/` cover the rendered pixels.
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

  describe "the general rules list" do
    test "the four columns name each rule's endpoints, scope, type and minimum time", ctx do
      scoped =
        rule!(ctx, %{
          from_stop_id: "CEN-A",
          to_stop_id: "CEN-C",
          from_route_id: "12",
          to_route_id: "24",
          transfer_type: 2,
          min_transfer_time: 180
        })

      half_minute =
        rule!(ctx, %{
          from_stop_id: "MKT",
          to_stop_id: "HBR",
          transfer_type: 2,
          min_transfer_time: 150
        })

      recommended = rule!(ctx, %{from_stop_id: "MUS", to_stop_id: "HBR", transfer_type: 0})
      timed = rule!(ctx, %{from_stop_id: "MKT", to_stop_id: "MUS", transfer_type: 1})
      impossible = rule!(ctx, %{from_stop_id: "HBR", to_stop_id: "MUS", transfer_type: 3})

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version))
      document = doc(view)

      from_cell = text_of(document, "tr#transfers-#{scoped.id} td[data-label='Arrive at']")

      assert from_cell =~ "Central · Bay A"
      assert from_cell =~ "Route 12"

      to_cell = text_of(document, "tr#transfers-#{scoped.id} td[data-label='Board at']")

      assert to_cell =~ "Central · Bay C"
      assert to_cell =~ "Route 24"

      assert text_of(document, "tr#transfers-#{scoped.id} td[data-label='Rule']") ==
               "Minimum time"

      assert text_of(document, "tr#transfers-#{scoped.id} td[data-label='Time']") == "3 min"

      assert text_of(document, "tr#transfers-#{half_minute.id} td[data-label='Time']") ==
               "2 min 30 sec"

      assert text_of(document, "tr#transfers-#{recommended.id} td[data-label='Rule']") ==
               "Preferred point"

      assert text_of(document, "tr#transfers-#{timed.id} td[data-label='Rule']") ==
               "Timed transfer"

      assert text_of(document, "tr#transfers-#{impossible.id} td[data-label='Rule']") ==
               "Not possible"

      for row <- [recommended, timed, impossible] do
        assert text_of(document, "tr#transfers-#{row.id} td[data-label='Time']") == "—"
      end
    end

    test "the scope subtext names the selector each side carries", ctx do
      station = rule!(ctx, %{from_stop_id: "CEN", to_stop_id: "CEN", transfer_type: 0})

      trips =
        rule!(ctx, %{
          from_stop_id: "CEN-A",
          to_stop_id: "CEN-C",
          from_trip_id: "12-0815",
          to_trip_id: "24-0840",
          transfer_type: 2,
          min_transfer_time: 180
        })

      dangling = rule!(ctx, %{from_stop_id: "GHOST", to_stop_id: "HBR", transfer_type: 0})

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version))
      document = doc(view)

      station_from = text_of(document, "tr#transfers-#{station.id} td[data-label='Arrive at']")

      assert station_from =~ "Central Station"
      assert station_from =~ "Any route · whole station"

      assert text_of(document, "tr#transfers-#{station.id} td[data-label='Board at']") =~
               "Any route · whole station"

      assert text_of(document, "tr#transfers-#{trips.id} td[data-label='Arrive at']") =~
               "Trip 12-0815"

      assert text_of(document, "tr#transfers-#{trips.id} td[data-label='Board at']") =~
               "Trip 24-0840"

      dangling_from = text_of(document, "tr#transfers-#{dangling.id} td[data-label='Arrive at']")

      assert dangling_from =~ "GHOST"
      assert dangling_from =~ "Any arriving route"
    end

    test "a competing rule carries a text badge and a clean rule carries none", ctx do
      competing =
        rule!(ctx, %{
          from_stop_id: "CEN",
          to_stop_id: "CEN",
          from_route_id: "12",
          transfer_type: 2,
          min_transfer_time: 120
        })

      equal =
        rule!(ctx, %{
          from_stop_id: "CEN",
          to_stop_id: "CEN",
          to_route_id: "24",
          transfer_type: 3
        })

      clean = rule!(ctx, %{from_stop_id: "MKT", to_stop_id: "HBR", transfer_type: 1})

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version))

      assert has_element?(view, "#transfer-attention-#{competing.id}", "Needs attention")
      assert has_element?(view, "#transfer-attention-#{equal.id}", "Needs attention")
      refute has_element?(view, "#transfer-attention-#{clean.id}")
    end

    test "only the general rules of this version are listed", ctx do
      general = rule!(ctx, %{from_stop_id: "CEN-A", to_stop_id: "CEN-C", transfer_type: 0})

      rule!(ctx, %{
        from_stop_id: "CEN-A",
        to_stop_id: "CEN-C",
        from_trip_id: "12-0815",
        to_trip_id: "24-0840",
        transfer_type: 4
      })

      rule!(ctx, %{from_trip_id: "12-0815", to_trip_id: "24-0840", transfer_type: 5})

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version))

      assert row_ids(doc(view)) == ["transfers-#{general.id}"]
      refute has_element?(view, "#transfers-first-use")
    end

    test "the count row names the list and the footer says what a selection drives", ctx do
      rule!(ctx, %{from_stop_id: "CEN-A", to_stop_id: "CEN-C", transfer_type: 0})
      rule!(ctx, %{from_stop_id: "MKT", to_stop_id: "HBR", transfer_type: 1})
      rule!(ctx, %{from_stop_id: "MUS", to_stop_id: "HBR", transfer_type: 3})

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version))
      document = doc(view)

      assert text_of(document, "#transfers-count") == "3 transfer rules"

      assert has_element?(
               view,
               "section[aria-label='Transfer rules'] p",
               "Select a rule to see it on the map and what it means for riders."
             )
    end
  end

  describe "sorting" do
    test "the From header patches a descending sort and reverses the order", ctx do
      bay_a = rule!(ctx, %{from_stop_id: "CEN-A", to_stop_id: "HBR", transfer_type: 0})
      market = rule!(ctx, %{from_stop_id: "MKT", to_stop_id: "HBR", transfer_type: 1})
      museum = rule!(ctx, %{from_stop_id: "MUS", to_stop_id: "HBR", transfer_type: 3})

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version))

      html = render(view)
      assert position(html, bay_a.id) < position(html, market.id)
      assert position(html, market.id) < position(html, museum.id)

      view
      |> element("button[phx-click='sort'][phx-value-key='from']")
      |> render_click()

      assert_patched(view, ~p"/gtfs/#{ctx.version.id}/transfers?sort_by=from&sort_dir=desc")

      html = render(view)
      assert position(html, museum.id) < position(html, market.id)
      assert position(html, market.id) < position(html, bay_a.id)
    end

    test "the Min time header sorts ascending with the rows without a time first", ctx do
      timed =
        rule!(ctx, %{
          from_stop_id: "MKT",
          to_stop_id: "HBR",
          transfer_type: 2,
          min_transfer_time: 180
        })

      untimed = rule!(ctx, %{from_stop_id: "MUS", to_stop_id: "HBR", transfer_type: 1})

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version))

      view
      |> element("button[phx-click='sort'][phx-value-key='min_time']")
      |> render_click()

      assert_patched(view, ~p"/gtfs/#{ctx.version.id}/transfers?sort_by=min_time&sort_dir=asc")

      html = render(view)
      assert position(html, untimed.id) < position(html, timed.id)

      assert text_of(doc(view), "tr#transfers-#{untimed.id} td[data-label='Time']") == "—"

      assert text_of(doc(view), "tr#transfers-#{timed.id} td[data-label='Time']") == "3 min"
    end
  end

  describe "pagination and canonical params" do
    test "51 rules page 50 then 1, and a page past the end clamps", ctx do
      rules = many_rules(ctx, 51)

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version))

      assert Enum.count(row_ids(doc(view))) == 50

      view
      |> element("button[phx-click='paginate'][phx-value-page='2']")
      |> render_click()

      assert_patched(view, ~p"/gtfs/#{ctx.version.id}/transfers?page=2")

      assert ["transfers-" <> second_page_id] = row_ids(doc(view))
      assert second_page_id in Enum.map(rules, & &1.id)

      # A rule on the second page opens that page with the rule selected.
      assert {:error, {:live_redirect, %{to: redirected_to}}} =
               live(ctx.conn, transfers_path(ctx.version) <> "?rule=#{second_page_id}")

      assert redirected_to ==
               ~p"/gtfs/#{ctx.version.id}/transfers?page=2&rule=#{second_page_id}"

      {:ok, selected, _html} = live(ctx.conn, redirected_to)

      assert has_element?(selected, "#transfer-select-#{second_page_id}[aria-current='true']")
      assert Enum.count(row_ids(doc(selected))) == 1

      assert {:error, {:live_redirect, %{to: clamped}}} =
               live(ctx.conn, transfers_path(ctx.version) <> "?page=9")

      assert clamped == ~p"/gtfs/#{ctx.version.id}/transfers?page=2"
    end

    test "an invalid rule and an unknown sort are dropped without error", ctx do
      rule!(ctx, %{from_stop_id: "CEN-A", to_stop_id: "HBR", transfer_type: 0})

      assert {:error, {:live_redirect, %{to: redirected_to}}} =
               live(ctx.conn, transfers_path(ctx.version) <> "?rule=not-a-uuid&sort_by=evil")

      assert redirected_to == transfers_path(ctx.version)

      {:ok, view, _html} = live(ctx.conn, redirected_to)

      assert has_element?(view, "#transfers")
      refute has_element?(view, "#transfers-unavailable")
    end

    test "selecting a row patches the rule parameter and moves the highlight", ctx do
      bay_a = rule!(ctx, %{from_stop_id: "CEN-A", to_stop_id: "HBR", transfer_type: 0})
      market = rule!(ctx, %{from_stop_id: "MKT", to_stop_id: "HBR", transfer_type: 1})

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version))

      # The page's first row is selected until a rule is named.
      assert has_element?(view, "#transfer-select-#{bay_a.id}[aria-current='true']")
      refute has_element?(view, "#transfer-select-#{market.id}[aria-current='true']")

      view |> element("#transfer-select-#{market.id}") |> render_click()

      assert_patched(view, ~p"/gtfs/#{ctx.version.id}/transfers?rule=#{market.id}")

      assert has_element?(view, "#transfer-select-#{market.id}[aria-current='true']")
      refute has_element?(view, "#transfer-select-#{bay_a.id}[aria-current='true']")
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

  defp position(html, needle) do
    case :binary.match(html, needle) do
      {position, _length} -> position
      :nomatch -> flunk("expected #{needle} in the rendered rows")
    end
  end
end
