defmodule GtfsPlanner.Gtfs.Blocking.InSeatTest do
  @moduledoc """
  Merge evidence (EV-4) for the shared in-seat state rule (R6, AC-7):

  - A pair that is consecutive in one block on every day type both services run in
    matches, including when the record carries no stops.
  - A trip between the pair on one day type makes the record stale `not_next`,
    naming only that day type with its label, date count and the natural trip ID
    the day type runs after the first trip; every failing day type is named in the
    context's list order.
  - A first trip that ends its block's order names no next trip, and a cross-block
    pair names the trip that follows the first trip in its own block.
  - Two non-nil different block IDs, or a missing order for a day type's block,
    are not next.
  - A non-nil record stop that differs from the matching endpoint is
    `:stops_changed`; a record that names no stops is never changed.
  - A trip the context does not carry is `:trip_missing`; an endpoint without a
    block is `:no_block`.
  - Disjoint service dates are `:no_shared_date`, unless the second trip runs the
    day after a date of the first, which is the `:next_service_day`
    continuation read from the first trip's dates.
  - A frequency-based or unplottable trip is `:untimed`, and the second trip
    departing before the first arrives is `:coupling` — at equality it is not.
  - A record with several defects gets the state AC-7's order chooses.
  - `finding/3` turns a stale state into an `:in_seat_stale` warning and an
    unconfirmed state into an `:in_seat_unconfirmed` notice, both named by the
    record ID, and returns `nil` for matches.

  The focused gate command is deferred to branch review:
  `MIX_TEST_PARTITION=_seat11 mix test
  test/gtfs_planner/gtfs/blocking/in_seat_test.exs`. Every expected state
  is taken from R6 and AC-7, trip rows and day types follow the Context contract's
  key sets, and times are integer seconds written by hand. The module reads no
  database, clock, files or network.
  """
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.Blocking.DayTypes
  alias GtfsPlanner.Gtfs.Blocking.InSeat

  # The "Weekday without school" service runs alone on 38 dates and alongside the
  # Saturday service on the 12 dates after them.
  @wws_only_start ~D[2026-09-01]
  @saturday_start ~D[2026-10-09]
  @names %{"SAT" => "Saturday", "WWS" => "Weekday without school"}

  describe "state/2 - a matching record" do
    test "matches when the second trip follows the first on every day type both run in" do
      context =
        context(
          trips: [a_trip(), b_trip(), x_trip()],
          sequences: %{
            {wws_day_type().key, "7"} => ["A", "B"],
            {saturday_day_type().key, "7"} => ["A", "B", "X"]
          }
        )

      assert InSeat.state(row("A", "B"), context) == :matches
    end

    test "treats a type 5 record like a type 4 one" do
      assert InSeat.state(row("A", "B", transfer_type: 5), context()) == :matches
    end

    test "matches when the record carries no stops" do
      record = row("A", "B", from_stop_id: nil, to_stop_id: nil)

      assert InSeat.state(record, context()) == :matches
    end

    test "matches when no supplied day type contains both services" do
      # The state covers the day types the caller supplies; step 11 restricts them
      # to the affected day types.
      assert InSeat.state(row("A", "B"), context(day_types: [])) == :matches
    end
  end

  describe "state/2 - a record that is not next" do
    test "names the one day type where another trip sits between the pair" do
      context =
        context(
          trips: [a_trip(), b_trip(), x_trip()],
          sequences: %{
            {wws_day_type().key, "7"} => ["A", "X", "B"],
            {saturday_day_type().key, "7"} => ["A", "B", "X"]
          }
        )

      assert InSeat.state(row("A", "B"), context) ==
               {:stale,
                {:not_next,
                 [
                   %{
                     key: wws_day_type().key,
                     label: "Weekday without school",
                     date_count: 38,
                     next_trip_id: "X"
                   }
                 ]}}
    end

    test "names no next trip when the first trip ends its block's order" do
      context =
        context(
          trips: [a_trip(), b_trip(), x_trip()],
          day_types: [wws_day_type()],
          sequences: %{{wws_day_type().key, "7"} => ["X", "A"]}
        )

      assert InSeat.state(row("A", "B"), context) ==
               {:stale,
                {:not_next,
                 [
                   %{
                     key: wws_day_type().key,
                     label: "Weekday without school",
                     date_count: 38,
                     next_trip_id: nil
                   }
                 ]}}
    end

    test "a cross-block pair names the trip that follows the first trip in its own block" do
      context =
        context(
          trips: [a_trip(), trip("B", at(9, 10), at(10, 0), block_id: "8"), y_trip()],
          sequences: %{
            {wws_day_type().key, "7"} => ["A", "Y"],
            {saturday_day_type().key, "7"} => ["A", "Y"]
          }
        )

      # The second trip is blocked elsewhere, so block 7's order for a day type holds
      # only the pair's first trip and Y. The pair is not next on either day type, and
      # both name Y: the trip a rider would really be put on instead of staying aboard.
      assert InSeat.state(row("A", "B"), context) ==
               {:stale,
                {:not_next,
                 [
                   %{
                     key: wws_day_type().key,
                     label: "Weekday without school",
                     date_count: 38,
                     next_trip_id: "Y"
                   },
                   %{
                     key: saturday_day_type().key,
                     label: "Saturday + Weekday without school",
                     date_count: 12,
                     next_trip_id: "Y"
                   }
                 ]}}
    end

    test "names every failing day type in the context's list order" do
      context =
        context(
          day_types: [saturday_day_type(), wws_day_type()],
          sequences: %{
            {wws_day_type().key, "7"} => ["B", "A"],
            {saturday_day_type().key, "7"} => ["B", "A"]
          }
        )

      # Both orders end with the pair's first trip, so neither day type has a trip
      # to name as the one that runs next.
      assert InSeat.state(row("A", "B"), context) ==
               {:stale,
                {:not_next,
                 [
                   %{
                     key: saturday_day_type().key,
                     label: "Saturday + Weekday without school",
                     date_count: 12,
                     next_trip_id: nil
                   },
                   %{
                     key: wws_day_type().key,
                     label: "Weekday without school",
                     date_count: 38,
                     next_trip_id: nil
                   }
                 ]}}
    end

    test "fails when the two trips carry different block IDs" do
      context =
        context(
          trips: [a_trip(), trip("B", at(9, 10), at(10, 0), block_id: "8")],
          # Block 7 holds only the pair's first trip, so a day type has nothing to
          # name as the trip that runs next.
          sequences: %{
            {wws_day_type().key, "7"} => ["A"],
            {saturday_day_type().key, "7"} => ["A"]
          }
        )

      assert InSeat.state(row("A", "B"), context) ==
               {:stale,
                {:not_next,
                 [
                   %{
                     key: wws_day_type().key,
                     label: "Weekday without school",
                     date_count: 38,
                     next_trip_id: nil
                   },
                   %{
                     key: saturday_day_type().key,
                     label: "Saturday + Weekday without school",
                     date_count: 12,
                     next_trip_id: nil
                   }
                 ]}}
    end

    test "fails when the day type holds no order for the block" do
      context = context(day_types: [wws_day_type()], sequences: %{})

      assert InSeat.state(row("A", "B"), context) ==
               {:stale,
                {:not_next,
                 [
                   %{
                     key: wws_day_type().key,
                     label: "Weekday without school",
                     date_count: 38,
                     next_trip_id: nil
                   }
                 ]}}
    end
  end

  describe "state/2 - stops" do
    test "reports changed stops when the record names another from stop" do
      record = row("A", "B", from_stop_id: "A-old-end")

      assert InSeat.state(record, context()) == {:stale, :stops_changed}
    end

    test "reports changed stops when the record names another to stop" do
      record = row("A", "B", to_stop_id: "B-old-start")

      assert InSeat.state(record, context()) == {:stale, :stops_changed}
    end
  end

  describe "state/2 - a missing trip or block" do
    test "reports a missing trip when the first trip is absent" do
      assert InSeat.state(row("Z", "B"), context()) == {:stale, :trip_missing}
    end

    test "reports a missing trip when the second trip is absent" do
      assert InSeat.state(row("A", "Z"), context()) == {:stale, :trip_missing}
    end

    test "reports no block when either trip has none" do
      without_from = context(trips: [trip("A", at(8, 0), at(9, 0), block_id: nil), b_trip()])
      without_to = context(trips: [a_trip(), trip("B", at(9, 10), at(10, 0), block_id: nil)])

      assert InSeat.state(row("A", "B"), without_from) == {:stale, :no_block}
      assert InSeat.state(row("A", "B"), without_to) == {:stale, :no_block}
    end
  end

  describe "state/2 - dates the two trips run on" do
    test "reports a next-service-day continuation when the second trip runs the day after" do
      assert InSeat.state(
               row("A", "B"),
               disjoint_date_context([~D[2026-09-01]], [~D[2026-09-02]])
             ) ==
               {:unconfirmed, :next_service_day}
    end

    test "reports no shared date otherwise, reading the continuation from the first trip" do
      assert InSeat.state(
               row("A", "B"),
               disjoint_date_context([~D[2026-09-01]], [~D[2026-09-05]])
             ) ==
               {:stale, :no_shared_date}

      assert InSeat.state(
               row("A", "B"),
               disjoint_date_context([~D[2026-09-02]], [~D[2026-09-01]])
             ) ==
               {:stale, :no_shared_date}
    end
  end

  describe "state/2 - untimed trips and coupling" do
    test "reports coupling when the second trip departs before the first arrives" do
      context = context(trips: [a_trip(), trip("B", at(8, 30), at(10, 0))])

      assert InSeat.state(row("A", "B"), context) == {:unconfirmed, :coupling}
    end

    test "does not report coupling when the second trip departs as the first arrives" do
      context = context(trips: [a_trip(), trip("B", at(9, 0), at(10, 0))])

      assert InSeat.state(row("A", "B"), context) == :matches
    end

    test "reports untimed when the first trip is frequency-based" do
      frequency = trip("A", at(8, 0), at(9, 0), frequency?: true, headway_secs: 1200)

      assert InSeat.state(row("A", "B"), context(trips: [frequency, b_trip()])) ==
               {:unconfirmed, :untimed}
    end

    test "reports untimed when the second trip cannot be plotted" do
      unplottable = trip("B", nil, nil, plottable?: false)

      assert InSeat.state(row("A", "B"), context(trips: [a_trip(), unplottable])) ==
               {:unconfirmed, :untimed}
    end
  end

  describe "state/2 - AC-7's order decides between defects" do
    test "prefers a missing trip to a missing block and no shared date" do
      context =
        context(
          trips: [trip("A", at(8, 0), at(9, 0), block_id: nil, service_id: "AA")],
          service_dates: %{}
        )

      assert InSeat.state(row("A", "Z"), context) == {:stale, :trip_missing}
    end

    test "prefers the shared-date check to the block check" do
      context =
        context(
          trips: [
            trip("A", at(8, 0), at(9, 0), block_id: nil, service_id: "AA"),
            trip("B", at(9, 10), at(10, 0), block_id: nil, service_id: "BB")
          ],
          service_dates: %{
            "AA" => MapSet.new([~D[2026-09-01]]),
            "BB" => MapSet.new([~D[2026-09-05]])
          }
        )

      assert InSeat.state(row("A", "B"), context) == {:stale, :no_shared_date}
    end

    test "prefers the block check to the time check" do
      frequency = trip("A", at(8, 0), at(9, 0), block_id: nil, frequency?: true)

      assert InSeat.state(row("A", "B"), context(trips: [frequency, b_trip()])) ==
               {:stale, :no_block}
    end

    test "prefers the time check to the coupling check" do
      context =
        context(
          trips: [
            trip("A", at(8, 0), at(9, 0), frequency?: true),
            trip("B", at(8, 30), at(10, 0))
          ]
        )

      assert InSeat.state(row("A", "B"), context) == {:unconfirmed, :untimed}
    end

    test "prefers the coupling check to the stops check" do
      context = context(trips: [a_trip(), trip("B", at(8, 30), at(10, 0))])
      record = row("A", "B", from_stop_id: "A-old-end")

      assert InSeat.state(record, context) == {:unconfirmed, :coupling}
    end
  end

  describe "finding/3" do
    test "returns nil for a matching record" do
      context = context()
      record = row("A", "B")

      assert InSeat.finding(record, InSeat.state(record, context), context) == nil
    end

    test "returns a warning carrying the not-next day types for a stale record" do
      context =
        context(
          trips: [a_trip(), b_trip(), x_trip()],
          sequences: %{
            {wws_day_type().key, "7"} => ["A", "X", "B"],
            {saturday_day_type().key, "7"} => ["A", "B", "X"]
          }
        )

      record = row("A", "B")
      state = InSeat.state(record, context)

      assert state ==
               {:stale,
                {:not_next,
                 [
                   %{
                     key: wws_day_type().key,
                     label: "Weekday without school",
                     date_count: 38,
                     next_trip_id: "X"
                   }
                 ]}}

      assert InSeat.finding(record, state, context) == %{
               code: :in_seat_stale,
               severity: :warning,
               block_id: "7",
               trip_ids: ["A", "B"],
               transfer_id: "T4-01",
               detail: %{
                 reason:
                   {:not_next,
                    [
                      %{
                        key: wws_day_type().key,
                        label: "Weekday without school",
                        date_count: 38,
                        next_trip_id: "X"
                      }
                    ]}
               }
             }
    end

    test "returns a notice for an unconfirmed record" do
      context = context(trips: [a_trip(), trip("B", at(8, 30), at(10, 0))])
      record = row("A", "B")
      state = InSeat.state(record, context)

      assert state == {:unconfirmed, :coupling}

      assert InSeat.finding(record, state, context) == %{
               code: :in_seat_unconfirmed,
               severity: :notice,
               block_id: "7",
               trip_ids: ["A", "B"],
               transfer_id: "T4-01",
               detail: %{reason: :coupling}
             }
    end

    test "names the first trip's block and only the trips the context holds" do
      record = row("A", "Z")
      context = context(trips: [a_trip()])
      state = InSeat.state(record, context)

      assert state == {:stale, :trip_missing}

      assert InSeat.finding(record, state, context) == %{
               code: :in_seat_stale,
               severity: :warning,
               block_id: "7",
               trip_ids: ["A"],
               transfer_id: "T4-01",
               detail: %{reason: :trip_missing}
             }

      missing_from = row("Z", "B")
      other_context = context(trips: [b_trip()])

      assert InSeat.finding(
               missing_from,
               InSeat.state(missing_from, other_context),
               other_context
             ) ==
               %{
                 code: :in_seat_stale,
                 severity: :warning,
                 block_id: nil,
                 trip_ids: ["B"],
                 transfer_id: "T4-01",
                 detail: %{reason: :trip_missing}
               }
    end
  end

  # The context of a record whose trips match: A and B are block 7's consecutive
  # trips in both day types, the record's stops are the trips' endpoints, and the
  # pair shares dates. Each case overrides only what it is about.
  defp context(opts \\ []) do
    list = Keyword.get(opts, :trips, [a_trip(), b_trip()])

    %{
      trips: Map.new(list, &{&1.trip_id, &1}),
      service_dates: Keyword.get(opts, :service_dates, service_dates()),
      day_types: Keyword.get(opts, :day_types, [wws_day_type(), saturday_day_type()]),
      sequences:
        Keyword.get(opts, :sequences, %{
          {wws_day_type().key, "7"} => ["A", "B"],
          {saturday_day_type().key, "7"} => ["A", "B"]
        }),
      trip_ids_by_uuid: Map.new(list, &{&1.id, &1.trip_id})
    }
  end

  defp a_trip, do: trip("A", at(8, 0), at(9, 0))
  defp b_trip, do: trip("B", at(9, 10), at(10, 0))
  # Between A (ends 09:00) and B (starts 09:10).
  defp x_trip, do: trip("X", at(9, 2), at(9, 8))
  # The trip block 7 runs after A instead of B, so a cross-block pair names it.
  defp y_trip, do: trip("Y", at(9, 2), at(9, 8))

  defp row(from_trip_id, to_trip_id, opts \\ []) do
    %{
      id: Keyword.get(opts, :id, "T4-01"),
      from_trip_id: from_trip_id,
      to_trip_id: to_trip_id,
      transfer_type: Keyword.get(opts, :transfer_type, 4),
      from_stop_id: Keyword.get(opts, :from_stop_id, from_trip_id <> "-end"),
      to_stop_id: Keyword.get(opts, :to_stop_id, to_trip_id <> "-start")
    }
  end

  # Two trips on separate one-date services, with no day type supplied: only the
  # shared-date check can decide their state.
  defp disjoint_date_context(from_dates, to_dates) do
    context(
      trips: [
        trip("A", at(8, 0), at(9, 0), service_id: "AA"),
        trip("B", at(9, 10), at(10, 0), service_id: "BB")
      ],
      service_dates: %{"AA" => MapSet.new(from_dates), "BB" => MapSet.new(to_dates)}
    )
  end

  # The "Weekday without school" service runs alone on 38 dates and with the
  # Saturday service on the 12 dates after them.
  defp service_dates do
    %{
      "WWS" => MapSet.new(wws_only_dates() ++ saturday_dates()),
      "SAT" => MapSet.new(saturday_dates())
    }
  end

  defp wws_only_dates, do: Enum.map(0..37, &Date.add(@wws_only_start, &1))
  defp saturday_dates, do: Enum.map(0..11, &Date.add(@saturday_start, &1))

  defp wws_day_type, do: day_type(["WWS"], wws_only_dates())
  defp saturday_day_type, do: day_type(["SAT", "WWS"], saturday_dates())

  defp day_type(service_ids, dates) do
    sorted = Enum.sort(service_ids)

    %{
      key: DayTypes.key(sorted),
      service_ids: sorted,
      label: Enum.map_join(sorted, " + ", &Map.fetch!(@names, &1)),
      dates: dates,
      date_count: length(dates),
      first_date: hd(dates),
      last_date: List.last(dates),
      trip_count: 0,
      special?: length(dates) == 1
    }
  end

  # The `Queries.trip_row/3` key set, with times as integer seconds (CR-3).
  defp trip(trip_id, first_departure, last_arrival, opts \\ []) do
    %{
      id: Keyword.get(opts, :id, trip_id),
      trip_id: trip_id,
      route_id: Keyword.get(opts, :route_id, "R1"),
      service_id: Keyword.get(opts, :service_id, "WWS"),
      block_id: Keyword.get(opts, :block_id, "7"),
      trip_headsign: nil,
      route_pattern_id: nil,
      updated_at: ~U[2026-10-01 00:00:00Z],
      frequency?: Keyword.get(opts, :frequency?, false),
      headway_secs: Keyword.get(opts, :headway_secs),
      first_arrival: Keyword.get(opts, :first_arrival, first_departure),
      first_departure: first_departure,
      last_arrival: last_arrival,
      last_departure: Keyword.get(opts, :last_departure, last_arrival),
      first_stop: Keyword.get(opts, :first_stop, stop(trip_id <> "-start")),
      last_stop: Keyword.get(opts, :last_stop, stop(trip_id <> "-end")),
      plottable?: Keyword.get(opts, :plottable?, true)
    }
  end

  defp stop(stop_id) do
    %{stop_id: stop_id, name: stop_id, parent_station: nil, lat: nil, lon: nil}
  end

  defp at(hours, minutes), do: hours * 3600 + minutes * 60
end
