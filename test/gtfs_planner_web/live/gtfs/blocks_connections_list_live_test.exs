defmodule GtfsPlannerWeb.Gtfs.BlocksConnectionsListLiveTest do
  @moduledoc """
  Merge evidence (EV-22) for the Connections list panel (R12, R13, AC-11,
  AC-12, CL-10, rejects FH-11):

  - One section per place in R12 order, and one row per group carrying the two
    route badges, "continues as" or "Turns back", the arrival stop, the handoff,
    the wait range, the count and each non-zero setting count with its icon.
  - The Show, Route and Find filters each narrow the list to the connections
    `Blocking.Connections` keeps, and each active filter shows a removable chip
    that removes only itself; Clear filters removes all three.
  - A day whose filters drop every connection says "No connections match" and
    offers the filters back; a day holding no connections at all says "No
    connections yet" and offers the one step that creates them.
  - 51 groups page into 50 and 1 under `gpage`, and the pager's own numbers come
    from `Blocking.Connections.page/3`.
  - The summary reads "{k} of {total} connections at {p} places" from the same
    derived assigns the sections read.

  Every case runs through the ordinary `/gtfs/:version/blocks` route on the
  production `CatalogReadAdapter.Repo` and the scoped `Blocking` context, so the
  sections, the order and the counts under the filters are the ones
  `Blocking.Connections` derived from the loaded day rather than values this
  module reconstructs.

  The seeded days are deliberately small. The three-place day holds one block per
  place, with a single type 4 record on the first pair (R13's quiet `:stay`), a
  type 4 and a stopless type 5 record on the second (R13's `:conflict`, which needs
  review) and no record at all on the third, so every mark a row can show is
  reachable from stored rows. The two-route day puts its two pairs on disjoint
  routes so a Route filter has something to drop, and the paged day seeds 51
  one-group places to exercise `gpage`.

  The focused gate command is deferred to branch review:
  `MIX_TEST_PARTITION=_seat11 gtimeout --signal=TERM --kill-after=10s 120s mix test test/gtfs_planner_web/live/gtfs/blocks_connections_list_live_test.exs`.

  `async: false` because these cases share the lane database.
  """
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.Blocking.Connections

  @weekday_dates [~D[2026-09-01], ~D[2026-09-02], ~D[2026-09-03]]

  setup do
    organization = organization_fixture()
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)

    twelve =
      route_fixture(organization.id, version.id, %{route_id: "R12", route_short_name: "12"})

    twenty_four =
      route_fixture(organization.id, version.id, %{route_id: "R24", route_short_name: "24"})

    # A route the version carries but no connection runs on, so the Route filter
    # can narrow to none without the page refusing a route it does not know.
    lonely =
      route_fixture(organization.id, version.id, %{route_id: "R50", route_short_name: "50"})

    calendar_service_fixture(organization.id, version.id, %{
      service_id: "W",
      name: "Weekday",
      dates: @weekday_dates
    })

    %{
      organization: organization,
      user: user,
      version: version,
      route_twelve: twelve,
      route_twenty_four: twenty_four,
      route_lonely: lonely
    }
  end

  defp blocks_path(version_id), do: "/gtfs/#{version_id}/blocks"

  defp editor_conn(context) do
    log_in_user(context.conn, context.user, organization: context.organization)
  end

  defp connections_url(version_id, params) do
    blocks_path(version_id) <> "?" <> URI.encode_query(params)
  end

  # The Connections view on the URL the case names. Every case names one, so the
  # path is always the query form and a quiet URL is not a second code path here.
  defp mount_connections(context, params) do
    live(editor_conn(context), connections_url(context.version.id, params))
  end

  # The day's own groups, read through the production derivation the panel reads,
  # so a case can name the group it means by its own token rather than by a token
  # this module guesses.
  defp derived_groups(context) do
    {:ok, day} =
      GtfsPlanner.Gtfs.load_blocking_day(context.organization.id, context.version.id, nil)

    Connections.build(day).groups
  end

  # The stop the derived group at `place_name` is decided at, as the DOM-safe
  # token the panel encodes it into.
  defp place_token(context, place_name) do
    context.stops
    |> Enum.find_value(fn stop -> if stop.stop_name == place_name, do: stop.stop_id end)
    |> Base.url_encode64(padding: false)
  end

  # A service day's stop, named for the place the derived group is decided at.
  defp place_stop(context, name, opts \\ []) do
    stop_fixture(context.organization.id, context.version.id, %{
      stop_id: "CONN_LIST_#{System.unique_integer([:positive])}",
      stop_name: name,
      stop_lat: Decimal.new(Keyword.get(opts, :lat, "40.0000")),
      stop_lon: Decimal.new(Keyword.get(opts, :lon, "-74.0000"))
    })
  end

  # One block's pair of consecutive trips meeting at `stop`, so the pair is a
  # connection and the two trips' routes and directions are the group's key. The
  # `from_stop` defaults to the `:stop` the caller names, and both trips end and
  # start there unless a caller names two stops for a handoff.
  defp block_pair(context, attrs) do
    stop = Map.fetch!(attrs, :stop)
    from_stop = Map.get(attrs, :from_stop, stop)
    to_stop = Map.get(attrs, :to_stop, stop)

    from_route = Map.get(attrs, :from_route, context.route_twelve)
    to_route = Map.get(attrs, :to_route, context.route_twenty_four)
    block_id = Map.fetch!(attrs, :block_id)
    suffix = Map.fetch!(attrs, :suffix)
    first = Map.fetch!(attrs, :first)

    from =
      blocked_trip_fixture(context.organization.id, context.version.id, from_route.route_id, %{
        service_id: "W",
        trip_id: "#{block_id}-#{suffix}-a",
        block_id: block_id,
        direction_id: Map.get(attrs, :from_direction, 0),
        trip_headsign: Map.get(attrs, :from_headsign, "North"),
        first_stop: from_stop.stop_id,
        last_stop: from_stop.stop_id,
        first_arrival: clock(first),
        last_arrival: clock(first + 3_600)
      })

    to =
      blocked_trip_fixture(context.organization.id, context.version.id, to_route.route_id, %{
        service_id: "W",
        trip_id: "#{block_id}-#{suffix}-b",
        block_id: block_id,
        direction_id: Map.get(attrs, :to_direction, 0),
        trip_headsign: Map.get(attrs, :to_headsign, "South"),
        first_stop: to_stop.stop_id,
        last_stop: to_stop.stop_id,
        first_arrival: clock(first + 4_200),
        last_arrival: clock(first + 7_800)
      })

    %{from: from, to: to}
  end

  # Seconds since midnight as the `HH:MM:SS` a stop time stores. Every fixture
  # block here starts at or after 05:00 and runs an hour and a half, so the last
  # one of a paged day still lands inside the same service day.
  defp clock(seconds) do
    [div(seconds, 3_600), div(rem(seconds, 3_600), 60), rem(seconds, 60)]
    |> Enum.map_join(":", &pad_clock/1)
  end

  defp pad_clock(part), do: part |> Integer.to_string() |> String.pad_leading(2, "0")

  # A type 4 record on the pair, which the day load evaluates over every day type
  # both trips run in.
  defp stay_record(context, pair) do
    in_seat_transfer_fixture(context.organization.id, context.version.id, pair.from, pair.to)
  end

  # A type 5 record on the same pair beside its type 4 record. The two rows differ
  # in transfer type, so the version's own unique index keeps both and R13 reads
  # the pair as a conflict that needs review.
  defp reboard_record(context, pair) do
    transfer_fixture(context.organization.id, context.version.id, %{
      from_trip_id: pair.from.trip_id,
      to_trip_id: pair.to.trip_id,
      transfer_type: 5
    })
  end

  # Three places and three blocks, one pair each: Alpha's pair holds a single
  # type 4 record (R13's quiet `:stay`), Beta's holds a type 4 and a type 5 record
  # (R13's `:conflict`, which needs review) and Gamma's holds none at all.
  defp three_place_day(context) do
    alpha = place_stop(context, "Alpha Yard", lat: "40.1000", lon: "-74.1000")
    beta = place_stop(context, "Beta Yard", lat: "40.2000", lon: "-74.2000")
    gamma = place_stop(context, "Gamma Yard", lat: "40.3000", lon: "-74.3000")

    stay = block_pair(context, %{stop: alpha, block_id: "101", suffix: "s", first: 21_600})
    stay_record(context, stay)

    conflict = block_pair(context, %{stop: beta, block_id: "202", suffix: "c", first: 21_600})
    stay_record(context, conflict)
    reboard_record(context, conflict)

    plain = block_pair(context, %{stop: gamma, block_id: "303", suffix: "p", first: 21_600})

    context
    |> Map.put(:stops, [alpha, beta, gamma])
    |> Map.put(:stay_pair, stay)
    |> Map.put(:conflict_pair, conflict)
    |> Map.put(:plain_pair, plain)
  end

  describe "the sections and the rows" do
    test "one section per place, in R12 order, each row carrying the group's facts", context do
      context = three_place_day(context)

      {:ok, view, _html} = mount_connections(context, view: "connections")

      # Alpha holds one group of one connection and Beta one of one, so R12's
      # count-descending tie breaks on the place name and Gamma — whose pair holds
      # no record — is last on its own count of one.
      sections = section_ids(view)

      assert sections == [
               "connections-place-#{place_token(context, "Alpha Yard")}",
               "connections-place-#{place_token(context, "Beta Yard")}",
               "connections-place-#{place_token(context, "Gamma Yard")}"
             ]

      assert has_element?(
               view,
               "#connections-place-#{place_token(context, "Alpha Yard")}",
               "Alpha Yard"
             )

      assert has_element?(
               view,
               "#connections-place-#{place_token(context, "Gamma Yard")}",
               "Gamma Yard"
             )
    end

    test "a group row shows both badges, the continuation, the stop, the handoff and the wait",
         context do
      context = three_place_day(context)
      [alpha_group | _rest] = derived_groups(context)

      {:ok, view, _html} = mount_connections(context, view: "connections")

      row = "#connections-group-#{alpha_group.token}"

      assert has_element?(view, row, "continues as 24")
      assert has_element?(view, row, "to South")
      assert has_element?(view, row, "Alpha Yard")
      assert has_element?(view, row, "Same stop")
      assert has_element?(view, row, "10 min")
      assert has_element?(view, row, "stay on board")
      assert has_element?(view, "#{row} .connections-mark-stay", "1")
    end

    test "a group's count is the connections it holds on this page", context do
      context = three_place_day(context)
      [alpha_group | _rest] = derived_groups(context)

      {:ok, view, _html} = mount_connections(context, view: "connections")

      assert has_element?(view, "#connections-group-count-#{alpha_group.token}", "1")
    end

    test "a turnback row says Turns back rather than naming a route", context do
      context =
        three_place_day(context)
        |> turnback_pair()

      [turnback_group] = derived_groups(context) |> Enum.filter(& &1.turnback?)

      {:ok, view, _html} = mount_connections(context, view: "connections")

      assert has_element?(view, "#connections-group-#{turnback_group.token}", "Turns back")
      refute has_element?(view, "#connections-group-#{turnback_group.token}", "continues as")
    end

    test "a group with no records shows no setting mark at all", context do
      context = three_place_day(context)
      [gamma_group] = derived_groups(context) |> Enum.filter(&(&1.place.name == "Gamma Yard"))

      {:ok, view, _html} = mount_connections(context, view: "connections")

      refute has_element?(view, "#connections-group-#{gamma_group.token} .connections-mark")
    end

    test "a conflict pair shows its review mark beside no stay or re-board mark", context do
      context = three_place_day(context)
      [beta_group] = derived_groups(context) |> Enum.filter(&(&1.place.name == "Beta Yard"))

      {:ok, view, _html} = mount_connections(context, view: "connections")

      assert has_element?(
               view,
               "#connections-group-#{beta_group.token} .connections-mark-review",
               "1"
             )

      refute has_element?(view, "#connections-group-#{beta_group.token} .connections-mark-stay")

      refute has_element?(
               view,
               "#connections-group-#{beta_group.token} .connections-mark-reboard"
             )
    end

    test "the summary reads the filtered count of the day's connections at its places", context do
      three_place_day(context)

      {:ok, view, _html} = mount_connections(context, view: "connections")

      assert has_element?(view, "#connections-summary", "3 of 3 connections at 3 places")
    end
  end

  describe "the filters" do
    test "Show = Needs review keeps only the groups holding a connection needing review",
         context do
      context = three_place_day(context)
      [beta_group] = derived_groups(context) |> Enum.filter(&(&1.place.name == "Beta Yard"))
      [alpha_group | _rest] = derived_groups(context)

      {:ok, view, _html} = mount_connections(context, view: "connections", setting: "review")

      assert has_element?(view, "#connections-group-#{beta_group.token}")
      refute has_element?(view, "#connections-group-#{alpha_group.token}")
      assert has_element?(view, "#connections-summary", "1 of 3 connections at 1 place")
    end

    test "Show = Riders stay on board keeps the quiet stay pair and not the conflict", context do
      context = three_place_day(context)
      [alpha_group | _rest] = derived_groups(context)
      [beta_group] = derived_groups(context) |> Enum.filter(&(&1.place.name == "Beta Yard"))

      {:ok, view, _html} = mount_connections(context, view: "connections", setting: "stay")

      assert has_element?(view, "#connections-group-#{alpha_group.token}")
      refute has_element?(view, "#connections-group-#{beta_group.token}")
    end

    test "the Route filter keeps only the connections running on that route", context do
      context = two_route_day(context)

      [on_twelve | _rest] =
        derived_groups(context) |> Enum.filter(&(&1.place.name == "Alpha Yard"))

      [on_fifty] = derived_groups(context) |> Enum.filter(&(&1.place.name == "Beta Yard"))

      {:ok, view, _html} =
        mount_connections(context, view: "connections", route: context.route_twelve.route_id)

      assert has_element?(view, "#connections-group-#{on_twelve.token}")
      refute has_element?(view, "#connections-group-#{on_fifty.token}")
      assert has_element?(view, "#connections-summary", "1 of 2 connections at 1 place")
    end

    test "a Route the version carries but no connection runs on narrows to none", context do
      context = three_place_day(context)

      # R50 runs a trip in the loaded day, so the page offers it and keeps the
      # filter rather than dropping it as a route the day does not carry, but no
      # connection does: the filter narrows to none.
      lonely_stop = place_stop(context, "Lonely Yard", lat: "40.6000", lon: "-74.6000")

      lonely_trip =
        trip_fixture(
          context.organization.id,
          context.version.id,
          context.route_lonely.route_id,
          %{service_id: "W", trip_id: "lonely"}
        )

      stop_time_fixture(
        context.organization.id,
        context.version.id,
        lonely_trip.trip_id,
        lonely_stop.stop_id,
        %{stop_sequence: 1, arrival_time: "06:00:00", departure_time: "06:00:00"}
      )

      {:ok, view, _html} =
        mount_connections(context, view: "connections", route: context.route_lonely.route_id)

      assert has_element?(view, "#connections-no-match-text")
      assert has_element?(view, "#connections-summary", "0 of 3 connections at 0 places")
    end

    test "Find matches a block id, so the search keeps only that block's connections", context do
      context = three_place_day(context)
      [alpha_group | _rest] = derived_groups(context)

      {:ok, view, _html} = mount_connections(context, view: "connections", cq: "block 101")

      assert has_element?(view, "#connections-group-#{alpha_group.token}")
      assert has_element?(view, "#connections-summary", "1 of 3 connections at 1 place")
    end

    test "the Show, Route and Find controls patch their own parameters", context do
      three_place_day(context)

      {:ok, view, _html} = mount_connections(context, view: "connections")

      render_change(view, "filter_connections", %{
        "setting" => "stay",
        "cq" => "block 101",
        "route" => context.route_twelve.route_id
      })

      assert_patch(
        view,
        connections_url(context.version.id,
          view: "connections",
          route: context.route_twelve.route_id,
          setting: "stay",
          cq: "block 101"
        )
      )
    end
  end

  describe "the chips" do
    test "each active filter shows a chip naming it", context do
      three_place_day(context)

      {:ok, view, _html} =
        mount_connections(context,
          view: "connections",
          setting: "review",
          route: context.route_twenty_four.route_id,
          cq: "block 101"
        )

      assert has_element?(view, "#connections-chip-setting", "Needs review")
      assert has_element?(view, "#connections-chip-route", "Route R24")
      assert has_element?(view, "#connections-chip-q", "block 101")
    end

    test "a filter the reader has not set shows no chip and no Clear filters", context do
      three_place_day(context)

      {:ok, view, _html} = mount_connections(context, view: "connections")

      refute has_element?(view, "#connections-chip-setting")
      refute has_element?(view, "#connections-clear-filters")
    end

    test "a chip removes only the filter it names", context do
      three_place_day(context)

      {:ok, view, _html} =
        mount_connections(context,
          view: "connections",
          setting: "review",
          route: context.route_twenty_four.route_id,
          cq: "block 101"
        )

      render_click(view, "remove_connection_filter", %{"filter" => "setting"})

      assert_patch(
        view,
        connections_url(context.version.id,
          view: "connections",
          route: context.route_twenty_four.route_id,
          cq: "block 101"
        )
      )

      refute has_element?(view, "#connections-chip-setting")
      assert has_element?(view, "#connections-chip-route")
    end

    test "the q chip removes the search and keeps the other two", context do
      three_place_day(context)

      {:ok, view, _html} =
        mount_connections(context, view: "connections", setting: "review", cq: "block 101")

      render_click(view, "remove_connection_filter", %{"filter" => "q"})

      assert_patch(
        view,
        connections_url(context.version.id, view: "connections", setting: "review")
      )
    end

    test "a chip kind the view does not own clears nothing", context do
      three_place_day(context)

      {:ok, view, _html} = mount_connections(context, view: "connections", setting: "review")

      render_hook(view, "remove_connection_filter", %{"filter" => "day"})

      assert has_element?(view, "#connections-chip-setting")
    end

    test "Clear filters removes all three and leaves the view parameter", context do
      three_place_day(context)
      [alpha_group | _rest] = derived_groups(context)

      {:ok, view, _html} =
        mount_connections(context,
          view: "connections",
          setting: "review",
          route: context.route_twenty_four.route_id,
          cq: "block 101"
        )

      render_click(view, "clear_connection_filters", %{})

      assert_patch(view, connections_url(context.version.id, view: "connections"))
      refute has_element?(view, "#connections-clear-filters")
      assert has_element?(view, "#connections-group-#{alpha_group.token}")
    end
  end

  describe "the two empty states" do
    test "a day whose filters drop every connection says so and offers the filters back",
         context do
      three_place_day(context)

      {:ok, view, _html} = mount_connections(context, view: "connections", cq: "nowhere at all")

      assert has_element?(view, "#connections-list h2", "No connections match")
      assert has_element?(view, "#connections-no-match-text", "nowhere at all")
      assert has_element?(view, "#connections-no-match-clear", "Clear filters")
      refute has_element?(view, "#connections-empty")

      render_click(view, "clear_connection_filters", %{})

      assert_patch(view, connections_url(context.version.id, view: "connections"))
      assert has_element?(view, "#connections-summary", "3 of 3 connections at 3 places")
    end

    test "a day holding no blocks says so and offers the one step that creates them",
         context do
      # A day with trips the Blocks page loaded, but no block to read a
      # consecutive pair out of. A day with no trips at all is the page's own
      # first-use state and never reaches the Connections panel.
      stop = place_stop(context, "Nowhere Yard")

      solo =
        trip_fixture(
          context.organization.id,
          context.version.id,
          context.route_twelve.route_id,
          %{service_id: "W", trip_id: "nobody"}
        )

      stop_time_fixture(
        context.organization.id,
        context.version.id,
        solo.trip_id,
        stop.stop_id,
        %{stop_sequence: 1, arrival_time: "06:00:00", departure_time: "06:00:00"}
      )

      {:ok, view, _html} = mount_connections(context, view: "connections")

      assert has_element?(view, "#connections-empty", "No connections yet")
      assert has_element?(view, "#connections-timeline-link", "Assign trips to blocks")
      refute has_element?(view, "#connections-no-match-text")

      view |> element("#connections-timeline-link") |> render_click()

      assert_patch(view, blocks_path(context.version.id))
    end

    test "a day holding blocks but no consecutive pair also says No connections yet", context do
      stop = place_stop(context, "Solo Yard")

      blocked_trip_fixture(
        context.organization.id,
        context.version.id,
        context.route_twelve.route_id,
        %{
          service_id: "W",
          trip_id: "solo",
          block_id: "900",
          first_stop: stop.stop_id,
          last_stop: stop.stop_id,
          first_arrival: "06:00:00",
          last_arrival: "07:00:00"
        }
      )

      {:ok, view, _html} = mount_connections(context, view: "connections")

      assert has_element?(view, "#connections-empty", "No connections yet")
      assert has_element?(view, "#connections-summary", "0 of 0 connections at 0 places")
    end
  end

  describe "the pager" do
    test "51 groups page into 50 and 1, and the pager moves between them", context do
      seed_paged_day(context, 51)

      {:ok, view, _html} = mount_connections(context, view: "connections")

      assert has_element?(view, "#connections-pager", "Showing 1–50 of 51 groups")
      assert page_row_count(view) == 50

      render_click(view, "paginate_groups", %{"page" => "2"})

      assert_patch(view, connections_url(context.version.id, view: "connections", gpage: "2"))
      assert has_element?(view, "#connections-pager", "Showing 51–51 of 51 groups")
      assert page_row_count(view) == 1
    end

    test "a page the list does not hold clamps to the last page rather than emptying", context do
      seed_paged_day(context, 51)

      {:ok, view, _html} = mount_connections(context, view: "connections", gpage: "9")

      assert has_element?(view, "#connections-pager", "Showing 51–51 of 51 groups")
      assert page_row_count(view) == 1
    end

    test "a day with one page shows no pager at all", context do
      three_place_day(context)

      {:ok, view, _html} = mount_connections(context, view: "connections")

      refute has_element?(view, "#connections-pager")
    end
  end

  describe "the layout" do
    test "the list and the map pane are the two columns of one workspace", context do
      three_place_day(context)

      {:ok, view, _html} = mount_connections(context, view: "connections")

      assert has_element?(view, "#connections-layout")
      assert has_element?(view, "#connections-list")
      assert has_element?(view, "#connections-map-pane")
      assert has_element?(view, "#connections-filter-form")
    end

    test "the note that settings span every date is on the summary strip", context do
      three_place_day(context)

      {:ok, view, _html} = mount_connections(context, view: "connections")

      assert has_element?(
               view,
               "#connections-summary-strip",
               "Settings apply to every date both trips run, not only this day type."
             )
    end
  end

  # The place sections in DOM order, as their encoded ids.
  defp attribute(view, selector, name) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.flat_map(&LazyHTML.attribute(&1, name))
  end

  defp texts(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.replace(~r/\s+/, " ") |> String.trim()))
  end

  defp section_ids(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("section[id^='connections-place-']")
    |> Enum.map(fn section -> section |> LazyHTML.attribute("id") |> List.first() end)
  end

  defp page_row_count(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("button[id^='connections-group-']")
    |> Enum.count()
  end

  # Two places whose pairs run on disjoint routes, so a Route filter has
  # something to drop: Alpha joins R12 to R24, Beta joins R50 to R24.
  defp two_route_day(context) do
    alpha = place_stop(context, "Alpha Yard", lat: "40.1000", lon: "-74.1000")
    beta = place_stop(context, "Beta Yard", lat: "40.2000", lon: "-74.2000")

    block_pair(context, %{stop: alpha, block_id: "101", suffix: "a", first: 21_600})

    block_pair(context, %{
      stop: beta,
      block_id: "202",
      suffix: "b",
      first: 21_600,
      from_route: context.route_lonely,
      to_route: context.route_twenty_four
    })

    Map.put(context, :stops, [alpha, beta])
  end

  # A turnback: one route's two directions meeting at one stop, which is the only
  # shape Google offers staying on board within a single route for.
  defp turnback_pair(context) do
    stop = place_stop(context, "Delta Yard", lat: "40.4000", lon: "-74.4000")

    block_pair(context, %{
      stop: stop,
      block_id: "404",
      suffix: "t",
      first: 21_600,
      from_route: context.route_twelve,
      to_route: context.route_twelve,
      from_direction: 0,
      to_direction: 1
    })

    Map.put(context, :stops, context.stops ++ [stop])
  end

  # `count` blocks of one consecutive pair each, at stops named so R12's
  # count-descending order falls back to the place name and the sections and the
  # pager are both decided by that order.
  defp seed_paged_day(context, count) do
    Enum.each(1..count, fn number ->
      stop =
        place_stop(context, "Paged #{String.pad_leading(Integer.to_string(number), 3, "0")}",
          # Each place a hundredth of a thousandth of a degree north of the last,
          # so the 51 stops are distinct rows at distinct points rather than one
          # stop written 51 times at one point.
          lat: lat_for(number),
          lon: "-74.0000"
        )

      block_pair(context, %{
        stop: stop,
        block_id: "P#{number}",
        suffix: "g",
        # 05:00 plus ninety seconds a block, so 51 blocks stay inside the day
        # while every arrival time — and therefore every R12 arrival order — is
        # distinct.
        first: 18_000 + number * 90
      })
    end)

    context
  end

  # The nth place's latitude, in the seven decimal places a `stop_lat` stores.
  defp lat_for(number),
    do: Decimal.to_string(Decimal.add("40.0000", Decimal.mult(number, "0.0001")))
end
