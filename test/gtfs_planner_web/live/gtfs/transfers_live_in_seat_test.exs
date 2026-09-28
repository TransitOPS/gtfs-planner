defmodule GtfsPlannerWeb.Gtfs.TransfersLiveInSeatTest do
  @moduledoc """
  Merge evidence (EV-19) for the view chips and the read-only in-seat view.

  The chips must switch the list between the version's general rules and its
  type 4/5 in-seat records, counting each view from the whole version before the
  switch. The in-seat view must then render those records read-only: no create
  control, no Needs attention checkbox, no row checkboxes, no inspector edit,
  delete, reverse, coverage, overlap or related-link element, a footer that says
  the records are retained in export, an empty state that sends the operator to
  Blocks, and a type filter limited to the view's own two types. A row without a
  stop must still render its endpoints, and the URL's `view`, `type`, `attention`
  and `rule` params must resolve inside the listed view, with a foreign or
  impossible value dropped rather than answered with an empty list.

  The cases assert literal copy, counts, row ids and patched URLs against the
  shared fixture network, and the in-seat view's clickable events are checked
  against a read-only allowlist, so a view that leaks a write control, lists the
  wrong rows, ignores the URL's view or crashes on a stopless row is rejected
  here. EV-19 does not prove the rendered pixels; the `in-seat:` journey in
  `assets/e2e/transfers.spec.js` (step 30) and the captures in
  `evidence/step-020/` cover those.

  The create button, the row checkboxes and the editor belong to steps 21, 22
  and 25; this file asserts their absence from the in-seat view only.
  """
  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.TransfersFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts

  # Every event the in-seat view may reach: the chips, the list's own reads and
  # the URL patches they make. A write event here would mean this view can reach
  # a mutation, which R1 forbids.
  @read_only_events ~w(switch_view sort select_rule toggle_filters clear_filters search filter paginate)

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

  describe "the view chips" do
    test "count both views of the version and mark the listed one pressed", ctx do
      %{general: general, in_seat: in_seat} = mixed_version!(ctx)

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version))
      document = doc(view)

      assert text_of(document, "#transfers-view-general") == "General rules (3)"
      assert text_of(document, "#transfers-view-in-seat") == "In-seat (2) · managed on Blocks"
      assert attribute(document, "#transfers-view-general", "aria-pressed") == "true"
      assert attribute(document, "#transfers-view-in-seat", "aria-pressed") == "false"

      # The counts are the version's, not the listed page's: the general view
      # still says how many in-seat records wait behind the other chip.
      assert text_of(document, "#transfers-count") == "3 rules"

      for rule <- general, do: assert(has_element?(view, "tr#transfers-#{rule.id}"))
      for record <- in_seat, do: refute(has_element?(view, "tr#transfers-#{record.id}"))
    end

    test "the chip is the way to a version whose only rows are in-seat records", ctx do
      record =
        in_seat!(ctx, %{
          from_route_id: "12",
          to_route_id: "24",
          from_trip_id: "12-0815",
          to_trip_id: "24-0840",
          transfer_type: 4
        })

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version))

      # No general rules: the general view keeps its first-use state, and the chip
      # still reaches the version's in-seat records.
      assert has_element?(view, "#transfers-first-use")
      assert text_of(doc(view), "#transfers-view-in-seat") == "In-seat (1) · managed on Blocks"
      refute has_element?(view, "tr#transfers-#{record.id}")

      view |> element("#transfers-view-in-seat") |> render_click()

      assert_patched(view, transfers_path(ctx.version, view: "in_seat"))
      refute has_element?(view, "#transfers-first-use")
      assert has_element?(view, "tr#transfers-#{record.id}")
      assert text_of(doc(view), "#transfers-count") == "1 in-seat record"
    end
  end

  describe "switching views" do
    test "drops the search, the filters and the selected rule", ctx do
      %{general: [bay_a | _rest], in_seat: [stay, alight]} = mixed_version!(ctx)

      {:ok, view, _html} =
        live(
          ctx.conn,
          transfers_path(ctx.version,
            q: "central",
            stop: "CEN",
            route: "12",
            type: "2",
            rule: bay_a.id
          )
        )

      # The URL named the selected rule, so the filters are canonical as loaded.
      assert has_element?(view, "#transfer-select-#{bay_a.id}[aria-current='true']")

      view |> element("#transfers-view-in-seat") |> render_click()

      assert_patched(view, transfers_path(ctx.version, view: "in_seat"))

      refute has_element?(view, "#transfer-select-#{bay_a.id}")
      refute has_element?(view, "#transfer-filter-attention")
      assert has_element?(view, "#transfer-search-form input[name='q'][value='']")

      # The view the chips switched to lists its own rows, unfiltered.
      assert text_of(doc(view), "#transfers-count") == "2 in-seat records"
      assert has_element?(view, "#transfer-select-#{stay.id}")
      assert has_element?(view, "#transfer-select-#{alight.id}")
    end

    test "Clear filters keeps the in-seat view and drops only its filters", ctx do
      %{in_seat: [stay, alight]} = mixed_version!(ctx)

      {:ok, view, _html} =
        live(ctx.conn, transfers_path(ctx.version, view: "in_seat", type: "5"))

      assert has_element?(view, "#transfer-select-#{alight.id}")
      refute has_element?(view, "#transfer-select-#{stay.id}")

      view |> element("#transfers-clear-filters") |> render_click()

      assert_patched(view, transfers_path(ctx.version, view: "in_seat"))
      assert text_of(doc(view), "#transfers-count") == "2 in-seat records"
      assert has_element?(view, "#transfer-select-#{stay.id}")
      refute has_element?(view, "#transfer-filter-attention")
    end

    test "drops the page the operator was on", ctx do
      many_rules(ctx, 51)

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version, page: "2"))
      document = doc(view)

      assert text_of(document, "#transfers-count") == "51 rules"
      assert Enum.count(row_ids(document)) == 1

      view |> element("#transfers-view-in-seat") |> render_click()

      assert_patched(view, transfers_path(ctx.version, view: "in_seat"))
      assert has_element?(view, "#transfers-in-seat-empty")
    end

    test "keeps the operator's sort", ctx do
      mixed_version!(ctx)

      {:ok, view, _html} =
        live(ctx.conn, transfers_path(ctx.version, sort_by: "min_time", sort_dir: "desc"))

      view |> element("#transfers-view-in-seat") |> render_click()

      assert_patched(
        view,
        transfers_path(ctx.version, view: "in_seat", sort_by: "min_time", sort_dir: "desc")
      )
    end

    test "an unknown value from a crafted chip event falls back to the general view", ctx do
      %{general: [bay_a | _rest]} = mixed_version!(ctx)

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version, view: "in_seat"))

      # The chips only ever send "general" or "in_seat"; anything else lists the
      # general rules, exactly as the URL parser resolves an unknown view.
      render_click(view, "switch_view", %{"view" => "elsewhere"})

      assert_patched(view, transfers_path(ctx.version))
      assert attribute(doc(view), "#transfers-view-general", "aria-pressed") == "true"
      assert has_element?(view, "#transfer-select-#{bay_a.id}")
    end

    test "switching back lists the general rules again", ctx do
      %{general: [bay_a | _rest]} = mixed_version!(ctx)

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version, view: "in_seat"))

      assert text_of(doc(view), "#transfers-count") == "2 in-seat records"

      view |> element("#transfers-view-general") |> render_click()

      assert_patched(view, transfers_path(ctx.version))
      assert has_element?(view, "#transfer-select-#{bay_a.id}")
      assert text_of(doc(view), "#transfers-count") == "3 rules"
    end
  end

  describe "the in-seat list" do
    test "lists only the version's in-seat records with the read-only count and footer", ctx do
      %{general: general, in_seat: [stay, alight]} = mixed_version!(ctx)

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version, view: "in_seat"))
      document = doc(view)

      assert text_of(document, "#transfers-count") == "2 in-seat records"
      assert has_element?(view, "tr#transfers-#{stay.id}")
      assert has_element?(view, "tr#transfers-#{alight.id}")
      for rule <- general, do: refute(has_element?(view, "tr#transfers-#{rule.id}"))

      assert has_element?(view, "tr#transfers-#{stay.id} td[data-label='Type']", "Stay on board")

      assert has_element?(
               view,
               "tr#transfers-#{alight.id} td[data-label='Type']",
               "Alight & reboard"
             )

      assert text_of(document, "#transfers-container + p") ==
               "Read-only here. All records are retained in export."

      # The page count names the same records the count bar does.
      assert render(view) =~ "of 2 in-seat records"
    end

    test "carries no attention badge, because in-seat rows need none", ctx do
      %{in_seat: [stay, alight]} = mixed_version!(ctx)

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version, view: "in_seat"))

      refute has_element?(view, "#transfer-attention-#{stay.id}")
      refute has_element?(view, "#transfer-attention-#{alight.id}")
    end

    test "renders a row without a stop from its trips without raising", ctx do
      stopless =
        in_seat!(ctx, %{
          from_trip_id: "24-0840",
          to_trip_id: "12-1010",
          transfer_type: 5
        })

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version, view: "in_seat"))
      document = doc(view)

      assert has_element?(view, "tr#transfers-#{stopless.id}")

      from_cell = text_of(document, "tr#transfers-#{stopless.id} td[data-label='From']")

      assert from_cell =~ "Stop not recorded"
      assert from_cell =~ "Trip 24-0840"

      to_cell = text_of(document, "tr#transfers-#{stopless.id} td[data-label='To']")

      assert to_cell =~ "Stop not recorded"
      assert to_cell =~ "Trip 12-1010"
    end

    test "offers only the in-seat types in its type filter", ctx do
      mixed_version!(ctx)

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version, view: "in_seat"))
      document = doc(view)

      options = LazyHTML.query(document, "#transfer-filter-type option")

      assert Enum.map(options, &LazyHTML.text(&1)) == [
               "All types",
               "Stay on board",
               "Alight & reboard"
             ]

      assert Enum.map(options, &LazyHTML.attribute(&1, "value")) == [
               [""],
               ["4"],
               ["5"]
             ]
    end

    test "keeps the view's own type filter and drops a general one", ctx do
      %{in_seat: [stay, alight]} = mixed_version!(ctx)

      # A general type is not a value in this view, so the mount canonicalizes it
      # away instead of listing nothing.
      assert {:error, {:live_redirect, %{to: redirected_to}}} =
               live(ctx.conn, transfers_path(ctx.version, view: "in_seat", type: "2"))

      assert redirected_to == transfers_path(ctx.version, view: "in_seat")

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version, view: "in_seat", type: "5"))

      document = doc(view)

      assert text_of(document, "#transfers-count") == "1 in-seat record"
      assert has_element?(view, "tr#transfers-#{alight.id}")
      refute has_element?(view, "tr#transfers-#{stay.id}")

      assert attribute(
               document,
               "#transfer-filter-type option[selected]",
               "value"
             ) == "5"
    end

    test "drops an attention flag and a general rule id from its URL", ctx do
      %{general: [bay_a | _general], in_seat: [stay | _in_seat]} = mixed_version!(ctx)

      assert {:error, {:live_redirect, %{to: redirected_to}}} =
               live(
                 ctx.conn,
                 transfers_path(ctx.version,
                   view: "in_seat",
                   attention: "1",
                   rule: bay_a.id
                 )
               )

      assert redirected_to == transfers_path(ctx.version, view: "in_seat")

      {:ok, view, _html} = live(ctx.conn, redirected_to)

      # The general rule is not in this view, so the first in-seat record is
      # selected instead.
      assert has_element?(view, "#transfer-select-#{stay.id}[aria-current='true']")
      refute has_element?(view, "#transfer-select-#{bay_a.id}")
    end

    test "an unknown view value falls back to the general list", ctx do
      %{general: [bay_a | _rest]} = mixed_version!(ctx)

      assert {:error, {:live_redirect, %{to: redirected_to}}} =
               live(ctx.conn, transfers_path(ctx.version, view: "elsewhere"))

      assert redirected_to == transfers_path(ctx.version)

      {:ok, view, _html} = live(ctx.conn, redirected_to)

      assert attribute(doc(view), "#transfers-view-general", "aria-pressed") == "true"
      assert has_element?(view, "#transfer-select-#{bay_a.id}")
    end

    test "shows where the records are managed when the version has none", ctx do
      rule!(ctx, %{
        from_stop_id: "CEN-A",
        to_stop_id: "CEN-C",
        transfer_type: 2,
        min_transfer_time: 180
      })

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version, view: "in_seat"))

      assert has_element?(view, "#transfers-in-seat-empty", "No in-seat records")

      assert has_element?(
               view,
               "#transfers-in-seat-empty",
               "Stay-on-board connections are managed on Blocks."
             )

      refute has_element?(view, "#transfers-first-use")
      refute has_element?(view, "#transfers-no-results")
      refute has_element?(view, "#transfers")
      refute has_element?(view, "#transfers-no-results-clear")
      assert has_element?(view, "#transfer-inspector-empty")
      assert text_of(doc(view), "#transfers-view-general") == "General rules (1)"
      assert text_of(doc(view), "#transfers-view-in-seat") == "In-seat (0) · managed on Blocks"
    end
  end

  describe "the read-only contract" do
    test "renders no create, mutation or inspector control", ctx do
      mixed_version!(ctx)

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version, view: "in_seat"))

      refute has_element?(view, "#transfers-create")
      refute has_element?(view, "#transfer-filter-attention")
      refute has_element?(view, "[id^=transfer-check-]")
      refute has_element?(view, "#transfers-select-all")
      refute has_element?(view, "#transfers-delete-selected")
      refute has_element?(view, "#transfer-inspector-edit")
      refute has_element?(view, "#transfer-inspector-delete")
      refute has_element?(view, "#transfer-inspector-reverse-create")
      refute has_element?(view, "#transfer-inspector-reverse-inspect")
      refute has_element?(view, "#transfer-inspector-coverage")
      refute has_element?(view, "#transfer-inspector-overlap")
      refute has_element?(view, "#transfer-inspector-compare")
      refute has_element?(view, "#transfer-inspector-attention")
      refute has_element?(view, "#transfer-inspector-stop-link")
      refute has_element?(view, "#transfer-inspector-route-link-from")
      refute has_element?(view, "#transfer-inspector-route-link-to")
      refute has_element?(view, "#transfer-delete-dialog")
    end

    test "reaches no event beyond the list's own reads and patches", ctx do
      mixed_version!(ctx)

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version, view: "in_seat"))

      clicks = clicked_events(view)

      assert "switch_view" in clicks
      assert clicks -- @read_only_events == [], "the in-seat view reached #{inspect(clicks)}"
    end
  end

  describe "the in-seat inspector" do
    test "names the record, its trips, the rider meaning and the Blocks handoff", ctx do
      mixed_version!(ctx)

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version, view: "in_seat"))
      document = doc(view)

      assert text_of(document, "#transfer-inspector > p") == "In-seat record"
      assert text_of(document, "#transfer-inspector > h2") == "Stay on board"

      inspector = text_of(document, "#transfer-inspector")

      assert inspector =~ "Arrive at"
      assert inspector =~ "Trip 12-0815"
      assert inspector =~ "Board at"
      assert inspector =~ "Trip 24-0840"

      assert inspector =~
               "Riders may stay on the vehicle as it continues on the next trip."

      assert has_element?(
               view,
               "#transfer-inspector-blocks-note",
               "Managed on Blocks. Changes to stay-on-board records are made there."
             )

      assert has_element?(view, "#transfer-inspector-details", "Rule scope & GTFS details")
    end

    test "shows the alight-and-reboard record's own meaning when it is selected", ctx do
      %{in_seat: [stay, alight]} = mixed_version!(ctx)

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version, view: "in_seat"))

      assert has_element?(view, "#transfer-select-#{stay.id}[aria-current='true']")

      view |> element("#transfer-select-#{alight.id}") |> render_click()

      assert_patched(view, transfers_path(ctx.version, view: "in_seat", rule: alight.id))
      assert text_of(doc(view), "#transfer-inspector > h2") == "Alight & reboard"

      assert text_of(doc(view), "#transfer-inspector") =~
               "Riders must get off and board again for the next trip."

      refute has_element?(view, "#transfer-inspector-edit")
    end

    test "renders a stopless record's inspector from its trips without raising", ctx do
      stopless =
        in_seat!(ctx, %{
          from_route_id: "12",
          to_route_id: "24",
          from_trip_id: "24-0840",
          to_trip_id: "12-1010",
          transfer_type: 5
        })

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version, view: "in_seat"))

      view |> element("#transfer-select-#{stopless.id}") |> render_click()

      document = doc(view)

      assert text_of(document, "#transfer-inspector > p") == "In-seat record"

      inspector = text_of(document, "#transfer-inspector")

      assert inspector =~ "Stop not recorded"
      assert inspector =~ "Trip 24-0840"

      refute has_element?(view, "#transfer-inspector-coverage")
      refute has_element?(view, "#transfer-inspector-route-link-from")
    end
  end

  # Three general rules and two in-seat records: the two counts the chips show,
  # and one in-seat row with a stop beside one without one.
  defp mixed_version!(ctx) do
    general = [
      rule!(ctx, %{
        from_stop_id: "CEN-A",
        to_stop_id: "CEN-C",
        from_route_id: "12",
        to_route_id: "24",
        transfer_type: 2,
        min_transfer_time: 180
      }),
      rule!(ctx, %{from_stop_id: "MKT", to_stop_id: "HBR", transfer_type: 0}),
      rule!(ctx, %{from_stop_id: "MUS", to_stop_id: "HBR", transfer_type: 3})
    ]

    in_seat = [
      in_seat!(ctx, %{
        from_stop_id: "CEN",
        to_stop_id: "CEN",
        from_trip_id: "12-0815",
        to_trip_id: "24-0840",
        transfer_type: 4
      }),
      in_seat!(ctx, %{
        from_stop_id: "MKT",
        to_stop_id: "MKT",
        from_trip_id: "12-1010",
        to_trip_id: "24-0920",
        transfer_type: 5
      })
    ]

    %{general: general, in_seat: in_seat}
  end

  # 51 general rules need 51 distinct keys, because the six-field key is unique
  # per version; the fixture network's eight stops supply more ordered pairs than
  # the two pages need.
  defp many_rules(ctx, count) do
    stops = ~w(CEN-A CEN-C CEN-E CEN MKT HBR MUS NOC)
    pairs = for from <- stops, to <- stops, from != to, do: {from, to}

    pairs
    |> Enum.take(count)
    |> Enum.map(fn {from, to} ->
      rule!(ctx, %{from_stop_id: from, to_stop_id: to, transfer_type: 0})
    end)
  end

  defp row_ids(document) do
    document
    |> LazyHTML.query("tbody#transfers tr")
    |> Enum.map(fn row -> row |> LazyHTML.attribute("id") |> List.first() end)
  end

  defp clicked_events(view) do
    view
    |> doc()
    |> LazyHTML.query("#transfers-page [phx-click]")
    |> Enum.flat_map(&LazyHTML.attribute(&1, "phx-click"))
    |> Enum.uniq()
  end

  defp transfers_path(version, params \\ []) do
    query = if params == [], do: "", else: "?" <> URI.encode_query(params)
    "/gtfs/#{version.id}/transfers#{query}"
  end

  defp rule!(ctx, attrs), do: transfer_fixture(ctx.organization.id, ctx.version.id, attrs)

  defp in_seat!(ctx, attrs), do: rule!(ctx, Map.put_new(attrs, :transfer_type, 4))

  defp doc(view), do: LazyHTML.from_fragment(render(view))

  defp text_of(document, selector) do
    document |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()
  end

  defp attribute(document, selector, name) do
    document |> LazyHTML.query(selector) |> LazyHTML.attribute(name) |> List.first()
  end
end
