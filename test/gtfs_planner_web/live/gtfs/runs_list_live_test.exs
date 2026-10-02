defmodule GtfsPlannerWeb.Gtfs.RunsListLiveTest do
  @moduledoc """
  The Runs List view.

  The list's values must equal the timeline's, and that is the whole shape of
  these tests. Seven of the eight columns are the same numbers the chart shows,
  and the risk is not that they are wrong but that the two views drift apart: a
  second implementation of the same seven cells would be free to print a bare time
  on one view and a GTFS-hours clock on the other, and a test that checked each
  against its own expected value would pass both.

  So the central assertion here is a cell-by-cell comparison between the two views
  on the same data, not a comparison against a second copy of the arithmetic.
  Everything the list adds — the Pieces column, the sort, the switching — is
  asserted around that.
  """
  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.RunsFixtures

  alias GtfsPlanner.Accounts

  @moduletag :ev_24
  @moduletag timeout: 120_000

  # Only the user is built here. `runs_version_fixture/1` creates its own
  # organization, so the membership goes on that one, not on a separate
  # organization fixture.
  setup do
    %{user: user_fixture()}
  end

  # One run over both blocks and one over the second block's last trip: one row
  # carries two pieces, the other one, and the two have different spreads, so a
  # sort has something to reorder.
  defp world(%{user: user}) do
    w = runs_version_fixture()
    [first, second] = w.blocks["102"]

    for trip <- w.blocks["101"] ++ [first] do
      trip_run_fixture(w.organization.id, w.version.id, %{
        trip: trip,
        day_type_key: w.day_type_key,
        run_id: "1001"
      })
    end

    trip_run_fixture(w.organization.id, w.version.id, %{
      trip: second,
      day_type_key: w.day_type_key,
      run_id: "1002"
    })

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: w.organization.id,
      roles: ["pathways_studio_editor"]
    })

    w
  end

  defp open(ctx, w, query) do
    conn = log_in_user(ctx.conn, ctx.user, organization: w.organization)
    {:ok, view, _html} = live(conn, "/gtfs/#{w.version.id}/runs?#{query}")
    view
  end

  defp run_ids(view) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query("#runs-list .runs-list-row")
    |> Enum.map(&(&1 |> LazyHTML.attribute("data-run") |> hd()))
  end

  # Every fact cell of a row, as `role => text`, so the two views can be compared
  # as maps and a difference names the column it is in.
  defp facts(html, row_selector) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query("#{row_selector} [data-role^='run-']")
    |> Enum.map(fn cell ->
      role = cell |> LazyHTML.attribute("data-role") |> hd()
      {String.replace_prefix(role, "run-", ""), String.trim(LazyHTML.text(cell))}
    end)
    |> Map.new()
  end

  defp cell(html, run_id, role) do
    facts(html, "#runs-list .runs-list-row[data-run='#{run_id}']")[role]
  end

  describe "?view=list renders the list" do
    test "one row per run, and not the chart", ctx do
      w = world(ctx)
      view = open(ctx, w, "view=list")

      assert has_element?(view, "table#runs-list")
      assert run_ids(view) == ["1001", "1002"]

      # The two views are alternatives. A list rendered under the timeline would
      # put two tables in one plan card, and a reader would not know which one
      # the figures on screen came from.
      refute has_element?(view, "#runs-timeline")
      refute has_element?(view, "#chart-key")
    end

    test "the default view is the timeline, and an unknown view is too", ctx do
      w = world(ctx)

      assert has_element?(open(ctx, w, ""), "#runs-timeline")
      assert has_element?(open(ctx, w, "view=chart"), "#runs-timeline")
      # A stale or hand-edited link lands on a page rather than on an error.
      refute has_element?(open(ctx, w, "view=nonsense"), "#runs-list")
    end

    test "the table names the day it is listing", ctx do
      w = world(ctx)
      view = open(ctx, w, "view=list")

      # A caption is the table's own name for a screen reader, and the day is
      # part of it: the same runs on another day type are different runs.
      assert has_element?(view, "#runs-list caption")

      # The label a reader knows, not the opaque key: "Weekday" is what the day
      # bar above the table says, and a caption that disagreed with the bar
      # would be a second name for the same thing.
      assert view |> element("#runs-list caption") |> render() =~ "Weekday"
    end

    test "the header names all eight columns in the order the cells are in", ctx do
      w = world(ctx)
      view = open(ctx, w, "view=list")

      headers =
        view
        |> render()
        |> LazyHTML.from_document()
        |> LazyHTML.query("#runs-list thead th .runs-sort")
        |> Enum.map(
          &(LazyHTML.text(&1)
            |> String.trim()
            |> String.split("\n")
            |> hd()
            |> String.trim())
        )

      assert headers == [
               "Run",
               "Type",
               "Pieces",
               "Sign-on",
               "Sign-off",
               "Spread",
               "Paid",
               "Status"
             ]

      # The header and the cells must agree, which a header-count assertion
      # cannot see: a list that appended its Pieces cell at the end would have
      # eight headers and eight cells in a DIFFERENT order.
      roles =
        view
        |> render()
        |> LazyHTML.from_document()
        |> LazyHTML.query("#runs-list .runs-list-row[data-run='1002'] > *")
        |> Enum.map(&String.trim(LazyHTML.text(&1)))

      assert length(roles) == 8
      assert Enum.at(roles, 0) == "1002"
      assert Enum.at(roles, 1) == "One piece"
      assert Enum.at(roles, 2) =~ ~r/^B 102 /
    end

    test "every header carries aria-sort and the sorted one is ascending", ctx do
      w = world(ctx)
      view = open(ctx, w, "view=list")

      html = view |> render() |> LazyHTML.from_document()

      none = html |> LazyHTML.query("#runs-list thead th[aria-sort=none]") |> Enum.count()

      ascending =
        html |> LazyHTML.query("#runs-list thead th[aria-sort=ascending]") |> Enum.count()

      assert none == 7
      assert ascending == 1
      assert none + ascending == 8

      # `aria-sort` is on every header whether or not it is the sorted one, so
      # the state never appears and disappears between renders.
      assert has_element?(view, "#runs-list th[aria-sort]:has(button[phx-value-key=status])")
    end
  end

  describe "the two views agree" do
    test "all seven shared cells carry identical text on the same run", ctx do
      w = world(ctx)
      list_html = open(ctx, w, "view=list") |> render()
      chart_html = open(ctx, w, "") |> render()

      for run_id <- ["1001", "1002"] do
        from_list = facts(list_html, "#runs-list .runs-list-row[data-run='#{run_id}']")
        from_chart = facts(chart_html, "#runs-timeline .runs-row[data-run='#{run_id}']")

        shared = ~w(type sign-on sign-off spread paid status)

        for role <- shared do
          assert Map.fetch!(from_list, role) == Map.fetch!(from_chart, role),
                 "run #{run_id}'s #{role} differs between the two views: " <>
                   "#{inspect(Map.fetch!(from_list, role))} vs #{inspect(Map.fetch!(from_chart, role))}"
        end
      end
    end

    test "the Run cell is the same button in both views", ctx do
      w = world(ctx)

      for {view_query, selector} <- [
            {"view=list", "#runs-list .runs-list-row"},
            {"", "#runs-timeline .runs-row"}
          ] do
        view = open(ctx, w, view_query)

        assert has_element?(
                 view,
                 "#{selector}[data-run='1001'] button[phx-click=open_run][phx-value-run='1001']"
               )

        # And the Run cell is the row's HEADER in both views, the way the
        # reference has it, so a screen reader announces the row by its run.
        assert has_element?(view, "#{selector}[data-run='1001'] th[scope=row][data-role=run-id]")
      end
    end

    test "the values are the run's own, read from WorkTime", ctx do
      w = world(ctx)
      list_html = open(ctx, w, "view=list") |> render()

      # Two runs with different spreads, so "identical" cannot be satisfied by a
      # cell that prints the same thing for every row.
      assert cell(list_html, "1001", "spread") != cell(list_html, "1002", "spread")
      assert cell(list_html, "1001", "type") == "Split"
      assert cell(list_html, "1002", "type") == "One piece"
    end
  end

  describe "the Pieces cell" do
    test "lists B <block> <start>–<end>, one line per piece", ctx do
      w = world(ctx)
      view = open(ctx, w, "view=list")

      html = view |> render() |> LazyHTML.from_document()

      two_pieces =
        html
        |> LazyHTML.query("#runs-list .runs-list-row[data-run='1001'] [data-role=run-pieces] div")
        |> Enum.count()

      one_piece =
        html
        |> LazyHTML.query("#runs-list .runs-list-row[data-run='1002'] [data-role=run-pieces] div")
        |> Enum.count()

      assert two_pieces == 2
      assert one_piece == 1

      lines =
        view
        |> render()
        |> LazyHTML.from_document()
        |> LazyHTML.query("#runs-list .runs-list-row[data-run='1001'] [data-role=run-pieces] div")
        |> Enum.map(&(LazyHTML.text(&1) |> String.trim()))

      assert length(lines) == 2

      assert Enum.all?(lines, &(&1 =~ ~r/^B \d+ \d{2}:\d{2}–\d{2}:\d{2}$/)),
             "got #{inspect(lines)}"

      # The two pieces are two different blocks, in the run's own order.
      assert hd(lines) =~ "B 101 "
      assert List.last(lines) =~ "B 102 "
    end

    test "each line carries THAT piece's own span, and the two are distinct", ctx do
      w = world(ctx)
      list_html = open(ctx, w, "view=list") |> render()

      lines =
        list_html
        |> LazyHTML.from_document()
        |> LazyHTML.query("#runs-list .runs-list-row[data-run='1001'] [data-role=run-pieces] div")
        |> Enum.map(&(LazyHTML.text(&1) |> String.trim()))

      # A cell that printed the run's sign-on for every piece, or one piece's
      # span twice, would still match the line format — so the two lines must
      # differ, and the block named must be the piece's own.
      assert length(lines) == 2
      assert hd(lines) != List.last(lines)
      assert hd(lines) =~ "B 101 "
      assert List.last(lines) =~ "B 102 "

      # This world's two blocks OVERLAP in the day, so the spans are not
      # chronological and the test does not claim they are. The claim is that
      # each line names its own block, which the run's own pieces confirm.
      for line <- lines do
        assert [_full, _block, _from, _to] =
                 Regex.run(~r/^B (\d+) (\d{2}:\d{2})–(\d{2}:\d{2})$/, line)
      end
    end

    test "the Pieces cell is the third column, where the header puts it", ctx do
      w = world(ctx)
      html = open(ctx, w, "view=list") |> render()

      cells =
        html
        |> LazyHTML.from_document()
        |> LazyHTML.query("#runs-list .runs-list-row[data-run='1002'] > *")
        # The per-cell class is the name every cell carries. `data-role` is not:
        # the Status cell's role is on the `status_cell/1` span inside it, and
        # moving it out would make the marks tests' `[data-role=run-status]`
        # selector match two elements and break its count assertions.
        |> Enum.map(fn cell ->
          cell |> LazyHTML.attribute("class") |> hd() |> String.split() |> List.last()
        end)

      assert cells ==
               ~w(runs-fact-id runs-fact-type runs-fact-pieces runs-fact-on runs-fact-off runs-fact-spread runs-fact-paid runs-fact-status)
    end
  end

  describe "sorting is shared" do
    test "sorting by Spread reorders the list", ctx do
      w = world(ctx)
      view = open(ctx, w, "view=list")

      assert run_ids(view) == ["1001", "1002"]

      view |> element("#runs-list th button[phx-value-key=spread]") |> render_click()

      # The patch KEEPS `view=list`. A path rebuilt from defaults would take the
      # reader back to the chart the moment they re-sorted a table they were
      # looking at.
      assert_patch(view, "/gtfs/#{w.version.id}/runs?day=#{w.day_type_key}&sort=spread&view=list")

      sorted = run_ids(view)
      assert sorted == ["1002", "1001"]

      assert has_element?(
               view,
               "#runs-list th[aria-sort=ascending]:has(button[phx-value-key=spread])"
             )
    end

    test "switching to Timeline keeps the sort", ctx do
      w = world(ctx)
      view = open(ctx, w, "view=list")

      view |> element("#runs-list th button[phx-value-key=spread]") |> render_click()
      assert ["1002", "1001"] = run_ids(view)

      # The sort lives in the URL, so the view switch carries it: this is the
      # same reason `?day=` is never dropped. A switch that rebuilt the path from
      # scratch would silently return a reader to sign-on order.
      view |> element("#runs-view-form") |> render_change(%{"view" => "timeline"})
      assert_patch(view, "/gtfs/#{w.version.id}/runs?day=#{w.day_type_key}&sort=spread")

      assert has_element?(view, "#runs-timeline")

      chart_order =
        view
        |> render()
        |> LazyHTML.from_document()
        |> LazyHTML.query("#runs-timeline .runs-row")
        |> Enum.map(&(&1 |> LazyHTML.attribute("data-run") |> hd()))

      assert chart_order == ["1002", "1001"]
    end

    test "switching to List keeps the sort and the direction", ctx do
      w = world(ctx)
      view = open(ctx, w, "view=list")

      view |> element("#runs-list th button[phx-value-key=spread]") |> render_click()
      view |> element("#runs-list th button[phx-value-key=spread]") |> render_click()
      assert run_ids(view) == ["1001", "1002"]

      view |> element("#runs-view-form") |> render_change(%{"view" => "timeline"})
      view |> element("#runs-view-form") |> render_change(%{"view" => "list"})

      assert_patch(
        view,
        "/gtfs/#{w.version.id}/runs?day=#{w.day_type_key}&dir=desc&sort=spread&view=list"
      )

      assert run_ids(view) == ["1001", "1002"]
    end

    test "the view param does not fill the URL when it is the default", ctx do
      w = world(ctx)
      view = open(ctx, w, "view=list")

      view |> element("#runs-view-form") |> render_change(%{"view" => "timeline"})

      # `?view=timeline` in the address bar would be noise: a reader copying the
      # URL for the page they are looking at should get the short one.
      assert_patch(view, "/gtfs/#{w.version.id}/runs?day=#{w.day_type_key}")
    end

    test "the URL alone restores the list and its sort", ctx do
      w = world(ctx)
      view = open(ctx, w, "view=list&sort=spread")

      assert has_element?(view, "#runs-list")
      assert run_ids(view) == ["1002", "1001"]
    end
  end

  describe "the controls" do
    test "the chart's scale control is not shown on the list", ctx do
      w = world(ctx)
      view = open(ctx, w, "view=list")

      # "Whole day | Zoom in" does nothing to a table, and a control that changes
      # nothing is a control the reader has to work out is broken.
      assert has_element?(view, "#runs-view")
      refute has_element?(view, "#runs-scale")
    end

    test "both views offer the same Timeline | List control", ctx do
      w = world(ctx)
      list = open(ctx, w, "view=list")
      chart = open(ctx, w, "")

      assert has_element?(list, "#runs-view-form input[value=list][checked]")
      assert has_element?(chart, "#runs-view-form input[value=timeline][checked]")
    end
  end
end
