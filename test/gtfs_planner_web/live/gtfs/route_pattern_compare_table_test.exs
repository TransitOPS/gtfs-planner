defmodule GtfsPlannerWeb.Gtfs.RoutePatternCompareTableTest do
  @moduledoc """
  Merge evidence (EV-14) for CL-5, CL-6, CL-8 and CL-19: the compare page's
  "Stop by stop" table.

  The table streams one row per aligned visit (`#compare-rows` with
  `phx-update="stream"` and stable `compare-row-<index>` ids) and renders each
  row's lane, ring, stop meta (`visit n of m` for a repeated stop), difference
  cell and running-time cell. The difference cells come from the read: "Only in
  A/B", the linked "Order differs" pair, "Wait differs" with both waits, "No
  scheduled time" for a shared stop the timing skips, "Boarding differs" and the
  "Time covers the whole stretch from X" note on an anchor that closes a stretch
  with own stops. Above 24 rows the table opens in Differences mode with fold
  markers; a side without timings shows the "—" cells and the footer that names
  why. No control or link in the card posts an event, because the workspace hook
  owns selection, folds and hover (`INV-4`), and every time, wait and count comes
  from the read (`INV-5`).

  The fixtures use the browser seed's literal offsets, so the times are
  hand-derivable: FULL's stop 4 arrives at 570 s and departs at 630 s, SHORT
  reaches it at 510 s, and the segment that ends there is −1:00. The pre-spec-27
  schema cannot store a blank offset (`arrival_offset`/`departure_offset` are NOT
  NULL), so the untimed-stop fixture is the shape the read will see then: an
  occurrence without a timing row, which `RoutePatterns.timing_rows/2` and
  `Alignment` both read as no scheduled time.

  Every case enters through ordinary login and the real `CatalogReadAdapter.Repo`
  on the local test database (`CR-7`); no adapter is substituted. The focused
  gate command is deferred to branch review:

      MIX_ENV=test MIX_TEST_PARTITION=_s19 ELIXIR_ERL_OPTIONS="+S 4" gtimeout --signal=TERM --kill-after=10s 120s mix test test/gtfs_planner_web/live/gtfs/route_pattern_compare_table_test.exs
  """

  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Repo

  defp editor_scope(%{conn: conn}) do
    organization =
      organization_fixture(%{
        alias: "route-pattern-compare-table-#{System.system_time(:nanosecond)}"
      })

    user =
      user_fixture(%{
        email: "pattern-compare-table-#{System.unique_integer([:positive])}@example.com"
      })

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)
    conn = log_in_user(conn, user, organization: organization)

    %{conn: conn, user: user, organization: organization, version: version}
  end

  defp route(organization, version, route_id) do
    route_fixture(organization.id, version.id, %{
      route_id: route_id,
      route_short_name: route_id,
      route_long_name: "#{route_id} corridor"
    })
  end

  defp stop(organization, version, stop_id, stop_name) do
    stop_fixture(organization.id, version.id, %{
      stop_id: stop_id,
      stop_name: stop_name,
      location_type: 0
    })
  end

  defp schedule_pattern(organization, version, route, attrs, stops) do
    schedule_pattern_fixture(organization.id, version.id, %{
      route_id: route.route_id,
      route_pattern_id: attrs.id,
      route_pattern_name: attrs.name,
      direction_id: Map.get(attrs, :direction, 0),
      route_pattern_typicality: 1,
      route_pattern_sort_order: Map.get(attrs, :sort, 0),
      timing_name: Map.get(attrs, :timing, "Weekday base"),
      stops: stops
    })
  end

  # A pattern with occurrences but no named timing at all: the read returns no
  # timing id and nil rows, which is the "running times: None yet" side (AC-8).
  defp untimed_pattern(organization, version, route, attrs, stop_ids) do
    pattern =
      route_pattern_fixture(organization.id, version.id, %{
        route_id: route.route_id,
        route_pattern_id: attrs.id,
        route_pattern_name: attrs.name,
        direction_id: 0,
        route_pattern_typicality: 1,
        route_pattern_sort_order: Map.get(attrs, :sort, 0)
      })

    stop_ids
    |> Enum.with_index(1)
    |> Enum.each(fn {stop_id, position} ->
      route_pattern_stop_fixture(pattern, stop_id, position)
    end)

    pattern
  end

  # Route TBL1 with the browser seed's literals: FULL is the six-stop reference
  # whose fourth stop waits 60 s, DEV replaces its third stop with two stops,
  # SHORT ends at the fourth stop one minute quicker over that stretch, LOOP
  # visits the first two stops twice, MOVED serves stop 3 before stop 2, and
  # UNTIMED_END is FULL with the last occurrence's timing row removed (see the
  # moduledoc). NO_TIMES has no timing at all. Routes TBL2 and TBL3 carry the
  # long (34 visits) and medium (13 visits) fixtures for the mode default.
  defp comparison_routes(%{organization: organization, version: version}) do
    route = route(organization, version, "TBL1")

    Enum.each([1, 2, 3, 4, 5, 6], fn index ->
      stop(organization, version, "TBL1_S#{index}", "TBL1 Stop #{index}")
    end)

    stop(organization, version, "TBL1_S3A", "TBL1 Stop 3A")
    stop(organization, version, "TBL1_S3B", "TBL1 Stop 3B")

    calendar_fixture(organization.id, version.id, %{service_id: "WEEKDAY"})

    calendar_attribute_fixture(organization.id, version.id, %{
      service_id: "WEEKDAY",
      service_description: "Weekday"
    })

    full =
      schedule_pattern(
        organization,
        version,
        route,
        %{id: "FULL", name: "Full"},
        [
          {"TBL1_S1", 0, 0, 1},
          {"TBL1_S2", 180, 180, 0},
          {"TBL1_S3", 360, 360, 0},
          {"TBL1_S4", 570, 570, 1},
          {"TBL1_S5", 870, 870, 0},
          {"TBL1_S6", 1110, 1110, 1}
        ]
      )

    # FULL with the browser seed's 60 s timepoint wait at stop 4, so the
    # short-turn segment that ends there is −1:00 (R5) and the wait is not
    # charged to the segment.
    _wait =
      schedule_pattern(
        organization,
        version,
        route,
        %{id: "WAIT", name: "Wait", sort: 7},
        [
          {"TBL1_S1", 0, 0, 1},
          {"TBL1_S2", 180, 180, 0},
          {"TBL1_S3", 360, 360, 0},
          {"TBL1_S4", 570, 630, 1},
          {"TBL1_S5", 870, 870, 0},
          {"TBL1_S6", 1110, 1110, 1}
        ]
      )

    dev =
      schedule_pattern(
        organization,
        version,
        route,
        %{id: "DEV", name: "Deviation", sort: 1},
        [
          {"TBL1_S1", 0, 0, 1},
          {"TBL1_S2", 180, 180, 0},
          {"TBL1_S3A", 600, 600, 0},
          {"TBL1_S3B", 900, 900, 0},
          {"TBL1_S4", 1290, 1290, 1},
          {"TBL1_S5", 1590, 1590, 0},
          {"TBL1_S6", 1830, 1830, 1}
        ]
      )

    short =
      schedule_pattern(
        organization,
        version,
        route,
        %{id: "SHORT", name: "Short turn", sort: 2, timing: "Weekday short"},
        [
          {"TBL1_S1", 0, 0, 1},
          {"TBL1_S2", 180, 180, 0},
          {"TBL1_S3", 360, 360, 0},
          {"TBL1_S4", 510, 510, 1}
        ]
      )

    loop =
      schedule_pattern(
        organization,
        version,
        route,
        %{id: "LOOP", name: "Loop", sort: 3},
        [
          {"TBL1_S1", 0, 0, 1},
          {"TBL1_S2", 240, 240, 0},
          {"TBL1_S3", 480, 480, 0},
          {"TBL1_S4", 720, 720, 1},
          {"TBL1_S1", 960, 960, 0},
          {"TBL1_S2", 1200, 1200, 1}
        ]
      )

    moved =
      schedule_pattern(
        organization,
        version,
        route,
        %{id: "MOVED", name: "Moved", sort: 4},
        [
          {"TBL1_S1", 0, 0, 1},
          {"TBL1_S3", 240, 240, 0},
          {"TBL1_S2", 480, 480, 0},
          {"TBL1_S4", 720, 720, 1},
          {"TBL1_S5", 1020, 1020, 0},
          {"TBL1_S6", 1260, 1260, 1}
        ]
      )

    untimed_end =
      schedule_pattern(
        organization,
        version,
        route,
        %{id: "UNTIMED_END", name: "Untimed end", sort: 5},
        [
          {"TBL1_S1", 0, 0, 1},
          {"TBL1_S2", 180, 180, 0},
          {"TBL1_S3", 360, 360, 0},
          {"TBL1_S4", 570, 570, 1},
          {"TBL1_S5", 870, 870, 0},
          {"TBL1_S6", 1110, 1110, 1}
        ]
      )

    Repo.delete!(List.last(untimed_end.rows))

    _no_times =
      untimed_pattern(
        organization,
        version,
        route,
        %{id: "NO_TIMES", name: "No times", sort: 6},
        ["TBL1_S1", "TBL1_S2", "TBL1_S3", "TBL1_S4", "TBL1_S5", "TBL1_S6"]
      )

    long = route(organization, version, "TBL2")

    Enum.each(1..34, fn index ->
      stop(organization, version, "TBL2_L#{index}", "TBL2 Stop #{index}")
    end)

    long_stops =
      Enum.map(1..34, fn index -> {"TBL2_L#{index}", index * 60, index * 60, timepoint(index)} end)

    Enum.each(["LONG_A", "LONG_B"], fn id ->
      schedule_pattern(organization, version, long, %{id: id, name: id}, long_stops)
    end)

    mid = route(organization, version, "TBL3")

    Enum.each(1..13, fn index ->
      stop(organization, version, "TBL3_M#{index}", "TBL3 Stop #{index}")
    end)

    mid_stops =
      Enum.map(1..13, fn index -> {"TBL3_M#{index}", index * 60, index * 60, timepoint(index)} end)

    Enum.each(["MID_A", "MID_B"], fn id ->
      schedule_pattern(organization, version, mid, %{id: id, name: id}, mid_stops)
    end)

    %{
      route: route,
      long_route: long,
      mid_route: mid,
      full: full,
      dev: dev,
      short: short,
      loop: loop,
      moved: moved
    }
  end

  defp timepoint(1), do: 1
  defp timepoint(34), do: 1
  defp timepoint(13), do: 1
  defp timepoint(_index), do: 0

  defp compare_path(version, route, params) do
    base = "/gtfs/#{version.id}/routes/#{route.route_id}/patterns/compare"

    case Enum.reject(params, fn {_key, value} -> is_nil(value) end) do
      [] -> base
      params -> base <> "?" <> URI.encode_query(params)
    end
  end

  defp row_html(view, selector), do: view |> element(selector) |> render()

  defp count_matches(html, regex), do: length(Regex.scan(regex, html))

  # A moved row of one side links to the other side's visit.
  defp other_letter("a"), do: "B"
  defp other_letter("b"), do: "A"

  defp stop_ids_in_order(html) do
    ~r/<tr[^>]*data-stop-id="([^"]+)"/
    |> Regex.scan(html)
    |> Enum.map(fn [_, stop_id] -> stop_id end)
  end

  describe "rows, lanes and difference cells" do
    setup :editor_scope

    test "the replacement renders every row in order with its own difference cell",
         %{conn: conn, version: version} = context do
      %{route: route} = comparison_routes(context)

      {:ok, view, _html} =
        live(conn, compare_path(version, route, %{"a" => "FULL", "b" => "DEV"}))

      html = render(view)

      assert has_element?(view, "#compare-rows[phx-update='stream']")
      assert has_element?(view, "#compare-rows #compare-row-0[data-row='0']")
      assert has_element?(view, "#compare-rows #compare-row-7[data-row='7']")
      refute has_element?(view, "#compare-rows #compare-row-8")

      assert stop_ids_in_order(html) ==
               ~w(TBL1_S1 TBL1_S2 TBL1_S3 TBL1_S3A TBL1_S3B TBL1_S4 TBL1_S5 TBL1_S6)

      assert has_element?(view, "#compare-row-2", "Only in")
      assert has_element?(view, "#compare-row-2", "B doesn’t stop here")
      assert count_matches(html, ~r/data-type="a"/) == 1
      assert count_matches(html, ~r/data-type="b"/) == 2
      assert row_html(view, "#compare-row-2") =~ ~r/Only in\s*<span[^>]*>\s*A\s*<\/span>/
      assert row_html(view, "#compare-row-3") =~ ~r/Only in\s*<span[^>]*>\s*B\s*<\/span>/
      assert row_html(view, "#compare-row-4") =~ ~r/Only in\s*<span[^>]*>\s*B\s*<\/span>/

      # The stretch from S2 to S4 spans DEV's own stops, so the anchor that
      # closes it says which stop the time is measured from (AC-19).
      assert has_element?(
               view,
               "#compare-row-5",
               "Time covers the whole stretch from TBL1 Stop 2"
             )

      assert row_html(view, "#compare-row-5") =~ "6:30"
      assert row_html(view, "#compare-row-5") =~ "18:30"
      assert row_html(view, "#compare-row-5") =~ "+12:00"

      # S1 is a timepoint in FULL, so its meta line names it; S3A is not.
      assert row_html(view, "#compare-row-0") =~ "Stop TBL1_S1 · timepoint"
      refute row_html(view, "#compare-row-3") =~ "timepoint"

      # Every control and link in the card is inert: the workspace hook owns
      # selection, folds and hover (INV-4, FH-25).
      card = row_html(view, "#compare-stops")
      refute card =~ "phx-click"
      refute card =~ "phx-change"
      refute card =~ "phx-submit"
    end

    test "the loop labels its second visit of a repeated stop",
         %{conn: conn, version: version} = context do
      %{route: route} = comparison_routes(context)

      {:ok, view, _html} =
        live(conn, compare_path(version, route, %{"a" => "FULL", "b" => "LOOP"}))

      assert has_element?(
               view,
               "#compare-rows tr[data-stop-id='TBL1_S1'][data-type='b']",
               "visit 2 of 2"
             )

      assert has_element?(
               view,
               "#compare-rows tr[data-stop-id='TBL1_S2'][data-type='b']",
               "visit 2 of 2"
             )

      # A stop visited once has no visit label.
      refute has_element?(view, "#compare-row-2", "visit")
    end

    test "the moved pair links both rows to each other",
         %{conn: conn, version: version} = context do
      %{route: route} = comparison_routes(context)

      {:ok, view, _html} =
        live(conn, compare_path(version, route, %{"a" => "FULL", "b" => "MOVED"}))

      moved =
        ~r/data-row="(\d+)"[^>]*data-type="([ab])"[^>]*data-moved-row="(\d+)"/
        |> Regex.scan(render(view))
        |> Enum.map(fn [_, row, type, target] ->
          {String.to_integer(row), type, String.to_integer(target)}
        end)

      assert [{first, first_type, target}, {second, second_type, back}] = moved
      assert first == back
      assert second == target
      assert first_type != second_type

      assert has_element?(view, "tr[data-row='#{first}']", "Order differs")
      assert has_element?(view, "tr[data-row='#{second}']", "Order differs")
      assert has_element?(view, "tr[data-row='#{first}']", "Stop 3 in A · stop 2 in B")

      assert has_element?(
               view,
               "tr[data-row='#{first}'] a[data-goto-row='#{target}']",
               "Go to #{other_letter(first_type)}’s visit"
             )

      assert has_element?(
               view,
               "tr[data-row='#{second}'] a[data-goto-row='#{back}']",
               "Go to #{other_letter(second_type)}’s visit"
             )
    end

    test "the short turn reports −1:00 at the shared end stop and no wait there",
         %{conn: conn, version: version} = context do
      %{route: route} = comparison_routes(context)

      {:ok, view, _html} =
        live(conn, compare_path(version, route, %{"a" => "WAIT", "b" => "SHORT"}))

      # WAIT's stop 4 departs at 570 s against SHORT's 510 s from stop 3's 360 s:
      # 210 s against 150 s, so B is 60 s quicker (R5).
      assert has_element?(view, "#compare-rows tr[data-stop-id='TBL1_S4']", "−1:00")

      # Stop 4 is B's last visit, so its 60 s wait is not reported here; the
      # segment is direct, so no stretch note either.
      refute has_element?(view, "#compare-rows tr[data-stop-id='TBL1_S4']", "Wait differs")
      refute has_element?(view, "#compare-rows tr[data-stop-id='TBL1_S4']", "Time covers")

      # The trailing A-only stops carry neither times nor notes.
      assert has_element?(view, "#compare-rows tr[data-stop-id='TBL1_S5']", "Only in")
      refute has_element?(view, "#compare-rows tr[data-stop-id='TBL1_S5']", "Time covers")
    end

    test "a differing wait at an interior anchor shows both waits",
         %{conn: conn, version: version} = context do
      %{route: route} = comparison_routes(context)

      {:ok, view, _html} =
        live(conn, compare_path(version, route, %{"a" => "FULL", "b" => "WAIT"}))

      # WAIT holds 60 s at stop 4; stop 4 is neither side's first or last visit,
      # so the difference is reported as a wait and not folded into the segment.
      assert has_element?(view, "#compare-rows tr[data-stop-id='TBL1_S4']", "Wait differs")
      assert row_html(view, "#compare-rows tr[data-stop-id='TBL1_S4']") =~ "A 0:00 · B 1:00"

      # The next segment is measured from the later departure, so it is 1:00
      # shorter on the wait side (R5).
      assert has_element?(view, "#compare-rows tr[data-stop-id='TBL1_S5']", "−1:00")
      refute has_element?(view, "#compare-rows tr[data-stop-id='TBL1_S5']", "Wait differs")
    end

    test "a shared stop without a scheduled time says so and gets no time cell",
         %{conn: conn, version: version} = context do
      %{route: route} = comparison_routes(context)

      {:ok, view, _html} =
        live(conn, compare_path(version, route, %{"a" => "FULL", "b" => "UNTIMED_END"}))

      assert has_element?(view, "#compare-rows tr[data-stop-id='TBL1_S6']", "No scheduled time")

      untimed = row_html(view, "#compare-rows tr[data-stop-id='TBL1_S6']")
      refute untimed =~ "—"
      refute untimed =~ ~r/\d+:\d\d/

      # The stop before it is still an anchor with its own time cell.
      assert row_html(view, "#compare-rows tr[data-stop-id='TBL1_S5']") =~ "5:00"
    end
  end

  describe "rows without comparable times" do
    setup :editor_scope

    test "B without timings shows the — cells and the footer explanation",
         %{conn: conn, version: version} = context do
      %{route: route} = comparison_routes(context)

      {:ok, view, _html} =
        live(conn, compare_path(version, route, %{"a" => "FULL", "b" => "NO_TIMES"}))

      assert has_element?(view, "#compare-stops", "B vs A")
      assert has_element?(view, "#compare-rows tr[data-stop-id='TBL1_S1']", "—")

      assert has_element?(
               view,
               "#stops-footer",
               "B has no running times yet, so no running times are compared. — means no time."
             )

      # A side without timings is not the same as an untimed shared stop.
      refute has_element?(view, "#compare-stops", "No scheduled time")
      refute has_element?(view, "#compare-stops", "Wait differs")
    end
  end

  describe "rows mode, folds and the stream" do
    setup :editor_scope

    test "34 rows open in Differences mode with folded matching runs",
         %{conn: conn, version: version} = context do
      %{long_route: long_route} = comparison_routes(context)

      {:ok, view, _html} =
        live(conn, compare_path(version, long_route, %{"a" => "LONG_A", "b" => "LONG_B"}))

      assert has_element?(view, "#compare-stops[data-mode='diff']")
      assert has_element?(view, "#stops-mode-diff[aria-pressed='true']")
      assert has_element?(view, "#compare-rows #compare-row-33[data-row='33']")
      refute has_element?(view, "#compare-rows #compare-row-34")

      assert has_element?(view, "#compare-rows tr[data-fold='1-32'] button[data-unfold='1-32']")
      assert has_element?(view, "#compare-rows tr[data-fold='1-32']", "Show 32 matching stops")

      assert has_element?(
               view,
               "#compare-rows tr[data-fold='1-32']",
               "TBL2 Stop 2 to TBL2 Stop 33"
             )

      assert has_element?(view, "#compare-rows tr[data-fold-range='1-32'][hidden]")

      # Identical stop lists have no difference to step through.
      assert has_element?(view, "#stops-position", "No differences")
      assert has_element?(view, "#stops-next[disabled]")
    end

    test "13 rows open in All stops mode with the fold still available",
         %{conn: conn, version: version} = context do
      %{mid_route: mid_route} = comparison_routes(context)

      {:ok, view, _html} =
        live(conn, compare_path(version, mid_route, %{"a" => "MID_A", "b" => "MID_B"}))

      assert has_element?(view, "#compare-stops[data-mode='all']")
      assert has_element?(view, "#stops-mode-all[aria-pressed='true']")
      assert has_element?(view, "#compare-rows #compare-row-12[data-row='12']")

      # The fold marker is in the markup, hidden until the hook switches modes.
      assert has_element?(view, "#compare-rows tr[data-fold='1-11'][hidden]")
      refute has_element?(view, "#compare-rows tr[data-fold-range='1-11'][hidden]")
    end

    test "the stream resets on every load instead of appending",
         %{conn: conn, version: version} = context do
      %{route: route} = comparison_routes(context)

      {:ok, view, _html} =
        live(conn, compare_path(version, route, %{"a" => "FULL", "b" => "DEV"}))

      assert count_matches(render(view), ~r/id="compare-row-\d+"/) == 8

      view
      |> element("#compare-calendar")
      |> render_change(%{"service" => "WEEKDAY"})

      html = render(view)
      assert count_matches(html, ~r/id="compare-row-\d+"/) == 8

      assert stop_ids_in_order(html) ==
               ~w(TBL1_S1 TBL1_S2 TBL1_S3 TBL1_S3A TBL1_S3B TBL1_S4 TBL1_S5 TBL1_S6)
    end

    test "the choose-B state lists A's stops in the stop card",
         %{conn: conn, version: version} = context do
      %{route: route} = comparison_routes(context)

      {:ok, view, _html} = live(conn, compare_path(version, route, %{"a" => "FULL"}))

      assert has_element?(view, "#compare-stops", "Stops in A")
      assert has_element?(view, "#compare-stops", "TBL1 Stop 1")
      assert has_element?(view, "#compare-stops", "TBL1 Stop 6")
      refute has_element?(view, "#compare-rows[phx-update='stream']")
    end
  end
end
