defmodule GtfsPlannerWeb.Gtfs.RunsSummaryLiveTest do
  @moduledoc """
  The Runs count strip and the Runs summary drawer.

  The counts are seeded. Every figure in the strip is produced by
  `Runs.Day.derive/4` on a real `runs_version_fixture/1` world whose trip_runs
  rows are written through `RunsFixtures.trip_run_fixture/3`, and the expected
  strings below are those figures read back out of the domain — so the case proves
  the DOM carries the derived numbers rather than a second arithmetic pass. The
  arithmetic itself is tested in `day_test.exs` and `derive_version_test.exs` and
  is not re-tested here.

  Asserted figures, for the world `two_runs/1` builds:

      run 1001  block 101's four trips     one piece
      run 1002  block 102's two trips      one piece

  which derives two runs, both one piece, a nil straight share, 72 300 s paid
  and 69 900 s on vehicles, and run 1001 spreading 42 180 s.

  ## Why the drawer is exercised through the page, not the component

  The strip's figures arrive with the page's read, but the drawer's share table is
  a `start_async` read of `Gtfs.run_day_type_shares/2` — a whole-version read the
  page does not otherwise perform. Driving the real button is the only way to
  prove the async is *started by the click* and not by the mount, which is the
  property that keeps a slow version-wide read off the page's critical path.
  `render_async/2` is what settles it.

  Rows are created inside the SQL Sandbox transaction and rolled back.
  """
  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.RunsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlannerWeb.Gtfs.RunsComponents

  # `render_async/2`'s default 100 ms is a race against the share read's own
  # transaction; the wait stays bounded and still fails when the socket never
  # settles its async work.
  @settle_timeout 5_000

  # No `Mox` here and no adapter stub: every figure below comes from the
  # production read path, so there is no mock to verify on exit.
  defp editor_setup(_context) do
    user = user_fixture()
    %{user: user}
  end

  # A published two-block world whose blocks are already cut into two runs. The
  # run numbers are the prototype's, so a reader comparing the page with the
  # reference sees the same names.
  defp two_runs(context) do
    world = seeded_world(context)

    for trip <- world.blocks["101"] do
      trip_run_fixture(world.organization.id, world.version.id, %{
        trip: trip,
        day_type_key: world.day_type_key,
        run_id: "1001"
      })
    end

    for trip <- world.blocks["102"] do
      trip_run_fixture(world.organization.id, world.version.id, %{
        trip: trip,
        day_type_key: world.day_type_key,
        run_id: "1002"
      })
    end

    world
  end

  # The same world with a second, Saturday-only calendar, so the version really
  # has two day types and the share table's "every day type" claim is a claim
  # about more than one. Weekday keys are integers on the calendar schema, not
  # booleans — `saturday: true` fails the cast.
  defp two_day_types(context) do
    world = two_runs(context)

    calendar_service_fixture(world.organization.id, world.version.id, %{
      service_id: "SA",
      name: "Saturday",
      monday: 0,
      tuesday: 0,
      wednesday: 0,
      thursday: 0,
      friday: 0,
      saturday: 1,
      sunday: 0
    })

    world
  end

  # Run 1001 takes block 101 and block 102's first trip, so it is one run over
  # two blocks and therefore a SPLIT: the break between the blocks is longer than
  # the 30-minute paid break. The share of straight over straight-plus-split is
  # then 0 of 1, which is a real figure rather than a dash.
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

  # Block 101 is cut into a run; block 102's trips are left unassigned, so they
  # are the day's uncovered work. Every world above assigns both blocks, so
  # without this one the strip's "N trips" branch — and its duration and its
  # warning tone — are never rendered by any test, and a strip that always said
  # "None" would pass.
  defp uncovered_work(context) do
    world = seeded_world(context)

    for trip <- world.blocks["101"] do
      trip_run_fixture(world.organization.id, world.version.id, %{
        trip: trip,
        day_type_key: world.day_type_key,
        run_id: "1001"
      })
    end

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

  # The domain's own answer, so the DOM assertions compare the page against the
  # read rather than against a second copy of the arithmetic in this file.
  defp derived(world) do
    {:ok, runs_day} =
      Gtfs.load_runs(world.organization.id, world.version.id, world.day_type_key)

    runs_day
  end

  describe "the count strip" do
    setup :editor_setup

    test "every tile carries the seeded day's own figures", context do
      world = two_runs(context)
      view = signed_in(context, world)
      stats = derived(world).derived.stats

      assert has_element?(view, "#runs-count-strip")

      # The Runs tile's sub-line is the type breakdown, and it is the only place
      # the three run types are counted for the reader.
      runs_html = view |> element("#runs-count-strip-item-runs") |> render()

      assert runs_html =~ "Runs"
      assert runs_html =~ "2"
      assert runs_html =~ "0 straight"
      assert runs_html =~ "0 split"
      assert runs_html =~ "2 one piece"
      assert stats.runs == 2

      # Straight share. Both runs are one piece, so neither had a choice and the
      # share is genuinely a dash rather than 0%.
      assert view |> element("#runs-count-strip-item-straight_share") |> render() =~ "—"

      # Paid hours from `paid_secs`, and the vehicle share as a percentage of it.
      assert has_element?(
               view,
               "#runs-count-strip-item-paid_hours [data-role=count-strip-value]",
               "20.1 h"
             )

      assert has_element?(
               view,
               "#runs-count-strip-item-on_vehicles [data-role=count-strip-value]",
               "97%"
             )

      # Longest spread names the run it is and the limit it is measured against.
      spread_html = view |> element("#runs-count-strip-item-longest_spread") |> render()

      assert spread_html =~ "11:43"
      assert spread_html =~ "run 1001"
      assert spread_html =~ "limit 12:00"
      assert stats.longest_spread.run_id == "1001"

      # Uncovered work: every seeded trip is in a run, so the tile says None.
      assert view |> element("#runs-count-strip-item-uncovered") |> render() =~ "None"
      assert stats.uncovered.trips == 0
    end

    test "a run that spans two blocks is reported as a split with a real share", context do
      world = split_run(context)
      view = signed_in(context, world)
      stats = derived(world).derived.stats

      assert stats.by_type.split == 1
      assert stats.straight_share == 0

      assert view |> element("#runs-count-strip-item-runs") |> render() =~
               "0 straight · 1 split · 1 one piece"

      # 0% and not a dash: the two figures the dash stands for are 0 and 1, so
      # there was a choice and the answer to it was zero.
      assert view |> element("#runs-count-strip-item-straight_share") |> render() =~ "0%"
    end

    test "uncovered work is counted, timed and toned, not hidden", context do
      world = uncovered_work(context)
      view = signed_in(context, world)
      stats = derived(world).derived.stats

      assert stats.uncovered.trips == 2

      tile = view |> element("#runs-count-strip-item-uncovered") |> render()

      assert tile =~ "Uncovered work"
      assert tile =~ "2 trips"
      # The quiet sub-figure is the work's own duration, so a reader can judge
      # whether two trips or twenty is the problem.
      assert tile =~ "min"

      # The tile carries the warning tone, which is the strip's way of saying
      # this is the one figure a reader should not have to go looking for.
      assert has_element?(
               view,
               "#runs-count-strip-item-uncovered [data-role=count-strip-tone].bg-warning"
             )
    end

    test "a sub-hour piece of uncovered work reads in minutes, not hours", context do
      world = two_runs(context)
      [first | _] = world.blocks["101"]

      stop =
        GtfsPlanner.GtfsFixtures.stop_fixture(world.organization.id, world.version.id, %{
          stop_id: "G1_STOP",
          stop_lat: world.garage.lat,
          stop_lon: world.garage.lon
        })

      # Uncovered work includes garage travel. This trip starts and ends at the
      # garage's coordinates, so its block is exactly 2700 s with no deadhead.
      # Under an hour, the duration reads "45 min" rather than "0 h 45 min".
      blocked_trip_fixture(world.organization.id, world.version.id, first.route_id, %{
        trip_id: "G1",
        service_id: "WK",
        block_id: "103",
        first_stop: stop.stop_id,
        last_stop: stop.stop_id,
        first_arrival: "14:00:00",
        first_departure: "14:00:00",
        last_arrival: "14:45:00"
      })

      view = signed_in(context, world)
      stats = derived(world).derived.stats

      assert stats.uncovered.trips == 1
      assert stats.uncovered.secs == 2700

      tile = view |> element("#runs-count-strip-item-uncovered") |> render()

      assert tile =~ "45 min"
      refute tile =~ "0 h 45 min"
    end

    test "the tiles are buttons that name their own action", context do
      world = two_runs(context)
      view = signed_in(context, world)

      for key <- ~w(runs straight_share paid_hours on_vehicles longest_spread uncovered) do
        assert has_element?(view, "#runs-count-strip-item-#{key}[type=button]")
      end

      # `aria-pressed` on every tile whether or not the drawer is open, so the
      # control's state never appears or disappears between renders.
      assert has_element?(view, "#runs-count-strip-item-runs[aria-pressed=false]")
    end

    test "the strip is inside the scope bar, below the day-type select", context do
      world = two_runs(context)
      view = signed_in(context, world)

      assert has_element?(view, "#runs-scope #runs-day-form")
      assert has_element?(view, "#runs-scope-counts #runs-count-strip")
    end
  end

  describe "the summary drawer" do
    setup :editor_setup

    test "a tile opens it and it lists every day type with its share", context do
      world = two_day_types(context)
      view = signed_in(context, world)

      refute has_element?(view, "#runs-summary-drawer-overlay[data-open=true]")

      # The tile, not the URL: the reader clicks a tile.
      view |> element("#runs-count-strip-item-runs") |> render_click()

      assert has_element?(view, "#runs-summary-drawer-overlay[data-open=true]")

      # The share read is `start_async`, so the table is not there on the click's
      # own render. `render_async/2` settles it, and the deadline is bounded.
      render_async(view, @settle_timeout)

      assert has_element?(view, "#runs-share-table")
      refute has_element?(view, "#runs-share-loading")
      refute has_element?(view, "#runs-share-error")

      # BOTH day types, including the Saturday that has no runs at all.
      assert has_element?(view, "#runs-share-row-#{world.day_type_key}")
      saturday = Gtfs.run_day_type_shares(world.organization.id, world.version.id)

      saturday_key =
        saturday |> elem(1) |> Enum.find(&(&1.label == "Saturday")) |> Map.fetch!(:day_type_key)

      assert has_element?(view, "#runs-share-row-#{saturday_key}")

      # The loaded day type's row is the one marked selected.
      assert has_element?(
               view,
               "#runs-share-row-#{world.day_type_key}[data-selected=true]"
             )

      assert has_element?(
               view,
               "#runs-share-row-#{saturday_key}[data-selected=false]"
             )
    end

    test "a day type with no runs shows a dash for its share", context do
      world = two_day_types(context)
      view = signed_in(context, world)

      view |> element("#runs-count-strip-item-runs") |> render_click()
      render_async(view, @settle_timeout)

      saturday_key =
        world.organization.id
        |> Gtfs.run_day_type_shares(world.version.id)
        |> elem(1)
        |> Enum.find(&(&1.label == "Saturday"))
        |> Map.fetch!(:day_type_key)

      saturday_html = view |> element("#runs-share-row-#{saturday_key}") |> render()

      # Zero straight, zero split, and a dash rather than a 0% that would read as
      # a share that was calculated and came to nothing.
      assert saturday_html =~ "0"
      assert saturday_html =~ "—"
      assert saturday_html =~ "Saturday"
    end

    test "it lists the rules in use", context do
      world = two_runs(context)
      view = signed_in(context, world)

      view |> element("#runs-count-strip-item-runs") |> render_click()

      rules = view |> element("#runs-summary-rules") |> render()

      # The piece limit and the relief marks are planning inputs from the day's
      # context, not the crew settings row, and the drawer says so by naming
      # both: 330 min is "5 h 30 min" and the one marked stop is the fixture's.
      assert rules =~ "Longest piece"
      assert rules =~ "5 h 30 min"

      assert rules =~ "Relief points"
      assert rules =~ "1 marked"
      assert rules =~ world.relief_stop_id

      assert rules =~ "Report"
      assert rules =~ "15 min before a pull-out, 5 min before a relief"

      assert rules =~ "Sign-off"
      assert rules =~ "Paid break"
      assert rules =~ "30 min or less"
      assert rules =~ "12 h"
    end

    test "the day type's own figures are on screen before the share read returns", context do
      world = two_day_types(context)
      view = signed_in(context, world)

      click_html = view |> element("#runs-count-strip-item-runs") |> render_click()
      click_document = LazyHTML.from_fragment(click_html)

      # No `render_async/2` here on purpose. The point of loading the shares
      # asynchronously is that the drawer's own half is already usable. Check
      # the click response itself: later DOM reads can observe the completed task.
      assert Enum.count(LazyHTML.query(click_document, "#runs-summary-straight")) == 1
      assert Enum.count(LazyHTML.query(click_document, "#runs-summary-one-piece")) == 1
      assert Enum.count(LazyHTML.query(click_document, "#runs-summary-rules")) == 1
      assert Enum.count(LazyHTML.query(click_document, "#runs-share-loading")) == 1
    end

    test "the tile that opened the drawer is marked pressed", context do
      world = two_runs(context)
      view = signed_in(context, world)

      view |> element("#runs-count-strip-item-runs") |> render_click()

      assert has_element?(view, "#runs-count-strip-item-runs[aria-pressed=true]")

      view |> element("#runs-summary-drawer-close") |> render_click()

      assert has_element?(view, "#runs-summary-drawer-overlay[data-open=false]")
      assert has_element?(view, "#runs-count-strip-item-runs[aria-pressed=false]")
    end

    test "a different tile is the one marked pressed, and only that one", context do
      world = two_runs(context)
      view = signed_in(context, world)

      view |> element("#runs-count-strip-item-longest_spread") |> render_click()

      # The pressed tile is the one the reader pressed, not a fixed first tile.
      # If the handler ignored the clicked key this would pass with the strip
      # marking the Runs tile instead, so the Runs tile is asserted NOT pressed.
      assert has_element?(view, "#runs-count-strip-item-longest_spread[aria-pressed=true]")
      assert has_element?(view, "#runs-count-strip-item-runs[aria-pressed=false]")
    end

    test "changing day type closes the drawer", context do
      world = two_day_types(context)
      view = signed_in(context, world)

      view |> element("#runs-count-strip-item-runs") |> render_click()
      assert has_element?(view, "#runs-summary-drawer-overlay[data-open=true]")

      saturday_key =
        world.organization.id
        |> Gtfs.run_day_type_shares(world.version.id)
        |> elem(1)
        |> Enum.find(&(&1.label == "Saturday"))
        |> Map.fetch!(:day_type_key)

      view |> element("#runs-day-form") |> render_change(%{"day" => saturday_key})

      # The drawer's figures belong to the day that was open. Leaving it open
      # would put the new day's numbers under the old day's strip for as long as
      # the share read took.
      assert has_element?(view, "#runs-summary-drawer-overlay[data-open=false]")
      assert has_element?(view, "#runs-page[data-load-state=empty]")
    end

    test "a loaded day type with no runs says so, rather than showing a share of 0", context do
      # The bare fixture: it HAS blocks, so the page is `:loaded` and the strip
      # renders, but nothing is assigned, so it has no runs. That is the case the
      # "no runs" reason exists for — and it is a different string from the
      # "no run had a choice" one, because the two mean different things about
      # whether there is work to suggest.
      #
      # Note this is NOT the same as the version's Saturday day type: that one
      # has no blocks either, so the page is `:empty` and renders no strip at
      # all. A day type with no runs and a day type with no work are different
      # states, and the strip only exists in the first.
      world = seeded_world(context)
      view = signed_in(context, world)

      assert has_element?(view, "#runs-page[data-load-state=loaded]")

      assert view |> element("#runs-count-strip-item-runs") |> render() =~ "0 one piece"

      assert view |> element("#runs-count-strip-item-straight_share") |> render() =~
               "No runs in this day type"

      # The version's other day type, which has neither runs nor blocks, is the
      # `:empty` state — so the strip is absent rather than reading zero.
      two_day_types = two_day_types(context)
      saturday_view = signed_in(context, two_day_types)

      saturday_key =
        two_day_types.organization.id
        |> Gtfs.run_day_type_shares(two_day_types.version.id)
        |> elem(1)
        |> Enum.find(&(&1.label == "Saturday"))
        |> Map.fetch!(:day_type_key)

      saturday_view |> element("#runs-day-form") |> render_change(%{"day" => saturday_key})

      assert has_element?(saturday_view, "#runs-page[data-load-state=empty]")
      refute has_element?(saturday_view, "#runs-count-strip")
    end
  end

  describe "the drawer's share read failing" do
    setup :editor_setup

    # `Gtfs.run_day_type_shares/2` does not go through the catalog read adapter —
    # it calls `Runs.day_type_shares/2` directly, which opens its own transaction
    # over `Blocking.export_movements/2` and the crew rules. So unlike the page's
    # own read there is no stub to install, and the failure branch is driven by
    # rendering the component in the state `handle_async/3` produces. That is a
    # real render of the real branch; what it does not prove is that the LiveView
    # reaches it, which remains untested.
    test "renders one line and keeps the day type's own figures" do
      html =
        render_component(&RunsComponents.summary_drawer/1,
          open?: true,
          stats: %{
            runs: 0,
            by_type: %{straight: 0, split: 0, one_piece: 0},
            straight_share: nil,
            paid_secs: 0,
            vehicle_secs: 0,
            vehicle_share: nil,
            longest_spread: nil,
            uncovered: %{trips: 0, secs: 0}
          },
          crew: %{
            report_pull_out_minutes: 15,
            report_relief_minutes: 5,
            sign_off_minutes: 5,
            paid_break_max_minutes: 30,
            max_spread_minutes: 720
          },
          max_piece_minutes: nil,
          relief_stop_ids: [],
          day_label: "Weekday",
          shares_state: :failed,
          shares: []
        )

      assert html =~ ~s(id="runs-share-error")
      assert html =~ "could not load"
      refute html =~ ~s(id="runs-share-loading")
      # The one table that would be wrong to show is not shown.
      refute html =~ ~s(id="runs-share-table")
      # The drawer's own half is untouched, which is the whole point.
      assert html =~ "Runs by type"
      assert html =~ "Rules in use"
      assert html =~ "Not set"
    end
  end
end
