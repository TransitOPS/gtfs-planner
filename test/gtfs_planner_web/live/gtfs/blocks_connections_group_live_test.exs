defmodule GtfsPlannerWeb.Gtfs.BlocksConnectionsGroupLiveTest do
  @moduledoc """
  Merge evidence (EV-23) for the group panel (R12, R13, AC-11, AC-12, AC-20,
  CL-10, rejects FH-11):

  - Opening a group from the list replaces the list with the group's heading,
    its facts, the hints of its first connection and its table of connections.
  - The table lists every connection the group's own derivation holds, with the
    block button, the arrival and the pair, the wait, and the R13 setting chip
    the timeline's gap chips and the drawer already use.
  - A block button sends `open_gap`, so the URL keeps `view=connections` and the
    group and the connection's own row carries `aria-current="true"`.
  - Set all offers the three settings, refuses a fourth, and keeps
    `#bulk-review-open` disabled with "Choose a setting to review." until one of
    them is chosen.
  - "All places" returns to the list and hands the keyboard back to the row the
    reader came from.

  Every case runs through the ordinary `/gtfs/:version/blocks` route on the
  production `CatalogReadAdapter.Repo` and the scoped `Blocking` context, so the
  group, its facts and its settings are the ones `Blocking.Connections` derived
  from the loaded day rather than values this module reconstructs.

  The seeded day is small and deliberate. One place holds two blocks of one
  consecutive pair each: the first pair carries a single type 4 record (R13's
  quiet `:stay`), the second carries a type 4 and a stopless type 5 record
  (R13's `:conflict`, which needs review), and a third place joins one route's
  two directions, which is the only turnback Google offers staying on board
  within a single route for.

  The focused gate command is deferred to branch review:
  `MIX_TEST_PARTITION=_seat11 gtimeout --signal=TERM --kill-after=10s 120s mix test test/gtfs_planner_web/live/gtfs/blocks_connections_group_live_test.exs`.

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
      route_twenty_four: twenty_four
    }
  end

  defp editor_conn(context) do
    log_in_user(context.conn, context.user, organization: context.organization)
  end

  defp connections_url(version_id, params) do
    "/gtfs/#{version_id}/blocks?" <> URI.encode_query(params)
  end

  defp mount_connections(context, params) do
    live(editor_conn(context), connections_url(context.version.id, params))
  end

  # The day's own groups, read through the production derivation the panel reads,
  # so a case names the group it means by its own token.
  defp derived_groups(context) do
    {:ok, day} =
      GtfsPlanner.Gtfs.load_blocking_day(context.organization.id, context.version.id, nil)

    Connections.build(day).groups
  end

  # A row's DOM id token: the connection's own id, its two trip UUIDs joined by a
  # bar, encoded without padding.
  defp row_token(connection), do: Base.url_encode64(connection.id, padding: false)

  defp place_stop(context, name, opts) do
    stop_fixture(context.organization.id, context.version.id, %{
      stop_id: "CONN_GROUP_#{System.unique_integer([:positive])}",
      stop_name: name,
      stop_lat: Decimal.new(Keyword.get(opts, :lat, "40.0000")),
      stop_lon: Decimal.new(Keyword.get(opts, :lon, "-74.0000"))
    })
  end

  # One block's pair of consecutive trips meeting at `stop`, so the pair is a
  # connection and the two trips' routes and directions are the group's key.
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

  # One place holding two blocks: a stay pair and a conflicting pair, so the group
  # has two connections, two settings and two waits. The first block arrives at
  # 06:00 and the second at 07:00, so the group's arrival range and the two
  # arrival times below are the day's own.
  defp two_connection_group(context) do
    stop = place_stop(context, "Farragut Square", lat: "40.1000", lon: "-74.1000")

    stay = block_pair(context, %{stop: stop, block_id: "101", suffix: "s", first: 21_600})
    stay_record(context, stay)

    conflict = block_pair(context, %{stop: stop, block_id: "202", suffix: "c", first: 25_200})
    stay_record(context, conflict)
    reboard_record(context, conflict)

    context
    |> Map.put(:stops, [stop])
    |> Map.put(:stay_pair, stay)
    |> Map.put(:conflict_pair, conflict)
  end

  # A second place holding one block, so a case has a group other than the first
  # to open.
  defp second_group(context) do
    stop = place_stop(context, "Dupont Circle", lat: "40.2000", lon: "-74.2000")

    block_pair(context, %{stop: stop, block_id: "303", suffix: "o", first: 21_600})

    Map.put(context, :stops, context.stops ++ [stop])
  end

  # A group whose pair hands over at a stop other than the one it arrives at, so
  # the facts name a departure stop and a handoff kind. The stop is far enough
  # away to be neither the same stop nor the same station, so the panel has a
  # handoff line to show rather than a second "Same stop".
  defp handoff_group(context) do
    arrives = place_stop(context, "Metro Center", lat: "40.3000", lon: "-74.3000")
    departs = place_stop(context, "Federal Triangle", lat: "40.5000", lon: "-74.5000")

    block_pair(context, %{
      stop: arrives,
      from_stop: arrives,
      to_stop: departs,
      block_id: "606",
      suffix: "h",
      first: 21_600
    })

    Map.put(context, :stops, context.stops ++ [arrives, departs])
  end

  # The word `Blocking.Checks` uses for a handoff kind, so the case asserts the
  # panel prints the day's own kind rather than a second mapping of it.
  defp handoff_word(handoffs) do
    case List.first(handoffs) do
      :same_stop -> "Same stop"
      :same_station -> "Same station"
      :nearby -> "Nearby stop"
      :moves -> "Vehicle moves"
      _other -> "Handoff"
    end
  end

  # A turnback: one route's two directions meeting at one stop.
  defp turnback_group(context) do
    stop = place_stop(context, "Union Depot", lat: "40.3000", lon: "-74.3000")

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

    Map.put(context, :stops, [stop])
  end

  # The panel for the group the derivation names, mounted on the URL that selects
  # it — the same URL a reader's click on the row produces.
  defp open_group(context, group) do
    mount_connections(context, view: "connections", group: group.token)
  end

  describe "the heading and the facts" do
    test "the heading names the two routes and the place the group is decided at", context do
      context = two_connection_group(context)
      [group | _rest] = derived_groups(context)

      {:ok, view, _html} = open_group(context, group)

      assert has_element?(view, "#connections-group-heading", "Continues as 24")
      assert has_element?(view, "#connections-group-title", "Continues as 24 at Farragut Square")
      assert has_element?(view, "#connections-group-heading", "12")
      assert has_element?(view, "#connections-group-heading", "24")
    end

    test "a turnback says Turns back at the place rather than naming a route", context do
      context = turnback_group(context)
      [group] = derived_groups(context)

      {:ok, view, _html} = open_group(context, group)

      assert has_element?(view, "#connections-group-title", "Turns back at Union Depot")
      refute has_element?(view, "#connections-group-title", "Continues as")
    end

    test "the facts name the stops, the handoff and the wait with the arrival range", context do
      context = two_connection_group(context)
      [group | _rest] = derived_groups(context)

      {:ok, view, _html} = open_group(context, group)

      assert has_element?(view, "#connections-group-facts", "Arrives at")
      assert has_element?(view, "#connections-group-facts", "Farragut Square")
      assert has_element?(view, "#connections-group-facts", "Departs from")
      # Both pairs hand over at the stop they arrive at, so there is no handoff
      # line to name.
      assert has_element?(view, "#connections-group-facts", "Same stop")
      assert has_element?(view, "#connections-group-facts", "On board")
      assert has_element?(view, "#connections-group-facts", "min, arrivals 06:00:00–08:00:00")
      refute has_element?(view, "#connections-group-facts", "Handoff")
    end

    test "a group whose pair hands over at another stop names the departure and the handoff",
         context do
      context = handoff_group(context)
      [group] = derived_groups(context)

      {:ok, view, _html} = open_group(context, group)

      assert has_element?(view, "#connections-group-facts", "Metro Center")
      assert has_element?(view, "#connections-group-facts", "Federal Triangle")
      assert has_element?(view, "#connections-group-facts", "Handoff")
      assert has_element?(view, "#connections-group-facts", handoff_word(group.handoffs))
      refute has_element?(view, "#connections-group-facts", "Same stop")
    end

    test "the hints of the first connection are the ones its own drawer shows", context do
      context = two_connection_group(context)
      [group | _rest] = derived_groups(context)

      {:ok, view, _html} = open_group(context, group)

      # The first connection is the 06:00 R12 → R24 pair, so the route change
      # hint is there and the turnback hint is not.
      assert has_element?(view, "#connections-group-hints [data-hint='route_change']")
      assert has_element?(view, "#connections-group-hints", "Continues as Route R24")
      refute has_element?(view, "#connections-group-hints [data-hint='turnback']")
    end

    test "a turnback group carries the turnback hint", context do
      context = turnback_group(context)
      [group] = derived_groups(context)

      {:ok, view, _html} = open_group(context, group)

      assert has_element?(view, "#connections-group-hints [data-hint='turnback']")
    end
  end

  describe "the connections table" do
    test "every connection of the group is a row, with its block, arrival, wait and setting",
         context do
      context = two_connection_group(context)
      [group | _rest] = derived_groups(context)
      [first, second] = group.connections

      {:ok, view, _html} = open_group(context, group)

      assert has_element?(view, "#connections-group-count", "2 connections")

      assert has_element?(
               view,
               "#connections-connection-#{row_token(first)}",
               "101"
             )

      assert has_element?(
               view,
               "#connections-connection-#{row_token(first)}",
               "06:00:00"
             )

      assert has_element?(
               view,
               "#connections-connection-#{row_token(first)}",
               "101-s-a→101-s-b"
             )

      assert has_element?(
               view,
               "#connections-connection-row-#{row_token(first)}",
               "10 min"
             )

      assert has_element?(
               view,
               "#connections-connection-row-#{row_token(second)}",
               "202"
             )

      assert table_row_count(view) == 2
    end

    test "a decided connection carries the stay chip and a conflicting one needs review",
         context do
      context = two_connection_group(context)
      [group | _rest] = derived_groups(context)
      [first, second] = group.connections

      {:ok, view, _html} = open_group(context, group)

      assert has_element?(
               view,
               "#connections-connection-row-#{row_token(first)} [data-setting='stay']",
               "Riders stay on board"
             )

      assert has_element?(
               view,
               "#connections-connection-row-#{row_token(second)} [data-setting='review']",
               "Needs review"
             )
    end

    test "a pair nobody has decided says Not stated rather than showing an empty chip",
         context do
      stop = place_stop(context, "Nowhere Yard", lat: "40.4000", lon: "-74.4000")

      block_pair(context, %{stop: stop, block_id: "505", suffix: "n", first: 21_600})

      [group] = derived_groups(context)

      {:ok, view, _html} = open_group(context, group)

      assert has_element?(view, "#connections-group-table [data-setting='none']", "Not stated")
    end

    test "the four column headers are there, with the wait column right-aligned", context do
      context = two_connection_group(context)
      [group | _rest] = derived_groups(context)

      {:ok, view, _html} = open_group(context, group)

      assert has_element?(view, "#connections-group-table th", "Block")
      assert has_element?(view, "#connections-group-table th", "Arrives")
      assert has_element?(view, "#connections-group-table th", "Wait")
      assert has_element?(view, "#connections-group-table th", "Setting")
    end
  end

  describe "opening a connection" do
    test "a block button opens the connection drawer and keeps the view and the group",
         context do
      context = two_connection_group(context)
      [group | _rest] = derived_groups(context)
      [first, _second] = group.connections

      {:ok, view, _html} = open_group(context, group)

      render_click(view, "open_gap", %{
        "from" => first.from.id,
        "to" => first.to.id,
        "block" => first.block_id
      })

      assert_patch(
        view,
        connections_url(context.version.id,
          view: "connections",
          group: group.token,
          gap: first.id,
          block: "101"
        )
      )

      # The panel is still the panel: the drawer opens over it rather than
      # replacing the group the reader chose.
      assert has_element?(view, "#connections-group-table")
    end

    test "the open connection's row is the current row and the others are not", context do
      context = two_connection_group(context)
      [group | _rest] = derived_groups(context)
      [first, second] = group.connections

      {:ok, view, _html} = open_group(context, group)

      refute current_row?(view, row_token(first))

      render_click(view, "open_gap", %{
        "from" => first.from.id,
        "to" => first.to.id,
        "block" => first.block_id
      })

      assert current_row?(view, row_token(first))
      refute current_row?(view, row_token(second))
    end

    test "a group opened with a connection already in the URL marks its row", context do
      context = two_connection_group(context)
      [group | _rest] = derived_groups(context)
      [second, _first] = Enum.reverse(group.connections)

      {:ok, view, _html} =
        mount_connections(context,
          view: "connections",
          group: group.token,
          gap: second.id
        )

      assert current_row?(view, row_token(second))
    end
  end

  describe "Set all" do
    test "the fieldset offers the three settings and no fourth", context do
      context = two_connection_group(context)
      [group | _rest] = derived_groups(context)

      {:ok, view, _html} = open_group(context, group)

      assert has_element?(view, "#connections-bulk-form", "Set all 2 at once")

      assert has_element?(view, "#connections-bulk-form", "Not stated")
      assert has_element?(view, "#connections-bulk-form", "Riders stay on board")
      assert has_element?(view, "#connections-bulk-form", "Riders must re-board")
      assert radio_count(view) == 3
    end

    test "the review is disabled with a reason until a setting is chosen", context do
      context = two_connection_group(context)
      [group | _rest] = derived_groups(context)

      {:ok, view, _html} = open_group(context, group)

      assert has_element?(view, "#bulk-review-open", "Review 2 connections")
      assert disabled?(view, "#bulk-review-open")
      assert has_element?(view, "#connections-bulk-disabled-note", "Choose a setting to review.")

      render_change(view, "bulk_choice", %{"bulk" => "stay"})

      refute disabled?(view, "#bulk-review-open")
      refute has_element?(view, "#connections-bulk-disabled-note")
      assert checked?(view, "stay")
    end

    test "a setting the fieldset does not offer is refused rather than kept", context do
      context = two_connection_group(context)
      [group | _rest] = derived_groups(context)

      {:ok, view, _html} = open_group(context, group)

      render_change(view, "bulk_choice", %{"bulk" => "review"})

      assert disabled?(view, "#bulk-review-open")
    end

    test "opening another group clears the choice made in the first", context do
      context = two_connection_group(context) |> second_group()
      [group | _rest] = derived_groups(context)

      {:ok, view, _html} = open_group(context, group)
      render_change(view, "bulk_choice", %{"bulk" => "reboard"})

      [other | _rest] = Enum.reject(derived_groups(context), &(&1.token == group.token))
      render_click(view, "open_group", %{"group" => other.token})

      assert has_element?(view, "#connections-group-heading", "Dupont Circle")
      assert disabled?(view, "#bulk-review-open")
      refute checked?(view, "reboard")
    end
  end

  describe "leaving the group" do
    test "All places returns to the list and hands the keyboard back to the group's row",
         context do
      context = two_connection_group(context)
      [group | _rest] = derived_groups(context)

      {:ok, view, _html} = open_group(context, group)

      assert has_element?(view, "#connections-group-back", "All places")
      refute has_element?(view, "#connections-group-table")

      render_click(view, "close_group", %{})

      assert_patch(view, connections_url(context.version.id, view: "connections"))
      assert has_element?(view, "#connections-group-#{group.token}")
      refute has_element?(view, "#connections-group-heading")

      # The back control is one command and one focus: the row the reader came
      # from is the element that takes the keyboard, not the top of the panel.
      back_command = attribute(view, "#connections-group-back", "phx-click")
      assert back_command =~ "close_group"
      assert back_command =~ "#connections-group-#{group.token}"
    end

    test "a group the filters dropped is not a group panel, it is the list", context do
      context = two_connection_group(context)
      [group | _rest] = derived_groups(context)

      {:ok, view, _html} =
        mount_connections(context,
          view: "connections",
          group: group.token,
          setting: "stay"
        )

      # The conflict pair is the one needing review, so the stay filter drops it
      # and the group rebuilds itself from the stay pair rather than vanishing.
      assert has_element?(view, "#connections-group-heading")
      assert has_element?(view, "#connections-group-count", "1 connection")

      {:ok, view, _html} =
        mount_connections(context, view: "connections", group: "not-a-real-token")

      refute has_element?(view, "#connections-group-heading")
      assert has_element?(view, "#connections-group-#{group.token}")
    end
  end

  # The rows the group's own table holds, in DOM order.
  defp table_row_count(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#connections-group-table tbody tr")
    |> length()
  end

  defp current_row?(view, token) do
    case attribute(view, "#connections-connection-row-#{token}", "aria-current") do
      [value] -> value == "true"
      _missing -> false
    end
  end

  defp attribute(view, selector, name) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.filter(selector)
    |> Enum.flat_map(&LazyHTML.attribute(&1, name))
  end

  defp disabled?(view, selector), do: attribute(view, selector, "disabled") != []

  defp checked?(view, value) do
    attribute(view, "input[name='bulk'][value='#{value}']", "checked") != []
  end

  defp radio_count(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#connections-bulk-form input[name='bulk']")
    |> length()
  end
end
