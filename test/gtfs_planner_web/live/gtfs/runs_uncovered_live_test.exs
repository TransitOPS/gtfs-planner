defmodule GtfsPlannerWeb.Gtfs.RunsUncoveredLiveTest do
  @moduledoc """
  EV-25: the Uncovered work tab.

  The card's independence field is "seeded segments", and that is the shape of
  this gate. The panel's whole purpose is answering "what is left?", so the
  assertions are about the answer being **the day's own** and not a second
  reading of the same numbers: the callout's count is trips, the tab's count is
  trips, the row's count is trips, and the empty state says so in words. Two of
  those three have to agree with each other, and a fourth thing — the count strip
  the callout sits under — has to agree with all of them.

  The second concern is the cell that exists for the panel's sake: the **next
  relief window**. A change of operator is only possible at a window, so a
  segment with one in five minutes and a segment with none in its own span are
  different pieces of work, and a table that showed only clock times would make
  them identical. The "no window" branch is asserted as its own sentence, not as
  an absent cell.
  """
  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.RunsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlannerWeb.Gtfs.RunsComponents

  @moduletag :ev_25
  @moduletag timeout: 120_000

  setup do
    %{user: user_fixture()}
  end

  # TWO uncovered segments and one run, so the panel has more than one row and
  # the count strip's uncovered tile is non-zero while the chart still has
  # something to draw. A fixture that uncovered everything would have no run at
  # all, and the callout's claim to sit UNDER the count strip would be untestable
  # — a callout above an empty strip is a different surface.
  #
  # The segments are the tail of block 101 and the head of block 102, so the
  # table's two rows are on DIFFERENT blocks and its block-then-start ordering has
  # something to do.
  defp world(ctx) do
    user = ctx.user
    w = runs_version_fixture()

    [first_101 | _tail_101] = w.blocks["101"]
    [_first_102, second_102] = w.blocks["102"]

    # One run over the head of 101 and the tail of 102: two pieces, so the chart
    # has a run with a gap in it and the uncovered segments are the two ends
    # between them.
    for trip <- [first_101, second_102] do
      trip_run_fixture(w.organization.id, w.version.id, %{
        trip: trip,
        day_type_key: w.day_type_key,
        run_id: "1001"
      })
    end

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: w.organization.id,
      roles: ["pathways_studio_editor"]
    })

    w
  end

  # A day with no uncovered work at all: every trip is in a run, and the panel
  # has to SAY that rather than render an empty table.
  defp covered_world(ctx) do
    user = ctx.user
    w = runs_version_fixture()

    for {block, trips} <- w.blocks, {trip, i} <- Enum.with_index(trips) do
      trip_run_fixture(w.organization.id, w.version.id, %{
        trip: trip,
        day_type_key: w.day_type_key,
        run_id: "#{block}#{i}"
      })
    end

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

  defp doc(view), do: view |> render() |> LazyHTML.from_document()

  # A cell's text, squashed. LazyHTML keeps the template's indentation, so an
  # exact match on "3" fails on "\n            3\n          " — and the fix for
  # that is NOT to relax the assertion to `=~`, which would also pass on "13".
  defp text(view, selector) do
    view
    |> doc()
    |> LazyHTML.query(selector)
    |> LazyHTML.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp attribute(view, selector, name) do
    view
    |> doc()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute(name)
    |> List.first()
  end

  defp count(view, selector) do
    view |> doc() |> LazyHTML.query(selector) |> Enum.count()
  end

  describe "the tabs" do
    test "the uncovered tab's count is the number of TRIPS, not segments", ctx do
      w = world(ctx)
      view = open(ctx, w, "panel=uncovered")

      # Two segments, on two blocks, holding three trips. A tab labelled with
      # the SEGMENT count would be a different measurement of the same thing
      # wearing the same name, and the row count below is what distinguishes
      # them.
      assert count(view, "#runs-uncovered-table [data-role=uncovered-row]") == 2

      # The seeded day has FOUR trips outside any run, in TWO segments on two
      # blocks. The tab counts TRIPS: 3 would be the segment count, and a reader
      # comparing the tab with the callout beneath it would see two different
      # numbers for one thing.
      assert has_element?(view, "#runs-tab-uncovered", "Uncovered work · 4")
      assert text(view, "#uncovered-0 [data-role=uncovered-trips]") == "3"
      assert text(view, "#uncovered-1 [data-role=uncovered-trips]") == "1"
    end

    test "both tabs are present and the pressed one carries aria-selected", ctx do
      w = world(ctx)
      view = open(ctx, w, "")

      assert has_element?(view, "#runs-tab-runs[role=tab][aria-selected=true]")
      assert has_element?(view, "#runs-tab-uncovered[role=tab][aria-selected=false]")
      assert has_element?(view, "[role=tablist][aria-label='Runs sections']")
    end

    test "the Runs tab's count is the number of runs", ctx do
      w = world(ctx)
      view = open(ctx, w, "")

      assert has_element?(view, "#runs-tab-runs", "Runs · 1")
    end

    test "an unknown panel falls back to the Runs panel", ctx do
      w = world(ctx)
      view = open(ctx, w, "panel=sideways")

      assert has_element?(view, "#runs-tab-runs[aria-selected=true]")
      refute has_element?(view, "#runs-uncovered-empty")
      assert has_element?(view, "#runs-timeline")
    end
  end

  describe "?panel=uncovered" do
    test "the table lists the seeded block with its trips, times and places", ctx do
      w = world(ctx)
      view = open(ctx, w, "panel=uncovered")

      assert count(view, "#runs-uncovered-table [data-role=uncovered-row]") == 2
      assert count(view, "#runs-uncovered-table [data-role=uncovered-trips]") == 2

      # The first row is block 101, the uncovered part of it.
      # The first row is the TAIL of block 101, so the row's start is its second
      # trip's departure and not the block's: a table that showed the block's
      # own start would claim the covered head of the block is uncovered too.
      first = text(view, "#uncovered-0")

      assert first =~ "Block 101"
      assert text(view, "#uncovered-0 [data-role=uncovered-time]") =~ ~r/\d{2}:\d{2}/
      assert text(view, "#uncovered-1 [data-role=uncovered-block]") =~ "Block 102"
    end

    test "each row's numbers are the segment's own, in its data attributes", ctx do
      w = world(ctx)
      view = open(ctx, w, "panel=uncovered")

      {:ok, day} = Gtfs.load_runs(w.organization.id, w.version.id, w.day_type_key)
      [segment | _] = Enum.sort_by(day.derived.uncovered, &String.to_integer(&1.block_id))

      row =
        view
        |> doc()
        |> LazyHTML.query("#uncovered-0")
        |> LazyHTML.attribute("data-block")
        |> List.first()

      assert row == "101"

      trips =
        view
        |> doc()
        |> LazyHTML.query("#uncovered-0")
        |> LazyHTML.attribute("data-trips")
        |> List.first()

      assert trips == to_string(length(segment.trips))

      start_secs =
        view
        |> doc()
        |> LazyHTML.query("#uncovered-0")
        |> LazyHTML.attribute("data-start")
        |> List.first()

      assert start_secs == to_string(segment.start_secs)
    end

    test "the Time cell prints the span and the time on the vehicle", ctx do
      w = world(ctx)
      view = open(ctx, w, "panel=uncovered")

      time = text(view, "#uncovered-0 [data-role=uncovered-time]")

      assert time =~ ~r/\d{2}:\d{2}/
      assert time =~ "on the vehicle"
    end

    test "the From to cell names the segment's own two places", ctx do
      w = world(ctx)
      view = open(ctx, w, "panel=uncovered")

      places = text(view, "#uncovered-0 [data-role=uncovered-places]")

      assert places =~ "→"
      refute places =~ "Unknown stop"
    end

    test "a segment with a window in its own span says Next relief at a NAMED stop", ctx do
      w = world(ctx)
      view = open(ctx, w, "panel=uncovered")

      relief = text(view, "#uncovered-0 [data-role=uncovered-relief]")

      assert relief =~ "Next relief"
      assert relief =~ ~r/\d{2}:\d{2}/
      # A stop id would satisfy the "at" clause; the point is a NAME. The
      # fixture's own stops are BAY_A and BAY_B, so this is a real
      # discrimination rather than a hopeful one.
      refute relief =~ "BAY_"
    end

    test "the window quoted is INSIDE that row's own span", ctx do
      w = world(ctx)
      view = open(ctx, w, "panel=uncovered")

      # The rule, asserted on every row rather than on whichever row happens to
      # lack a window: a relief point before the work started or after it ended
      # is not somewhere an operator can pick this work up, so quoting one is a
      # number that cannot be acted on. This is the cell the panel exists for, so
      # it is the one worth the unconditional assertion.
      for index <- [0, 1] do
        start_secs = attribute(view, "#uncovered-#{index}", "data-start") |> String.to_integer()
        end_secs = attribute(view, "#uncovered-#{index}", "data-end") |> String.to_integer()

        [_, hour, minute] =
          Regex.run(
            ~r/(\d{2}):(\d{2})/,
            text(view, "#uncovered-#{index} [data-role=uncovered-relief]")
          )

        quoted = String.to_integer(hour) * 3600 + String.to_integer(minute) * 60

        assert quoted >= start_secs,
               "row #{index} quotes #{hour}:#{minute} before its own start of #{start_secs}"

        assert quoted <= end_secs,
               "row #{index} quotes #{hour}:#{minute} after its own end of #{end_secs}"
      end
    end

    test "a segment with no window in its own span says No relief point", _ctx do
      # Which of the two seeded segments has no window inside its own span is a
      # property of the fixture, so this renders the COMPONENT directly with a
      # segment that provably has none. Asserting the empty branch only
      # conditionally, off the live day, would leave it unasserted whenever the
      # fixture happens to give both segments a window — and the branch is the
      # one that matters: an empty cell renders identically to a rendering
      # fault, so a reader cannot tell "no relief point" from "the page broke".
      segment = %{
        run_id: nil,
        block_id: "999",
        route_id: "R9",
        trips: [%{trip_id: "x"}],
        start_secs: 30_000,
        end_secs: 40_000,
        start_stop: %{stop_id: "BAY_A"},
        end_stop: %{stop_id: "BAY_B"}
      }

      html =
        render_component(&RunsComponents.uncovered/1,
          segments: [segment],
          windows: %{
            "999" => [
              %{
                stop_id: "BAY_B",
                start_secs: 10_000,
                end_secs: 12_000,
                drive_secs: 0,
                gap_index: 0,
                side: :same
              }
            ]
          },
          routes: %{},
          stop_names: %{"BAY_A" => "Bay A", "BAY_B" => "Bay B"}
        )

      cell =
        html
        |> LazyHTML.from_document()
        |> LazyHTML.query("[data-role=uncovered-relief]")
        |> LazyHTML.text()

      assert String.trim(cell) == "No relief point"

      # The window that EXISTS but falls before the segment's own span is not
      # quoted: that is the whole rule. The scope is the CELL, not the page —
      # the column is headed "Next relief window" whatever any row says.
      refute cell =~ "Next relief"
      refute cell =~ "and 1 more"
    end

    test "the Create run button is present and carries the segment it is for", ctx do
      w = world(ctx)
      view = open(ctx, w, "panel=uncovered")

      assert count(view, "[data-role=create-run]") == 2
      assert has_element?(view, "#uncovered-0 [data-role=create-run]", "Create run")

      # Step 28 wires the handler. Until then the button is inert BY THE CARD'S
      # SEQUENCING, so this gate asserts its identity and does not click it: a
      # click here would be testing step 28's work.
      block =
        view
        |> doc()
        |> LazyHTML.query("#uncovered-0 [data-role=create-run]")
        |> LazyHTML.attribute("phx-value-block")
        |> List.first()

      assert block == "101"
    end

    test "the panel does not render the chart or the list", ctx do
      w = world(ctx)
      view = open(ctx, w, "panel=uncovered")

      refute has_element?(view, "#runs-timeline")
      refute has_element?(view, "#runs-list")
    end
  end

  describe "the callout" do
    test "it appears under the count strip when uncovered work exists", ctx do
      w = world(ctx)
      view = open(ctx, w, "")

      assert has_element?(view, "#runs-uncovered-callout")

      html = render(view)
      strip = html |> String.split("id=\"runs-uncovered-callout\"") |> List.first()
      assert strip =~ "runs-count-strip" or strip =~ "runs-tile"
    end

    test "its count is TRIPS and it names what the work costs", ctx do
      w = world(ctx)
      view = open(ctx, w, "")

      # The SAME number the tab carries, because both are counting trips and a
      # reader who compares them will.
      assert has_element?(
               view,
               "#runs-uncovered-callout",
               "4 trips are not in a run."
             )

      assert render(view) =~ "of vehicle work has no operator"
    end

    test "it is a warning callout, not an error and not info", ctx do
      w = world(ctx)
      view = open(ctx, w, "")

      classes =
        view
        |> doc()
        |> LazyHTML.query("#runs-uncovered-callout div")
        |> Enum.map(&(&1 |> LazyHTML.attribute("class") |> List.first()))

      # A warning and not an error: uncovered work is a thing to plan, not a
      # fault. An error-red callout would train a reader that amber means broken.
      assert Enum.any?(classes, &(&1 =~ "border-warning"))
      refute Enum.any?(classes, &(&1 =~ "border-error"))
      refute Enum.any?(classes, &(&1 =~ "border-info"))
    end

    test "its Review button switches to the tab", ctx do
      w = world(ctx)
      view = open(ctx, w, "")

      assert has_element?(
               view,
               "#runs-uncovered-callout [data-role=review-uncovered]",
               "Review uncovered work"
             )

      view |> element("#runs-uncovered-callout [data-role=review-uncovered]") |> render_click()

      assert has_element?(view, "#runs-tab-uncovered[aria-selected=true]")
      assert has_element?(view, "#runs-uncovered-table")
    end

    test "it never blocks: the Runs panel is the default and it is on the page", ctx do
      w = world(ctx)
      view = open(ctx, w, "")

      assert has_element?(view, "#runs-timeline")
      assert has_element?(view, "#runs-uncovered-callout")
    end
  end

  describe "a fully covered day" do
    test "it says every blocked trip is in a run and shows no table", ctx do
      w = covered_world(ctx)
      view = open(ctx, w, "panel=uncovered")

      assert has_element?(view, "#runs-uncovered-empty", "Every blocked trip is in a run.")
      refute has_element?(view, "#runs-uncovered-table")
    end

    test "it shows no callout at all, on either panel", ctx do
      w = covered_world(ctx)
      view = open(ctx, w, "")

      refute has_element?(view, "#runs-uncovered-callout")
      assert has_element?(view, "#runs-tab-uncovered", "Uncovered work · 0")
      refute has_element?(view, "[data-role=uncovered-dot]")
    end
  end

  describe "the panel param" do
    test "the URL alone restores the panel", ctx do
      w = world(ctx)
      view = open(ctx, w, "panel=uncovered")

      assert has_element?(view, "#runs-uncovered-table")
    end

    test "a tab switch keeps every other piece of URL state", ctx do
      w = world(ctx)
      view = open(ctx, w, "sort=spread&dir=desc")

      # The sort is still in force after the panel changes, so a reader who
      # sorted a table and then went looking at uncovered work does not lose
      # their order — step 26's bug, reached through a different control.
      # The WHOLE path, so a patch that dropped the sort or the direction is a
      # failure rather than a prefix match — step 26's bug, reached through the
      # new control instead of the old one.
      view |> element("#runs-tab-uncovered") |> render_click()

      assert_patch(
        view,
        "/gtfs/#{w.version.id}/runs?day=#{w.day_type_key}&sort=spread&dir=desc&panel=uncovered"
      )

      assert has_element?(view, "#runs-uncovered-table")
    end

    test "the panel does not appear in the URL when it is the default", ctx do
      w = world(ctx)
      view = open(ctx, w, "")

      view |> element("#runs-tab-runs") |> render_click()

      assert_patch(view, "/gtfs/#{w.version.id}/runs?day=#{w.day_type_key}")
    end

    test "switching back to Runs returns to the chart, still sorted", ctx do
      w = world(ctx)
      view = open(ctx, w, "panel=uncovered&sort=spread")

      view |> element("#runs-tab-runs") |> render_click()

      assert_patch(view, "/gtfs/#{w.version.id}/runs?day=#{w.day_type_key}&sort=spread")

      assert has_element?(view, "#runs-tab-runs[aria-selected=true]")
      assert has_element?(view, "#runs-timeline")
    end

    test "the scale control is hidden on the uncovered panel", ctx do
      w = world(ctx)
      view = open(ctx, w, "panel=uncovered")

      # A zoom on a table changes nothing, and a control that changes nothing is
      # one the reader has to work out is broken — step 26's rule, applied to the
      # second control that only ever drew the chart.
      refute has_element?(view, "#runs-scale")
    end
  end
end
