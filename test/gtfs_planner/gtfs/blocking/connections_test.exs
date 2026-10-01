defmodule GtfsPlanner.Gtfs.Blocking.ConnectionsTest do
  @moduledoc """
  Merge evidence (EV-12) for the pure in-seat connection grouping (R12, R13,
  AC-11, AC-12):

  - Two connections of one route pair and direction at one stop are one group; the
    same routes with a different from direction at that stop, and the same routes
    and directions at another stop, are two further groups.
  - A pair holding a stopless type 4 record and a type 5 record is `:conflict` and
    needs review; a pair holding one stale type 4 record is `:stay` and still
    needs review; a pair holding no record is `:none` and needs no review.
  - Groups sort by connection count descending, then place name, then key.
  - `setting: :review` keeps the review connections, `:stay` and `:reboard` and
    `:none` keep only the quiet connections of that setting, `route` matches
    either route, and `q` matches a trip ID case-insensitively and `"block 101"`.
    A group left with no connection is dropped and a group that keeps some is
    rebuilt from them.
  - `page/3` returns the group the requested page starts at and clamps a page
    beyond the last one.
  - `token/1` is URL-safe and decodes back to the key's parts in order, and the
    group it names is the one the list holds.
  - `places/1` sums a place's groups' connections, carries `review?` from any of
    them, and leaves a stop without coordinates at `nil` rather than at zero.
  - A group of one route's two directions is a turnback; a group missing either
    direction is not.

  The days are hand-built in the shape `Blocking.load_day/3` returns, carrying the
  keys the grouping reads: each block's `summary`, `trips` and `gaps`, and the
  day's `in_seat` map of stored records with the state the shared rule gave them.
  The module reads no database, clock, file or network.

  The focused gate command is deferred to branch review:
  `MIX_TEST_PARTITION=_seat11 mix test
  test/gtfs_planner/gtfs/blocking/connections_test.exs`.
  """
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.Blocking.Connections

  @unit_separator <<31>>

  describe "build/1 - grouping (R12)" do
    test "one arrival stop and one pair of routes and directions make one group" do
      far_a = stop("FAR_A", "Far A")
      far_b = stop("FAR_B", "Far B")

      day =
        day([
          connection(
            block_id: "1",
            arrival: far_a,
            from: trip(1, "R12", 0, 1_800),
            to: trip(2, "R24", 0, 1_900)
          ),
          connection(
            block_id: "2",
            arrival: far_a,
            from: trip(3, "R12", 1, 2_400),
            to: trip(4, "R24", 0, 2_500)
          ),
          connection(
            block_id: "3",
            arrival: far_b,
            from: trip(5, "R12", 0, 3_000),
            to: trip(6, "R24", 0, 3_100)
          ),
          connection(
            block_id: "4",
            arrival: far_a,
            from: trip(7, "R12", 0, 4_000),
            to: trip(8, "R24", 0, 4_100)
          )
        ])

      built = Connections.build(day)

      assert length(built.connections) == 4
      assert length(built.groups) == 3

      assert length(find_group(built.groups, {"FAR_A", "R12", 0, "R24", 0}).connections) == 2
      assert length(find_group(built.groups, {"FAR_A", "R12", 1, "R24", 0}).connections) == 1
      assert length(find_group(built.groups, {"FAR_B", "R12", 0, "R24", 0}).connections) == 1
    end

    test "a connection is named by its two trips and carries the pair's records" do
      day =
        day(
          [
            connection(
              block_id: "101",
              arrival: stop("FAR_A", "Far A"),
              from: trip(1, "R12", 0, 1_800),
              to: trip(2, "R24", 0, 1_900)
            )
          ],
          %{
            uuid(2) => [record(uuid(102), "TRIP-1", "TRIP-2", 5, :matches)],
            uuid(1) => [record(uuid(101), "TRIP-1", "TRIP-2", 4, :matches)]
          }
        )

      assert [connection] = Connections.build(day).connections

      assert connection.id == "#{uuid(1)}|#{uuid(2)}"
      assert connection.block_id == "101"
      assert connection.from.trip_id == "TRIP-1"
      assert connection.to.trip_id == "TRIP-2"
      assert connection.gap.gap_secs == 300
      assert Enum.map(connection.records, & &1.row.id) == [uuid(101), uuid(102)]
    end
  end

  describe "build/1 - settings and review (R13)" do
    setup do
      day =
        day(
          [
            connection(
              block_id: "1",
              from: trip(1, "R12", 0, 1_800),
              to: trip(2, "R24", 0, 1_900)
            ),
            connection(
              block_id: "2",
              from: trip(3, "R12", 0, 2_000),
              to: trip(4, "R24", 0, 2_100)
            ),
            connection(
              block_id: "3",
              from: trip(5, "R12", 0, 2_200),
              to: trip(6, "R24", 0, 2_300)
            )
          ],
          %{
            uuid(1) => [record(uuid(101), "TRIP-1", "TRIP-2", 4, :matches)],
            uuid(2) => [record(uuid(102), "TRIP-1", "TRIP-2", 5, :matches)],
            uuid(3) => [record(uuid(103), "TRIP-3", "TRIP-4", 4, {:stale, :no_block})]
          }
        )

      %{connections: Map.new(Connections.build(day).connections, &{&1.id, &1})}
    end

    test "a stopless type 4 record beside a type 5 record is a conflict needing review",
         %{connections: connections} do
      connection = Map.fetch!(connections, "#{uuid(1)}|#{uuid(2)}")

      assert connection.setting == :conflict
      assert connection.review?
      assert Enum.all?(connection.records, &is_nil(&1.row.from_stop_id))
    end

    test "a single stale type 4 record is :stay and still needs review", %{
      connections: connections
    } do
      connection = Map.fetch!(connections, "#{uuid(3)}|#{uuid(4)}")

      assert connection.setting == :stay
      assert connection.review?
    end

    test "a pair with no record is :none and needs no review", %{connections: connections} do
      connection = Map.fetch!(connections, "#{uuid(5)}|#{uuid(6)}")

      assert connection.setting == :none
      refute connection.review?
    end
  end

  describe "build/1 - group facts and order" do
    test "sorts by connection count descending, then place name, then key" do
      day =
        day([
          connection(
            block_id: "1",
            arrival: stop("Z", "Zed Yard"),
            from: trip(1, "R1", 0, 600),
            to: trip(2, "R2", 0, 700)
          ),
          connection(
            block_id: "2",
            arrival: stop("A", "Alpha Yard"),
            from: trip(3, "R1", 0, 800),
            to: trip(4, "R2", 0, 900)
          ),
          connection(
            block_id: "3",
            arrival: stop("M", "Mid Yard"),
            from: trip(5, "R1", 0, 1_000),
            to: trip(6, "R2", 0, 1_100)
          ),
          connection(
            block_id: "4",
            arrival: stop("M", "Mid Yard"),
            from: trip(7, "R1", 0, 1_200),
            to: trip(8, "R2", 0, 1_300)
          )
        ])

      assert ["Mid Yard", "Alpha Yard", "Zed Yard"] =
               day |> Connections.build() |> Map.fetch!(:groups) |> Enum.map(& &1.place.name)
    end

    test "a group's counts, waits, arrivals and handoffs describe its connections" do
      far_a = stop("FAR_A", "Far A")
      far_b = stop("FAR_B", "Far B")

      day =
        day([
          connection(
            block_id: "1",
            arrival: far_a,
            gap_secs: 600,
            handoff: :same_stop,
            from: trip(1, "R12", 0, 1_800),
            to: trip(2, "R24", 0, 1_900)
          ),
          connection(
            block_id: "2",
            arrival: far_a,
            departure: far_b,
            gap_secs: 90,
            handoff: {:moves, 370},
            from: trip(3, "R12", 0, 2_400),
            to: trip(4, "R24", 0, 2_500)
          )
        ])

      assert [group] = Connections.build(day).groups

      assert group.key == {"FAR_A", "R12", 0, "R24", 0}
      assert group.place == %{id: "FAR_A", name: "Far A"}
      assert group.arrival_stop == far_a
      assert group.departure_stop == far_a
      assert group.from_route_id == "R12"
      assert group.to_route_id == "R24"
      assert group.headsign == "Terminus"
      refute group.turnback?
      assert group.handoffs == [:same_stop, :moves]
      assert group.wait_min == 1
      assert group.wait_max == 10
      assert group.first_arrival == 1_800
      assert group.last_arrival == 2_400
      assert group.counts == %{none: 2, stay: 0, reboard: 0, conflict: 0, review: 0}
    end

    test "a place is the arrival stop's parent station when it has one" do
      far_b = stop("FAR_B", "Far B", parent_station: "STATION_FAR", parent_name: "Far Station")

      day =
        day([
          connection(
            block_id: "1",
            arrival: far_b,
            from: trip(1, "R12", 0, 1_800),
            to: trip(2, "R24", 0, 1_900)
          )
        ])

      assert [group] = Connections.build(day).groups
      assert group.place == %{id: "STATION_FAR", name: "Far Station"}
    end

    test "one route's two directions turn back, and a missing direction does not" do
      day =
        day([
          connection(
            block_id: "1",
            arrival: stop("FAR_A", "Far A"),
            from: trip(1, "R12", 0, 1_800),
            to: trip(2, "R12", 1, 1_900)
          ),
          connection(
            block_id: "2",
            arrival: stop("FAR_B", "Far B"),
            from: trip(3, "R24", nil, 2_400),
            to: trip(4, "R24", 1, 2_500)
          )
        ])

      groups = Connections.build(day).groups

      assert find_group(groups, {"FAR_A", "R12", 0, "R12", 1}).turnback?
      refute find_group(groups, {"FAR_B", "R24", nil, "R24", 1}).turnback?
    end
  end

  describe "filter/2" do
    setup do
      day =
        day(
          [
            connection(
              block_id: "1",
              arrival: stop("ALPHA", "Alpha Yard"),
              from: trip(1, "R12", 0, 1_800),
              to: trip(2, "R24", 0, 1_900)
            ),
            connection(
              block_id: "2",
              arrival: stop("BETA", "Beta Yard"),
              from: trip(3, "R12", 0, 2_000),
              to: trip(4, "R24", 0, 2_100)
            ),
            connection(
              block_id: "101",
              arrival: stop("GAMMA", "Gamma Yard"),
              from: trip(5, "R30", 0, 2_200),
              to: trip(6, "R40", 0, 2_300)
            ),
            connection(
              block_id: "4",
              arrival: stop("DELTA", "Delta Yard"),
              from: trip(7, "R12", 0, 2_400),
              to: trip(8, "R24", 0, 2_500)
            )
          ],
          %{
            uuid(1) => [record(uuid(101), "TRIP-1", "TRIP-2", 4, :matches)],
            uuid(3) => [record(uuid(103), "TRIP-3", "TRIP-4", 5, {:stale, :stops_changed})],
            uuid(7) => [record(uuid(107), "TRIP-7", "TRIP-8", 5, :matches)]
          }
        )

      %{groups: Connections.build(day).groups}
    end

    test "setting :review keeps only the connections needing review", %{groups: groups} do
      filtered = Connections.filter(groups, %{setting: :review})

      assert [group] = filtered
      assert group.place.name == "Beta Yard"
      assert group.counts == %{none: 0, stay: 0, reboard: 1, conflict: 0, review: 1}
    end

    test "a decided setting keeps only its quiet connections", %{groups: groups} do
      assert [group] = Connections.filter(groups, %{setting: :stay})
      assert group.place.name == "Alpha Yard"

      assert [group] = Connections.filter(groups, %{setting: :reboard})
      assert group.place.name == "Delta Yard"

      assert [group] = Connections.filter(groups, %{setting: :none})
      assert group.place.name == "Gamma Yard"
    end

    test "route matches either of a connection's routes", %{groups: groups} do
      assert ["Gamma Yard"] =
               groups
               |> Connections.filter(%{route: "R30"})
               |> Enum.map(& &1.place.name)

      assert ["Alpha Yard", "Beta Yard", "Delta Yard"] =
               groups
               |> Connections.filter(%{route: "R24"})
               |> Enum.map(& &1.place.name)
    end

    test "q matches a trip ID case-insensitively and \"block 101\"", %{groups: groups} do
      assert ["Beta Yard"] =
               groups
               |> Connections.filter(%{q: "trip-3"})
               |> Enum.map(& &1.place.name)

      assert ["Gamma Yard"] =
               groups
               |> Connections.filter(%{q: "BLOCK 101"})
               |> Enum.map(& &1.place.name)

      assert ["Gamma Yard"] =
               groups
               |> Connections.filter(%{q: "gamma"})
               |> Enum.map(& &1.place.name)

      assert [] = Connections.filter(groups, %{q: "nothing here"})
    end

    test "no filter keeps every group in the day's order", %{groups: groups} do
      assert Connections.filter(groups, %{}) == groups
      assert Connections.filter(groups, %{setting: nil, route: nil, q: "  "}) == groups
    end
  end

  describe "page/3" do
    setup do
      blocks =
        for number <- 1..51 do
          connection(
            block_id: "B#{number}",
            arrival: stop("STOP_#{number}", "Stop #{number}"),
            from: trip(number * 2 - 1, "R12", 0, number * 100),
            to: trip(number * 2, "R24", 0, number * 100 + 50)
          )
        end

      %{groups: day(blocks) |> Connections.build() |> Map.fetch!(:groups)}
    end

    test "returns the group the requested page starts at", %{groups: groups} do
      assert %{groups: first_page, page: 1, pages: 2} = Connections.page(groups, 1, 50)
      assert length(first_page) == 50
      assert first_page == Enum.take(groups, 50)

      assert %{groups: [last], page: 2, pages: 2} = Connections.page(groups, 2, 50)
      assert last == Enum.at(groups, 50)
    end

    test "clamps a page beyond the last one", %{groups: groups} do
      assert %{page: 2, pages: 2} = Connections.page(groups, 9, 50)
      assert %{groups: [], page: 1, pages: 1} = Connections.page([], 3, 50)
    end
  end

  describe "token/1" do
    test "is URL-safe and decodes back to the key's parts in order" do
      key = {"FAR_A", "R12", 0, "R24", nil}
      token = Connections.token(key)

      refute token =~ ~r/[^A-Za-z0-9_-]/

      assert ["FAR_A", "R12", "0", "R24", ""] =
               token |> Base.url_decode64!(padding: false) |> String.split(@unit_separator)
    end

    test "names the group the list holds" do
      day =
        day([
          connection(
            block_id: "1",
            arrival: stop("FAR_A", "Far A"),
            from: trip(1, "R12", 0, 1_800),
            to: trip(2, "R24", 0, 1_900)
          )
        ])

      [group] = Connections.build(day).groups

      assert group.token == Connections.token(group.key)
      assert Connections.build(day).groups |> Enum.find(&(&1.token == group.token)) == group
    end
  end

  describe "places/1" do
    test "sums a place's connections, carries review? and keeps nil coordinates" do
      alpha =
        stop("ALPHA_1", "Alpha Bay",
          parent_station: "ALPHA",
          parent_name: "Alpha Station",
          lat: 42.1,
          lon: -71.2
        )

      no_coords = stop("SOLO", "Solo Stop")

      day =
        day(
          [
            connection(
              block_id: "1",
              arrival: alpha,
              from: trip(1, "R12", 0, 1_800),
              to: trip(2, "R24", 0, 1_900)
            ),
            connection(
              block_id: "2",
              arrival: alpha,
              from: trip(3, "R12", 1, 2_000),
              to: trip(4, "R24", 0, 2_100)
            ),
            connection(
              block_id: "3",
              arrival: no_coords,
              from: trip(5, "R12", 0, 2_200),
              to: trip(6, "R24", 0, 2_300)
            )
          ],
          %{
            uuid(3) => [record(uuid(103), "TRIP-3", "TRIP-4", 4, {:stale, :not_next})]
          }
        )

      assert [alpha_place, solo_place] = Connections.places(Connections.build(day).groups)

      assert alpha_place == %{
               id: "ALPHA",
               name: "Alpha Station",
               lat: 42.1,
               lon: -71.2,
               count: 2,
               review?: true
             }

      assert solo_place == %{
               id: "SOLO",
               name: "Solo Stop",
               lat: nil,
               lon: nil,
               count: 1,
               review?: false
             }
    end

    test "is empty for a day with no groups" do
      assert [] == Connections.places([])
    end
  end

  defp find_group(groups, key) do
    Enum.find(groups, fn group -> group.key == key end) ||
      flunk("no group for #{inspect(key)}")
  end

  # A day in the shape `Blocking.load_day/3` returns, carrying the keys the
  # grouping reads: each block's `summary`, `trips` and `gaps`, and the day's
  # `in_seat` map of stored records with the state the shared rule gave them.
  defp day(blocks, in_seat \\ %{}) do
    %{
      day_types: [],
      day_type: nil,
      blocks: blocks,
      in_seat: in_seat,
      counts: %{blocks: length(blocks), trips: 0, unassigned: 0, problems: 0, notices: 0}
    }
  end

  # One block holding one connection: `from` ends at the block's arrival stop and
  # `to` starts there `gap_secs` later, which is the gap the day load derives.
  defp connection(opts) do
    block_id = Keyword.get(opts, :block_id, "1")
    arrival = Keyword.get(opts, :arrival, stop("FAR_A", "Far A"))

    from =
      opts
      |> Keyword.fetch!(:from)
      |> Keyword.merge(block_id: block_id, last_stop: arrival)
      |> trip()

    to =
      opts
      |> Keyword.fetch!(:to)
      |> Keyword.merge(block_id: block_id, first_stop: Keyword.get(opts, :departure, arrival))
      |> trip()

    %{
      summary: %{block_id: block_id},
      trips: [from, to],
      gaps: [
        %{
          from_id: from.id,
          to_id: to.id,
          gap_secs: Keyword.get(opts, :gap_secs, 300),
          handoff: Keyword.get(opts, :handoff, :same_stop)
        }
      ]
    }
  end

  # One numbered trip of a route in a direction, arriving and ending at `at`, so a
  # connection's arrival is the `at` it was built with and a gap's seconds are the
  # only thing that decides its wait.
  defp trip(number, route_id, direction_id, at) do
    [
      id: uuid(number),
      trip_id: "TRIP-#{number}",
      route_id: route_id,
      direction_id: direction_id,
      first_arrival: at,
      last_arrival: at
    ]
  end

  defp trip(opts) do
    first_stop = Keyword.get(opts, :first_stop)
    first_arrival = Keyword.get(opts, :first_arrival, 0)
    first_departure = Keyword.get(opts, :first_departure, first_arrival)
    last_arrival = Keyword.get(opts, :last_arrival, first_arrival)

    %{
      id: Keyword.get(opts, :id),
      trip_id: Keyword.get(opts, :trip_id),
      route_id: Keyword.get(opts, :route_id),
      service_id: "WEEK",
      block_id: Keyword.get(opts, :block_id),
      direction_id: Keyword.get(opts, :direction_id),
      trip_headsign: Keyword.get(opts, :headsign, "Terminus"),
      route_pattern_id: nil,
      shape_id: nil,
      updated_at: ~U[2026-09-01 12:00:00Z],
      frequency?: false,
      headway_secs: nil,
      first_arrival: first_arrival,
      first_departure: first_departure,
      last_arrival: last_arrival,
      last_departure: Keyword.get(opts, :last_departure, last_arrival),
      first_pickup_type: 0,
      last_drop_off_type: 0,
      first_stop: first_stop,
      last_stop: Keyword.get(opts, :last_stop),
      plottable?: true
    }
  end

  defp stop(stop_id, name, opts \\ []) do
    %{
      stop_id: stop_id,
      name: name,
      parent_station: Keyword.get(opts, :parent_station),
      parent_name: Keyword.get(opts, :parent_name),
      lat: Keyword.get(opts, :lat),
      lon: Keyword.get(opts, :lon)
    }
  end

  # One type 4/5 record as the day load holds it: the stored row with the state
  # the shared rule gave it.
  defp record(id, from_trip_id, to_trip_id, transfer_type, state) do
    %{
      row: %{
        id: id,
        from_trip_id: from_trip_id,
        to_trip_id: to_trip_id,
        transfer_type: transfer_type,
        from_stop_id: nil,
        to_stop_id: nil,
        updated_at: ~U[2026-09-01 12:00:00Z]
      },
      state: state
    }
  end

  # Stable UUIDs, so a test can name the trip or record it means.
  defp uuid(number) do
    "00000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(number), 12, "0")
  end
end
