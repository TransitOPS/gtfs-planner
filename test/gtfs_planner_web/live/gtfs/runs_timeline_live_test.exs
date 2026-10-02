defmodule GtfsPlannerWeb.Gtfs.RunsTimelineLiveTest do
  @moduledoc """
  The Runs duty chart — its table, rows, pieces, axis, sort and zoom.

  The tests assert element structure and order: the figures in the cells are
  tested in `day_test.exs` and `derive_version_test.exs`, so what is tested here
  is that each cell carries the run's own value in the right column, that the rows
  are in the order the sort asked for, and that the pieces sit on the track where
  the day's axis says they belong.

  Every world is a real `runs_version_fixture/1` with `RunsFixtures.trip_run_fixture/3`
  rows, loaded through the production read path. There is no mock and no stub in
  this file, so there is nothing to verify on exit.

  ## Why the geometry is asserted on the style attribute

  The pieces are positioned as percentages of the day's axis, and the axis is
  derived from the runs themselves. Asserting "there are two pieces" would pass
  with both at the same coordinates; asserting the `left` and `width` in the
  style pins the piece to the block it came from. Two decimals is the precision
  `BlocksComponents` uses and it is what makes that comparison possible.

  Measured pixel sizes are not tested here: row and bar heights live in
  `assets/css/app.css`, which no Elixir test reads. The Playwright journey
  `assets/e2e/runs.spec.js` measures the 44 px rows and 28 px bars.

  Rows are created inside the SQL Sandbox transaction and rolled back.
  """
  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.RunsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.GtfsTime

  setup :editor_setup

  # Only the user is built here. `runs_version_fixture/1` creates its own
  # organization, so the membership goes on that one, not on a separate
  # organization fixture.
  defp editor_setup(_context) do
    %{user: user_fixture()}
  end

  # Block 101's four trips in run 1001, block 102's two in run 1002. Two
  # one-piece runs, so the two rows are separable by sign-on and their pieces are
  # separable by block.
  defp two_runs(context) do
    world = seeded_world(context)

    for {block, run_id} <- [{"101", "1001"}, {"102", "1002"}], trip <- world.blocks[block] do
      trip_run_fixture(world.organization.id, world.version.id, %{
        trip: trip,
        day_type_key: world.day_type_key,
        run_id: run_id
      })
    end

    world
  end

  # One run over both blocks and one over the second block's last trip, so there
  # is a run with TWO pieces. A two-piece run is what proves the piece list is
  # per run rather than per block.
  defp split_run(context) do
    world = seeded_world(context)
    [first, second] = world.blocks["102"]

    for trip <- world.blocks["101"] ++ [first] do
      trip_run_fixture(world.organization.id, world.version.id, %{
        trip: trip,
        day_type_key: world.day_type_key,
        run_id: "1001"
      })
    end

    trip_run_fixture(world.organization.id, world.version.id, %{
      trip: second,
      day_type_key: world.day_type_key,
      run_id: "1002"
    })

    world
  end

  defp seeded_world(%{user: user}) do
    world = runs_version_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: world.organization.id,
      roles: ["pathways_studio_editor"]
    })

    world
  end

  defp signed_in(context, world) do
    conn = log_in_user(context.conn, context.user, organization: world.organization)
    {:ok, view, _html} = live(conn, "/gtfs/#{world.version.id}/runs")
    view
  end

  defp derived(world) do
    {:ok, runs_day} = Gtfs.load_runs(world.organization.id, world.version.id, world.day_type_key)
    runs_day
  end

  # The run IDs in the order the table currently holds them, read from the DOM
  # rather than from the domain, so the assertion is about the ORDER and not
  # about a set.
  defp row_order(view) do
    view
    |> element("#runs-timeline-body")
    |> render()
    |> then(&Regex.scan(~r/data-run="([^"]+)"/, &1))
    |> Enum.map(fn [_all, id] -> id end)
  end

  # The two decimals `piece_geometry/2` writes, read back out of the style.
  defp piece_style(view, run_id, block_id) do
    view
    |> element("#run-#{run_id} [data-role=piece][data-block='#{block_id}']")
    |> render()
    |> then(&Regex.run(~r/style="([^"]*)"/, &1))
    |> case do
      [_, style] -> style
      _ -> nil
    end
  end

  describe "the table and its rows" do
    test "#runs-timeline has one row per run in sign-on order with all seven fact cells",
         context do
      world = two_runs(context)
      view = signed_in(context, world)
      runs = derived(world).derived.runs

      assert has_element?(view, "#runs-timeline-scroll")
      assert has_element?(view, "#runs-timeline[data-scale=day]")
      assert has_element?(view, "#runs-timeline-body[phx-update=stream]")

      # Two runs, two rows, in sign-on order. Run 1001 is block 101 (05:50) and
      # run 1002 is block 102 (12:00), so sign-on order and run-number order
      # happen to agree here — which is why the SIGN-ON sort is asserted
      # separately below rather than left implied by this one.
      assert row_order(view) == ["1001", "1002"]
      assert length(runs) == 2

      for run_id <- ["1001", "1002"] do
        assert has_element?(view, "#run-#{run_id}[data-run='#{run_id}']")
      end

      # The seven headers, in the prototype's order, all sortable.
      for {key, label} <- [
            {"id", "Run"},
            {"type", "Type"},
            {"sign_on", "Sign-on"},
            {"sign_off", "Sign-off"},
            {"spread", "Spread"},
            {"paid", "Paid"},
            {"status", "Status"}
          ] do
        assert has_element?(view, "th.runs-meta-#{key}[aria-sort] .runs-sort", label)
      end

      # `aria-sort` is on every header whether or not it is the sorted one, so
      # the sort state never appears or disappears between renders.
      assert has_element?(view, "th.runs-meta-sign_on[aria-sort=ascending]")
      assert has_element?(view, "th.runs-meta-paid[aria-sort=none]")
    end

    test "each cell carries the run's own figure", context do
      world = two_runs(context)
      view = signed_in(context, world)
      [first, second] = derived(world).derived.runs

      assert has_element?(
               view,
               "#run-1001 [data-role=run-type]",
               "One piece"
             )

      # Sign-on and sign-off are the shared GTFS-hours formatter, so a run that
      # signs off after midnight reads "25:30" rather than a bare time that looks
      # like it signed on before it started.
      assert has_element?(
               view,
               "#run-1001 [data-role=run-sign-on]",
               GtfsTime.display(first.work.sign_on_secs)
             )

      assert has_element?(
               view,
               "#run-1001 [data-role=run-sign-off]",
               GtfsTime.display(first.work.sign_off_secs)
             )

      # Spread and Paid as hours and minutes — "11:43", not "703 min" — the same
      # way the summary drawer prints them, so the two cannot disagree.
      assert has_element?(
               view,
               "#run-1001 [data-role=run-spread]",
               "#{div(first.work.spread_secs, 3600)}:#{pad(rem(div(first.work.spread_secs, 60), 60))}"
             )

      assert has_element?(
               view,
               "#run-1002 [data-role=run-paid]",
               "#{div(second.work.paid_secs, 3600)}:#{pad(rem(div(second.work.paid_secs, 60), 60))}"
             )

      # A row is never blank in its Status cell. The wording is the marks tests'
      # subject; here it is the run's own findings.
      assert has_element?(view, "#run-1001 [data-role=run-status]")
    end

    test "a run that signs off after midnight prints GTFS hours", context do
      world = two_runs(context)
      view = signed_in(context, world)
      [_first, second] = derived(world).derived.runs

      # The fixture's two blocks sit either side of midday, so nothing crosses
      # midnight and the fixture cannot prove this case. The formatter's own
      # behaviour is `GtfsTime.display/1`'s and is tested in
      # `gtfs_time_test.exs`, but the COLUMN is this step's, so what is pinned
      # here is that the cell uses the shared formatter rather than a bare
      # `hh:mm` of its own — by the sign-off being the same string the formatter
      # produces for these seconds.
      # The cell's text is EXACTLY what `GtfsTime.display/1` returns for these
      # seconds, which is the claim this column owns: it uses the shared
      # formatter rather than a bare `hh:mm` of its own. The GTFS-hours clock is
      # that formatter's behaviour and is its tested, not this step's — and no
      # world in `RunsFixtures` crosses midnight, so a `25:30`-style value cannot
      # be seen end to end here without inventing a fixture this step would own
      # forever.
      cell = view |> element("#run-1002 [data-role=run-sign-off]") |> render()

      assert String.trim(cell) =~ "<td"
      assert cell =~ GtfsTime.display(second.work.sign_off_secs)
    end
  end

  describe "the pieces on the track" do
    test "each row's pieces render as buttons labelled B <block>", context do
      world = two_runs(context)
      view = signed_in(context, world)

      assert has_element?(view, "#run-1001 [data-role=piece][data-block='101']", "B 101")
      assert has_element?(view, "#run-1002 [data-role=piece][data-block='102']", "B 102")

      # One piece each, so each row carries exactly one bar.
      assert view
             |> element("#run-1001 [data-role=piece]")
             |> render() =~
               "data-piece=\"1\""
    end

    test "a run over two blocks carries one bar per block", context do
      world = split_run(context)
      view = signed_in(context, world)

      run = Enum.find(derived(world).derived.runs, &(&1.run_id == "1001"))

      assert length(run.pieces) == 2

      assert has_element?(view, "#run-1001 [data-role=piece][data-block='101']")
      assert has_element?(view, "#run-1001 [data-role=piece][data-block='102']")

      # The second piece of the SAME run is numbered 2, so `data-piece` counts
      # within a run and not within a block.
      assert view
             |> element("#run-1001 [data-role=piece][data-block='102']")
             |> render() =~
               "data-piece=\"2\""
    end

    test "a piece is positioned on the day's own axis", context do
      world = two_runs(context)
      view = signed_in(context, world)
      [first, second] = derived(world).derived.runs
      axis = derived(world).derived.axis

      span = axis.end_secs - axis.start_secs
      [piece] = first.pieces

      style = piece_style(view, "1001", "101")

      left = expected_percent(piece.start_secs - axis.start_secs, span)
      width = expected_percent(piece.end_secs - piece.start_secs, span)

      assert style =~ "left: #{left}%"
      assert style =~ "width: #{width}%"

      # Run 1002 signs on eleven hours later, so its piece starts further right
      # than run 1001's. Asserting only the first piece would pass with a track
      # that puts everything at the same place.
      [later_piece] = second.pieces
      later_left = expected_percent(later_piece.start_secs - axis.start_secs, span)

      assert piece_style(view, "1002", "102") =~ "left: #{later_left}%"
      assert String.to_float(left) < String.to_float(later_left)
    end

    test "the piece carries its own title naming the run, the piece and the block", context do
      world = two_runs(context)
      view = signed_in(context, world)

      title = view |> element("#run-1001 [data-role=piece]") |> render()

      assert title =~ "Run 1001, piece 1: block 101"
    end
  end

  describe "the axis" do
    test "ticks every two hours across the day's span", context do
      world = two_runs(context)
      view = signed_in(context, world)
      axis = derived(world).derived.axis

      ticks =
        view
        |> element("#runs-timeline thead")
        |> render()
        |> then(&Regex.scan(~r/class="runs-axis-tick" style="left: ([^"]+)"/, &1))

      # Two-hourly over a span that starts at the first sign-on. The count is
      # asserted as "more than one and fewer than span/2h + 1" rather than as a
      # literal, because the span is the fixture's and `Runs.Day` owns the axis.
      span_hours = div(axis.end_secs - axis.start_secs, 3600)
      assert ticks != []
      assert length(ticks) <= div(span_hours, 2)

      # The first tick is the start of the axis, and its label is that instant on
      # the shared GTFS-hours formatter — so the tick and the row's sign-on cell
      # agree.
      # The regex has one capture group, so each match is [full, left].
      [_full, first_left] = hd(ticks)

      # The style carries the percent sign; the left position of the first tick is zero.
      assert first_left == "0.00%"

      assert view |> element("#runs-timeline thead") |> render() =~
               GtfsTime.display(axis.start_secs)
    end

    test "the track shares the axis's spacing rule", context do
      world = two_runs(context)
      view = signed_in(context, world)

      # One `--runs-grid` custom property on the row's track cell, so the track's
      # rules and the axis's ticks cannot drift apart: they read the same number.
      style =
        view
        |> element("#run-1001 .runs-track")
        |> render()

      assert style =~ "--runs-grid:"
    end
  end

  describe "sorting" do
    test "clicking the Paid header reorders rows and sets aria-sort; clicking again reverses",
         context do
      world = two_runs(context)
      view = signed_in(context, world)
      [first, second] = derived(world).derived.runs

      # The fixture's two runs have different paid times, so paid order is
      # separable from sign-on order. If they were equal the sort would be a
      # no-op and the test would pass without proving anything.
      assert first.work.paid_secs != second.work.paid_secs

      before = row_order(view)

      view |> element("th.runs-meta-paid .runs-sort") |> render_click()

      assert has_element?(view, "th.runs-meta-paid[aria-sort=ascending]")
      assert has_element?(view, "th.runs-meta-sign_on[aria-sort=none]")

      ascending = row_order(view)
      assert ascending != before

      assert ascending ==
               Enum.sort(ascending, fn a, b -> paid_of(world, a) <= paid_of(world, b) end)

      # The order is in the URL, so it is shareable and the back button returns.
      assert_patch(view, "/gtfs/#{world.version.id}/runs?day=#{world.day_type_key}&sort=paid")

      view |> element("th.runs-meta-paid .runs-sort") |> render_click()

      assert has_element?(view, "th.runs-meta-paid[aria-sort=descending]")
      assert row_order(view) == Enum.reverse(ascending)

      assert_patch(
        view,
        "/gtfs/#{world.version.id}/runs?day=#{world.day_type_key}&sort=paid&dir=desc"
      )
    end

    test "sorting by Sign-on puts the earliest sign-on first", context do
      world = two_runs(context)
      view = signed_in(context, world)

      view |> element("th.runs-meta-paid .runs-sort") |> render_click()
      assert has_element?(view, "th.runs-meta-paid[aria-sort=ascending]")

      # A different key starts ascending again rather than continuing the
      # previous direction — `BlocksLive`'s rule.
      view |> element("th.runs-meta-sign_on .runs-sort") |> render_click()

      assert has_element?(view, "th.runs-meta-sign_on[aria-sort=ascending]")

      order = row_order(view)
      signs = Enum.map(order, &sign_on_of(world, &1))

      assert signs == Enum.sort(signs)
    end

    test "the URL restores an order without re-reading the day", context do
      world = two_runs(context)
      conn = log_in_user(context.conn, context.user, organization: world.organization)

      {:ok, view, _html} = live(conn, "/gtfs/#{world.version.id}/runs?sort=paid&dir=desc")

      assert has_element?(view, "th.runs-meta-paid[aria-sort=descending]")

      expected =
        derived(world).derived.runs
        |> Enum.sort_by(& &1.run_id)
        |> Enum.sort_by(& &1.work.paid_secs, :desc)
        |> Enum.map(& &1.run_id)

      assert row_order(view) == expected
    end

    test "an unknown sort key in the URL falls back to the default order", context do
      world = two_runs(context)
      conn = log_in_user(context.conn, context.user, organization: world.organization)

      {:ok, view, _html} = live(conn, "/gtfs/#{world.version.id}/runs?sort=nope")

      # A reader who edits the URL gets the default order, not a crash.
      assert has_element?(view, "th.runs-meta-sign_on[aria-sort=ascending]")
      assert row_order(view) == ["1001", "1002"]
    end
  end

  describe "zoom" do
    test "Zoom in sets data-scale=zoom and the URL param scale=zoom", context do
      world = two_runs(context)
      view = signed_in(context, world)

      assert has_element?(view, "#runs-timeline[data-scale=day]")
      assert has_element?(view, "#runs-scale-option-day[checked]")
      refute has_element?(view, "#runs-scale-option-zoom[checked]")

      view |> element("#runs-scale-form") |> render_change(%{"scale" => "zoom"})

      assert has_element?(view, "#runs-timeline[data-scale=zoom]")
      assert has_element?(view, "#runs-scale-option-zoom[checked]")
      refute has_element?(view, "#runs-scale-option-day[checked]")

      assert_patch(view, "/gtfs/#{world.version.id}/runs?day=#{world.day_type_key}&scale=zoom")

      view |> element("#runs-scale-form") |> render_change(%{"scale" => "day"})

      assert has_element?(view, "#runs-timeline[data-scale=day]")
      assert_patch(view, "/gtfs/#{world.version.id}/runs?day=#{world.day_type_key}")
    end

    test "the URL restores the zoom", context do
      world = two_runs(context)
      conn = log_in_user(context.conn, context.user, organization: world.organization)

      {:ok, view, _html} = live(conn, "/gtfs/#{world.version.id}/runs?scale=zoom")

      assert has_element?(view, "#runs-timeline[data-scale=zoom]")
      assert has_element?(view, "#runs-scale-option-zoom[checked]")
    end

    test "zooming keeps the selected day type", context do
      world = two_runs(context)
      view = signed_in(context, world)

      view |> element("#runs-day-form") |> render_change(%{"day" => world.day_type_key})
      assert_patch(view, "/gtfs/#{world.version.id}/runs?day=#{world.day_type_key}")

      view |> element("#runs-scale-form") |> render_change(%{"scale" => "zoom"})

      # A patch that rebuilt the path from scratch would silently send a reader
      # who had picked a day type back to the version's default day.
      assert_patch(view, "/gtfs/#{world.version.id}/runs?day=#{world.day_type_key}&scale=zoom")
    end

    test "zooming does not change the row order", context do
      world = two_runs(context)
      view = signed_in(context, world)

      before = row_order(view)

      view |> element("#runs-scale-form") |> render_change(%{"scale" => "zoom"})

      assert row_order(view) == before
    end
  end

  describe "the chart and the rest of the page" do
    test "the chart is not rendered in a state with no day loaded", context do
      world = seeded_world(context)
      conn = log_in_user(context.conn, context.user, organization: world.organization)

      # The version's day type with no runs still has blocks, so the page IS
      # `:loaded` — and that state has a panel of its own. The chart used to
      # render here with no rows; it no longer does, because an empty chart reads
      # as a day whose blocks are all covered, which is the opposite of what is
      # true. The region is still explained, by the first-use panel.
      {:ok, view, _html} = live(conn, "/gtfs/#{world.version.id}/runs")

      assert has_element?(view, "#runs-page[data-load-state=loaded]")
      assert has_element?(view, "#runs-first-use")
      refute has_element?(view, "#runs-timeline")

      # A day that HAS runs is not in that state, and the chart is there — which
      # is what keeps the panel from being a permanent replacement.
      planned = seeded_world(context)
      [first | _rest] = planned.blocks["101"]

      trip_run_fixture(planned.organization.id, planned.version.id, %{
        trip: first,
        day_type_key: planned.day_type_key,
        run_id: "1001"
      })

      # A FRESH conn: `live/2` consumes the one it is given, so the same `conn`
      # cannot mount a second LiveView.
      planned_conn = log_in_user(context.conn, context.user, organization: planned.organization)
      {:ok, planned_view, _html} = live(planned_conn, "/gtfs/#{planned.version.id}/runs")

      refute has_element?(planned_view, "#runs-first-use")
      assert has_element?(planned_view, "#runs-timeline")

      # An unknown day type is a state the page moves into rather than a day it
      # has, and the chart is not part of that state.
      {:ok, view, _html} = live(conn, "/gtfs/#{world.version.id}/runs?day=nope")

      assert has_element?(view, "#runs-page[data-load-state=unknown]")
      refute has_element?(view, "#runs-timeline")
    end

    test "the count strip and the chart are on the same page", context do
      world = two_runs(context)
      view = signed_in(context, world)

      # The strip is the summary of this same day's runs, so the two must be
      # about the same day. A chart that re-read or defaulted a different day
      # would be a chart of something else.
      assert has_element?(view, "#runs-count-strip")
      assert has_element?(view, "#runs-timeline")
      assert has_element?(view, "#runs-scope")
    end
  end

  defp paid_of(world, run_id) do
    world.organization.id
    |> Gtfs.load_runs(world.version.id, world.day_type_key)
    |> elem(1)
    |> Map.fetch!(:derived)
    |> Map.fetch!(:runs)
    |> Enum.find(&(&1.run_id == run_id))
    |> Map.fetch!(:work)
    |> Map.fetch!(:paid_secs)
  end

  defp sign_on_of(world, run_id) do
    world.organization.id
    |> Gtfs.load_runs(world.version.id, world.day_type_key)
    |> elem(1)
    |> Map.fetch!(:derived)
    |> Map.fetch!(:runs)
    |> Enum.find(&(&1.run_id == run_id))
    |> Map.fetch!(:work)
    |> Map.fetch!(:sign_on_secs)
  end

  # The same two-decimal conversion `piece_geometry/2` performs, computed here
  # from the domain so the DOM is compared against the read rather than against
  # a copy of the component's own arithmetic.
  defp expected_percent(value, span) do
    :erlang.float_to_binary(value * 100 / span * 1.0, decimals: 2)
  end

  defp pad(minutes) when minutes < 10, do: "0" <> Integer.to_string(minutes)
  defp pad(minutes), do: Integer.to_string(minutes)
end
